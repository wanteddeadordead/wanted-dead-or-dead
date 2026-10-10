-- Wanted: capture fronts, played like a MOBA. Each front is a zone with each side's base, its Nexus, on the main road into
-- its flight-master town just outside the guards, and three lanes (Top, Mid, Bot) between them, four points to a lane:
-- each side's tower and, nearer its Nexus, its inhibitor. A side takes a lane in order from its own end; taking one of
-- the enemy's inhibitors opens their Nexus, and taking the Nexus wins the front for the week.
--
-- wanteddeadordead.com decides who holds what, from several players' apps and the kills there; this client never does.
-- While the player stands in a point able to fight, the addon counts it every 30 seconds in a presence book the
-- desktop app sends the site, and tells its side's channel (provisional news, shown, never counted). The site's holds
-- come back through the app's catch-up, read at login.

local _, Wanted = ...
local Captures = Wanted:NewModule("Captures")
local private = {
	current = nil, -- the point the player is in, as of the last sample
	holds = {}, -- point id -> { h = "Horde" | "Alliance", s = since, r = respawn at, t = when the site worked it out }
	heard = {}, -- point id -> { [sender] = GetTime() } players of our side who said they're there
	mine = nil, -- { p = point id, at = GetTime() } our own last counted sample
	sentAt = 0, -- when we last told the channel
	listeners = {},
	won = {}, -- front id -> the side that took the other's Nexus this week, by the site's holds
	blocked = nil, -- why the player's presence doesn't count, at the last sample
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
local CAPTURE_SLOTS, NEXUS_SLOTS = 2, 4
-- Our side's players heard at a point count as there this long; we tell the channel at most this often
local HEARD_SECONDS = 90
local SEND_SECONDS = 60
local TOWER_RADIUS, BASE_RADIUS = 40, 50
Captures.SLOT_SECONDS = SLOT_SECONDS
Captures.MIN_PEOPLE = MIN_PEOPLE
Captures.CAPTURE_SLOTS, Captures.NEXUS_SLOTS = CAPTURE_SLOTS, NEXUS_SLOTS
-- The words the addon shows, in one place: a side's base is its Nexus (Chris may rename it)
Captures.TERMS = { nexus = "Nexus", tower = "Tower", inhibitor = "Inhibitor" }
-- Campaign weeks start at this Tuesday 15:00 UTC plus whole weeks, as the site's (stats.CampaignStart)
local WEEK_ANCHOR, WEEK = 1790694000, 7 * 24 * 60 * 60
-- Druid forms that travel (Travel, Aquatic, Flight, Swift Flight Form): presence there doesn't count. Spell ids to
-- confirm in game
local TRAVEL_FORMS = { [783] = true, [1066] = true, [33943] = true, [40120] = true }

-- Each zone map's size in yards: width (the world's Y span) and height (its X span), from the game's UiMapAssignment
-- table as wanteddeadordead.com keeps it (stats.mapWorld), so a point's circle is round on the map
local MAP_YARDS = {
	[1417] = { 3600.0, 2400.0 }, -- Arathi Highlands
	[1424] = { 3200.0, 2133.3 }, -- Hillsbrad Foothills
	[1440] = { 5766.7, 3843.8 }, -- Ashenvale
}
Captures.MAP_YARDS = MAP_YARDS
-- The fronts, as the site holds them (stats.Fronts). Each base is a flight master (x, y: Questie v10 classicNpcDB) and its
-- Nexus (nx, ny) on the town's main approach outside the guards. Lane points run from the Horde Nexus, each on a ground
-- NPC's spawn (Questie v10) or a Spirit Healer where one is near, else placed by hand on the lane. Every position is to
-- be confirmed in game.
Captures.FRONTS = {
	{ id = "ah", zone = "Arathi Highlands", mapId = 1417,
		horde = { id = "ah-horde", name = "Hammerfall", x = 73.02, y = 32.70, nx = 69.14, ny = 33.80 }, -- flight master Urda (NPC 2851); Nexus: Plains Creeper (NPC 2563)
		alliance = { id = "ah-alliance", name = "Refuge Pointe", x = 45.73, y = 46.10, nx = 51.09, ny = 47.39 }, -- flight master Cedrik Prose (NPC 2835); Nexus: Highland Strider (NPC 2559)
		lanes = {
			{ id = "top", name = "Top", points = {
				{ id = "ah-top-1", name = "Circle of East Binding", x = 64.90, y = 34.00 }, -- on the lane, placed by hand
				{ id = "ah-top-2", name = "Circle of East Binding", x = 60.76, y = 35.12 }, -- Fozruk (NPC 2611)
				{ id = "ah-top-3", name = "Dabyrie's Farmstead", x = 56.55, y = 38.70 }, -- Fardel Dabyrie (NPC 4479)
				{ id = "ah-top-4", name = "Dabyrie's Farmstead", x = 53.76, y = 40.92 }, -- Lieutenant Valorcall (NPC 2612)
			} },
			{ id = "mid", name = "Mid", points = {
				{ id = "ah-mid-1", name = "near Circle of East Binding", x = 66.11, y = 43.66 }, -- Highland Strider (NPC 2559)
				{ id = "ah-mid-2", name = "Go'Shek Farm", x = 62.68, y = 52.93 }, -- Hammerfall Grunt (NPC 2619)
				{ id = "ah-mid-3", name = "near Go'Shek Farm", x = 57.10, y = 56.20 }, -- on the lane, placed by hand
				{ id = "ah-mid-4", name = "Arathi graveyard", x = 48.84, y = 55.61 }, -- Spirit Healer (NPC 6491)
			} },
			{ id = "bot", name = "Bot", points = {
				{ id = "ah-bot-1", name = "near Go'Shek Farm", x = 69.94, y = 50.23 }, -- Plains Creeper (NPC 2563)
				{ id = "ah-bot-2", name = "Witherbark Village", x = 66.32, y = 64.74 }, -- Witherbark Axe Thrower (NPC 2554)
				{ id = "ah-bot-3", name = "Boulderfist Hall", x = 57.20, y = 72.10 }, -- on the lane, placed by hand
				{ id = "ah-bot-4", name = "Boulderfist Hall", x = 50.16, y = 63.87 }, -- Highland Fleshstalker (NPC 2561)
			} },
		},
	},
	{ id = "hb", zone = "Hillsbrad Foothills", mapId = 1424,
		horde = { id = "hb-horde", name = "Tarren Mill", x = 60.14, y = 18.62, nx = 55.70, ny = 22.70 }, -- flight master Zarise (NPC 2389); Nexus: on the main approach, placed by hand
		alliance = { id = "hb-alliance", name = "Southshore", x = 49.34, y = 52.27, nx = 49.85, ny = 44.68 }, -- flight master Darla Harris (NPC 2432); Nexus: Vicious Gray Bear (NPC 2354)
		lanes = {
			{ id = "top", name = "Top", points = {
				{ id = "hb-top-1", name = "near Darrow Hill", x = 47.61, y = 26.09 }, -- Starving Mountain Lion (NPC 2384)
				{ id = "hb-top-2", name = "Hillsbrad Fields", x = 40.80, y = 32.60 }, -- on the lane, placed by hand
				{ id = "hb-top-3", name = "Hillsbrad Fields", x = 35.41, y = 42.01 }, -- Hillsbrad Peasant (NPC 2267)
				{ id = "hb-top-4", name = "Hillsbrad Fields", x = 42.35, y = 47.48 }, -- Elder Gray Bear (NPC 2356)
			} },
			{ id = "mid", name = "Mid", points = {
				{ id = "hb-mid-1", name = "near Darrow Hill", x = 54.10, y = 26.90 }, -- on the lane, placed by hand
				{ id = "hb-mid-2", name = "Darrow Hill", x = 52.30, y = 30.90 }, -- on the lane, placed by hand
				{ id = "hb-mid-3", name = "Darrow Hill", x = 50.80, y = 35.10 }, -- on the lane, placed by hand
				{ id = "hb-mid-4", name = "near Darrow Hill", x = 50.30, y = 39.90 }, -- on the lane, placed by hand
			} },
			{ id = "bot", name = "Bot", points = {
				{ id = "hb-bot-1", name = "Tarren Mill", x = 66.90, y = 28.87 }, -- Gray Bear (NPC 2351)
				{ id = "hb-bot-2", name = "Durnholde Keep", x = 75.15, y = 37.95 }, -- Syndicate Watchman (NPC 2261)
				{ id = "hb-bot-3", name = "Nethander Stead", x = 68.72, y = 48.87 }, -- Giant Moss Creeper (NPC 2349)
				{ id = "hb-bot-4", name = "Nethander Stead", x = 60.16, y = 52.72 }, -- Elder Moss Creeper (NPC 2348)
			} },
		},
	},
	{ id = "av", zone = "Ashenvale", mapId = 1440,
		horde = { id = "av-horde", name = "Splintertree Post", x = 73.18, y = 61.59, nx = 69.70, ny = 60.34 }, -- flight master Vhulgra (NPC 12616); Nexus: Shadethicket Stone Mover (NPC 3782)
		alliance = { id = "av-alliance", name = "Astranaar", x = 34.41, y = 47.99, nx = 39.50, ny = 48.00 }, -- flight master Daelyshia (NPC 4267); Nexus: on the main approach, placed by hand
		lanes = {
			{ id = "top", name = "Top", points = {
				{ id = "av-top-1", name = "Raynewood Retreat", x = 64.37, y = 49.36 }, -- Ghostpaw Alpha (NPC 3825)
				{ id = "av-top-2", name = "The Howling Vale", x = 57.13, y = 37.94 }, -- Elder Shadowhorn Stag (NPC 3818)
				{ id = "av-top-3", name = "near Iris Lake", x = 48.00, y = 36.90 }, -- on the lane, placed by hand
				{ id = "av-top-4", name = "Thistlefur Village", x = 38.45, y = 37.53 }, -- Ashenvale Bear (NPC 3809)
			} },
			{ id = "mid", name = "Mid", points = {
				{ id = "av-mid-1", name = "Raynewood Retreat", x = 63.81, y = 55.18 }, -- Elder Ashenvale Bear (NPC 3810)
				{ id = "av-mid-2", name = "Raynewood Retreat", x = 57.20, y = 50.40 }, -- on the lane, placed by hand
				{ id = "av-mid-3", name = "Iris Lake", x = 49.79, y = 48.70 }, -- Shadowhorn Stag (NPC 3817)
				{ id = "av-mid-4", name = "Astranaar graveyard", x = 40.49, y = 52.76 }, -- Spirit Healer (NPC 6491)
			} },
			{ id = "bot", name = "Bot", points = {
				{ id = "av-bot-1", name = "Fallen Sky Lake", x = 70.56, y = 76.28 }, -- Wildthorn Stalker (NPC 3819)
				{ id = "av-bot-2", name = "near Fallen Sky Lake", x = 62.17, y = 78.76 }, -- Wildthorn Stalker (NPC 3819)
				{ id = "av-bot-3", name = "Mystral Lake", x = 50.84, y = 75.08 }, -- Krolg (NPC 3897)
				{ id = "av-bot-4", name = "near Mystral Lake", x = 44.43, y = 62.64 }, -- Shadowhorn Stag (NPC 3817)
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
	Add({ id = front.horde.id, name = front.horde.name, front = front, order = 0, x = front.horde.nx, y = front.horde.ny, r = BASE_RADIUS, home = "Horde" })
	for l, lane in ipairs(front.lanes) do
		for i, p in ipairs(lane.points) do
			Add({ id = p.id, name = p.name, front = front, lane = l, order = i, x = p.x, y = p.y, r = TOWER_RADIUS, home = i <= 2 and "Horde" or "Alliance" })
		end
	end
	Add({ id = front.alliance.id, name = front.alliance.name, front = front, order = 5, x = front.alliance.nx, y = front.alliance.ny, r = BASE_RADIUS, home = "Alliance" })
end
Captures.POINTS = points



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Captures:OnLoad()
	-- The presence book, for the app: "point:slot:guid" -> { g = GUID, n = name, f = side, p = point id, s = slot,
	-- c = samples }
	Wanted.db.presence = type(Wanted.db.presence) == "table" and Wanted.db.presence or {}
	private.Prune(GetServerTime())
	-- What the site last said of each point, as the addon showed it: { week, [id] = holder }, to tell what changed since
	Wanted.db.captureSeen = type(Wanted.db.captureSeen) == "table" and Wanted.db.captureSeen or {}
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

---Registers a function called when what the addon knows of the points changes (a sample, a peer, the site's holds):
---func(fresh), fresh true when the site's holds just came in (their news waits in Captures:TakeNews).
function Captures:OnChange(func)
	tinsert(private.listeners, func)
end

function private.Changed(fresh)
	for _, func in ipairs(private.listeners) do
		func(fresh)
	end
end

---The campaign week that t falls in: when it started.
function Captures:WeekStart(t)
	return WEEK_ANCHOR + floor((t - WEEK_ANCHOR) / WEEK) * WEEK
end

---What a point is called with its role: "Mid Tower", "Bot Inhibitor", "Nexus".
function Captures:Role(point)
	if not point.lane then
		return Captures.TERMS.nexus
	end
	local lane = point.front.lanes[point.lane]
	local inhibitor = point.order == 1 or point.order == 4
	return lane.name.." "..(inhibitor and Captures.TERMS.inhibitor or Captures.TERMS.tower)
end

---Its kind: "tower", "inhibitor" or "nexus" (the icons).
function Captures:Kind(point)
	return not point.lane and "nexus" or (point.order == 1 or point.order == 4) and "inhibitor" or "tower"
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

---Who holds a point as the site last told the app: its home side until the site says otherwise, and again once a taken
---inhibitor's respawn time has passed (the site will say so too, unless its takers held it since: provisional).
---@param id string
---@return string "Horde" or "Alliance"
function Captures:Holder(id)
	local hold, point = private.holds[id], byId[id]
	if not hold or not point then
		return point and point.home
	end
	if hold.r and GetServerTime() >= hold.r and hold.h ~= point.home and not private.won[point.front.id] then
		return point.home
	end
	return hold.h
end

---The side that won a front this week (took the other's base), or nil.
function Captures:Winner(front)
	return private.won[front.id]
end

---Works out which fronts the site's holds say are won (a Nexus held by the other side).
function private.Won()
	private.won = {}
	for _, front in ipairs(Captures.FRONTS) do
		local h, a = private.holds[front.horde.id], private.holds[front.alliance.id]
		private.won[front.id] = a and a.h == "Horde" and "Horde" or h and h.h == "Alliance" and "Alliance" or nil
	end
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

---Why the player's presence didn't count at the last sample ("Mounted"), or nil.
function Captures:BlockedReason()
	return private.blocked
end

---The point the player stood in at the last sample, or nil.
function Captures:Current()
	return private.current
end



-- ============================================================================
-- Sampling
-- ============================================================================

---Every 30 seconds: notes which point the player is in and counts a sample when the player's presence can count (and
---tells our side, at most once a minute). The bar at the top shows it (CapturesHUD).
function Captures:Sample()
	local _, x, y, mapId = Wanted.Recorder:GetPosition()
	local point = Captures:PointAt(mapId, x, y)
	private.current, private.blocked = point, nil
	if point then
		local blocked = Captures:Blocked()
		if blocked then
			private.mine, private.blocked = nil, blocked
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
		entry = { g = guid, n = Wanted.Store:GetOrigin(), f = UnitFactionGroup("player"), p = pointId, s = slot, c = 0 }
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
		private.Won()
		-- Held until the HUD takes it: the catch-up is read at login before the HUD is enabled (Catchup comes first in
		-- the .toc), and what the addon showed is only marked once it's shown
		private.pending = private.News()
	else
		private.Won()
	end
	private.Changed(type(list) == "table")
end

---The news of the site's last holds, once: { { kind, point } }, or nil when there's none waiting. Marks what the addon
---showed, so the next login tells only what changed since.
function Captures:TakeNews()
	local news = private.pending
	private.pending = nil
	if not news then
		return nil
	end
	local seen = Wanted.db.captureSeen
	local week = Captures:WeekStart(GetServerTime())
	if seen.week ~= week then
		wipe(seen)
		seen.week = week
	end
	for _, point in ipairs(points) do
		seen[point.id] = Captures:Holder(point.id)
	end
	return news
end

---What changed since the addon last showed the site's holds, this week: { { kind, point } }, kind "lost" (one of our
---points taken), "taken" (one of theirs we took), "respawned" (an inhibitor back with its side), "won" or "beaten" (a
---front's Nexus). Nothing in a week the addon hasn't shown yet. Changes nothing (Captures:TakeNews marks it shown).
function private.News()
	local seen = Wanted.db.captureSeen
	local fresh = seen.week ~= Captures:WeekStart(GetServerTime())
	local side = UnitFactionGroup("player")
	local news = {}
	for _, point in ipairs(points) do
		local now = Captures:Holder(point.id)
		local before = seen[point.id] or point.home
		if now ~= before and not fresh then
			local kind
			if not point.lane then
				kind = now == side and "won" or "beaten"
			elseif now == point.home then
				kind = "respawned"
			elseif point.home == side then
				kind = "lost"
			else
				kind = "taken"
			end
			tinsert(news, { kind = kind, point = point })
		end
	end
	return news
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
	return format("Held by the %s when the app last checked (%s).", Captures:Holder(id), Wanted.Theme:Ago(GetServerTime() - hold.t))
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
				Wanted:Print("  %s (%s) %.0f,%.0f: %s", Captures:Role(point), point.name, point.x, point.y, private.HolderText(point.id))
			end
		end
	end
end)
