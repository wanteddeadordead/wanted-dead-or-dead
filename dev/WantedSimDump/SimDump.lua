-- Wanted SimDump: a development tool, never released (.pkgmeta leaves dev/ out). /wanted simdump reads the spell and
-- item IDs the damage simulator wrote to simdump-ids.lua (WantedSimDumpIDs = { spells = {...}, items = {...} }),
-- records what this client says about each one, with the character's own stats, talents and gear, and keeps it in
-- WantedSimDumpDB, saved on the next /reload.

local Wanted = _G.Wanted
if not Wanted then
	return
end

local PER_FRAME = 10 -- IDs asked for, and IDs recorded, each frame
local MAX_WAITING = 60 -- IDs whose data may be loading at once
local RETRY_SECONDS = 3 -- an ID still loading is asked for again this often
local TEXT_SECONDS = 3 -- a loaded spell with an empty description is recorded after this (some have none)
local WAIT_SECONDS = 20 -- an ID still not loaded after this is recorded as it is, marked incomplete

local frame = CreateFrame("Frame")
local queue, waiting = {}, {}
local nextIndex, waitingCount, doneCount, incompleteCount, progressStep, nextProgress = 1, 0, 0, 0, 1, 1

---A tooltip's lines as left and right text, from C_TooltipInfo
local function TooltipLines(data)
	if type(data) ~= "table" or type(data.lines) ~= "table" then
		return nil
	end
	local lines = {}
	for i, line in ipairs(data.lines) do
		lines[i] = { left = line.leftText, right = line.rightText, type = line.type }
	end
	return lines
end

local function SpellRecord(id)
	if not C_Spell.DoesSpellExist(id) then
		return { missing = true }
	end
	local info = C_Spell.GetSpellInfo(id)
	local cooldown = C_Spell.GetSpellCooldown(id)
	local costs = {}
	for _, cost in ipairs(C_Spell.GetSpellPowerCost(id) or {}) do
		tinsert(costs, { power = cost.name, cost = cost.cost, minCost = cost.minCost, percent = cost.costPercent, percentPerSecond = cost.costPerSec })
	end
	return {
		name = info and info.name,
		rank = C_Spell.GetSpellSubtext(id),
		description = C_Spell.GetSpellDescription(id),
		castTime = info and info.castTime, -- milliseconds
		minRange = info and info.minRange,
		maxRange = info and info.maxRange,
		cooldownNow = cooldown and cooldown.duration, -- the cooldown running now (0 when ready); the tooltip has the spell's own
		costs = costs,
		known = C_SpellBook.IsSpellKnown(id),
		tooltip = TooltipLines(C_TooltipInfo.GetSpellByID(id)),
	}
end

local function ItemRecord(id)
	local name, link, quality, itemLevel, minLevel, itemType, subType, _, equipLoc, _, _, classID, subclassID, bindType = C_Item.GetItemInfo(id)
	return {
		name = name,
		link = link,
		quality = quality,
		itemLevel = itemLevel,
		minLevel = minLevel,
		type = itemType,
		subType = subType,
		equipLoc = equipLoc,
		classID = classID,
		subclassID = subclassID,
		bindType = bindType,
		stats = link and C_Item.GetItemStats(link) or nil,
		tooltip = TooltipLines(C_TooltipInfo.GetItemByID(id)),
	}
end

local function Request(entry)
	if entry.kind == "spells" then
		C_Spell.RequestLoadSpellData(entry.id)
	else
		C_Item.RequestLoadItemDataByID(entry.id)
	end
end

local function IsReady(entry, now)
	if entry.kind == "items" then
		return C_Item.IsItemDataCachedByID(entry.id)
	end
	if not C_Spell.DoesSpellExist(entry.id) then
		return true
	end
	if not C_Spell.IsSpellDataCached(entry.id) then
		return false
	end
	-- The description can arrive after the rest of the spell's data (SPELL_TEXT_UPDATE)
	return (C_Spell.GetSpellDescription(entry.id) or "") ~= "" or now - entry.started > TEXT_SECONDS
end

local function Record(entry, complete)
	local record = entry.kind == "spells" and SpellRecord(entry.id) or ItemRecord(entry.id)
	if not complete then
		record.incomplete = true
		incompleteCount = incompleteCount + 1
	end
	WantedSimDumpDB[entry.kind][entry.id] = record
	doneCount = doneCount + 1
end

local function Finish()
	frame:SetScript("OnUpdate", nil)
	WantedSimDumpDB.finished = time()
	local spells, items = 0, 0
	for _ in pairs(WantedSimDumpDB.spells) do spells = spells + 1 end
	for _ in pairs(WantedSimDumpDB.items) do items = items + 1 end
	Wanted:Print("SimDump: done, %d spells and %d items (%d incomplete). /reload to save.", spells, items, incompleteCount)
end

local function Step()
	local now = GetTime()
	local asked = 0
	while queue[nextIndex] and asked < PER_FRAME and waitingCount < MAX_WAITING do
		local entry = queue[nextIndex]
		nextIndex = nextIndex + 1
		entry.started, entry.asked = now, now
		Request(entry)
		waiting[entry] = true
		waitingCount = waitingCount + 1
		asked = asked + 1
	end
	local recorded = 0
	for entry in pairs(waiting) do
		if recorded >= PER_FRAME then
			break
		end
		local ready = IsReady(entry, now)
		if ready or now - entry.started > WAIT_SECONDS then
			Record(entry, ready)
			waiting[entry] = nil
			waitingCount = waitingCount - 1
			recorded = recorded + 1
		elseif now - entry.asked > RETRY_SECONDS then
			entry.asked = now
			Request(entry)
		end
	end
	if doneCount >= nextProgress and doneCount < #queue then
		Wanted:Print("SimDump: %d of %d.", doneCount, #queue)
		nextProgress = nextProgress + progressStep
	end
	if doneCount >= #queue then
		Finish()
	end
end

-- ============================================================================
-- The character: its stats, talents, skills and gear as the client works them out, for the simulator to start from
-- ============================================================================

local STAT_NAMES = { "strength", "agility", "stamina", "intellect", "spirit" }
local SCHOOL_NAMES = { "physical", "holy", "fire", "nature", "frost", "shadow", "arcane" }

---A unit's five stats: base (before gear and buffs) and total, with the buffs either way
local function UnitStats(unit)
	local stats = {}
	for i, name in ipairs(STAT_NAMES) do
		local base, total, plus, minus = UnitStat(unit, i)
		stats[name] = { base = base, total = total, plus = plus, minus = minus }
	end
	return stats
end

---Attack power from UnitAttackPower or UnitRangedAttackPower: base plus buffs either way
local function AttackPower(base, plus, minus)
	return { base = base, plus = plus, minus = minus, total = base and base + (plus or 0) + (minus or 0) }
end

local function Armor(unit)
	local base, effective, real, bonus = UnitArmor(unit)
	return { base = base, effective = effective, real = real, bonus = bonus }
end

---Weapon damage and speed from UnitDamage, UnitRangedDamage and UnitAttackSpeed
local function Weapons(unit)
	local minMain, maxMain, minOff, maxOff, plus, minus, percent = UnitDamage(unit)
	local mainSpeed, offSpeed = UnitAttackSpeed(unit)
	local weapons = {
		mainHand = { min = minMain, max = maxMain, speed = mainSpeed },
		offHand = offSpeed and { min = minOff, max = maxOff, speed = offSpeed } or nil,
		meleeBonus = { plus = plus, minus = minus, percent = percent },
	}
	if unit == "player" then
		local speed, minRanged, maxRanged, rangedPlus, rangedMinus, rangedPercent = UnitRangedDamage(unit)
		weapons.ranged = { min = minRanged, max = maxRanged, speed = speed, plus = rangedPlus, minus = rangedMinus, percent = rangedPercent }
	end
	return weapons
end

---Copies a list of plain tables (the API's structures) so they can be saved
local function CopyList(list)
	local copy = {}
	for i, item in ipairs(list or {}) do
		copy[i] = {}
		for key, value in pairs(item) do
			if type(value) ~= "table" then
				copy[i][key] = value
			end
		end
	end
	return copy
end

---The active talent loadout: points per tree and each talent taken with its rank. This client has no talent
---export string, so the loadout is walked through C_Traits the way its talent frame does.
local function Talents()
	local specGroup = C_SpecializationInfo.GetActiveSpecGroup()
	local configID = C_SpecializationInfo.GetCombatConfigIDForSpecGroup(specGroup)
	local config = configID and C_Traits.GetConfigInfo(configID)
	local treeID = config and config.treeIDs and config.treeIDs[1]
	if not treeID then
		return { specGroup = specGroup, configID = configID }
	end
	local talents = { specGroup = specGroup, configID = configID, treeID = treeID, trees = {}, taken = {} }
	local trees, groupIDs = {}, {}
	for _, display in ipairs(C_Traits.GetGroupDisplayInfoByTreeID(treeID) or {}) do
		local tree = { groupID = display.groupID, name = display.displayName, skillLineID = display.skillLineID, order = display.orderIndex, points = 0 }
		tinsert(talents.trees, tree)
		trees[display.groupID] = tree
		tinsert(groupIDs, display.groupID)
	end
	for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
		local node = C_Traits.GetNodeInfo(configID, nodeID)
		if node and ((node.ranksPurchased or 0) > 0 or (node.activeRank or 0) > 0) then
			local entryID = node.activeEntry and node.activeEntry.entryID
			local entry = entryID and C_Traits.GetEntryInfo(configID, entryID)
			local definition = entry and C_Traits.GetDefinitionInfo(entry.definitionID)
			local spellID = definition and definition.spellID
			tinsert(talents.taken, { nodeID = nodeID, entryID = entryID, spellID = spellID, name = spellID and C_Spell.GetSpellName(spellID),
				rank = node.activeRank, ranksPurchased = node.ranksPurchased, maxRanks = node.maxRanks, groupIDs = node.groupIDs })
			for _, groupID in ipairs(node.groupIDs or {}) do
				if trees[groupID] then
					trees[groupID].points = trees[groupID].points + (node.ranksPurchased or 0)
				end
			end
		end
	end
	for _, info in ipairs(#groupIDs > 0 and C_Traits.GetGroupCurrencyInfo(configID, groupIDs) or {}) do
		if trees[info.traitNodeGroupID] then
			trees[info.traitNodeGroupID].currency = CopyList(info.currencyInfos)
		end
	end
	talents.currency = CopyList(C_Traits.GetTreeCurrencyInfo(configID, treeID, false))
	return talents
end

---Skill lines with their ranks (weapon skills, defense). Lines under a collapsed header in the Skills window are not listed.
local function Skills()
	local skills = {}
	for index = 1, C_SkillInfo.GetNumSkillLines() do
		local info = C_SkillInfo.GetSkillLineInfo(index)
		if info and not info.isHeader then
			tinsert(skills, { skillID = info.skillID, name = info.name, rank = info.rank, modifier = info.modifier, maxRank = info.maxRank, category = info.skillLineCategoryID })
		end
	end
	return skills
end

local function Pet()
	if not UnitExists("pet") then
		return nil
	end
	local family, familyID = UnitCreatureFamily("pet")
	return {
		name = UnitName("pet"),
		level = UnitLevel("pet"),
		family = family,
		familyID = familyID,
		stats = UnitStats("pet"),
		attackPower = AttackPower(UnitAttackPower("pet")),
		armor = Armor("pet"),
		health = UnitHealthMax("pet"),
		power = UnitPowerMax("pet"),
		weapons = Weapons("pet"),
	}
end

local function Character()
	local _, class = UnitClass("player")
	local _, race = UnitRace("player")
	local character = {
		name = (UnitName("player")),
		level = UnitLevel("player"),
		class = class,
		race = race,
		talents = Talents(),
		stats = UnitStats("player"),
		attackPower = AttackPower(UnitAttackPower("player")),
		rangedAttackPower = AttackPower(UnitRangedAttackPower("player")),
		armor = Armor("player"),
		health = UnitHealthMax("player"),
		power = {
			mana = UnitPowerMax("player", Enum.PowerType.Mana),
			rage = UnitPowerMax("player", Enum.PowerType.Rage),
			energy = UnitPowerMax("player", Enum.PowerType.Energy),
		},
		crit = { melee = GetCritChance(), ranged = GetRangedCritChance(), spell = GetSpellCritChance() },
		hit = { melee = GetHitModifier(), ranged = GetRangedHitModifier(), spell = GetSpellHitModifier() },
		hitFromRating = { melee = GetCombatRatingBonus(CR_HIT_MELEE), ranged = GetCombatRatingBonus(CR_HIT_RANGED), spell = GetCombatRatingBonus(CR_HIT_SPELL) },
		haste = { melee = GetMeleeHaste(), ranged = GetRangedHaste(), spell = UnitSpellHaste("player") },
		dodge = GetDodgeChance(),
		parry = GetParryChance(),
		block = GetBlockChance(),
		shieldBlock = GetShieldBlock(),
		spellPower = {},
		healing = GetSpellBonusHealing(),
		spellPenetration = GetSpellPenetration(),
		armorPenetration = GetArmorPenetration(),
		skills = Skills(),
		weapons = Weapons("player"),
		gear = {},
		ammoItemID = GetInventoryItemID("player", 0),
		pet = Pet(),
	}
	local expertiseMain, expertiseOff, expertiseRanged = GetExpertise()
	character.expertise = { mainHand = expertiseMain, offHand = expertiseOff, ranged = expertiseRanged }
	local regenBase, regenCasting = GetManaRegen()
	character.manaRegen = { base = regenBase, casting = regenCasting } -- per second
	-- This client's GetSpellCritChance takes no school (PlayerScriptDocumentation); spell.crit has the one figure
	for school, name in ipairs(SCHOOL_NAMES) do
		character.spellPower[name] = GetSpellBonusDamage(school)
	end
	for slot = 0, 19 do
		character.gear[slot] = GetInventoryItemID("player", slot)
	end
	return character
end

Wanted:RegisterCommand("simdump", "Development: records the client's spell and item data for the damage simulator: /wanted simdump", function()
	if frame:GetScript("OnUpdate") then
		Wanted:Print("SimDump: already running, %d of %d.", doneCount, #queue)
		return
	end
	local ids = WantedSimDumpIDs
	if type(ids) ~= "table" then
		Wanted:Print("SimDump: no ID list. Is simdump-ids.lua in the WantedSimDump folder?")
		return
	end
	queue, waiting = {}, {}
	local queuedItems = {}
	for _, kind in ipairs({ "spells", "items" }) do
		for _, id in ipairs(ids[kind] or {}) do
			tinsert(queue, { kind = kind, id = id })
			if kind == "items" then
				queuedItems[id] = true
			end
		end
	end
	-- The equipped gear and ammo too: the simulator needs each weapon's own damage and speed (UnitDamage includes attack power)
	for slot = 0, 19 do
		local id = GetInventoryItemID("player", slot)
		if id and not queuedItems[id] then
			queuedItems[id] = true
			tinsert(queue, { kind = "items", id = id })
		end
	end
	local _, class = UnitClass("player")
	local version, build, buildDate, interface = GetBuildInfo()
	WantedSimDumpDB = {
		level = UnitLevel("player"),
		class = class,
		build = version.."."..build,
		buildDate = buildDate,
		interface = interface,
		started = time(),
		serverTime = GetServerTime(),
		date = date("%Y-%m-%d %H:%M:%S"),
		spells = {},
		items = {},
	}
	-- One stat the client won't give shouldn't cost the spell and item dump
	local ok, character = pcall(Character)
	if ok then
		WantedSimDumpDB.character = character
		Wanted:Print("SimDump: character captured, level %d %s.", character.level or 0, character.class or "?")
	else
		WantedSimDumpDB.characterError = tostring(character)
		Wanted:Print("SimDump: couldn't capture the character: %s", tostring(character))
	end
	nextIndex, waitingCount, doneCount, incompleteCount = 1, 0, 0, 0
	progressStep = max(1, floor(#queue / 10))
	nextProgress = progressStep
	Wanted:Print("SimDump: reading %d spells and items.", #queue)
	if #queue == 0 then
		Finish()
		return
	end
	frame:SetScript("OnUpdate", Step)
end)
