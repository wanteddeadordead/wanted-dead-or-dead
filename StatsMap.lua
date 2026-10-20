-- Wanted: current stats on the world map. For each zone: who holds it (its side's tint), the kills seen there in the
-- last hour by side and who is ahead, and whether it is busy now, from what this client and the other Wanted players
-- already told it (Store's kills and deaths, Hotspots' enemy counts) and the catch-up's holders. No data of its own.
-- WarMap draws it (a badge on each zone of a continent's map, a plate on a zone's map); this is its numbers and its
-- switch (Settings, Map, and the map button's menu).

local _, Wanted = ...
local StatsMap = Wanted:NewModule("StatsMap")
local Store = Wanted.Store
local GuildWars = Wanted.GuildWars
local C = Wanted.Theme.C
local HOUR, CACHE_SECONDS = 3600, 20
-- Enemies seen in the last 15 minutes (Hotspots' "now") from which a zone is called busy
local BUSY_MIN = 5
local COLORS = { Horde = { 0.82, 0.24, 0.2 }, Alliance = { 0.24, 0.48, 0.92 } }
local private = {}

---Whether the layer is on (the map button's menu, Settings).
function StatsMap:Shown()
	return Wanted.db.settings.statsMap ~= false
end

function StatsMap:SetShown(shown)
	Wanted.db.settings.statsMap = shown and true or false
	Wanted.WarMap:Refresh()
end

---Kills in the last hour by the killer's side, and the enemies seen, per map: mapId -> { Horde, Alliance, kills,
---recent, hour }. Kept for a few seconds: the map redraws often.
function private.Build(now)
	local byMap = {}
	local function Entry(mapId)
		byMap[mapId] = byMap[mapId] or { Horde = 0, Alliance = 0, kills = 0, recent = 0, hour = 0 }
		return byMap[mapId]
	end
	local counted = {}
	for _, kind in ipairs({ "kill", "death" }) do
		for record in Store:Iterator(kind) do
			local data = record.data
			local key = data.deathId or record.id
			if record.t and now - record.t <= HOUR and type(data.mapId) == "number" and not counted[key] and not Store:IsTest(record) then
				counted[key] = true
				local known = type(data.killer) == "string" and Wanted.db.players[data.killer]
				local side = data.killerFaction or (known and known.faction)
				local entry = Entry(data.mapId)
				entry.kills = entry.kills + 1
				if COLORS[side] then
					entry[side] = entry[side] + 1
				end
			end
		end
	end
	for _, group in ipairs(Wanted.Hotspots:Get()) do
		if type(group.mapId) == "number" then
			local entry = Entry(group.mapId)
			entry.recent, entry.hour = group.recent, group.hour
		end
	end
	return byMap
end

---One zone's stats: { name, mapId, kills, Horde, Alliance, ahead, recent, hour, busy, holder (the guild), faction (its
---side), active (anything to say) }.
---@param mapId number
---@param name string
---@param now number?
function StatsMap:Zone(mapId, name, now)
	now = now or GetServerTime()
	if not private.cache or now - private.cache.t >= CACHE_SECONDS then
		private.cache = { t = now, byMap = private.Build(now) }
	end
	local entry = private.cache.byMap[mapId] or { Horde = 0, Alliance = 0, kills = 0, recent = 0, hour = 0 }
	local stats = { name = name, mapId = mapId, kills = entry.kills, Horde = entry.Horde, Alliance = entry.Alliance, recent = entry.recent,
		hour = entry.hour, busy = entry.recent >= BUSY_MIN }
	stats.ahead = entry.Horde > entry.Alliance and "Horde" or entry.Alliance > entry.Horde and "Alliance" or nil
	for _, zone in ipairs(GuildWars:Zones()) do
		if zone.zone == name and type(zone.holder) == "table" and type(zone.holder.guild) == "string" then
			stats.holder, stats.faction = zone.holder.guild, COLORS[zone.holder.faction] and zone.holder.faction or nil
		end
	end
	stats.active = stats.kills > 0 or stats.hour > 0 or stats.holder ~= nil
	return stats
end

---The tint of a zone's stats: its holder's side, else the side ahead, else grey.
function StatsMap:Color(stats)
	return COLORS[stats.faction] or COLORS[stats.ahead] or C.muted
end

---The lines of a tooltip or plate: { { text, color } }.
function StatsMap:Lines(stats)
	local lines = {}
	tinsert(lines, { stats.holder and format("Held by <%s> (%s)", stats.holder, stats.faction or "?") or "Unclaimed", COLORS[stats.faction] or C.text })
	if stats.kills > 0 then
		tinsert(lines, { format("Kills in the last hour: %d (Horde %d, Alliance %d)", stats.kills, stats.Horde, stats.Alliance), C.text })
		tinsert(lines, { stats.ahead and (stats.ahead.." ahead") or "Even", COLORS[stats.ahead] or C.muted })
	else
		tinsert(lines, { "No kills seen in the last hour", C.muted })
	end
	tinsert(lines, { stats.busy and format("Busy now: %d enemies seen in 15 minutes", stats.recent) or "Quiet now", stats.busy and C.amber or C.muted })
	return lines
end

---A few words for a badge: "7 kills", with the busy mark.
function StatsMap:Short(stats)
	return format("%d kill%s%s", stats.kills, stats.kills == 1 and "" or "s", stats.busy and " · busy" or "")
end
