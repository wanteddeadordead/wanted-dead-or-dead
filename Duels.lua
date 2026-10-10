-- Wanted: duels. Each duel the player fights is kept for their own matchup sheet: who it was against (class, race,
-- level and talent build, by inspect), their own build, who won, how long it took, where, and how much health and
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
-- Talent trees read at most
local MAX_TREES = 4
local MANA = 0
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
---hostile) and their health and mana as last seen, and asks for their talents until the game answers.
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
		private.ReadVitals(duel.them, unit)
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
	return nil
end

---What the opponent's unit shows: GUID, class, race and level.
function private.Learn(duel, unit)
	local them = duel.them
	duel.guid = duel.guid or private.Readable(UnitGUID(unit))
	them.class = them.class or Store:CleanName(private.Readable((select(2, UnitClass(unit)))))
	them.race = them.race or Store:CleanName(private.Readable((select(2, UnitRace(unit)))))
	local level = private.Readable(UnitLevel(unit))
	-- A skull (-1) isn't a level
	if type(level) == "number" and level > 0 then
		them.level = level
	end
end

---A unit's health and mana as percentages, where the game lets us read them (mana only for those who use it).
function private.ReadVitals(into, unit)
	local health, healthMax = private.Readable(UnitHealth(unit)), private.Readable(UnitHealthMax(unit))
	if type(health) == "number" and type(healthMax) == "number" and healthMax > 0 then
		into.health = floor(health / healthMax * 100 + 0.5)
	end
	if UnitPowerType and UnitPower and UnitPowerMax and private.Readable(UnitPowerType(unit)) == MANA then
		local mana, manaMax = private.Readable(UnitPower(unit, MANA)), private.Readable(UnitPowerMax(unit, MANA))
		if type(mana) == "number" and type(manaMax) == "number" and manaMax > 0 then
			into.mana = floor(mana / manaMax * 100 + 0.5)
		end
	end
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
		private.ReadVitals(duel.them, unit)
	end
	duel.me = {}
	private.ReadVitals(duel.me, "player")
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
	local level = private.Readable(UnitLevel("player"))
	me.guid = private.Readable(UnitGUID("player"))
	me.name = Store:CleanName(origin)
	me.class = Store:CleanName(private.Readable((select(2, UnitClass("player")))))
	me.race = Store:CleanName(private.Readable((select(2, UnitRace("player")))))
	me.level = type(level) == "number" and level > 0 and level or nil
	me.talents, me.spec = private.ReadTalents(false)
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
	Wanted:Log("Duels: %s a duel against %s %s", duel.result or "no result in", tostring(them.spec), tostring(them.class))
end



-- ============================================================================
-- Talents
-- ============================================================================

---Points in each talent tree, and the name of the tree with the most ("Frost"; nil with no points spent), for the
---player or the unit last inspected.
---@param isInspect boolean
---@return number[]? points
---@return string? spec
function private.ReadTalents(isInspect)
	local info = C_SpecializationInfo
	if not (info and info.GetSpecializationInfo) then
		return nil, nil
	end
	local points, spec, most = {}, nil, 0
	for tree = 1, MAX_TREES do
		local ok, _, name, _, _, _, _, spent = pcall(info.GetSpecializationInfo, tree, isInspect)
		name, spent = ok and private.Readable(name), ok and private.Readable(spent)
		if type(name) ~= "string" or type(spent) ~= "number" then
			break
		end
		tinsert(points, spent)
		if spent > most then
			spec, most = name, spent
		end
	end
	if #points == 0 then
		return nil, nil
	end
	return points, Store:CleanName(spec)
end

---Asks for the opponent's talents, unless anyone else's inspect may still be waiting (the inspect window's, another
---addon's): the game answers one at a time, and ours would take theirs.
function private.TryInspect(duel, unit)
	if duel.them.talents or private.inspect or (duel.inspectTries or 0) >= INSPECT_TRIES or not duel.guid then
		return
	end
	if GetTime() - private.othersAt < OTHERS_SECONDS or private.PlayerInspecting() then
		return
	end
	if not (NotifyInspect and CanInspect) then
		return
	end
	local ok, can = pcall(CanInspect, unit, false)
	if not ok or not private.Readable(can) then
		return
	end
	duel.inspectTries = (duel.inspectTries or 0) + 1
	private.asking = true
	local asked = pcall(NotifyInspect, unit)
	private.asking = false
	if asked then
		private.inspect = { guid = duel.guid, at = GetTime() }
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
	if not inspect or inspect.taken or private.Readable(guid) ~= inspect.guid then
		return
	end
	local duel = private.duel
	if duel and duel.guid == guid then
		duel.them.talents, duel.them.spec = private.ReadTalents(true)
	end
	private.ReleaseInspect()
end

---An inspect not answered in time is given up.
function private.CheckInspectTimeout()
	if private.inspect and GetTime() - private.inspect.at > INSPECT_TIMEOUT then
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

---A duellist's class and spec, never their name: "Frost Mage", "Mage" with no spec known.
---@param side table
---@return string
function Duels:Build(side)
	local class = type(side) == "table" and type(side.class) == "string" and Wanted.Theme:ClassLabel(side.class) or "Unknown class"
	return type(side) == "table" and type(side.spec) == "string" and (side.spec.." "..class) or class
end

---The player's duels added up: the record overall, the record against each class and spec (most faced first), the
---record as each of their own builds, and every duel newest first. Records not in the expected shape are passed over.
---@return table { won, lost, total, matchups = { { label, class, won, lost, games } }, builds = (the same), recent }
function Duels:GetSheet()
	local sheet = { won = 0, lost = 0, total = 0, matchups = {}, builds = {}, recent = {} }
	local byMatchup, byBuild = {}, {}
	local function Add(rows, index, side, record)
		local label = Duels:Build(side)
		local row = index[label]
		if not row then
			row = { label = label, class = side.class, won = 0, lost = 0, games = 0 }
			index[label] = row
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
			Add(sheet.builds, byBuild, record.me, record)
			tinsert(sheet.recent, record)
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
