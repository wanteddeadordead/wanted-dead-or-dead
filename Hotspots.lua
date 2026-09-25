-- Wanted: PvP hotspots. Groups the enemy players seen in the last hour, by you and by other Wanted users,
-- by the zone they were last seen in. Each zone gets its enemy count, their levels, the biggest guild
-- among them, recent PvP deaths there, and whether it's getting busier. It only knows about enemies a
-- Wanted user has seen, so the counts are a floor, not a census.

local _, Wanted = ...
local Hotspots = Wanted:NewModule("Hotspots")
local Store = Wanted.Store
local private = {}
local RECENT = 15 * 60 -- "now" means seen in the last 15 minutes
local HOUR = 3600
local GUILD_MIN = 3 -- a guild is named once this many of its players are in the zone
local TREND_MIN = 2 -- the count has to move by at least this much to count as rising or falling



-- ============================================================================
-- Grouping
-- ============================================================================

---The zone's name in this client's language, from the map id.
---@param mapId number?
---@return string?
function private.MapName(mapId)
	local info = mapId and C_Map.GetMapInfo and C_Map.GetMapInfo(mapId)
	return info and info.name or nil
end

---Finds or makes the group for a zone. Map ids group the same zone across game languages; a zone
---known only by name (kill and death records carry no map id) joins the group showing that name.
function private.GetGroup(groups, byName, mapId, zone)
	local name = private.MapName(mapId) or zone
	local named = name and byName[name]
	if mapId and named and not named.mapId then
		-- The zone was known by name only until now: give that group the map id
		groups[named.key] = nil
		named.key, named.mapId = mapId, mapId
		groups[mapId] = named
	end
	local key = mapId or (named and named.key) or ("zone:"..tostring(name))
	local group = groups[key]
	if not group then
		group = {
			key = key, mapId = mapId, zone = name or "Unknown", recent = 0, hour = 0, earlier = 0, deaths = 0,
			guilds = {}, enemies = {},
		}
		groups[key] = group
		if name then
			byName[name] = byName[name] or group
		end
	end
	return group
end

---A value the addon may read (not one of the client's secret values).
function private.Readable(value)
	if issecretvalue and issecretvalue(value) then
		return nil
	end
	return value
end

---Adds the enemies seen in the last hour to their zones.
function private.AddPlayers(groups, byName, now)
	local myFaction = UnitFactionGroup("player")
	for guid, player in pairs(Wanted.db.players) do
		local lastSeen = player.lastSeen
		if lastSeen and now - lastSeen <= HOUR and player.faction and player.faction ~= myFaction
				and not Wanted.db.ignore[guid] and strfind(guid, "^Player%-") and (player.mapId or player.zone) then
			local group = private.GetGroup(groups, byName, player.mapId, player.zone)
			group.hour = group.hour + 1
			if now - lastSeen <= RECENT then
				group.recent = group.recent + 1
			end
			local level = private.Readable(player.level)
			if type(level) == "number" then
				if level < 0 then
					group.skull = true
				elseif level > 0 then
					group.minLevel = min(group.minLevel or level, level)
					group.maxLevel = max(group.maxLevel or level, level)
				end
			end
			local guild = private.Readable(player.guild)
			if type(guild) == "string" then
				group.guilds[guild] = (group.guilds[guild] or 0) + 1
			end
			group.lastSeen = max(group.lastSeen or 0, lastSeen)
			tinsert(group.enemies, { guid = guid, name = player.name, class = player.class, level = level, lastSeen = lastSeen })
		end
	end
end

---Counts the enemies seen 15 to 30 minutes ago per zone, for the trend. Returns false when the sighting
---ring doesn't reach back that far (a busy half hour fills it), so no trend is shown.
function private.AddEarlier(groups, byName, now)
	local from, to = now - 2 * RECENT, now - RECENT
	local seen = {}
	local count, oldest = 0, now
	for sighting in Store:SightingIterator() do
		count = count + 1
		oldest = min(oldest, sighting.t or now)
		if sighting.t and sighting.t >= from and sighting.t < to and not Wanted.db.ignore[sighting.guid] then
			local key = (sighting.mapId or sighting.zone or "?").."|"..sighting.guid
			if not seen[key] then
				seen[key] = true
				local player = Store:GetPlayer(sighting.guid)
				if not player or player.faction ~= UnitFactionGroup("player") then
					local group = private.GetGroup(groups, byName, sighting.mapId, sighting.zone)
					group.earlier = group.earlier + 1
				end
			end
		end
	end
	return count < Store.MAX_SIGHTINGS or oldest <= from
end

---Adds PvP deaths in the last hour (kills and witnessed deaths, each death once).
function private.AddDeaths(groups, byName, now)
	local counted = {}
	for _, kind in ipairs({ "kill", "death" }) do
		for record in Store:Iterator(kind) do
			local data = record.data
			local key = data.deathId or record.id
			if record.t and now - record.t <= HOUR and data.zone and not counted[key] then
				counted[key] = true
				local group = private.GetGroup(groups, byName, nil, data.zone)
				group.deaths = group.deaths + 1
				group.lastFight = max(group.lastFight or 0, record.t)
			end
		end
	end
end



-- ============================================================================
-- Public
-- ============================================================================

---Zones with enemy activity in the last hour, busiest first.
---@return table[] { zone, mapId, recent, hour, minLevel, maxLevel, skull, guild, guildCount, deaths, trend, lastSeen, enemies }
function Hotspots:Get()
	local now = GetServerTime()
	local groups, byName = {}, {}
	private.AddPlayers(groups, byName, now)
	local trendKnown = private.AddEarlier(groups, byName, now)
	private.AddDeaths(groups, byName, now)
	local list = {}
	for _, group in pairs(groups) do
		if group.hour > 0 or group.deaths > 0 then
			for guild, count in pairs(group.guilds) do
				if count >= GUILD_MIN and count > (group.guildCount or 0) then
					group.guild, group.guildCount = guild, count
				end
			end
			if trendKnown then
				local change = group.recent - group.earlier
				group.trend = change >= TREND_MIN and "up" or (change <= -TREND_MIN and "down") or "steady"
			end
			sort(group.enemies, function(a, b) return a.lastSeen > b.lastSeen end)
			tinsert(list, group)
		end
	end
	sort(list, function(a, b)
		if a.recent ~= b.recent then
			return a.recent > b.recent
		elseif a.hour ~= b.hour then
			return a.hour > b.hour
		elseif a.deaths ~= b.deaths then
			return a.deaths > b.deaths
		end
		return a.zone < b.zone
	end)
	return list
end

---The zones with enemies seen in the last 15 minutes, busiest first.
---@param count number
---@return table[]
function Hotspots:GetTop(count)
	local top = {}
	for _, group in ipairs(Hotspots:Get()) do
		if group.recent > 0 and #top < count then
			tinsert(top, group)
		end
	end
	return top
end

---"18-24", "20", "60 + ??" style level range.
---@param group table
---@return string
function Hotspots:FormatLevels(group)
	local text
	if group.minLevel and group.minLevel ~= group.maxLevel then
		text = group.minLevel.."-"..group.maxLevel
	elseif group.minLevel then
		text = tostring(group.minLevel)
	end
	if group.skull then
		return text and (text.." + ??") or "??"
	end
	return text or "?"
end

---Opens the world map on the zone, when its map id is known.
---@param group table
---@return boolean opened
function Hotspots:OpenMap(group)
	-- The game can block an addon opening the map in combat
	if not group.mapId or not OpenWorldMap or InCombatLockdown() then
		return false
	end
	OpenWorldMap(group.mapId)
	return true
end
