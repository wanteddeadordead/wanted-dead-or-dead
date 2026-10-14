-- Wanted: the deal nobody at the table can rig. Before a hand every player makes a secret and sends its hash (the
-- commitment) to the host; once the host has shown everyone the commitments, each sends the secret. The deck is
-- shuffled from every secret together, so no one player, the host included, could choose it: changing a secret
-- after seeing the others would break that player's own commitment. After the hand the host sends the audit
-- (secrets, commitments, deck hash, actions and payouts) and every client checks it here: that its own commitment
-- and secret are the ones used, that every secret matches its commitment, that the deck is the one the secrets
-- make, that its own cards and the board came from that deck, and that the payouts follow from the actions.
-- The host's client still deals, so a host who edits the addon can see the cards; it can't change them.
local _, Poker = ...
local Deal = Poker:NewModule("PokerDeal")
local Crypto = Poker.Wanted.Crypto
local Engine = Poker.PokerEngine
local private = { counter = 0 }

local TWO_32 = 4294967296

---A fresh 32-byte secret, in hex. The game's random numbers, the clock and a counter go through the hash, so the
---secret shows nothing of the generator.
---@return string
function Deal:Secret()
	private.counter = private.counter + 1
	local parts = { tostring(private.counter), tostring(GetTime and GetTime() or 0), tostring(time()), tostring({}), tostring(math.random()) }
	for _ = 1, 32 do
		parts[#parts + 1] = string.char(math.random(0, 255))
	end
	return Crypto:Hex(Crypto:SHA512(table.concat(parts, "|")):sub(1, 32))
end

---The commitment to a secret: a hash to send before the secret.
---@param secret string
---@return string
function Deal:Commit(secret)
	return Crypto:Hex(Crypto:SHA512(secret):sub(1, 32))
end

-- A stream of bytes from a seed: block i is the hash of the seed and i
local function Stream(seed)
	local block, pos, blockNo = "", 1, 0
	return function()
		if pos > #block then
			blockNo = blockNo + 1
			block = Crypto:SHA512(seed..string.char(blockNo))
			pos = 1
		end
		local b = block:byte(pos)
		pos = pos + 1
		return b
	end
end

---The deck a table's hand gets from its players' secrets: the same inputs always give the same deck.
---@param tableId string
---@param handNo number
---@param secrets table seat -> secret
---@return number[] deck 52 cards
function Deal:Deck(tableId, handNo, secrets)
	local seats = {}
	for seat in pairs(secrets) do
		seats[#seats + 1] = seat
	end
	sort(seats)
	local material = { tostring(tableId), tostring(handNo) }
	for _, seat in ipairs(seats) do
		material[#material + 1] = seat..":"..secrets[seat]
	end
	local nextByte = Stream(Crypto:SHA512(table.concat(material, "|")))
	-- Fisher-Yates, each draw uniform over its range: a 32-bit number is thrown back when it falls in the short tail
	local function Uniform(n)
		local limit = TWO_32 - TWO_32 % n
		while true do
			local v = ((nextByte() * 256 + nextByte()) * 256 + nextByte()) * 256 + nextByte()
			if v < limit then
				return v % n + 1
			end
		end
	end
	local deck = {}
	for i = 1, 52 do deck[i] = i end
	for i = 52, 2, -1 do
		local j = Uniform(i)
		deck[i], deck[j] = deck[j], deck[i]
	end
	return deck
end

---A hash of a deck, which the host sends before dealing.
---@param deck number[]
---@return string
function Deal:DeckHash(deck)
	return Crypto:Hex(Crypto:SHA512(table.concat(deck, ",")):sub(1, 32))
end

---Checks a hand's audit from where one player sits. True, or false and the reason, said for the table.
---@param audit table { tableId, handNo, commits = { seat -> commit }, secrets = { seat -> secret }, deckHash, setup, log, board?, payouts? }
---@param me table { seat, secret, commit, hole = { c1, c2 } }
---@return boolean ok
---@return string? reason
function Deal:Verify(audit, me)
	if type(audit) ~= "table" or type(me) ~= "table" then
		return false, "no audit"
	end
	local commits, secrets = audit.commits or {}, audit.secrets or {}
	if commits[me.seat] ~= me.commit then
		return false, "your commitment isn't the one in the hand"
	end
	if secrets[me.seat] ~= me.secret then
		return false, "your secret isn't the one in the hand"
	end
	for seat, commit in pairs(commits) do
		local secret = secrets[seat]
		if type(secret) ~= "string" or Deal:Commit(secret) ~= commit then
			return false, ("seat %s's secret doesn't match their commitment"):format(tostring(seat))
		end
	end
	for seat in pairs(secrets) do
		if not commits[seat] then
			return false, ("seat %s's secret has no commitment"):format(tostring(seat))
		end
	end
	local deck = Deal:Deck(audit.tableId, audit.handNo, secrets)
	if Deal:DeckHash(deck) ~= audit.deckHash then
		return false, "the deck isn't the one the secrets make"
	end
	if type(audit.setup) ~= "table" then
		return false, "the audit has no setup"
	end
	local hand = Engine:Replay(audit.setup, deck, audit.log or {})
	if not hand then
		return false, "the actions don't replay"
	end
	local mine = hand.seats[me.seat]
	if not mine or type(me.hole) ~= "table" or mine.hole[1] ~= me.hole[1] or mine.hole[2] ~= me.hole[2] then
		return false, "the cards you were dealt aren't the deck's"
	end
	if audit.payouts ~= nil and (not hand.results or not Engine:SamePayouts(hand.results.payouts, audit.payouts)) then
		return false, "the payouts don't follow from the actions"
	end
	if type(audit.board) == "table" then
		for i = 1, math.max(#audit.board, #hand.board) do
			if audit.board[i] ~= hand.board[i] then
				return false, "the board isn't the deck's"
			end
		end
	end
	return true
end
