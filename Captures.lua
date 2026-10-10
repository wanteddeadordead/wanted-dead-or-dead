-- Wanted: capture fronts, played like a MOBA. Each front is a zone with each side's flight master as its base and three
-- lanes between them, four points to a lane: the two nearer the Horde start the Horde's, the two nearer the Alliance
-- the Alliance's. A side takes a lane's points in order from its own base; holding one of the enemy's inhibitors (the
-- point before their base) opens their base, and taking it wins the front for the week.
--
-- wanteddeadordead.com decides who holds what, from several players' apps and the kills there; this client never does.
-- While the player stands in a point able to fight, the addon counts it every 30 seconds in a presence book the
-- desktop app sends the site, and tells its side's channel (provisional news, shown, never counted). The site's holds
-- come back through the app's catch-up, read at login.

local _, Wanted = ...
local Captures = Wanted:NewModule("Captures")
local private = {
	current = nil, -- the point the player is in, as of the last sample
	toldBlocked = false, -- why the presence doesn't count was said this visit
	holds = {}, -- point id -> { h = "Horde" | "Alliance", s = since, r = respawn at, t = when the site worked it out }
	heard = {}, -- point id -> { [sender] = GetTime() } players of our side who said they're there
	mine = nil, -- { p = point id, at = GetTime() } our own last counted sample
	sentAt = 0, -- when we last told the channel
	listeners = {},
}
local SAMPLE_SECONDS = 30
-- A slot is five minutes of game-server time; a sample adds one to the player's count at a point in the slot
local SLOT_SECONDS = 300
local MAX_SAMPLES = SLOT_SECONDS / SAMPLE_SECONDS
-- The book keeps three days (the app sends it at its next catch-up) and at most this many entries
local KEEP_SECONDS = 3 * 24 * 60 * 60
local MAX_ENTRIES = 2000
-- The site's rules, for what the addon shows (stats/points.go): people a side needs at a point, slots in a row to take
-- a lane point or a base
local MIN_PEOPLE = 2
local CAPTURE_SLOTS, BASE_SLOTS = 2, 3
-- Our side's players heard at a point count as there this long; we tell the channel at most this often
local HEARD_SECONDS = 90
local SEND_SECONDS = 60
local TOWER_RADIUS, BASE_RADIUS = 40, 50
Captures.SLOT_SECONDS = SLOT_SECONDS
Captures.MIN_PEOPLE = MIN_PEOPLE
Captures.CAPTURE_SLOTS, Captures.BASE_SLOTS = CAPTURE_SLOTS, BASE_SLOTS

-- Each zone map's size in yards: width (the world's Y span) and height (its X span), from the game's UiMapAssignment
-- table as wanteddeadordead.com keeps it (stats.mapWorld), so a point's circle is round on the map
local MAP_YARDS = {
	[1417] = { 3600.0, 2400.0 }, -- Arathi Highlands
	[1424] = { 3200.0, 2133.3 }, -- Hillsbrad Foothills
	[1440] = { 5766.7, 3843.8 }, -- Ashenvale
}
Captures.MAP_YARDS = MAP_YARDS
-- The fronts, as the site holds them (stats.Fronts). Bases on the flight masters (Questie v10 classicNpcDB, matching
-- TaxiNodes); outer points on the game's named areas or a Spirit Healer (NPC 6491); inhibitors halfway to the base
-- unless a graveyard is there. Every position is to be confirmed in game. Lane points run from the Horde base.
Captures.FRONTS = {
	{ id = "ah", zone = "Arathi Highlands", mapId = 1417,
		horde = { id = "ah-horde", name = "Hammerfall", x = 73.0, y = 32.7 }, -- flight master Urda (NPC 2851, TaxiNodes 17)
		alliance = { id = "ah-alliance", name = "Refuge Pointe", x = 45.7, y = 46.1 }, -- flight master Cedrik Prose (NPC 2835, TaxiNodes 16)
		lanes = {
			{ id = "top", name = "North road", points = {
				{ id = "ah-top-1", name = "North road to Hammerfall", x = 68.3, y = 33.4 }, -- halfway from Hammerfall to Circle of East Binding (derived)
				{ id = "ah-top-2", name = "Circle of East Binding", x = 63.7, y = 34.0 }, -- area Circle of East Binding (WorldMapOverlay hit rect, Classic Era 1.15.9)
				{ id = "ah-top-3", name = "Dabyrie's Farmstead", x = 55.1, y = 39.6 }, -- area Dabyrie's Farmstead (WorldMapOverlay hit rect, Classic Era 1.15.9)
				{ id = "ah-top-4", name = "North road to Refuge Pointe", x = 50.4, y = 42.9 }, -- halfway from Dabyrie's Farmstead to Refuge Pointe (derived)
			} },
			{ id = "mid", name = "The farms", points = {
				{ id = "ah-mid-1", name = "Middle road to Hammerfall", x = 67.2, y = 44.6 }, -- halfway from Hammerfall to Go'Shek Farm (derived)
				{ id = "ah-mid-2", name = "Go'Shek Farm", x = 61.4, y = 56.5 }, -- area Go'Shek Farm (WorldMapOverlay hit rect, Classic Era 1.15.9)
				{ id = "ah-mid-3", name = "Arathi graveyard", x = 48.8, y = 55.6 }, -- Spirit Healer (NPC 6491, Questie v10 classicNpcDB)
				{ id = "ah-mid-4", name = "Middle road to Refuge Pointe", x = 47.2, y = 50.9 }, -- halfway from Arathi graveyard to Refuge Pointe (derived)
			} },
			{ id = "bot", name = "South", points = {
				{ id = "ah-bot-1", name = "South road to Hammerfall", x = 69.8, y = 49.9 }, -- halfway from Hammerfall to Witherbark Village (derived)
				{ id = "ah-bot-2", name = "Witherbark Village", x = 66.7, y = 67.0 }, -- area Witherbark Village (WorldMapOverlay hit rect, Classic Era 1.15.9)
				{ id = "ah-bot-3", name = "Boulderfist Hall", x = 54.1, y = 73.7 }, -- area Boulderfist Hall (WorldMapOverlay hit rect, Classic Era 1.15.9)
				{ id = "ah-bot-4", name = "South road to Refuge Pointe", x = 49.9, y = 59.9 }, -- halfway from Boulderfist Hall to Refuge Pointe (derived)
			} },
		},
	},
	{ id = "hb", zone = "Hillsbrad Foothills", mapId = 1424,
		horde = { id = "hb-horde", name = "Tarren Mill", x = 60.1, y = 18.6 }, -- flight master Zarise (NPC 2389, TaxiNodes 13)
		alliance = { id = "hb-alliance", name = "Southshore", x = 49.3, y = 52.3 }, -- flight master Darla Harris (NPC 2432, TaxiNodes 14)
		lanes = {
			{ id = "top", name = "West, by the fields", points = {
				{ id = "hb-top-1", name = "West road to Tarren Mill", x = 51.0, y = 24.3 }, -- halfway from Tarren Mill to West of Darrow Hill (derived)
				{ id = "hb-top-2", name = "West of Darrow Hill", x = 42.0, y = 30.0 }, -- lane waypoint (placed by hand)
				{ id = "hb-top-3", name = "Hillsbrad Fields", x = 35.0, y = 44.9 }, -- area Hillsbrad Fields (WorldMapOverlay hit rect, Classic Era 1.15.9)
				{ id = "hb-top-4", name = "West road to Southshore", x = 42.1, y = 48.6 }, -- halfway from Hillsbrad Fields to Southshore (derived)
			} },
			{ id = "mid", name = "The road", points = {
				{ id = "hb-mid-1", name = "Middle road to Tarren Mill", x = 55.5, y = 26.1 }, -- halfway from Tarren Mill to Darrow Hill (derived)
				{ id = "hb-mid-2", name = "Darrow Hill", x = 50.9, y = 33.6 }, -- area Darrow Hill (WorldMapOverlay hit rect, Classic Era 1.15.9)
				{ id = "hb-mid-3", name = "Southshore road", x = 50.0, y = 43.0 }, -- lane waypoint (placed by hand)
				{ id = "hb-mid-4", name = "Middle road to Southshore", x = 49.6, y = 47.6 }, -- halfway from Southshore road to Southshore (derived)
			} },
			{ id = "bot", name = "East, by the keep", points = {
				{ id = "hb-bot-1", name = "East road to Tarren Mill", x = 68.5, y = 29.7 }, -- halfway from Tarren Mill to Durnholde Keep (derived)
				{ id = "hb-bot-2", name = "Durnholde Keep", x = 76.8, y = 40.8 }, -- area Durnholde Keep (WorldMapOverlay hit rect, Classic Era 1.15.9)
				{ id = "hb-bot-3", name = "Nethander Stead", x = 63.9, y = 55.4 }, -- area Nethander Stead (WorldMapOverlay hit rect, Classic Era 1.15.9)
				{ id = "hb-bot-4", name = "East road to Southshore", x = 56.6, y = 53.8 }, -- halfway from Nethander Stead to Southshore (derived)
			} },
		},
	},
	{ id = "av", zone = "Ashenvale", mapId = 1440,
		horde = { id = "av-horde", name = "Splintertree Post", x = 73.2, y = 61.6 }, -- flight master Vhulgra (NPC 12616, TaxiNodes 61)
		alliance = { id = "av-alliance", name = "Astranaar", x = 34.4, y = 48.0 }, -- flight master Daelyshia (NPC 4267, TaxiNodes 28)
		lanes = {
			{ id = "top", name = "North, the Howling Vale", points = {
				{ id = "av-top-1", name = "North road to Splintertree Post", x = 64.7, y = 49.3 }, -- halfway from Splintertree Post to The Howling Vale (derived)
				{ id = "av-top-2", name = "The Howling Vale", x = 56.1, y = 37.0 }, -- area The Howling Vale (WorldMapOverlay hit rect, Classic Era 1.15.9)
				{ id = "av-top-3", name = "Thistlefur Village", x = 36.9, y = 36.7 }, -- area Thistlefur Village (WorldMapOverlay hit rect, Classic Era 1.15.9)
				{ id = "av-top-4", name = "North road to Astranaar", x = 35.6, y = 42.4 }, -- halfway from Thistlefur Village to Astranaar (derived)
			} },
			{ id = "mid", name = "The road", points = {
				{ id = "av-mid-1", name = "Middle road to Splintertree Post", x = 67.0, y = 56.7 }, -- halfway from Splintertree Post to Raynewood Retreat (derived)
				{ id = "av-mid-2", name = "Raynewood Retreat", x = 60.9, y = 51.7 }, -- area Raynewood Retreat (WorldMapOverlay hit rect, Classic Era 1.15.9)
				{ id = "av-mid-3", name = "Iris Lake", x = 46.4, y = 46.8 }, -- area Iris Lake (WorldMapOverlay hit rect, Classic Era 1.15.9)
				{ id = "av-mid-4", name = "Astranaar graveyard", x = 40.5, y = 52.8 }, -- Spirit Healer (NPC 6491, Questie v10 classicNpcDB)
			} },
			{ id = "bot", name = "South, the lakes", points = {
				{ id = "av-bot-1", name = "South road to Splintertree Post", x = 71.2, y = 71.8 }, -- halfway from Splintertree Post to Fallen Sky Lake (derived)
				{ id = "av-bot-2", name = "Fallen Sky Lake", x = 69.2, y = 81.9 }, -- area Fallen Sky Lake (WorldMapOverlay hit rect, Classic Era 1.15.9)
				{ id = "av-bot-3", name = "Mystral Lake", x = 49.4, y = 73.3 }, -- area Mystral Lake (WorldMapOverlay hit rect, Classic Era 1.15.9)
				{ id = "av-bot-4", name = "South road to Astranaar", x = 41.9, y = 60.6 }, -- halfway from Mystral Lake to Astranaar (derived)
			} },
		},
	},
}
-- Every point, bases too: { id, name, front, lane (index, nil for a base), order (1-4 from the Horde base; 0 the Horde
-- base, 5 the Alliance's), x, y, r (yards), home }
local points, byId = {}, {}
for _, front in ipairs(Captures.FRONTS) do
	local function Add(p)
		tinsert(points, p)
		byId[p.id] = p
	end
	Add({ id = front.horde.id, name = front.horde.name, front = front, order = 0, x = front.horde.x, y = front.horde.y, r = BASE_RADIUS, home = "Horde" })
	for l, lane in ipairs(front.lanes) do
		for i, p in ipairs(lane.points) do
			Add({ id = p.id, name = p.name, front = front, lane = l, order = i, x = p.x, y = p.y, r = TOWER_RADIUS, home = i <= 2 and "Horde" or "Alliance" })
		end
	end
	Add({ id = front.alliance.id, name = front.alliance.name, front = front, order = 5, x = front.alliance.x, y = front.alliance.y, r = BASE_RADIUS, home = "Alliance" })
end
Captures.POINTS = points



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Captures:OnLoad()
	-- The presence book, for the app: "point:slot:guid" -> { g = GUID, n = name, p = point id, s = slot, c = samples }
	Wanted.db.presence = type(Wanted.db.presence) == "table" and Wanted.db.presence or {}
	private.Prune(GetServerTime())
	local settings = Wanted.db.settings
	settings.captures = type(settings.captures) == "table" and settings.captures or {}
	local c = settings.captures
	for key, value in pairs({ map = true, minimap = true, bar = true, alerts = true, autoTrack = false }) do
		if type(c[key]) ~= "boolean" then
			c[key] = value
		end
	end
end

function Captures:OnEnable()
	C_Timer.NewTicker(SAMPLE_SECONDS, Wanted:Timed("Captures sample", function() Captures:Sample() end))
end

---The capture settings: { map, minimap, bar, alerts, autoTrack }.
function Captures:Settings()
	return Wanted.db.settings.captures
end

---Registers a function called when what the addon knows of the points changes (a sample, a peer, the site's holds).
function Captures:OnChange(func)
	tinsert(private.listeners, func)
end

function private.Changed()
	for _, func in ipairs(private.listeners) do
		func()
	end
end



-- ============================================================================
-- Fronts and points
-- ============================================================================

---The front on a map, or nil.
---@param mapId number?
function Captures:FrontOn(mapId)
	for _, front in ipairs(Captures.FRONTS) do
		if front.mapId == mapId then
			return front
		end
	end
	return nil
end

---A point by id (a lane point or a base), or nil.
function Captures:Get(id)
	return byId[id]
end

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
	for _, point in ipairs(points) do
		if point.front.mapId == mapId then
			local dx, dy = (x - point.x) / 100 * yards[1], (y - point.y) / 100 * yards[2]
			if dx * dx + dy * dy <= point.r * point.r then
				return point
			end
		end
	end
	return nil
end

---Who holds a point as the site last told the app: its home side until the site says otherwise.
---@param id string
---@return string "Horde" or "Alliance"
function Captures:Holder(id)
	local hold = private.holds[id]
	return hold and hold.h or (byId[id] and byId[id].home)
end

---The side that won a front this week (took the other's base), or nil.
function Captures:Winner(front)
	if Captures:Holder(front.alliance.id) == "Horde" then
		return "Horde"
	elseif Captures:Holder(front.horde.id) == "Alliance" then
		return "Alliance"
	end
	return nil
end

---A lane's points from the Horde base, as ids (made once: the bar and map ask every second).
function private.LaneIds(front, l)
	local lane = front.lanes[l]
	if not lane.ids then
		lane.ids = {}
		for i, p in ipairs(lane.points) do
			lane.ids[i] = p.id
		end
	end
	return lane.ids
end

---Whether a side may attack a point, as the site has it: a lane point when it holds every point of the lane between
---its own base and this one; a base when it holds one of that base's side's inhibitors. Never once the front is won.
---@param side string
---@param point table
function Captures:CanAttack(side, point)
	if Captures:Winner(point.front) or Captures:Holder(point.id) == side then
		return false
	end
	if not point.lane then
		for l in ipairs(point.front.lanes) do
			local ids = private.LaneIds(point.front, l)
			if Captures:Holder(point.home == "Alliance" and ids[#ids] or ids[1]) == side then
				return true
			end
		end
		return false
	end
	for i, id in ipairs(private.LaneIds(point.front, point.lane)) do
		local between = side == "Horde" and i < point.order or side == "Alliance" and i > point.order
		if between and Captures:Holder(id) ~= side then
			return false
		end
	end
	return true
end

---How many points each side holds on a front: horde, alliance.
function Captures:Count(front)
	local horde, alliance = 0, 0
	for _, point in ipairs(points) do
		if point.front == front then
			if Captures:Holder(point.id) == "Horde" then
				horde = horde + 1
			else
				alliance = alliance + 1
			end
		end
	end
	return horde, alliance
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

---The point the player stood in at the last sample, or nil.
function Captures:Current()
	return private.current
end



-- ============================================================================
-- Sampling
-- ============================================================================

---Every 30 seconds: notes which point the player is in, says so on the way in, and counts a sample when the
---player's presence can count (and tells our side, at most once a minute).
function Captures:Sample()
	local _, x, y, mapId = Wanted.Recorder:GetPosition()
	local point = Captures:PointAt(mapId, x, y)
	if point ~= private.current then
		private.current, private.toldBlocked = point, false
		if point then
			Wanted:Print("You're at %s, a capture point in %s. %s", point.name, point.front.zone, private.HolderText(point.id))
		end
	end
	if point then
		local blocked = Captures:Blocked()
		if blocked then
			private.mine = nil
			if not private.toldBlocked then
				private.toldBlocked = true
				Wanted:Print("%s: your presence at %s doesn't count until that changes.", blocked, point.name)
			end
		else
			local now = GetServerTime()
			local entry = private.Count(point.id, now)
			private.mine = { p = point.id, at = GetTime() }
			if entry and GetTime() - private.sentAt >= SEND_SECONDS then
				private.sentAt = GetTime()
				Wanted.Sync:SendPoint({ p = point.id, s = entry.s, c = entry.c })
			end
		end
	else
		private.mine = nil
	end
	Captures:AutoTrack()
	private.Changed()
end

---Adds a sample to the book for this character at a point. Returns the entry.
function private.Count(pointId, now)
	local guid = UnitGUID("player")
	if type(guid) ~= "string" or (issecretvalue and issecretvalue(guid)) then
		return nil
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
	return entry
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
-- Our side, right now (provisional)
-- ============================================================================

---A player of our side says they're at a point (Sync, from the channel's own sender): { p, s, c }. Shown only.
---@param tbl table
---@param sender string
function Captures:OnPeer(tbl, sender)
	local point = type(tbl.p) == "string" and byId[tbl.p]
	local slot = floor(GetServerTime() / SLOT_SECONDS)
	if not point or type(sender) ~= "string" or type(tbl.s) ~= "number" or abs(tbl.s - slot) > 1 or type(tbl.c) ~= "number"
		or tbl.c < 1 or tbl.c > MAX_SAMPLES then
		return
	end
	-- One sender is at one point
	for _, heard in pairs(private.heard) do
		heard[sender] = nil
	end
	private.heard[point.id] = private.heard[point.id] or {}
	private.heard[point.id][sender] = GetTime()
	private.Changed()
end

---How many of our side are at a point now: players heard in the last HEARD_SECONDS, and us.
---@param id string
---@return number
function Captures:Allies(id)
	local now, count = GetTime(), 0
	for sender, at in pairs(private.heard[id] or {}) do
		if now - at <= HEARD_SECONDS then
			count = count + 1
		else
			private.heard[id][sender] = nil
		end
	end
	if private.mine and private.mine.p == id and now - private.mine.at <= HEARD_SECONDS then
		count = count + 1
	end
	return count
end

---Whether our side looks to be taking a point now: enough of us there, and it's ours to attack.
---@param point table
---@return boolean
function Captures:Taking(point)
	local side = UnitFactionGroup("player")
	return Captures:Allies(point.id) >= MIN_PEOPLE and Captures:CanAttack(side, point)
end



-- ============================================================================
-- Holders, from the site
-- ============================================================================

---Takes the holders the site worked out, from the app's catch-up: { [point id] = { h = "H" | "A", s, r, t } }. Only
---shown, so it's read at every login.
---@param list table?
function Captures:Take(list)
	private.holds = {}
	if type(list) == "table" then
		for id, hold in pairs(list) do
			if byId[id] and type(hold) == "table" and type(hold.t) == "number" and (hold.h == "H" or hold.h == "A") then
				private.holds[id] = {
					h = hold.h == "H" and "Horde" or "Alliance",
					s = type(hold.s) == "number" and hold.s > 0 and hold.s or nil,
					r = type(hold.r) == "number" and hold.r > 0 and hold.r or nil,
					t = hold.t,
				}
			end
		end
	end
	private.Changed()
end

---What the site last said of a point: { h, s, r, t }, or nil when it hasn't.
---@param id string
---@return table?
function Captures:Hold(id)
	return private.holds[id]
end

---"Held by the Horde when the app last checked (2h ago)." or what to say when the site hasn't said.
function private.HolderText(id)
	local hold = private.holds[id]
	if not hold then
		return format("The %s's at the start of the week; wanteddeadordead.com decides who holds it from the players there.", byId[id].home)
	end
	return format("Held by the %s when the app last checked (%s).", hold.h, Wanted.Theme:Ago(GetServerTime() - hold.t))
end
Captures.HolderText = function(_, id) return private.HolderText(id) end



-- ============================================================================
-- Waypoints
-- ============================================================================

---Sets the game's map waypoint on a point and tracks it (the marker in the world). Returns whether it was set.
---@param point table
---@return boolean
function Captures:Track(point)
	local mapId = point.front.mapId
	if not (C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates) then
		return false
	end
	if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(mapId) then
		return false
	end
	local ok, set = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(mapId, point.x / 100, point.y / 100))
	if not ok or set == false then
		return false
	end
	if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
		pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
	end
	private.ours = { mapId = mapId, x = point.x / 100, y = point.y / 100, id = point.id }
	return true
end

---Whether the map's waypoint now is the one we set (or there is none): only ours is ever replaced.
function private.WaypointIsOurs()
	if not (C_Map and C_Map.HasUserWaypoint and C_Map.HasUserWaypoint()) then
		return true
	end
	local ours = private.ours
	local current = C_Map.GetUserWaypoint and C_Map.GetUserWaypoint()
	if not ours or type(current) ~= "table" then
		return false
	end
	local pos = current.position
	local x, y = pos and (pos.x or (pos.GetXY and pos:GetXY())), pos and pos.y
	return current.uiMapID == ours.mapId and type(x) == "number" and type(y) == "number" and abs(x - ours.x) < 0.001 and abs(y - ours.y) < 0.001
end

---With the setting on, keeps the waypoint on the nearest point in the player's front that our side may attack. Never
---replaces a waypoint the player set.
function Captures:AutoTrack()
	if not Captures:Settings().autoTrack or not private.WaypointIsOurs() then
		return
	end
	local _, x, y, mapId = Wanted.Recorder:GetPosition()
	local front, yards = Captures:FrontOn(mapId), MAP_YARDS[mapId]
	if not front or not x then
		return
	end
	local side, best, bestDistance = UnitFactionGroup("player"), nil, nil
	for _, point in ipairs(points) do
		if point.front == front and Captures:CanAttack(side, point) then
			local dx, dy = (x - point.x) / 100 * yards[1], (y - point.y) / 100 * yards[2]
			local distance = dx * dx + dy * dy
			if not bestDistance or distance < bestDistance then
				best, bestDistance = point, distance
			end
		end
	end
	if best and (not private.ours or private.ours.id ~= best.id) then
		Captures:Track(best)
	end
end

Wanted:RegisterCommand("points", "Lists the capture fronts and who held each point when the desktop app last checked.", function()
	for _, front in ipairs(Captures.FRONTS) do
		local horde, alliance = Captures:Count(front)
		local winner = Captures:Winner(front)
		Wanted:Print("%s: Horde %d, Alliance %d%s", front.zone, horde, alliance, winner and (", won by the "..winner) or "")
		for _, point in ipairs(points) do
			if point.front == front then
				Wanted:Print("  %s %.0f,%.0f: %s", point.name, point.x, point.y, private.HolderText(point.id))
			end
		end
	end
end)
