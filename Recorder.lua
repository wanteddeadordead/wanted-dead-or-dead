-- Wanted: records what this client witnesses. The combat log is off limits to addons on this client
-- (registering COMBAT_LOG_EVENT_UNFILTERED is forbidden), so kills are seen two other ways: the server's
-- honor message credits the player's own kills by the victim's name, and enemy players in nameplate,
-- target or mouseover range are watched for dying, which any client nearby can witness. Sightings of
-- enemy players come from the same units. Nothing here talks to other clients.

local _, Wanted = ...
local Recorder = Wanted:NewModule("Recorder")
local Store = Wanted.Store
local private = {
	frame = CreateFrame("Frame"),
	tracked = {}, -- unit token -> guid of a player being watched (enemies, and our own side for their deaths)
	friendly = {}, -- guid -> { name, level, guild, t } for players of our own faction being watched (t: when last seen)
	skyborne = {}, -- the game's name for each side's Skyborne -> that side, learned from units seen
	lastSighting = {}, -- guid -> time
	recentDeaths = {}, -- guid -> time the death was recorded
	seenAlive = {}, -- guid -> when we last saw them alive (a corpse we come across is not a new death)
	confirming = {}, -- guid -> true while a death waits to be confirmed
	recentOwnKill = {}, -- guid -> time of the player's own kill (kill event and honor message both report it)
	ownKillTimes = {}, -- GetTime() of each own kill not yet matched to an HK credit
	assisted = {}, -- deathId -> true once an assist was recorded for it
	hkCount = nil, -- honorable kills as last read (private.HKCount)
	hkSource = nil, -- which count that was: "lifetime" or "session"
	playerGUID = nil,
	playerFaction = nil,
	places = nil, -- the named-area grid of one map, see private.ScanPlaces
}
-- The same enemy is not re-sighted more often than this
local SIGHTING_INTERVAL = 30
-- One death per victim within this window, however many units show it
local DEATH_DEDUPE_SECONDS = 15
-- Players out of view this long are let go (Prune, every PRUNE_SECONDS)
local FORGET_SECONDS = 10 * 60
local PRUNE_SECONDS = 60
-- A death on our own side counts only with an enemy player in view this recently: dying to a mob while
-- questing isn't world PvP
local PVP_CONTEXT_SECONDS = 20
-- Our own death record names the killer the death recap gave within this long (it's read 0.5 to 2 seconds after)
local OWN_KILLER_SECONDS = 15
-- Each side's races (the client's race file names), for players of ours we only know by GUID. Skyborne is on
-- both sides under different names ("High Order Skyborne" is the Alliance's), learned as units are seen
-- (private.skyborne), so it isn't listed here.
local OUR_RACES = {
	Horde = { Orc = true, Troll = true, Tauren = true, Scourge = true },
	Alliance = { Human = true, Dwarf = true, NightElf = true, Gnome = true },
}
-- A death is confirmed this long after it's seen: a hunter's Feign Death looks exactly like dying, but they're
-- up again by then. Nobody comes back from a real death that fast (a ghost that released drops out of view).
local DEATH_CONFIRM_SECONDS = 4
-- The server's honor message arrives within this long of the death
local HONOR_MATCH_WINDOW = 10
-- The HK count can rise before the death it's for is recorded; the assist waits this long
local ASSIST_DELAY = 2
-- The addon sees a death on its next nameplate check, a few seconds after the game credits the HK (Chris's client,
-- 2026-09-28: every HK came 1 to 4 s before the death was seen): an unmatched HK is tried again this often, this many times
local ASSIST_RETRY_SECONDS, ASSIST_RETRIES = 1, 8
-- More new HKs than this at once isn't a fight: a count read before the game had it (the lifetime count is in the
-- thousands), taken as the new starting point
local MAX_HKS_AT_ONCE = 10
local MAX_LOG_LINES = 20
local UNITS = { "target", "mouseover" }
-- The zone map is read in a grid this many cells across for its named areas
local PLACE_GRID = 50
local DIRECTIONS = { "east", "northeast", "north", "northwest", "west", "southwest", "south", "southeast" }



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Recorder:OnEnable()
	private.playerGUID = UnitGUID("player")
	private.playerFaction = UnitFactionGroup("player")
	private.hkCount, private.hkSource = private.HKCount()
	for _, event in ipairs({ "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "UNIT_HEALTH", "CHAT_MSG_COMBAT_HONOR_GAIN", "PARTY_KILL", "UNIT_DIED", "ZONE_CHANGED_NEW_AREA", "PLAYER_PVP_KILLS_CHANGED" }) do
		Wanted:Log("Recorder: registering %s", event)
		private.frame:RegisterEvent(event)
	end
	private.frame:SetScript("OnEvent", Wanted:Timed("Recorder events", private.OnEvent))
	C_Timer.NewTicker(PRUNE_SECONDS, private.Prune)
end

---Lets go of players not watched or seen for a while, and of sightings and deaths past their dedupe windows: a long
---session would otherwise keep everyone ever seen.
function private.Prune()
	local now = GetTime()
	local watched = {}
	for _, guid in pairs(private.tracked) do
		watched[guid] = true
	end
	for guid, t in pairs(private.lastSighting) do
		if now - t >= SIGHTING_INTERVAL then
			private.lastSighting[guid] = nil
		end
	end
	for guid, t in pairs(private.recentDeaths) do
		if now - t >= DEATH_DEDUPE_SECONDS then
			private.recentDeaths[guid] = nil
		end
	end
	for guid, t in pairs(private.seenAlive) do
		if not watched[guid] and now - t > FORGET_SECONDS then
			private.seenAlive[guid] = nil
		end
	end
	for guid, friend in pairs(private.friendly) do
		if not watched[guid] and not private.confirming[guid] and now - (friend.t or 0) > FORGET_SECONDS then
			private.friendly[guid] = nil
		end
	end
end

function Recorder:Status()
	local numKills, numDeaths = 0, 0
	for _ in Store:Iterator("kill") do
		numKills = numKills + 1
	end
	for _ in Store:Iterator("death") do
		numDeaths = numDeaths + 1
	end
	return format("Recorder: %d honor kills recorded, %d enemy deaths witnessed.", numKills, numDeaths)
end

-- Events about other units: none is read in an instance, where their identity is secret
local UNIT_EVENTS = { PLAYER_TARGET_CHANGED = true, UPDATE_MOUSEOVER_UNIT = true, NAME_PLATE_UNIT_ADDED = true,
	UNIT_HEALTH = true, PARTY_KILL = true, UNIT_DIED = true }

function private.OnEvent(_, event, arg1, arg2)
	if UNIT_EVENTS[event] and Wanted:InInstance() then
		return
	end
	if event == "PLAYER_TARGET_CHANGED" then
		private.Track("target")
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		private.Track("mouseover")
	elseif event == "NAME_PLATE_UNIT_ADDED" then
		private.Track(arg1)
	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		private.tracked[arg1] = nil
	elseif event == "UNIT_HEALTH" then
		private.CheckDeath(arg1)
	elseif event == "CHAT_MSG_COMBAT_HONOR_GAIN" then
		private.HandleHonorGain(arg1)
	elseif event == "PARTY_KILL" then
		private.HandlePartyKill(arg1, arg2)
	elseif event == "UNIT_DIED" then
		private.OnUnitDied(arg1)
	elseif event == "PLAYER_PVP_KILLS_CHANGED" then
		private.OnHKsChanged()
	elseif event == "ZONE_CHANGED_NEW_AREA" then
		-- Read the new zone's areas soon, in the background, rather than when help is called
		private.places = nil
		Wanted:QueueWork(private.GetPlaces)
	end
end



-- ============================================================================
-- Where we are
-- ============================================================================

-- The continent map type (Enum.UIMapType.Continent)
local MAP_TYPE_CONTINENT = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2

-- The player's position as last read, and when (GetTime())
private.position = {}

---The zone name and map coordinates (0-100) of the player, or nil coordinates where the map gives none. Read once
---a moment: every enemy scanned asks, and the game makes new tables for each answer.
---@return string zone
---@return number? x
---@return number? y
function Recorder:GetPosition()
	local position, now = private.position, GetTime()
	if position.t ~= now then
		position.zone, position.x, position.y, position.mapId = private.ReadPosition()
		position.t = now
	end
	return position.zone, position.x, position.y, position.mapId
end

function private.ReadPosition()
	local zone = GetZoneText() or "?"
	local mapId = C_Map.GetBestMapForUnit("player")
	if not mapId then
		return zone, nil, nil, nil
	end
	local pos = C_Map.GetPlayerMapPosition(mapId, "player")
	if not pos then
		return zone, nil, nil, mapId
	end
	-- Underground, where no zone map reaches (a dungeon's mine or cave), the game places the player on the
	-- continent's map, where a tenth of a percent is about 35 yards: keep a hundredth there
	local info = C_Map.GetMapInfo(mapId)
	local steps = info and info.mapType == MAP_TYPE_CONTINENT and 10000 or 1000
	return zone, floor(pos.x * steps + 0.5) / (steps / 100), floor(pos.y * steps + 0.5) / (steps / 100), mapId
end

---Where the player is, for other players to find them: "in Ratchet, The Barrens 62,38" where the game names
---the area, otherwise the nearest named area and which way it is ("west of Razor Hill, Durotar 47,40"), or
---just "Durotar 47,40".
---@return string
function Recorder:DescribePlace()
	local zone, x, y, mapId = Recorder:GetPosition()
	local coords = x and format(" %.0f,%.0f", x, y) or ""
	local area = GetSubZoneText()
	if area and area ~= "" and area ~= zone then
		return "in "..area..", "..zone..coords
	end
	local near, direction = private.NearestPlace(zone, x, y)
	if near then
		return (direction and direction.." of " or "near ")..near..", "..zone..coords
	end
	return "in "..zone..coords
end

---The named areas of the player's map, read once per zone from the world map's hover labels (only the areas
---this character has uncovered have them): a grid of area names by cell, and each area's centre.
---@return table? { mapId, cells = { [index] = name }, centres = { [name] = { x, y } }, width, height }
function private.GetPlaces()
	local mapId = C_Map.GetBestMapForUnit("player")
	if not mapId or not C_MapExplorationInfo or not C_Map.GetAreaInfo then
		return nil
	end
	if private.places and private.places.mapId == mapId then
		return private.places
	end
	local zone = GetZoneText()
	local cells, sums = {}, {}
	for row = 0, PLACE_GRID - 1 do
		for col = 0, PLACE_GRID - 1 do
			local x, y = (col + 0.5) / PLACE_GRID, (row + 0.5) / PLACE_GRID
			for _, areaId in ipairs(C_MapExplorationInfo.GetExploredAreaIDsAtPosition(mapId, CreateVector2D(x, y)) or {}) do
				local name = C_Map.GetAreaInfo(areaId)
				if name and name ~= "" and name ~= zone then
					cells[row * PLACE_GRID + col] = name
					local sum = sums[name] or { 0, 0, 0 }
					sum[1], sum[2], sum[3] = sum[1] + x, sum[2] + y, sum[3] + 1
					sums[name] = sum
					break
				end
			end
		end
	end
	local centres = {}
	for name, sum in pairs(sums) do
		centres[name] = { sum[1] / sum[3], sum[2] / sum[3] }
	end
	-- Distances in yards where the map says its size, so a wide map doesn't bend directions
	local width, height
	if C_Map.GetMapWorldSize then
		width, height = C_Map.GetMapWorldSize(mapId)
	end
	if not width or width <= 0 or not height or height <= 0 then
		width, height = 1, 1
	end
	private.places = { mapId = mapId, cells = cells, centres = centres, width = width, height = height }
	return private.places
end

---The named area nearest the player and the direction from its centre to them, or no direction when the
---player stands in it (the game doesn't name every spot inside an area).
---@param zone string
---@param x number? 0-100
---@param y number? 0-100
---@return string? name
---@return string? direction
function private.NearestPlace(zone, x, y)
	local places = x and private.GetPlaces()
	if not places then
		return nil
	end
	x, y = x / 100, y / 100
	local col, row = floor(x * PLACE_GRID), floor(y * PLACE_GRID)
	local here = places.cells[row * PLACE_GRID + col]
	if here then
		return here, nil
	end
	local nearest, bestDistance
	for index, name in pairs(places.cells) do
		local dx = ((index % PLACE_GRID) + 0.5) / PLACE_GRID - x
		local dy = (floor(index / PLACE_GRID) + 0.5) / PLACE_GRID - y
		local distance = (dx * places.width) ^ 2 + (dy * places.height) ^ 2
		if not bestDistance or distance < bestDistance then
			nearest, bestDistance = name, distance
		end
	end
	if not nearest then
		return nil
	end
	-- Map y grows southward; turn it round so north is up
	local centre = places.centres[nearest]
	local angle = math.atan2((centre[2] - y) * places.height, (x - centre[1]) * places.width)
	local sector = floor(angle / (math.pi / 4) + 0.5) % 8
	return nearest, DIRECTIONS[sector + 1]
end

---A unit's guild name, or nil (no guild, or not readable).
---@param unit string
---@return string?
function Recorder:GetUnitGuild(unit)
	if not GetGuildInfo then
		return nil
	end
	local ok, guild = pcall(GetGuildInfo, unit)
	if not ok or not guild or (issecretvalue and issecretvalue(guild)) or guild == "" then
		return nil
	end
	return guild
end

---The guild last seen for a player GUID, or nil: the one the game read on a unit (Enemies), never a peer's word.
---@param guid string?
---@return string?
function Recorder:GetKnownGuild(guid)
	local player = guid and Store:GetPlayer(guid)
	return player and player.guild or nil
end

---A player's guild as the game gives it right now, from any unit token showing them, or nil. At a kill or a death
---the unit is usually still there: that reading beats the saved one (a guild bounty's witnesses are matched on it).
---@param guid string?
---@return string?
function private.LiveGuild(guid)
	if not guid then
		return nil
	end
	for unit, trackedGuid in pairs(private.tracked) do
		if trackedGuid == guid and UnitExists(unit) and UnitGUID(unit) == guid then
			local guild = Recorder:GetUnitGuild(unit)
			if guild then
				return guild
			end
		end
	end
	return nil
end

---A value the client let us read, or nil for a hidden (secret) one.
function private.Readable(value)
	if value == nil or (issecretvalue and issecretvalue(value)) then
		return nil
	end
	return value
end

---Adds what the client knows of a player to a record's data, under "victim" or "killer": class and race
---(the client's file names, e.g. ROGUE and Scourge), the level last seen and faction. Unknown ones are left out.
---@param data table
---@param prefix string
---@param guid string?
---@return table data
---The game's number for a player's sex as a word: 2 is male, 3 female, anything else unknown.
---@param n any
---@return string?
function private.SexName(n)
	n = private.Readable(n)
	if n == 2 then
		return "male"
	elseif n == 3 then
		return "female"
	end
	return nil
end

function private.AddTraits(data, prefix, guid)
	local player = guid and Store:GetPlayer(guid)
	local class, race, sex
	if guid and strfind(guid, "^Player%-") then
		local _, classFile, _, raceFile, sexNumber = GetPlayerInfoByGUID(guid)
		class, race, sex = private.Readable(classFile), private.Readable(raceFile), private.SexName(sexNumber)
	end
	local friend = guid and private.friendly[guid]
	local level = player and player.level or friend and friend.level
	data[prefix.."Class"] = class or (player and player.class) or nil
	data[prefix.."Race"] = race
	data[prefix.."Sex"] = sex or (player and player.sex) or nil
	data[prefix.."Level"] = type(level) == "number" and level > 0 and level or nil
	data[prefix.."Faction"] = player and player.faction or nil
	if prefix == "victim" and not data.victimFaction and private.playerFaction then
		-- A victim we watched as one of our own side is ours; any other is the enemy's
		data.victimFaction = friend and private.playerFaction or (private.playerFaction == "Horde" and "Alliance" or "Horde")
	end
	return data
end

---Adds our own class, race, level, faction and group size to a record's data as the killer.
---@param data table
---@return table data
function private.AddOwnTraits(data)
	local level = private.Readable(UnitLevel("player"))
	data.killerClass = private.Readable((select(2, UnitClass("player"))))
	data.killerRace = private.Readable((select(2, UnitRace("player"))))
	data.killerSex = private.SexName(UnitSex("player"))
	data.killerLevel = type(level) == "number" and level > 0 and level or nil
	data.killerFaction = private.playerFaction
	-- How many were in our group (1 alone), for solo and group kills. A raid counts everyone in it.
	local group = GetNumGroupMembers and private.Readable(GetNumGroupMembers())
	data.killerGroup = max(type(group) == "number" and group or 0, 1)
	return data
end

function private.InOpenWorld()
	return not IsInInstance()
end



-- ============================================================================
-- Watching enemy players
-- ============================================================================

---Starts watching a unit if it is an enemy player, and records a sighting.
function private.Track(unit)
	if Wanted:InInstance() then
		-- An instance's players aren't world PvP, and their identity is secret: not watched or sighted
		return
	end
	if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then
		private.tracked[unit] = nil
		return
	end
	local guid = UnitGUID(unit)
	if not guid or (issecretvalue and issecretvalue(guid)) then
		return
	end
	Store:NoteName(guid, GetUnitName(unit, true))
	Store:NoteGuild(guid, Recorder:GetUnitGuild(unit))
	local faction = UnitFactionGroup(unit)
	local raceName, raceFile = UnitRace(unit)
	if raceFile == "Skyborne" and type(raceName) == "string" and type(faction) == "string" then
		private.skyborne[raceName] = faction
	end
	if faction == private.playerFaction then
		-- Our own side: watched for deaths only, never sighted or listed as an enemy
		private.tracked[unit] = guid
		local level = private.Readable(UnitLevel(unit))
		private.friendly[guid] = { name = GetUnitName(unit, true), level = type(level) == "number" and level > 0 and level or nil,
			guild = Recorder:GetUnitGuild(unit), t = GetTime() }
		private.NoteAlive(unit, guid)
		return
	end
	private.tracked[unit] = guid
	private.NoteAlive(unit, guid)
	local now = GetTime()
	if private.lastSighting[guid] and now - private.lastSighting[guid] < SIGHTING_INTERVAL then
		return
	end
	private.lastSighting[guid] = now
	local zone, x, y, mapId = Recorder:GetPosition()
	local _, class = UnitClass(unit)
	-- A skull (-1: far above us) isn't a level: the last one known stays
	local level = private.Readable(UnitLevel(unit))
	Store:UpdatePlayer(guid, {
		name = GetUnitName(unit, true),
		class = class,
		level = type(level) == "number" and level > 0 and level or nil,
		faction = faction,
		guild = Recorder:GetUnitGuild(unit) or false, -- false = seen without a guild
		race = UnitRace(unit),
		sex = private.SexName(UnitSex(unit)),
		zone = zone,
		mapId = mapId,
		x = x,
		y = y,
	})
	Store:AddSighting(guid, zone, x, y, mapId)
end

---An enemy player we are watching may have died.
function private.CheckDeath(unit)
	if (unit == "player" or strfind(unit, "^party%d") or strfind(unit, "^raid%d")) and private.tracked[unit] ~= UnitGUID(unit) then
		-- Ourselves and our group, never shown on nameplates: watched from their first health change
		private.Track(unit)
	end
	local guid = private.tracked[unit]
	if not guid or UnitGUID(unit) ~= guid then
		return
	end
	-- Health is always secret on this client; whether the unit is dead is not
	local dead = UnitIsDeadOrGhost(unit)
	if issecretvalue and issecretvalue(dead) then
		return
	end
	if not dead then
		private.seenAlive[guid] = GetTime()
		return
	end
	-- Only a death we saw happen: someone already dead when we found them (a corpse at login, say) died
	-- earlier, maybe hours ago
	if not private.seenAlive[guid] then
		return
	end
	private.seenAlive[guid] = nil
	private.ConfirmDeath(guid, GetUnitName(unit, true))
end

---Whether a player is in view and alive right now.
function private.IsAliveNow(guid)
	for unit, trackedGuid in pairs(private.tracked) do
		if trackedGuid == guid and UnitGUID(unit) == guid then
			local dead = UnitIsDeadOrGhost(unit)
			if dead == false then
				return true
			end
		end
	end
	return false
end

---Records a death once it has lasted a few seconds, so Feign Death doesn't count.
function private.ConfirmDeath(guid, name)
	if private.confirming[guid] then
		return
	end
	private.confirming[guid] = true
	C_Timer.After(DEATH_CONFIRM_SECONDS, function()
		private.confirming[guid] = nil
		if private.IsAliveNow(guid) then
			Wanted:Log("Recorder: %s got up again (Feign Death), not a death", tostring(name))
			private.seenAlive[guid] = GetTime()
			return
		end
		private.RecordDeath(guid, name)
	end)
end

---Remembers that a watched enemy was alive when seen.
function private.NoteAlive(unit, guid)
	local dead = UnitIsDeadOrGhost(unit)
	if dead == false then
		private.seenAlive[guid] = GetTime()
	end
end

---The client's death event for any unit near us: an enemy player dying is a witnessed death, and so is one of
---our own side (RecordDeath keeps those to world PvP).
function private.OnUnitDied(guid)
	if issecretvalue and issecretvalue(guid) then
		Wanted:Log("Recorder: UNIT_DIED with a hidden GUID")
		return
	end
	if not guid or type(guid) ~= "string" or not strfind(guid, "^Player%-") then
		return
	end
	local player = Store:GetPlayer(guid)
	if player and player.faction and player.faction ~= private.playerFaction then
		private.ConfirmDeath(guid, player.name)
		return
	end
	if private.friendly[guid] then
		private.ConfirmDeath(guid, private.friendly[guid].name)
		return
	end
	-- Unknown so far: ask the client
	local _, _, raceName, race, _, name = GetPlayerInfoByGUID(guid)
	if not name or (issecretvalue and issecretvalue(name)) then
		Wanted:Log("Recorder: UNIT_DIED for a player the client won't name")
		return
	end
	for _, trackedGuid in pairs(private.tracked) do
		if trackedGuid == guid then
			-- A watched enemy not saved yet
			private.ConfirmDeath(guid, name)
			return
		end
	end
	local ours = OUR_RACES[private.playerFaction]
	local theirs = OUR_RACES[private.playerFaction == "Horde" and "Alliance" or "Horde"]
	if (theirs and race and theirs[race]) or (race == "Skyborne" and private.skyborne[raceName] and private.skyborne[raceName] ~= private.playerFaction) then
		-- An enemy we never had a unit for: their race says which side
		private.ConfirmDeath(guid, name)
		return
	end
	if guid == private.playerGUID or (ours and race and ours[race]) or (race == "Skyborne" and private.IsOurSkyborne(raceName)) then
		-- One of our side we never had a unit for (friendly nameplates are usually off)
		Wanted:Log("Recorder: UNIT_DIED for %s (%s), one of ours", name, tostring(raceName))
		private.friendly[guid] = { name = name, t = GetTime() }
		private.ConfirmDeath(guid, name)
		return
	end
	Wanted:Log("Recorder: UNIT_DIED for %s (%s, %s), side unknown; not recorded", name, tostring(raceName), tostring(race))
end

---Whether a Skyborne player of this name is on our side: their name is the one seen on our side, or it isn't
---the one seen on the enemy's. Unknown until a Skyborne of either side has been seen.
---@param raceName string?
---@return boolean
function private.IsOurSkyborne(raceName)
	if type(raceName) ~= "string" then
		return false
	end
	local side = private.skyborne[raceName]
	if side then
		return side == private.playerFaction
	end
	for _, seenSide in pairs(private.skyborne) do
		if seenSide ~= private.playerFaction then
			return true
		end
	end
	return false
end

function private.RecordDeath(guid, name)
	if not private.InOpenWorld() then
		return
	end
	local friend = private.friendly[guid]
	-- Our own death: the death recap may name the player who killed us
	local killer = guid == private.playerGUID and Wanted.Enemies and Wanted.Enemies:GetLastKiller(OWN_KILLER_SECONDS)
	if friend and not killer then
		local lastEnemy = Wanted.Enemies and Wanted.Enemies:LastEnemySeen()
		if not lastEnemy or GetTime() - lastEnemy > PVP_CONTEXT_SECONDS then
			Wanted:Log("Recorder: %s died with no enemy player around; not world PvP", tostring(name))
			return
		end
	end
	local now = GetTime()
	if private.recentDeaths[guid] and now - private.recentDeaths[guid] < DEATH_DEDUPE_SECONDS then
		return
	end
	private.recentDeaths[guid] = now
	local zone, x, y, mapId = Recorder:GetPosition()
	local t = GetServerTime()
	-- Content-addressed id shared by every witness of the same death
	local deathId = Store:Hash(strjoin("|", guid, zone, floor(t / 10)))
	Wanted:Log("Recorder: death of %s in %s", tostring(name), zone)
	if not friend then
		-- The saved players are enemies (the Nearby window, the map and hotspots read them)
		Store:UpdatePlayer(guid, { name = name })
	end
	local data = private.AddTraits({
		deathId = deathId,
		victim = guid,
		victimName = name,
		victimGuild = friend and friend.guild or private.LiveGuild(guid) or Recorder:GetKnownGuild(guid),
		zone = zone,
		mapId = mapId, -- names the zone the same in every language (the site reads it)
		x = x,
		y = y,
	}, "victim", guid)
	if killer then
		-- Named by the one who died: the network counts it as a witnessed kill for them
		local player = Store:GetPlayer(killer) or {}
		local _, _, _, _, _, killerName = GetPlayerInfoByGUID(killer)
		data.killer = killer
		data.killerName = private.Readable(killerName) or player.name
		data.killerGuild = player.guild or nil
		private.AddTraits(data, "killer", killer)
		data.killerFaction = data.killerFaction or (private.playerFaction == "Horde" and "Alliance" or "Horde")
		Wanted:Log("Recorder: our death, killed by %s", tostring(data.killerName))
	end
	Store:NewRecord("death", data)
	return deathId
end



-- ============================================================================
-- Own kills, credited by the server
-- ============================================================================

---The client's own kill event: who got the killing blow (the player or a party member) and on whom. The
---player's kills become kill records; a party member's kill becomes a witnessed death naming the killer.
function private.HandlePartyKill(attackerGUID, targetGUID)
	if (issecretvalue and (issecretvalue(attackerGUID) or issecretvalue(targetGUID))) or not private.InOpenWorld() then
		return
	end
	if type(targetGUID) ~= "string" or not strfind(targetGUID, "^Player%-") then
		return
	end
	local victim = Store:GetPlayer(targetGUID)
	if victim and victim.faction and victim.faction == private.playerFaction then
		return
	end
	local _, class, _, race, _, name = GetPlayerInfoByGUID(targetGUID)
	if issecretvalue and issecretvalue(name) then
		name = nil
	end
	name = name or (victim and victim.name)
	if not name then
		return
	end
	Store:UpdatePlayer(targetGUID, { name = victim and victim.name or name, class = class, race = race })
	local zone, x, y, mapId = Recorder:GetPosition()
	local now = GetServerTime()
	local deathId = Store:Hash(strjoin("|", targetGUID, zone, floor(now / 10)))
	if attackerGUID == private.playerGUID or attackerGUID == UnitGUID("pet") then
		Wanted:Log("Recorder: party kill by you of %s in %s", name, zone)
		private.recentOwnKill[targetGUID] = GetTime()
		tinsert(private.ownKillTimes, GetTime())
		Store:NewRecord("kill", private.AddOwnTraits(private.AddTraits({
			killer = private.playerGUID,
			killerName = Store:GetOrigin(),
			killerGuild = Recorder:GetUnitGuild("player"),
			victim = targetGUID,
			victimName = victim and victim.name or name,
			victimGuild = private.LiveGuild(targetGUID) or Recorder:GetKnownGuild(targetGUID),
			deathId = deathId,
			zone = zone,
			mapId = mapId, -- names the zone the same in every language (the site reads it)
			x = x,
			y = y,
		}, "victim", targetGUID)))
		if Wanted.Enemies then
			Wanted.Enemies:NoteWin(targetGUID)
		end
	else
		local _, _, _, _, _, killerName = GetPlayerInfoByGUID(attackerGUID)
		if issecretvalue and issecretvalue(killerName) then
			killerName = nil
		end
		Wanted:Log("Recorder: party kill by %s of %s in %s", tostring(killerName), name, zone)
		private.recentDeaths[targetGUID] = GetTime()
		local data = private.AddTraits(private.AddTraits({
			deathId = deathId,
			victim = targetGUID,
			victimName = victim and victim.name or name,
			victimGuild = private.LiveGuild(targetGUID) or Recorder:GetKnownGuild(targetGUID),
			killer = attackerGUID,
			killerName = killerName,
			zone = zone,
			mapId = mapId, -- names the zone the same in every language (the site reads it)
			x = x,
			y = y,
		}, "victim", targetGUID), "killer", attackerGUID)
		-- A party member is on our side
		data.killerFaction = data.killerFaction or private.playerFaction
		Store:NewRecord("death", data)
	end
end

function private.HandleHonorGain(text)
	if issecretvalue and issecretvalue(text) then
		return
	end
	-- WoW Forever's line for HK credit names no victim; PLAYER_PVP_KILLS_CHANGED handles those (assists)
	if strmatch(text, "^You have been awarded") then
		return
	end
	-- "<name> dies, honorable kill Rank: ..." (the victim's name comes first)
	local victimName = strmatch(text, "^(.-) dies")
	if not victimName then
		Wanted:Log("Recorder: honor message not understood: %s", text)
		return
	end
	if not private.InOpenWorld() then
		return
	end
	-- Find the victim's GUID: a death we just witnessed, then a watched unit, then any player seen
	local guid = nil
	local now = GetServerTime()
	for record in Store:Iterator("death") do
		if now - record.t <= HONOR_MATCH_WINDOW and record.data.victimName == victimName and record.data.victimFaction ~= private.playerFaction then
			guid = record.data.victim
			break
		end
	end
	if not guid then
		for unit, unitGuid in pairs(private.tracked) do
			if UnitExists(unit) and GetUnitName(unit, true) == victimName then
				guid = unitGuid
				break
			end
		end
	end
	if not guid then
		guid = Store:FindPlayerByName(victimName)
	end
	if guid and private.recentOwnKill[guid] and GetTime() - private.recentOwnKill[guid] < HONOR_MATCH_WINDOW then
		-- Already recorded from the kill event itself
		return
	end
	local zone, x, y, mapId = Recorder:GetPosition()
	Wanted:Log("Recorder: honor kill of %s (%s) in %s", victimName, tostring(guid), zone)
	tinsert(private.ownKillTimes, GetTime())
	if guid then
		private.recentOwnKill[guid] = GetTime()
		if Wanted.Enemies then
			Wanted.Enemies:NoteWin(guid)
		end
	end
	if guid then
		Store:UpdatePlayer(guid, { name = victimName })
	end
	Store:NewRecord("kill", private.AddOwnTraits(private.AddTraits({
		killer = private.playerGUID,
		killerName = Store:GetOrigin(),
		killerGuild = Recorder:GetUnitGuild("player"),
		victim = guid or ("name:"..victimName),
		victimName = victimName,
		victimGuild = private.LiveGuild(guid) or Recorder:GetKnownGuild(guid),
		deathId = Store:Hash(strjoin("|", guid or victimName, zone, floor(now / 10))),
		zone = zone,
		mapId = mapId, -- names the zone the same in every language (the site reads it)
		x = x,
		y = y,
		honor = true,
	}, "victim", guid)))
end



-- ============================================================================
-- Assists: HK credit without the killing blow
-- ============================================================================

---Honorable kills as the client counts them, and which count: the lifetime one where the client gives it (it never
---resets), else this session's (it starts again at each daily reset). nil where the client says neither.
---@return number?
---@return string? source "lifetime" or "session"
function private.HKCount()
	if GetPVPLifetimeStats then
		local ok, hks = pcall(GetPVPLifetimeStats)
		hks = ok and private.Readable(hks) or nil
		if type(hks) == "number" then
			return hks, "lifetime"
		end
	end
	if not GetPVPSessionStats then
		return nil
	end
	local hks = private.Readable(GetPVPSessionStats())
	return type(hks) == "number" and hks or nil, "session"
end

---The HK count changed: each new HK that isn't our own killing blow is an assist on a death we just saw.
function private.OnHKsChanged()
	local now, source = private.HKCount()
	if not now or not private.hkCount or source ~= private.hkSource then
		private.hkCount, private.hkSource = now, source
		return
	end
	local added = now - private.hkCount
	if added < 0 and source == "session" then
		-- The daily reset: every HK since it is new
		added = now
	end
	private.hkCount = now
	if added > MAX_HKS_AT_ONCE then
		Wanted:Log("!! Recorder: the %s HK count jumped by %d; taken as the new start", source, added)
		return
	end
	local at = GetServerTime()
	for _ = 1, added do
		C_Timer.After(ASSIST_DELAY, function() private.CreditHK(at, 0) end)
	end
end

---Matches one HK credit: to our own recent kill if there is one, otherwise to the newest enemy death we saw
---around it that has no assist yet. WoW Forever doesn't say whose death it was. The death is often seen a few
---seconds after the credit, so a miss is tried again for a while.
---@param at number server time the credit arrived
---@param tries number retries so far
function private.CreditHK(at, tries)
	at, tries = at or GetServerTime(), tries or 0
	local now = GetTime()
	while private.ownKillTimes[1] and now - private.ownKillTimes[1] > HONOR_MATCH_WINDOW + ASSIST_DELAY + ASSIST_RETRIES * ASSIST_RETRY_SECONDS do
		tremove(private.ownKillTimes, 1)
	end
	if private.ownKillTimes[1] then
		tremove(private.ownKillTimes, 1)
		return
	end
	local me = Store:GetOrigin()
	local death
	for record in Store:Iterator("death") do
		local data = record.data
		-- A death from shortly before the credit, or seen since
		if record.origin == me and record.t >= at - HONOR_MATCH_WINDOW and data.deathId
			and data.victimFaction ~= private.playerFaction and not private.assisted[data.deathId] and (not death or record.t > death.t) then
			death = record
		end
	end
	if not death then
		if tries < ASSIST_RETRIES then
			C_Timer.After(ASSIST_RETRY_SECONDS, function() private.CreditHK(at, tries + 1) end)
		else
			Wanted:Log("Recorder: HK credit with no enemy death seen to match")
		end
		return
	end
	local data = death.data
	private.assisted[data.deathId] = true
	Wanted:Log("Recorder: assist on %s in %s", tostring(data.victimName), tostring(data.zone))
	Store:NewRecord("assist", private.AddOwnTraits({
		killer = private.playerGUID,
		killerName = me,
		killerGuild = Recorder:GetUnitGuild("player"),
		victim = data.victim,
		victimName = data.victimName,
		victimGuild = data.victimGuild,
		victimClass = data.victimClass,
		victimRace = data.victimRace,
		victimLevel = data.victimLevel,
		victimFaction = data.victimFaction,
		deathId = data.deathId,
		zone = data.zone,
		x = data.x,
		y = data.y,
	}))
end



-- ============================================================================
-- Commands
-- ============================================================================

local function Ago(t)
	local seconds = max(GetServerTime() - t, 0)
	if seconds < 60 then
		return seconds.."s ago"
	elseif seconds < 3600 then
		return floor(seconds / 60).."m ago"
	end
	return floor(seconds / 3600).."h ago"
end

Wanted:RegisterCommand("log", "Lists your kills and the enemy deaths witnessed.", function()
	local events = {}
	for record in Store:Iterator("kill") do
		tinsert(events, record)
	end
	for record in Store:Iterator("death") do
		tinsert(events, record)
	end
	sort(events, function(a, b) return a.t > b.t end)
	if #events == 0 then
		Wanted:Print("No kills or enemy deaths witnessed yet.")
		return
	end
	for i = 1, min(#events, MAX_LOG_LINES) do
		local record = events[i]
		local data = record.data
		local where = (data.zone or "?")..(data.x and format(" (%.1f, %.1f)", data.x, data.y) or "")
		if record.kind == "kill" then
			local killer = record.origin == Store:GetOrigin() and "you" or record.origin
			Wanted:Print("%s: %s killed %s in %s [honor]", Ago(record.t), killer, Store:CleanName(data.victimName) or data.victim, where)
		else
			Wanted:Print("%s: %s died in %s (witnessed by %s)", Ago(record.t), Store:CleanName(data.victimName) or data.victim, where, record.origin)
		end
	end
end)

Wanted:RegisterCommand("seen", "Lists recently sighted enemy players, or one by name.", function(args)
	local wanted = strtrim(args or "")
	local shown = 0
	for sighting in Store:SightingIterator() do
		local player = Store:GetPlayer(sighting.guid)
		local name = player and player.name or sighting.guid
		if wanted == "" or strfind(strlower(name), strlower(wanted), 1, true) then
			Wanted:Print("%s: %s (%s %s) in %s%s", Ago(sighting.t), name, player and player.level and (player.level > 0 and player.level or "??") or "?", player and player.class or "?", sighting.zone, sighting.x and format(" (%.1f, %.1f)", sighting.x, sighting.y) or "")
			shown = shown + 1
			if shown >= MAX_LOG_LINES then
				break
			end
		end
	end
	if shown == 0 then
		Wanted:Print("No sightings%s.", wanted ~= "" and (" of "..wanted) or "")
	end
end)
