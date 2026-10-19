-- Wanted: daily influence races. Three a night, each in a zone the site picks the evening before, open to everyone
-- there, Horde v Alliance: each side earns influence from witnessed kills on the other side and from minutes on the
-- zone's three race points (the middle one +20%). Nothing is captured or owned.
--
-- wanteddeadordead.com runs the races and counts the influence; this client never does. The app brings tonight's
-- races (with their points and influence as the site last counted them) and tomorrow's zones in its catch-up, read at
-- every login. While a race is run the addon counts the player's presence on its points every 30 seconds, in the
-- same presence book and on the same log line as a capture point's (Captures:CountRace), for the app to send on.

local _, Wanted = ...
local Races = Wanted:NewModule("Races")
local private = {
	state = nil, -- the catch-up's races, cleaned (private.Clean), or nil when it named none
	listeners = {},
	current = nil, -- the race point the player stood on at the last look, or nil
	blocked = nil, -- why the player's presence didn't count there, or nil
}
local SAMPLE_SECONDS = 30
local MAX_RACES, MAX_GUILDS = 6, 20
local STATES = { upcoming = true, live = true, counting = true, final = true }
local SIDES = { H = "Horde", A = "Alliance" }
Races.SAMPLE_SECONDS = SAMPLE_SECONDS



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Races:OnLoad()
	-- Samples counted per race this client saw, for the HUD's minutes: "<zone>:<start>" -> samples
	Wanted.db.raceSamples = type(Wanted.db.raceSamples) == "table" and Wanted.db.raceSamples or {}
end

function Races:OnEnable()
	C_Timer.NewTicker(SAMPLE_SECONDS, Wanted:Timed("Races sample", function() Races:Sample() end))
end



-- ============================================================================
-- The catch-up
-- ============================================================================

---Text from the catch-up as plain text: no escape sequences or control characters, at most max letters.
function private.Text(value, max)
	if type(value) ~= "string" then
		return nil
	end
	value = strtrim((gsub(value, "[|%c]", "")))
	return value ~= "" and strsub(value, 1, max or 64) or nil
end

function private.Number(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value or nil
end

---A race point, or nil when it's malformed: { id, name, x, y (zone map 0 to 100), r (yards), weight, bonus, holder }.
function private.CleanPoint(p)
	if type(p) ~= "table" then
		return nil
	end
	local id, name = private.Text(p.id, 24), private.Text(p.name)
	local x, y, r, weight = private.Number(p.x), private.Number(p.y), private.Number(p.r), private.Number(p.weight)
	if not (id and strmatch(id, "^[a-z0-9%-]+$") and name and x and y and r and weight) or x < 0 or x > 100 or y < 0 or y > 100
		or r <= 0 or r > 200 or weight <= 0 then
		return nil
	end
	return { id = id, name = name, x = x, y = y, r = r, weight = weight, bonus = p.bonus == true, holder = SIDES[p.holder] }
end

---A race, or nil when it's malformed.
function private.CleanRace(r)
	if type(r) ~= "table" then
		return nil
	end
	local zone, start, stop, mapId = private.Text(r.zone), private.Number(r.start), private.Number(r["end"]), private.Number(r.mapID)
	if not (zone and start and stop and mapId) or stop <= start or type(r.points) ~= "table" then
		return nil
	end
	local race = { n = private.Number(r.n) or 0, zone = zone, mapId = mapId, start = start, stop = stop,
		state = STATES[r.state] and r.state or "upcoming", horde = max(private.Number(r.horde) or 0, 0),
		alliance = max(private.Number(r.alliance) or 0, 0), winner = (r.winner == "Horde" or r.winner == "Alliance") and r.winner or nil,
		mayDeclare = (r.mayDeclare == "Horde" or r.mayDeclare == "Alliance") and r.mayDeclare or nil, final = r.final == true,
		at = private.Number(r.at), points = {}, guilds = {} }
	for _, p in ipairs(r.points) do
		local point = private.CleanPoint(p)
		if point and #race.points < 3 then
			point.race = race
			tinsert(race.points, point)
		end
	end
	if #race.points == 0 then
		return nil
	end
	for _, g in ipairs(type(r.guilds) == "table" and r.guilds or {}) do
		local side = type(g) == "table" and SIDES[g.f]
		if side and #race.guilds < MAX_GUILDS then
			tinsert(race.guilds, { name = private.Text(g.name, 48) or "", side = side, influence = max(private.Number(g.influence) or 0, 0),
				kills = max(private.Number(g.kills) or 0, 0), minutes = max(private.Number(g.minutes) or 0, 0) })
		end
	end
	sort(race.guilds, function(a, b) return a.influence > b.influence end)
	return race
end

---The races as the catch-up has them, cleaned: nil when it has none (races off on the site, or an old app).
function private.Clean(src)
	if type(src) ~= "table" or type(src.tonight) ~= "table" then
		return nil
	end
	local state = { tonight = {}, tomorrow = {} }
	for _, r in ipairs(src.tonight) do
		local race = private.CleanRace(r)
		if race and #state.tonight < MAX_RACES then
			tinsert(state.tonight, race)
		end
	end
	for _, r in ipairs(type(src.tomorrow) == "table" and src.tomorrow or {}) do
		local zone, start, stop = type(r) == "table" and private.Text(r.zone), type(r) == "table" and private.Number(r.start), type(r) == "table" and private.Number(r["end"])
		if zone and start and stop and stop > start and #state.tomorrow < MAX_RACES then
			tinsert(state.tomorrow, { n = private.Number(r.n) or 0, zone = zone, start = start, stop = stop })
		end
	end
	sort(state.tonight, function(a, b) return a.start < b.start end)
	sort(state.tomorrow, function(a, b) return a.start < b.start end)
	return state
end

---Takes in the races from a catch-up (or nil: none). Only shown, so read at every login.
---@param src table?
function Races:Take(src)
	private.state = private.Clean(src)
	-- The HUD's minutes are kept for tonight's races only
	local keep = {}
	for _, race in ipairs(private.state and private.state.tonight or {}) do
		keep[private.Key(race)] = true
	end
	for key in pairs(Wanted.db.raceSamples or {}) do
		if not keep[key] then
			Wanted.db.raceSamples[key] = nil
		end
	end
	private.Changed()
end



-- ============================================================================
-- Reading
-- ============================================================================

function private.Key(race)
	return race.zone..":"..race.start
end

---Whether the site runs races on this client's campaign: the catch-up named them (Siege steps aside then).
---@return boolean
function Races:On()
	return private.state ~= nil
end

---Tonight's races, by start.
---@return table[]
function Races:Tonight()
	return private.state and private.state.tonight or {}
end

---Tomorrow's zones and times, by start.
---@return table[]
function Races:Tomorrow()
	return private.state and private.state.tomorrow or {}
end

---The race being run now, by the clock (the catch-up's state can be a while old), or nil.
---@param now number? server time
---@return table?
function Races:Live(now)
	now = now or GetServerTime()
	for _, race in ipairs(Races:Tonight()) do
		if now >= race.start and now < race.stop then
			return race
		end
	end
	return nil
end

---The next race to start, tonight's then tomorrow's, or nil.
---@param now number? server time
---@return table?
function Races:Next(now)
	now = now or GetServerTime()
	for _, list in ipairs({ Races:Tonight(), Races:Tomorrow() }) do
		for _, race in ipairs(list) do
			if race.start > now then
				return race
			end
		end
	end
	return nil
end

---"upcoming", "live" or "ended", by the clock.
---@param race table
---@param now number?
---@return string
function Races:Phase(race, now)
	now = now or GetServerTime()
	return now < race.start and "upcoming" or now < race.stop and "live" or "ended"
end

---A map's size in yards: the game's, else the capture fronts' table (Captures.MAP_YARDS).
function private.Yards(mapId)
	if C_Map and C_Map.GetMapWorldSize then
		local ok, w, h = pcall(C_Map.GetMapWorldSize, mapId)
		if ok and type(w) == "number" and type(h) == "number" and w > 0 and h > 0 and not (issecretvalue and (issecretvalue(w) or issecretvalue(h))) then
			return w, h
		end
	end
	local yards = Wanted.Captures.MAP_YARDS[mapId]
	if yards then
		return yards[1], yards[2]
	end
	return nil
end

---The race's point the player at (mapId, x, y) stands on (within its radius), or nil.
---@param race table
---@param mapId number?
---@param x number? zone map 0 to 100
---@param y number?
---@return table?
function Races:PointAt(race, mapId, x, y)
	if not race or mapId ~= race.mapId or type(x) ~= "number" or type(y) ~= "number" then
		return nil
	end
	local w, h = private.Yards(mapId)
	if not w then
		return nil
	end
	for _, point in ipairs(race.points) do
		local dx, dy = (x - point.x) / 100 * w, (y - point.y) / 100 * h
		if dx * dx + dy * dy <= point.r * point.r then
			return point
		end
	end
	return nil
end

---The point nearest to (x, y) on the race's map, or its first when the player is elsewhere.
---@param race table
---@param x number?
---@param y number?
---@return table
function Races:Nearest(race, x, y)
	local best, bestD = race.points[1], math.huge
	if type(x) == "number" and type(y) == "number" then
		for _, point in ipairs(race.points) do
			local d = (x - point.x) ^ 2 + (y - point.y) ^ 2
			if d < bestD then
				best, bestD = point, d
			end
		end
	end
	return best
end

---A side's guilds in a race, by influence.
---@param race table
---@param side string "Horde" or "Alliance"
---@return table[]
function Races:Guilds(race, side)
	local list = {}
	for _, g in ipairs(race.guilds) do
		if g.side == side then
			tinsert(list, g)
		end
	end
	return list
end

---Your part in a race, as this client counted it: minutes on its points, and your kills of the other side in its zone
---while it ran.
---@param race table
---@return number kills
---@return number minutes
function Races:Mine(race)
	local samples = Wanted.db.raceSamples and Wanted.db.raceSamples[private.Key(race)] or 0
	local kills = 0
	for _, item in ipairs(Wanted.Model:GetActivity()) do
		if item.kind == "kill" and item.who == "You" and item.zone == race.zone and item.t >= race.start and item.t < race.stop then
			kills = kills + 1
		end
	end
	return kills, floor(samples * SAMPLE_SECONDS / 60)
end

---The race point the player stood on at the last look, and why their presence wouldn't count there (or nil).
---@return table? point
---@return string? blocked
function Races:Current()
	return private.current, private.blocked
end

---Calls func() when the races or the player's place on them change.
---@param func function
function Races:OnChange(func)
	tinsert(private.listeners, func)
end

function private.Changed()
	for _, func in ipairs(private.listeners) do
		func()
	end
end



-- ============================================================================
-- Presence
-- ============================================================================

---Every 30 seconds while a race is run: whether the player stands on one of its points, and if their presence can
---count there (Captures:Blocked), a sample in the presence book and on the log line the app reads.
---@param now number? server time
function Races:Sample(now)
	now = now or GetServerTime()
	local race = Races:Live(now)
	local point, blocked
	if race then
		local _, x, y, mapId = Wanted.Recorder:GetPosition()
		point = Races:PointAt(race, mapId, x, y)
		if point then
			blocked = Wanted.Captures:Blocked()
			if not blocked and Wanted.Captures:CountRace(point.id, now) then
				local key = private.Key(race)
				Wanted.db.raceSamples[key] = (Wanted.db.raceSamples[key] or 0) + 1
			end
		end
	end
	private.current, private.blocked = point, blocked
	private.Changed()
end
