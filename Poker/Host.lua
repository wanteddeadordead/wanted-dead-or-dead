-- Wanted: Dead Man's Hand Poker. The host's side of a table: seats, the secret round before each hand
-- (Deal), the engine (Engine), turn timers, the state every player is sent, the audit after each hand, and the
-- backup the next seat keeps so it can take the table over if the host vanishes. Pure: it sends through the
-- function it's given and asks the clock it's given, so the tests run a host and several players in one place.
-- The host plays too: their own client talks to this through the same messages, delivered locally (Net).
local _, Poker = ...
local Host = Poker:NewModule("PokerHost")
local Engine = Poker.PokerEngine
local Deal = Poker.PokerDeal
local Protocol = Poker.PokerProtocol

local Table = {}
Table.__index = Table

local function Copy(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = type(v) == "table" and Copy(v) or v
	end
	return out
end

---Opens a table. The host sits down through their own client's join, like anyone else.
---@param o table { name, id?, cfg, send = fun(target, tbl), ad = fun(tbl)?, now = fun(): number, on = fun(event, ...)? }
---@return table? table
---@return string? reason
function Host:New(o)
	local cfg, reason = Protocol:Settings(o.cfg)
	if not cfg then
		return nil, reason
	end
	local now = o.now()
	local t = setmetatable({
		name = o.name, id = o.id or Protocol:NewId(o.name, now), cfg = cfg, send = o.send, ad = o.ad, now = o.now, on = o.on or function() end,
		term = o.term or 1, seq = 0, handNo = o.handNo or 0, attempt = 0,
		seats = {}, -- seat -> { name, stack, out (false, or why: "away", "missed", "busted"), away (timeouts and misses in a row), since }
		phase = "waiting", -- waiting | seeding | playing | showdown | closed
		hand = nil, -- the engine's hand while one is played
		hs = nil, -- the hand's session: players, commits, secrets, deck, deadline, stage, setup
		button = o.button, open = true, nextHandAt = now, lastSent = now, lastAd = 0,
	}, Table)
	for seat, p in pairs(o.seats or {}) do
		t.seats[seat] = { name = p.name, stack = p.stack, bought = p.bought or p.stack, out = type(p.out) == "string" and p.out or false, away = 0, since = now }
	end
	return t
end

---Rebuilds a table from the backup its host sent the next seat, under a new host and term.
---@param backup table
---@param o table { name, send, ad?, now, on? }
---@return table? table
---@return string? reason
function Host:Restore(backup, o)
	if type(backup) ~= "table" or type(backup.id) ~= "string" or type(backup.seats) ~= "table" then
		return nil, "no backup"
	end
	local seats = {}
	for seat, p in pairs(backup.seats) do
		if Protocol:IsCount(seat, 1, Protocol.MAX_SEATS) and Protocol:IsName(p.name) and Protocol:IsCount(p.stack) then
			seats[seat] = { name = p.name, stack = p.stack, bought = p.bought, out = p.out }
		end
	end
	return Host:New({ name = o.name, id = backup.id, cfg = backup.cfg, send = o.send, ad = o.ad, now = o.now, on = o.on,
		term = (tonumber(backup.term) or 1) + 1, handNo = tonumber(backup.handNo) or 0, button = backup.button, seats = seats })
end

-- ============================================================================
-- Seats
-- ============================================================================

function Table:SeatOf(name)
	for seat, p in pairs(self.seats) do
		if p.name == name then
			return seat, p
		end
	end
end

function Table:Seated()
	local list = {}
	for seat in pairs(self.seats) do
		list[#list + 1] = seat
	end
	sort(list)
	return list
end

---Seats a player. Returns the seat, or nil and why not.
---@param name string
---@param buyin number
---@return number? seat
---@return string? reason
function Table:Sit(name, buyin)
	if not self.open then
		return nil, "the table is closed"
	end
	if self:SeatOf(name) then
		return nil, "you're already seated"
	end
	if not Protocol:IsCount(buyin, self.cfg.buyMin, self.cfg.buyMax) then
		return nil, ("the buy-in is %d to %d"):format(self.cfg.buyMin, self.cfg.buyMax)
	end
	for seat = 1, self.cfg.maxSeats do
		if not self.seats[seat] then
			self.seats[seat] = { name = name, stack = buyin, bought = buyin, out = false, away = 0, since = self.now() }
			self.on("sat", name, seat, buyin)
			return seat
		end
	end
	return nil, "the table is full"
end

---Takes a player out of their seat. In a hand, their cards are folded and their bets stay in the pot.
---@param name string
function Table:Stand(name)
	local seat, p = self:SeatOf(name)
	if not seat then
		return
	end
	if self.hand and self.hand.street ~= "done" and self.hand.seats[seat] then
		local wasToAct = self.hand.toAct == seat
		Engine:Leave(self.hand, seat)
		if wasToAct and self.hand.street ~= "done" then
			self.hs.deadline = self.now() + self.cfg.turnSeconds
		end
	end
	if self.hs and self.hs.players[seat] then
		self.hs.players[seat] = nil
	end
	self.seats[seat] = nil
	self:Settle(seat, p)
	self.on("stood", name, seat, p.stack)
	if self.hand and self.hand.street == "done" and self.phase == "playing" then
		self:Showdown()
	elseif self.hs and self.phase == "seeding" then
		self:CheckSeedRound()
	end
end

-- The seats in play order after `seat`
function Table:After(seat)
	local list = self:Seated()
	local out = {}
	local n = #list
	local start = 1
	for i, s in ipairs(list) do
		if s > seat then start = i break end
		start = i + 1
	end
	for i = 0, n - 1 do
		local s = list[(start - 1 + i) % n + 1]
		if s ~= seat then out[#out + 1] = s end
	end
	return out
end

---The seat that takes the table over if this host vanishes: the next seated player after the host.
---@return number? seat
function Table:Successor()
	local mine = self:SeatOf(self.name)
	local after = self:After(mine or 0)
	return after[1]
end

-- ============================================================================
-- Messages in
-- ============================================================================

---Handles a message from a player. Sender is who the game says sent it.
---@param sender string
---@param tbl table
function Table:Receive(sender, tbl)
	if type(tbl) ~= "table" or tbl.t ~= self.id or not Protocol.TO_HOST[tbl.k] then
		return
	end
	local k = tbl.k
	if k == "join" then
		local seated, p = self:SeatOf(sender)
		if seated then
			-- Back after a reload: a seat sat out for not answering is theirs to play again
			if p.out == "missed" then
				p.out, p.away = false, 0
			end
			self:SendState(sender, "welcome")
			return
		end
		local seat, reason = self:Sit(sender, tbl.b)
		if seat then
			self:Bump()
			self:SendState(sender, "welcome")
			self:Broadcast(sender)
			self:Backup()
		else
			self.send(sender, { k = "refuse", t = self.id, why = reason })
		end
		return
	end
	local seat = self:SeatOf(sender)
	if not seat then
		return
	end
	if k == "leave" then
		self:Stand(sender)
		self:Bump()
		self:Broadcast()
		self:Backup()
	elseif k == "sync" then
		self:SendState(sender, "state")
	elseif k == "back" then
		local p = self.seats[seat]
		if p.stack > 0 then
			p.out, p.away = false, 0
			self:Bump()
			self:Broadcast()
		end
	elseif k == "sitout" then
		-- From the next hand; a hand under way is played out
		local p = self.seats[seat]
		if not p.out then
			p.out = "sitting"
			self:Bump()
			self:Broadcast()
		end
	elseif k == "rebuy" then
		local p = self.seats[seat]
		local inHand = self.hand and self.hand.street ~= "done" and self.hand.seats[seat] and not self.hand.seats[seat].folded
		if not inHand and Protocol:IsCount(tbl.b, 1) and p.stack + tbl.b <= self.cfg.buyMax then
			p.stack = p.stack + tbl.b
			p.bought = (p.bought or 0) + tbl.b
			p.out, p.away = false, 0
			self.on("rebuy", sender, seat, tbl.b)
			self:Bump()
			self:Broadcast()
			self:Backup()
		end
	elseif k == "commit" then
		self:OnCommit(seat, tbl)
	elseif k == "reveal" then
		self:OnReveal(seat, tbl)
	elseif k == "act" then
		self:OnAct(seat, tbl)
	end
end

function Table:OnCommit(seat, tbl)
	local hs = self.hs
	if not hs or hs.stage ~= "commits" or not hs.players[seat] or tbl.h ~= hs.key or not Protocol:IsHex(tbl.c, 64) or hs.commits[seat] then
		return
	end
	hs.commits[seat] = tbl.c
	self:CheckSeedRound()
end

function Table:OnReveal(seat, tbl)
	local hs = self.hs
	if not hs or hs.stage ~= "reveals" or not hs.players[seat] or tbl.h ~= hs.key or not Protocol:IsHex(tbl.s, 64) or hs.secrets[seat] then
		return
	end
	if Deal:Commit(tbl.s) ~= hs.commits[seat] then
		return
	end
	hs.secrets[seat] = tbl.s
	self:CheckSeedRound()
end

function Table:OnAct(seat, tbl)
	local hand = self.hand
	if self.phase ~= "playing" or not hand or tbl.h ~= self.hs.key or tbl.q ~= self.seq or hand.toAct ~= seat then
		return
	end
	local ok = Engine:Act(hand, seat, tbl.a, tbl.m)
	if not ok then
		-- Their client works from the same rules: a refused action means stale state, so send it again
		self:SendState(self.seats[seat].name, "state")
		return
	end
	self.seats[seat].away = 0
	self:AfterAction()
end

-- ============================================================================
-- The hand
-- ============================================================================

-- Who is dealt in: seated, not sitting out, with chips
function Table:Players()
	local players, n = {}, 0
	for seat, p in pairs(self.seats) do
		if not p.out and p.stack > 0 then
			players[seat] = true
			n = n + 1
		end
	end
	return players, n
end

---Calls the next hand: every player makes a secret and sends its commitment.
function Table:StartSeedRound()
	local players, n = self:Players()
	if n < Protocol.MIN_SEATS then
		return false
	end
	if self.attempt == 0 then
		self.handNo = self.handNo + 1
	end
	self.attempt = self.attempt + 1
	self.hs = { key = self.handNo.."."..self.attempt, players = players, commits = {}, secrets = {}, stage = "commits",
		deadline = self.now() + Protocol.COMMIT_SECONDS }
	self.phase = "seeding"
	self.hand = nil
	self:Bump()
	self:Broadcast()
	return true
end

-- Moves the secret round on when everyone has answered
function Table:CheckSeedRound()
	local hs = self.hs
	if not hs then
		return
	end
	local waiting = false
	for seat in pairs(hs.players) do
		if (hs.stage == "commits" and not hs.commits[seat]) or (hs.stage == "reveals" and not hs.secrets[seat]) then
			waiting = true
		end
	end
	if not waiting then
		self:SeedDeadline()
	end
end

-- The commit or reveal window closed (or everyone answered): drop whoever didn't answer and go on
function Table:SeedDeadline()
	local hs = self.hs
	local answered = hs.stage == "commits" and hs.commits or hs.secrets
	local missed = {}
	local n = 0
	for seat in pairs(hs.players) do
		if answered[seat] then
			n = n + 1
		else
			missed[#missed + 1] = seat
		end
	end
	for _, seat in ipairs(missed) do
		-- A player whose client didn't answer sits out until it says it's back (an honest one does so at once)
		local p = self.seats[seat]
		if p then
			p.away = p.away + 1
			if p.away >= Protocol.AWAY_TIMEOUTS then p.out = "missed" end
		end
		hs.players[seat] = nil
	end
	if hs.stage == "commits" then
		if n < Protocol.MIN_SEATS then
			return self:AbortHand()
		end
		-- Every commitment published: now the secrets. Only the seats that committed stay in the hand
		hs.stage = "reveals"
		hs.deadline = self.now() + Protocol.REVEAL_SECONDS
		self:Bump()
		self:Broadcast()
	else
		if #missed > 0 or n < Protocol.MIN_SEATS then
			-- The deck needs every committed secret: without one the round is run again, without them
			return self:AbortHand()
		end
		self:DealHand()
	end
end

function Table:AbortHand()
	self.hs = nil
	self.phase = "waiting"
	self.nextHandAt = self.now() + 1
	self:Bump()
	self:Broadcast()
end

function Table:DealHand()
	local hs = self.hs
	local deck = Deal:Deck(self.id, hs.key, hs.secrets)
	hs.deck, hs.deckHash = deck, Deal:DeckHash(deck)
	-- The button moves to the next player in the hand after where it was
	local order = {}
	for seat in pairs(hs.players) do order[#order + 1] = seat end
	sort(order)
	local button = order[1]
	if self.button then
		for _, seat in ipairs(order) do
			if seat > self.button then button = seat break end
		end
	end
	self.button = button
	local seats = {}
	for seat in pairs(hs.players) do
		seats[seat] = { stack = self.seats[seat].stack, name = self.seats[seat].name }
	end
	hs.setup = { seats = Copy(seats), button = button, sb = self.cfg.sb, bb = self.cfg.bb, ante = self.cfg.ante }
	self.hand = Engine:NewHand({ seats = seats, button = button, sb = self.cfg.sb, bb = self.cfg.bb, ante = self.cfg.ante, deck = deck })
	Engine:Start(self.hand)
	hs.stage = "play"
	self.phase = "playing"
	self.attempt = 0
	self.on("dealt", self.handNo)
	self:AfterAction()
end

function Table:AfterAction()
	self.hs.deadline = self.now() + self.cfg.turnSeconds
	self:Bump()
	if self.hand.street == "done" then
		self:Showdown()
	else
		self:Broadcast()
	end
end

function Table:Showdown()
	local hand, hs = self.hand, self.hs
	for seat, p in pairs(hand.seats) do
		if self.seats[seat] then
			self.seats[seat].stack = p.stack
			if p.stack == 0 then
				self.seats[seat].out = "busted"
			end
		end
	end
	self.phase = "showdown"
	self.nextHandAt = self.now() + Protocol.SHOWDOWN_SECONDS
	self:Broadcast()
	local audit = { tableId = self.id, handNo = hs.key, commits = hs.commits, secrets = hs.secrets, deckHash = hs.deckHash, setup = hs.setup,
		log = hand.log, board = hand.board, payouts = hand.results.payouts }
	for seat in pairs(hand.seats) do
		if self.seats[seat] then
			self.send(self.seats[seat].name, { k = "audit", t = self.id, h = hs.key, a = audit })
		end
	end
	self.on("hand", self.handNo, hand, hs)
	self:Backup()
end

---Closes the table: the final stacks go out and nothing more is dealt.
function Table:Close()
	if not self.open then
		return
	end
	self.open = false
	if self.hand and self.hand.street ~= "done" and self.phase == "playing" then
		-- A hand cut short: everyone gets their chips back
		for seat, p in pairs(self.hand.seats) do
			if self.seats[seat] then self.seats[seat].stack = p.stack + p.total end
		end
	end
	self.phase = "closed"
	self.hand, self.hs = nil, nil
	self:Bump()
	self:Broadcast()
	for seat, p in pairs(self.seats) do
		self:Settle(seat, p)
	end
	self.on("closed")
end

---At a gold table the host is the bank: a player who leaves (or is at the table when it closes) owes the host
---what they lost, or is owed what they won, against what they bought in for. The player is sent the line, and
---the host's own ledger gets it (on "settle"). Chips tables settle nothing.
---@param seat number
---@param p table the seat's record
function Table:Settle(seat, p)
	if self.cfg.stakes ~= "gold" or p.name == self.name then
		return
	end
	local net = p.stack - (p.bought or 0)
	if net == 0 then
		return
	end
	self.settled = (self.settled or 0) + 1
	local line = { id = self.id..":"..self.settled, table = self.id, title = self.cfg.title, host = self.name, at = time(),
		from = net < 0 and p.name or self.name, to = net < 0 and self.name or p.name, amount = math.abs(net) }
	self.send(p.name, { k = "settle", t = self.id, l = line })
	self.on("settle", line)
end

-- ============================================================================
-- Time
-- ============================================================================

---Runs the clock: deadlines, the next hand, heartbeats and ads. Call about once a second.
function Table:Tick()
	if not self.open then
		return
	end
	local now = self.now()
	if self.phase == "waiting" and now >= self.nextHandAt then
		self:StartSeedRound()
	elseif self.phase == "seeding" and now >= self.hs.deadline then
		self:SeedDeadline()
	elseif self.phase == "playing" and now >= self.hs.deadline then
		self:TimeOut()
	elseif self.phase == "showdown" and now >= self.nextHandAt then
		self.phase = "waiting"
		self.hand = nil
		self:StartSeedRound()
	end
	if self.open and now - self.lastSent >= Protocol.BEAT_SECONDS then
		self:Beat()
	end
	if self.open and self.ad and now - self.lastAd >= Protocol.AD_SECONDS then
		self:Advertise()
	end
end

-- The player to act ran out of time: a check when free, else a fold; twice running and they sit out
function Table:TimeOut()
	local hand = self.hand
	local seat = hand.toAct
	if not seat then
		return
	end
	local legal = Engine:Legal(hand, seat)
	Engine:Act(hand, seat, legal and legal.check and "check" or "fold")
	local p = self.seats[seat]
	if p then
		p.away = p.away + 1
		if p.away >= Protocol.AWAY_TIMEOUTS then
			p.out = "away"
		end
	end
	self.on("timeout", seat)
	self:AfterAction()
end

-- ============================================================================
-- Messages out
-- ============================================================================

function Table:Bump()
	self.seq = self.seq + 1
end

function Table:Beat()
	self.lastSent = self.now()
	for _, p in pairs(self.seats) do
		self.send(p.name, { k = "beat", t = self.id, q = self.seq, e = self.term })
	end
end

function Table:Advertise()
	self.lastAd = self.now()
	local taken = #self:Seated()
	self.ad({ id = self.id, h = self.name, n = self.cfg.title, s = taken, m = self.cfg.maxSeats, sb = self.cfg.sb, bb = self.cfg.bb,
		g = self.cfg.stakes == "gold" and 1 or nil, lo = self.cfg.buyMin, hi = self.cfg.buyMax, c = not self.open and 1 or nil })
end

---Sends every seat its view of the table.
---@param except string? a player just sent theirs
function Table:Broadcast(except)
	self.lastSent = self.now()
	for _, p in pairs(self.seats) do
		if p.name ~= except then
			self:SendState(p.name, "state")
		end
	end
end

---The table as one seat sees it: its own cards, everyone's at a showdown, nobody else's otherwise.
---@param name string
---@return table
function Table:StateFor(name)
	local mySeat = self:SeatOf(name)
	local hand, hs = self.hand, self.hs
	local st = { t = self.id, host = self.name, e = self.term, q = self.seq, h = self.handNo, cfg = self.cfg, phase = self.phase, me = mySeat, seats = {}, open = self.open }
	for seat, p in pairs(self.seats) do
		local s = { n = p.name, s = p.stack, bought = p.bought, out = p.out or nil, away = p.away > 0 and p.away or nil }
		if hand and hand.seats[seat] then
			local hp = hand.seats[seat]
			s.s, s.b, s.tot = hp.stack, hp.bet, hp.total
			s.f, s.a = hp.folded or nil, hp.allin or nil
			local shown = hand.results and hand.results.shown[seat]
			if seat == mySeat or shown then
				s.hole = { hp.hole[1], hp.hole[2] }
			end
		elseif hs and hs.stage ~= "play" then
			s.inHand = hs.players[seat] or nil
		end
		st.seats[seat] = s
	end
	if hs then
		st.hand = { key = hs.key, stage = hs.stage, left = max(0, floor((hs.deadline or self.now()) - self.now() + 0.5)) }
		if hs.stage == "reveals" or hs.stage == "play" then
			st.hand.commits = hs.commits
		end
		if hand then
			local h = st.hand
			h.button, h.street, h.board, h.toAct, h.cur, h.dh, h.log = hand.button, hand.street, hand.board, hand.toAct, hand.currentBet, hs.deckHash, hand.log
			h.sb, h.bb = hand.sbSeat, hand.bbSeat
			local pot = 0
			for _, p in pairs(hand.seats) do pot = pot + p.total end
			h.pot = pot
			if mySeat then
				h.legal = Engine:Legal(hand, mySeat)
			end
			if hand.results then
				local r = hand.results
				h.results = { payouts = r.payouts, returned = r.returned, pots = {} }
				for i, pot in ipairs(r.pots) do
					h.results.pots[i] = { amount = pot.amount, winners = pot.winners, description = pot.description, best = pot.best, eligible = pot.eligible }
				end
			end
		end
	end
	if self.phase == "showdown" or self.phase == "waiting" then
		st.nextIn = max(0, floor(self.nextHandAt - self.now() + 0.5))
	end
	return st
end

function Table:SendState(name, kind)
	self.lastSent = self.now()
	self.send(name, { k = kind, t = self.id, st = self:StateFor(name) })
end

---What the next seat needs to carry the table on: settings, seats and stacks, the hand count and term.
function Table:BackupData()
	local seats = {}
	for seat, p in pairs(self.seats) do
		seats[seat] = { name = p.name, stack = p.stack, bought = p.bought, out = p.out or nil }
	end
	return { id = self.id, cfg = self.cfg, seats = seats, handNo = self.handNo, term = self.term, button = self.button, host = self.name }
end

function Table:Backup()
	local seat = self:Successor()
	if seat and self.seats[seat] then
		self.send(self.seats[seat].name, { k = "backup", t = self.id, b = self:BackupData() })
	end
end

---Tells every seat this is the table's host now (after a takeover), with their state.
function Table:AnnounceTakeover()
	self:Bump()
	for _, p in pairs(self.seats) do
		self.send(p.name, { k = "takeover", t = self.id, st = self:StateFor(p.name) })
	end
	self:Backup()
	self.nextHandAt = self.now() + 2
end
