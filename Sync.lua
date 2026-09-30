-- Wanted: peer to peer sync over a hidden custom chat channel. Every client holds the full store and
-- broadcasts its own new records once; a client that logs in says what it holds, peers answer with what
-- they hold, and gaps are filled by whoever answers first. No relay of live traffic, no server, no owner.
-- Everything sent is addon messages (data only, invisible to normal chat), through C_ChatInfo.
--
-- Realm links: WoW Forever's one shared world has several realm names, and a custom channel belongs to one,
-- so players on another realm name can't hear this channel. They're reached by hidden addon whispers
-- instead, which do cross: the same messages, sent to one player. A link catches both sides up, then
-- forwards every new record both ways, and records that arrive over a link are shared once on this realm's
-- channel. Links are found through Battle.net friends (Bridge), anyone who greets us from another realm,
-- and the ones remembered from before.

local _, Wanted = ...
local Sync = Wanted:NewModule("Sync")
local Store = Wanted.Store
local LibSerialize = LibStub("LibSerialize")
local LibDeflate = LibStub("LibDeflate")
local private = {
	frame = CreateFrame("Frame"),
	liveQueue = {},
	liveFlushPending = false,
	channelName = nil,
	channelId = nil,
	joinAttempts = 0,
	msgCounter = 0,
	partial = {}, -- sender..msgId -> { parts = {}, total, t }
	outbox = {}, -- channel messages waiting to go: { tag, parts, next, priority, queued, refusals }
	outboxParts = 0, -- parts still to send in outbox
	tokens = 0, -- channel parts we may send now (refilled with time; starts full, below)
	tokensAt = 0,
	drainScheduled = false,
	inbound = {}, -- sender -> { count, minute }
	ceilingHitMinute = nil,
	pausedUntil = 0,
	peers = {}, -- sender -> last message time
	ownMessages = {}, -- tag:msgId -> time sent, to recognise our own echoes
	pendingNeedAnswers = {}, -- origin -> { from, t } scheduled answers
	recentFills = {}, -- origin -> highest seq seen filled by anyone recently
	stats = { sent = 0, received = 0, echoed = 0, dropped = 0, merged = 0, invalid = 0, throttled = 0, skipped = 0 },
	sightingTimes = {}, -- outbound sighting message times in the last minute (their own budget)
	sightingQueue = {}, -- guid -> { data, urgent, t } waiting for the next batch
	flushDue = nil,
	flushGen = 0,
	recentSightings = {}, -- guid -> when anyone (us included) last shared them
	retryQueue = {}, -- { tag, tbl, attempt, target } throttled by the game, sent again shortly
	retryScheduled = false,
	testStartedAt = nil,
	links = {}, -- name -> { realm, heard, since, sent, received } realm links (players on another realm name)
	linkTimes = {}, -- outbound link message times in the last minute (their own budget)
	greeted = {}, -- name -> when we last greeted them over a whisper
	greetedRealm = {}, -- name -> the realm they were greeted on
	endedLinks = {}, -- name -> when their link ended because they went offline (their message stays hidden)
	forwardQueue = {}, -- name -> records to forward to that link
	reshareQueue = {}, -- records from a link to share on this realm's channel
	forwardDue = false,
	currentSource = nil, -- the link whose records are being merged (not sent back to it)
	lockedOut = nil, -- why this client can't get into the channel (banned, wrong password, no answer), or nil
	rejoinFailing = false, -- the game asked for the password: its own rejoin without one is about to fail
	lastChannelSend = -math.huge, -- GetTime() of our last addon message on the channel
	moderated = false, -- moderation is on in the channel: only its moderators can send, so we don't
	membersRetrying = false, -- a member request is waiting for the game's channel list; others don't start one
	members = nil, -- how many are in the channel, as the game's channel list last said
	lockoutTicker = nil, -- tries the channel again while locked out
}
local PREFIX = "WNTD"
local CHANNEL_BASE = "WantedNet"
-- The password only keeps stray chat out of the channel; the addon is public, so it is not a secret
local CHANNEL_PASSWORD = "wnt1"
-- Moving channels. A move is followed when this client saw the takeover itself (in the last few minutes), when
-- MOVE_QUORUM different players it knows sent the same move, or when the Wanted app passed it on from the server.
local MOVE_TRUST_SECONDS = 10 * 60
local MOVE_QUORUM = 2
local MOVE_ASK_PEERS = 5 -- players asked for the current channel at login
local MOVE_REPLY_SECONDS = 60 -- one answer per player a minute
local CHANNEL_NAME_MAX = 31
-- Message = tag ":" msgId ":" part "/" total ":" chunk; the header is at most 12 characters
local MAX_MESSAGE_LEN = 255
local CHUNK_LEN = 240
local PARTIAL_TIMEOUT = 30
-- Tags
local TAG_HELLO, TAG_HAVE, TAG_NEED, TAG_LIVE, TAG_FILL = "H", "V", "N", "R", "F"
-- Enemy sightings are passing news, not records: never stored in a chain, never re-sent. They go out in
-- batches ("S"); single sightings ("E") are what the first version sent, still understood when received.
local TAG_ENEMY, TAG_SIGHTINGS = "E", "S"
-- Sent privately (addon whisper) to a player on an older version: update
local TAG_UPDATE = "U"
-- Sent privately to a posse's caller: I'm joining (Posse)
local TAG_POSSE_JOIN = "J"
-- A move to a new sync channel after the old one was taken over, or (q) a player asking for the current one:
-- { e = epoch, n = name, p = password, q = 1 when asking }. Whispers only, never on a channel.
local TAG_MOVE = "M"
local TELL_OUTDATED_SECONDS = 10 * 60 -- at most one update notice per player this often
-- The game's own limit on channel addon messages, measured on WoW Forever (2026-09-26 dev log, 740 parts): about
-- 10 parts at once, then one more every 2 seconds; past that it refuses them (ChannelThrottle). Channel parts
-- wait in a queue and go out a little under that pace, so the game never has to refuse them.
local CHANNEL_BURST = 8
local CHANNEL_PART_SECONDS = 2.5
private.tokens = CHANNEL_BURST
-- The queue holds about two minutes of sending. Gap fills only take what room is left below their share: the
-- next resync asks for anything they leave out. A sighting still waiting after 15 seconds is old news.
local MAX_QUEUED_PARTS = 48
local MAX_QUEUED_FILL_PARTS = 16
local SIGHTING_QUEUE_SECONDS = 15
-- Messages received in a fight wait, unopened, until it's over; past this many the rest are left to the resync
local MAX_DEFERRED_MESSAGES = 300
-- Which messages go first: our new records, then sightings, then the sync conversation, then gap fills
local SEND_PRIORITY = { R = 1, S = 2, F = 4 }
local DEFAULT_SEND_PRIORITY = 3
-- A cap on what any one sender may push at us, and a pause when our own queue overflows two minutes running
-- Sightings have their own budget and never trigger the pause, so a big fight can't hold up bounties, kills and
-- claims (10 parts a minute: a raid on Undercity hit 6 over and over while the game still had room). A new enemy waits up to 8s to share a message with others seen around the same time;
-- Kill on Sight, bounty and stealthed enemies go within 2s. An enemy someone shared in the last minute isn't
-- sent again: everyone nearby sees the same raid, and one report of it is enough.
local MAX_SIGHTING_MESSAGES_PER_MINUTE = 10
local SIGHTING_BATCH_SECONDS = 8
local SIGHTING_URGENT_SECONDS = 2
local MAX_SIGHTINGS_PER_BATCH = 15
local SIGHTING_FRESH_SECONDS = 60
-- The game's own addon message limits (SendAddonMessage results AddonMessageThrottle and ChannelThrottle).
-- A refused channel part waits and is sent again by itself; a refused whisper is sent again whole.
local RESULT_THROTTLED = { [3] = true, [8] = true }
local RETRY_SECONDS = 5
-- The game answers a refused channel send with a chat notice, shown in a public channel's name (Chris's client,
-- 2026-09-28: "[1. General] The number of messages that can be sent to this channel is limited" and "That
-- operation is not permitted in this channel"). Notices this soon after our own send are ours and hidden; joins,
-- leaves and zone changes never are.
local OWN_NOTICE_SECONDS = 2
local NEVER_HIDDEN_NOTICES = { YOU_JOINED = true, YOU_LEFT = true, YOU_CHANGED = true, SUSPENDED = true }
local MAX_RETRIES = 3
local MAX_RETRY_QUEUE = 30
local MAX_INBOUND_PER_SENDER_PER_MINUTE = 60
local PAUSE_SECONDS = 10 * 60
local JOIN_RETRY_SECONDS = 10
local JOIN_SETTLE_SECONDS = 5
local RESULT_INVALID_CHANNEL = 7
local MAX_JOIN_ATTEMPTS = 12
local PEER_TIMEOUT = 10 * 60
-- How many records a fill answer sends per message batch and per request
local FILL_BATCH = 8
local MAX_FILL_PER_REQUEST = 200
-- Realm links (whispers to players on another realm name): their own budget, a resync every minute so a
-- catch-up cut short by the budget carries on, forwarding in small batches, a remembered list
local MAX_LINK_PARTS_PER_MINUTE = 40
local LINK_HAVE_SECONDS = 60
local LINK_TIMEOUT = 3 * 60 -- a link that misses a few resyncs is dropped (and greeted again later)
local LINK_FORWARD_SECONDS = 2
local MAX_FORWARD_QUEUE = 200
local MAX_NEED_ORIGINS_LINK = 40
local GREET_SECONDS = 5 * 60 -- the same player is greeted at most this often
local MAX_REMEMBERED_LINKS = 20
local REMEMBER_LINK_SECONDS = 7 * 24 * 60 * 60
local NOT_FOUND_SECONDS = 10 -- the game's "no player named ..." for someone just greeted is hidden this long
-- Locked out of the channel (an owner banned us or changed its password): sync goes on by whisper links to the
-- players last heard on it, and joining is tried again now and then (a re-passworded channel is gone once its
-- last member leaves, and the next joiner makes it afresh with the addon's password)
local MAX_RECENT_PEERS = 20
local RECENT_PEER_SECONDS = 7 * 24 * 60 * 60
local LOCKOUT_RETRY_SECONDS = 5 * 60
local MEMBERS_INTERVAL = 5 * 60 -- how often the game is asked for the channel's member count
local MEMBERS_RETRY_SECONDS, MEMBERS_ATTEMPTS = 10, 6 -- when the channel isn't in the game's list yet
local REJOIN_FAIL_SECONDS = 15 -- how long after a password request its failed rejoin is expected
-- The game's own rejoin fails once per login; this many wrong passwords this close together are ours being turned
-- down: the channel's password was changed
local WRONG_PASSWORDS_TAKEOVER = 3
local WRONG_PASSWORDS_SECONDS = 120
-- Channel notices an owner or moderator causes, and what to say: kicks and bans name the target then the actor
local HOSTILE_NOTICES = {
	PLAYER_KICKED = "%s was kicked from the sync channel by %s.",
	PLAYER_BANNED = "%s was banned from the sync channel by %s.",
	PASSWORD_CHANGED = "%s changed the sync channel's password.",
	MODERATION_ON = "%s turned moderation on in the sync channel: only its moderators can send.",
}
-- The same, when it was done to this player
local HOSTILE_NOTICES_SELF = {
	PLAYER_KICKED = "You were kicked from the sync channel by %s.",
	PLAYER_BANNED = "You were banned from the sync channel by %s.",
}
-- Moderator and owner changes aren't said, only logged: the channel passes to whoever has been in it longest, so
-- they happen all the time, and they harm nobody until someone turns moderation on (which is said)



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Sync:OnEnable()
	private.faction = UnitFactionGroup("player") or ""
	private.channelName, private.password, private.epoch = CHANNEL_BASE..private.faction, CHANNEL_PASSWORD, 0
	-- The channel everyone moved to, if the first was ever taken over
	local pointer = Wanted.db.syncChannel
	if type(pointer) == "table" and private.ValidPointer(pointer) then
		private.channelName, private.password, private.epoch = pointer.n, pointer.p, pointer.e
	end
	local result = C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
	Wanted:Log("Sync: prefix %s registered (%s), channel %s", PREFIX, tostring(result), private.channelName)
	private.frame:RegisterEvent("CHAT_MSG_ADDON")
	private.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	private.frame:RegisterEvent("CHANNEL_PASSWORD_REQUEST")
	private.frame:RegisterEvent("CHAT_MSG_SYSTEM")
	private.frame:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
	private.frame:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE_USER")
	private.frame:RegisterEvent("CHANNEL_COUNT_UPDATE")
	private.frame:RegisterEvent("CHANNEL_UI_UPDATE")
	private.frame:RegisterEvent("CHAT_MSG_CHANNEL_LIST")
	private.frame:SetScript("OnEvent", Wanted:Timed("Sync events", private.OnEvent))
	-- Every kind of our own record is shared (a fixed list once left out links and assists)
	Store:OnRecord("*", private.OnOwnRecord)
	-- What a fight held back goes once it's over
	Wanted:OnCombatEnd(function()
		private.FlushLive()
		private.FlushForward()
		private.Drain()
	end)
	-- Channels are joined a little after login, so wait before trying
	C_Timer.After(5, private.TryJoin)
	-- Realm links
	Store:OnRecord("*", private.OnAnyRecord)
	C_Timer.NewTicker(LINK_HAVE_SECONDS, private.LinkTick)
	C_Timer.After(15, private.GreetRemembered)
	-- Did everyone move while we were away? Ask the players last heard
	C_Timer.After(25, private.AskPointer)
	local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
	if addFilter then
		addFilter("CHAT_MSG_SYSTEM", private.HideNotFound)
		-- The channel's joins, leaves and owner changes are nobody's business: it only carries addon data
		addFilter("CHAT_MSG_CHANNEL_NOTICE", private.HideChannelNotice)
		addFilter("CHAT_MSG_CHANNEL_NOTICE_USER", private.HideChannelNotice)
		-- The member list the addon asks for (RequestMembers) is for counting, not reading
		addFilter("CHAT_MSG_CHANNEL_LIST", private.HideChannelNotice)
	end
end

---Hides the game's notices about the sync channel (arg9 is the channel's base name), and the ones it gives, under
---a public channel's name, for our own sends it refused a moment ago.
function private.HideChannelNotice(_, event, kind, _, _, channelString, _, _, _, channelNumber, baseName)
	if type(baseName) == "string" and private.channelName ~= nil and strlower(baseName) == strlower(private.channelName) then
		return true
	end
	if event == "CHAT_MSG_CHANNEL_NOTICE" and type(kind) == "string" and not NEVER_HIDDEN_NOTICES[kind]
		and GetTime() - private.lastChannelSend < OWN_NOTICE_SECONDS then
		-- What the game said and where it put it: our sends go to our channel, yet it names a public one
		Wanted:Log("Sync: hid the game's notice %s, shown in %q (#%s, %s), %.1fs after our send to #%s", kind, tostring(channelString),
			tostring(channelNumber), tostring(baseName), GetTime() - private.lastChannelSend, tostring(private.channelId))
		return true
	end
	return false
end

---Takes the sync channel out of every chat window. The game lists a channel in the window it was joined from
---by hand (the /join tip), and then shows its every join, leave and owner change there; the addon's own join
---names no window. Membership is untouched: only what the windows show.
function private.HideFromChatWindows()
	for i = 1, NUM_CHAT_WINDOWS or 10 do
		local frame = _G["ChatFrame"..i]
		if frame and frame.RemoveChannel then
			frame:RemoveChannel(private.channelName)
		end
	end
end

---Connection facts for the interface.
---@return table
function Sync:GetInfo()
	local numPeers = 0
	local now = GetTime()
	for _, t in pairs(private.peers) do
		if now - t < PEER_TIMEOUT then
			numPeers = numPeers + 1
		end
	end
	-- Players on other realm names linked by whisper count too
	for _, link in pairs(private.links) do
		if now - (link.heard or 0) < PEER_TIMEOUT then
			numPeers = numPeers + 1
		end
	end
	return {
		channelName = private.channelName,
		channelId = private.channelId,
		peers = numPeers,
		members = Sync:GetMembers(),
		paused = now < private.pausedUntil,
		stats = private.stats,
	}
end

function Sync:Status()
	local numPeers = 0
	local now = GetTime()
	for _, t in pairs(private.peers) do
		if now - t < PEER_TIMEOUT then
			numPeers = numPeers + 1
		end
	end
	-- Players on other realm names linked by whisper count too
	for _, link in pairs(private.links) do
		if now - (link.heard or 0) < PEER_TIMEOUT then
			numPeers = numPeers + 1
		end
	end
	local numLinks = 0
	for _, link in pairs(private.links) do
		if now - (link.heard or 0) < LINK_TIMEOUT then
			numLinks = numLinks + 1
		end
	end
	local members = Sync:GetMembers()
	return format("Sync: channel %s (%s%s), %d peers in the last 10 min (%d on other realms by whisper); sent %d, received %d (%d own echoes), merged %d, invalid %d, dropped %d, throttled %d, repeats skipped %d%s.", private.channelName or "?", private.channelId and ("#"..private.channelId) or "not joined", members and format(", %d in it", members) or "", numPeers, numLinks, private.stats.sent, private.stats.received, private.stats.echoed, private.stats.merged, private.stats.invalid, private.stats.dropped, private.stats.throttled, private.stats.skipped, now < private.pausedUntil and " PAUSED" or "")
end

function private.OnEvent(_, event, ...)
	if event == "CHAT_MSG_ADDON" then
		private.OnAddonMessage(...)
	elseif event == "PLAYER_ENTERING_WORLD" then
		-- A zone change or reload can drop the channel id
		private.channelId = nil
		private.joinAttempts = 0
		C_Timer.After(5, private.TryJoin)
	elseif event == "CHANNEL_PASSWORD_REQUEST" then
		private.OnPasswordRequest(...)
	elseif event == "CHAT_MSG_SYSTEM" then
		private.OnSystemMessage(...)
	elseif event == "CHAT_MSG_CHANNEL_NOTICE" or event == "CHAT_MSG_CHANNEL_NOTICE_USER" then
		private.OnChannelNotice(event, ...)
	elseif event == "CHANNEL_COUNT_UPDATE" then
		private.ReadMembers(...)
	elseif event == "CHAT_MSG_CHANNEL_LIST" then
		private.OnChannelList(...)
	elseif event == "CHANNEL_UI_UPDATE" then
		-- The game (re)built its channel list: ask once it settles, if the count isn't known yet
		if private.channelId and not private.members then
			C_Timer.After(2, function() private.RequestMembers() end)
		end
	end
end

---How many are in the sync channel, as the game last answered (RequestMembers). Every one of them runs Wanted:
---nothing else joins the channel. Nil until the game has answered.
---@return number?
function Sync:GetMembers()
	return private.members
end

---The sync channel's number right now, or nil when the game has it at none. The game's answer names the channel
---too; a number whose channel isn't ours is never used.
---@return number?
function private.CurrentChannelId()
	if not private.channelName then
		return nil
	end
	local id, name = GetChannelName(private.channelName)
	if type(id) ~= "number" or id <= 0 then
		return nil
	end
	if type(name) == "string" and name ~= "" and strlower(name) ~= strlower(private.channelName) then
		return nil
	end
	return id
end

---The sync channel's index in the game's channel list, if it's there.
---@return number?
function private.DisplayIndex()
	if not private.channelName or not GetNumDisplayChannels or not GetChannelDisplayInfo then
		return nil
	end
	local mine = strlower(private.channelName)
	for i = 1, GetNumDisplayChannels() do
		local name, header = GetChannelDisplayInfo(i)
		if not header and type(name) == "string" and strlower(name) == mine then
			return i
		end
	end
	return nil
end

---Asks the game for the channel's member list (as /chatlist does). The count in the game's channel list stays
---empty until then; the answer brings CHANNEL_COUNT_UPDATE and CHAT_MSG_CHANNEL_LIST (Chris's client,
---2026-09-28: selecting the channel in the hidden channels window, SetSelectedDisplayChannel, brought nothing
---from a timer). The list's chat line is hidden. Asked after joining and every few minutes; the game's channel
---list can still be empty right after a login or reload, so a miss is tried again a few times.
---Only one chain of retries runs at a time: the join, the ticker and a rebuilt list each ask, and a chain
---already waiting covers them.
---@param attempt number? set by a retry
function private.RequestMembers(attempt)
	if not attempt and private.membersRetrying then
		return
	end
	attempt = attempt or 1
	local index = private.DisplayIndex()
	if not index then
		Wanted:Log("Sync: %s isn't in the game's channel list yet (%s channels; attempt %d)", tostring(private.channelName),
			GetNumDisplayChannels and tostring(GetNumDisplayChannels()) or "no", attempt)
		private.membersRetrying = attempt < MEMBERS_ATTEMPTS
		if private.membersRetrying then
			C_Timer.After(MEMBERS_RETRY_SECONDS, function() private.RequestMembers(attempt + 1) end)
		end
		return
	end
	private.membersRetrying = false
	if not ListChannelByName then
		Wanted:Log("!! Sync: no ListChannelByName; can't ask for the member count")
		return
	end
	Wanted:Log("Sync: asking for the member list of %s (channel list entry %d)", private.channelName, index)
	ListChannelByName(private.channelName)
end

---The game's answer to a member list request: the names, comma-separated. Counted when no count update came
---(arg9 is the channel's base name).
function private.OnChannelList(text, _, _, _, _, _, _, _, baseName)
	if type(baseName) ~= "string" or not private.channelName or strlower(baseName) ~= strlower(private.channelName) or type(text) ~= "string" then
		return
	end
	local n = 0
	for name in string.gmatch(text, "[^,]+") do
		if string.match(name, "%S") then
			n = n + 1
		end
	end
	if n > 0 and n ~= private.members then
		Wanted:Log("Sync: %d in %s (from its member list)", n, private.channelName)
		private.members = n
		Wanted.db.channel = { name = private.channelName, realm = GetRealmName(), members = n, t = GetServerTime() }
	end
end

---Reads the channel's member count from the game's channel list (or a CHANNEL_COUNT_UPDATE payload) and
---remembers it for the app, which sends it to wanteddeadordead.com with its next catch-up (the file is written
---at logout or /reload).
---@param updatedIndex number? the display index a count update names
---@param updatedCount number? the count it carries
function private.ReadMembers(updatedIndex, updatedCount)
	local index = private.DisplayIndex()
	if not index then
		return
	end
	local count = select(5, GetChannelDisplayInfo(index))
	if updatedIndex == index and type(updatedCount) == "number" then
		count = updatedCount
	end
	if type(count) == "number" and count > 0 and count ~= private.members then
		Wanted:Log("Sync: %d in %s", count, private.channelName)
		private.members = count
		Wanted.db.channel = { name = private.channelName, realm = GetRealmName(), members = count, t = GetServerTime() }
	end
end

---The game's notices about the sync channel (hidden from chat since 1.2.8, so this is where they're seen).
---Whoever has been in a custom channel longest becomes its owner when the owner leaves, and an owner can kick,
---ban, re-password or moderate it; the game names who did what, so it's said in chat and logged. A kick is
---undone by rejoining; a ban or a changed password locks this client out, and sync goes on by whisper.
function private.OnChannelNotice(event, kind, player, _, _, actor, _, _, _, baseName)
	if type(baseName) ~= "string" or not private.channelName or strlower(baseName) ~= strlower(private.channelName) then
		return
	end
	Wanted:Log("Sync: channel notice %s%s%s", tostring(kind), player and player ~= "" and (" "..player) or "", actor and actor ~= "" and (" by "..actor) or "")
	-- The game names players by first name in these notices ("Khal", not "Khal Drogash")
	local us = Store:GetOrigin()
	local isUs = player == us or player == strmatch(us, "^(%S+)")
	if event == "CHAT_MSG_CHANNEL_NOTICE_USER" then
		local text = HOSTILE_NOTICES[kind]
		if text then
			-- The game doesn't always name who did it; the texts take two names, so both are always given
			-- (string.format takes extra arguments in its stride, never missing ones)
			local who = (type(actor) == "string" and actor ~= "") and actor or "someone"
			if isUs and HOSTILE_NOTICES_SELF[kind] then
				Wanted:Print(HOSTILE_NOTICES_SELF[kind], who)
			else
				Wanted:Print(text, tostring(player), who)
			end
		end
		if kind == "PLAYER_KICKED" and isUs then
			private.Rejoin("kicked")
		elseif kind == "PLAYER_BANNED" and isUs then
			private.LockOut("banned")
			private.TakenOver("we were banned")
		elseif kind == "MODERATION_ON" then
			-- Only moderators can send now: every message would be refused. Sync by whisper until it's off, and
			-- move everyone to a new channel
			private.moderated = true
			private.LockOut("moderation is on")
			if not isUs then
				private.TakenOver("moderation was turned on")
			end
		elseif kind == "MODERATION_OFF" and private.moderated then
			private.moderated = false
			if private.lockedOut then
				private.joinAttempts = 0
				private.TryJoin()
			end
		end
		return
	end
	if kind == "YOU_LEFT" and private.channelId then
		-- Left without leaving: kicked, or the channel was closed under us
		private.Rejoin("out of the channel")
	elseif kind == "BANNED" then
		private.LockOut("banned")
	elseif kind == "WRONG_PASSWORD" then
		if private.RepeatedWrongPassword() then
			private.rejoinFailing, private.wrongPasswords = false, nil
			private.LockOut("its password was changed")
			private.TakenOver("its password was changed")
		elseif private.rejoinFailing then
			-- The game rejoined the channel at login without its password and asked for one: this is that
			-- attempt failing, and the join with the password is on its way
			private.rejoinFailing = false
			Wanted:Log("Sync: the game's rejoin without the password failed; ours follows")
			C_Timer.After(JOIN_RETRY_SECONDS, private.TryJoin)
		else
			private.LockOut("its password was changed")
			private.TakenOver("its password was changed")
		end
	end
end

---Notes a wrong-password notice; true once they come too often to be the game's rejoin at login.
---@return boolean
function private.RepeatedWrongPassword()
	local now = GetTime()
	local recent = {}
	for _, t in ipairs(private.wrongPasswords or {}) do
		if now - t < WRONG_PASSWORDS_SECONDS then
			recent[#recent + 1] = t
		end
	end
	recent[#recent + 1] = now
	private.wrongPasswords = recent
	return #recent >= WRONG_PASSWORDS_TAKEOVER
end

---Joins again shortly.
function private.Rejoin(why)
	Wanted:Log("!! Sync: %s; rejoining the channel in %ds", why, JOIN_RETRY_SECONDS)
	private.channelId = nil
	private.joinAttempts = 0
	C_Timer.After(JOIN_RETRY_SECONDS, private.TryJoin)
end

---Can't get into the channel: say so once, whisper the players last heard on it, and try the channel again later.
function private.LockOut(why)
	if private.lockedOut then
		return
	end
	private.lockedOut = why
	private.channelId = nil
	Wanted:Log("!! Sync: locked out of the channel (%s)", why)
	Wanted:Print("Wanted can't get into its sync channel (%s). It keeps syncing by whisper with players seen there, and tries the channel again every %d minutes.", why, LOCKOUT_RETRY_SECONDS / 60)
	private.GreetRecentPeers()
	if not private.lockoutTicker then
		private.lockoutTicker = C_Timer.NewTicker(LOCKOUT_RETRY_SECONDS, function()
			if private.lockedOut then
				private.joinAttempts = 0
				private.TryJoin()
			end
		end)
	end
end

---Whispers a hello to the players last heard on the channel, as realm links, while locked out.
function private.GreetRecentPeers()
	local cutoff = GetServerTime() - RECENT_PEER_SECONDS
	for name, seen in pairs(Wanted.db.recentPeers) do
		if type(seen) == "number" and seen >= cutoff then
			Sync:Greet(name, nil)
		end
	end
end

---Remembers a player heard on the channel, keeping the most recent few.
function private.NoteRecentPeer(name)
	local recent = Wanted.db.recentPeers
	recent[name] = GetServerTime()
	local names = {}
	for other in pairs(recent) do
		tinsert(names, other)
	end
	if #names > MAX_RECENT_PEERS + 10 then
		sort(names, function(a, b) return recent[a] > recent[b] end)
		for i = MAX_RECENT_PEERS + 1, #names do
			recent[names[i]] = nil
		end
	end
end

---The game rejoins the channels it remembers at login without their passwords, then pops up a box asking for
---one. For the sync channel, Wanted answers with its password and closes the box (a moment later, once the
---game's own handler has shown it).
function private.OnPasswordRequest(channel)
	if type(channel) ~= "string" or strlower(channel) ~= strlower(private.channelName or "") then
		return
	end
	Wanted:Log("Sync: the game asked for the %s password; joining with it", channel)
	-- The game's own attempt fails with a wrong-password notice in a moment. Expected only for a short while, so a
	-- real password change later is still a lockout
	private.rejoinFailing = true
	C_Timer.After(REJOIN_FAIL_SECONDS, function() private.rejoinFailing = false end)
	JoinPermanentChannel(private.channelName, private.password)
	C_Timer.After(0, function()
		if StaticPopup_Hide then
			StaticPopup_Hide("CHAT_CHANNEL_PASSWORD", channel)
		end
	end)
end



-- ============================================================================
-- Channel
-- ============================================================================

function private.TryJoin()
	if private.channelId then
		-- Already in (the login and entering-world timers both call this)
		return
	end
	local id = GetChannelName(private.channelName)
	Wanted:Log("Sync: GetChannelName(%s) = %s (attempt %d)", private.channelName, tostring(id), private.joinAttempts)
	if not id or id == 0 then
		if private.joinAttempts >= MAX_JOIN_ATTEMPTS then
			Wanted:Log("Sync: giving up joining after %d attempts", private.joinAttempts)
			private.LockOut("no answer from the game")
			return
		end
		private.joinAttempts = private.joinAttempts + 1
		if private.joinAttempts == 1 then
			Wanted:Log("Sync: calling JoinPermanentChannel")
			-- Joined without a chat frame id, so it is not shown in any tab; it only ever carries addon data, which
			-- never displays anyway. Permanent channels are remembered by the server, so if this client blocks the
			-- call, joining once by hand (/join <name> <password>) is enough for good.
			JoinPermanentChannel(private.channelName, private.password)
		elseif private.joinAttempts == 3 then
			Wanted:Print("Not in the sync channel yet. If it never joins, type once: /join %s %s", private.channelName, private.password)
		end
		C_Timer.After(JOIN_RETRY_SECONDS, private.TryJoin)
		return
	end
	if private.moderated then
		-- Still in it, but it's moderated: stay on whispers until moderation goes off
		Wanted:Log("Sync: the channel is still moderated; syncing by whisper")
		return
	end
	private.channelId = id
	if private.lockedOut then
		Wanted:Log("Sync: back in the channel after being locked out (%s)", private.lockedOut)
		private.lockedOut = nil
		if private.lockoutTicker then
			private.lockoutTicker:Cancel()
			private.lockoutTicker = nil
		end
	end
	private.HideFromChatWindows()
	if not private.membersTicker then
		private.membersTicker = C_Timer.NewTicker(MEMBERS_INTERVAL, function() private.RequestMembers() end)
	end
	C_Timer.After(JOIN_SETTLE_SECONDS, function() private.RequestMembers() end)
	if private.joinAttempts > 0 then
		-- Freshly joined: the server needs a moment before it accepts messages on it (result 7, invalid channel)
		Wanted:Log("Sync: in channel #%d after joining, HELLO in %ds", id, JOIN_SETTLE_SECONDS)
		C_Timer.After(JOIN_SETTLE_SECONDS, private.SendHello)
	else
		Wanted:Log("Sync: in channel #%d, sending HELLO", id)
		private.SendHello()
	end
end



-- ============================================================================
-- Sending
-- ============================================================================

local function Encode(tbl)
	local serialized = LibSerialize:Serialize(tbl)
	local compressed = LibDeflate:CompressDeflate(serialized)
	return LibDeflate:EncodeForWoWAddonChannel(compressed)
end

local function Decode(str)
	local compressed = LibDeflate:DecodeForWoWAddonChannel(str)
	if not compressed then
		return nil
	end
	local serialized = LibDeflate:DecompressDeflate(compressed)
	if not serialized then
		return nil
	end
	local ok, tbl = LibSerialize:Deserialize(serialized)
	return ok and tbl or nil
end

---The same encoding for other hidden messages (Battle.net game data, see Bridge).
function Sync:Encode(tbl)
	return Encode(tbl)
end

function Sync:Decode(str)
	return Decode(str)
end

local function PruneTimes(times, now)
	while times[1] and now - times[1] >= 60 do
		tremove(times, 1)
	end
end

---Sends a table as one or more addon messages, on the channel or to one player by whisper (a realm link).
---Returns whether it was sent.
---@param tag string
---@param tbl table
---@param attempt number? how many times the game has throttled it already
---@param target string? a player to whisper instead of the channel
---@return boolean
function private.Send(tag, tbl, attempt, target)
	if not target and not private.channelId then
		return false
	end
	local now = GetTime()
	local isSighting = tag == TAG_SIGHTINGS
	-- Waiting for an update: only say hello (so others know which version this is); share nothing
	if Wanted:GetRequiredUpdate() and tag ~= TAG_HELLO then
		return false
	end
	-- Every message says which version sent it: the newest version wins (Core)
	tbl.v = Wanted.VERSION
	if not target and not isSighting and now < private.pausedUntil then
		private.stats.dropped = private.stats.dropped + 1
		return false
	end
	local payload = Encode(tbl)
	local total = ceil(#payload / CHUNK_LEN)
	Wanted:Log("Sync: send %s%s, %d bytes in %d part(s)", tag, target and (" to "..target) or "", #payload, total)
	if target then
		PruneTimes(private.linkTimes, now)
		if #private.linkTimes + total > MAX_LINK_PARTS_PER_MINUTE then
			Wanted:Log("!! Sync: realm link budget reached, holding %s to %s (the next resync picks it up)", tag, target)
			private.stats.dropped = private.stats.dropped + 1
			return false
		end
	elseif isSighting then
		PruneTimes(private.sightingTimes, now)
		if #private.sightingTimes + total > MAX_SIGHTING_MESSAGES_PER_MINUTE then
			Wanted:Log("Sync: sighting budget reached, dropping a batch")
			private.stats.dropped = private.stats.dropped + 1
			return false
		end
	elseif not private.MakeRoom(tag, total, now) then
		return false
	end
	private.msgCounter = (private.msgCounter % 46655) + 1
	local msgId = private.ToBase36(private.msgCounter)
	local parts = {}
	for part = 1, total do
		local chunk = strsub(payload, (part - 1) * CHUNK_LEN + 1, part * CHUNK_LEN)
		parts[part] = tag..":"..msgId..":"..part.."/"..total..":"..chunk
		assert(#parts[part] <= MAX_MESSAGE_LEN)
	end
	if not target then
		-- Channel messages come back to us; whispers don't
		private.ownMessages[tag..":"..msgId] = now
		if isSighting then
			for _ = 1, total do
				tinsert(private.sightingTimes, now)
			end
		end
		private.Enqueue({ tag = tag, parts = parts, next = 1, priority = SEND_PRIORITY[tag] or DEFAULT_SEND_PRIORITY, queued = now, refusals = 0 })
		return true
	end
	for part = 1, total do
		local result = C_ChatInfo.SendAddonMessage(PREFIX, parts[part], "WHISPER", target)
		Wanted:Log("Sync: SendAddonMessage part %d/%d to %s -> %s", part, total, target, tostring(result))
		if RESULT_THROTTLED[result] then
			private.stats.throttled = private.stats.throttled + 1
			Wanted:Log("!! Sync: throttled by the game (%s) at part %d/%d of %s to %s", tostring(result), part, total, tag, target)
			private.QueueRetry(tag, tbl, attempt, target)
			return false
		end
		tinsert(private.linkTimes, now)
		private.stats.sent = private.stats.sent + 1
	end
	if private.links[target] then
		private.links[target].sent = private.links[target].sent + 1
	end
	return true
end

---Makes room in the channel queue for a message, dropping queued gap fills that haven't started if a more
---important message needs their place. Returns whether it fits.
---@param tag string
---@param total number its parts
---@param now number
---@return boolean
function private.MakeRoom(tag, total, now)
	if tag == TAG_FILL then
		if private.outboxParts + total > MAX_QUEUED_FILL_PARTS then
			Wanted:Log("Sync: send queue busy, leaving the rest of a fill for the next resync")
			private.stats.skipped = private.stats.skipped + 1
			return false
		end
		return true
	end
	local outbox = private.outbox
	for i = #outbox, 1, -1 do
		if private.outboxParts + total <= MAX_QUEUED_PARTS then
			break
		end
		if outbox[i].tag == TAG_FILL and outbox[i].next == 1 then
			private.outboxParts = private.outboxParts - #outbox[i].parts
			tremove(outbox, i)
			private.stats.skipped = private.stats.skipped + 1
		end
	end
	if private.outboxParts + total <= MAX_QUEUED_PARTS then
		return true
	end
	Wanted:Log("!! Sync: send queue full, dropping %s", tag)
	local minute = floor(now / 60)
	if private.ceilingHitMinute and minute == private.ceilingHitMinute + 1 then
		private.pausedUntil = now + PAUSE_SECONDS
		Wanted:Log("!! Sync: send queue full two minutes running, paused for %d minutes", PAUSE_SECONDS / 60)
		Wanted:Print("Sync had more to send than the game allows two minutes running, so it is paused for %d minutes.", PAUSE_SECONDS / 60)
	end
	private.ceilingHitMinute = minute
	private.stats.dropped = private.stats.dropped + 1
	return false
end

---Queues a channel message behind everything as important or more, then sends what the pace allows.
---@param item table
function private.Enqueue(item)
	local outbox = private.outbox
	local at = #outbox + 1
	for i = #outbox, 1, -1 do
		-- A message already partly sent keeps its place, so its parts arrive close together
		if outbox[i].priority <= item.priority or outbox[i].next > 1 then
			break
		end
		at = i
	end
	tinsert(outbox, at, item)
	private.outboxParts = private.outboxParts + #item.parts
	private.Drain()
end

---Where the next message to send is in the queue: the first one, except that in a fight only sightings (and
---messages already part sent) go. Nil when everything left is held.
---@return number?
function private.NextToSend()
	local outbox = private.outbox
	if not Wanted:InCombat() then
		return outbox[1] and 1 or nil
	end
	for i, item in ipairs(outbox) do
		if item.tag == TAG_SIGHTINGS or item.next > 1 then
			return i
		end
	end
	return nil
end

---Sends queued channel parts while the pace allows, then waits for the next one.
function private.Drain()
	private.drainScheduled = false
	local now = GetTime()
	private.tokens = min(CHANNEL_BURST, private.tokens + max(0, now - private.tokensAt) / CHANNEL_PART_SECONDS)
	private.tokensAt = now
	local outbox = private.outbox
	local wait = nil
	while outbox[1] and not wait do
		local at = private.NextToSend()
		if not at then
			-- Only held messages left: they go when the fight is over (OnCombatEnd)
			return
		end
		local item = outbox[at]
		if not private.channelId then
			-- Left the channel: the queue is stale, and the hello after rejoining starts a resync
			private.stats.dropped = private.stats.dropped + #outbox
			wipe(outbox)
			private.outboxParts = 0
			return
		elseif item.tag == TAG_SIGHTINGS and item.next == 1 and now - item.queued > SIGHTING_QUEUE_SECONDS then
			tremove(outbox, at)
			private.outboxParts = private.outboxParts - #item.parts
			private.stats.dropped = private.stats.dropped + 1
		elseif private.tokens < 1 then
			wait = (1 - private.tokens) * CHANNEL_PART_SECONDS
		else
			-- The channel's number, asked again every time: the game renumbers channels as they're left and joined
			-- (zone changes, loading screens, a rejoin), and a number kept from the join once pointed at General
			local id = private.CurrentChannelId()
			if not id then
				Wanted:Log("!! Sync: %s has no channel number now; not sending, rejoining", tostring(private.channelName))
				private.channelId = nil
				private.joinAttempts = 0
				private.stats.dropped = private.stats.dropped + #outbox
				wipe(outbox)
				private.outboxParts = 0
				C_Timer.After(JOIN_RETRY_SECONDS, private.TryJoin)
				return
			elseif id ~= private.channelId then
				Wanted:Log("!! Sync: %s moved from #%s to #%d", private.channelName, tostring(private.channelId), id)
				private.channelId = id
			end
			local part, total = item.next, #item.parts
			private.lastChannelSend = GetTime()
			local result = C_ChatInfo.SendAddonMessage(PREFIX, item.parts[part], "CHANNEL", tostring(id))
			Wanted:Log("Sync: SendAddonMessage part %d/%d of %s -> %s", part, total, item.tag, tostring(result))
			if result == RESULT_INVALID_CHANNEL then
				-- Not really in the channel (yet): look it up again shortly and say hello then
				private.channelId = nil
				private.joinAttempts = 0
				C_Timer.After(JOIN_SETTLE_SECONDS, private.TryJoin)
			elseif RESULT_THROTTLED[result] then
				-- Something else used up the game's allowance (another addon, or chat): wait, then send this part again
				private.stats.throttled = private.stats.throttled + 1
				item.refusals = item.refusals + 1
				Wanted:Log("!! Sync: throttled by the game (%s) at part %d/%d of %s", tostring(result), part, total, item.tag)
				if item.refusals > MAX_RETRIES then
					tremove(outbox, at)
					private.outboxParts = private.outboxParts - (total - part + 1)
					private.stats.dropped = private.stats.dropped + 1
				end
				private.tokens = 0
				-- Longer each time: every refusal also puts a notice on the screen (hidden, but still)
				wait = RETRY_SECONDS * 2 ^ (item.refusals - 1)
			else
				private.tokens = private.tokens - 1
				private.stats.sent = private.stats.sent + 1
				private.outboxParts = private.outboxParts - 1
				item.next = part + 1
				if item.next > total then
					tremove(outbox, at)
				end
			end
		end
	end
	if outbox[1] and not private.drainScheduled then
		private.drainScheduled = true
		C_Timer.After(wait or CHANNEL_PART_SECONDS, private.Drain)
	end
end

---Sends a throttled message again in a few seconds, up to a few times.
function private.QueueRetry(tag, tbl, attempt, target)
	attempt = (attempt or 0) + 1
	if attempt > MAX_RETRIES or #private.retryQueue >= MAX_RETRY_QUEUE then
		private.stats.dropped = private.stats.dropped + 1
		return
	end
	tinsert(private.retryQueue, { tag = tag, tbl = tbl, attempt = attempt, target = target })
	private.ScheduleRetries()
end

function private.ScheduleRetries()
	if private.retryScheduled or #private.retryQueue == 0 then
		return
	end
	private.retryScheduled = true
	C_Timer.After(RETRY_SECONDS, private.RunRetries)
end

function private.RunRetries()
	private.retryScheduled = false
	local queue = private.retryQueue
	private.retryQueue = {}
	for i, item in ipairs(queue) do
		if not private.Send(item.tag, item.tbl, item.attempt, item.target) then
			-- Throttled again (Send queued it) or held by a limit: the rest waits for the next round
			for j = i + 1, #queue do
				tinsert(private.retryQueue, queue[j])
			end
			break
		end
	end
	private.ScheduleRetries()
end

---Queues an enemy sighting for the next batch.
---@param data table the sighting (g = guid, n = name, c, l, r, u, z, m, x, y, s)
---@param urgent boolean? Kill on Sight, bounty or stealthed: send within a couple of seconds
function Sync:QueueSighting(data, urgent)
	local now = GetTime()
	local last = private.recentSightings[data.g]
	if not urgent and last and now - last < SIGHTING_FRESH_SECONDS then
		-- Someone shared them a moment ago
		private.stats.skipped = private.stats.skipped + 1
		return
	end
	local queued = private.sightingQueue[data.g]
	private.sightingQueue[data.g] = { data = data, urgent = urgent or (queued and queued.urgent) or false, t = now }
	private.ScheduleFlush(urgent and SIGHTING_URGENT_SECONDS or SIGHTING_BATCH_SECONDS)
end

---Flushes the sighting queue after a delay, keeping an earlier flush if one is already due sooner.
function private.ScheduleFlush(delay)
	local due = GetTime() + delay
	if private.flushDue and private.flushDue <= due then
		return
	end
	private.flushDue = due
	private.flushGen = private.flushGen + 1
	local gen = private.flushGen
	C_Timer.After(delay, function()
		if gen == private.flushGen then
			private.FlushSightings()
		end
	end)
end

---Sends the queued sightings as one message: urgent ones first, then the newest, up to the batch size.
function private.FlushSightings()
	private.flushDue = nil
	local now = GetTime()
	local list = {}
	for guid, item in pairs(private.sightingQueue) do
		local last = private.recentSightings[guid]
		if now - item.t > SIGHTING_FRESH_SECONDS or (not item.urgent and last and last >= item.t) then
			-- Stale, or someone else shared them while this waited
			private.sightingQueue[guid] = nil
			private.stats.skipped = private.stats.skipped + 1
		else
			tinsert(list, item)
		end
	end
	for guid, t in pairs(private.recentSightings) do
		if now - t > 5 * SIGHTING_FRESH_SECONDS then
			private.recentSightings[guid] = nil
		end
	end
	if #list == 0 or not private.channelId then
		return
	end
	sort(list, function(a, b)
		if a.urgent ~= b.urgent then
			return a.urgent
		end
		return a.t > b.t
	end)
	local batch = {}
	for i = 1, min(#list, MAX_SIGHTINGS_PER_BATCH) do
		batch[i] = list[i].data
		-- Sent or not, this news is used up: a dropped batch isn't worth sending late
		private.sightingQueue[list[i].data.g] = nil
	end
	if private.Send(TAG_SIGHTINGS, { s = batch }) then
		for _, data in ipairs(batch) do
			private.recentSightings[data.g] = now
		end
	end
	if next(private.sightingQueue) then
		private.ScheduleFlush(SIGHTING_BATCH_SECONDS)
	end
end

function private.ToBase36(n)
	local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
	local str = ""
	repeat
		local d = n % 36
		str = strsub(digits, d + 1, d + 1)..str
		n = floor(n / 36)
	until n == 0
	return str
end

-- A hello lists only the chains active lately: listing every origin ever seen grew with the network, and past
-- about 1,000 origins it no longer fit the send queue, so no hello went out at all. A quiet chain is listed again
-- once its origin makes a new record.
local HAVE_ACTIVE_SECONDS = 7 * 24 * 60 * 60
local MAX_HAVE_ORIGINS = 150

---What this client holds: the highest seq per origin, for our own chain and the most recently active others.
function private.GetHaveTable()
	local own = Store:GetOrigin()
	local cutoff = GetServerTime() - HAVE_ACTIVE_SECONDS
	local active = {}
	for origin, chain in pairs(Wanted.db.chains) do
		if chain.seq > 0 and (origin == own or Store:GetLastActive(origin) >= cutoff) then
			tinsert(active, origin)
		end
	end
	sort(active, function(a, b)
		if (a == own) ~= (b == own) then
			return a == own
		end
		local ta, tb = Store:GetLastActive(a), Store:GetLastActive(b)
		if ta ~= tb then
			return ta > tb
		end
		return a < b
	end)
	local chains = {}
	for i = 1, min(#active, MAX_HAVE_ORIGINS) do
		chains[active[i]] = Wanted.db.chains[active[i]].seq
	end
	return chains
end

function private.SendHello()
	private.Send(TAG_HELLO, { c = private.GetHaveTable(), v = Wanted.VERSION })
end

-- Our new records go out together: a busy fight makes one every few seconds, and one message each hit the send
-- limit. One death record alone is just over one part, so waiting 8 seconds (as sightings do) roughly halves
-- the parts a fight costs.
local LIVE_BATCH_SECONDS = 8
local LIVE_BATCH_MAX = 10

function private.OnOwnRecord(record, isOwn)
	-- Sightings are announced to listeners too, but are not records and are shared by their own messages
	if not isOwn or not record.id or Store:IsTest(record) then
		return
	end
	tinsert(private.liveQueue, record)
	if not private.liveFlushPending then
		private.liveFlushPending = true
		C_Timer.After(LIVE_BATCH_SECONDS, private.FlushLive)
	end
end

---Sends the queued new records, up to LIVE_BATCH_MAX to a message. Any the send limit refuses still reach
---other players at the next resync.
function private.FlushLive()
	private.liveFlushPending = false
	if Wanted:InCombat() then
		-- Kept until the fight is over (OnCombatEnd)
		return
	end
	local queue = private.liveQueue
	private.liveQueue = {}
	for first = 1, #queue, LIVE_BATCH_MAX do
		private.Send(TAG_LIVE, { r = { unpack(queue, first, min(first + LIVE_BATCH_MAX - 1, #queue)) } })
	end
end



-- ============================================================================
-- Receiving
-- ============================================================================

function private.OnAddonMessage(prefix, text, channel, sender, _, _, _, channelName)
	if prefix ~= PREFIX then
		return
	end
	-- The one private message: a newer client telling this one to update
	if channel == "WHISPER" and strsub(text, 1, 2) == TAG_UPDATE..":" then
		local payload = strmatch(text, "^%u:%w+:%d+/%d+:(.*)$")
		local tbl = payload and Decode(payload)
		if type(tbl) == "table" then
			Wanted:Log("Sync: %s says we must update to %s", tostring(sender), tostring(tbl.v))
			Wanted:NoteVersion(tbl.v)
		end
		return
	end
	-- A channel move, or a question about the current channel
	if channel == "WHISPER" and strsub(text, 1, 2) == TAG_MOVE..":" then
		local payload = strmatch(text, "^%u:%w+:%d+/%d+:(.*)$")
		local tbl = payload and Decode(payload)
		if type(tbl) == "table" then
			private.OnMove(tbl, sender)
		end
		return
	end
	-- A join for a posse we called
	if channel == "WHISPER" and strsub(text, 1, 2) == TAG_POSSE_JOIN..":" then
		local payload = strmatch(text, "^%u:%w+:%d+/%d+:(.*)$")
		local tbl = payload and Decode(payload)
		if type(tbl) == "table" and Wanted.Posse then
			Wanted.Posse:OnJoin(sender, tbl.g)
		end
		return
	end
	-- Whispers carry realm links (players on another realm name); anything else must be our channel
	local viaLink = channel == "WHISPER"
	if not viaLink then
		if channel ~= "CHANNEL" then
			return
		end
		if channelName and channelName ~= "" and strlower(channelName) ~= strlower(private.channelName) then
			return
		end
	end
	local now = GetTime()
	private.stats.received = private.stats.received + 1
	-- Our own messages come back to us; recognise them by the id we just sent rather than by name, and let the
	-- store learn how the server names us as a sender
	local isSelf = false
	if not viaLink then
		local echoTag, echoId = strmatch(text, "^(%u):(%w+):")
		isSelf = echoTag and private.ownMessages[echoTag..":"..echoId] and now - private.ownMessages[echoTag..":"..echoId] < 30
		if isSelf then
			private.ownMessages[echoTag..":"..echoId] = nil
			Store:LearnOrigin(sender)
		elseif sender == Store:GetOrigin() then
			isSelf = true
		end
	end
	Wanted:Log("Sync: received %d bytes from %s%s %s", #text, sender, isSelf and " (self)" or "", viaLink and "by whisper" or ("on "..tostring(channelName)))
	if isSelf then
		-- Our own messages come back to us too, which is the transport check in /wanted synctest
		private.stats.echoed = private.stats.echoed + 1
		if private.testStartedAt then
			Wanted:Print("Sync test: our message came back through the channel (%.2fs).", now - private.testStartedAt)
			private.testStartedAt = nil
		end
		return
	end
	if not viaLink then
		private.peers[sender] = now
		private.NoteRecentPeer(sender)
	end
	-- Per-sender inbound cap
	local minute = floor(now / 60)
	local inbound = private.inbound[sender]
	if not inbound or inbound.minute ~= minute then
		inbound = { count = 0, minute = minute }
		private.inbound[sender] = inbound
	end
	inbound.count = inbound.count + 1
	if inbound.count > MAX_INBOUND_PER_SENDER_PER_MINUTE then
		if inbound.count == MAX_INBOUND_PER_SENDER_PER_MINUTE + 1 then
			Wanted:Log("!! Sync: %s sent over %d messages this minute; ignoring the rest", tostring(sender), MAX_INBOUND_PER_SENDER_PER_MINUTE)
		end
		return
	end
	-- Framing
	local tag, msgId, part, total, chunk = strmatch(text, "^(%u):(%w+):(%d+)/(%d+):(.*)$")
	if not tag then
		private.stats.invalid = private.stats.invalid + 1
		Wanted:Log("!! Sync: badly framed message from %s", tostring(sender))
		return
	end
	part, total = tonumber(part), tonumber(total)
	if part < 1 or part > total then
		private.stats.invalid = private.stats.invalid + 1
		Wanted:Log("!! Sync: part %d/%d from %s doesn't fit its message", part, total, tostring(sender))
		return
	end
	local payload = nil
	if total == 1 then
		payload = chunk
	else
		local key = sender..":"..msgId
		local partial = private.partial[key]
		if not partial or now - partial.t > PARTIAL_TIMEOUT then
			partial = { parts = {}, total = total, t = now, count = 0 }
			private.partial[key] = partial
		elseif partial.total ~= total then
			-- Parts of one message all carry its total; a mismatch is a crafted or garbled message
			private.stats.invalid = private.stats.invalid + 1
			private.partial[key] = nil
			return
		end
		if not partial.parts[part] then
			partial.parts[part] = chunk
			partial.count = partial.count + 1
		end
		if partial.count < total then
			return
		end
		private.partial[key] = nil
		payload = table.concat(partial.parts, "", 1, total)
	end
	-- Sightings are news only while fresh; everything else waits out a fight (and any backlog, to keep order)
	if tag ~= TAG_SIGHTINGS and tag ~= TAG_ENEMY and (Wanted:InCombat() or Wanted:QueuedWork() > 0) then
		if Wanted:QueuedWork() >= MAX_DEFERRED_MESSAGES then
			-- The next resync asks again for anything this leaves out
			private.stats.dropped = private.stats.dropped + 1
			return
		end
		Wanted:QueueWork(function() private.Process(tag, payload, sender, viaLink) end)
		return
	end
	private.Process(tag, payload, sender, viaLink)
end

---Decodes and handles one whole message.
function private.Process(tag, payload, sender, viaLink)
	local tbl = Decode(payload)
	if type(tbl) ~= "table" then
		private.stats.invalid = private.stats.invalid + 1
		Wanted:Log("!! Sync: could not decode a %s message from %s", tag, sender)
		return
	end
	Wanted:Log("Sync: handling %s from %s%s", tag, sender, viaLink and " (realm link)" or "")
	private.HandleMessage(tag, tbl, sender, viaLink)
end

---Tells a player on an older version, privately and at most every few minutes, to update.
function private.TellOutdated(sender)
	private.toldOutdated = private.toldOutdated or {}
	local now = GetTime()
	if private.toldOutdated[sender] and now - private.toldOutdated[sender] < TELL_OUTDATED_SECONDS then
		return
	end
	private.toldOutdated[sender] = now
	private.msgCounter = (private.msgCounter % 46655) + 1
	local text = TAG_UPDATE..":"..private.ToBase36(private.msgCounter)..":1/1:"..Encode({ v = Wanted.VERSION })
	C_ChatInfo.SendAddonMessage(PREFIX, text, "WHISPER", sender)
	Wanted:Log("Sync: told %s to update", tostring(sender))
end

function private.HandleMessage(tag, tbl, sender, viaLink)
	-- The newest release wins: a newer one may lock this client (Core); an older one's news is ignored. A
	-- development build is not a release, so it neither locks others nor turns them away.
	Wanted:NoteVersion(tbl.v)
	Store:NoteAddonVersion(sender, tbl.v)
	if type(tbl.v) == "string" and Wanted:IsRelease(Wanted.VERSION) and Wanted:IsNewerVersion(Wanted.VERSION, tbl.v) then
		private.TellOutdated(sender)
		if tag ~= TAG_HELLO and tag ~= TAG_HAVE and tag ~= TAG_NEED then
			return
		end
	end
	-- Waiting for an update: take nothing in until this client can read what newer versions write
	if Wanted:GetRequiredUpdate() then
		return
	end
	if viaLink then
		private.HandleLinkMessage(tag, tbl, sender)
		return
	end
	if tag == TAG_ENEMY or tag == TAG_SIGHTINGS then
		local list = tag == TAG_SIGHTINGS and tbl.s or { tbl }
		if type(list) ~= "table" then
			return
		end
		local now = GetTime()
		for i, data in ipairs(list) do
			if i > MAX_SIGHTINGS_PER_BATCH then
				break
			end
			if type(data) == "table" and type(data.g) == "string" then
				private.recentSightings[data.g] = now
				if Wanted.Enemies then
					Wanted.Enemies:OnSharedSighting(data, sender)
				end
			end
		end
		return
	end
	if tag == TAG_HELLO or tag == TAG_HAVE then
		if type(tbl.c) ~= "table" then
			return
		end
		private.HandleHave(tbl.c, sender, tag == TAG_HELLO)
	elseif tag == TAG_NEED then
		if type(tbl.n) ~= "table" then
			return
		end
		private.HandleNeed(tbl.n, sender)
	elseif tag == TAG_LIVE or tag == TAG_FILL then
		if type(tbl.r) ~= "table" then
			return
		end
		-- The sender's copy of a chain starts later than we asked: the earlier records were pruned. Move on to
		-- where it starts, continuing from the first record's predecessor when it's in this message.
		if tag == TAG_FILL and type(tbl.p) == "table" then
			for origin, seq in pairs(tbl.p) do
				if type(origin) == "string" and type(seq) == "number" then
					local prev
					for _, record in ipairs(tbl.r) do
						if type(record) == "table" and record.origin == origin and record.seq == seq then
							prev = record.prev
						end
					end
					Store:SkipTo(origin, seq, prev)
				end
			end
		end
		for _, record in ipairs(tbl.r) do
			local isNew, why
			-- A record sent by its own origin was heard straight from it, live message or gap fill (the game
			-- stamps the sender)
			if tag == TAG_LIVE or (type(record) == "table" and record.origin == sender) then
				isNew, why = Store:Merge(record, sender)
			else
				isNew, why = Store:MergeRelayed(record)
			end
			Wanted:Log("Sync: %s record %s from %s: %s", tag == TAG_LIVE and "live" or "fill", tostring(type(record) == "table" and record.id), sender, isNew and "new" or why or "not taken")
			if isNew then
				private.stats.merged = private.stats.merged + 1
				if type(record.origin) == "string" and type(record.seq) == "number" then
					private.recentFills[record.origin] = max(private.recentFills[record.origin] or 0, record.seq)
				end
			end
		end
		if tag == TAG_FILL then
			private.SkipPruned(tbl)
		end
	end
end

---A peer told us what it holds. Ask for what we lack, and if this was a HELLO, tell it what we hold. Over a
---realm link the request goes straight back to that player, for more origins at once.
function private.HandleHave(chains, sender, isHello, viaLink)
	local need = {}
	local numNeed = 0
	local maxNeed = viaLink and MAX_NEED_ORIGINS_LINK or 5
	for origin, seq in pairs(chains) do
		if type(origin) == "string" and type(seq) == "number" and seq > Store:GetChainSeq(origin) and origin ~= Store:GetOrigin() then
			need[origin] = Store:GetChainSeq(origin) + 1
			numNeed = numNeed + 1
			if numNeed >= maxNeed then
				break
			end
		end
	end
	if numNeed > 0 and viaLink then
		private.Send(TAG_NEED, { n = need }, nil, sender)
	elseif numNeed > 0 then
		-- Spread requests so a busy channel is not hit by everyone at once
		C_Timer.After(0.5 + math.random() * 2.5, function()
			private.Send(TAG_NEED, { n = need })
		end)
	end
	if isHello then
		-- Answer with what we hold, only if it has something the newcomer lacks
		local mine = private.GetHaveTable()
		local hasMore = false
		for origin, seq in pairs(mine) do
			if (chains[origin] or 0) < seq then
				hasMore = true
				break
			end
		end
		if hasMore then
			C_Timer.After(1 + math.random() * 3, function()
				private.Send(TAG_HAVE, { c = mine, v = Wanted.VERSION })
			end)
		end
	end
end

---A peer asked for records. Answer after a random delay unless someone else already filled that range (over a
---realm link nobody else can: answer that player straight away).
function private.HandleNeed(need, sender, viaLink)
	local asked = {}
	for origin, fromSeq in pairs(need) do
		tinsert(asked, tostring(origin).." from "..tostring(fromSeq))
	end
	Wanted:Log("Sync: %s asks for %s", sender, table.concat(asked, ", "))
	if viaLink then
		for origin, fromSeq in pairs(need) do
			if type(origin) == "string" and type(fromSeq) == "number" and Store:GetChainSeq(origin) >= fromSeq then
				private.SendFill(origin, fromSeq, sender)
			end
		end
		return
	end
	for origin, fromSeq in pairs(need) do
		if type(origin) == "string" and type(fromSeq) == "number" and Store:GetChainSeq(origin) >= fromSeq then
			private.pendingNeedAnswers[origin] = { from = fromSeq, t = GetTime() }
			C_Timer.After(0.5 + math.random() * 2.5, function()
				local pending = private.pendingNeedAnswers[origin]
				if not pending or pending.from ~= fromSeq then
					return
				end
				private.pendingNeedAnswers[origin] = nil
				if (private.recentFills[origin] or 0) >= fromSeq and GetTime() - pending.t < 10 then
					-- Someone answered first
					return
				end
				private.SendFill(origin, fromSeq)
			end)
		end
	end
end

---Sends an origin's records from a seq on, on the channel or to one player. Every kind: notices and proofs
---too, which the first list here left out.
function private.SendFill(origin, fromSeq, target)
	local records = {}
	local lowest = Store:GetChainSeq(origin) + 1
	for _, record in pairs(Wanted.db.records) do
		if record.origin == origin and type(record.seq) == "number" and not Store:IsTest(record) then
			lowest = min(lowest, record.seq)
			if record.seq >= fromSeq then
				tinsert(records, record)
			end
		end
	end
	sort(records, function(a, b) return a.seq < b.seq end)
	-- Older records than they asked for were pruned here (Store:Prune): the answer says where our copy of the
	-- chain starts, so they stop asking for what nobody has any more (1.2.9 to 1.2.20 read only this)
	local extras = { [1] = lowest > fromSeq and { p = { [origin] = lowest } } or nil }
	-- Pruning also leaves holes further on (what it keeps sits between what it drops): g lists each as the seq
	-- held before it and the one after, in the message carrying the one after, the last message for one at the end
	local chainSeq, last, count = Store:GetChainSeq(origin), fromSeq - 1, min(#records, MAX_FILL_PER_REQUEST)
	local function AddGap(first, to)
		local extra = extras[first] or {}
		extras[first] = extra
		extra.g = extra.g or { [origin] = {} }
		tinsert(extra.g[origin], last)
		tinsert(extra.g[origin], to)
	end
	for i = 1, count do
		local seq = records[i].seq
		-- Only below our chain's end is a missing record a pruned one; past it, one we never had
		if seq > last + 1 and last < chainSeq then
			AddGap(i - (i - 1) % FILL_BATCH, min(seq, chainSeq + 1))
		end
		last = seq
	end
	if count == #records and last < chainSeq then
		AddGap(max(count - (count - 1) % FILL_BATCH, 1), chainSeq + 1)
	end
	private.SendInBatches(records, target, MAX_FILL_PER_REQUEST, extras)
end

---Moves chains on over the holes a fill says pruning left at its sender (SendFill), once this client has what
---comes before each: the records between were pruned everywhere it could ask, and would be asked for forever.
---@param tbl table the fill
function private.SkipPruned(tbl)
	if type(tbl.g) ~= "table" then
		return
	end
	for origin, gaps in pairs(tbl.g) do
		if type(origin) == "string" and type(gaps) == "table" then
			for i = 1, min(#gaps, 2 * MAX_FILL_PER_REQUEST) - 1, 2 do
				local from, to = gaps[i], gaps[i + 1]
				-- Whole numbers only (floor also gives Lua 5.4's integers, as the record ids need)
				from = type(from) == "number" and from == floor(from) and floor(from) or nil
				to = type(to) == "number" and to == floor(to) and floor(to) or nil
				if from and to and Store:GetChainSeq(origin) >= from then
					local prev
					for _, record in ipairs(tbl.r) do
						if type(record) == "table" and record.origin == origin and record.seq == to then
							prev = record.prev
						end
					end
					Store:SkipTo(origin, to, prev)
				end
			end
		end
	end
end

---Sends records as fills, FILL_BATCH to a message, one message per piece of background work: packing a long
---catch-up in one go stalled the game for a frame. Stops at the first message a limit turns away (the next
---resync asks again), or after max records.
---@param records table[]
---@param target string? a realm link to whisper, or nil for the channel
---@param max number?
---@param extras table? fields for a message, by the index of its first record ([1] is sent on its own when there
---are no records)
function private.SendInBatches(records, target, max, extras)
	local state = { stopped = false }
	local count = min(#records, max or #records)
	if count == 0 and extras and extras[1] then
		Wanted:QueueWork(function()
			local tbl = { r = {} }
			for k, v in pairs(extras[1]) do
				tbl[k] = v
			end
			private.Send(TAG_FILL, tbl, nil, target)
		end)
		return
	end
	for i = 1, count, FILL_BATCH do
		Wanted:QueueWork(function()
			if state.stopped then
				return
			end
			local batch = {}
			for j = i, min(i + FILL_BATCH - 1, count) do
				tinsert(batch, records[j])
			end
			local tbl = { r = batch }
			if extras and extras[i] then
				for k, v in pairs(extras[i]) do
					tbl[k] = v
				end
			end
			if not private.Send(TAG_FILL, tbl, nil, target) then
				state.stopped = true
			end
		end)
	end
end



-- ============================================================================
-- Realm links
-- ============================================================================

local function NormalizeRealm(name)
	return type(name) == "string" and strlower((gsub(name, "[%s%-']", ""))) or nil
end

---Whether a realm name (as the game or Battle.net gives it) is this player's.
---@param name string?
---@return boolean
function Sync:IsOwnRealm(name)
	local mine = NormalizeRealm(GetRealmName())
	return mine ~= nil and NormalizeRealm(name) == mine
end

---Greets a player on another realm name by hidden whisper. A Wanted client answers, and the two become a realm
---link: they catch each other up and forward new records both ways from then on.
---@param name string the player's name as a whisper takes it
---@param realm string? where they are, if known
function Sync:Greet(name, realm)
	if type(name) ~= "string" or name == "" or name == Store:GetOrigin() or (realm and Sync:IsOwnRealm(realm) and not private.lockedOut) then
		return
	end
	local now = GetTime()
	local link = private.links[name]
	if (link and now - link.heard < LINK_TIMEOUT) or (private.greeted[name] and now - private.greeted[name] < GREET_SECONDS) then
		return
	end
	private.greeted[name] = now
	private.greetedRealm[name] = realm
	Wanted:Log("Sync: greeting %s (%s) as a realm link", name, tostring(realm))
	private.SendLinkHello(name, false)
end

function private.SendLinkHello(name, isAnswer)
	-- x: locked out of the channel, so a player on this very realm should link by whisper too
	private.Send(TAG_HELLO, { c = private.GetHaveTable(), r = GetRealmName(), a = isAnswer or nil, x = private.lockedOut and 1 or nil }, nil, name)
end

function private.AddLink(name, realm)
	local now = GetTime()
	local link = private.links[name]
	if not link then
		link = { realm = realm, since = now, sent = 0, received = 0 }
		private.links[name] = link
		Wanted:Log("Sync: realm link with %s on %s", name, tostring(realm))
	end
	link.realm, link.heard = realm, now
	-- Remember them for next time: the most recent few, for a week. Not a player on this very realm (the
	-- channel covers them) or one whose realm isn't known: greeting those at every login goes unanswered
	local far = Wanted.db.farPeers
	if type(realm) ~= "string" or realm == "?" or Sync:IsOwnRealm(realm) then
		return link
	end
	far[name] = { realm = realm, seen = GetServerTime() }
	local names = {}
	for other in pairs(far) do
		tinsert(names, other)
	end
	if #names > MAX_REMEMBERED_LINKS then
		sort(names, function(a, b) return far[a].seen > far[b].seen end)
		for i = MAX_REMEMBERED_LINKS + 1, #names do
			far[names[i]] = nil
		end
	end
	return link
end

---A realm link message (a whisper). A HELLO from another realm makes the link; everything else needs one.
function private.HandleLinkMessage(tag, tbl, sender)
	local link = private.links[sender]
	if tag == TAG_HELLO then
		-- Our own realm's players are covered by the channel, unless they say they're locked out of it (x) or
		-- this answers a greeting we sent them (while locked out ourselves)
		local greeted = private.greeted[sender] and GetTime() - private.greeted[sender] < GREET_SECONDS
		local wanted = tbl.x or (tbl.a and greeted)
		if type(tbl.r) ~= "string" or (Sync:IsOwnRealm(tbl.r) and not wanted) or type(tbl.c) ~= "table" then
			Wanted:Log("!! Sync: %s greeted us by whisper from our own realm or without one; ignored", tostring(sender))
			return
		end
		link = private.AddLink(sender, tbl.r)
		link.received = link.received + 1
		if not tbl.a then
			private.SendLinkHello(sender, true)
		end
		private.HandleHave(tbl.c, sender, false, true)
		return
	end
	if not link and private.greeted[sender] and GetTime() - private.greeted[sender] < GREET_SECONDS then
		-- We greeted them and their answer's parts are still on the way: their shorter messages can arrive first
		link = private.AddLink(sender, private.greetedRealm[sender] or "?")
	end
	if not link then
		Wanted:Log("!! Sync: %s whispered a %s without being a realm link; ignored", tostring(sender), tag)
		return
	end
	link.heard = GetTime()
	link.received = link.received + 1
	if tag == TAG_HAVE and type(tbl.c) == "table" then
		private.HandleHave(tbl.c, sender, false, true)
	elseif tag == TAG_NEED and type(tbl.n) == "table" then
		private.HandleNeed(tbl.n, sender, true)
	elseif (tag == TAG_FILL or tag == TAG_LIVE) and type(tbl.r) == "table" then
		private.currentSource = sender
		for _, record in ipairs(tbl.r) do
			local isNew, why
			if type(record) == "table" and record.origin == sender then
				isNew, why = Store:Merge(record, sender)
			else
				isNew, why = Store:MergeRelayed(record)
			end
			Wanted:Log("Sync: realm link record %s from %s: %s", tostring(type(record) == "table" and record.id), sender, isNew and "new" or why or "not taken")
			if isNew then
				private.stats.merged = private.stats.merged + 1
			end
		end
		if tag == TAG_FILL then
			private.SkipPruned(tbl)
		end
		private.currentSource = nil
	end
end

---Every new record, whoever made it: forwarded to the realm links (not back to the one it came from), and one
---that came over a link is shared once on this realm's channel. Records are only new once, so nothing loops.
---Tells a posse's caller we're joining (an addon whisper; they invite us).
---@param caller string
---@param guid string the target
function Sync:SendPosseJoin(caller, guid)
	return private.Send(TAG_POSSE_JOIN, { g = guid }, nil, caller)
end

---Runs func with the records merged in it kept to this client: not forwarded to realm links or re-shared. For
---the desktop app's catch-up, which every player with the app takes in for themselves.
---@param func function
function Sync:WithoutForwarding(func)
	private.quiet = true
	local ok, err = pcall(func)
	private.quiet = false
	if not ok then
		error(err, 0)
	end
end

function private.OnAnyRecord(record)
	-- Sightings are announced like records but aren't (no id, never forwarded)
	if private.quiet or type(record.id) ~= "string" or Store:IsTest(record) then
		return
	end
	local source = private.currentSource
	local now = GetTime()
	local queued = false
	for name, link in pairs(private.links) do
		if name ~= source and now - (link.heard or 0) < LINK_TIMEOUT then
			local queue = private.forwardQueue[name] or {}
			private.forwardQueue[name] = queue
			if #queue < MAX_FORWARD_QUEUE then
				tinsert(queue, record)
				queued = true
			end
		end
	end
	if source and #private.reshareQueue < MAX_FORWARD_QUEUE then
		tinsert(private.reshareQueue, record)
		queued = true
	end
	if queued and not private.forwardDue then
		private.forwardDue = true
		C_Timer.After(LINK_FORWARD_SECONDS, private.FlushForward)
	end
end

function private.FlushForward()
	private.forwardDue = false
	if Wanted:InCombat() then
		-- Kept until the fight is over (OnCombatEnd)
		return
	end
	for name, queue in pairs(private.forwardQueue) do
		private.forwardQueue[name] = nil
		private.SendInBatches(queue, name)
	end
	local reshare = private.reshareQueue
	private.reshareQueue = {}
	if #reshare > 0 then
		private.SendInBatches(reshare, nil)
	end
end

---Once a minute: each live link hears what we hold (a catch-up the budget cut short carries on), and links
---nobody has heard from in a while are dropped.
function private.LinkTick()
	-- A resync can wait a minute; a fight can't
	if Wanted:InCombat() then
		return
	end
	local now = GetTime()
	for name, link in pairs(private.links) do
		if now - (link.heard or 0) >= LINK_TIMEOUT then
			private.links[name] = nil
			Wanted:Log("Sync: realm link with %s went quiet; dropped", name)
		else
			private.Send(TAG_HAVE, { c = private.GetHaveTable() }, nil, name)
		end
	end
end

---At login: greet the realm links remembered from the last week.
function private.GreetRemembered()
	local cutoff = GetServerTime() - REMEMBER_LINK_SECONDS
	for name, info in pairs(Wanted.db.farPeers) do
		if type(info) ~= "table" or info.realm == "?" or Sync:IsOwnRealm(info.realm) then
			Wanted.db.farPeers[name] = nil -- remembered by earlier versions; nobody to greet there
		elseif (info.seen or 0) >= cutoff then
			Sync:Greet(name, info.realm)
		end
	end
end

---The player a "No player named ... is currently playing." message is about, if it's one we greeted a moment
---ago or a realm link (they logged off).
function private.NotFoundName(msg)
	if type(msg) ~= "string" or not ERR_CHAT_PLAYER_NOT_FOUND_S then
		return nil
	end
	local now = GetTime()
	for name in pairs(private.links) do
		if msg == format(ERR_CHAT_PLAYER_NOT_FOUND_S, name) then
			return name
		end
	end
	for _, names in ipairs({ private.greeted, private.endedLinks }) do
		for name, t in pairs(names) do
			if now - t < NOT_FOUND_SECONDS and msg == format(ERR_CHAT_PLAYER_NOT_FOUND_S, name) then
				return name
			end
		end
	end
	return nil
end

---Hides that message for our own whispers: a remembered link who isn't online, or a link who just logged off.
function private.HideNotFound(_, _, msg)
	return private.NotFoundName(msg) ~= nil
end

---A link who logged off: end the link at once, so nothing more is whispered to them.
function private.OnSystemMessage(msg)
	local name = private.NotFoundName(msg)
	if name and private.links[name] then
		private.links[name] = nil
		private.forwardQueue[name] = nil
		private.endedLinks[name] = GetTime()
		Wanted:Log("Sync: realm link %s is offline; link ended", name)
	end
end

---The realm links now: name -> { realm, since, heard, sent, received }.
function Sync:GetLinks()
	return private.links
end



-- ============================================================================
-- Commands
-- ============================================================================

Wanted:RegisterCommand("sync", "Shows the sync channel and traffic counts.", function()
	Wanted:Print(Sync:Status())
end)

Wanted:RegisterCommand("synctest", "Sends a message through the channel and reports when it comes back.", function()
	if not private.channelId then
		Wanted:Print("Not in the channel yet (%s).", private.channelName or "?")
		return
	end
	private.testStartedAt = GetTime()
	if private.Send(TAG_HELLO, { c = private.GetHaveTable(), v = Wanted.VERSION }) then
		Wanted:Print("Sync test: message sent on channel #%d, waiting for it to come back...", private.channelId)
		C_Timer.After(5, function()
			if private.testStartedAt then
				private.testStartedAt = nil
				Wanted:Print("Sync test: nothing came back in 5s. The channel or addon messages are not working.")
			end
		end)
	else
		Wanted:Print("Sync test: could not send (limit or pause).")
	end
end)

Wanted:RegisterCommand("reconnect", "Looks for the sync channel again.", function()
	private.channelId = nil
	private.joinAttempts = 0
	C_Timer.After(1, private.TryJoin)
	Wanted:Print("Looking for %s...", private.channelName or "?")
end)



-- ============================================================================
-- Moving channels
-- ============================================================================
-- The sync channel is an ordinary custom channel: whoever owns it can moderate, ban or re-password it, and its
-- name is in this public code. When that happens, the client that sees it picks a new channel with a random name
-- and password and whispers it to the players it knows; they follow (see MOVE_QUORUM) and pass it on. The Wanted
-- app also carries the current channel from wanteddeadordead.com (Catchup). WantedDB.syncChannel keeps it.

---Whether a channel pointer is one this client could use: a later epoch, a name on this side, a password.
function private.ValidPointer(p)
	return type(p.e) == "number" and p.e >= 1 and p.e == floor(p.e) and p.e < 100000
		and type(p.n) == "string" and #p.n <= CHANNEL_NAME_MAX and strfind(p.n, "^"..CHANNEL_BASE..private.faction.."%l+$") ~= nil
		and type(p.p) == "string" and strfind(p.p, "^%w+$") ~= nil and #p.p >= 6 and #p.p <= 16
end

local function RandomWord(length, letters)
	local out = {}
	for i = 1, length do
		local at = math.random(1, #letters)
		out[i] = strsub(letters, at, at)
	end
	return table.concat(out)
end

---The current channel was taken over: pick the next one (once per channel) and move there.
function private.TakenOver(why)
	private.takenOverAt = GetTime()
	if Wanted.db.settings.channelMoves == false then
		return
	end
	if private.proposedFrom == private.epoch then
		return
	end
	private.proposedFrom = private.epoch
	local pointer = { e = private.epoch + 1, n = CHANNEL_BASE..private.faction..RandomWord(6, "abcdefghijklmnopqrstuvwxyz"),
		p = RandomWord(10, "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789") }
	Wanted:Log("!! Sync: the channel was taken over (%s); moving to %s (%d)", why, pointer.n, pointer.e)
	private.Adopt(pointer, why)
end

---Whether a pointer is newer than ours: a later epoch, or at the same epoch the lower name (two players who saw
---the same takeover pick different names; everyone settles on the same one).
function private.IsNewer(p)
	return p.e > private.epoch or (p.e == private.epoch and p.n < private.channelName)
end

---Moves to a channel: leaves the old one, joins the new, tells the players we know.
function private.Adopt(pointer, why)
	if not private.ValidPointer(pointer) or not private.IsNewer(pointer) then
		return false
	end
	local old = private.channelName
	private.channelName, private.password, private.epoch = pointer.n, pointer.p, pointer.e
	Wanted.db.syncChannel = { e = pointer.e, n = pointer.n, p = pointer.p, t = GetServerTime() }
	Wanted:Print("Wanted's sync channel was taken over (%s), so everyone is moving to a new one.", why)
	Wanted:Log("Sync: moving from %s to %s (%d)", old, pointer.n, pointer.e)
	if LeaveChannelByName and old ~= pointer.n then
		LeaveChannelByName(old)
	end
	private.channelId, private.lockedOut, private.moderated, private.members = nil, nil, false, nil
	if private.lockoutTicker then
		private.lockoutTicker:Cancel()
		private.lockoutTicker = nil
	end
	private.joinAttempts = 0
	C_Timer.After(2, private.TryJoin)
	private.SpreadMove()
	return true
end

---The players this client knows: realm links and those heard on the channel in the last week.
function private.KnownPeers()
	local out, cutoff = {}, GetServerTime() - RECENT_PEER_SECONDS
	for name, seen in pairs(Wanted.db.recentPeers) do
		if type(seen) == "number" and seen >= cutoff then
			out[name] = seen
		end
	end
	for name in pairs(private.links) do
		out[name] = out[name] or GetServerTime()
	end
	return out
end

local function SendMove(target, question)
	private.msgCounter = (private.msgCounter % 46655) + 1
	local tbl = { e = private.epoch, n = private.channelName, p = private.password, q = question and 1 or nil }
	if private.epoch == 0 then
		tbl.n, tbl.p = nil, nil -- the first channel: everyone knows it
	end
	C_ChatInfo.SendAddonMessage(PREFIX, TAG_MOVE..":"..private.ToBase36(private.msgCounter)..":1/1:"..Encode(tbl), "WHISPER", target)
end

---Tells every player we know where we are now.
function private.SpreadMove()
	for name in pairs(private.KnownPeers()) do
		if name ~= Store:GetOrigin() then
			SendMove(name)
		end
	end
end

---At login: asks the few players heard most recently which channel they're on.
function private.AskPointer()
	local peers = {}
	for name, seen in pairs(private.KnownPeers()) do
		if name ~= Store:GetOrigin() then
			tinsert(peers, { name = name, seen = seen })
		end
	end
	sort(peers, function(a, b) return a.seen > b.seen end)
	for i = 1, min(#peers, MOVE_ASK_PEERS) do
		SendMove(peers[i].name, true)
	end
end

---A move (or a question) from another player.
function private.OnMove(tbl, sender)
	if type(sender) ~= "string" or sender == Store:GetOrigin() then
		return
	end
	private.moveReplies = private.moveReplies or {}
	-- They're behind us: tell them where we are (at most once a minute each)
	if type(tbl.e) == "number" and tbl.e < private.epoch then
		local now = GetTime()
		if not private.moveReplies[sender] or now - private.moveReplies[sender] >= MOVE_REPLY_SECONDS then
			private.moveReplies[sender] = now
			SendMove(sender)
		end
		return
	end
	if tbl.q or not private.ValidPointer(tbl) or not private.IsNewer(tbl) then
		return
	end
	-- Only players we know count, and one player alone isn't enough unless we saw the takeover ourselves
	if not private.KnownPeers()[sender] then
		Wanted:Log("!! Sync: a channel move from %s, who we don't know; ignored", tostring(sender))
		return
	end
	local key = tbl.e.."|"..tbl.n.."|"..tbl.p
	private.moveVotes = private.moveVotes or {}
	local votes = private.moveVotes[key] or {}
	private.moveVotes[key] = votes
	votes[sender] = true
	local count = 0
	for _ in pairs(votes) do
		count = count + 1
	end
	local sawIt = private.takenOverAt and GetTime() - private.takenOverAt < MOVE_TRUST_SECONDS
	Wanted:Log("Sync: %s says the channel moved to %s (%d); %d player(s) so far%s", sender, tbl.n, tbl.e, count, sawIt and ", and we saw the takeover" or "")
	if sawIt or count >= MOVE_QUORUM then
		private.Adopt(tbl, sawIt and "we saw it too" or "players we know moved")
	end
end

---The channel the Wanted app passed on from wanteddeadordead.com (Catchup): trusted like our own eyes.
---@param pointer table { e, n, p }
function Sync:AdoptFromApp(pointer)
	if type(pointer) == "table" and private.Adopt(pointer, "the Wanted app says so") then
		Wanted:Log("Sync: moved to the app's channel %s (%d)", pointer.n, pointer.e)
	end
end

---The current channel, for the app to report (WantedDB.syncChannel holds the same once moved).
function Sync:GetPointer()
	return { e = private.epoch, n = private.channelName }
end
