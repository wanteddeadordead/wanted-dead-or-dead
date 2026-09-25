-- Wanted: peer to peer sync over a hidden custom chat channel. Every client holds the full store and
-- broadcasts its own new records once; a client that logs in says what it holds, peers answer with what
-- they hold, and gaps are filled by whoever answers first. No relay of live traffic, no server, no owner.
-- Everything sent is addon messages (data only, invisible to normal chat), through C_ChatInfo.

local _, Wanted = ...
local Sync = Wanted:NewModule("Sync")
local Store = Wanted.Store
local LibSerialize = LibStub("LibSerialize")
local LibDeflate = LibStub("LibDeflate")
local private = {
	frame = CreateFrame("Frame"),
	channelName = nil,
	channelId = nil,
	joinAttempts = 0,
	msgCounter = 0,
	partial = {}, -- sender..msgId -> { parts = {}, total, t }
	sentTimes = {}, -- outbound message times in the last minute
	inbound = {}, -- sender -> { count, minute }
	ceilingHitMinute = nil,
	pausedUntil = 0,
	peers = {}, -- sender -> last message time
	ownMessages = {}, -- tag:msgId -> time sent, to recognise our own echoes
	pendingNeedAnswers = {}, -- origin -> { from, t } scheduled answers
	recentFills = {}, -- origin -> highest seq seen filled by anyone recently
	stats = { sent = 0, received = 0, echoed = 0, dropped = 0, merged = 0, invalid = 0 },
	testStartedAt = nil,
}
local PREFIX = "WNTD"
local CHANNEL_BASE = "WantedNet"
-- The password only keeps stray chat out of the channel; the addon is public, so it is not a secret
local CHANNEL_PASSWORD = "wnt1"
-- Message = tag ":" msgId ":" part "/" total ":" chunk; the header is at most 12 characters
local MAX_MESSAGE_LEN = 255
local CHUNK_LEN = 240
local PARTIAL_TIMEOUT = 30
-- Tags
local TAG_HELLO, TAG_HAVE, TAG_NEED, TAG_LIVE, TAG_FILL = "H", "V", "N", "R", "F"
-- Enemy sightings are passing news, not records: never stored in a chain, never re-sent
local TAG_ENEMY = "E"
-- Limits, the same shape as AskPrice's: a hard ceiling on everything sent, a cap on what any one sender may
-- push at us, and a pause when the ceiling is hit two minutes running
local MAX_SENT_PER_MINUTE = 20
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



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Sync:OnEnable()
	private.channelName = CHANNEL_BASE..(UnitFactionGroup("player") or "")
	local result = C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
	Wanted:Log("Sync: prefix %s registered (%s), channel %s", PREFIX, tostring(result), private.channelName)
	private.frame:RegisterEvent("CHAT_MSG_ADDON")
	private.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	private.frame:SetScript("OnEvent", private.OnEvent)
	Store:OnRecord("kill", private.OnOwnRecord)
	Store:OnRecord("death", private.OnOwnRecord)
	Store:OnRecord("bounty", private.OnOwnRecord)
	Store:OnRecord("claim", private.OnOwnRecord)
	Store:OnRecord("payment", private.OnOwnRecord)
	Store:OnRecord("mark", private.OnOwnRecord)
	Store:OnRecord("raise", private.OnOwnRecord)
	Store:OnRecord("pass", private.OnOwnRecord)
	Store:OnRecord("confirm", private.OnOwnRecord)
	Store:OnRecord("withdraw", private.OnOwnRecord)
	Store:OnRecord("hunt", private.OnOwnRecord)
	-- Channels are joined a little after login, so wait before trying
	C_Timer.After(5, private.TryJoin)
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
	return {
		channelName = private.channelName,
		channelId = private.channelId,
		peers = numPeers,
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
	return format("Sync: channel %s (%s), %d peers in the last 10 min; sent %d, received %d (%d own echoes), merged %d, invalid %d, dropped %d%s.", private.channelName or "?", private.channelId and ("#"..private.channelId) or "not joined", numPeers, private.stats.sent, private.stats.received, private.stats.echoed, private.stats.merged, private.stats.invalid, private.stats.dropped, now < private.pausedUntil and " PAUSED" or "")
end

function private.OnEvent(_, event, ...)
	if event == "CHAT_MSG_ADDON" then
		private.OnAddonMessage(...)
	elseif event == "PLAYER_ENTERING_WORLD" then
		-- A zone change or reload can drop the channel id
		private.channelId = nil
		private.joinAttempts = 0
		C_Timer.After(5, private.TryJoin)
	end
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
			return
		end
		private.joinAttempts = private.joinAttempts + 1
		if private.joinAttempts == 1 then
			Wanted:Log("Sync: calling JoinPermanentChannel")
			-- Joined without a chat frame id, so it is not shown in any tab; it only ever carries addon data, which
			-- never displays anyway. Permanent channels are remembered by the server, so if this client blocks the
			-- call, joining once by hand (/join <name> <password>) is enough for good.
			JoinPermanentChannel(private.channelName, CHANNEL_PASSWORD)
		elseif private.joinAttempts == 3 then
			Wanted:Print("Not in the sync channel yet. If it never joins, type once: /join %s %s", private.channelName, CHANNEL_PASSWORD)
		end
		C_Timer.After(JOIN_RETRY_SECONDS, private.TryJoin)
		return
	end
	private.channelId = id
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

local function PruneTimes(times, now)
	while times[1] and now - times[1] >= 60 do
		tremove(times, 1)
	end
end

---Sends a table as one or more addon messages. Returns whether it was sent.
---@param tag string
---@param tbl table
---@return boolean
function private.Send(tag, tbl)
	if not private.channelId then
		return false
	end
	local now = GetTime()
	if now < private.pausedUntil then
		private.stats.dropped = private.stats.dropped + 1
		return false
	end
	local payload = Encode(tbl)
	local total = ceil(#payload / CHUNK_LEN)
	PruneTimes(private.sentTimes, now)
	Wanted:Log("Sync: send %s, %d bytes in %d part(s)", tag, #payload, total)
	if #private.sentTimes + total > MAX_SENT_PER_MINUTE then
		Wanted:Log("Sync: send limit reached, dropping %s", tag)
		local minute = floor(now / 60)
		if private.ceilingHitMinute and minute == private.ceilingHitMinute + 1 then
			private.pausedUntil = now + PAUSE_SECONDS
			Wanted:Print("Sync hit its send limit two minutes running, so it is paused for %d minutes.", PAUSE_SECONDS / 60)
		end
		private.ceilingHitMinute = minute
		private.stats.dropped = private.stats.dropped + 1
		return false
	end
	private.msgCounter = (private.msgCounter % 46655) + 1
	local msgId = private.ToBase36(private.msgCounter)
	private.ownMessages[tag..":"..msgId] = now
	for part = 1, total do
		local chunk = strsub(payload, (part - 1) * CHUNK_LEN + 1, part * CHUNK_LEN)
		local text = tag..":"..msgId..":"..part.."/"..total..":"..chunk
		assert(#text <= MAX_MESSAGE_LEN)
		local result = C_ChatInfo.SendAddonMessage(PREFIX, text, "CHANNEL", tostring(private.channelId))
		Wanted:Log("Sync: SendAddonMessage part %d/%d -> %s", part, total, tostring(result))
		if result == RESULT_INVALID_CHANNEL then
			-- Not really in the channel (yet): look it up again shortly and say hello then
			private.channelId = nil
			private.joinAttempts = 0
			C_Timer.After(JOIN_SETTLE_SECONDS, private.TryJoin)
			private.stats.dropped = private.stats.dropped + 1
			return false
		end
		tinsert(private.sentTimes, now)
		private.stats.sent = private.stats.sent + 1
	end
	return true
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

---What this client holds: the highest seq per origin, most recently active origins first, bounded.
function private.GetHaveTable()
	local chains = {}
	for origin, chain in pairs(Wanted.db.chains) do
		if chain.seq > 0 then
			chains[origin] = chain.seq
		end
	end
	return chains
end

function private.SendHello()
	private.Send(TAG_HELLO, { c = private.GetHaveTable(), v = Wanted.VERSION })
end

function private.OnOwnRecord(record, isOwn)
	if isOwn and not Store:IsTest(record) then
		private.Send(TAG_LIVE, { r = { record } })
	end
end



-- ============================================================================
-- Receiving
-- ============================================================================

function private.OnAddonMessage(prefix, text, channel, sender, _, _, _, channelName)
	if prefix ~= PREFIX or channel ~= "CHANNEL" then
		return
	end
	if channelName and channelName ~= "" and strlower(channelName) ~= strlower(private.channelName) then
		return
	end
	local now = GetTime()
	private.stats.received = private.stats.received + 1
	-- Our own messages come back to us; recognise them by the id we just sent rather than by name, and let the
	-- store learn how the server names us as a sender
	local echoTag, echoId = strmatch(text, "^(%u):(%w+):")
	local isSelf = echoTag and private.ownMessages[echoTag..":"..echoId] and now - private.ownMessages[echoTag..":"..echoId] < 30
	if isSelf then
		private.ownMessages[echoTag..":"..echoId] = nil
		Store:LearnOrigin(sender)
	elseif sender == Store:GetOrigin() then
		isSelf = true
	end
	Wanted:Log("Sync: received %d bytes from %s%s on %s", #text, sender, isSelf and " (self)" or "", tostring(channelName))
	if isSelf then
		-- Our own messages come back to us too, which is the transport check in /wanted synctest
		private.stats.echoed = private.stats.echoed + 1
		if private.testStartedAt then
			Wanted:Print("Sync test: our message came back through the channel (%.2fs).", now - private.testStartedAt)
			private.testStartedAt = nil
		end
		return
	end
	private.peers[sender] = now
	-- Per-sender inbound cap
	local minute = floor(now / 60)
	local inbound = private.inbound[sender]
	if not inbound or inbound.minute ~= minute then
		inbound = { count = 0, minute = minute }
		private.inbound[sender] = inbound
	end
	inbound.count = inbound.count + 1
	if inbound.count > MAX_INBOUND_PER_SENDER_PER_MINUTE then
		return
	end
	-- Framing
	local tag, msgId, part, total, chunk = strmatch(text, "^(%u):(%w+):(%d+)/(%d+):(.*)$")
	if not tag then
		private.stats.invalid = private.stats.invalid + 1
		return
	end
	part, total = tonumber(part), tonumber(total)
	local payload = nil
	if total == 1 then
		payload = chunk
	else
		local key = sender..":"..msgId
		local partial = private.partial[key]
		if not partial or now - partial.t > PARTIAL_TIMEOUT then
			partial = { parts = {}, total = total, t = now, count = 0 }
			private.partial[key] = partial
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
	local tbl = Decode(payload)
	if type(tbl) ~= "table" then
		private.stats.invalid = private.stats.invalid + 1
		Wanted:Log("Sync: could not decode a %s message from %s", tag, sender)
		return
	end
	Wanted:Log("Sync: handling %s from %s", tag, sender)
	private.HandleMessage(tag, tbl, sender)
end

---Tells other Wanted users about an enemy just seen.
---@param data table
function Sync:ShareSighting(data)
	private.Send(TAG_ENEMY, data)
end

function private.HandleMessage(tag, tbl, sender)
	if tag == TAG_ENEMY then
		if Wanted.Enemies then
			Wanted.Enemies:OnSharedSighting(tbl, sender)
		end
		return
	end
	if tag == TAG_HELLO or tag == TAG_HAVE then
		Wanted:NoteVersion(tbl.v)
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
		for _, record in ipairs(tbl.r) do
			local isNew
			if tag == TAG_LIVE then
				isNew = Store:Merge(record, sender)
			else
				isNew = Store:MergeRelayed(record)
			end
			Wanted:Log("Sync: %s record %s from %s: %s", tag == TAG_LIVE and "live" or "fill", tostring(record.id), sender, isNew and "new" or "known or rejected")
			if isNew then
				private.stats.merged = private.stats.merged + 1
				if type(record.origin) == "string" and type(record.seq) == "number" then
					private.recentFills[record.origin] = max(private.recentFills[record.origin] or 0, record.seq)
				end
			end
		end
	end
end

---A peer told us what it holds. Ask for what we lack, and if this was a HELLO, tell it what we hold.
function private.HandleHave(chains, sender, isHello)
	local need = {}
	local numNeed = 0
	for origin, seq in pairs(chains) do
		if type(origin) == "string" and type(seq) == "number" and seq > Store:GetChainSeq(origin) and origin ~= Store:GetOrigin() then
			need[origin] = Store:GetChainSeq(origin) + 1
			numNeed = numNeed + 1
			if numNeed >= 5 then
				break
			end
		end
	end
	if numNeed > 0 then
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

---A peer asked for records. Answer after a random delay unless someone else already filled that range.
function private.HandleNeed(need, sender)
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

function private.SendFill(origin, fromSeq)
	local records = {}
	for _, kind in ipairs({ "kill", "death", "bounty", "claim", "payment", "mark", "raise", "pass", "confirm", "withdraw", "hunt" }) do
		for record in Store:Iterator(kind) do
			if record.origin == origin and record.seq >= fromSeq and not Store:IsTest(record) then
				tinsert(records, record)
			end
		end
	end
	sort(records, function(a, b) return a.seq < b.seq end)
	local numSent = 0
	for i = 1, #records, FILL_BATCH do
		local batch = {}
		for j = i, min(i + FILL_BATCH - 1, #records) do
			tinsert(batch, records[j])
		end
		if not private.Send(TAG_FILL, { r = batch }) then
			return
		end
		numSent = numSent + #batch
		if numSent >= MAX_FILL_PER_REQUEST then
			return
		end
	end
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
