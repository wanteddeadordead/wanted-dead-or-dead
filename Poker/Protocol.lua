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
Protocol.TO_HOST = { join = true, leave = true, sync = true, commit = true, reveal = true, act = true, back = true, sitout = true, rebuy = true }
-- From the host to a player:
Protocol.TO_PLAYER = { welcome = true, refuse = true, state = true, beat = true, audit = true, backup = true, takeover = true, settle = true }

Protocol.MAX_SEATS = 8
Protocol.MIN_SEATS = 2
Protocol.MAX_TITLE = 40
Protocol.COMMIT_SECONDS = 6 -- a player has this long to commit to a secret once a hand is called
Protocol.REVEAL_SECONDS = 6 -- and this long to send it once every commitment is published
Protocol.SHOWDOWN_SECONDS = 8 -- the result stays up this long before the next hand
Protocol.BEAT_SECONDS = 10 -- the host says it's there this often when nothing else is sent
Protocol.HOST_TIMEOUT = 30 -- a host silent this long is gone
Protocol.TAKEOVER_STEP = 10 -- each next seat in line waits this much longer before taking over
Protocol.AWAY_TIMEOUTS = 2 -- timeouts in a row before a player sits out
Protocol.AD_SECONDS = 45 -- an open table's ad is repeated this often
Protocol.AD_STALE_SECONDS = 120 -- and forgotten when not heard for this long
Protocol.JOIN_RETRY_SECONDS = 5 -- a join unanswered this long is sent again
Protocol.SYNC_SECONDS = 20 -- a player whose last message brought no new state asks for it after this long
Protocol.MIN_TURN_SECONDS, Protocol.MAX_TURN_SECONDS, Protocol.DEFAULT_TURN_SECONDS = 15, 90, 30

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
---@param cfg table { sb, bb, ante?, maxSeats?, buyMin, buyMax, turnSeconds?, stakes?, title? }
---@return table? cfg
---@return string? reason
function Protocol:Settings(cfg)
	if type(cfg) ~= "table" then
		return nil, "no settings"
	end
	local c = {
		sb = cfg.sb, bb = cfg.bb, ante = cfg.ante or 0, maxSeats = cfg.maxSeats or 6, buyMin = cfg.buyMin, buyMax = cfg.buyMax,
		turnSeconds = cfg.turnSeconds or Protocol.DEFAULT_TURN_SECONDS, stakes = cfg.stakes or "chips", title = cfg.title,
	}
	if not (Protocol:IsCount(c.sb, 1) and Protocol:IsCount(c.bb, c.sb) and Protocol:IsCount(c.ante)) then
		return nil, "the blinds are whole numbers, the big blind at least the small"
	end
	if not Protocol:IsCount(c.maxSeats, Protocol.MIN_SEATS, Protocol.MAX_SEATS) then
		return nil, ("a table seats %d to %d"):format(Protocol.MIN_SEATS, Protocol.MAX_SEATS)
	end
	if not (Protocol:IsCount(c.buyMin, c.bb) and Protocol:IsCount(c.buyMax, c.buyMin)) then
		return nil, "the buy-in is at least a big blind, the most at least the least"
	end
	if not Protocol:IsCount(c.turnSeconds, Protocol.MIN_TURN_SECONDS, Protocol.MAX_TURN_SECONDS) then
		return nil, ("a turn is %d to %d seconds"):format(Protocol.MIN_TURN_SECONDS, Protocol.MAX_TURN_SECONDS)
	end
	if c.stakes ~= "chips" and c.stakes ~= "gold" then
		return nil, "stakes are chips or gold"
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
