-- Wanted: Dead Man's Hand Poker. The host's side of a table: seats, the secret round before each hand
-- (Deal), the engine (Engine), turn timers, the state every player is sent, the audit after each hand, and the
-- backup the next seat keeps so it can take the table over if the host vanishes. Pure: it sends through the
-- function it's given and asks the clock it's given, so the tests run a host and several players in one place.
-- The host plays too: their own client talks to this through the same messages, delivered locally (Net).
-- Gold tables are cash on the table: a seat's buy-in goes to the host first (by trade or mail; Gold sees it arrive
-- and calls Paid) and the seat is dealt in once it has; when a player leaves, the host owes them their stack, as a
-- settlement line. Nobody but the host ever owes anyone, so no seat can run up a debt.
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
---@param o table { name, id?, cfg, send = fun(target, tbl), ad = fun(tbl)?, now = fun(): number, on = fun(event, ...)?,
---blocked = fun(): boolean? (the game is refusing our messages: the clocks stop) }
---@return table? table
---@return string? reason
function Host:New(o)
	local cfg, reason = Protocol:Settings(o.cfg)
	if not cfg then
		return nil, reason
	end
	local now = o.now()
	local t = setmetatable({
		name = o.name, id = o.id or Protocol:NewId(o.name, now), cfg = cfg, send = o.send, ad = o.ad, now = o.now, on = o.on or function() end, blocked = o.blocked,
		term = o.term or 1, seq = 0, handNo = o.handNo or 0, attempt = 0,
		seats = {}, -- seat -> { name, stack, out (false, or why: "away", "missed", "busted"), away (timeouts and misses in a row), since }
		phase = "waiting", -- waiting | seeding | playing | showdown | closed
		hand = nil, -- the engine's hand while one is played
		hs = nil, -- the hand's session: players, commits, secrets, deck, deadline, stage, setup
		button = o.button, open = true, nextHandAt = now, lastSent = now, lastAd = 0,
		password = type(o.password) == "string" and o.password ~= "" and strlower(strtrim(o.password)) or nil, -- asked of anyone sitting down; never sent in the state
		startedAt = o.elapsed and (now - o.elapsed) or nil, -- a tournament under way, and since when
		entrants = o.entrants or {}, -- a tournament's players, by name: { seat, outNo?, place?, left? }, kept after they bust or leave
		outCount = o.outCount or 0, -- how many entrants have gone out (busted or left), for their places
		settled = o.settled,
	}, Table)
	for seat, p in pairs(o.seats or {}) do
		t.seats[seat] = { name = p.name, class = p.class, stack = p.stack, bought = p.bought or p.stack, out = type(p.out) == "string" and p.out or false, away = 0, since = now }
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
			seats[seat] = { name = p.name, class = Protocol:IsClass(p.class) and p.class or nil, stack = p.stack, bought = p.bought, out = p.out }
		end
	end
	return Host:New({ name = o.name, id = backup.id, cfg = backup.cfg, send = o.send, ad = o.ad, now = o.now, on = o.on, blocked = o.blocked,
		term = (tonumber(backup.term) or 1) + 1, handNo = tonumber(backup.handNo) or 0, button = backup.button, seats = seats,
		elapsed = tonumber(backup.elapsed), entrants = type(backup.entrants) == "table" and backup.entrants or nil, settled = tonumber(backup.settled), password = backup.password, outCount = tonumber(backup.outCount) })
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
function Table:Sit(name, buyin, class)
	if not self.open then
		return nil, "the table is closed"
	end
	if self:SeatOf(name) then
		return nil, "you're already seated"
	end
	local tournament = self.cfg.kind == "tournament"
	if tournament and self.startedAt and (self.phase == "finished" or self:Level() > (self.cfg.lateLevels or 0)) then
		return nil, (self.cfg.lateLevels or 0) > 0 and "late entry has closed" or "the tournament has started"
	end
	if not Protocol:IsCount(buyin, self.cfg.buyMin, self.cfg.buyMax) then
		return nil, tournament and ("the entry is %s"):format(Protocol:Money(self.cfg.entry, self.cfg.stakes)) or ("the buy-in is %d to %d"):format(self.cfg.buyMin, self.cfg.buyMax)
	end
	for seat = 1, self.cfg.maxSeats do
		if not self.seats[seat] then
			-- At a gold table the seat waits, with no chips, until the buy-in has reached the host (Paid)
			local owes = self.cfg.stakes == "gold" and name ~= self.name and buyin > 0
			self.seats[seat] = { name = name, class = Protocol:IsClass(class) and class or nil, stack = owes and 0 or (tournament and self.cfg.startStack or buyin), bought = owes and 0 or buyin, out = false, away = 0, since = self.now(),
				unpaid = owes and buyin or nil, received = owes and 0 or nil }
			if tournament then
				self.entrants[name] = { seat = seat }
				self:Replace()
			end
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
	if p.unpaid then
		-- Never dealt in: whatever part of the buy-in arrived goes back
		if (p.received or 0) > 0 then self:SettleAmount(name, p.received, "refund") end
		if self.cfg.kind == "tournament" then self.entrants[name] = nil end
		self.on("stood", name, seat, 0)
		return
	end
	if self.cfg.kind == "tournament" then
		if self.startedAt and self.phase ~= "finished" and self.entrants[name] and not self.entrants[name].place then
			-- Out of the running: the entry forfeited, their chips out of play, placed by the order they went out
			self.outCount = (self.outCount or 0) + 1
			self.entrants[name].outNo, self.entrants[name].left = self.outCount, true
			self:Replace()
			self.on("eliminated", name, self.entrants[name].place)
			-- The last one standing wins: now, or once the hand under way has been shown
			if self:PlaceNow() <= 2 then
				if self.hand and self.hand.street ~= "done" then
					self.finishPending = true
				else
					self.finishLater = true
				end
			end
		elseif not self.startedAt then
			self.entrants[name] = nil
		end
	else
		self:Settle(seat, p)
	end
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

---The seat that takes the table over if this host vanishes, or is handed it: the next seated player after the host
---whose client is answering, else the next seated player.
---@return number? seat
function Table:Successor()
	local mine = self:SeatOf(self.name)
	local after = self:After(mine or 0)
	for _, seat in ipairs(after) do
		local p = self.seats[seat]
		if p and p.out ~= "missed" and p.away == 0 and not p.unpaid then return seat end
	end
	return after[1]
end

-- ============================================================================
-- Handing the table on
-- ============================================================================

---Hands the table to the next seat: everyone is told who, and the successor gets the backup to carry on from. The
---table runs on here until the successor announces, or HANDOFF_SECONDS pass. Never at a gold table: the host holds
---the money, and the books stay with one bank from the first buy-in to the last cash-out.
---@return boolean ok
---@return string? reason
function Table:Handoff()
	if not self.open or self.phase == "finished" then
		return false, "the table is over"
	end
	if self.cfg.stakes == "gold" then
		return false, "a gold table stays with the host who holds the money"
	end
	local seat = self:Successor()
	if not seat then
		return false, "nobody to hand the table to"
	end
	local name = self.seats[seat].name
	self.handingTo, self.handingAt = name, self.now()
	self:Bump()
	for _, p in pairs(self.seats) do
		self.send(p.name, { k = "handoff", t = self.id, to = name, b = p.name == name and self:BackupData() or nil })
	end
	self.on("handing", name)
	return true
end

---The successor announced (this host's own seat heard a takeover): the table is theirs now.
---@return boolean handed
function Table:Handed()
	if not self.handingTo then
		return false
	end
	self.open = false
	self.phase = "handed"
	self.hand, self.hs = nil, nil
	self.on("handed", self.handingTo)
	return true
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
		local seat, reason
		if self.password and (type(tbl.pw) ~= "string" or strlower(strtrim(tbl.pw)) ~= self.password) then
			reason = "wrong password"
		else
			seat, reason = self:Sit(sender, tbl.b, tbl.c)
		end
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
		if self.cfg.kind ~= "tournament" and not p.unpaid and Protocol:IsCount(tbl.b, 1) and p.stack + (p.pendingChips or 0) + tbl.b <= self.cfg.buyMax then
			if self.cfg.stakes == "gold" and sender ~= self.name then
				-- The chips come once the money has (Paid)
				p.rebuyDue = tbl.b
				self:Bump()
				self:Broadcast()
			elseif not inHand then
				self:AddChips(seat, tbl.b)
				self.on("rebuy", sender, seat, tbl.b)
				self:Bump()
				self:Broadcast()
				self:Backup()
			end
		end
	elseif k == "commit" then
		self:OnCommit(seat, tbl)
	elseif k == "reveal" then
		self:OnReveal(seat, tbl)
	elseif k == "act" then
		self:OnAct(seat, tbl)
	elseif k == "say" then
		-- Table talk, relayed to everyone: one of the set lines, not too often
		local p = self.seats[seat]
		if Protocol:IsCount(tbl.e, 1, #Protocol.EMOTES) and self.now() - (p.saidAt or -math.huge) >= Protocol.SAY_SECONDS then
			p.saidAt = self.now()
			for _, q in pairs(self.seats) do
				self.send(q.name, { k = "said", t = self.id, s = seat, e = tbl.e })
			end
		end
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
-- Money in (gold tables)
-- ============================================================================

---Adds chips to a seat: now between hands, or once the hand under way is over.
---@param seat number
---@param chips number
function Table:AddChips(seat, chips)
	local p = self.seats[seat]
	local inHand = self.hand and self.hand.street ~= "done" and self.hand.seats[seat]
	p.bought = (p.bought or 0) + chips
	if inHand then
		p.pendingChips = (p.pendingChips or 0) + chips
	else
		p.stack = p.stack + chips
		p.out, p.away = false, 0
	end
end

-- Chips bought during a hand join the stacks once it's over
function Table:ApplyPendingChips()
	for _, p in pairs(self.seats) do
		if p.pendingChips then
			p.stack = p.stack + p.pendingChips
			p.pendingChips = nil
			if p.out == "busted" then p.out, p.away = false, 0 end
		end
	end
end

---Money from a player reached the host (a trade, a mail: Gold). It pays the seat's buy-in, or the rebuy they asked
---for; anything over, or money nobody asked for, is owed straight back. Returns whether it was something due.
---@param name string
---@param silver number
---@param how string "trade" | "mail"
---@return boolean due
function Table:Paid(name, silver, how)
	if self.cfg.stakes ~= "gold" or not Protocol:IsCount(silver, 1) or name == self.name then
		return false
	end
	local seat, p = self:SeatOf(name)
	if p and p.unpaid then
		p.received = (p.received or 0) + silver
		if p.received >= p.unpaid then
			local extra = p.received - p.unpaid
			p.bought = p.unpaid
			p.stack = self.cfg.kind == "tournament" and self.cfg.startStack or p.unpaid
			p.unpaid, p.received, p.paidHow = nil, nil, how
			self.on("paid", name, seat, p.bought)
			if extra > 0 then self:SettleAmount(name, extra, "refund") end
			self:Backup()
		end
		self:Bump()
		self:Broadcast()
		return true
	end
	if p and p.rebuyDue then
		if silver >= p.rebuyDue then
			local extra = silver - p.rebuyDue
			self:AddChips(seat, p.rebuyDue)
			self.on("rebuy", name, seat, p.rebuyDue)
			p.rebuyDue = nil
			if extra > 0 then self:SettleAmount(name, extra, "refund") end
		else
			-- Short of the rebuy asked: it goes back, the rebuy stays asked
			self:SettleAmount(name, silver, "refund")
		end
		self:Bump()
		self:Broadcast()
		self:Backup()
		return true
	end
	self:SettleAmount(name, silver, "refund")
	return false
end

---The host says the money came, by their own eyes (a trade or mail the client didn't see), and how much: a seat
---waiting for its buy-in is dealt in with that much, within the table's range (a tournament's entry exactly, anything
---over owed back); a rebuy asked for is filled with it. Returns whether, and why not.
---@param name string
---@param amount number copper
---@return boolean ok
---@return string? reason
function Table:Admit(name, amount)
	if self.cfg.stakes ~= "gold" or not Protocol:IsCount(amount, 1) then
		return false, "a whole amount of money"
	end
	local seat, p = self:SeatOf(name)
	if not p then
		return false, "not at the table"
	end
	local tournament = self.cfg.kind == "tournament"
	if p.unpaid then
		if tournament and amount < self.cfg.entry then
			return false, ("the entry is %s"):format(Protocol:Money(self.cfg.entry, "gold"))
		end
		if not tournament and (amount < self.cfg.buyMin or amount > self.cfg.buyMax) then
			return false, ("the buy-in is %s to %s"):format(Protocol:Money(self.cfg.buyMin, "gold"), Protocol:Money(self.cfg.buyMax, "gold"))
		end
		local received = p.received or 0
		p.bought = tournament and self.cfg.entry or amount
		p.stack = tournament and self.cfg.startStack or amount
		p.unpaid, p.received, p.paidHow = nil, nil, "hand"
		self.on("paid", name, seat, p.bought)
		self.on("admitted", name, amount)
		local extra = received + amount - p.bought
		if extra > 0 then self:SettleAmount(name, extra, "refund") end
	elseif p.rebuyDue then
		local room = self.cfg.buyMax - p.stack - (p.pendingChips or 0)
		local chips = min(amount, room)
		if chips >= 1 then
			self:AddChips(seat, chips)
			self.on("rebuy", name, seat, chips)
		end
		p.rebuyDue = nil
		self.on("admitted", name, amount)
		if amount - max(chips, 0) > 0 then self:SettleAmount(name, amount - max(chips, 0), "refund") end
	else
		return false, "nothing due from them"
	end
	self:Bump()
	self:Broadcast()
	self:Backup()
	return true
end

---What the host holds for the players at the table, in copper: every paid seat's buy-ins and rebuys.
---@return number
function Table:Holding()
	local total = 0
	if self.cfg.stakes == "gold" then
		for _, p in pairs(self.seats) do
			if p.name ~= self.name and not p.unpaid then total = total + (p.bought or 0) end
		end
	end
	return total
end

-- ============================================================================
-- The hand
-- ============================================================================

-- Who is dealt in: seated, paid up, not sitting out, with chips
function Table:Players()
	local players, n = {}, 0
	local tournament = self.cfg.kind == "tournament"
	for seat, p in pairs(self.seats) do
		if p.stack > 0 and not p.unpaid and (tournament or not p.out) then
			players[seat] = true
			n = n + 1
		end
	end
	return players, n
end

---A tournament's level now: 1 at the start, one more every levelMinutes.
---@return number level
---@return number secondsLeft in this level
function Table:Level()
	if self.cfg.kind ~= "tournament" or not self.startedAt then
		return 1, 0
	end
	local length = self.cfg.levelMinutes * 60
	local elapsed = self.now() - self.startedAt
	local level = min(#Protocol.SCHEDULE, floor(elapsed / length) + 1)
	return level, max(0, length - (elapsed % length))
end

---The ante for the next hand: a tournament with antes on takes a tenth of the big blind from everyone from
---ANTE_FROM_LEVEL; otherwise the table's own ante (none, for now).
---@return number
function Table:Ante()
	if self.cfg.kind == "tournament" then
		if not self.cfg.antes then return 0 end
		local level = self:Level()
		if level < Protocol.ANTE_FROM_LEVEL then return 0 end
		return max(1, floor(Protocol.SCHEDULE[level][2] / 10))
	end
	return self.cfg.ante or 0
end

---Whether a tournament still takes entrants: not started, or under way with late entry open.
---@return boolean
function Table:LateEntryOpen()
	return self.cfg.kind == "tournament" and self.startedAt ~= nil and self.phase ~= "finished" and self:Level() <= (self.cfg.lateLevels or 0)
end

---Places every entrant by the order they went out: the first out finishes last, however many entered after them.
function Table:Replace()
	local n = 0
	for _ in pairs(self.entrants) do n = n + 1 end
	for name, e in pairs(self.entrants) do
		if e.outNo then
			e.place = n - e.outNo + 1
			local _, p = self:SeatOf(name)
			if p then p.place = e.place end
		end
	end
end

---The blinds for the next hand: the table's, or a tournament's level.
---@return number sb
---@return number bb
function Table:Blinds()
	if self.cfg.kind == "tournament" then
		local level = self:Level()
		return Protocol.SCHEDULE[level][1], Protocol.SCHEDULE[level][2]
	end
	return self.cfg.sb, self.cfg.bb
end

---Starts a tournament: no more seats, the clock runs, the first hand is dealt.
---@return boolean ok
---@return string? reason
function Table:Start()
	if self.cfg.kind ~= "tournament" then
		return false, "not a tournament"
	end
	if self.startedAt then
		return false, "it has started"
	end
	-- Whoever hasn't paid their entry by now isn't in
	for _, seat in ipairs(self:Seated()) do
		if self.seats[seat].unpaid then self:Stand(self.seats[seat].name) end
	end
	if #self:Seated() < Protocol.MIN_SEATS then
		return false, "it takes at least two paid-up players"
	end
	self.startedAt = self.now()
	self.nextHandAt = self.now()
	self:Bump()
	self:Broadcast()
	self:Backup()
	if self.ad then self:Advertise() end
	return true
end

---The place a player going out now finishes in: one more than the players still holding chips.
function Table:PlaceNow()
	local alive = 0
	for _, p in pairs(self.seats) do
		if p.stack > 0 then alive = alive + 1 end
	end
	return alive + 1
end

---Calls the next hand: every player makes a secret and sends its commitment.
function Table:StartSeedRound()
	if self.cfg.kind == "tournament" and (not self.startedAt or self.phase == "finished") then
		return false
	end
	self:ApplyPendingChips()
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
			if self.cfg.kind == "tournament" and hs.stage == "commits" then
				-- An absent entrant can't hold the table up: a big blind a hand leaves play until they're out
				local _, bb = self:Blinds()
				p.stack = max(0, p.stack - bb)
				if p.stack == 0 then
					self:Eliminate(seat)
				end
			end
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
	local sb, bb = self:Blinds()
	local ante = self:Ante()
	hs.setup = { seats = Copy(seats), button = button, sb = sb, bb = bb, ante = ante }
	hs.level = self:Level()
	self.hand = Engine:NewHand({ seats = seats, button = button, sb = sb, bb = bb, ante = ante, deck = deck })
	Engine:Start(self.hand)
	hs.stage = "play"
	self.phase = "playing"
	self.attempt = 0
	self.on("dealt", self.handNo)
	self:AfterAction()
end

function Table:AfterAction()
	-- A tournament deals in players sitting out, and plays their turn for them at once
	if self.cfg.kind == "tournament" then
		local hand = self.hand
		local guard = 0
		while hand.street ~= "done" and hand.toAct and self.seats[hand.toAct] and self.seats[hand.toAct].out and guard < 20 do
			guard = guard + 1
			local legal = Engine:Legal(hand, hand.toAct)
			Engine:Act(hand, hand.toAct, legal and legal.check and "check" or "fold")
		end
	end
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
	local busted = {}
	for seat, p in pairs(hand.seats) do
		if self.seats[seat] then
			self.seats[seat].stack = p.stack
			if p.stack == 0 then
				self.seats[seat].out = "busted"
				busted[#busted + 1] = seat
			end
		end
	end
	if self.cfg.kind == "tournament" and #busted > 0 then
		-- Two out in one hand: the one who started it with fewer chips goes out first, so places lower
		sort(busted, function(a, b) return (hs.setup.seats[a] and hs.setup.seats[a].stack or 0) < (hs.setup.seats[b] and hs.setup.seats[b].stack or 0) end)
		for _, seat in ipairs(busted) do
			self:Eliminate(seat)
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
	if self.cfg.kind == "tournament" and self:PlaceNow() <= 2 then
		-- One player holds every chip: the tournament ends once the hand has been shown
		self.finishPending = true
	end
	self:Backup()
end

---A tournament entrant is out: placed by the order they went out (the first out finishes last).
---@param seat number
function Table:Eliminate(seat)
	local p = self.seats[seat]
	if not p then return end
	local entrant = self.entrants[p.name]
	if entrant and not entrant.outNo and not entrant.place then
		self.outCount = (self.outCount or 0) + 1
		entrant.outNo = self.outCount
		p.out = "busted"
		self:Replace()
		self.on("eliminated", p.name, entrant.place)
	end
end

---A tournament's standings: every entrant by place (the winner first).
---@return table[] { name, place, prize?, seat }
function Table:Standings()
	local list = {}
	for name, e in pairs(self.entrants) do
		list[#list + 1] = { name = name, place = e.place, seat = e.seat, left = e.left }
	end
	sort(list, function(a, b) return (a.place or 0) < (b.place or 0) end)
	return list
end

---Ends a tournament: the last player with chips wins, the prizes are set by place, and at a gold table every
---entrant's prize less their entry is settled with the host.
function Table:Finish()
	if self.phase == "finished" then return end
	for _, p in pairs(self.seats) do
		if p.stack > 0 and self.entrants[p.name] and not self.entrants[p.name].place then
			self.entrants[p.name].place = 1
			p.place = 1
		end
	end
	local entrants = 0
	for _ in pairs(self.entrants) do entrants = entrants + 1 end
	local prizes = Protocol:Prizes(self.cfg.entry * entrants, entrants)
	for name, e in pairs(self.entrants) do
		e.prize = (not e.left and e.place and prizes[e.place]) or 0
		if e.prize > 0 then
			self:SettleAmount(name, e.prize, "prize")
		end
	end
	self.phase = "finished"
	self.hand, self.hs = nil, nil
	self.finishPending = nil
	self:Bump()
	self:Broadcast()
	self.on("finished", self:Standings())
	if self.ad then
		self.open = false
		self:Advertise()
	end
	self:Backup()
end

---Owes a player an amount of money: their stack when they leave ("cashout"), a tournament prize ("prize"), money
---back ("refund"). The host holds the money, so every line runs from the host to a player. Gold tables only.
---@param name string
---@param amount number silver
---@param kind string
function Table:SettleAmount(name, amount, kind)
	if self.cfg.stakes ~= "gold" or name == self.name or not Protocol:IsCount(amount, 1) then
		return
	end
	self.settled = (self.settled or 0) + 1
	local line = { id = self.id..":"..self.settled, table = self.id, title = self.cfg.title, host = self.name, at = time(),
		from = self.name, to = name, amount = amount, kind = kind or "cashout" }
	self.send(name, { k = "settle", t = self.id, l = line })
	self.on("settle", line)
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
	local finished = self.phase == "finished"
	self.phase = "closed"
	self.hand, self.hs = nil, nil
	self:ApplyPendingChips()
	self:Bump()
	self:Broadcast()
	for seat, p in pairs(self.seats) do
		if p.unpaid then
			if (p.received or 0) > 0 then self:SettleAmount(p.name, p.received, "refund") end
		elseif self.cfg.kind ~= "tournament" then
			self:Settle(seat, p)
		elseif not finished then
			-- A tournament cut short: every entry goes back
			self:SettleAmount(p.name, p.bought or 0, "refund")
		end
	end
	self.on("closed", finished)
end

---At a gold table the host holds the money: a player who leaves (or is at the table when it closes) is owed their
---stack. The player is sent the line, and the host's own ledger gets it (on "settle"). Chips tables settle nothing.
---@param seat number
---@param p table the seat's record
function Table:Settle(seat, p)
	if self.cfg.stakes ~= "gold" or p.name == self.name then
		return
	end
	self:SettleAmount(p.name, p.stack + (p.pendingChips or 0), "cashout")
end

-- ============================================================================
-- Time
-- ============================================================================

---Runs the clock: deadlines, the next hand, heartbeats and ads. Call about once a second.
function Table:Tick()
	if not self.open or self.phase == "finished" then
		if self.phase == "finished" and self.open and self.now() - self.lastSent >= Protocol.BEAT_SECONDS then self:Beat() end
		return
	end
	local now = self.now()
	local since = self.lastTick and (now - self.lastTick) or 0
	self.lastTick = now
	if self.blocked and self.blocked() then
		-- The game is refusing our messages (a boss fight, a PvP match): every clock stops where it is, and the beat
		-- goes on so we learn when they go through again
		if self.hs and self.hs.deadline then self.hs.deadline = self.hs.deadline + since end
		self.nextHandAt = self.nextHandAt + since
		if self.startedAt then self.startedAt = self.startedAt + since end
		self.wasBlocked = true
		if now - self.lastSent >= Protocol.BEAT_SECONDS then
			self:Beat()
		end
		return
	elseif self.wasBlocked then
		-- Through again: everyone gets the table as it stands, clocks included
		self.wasBlocked = nil
		self:Bump()
		self:Broadcast()
	end
	-- A successor who never took the table: it carries on here
	if self.handingTo and now - self.handingAt >= Protocol.HANDOFF_SECONDS then
		local name = self.handingTo
		self.handingTo, self.handingAt = nil, nil
		self.on("handoffFailed", name)
	end
	-- A seat whose buy-in never came is given up
	for _, seat in ipairs(self:Seated()) do
		local p = self.seats[seat]
		if p and p.unpaid and now - p.since >= Protocol.PAY_SECONDS then
			self:Stand(p.name)
			self.on("unpaid", p.name)
			self:Bump()
			self:Broadcast()
		end
	end
	if self.phase == "waiting" and now >= self.nextHandAt then
		self:StartSeedRound()
	elseif self.phase == "seeding" and now >= self.hs.deadline then
		self:SeedDeadline()
	elseif self.phase == "playing" and now >= self.hs.deadline then
		self:TimeOut()
	elseif self.finishLater and self.phase ~= "playing" then
		self.finishLater = nil
		return self:Finish()
	elseif self.phase == "showdown" and now >= self.nextHandAt then
		if self.finishPending then
			return self:Finish()
		end
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
	if not self.ad then
		return -- a practice table is nobody's business
	end
	self.lastAd = self.now()
	local taken = #self:Seated()
	local sb, bb = self:Blinds()
	self.ad({ id = self.id, h = self.name, n = self.cfg.title, s = taken, m = self.cfg.maxSeats, sb = sb, bb = bb,
		g = self.cfg.stakes == "gold" and 1 or nil, lo = self.cfg.buyMin, hi = self.cfg.buyMax, c = (not self.open or self.phase == "finished") and 1 or nil,
		k = self.cfg.kind == "tournament" and "t" or nil, e = self.cfg.entry, ss = self.cfg.startStack, lm = self.cfg.levelMinutes, on = self.startedAt and 1 or nil,
		la = self:LateEntryOpen() and 1 or nil, ll = self.cfg.lateLevels, lv = self.startedAt and self:Level() or nil, an = self.cfg.antes and 1 or nil,
		p = self.password and 1 or nil })
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
	if self.cfg.kind == "tournament" then
		local level, left = self:Level()
		st.started = self.startedAt ~= nil
		st.level, st.levelLeft = level, floor(left + 0.5)
		st.levelBlinds = Protocol.SCHEDULE[level]
		st.ante = self:Ante()
		st.antes = self.cfg.antes or nil
		st.lateLevels = self.cfg.lateLevels
		st.lateOpen = self:LateEntryOpen() or nil
		local nextLevel = Protocol.SCHEDULE[level + 1]
		st.nextBlinds = nextLevel
		if self.phase == "finished" or self.phase == "closed" then
			st.standings = self:Standings()
			for _, row in ipairs(st.standings) do row.prize = self.entrants[row.name] and self.entrants[row.name].prize end
		end
	end
	for seat, p in pairs(self.seats) do
		local s = { n = p.name, c = p.class, s = p.stack, bought = p.bought, out = p.out or nil, away = p.away > 0 and p.away or nil, place = p.place,
			unpaid = p.unpaid, received = p.unpaid and p.received or nil, rebuyDue = p.rebuyDue, pending = p.pendingChips }
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
	if self.cfg.stakes == "gold" then
		st.holding = self:Holding()
	end
	if self.handingTo then
		st.handingTo = self.handingTo
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
		seats[seat] = { name = p.name, class = p.class, stack = p.stack, bought = p.bought, out = p.out or nil }
	end
	return { id = self.id, cfg = self.cfg, seats = seats, handNo = self.handNo, term = self.term, button = self.button, host = self.name,
		elapsed = self.startedAt and (self.now() - self.startedAt) or nil, entrants = self.cfg.kind == "tournament" and self.entrants or nil, settled = self.settled,
		password = self.password, outCount = self.outCount }
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
