-- Wanted: where wanted players have been. Sightings (yours and other Wanted users') of anyone with an open
-- bounty on them or their guild, or on your Kill on Sight list, are kept per player for a month, so a
-- hunter can see their usual zones and the hours they're about. Other enemies aren't kept: the saved data
-- would grow with every player you ever pass.

local _, Wanted = ...
local Tracks = Wanted:NewModule("Tracks")
local Store = Wanted.Store
local Bounties = Wanted.Bounties
local private = { watched = nil, watchedAt = 0 }
local MAX_PER_PLAYER = 300
local KEEP_SECONDS = 30 * 24 * 60 * 60
local MIN_GAP = 60 -- one entry a minute per player, unless they changed zone
local WATCHED_REFRESH = 30 -- seconds between rebuilding the list of who is wanted

function Tracks:OnLoad()
	Wanted.db.tracks = Wanted.db.tracks or {}
end

function Tracks:OnEnable()
	Store:OnRecord("sighting", function(record)
		Tracks:Add(record.sighting)
	end)
end

---Players and guilds worth keeping a history of: open bounties and Kill on Sight.
function private.GetWatched()
	local now = GetTime()
	if private.watched and now - private.watchedAt < WATCHED_REFRESH then
		return private.watched
	end
	local watched = { players = {}, guilds = {} }
	for bounty in Bounties:OpenIterator() do
		if bounty.data.target then
			watched.players[bounty.data.target] = true
		elseif bounty.data.guild then
			watched.guilds[bounty.data.guild] = true
		end
	end
	for guid in pairs(Wanted.db.kos) do
		watched.players[guid] = true
	end
	private.watched, private.watchedAt = watched, now
	return watched
end

---Whether a player's sightings are kept.
---@param guid string
---@return boolean
function Tracks:IsWatched(guid)
	local watched = private.GetWatched()
	if watched.players[guid] then
		return true
	end
	local player = Store:GetPlayer(guid)
	return player and type(player.guild) == "string" and watched.guilds[player.guild] or false
end

---Adds a sighting to the player's history if they're wanted.
---@param sighting table { guid, zone, mapId, x, y, by, t }
function Tracks:Add(sighting)
	if not sighting or not sighting.guid or not Tracks:IsWatched(sighting.guid) then
		return
	end
	local tracks = Wanted.db.tracks
	local list = tracks[sighting.guid]
	if not list then
		list = {}
		tracks[sighting.guid] = list
	end
	local last = list[#list]
	local entry = { t = sighting.t, zone = sighting.zone, mapId = sighting.mapId, x = sighting.x, y = sighting.y, by = sighting.by }
	if last and sighting.t - last.t < MIN_GAP and last.zone == sighting.zone then
		-- Still around the same place: keep the newest position
		list[#list] = entry
	else
		tinsert(list, entry)
	end
	private.Trim(list, sighting.t)
end

function private.Trim(list, now)
	while list[1] and (#list > MAX_PER_PLAYER or now - list[1].t > KEEP_SECONDS) do
		tremove(list, 1)
	end
end

---Everything known about where a player has been, newest first: their kept history, plus recent
---sightings from before they were wanted.
---@param guid string
---@return table[] { t, zone, mapId, x, y, by }
function Tracks:Get(guid)
	local entries = {}
	local seen = {}
	for _, entry in ipairs(Wanted.db.tracks[guid] or {}) do
		tinsert(entries, entry)
		seen[floor(entry.t / MIN_GAP)..(entry.by or "")] = true
	end
	for sighting in Store:SightingIterator() do
		if sighting.guid == guid and not seen[floor(sighting.t / MIN_GAP)..(sighting.by or "")] then
			seen[floor(sighting.t / MIN_GAP)..(sighting.by or "")] = true
			tinsert(entries, { t = sighting.t, zone = sighting.zone, mapId = sighting.mapId, x = sighting.x, y = sighting.y, by = sighting.by })
		end
	end
	sort(entries, function(a, b) return a.t > b.t end)
	return entries
end

---Patterns in a player's whereabouts: zones by how often, the hours they're usually about (your time),
---and on how many days they've been seen.
---@param entries table[] from Tracks:Get
---@return table { zones = { { zone, count, last } }, hours = { { from, to, count } }, days, first }
function Tracks:Summarize(entries)
	local zones, byZone = {}, {}
	local hours = {}
	local days = {}
	local first
	for _, entry in ipairs(entries) do
		local zone = entry.zone or "?"
		local z = byZone[zone]
		if not z then
			z = { zone = zone, count = 0, last = 0, mapId = entry.mapId }
			byZone[zone] = z
			tinsert(zones, z)
		end
		z.count = z.count + 1
		z.last = max(z.last, entry.t)
		local hour = tonumber(date("%H", entry.t))
		hours[hour] = (hours[hour] or 0) + 1
		days[date("%Y-%m-%d", entry.t)] = true
		first = min(first or entry.t, entry.t)
	end
	sort(zones, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.last > b.last
	end)
	-- The busiest three-hour windows, not overlapping
	local windows = {}
	local used = {}
	for _ = 1, 2 do
		local bestStart, bestCount = nil, 0
		for start = 0, 23 do
			local count = 0
			local free = true
			for h = start, start + 2 do
				local hour = h % 24
				count = count + (hours[hour] or 0)
				free = free and not used[hour]
			end
			if free and count > bestCount then
				bestStart, bestCount = start, count
			end
		end
		if bestStart then
			for h = bestStart, bestStart + 2 do
				used[h % 24] = true
			end
			tinsert(windows, { from = bestStart, to = (bestStart + 3) % 24, count = bestCount })
		end
	end
	local numDays = 0
	for _ in pairs(days) do
		numDays = numDays + 1
	end
	return { zones = zones, hours = windows, days = numDays, first = first }
end

---Deaths of the player the records hold (kills of them and witnessed deaths, each once), newest first.
---@param guid string
---@return table[] { t, zone, x, y, by, killer }
function Tracks:GetDeaths(guid)
	local deaths, counted = {}, {}
	for _, kind in ipairs({ "kill", "death" }) do
		for record in Store:Iterator(kind) do
			local data = record.data
			local key = data.deathId or record.id
			if data.victim == guid and not counted[key] then
				counted[key] = true
				tinsert(deaths, { t = record.t, zone = data.zone, x = data.x, y = data.y, by = record.origin, killer = kind == "kill" and record.origin or data.killerName })
			end
		end
	end
	sort(deaths, function(a, b) return a.t > b.t end)
	return deaths
end
