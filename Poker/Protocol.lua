-- Wanted: Dead Man's Hand Poker. The table protocol: what the host and the players at a table say to each other,
-- by hidden addon whisper through the base's sync transport (Sync:RegisterPlugin), and the open-table ad on the
-- base's channel. One table has one host, whose client runs the engine and deals; every player's client keeps a
-- mirror of the table from the host's numbered state messages and checks the host's audit after each hand (Deal).
-- Who sent a message is what the game says, never what the message says: a seat's actions are taken only from
-- the name in that seat, and table state only from the host.
local _, Poker = ...
local Protocol = Poker:NewModule("PokerProtocol")

Protocol.VERSION = 1 -- bumped when older clients can't read the messages
Protocol.TAG = "P" -- table traffic, by whisper
Protocol.AD_TAG = "T" -- open tables, on the channel

-- Message kinds, in the message's k field. From a player to the host:
Protocol.TO_HOST = { join = true, leave = true, sync = true, commit = true, reveal = true, act = true, back = true, sitout = true, rebuy = true, say = true }
-- From the host to a player:
Protocol.TO_PLAYER = { welcome = true, refuse = true, state = true, beat = true, audit = true, backup = true, takeover = true, settle = true, handoff = true, said = true }
-- Table talk: a seat says one of these, by number, and the host tells every seat (at most one every SAY_SECONDS)
Protocol.EMOTES = { "Nice hand", "Great call", "I bluffed", "Ouch", "Well played", "Lucky", "gg", "Ha!" }
Protocol.SAY_SECONDS = 3
-- Between any two players, about no table: { k = "lines" } asks for the open lines the sender is owed by the receiver;
-- { k = "lines", l = { line, ... } } answers with them (Gold). Only lines the SENDER owes are taken from an answer.
Protocol.LINES = "lines"

Protocol.MAX_SEATS = 8
Protocol.MIN_SEATS = 2
Protocol.MAX_TITLE = 40
Protocol.COMMIT_SECONDS = 6 -- a player has this long to commit to a secret once a hand is called
Protocol.REVEAL_SECONDS = 6 -- and this long to send it once every commitment is published
Protocol.SHOWDOWN_SECONDS = 10 -- the result stays up this long before the next hand
Protocol.BEAT_SECONDS = 10 -- the host says it's there this often when nothing else is sent
Protocol.HOST_TIMEOUT = 30 -- a host silent this long is gone
Protocol.TAKEOVER_STEP = 10 -- each next seat in line waits this much longer before taking over
Protocol.AWAY_TIMEOUTS = 2 -- timeouts in a row before a player sits out
Protocol.AD_SECONDS = 45 -- an open table's ad is repeated this often
Protocol.AD_STALE_SECONDS = 120 -- and forgotten when not heard for this long
Protocol.JOIN_RETRY_SECONDS = 5 -- a join unanswered this long is sent again
Protocol.SYNC_SECONDS = 20 -- a player whose last message brought no new state asks for it after this long
Protocol.MIN_TURN_SECONDS, Protocol.MAX_TURN_SECONDS, Protocol.DEFAULT_TURN_SECONDS = 15, 90, 30
-- Tournaments: the blind levels, in chips, and how prizes split by how many entered (the host holds the entries)
Protocol.SCHEDULE = { { 10, 20 }, { 15, 30 }, { 25, 50 }, { 50, 100 }, { 75, 150 }, { 100, 200 }, { 150, 300 }, { 200, 400 }, { 300, 600 }, { 400, 800 }, { 500, 1000 }, { 700, 1400 }, { 1000, 2000 }, { 1500, 3000 }, { 2000, 4000 } }
Protocol.START_STACKS = { 1000, 1500, 3000 }
Protocol.MIN_LEVEL_MINUTES, Protocol.MAX_LEVEL_MINUTES = 1, 60
Protocol.ABSENT_BLIND_SECONDS = 0 -- an absent entrant loses a big blind every hand they miss
Protocol.ANTE_FROM_LEVEL = 4 -- with antes on, every player antes a tenth of the big blind from this level
Protocol.DEFAULT_LATE_LEVELS = 2 -- late entry stays open through this level
-- A practice table: the host plays computer players run by their own client (Bots), for chips, never advertised
Protocol.MAX_BOTS = Protocol.MAX_SEATS - 1
Protocol.BOT_THINK_MIN, Protocol.BOT_THINK_MAX = 1, 4 -- a bot takes this long over its turn
-- The game refused a table message (its addon message lockdown: a boss fight, a PvP match). The table's clocks stop
-- until a message goes through again; the host's beat tries every BEAT_SECONDS, so this is two beats and a little
Protocol.BLOCKED_SECONDS = 25
-- Gold tables: cash on the table. A seat waits this long for its buy-in to reach the host before it's given up
Protocol.PAY_SECONDS = 180
-- A gold table's host gone this long is lost: the table is over and the host owes every seat its stack (Client)
Protocol.HOST_LOST_SECONDS = 120
-- A host handing the table to the next seat waits this long for them to take it before carrying on
Protocol.HANDOFF_SECONDS = 30
-- A seat remembered across a reload: joined again this long after login, given up without an answer, forgotten after
Protocol.REJOIN_DELAY_SECONDS = 4
Protocol.REJOIN_GIVE_UP_SECONDS = 60
Protocol.REJOIN_WINDOW_SECONDS = 6 * 60 * 60

---About how long a tournament runs, in minutes: the level at which the whole field's chips are twenty-five big
---blinds is near the end (the last few hands go fast), so that level's number times the level length, a little less
---with antes. A rule of thumb that matches the usual online structures.
---@param stack number the starting stack
---@param players number
---@param levelMinutes number
---@param antes boolean?
---@return number minutes
function Protocol:TournamentMinutes(stack, players, levelMinutes, antes)
	local chips = (stack or 1500) * max(2, players or 2)
	local level = #Protocol.SCHEDULE
	for i, blinds in ipairs(Protocol.SCHEDULE) do
		if blinds[2] * 25 >= chips then
			level = i
			break
		end
	end
	local minutes = level * (levelMinutes or 10)
	if antes then minutes = minutes * 0.9 end
	return max(levelMinutes or 10, floor(minutes + 0.5))
end

---A length of time in words: "about 50 min", "about 1 h 30 min".
---@param minutes number
---@return string
function Protocol:AboutMinutes(minutes)
	minutes = floor(minutes / 5 + 0.5) * 5
	if minutes < 60 then return ("about %d min"):format(minutes) end
	local h, m = floor(minutes / 60), minutes % 60
	return m > 0 and ("about %d h %d min"):format(h, m) or ("about %d h"):format(h)
end

---How a tournament's prize pool splits: shares by place, for a number of entrants.
---@param entrants number
---@return number[] shares summing to 1
function Protocol:PrizeShares(entrants)
	if entrants >= 7 then return { 0.5, 0.3, 0.2 } end
	if entrants >= 5 then return { 0.65, 0.35 } end
	return { 1 }
end

---The prizes, in chips of money (copper), for a pool: whole amounts, the rounding left to first place.
---@param pool number
---@param entrants number
---@return number[] prize by place
function Protocol:Prizes(pool, entrants)
	local shares = Protocol:PrizeShares(entrants)
	local prizes, given = {}, 0
	for i = #shares, 2, -1 do
		prizes[i] = floor(pool * shares[i])
		given = given + prizes[i]
	end
	prizes[1] = pool - given
	return prizes
end

---Whether stakes are shown as money: real gold, or a practice table's play money.
---@param stakes string?
---@return boolean
function Protocol:IsMoney(stakes)
	return stakes == "gold" or stakes == "play"
end

---An amount shown: chips as a number; at a gold table (or a practice table on play money) a chip is a copper piece,
---shown as gold, silver and copper ("2g 50s", "75c", "1g 5c").
---@param chips number
---@param stakes string? "chips" | "gold" | "play"
---@return string
function Protocol:Money(chips, stakes)
	chips = floor((chips or 0) + 0.5)
	if not Protocol:IsMoney(stakes) then
		return tostring(chips)
	end
	local g, s, c = floor(chips / 10000), floor(chips / 100) % 100, chips % 100
	local parts = {}
	if g > 0 then parts[#parts + 1] = g.."g" end
	if s > 0 then parts[#parts + 1] = s.."s" end
	if c > 0 or #parts == 0 then parts[#parts + 1] = c.."c" end
	return table.concat(parts, " ")
end

---An amount typed: a number of chips, or at a gold table gold, silver and copper ("10g", "2g 50s", "75s", "5c"; a
---bare number is gold). Nil when it isn't one.
---@param text string
---@param stakes string? "chips" | "gold" | "play"
---@return number? chips
function Protocol:ParseAmount(text, stakes)
	text = strlower(strtrim(tostring(text or "")))
	if text == "" then return nil end
	if not Protocol:IsMoney(stakes) then
		local n = tonumber(text)
		return n and n == floor(n) and n >= 0 and n or nil
	end
	local plain = tonumber(text)
	if plain then
		local copper = floor(plain * 10000 + 0.5)
		return copper >= 0 and copper or nil
	end
	local total, rest, any = 0, text, false
	for _, unit in ipairs({ { "g", 10000 }, { "s", 100 }, { "c", 1 } }) do
		local n = strmatch(rest, "^(%d+)%s*"..unit[1])
		if n then
			total = total + tonumber(n) * unit[2]
			rest = gsub(rest, "^%d+%s*"..unit[1].."%s*", "")
			any = true
		end
	end
	if rest ~= "" or not any then return nil end
	return total
end

---Whether a value is a whole number of chips (or seats, or seconds).
---@param n any
---@param min number?
---@param max number?
---@return boolean
function Protocol:IsCount(n, min, max)
	return type(n) == "number" and n == floor(n) and n >= (min or 0) and (max == nil or n <= max)
end

---Whether a value is a player's name as the game gives it.
---@param s any
---@return boolean
function Protocol:IsName(s)
	return type(s) == "string" and #s >= 2 and #s <= 60 and not strfind(s, "[|%c]")
end

---Whether a value is a hex string of the given length (a commitment, a secret, a deck hash).
---@param s any
---@param len number
---@return boolean
function Protocol:IsHex(s, len)
	return type(s) == "string" and #s == len and strmatch(s, "^%x+$") ~= nil
end

local BASE36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function ToBase36(n)
	local out = ""
	repeat
		local d = n % 36
		out = strsub(BASE36, d + 1, d + 1)..out
		n = floor(n / 36)
	until n == 0
	return out
end

---A new table id: the host's name, then a stamp, so one host's tables never collide and anyone can read who hosts.
---@param host string
---@param now number
---@return string
function Protocol:NewId(host, now)
	return host.."#"..ToBase36(floor(now * 10) % 2176782336)..ToBase36(math.random(0, 1295))
end

---The host's name from a table id.
---@param id string
---@return string?
function Protocol:HostOf(id)
	return type(id) == "string" and strmatch(id, "^(.-)#[%w]+$") or nil
end

---Checks a table's settings, filling in defaults. Returns the settings, or nil and what's wrong.
---@param cfg table { sb, bb, ante?, maxSeats?, buyMin, buyMax, turnSeconds?, stakes?, title?, bots? }
---@return table? cfg
---@return string? reason
function Protocol:Settings(cfg)
	if type(cfg) ~= "table" then
		return nil, "no settings"
	end
	local c = {
		kind = cfg.kind or "cash", sb = cfg.sb, bb = cfg.bb, ante = cfg.ante or 0, maxSeats = cfg.maxSeats or 6, buyMin = cfg.buyMin, buyMax = cfg.buyMax,
		turnSeconds = cfg.turnSeconds or Protocol.DEFAULT_TURN_SECONDS, stakes = cfg.stakes or "chips", title = cfg.title,
		entry = cfg.entry, startStack = cfg.startStack, levelMinutes = cfg.levelMinutes, bots = cfg.bots or 0,
		antes = cfg.antes == true, lateLevels = cfg.lateLevels,
	}
	if not Protocol:IsCount(c.bots, 0, Protocol.MAX_BOTS) then
		return nil, ("a table takes up to %d computer players"):format(Protocol.MAX_BOTS)
	end
	if c.bots > 0 and c.stakes == "gold" then
		return nil, "a practice table plays for chips or play money, never gold"
	end
	if c.kind ~= "cash" and c.kind ~= "tournament" then
		return nil, "a table is a cash game or a tournament"
	end
	if c.kind == "tournament" then
		-- Blinds come from the schedule; the entry is the one buy-in; the stacks are chips, not money
		c.sb, c.bb = Protocol.SCHEDULE[1][1], Protocol.SCHEDULE[1][2]
		c.entry = c.entry or 0
		c.startStack = c.startStack or Protocol.START_STACKS[2]
		c.levelMinutes = c.levelMinutes or 10
		c.buyMin, c.buyMax = c.entry, c.entry
		if not Protocol:IsCount(c.entry) then
			return nil, "the entry is a whole amount"
		end
		if not Protocol:IsCount(c.startStack, c.bb * 10) then
			return nil, "the starting stack is at least ten big blinds"
		end
		if not Protocol:IsCount(c.levelMinutes, Protocol.MIN_LEVEL_MINUTES, Protocol.MAX_LEVEL_MINUTES) then
			return nil, ("a level lasts %d to %d minutes"):format(Protocol.MIN_LEVEL_MINUTES, Protocol.MAX_LEVEL_MINUTES)
		end
		if c.lateLevels == nil then c.lateLevels = Protocol.DEFAULT_LATE_LEVELS end
		if not Protocol:IsCount(c.lateLevels, 0, #Protocol.SCHEDULE) then
			return nil, "late entry is open through a level of the schedule, or not at all"
		end
	else
		c.antes, c.lateLevels = false, nil
	end
	if not (Protocol:IsCount(c.sb, 1) and Protocol:IsCount(c.bb, c.sb) and Protocol:IsCount(c.ante)) then
		return nil, "the blinds are whole numbers, the big blind at least the small"
	end
	if not Protocol:IsCount(c.maxSeats, Protocol.MIN_SEATS, Protocol.MAX_SEATS) then
		return nil, ("a table seats %d to %d"):format(Protocol.MIN_SEATS, Protocol.MAX_SEATS)
	end
	if c.bots >= c.maxSeats then
		return nil, "a practice table keeps a seat for you"
	end
	if c.kind == "cash" and not (Protocol:IsCount(c.buyMin, c.bb) and Protocol:IsCount(c.buyMax, c.buyMin)) then
		return nil, "the buy-in is at least a big blind, the most at least the least"
	end
	if not Protocol:IsCount(c.turnSeconds, Protocol.MIN_TURN_SECONDS, Protocol.MAX_TURN_SECONDS) then
		return nil, ("a turn is %d to %d seconds"):format(Protocol.MIN_TURN_SECONDS, Protocol.MAX_TURN_SECONDS)
	end
	if c.stakes ~= "chips" and c.stakes ~= "gold" and c.stakes ~= "play" then
		return nil, "stakes are chips, gold or play money"
	end
	if c.stakes == "play" and c.bots == 0 then
		return nil, "play money is for practice tables"
	end
	if c.title ~= nil and (type(c.title) ~= "string" or #c.title > Protocol.MAX_TITLE or strfind(c.title, "[|%c]")) then
		return nil, "a title is a short line"
	end
	return c
end

---Whether a message's settings block is one this client can play on (a host's state carries its table's).
---@param cfg any
---@return boolean
function Protocol:ValidSettings(cfg)
	return Protocol:Settings(cfg) ~= nil
end
