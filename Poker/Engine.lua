-- Wanted: the hold'em engine. No-limit Texas hold'em for one table: blinds and antes, the four streets, the
-- minimum raise, all-ins and side pots, the showdown and the split of each pot. Pure Lua with no game calls,
-- so the same code runs the host's table, each client's replay of the host's audit, and the tests. A hand is a
-- plain table (NewHand, Start, Act, Leave) that records every action in its log; Replay runs a log again over
-- the same deck, which is how a client checks the host's settlement (PokerDeal).
-- Cards are 1..52: 2c is 1, Ac 13, 2d 14 ... As 52. Ranks run 2..14 with the ace high; suits 1..4 are clubs,
-- diamonds, hearts, spades.
local _, Poker = ...
local Engine = Poker:NewModule("PokerEngine")

local RANK_NAMES = { [2] = "2", [3] = "3", [4] = "4", [5] = "5", [6] = "6", [7] = "7", [8] = "8", [9] = "9", [10] = "T", [11] = "J", [12] = "Q", [13] = "K", [14] = "A" }
local SUIT_NAMES = { "c", "d", "h", "s" }
local RANK_WORDS = { [2] = "two", [3] = "three", [4] = "four", [5] = "five", [6] = "six", [7] = "seven", [8] = "eight", [9] = "nine", [10] = "ten", [11] = "jack", [12] = "queen", [13] = "king", [14] = "ace" }
local RANK_PLURALS = { [2] = "twos", [3] = "threes", [4] = "fours", [5] = "fives", [6] = "sixes", [7] = "sevens", [8] = "eights", [9] = "nines", [10] = "tens", [11] = "jacks", [12] = "queens", [13] = "kings", [14] = "aces" }
local CATEGORY_NAMES = { "high card", "pair", "two pair", "three of a kind", "straight", "flush", "full house", "four of a kind", "straight flush" }
local NEXT_STREET = { preflop = "flop", flop = "turn", turn = "river", river = "showdown" }
local ACTIONS = { fold = true, check = true, call = true, bet = true, raise = true, allin = true }

-- ============================================================================
-- Cards
-- ============================================================================

---@param rank number 2..14
---@param suit number 1..4
---@return number card
function Engine:Card(rank, suit)
	return (suit - 1) * 13 + (rank - 1)
end

---@param card number
---@return number rank 2..14
function Engine:RankOf(card)
	return (card - 1) % 13 + 2
end

---@param card number
---@return number suit 1..4
function Engine:SuitOf(card)
	return floor((card - 1) / 13) + 1
end

---A card's short name: "Ah", "Tc".
---@param card number
---@return string
function Engine:Name(card)
	return RANK_NAMES[Engine:RankOf(card)]..SUIT_NAMES[Engine:SuitOf(card)]
end

-- ============================================================================
-- Hand ranking
-- ============================================================================

-- A score orders every hand: the category first, then up to five ranks that break ties within it (the pair's
-- rank before the kickers, a flush's cards from the top down). Equal scores are a split.
local function Score(category, values)
	local s = category
	for i = 1, 5 do
		s = s * 15 + (values[i] or 0)
	end
	return s
end

local function ByRankDesc(a, b)
	return Engine:RankOf(a) > Engine:RankOf(b)
end

-- The highest five-card run among rankToCard (rank -> a card of that rank), the ace counting low too
local function Straight(rankToCard)
	for high = 14, 5, -1 do
		local run = {}
		for r = high, high - 4, -1 do
			local card = rankToCard[r == 1 and 14 or r]
			if not card then
				run = nil
				break
			end
			run[#run + 1] = card
		end
		if run then
			return high, run
		end
	end
end

-- The top n cards by rank that aren't in `taken`
local function Kickers(cards, taken, n)
	local out, ranks = {}, {}
	for _, c in ipairs(cards) do
		if not taken[c] then
			out[#out + 1] = c
		end
	end
	sort(out, ByRankDesc)
	while #out > n do
		out[#out] = nil
	end
	for i, c in ipairs(out) do
		ranks[i] = Engine:RankOf(c)
	end
	return out, ranks
end

local function Append(list, cards, n)
	local taken = {}
	for i = 1, math.min(n or #cards, #cards) do
		list[#list + 1] = cards[i]
		taken[cards[i]] = true
	end
	return taken
end

---Ranks five to seven cards.
---@param cards number[]
---@return number score higher wins, equal splits
---@return string category "pair", "flush", ...
---@return number[] best the five cards that make the hand
function Engine:Evaluate(cards)
	local byRank, bySuit = {}, {}
	for _, c in ipairs(cards) do
		local r, s = Engine:RankOf(c), Engine:SuitOf(c)
		byRank[r] = byRank[r] or {}
		bySuit[s] = bySuit[s] or {}
		tinsert(byRank[r], c)
		tinsert(bySuit[s], c)
	end
	local flushSuit
	for s = 1, 4 do
		if bySuit[s] and #bySuit[s] >= 5 then
			flushSuit = s
		end
	end
	if flushSuit then
		local suited = {}
		for _, c in ipairs(bySuit[flushSuit]) do
			suited[Engine:RankOf(c)] = c
		end
		local high, run = Straight(suited)
		if high then
			return Score(9, { high }), CATEGORY_NAMES[9], run
		end
	end
	local groups = {}
	for rank, list in pairs(byRank) do
		groups[#groups + 1] = { rank = rank, n = #list }
	end
	sort(groups, function(a, b)
		if a.n ~= b.n then return a.n > b.n end
		return a.rank > b.rank
	end)
	local first, second = groups[1], groups[2]
	if first.n == 4 then
		local best = {}
		local taken = Append(best, byRank[first.rank], 4)
		local kick, ranks = Kickers(cards, taken, 1)
		Append(best, kick)
		return Score(8, { first.rank, ranks[1] }), CATEGORY_NAMES[8], best
	end
	if first.n == 3 and second and second.n >= 2 then
		local best = {}
		Append(best, byRank[first.rank], 3)
		Append(best, byRank[second.rank], 2)
		return Score(7, { first.rank, second.rank }), CATEGORY_NAMES[7], best
	end
	if flushSuit then
		local suited = {}
		Append(suited, bySuit[flushSuit])
		sort(suited, ByRankDesc)
		local best, ranks = {}, {}
		for i = 1, 5 do
			best[i] = suited[i]
			ranks[i] = Engine:RankOf(suited[i])
		end
		return Score(6, ranks), CATEGORY_NAMES[6], best
	end
	do
		local any = {}
		for rank, list in pairs(byRank) do
			any[rank] = list[1]
		end
		local high, run = Straight(any)
		if high then
			return Score(5, { high }), CATEGORY_NAMES[5], run
		end
	end
	if first.n == 3 then
		local best = {}
		local taken = Append(best, byRank[first.rank], 3)
		local kick, ranks = Kickers(cards, taken, 2)
		Append(best, kick)
		return Score(4, { first.rank, ranks[1], ranks[2] }), CATEGORY_NAMES[4], best
	end
	if first.n == 2 and second and second.n == 2 then
		local best = {}
		local taken = Append(best, byRank[first.rank], 2)
		for c, v in pairs(Append(best, byRank[second.rank], 2)) do taken[c] = v end
		local kick, ranks = Kickers(cards, taken, 1)
		Append(best, kick)
		return Score(3, { first.rank, second.rank, ranks[1] }), CATEGORY_NAMES[3], best
	end
	if first.n == 2 then
		local best = {}
		local taken = Append(best, byRank[first.rank], 2)
		local kick, ranks = Kickers(cards, taken, 3)
		Append(best, kick)
		return Score(2, { first.rank, ranks[1], ranks[2], ranks[3] }), CATEGORY_NAMES[2], best
	end
	local best, ranks = Kickers(cards, {}, 5)
	return Score(1, ranks), CATEGORY_NAMES[1], best
end

---Says what a hand is: "a pair of aces", "two pair, aces and kings", "a nine-high straight".
---@param cards number[] five to seven cards
---@return string
function Engine:Describe(cards)
	local score, category, best = Engine:Evaluate(cards)
	local values = {}
	local v = score
	for i = 5, 1, -1 do
		values[i] = v % 15
		v = floor(v / 15)
	end
	local top = values[1]
	if category == "straight flush" then
		return top == 14 and "a royal flush" or ("a "..RANK_WORDS[top].."-high straight flush")
	elseif category == "four of a kind" then
		return "four "..RANK_PLURALS[top]
	elseif category == "full house" then
		return "a full house, "..RANK_PLURALS[top].." full of "..RANK_PLURALS[values[2]]
	elseif category == "flush" then
		return "a flush, "..RANK_WORDS[top].." high"
	elseif category == "straight" then
		return "a "..RANK_WORDS[top].."-high straight"
	elseif category == "three of a kind" then
		return "three "..RANK_PLURALS[top]
	elseif category == "two pair" then
		return "two pair, "..RANK_PLURALS[top].." and "..RANK_PLURALS[values[2]]
	elseif category == "pair" then
		return "a pair of "..RANK_PLURALS[top]
	end
	return RANK_WORDS[top].." high"
end

-- ============================================================================
-- A hand
-- ============================================================================

local function IsCount(n)
	return type(n) == "number" and n == floor(n) and n >= 0
end

-- The seat after `seat` at the table
local function Clockwise(hand, seat)
	local order = hand.order
	for i, s in ipairs(order) do
		if s == seat then
			return order[i % #order + 1]
		end
	end
	-- A seat not at the table: the first after it in number order
	for _, s in ipairs(order) do
		if s > seat then return s end
	end
	return order[1]
end

-- The next seat after `seat` that can still act: in the hand and not all-in
local function NextToAct(hand, seat)
	local s = seat
	for _ = 1, #hand.order do
		s = Clockwise(hand, s)
		local p = hand.seats[s]
		if not p.folded and not p.allin then
			return s
		end
	end
end

-- Puts up to `amount` of a seat's chips in front of them
local function Post(hand, seat, amount)
	local p = hand.seats[seat]
	local chips = math.min(amount, p.stack)
	p.stack = p.stack - chips
	p.bet = p.bet + chips
	p.total = p.total + chips
	if p.stack == 0 then
		p.allin = true
	end
	return chips
end

local function Draw(hand)
	local card = hand.deck[hand.next]
	hand.next = hand.next + 1
	return card
end

local function Active(hand)
	local n = 0
	for _, p in pairs(hand.seats) do
		if not p.folded and not p.allin then
			n = n + 1
		end
	end
	return n
end

local function Live(hand)
	local live = {}
	for _, seat in ipairs(hand.order) do
		if not hand.seats[seat].folded then
			live[#live + 1] = seat
		end
	end
	return live
end

---Sets up a hand: at least two seats with chips, the button on one of them, blinds, an optional ante and a
---shuffled deck of 52 (PokerDeal). Nothing is dealt until Start.
---@param o table { seats = { [seat] = { stack, name? } }, button, sb, bb, ante?, deck }
---@return table hand
function Engine:NewHand(o)
	assert(type(o) == "table" and type(o.seats) == "table", "a hand needs seats")
	local hand = { seats = {}, order = {}, button = o.button, sb = o.sb, bb = o.bb, ante = o.ante or 0, deck = {}, next = 1,
		board = {}, log = {}, acted = {}, barred = {}, currentBet = 0, lastRaiseSize = 0 }
	for seat, p in pairs(o.seats) do
		assert(IsCount(seat) and IsCount(p.stack) and p.stack > 0, "a seat is a number with a stack of chips")
		hand.seats[seat] = { stack = p.stack, name = p.name, bet = 0, total = 0, folded = false, allin = false, hole = {} }
		hand.order[#hand.order + 1] = seat
	end
	sort(hand.order)
	assert(#hand.order >= 2, "a hand takes at least two players")
	assert(hand.seats[hand.button], "the button is on a seat in the hand")
	assert(IsCount(hand.sb) and IsCount(hand.bb) and hand.bb > 0 and hand.sb <= hand.bb and IsCount(hand.ante), "blinds are whole numbers")
	assert(type(o.deck) == "table" and #o.deck == 52, "a deck of 52")
	local seen = {}
	for i, c in ipairs(o.deck) do
		assert(IsCount(c) and c >= 1 and c <= 52 and not seen[c], "a deck of 52 different cards")
		seen[c] = true
		hand.deck[i] = c
	end
	return hand
end

local Continue

-- Gathers the bets and deals the next street; with fewer than two players able to act, the board runs out
local function NextStreet(hand)
	for _, p in pairs(hand.seats) do
		p.bet = 0
	end
	hand.currentBet, hand.lastRaiseSize, hand.acted, hand.barred = 0, hand.bb, {}, {}
	local street = NEXT_STREET[hand.street]
	if street == "showdown" then
		return Engine.Settle(hand)
	end
	Draw(hand) -- the burn
	for _ = 1, street == "flop" and 3 or 1 do
		hand.board[#hand.board + 1] = Draw(hand)
	end
	hand.street = street
	if Active(hand) >= 2 then
		hand.toAct = NextToAct(hand, hand.button)
	else
		hand.toAct = nil
		return NextStreet(hand)
	end
end

-- Whether everyone still able to act has acted since the last full raise and matched the bet
local function RoundComplete(hand)
	for _, seat in ipairs(hand.order) do
		local p = hand.seats[seat]
		if not p.folded and not p.allin and (not hand.acted[seat] or p.bet ~= hand.currentBet) then
			return false
		end
	end
	return true
end

Continue = function(hand)
	if #Live(hand) == 1 then
		return Engine.Settle(hand)
	end
	if RoundComplete(hand) then
		return NextStreet(hand)
	end
end

---Posts the antes and blinds and deals the hole cards, one at a time from the seat left of the button. Heads up
---the button posts the small blind and acts first.
---@param hand table
function Engine:Start(hand)
	assert(not hand.street, "the hand has started")
	local n = #hand.order
	if hand.ante > 0 then
		for _, seat in ipairs(hand.order) do
			local p = hand.seats[seat]
			local chips = math.min(hand.ante, p.stack)
			p.stack, p.total = p.stack - chips, p.total + chips
			if p.stack == 0 then p.allin = true end
		end
	end
	local sbSeat = n == 2 and hand.button or Clockwise(hand, hand.button)
	local bbSeat = Clockwise(hand, sbSeat)
	Post(hand, sbSeat, hand.sb)
	Post(hand, bbSeat, hand.bb)
	hand.sbSeat, hand.bbSeat = sbSeat, bbSeat
	hand.currentBet, hand.lastRaiseSize = hand.bb, hand.bb
	local seat = Clockwise(hand, hand.button)
	for round = 1, 2 do
		for _ = 1, n do
			hand.seats[seat].hole[round] = Draw(hand)
			seat = Clockwise(hand, seat)
		end
	end
	hand.street = "preflop"
	hand.toAct = NextToAct(hand, bbSeat)
	if Active(hand) < 2 then
		-- The blinds put someone all-in and nobody else can act: nothing to decide
		if hand.toAct == nil or Active(hand) == 1 and RoundComplete(hand) then
			hand.toAct = nil
			return NextStreet(hand)
		end
	end
end

---What a seat may do now, or nil when it isn't their turn (or the hand is over).
---@param hand table
---@param seat number
---@return table? { fold, check?, call?, minBet?, maxBet?, minRaise?, maxRaise? } amounts in chips; bets and raises
---are the total in front of the player after the action
function Engine:Legal(hand, seat)
	if hand.street == nil or hand.street == "done" or hand.toAct ~= seat then
		return nil
	end
	local p = hand.seats[seat]
	local owe = hand.currentBet - p.bet
	local legal = { fold = true }
	if owe <= 0 then
		legal.check = true
	else
		legal.call = math.min(owe, p.stack)
	end
	if p.stack > owe and not hand.barred[seat] then
		local maxTo = p.bet + p.stack
		if hand.currentBet == 0 then
			legal.minBet, legal.maxBet = math.min(hand.bb, maxTo), maxTo
		else
			legal.minRaise, legal.maxRaise = math.min(hand.currentBet + hand.lastRaiseSize, maxTo), maxTo
		end
	end
	return legal
end

-- A bet or raise to `to` chips in front of the player. A full raise (at least the last raise) reopens the
-- betting; a short all-in doesn't: those who already acted may call or fold, not raise again.
local function RaiseTo(hand, seat, to)
	local size = to - hand.currentBet
	Post(hand, seat, to - hand.seats[seat].bet)
	hand.currentBet = to
	if size >= hand.lastRaiseSize then
		hand.lastRaiseSize, hand.acted, hand.barred = size, {}, {}
	else
		for s in pairs(hand.acted) do
			hand.barred[s] = true
		end
	end
end

---Plays an action for the seat whose turn it is: "fold", "check", "call", "bet" (to amount), "raise" (to
---amount), "allin". Returns whether it was legal, and why not.
---@param hand table
---@param seat number
---@param action string
---@param amount number?
---@return boolean ok
---@return string? reason
function Engine:Act(hand, seat, action, amount)
	local legal = Engine:Legal(hand, seat)
	if not legal then
		return false, "it isn't your turn"
	end
	if not ACTIONS[action] then
		return false, "no such action"
	end
	if amount ~= nil and not IsCount(amount) then
		return false, "the amount must be a whole number of chips"
	end
	local p = hand.seats[seat]
	local logged = amount
	if action == "fold" then
		p.folded = true
		logged = nil
	elseif action == "check" then
		if not legal.check then
			return false, "there is a bet to call"
		end
		logged = nil
	elseif action == "call" then
		if not legal.call then
			return false, "there is nothing to call"
		end
		Post(hand, seat, legal.call)
		logged = legal.call
	elseif action == "bet" then
		if hand.currentBet ~= 0 then
			return false, "there is a bet already: raise it"
		end
		if not legal.minBet then
			return false, "you can't bet"
		end
		if not amount or amount < legal.minBet or amount > legal.maxBet then
			return false, ("a bet is %d to %d"):format(legal.minBet, legal.maxBet)
		end
		RaiseTo(hand, seat, amount)
	elseif action == "raise" then
		if hand.currentBet == 0 then
			return false, "there is no bet to raise: bet"
		end
		if not legal.minRaise then
			return false, hand.barred[seat] and "that all-in didn't reopen the betting" or "you can't raise"
		end
		if not amount or amount < legal.minRaise or amount > legal.maxRaise then
			return false, ("a raise is to %d to %d"):format(legal.minRaise, legal.maxRaise)
		end
		RaiseTo(hand, seat, amount)
	elseif action == "allin" then
		local to = p.bet + p.stack
		if legal.maxBet or legal.maxRaise then
			RaiseTo(hand, seat, to)
		elseif legal.call then
			Post(hand, seat, legal.call)
		else
			return false, "you have no chips to put in"
		end
		logged = to
	end
	hand.log[#hand.log + 1] = { seat = seat, action = action, amount = logged }
	hand.acted[seat] = true
	hand.toAct = NextToAct(hand, seat)
	Continue(hand)
	return true
end

---Takes a seat out of the hand: a fold, whether or not it's their turn. Their chips stay in the pot.
---@param hand table
---@param seat number
function Engine:Leave(hand, seat)
	local p = hand.seats[seat]
	if not p or p.folded or hand.street == nil or hand.street == "done" then
		return
	end
	p.folded = true
	hand.log[#hand.log + 1] = { seat = seat, action = "leave" }
	if hand.toAct == seat then
		hand.toAct = NextToAct(hand, seat)
	end
	Continue(hand)
end

-- ============================================================================
-- The showdown
-- ============================================================================

-- Pots by contribution: everyone who put in at least a level's chips is in that layer, whoever hasn't folded
-- can win it, and a layer only one player reached is theirs back (an uncalled bet). Layers the same players
-- can win are one pot.
local function BuildPots(hand)
	local levels, seen = {}, {}
	for _, p in pairs(hand.seats) do
		if p.total > 0 and not seen[p.total] then
			seen[p.total] = true
			levels[#levels + 1] = p.total
		end
	end
	sort(levels)
	local pots, returned, prev = {}, {}, 0
	for _, level in ipairs(levels) do
		local contributors, eligible = {}, {}
		for _, seat in ipairs(hand.order) do
			local p = hand.seats[seat]
			if p.total >= level then
				contributors[#contributors + 1] = seat
				if not p.folded then
					eligible[#eligible + 1] = seat
				end
			end
		end
		local amount = (level - prev) * #contributors
		if #contributors == 1 or #eligible == 0 then
			for _, seat in ipairs(contributors) do
				returned[seat] = (returned[seat] or 0) + (level - prev)
			end
		else
			local last = pots[#pots]
			if last and table.concat(last.eligible, ",") == table.concat(eligible, ",") then
				last.amount = last.amount + amount
			else
				pots[#pots + 1] = { amount = amount, eligible = eligible }
			end
		end
		prev = level
	end
	return pots, returned
end

---Ends the hand: builds the pots, ranks the hands still in, pays the winners (the odd chip to the first winner
---left of the button) and returns any uncalled bet. Called by the engine; public for the replay.
---@param hand table
function Engine.Settle(hand)
	local pots, returned = BuildPots(hand)
	local live = Live(hand)
	local payouts, shown = {}, {}
	local scores = {}
	if #live >= 2 then
		for _, seat in ipairs(live) do
			local p = hand.seats[seat]
			local cards = { p.hole[1], p.hole[2] }
			for _, c in ipairs(hand.board) do cards[#cards + 1] = c end
			local score, _, best = Engine:Evaluate(cards)
			scores[seat] = { score = score, best = best, description = Engine:Describe(cards) }
			shown[seat] = { p.hole[1], p.hole[2] }
		end
	end
	for _, pot in ipairs(pots) do
		local winners
		if #pot.eligible == 1 or #live < 2 then
			winners = { pot.eligible[1] }
		else
			local top = -1
			for _, seat in ipairs(pot.eligible) do
				top = math.max(top, scores[seat].score)
			end
			winners = {}
			local seat = hand.button
			for _ = 1, #hand.order do
				seat = Clockwise(hand, seat)
				if scores[seat] and scores[seat].score == top then
					local eligible = false
					for _, e in ipairs(pot.eligible) do if e == seat then eligible = true end end
					if eligible then winners[#winners + 1] = seat end
				end
			end
			pot.description = scores[winners[1]].description
			pot.best = scores[winners[1]].best
		end
		pot.winners = winners
		local share = floor(pot.amount / #winners)
		local odd = pot.amount - share * #winners
		for i, seat in ipairs(winners) do
			local won = share + (i <= odd and 1 or 0)
			payouts[seat] = (payouts[seat] or 0) + won
		end
	end
	for seat, amount in pairs(payouts) do
		hand.seats[seat].stack = hand.seats[seat].stack + amount
	end
	for seat, amount in pairs(returned) do
		hand.seats[seat].stack = hand.seats[seat].stack + amount
	end
	hand.results = { pots = pots, returned = returned, payouts = payouts, shown = shown, board = hand.board }
	hand.street, hand.toAct = "done", nil
end

-- ============================================================================
-- Replay
-- ============================================================================

---Plays a hand again from its setup, deck and log. Nil when an action in the log wasn't legal.
---@param setup table { seats = { [seat] = { stack, name? } }, button, sb, bb, ante? }
---@param deck number[]
---@param log table[] { seat, action, amount? }
---@return table? hand
function Engine:Replay(setup, deck, log)
	local ok, hand = pcall(Engine.NewHand, Engine, { seats = setup.seats, button = setup.button, sb = setup.sb, bb = setup.bb, ante = setup.ante, deck = deck })
	if not ok then
		return nil
	end
	Engine:Start(hand)
	for _, entry in ipairs(log) do
		if entry.action == "leave" then
			Engine:Leave(hand, entry.seat)
		elseif not Engine:Act(hand, entry.seat, entry.action, entry.amount) then
			return nil
		end
	end
	return hand
end

---Whether two payout tables (seat -> chips) agree.
---@param a table
---@param b table
---@return boolean
function Engine:SamePayouts(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for seat, amount in pairs(a) do
		if b[seat] ~= amount then return false end
	end
	for seat in pairs(b) do
		if a[seat] == nil then return false end
	end
	return true
end
