-- Map-open bench: what opening the world map costs with a large saved file (records, players and sightings made up).
-- usage, from the repo root: lua tests/map_open_bench.lua [addon dir] [records] [records in the last hour]
-- Times are desktop Lua; the beta client runs about 5x slower. Not part of CI.
local DIR = (arg[1] or "."):gsub("/$", "")
local NREC, NRECENT = tonumber(arg[2] or 10000), tonumber(arg[3] or 3000)
local src = io.open(DIR.."/tests/smoke_test.lua"):read("a")
local prelude = src:sub(1, src:find("-- Load the addon in .toc order", 1, true) - 1)
prelude = prelude:gsub('local ADDON = "%./"', function() return 'local ADDON = "'..DIR..'/"' end)
local bench = [==[
local NREC, NRECENT = ...
local SHARED = NewMock()
local function NOOP() return SHARED end
local creators = {}
local origIndex = Mock.__index
Mock.__index = function(t, k)
	if type(k) == "string" and k:match("^[SGHI][a-z]*[A-Z]") and not k:match("^Create") and not Methods[k] and (k:match("^Set") or k:match("^Get") or k:match("^Is") or k:match("^Hide") or k:match("^Show") or k:match("^Clear") or k:match("^Enable") or k:match("^Disable") or k:match("^Register") or k:match("^Unregister")) then
		return NOOP
	end
	return origIndex(t, k)
end
function Methods:SetAttribute(k, v) self._attr = self._attr or {} self._attr[k] = v end
function Methods:GetAttribute(k) return self._attr and self._attr[k] end
local providers = {}
local realAdd = WorldMapFrame.AddDataProvider
WorldMapFrame.AddDataProvider = function(self, p) providers[#providers + 1] = p return realAdd(self, p) end
-- realistic saved data
local NOW = 1790697600
clock = NOW
local MAPS = { 1424, 1417, 1440, 1434, 1446, 1413, 1411, 1412, 1429, 1430 }
WantedDB = { records = {}, players = {}, sightings = {}, sightingsPos = 1, ignore = {}, settings = {} }
local db = WantedDB
math.randomseed(7)
local origin = "Bench Peer"
for i = 1, NREC do
	local recent = i <= NRECENT
	local kind = (i % 2 == 0) and "kill" or "death"
	local killer = format("Player-4619-%08X", math.random(1, 3000))
	local victim = format("Player-4619-%08X", math.random(3001, 6000))
	local mapId = MAPS[math.random(#MAPS)]
	local id = origin..":"..i
	db.records[id] = { kind = kind, id = id, origin = origin, seq = i, prev = "x", hash = "h", live = true,
		t = recent and (NOW - math.random(0, 3500)) or (NOW - 4000 - math.random(0, 86400 * 20)),
		data = { killer = killer, victim = victim, killerName = "K"..i, victimName = "V"..i, killerFaction = (i % 3 == 0) and "Horde" or "Alliance",
			victimFaction = (i % 3 == 0) and "Alliance" or "Horde", zone = "Zone"..mapId, mapId = mapId, x = math.random() * 100, y = math.random() * 100, deathId = format("%08x", i), killerClass = "MAGE", victimClass = "ROGUE", killerLevel = 20, victimLevel = 20 } }
end
for i = 1, 6000 do
	local g = format("Player-4619-%08X", i)
	local mapId = MAPS[math.random(#MAPS)]
	db.players[g] = { name = "Enemy"..i, class = "MAGE", level = 20, faction = (i % 2 == 0) and "Horde" or "Alliance", lastSeen = (i % 3 == 0) and (NOW - math.random(0, 3500)) or (NOW - 90000), mapId = mapId, zone = "Zone"..mapId, guild = i % 7 == 0 and "G"..(i % 5) or nil }
end
for i = 1, 500 do
	local mapId = MAPS[math.random(#MAPS)]
	db.sightings[i] = { guid = format("Player-4619-%08X", math.random(1, 6000)), t = NOW - math.random(0, 1700), mapId = mapId, zone = "Zone"..mapId, x = math.random() * 100, y = math.random() * 100 }
end
db.sightingsPos = 1
WantedDeadOrDead_DB = nil
_G.WantedDB = db
local ns = {}
WantedTestNS = ns
for line in io.lines(ADDON.."WantedDeadOrDead.toc") do
	line = line:gsub("\r", "")
	if line ~= "" and not line:match("^#") and not line:match("%.xml$") and not line:match("Debug%.lua") then
		assert(loadfile(ADDON..line:gsub("\\", "/")))("WantedDeadOrDead", ns)
	end
end
Fire("ADDON_LOADED", "WantedDeadOrDead")
Fire("PLAYER_LOGIN")
RunTimers()
for _ = 1, 20 do RunFrames() RunTimers() end
clock = NOW
local canvas = NewMock()
canvas._w, canvas._h = 1002, 668
WorldMapFrame.GetCanvas = function() return canvas end
WorldMapFrame.IsShown = function() return true end
local mapId = 1424
WorldMapFrame.GetMapID = function() return mapId end
print(format("addon %s: %d providers, %d records, %d recent", ADDON, #providers, NREC, NRECENT))
local function Time(label, f, n)
	collectgarbage("collect") collectgarbage("stop")
	local k0, t0 = collectgarbage("count"), os.clock()
	for _ = 1, n do f() end
	local ms = (os.clock() - t0) * 1000 / n
	local kb = (collectgarbage("count") - k0) / n
	collectgarbage("restart")
	print(format("  %-46s %9.2f ms  %9.1f KB", label, ms, kb))
	return ms
end
for i, p in ipairs(providers) do
	Time("provider "..i.." RefreshAllData, zone map 1424", function() p:RefreshAllData() end, 20)
end
local function Open(m)
	mapId = m
	-- StatsMap/other caches kept for 20 s: a fresh open after the cache expired
	clock = clock + 25
	for _, p in ipairs(providers) do p:RefreshAllData() end
end
Time("map open (all providers), zone 1424, cache cold", function() Open(1424) end, 10)
Time("map open (all providers), continent, cache cold", function() Open(1415) end, 10)
local function Warm(m) mapId = m for _, p in ipairs(providers) do p:RefreshAllData() end end
Time("map re-open, same second (cache warm)", function() Warm(1424) end, 20)
Time("one OnCanvasScaleChanged (all providers)", function() for _, p in ipairs(providers) do if p.OnCanvasScaleChanged then p:OnCanvasScaleChanged() end end end, 20)

-- A burst of 50 kills/deaths arriving with the map open (a catch-up, a big fight)
do
	local refreshes = 0
	for _, p in ipairs(providers) do
		local orig = p.RefreshAllData
		p.RefreshAllData = function(...) refreshes = refreshes + 1 return orig(...) end
	end
	mapId = 1424
	collectgarbage("collect")
	local t0 = os.clock()
	for i = 1, 50 do
		clock = clock + 0.02
		ns.Store:NewRecord("death", { killer = format("Player-9-BURST%d", i), killerName = "Burst"..i, killerFaction = "Alliance", victim = "Player-1-OURS5", victimName = "Our Five", victimFaction = "Horde", deathId = "burst-"..i, zone = "Zone1424", mapId = 1424, x = 10 + i, y = 20 })
	end
	RunTimers()
	print(format("  burst of 50 records, map open: %d provider refreshes, %.1f ms total", refreshes, (os.clock() - t0) * 1000))
end

]==]
local chunk = assert(load(prelude.."\n"..bench, "bench"))
chunk(NREC, NRECENT)
