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
	tracked = {}, -- unit token -> guid of an enemy player being watched
	lastSighting = {}, -- guid -> time
	recentDeaths = {}, -- guid -> time the death was recorded
	seenAlive = {}, -- guid -> true once we've seen them alive (a corpse we come across is not a new death)
	confirming = {}, -- guid -> true while a death waits to be confirmed
	recentOwnKill = {}, -- guid -> time of the player's own kill (kill event and honor message both report it)
	playerGUID = nil,
	playerFaction = nil,
}
-- The same enemy is not re-sighted more often than this
local SIGHTING_INTERVAL = 30
-- One death per victim within this window, however many units show it
local DEATH_DEDUPE_SECONDS = 15
-- A death is confirmed this long after it's seen: a hunter's Feign Death looks exactly like dying, but they're
-- up again by then. Nobody comes back from a real death that fast (a ghost that released drops out of view).
local DEATH_CONFIRM_SECONDS = 4
-- The server's honor message arrives within this long of the death
local HONOR_MATCH_WINDOW = 10
local MAX_LOG_LINES = 20
local UNITS = { "target", "mouseover" }



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Recorder:OnEnable()
	private.playerGUID = UnitGUID("player")
	private.playerFaction = UnitFactionGroup("player")
	for _, event in ipairs({ "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "UNIT_HEALTH", "CHAT_MSG_COMBAT_HONOR_GAIN", "PARTY_KILL", "UNIT_DIED" }) do
		Wanted:Log("Recorder: registering %s", event)
		private.frame:RegisterEvent(event)
	end
	private.frame:SetScript("OnEvent", private.OnEvent)
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

function private.OnEvent(_, event, arg1, arg2)
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
	end
end



-- ============================================================================
-- Where we are
-- ============================================================================

---The zone name and map coordinates (0-100) of the player, or nil coordinates where the map gives none.
---@return string zone
---@return number? x
---@return number? y
function Recorder:GetPosition()
	local zone = GetZoneText() or "?"
	local mapId = C_Map.GetBestMapForUnit("player")
	if not mapId then
		return zone, nil, nil, nil
	end
	local pos = C_Map.GetPlayerMapPosition(mapId, "player")
	if not pos then
		return zone, nil, nil, mapId
	end
	return zone, floor(pos.x * 1000 + 0.5) / 10, floor(pos.y * 1000 + 0.5) / 10, mapId
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

---The guild last seen for a player GUID, or nil.
---@param guid string?
---@return string?
function Recorder:GetKnownGuild(guid)
	local player = guid and Store:GetPlayer(guid)
	return player and player.guild or nil
end

function private.InOpenWorld()
	return not IsInInstance()
end



-- ============================================================================
-- Watching enemy players
-- ============================================================================

---Starts watching a unit if it is an enemy player, and records a sighting.
function private.Track(unit)
	if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then
		private.tracked[unit] = nil
		return
	end
	local guid = UnitGUID(unit)
	if not guid or (issecretvalue and issecretvalue(guid)) then
		return
	end
	local faction = UnitFactionGroup(unit)
	if faction == private.playerFaction then
		private.tracked[unit] = nil
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
	Store:UpdatePlayer(guid, {
		name = GetUnitName(unit, true),
		class = class,
		level = UnitLevel(unit),
		faction = faction,
		guild = Recorder:GetUnitGuild(unit) or false, -- false = seen without a guild
		race = UnitRace(unit),
		zone = zone,
		mapId = mapId,
		x = x,
		y = y,
	})
	Store:AddSighting(guid, zone, x, y, mapId)
end

---An enemy player we are watching may have died.
function private.CheckDeath(unit)
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
		private.seenAlive[guid] = true
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
			private.seenAlive[guid] = true
			return
		end
		private.RecordDeath(guid, name)
	end)
end

---Remembers that a watched enemy was alive when seen.
function private.NoteAlive(unit, guid)
	local dead = UnitIsDeadOrGhost(unit)
	if dead == false then
		private.seenAlive[guid] = true
	end
end

---The client's death event for any unit near us; an enemy player dying is a witnessed death.
function private.OnUnitDied(guid)
	if not guid or (issecretvalue and issecretvalue(guid)) or type(guid) ~= "string" or not strfind(guid, "^Player%-") then
		return
	end
	local player = Store:GetPlayer(guid)
	local enemy = player and player.faction and player.faction ~= private.playerFaction
	if not enemy then
		-- Unknown so far: ask the client, and only count other-faction players
		local _, class, _, _, _, name = GetPlayerInfoByGUID(guid)
		if not name or (issecretvalue and issecretvalue(name)) then
			return
		end
		for unit, trackedGuid in pairs(private.tracked) do
			if trackedGuid == guid then
				enemy = true
				break
			end
		end
		if not enemy then
			return
		end
		player = { name = name, class = class }
	end
	private.ConfirmDeath(guid, player.name)
end

function private.RecordDeath(guid, name)
	if not private.InOpenWorld() then
		return
	end
	local now = GetTime()
	if private.recentDeaths[guid] and now - private.recentDeaths[guid] < DEATH_DEDUPE_SECONDS then
		return
	end
	private.recentDeaths[guid] = now
	local zone, x, y = Recorder:GetPosition()
	local t = GetServerTime()
	-- Content-addressed id shared by every witness of the same death
	local deathId = Store:Hash(strjoin("|", guid, zone, floor(t / 10)))
	Wanted:Log("Recorder: death of %s in %s", tostring(name), zone)
	Store:UpdatePlayer(guid, { name = name })
	Store:NewRecord("death", {
		deathId = deathId,
		victim = guid,
		victimName = name,
		victimGuild = Recorder:GetKnownGuild(guid),
		zone = zone,
		x = x,
		y = y,
	})
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
	local zone, x, y = Recorder:GetPosition()
	local now = GetServerTime()
	local deathId = Store:Hash(strjoin("|", targetGUID, zone, floor(now / 10)))
	if attackerGUID == private.playerGUID or attackerGUID == UnitGUID("pet") then
		Wanted:Log("Recorder: party kill by you of %s in %s", name, zone)
		private.recentOwnKill[targetGUID] = GetTime()
		Store:NewRecord("kill", {
			killer = private.playerGUID,
			killerName = Store:GetOrigin(),
			killerGuild = Recorder:GetUnitGuild("player"),
			victim = targetGUID,
			victimName = victim and victim.name or name,
			victimGuild = Recorder:GetKnownGuild(targetGUID),
			deathId = deathId,
			zone = zone,
			x = x,
			y = y,
		})
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
		Store:NewRecord("death", {
			deathId = deathId,
			victim = targetGUID,
			victimName = victim and victim.name or name,
			victimGuild = Recorder:GetKnownGuild(targetGUID),
			killer = attackerGUID,
			killerName = killerName,
			zone = zone,
			x = x,
			y = y,
		})
	end
end

function private.HandleHonorGain(text)
	if issecretvalue and issecretvalue(text) then
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
		if now - record.t <= HONOR_MATCH_WINDOW and record.data.victimName == victimName then
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
	local zone, x, y = Recorder:GetPosition()
	Wanted:Log("Recorder: honor kill of %s (%s) in %s", victimName, tostring(guid), zone)
	if guid then
		private.recentOwnKill[guid] = GetTime()
		if Wanted.Enemies then
			Wanted.Enemies:NoteWin(guid)
		end
	end
	if guid then
		Store:UpdatePlayer(guid, { name = victimName })
	end
	Store:NewRecord("kill", {
		killer = private.playerGUID,
		killerName = Store:GetOrigin(),
		killerGuild = Recorder:GetUnitGuild("player"),
		victim = guid or ("name:"..victimName),
		victimName = victimName,
		victimGuild = Recorder:GetKnownGuild(guid),
		deathId = Store:Hash(strjoin("|", guid or victimName, zone, floor(now / 10))),
		zone = zone,
		x = x,
		y = y,
		honor = true,
	})
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
		local where = data.zone..(data.x and format(" (%.1f, %.1f)", data.x, data.y) or "")
		if record.kind == "kill" then
			local killer = record.origin == Store:GetOrigin() and "you" or record.origin
			Wanted:Print("%s: %s killed %s in %s [honor]", Ago(record.t), killer, data.victimName or data.victim, where)
		else
			Wanted:Print("%s: %s died in %s (witnessed by %s)", Ago(record.t), data.victimName or data.victim, where, record.origin)
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
			Wanted:Print("%s: %s (%s %s) in %s%s", Ago(sighting.t), name, player and player.level or "?", player and player.class or "?", sighting.zone, sighting.x and format(" (%.1f, %.1f)", sighting.x, sighting.y) or "")
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
