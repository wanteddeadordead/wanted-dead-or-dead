-- Wanted: bounty notices across the factions. Each faction runs its own network (a custom channel is per
-- faction), so a player never hears of the bounties the other side posts on them. A Battle.net friend on the
-- other faction who also runs Wanted can carry them across as hidden game data (C_BattleNet.SendGameData),
-- never chat. Only bounty facts cross: the target, the amount, when it was posted, and a hash standing in
-- for the poster so posters can be counted without being named. The friend's client stores each as a
-- "notice" record of its own and ordinary sync spreads it on that side, so the target learns of the price on
-- their head and it adds to their lifetime total (the wanted poster).

local _, Wanted = ...
local Bridge = Wanted:NewModule("Bridge")
local Store = Wanted.Store
local Bounties = Wanted.Bounties
local Sync = Wanted.Sync
local private = {
	frame = CreateFrame("Frame"),
	bridges = {}, -- gameAccountID -> { faction, character, since, version }
	helloSent = {}, -- gameAccountID -> time of our last hello
	sent = {}, -- gameAccountID -> { [bountyId] = amount } notices already sent this session
	queue = {}, -- { id, tbl } waiting to go out, one every SEND_SPACING seconds
	sending = false,
	lastScan = nil,
	scanScheduled = false,
	newOnMe = nil, -- { count, amount } gathered for one "price on your head" alert
	stats = { hellos = 0, noticesSent = 0, noticesReceived = 0, noticesStored = 0, skipped = 0 },
}
local PREFIX = "WNTDB"
local TAG_HELLO, TAG_ANSWER, TAG_NOTICES = "H", "A", "N"
local SCAN_INTERVAL = 30 -- friend list changes come in bursts; look at most this often
local HELLO_INTERVAL = 10 * 60 -- per friend
local SEND_SPACING = 1 -- seconds between messages, well inside the game's limits
local NOTICES_PER_MESSAGE = 10
local BACKLOG_SECONDS = 30 * 24 * 60 * 60
local MAX_BACKLOG = 50
local MAX_AMOUNT = 1e10 -- a million gold in copper; anything above is not a real bounty
local ALERT_GATHER_SECONDS = 2 -- notices arriving together (a login's catch-up) make one alert



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Bridge:OnEnable()
	if not C_BattleNet or not C_BattleNet.SendGameData or not C_BattleNet.GetFriendAccountInfo or not BNGetNumFriends then
		Wanted:Log("Bridge: no Battle.net game data on this client")
		return
	end
	C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
	for _, event in ipairs({ "BN_CHAT_MSG_ADDON", "BN_FRIEND_ACCOUNT_ONLINE", "BN_FRIEND_INFO_CHANGED" }) do
		private.frame:RegisterEvent(event)
	end
	private.frame:SetScript("OnEvent", private.OnEvent)
	Store:OnRecord("bounty", private.OnBounty)
	Store:OnRecord("raise", private.OnRaise)
	Store:OnRecord("notice", private.OnNotice)
	C_Timer.After(10, private.Scan)
end

function private.OnEvent(_, event, ...)
	if event == "BN_CHAT_MSG_ADDON" then
		local prefix, text, _, senderID = ...
		if prefix == PREFIX then
			private.OnMessage(text, senderID)
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

---A friend's game account that could be a bridge: in WoW now, on this ruleset, on the other faction.
---@param game table? BNetGameAccountInfo
---@return boolean
function private.IsCandidate(game)
	if not game or not game.isOnline or game.isAppearOffline or not game.gameAccountID then
		return false
	end
	if game.clientProgram ~= (BNET_CLIENT_WOW or "WoW") or not game.factionName or private.IsOwnFaction(game.factionName) then
		return false
	end
	return private.IsOwnRealm(game.realmName)
end

---Says hello to every friend who could be a bridge; the ones running Wanted answer.
function private.Scan()
	if not private.Enabled() then
		return
	end
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
	for i = 1, BNGetNumFriends() do
		local account = C_BattleNet.GetFriendAccountInfo(i)
		local game = account and account.gameAccountInfo
		if private.IsCandidate(game) then
			local id = game.gameAccountID
			if not private.helloSent[id] or now - private.helloSent[id] >= HELLO_INTERVAL then
				private.helloSent[id] = now
				private.stats.hellos = private.stats.hellos + 1
				Wanted:Log("Bridge: hello to %s (%s)", tostring(game.characterName), tostring(game.factionName))
				private.Queue(id, { k = TAG_HELLO, v = Wanted.VERSION })
			end
		end
	end
end



-- ============================================================================
-- Messages
-- ============================================================================

function private.Queue(id, tbl)
	tinsert(private.queue, { id = id, tbl = tbl })
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
	C_BattleNet.SendGameData(item.id, PREFIX, Sync:Encode(item.tbl))
	C_Timer.After(SEND_SPACING, private.Pump)
end

function private.OnMessage(text, senderID)
	if not private.Enabled() then
		return
	end
	local tbl = Sync:Decode(text)
	if type(tbl) ~= "table" then
		return
	end
	-- Who sent it as the game sees them, not as the message claims
	local game = C_BattleNet.GetGameAccountInfoByID and C_BattleNet.GetGameAccountInfoByID(senderID)
	if not game or not game.factionName or private.IsOwnFaction(game.factionName) or not private.IsOwnRealm(game.realmName) then
		private.stats.skipped = private.stats.skipped + 1
		Wanted:Log("!! Bridge: ignored a message from %s (%s, %s): not the other faction on this ruleset",
			tostring(game and game.characterName), tostring(game and game.factionName), tostring(game and game.realmName))
		return
	end
	if tbl.k == TAG_HELLO or tbl.k == TAG_ANSWER then
		local isNew = not private.bridges[senderID]
		private.bridges[senderID] = { faction = game.factionName, character = game.characterName, since = GetServerTime(), version = tostring(tbl.v) }
		if tbl.k == TAG_HELLO then
			private.Queue(senderID, { k = TAG_ANSWER, v = Wanted.VERSION })
		end
		if isNew then
			Wanted:Log("Bridge: %s (%s) runs Wanted %s", tostring(game.characterName), tostring(game.factionName), tostring(tbl.v))
			private.SendBacklog(senderID)
		end
	elseif tbl.k == TAG_NOTICES and type(tbl.n) == "table" then
		for _, notice in ipairs(tbl.n) do
			private.Receive(notice)
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
	return {
		b = bounty.id,
		g = bounty.data.target,
		n = bounty.data.targetName,
		a = Bounties:GetAmount(bounty),
		p = Store:Hash(bounty.origin),
		t = bounty.t,
	}
end

---Sends a bridge the notices it hasn't had at their current amounts.
---@param id number gameAccountID
---@param bounties table[]
function private.SendNotices(id, bounties)
	local sent = private.sent[id] or {}
	private.sent[id] = sent
	local batch = {}
	for _, bounty in ipairs(bounties) do
		local notice = private.MakeNotice(bounty)
		if notice and sent[notice.b] ~= notice.a then
			sent[notice.b] = notice.a
			tinsert(batch, notice)
			if #batch == NOTICES_PER_MESSAGE then
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

function private.Receive(notice)
	if type(notice) ~= "table" or not ValidText(notice.b, 80) or not ValidText(notice.g, 64) or not strmatch(notice.g, "^Player%-")
		or not ValidText(notice.n, 48) or type(notice.a) ~= "number" or notice.a <= 0 or notice.a > MAX_AMOUNT
		or type(notice.t) ~= "number" or (notice.p ~= nil and not ValidText(notice.p, 16)) then
		private.stats.skipped = private.stats.skipped + 1
		Wanted:Log("!! Bridge: rejected a malformed bounty notice")
		return
	end
	private.stats.noticesReceived = private.stats.noticesReceived + 1
	local amount = floor(notice.a)
	-- Someone on this side may have carried it across already, at this amount or higher
	for known in Store:Iterator("notice") do
		if known.data.bounty == notice.b and (known.data.amount or 0) >= amount then
			return
		end
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
	local byBounty, posters = {}, {}
	for notice in Store:Iterator("notice") do
		local data = notice.data
		if data.target == me and not Store:IsTest(notice) and type(data.amount) == "number" then
			byBounty[data.bounty] = max(byBounty[data.bounty] or 0, data.amount)
			if data.poster then
				posters[data.poster] = true
			end
		end
	end
	local total, count, numPosters = 0, 0, 0
	for _, amount in pairs(byBounty) do
		total, count = total + amount, count + 1
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
	local s = private.stats
	return format("Bridge: %d Battle.net friends on the other faction run Wanted; %d hellos, %d notices sent, %d received (%d new).",
		numBridges, s.hellos, s.noticesSent, s.noticesReceived, s.noticesStored)
end

Wanted:RegisterCommand("bridge", "Battle.net friends on the other faction who carry bounty notices across: /wanted bridge", function()
	if not private.Enabled() then
		Wanted:Print("Bounty notices across factions are off (Settings > Sharing).")
		return
	end
	Wanted:Print(Bridge:Status())
	for _, info in pairs(private.bridges) do
		Wanted:Print("  %s (%s), Wanted %s", tostring(info.character), tostring(info.faction), info.version)
	end
	local total, count, posters = Bridge:GetPriceOnMe()
	Wanted:Print("Price on your head: %s from %d bounties by %d players.", Bounties:FormatMoney(total), count, posters)
end)
