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
local LibSerialize = LibStub("LibSerialize-WantedDeadOrDead") -- Wanted's own copy (see its MAJOR)
local LibDeflate = LibStub("LibDeflate")
local private = {
	frame = CreateFrame("Frame"),
	liveQueue = {},
	liveFlushPending = false,
	channelName = nil,
	channelId = nil,
	joinAttempts = 0,
	msgCounter = 0,
	partial = {}, -- sender..msgId -> { sender, parts = {}, total, count, t }
	outbox = {}, -- channel messages waiting to go: { tag, parts, next, priority, queued, refusals }
	outboxParts = 0, -- parts still to send in outbox
	tokens = 0, -- channel parts we may send now (refilled with time; starts full, below)
	tokensAt = 0,
	drainScheduled = false,
	inbound = {}, -- sender -> { count, minute }
	deferred = {}, -- sender -> their messages waiting out a fight (or a backlog)
	ceilingHitMinute = nil,
	pausedUntil = 0,
	peers = {}, -- sender -> last message time
	ownMessages = {}, -- tag:msgId -> time sent, to recognise our own echoes
	pendingNeedAnswers = {}, -- origin -> { from, t } scheduled answers
	recentFills = {}, -- origin -> highest seq seen filled by anyone recently
	stats = { sent = 0, received = 0, echoed = 0, dropped = 0, merged = 0, invalid = 0, throttled = 0, skipped = 0 },
	dropReasons = {}, -- why messages were dropped, reason -> count (shown in /wanted bug)
	sightingTimes = {}, -- outbound sighting message times in the last minute (their own budget)
	sightingQueue = {}, -- guid -> { data, urgent, t } waiting for the next batch
	flushDue = nil,
	flushGen = 0,
	recentSightings = {}, -- guid -> when anyone (us included) last shared them
	retryQueue = {}, -- { tag, tbl, attempt, target } throttled by the game, sent again shortly
	retryScheduled = false,
	testStartedAt = nil,
	links = {}, -- name -> { realm, heard, since, sent, received } realm links (players on another realm name)
	directory = {}, -- { name, realm } players on other realm names from the app, newest first (TakeDirectory)
	linkTimes = {}, -- outbound link message times in the last minute (their own budget)
	greeted = {}, -- name -> when we last greeted them over a whisper
	greetedRealm = {}, -- name -> the realm they were greeted on
	endedLinks = {}, -- name -> when their link ended because they went offline (their message stays hidden)
	whispered = {}, -- name -> when we last whispered them addon data (any kind: the game's "not online" stays hidden)
	offline = {}, -- name -> when the game said they weren't online (no more whispers to them for a while)
	forwardQueue = {}, -- name -> records to forward to that link
	reshareQueue = {}, -- records from a link to share on this realm's channel
	forwardDue = false,
	currentSource = nil, -- the link whose records are being merged (not sent back to it)
	lockedOut = nil, -- why this client can't get into the channel (banned, a password set, no answer), or nil
	lastChannelSend = -math.huge, -- GetTime() of our last addon message on the channel
	moderated = false, -- moderation is on in the channel: only its moderators can send, so we don't
	membersRetrying = false, -- a member request is waiting for the game's channel list; others don't start one
	membersAskedAt = nil, -- GetTime() of the last member list request
	members = nil, -- how many are in the channel, as the game's channel list last said
	lockoutTicker = nil, -- tries the channel again while locked out
	guildTimes = {}, -- outbound guild message times in the last minute (their own budget)
	mutes = 0, -- how many of our joins have the invite sound muted right now (MuteInvite)
	mainCheck = nil, -- the main channel's name while we try it quietly (CheckMain), or nil
	mainCheckRefused = false, -- the game turned that try down
	mainCheckAt = nil, -- GetTime() of the last try
	mainWaitLogged = nil, -- the next try's time, once its wait has been logged
	epoch = 0, -- the server's channel pointer we're on (0: none ever came, so the main channel)
	hop = nil, -- how that pointer reached us: 0 from our own app, 1 or more by whisper; nil when unknown (saved)
	kicks = nil, -- GetTime() of our recent kicks from the main channel
}
local PREFIX = "WNTD"
local CHANNEL_BASE = "WantedNet"
-- Moving channels (from 1.4.0). Only wanteddeadordead.com picks a channel other than the main one; the Wanted app
-- passes its choice on (Catchup), and players it reached whisper it on. A whispered pointer travels at most
-- MOVE_MAX_HOPS whispers from a player whose own app delivered it: each player spreads a pointer once, when it's new.
local MOVE_MAX_HOPS = 2
local MOVE_ASK_PEERS = 5 -- players asked for the current channel at login
local MOVE_REPLY_SECONDS = 60 -- one answer per player a minute
local CHANNEL_NAME_MAX = 31
-- Message = tag ":" msgId ":" part "/" total ":" chunk; the header is at most 12 characters
local MAX_MESSAGE_LEN = 255
local CHUNK_LEN = 240
local PARTIAL_TIMEOUT = 30
local MAX_PARTIALS_PER_SENDER = 4
-- Tags
local TAG_HELLO, TAG_HAVE, TAG_NEED, TAG_LIVE, TAG_FILL = "H", "V", "N", "R", "F"
-- Enemy sightings are passing news, not records: never stored in a chain, never re-sent. They go out in
-- batches ("S"); single sightings ("E") are what the first version sent, still understood when received.
local TAG_ENEMY, TAG_SIGHTINGS = "E", "S"
-- Sent privately (addon whisper) to a player on an older version: update
local TAG_UPDATE = "U"
-- Sent privately to a posse's caller: I'm joining (Posse)
local TAG_POSSE_JOIN = "J"
-- A world PvP raid's ad (Raids): on the channel, and to realm links, whose clients share it once on theirs (fw = 1).
-- Passing news like sightings: never stored, never forwarded further. Older versions ignore it.
local TAG_RAID = "A"
local GUILD_ONLY = "@guild" -- private.Send's target for the guild's addon channel alone
-- Sent privately to a raid's leader: I'm joining (or signing up for) your raid { r = raid id } (Raids)
local TAG_RAID_JOIN = "I"
-- Sent privately to a raid's leader: who's going? { r = raid id }; and the leader's answer: { r, g = going names,
-- i = interested names (comma separated), m = how many more didn't fit } (Raids)
local TAG_RAID_WHO, TAG_RAID_ROSTER = "W", "Y"
-- The server's sync channel, or (q) a player asking for the current one: { e = epoch, n = name, a = 1 (the
-- server chose it), h = whispers since an app delivered it, q = 1 when asking }. Whispers only, never on a channel.
-- Before 1.4.0 it was { e, n, p = password } with names addons picked; those are ignored.
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
-- Messages received in a fight wait, unopened, until it's over; past this many (or this many from one player) the
-- rest are left to the resync
local MAX_DEFERRED_MESSAGES = 300
local MAX_DEFERRED_PER_SENDER = 50
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
-- AddOnMessageLockdown: the game refuses addon messages for now (in a PvP match). The part waits and goes again later.
local RESULT_LOCKDOWN = 11
local LOCKDOWN_RETRY_SECONDS = 30
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
-- The game's "no player named ..." for someone just whispered is hidden this long: it can come minutes late (seen 72 s,
-- 119 s and past 2 minutes, every name at once), and the greetings to the same player are 15 minutes apart
local NOT_FOUND_SECONDS = 10 * 60
local OFFLINE_SECONDS = 10 * 60 -- someone the game said wasn't online isn't whispered again for this long
-- The realm-link directory: players on other realm names the app names (from wanteddeadordead.com), greeted a few
-- per realm at a time until one answers
local MAX_DIRECTORY = 20
local DIRECTORY_GREETS = 3 -- names greeted per realm name each round
local DIRECTORY_SECONDS = GREET_SECONDS -- how often a round runs

---Whispers addon data to target, noting it so the game's "No player named ... is currently playing" for them is
---hidden (HideNotFound). Someone the game just said wasn't online isn't whispered again for a while.
---@return any result SendAddonMessage's result, or nil when skipped
local function Whisper(text, target)
	local off = private.offline[target]
	if off and GetTime() - off < OFFLINE_SECONDS then
		return nil
	end
	private.whispered[target] = GetTime()
	return C_ChatInfo.SendAddonMessage(PREFIX, text, "WHISPER", target)
end

-- Locked out of the channel (an owner banned us or set a password): sync goes on by whisper links to the
-- players last heard on it, and joining is tried again now and then (a passworded channel is gone once its last
-- member leaves, and the next joiner makes it afresh without one)
local MAX_RECENT_PEERS = 20
local RECENT_PEER_SECONDS = 7 * 24 * 60 * 60
local LOCKOUT_RETRY_SECONDS = 5 * 60
-- Locked out and in a guild: what would go on the channel goes to the guild instead (same messages, same checks
-- when received), on its own budget. Never while the channel works, so nothing is sent twice.
local MAX_GUILD_PARTS_PER_MINUTE = 20
local MEMBERS_INTERVAL = 5 * 60 -- how often the game is asked for the channel's member count
local MEMBERS_RETRY_SECONDS, MEMBERS_ATTEMPTS = 10, 6 -- when the channel isn't in the game's list yet
local MEMBERS_ASK_SECONDS = 10 -- at most one member list request this often
-- A refused join makes the game ask for the password in a box (CHAT_CHANNEL_PASSWORD) that plays the party-invite
-- sound, SOUNDKIT.IG_PLAYER_INVITE (kit 880). That kit's one file is FileDataID 567451, sound/interface/iplayerinvitea.ogg
-- (wago.tools SoundKitEntry, SoundKitID 880, read 2026-10-01). It's muted for a few seconds around our own joins, and
-- for a while at login, when the game rejoins the channels it remembers.
local INVITE_SOUND_FILE = 567451
local INVITE_MUTE_SECONDS = 5
local LOGIN_MUTE_SECONDS = 20
-- While the main channel turns us away, or we're on the server's channel, the main one is tried again quietly
-- (CheckMain), out of fights and instances: after 5 minutes, then twice as long after each refusal, up to 25 minutes (the server counts a report for 30).
-- Let in, the wait is back to 5 minutes.
local MAIN_TICK_SECONDS = 60
local MAIN_RETRY_SECONDS = 5 * 60
local MAIN_MAX_WAIT_SECONDS = 25 * 60
local MAIN_ANSWER_SECONDS = 5 -- how long the game has to let us in
local MAIN_SETTLE_SECONDS = 5 -- then how long we stay in before believing it (a moderated channel says so)
local MAIN_QUIET_SECONDS = 30 -- the main channel's notices are hidden this long after a try
-- Kicked from the main channel this many times this close together: it's turning us away
local KICKS_REFUSED, KICKS_SECONDS = 2, 10 * 60
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
	private.channelName, private.epoch = private.MainName(), 0
	-- The channel wanteddeadordead.com last pointed everyone to, if it ever did
	local pointer = Wanted.db.syncChannel
	if type(pointer) == "table" and private.ValidPointer(pointer) then
		private.channelName, private.epoch = pointer.n, pointer.e
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
	private.frame:RegisterEvent("PLAYER_LOGOUT")
	private.frame:SetScript("OnEvent", Wanted:Timed("Sync events", private.OnEvent))
	-- Every kind of our own record is shared (a fixed list once left out links and assists)
	Store:OnRecord("*", private.OnOwnRecord)
	-- What a fight held back goes once it's over
	Wanted:OnCombatEnd(function()
		private.FlushLive()
		private.FlushForward()
		private.Drain()
	end)
	-- The game rejoins the channels it remembers at login, and its box asking for a password plays the invite sound
	private.MuteInvite(LOGIN_MUTE_SECONDS)
	-- Channels are joined a little after login, so wait before trying
	C_Timer.After(5, private.TryJoin)
	C_Timer.After(5, private.LeaveOldChannel)
	-- The main channel, tried again while it turns us away or we're on the server's channel
	C_Timer.NewTicker(MAIN_TICK_SECONDS, private.CheckMain)
	-- Realm links
	Store:OnRecord("*", private.OnAnyRecord)
	C_Timer.NewTicker(LINK_HAVE_SECONDS, private.LinkTick)
	C_Timer.After(15, private.GreetRemembered)
	C_Timer.After(20, function() Sync:GreetDirectory() end)
	C_Timer.NewTicker(DIRECTORY_SECONDS, function() Sync:GreetDirectory() end)
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
	-- Our quiet try of the main channel (CheckMain)
	if type(baseName) == "string" and private.mainCheckAt and GetTime() - private.mainCheckAt < MAIN_QUIET_SECONDS
		and strlower(baseName) == strlower(private.MainName()) then
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
	return format("Sync: channel %s (%s%s), %d peers in the last 10 min (%d on other realms by whisper); sent %d, received %d (%d own echoes), merged %d, invalid %d, dropped %d, throttled %d, repeats skipped %d%s%s.", private.channelName or "?", private.channelId and ("#"..private.channelId) or "not joined", members and format(", %d in it", members) or "", numPeers, numLinks, private.stats.sent, private.stats.received, private.stats.echoed, private.stats.merged, private.stats.invalid, private.stats.dropped, private.stats.throttled, private.stats.skipped, now < private.pausedUntil and " PAUSED" or "", private.ViaGuild() and "; locked out, sending to the guild" or "")
end

---Whether any of the values is one the game keeps secret from addons (chat text in a PvP match).
function private.AnySecret(...)
	if not issecretvalue then
		return false
	end
	for i = 1, select("#", ...) do
		if issecretvalue((select(i, ...))) then
			return true
		end
	end
	return false
end

function private.OnEvent(_, event, ...)
	if (event == "CHAT_MSG_ADDON" or event == "CHAT_MSG_SYSTEM" or event == "CHAT_MSG_CHANNEL_NOTICE" or event == "CHAT_MSG_CHANNEL_NOTICE_USER")
		and private.AnySecret(...) then
		return
	end
	if event == "CHAT_MSG_ADDON" then
		private.OnAddonMessage(...)
	elseif event == "PLAYER_ENTERING_WORLD" then
		-- A zone change or reload can drop the channel id
		private.channelId = nil
		private.joinAttempts = 0
		if Wanted:InPvPMatch() then
			-- Addon messages are blocked in a battleground: out of the channel until we leave, then the hello resyncs
			Wanted:Log("Sync: in a PvP match; paused until we leave")
			return
		end
		C_Timer.After(5, private.TryJoin)
	elseif event == "CHANNEL_PASSWORD_REQUEST" then
		private.OnPasswordRequest(...)
	elseif event == "PLAYER_LOGOUT" then
		private.UnmuteAll()
	elseif event == "CHAT_MSG_SYSTEM" then
		private.OnSystemMessage(...)
	elseif event == "CHAT_MSG_CHANNEL_NOTICE" or event == "CHAT_MSG_CHANNEL_NOTICE_USER" then
		private.OnChannelNotice(event, ...)
	elseif event == "CHANNEL_COUNT_UPDATE" then
		private.ReadMembers(...)
	elseif event == "CHAT_MSG_CHANNEL_LIST" then
		private.OnChannelList(...)
	elseif event == "CHANNEL_UI_UPDATE" then
		-- The list changed (a join, a leave, the login rejoin): once it settles, put the sync channel back at the end
		if private.channelId and not private.movePending then
			private.movePending = true
			C_Timer.After(1, function()
				private.movePending = nil
				private.MoveToEnd()
			end)
		end
		-- The game (re)built its channel list: ask once it settles, if the count isn't known yet. It fires many
		-- times at login, so whether it's known is asked again when the timer runs (2026-10-01 log: seven requests
		-- in a second, after the count had come)
		if private.channelId and not private.members then
			C_Timer.After(2, function()
				if not private.members then
					private.RequestMembers()
				end
			end)
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

---Moves the sync channel to the end of the channel list. The game numbers channels in the order they're joined,
---so a sync channel joined first took /1 and pushed General and Trade down (player report, 2026-10-05). It goes
---one slot at a time, as the chat settings' Move Down does, so the other channels keep their order and colours.
function private.MoveToEnd()
	local id = private.CurrentChannelId()
	if not id or not GetChannelList or not C_ChatInfo.SwapChatChannelsByChannelIndex then
		return
	end
	local list, last = { GetChannelList() }, id
	for i = 1, #list, 3 do
		if type(list[i]) == "number" and list[i] > last then
			last = list[i]
		end
	end
	for i = id, last - 1 do
		if ChatTypeInfo then
			local a, b = "CHANNEL"..i, "CHANNEL"..(i + 1)
			ChatTypeInfo[a], ChatTypeInfo[b] = ChatTypeInfo[b], ChatTypeInfo[a]
		end
		C_ChatInfo.SwapChatChannelsByChannelIndex(i, i + 1)
	end
	if last > id then
		Wanted:Log("Sync: moved %s from #%d to the end of the channel list (#%d)", private.channelName, id, last)
		private.channelId = last
	end
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
	if private.membersAskedAt and GetTime() - private.membersAskedAt < MEMBERS_ASK_SECONDS then
		return
	end
	private.membersAskedAt = GetTime()
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
---ban, password or moderate it; the game names who did what, so it's said in chat and logged. A kick is undone by
---rejoining; a ban, a password or moderation turns us away (Refused), and sync goes on by whisper.
function private.OnChannelNotice(event, kind, player, _, _, actor, _, _, _, baseName)
	if private.mainCheck and type(baseName) == "string" and strlower(baseName) == strlower(private.mainCheck) then
		-- Our quiet try of the main channel: only whether it let us in, and isn't moderated, matters (CheckMain)
		if kind == "WRONG_PASSWORD" or kind == "BANNED" or kind == "MODERATION_ON" then
			private.mainCheckRefused = true
			if kind == "MODERATION_ON" and private.channelName == private.mainCheck then
				-- Still in it, but moderated: we wait for moderation to go off
				private.moderated = true
			end
		end
		return
	end
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
			if private.RepeatedKick() then
				private.Refused("we were kicked again and again")
			else
				private.Rejoin("kicked")
			end
		elseif kind == "PLAYER_BANNED" and isUs then
			private.Refused("we were banned")
		elseif kind == "PASSWORD_CHANGED" then
			-- We're still in, but nobody else gets in without the password
			private.MarkFollowed(false, "a password was set")
		elseif kind == "MODERATION_ON" then
			-- Only moderators can send now: every message would be refused. Sync by whisper until it's off
			private.moderated = true
			private.Refused("moderation is on")
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
		private.Refused("banned")
	elseif kind == "WRONG_PASSWORD" then
		-- We join without a password (from 1.4.0): the channel has one now
		private.Refused("it has a password now")
	end
end

---Notes a kick from the sync channel; true once they come too often to be a one-off.
---@return boolean
function private.RepeatedKick()
	local now = GetTime()
	local recent = {}
	for _, t in ipairs(private.kicks or {}) do
		if now - t < KICKS_SECONDS then
			recent[#recent + 1] = t
		end
	end
	recent[#recent + 1] = now
	private.kicks = recent
	return #recent >= KICKS_REFUSED
end

---The channel we follow turned us away (the main one, or the server's). It's marked refused for the Wanted app to
---report, and tried again: the main one now and then (CheckMain), the server's every few minutes (LockOut). The
---addon never picks another channel itself; it waits for the server's.
function private.Refused(why)
	private.MarkFollowed(false, why)
	if private.channelName == private.MainName() then
		Wanted.db.homeCheck.tried = GetServerTime()
	end
	private.LockOut(why)
end

---Notes what the channel we follow did, for the Wanted app to pass to wanteddeadordead.com
---(WantedDB.syncChannelState): mainRefused is whether it turned us away, main channel or the server's (the name is
---from when only the main one was reported); epoch says which, the epoch of the server's pointer we follow (0: none).
---On the main channel, mainOpen goes with it.
---@param open boolean
---@param why string?
function private.MarkFollowed(open, why)
	local mainOpen = nil
	if private.channelName == private.MainName() then
		mainOpen = open
	end
	private.MarkState(not open, mainOpen, why)
end

---Notes whether the main channel lets us in, while we follow the server's (CheckMain), or on it (MarkFollowed).
---@param open boolean
---@param why string?
function private.MarkMain(open, why)
	if private.channelName == private.MainName() then
		private.MarkFollowed(open, why)
	else
		private.MarkState(nil, open, why)
	end
end

---Sets syncChannelState's flags (nil leaves one as it is), when we last saw them so (the server counts only recent
---reports) and the epoch we follow.
---@param refused boolean?
---@param mainOpen boolean?
---@param why string?
function private.MarkState(refused, mainOpen, why)
	local state = Wanted.db.syncChannelState
	if refused ~= nil and state.mainRefused ~= refused then
		Wanted:Log("%sSync: %s %s%s", refused and "!! " or "", private.channelName, refused and "turns us away" or "lets us in", why and (" ("..why..")") or "")
	end
	if mainOpen ~= nil and state.mainOpen ~= mainOpen then
		Wanted:Log("Sync: the main channel %s%s", mainOpen and "lets us in" or "turns us away", why and (" ("..why..")") or "")
	end
	if refused ~= nil then
		state.mainRefused = refused
	end
	if mainOpen ~= nil then
		state.mainOpen = mainOpen
	end
	state.at, state.epoch = GetServerTime(), private.epoch
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
	local onMain = private.channelName == private.MainName()
	Wanted:Print("Wanted can't get into its sync channel (%s). It keeps syncing by whisper with players seen there, and tries the channel again every few minutes.%s",
		why, onMain and " If it stays shut, wanteddeadordead.com picks a new channel and the Wanted app brings it." or "")
	if onMain and Wanted:AppVersion() then
		-- The app reads the saved data, which the game writes only at logout or /reload
		Wanted:Print("A /reload lets your Wanted app report it right away.")
	end
	private.GreetRecentPeers()
	if private.ViaGuild() then
		Wanted:Log("Sync: locked out; channel messages go to the guild until we're back")
		private.SendHello()
	end
	-- The main channel is tried again by CheckMain, with its own wait
	if not onMain and not private.lockoutTicker then
		private.lockoutTicker = C_Timer.NewTicker(LOCKOUT_RETRY_SECONDS, function()
			if private.lockedOut then
				private.joinAttempts = 0
				private.TryJoin()
			end
		end)
	end
end

---Whether channel messages go to the guild instead: locked out of the channel (not the moment's rejoin after a
---loading screen), in a guild, and not in a PvP match.
---@return boolean
function private.ViaGuild()
	return not private.channelId and private.lockedOut ~= nil and IsInGuild() and not Wanted:InPvPMatch()
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

---The game asks for a channel's password when a join is turned down; its box plays the invite sound and is closed.
---Wanted joins without a password (from 1.4.0), so for the sync channel it means the channel has one now; for our
---try of the main channel (CheckMain), that the try failed. A channel 1.3.x used (WantedNet<Side><letters>, with a
---password) that the game rejoins at login is left.
function private.OnPasswordRequest(channel)
	if type(channel) ~= "string" then
		return
	end
	local lower = strlower(channel)
	if private.mainCheck and lower == strlower(private.mainCheck) then
		private.mainCheckRefused = true
		private.HidePasswordBox(channel)
		return
	end
	if lower == strlower(private.channelName or "") then
		Wanted:Log("Sync: the game asked for the %s password: it has one now", channel)
		private.HidePasswordBox(channel)
		private.Refused("it has a password now")
		return
	end
	if strfind(lower, "^"..strlower(CHANNEL_BASE)) then
		Wanted:Log("Sync: the game asked for the password of %s, not our sync channel now; leaving it", channel)
		if lower == strlower(private.MainName()) then
			private.MarkMain(false, "it has a password")
		end
		private.HidePasswordBox(channel)
		if LeaveChannelByName then
			LeaveChannelByName(channel)
		end
	end
end

---Leaves, once, the channel 1.3.x had moved to (saved by the 1.4.0 migration), if the game rejoined it at login.
function private.LeaveOldChannel()
	local old = Wanted.db.oldSyncChannel
	Wanted.db.oldSyncChannel = nil
	if type(old) ~= "string" or strlower(old) == strlower(private.channelName) then
		return
	end
	local id = GetChannelName(old)
	if id and id ~= 0 and LeaveChannelByName then
		Wanted:Log("Sync: leaving %s, the channel 1.3.x had moved to", old)
		LeaveChannelByName(old)
	end
end

---Closes the game's password box for one channel, next frame (the game's handler shows it after ours runs). The
---box is matched by its data, the channel's name as the game gave it, so a box for another channel stays.
function private.HidePasswordBox(channel)
	C_Timer.After(0, function()
		if StaticPopup_Hide then
			StaticPopup_Hide("CHAT_CHANNEL_PASSWORD", channel)
		end
	end)
end

---Mutes the party-invite sound for a while (see INVITE_SOUND_FILE). Mutes overlap: the sound comes back only when
---the last one ends. Nothing in the player's settings changes.
function private.MuteInvite(seconds)
	if not MuteSoundFile or not UnmuteSoundFile then
		return
	end
	if private.mutes == 0 then
		MuteSoundFile(INVITE_SOUND_FILE)
	end
	private.mutes = private.mutes + 1
	C_Timer.After(seconds or INVITE_MUTE_SECONDS, private.UnmuteInvite)
end

function private.UnmuteInvite()
	if private.mutes == 0 then
		return
	end
	private.mutes = private.mutes - 1
	if private.mutes == 0 then
		UnmuteSoundFile(INVITE_SOUND_FILE)
	end
end

---Logging out or reloading: the timers that would unmute won't run, so the sound comes back now.
function private.UnmuteAll()
	if private.mutes > 0 then
		private.mutes = 0
		UnmuteSoundFile(INVITE_SOUND_FILE)
	end
end

---Joins a channel, without a password, with the invite sound muted in case the game turns us down and asks for one.
function private.Join(name)
	private.MuteInvite()
	JoinPermanentChannel(name)
end



-- ============================================================================
-- Channel
-- ============================================================================

function private.TryJoin()
	if private.channelId or Wanted:InPvPMatch() then
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
			-- call, joining once by hand (/join <name>) is enough for good.
			private.Join(private.channelName)
		elseif private.joinAttempts == 3 then
			Wanted:Print("Not in the sync channel yet. If it never joins, type once: /join %s", private.channelName)
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
	private.MarkFollowed(true)
	private.MoveToEnd()
	if private.channelName == private.MainName() then
		Wanted.db.homeCheck.wait = MAIN_RETRY_SECONDS
	end
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

---Sends a table as one or more addon messages, on the channel (the guild while locked out of it) or to one player
---by whisper (a realm link). Returns whether it was sent.
---@param tag string
---@param tbl table
---@param attempt number? how many times the game has throttled it already
---@param target string? a player to whisper instead of the channel
---@return boolean
function private.Send(tag, tbl, attempt, target)
	-- GUILD_ONLY: the guild's addon channel, whether or not we're on the sync channel
	local guildOnly = target == GUILD_ONLY
	if guildOnly then
		if not IsInGuild() then
			return false
		end
		target = nil
	end
	local viaGuild = guildOnly or (not target and private.ViaGuild())
	if not target and not private.channelId and not viaGuild then
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
		private.Drop("paused", 1)
		return false
	end
	local payload = Encode(tbl)
	local total = ceil(#payload / CHUNK_LEN)
	Wanted:Log("Sync: send %s%s, %d bytes in %d part(s)", tag, target and (" to "..target) or viaGuild and " to the guild" or "", #payload, total)
	if viaGuild then
		PruneTimes(private.guildTimes, now)
		if #private.guildTimes + total > MAX_GUILD_PARTS_PER_MINUTE then
			Wanted:Log("!! Sync: guild budget reached, dropping %s (the next resync picks it up)", tag)
			private.Drop("guild budget", 1)
			return false
		end
	elseif target then
		PruneTimes(private.linkTimes, now)
		if #private.linkTimes + total > MAX_LINK_PARTS_PER_MINUTE then
			Wanted:Log("!! Sync: realm link budget reached, holding %s to %s (the next resync picks it up)", tag, target)
			private.Drop("realm link budget", 1)
			return false
		end
	elseif isSighting then
		PruneTimes(private.sightingTimes, now)
		if #private.sightingTimes + total > MAX_SIGHTING_MESSAGES_PER_MINUTE then
			Wanted:Log("Sync: sighting budget reached, dropping a batch")
			private.Drop("sighting budget", 1)
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
	if viaGuild then
		-- Guild messages come back to us too
		private.ownMessages[tag..":"..msgId] = now
		for part = 1, total do
			local result = C_ChatInfo.SendAddonMessage(PREFIX, parts[part], "GUILD")
			Wanted:Log("Sync: SendAddonMessage part %d/%d of %s to the guild -> %s", part, total, tag, tostring(result))
			if RESULT_THROTTLED[result] or result == RESULT_LOCKDOWN then
				private.stats.throttled = private.stats.throttled + 1
				private.QueueRetry(tag, tbl, attempt, guildOnly and GUILD_ONLY or nil)
				return false
			end
			tinsert(private.guildTimes, now)
			private.stats.sent = private.stats.sent + 1
		end
		return true
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
		local result = Whisper(parts[part], target)
		Wanted:Log("Sync: SendAddonMessage part %d/%d to %s -> %s", part, total, target, tostring(result))
		if RESULT_THROTTLED[result] or result == RESULT_LOCKDOWN then
			private.stats.throttled = private.stats.throttled + 1
			Wanted:Log("!! Sync: refused by the game (%s) at part %d/%d of %s to %s", tostring(result), part, total, tag, target)
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
	private.Drop("send queue full", 1)
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
			private.Drop("left the channel", #outbox)
			wipe(outbox)
			private.outboxParts = 0
			return
		elseif item.tag == TAG_SIGHTINGS and item.next == 1 and now - item.queued > SIGHTING_QUEUE_SECONDS then
			tremove(outbox, at)
			private.outboxParts = private.outboxParts - #item.parts
			private.Drop("stale sightings", 1)
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
				private.Drop("no channel number", #outbox)
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
			elseif result == RESULT_LOCKDOWN then
				-- The game refuses addon messages for now: not sent, and not counted against the part
				Wanted:Log("!! Sync: addon messages locked down (%s) at part %d/%d of %s", tostring(result), part, total, item.tag)
				wait = LOCKDOWN_RETRY_SECONDS
			elseif RESULT_THROTTLED[result] then
				-- Something else used up the game's allowance (another addon, or chat): wait, then send this part again
				private.stats.throttled = private.stats.throttled + 1
				item.refusals = item.refusals + 1
				Wanted:Log("!! Sync: throttled by the game (%s) at part %d/%d of %s", tostring(result), part, total, item.tag)
				if item.refusals > MAX_RETRIES then
					tremove(outbox, at)
					private.outboxParts = private.outboxParts - (total - part + 1)
					private.Drop("throttled too often", 1)
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

---Counts n messages dropped (not sent, or not taken in) for reason, for /wanted bug.
---@param reason string
---@param n number
function private.Drop(reason, n)
	private.stats.dropped = private.stats.dropped + n
	private.dropReasons[reason] = (private.dropReasons[reason] or 0) + n
end

---Why messages were dropped, most first: "sighting budget 120, stale sightings 30", or "" for none.
---@return string
function Sync:DropReasons()
	local list = {}
	for reason, n in pairs(private.dropReasons) do
		tinsert(list, { reason = reason, n = n })
	end
	sort(list, function(a, b) return a.n > b.n or (a.n == b.n and a.reason < b.reason) end)
	local parts = {}
	for i = 1, min(#list, 5) do
		parts[i] = list[i].reason.." "..list[i].n
	end
	return table.concat(parts, ", ")
end

---Sends a throttled message again in a few seconds, up to a few times.
function private.QueueRetry(tag, tbl, attempt, target)
	attempt = (attempt or 0) + 1
	if attempt > MAX_RETRIES or #private.retryQueue >= MAX_RETRY_QUEUE then
		private.Drop("retries used up", 1)
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
	if #list == 0 or (not private.channelId and not private.ViaGuild()) then
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
		if chain.seq > Store:SeqBase() and (origin == own or Store:GetLastActive(origin) >= cutoff) then
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

---A hello's fields: what we hold, our version, and our Blizzard PvP rank and its season when we have one.
function private.HelloFields()
	local fields = { c = private.GetHaveTable(), v = Wanted.VERSION }
	if Wanted.BlizzRank then
		fields.b, fields.bs = Wanted.BlizzRank:Mine()
	end
	return fields
end

function private.SendHello()
	private.Send(TAG_HELLO, private.HelloFields())
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
			Wanted:NoteVersion(tbl.v, sender)
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
	-- A join for a raid we lead
	if channel == "WHISPER" and strsub(text, 1, 2) == TAG_RAID_JOIN..":" then
		local payload = strmatch(text, "^%u:%w+:%d+/%d+:(.*)$")
		local tbl = payload and Decode(payload)
		if type(tbl) == "table" and Wanted.Raids then
			Wanted.Raids:OnJoin(sender, tbl)
		end
		return
	end
	-- Who's going to a raid we lead, and a leader's answer
	if channel == "WHISPER" and (strsub(text, 1, 2) == TAG_RAID_WHO..":" or strsub(text, 1, 2) == TAG_RAID_ROSTER..":") then
		local payload = strmatch(text, "^%u:%w+:%d+/%d+:(.*)$")
		local tbl = payload and Decode(payload)
		if type(tbl) == "table" and Wanted.Raids then
			if strsub(text, 1, 1) == TAG_RAID_WHO then
				Wanted.Raids:OnWho(sender, tbl)
			else
				Wanted.Raids:OnRoster(sender, tbl)
			end
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
	-- Whispers carry realm links (players on another realm name); anything else must be our channel, or the guild
	-- (guildmates locked out of the channel send there, and are taken like the channel)
	local viaLink = channel == "WHISPER"
	if not viaLink then
		if channel ~= "CHANNEL" and channel ~= "GUILD" then
			return
		end
		if channel == "CHANNEL" and channelName and channelName ~= "" and strlower(channelName) ~= strlower(private.channelName) then
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
	Wanted:Log("Sync: received %d bytes from %s%s %s", #text, sender, isSelf and " (self)" or "", viaLink and "by whisper" or channel == "GUILD" and "in the guild" or ("on "..tostring(channelName)))
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
			-- One player holds only a few messages open at once (ours interleave two at most)
			if private.OpenPartials(sender, now) >= MAX_PARTIALS_PER_SENDER then
				private.Drop("too many open messages", 1)
				return
			end
			partial = { sender = sender, parts = {}, total = total, t = now, count = 0 }
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
		-- Each player only gets a share of the room, so one flooding can't crowd out everyone else
		local waiting = private.deferred[sender] or 0
		if Wanted:QueuedWork() >= MAX_DEFERRED_MESSAGES or waiting >= MAX_DEFERRED_PER_SENDER then
			-- The next resync asks again for anything this leaves out
			private.Drop("busy in combat", 1)
			return
		end
		private.deferred[sender] = waiting + 1
		Wanted:QueueWork(function()
			private.deferred[sender] = (private.deferred[sender] or 1) > 1 and private.deferred[sender] - 1 or nil
			private.Process(tag, payload, sender, viaLink, channel)
		end)
		return
	end
	private.Process(tag, payload, sender, viaLink, channel)
end

---How many messages a sender has part sent, letting go of every message whose parts stopped coming.
function private.OpenPartials(sender, now)
	local open = 0
	for key, partial in pairs(private.partial) do
		if now - partial.t > PARTIAL_TIMEOUT then
			private.partial[key] = nil
		elseif partial.sender == sender then
			open = open + 1
		end
	end
	return open
end

---Decodes and handles one whole message.
function private.Process(tag, payload, sender, viaLink, channel)
	local tbl = Decode(payload)
	if type(tbl) ~= "table" then
		private.stats.invalid = private.stats.invalid + 1
		Wanted:Log("!! Sync: could not decode a %s message from %s", tag, sender)
		return
	end
	Wanted:Log("Sync: handling %s from %s%s", tag, sender, viaLink and " (realm link)" or "")
	private.HandleMessage(tag, tbl, sender, viaLink, channel)
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
	Whisper(text, sender)
	Wanted:Log("Sync: told %s to update", tostring(sender))
end

---channel is how it came: "CHANNEL", "GUILD" or "WHISPER" (a realm link).
function private.HandleMessage(tag, tbl, sender, viaLink, channel)
	-- The newest release wins: a newer one may lock this client (Core); an older one's news is ignored. A
	-- development build is not a release, so it neither locks others nor turns them away.
	Wanted:NoteVersion(tbl.v, sender)
	Store:NoteAddonVersion(sender, tbl.v)
	-- Their Blizzard PvP rank, in a hello (from 1.10.0)
	if tbl.b and Wanted.BlizzRank then
		Wanted.BlizzRank:Note(sender, tbl.b, tbl.bs)
	end
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
	if tag == TAG_RAID then
		local taken = Wanted.Raids and Wanted.Raids:OnAd(tbl, sender, channel)
		-- One a realm link sent of its own raid goes on our channel once, so players on this realm name see it too:
		-- never one from a stranger, one already shared on, or one the raids didn't take
		if taken and viaLink and private.links[sender] and tbl.fw == nil and not tbl.x and private.channelId then
			tbl.fw = 1
			private.Send(TAG_RAID, tbl)
		end
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
	-- Only chains we hold, from a whole seq, and no more chains than a request asks for (HandleHave): every answer
	-- walks an origin's records and sends them
	local wanted, asked = {}, {}
	local maxNeed = viaLink and MAX_NEED_ORIGINS_LINK or 5
	for origin, fromSeq in pairs(need) do
		if type(origin) == "string" and type(fromSeq) == "number" and fromSeq == floor(fromSeq) and fromSeq >= 1
			and Wanted.db.chains[origin] and Store:GetChainSeq(origin) >= fromSeq then
			wanted[origin] = floor(fromSeq)
			tinsert(asked, origin.." from "..fromSeq)
			if #asked >= maxNeed then
				break
			end
		end
	end
	Wanted:Log("Sync: %s asks for %s", sender, table.concat(asked, ", "))
	need = wanted
	if viaLink then
		for origin, fromSeq in pairs(need) do
			private.SendFill(origin, fromSeq, sender)
		end
		return
	end
	for origin, fromSeq in pairs(need) do
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

---Sends an origin's records from a seq on, on the channel or to one player. Every kind: notices and proofs
---too, which the first list here left out.
function private.SendFill(origin, fromSeq, target)
	local records = {}
	local lowest = Store:GetChainSeq(origin) + 1
	for record in Store:OriginIterator(origin) do
		if type(record.seq) == "number" and not Store:IsTest(record) then
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

---Shares a raid's ad: on the channel, and to each realm link (whose clients share it on theirs).
---@param ad table
function Sync:SendRaidAd(ad)
	-- A guild-only raid goes to the guild alone
	if ad.x then
		private.Send(TAG_RAID, ad, nil, GUILD_ONLY)
		return
	end
	private.Send(TAG_RAID, ad)
	for name in pairs(private.links) do
		private.Send(TAG_RAID, ad, nil, name)
	end
end

---Asks a raid's leader to invite us, or signs us up for a raid that hasn't started: kind "g" going, "i" interested,
---"x" taken back.
---@param leader string
---@param raidId string
---@param kind string?
function Sync:SendRaidJoin(leader, raidId, kind)
	return private.Send(TAG_RAID_JOIN, { r = raidId, k = kind }, nil, leader)
end

---Asks a raid's leader who's going.
---@param leader string
---@param raidId string
function Sync:SendRaidWho(leader, raidId)
	return private.Send(TAG_RAID_WHO, { r = raidId }, nil, leader)
end

---Answers who's going to the raid we lead: { r, g, i, m }.
---@param to string
---@param roster table
function Sync:SendRaidRoster(to, roster)
	return private.Send(TAG_RAID_ROSTER, roster, nil, to)
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

---Keeps the players on other realm names the app passed on (the catch-up's links: { n = name, r = realm, t }),
---newest first. Anything malformed, on our own realm or ourselves is dropped. None (an older app) keeps the list.
---@param list table?
function Sync:TakeDirectory(list)
	if type(list) ~= "table" then
		return
	end
	local kept, me = {}, Store:GetOrigin()
	for _, entry in ipairs(list) do
		local name, realm = type(entry) == "table" and entry.n, type(entry) == "table" and entry.r
		if type(name) == "string" and type(realm) == "string" and name ~= "" and #name <= 48 and realm ~= "" and #realm <= 64
			and not strfind(name, "|", 1, true) and not strfind(realm, "|", 1, true) and name ~= me and not Sync:IsOwnRealm(realm) then
			tinsert(kept, { name = name, realm = realm })
			if #kept >= MAX_DIRECTORY then
				break
			end
		end
	end
	private.directory = kept
	Wanted:Log("Sync: %d realm-link names from the app", #kept)
end

---The realm names (normalized) with a live realm link now.
function private.LinkedRealms()
	local now, realms = GetTime(), {}
	for _, link in pairs(private.links) do
		local realm = NormalizeRealm(link.realm)
		if realm and now - (link.heard or 0) < LINK_TIMEOUT then
			realms[realm] = true
		end
	end
	return realms
end

---One round of the directory: for each realm name with no live link, greet the next few names not greeted lately
---(nor said to be offline). The first to answer makes the link, and that realm is left alone while it lasts.
function Sync:GreetDirectory()
	if Wanted:InCombat() or #private.directory == 0 then
		return
	end
	local now, linked, greets = GetTime(), private.LinkedRealms(), {}
	for _, entry in ipairs(private.directory) do
		local realm = NormalizeRealm(entry.realm)
		local recent = private.greeted[entry.name] and now - private.greeted[entry.name] < GREET_SECONDS
		local offline = private.offline[entry.name] and now - private.offline[entry.name] < OFFLINE_SECONDS
		if not linked[realm] and (greets[realm] or 0) < DIRECTORY_GREETS and not recent and not offline then
			greets[realm] = (greets[realm] or 0) + 1
			Sync:Greet(entry.name, entry.realm)
		end
	end
end

---How the directory is doing: names held, and how many of their realm names have a live link.
---@return table { names, realms, linked }
function Sync:GetDirectory()
	local linked, realms, out = private.LinkedRealms(), {}, { names = #private.directory, realms = 0, linked = 0 }
	for _, entry in ipairs(private.directory) do
		local realm = NormalizeRealm(entry.realm)
		if not realms[realm] then
			realms[realm] = true
			out.realms = out.realms + 1
			out.linked = out.linked + (linked[realm] and 1 or 0)
		end
	end
	return out
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
	for _, names in ipairs({ private.greeted, private.endedLinks, private.whispered }) do
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
	if name then
		-- The game says it once per message part: log it once
		local before = private.offline[name]
		private.offline[name] = GetTime()
		if not private.links[name] and not (before and GetTime() - before < NOT_FOUND_SECONDS) then
			Wanted:Log("Sync: %s isn't online (the game says)", name)
		end
	end
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
	if private.Send(TAG_HELLO, private.HelloFields()) then
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
-- The sync channel is an ordinary custom channel: whoever owns it can moderate, ban or password it, and its name is
-- in this public code. The main channel, WantedNet<Side>, has no password. When it turns us away, the addon marks
-- it refused (WantedDB.syncChannelState), keeps trying it, and waits: the Wanted app reports it to
-- wanteddeadordead.com, which alone picks another channel (no password, a higher epoch) once two accounts say so,
-- and points everyone back to the main one once it's open again. The app brings the server's pointer in its
-- catch-up (Catchup); the addon follows it and whispers it to the players it knows, so those without the app follow
-- too. WantedDB.syncChannel keeps it. An addon never picks a channel itself, and never follows one another addon
-- made up (1.3.x moves, with a password, are ignored).

---The main sync channel's name for this side.
---@return string
function private.MainName()
	return CHANNEL_BASE..(private.faction or "")
end

---Whether a pointer is one the server could have sent: an epoch, and the main channel or a name on this side, with
---no password (a pointer with one is from before 1.4.0).
function private.ValidPointer(p)
	local main = private.MainName()
	return type(p) == "table" and p.p == nil and type(p.e) == "number" and p.e >= 1 and p.e == floor(p.e) and p.e < 100000
		and type(p.n) == "string" and #p.n <= CHANNEL_NAME_MAX and (p.n == main or strfind(p.n, "^"..main.."%w+$") ~= nil)
end

---Moves to the server's channel (or back to the main one): leaves the old one, joins the new, and tells the players
---we know unless the pointer has already gone as far by whisper as it may. Followed when its epoch is newer than ours;
---from our own app, also at the same epoch with another name (the server's word).
---@param pointer table { e, n }
---@param why string
---@param hop number 0 from our own app, else how many whispers it took
---@return boolean moved
function private.Adopt(pointer, why, hop)
	if not private.ValidPointer(pointer) or pointer.e < private.epoch
		or (pointer.e == private.epoch and (hop > 0 or pointer.n == private.channelName)) then
		return false
	end
	local old = private.channelName
	private.channelName, private.epoch, private.hop = pointer.n, pointer.e, hop
	Wanted.db.syncChannel = { e = pointer.e, n = pointer.n, t = GetServerTime() }
	if old ~= pointer.n then
		if pointer.n == private.MainName() then
			Wanted:Print("Wanted's sync channel is back to the main one, as wanteddeadordead.com says.")
		else
			Wanted:Print("Wanted's sync channel moved to %s, chosen by wanteddeadordead.com while the main one turns players away.", pointer.n)
		end
	end
	Wanted:Log("Sync: moving from %s to %s (%d), %s", old, pointer.n, pointer.e, why)
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
	if hop < MOVE_MAX_HOPS then
		private.SpreadMove(hop + 1)
	end
	return true
end

---Tries the main channel again, quietly, while it turns us away or we're on the server's channel. On the main
---channel, being let in brings sync back there; on the server's, it's only reported (the server decides when
---everyone goes back), and the main channel is left again.
function private.CheckMain()
	local main, state, now = private.MainName(), Wanted.db.homeCheck, GetServerTime()
	if private.mainCheck or Wanted:InPvPMatch() then
		return
	end
	if private.channelName == main and (private.channelId or not private.lockedOut) then
		-- In it, or joining it the usual way (TryJoin)
		return
	end
	if now - state.tried < state.wait then
		-- Said once per wait, not every tick
		local nextTry = state.tried + state.wait
		if private.mainWaitLogged ~= nextTry then
			private.mainWaitLogged = nextTry
			Wanted:Log("Sync: next try of %s at %s (every %d min)", main, date("%H:%M", nextTry), state.wait / 60)
		end
		return
	end
	if Wanted:InCombat() or IsInInstance() then
		return
	end
	local id = GetChannelName(main)
	if id and id ~= 0 then
		if private.channelName == main then
			-- Still in it. Moderated, moderation going off brings us back (OnChannelNotice); otherwise sync on it
			if not private.moderated then
				private.joinAttempts = 0
				private.TryJoin()
			end
			return
		end
		-- Still in it from before: being in says nothing about a password. Out now, tried next time
		Wanted:Log("Sync: still in %s from before; leaving it", main)
		if LeaveChannelByName then
			LeaveChannelByName(main)
		end
		return
	end
	private.mainCheck, private.mainCheckRefused, private.mainCheckAt = main, false, GetTime()
	state.tried = now
	Wanted:Log("Sync: on %s (%d); trying %s again", private.channelName, private.epoch, main)
	private.Join(main)
	C_Timer.After(MAIN_ANSWER_SECONDS, private.MainAnswer)
end

---What came of the try: in the main channel, and still there and not moderated a moment later, means it's open.
function private.MainAnswer(settled)
	local main = private.mainCheck
	if not main then
		return
	end
	local state = Wanted.db.homeCheck
	local id = GetChannelName(main)
	if private.mainCheckRefused or not id or id == 0 then
		private.mainCheck = nil
		state.wait = min(state.wait * 2, MAIN_MAX_WAIT_SECONDS)
		private.MarkMain(false, "tried again")
		Wanted:Log("Sync: %s still turns us away; next try in %d minutes", main, state.wait / 60)
		if id and id ~= 0 and private.channelName ~= main and LeaveChannelByName then
			LeaveChannelByName(main)
		end
		return
	end
	if not settled then
		C_Timer.After(MAIN_SETTLE_SECONDS, function() private.MainAnswer(true) end)
		return
	end
	private.mainCheck = nil
	state.wait = MAIN_RETRY_SECONDS
	private.MarkMain(true)
	if private.channelName == main then
		Wanted:Log("!! Sync: let into %s again", main)
		private.joinAttempts = 0
		private.TryJoin()
	else
		Wanted:Log("Sync: %s lets us in again; staying on %s until wanteddeadordead.com says so", main, private.channelName)
		if LeaveChannelByName then
			LeaveChannelByName(main)
		end
	end
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

---Whispers our channel pointer (or, asking, our epoch) to a player.
---@param target string
---@param question boolean?
---@param hops number? whispers the pointer will have taken; by default one more than it took to reach us
local function SendMove(target, question, hops)
	private.msgCounter = (private.msgCounter % 46655) + 1
	local tbl = { e = private.epoch, q = question and 1 or nil }
	if private.epoch > 0 then
		-- The server's pointer: only those ever travel (the main channel at epoch 0 is known to everyone)
		tbl.n, tbl.a, tbl.h = private.channelName, 1, hops or min((private.hop or MOVE_MAX_HOPS) + 1, MOVE_MAX_HOPS + 1)
	end
	Whisper(TAG_MOVE..":"..private.ToBase36(private.msgCounter)..":1/1:"..Encode(tbl), target)
end

---Tells every player we know where we are now.
---@param hops number
function private.SpreadMove(hops)
	for name in pairs(private.KnownPeers()) do
		if name ~= Store:GetOrigin() then
			SendMove(name, false, hops)
		end
	end
end

---At login: asks the few players heard most recently which channel they're on, and tells those whose last message
---came from an older release to update (1.4.0 needs everyone on it: older ones pick channels themselves).
function private.AskPointer()
	local peers = {}
	for name, seen in pairs(private.KnownPeers()) do
		if name ~= Store:GetOrigin() then
			tinsert(peers, { name = name, seen = seen })
			local known = Wanted.db.addonVersions[strmatch(name, "^([^%-]+)") or name]
			if type(known) == "table" and Wanted:IsRelease(Wanted.VERSION) and Wanted:IsNewerVersion(Wanted.VERSION, known.v) then
				private.TellOutdated(name)
			end
		end
	end
	sort(peers, function(a, b) return a.seen > b.seen end)
	for i = 1, min(#peers, MOVE_ASK_PEERS) do
		SendMove(peers[i].name, true)
	end
end

---A pointer (or a question) from another player. Followed only when it's the server's (a), from a player we know,
---and newer than ours; passed on once more while under the hop cap (Adopt).
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
	if tbl.q then
		return
	end
	if tbl.a ~= 1 or not private.ValidPointer(tbl) then
		Wanted:Log("Sync: a channel move from %s that isn't the server's; ignored", tostring(sender))
		return
	end
	if tbl.e <= private.epoch then
		return
	end
	if not private.KnownPeers()[sender] then
		Wanted:Log("!! Sync: a channel move from %s, who we don't know; ignored", tostring(sender))
		return
	end
	local hops = type(tbl.h) == "number" and tbl.h >= 1 and floor(tbl.h) or MOVE_MAX_HOPS
	Wanted:Log("Sync: %s says wanteddeadordead.com moved the channel to %s (%d), %d whisper(s) from an app", sender, tbl.n, tbl.e, hops)
	private.Adopt({ e = tbl.e, n = tbl.n }, "a player whose Wanted app brought it", hops)
end

---The channel the Wanted app passed on from wanteddeadordead.com (Catchup): followed when newer than ours.
---@param pointer table { e, n }
function Sync:AdoptFromApp(pointer)
	if type(pointer) == "table" and private.Adopt(pointer, "the Wanted app says so", 0) then
		Wanted:Log("Sync: moved to the app's channel %s (%d)", pointer.n, pointer.e)
	end
end

---The current channel, for the app to report (WantedDB.syncChannel holds the same once moved).
function Sync:GetPointer()
	return { e = private.epoch, n = private.channelName }
end
