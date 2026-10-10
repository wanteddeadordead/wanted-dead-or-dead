-- Wanted: capture points. A few places between the two towns of the busiest fronts. While the player stands in one,
-- able to fight (not mounted, flying, stealthed, dead or away), the addon counts it every 30 seconds in a presence
-- book. The desktop app sends the book to wanteddeadordead.com, which decides who holds each point from several
-- players' apps and the kills there; this client never decides it. Nothing here goes to other players.

local _, Wanted = ...
local Captures = Wanted:NewModule("Captures")
local private = {
	current = nil, -- the point the player is in, as of the last sample
	toldBlocked = false, -- why the presence doesn't count was said this visit
	holds = {}, -- point id -> { h = "Horde" | "Alliance" | nil, s = since, t = when the site worked it out }
}
local SAMPLE_SECONDS = 30
-- A slot is five minutes of game-server time; a sample adds one to the player's count at a point in the slot
local SLOT_SECONDS = 300
local MAX_SAMPLES = SLOT_SECONDS / SAMPLE_SECONDS
-- The book keeps three days (the app sends it at its next catch-up) and at most this many entries
local KEEP_SECONDS = 3 * 24 * 60 * 60
local MAX_ENTRIES = 2000
Captures.SLOT_SECONDS = SLOT_SECONDS

-- Each zone map's size in yards: width (the world's Y span) and height (its X span), from the game's UiMapAssignment
-- table as wanteddeadordead.com keeps it (stats.mapWorld), so a point's circle is round on any map
local MAP_YARDS = {
	[1424] = { 3200.0, 2133.3 }, -- Hillsbrad Foothills
	[1440] = { 5766.7, 3843.8 }, -- Ashenvale
	[1417] = { 3600.0, 2400.0 }, -- Arathi Highlands
}
-- The points: the middle of the game's own area for each place (wanteddeadordead.com's subzone table) on the zone map,
-- 0 to 100, and a radius in yards. The ids are the site's; it keeps the same list.
Captures.POINTS = {
	{ id = "hb-darrow", name = "Darrow Hill", zone = "Hillsbrad Foothills", mapId = 1424, x = 50.9, y = 33.7, r = 60 },
	{ id = "hb-fields", name = "Hillsbrad Fields", zone = "Hillsbrad Foothills", mapId = 1424, x = 35.0, y = 44.9, r = 60 },
	{ id = "hb-nethander", name = "Nethander Stead", zone = "Hillsbrad Foothills", mapId = 1424, x = 63.9, y = 55.4, r = 60 },
	{ id = "av-raynewood", name = "Raynewood Retreat", zone = "Ashenvale", mapId = 1440, x = 60.9, y = 51.7, r = 60 },
	{ id = "av-iris", name = "Iris Lake", zone = "Ashenvale", mapId = 1440, x = 46.4, y = 46.8, r = 60 },
	{ id = "av-howling", name = "The Howling Vale", zone = "Ashenvale", mapId = 1440, x = 56.2, y = 37.1, r = 60 },
	{ id = "ah-outer", name = "Circle of Outer Binding", zone = "Arathi Highlands", mapId = 1417, x = 52.7, y = 52.8, r = 60 },
	{ id = "ah-dabyrie", name = "Dabyrie's Farmstead", zone = "Arathi Highlands", mapId = 1417, x = 55.2, y = 39.7, r = 60 },
	{ id = "ah-goshek", name = "Go'Shek Farm", zone = "Arathi Highlands", mapId = 1417, x = 61.4, y = 56.5, r = 60 },
}
local byId = {}
for _, point in ipairs(Captures.POINTS) do
	byId[point.id] = point
end



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Captures:OnLoad()
	-- The presence book, for the app: "point:slot:guid" -> { g = GUID, n = name, p = point id, s = slot, c = samples }
	Wanted.db.presence = type(Wanted.db.presence) == "table" and Wanted.db.presence or {}
	private.Prune(GetServerTime())
end

function Captures:OnEnable()
	C_Timer.NewTicker(SAMPLE_SECONDS, Wanted:Timed("Captures sample", function() Captures:Sample() end))
end



-- ============================================================================
-- Where the player is
-- ============================================================================

---The point at a place on a zone map (0 to 100), or nil.
---@param mapId number?
---@param x number?
---@param y number?
---@return table?
function Captures:PointAt(mapId, x, y)
	local yards = mapId and MAP_YARDS[mapId]
	if not yards or type(x) ~= "number" or type(y) ~= "number" then
		return nil
	end
	for _, point in ipairs(Captures.POINTS) do
		if point.mapId == mapId then
			local dx, dy = (x - point.x) / 100 * yards[1], (y - point.y) / 100 * yards[2]
			if dx * dx + dy * dy <= point.r * point.r then
				return point
			end
		end
	end
	return nil
end

---Whether one of the game's yes-or-no answers is yes. A secret answer is yes: it can't be read, so it can't be ruled
---out. A call that fails is yes too; a call the client doesn't have is no.
function private.Yes(func, ...)
	if type(func) ~= "function" then
		return false
	end
	local ok, result = pcall(func, ...)
	if not ok or (issecretvalue and issecretvalue(result)) then
		return true
	end
	return result == true
end

---Why the player's presence can't count right now ("Mounted"), or nil when it can.
---@return string?
function Captures:Blocked()
	if private.Yes(UnitIsDeadOrGhost, "player") then
		return "Dead"
	elseif private.Yes(IsInInstance) then
		return "In an instance"
	elseif private.Yes(UnitOnTaxi, "player") then
		return "On a flight"
	elseif private.Yes(IsMounted) then
		return "Mounted"
	elseif private.Yes(IsFlying, "player") then
		return "Flying"
	elseif C_PlayerInfo and private.Yes(C_PlayerInfo.GetGlidingInfo) then
		return "Gliding"
	elseif private.Yes(UnitInVehicle, "player") then
		return "In a vehicle"
	elseif private.Yes(IsStealthed) then
		return "Stealthed"
	elseif private.Yes(UnitIsAFK, "player") then
		return "Away"
	end
	return nil
end



-- ============================================================================
-- Sampling
-- ============================================================================

---Every 30 seconds: notes which point the player is in, says so on the way in, and counts a sample when the
---player's presence can count.
function Captures:Sample()
	local _, x, y, mapId = Wanted.Recorder:GetPosition()
	local point = Captures:PointAt(mapId, x, y)
	if point ~= private.current then
		private.current, private.toldBlocked = point, false
		if point then
			Wanted:Print("You're at %s, a capture point in %s. %s", point.name, point.zone, private.HolderText(point.id))
		end
	end
	if not point then
		return
	end
	local blocked = Captures:Blocked()
	if blocked then
		if not private.toldBlocked then
			private.toldBlocked = true
			Wanted:Print("%s: your presence at %s doesn't count until that changes.", blocked, point.name)
		end
		return
	end
	private.Count(point.id, GetServerTime())
end

---Adds a sample to the book for this character at a point.
function private.Count(pointId, now)
	local guid = UnitGUID("player")
	if type(guid) ~= "string" or (issecretvalue and issecretvalue(guid)) then
		return
	end
	local slot = floor(now / SLOT_SECONDS)
	local key = pointId..":"..slot..":"..guid
	local book = Wanted.db.presence
	local entry = book[key]
	if not entry then
		entry = { g = guid, n = Wanted.Store:GetOrigin(), p = pointId, s = slot, c = 0 }
		book[key] = entry
	end
	entry.c = min(entry.c + 1, MAX_SAMPLES)
end

---Drops entries older than KEEP_SECONDS or malformed, then the oldest past MAX_ENTRIES.
function private.Prune(now)
	local book = Wanted.db.presence
	local oldest = floor((now - KEEP_SECONDS) / SLOT_SECONDS)
	local kept = {}
	for key, entry in pairs(book) do
		if type(entry) ~= "table" or type(entry.s) ~= "number" or entry.s < oldest or not byId[entry.p] or type(entry.c) ~= "number" then
			book[key] = nil
		else
			tinsert(kept, key)
		end
	end
	if #kept > MAX_ENTRIES then
		sort(kept, function(a, b) return book[a].s < book[b].s end)
		for i = 1, #kept - MAX_ENTRIES do
			book[kept[i]] = nil
		end
	end
end



-- ============================================================================
-- Holders, from the site
-- ============================================================================

---Takes the holders the site worked out, from the app's catch-up: { [point id] = { h = "H" | "A" | "", s, t } }.
---Only shown, so it's read at every login.
---@param points table?
function Captures:Take(points)
	private.holds = {}
	if type(points) ~= "table" then
		return
	end
	for id, hold in pairs(points) do
		if byId[id] and type(hold) == "table" and type(hold.t) == "number" then
			private.holds[id] = {
				h = hold.h == "H" and "Horde" or hold.h == "A" and "Alliance" or nil,
				s = type(hold.s) == "number" and hold.s or nil,
				t = hold.t,
			}
		end
	end
end

---Who holds a point as the site last told the app: { h, s, t }, or nil when the site hasn't said.
---@param id string
---@return table?
function Captures:Holder(id)
	return private.holds[id]
end

---"Held by the Horde when the app last checked (2h ago)." or what to say when the site hasn't said.
function private.HolderText(id)
	local hold = private.holds[id]
	if not hold then
		return "wanteddeadordead.com decides who holds it from the players there."
	end
	local ago = Wanted.Theme:Ago(GetServerTime() - hold.t)
	if not hold.h then
		return format("Nobody held it when the app last checked (%s).", ago)
	end
	return format("Held by the %s when the app last checked (%s).", hold.h, ago)
end

Wanted:RegisterCommand("points", "Lists the capture points and who held them when the desktop app last checked.", function()
	for _, point in ipairs(Captures.POINTS) do
		Wanted:Print("%s, %s %.0f,%.0f: %s", point.name, point.zone, point.x, point.y, private.HolderText(point.id))
	end
end)
