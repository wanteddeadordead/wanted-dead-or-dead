-- Wanted: duels. Each duel the player fights is kept for their own matchup sheet: who it was against (class, race,
-- level and specialization, by inspect), their own specialization, who won, how long it took, where, and how much health and
-- mana each side had left. The opponent's name is kept only when they run Wanted; anyone else is their class and
-- spec ("Frost Mage"), with the GUID kept only to tell duels apart. Kept in WantedDB.duels for the desktop app, never
-- shared with other players, and never a kill, a death or a sighting.
--
-- The game says little about a duel. A challenge to us is DUEL_REQUESTED (or DUEL_TO_THE_DEATH_REQUESTED) with the
-- challenger's name, and GetDuelerInfo gives their GUID; a challenge we send is only our StartDuel call. Accepting is
-- our AcceptDuel call, then a three second countdown; a duel we sent has started once the opponent turns hostile. The
-- end is DUEL_FINISHED (also sent for a challenge declined), and the winner only the system line "X has defeated Y in a
-- duel" (or "Y has fled from X").

local _, Wanted = ...
local Duels = Wanted:NewModule("Duels")
local Store = Wanted.Store
local private = {
	frame = CreateFrame("Frame"),
	-- The duel asked for or under way: { name, guid, requestedAt, startAt, endAt, result, fled, toTheDeath, them,
	-- hostile (whether the opponent was attackable when last seen) }
	-- (them: what's known of the opponent so far, the same fields as a record's)
	duel = nil,
	last = nil, -- { guid, endedAt (GetServerTime()), toTheDeath } of the duel fought last (Duels:Involves)
	inspect = nil, -- { guid, at (GetTime()), taken }: our inspect waiting for its answer (taken: someone else asked since)
	asking = false, -- while our own NotifyInspect runs
	othersAt = -math.huge, -- GetTime() when anyone else last asked for an inspect
	endings = nil, -- the system lines that end a duel, as patterns (private.Endings)
}
-- Duels kept, the oldest dropped first
Duels.MAX = 500
-- Accepting starts a countdown this long before the fight
local COUNTDOWN_SECONDS = 3
-- The winner's line can come just after DUEL_FINISHED: the record waits this long for it
local SETTLE_SECONDS = 2
-- A challenge nobody answered (no DUEL_FINISHED came) is let go after this long
local REQUEST_SECONDS = 10 * 60
-- A duel under way that the game never finished (no DUEL_FINISHED came) is let go after this long
local DUEL_SECONDS = 15 * 60
-- Deaths and kills of the two duellists stay out of the records this long after the duel (a duel to the death's
-- loser dies; the game confirms a death a few seconds later)
local INVOLVED_SECONDS = 30
-- Someone else's inspect gets this long to be answered before ours goes; ours this long before it's given up
local OTHERS_SECONDS = 5
local INSPECT_TIMEOUT = 5
local INSPECT_TRIES = 5
local CHECK_SECONDS = 1
local MANA = 0
-- A talent loadout's import string longer than this isn't kept
local MAX_LOADOUT = 512
-- The game's lines, in case a client lacks them: %1$s is the winner, %2$s the loser
local ENDINGS = {
	{ global = "DUEL_WINNER_KNOCKOUT", text = "%1$s has defeated %2$s in a duel" },
	{ global = "DUEL_WINNER_RETREAT", text = "%2$s has fled from %1$s in a duel", fled = true },
}

function Duels:OnLoad()
	-- Duel records, oldest first (docs/DATA.md)
	Wanted.db.duels = type(Wanted.db.duels) == "table" and Wanted.db.duels or {}
end

function Duels:OnEnable()
	for _, event in ipairs({ "DUEL_REQUESTED", "DUEL_TO_THE_DEATH_REQUESTED", "DUEL_FINISHED", "CHAT_MSG_SYSTEM", "INSPECT_READY" }) do
		pcall(private.frame.RegisterEvent, private.frame, event)
	end
	private.frame:SetScript("OnEvent", function(_, event, arg1)
		if event == "DUEL_REQUESTED" or event == "DUEL_TO_THE_DEATH_REQUESTED" then
			private.OnChallenged(arg1, event == "DUEL_TO_THE_DEATH_REQUESTED")
		elseif event == "DUEL_FINISHED" then
			private.OnFinished()
		elseif event == "CHAT_MSG_SYSTEM" then
			private.OnSystemLine(arg1)
		elseif event == "INSPECT_READY" then
			private.OnInspectReady(arg1)
		end
	end)
	pcall(hooksecurefunc, "StartDuel", private.OnChallenge)
	pcall(hooksecurefunc, "AcceptDuel", private.OnAccepted)
	-- An inspect someone else asks for (the inspect window, another addon) replaces ours: it's theirs to let go
	pcall(hooksecurefunc, "NotifyInspect", function()
		if private.asking then
			return
		end
		private.othersAt = GetTime()
		if private.inspect then
			private.inspect.taken = true
		end
	end)
	C_Timer.NewTicker(CHECK_SECONDS, function() Duels:Check() end)
end

---A value the client let us read, or nil for a hidden (secret) one.
function private.Readable(value)
	if value == nil or (issecretvalue and issecretvalue(value)) then
		return nil
	end
	return value
end

---A name to compare: lower case, any realm left off.
function private.Short(name)
	name = private.Readable(name)
	return type(name) == "string" and strlower(strmatch(name, "^([^%-]+)") or name) or nil
end



-- ============================================================================
-- The duel
-- ============================================================================

---Someone challenged us.
function private.OnChallenged(name, toTheDeath)
	local duel = private.duel
	-- The game may send both challenges for a duel to the death
	if duel and not duel.startAt and private.Short(duel.name) == private.Short(name) then
		duel.toTheDeath = duel.toTheDeath or toTheDeath or nil
		return
	end
	local guid = nil
	if GetDuelerInfo then
		local ok, dueler = pcall(GetDuelerInfo)
		guid = ok and private.Readable(dueler) or nil
	end
	private.Begin(name, guid, toTheDeath)
end

---We challenged someone: StartDuel(unit or name, _, toTheDeath). /duel with no name challenges the target.
function private.OnChallenge(target, _, toTheDeath)
	local unit = type(target) == "string" and target ~= "" and target or "target"
	local exists = private.Readable(UnitExists(unit))
	local guid = exists and private.Readable(UnitGUID(unit)) or nil
	private.Begin(guid and GetUnitName(unit, true) or target, guid, toTheDeath)
end

---We accepted a challenge: the fight starts after the countdown.
function private.OnAccepted()
	local duel = private.duel
	if duel and not duel.startAt then
		duel.startAt = GetServerTime() + COUNTDOWN_SECONDS
	end
end

---A new duel asked for (any earlier one not finished is let go).
function private.Begin(name, guid, toTheDeath)
	if type(guid) ~= "string" or not strfind(guid, "^Player%-") then
		guid = nil
	end
	local duel = { name = Store:CleanName(private.Readable(name)), guid = guid, requestedAt = GetServerTime(),
		toTheDeath = toTheDeath and true or nil, them = {} }
	private.duel = duel
	if guid then
		local _, class, _, race = GetPlayerInfoByGUID(guid)
		duel.them.class, duel.them.race = Store:CleanName(private.Readable(class)), Store:CleanName(private.Readable(race))
	end
	Duels:Check()
end

---Once a second while a duel is asked for or on: finds the opponent's unit, notes when the fight starts (they turn
---hostile) and their health and mana as last seen, and asks for their specialization until the game answers.
function Duels:Check()
	local duel = private.duel
	private.CheckInspectTimeout()
	if not duel or duel.endAt then
		return
	end
	local now = GetServerTime()
	if (not duel.startAt and now - duel.requestedAt > REQUEST_SECONDS) or (duel.startAt and now - duel.startAt > DUEL_SECONDS) then
		private.duel = nil
		return
	end
	local unit = private.FindUnit(duel)
	if not unit then
		if not duel.inspected then
			private.InspectNote(duel, "skipped: opponent not in view (target, focus, mouseover or a nameplate)")
		end
		return
	end
	private.Learn(duel, unit)
	-- Only the turn from friendly to hostile: someone hostile already (an enemy, a free-for-all area) isn't dueling us
	local hostile = UnitCanAttack ~= nil and private.Readable(UnitCanAttack("player", unit)) == true
	if not duel.startAt and hostile and duel.hostile == false then
		duel.startAt = now
	end
	duel.hostile = hostile
	if duel.startAt then
		private.ReadVitals(duel, duel.them, unit, "their")
	end
	private.TryInspect(duel, unit)
end

---The opponent's unit, if one is in view: by GUID once known, by name until then.
---@return string?
function private.FindUnit(duel)
	local units = { "target", "focus", "mouseover" }
	if C_NamePlate and C_NamePlate.GetNamePlates then
		local ok, plates = pcall(C_NamePlate.GetNamePlates)
		for _, plate in ipairs(ok and type(plates) == "table" and plates or {}) do
			if type(plate.namePlateUnitToken) == "string" then
				tinsert(units, plate.namePlateUnitToken)
			end
		end
	end
	local name = private.Short(duel.name)
	for _, unit in ipairs(units) do
		if private.Readable(UnitIsPlayer(unit)) then
			local guid = private.Readable(UnitGUID(unit))
			if guid and (guid == duel.guid or (not duel.guid and name and private.Short(GetUnitName(unit, true)) == name)) then
				return unit
			end
		end
	end
	if duel.guid then
		return nil
	end
	-- Neither GUID nor name known (this client may hide the challenger's name, and has no GetDuelerInfo): once the
	-- duel is accepted, the one player of our own faction we can attack is the opponent. A stealthed rogue is found
	-- once they show. Two or more such players (a free-for-all area) and nobody is guessed.
	if not duel.startAt then
		return nil
	end
	local mine, found, seen = private.Readable(UnitFactionGroup("player")), nil, {}
	for _, unit in ipairs(units) do
		local guid = private.Readable(UnitIsPlayer(unit)) and private.Readable(UnitGUID(unit)) or nil
		if guid and not seen[guid] and not private.Readable(UnitIsUnit(unit, "player"))
			and mine and private.Readable(UnitFactionGroup(unit)) == mine
			and UnitCanAttack ~= nil and private.Readable(UnitCanAttack("player", unit)) == true then
			seen[guid] = true
			if found then
				return nil
			end
			found = unit
		end
	end
	return found
end

---What the opponent's unit shows: GUID, class, race and level.
function private.Learn(duel, unit)
	local them = duel.them
	duel.guid = duel.guid or private.Readable(UnitGUID(unit))
	them.class = them.class or Store:CleanName(private.Readable((select(2, UnitClass(unit)))))
	them.race = them.race or Store:CleanName(private.Readable((select(2, UnitRace(unit)))))
	them.raceName = them.raceName or Store:CleanName(private.Readable((UnitRace(unit))))
	local level = private.Readable(UnitLevel(unit))
	-- A skull (-1) isn't a level
	if type(level) == "number" and level > 0 then
		them.level = level
	end
end

---A unit's health and mana as percentages, where the game lets us read them (mana only for those who use it). The
---game may hide either (a secret value; this client's UnitHealth is documented as always secret): what it hid is
---logged once a duel, for the in-game tests.
---@param who string "your" or "their", for the log
function private.ReadVitals(duel, into, unit, who)
	local health = private.Percent(duel, who.." health", UnitHealth(unit), UnitHealthMax(unit))
	into.health = health or into.health
	if UnitPowerType and UnitPower and UnitPowerMax and private.Readable(UnitPowerType(unit)) == MANA then
		into.mana = private.Percent(duel, who.." mana", UnitPower(unit, MANA), UnitPowerMax(unit, MANA)) or into.mana
	end
end

---Fills in health or mana not read yet, leaving what was read at the end.
function private.FillVitals(duel, into, unit, who)
	if into.health == nil or into.mana == nil then
		local now = {}
		private.ReadVitals(duel, now, unit, who)
		into.health, into.mana = into.health or now.health, into.mana or now.mana
	end
end

---A value as a percentage of its maximum, or nil (logged) when the game hides either.
function private.Percent(duel, what, value, maximum)
	local readValue, readMax = private.Readable(value), private.Readable(maximum)
	if type(readValue) == "number" and type(readMax) == "number" and readMax > 0 then
		return floor(readValue / readMax * 100 + 0.5)
	end
	duel.hidden = duel.hidden or {}
	if not duel.hidden[what] then
		duel.hidden[what] = true
		Wanted:Log("Duels: %s %s", what, (readValue == nil and value ~= nil or readMax == nil and maximum ~= nil) and "hidden by the game"
			or format("unreadable (%s of %s)", type(value), type(maximum)))
	end
	return nil
end

---A system line: the one that names the duel's winner, if it names us.
function private.OnSystemLine(text)
	local duel = private.duel
	text = private.Readable(text)
	if not duel or duel.result or type(text) ~= "string" then
		return
	end
	local mine = private.MyNames()
	for _, ending in ipairs(private.Endings()) do
		local captures = { strmatch(text, ending.pattern) }
		if #captures == #ending.order and #captures > 0 then
			local named = {}
			for i, capture in ipairs(captures) do
				named[ending.order[i]] = private.Short(capture)
			end
			local winner, loser = named[1], named[2]
			if winner and loser and mine[winner] ~= mine[loser] then
				duel.result = mine[winner] and "won" or "lost"
				duel.fled = ending.fled
				-- A duel sent to someone out of view may not have been seen starting
				duel.startAt = duel.startAt or duel.requestedAt
				return
			end
		end
	end
end

---Our own names as the game may write them in a system line: the first name, with the surname, and as a sender.
function private.MyNames()
	local name, surname = UnitName("player")
	local names = { [private.Short(Store:GetOrigin())] = true }
	if type(name) == "string" then
		names[strlower(name)] = true
		if type(surname) == "string" and surname ~= "" then
			names[strlower(name.." "..surname)] = true
		end
	end
	return names
end

---The lines that end a duel as patterns, with which capture is the winner (1) and the loser (2).
function private.Endings()
	if private.endings then
		return private.endings
	end
	private.endings = {}
	for _, ending in ipairs(ENDINGS) do
		local text = type(_G[ending.global]) == "string" and _G[ending.global] or ending.text
		local order = {}
		local pattern = gsub(text, "%%(%d?)%$?s", function(index)
			tinsert(order, tonumber(index) or #order + 1)
			return "\001"
		end)
		pattern = "^"..gsub(gsub(pattern, "[%^%$%(%)%.%[%]%*%+%-%?%%]", "%%%0"), "\001", "(.+)").."$"
		tinsert(private.endings, { pattern = pattern, order = order, fled = ending.fled })
	end
	return private.endings
end

---The duel is over (or a challenge was declined): what's left to read is read now, and the record is written once the
---winner's line has had time to come.
function private.OnFinished()
	local duel = private.duel
	if not duel or duel.endAt then
		return
	end
	duel.endAt = GetServerTime()
	local unit = private.FindUnit(duel)
	if unit then
		private.Learn(duel, unit)
		private.ReadVitals(duel, duel.them, unit, "their")
	end
	duel.me = {}
	private.ReadVitals(duel, duel.me, "player", "your")
	-- A duel to the death ends in a death, whatever the lines say
	duel.deadMe = private.Readable(UnitIsDeadOrGhost("player")) == true
	duel.deadThem = unit and private.Readable(UnitIsDeadOrGhost(unit)) == true or false
	-- Written even if a new challenge came meanwhile
	C_Timer.After(SETTLE_SECONDS, function()
		if private.duel == duel then
			private.duel = nil
		end
		private.Finish(duel)
	end)
end

---Writes the record of a duel that was fought. A challenge declined (never started, no winner) leaves nothing.
function private.Finish(duel)
	if duel.toTheDeath and not duel.result and duel.deadMe ~= duel.deadThem then
		duel.result = duel.deadThem and "won" or "lost"
		duel.startAt = duel.startAt or duel.requestedAt
	end
	if not duel.startAt or duel.startAt > duel.endAt then
		return
	end
	private.last = { guid = duel.guid, endedAt = duel.endAt, toTheDeath = duel.toTheDeath }
	local zone, x, y, mapId = Wanted.Recorder:GetPosition()
	local realZone = GetRealZoneText and private.Readable(GetRealZoneText())
	local origin = Store:GetOrigin()
	local me = duel.me
	-- What the game hid at the end is read again a moment later: it may hide it only during the fight
	private.FillVitals(duel, me, "player", "your")
	local unit = private.FindUnit(duel)
	if unit then
		private.FillVitals(duel, duel.them, unit, "their")
	end
	local level = private.Readable(UnitLevel("player"))
	me.guid = private.Readable(UnitGUID("player"))
	me.name = Store:CleanName(origin)
	me.class = Store:CleanName(private.Readable((select(2, UnitClass("player")))))
	me.race = Store:CleanName(private.Readable((select(2, UnitRace("player")))))
	me.raceName = Store:CleanName(private.Readable((UnitRace("player"))))
	me.level = type(level) == "number" and level > 0 and level or nil
	me.spec, me.specId = private.OwnSpec()
	me.loadout = private.OwnLoadout()
	local them = duel.them
	-- The name only of a Wanted user, and only when the game names the character so too: a hello can claim any GUID
	them.guid = duel.guid
	local wanted = Wanted.KeyBook:OriginOf(duel.guid)
	if Wanted.KeyBook:IsCharacter(wanted, duel.guid) then
		them.name = Store:CleanName(wanted)
	end
	local list = Wanted.db.duels
	tinsert(list, {
		id = format("%s:duel:%d", origin, duel.startAt),
		startAt = duel.startAt,
		endAt = duel.endAt,
		length = duel.endAt - duel.startAt,
		result = duel.result or "none",
		fled = duel.fled or nil,
		toTheDeath = duel.toTheDeath,
		zone = Store:CleanName(realZone ~= "" and realZone or zone),
		mapId = mapId,
		x = x,
		y = y,
		me = me,
		them = them,
	})
	while #list > Duels.MAX do
		tremove(list, 1)
	end
	Wanted.UI:Refresh()
	Wanted:Log("Duels: %s a duel against %s", duel.result or "no result in", Duels:Build(them))
end



-- ============================================================================
-- Specialization
-- ============================================================================

---The name of a specialization by its id ("Frost"), or nil.
function private.SpecName(specId)
	specId = private.Readable(specId)
	if type(specId) ~= "number" or specId <= 0 then
		return nil
	end
	local name
	if GetSpecializationNameForSpecID then
		local ok, found = pcall(GetSpecializationNameForSpecID, specId)
		name = ok and private.Readable(found) or nil
	end
	if not name and GetSpecializationInfoByID then
		local ok, _, found = pcall(GetSpecializationInfoByID, specId)
		name = ok and private.Readable(found) or nil
	end
	return type(name) == "string" and name ~= "" and Store:CleanName(name) or nil
end

---A specialization id the game gave, or nil.
function private.SpecId(specId)
	specId = private.Readable(specId)
	return type(specId) == "number" and specId > 0 and specId or nil
end

---The player's own specialization: its name ("Arms") and id, or nil before one is chosen. Forever's talents are
---retail's: a chosen specialization and a talent loadout, not points in three trees.
---@return string? name
---@return number? specId
function private.OwnSpec()
	local info = C_SpecializationInfo
	if not (info and info.GetSpecialization and info.GetSpecializationInfo) then
		return nil, nil
	end
	local ok, index = pcall(info.GetSpecialization)
	index = ok and private.Readable(index)
	if type(index) ~= "number" or index <= 0 then
		return nil, nil
	end
	local okInfo, specId = pcall(info.GetSpecializationInfo, index)
	specId = okInfo and private.SpecId(specId) or nil
	return private.SpecName(specId), specId
end

---The specialization of the unit our inspect was answered for: its name and id, or nil.
---@return string? name
---@return number? specId
function private.InspectSpec(unit)
	local info = C_SpecializationInfo
	if not (info and info.GetInspectSpecialization) then
		return nil, nil
	end
	local ok, specId = pcall(info.GetInspectSpecialization, unit)
	specId = ok and private.SpecId(specId) or nil
	return private.SpecName(specId), specId
end

---A talent loadout as the game exports it (the import string the talents frame copies), kept only when it is a plain
---printable string of sane length: no spaces, no escape codes, at most MAX_LOADOUT bytes.
function private.CleanLoadout(text)
	text = private.Readable(text)
	if type(text) ~= "string" or #text > MAX_LOADOUT or not strfind(text, "^[!-{}~]+$") then
		return nil
	end
	return text
end

---The player's own active talent loadout, or nil.
function private.OwnLoadout()
	if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits and C_Traits.GenerateImportString) then
		return nil
	end
	local ok, configID = pcall(C_ClassTalents.GetActiveConfigID)
	configID = ok and private.Readable(configID)
	if type(configID) ~= "number" then
		return nil
	end
	local okExport, text = pcall(C_Traits.GenerateImportString, configID)
	return okExport and private.CleanLoadout(text) or nil
end

---The talent loadout of the unit our inspect was answered for (read before the inspect is let go), or nil.
function private.InspectLoadout(unit)
	if not (C_Traits and C_Traits.GenerateInspectImportString) then
		return nil
	end
	local ok, text = pcall(C_Traits.GenerateInspectImportString, unit)
	return ok and private.CleanLoadout(text) or nil
end

---Asks for the opponent's specialization, unless anyone else's inspect may still be waiting (the inspect window's, another
---addon's): the game answers one at a time, and ours would take theirs.
function private.TryInspect(duel, unit)
	if duel.inspected or private.inspect then
		return
	end
	if (duel.inspectTries or 0) >= INSPECT_TRIES then
		return private.InspectNote(duel, format("given up after %d tries", INSPECT_TRIES))
	elseif not duel.guid then
		return private.InspectNote(duel, "skipped: no GUID for the opponent")
	elseif GetTime() - private.othersAt < OTHERS_SECONDS then
		return private.InspectNote(duel, "skipped: someone else's inspect may be waiting")
	elseif private.PlayerInspecting() then
		return private.InspectNote(duel, "skipped: the inspect window or talents frame is open")
	elseif not (NotifyInspect and CanInspect) then
		return private.InspectNote(duel, "skipped: no inspect functions in this client")
	end
	local ok, can = pcall(CanInspect, unit, false)
	if not ok or not private.Readable(can) then
		return private.InspectNote(duel, "skipped: the game won't inspect them (CanInspect)")
	end
	duel.inspectTries = (duel.inspectTries or 0) + 1
	private.asking = true
	local asked = pcall(NotifyInspect, unit)
	private.asking = false
	if asked then
		private.inspect = { guid = duel.guid, at = GetTime() }
		duel.inspectNote = nil
		Wanted:Log("Duels: inspect asked (try %d)", duel.inspectTries)
	else
		private.InspectNote(duel, "NotifyInspect failed")
	end
end

---Logs why the opponent's inspect wasn't asked, once a reason (Check runs every second).
function private.InspectNote(duel, note)
	if duel.inspectNote ~= note then
		duel.inspectNote = note
		Wanted:Log("Duels: inspect %s", note)
	end
end

---Whether the player is looking at someone's inspect: the inspect window, or the talents frame showing another
---player's talents (Blizzard's inspect window doesn't let its inspect go then either).
function private.PlayerInspecting()
	return (InspectFrame and InspectFrame:IsShown()) or (PlayerSpellsFrame and PlayerSpellsFrame.IsInspecting and PlayerSpellsFrame:IsInspecting()) or false
end

---The game's answer to an inspect. Read only when it's ours: after someone else's question the data is theirs.
function private.OnInspectReady(guid)
	local inspect = private.inspect
	if not inspect or private.Readable(guid) ~= inspect.guid then
		return
	end
	if inspect.taken then
		Wanted:Log("Duels: inspect answered after someone else asked one; not read")
		return
	end
	local duel = private.duel
	local unit = duel and duel.guid == guid and private.FindUnit(duel)
	if unit then
		duel.them.spec, duel.them.specId = private.InspectSpec(unit)
		duel.them.loadout = private.InspectLoadout(unit)
		duel.inspected = true
		Wanted:Log("Duels: inspect answered: %s", duel.them.spec or "no specialization")
	else
		Wanted:Log("Duels: inspect answered with the opponent out of view; not read")
	end
	private.ReleaseInspect()
end

---An inspect not answered in time is given up.
function private.CheckInspectTimeout()
	if private.inspect and GetTime() - private.inspect.at > INSPECT_TIMEOUT then
		Wanted:Log("Duels: inspect timed out%s", private.inspect.taken and " (someone else asked one since)" or "")
		private.ReleaseInspect()
	end
end

---Done with our inspect: let it go, unless it isn't ours any more (someone asked since, or the inspect window is
---showing one).
function private.ReleaseInspect()
	local inspect = private.inspect
	private.inspect = nil
	if not inspect or inspect.taken or private.PlayerInspecting() then
		return
	end
	if ClearInspectPlayer then
		pcall(ClearInspectPlayer)
	end
end



-- ============================================================================
-- Reading
-- ============================================================================

---Whether a player is in a duel to the death under way or one that just ended (the player themself or their
---opponent): their death or kill then is the duel's, not world PvP. A normal duel ends at 1 health and kills nobody,
---so a death during one is world PvP (an enemy ganking the duellists) and counts.
---@param guid string?
---@return boolean
function Duels:Involves(guid)
	if type(guid) ~= "string" then
		return false
	end
	local me = UnitGUID("player")
	local duel = private.duel
	if duel and duel.startAt and duel.toTheDeath and (guid == duel.guid or guid == me) then
		return true
	end
	local last = private.last
	return last ~= nil and last.toTheDeath and GetServerTime() - last.endedAt <= INVOLVED_SECONDS and (guid == last.guid or guid == me) or false
end

---How a duellist reads: the Wanted user's name, otherwise spec and class ("Frost Mage", or "Mage" with no spec known).
---@param side table a record's me or them
---@return string
function Duels:Opponent(side)
	if type(side) ~= "table" then
		return "?"
	end
	if type(side.name) == "string" then
		return side.name
	end
	return Duels:Build(side)
end

---A duellist's class and spec, never their name: "Frost Mage", "Mage" with no spec known. A spec named after its
---class (this client's specs below the level for a real one: "Rogue") is just the class.
---@param side table
---@return string
function Duels:Build(side)
	local class = type(side) == "table" and type(side.class) == "string" and Wanted.Theme:ClassLabel(side.class) or "Unknown class"
	local spec = type(side) == "table" and type(side.spec) == "string" and side.spec or nil
	return spec and strlower(spec) ~= strlower(class) and (spec.." "..class) or class
end

-- Race names for duels recorded before the game's own name was kept (its file names: Scourge is Undead)
local RACE_NAMES = { Scourge = "Undead", NightElf = "Night Elf" }

---A duellist in full, never their name: "Level 21 Skyborne Druid", "Level 58 Orc Affliction Warlock". Parts the
---record lacks are left out.
---@param side table
---@return string
function Duels:Describe(side)
	if type(side) ~= "table" then
		return Duels:Build(side)
	end
	local race = type(side.raceName) == "string" and side.raceName or type(side.race) == "string" and (RACE_NAMES[side.race] or side.race) or nil
	local level = type(side.level) == "number" and ("Level "..side.level) or nil
	local parts, all = {}, { level or false, race or false, Duels:Build(side) }
	for i = 1, 3 do
		if all[i] then
			parts[#parts + 1] = all[i]
		end
	end
	return table.concat(parts, " ")
end

---The player's duels added up: the record overall, the record against each class and spec (most faced first), the
---record as each of their own builds (one a talent loadout where the record has one, else one a specialization), and
---every duel newest first. Records not in the expected shape are passed over.
---@return table { won, lost, total, matchups = { { label, class, won, lost, games } }, builds = (the same), recent }
function Duels:GetSheet()
	local sheet = { won = 0, lost = 0, total = 0, matchups = {}, builds = {}, recent = {} }
	local byMatchup, byBuild = {}, {}
	local function Add(rows, index, side, record, key)
		local label = Duels:Build(side)
		key = key or label
		local row = index[key]
		if not row then
			row = { label = label, class = side.class, won = 0, lost = 0, games = 0, loadout = key ~= label and key or nil }
			index[key] = row
			tinsert(rows, row)
		end
		row.games = row.games + 1
		row.won = row.won + (record.result == "won" and 1 or 0)
		row.lost = row.lost + (record.result == "lost" and 1 or 0)
	end
	for _, record in ipairs(Wanted.db.duels) do
		if type(record) == "table" and type(record.me) == "table" and type(record.them) == "table" and type(record.startAt) == "number" then
			sheet.total = sheet.total + 1
			sheet.won = sheet.won + (record.result == "won" and 1 or 0)
			sheet.lost = sheet.lost + (record.result == "lost" and 1 or 0)
			Add(sheet.matchups, byMatchup, record.them, record)
			Add(sheet.builds, byBuild, record.me, record, type(record.me.loadout) == "string" and record.me.loadout or nil)
			tinsert(sheet.recent, record)
		end
	end
	-- Several builds of one specialization: numbered as first played, "(build unknown)" for duels from before loadouts
	local perSpec = {}
	for _, row in ipairs(sheet.builds) do
		perSpec[row.label] = (perSpec[row.label] or 0) + 1
	end
	local numbered = {}
	for _, row in ipairs(sheet.builds) do
		if perSpec[row.label] > 1 then
			local spec = row.label
			if row.loadout then
				numbered[spec] = (numbered[spec] or 0) + 1
				row.label = format("%s (build %d)", spec, numbered[spec])
			else
				row.label = spec.." (build unknown)"
			end
		end
	end
	local function ByGames(a, b)
		if a.games ~= b.games then
			return a.games > b.games
		end
		return a.label < b.label
	end
	sort(sheet.matchups, ByGames)
	sort(sheet.builds, ByGames)
	sort(sheet.recent, function(a, b) return a.startAt > b.startAt end)
	return sheet
end
