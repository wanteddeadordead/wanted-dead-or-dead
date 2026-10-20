-- Wanted: presence at race and war points. While the player stands on a point able to fight, Races and WarLive count
-- it every 30 seconds here: in the presence book the desktop app sends the site (WantedDB.presence), and at once on
-- the game's log, where the app reads it within a minute. wanteddeadordead.com decides what the samples are worth;
-- this client never does. Also what the points share: why the player's presence can't count right now, a waypoint on
-- a point, and the size in yards of the maps the game doesn't give one for.

local _, Wanted = ...
local Presence = Wanted:NewModule("Presence")
local private = {}
-- A slot is five minutes of game-server time; a sample adds one to the player's count at a point in the slot
local SLOT_SECONDS = 300
local SAMPLE_SECONDS = 30
local MAX_SAMPLES = SLOT_SECONDS / SAMPLE_SECONDS
-- The book keeps three days (the app sends it at its next catch-up) and at most this many entries
local KEEP_SECONDS = 3 * 24 * 60 * 60
local MAX_ENTRIES = 2000
-- Druid forms that travel (Travel, Aquatic, Flight, Swift Flight Form): presence there doesn't count. Spell ids to
-- confirm in game
local TRAVEL_FORMS = { [783] = true, [1066] = true, [33943] = true, [40120] = true }
Presence.SLOT_SECONDS = SLOT_SECONDS

-- Each zone map's size in yards where the game gives none: width (the world's Y span) and height (its X span), from
-- the game's UiMapAssignment table as wanteddeadordead.com keeps it (stats.mapWorld)
Presence.MAP_YARDS = {
	[1417] = { 3600.0, 2400.0 }, -- Arathi Highlands
	[1424] = { 3200.0, 2133.3 }, -- Hillsbrad Foothills
	[1440] = { 5766.7, 3843.8 }, -- Ashenvale
}

function Presence:OnLoad()
	-- The presence book, for the app: "point:slot:guid" -> { g = GUID, n = name, f = side, p = point id, s = slot,
	-- c = samples, l = our layer of the zone at the last sample (Shard), left out while it isn't known }
	Wanted.db.presence = type(Wanted.db.presence) == "table" and Wanted.db.presence or {}
	private.Prune(GetServerTime())
end



-- ============================================================================
-- Where the player is
-- ============================================================================

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
function Presence:Blocked()
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
	elseif private.TravelForm() then
		return "In travel form"
	end
	return nil
end

---Whether the player is in a druid form that travels: the active form's spell (GetShapeshiftForm, GetShapeshiftFormInfo).
function private.TravelForm()
	if type(GetShapeshiftForm) ~= "function" or type(GetShapeshiftFormInfo) ~= "function" then
		return false
	end
	local ok, index = pcall(GetShapeshiftForm)
	if not ok or type(index) ~= "number" or (issecretvalue and issecretvalue(index)) or index <= 0 then
		return false
	end
	local okInfo, _, _, _, spellId = pcall(GetShapeshiftFormInfo, index)
	return okInfo and type(spellId) == "number" and TRAVEL_FORMS[spellId] == true
end



-- ============================================================================
-- The presence book
-- ============================================================================

---Adds a sample to the book for this character at a race or war point ("hb-r2", "hb-top-h-tower"). Returns the
---entry, or nil when this character can't be named.
---@param pointId string
---@param now number server time
---@return table?
function Presence:Count(pointId, now)
	local guid = UnitGUID("player")
	if type(guid) ~= "string" or (issecretvalue and issecretvalue(guid)) then
		return nil
	end
	local slot = floor(now / SLOT_SECONDS)
	local key = pointId..":"..slot..":"..guid
	local book = Wanted.db.presence
	local entry = book[key]
	if not entry then
		entry = { g = guid, n = Wanted.Store:GetOrigin(), f = UnitFactionGroup("player"), p = pointId, s = slot, c = 0 }
		book[key] = entry
	end
	entry.c = min(entry.c + 1, MAX_SAMPLES)
	entry.l = Wanted.Shard:Current() or entry.l
	private.WriteLive(entry)
	return entry
end

---The sample, at once, on the game's log file (Logs\General.log, written within seconds): the Wanted app reads it
---there and passes it to the site within a minute, where the saved data reaches the app only at a /reload or logout.
---One line: "WANTEDP1 <account mark> <point> <slot> <count> <side> <layer or -> <GUID> <name>" (the name last: it has
---spaces).
function private.WriteLive(entry)
	local mark = Wanted.db.accountMark
	if not (C_Log and C_Log.LogMessage) or type(mark) ~= "string" or not strmatch(mark, "^%w+$") then
		return
	end
	local layer = type(entry.l) == "string" and strmatch(entry.l, "^[%w%-]+$") and entry.l or "-"
	C_Log.LogMessage(format("WANTEDP1 %s %s %d %d %s %s %s %s", mark, entry.p, entry.s, entry.c, entry.f, layer, entry.g, entry.n))
end

---Drops entries older than KEEP_SECONDS or malformed, then the oldest past MAX_ENTRIES. Any well-formed point id is
---kept to its age (the site checks the points): entries from the retired capture fronts only age out.
function private.Prune(now)
	local book = Wanted.db.presence
	local oldest = floor((now - KEEP_SECONDS) / SLOT_SECONDS)
	local kept = {}
	for key, entry in pairs(book) do
		if type(entry) ~= "table" or type(entry.s) ~= "number" or entry.s < oldest or type(entry.c) ~= "number"
			or type(entry.p) ~= "string" or not strmatch(entry.p, "^[a-z0-9%-]+$") then
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
-- Waypoints
-- ============================================================================

---Sets the game's map waypoint on a place and tracks it (the marker in the world). Returns whether it was set.
---@param mapId number the zone map
---@param x number 0 to 100
---@param y number 0 to 100
---@return boolean
function Presence:Track(mapId, x, y)
	if not (C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates) then
		return false
	end
	if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(mapId) then
		return false
	end
	local ok, set = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(mapId, x / 100, y / 100))
	if not ok or set == false then
		return false
	end
	if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
		pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
	end
	return true
end
