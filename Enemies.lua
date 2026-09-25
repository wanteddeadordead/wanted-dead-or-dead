-- Wanted: enemy awareness. Keeps the Nearby list (enemy players seen in the last minute or so, with the
-- ones acting right now marked active), the Kill on Sight and Ignore lists with reasons, and per-enemy
-- statistics: how often seen, wins (your kills of them) and losses (their kills of you).
--
-- The combat log is closed on this client, so enemies are seen through unit tokens: nameplates, target,
-- focus and mouseover, scanned when they appear and once a second while they stay. Their spell casts
-- reveal stealth. Losses come from the death recap, or failing that from the one enemy who had you
-- targeted when you died.

local _, Wanted = ...
local Enemies = Wanted:NewModule("Enemies")
local Store = Wanted.Store
local private = {
	frame = CreateFrame("Frame"),
	nearby = {}, -- guid -> entry
	plates = {}, -- nameplate unit -> true
	targetingMe = {}, -- guid -> time they last had us targeted
	recentCasts = {}, -- guid..spell -> time
	lastShared = {}, -- guid -> time we last shared a sighting of them
	targeters = {}, -- guid -> true for enemies targeting us now
	lastRecapId = nil,
	listeners = {},
	playerFaction = nil,
}
local SCAN_SECONDS = 1
local ACTIVE_SECONDS = 10 -- seen acting this recently counts as active
-- Nameplates only exist while a player is on screen, so turning the camera away or stepping behind a wall
-- hides someone who is still around: they count as in sight for a while after the last sighting (settings:
-- inSight), then show shaded (settings: timeout), then leave the list
local DEFAULT_IN_SIGHT = 60
local DEFAULT_SHADED = 30
local TARGETER_SECONDS = 2.2 -- seen targeting us within this long counts as targeting us now
local LAST_HOUR = 3600
local TARGETING_WINDOW = 6 -- had us targeted within this long before we died
local SHARE_EVERY = 120 -- seconds between shared sightings of the same enemy
local STORE_EVERY = 5 -- seconds between updates of a nearby enemy's saved record
local RECAP_DELAYS = { 0.5, 2 }
-- Stealth-type abilities by spell id (all ranks); names catch anything the client renumbered
local STEALTH_SPELLS = {
	[1784] = "Stealth", [1785] = "Stealth", [1786] = "Stealth", [1787] = "Stealth",
	[1856] = "Vanish", [1857] = "Vanish", [26889] = "Vanish",
	[5215] = "Prowl", [6783] = "Prowl", [9913] = "Prowl",
	[58984] = "Shadowmeld", [20580] = "Shadowmeld",
	[66] = "Invisibility",
}
local STEALTH_NAMES = { Stealth = true, Vanish = true, Prowl = true, Shadowmeld = true, Invisibility = true }



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Enemies:OnLoad()
	local db = Wanted.db
	db.kos = db.kos or {}
	db.ignore = db.ignore or {}
	db.enemyStats = db.enemyStats or {}
end

function Enemies:OnEnable()
	private.playerFaction = UnitFactionGroup("player")
	for _, event in ipairs({ "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "PLAYER_FOCUS_CHANGED", "UNIT_SPELLCAST_SUCCEEDED", "PLAYER_DEAD", "UNIT_TARGET" }) do
		private.frame:RegisterEvent(event)
	end
	private.frame:SetScript("OnEvent", private.OnEvent)
	C_Timer.NewTicker(SCAN_SECONDS, private.Tick)
end

function Enemies:Status()
	local nearby = 0
	for _ in pairs(private.nearby) do
		nearby = nearby + 1
	end
	return format("Enemies: %d nearby, %d on Kill on Sight, %d ignored.", nearby, Enemies:Count(Wanted.db.kos), Enemies:Count(Wanted.db.ignore))
end

function Enemies:Count(tbl)
	local n = 0
	for _ in pairs(tbl) do
		n = n + 1
	end
	return n
end

---Registers a function called as (event, entry) for "new", "update", "removed", "stealth", "shared".
function Enemies:OnChange(func)
	tinsert(private.listeners, func)
end

local function Fire(event, entry)
	for _, func in ipairs(private.listeners) do
		func(event, entry)
	end
end

function private.Settings()
	return Wanted.db.settings.detect
end

function private.Readable(value)
	if value == nil or (issecretvalue and issecretvalue(value)) then
		return nil
	end
	return value
end



-- ============================================================================
-- Events
-- ============================================================================

function private.OnEvent(_, event, arg1, _, arg3)
	if not private.Settings().enabled then
		return
	end
	if event == "NAME_PLATE_UNIT_ADDED" then
		private.plates[arg1] = true
		private.Scan(arg1)
	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		private.plates[arg1] = nil
	elseif event == "PLAYER_TARGET_CHANGED" then
		private.Scan("target")
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		private.Scan("mouseover")
	elseif event == "PLAYER_FOCUS_CHANGED" then
		private.Scan("focus")
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		private.OnCast(arg1, arg3)
	elseif event == "PLAYER_DEAD" then
		private.OnPlayerDead()
	elseif event == "UNIT_TARGET" then
		-- An enemy changed target: check at once rather than on the next scan
		if arg1 == "target" or arg1 == "focus" or (type(arg1) == "string" and strfind(arg1, "^nameplate%d+$")) then
			private.Scan(arg1)
			private.UpdateTargeters()
		end
	end
end

---Who has us targeted right now (seen doing so in the last couple of seconds), and tells listeners when that
---changes: "targeted" with the new list, and "newTargeter" for each enemy who just started.
function private.UpdateTargeters()
	local now = GetTime()
	local current = {}
	local changed = false
	for guid, entry in pairs(private.nearby) do
		if entry.targetingMe and now - entry.targetingMe < TARGETER_SECONDS then
			current[guid] = true
			if not private.targeters[guid] then
				changed = true
				Fire("newTargeter", entry)
			end
		end
	end
	for guid in pairs(private.targeters) do
		if not current[guid] then
			changed = true
		end
	end
	private.targeters = current
	if changed then
		Fire("targeted", nil)
	end
end

---The enemies targeting us now, as Describe() results, Kill on Sight and bounty targets first.
---@return table[]
function Enemies:GetTargeters()
	local list = {}
	for guid in pairs(private.targeters) do
		tinsert(list, Enemies:Describe(guid))
	end
	-- Most dangerous first: Kill on Sight and bounty targets, then anyone casting, then by level. Distance would
	-- be better, but this client doesn't tell addons how far away an enemy player is.
	local function Rank(d)
		if d.kos or d.bounty > 0 then
			return 0
		end
		return d.active and 1 or 2
	end
	sort(list, function(a, b)
		local ar, br = Rank(a), Rank(b)
		if ar ~= br then
			return ar < br
		end
		if (a.level or 0) ~= (b.level or 0) then
			return (a.level or 0) > (b.level or 0)
		end
		return a.name < b.name
	end)
	return list
end

function private.Tick()
	if not private.Settings().enabled then
		return
	end
	for unit in pairs(private.plates) do
		if UnitExists(unit) then
			private.Scan(unit)
		else
			private.plates[unit] = nil
		end
	end
	private.Scan("target")
	private.Scan("focus")
	-- Enemies nobody has seen for the in-sight time plus the shaded time leave the Nearby list
	local now = GetTime()
	local timeout = private.InSightSeconds() + (private.Settings().timeout or DEFAULT_SHADED)
	for guid, entry in pairs(private.nearby) do
		if now - entry.lastSeen > timeout then
			private.nearby[guid] = nil
			Fire("removed", entry)
		end
	end
	for guid, t in pairs(private.targetingMe) do
		if now - t > 60 then
			private.targetingMe[guid] = nil
		end
	end
	private.UpdateTargeters()
end



-- ============================================================================
-- Seeing enemies
-- ============================================================================

---Looks at a unit; if it's an enemy player, updates the Nearby list and returns its entry.
function private.Scan(unit)
	if not unit or not private.Readable(UnitExists(unit)) or not private.Readable(UnitIsPlayer(unit)) then
		return nil
	end
	if not private.Readable(UnitIsEnemy("player", unit)) then
		return nil
	end
	local guid = private.Readable(UnitGUID(unit))
	local name = private.Readable(GetUnitName(unit, true))
	if not guid or not name then
		return nil
	end
	if Wanted.db.ignore[guid] then
		return nil
	end
	local now = GetTime()
	local entry = private.nearby[guid]
	local isNew = not entry
	if isNew then
		entry = { guid = guid, firstSeen = now, detected = GetServerTime() }
		private.nearby[guid] = entry
	end
	entry.name = name
	entry.unit = unit
	entry.lastSeen = now
	local _, class = UnitClass(unit)
	entry.class = private.Readable(class) or entry.class
	local level = private.Readable(UnitLevel(unit))
	entry.level = (level and level > 0) and level or entry.level
	entry.skull = level == -1
	entry.race = private.Readable((UnitRace(unit))) or entry.race
	entry.guild = Wanted.Recorder:GetUnitGuild(unit) or entry.guild

	local zone, x, y, mapId = Wanted.Recorder:GetPosition()
	entry.zone, entry.x, entry.y, entry.mapId = zone, x, y, mapId
	-- Someone who has us targeted is a likely killer if we die
	local ok, targetsMe = pcall(UnitIsUnit, unit.."target", "player")
	if ok and private.Readable(targetsMe) then
		private.targetingMe[guid] = now
		entry.targetingMe = now
	elseif ok and targetsMe == false then
		-- Seen targeting someone else: they've stopped targeting us
		entry.targetingMe = nil
	end
	-- Keep the saved player current (the Last hour list and the map read it), at most every few seconds
	if not entry.lastStored or now - entry.lastStored >= STORE_EVERY then
		entry.lastStored = now
		Store:UpdatePlayer(guid, {
			name = name,
			class = entry.class,
			level = entry.level,
			race = entry.race,
			guild = entry.guild or false,
			faction = private.Readable(UnitFactionGroup(unit)) or (private.playerFaction == "Horde" and "Alliance" or "Horde"),
			zone = zone,
			mapId = mapId,
			x = x,
			y = y,
		})
	end
	if isNew then
		local stats = Enemies:GetStats(guid, true)
		stats.detections = (stats.detections or 0) + 1
		stats.first = stats.first or GetServerTime()
		stats.last = GetServerTime()
		stats.name = name
		Fire("new", entry)
		private.Share(entry)
	else
		Enemies:GetStats(guid, true).last = GetServerTime()
		Fire("update", entry)
		if GetTime() - (private.lastShared[guid] or 0) > SHARE_EVERY then
			private.Share(entry)
		end
	end
	return entry
end

function private.OnCast(unit, spellID)
	if type(unit) ~= "string" or not (unit == "target" or unit == "focus" or unit == "mouseover" or strfind(unit, "^nameplate%d+$")) then
		return
	end
	local entry = private.Scan(unit)
	spellID = private.Readable(spellID)
	if not entry or type(spellID) ~= "number" then
		return
	end
	entry.lastActive = GetTime()
	local key = entry.guid..":"..spellID
	local now = GetTime()
	-- One cast is reported once for every token pointing at the caster
	if private.recentCasts[key] and now - private.recentCasts[key] < 1 then
		return
	end
	private.recentCasts[key] = now
	local kind = STEALTH_SPELLS[spellID]
	if not kind and C_Spell and C_Spell.GetSpellName then
		local spellName = private.Readable(C_Spell.GetSpellName(spellID))
		kind = spellName and STEALTH_NAMES[spellName] and spellName or nil
	end
	if kind then
		entry.stealthed = now
		entry.stealthKind = kind
		Fire("stealth", entry)
	end
end



-- ============================================================================
-- Wins and losses
-- ============================================================================

---Enemy statistics (created on demand when create is set).
---@param guid string
---@param create boolean?
---@return table?
function Enemies:GetStats(guid, create)
	local stats = Wanted.db.enemyStats[guid]
	if not stats and create then
		stats = { wins = 0, losses = 0, detections = 0 }
		Wanted.db.enemyStats[guid] = stats
	end
	return stats
end

---Called by the recorder when the player kills an enemy.
---@param guid string
function Enemies:NoteWin(guid)
	local stats = Enemies:GetStats(guid, true)
	stats.wins = (stats.wins or 0) + 1
	stats.lastWin = GetServerTime()
	Wanted:Log("Enemies: win against %s", guid)
end

function private.OnPlayerDead()
	if IsInInstance() then
		return
	end
	-- Take the suspects now: the scan keeps running while we wait for the recap
	local suspects = {}
	local now = GetTime()
	for guid, t in pairs(private.targetingMe) do
		if now - t <= TARGETING_WINDOW then
			tinsert(suspects, guid)
		end
	end
	C_Timer.After(RECAP_DELAYS[1], function() private.ResolveDeath(suspects, 1) end)
end

---The killing blow of the latest death recap, as a GUID and name, if it names a player.
function private.KillerFromRecap()
	if not (C_DeathRecap and C_DeathRecap.GetRecapEvents) then
		return nil, "unavailable"
	end
	local id = nil
	if C_DeathRecap.GetRecapLink then
		local ok, link = pcall(C_DeathRecap.GetRecapLink)
		link = ok and private.Readable(link)
		id = type(link) == "string" and tonumber(strmatch(link, "death:(%d+)")) or nil
	end
	if id and id == private.lastRecapId then
		return nil, "stale"
	end
	private.lastRecapId = id
	local ok, events = pcall(C_DeathRecap.GetRecapEvents)
	if not ok or type(events) ~= "table" or (issecrettable and issecrettable(events)) then
		return nil, "unreadable"
	end
	local blow = events[1]
	if type(blow) ~= "table" or (issecrettable and issecrettable(blow)) then
		return nil, "empty"
	end
	local sourceGUID = private.Readable(blow.sourceGUID)
	if type(sourceGUID) == "string" and strfind(sourceGUID, "^Player%-") then
		return sourceGUID, "recap"
	end
	return nil, "not a player"
end

function private.ResolveDeath(suspects, attempt)
	local killer, how = private.KillerFromRecap()
	if not killer and how == "stale" and attempt < #RECAP_DELAYS then
		C_Timer.After(RECAP_DELAYS[attempt + 1] - RECAP_DELAYS[attempt], function() private.ResolveDeath(suspects, attempt + 1) end)
		return
	end
	if not killer and how ~= "not a player" and #suspects == 1 then
		-- The recap couldn't say: the one enemy who had us targeted is the likely killer
		killer, how = suspects[1], "targeting"
	end
	Wanted:Log("Enemies: death, killer %s (%s)", tostring(killer), how)
	if killer then
		local stats = Enemies:GetStats(killer, true)
		stats.losses = (stats.losses or 0) + 1
		stats.lastLoss = GetServerTime()
		local entry = private.nearby[killer]
		Fire("killedby", entry or { guid = killer, name = stats.name or (Store:GetPlayer(killer) or {}).name })
	end
end



-- ============================================================================
-- Kill on Sight and Ignore
-- ============================================================================

function Enemies:IsKoS(guid)
	return guid and Wanted.db.kos[guid] ~= nil
end

function Enemies:IsIgnored(guid)
	return guid and Wanted.db.ignore[guid] ~= nil
end

---@param guid string
---@param name string
---@param on boolean
function Enemies:SetKoS(guid, name, on)
	if on then
		Wanted.db.kos[guid] = Wanted.db.kos[guid] or { name = name, t = GetServerTime() }
		Wanted.db.ignore[guid] = nil
	else
		Wanted.db.kos[guid] = nil
	end
	Fire("lists", nil)
end

function Enemies:SetReason(guid, reason)
	local kos = Wanted.db.kos[guid]
	if kos then
		kos.reason = reason ~= "" and reason or nil
		Fire("lists", nil)
	end
end

function Enemies:SetIgnored(guid, name, on)
	if on then
		Wanted.db.ignore[guid] = { name = name, t = GetServerTime() }
		Wanted.db.kos[guid] = nil
		local entry = private.nearby[guid]
		private.nearby[guid] = nil
		if entry then
			Fire("removed", entry)
		end
	else
		Wanted.db.ignore[guid] = nil
	end
	Fire("lists", nil)
end

---Takes an enemy off the Nearby list until they're seen again.
function Enemies:RemoveNearby(guid)
	local entry = private.nearby[guid]
	private.nearby[guid] = nil
	if entry then
		Fire("removed", entry)
	end
end

function Enemies:ClearNearby()
	wipe(private.nearby)
	Fire("lists", nil)
end



-- ============================================================================
-- Lists for the interface
-- ============================================================================

---Everything known about an enemy, merged from the Nearby entry, the player store and the lists.
---@param guid string
---How long an enemy out of view still counts as in sight.
function private.InSightSeconds()
	return private.Settings().inSight or DEFAULT_IN_SIGHT
end

---@return table
function Enemies:Describe(guid)
	local entry = private.nearby[guid]
	local player = Store:GetPlayer(guid) or {}
	local stats = Enemies:GetStats(guid) or {}
	local kos = Wanted.db.kos[guid]
	local bounty = 0
	for _, b in ipairs(Wanted.Bounties:GetOpenForTarget(guid)) do
		bounty = bounty + Wanted.Bounties:GetAmount(b)
	end
	local guild = entry and entry.guild or player.guild or nil
	for _, b in ipairs(Wanted.Bounties:GetOpenForGuild(guild)) do
		bounty = bounty + Wanted.Bounties:GetAmount(b)
	end
	return {
		guid = guid,
		name = entry and entry.name or player.name or stats.name or (kos and kos.name) or "?",
		class = entry and entry.class or player.class,
		level = entry and entry.level or player.level,
		skull = entry and entry.skull,
		race = entry and entry.race or player.race,
		guild = guild or nil,
		zone = entry and entry.zone or player.zone,
		x = entry and entry.x or player.x,
		y = entry and entry.y or player.y,
		lastSeen = entry and (GetServerTime() - (GetTime() - entry.lastSeen)) or player.lastSeen or stats.last,
		nearby = entry ~= nil,
		-- In sight: a unit token showed them in the last scan. Active: casting or targeting us lately.
		inSight = entry and GetTime() - entry.lastSeen < private.InSightSeconds() or false,
		goneFor = entry and floor(GetTime() - entry.lastSeen) or nil,
		active = entry and ((entry.lastActive and GetTime() - entry.lastActive < ACTIVE_SECONDS) or (entry.targetingMe and GetTime() - entry.targetingMe < ACTIVE_SECONDS)) or false,
		stealthed = entry and entry.stealthed and GetTime() - entry.stealthed < 30,
		stealthKind = entry and entry.stealthKind,
		targetingMe = entry and entry.targetingMe and GetTime() - entry.targetingMe < 5,
		-- The unit token that showed them last (for widgets that draw secret values such as health)
		unit = entry and entry.unit,
		kos = kos ~= nil,
		reason = kos and kos.reason,
		ignored = Wanted.db.ignore[guid] ~= nil,
		wins = stats.wins or 0,
		losses = stats.losses or 0,
		detections = stats.detections or 0,
		bounty = bounty,
		firstSeen = entry and entry.firstSeen,
	}
end

---The Nearby list: Kill on Sight and bounty targets first, then whoever is acting, then newest first.
---@return table[]
function Enemies:GetNearby()
	local list = {}
	for guid in pairs(private.nearby) do
		tinsert(list, Enemies:Describe(guid))
	end
	-- Kill on Sight and bounty targets first, then who's acting, then who's in sight, then who's gone; newest
	-- detection first within each
	local function Rank(d)
		local rank = d.active and 1 or (d.inSight and 2 or 3)
		if d.kos or d.bounty > 0 then
			rank = rank - 3
		end
		return rank
	end
	sort(list, function(a, b)
		local ai, bi = Rank(a), Rank(b)
		if ai ~= bi then
			return ai < bi
		end
		return (a.firstSeen or 0) > (b.firstSeen or 0)
	end)
	return list
end

---Enemies seen in the last hour (own and shared sightings), newest first.
---@return table[]
function Enemies:GetLastHour()
	local list, seen = {}, {}
	local now = GetServerTime()
	for guid, player in pairs(Wanted.db.players) do
		if player.lastSeen and now - player.lastSeen <= LAST_HOUR and player.faction and player.faction ~= private.playerFaction and not Wanted.db.ignore[guid] and strfind(guid, "^Player%-") then
			seen[guid] = true
			tinsert(list, Enemies:Describe(guid))
		end
	end
	for guid in pairs(private.nearby) do
		if not seen[guid] then
			tinsert(list, Enemies:Describe(guid))
		end
	end
	sort(list, function(a, b) return (a.lastSeen or 0) > (b.lastSeen or 0) end)
	return list
end

---Whether enemy players can attack you right now: PvP flagged (or in a free-for-all area), and not in a
---sanctuary. Alerts and the Nearby window stay quiet otherwise, when the player chooses (settings:
---onlyWhenExposed); detection itself keeps running either way.
---@return boolean
function Enemies:IsExposed()
	if UnitIsPVPSanctuary and private.Readable(UnitIsPVPSanctuary("player")) then
		return false
	end
	if UnitIsPVPFreeForAll and private.Readable(UnitIsPVPFreeForAll("player")) then
		return true
	end
	return private.Readable(UnitIsPVP("player")) and true or false
end

---Whether alerts and the Nearby window should speak up now.
---@return boolean
function Enemies:ShouldAlert()
	local settings = private.Settings()
	return settings.enabled and (not settings.onlyWhenExposed or Enemies:IsExposed())
end

function Enemies:GetKoSList()
	local list = {}
	for guid in pairs(Wanted.db.kos) do
		tinsert(list, Enemies:Describe(guid))
	end
	sort(list, function(a, b) return (a.lastSeen or 0) > (b.lastSeen or 0) end)
	return list
end

function Enemies:GetIgnoreList()
	local list = {}
	for guid, info in pairs(Wanted.db.ignore) do
		local d = Enemies:Describe(guid)
		d.name = d.name ~= "?" and d.name or info.name
		tinsert(list, d)
	end
	sort(list, function(a, b) return a.name < b.name end)
	return list
end

---Every enemy the addon knows, for the statistics page.
---@param filter string? "kos" | "ignored" | nil
---@return table[]
function Enemies:GetAll(filter)
	local list = {}
	local guids = {}
	for guid, player in pairs(Wanted.db.players) do
		if player.faction and player.faction ~= private.playerFaction then
			guids[guid] = true
		end
	end
	for guid in pairs(Wanted.db.enemyStats) do
		guids[guid] = true
	end
	for guid in pairs(Wanted.db.kos) do
		guids[guid] = true
	end
	for guid in pairs(Wanted.db.ignore) do
		guids[guid] = true
	end
	for guid in pairs(guids) do
		if strfind(guid, "^Player%-") and (not filter or (filter == "kos" and Wanted.db.kos[guid]) or (filter == "ignored" and Wanted.db.ignore[guid])) then
			tinsert(list, Enemies:Describe(guid))
		end
	end
	return list
end



-- ============================================================================
-- Sharing
-- ============================================================================

function private.Share(entry)
	if not private.Settings().share or not Wanted.Sync or IsInInstance() then
		return
	end
	private.lastShared[entry.guid] = GetTime()
	local stealthed = entry.stealthed and GetTime() - entry.stealthed < 30 or nil
	local d = Enemies:Describe(entry.guid)
	Wanted.Sync:QueueSighting({
		g = entry.guid, n = entry.name, c = entry.class, l = entry.level, r = entry.race, u = entry.guild,
		z = entry.zone, m = entry.mapId, x = entry.x, y = entry.y, s = stealthed,
	}, d.kos or d.bounty > 0 or stealthed or false)
end

---A sighting another Wanted user shared.
---@param data table
---@param sender string
function Enemies:OnSharedSighting(data, sender)
	if type(data.g) ~= "string" or not strfind(data.g, "^Player%-") or type(data.n) ~= "string" then
		return
	end
	local player = Store:GetPlayer(data.g)
	if player and player.faction == private.playerFaction then
		return
	end
	Store:UpdatePlayer(data.g, {
		name = data.n,
		class = type(data.c) == "string" and data.c or nil,
		level = type(data.l) == "number" and data.l or nil,
		race = type(data.r) == "string" and data.r or nil,
		guild = type(data.u) == "string" and data.u or nil,
		faction = player and player.faction or (private.playerFaction == "Horde" and "Alliance" or "Horde"),
		zone = type(data.z) == "string" and data.z or nil,
		mapId = type(data.m) == "number" and data.m or nil,
		x = type(data.x) == "number" and data.x or nil,
		y = type(data.y) == "number" and data.y or nil,
		seenBy = sender,
	})
	Store:AddSighting(data.g, data.z, data.x, data.y, data.m, sender)
	Fire("shared", { guid = data.g, name = data.n, by = sender, zone = data.z, x = data.x, y = data.y, stealthed = data.s })
end
