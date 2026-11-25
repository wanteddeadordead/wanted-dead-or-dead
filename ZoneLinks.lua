-- Wanted: which open-world zones touch which, and which maps are capital cities, for the RISING FAST warning's two
-- filters (Hotspots). Map ids are the client's uiMapIDs. Written from map knowledge, not read from the client, which
-- has no adjacency data: a zone missing here counts as not near anything.

local _, Wanted = ...
local ZoneLinks = {}
Wanted.ZoneLinks = ZoneLinks

-- Capital cities by map id, and by name for a record that carries no map id
ZoneLinks.CITY_MAPS = {
	[1454] = true, -- Orgrimmar
	[1456] = true, -- Thunder Bluff
	[1458] = true, -- Undercity
	[1453] = true, -- Stormwind City
	[1455] = true, -- Ironforge
	[1457] = true, -- Darnassus
}
ZoneLinks.CITY_NAMES = {
	["Orgrimmar"] = true, ["Thunder Bluff"] = true, ["Undercity"] = true,
	["Stormwind City"] = true, ["Ironforge"] = true, ["Darnassus"] = true,
}

-- One line per border, each listed once; Near() reads it both ways.
local BORDERS = {
	-- Eastern Kingdoms
	{ 1420, 1421 }, { 1420, 1422 }, { 1420, 1458 }, -- Tirisfal Glades: Silverpine, Western Plaguelands, Undercity
	{ 1421, 1424 }, -- Silverpine Forest: Hillsbrad Foothills
	{ 1422, 1423 }, { 1422, 1425 }, { 1422, 1416 }, -- Western Plaguelands: Eastern Plaguelands, The Hinterlands, Alterac Mountains
	{ 1424, 1416 }, { 1424, 1417 }, { 1424, 1425 }, -- Hillsbrad Foothills: Alterac, Arathi, The Hinterlands
	{ 1417, 1437 }, -- Arathi Highlands: Wetlands
	{ 1437, 1432 }, -- Wetlands: Loch Modan
	{ 1426, 1432 }, { 1426, 1455 }, -- Dun Morogh: Loch Modan, Ironforge
	{ 1432, 1418 }, -- Loch Modan: Badlands
	{ 1418, 1427 }, -- Badlands: Searing Gorge
	{ 1427, 1428 }, -- Searing Gorge: Burning Steppes
	{ 1428, 1433 }, -- Burning Steppes: Redridge Mountains
	{ 1433, 1429 }, { 1433, 1431 }, -- Redridge Mountains: Elwynn Forest, Duskwood
	{ 1429, 1436 }, { 1429, 1431 }, { 1429, 1453 }, -- Elwynn Forest: Westfall, Duskwood, Stormwind City
	{ 1436, 1431 }, -- Westfall: Duskwood
	{ 1431, 1434 }, { 1431, 1430 }, -- Duskwood: Stranglethorn Vale, Deadwind Pass
	{ 1430, 1435 }, -- Deadwind Pass: Swamp of Sorrows
	{ 1435, 1419 }, -- Swamp of Sorrows: Blasted Lands
	-- Kalimdor
	{ 1411, 1454 }, { 1411, 1413 }, -- Durotar: Orgrimmar, The Barrens
	{ 1412, 1456 }, { 1412, 1413 }, -- Mulgore: Thunder Bluff, The Barrens
	{ 1413, 1440 }, { 1413, 1442 }, { 1413, 1441 }, { 1413, 1445 }, -- The Barrens: Ashenvale, Stonetalon, Thousand Needles, Dustwallow Marsh
	{ 1440, 1442 }, { 1440, 1439 }, { 1440, 1448 }, { 1440, 1447 }, -- Ashenvale: Stonetalon, Darkshore, Felwood, Azshara
	{ 1442, 1443 }, -- Stonetalon Mountains: Desolace
	{ 1443, 1444 }, -- Desolace: Feralas
	{ 1444, 1441 }, -- Feralas: Thousand Needles
	{ 1441, 1446 }, -- Thousand Needles: Tanaris
	{ 1446, 1449 }, -- Tanaris: Un'Goro Crater
	{ 1449, 1451 }, -- Un'Goro Crater: Silithus
	{ 1438, 1457 }, { 1438, 1439 }, -- Teldrassil: Darnassus, Darkshore (by boat)
	{ 1448, 1452 }, { 1448, 1450 }, -- Felwood: Winterspring, Moonglade
	{ 1452, 1450 }, -- Winterspring: Moonglade
}

local links = {}
for _, border in ipairs(BORDERS) do
	local a, b = border[1], border[2]
	links[a] = links[a] or {}
	links[b] = links[b] or {}
	links[a][b], links[b][a] = true, true
end

---Whether a map is a capital city, by map id or by name.
---@param mapId number?
---@param name string?
---@return boolean
function ZoneLinks:IsCity(mapId, name)
	return (mapId and ZoneLinks.CITY_MAPS[mapId]) or (name and ZoneLinks.CITY_NAMES[name]) or false
end

---Whether a zone is the player's own or touches it. A zone not in the table is not near.
---@param mapId number? the zone being asked about
---@param ownMapId number? where the player is
---@return boolean
function ZoneLinks:Near(mapId, ownMapId)
	if not mapId or not ownMapId then
		return false
	end
	return mapId == ownMapId or (links[ownMapId] and links[ownMapId][mapId]) or false
end
