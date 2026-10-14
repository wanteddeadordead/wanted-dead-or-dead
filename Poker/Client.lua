-- Wanted: Dead Man's Hand Poker. A player's side of a table: joining, the secret for each hand and when to send
-- it, a mirror of the host's numbered state, acting on one's turn, checking the audit after each hand (Deal), and
-- noticing a host that has gone quiet, with the backup to take the table over. Pure like the host: it sends
-- through the function it's given and asks the clock it's given. Table state is taken only from the host (the
-- game says who sent a message), and only when newer than what's held.
local _, Poker = ...
local Client = Poker:NewModule("PokerClient")
local Deal = Poker.PokerDeal
local Protocol = Poker.PokerProtocol

local Player = {}
Player.__index = Player

---A player's client. Nothing happens until Join.
---@param o table { name, send = fun(target, tbl), now = fun(): number, on = fun(event, ...)? }
---@return table
function Client:New(o)
	return setmetatable({ name = o.name, send = o.send, now = o.now, on = o.on or function() end,
		id = nil, host = nil, seat = nil, state = nil, term = 0, seq = 0,
		secrets = {}, -- hand key -> { secret, commit, committed, revealed }
		audits = {}, -- hand key -> { ok, reason }
		lastHeard = 0, lastSent = 0, joinedAt = nil, buyin = nil, backup = nil, sittingOut = false, left = false }, Player)
end

---Asks a host for a seat.
---@param host string
---@param id string
---@param buyin number
function Player:Join(host, id, buyin)
	self.id, self.host, self.buyin, self.seat, self.state = id, host, buyin, nil, nil
	self.term, self.seq, self.left = 0, 0, false
	self.joinedAt, self.lastHeard = self.now(), self.now()
	self:Send({ k = "join", b = buyin })
end

function Player:Send(tbl)
	tbl.t = self.id
	self.lastSent = self.now()
	self.send(self.host, tbl)
end

---Leaves the table.
function Player:Leave()
	if self.id and not self.left then
		self:Send({ k = "leave" })
	end
	self.left = true
	self.on("left")
end

---Asks the host for the state again.
function Player:Sync()
	self:Send({ k = "sync" })
end

---Says this player is back after sitting out (or wants to play on after missing a round).
function Player:Back()
	self.sittingOut = false
	self:Send({ k = "back" })
end

---Sits out from the next hand.
function Player:SitOut()
	self.sittingOut = true
	self:Send({ k = "sitout" })
end

---Buys more chips between hands.
---@param amount number
function Player:Rebuy(amount)
	self:Send({ k = "rebuy", b = amount })
end

---Acts on this player's turn: "fold", "check", "call", "bet", "raise" (to amount), "allin".
---@param action string
---@param amount number?
---@return boolean sent
function Player:Act(action, amount)
	local st = self.state
	if not st or not st.hand or st.hand.toAct ~= self.seat or not st.hand.legal then
		return false
	end
	self:Send({ k = "act", h = st.hand.key, q = self.seq, a = action, m = amount })
	return true
end

-- ============================================================================
-- Messages in
-- ============================================================================

---Handles a message. Sender is who the game says sent it.
---@param sender string
---@param tbl table
function Player:Receive(sender, tbl)
	if type(tbl) ~= "table" or tbl.t ~= self.id or not Protocol.TO_PLAYER[tbl.k] or self.left then
		return
	end
	local k = tbl.k
	if k == "takeover" then
		return self:OnTakeover(sender, tbl)
	end
	if sender ~= self.host then
		return
	end
	self.lastHeard = self.now()
	if k == "refuse" then
		self.on("refused", tostring(tbl.why))
		self.id, self.host = nil, nil
	elseif k == "welcome" or k == "state" then
		self:Apply(tbl.st)
	elseif k == "beat" then
		-- Quiet from the host, and a state we missed shows as a seq ahead of ours
		if type(tbl.q) == "number" and tbl.e == self.term and tbl.q > self.seq then
			self:Sync()
		end
	elseif k == "audit" then
		self:OnAudit(tbl)
	elseif k == "backup" then
		self.backup = tbl.b
	elseif k == "settle" then
		local l = tbl.l
		if type(l) == "table" and type(l.id) == "string" and Protocol:IsName(l.from) and Protocol:IsName(l.to) and Protocol:IsCount(l.amount, 1)
			and (l.from == self.name or l.to == self.name) and (l.from == sender or l.to == sender) then
			self.on("settle", { id = l.id, table = self.id, title = type(l.title) == "string" and l.title or nil, host = sender, at = time(),
				from = l.from, to = l.to, amount = l.amount })
		end
	end
end

-- Takes a state in when it's newer than what's held
function Player:Apply(st)
	if type(st) ~= "table" or type(st.q) ~= "number" or type(st.e) ~= "number" or type(st.seats) ~= "table" or not Protocol:ValidSettings(st.cfg) then
		return
	end
	if st.e < self.term or (st.e == self.term and st.q < self.seq) then
		return
	end
	local same = st.e == self.term and st.q == self.seq and self.state ~= nil
	self.term, self.seq, self.state, self.seat = st.e, st.q, st, st.me
	if not same then
		self.on("state", st)
	end
	-- Sat out for not answering a round (this client was away, not the player): say we're here. A player who sat
	-- out by timing out, or by choice, comes back when they say so
	local me = self.seat and st.seats[self.seat]
	if me and me.out == "missed" and not self.sittingOut and (me.s or 0) > 0 and st.phase ~= "playing" and not self.saidBack then
		self.saidBack = true
		self:Back()
	elseif me and not me.out then
		self.saidBack = nil
	end
	self:AnswerSeedRound(st)
end

-- The secret round: a fresh secret per hand key; the commitment as soon as the hand is called, the secret only
-- once the host has published every commitment with ours among them
function Player:AnswerSeedRound(st)
	local hand = st.hand
	if not hand or type(hand.key) ~= "string" or not self.seat then
		return
	end
	local me = st.seats[self.seat]
	if not me or not me.inHand then
		return
	end
	local mine = self.secrets[hand.key]
	if hand.stage == "commits" then
		if not mine then
			local secret = Deal:Secret()
			mine = { secret = secret, commit = Deal:Commit(secret) }
			self.secrets[hand.key] = mine
		end
		if not mine.committed then
			mine.committed = true
			self:Send({ k = "commit", h = hand.key, c = mine.commit })
		end
	elseif hand.stage == "reveals" and mine and mine.committed and not mine.revealed then
		if type(hand.commits) == "table" and hand.commits[self.seat] == mine.commit then
			mine.revealed = true
			self:Send({ k = "reveal", h = hand.key, s = mine.secret })
		elseif not mine.leftOut then
			-- Our commitment isn't the one published: the deck can't be ours. Say so and keep the secret
			mine.leftOut = true
			self.on("leftOut", hand.key)
		end
	end
end

-- The host's account of the hand, checked against what this client knows
function Player:OnAudit(tbl)
	local a = tbl.a
	if type(a) ~= "table" or type(tbl.h) ~= "string" then
		return
	end
	local mine = self.secrets[tbl.h]
	if not mine then
		-- Not in this hand (sat out, or joined during it): nothing of ours to check, so nothing to say
		return
	end
	local st = self.state
	local me = { seat = self.seat, secret = mine.secret, commit = mine.commit }
	if st and st.hand and st.hand.key == tbl.h and self.seat and st.seats[self.seat] then
		me.hole = st.seats[self.seat].hole
	end
	local ok, reason = Deal:Verify(a, me)
	self.audits[tbl.h] = { ok = ok, reason = reason, payouts = a.payouts }
	self.on("audit", tbl.h, ok, reason, a)
end

-- Another seat says it is the host now
function Player:OnTakeover(sender, tbl)
	local st = tbl.st
	if type(st) ~= "table" or type(st.e) ~= "number" or st.e <= self.term or st.host ~= sender then
		return
	end
	-- Only once the host is gone, and only from a player who was at the table
	if self.now() - self.lastHeard < Protocol.HOST_TIMEOUT or not self:WasSeated(sender) then
		return
	end
	self.host = sender
	self.on("newHost", sender)
	self:Apply(st)
end

function Player:WasSeated(name)
	if not self.state then
		return false
	end
	for _, p in pairs(self.state.seats) do
		if p.n == name then return true end
	end
	return false
end

-- ============================================================================
-- Time
-- ============================================================================

---This player's place in the line to take over: 1 for the seat after the host, nil when not seated.
---@return number?
function Player:Rank()
	local st = self.state
	if not st or not self.seat then
		return nil
	end
	local seats = {}
	local hostSeat
	for seat, p in pairs(st.seats) do
		seats[#seats + 1] = seat
		if p.n == self.host then hostSeat = seat end
	end
	sort(seats)
	hostSeat = hostSeat or 0
	local rank = 0
	-- Count the seats after the host's, wrapping round, up to ours
	for _, seat in ipairs(seats) do
		if seat > hostSeat then
			rank = rank + 1
			if seat == self.seat then return rank end
		end
	end
	for _, seat in ipairs(seats) do
		if seat < hostSeat then
			rank = rank + 1
			if seat == self.seat then return rank end
		end
	end
	return nil
end

---Runs the clock: an unanswered join, a stale state, a host gone quiet. Call about once a second.
function Player:Tick()
	if not self.id or self.left then
		return
	end
	local now = self.now()
	if not self.state then
		if now - self.joinedAt >= Protocol.JOIN_RETRY_SECONDS and now - self.lastSent >= Protocol.JOIN_RETRY_SECONDS then
			self:Send({ k = "join", b = self.buyin })
		end
		return
	end
	local silent = now - self.lastHeard
	if silent >= Protocol.HOST_TIMEOUT then
		local rank = self:Rank()
		if rank and self.backup and silent >= Protocol.HOST_TIMEOUT + (rank - 1) * Protocol.TAKEOVER_STEP and not self.takingOver then
			self.takingOver = true
			self.on("takeover", self.backup)
		elseif not self.saidGone then
			self.saidGone = true
			self.on("hostGone")
		end
	elseif silent >= Protocol.SYNC_SECONDS and now - self.lastSent >= Protocol.SYNC_SECONDS then
		self:Sync()
	end
end
