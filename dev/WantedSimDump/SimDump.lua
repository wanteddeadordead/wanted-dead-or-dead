-- Wanted SimDump: a development tool, never released (.pkgmeta leaves dev/ out). /wanted simdump reads the spell and
-- item IDs the damage simulator wrote to simdump-ids.lua (WantedSimDumpIDs = { spells = {...}, items = {...} }),
-- records what this client says about each one and keeps it in WantedSimDumpDB, saved on the next /reload.

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
	for _, kind in ipairs({ "spells", "items" }) do
		for _, id in ipairs(ids[kind] or {}) do
			tinsert(queue, { kind = kind, id = id })
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
		date = date("%Y-%m-%d %H:%M:%S"),
		spells = {},
		items = {},
	}
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
