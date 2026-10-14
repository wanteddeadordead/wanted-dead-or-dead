-- Wanted: Dead Man's Hand Poker. Computer players for a practice table: each is an ordinary player client (Client)
-- run by the host's own client, so it joins, commits and reveals its secret for the shuffle, checks the audit and
-- acts on its turn through the same messages as anyone else, delivered without the network (Net). What it does on
-- its turn is decided here from what its state shows: its own cards, the board, the pot and what it costs to stay
-- in. A rule player, not a strong one: it bets its made hands, calls when the price is right for its draws, folds
-- the rest and bluffs now and then. Three styles so they don't all play the same.
local _, Poker = ...
local Bots = Poker:NewModule("PokerBots")
local Engine = Poker.PokerEngine
local Client = Poker.PokerClient
local Protocol = Poker.PokerProtocol

-- Names no character can have (the game allows no spaces), so a bot is never mistaken for a player
Bots.NAMES = { "Doc Holliday", "Calamity Jane", "Wild Bill", "Belle Starr", "Black Bart", "Annie Oakley", "Kid Curry" }
-- aggression scales how strong a hand must be to bet and how often to raise; bluff is the chance of betting nothing
Bots.STYLES = {
	{ key = "steady", aggression = 1, bluff = 0.1 },
	{ key = "tight", aggression = 0.8, bluff = 0.05 },
	{ key = "loose", aggression = 1.25, bluff = 0.16 },
}

local FIFTEEN4 = 15 ^ 4
local FIFTEEN5 = 15 ^ 5
-- How good a made hand is on its own, 0 to 1 (pairs and two pair are refined below)
local MADE = { ["high card"] = 0.1, pair = 0.35, ["two pair"] = 0.65, ["three of a kind"] = 0.78, straight = 0.86, flush = 0.9,
	["full house"] = 0.96, ["four of a kind"] = 0.99, ["straight flush"] = 1 }
local HIGH_POINTS = { [14] = 10, [13] = 8, [12] = 7, [11] = 6 }

---How good two hole cards are before the flop, 0 to 1: Bill Chen's formula (a pair of aces 20 points, a seven and
---a deuce offsuit about nothing) over 20.
---@param c1 number
---@param c2 number
---@return number
function Bots:Preflop(c1, c2)
	local r1, r2 = Engine:RankOf(c1), Engine:RankOf(c2)
	if r1 < r2 then r1, r2 = r2, r1 end
	local points = HIGH_POINTS[r1] or r1 / 2
	if r1 == r2 then
		points = max(5, points * 2)
	else
		if Engine:SuitOf(c1) == Engine:SuitOf(c2) then points = points + 2 end
		local gap = r1 - r2 - 1
		if gap == 1 then points = points - 1
		elseif gap == 2 then points = points - 2
		elseif gap == 3 then points = points - 4
		elseif gap >= 4 then points = points - 5 end
		if gap <= 1 and r1 < 12 then points = points + 1 end
	end
	return max(0, min(1, ceil(points) / 20))
end

---Whether the cards hold four to a flush (one more card makes it) and four to a straight.
---@param cards number[]
---@return boolean flushDraw
---@return boolean straightDraw
function Bots:Draws(cards)
	local suits, ranks = {}, {}
	for _, c in ipairs(cards) do
		local s, r = Engine:SuitOf(c), Engine:RankOf(c)
		suits[s] = (suits[s] or 0) + 1
		ranks[r] = true
		if r == 14 then ranks[1] = true end
	end
	local flush = false
	for _, n in pairs(suits) do
		if n == 4 then flush = true end
	end
	local straight = false
	for low = 1, 10 do
		local n = 0
		for r = low, low + 4 do
			if ranks[r] then n = n + 1 end
		end
		if n == 4 then straight = true end
	end
	return flush, straight
end

---How good a hand is after the flop, 0 to 1: what it has made, refined for a pair (top pair or not, the pair on the
---board or in the hand), plus what it may still make while cards are to come.
---@param hole number[] the two hole cards
---@param board number[] three to five cards
---@return number
function Bots:Strength(hole, board)
	local cards = { hole[1], hole[2] }
	local boardTop, boardRanks = 0, {}
	for _, c in ipairs(board) do
		cards[#cards + 1] = c
		local r = Engine:RankOf(c)
		boardTop = max(boardTop, r)
		boardRanks[r] = (boardRanks[r] or 0) + 1
	end
	local score, category = Engine:Evaluate(cards)
	local top = floor(score / FIFTEEN4) % 15
	local h1, h2 = Engine:RankOf(hole[1]), Engine:RankOf(hole[2])
	local made = MADE[category] or 0.1
	if category == "pair" then
		if top ~= h1 and top ~= h2 then
			-- The board's pair: overcards to it are worth a little
			made = max(h1, h2) > boardTop and 0.18 or 0.12
		elseif top >= boardTop then
			made = 0.55
		end
	elseif category == "two pair" then
		-- One of the two is the board's: a weaker two pair than two of our own
		for r, n in pairs(boardRanks) do
			if n >= 2 and r ~= h1 and r ~= h2 then made = 0.5 end
		end
	elseif category == "three of a kind" and boardRanks[top] == 3 then
		made = 0.3 -- the board's trips, everyone has them
	elseif category == "high card" and max(h1, h2) > boardTop then
		made = 0.15
	end
	local toCome = 5 - #board
	if toCome > 0 and made < 0.6 then
		local flush, straight = Bots:Draws(cards)
		local draw = (flush and 0.18 or 0) + (straight and 0.14 or 0)
		made = made + draw * (toCome == 2 and 1.6 or 1)
	end
	return min(1, made)
end

---What a bot does on its turn: the action and, for a bet or raise, the total to have in front.
---@param st table the state the host sent it, with its own cards and hand.legal
---@param seat number its seat
---@param style table one of Bots.STYLES
---@param rng fun(): number 0 to 1
---@return string action
---@return number? amount
function Bots:Decide(st, seat, style, rng)
	local hand = st.hand
	local legal = hand.legal
	local me = st.seats[seat]
	local bb = (st.levelBlinds and st.levelBlinds[2]) or st.cfg.bb
	local toCall = legal.call or 0
	local pot = hand.pot or 0
	local stack = me.s or 0
	local a = style.aggression
	local strength
	if hand.street == "preflop" then
		strength = Bots:Preflop(me.hole[1], me.hole[2])
	else
		strength = Bots:Strength(me.hole, hand.board or {})
	end
	strength = strength + (rng() * 0.08 - 0.04)
	local canRaise = legal.minBet or legal.minRaise
	local function Bet()
		if legal.minBet then
			local to = hand.street == "preflop" and 3 * bb or floor(pot * 0.66)
			return "bet", max(legal.minBet, min(legal.maxBet, to))
		end
		local to = floor((hand.cur or 0) * 2.5)
		return "raise", max(legal.minRaise, min(legal.maxRaise, to))
	end
	-- Short: a hand worth playing goes in whole
	if stack <= 8 * bb and strength >= 0.5 and (canRaise or toCall > 0) then
		return "allin"
	end
	if toCall <= 0 then
		if canRaise and strength >= 0.55 / a then
			return Bet()
		elseif canRaise and hand.street ~= "preflop" and strength < 0.3 and rng() < style.bluff then
			return Bet()
		end
		return "check"
	end
	local odds = toCall / (pot + toCall)
	if strength >= 0.8 then
		if canRaise and rng() < 0.7 * a then
			return Bet()
		end
		return "call"
	end
	if strength >= odds + 0.1 or (toCall <= bb and strength >= 0.25) then
		if canRaise and strength >= 0.6 and rng() < 0.3 * a then
			return Bet()
		end
		return "call"
	end
	if toCall >= stack and strength >= 0.5 then
		return "call"
	end
	return "fold"
end

-- ============================================================================
-- A bot at a table
-- ============================================================================

local Bot = {}
Bot.__index = Bot

---A computer player. Join seats it; Receive and Tick run it like a player's client.
---@param o table { name, style, send = fun(target, tbl), now = fun(): number, rng = fun(): number? }
---@return table
function Bots:New(o)
	local bot = setmetatable({ name = o.name, style = o.style or Bots.STYLES[1], now = o.now, rng = o.rng or math.random, buyin = nil, turnKey = nil, actAt = nil, rebuyAt = 0 }, Bot)
	bot.player = Client:New({ name = o.name, send = o.send, now = o.now })
	return bot
end

---Asks the host for a seat.
---@param host string
---@param id string
---@param buyin number
function Bot:Join(host, id, buyin)
	self.buyin = buyin
	self.player:Join(host, id, buyin)
end

---A message from the host.
---@param sender string
---@param tbl table
function Bot:Receive(sender, tbl)
	self.player:Receive(sender, tbl)
end

---Runs the bot: its client's clock, its turn after a moment's thought, and a buy back in when it busts at a cash
---table. Call about once a second.
function Bot:Tick()
	self.player:Tick()
	local st, seat = self.player.state, self.player.seat
	if not st or not seat or self.player.left then
		return
	end
	local now = self.now()
	local hand = st.hand
	if hand and hand.stage == "play" and hand.toAct == seat and hand.legal then
		local key = hand.key..":"..#(hand.log or {})
		if self.turnKey ~= key then
			self.turnKey = key
			self.actAt = now + Protocol.BOT_THINK_MIN + self.rng() * (Protocol.BOT_THINK_MAX - Protocol.BOT_THINK_MIN)
		end
		if now >= self.actAt then
			local action, amount = Bots:Decide(st, seat, self.style, self.rng)
			self.player:Act(action, amount)
		end
	else
		self.turnKey = nil
	end
	local me = st.seats[seat]
	if me and (me.s or 0) == 0 and st.cfg.kind ~= "tournament" and st.phase ~= "playing" and st.phase ~= "closed" and now - self.rebuyAt >= 3 then
		self.rebuyAt = now
		self.player:Rebuy(self.buyin)
	end
end
