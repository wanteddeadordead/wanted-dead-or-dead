-- Wanted: bounty notices across the factions. Each faction runs its own network (a custom channel is per
-- faction), so a player never hears of the bounties the other side posts on them. A Battle.net friend on the
-- other faction who also runs Wanted can carry them across as hidden game data (C_BattleNet.SendGameData),
-- never chat. Only bounty facts cross: the target, the amount, and when it was posted, under an id that doesn't
-- name the poster. The friend's client stores each as a
-- "notice" record of its own and ordinary sync spreads it on that side, so the target learns of the price on
-- their head and it adds to their lifetime total (the wanted poster).
--
-- Bridges are Battle.net friends and, when it is set up, members of the Wanted Battle.net community: up to
-- MAX_TARGETS online game accounts in WoW Forever on the other faction, friends first. A message too long for one
-- piece of game data goes in parts under its own prefix, so older clients never see a part.

local _, Wanted = ...
local Bridge = Wanted:NewModule("Bridge")
local Store = Wanted.Store
local Bounties = Wanted.Bounties
local Sync = Wanted.Sync
local private = {
	frame = CreateFrame("Frame"),
	bridges = {}, -- gameAccountID -> { faction, character, since, version, parts }
	targets = {}, -- gameAccountID -> { game, account, source } online on the other faction, from the last scan
	runners = {}, -- Battle.net account id -> { version, parts } that answered as a bridge this session
	pushedAt = {}, -- Battle.net account id -> when its notices were last pushed on appearing
	community = nil, -- what the last scan found in the Wanted community, for /wanted community
	helloSent = {}, -- gameAccountID -> time of our last hello
	sent = {}, -- gameAccountID -> { [bountyId] = amount } notices already sent this session
	queue = {}, -- { id, tbl } waiting to go out, one every SEND_SPACING seconds
	sending = false,
	lastScan = nil,
	scanScheduled = false,
	newOnMe = nil, -- { count, amount } gathered for one "price on your head" alert
	msgCounter = 0,
	partial = {}, -- senderID:msgId -> { sender, parts, total, count, t } parts still arriving
	inbound = {}, -- senderID -> { count, minute }
	noticeTimes = {}, -- senderID -> when each new notice from them in the last hour was taken
	targetTimes = {}, -- target GUID -> when each new notice about them in the last hour was taken
	stats = { hellos = 0, noticesSent = 0, noticesReceived = 0, noticesStored = 0, skipped = 0, pushes = 0, partsSent = 0, partsReceived = 0, partsExpired = 0 },
}
local PREFIX = "WNTDB"
-- A message in parts: "msgId:part/total:chunk". Its own prefix, so a client before parts never sees one
local PART_PREFIX = "WNTDP"
local TAG_HELLO, TAG_ANSWER, TAG_NOTICES = "H", "A", "N"
local SCAN_INTERVAL = 30 -- friend list and community changes come in bursts; look at most this often
local HELLO_INTERVAL = 10 * 60 -- per game account
local HELLO_MIN_SECONDS = 60 -- a bridge that comes and goes is greeted at most this often
local SEND_SPACING = 1 -- seconds between messages, well inside the game's limits
local NOTICES_PER_MESSAGE = 10 -- to a bridge that doesn't read parts: always fits one piece of game data
local NOTICES_PER_PARTED_MESSAGE = 50 -- to one that does (the whole backlog at once)
-- One piece of game data holds about 4 KB (to be confirmed in game); parts stay well inside that
local MAX_GAME_DATA_LEN = 3800
local PART_HEADER_LEN = 16 -- "zzzz:8/8:" and room to spare
local MAX_PARTS = 8
local PART_TIMEOUT = 30 -- a message whose parts haven't all come by then is dropped
local MAX_PARTIALS_PER_SENDER = 2
local MAX_INBOUND_PER_MINUTE = 30 -- game data messages (whole or part) taken from one sender a minute
local MAX_TARGETS = 20
local PUSH_SECONDS = 10 * 60 -- a bridge that comes back is sent the current notices at most this often
-- The Wanted Battle.net community ("Wanted: Dead or... Dead"): its online members on the other faction are bridges
-- too, as friends are. 0 turns it off. /wanted community lists the communities you're in, with their ids.
local WANTED_CLUB_ID = 23053871
-- Enum.ClubMemberPresence: in the game (Online, Away, Busy), not OnlineMobile (the phone app)
local PRESENCE_IN_GAME = { [1] = true, [4] = true, [5] = true }
-- Enum.PvPFaction
local PVP_FACTION = { Horde = 0, Alliance = 1 }
local BACKLOG_SECONDS = 30 * 24 * 60 * 60
local MAX_BACKLOG = 50
-- New notices taken from one bridge, and about one player, an hour: a bridge's whole backlog fits (MAX_BACKLOG)
local MAX_NOTICES_PER_SENDER_HOUR = 100
local MAX_NOTICES_PER_TARGET_HOUR = 10
local ALERT_GATHER_SECONDS = 2 -- notices arriving together (a login's catch-up) make one alert
-- The community in use (a field so the tests can set one)
Bridge.clubId = WANTED_CLUB_ID
-- Its invite link (never expires): shown in Settings and by /wanted community
Bridge.INVITE_URL = "https://blizzard.com/invite/7mmzbzC47G"

---Values the game hides from addons for now (in a chat lockdown) can't be read or compared.
local function IsSecret(value)
	return issecretvalue and issecretvalue(value) or false
end



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Bridge:OnEnable()
	if not C_BattleNet or not C_BattleNet.SendGameData or not C_BattleNet.GetFriendAccountInfo or not BNGetNumFriends then
		Wanted:Log("Bridge: no Battle.net game data on this client")
		return
	end
	C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
	C_ChatInfo.RegisterAddonMessagePrefix(PART_PREFIX)
	for _, event in ipairs({ "BN_CHAT_MSG_ADDON", "BN_FRIEND_ACCOUNT_ONLINE", "BN_FRIEND_ACCOUNT_OFFLINE", "BN_FRIEND_INFO_CHANGED",
		"INITIAL_CLUBS_LOADED", "CLUB_MEMBER_PRESENCE_UPDATED", "CLUB_MEMBER_ADDED", "CLUB_MEMBER_REMOVED" }) do
		private.frame:RegisterEvent(event)
	end
	private.frame:SetScript("OnEvent", Wanted:Timed("Bridge events", private.OnEvent))
	Store:OnRecord("bounty", private.OnBounty)
	Store:OnRecord("raise", private.OnRaise)
	Store:OnRecord("notice", private.OnNotice)
	C_Timer.After(10, private.Scan)
end

function private.OnEvent(_, event, ...)
	if event == "BN_CHAT_MSG_ADDON" then
		local prefix, text, _, senderID = ...
		if IsSecret(prefix) or IsSecret(text) or IsSecret(senderID) then
			return
		end
		if (prefix == PREFIX or prefix == PART_PREFIX) and private.TakeInbound(senderID) then
			if prefix == PREFIX then
				private.OnMessage(text, senderID)
			else
				private.OnPart(text, senderID)
			end
		end
	elseif strmatch(event, "^CLUB_MEMBER_") then
		local clubId = ...
		if not IsSecret(clubId) and tostring(clubId) == tostring(Bridge.clubId) then
			private.Scan()
		end
	else
		private.Scan()
	end
end

function private.Enabled()
	return Wanted.db and Wanted.db.settings.bridge
end



-- ============================================================================
-- Finding bridges
-- ============================================================================

---Whether a faction name (English or localised, as the Battle.net info gives it) is the player's own.
function private.IsOwnFaction(name)
	local english, localized = UnitFactionGroup("player")
	return name == english or name == localized
end

---Realm names compared without spaces, dashes, apostrophes or case (the ruleset on Forever).
local function NormalizeRealm(name)
	return type(name) == "string" and strlower((gsub(name, "[%s%-']", ""))) or nil
end

function private.IsOwnRealm(name)
	local mine = NormalizeRealm(GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName())
	return mine ~= nil and NormalizeRealm(name) == mine
end

---Whether a game account is in WoW on this client's game version, as Blizzard's friends list tells (wowProjectID).
---Retail may share the number, so the realm checks below still decide which world it is; when the info leaves it
---out, the realm alone decides.
---@param game table BNetGameAccountInfo
---@return boolean
function private.InForever(game)
	if game.clientProgram ~= (BNET_CLIENT_WOW or "WoW") then
		return false
	end
	return type(game.wowProjectID) ~= "number" or type(WOW_PROJECT_ID) ~= "number" or game.wowProjectID == WOW_PROJECT_ID
end

---A game account that could be a bridge: in WoW Forever now, on this ruleset, on the other faction.
---@param game table? BNetGameAccountInfo
---@return boolean
function private.IsCandidate(game)
	if not game or not game.isOnline or game.isAppearOffline or not game.gameAccountID then
		return false
	end
	if not private.InForever(game) or not game.factionName or private.IsOwnFaction(game.factionName) then
		return false
	end
	return private.IsOwnRealm(game.realmName)
end

---A friend's game account on our faction but another realm name: a realm link for the sync (Sync:Greet).
---@param game table? BNetGameAccountInfo
---@return boolean
function private.IsRealmLinkCandidate(game)
	if not game or not game.isOnline or game.isAppearOffline or type(game.characterName) ~= "string" then
		return false
	end
	if not private.InForever(game) or not game.factionName or not private.IsOwnFaction(game.factionName) then
		return false
	end
	return type(game.realmName) == "string" and not private.IsOwnRealm(game.realmName)
end

---The Wanted community's club id, if it is set and this player is in it.
---@return any? clubId
function private.CommunityClub()
	local wanted = Bridge.clubId
	if not wanted or wanted == 0 or not C_Club or not C_Club.GetSubscribedClubs or not C_Club.GetClubMembers then
		return nil
	end
	for _, club in ipairs(C_Club.GetSubscribedClubs() or {}) do
		if not IsSecret(club.clubId) and tostring(club.clubId) == tostring(wanted) then
			return club.clubId
		end
	end
	return nil
end

---Adds the Wanted community's members who could be bridges to found, up to room more. A member's game is only
---known through C_BattleNet.GetAccountInfoByID; Blizzard's own interface only asks that of friends, so whether
---it answers for anyone else must be seen in game (/wanted community counts the ones it didn't).
---@param found table gameAccountID -> target
---@param room number
function private.AddCommunityTargets(found, room)
	local seen = { members = 0, inGame = 0, otherFaction = 0, added = 0, hidden = 0, elsewhere = 0 }
	private.community = seen
	local clubId = private.CommunityClub()
	if not clubId then
		return
	end
	seen.clubId = clubId
	-- Asks the game to keep the members' presence up to date, as the community window does when it shows them
	if C_Club.FocusMembers then
		C_Club.FocusMembers(clubId)
	end
	local ownFaction = PVP_FACTION[UnitFactionGroup("player") or ""]
	for _, memberId in ipairs(C_Club.GetClubMembers(clubId) or {}) do
		local info = C_Club.GetMemberInfo(clubId, memberId)
		seen.members = seen.members + 1
		if info and not info.isSelf and not IsSecret(info.presence) and PRESENCE_IN_GAME[info.presence]
			and type(info.bnetAccountId) == "number" and not IsSecret(info.bnetAccountId) then
			seen.inGame = seen.inGame + 1
			-- The community may say the faction (character communities); a Battle.net one leaves it to the game info
			if info.faction == nil or info.faction ~= ownFaction then
				seen.otherFaction = seen.otherFaction + 1
				local account = C_BattleNet.GetAccountInfoByID and C_BattleNet.GetAccountInfoByID(info.bnetAccountId)
				local game = account and account.gameAccountInfo
				if not game or not game.gameAccountID then
					seen.hidden = seen.hidden + 1
				elseif not private.IsCandidate(game) then
					seen.elsewhere = seen.elsewhere + 1
				elseif not found[game.gameAccountID] and room > 0 then
					found[game.gameAccountID] = { game = game, account = info.bnetAccountId, source = "community" }
					seen.added = seen.added + 1
					room = room - 1
				end
			end
		end
	end
	Wanted:Log("Bridge: community %s: %d members, %d in game, %d maybe on the other faction, %d added, %d not visible, %d elsewhere",
		tostring(clubId), seen.members, seen.inGame, seen.otherFaction, seen.added, seen.hidden, seen.elsewhere)
end

---Adds a friend's game accounts that could be bridges to found (every one they're logged into), up to room more.
---@return number room left
function private.AddFriendTargets(i, account, found, room)
	local numGames = C_BattleNet.GetFriendNumGameAccounts and C_BattleNet.GetFriendGameAccountInfo and C_BattleNet.GetFriendNumGameAccounts(i) or 0
	local games = {}
	for j = 1, numGames do
		games[j] = C_BattleNet.GetFriendGameAccountInfo(i, j)
	end
	if numGames == 0 then
		games[1] = account.gameAccountInfo
	end
	for _, game in pairs(games) do
		if room > 0 and private.IsCandidate(game) and not found[game.gameAccountID] then
			found[game.gameAccountID] = { game = game, account = account.bnetAccountID, source = "friend" }
			room = room - 1
		end
	end
	return room
end

---Finds who could be a bridge (friends first, then the community) and says hello; the ones running Wanted answer.
function private.Scan()
	local now = GetTime()
	if private.lastScan and now - private.lastScan < SCAN_INTERVAL then
		if not private.scanScheduled then
			private.scanScheduled = true
			C_Timer.After(SCAN_INTERVAL - (now - private.lastScan), function()
				private.scanScheduled = false
				private.Scan()
			end)
		end
		return
	end
	private.lastScan = now
	local found, room = {}, MAX_TARGETS
	for i = 1, BNGetNumFriends() do
		local account = C_BattleNet.GetFriendAccountInfo(i)
		local game = account and account.gameAccountInfo
		if private.IsRealmLinkCandidate(game) then
			-- Our faction on another realm name: can't hear our channel, but a hidden whisper reaches them (Sync)
			Wanted.Sync:Greet(game.characterName, game.realmName)
		elseif account and private.Enabled() then
			room = private.AddFriendTargets(i, account, found, room)
		end
	end
	if private.Enabled() then
		private.AddCommunityTargets(found, room)
	end
	private.UpdateTargets(found, now)
end

---Greets the targets due a hello, pushes the current notices to bridges that came back, and forgets the ones gone.
---@param found table gameAccountID -> { game, account, source }
---@param now number
function private.UpdateTargets(found, now)
	for id, target in pairs(found) do
		local last = private.helloSent[id]
		local appeared = not private.targets[id]
		if not last or now - last >= HELLO_INTERVAL or (appeared and now - last >= HELLO_MIN_SECONDS) then
			private.helloSent[id] = now
			private.stats.hellos = private.stats.hellos + 1
			Wanted:Log("Bridge: hello to %s (%s, %s)", tostring(target.game.characterName), tostring(target.game.factionName), target.source)
			private.Queue(id, { k = TAG_HELLO, v = Wanted.VERSION, f = 1 })
		end
		if appeared then
			private.PushOnAppear(id, target, now)
		end
	end
	for id, target in pairs(private.targets) do
		if not found[id] and private.bridges[id] then
			-- Logged off or moved on: nothing more goes to them until they're back (and then they're sent what they missed)
			Wanted:Log("Bridge: %s is no longer a bridge", tostring(target.game.characterName))
			private.bridges[id] = nil
		end
	end
	private.targets = found
end

---A bridge that answered earlier this session is back: it gets the current notices at once, without waiting for
---its answer (deduped by what it was already sent, and at most every PUSH_SECONDS).
function private.PushOnAppear(id, target, now)
	local runner = target.account and private.runners[target.account]
	if not runner or (private.pushedAt[target.account] and now - private.pushedAt[target.account] < PUSH_SECONDS) then
		return
	end
	private.pushedAt[target.account] = now
	private.bridges[id] = { faction = target.game.factionName, character = target.game.characterName, since = GetServerTime(), version = runner.version, parts = runner.parts }
	private.stats.pushes = private.stats.pushes + 1
	Wanted:Log("Bridge: %s is back; sending the current notices", tostring(target.game.characterName))
	private.SendBacklog(id)
end



-- ============================================================================
-- Messages
-- ============================================================================

---Queues a message for a game account, in parts if it's too long for one piece of game data.
function private.Queue(id, tbl)
	local text = Sync:Encode(tbl)
	if #text <= MAX_GAME_DATA_LEN then
		tinsert(private.queue, { id = id, prefix = PREFIX, text = text })
	else
		local parts = private.Split(text)
		if not parts then
			private.stats.skipped = private.stats.skipped + 1
			Wanted:Log("!! Bridge: a %d byte message is too long even in parts; not sent", #text)
			return
		end
		for _, part in ipairs(parts) do
			tinsert(private.queue, { id = id, prefix = PART_PREFIX, text = part })
		end
		private.stats.partsSent = private.stats.partsSent + #parts
	end
	if not private.sending then
		private.sending = true
		private.Pump()
	end
end

function private.Pump()
	local item = tremove(private.queue, 1)
	if not item then
		private.sending = false
		return
	end
	local result = C_BattleNet.SendGameData(item.id, item.prefix, item.text)
	if result ~= nil and result ~= 0 then
		Wanted:Log("!! Bridge: SendGameData %s, %d bytes -> %s", item.prefix, #item.text, tostring(result))
	end
	C_Timer.After(SEND_SPACING, private.Pump)
end

---Cuts a payload into parts ("msgId:part/total:chunk"), or nil if it would take more than MAX_PARTS.
---@param text string
---@return string[]?
function private.Split(text)
	local chunkLen = MAX_GAME_DATA_LEN - PART_HEADER_LEN
	local total = ceil(#text / chunkLen)
	if total > MAX_PARTS then
		return nil
	end
	private.msgCounter = (private.msgCounter % 46655) + 1
	local msgId = tostring(private.msgCounter)
	local parts = {}
	for part = 1, total do
		parts[part] = msgId..":"..part.."/"..total..":"..strsub(text, (part - 1) * chunkLen + 1, part * chunkLen)
	end
	return parts
end

---Counts a message from a sender against its allowance for the minute; false once it's used up.
function private.TakeInbound(senderID)
	local minute = floor(GetTime() / 60)
	local inbound = private.inbound[senderID]
	if not inbound or inbound.minute ~= minute then
		inbound = { count = 0, minute = minute }
		private.inbound[senderID] = inbound
	end
	inbound.count = inbound.count + 1
	if inbound.count == MAX_INBOUND_PER_MINUTE + 1 then
		Wanted:Log("!! Bridge: %s sent over %d messages this minute; ignoring the rest", tostring(senderID), MAX_INBOUND_PER_MINUTE)
	end
	return inbound.count <= MAX_INBOUND_PER_MINUTE
end

---One part of a long message: kept until the rest arrive (for PART_TIMEOUT), then handled whole.
function private.OnPart(text, senderID)
	if not private.Enabled() then
		return
	end
	local msgId, part, total, chunk = strmatch(text, "^(%w+):(%d+)/(%d+):(.+)$")
	part, total = tonumber(part or ""), tonumber(total or "")
	if not msgId or part < 1 or part > total or total > MAX_PARTS or not private.ValidSender(senderID) then
		private.stats.skipped = private.stats.skipped + 1
		Wanted:Log("!! Bridge: ignored a message part from %s", tostring(senderID))
		return
	end
	private.stats.partsReceived = private.stats.partsReceived + 1
	local now = GetTime()
	local key = senderID..":"..msgId
	local partial = private.partial[key]
	if partial and now - partial.t > PART_TIMEOUT then
		private.partial[key] = nil
		private.stats.partsExpired = private.stats.partsExpired + 1
		Wanted:Log("!! Bridge: parts of a message from %s stopped coming (%d of %d)", tostring(senderID), partial.count, partial.total)
		partial = nil
	end
	if not partial then
		if private.OpenPartials(senderID, now) >= MAX_PARTIALS_PER_SENDER then
			private.stats.skipped = private.stats.skipped + 1
			return
		end
		partial = { sender = senderID, parts = {}, total = total, count = 0, t = now }
		private.partial[key] = partial
	elseif partial.total ~= total then
		-- Every part of a message carries its total: a mismatch is a garbled or crafted message
		private.partial[key] = nil
		private.stats.skipped = private.stats.skipped + 1
		return
	end
	if not partial.parts[part] then
		partial.parts[part] = chunk
		partial.count = partial.count + 1
	end
	if partial.count == total then
		private.partial[key] = nil
		private.OnMessage(table.concat(partial.parts, "", 1, total), senderID)
	end
end

---How many messages a sender has part sent, dropping every message whose parts stopped coming.
function private.OpenPartials(senderID, now)
	local open = 0
	for key, partial in pairs(private.partial) do
		if now - partial.t > PART_TIMEOUT then
			private.partial[key] = nil
			private.stats.partsExpired = private.stats.partsExpired + 1
			Wanted:Log("!! Bridge: parts of a message from %s stopped coming (%d of %d)", tostring(partial.sender), partial.count, partial.total)
		elseif partial.sender == senderID then
			open = open + 1
		end
	end
	return open
end

---Who sent game data, as the game sees them (not as the message claims), if they may be a bridge: the other
---faction on this ruleset, in WoW Forever. A community member who isn't a friend is known from the last scan.
---@return table? game BNetGameAccountInfo
function private.ValidSender(senderID)
	local game = C_BattleNet.GetGameAccountInfoByID and C_BattleNet.GetGameAccountInfoByID(senderID)
	if not game and private.targets[senderID] then
		game = private.targets[senderID].game
	end
	if not game or not game.factionName or private.IsOwnFaction(game.factionName) or not private.IsOwnRealm(game.realmName)
		or (game.clientProgram and not private.InForever(game)) then
		private.stats.skipped = private.stats.skipped + 1
		Wanted:Log("!! Bridge: ignored a message from %s (%s, %s): not the other faction on this ruleset",
			tostring(game and game.characterName), tostring(game and game.factionName), tostring(game and game.realmName))
		return nil
	end
	return game
end

function private.OnMessage(text, senderID)
	if not private.Enabled() then
		return
	end
	local tbl = Sync:Decode(text)
	if type(tbl) ~= "table" then
		return
	end
	local game = private.ValidSender(senderID)
	if not game then
		return
	end
	if tbl.k == TAG_HELLO or tbl.k == TAG_ANSWER then
		local isNew = not private.bridges[senderID]
		-- f: reads messages in parts
		local parts = tbl.f == 1
		private.bridges[senderID] = { faction = game.factionName, character = game.characterName, since = GetServerTime(), version = tostring(tbl.v), parts = parts }
		local account = private.targets[senderID] and private.targets[senderID].account
		if account then
			private.runners[account] = { version = tostring(tbl.v), parts = parts }
		end
		if tbl.k == TAG_HELLO then
			private.Queue(senderID, { k = TAG_ANSWER, v = Wanted.VERSION, f = 1 })
		end
		if isNew then
			Wanted:Log("Bridge: %s (%s) runs Wanted %s", tostring(game.characterName), tostring(game.factionName), tostring(tbl.v))
			private.SendBacklog(senderID)
		end
	elseif tbl.k == TAG_NOTICES and type(tbl.n) == "table" then
		for _, notice in ipairs(tbl.n) do
			private.Receive(notice, senderID)
		end
	end
end



-- ============================================================================
-- Sending notices (bounties on the other faction's players, from this side's network)
-- ============================================================================

---The notice for a bounty on a player, or nil (a guild bounty, test data).
function private.MakeNotice(bounty)
	if not bounty or Store:IsTest(bounty) or type(bounty.data.target) ~= "string" then
		return nil
	end
	-- The bounty's id names its poster ("First Last:seq"), and a hash of a name can be matched against a list of names:
	-- the other side gets neither. The record's own hash stands in for the id, the same on every client of this side
	-- (it covers the previous record's hash, which the other side never sees, so it says nothing of who posted it).
	return {
		b = "w"..tostring(bounty.hash),
		g = bounty.data.target,
		n = bounty.data.targetName,
		a = Bounties:GetAmount(bounty),
		t = bounty.t,
	}
end

---Sends a bridge the notices it hasn't had at their current amounts.
---@param id number gameAccountID
---@param bounties table[]
function private.SendNotices(id, bounties)
	local sent = private.sent[id] or {}
	private.sent[id] = sent
	local perMessage = private.bridges[id] and private.bridges[id].parts and NOTICES_PER_PARTED_MESSAGE or NOTICES_PER_MESSAGE
	local batch = {}
	for _, bounty in ipairs(bounties) do
		local notice = private.MakeNotice(bounty)
		if notice and sent[notice.b] ~= notice.a then
			sent[notice.b] = notice.a
			tinsert(batch, notice)
			if #batch == perMessage then
				private.stats.noticesSent = private.stats.noticesSent + #batch
				private.Queue(id, { k = TAG_NOTICES, n = batch })
				batch = {}
			end
		end
	end
	if #batch > 0 then
		private.stats.noticesSent = private.stats.noticesSent + #batch
		private.Queue(id, { k = TAG_NOTICES, n = batch })
	end
end

---A new bridge gets the recent bounties, newest first.
function private.SendBacklog(id)
	local since = GetServerTime() - BACKLOG_SECONDS
	local recent = {}
	for bounty in Store:Iterator("bounty") do
		if bounty.t >= since and private.MakeNotice(bounty) then
			tinsert(recent, bounty)
		end
	end
	sort(recent, function(a, b) return a.t > b.t end)
	for i = MAX_BACKLOG + 1, #recent do
		recent[i] = nil
	end
	private.SendNotices(id, recent)
end

function private.Relay(bounty)
	if not private.Enabled() or not private.MakeNotice(bounty) then
		return
	end
	for id in pairs(private.bridges) do
		private.SendNotices(id, { bounty })
	end
end

function private.OnBounty(bounty)
	private.Relay(bounty)
end

function private.OnRaise(raise)
	private.Relay(Store:Get(raise.data.bounty))
end



-- ============================================================================
-- Receiving notices (bounties the other side posted on this faction's players)
-- ============================================================================

local function ValidText(value, maxLen)
	return type(value) == "string" and value ~= "" and #value <= maxLen
end

---@param notice table
---@param senderID number? the bridge that sent it; nil for the app's catch-up (the server's word)
function private.Receive(notice, senderID)
	if type(notice) ~= "table" or not ValidText(notice.b, 80) or not ValidText(notice.g, 64) or not strmatch(notice.g, "^Player%-")
		or not ValidText(notice.n, 48) or type(notice.a) ~= "number" or notice.a <= 0 or notice.a == math.huge
		or notice.a ~= notice.a or type(notice.t) ~= "number" or notice.t ~= notice.t or notice.t == math.huge or notice.t == -math.huge
		or (notice.p ~= nil and not ValidText(notice.p, 16)) then
		private.stats.skipped = private.stats.skipped + 1
		Wanted:Log("!! Bridge: rejected a malformed bounty notice")
		return
	end
	private.stats.noticesReceived = private.stats.noticesReceived + 1
	-- At most what the game's money holds (an older bridge may send more)
	local amount = min(floor(notice.a), Store.MAX_COPPER)
	-- Someone on this side may have carried it across already, at this amount or higher (an older bridge sends the
	-- bounty's own id, a newer one its hash: the same bounty is the same target and posting time either way)
	for known in Store:Iterator("notice") do
		if private.SameBounty(known.data.target, known.data.postedAt, known.data.bounty, notice.g, notice.t, notice.b)
			and (known.data.amount or 0) >= amount then
			return
		end
	end
	if senderID and not private.UnderNoticeCaps(senderID, notice.g) then
		private.stats.skipped = private.stats.skipped + 1
		Wanted:Log("!! Bridge: too many new bounty notices from %s, or on %s, this hour; left out", tostring(senderID), notice.g)
		return
	end
	private.stats.noticesStored = private.stats.noticesStored + 1
	Store:NewRecord("notice", {
		bounty = notice.b,
		target = notice.g,
		targetName = notice.n,
		amount = amount,
		poster = notice.p,
		postedAt = floor(notice.t),
	})
end

---Whether two notices are of the same bounty. Its id differs between bridges of different versions (an older one
---sends the bounty's own id, a newer one "w" and its hash), so notices with ids of different forms are the same bounty
---when they name the same target and posting time; with ids of the same form, only when the ids match (two bounties
---can be posted on one player in the same second).
function private.SameBounty(targetA, postedA, idA, targetB, postedB, idB)
	if idA == idB then
		return true
	end
	if targetA ~= targetB or type(postedA) ~= "number" or postedA ~= postedB then
		return false
	end
	return private.IsHashId(idA) ~= private.IsHashId(idB)
end

---Whether a notice's bounty id is the newer form: "w" and the bounty record's hash.
function private.IsHashId(id)
	return type(id) == "string" and strfind(id, "^w%x+$") ~= nil
end

---Whether one more new notice from a bridge, about a player, fits this hour's caps; counts it if so.
function private.UnderNoticeCaps(senderID, target)
	local now = GetTime()
	local function Recent(times)
		while times[1] and now - times[1] >= 3600 do
			tremove(times, 1)
		end
		return times
	end
	local bySender = Recent(private.noticeTimes[senderID] or {})
	local byTarget = Recent(private.targetTimes[target] or {})
	private.noticeTimes[senderID], private.targetTimes[target] = bySender, byTarget
	if #bySender >= MAX_NOTICES_PER_SENDER_HOUR or #byTarget >= MAX_NOTICES_PER_TARGET_HOUR then
		return false
	end
	tinsert(bySender, now)
	tinsert(byTarget, now)
	return true
end

---A bounty notice from elsewhere than a Battle.net friend (the desktop app's catch-up): checked and stored the
---same way.
---@param notice table { b, g, n, a, p, t }
function Bridge:ReceiveNotice(notice)
	private.Receive(notice)
end

---A notice about this player, from this client or synced: one alert for everything new arriving together.
function private.OnNotice(record)
	local data = record.data
	if Store:IsTest(record) or data.target ~= UnitGUID("player") or type(data.amount) ~= "number" then
		return
	end
	local seen = Wanted.db.seenNotices
	local before = seen[data.bounty]
	if before and before >= data.amount then
		return
	end
	seen[data.bounty] = data.amount
	local pending = private.newOnMe
	if not pending then
		pending = { count = 0, amount = 0 }
		private.newOnMe = pending
		C_Timer.After(ALERT_GATHER_SECONDS, private.AlertPriceOnMe)
	end
	pending.count = pending.count + (before and 0 or 1)
	pending.amount = pending.amount + data.amount - (before or 0)
end

function private.AlertPriceOnMe()
	local pending = private.newOnMe
	private.newOnMe = nil
	if not pending or pending.amount <= 0 then
		return
	end
	local total = Bridge:GetPriceOnMe()
	local added = Bounties:FormatMoney(pending.amount)
	local what = pending.count > 1 and format("%d new bounties on you (+%s)", pending.count, added)
		or pending.count == 1 and format("A bounty of %s is on you", added)
		or format("A bounty on you was raised by %s", added)
	local text = format("%s. Lifetime: %s. /wanted poster to see your poster.", what, Bounties:FormatMoney(total))
	Wanted:Print(text)
	if Wanted.Alerts then
		Wanted.Alerts:Warn("PRICE ON YOUR HEAD", text, Wanted.Theme.C.gold)
	end
end



-- ============================================================================
-- The price on your head
-- ============================================================================

---Every bounty ever posted on this player that reached this side, paid or not, each once at its highest
---amount.
---@return number total copper
---@return number count bounties
---@return number posters distinct players who posted them
function Bridge:GetPriceOnMe()
	local me = UnitGUID("player")
	-- Each bounty once, at its highest amount: notices of the same bounty (SameBounty) go together
	local bounties, posters = {}, {}
	for notice in Store:Iterator("notice") do
		local data = notice.data
		if data.target == me and not Store:IsTest(notice) and type(data.amount) == "number" then
			local found
			for _, bounty in ipairs(bounties) do
				if private.SameBounty(bounty.target, bounty.postedAt, bounty.id, data.target, data.postedAt, data.bounty) then
					found = bounty
					break
				end
			end
			if found then
				found.amount = max(found.amount, data.amount)
			else
				tinsert(bounties, { target = data.target, postedAt = data.postedAt, id = data.bounty, amount = data.amount })
			end
			if data.poster then
				posters[data.poster] = true
			end
		end
	end
	local total, count, numPosters = 0, 0, 0
	for _, bounty in ipairs(bounties) do
		total, count = total + bounty.amount, count + 1
	end
	for _ in pairs(posters) do
		numPosters = numPosters + 1
	end
	return total, count, numPosters
end

function Bridge:Status()
	local numBridges = 0
	for _ in pairs(private.bridges) do
		numBridges = numBridges + 1
	end
	local numTargets = 0
	for _ in pairs(private.targets) do
		numTargets = numTargets + 1
	end
	local s = private.stats
	return format("Bridge: %d players on the other faction run Wanted (of %d friends and community members online there); %d hellos, %d notices sent (%d pushed on return), %d received (%d new); parts %d sent, %d received, %d expired.",
		numBridges, numTargets, s.hellos, s.noticesSent, s.pushes, s.noticesReceived, s.noticesStored, s.partsSent, s.partsReceived, s.partsExpired)
end

---What /wanted community says: the communities this player is in, with their ids, and what the last scan saw in
---the Wanted one.
---@return string[]
function Bridge:CommunityReport()
	local lines = {}
	if not C_Club or not C_Club.GetSubscribedClubs then
		return { "Communities aren't available on this client." }
	end
	for _, club in ipairs(C_Club.GetSubscribedClubs() or {}) do
		if not IsSecret(club.clubId) and not IsSecret(club.name) then
			local kind = club.clubType == 0 and "Battle.net" or club.clubType == 1 and "character" or club.clubType == 2 and "guild" or "other"
			tinsert(lines, format("  %s: id %s, %s community, %s members%s", tostring(club.name), tostring(club.clubId), kind,
				tostring(club.memberCount or "?"), tostring(club.clubId) == tostring(Bridge.clubId) and " (Wanted's)" or ""))
		end
	end
	if #lines == 0 then
		tinsert(lines, "  none (or hidden for now)")
	end
	tinsert(lines, 1, "Your communities:")
	local seen = private.community
	if not private.Enabled() then
		tinsert(lines, "Bounty notices across factions are off (Settings > Sharing).")
	elseif not Bridge.clubId or Bridge.clubId == 0 then
		tinsert(lines, "The Wanted community isn't set up in this version.")
	elseif not seen or not seen.clubId then
		tinsert(lines, format("You're not in the Wanted community (id %s), or it hasn't loaded yet. Join it to link your addon to the other faction (members can see each other's BattleTag): %s",
			tostring(Bridge.clubId), Bridge.INVITE_URL))
	else
		tinsert(lines, format("Wanted community, last look: %d members, %d in game, %d maybe on the other faction: %d bridges, %d whose game Battle.net doesn't show, %d elsewhere (own faction, another game or ruleset).",
			seen.members, seen.inGame, seen.otherFaction, seen.added, seen.hidden, seen.elsewhere))
	end
	tinsert(lines, format("This client's game version (WOW_PROJECT_ID): %s", tostring(WOW_PROJECT_ID)))
	return lines
end

Wanted:RegisterCommand("bridge", "Battle.net friends on the other faction who carry bounty notices across: /wanted bridge", function()
	if not private.Enabled() then
		Wanted:Print("Bounty notices across factions are off (Settings > Sharing).")
		return
	end
	Wanted:Print(Bridge:Status())
	for id, info in pairs(private.bridges) do
		local target = private.targets[id]
		Wanted:Print("  %s (%s), Wanted %s%s%s", tostring(info.character), tostring(info.faction), info.version,
			target and (", "..target.source) or "", target and (", game version "..tostring(target.game.wowProjectID)) or "")
	end
	local total, count, posters = Bridge:GetPriceOnMe()
	Wanted:Print("Price on your head: %s from %d bounties by %d players.", Bounties:FormatMoney(total), count, posters)
	local now = GetTime()
	for name, link in pairs(Wanted.Sync:GetLinks()) do
		Wanted:Print("  Realm link: %s on %s, heard %ds ago, %d sent, %d received", name, tostring(link.realm), floor(now - (link.heard or now)), link.sent, link.received)
	end
	local directory = Wanted.Sync:GetDirectory()
	Wanted:Print("Realm-link names from the app: %d, on %d other realm names, %d of them linked now.", directory.names, directory.realms, directory.linked)
end)

Wanted:RegisterCommand("community", "Your Battle.net communities with their ids, and the Wanted community's members on the other faction: /wanted community", function()
	private.lastScan = nil
	private.Scan()
	for _, line in ipairs(Bridge:CommunityReport()) do
		Wanted:Print("%s", line)
	end
end)
