-- Wanted: the PvP gear catalogue. The rank vendors (Hall of Legends in Orgrimmar, Champion's Hall in Stormwind) sell
-- the gear; the rank rewards only describe it. When one opens, every item that costs Honor Points or needs a rank is
-- kept (WantedDB.pvpGear, per faction): slot, type, level, rank, honor and Marks of Honor. Then, for this character:
-- what it can use (its armour and weapon skills; Forever has no specs) and what it's still missing. Starred items are
-- WantedDB.gearGoals, per character (docs/gear-tab-plan.md).

local _, Wanted = ...
local GearCatalog = Wanted:NewModule("GearCatalog")
local BlizzRank = Wanted.BlizzRank
local private = { listeners = {}, allRead = {} } -- allRead: vendors read with the "All" filter this session
local KEEP_DAYS = 60 -- an item no vendor has shown in this long is dropped when a vendor next opens
local MAX_ITEMS = 120 -- a vendor's items read at most

-- Item class and subclass numbers (the game's, in any language)
local ARMOR, WEAPON = 4, 2
local ARMOR_MISC, ARMOR_CLOTH, ARMOR_LEATHER, ARMOR_MAIL, ARMOR_PLATE, ARMOR_SHIELD = 0, 1, 2, 3, 4, 6
-- Each class's best armour, the shield-users and the weapon skills it can learn (classic rules), by class ID
local CLASSES = {
	[1] = { armor = ARMOR_PLATE, shield = true, weapons = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 15, 16, 18 } }, -- Warrior
	[2] = { armor = ARMOR_PLATE, shield = true, holdable = true, weapons = { 0, 1, 4, 5, 6, 7, 8 } }, -- Paladin
	[3] = { armor = ARMOR_MAIL, weapons = { 0, 1, 2, 3, 6, 7, 8, 10, 13, 15, 16, 18 } }, -- Hunter
	[4] = { armor = ARMOR_LEATHER, weapons = { 2, 3, 4, 7, 13, 15, 16, 18 } }, -- Rogue
	[5] = { armor = ARMOR_CLOTH, holdable = true, weapons = { 4, 10, 15, 19 } }, -- Priest
	[7] = { armor = ARMOR_MAIL, shield = true, holdable = true, weapons = { 0, 1, 4, 5, 10, 13, 15 } }, -- Shaman
	[8] = { armor = ARMOR_CLOTH, holdable = true, weapons = { 7, 10, 15, 19 } }, -- Mage
	[9] = { armor = ARMOR_CLOTH, holdable = true, weapons = { 7, 10, 15, 19 } }, -- Warlock
	[11] = { armor = ARMOR_LEATHER, holdable = true, weapons = { 4, 5, 10, 13, 15 } }, -- Druid
}

function GearCatalog:OnLoad()
	Wanted.db.pvpGear = type(Wanted.db.pvpGear) == "table" and Wanted.db.pvpGear or {}
	Wanted.db.gearGoals = type(Wanted.db.gearGoals) == "table" and Wanted.db.gearGoals or {}
end

function GearCatalog:OnEnable()
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("MERCHANT_SHOW")
	frame:SetScript("OnEvent", function()
		-- A moment after it opens, once the vendor's items are in
		C_Timer.After(0.5, function()
			if GearCatalog:ReadVendor() then
				private.ReadAllClasses()
			end
		end)
	end)
end

---Registers a function called when the catalogue or the starred items change.
function GearCatalog:OnChange(func)
	tinsert(private.listeners, func)
end

function private.Changed()
	for _, func in ipairs(private.listeners) do
		func()
	end
end

---A value the addon may use: not a secret.
function private.Readable(value)
	return not (issecretvalue and issecretvalue(value))
end

---This character's side's catalogue: itemID -> entry.
---@return table
function GearCatalog:Items()
	local faction = UnitFactionGroup("player") or "Horde"
	Wanted.db.pvpGear[faction] = Wanted.db.pvpGear[faction] or {}
	return Wanted.db.pvpGear[faction]
end

---The rank a vendor item's tooltip asks for ("Requires Knight-Captain / Legionnaire (Rank 8)": its number in brackets,
---or failing that a rank title in the line) and the classes it's for ("Classes: Rogue", in the game's own wording).
---(The level comes from the item itself.)
function private.Requirements(index)
	local rank, classes = nil, nil
	local classesPattern = type(ITEM_CLASSES_ALLOWED) == "string" and "^"..gsub(ITEM_CLASSES_ALLOWED, "%%s", "(.+)").."$" or "^Classes: (.+)$"
	local tip = C_TooltipInfo and C_TooltipInfo.GetMerchantItem and C_TooltipInfo.GetMerchantItem(index)
	for _, line in ipairs(type(tip) == "table" and tip.lines or {}) do
		local text = line.leftText
		if type(text) == "string" and private.Readable(text) then
			rank = rank or tonumber(strmatch(text, "%(%a* ?(%d+)%)"))
			local allowed = strmatch(text, classesPattern)
			if allowed then
				classes = {}
				for name in gmatch(allowed, "[^,]+") do
					tinsert(classes, strtrim(name))
				end
			end
			if not rank then
				for _, titles in pairs(BlizzRank.TITLES) do
					for r, title in ipairs(titles) do
						if strfind(text, title, 1, true) and strfind(text, "/", 1, true) then
							rank = r
						end
					end
				end
			end
		end
	end
	return rank, classes
end

---Reads the open vendor: every item that costs Honor Points or needs a rank goes in the catalogue.
function GearCatalog:ReadVendor()
	local count = GetMerchantNumItems and GetMerchantNumItems() or 0
	if count == 0 then
		return
	end
	local honorName = nil
	local honor = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(BlizzRank.HONOR)
	if type(honor) == "table" and private.Readable(honor.name) then
		honorName = honor.name
	end
	local items, now, vendor, kept = GearCatalog:Items(), GetServerTime(), UnitName("npc"), 0
	for index = 1, min(count, MAX_ITEMS) do
		local ok, entry, itemID = pcall(private.ReadItem, index, honorName)
		if ok and entry then
			entry.vendor, entry.seen = vendor, now
			items[itemID] = entry
			kept = kept + 1
		end
	end
	-- What no vendor has shown in a long while is gone from the game
	for itemID, entry in pairs(items) do
		if type(entry) ~= "table" or (entry.seen or 0) < now - KEEP_DAYS * 86400 then
			items[itemID] = nil
		end
	end
	if kept > 0 then
		Wanted:Log("GearCatalog: %d PvP items from %s", kept, tostring(vendor))
		private.Changed()
	end
	return kept > 0
end

---A rank vendor shows only this class's items by default. Once a session per vendor: switch its filter to All, read
---every class's items, and put the filter back as the player had it.
function private.ReadAllClasses()
	local vendor = UnitName("npc")
	if not vendor or private.allRead[vendor] or not GetMerchantFilter or not SetMerchantFilter or not LE_LOOT_FILTER_ALL then
		return
	end
	local before = GetMerchantFilter()
	if before == LE_LOOT_FILTER_ALL then
		private.allRead[vendor] = true
		return
	end
	private.allRead[vendor] = true
	SetMerchantFilter(LE_LOOT_FILTER_ALL)
	C_Timer.After(0.5, function()
		GearCatalog:ReadVendor()
		-- Back as the player had it, if the window is still open on this vendor
		if MerchantFrame and MerchantFrame:IsShown() and UnitName("npc") == vendor then
			SetMerchantFilter(before)
			if MerchantFrame_Update then
				MerchantFrame_Update()
			end
		end
	end)
end

---One vendor item as a catalogue entry, or nil when it's not PvP gear (no honor, no rank).
function private.ReadItem(index, honorName)
	local itemID = GetMerchantItemID and GetMerchantItemID(index)
	if type(itemID) ~= "number" then
		return nil
	end
	local entry = { honor = 0, marks = {} }
	for c = 1, (GetMerchantItemCostInfo and GetMerchantItemCostInfo(index) or 0) do
		local _, value, link, currencyName = GetMerchantItemCostItem(index, c)
		local markID = type(link) == "string" and tonumber(strmatch(link, "item:(%d+)"))
		if markID then
			entry.marks[markID] = value
		elseif honorName and currencyName == honorName then
			entry.honor = value or 0
		end
	end
	entry.rank, entry.classes = private.Requirements(index)
	if entry.honor == 0 and not entry.rank then
		return nil
	end
	local info = C_MerchantFrame and C_MerchantFrame.GetItemInfo and C_MerchantFrame.GetItemInfo(index)
	entry.price = type(info) == "table" and info.price or 0
	local _, _, _, equipLoc, icon, classID, subclassID = C_Item.GetItemInfoInstant(itemID)
	local name, _, quality, _, minLevel = C_Item.GetItemInfo(itemID)
	entry.name = name or (type(info) == "table" and info.name) or ("item "..itemID)
	entry.quality, entry.icon = quality or 1, icon
	entry.slot, entry.class, entry.subclass = equipLoc, classID, subclassID
	entry.level = minLevel
	return entry, itemID
end

---Whether this character's class can use an item: its armour type (cloaks and trinkets for everyone), its shields and
---off-hands, its weapon skills. Items that aren't gear (potions, standards, mounts) are for everyone.
---@param entry table
---@param classID number?
---@return boolean
function GearCatalog:CanUse(entry, classID)
	-- An item for named classes ("Classes: Rogue"): those only. Rogues and druids both wear leather, but not one set
	if type(entry.classes) == "table" then
		local myClass = UnitClass("player")
		for _, name in ipairs(entry.classes) do
			if name == myClass then
				return true
			end
		end
		return false
	end
	classID = classID or select(3, UnitClass("player"))
	local class = CLASSES[classID]
	if not class then
		return true
	end
	if entry.class == WEAPON then
		for _, skill in ipairs(class.weapons) do
			if skill == entry.subclass then
				return true
			end
		end
		return false
	elseif entry.class == ARMOR then
		if entry.slot == "INVTYPE_CLOAK" or entry.slot == "INVTYPE_NECK" or entry.slot == "INVTYPE_TRINKET" or entry.slot == "INVTYPE_FINGER"
			or entry.slot == "INVTYPE_TABARD" or entry.subclass == ARMOR_MISC and entry.slot ~= "INVTYPE_HOLDABLE" then
			return true
		elseif entry.slot == "INVTYPE_HOLDABLE" then
			return class.holdable == true
		elseif entry.subclass == ARMOR_SHIELD then
			return class.shield == true
		end
		-- The vendor sells a class its own set: its best armour type
		return entry.subclass == class.armor
	end
	return true
end

---What stands between this character and an item, most important first: { "Rank 8", "Level 55", "4,650 more honor",
---"8 more AV marks" }; empty when it can be bought.
---@param entry table
---@return string[]
function GearCatalog:Missing(entry)
	local missing = {}
	local r = BlizzRank:Get()
	if entry.rank and (not r or r.rank < entry.rank) then
		tinsert(missing, "Rank "..entry.rank)
	end
	if entry.level and entry.level > (UnitLevel("player") or 0) then
		tinsert(missing, "Level "..entry.level)
	end
	local have = BlizzRank:Honor() or 0
	if (entry.honor or 0) > have then
		tinsert(missing, private.Count(entry.honor - have).." more honor")
	end
	for _, mark in ipairs(BlizzRank.MARKS) do
		local need = entry.marks and entry.marks[mark.id]
		local held = need and BlizzRank:MarkCount(mark.id) or 0
		if need and need > held then
			tinsert(missing, format("%d more %s marks", need - held, mark.short))
		end
	end
	return missing
end

---A number with thousands separators: 4,650.
function private.Count(n)
	local text = tostring(floor(n or 0))
	repeat
		local changed
		text, changed = gsub(text, "^(%d+)(%d%d%d)", "%1,%2")
	until changed == 0
	return text
end

---The catalogue for this character's class, starred first, then by rank, then by slot and name: { itemID, entry,
---starred, missing }.
---@return table[]
function GearCatalog:ForMe()
	local out = {}
	local classID = select(3, UnitClass("player"))
	local goals = GearCatalog:Goals()
	for itemID, entry in pairs(GearCatalog:Items()) do
		-- An item the game hadn't loaded when the vendor was read: its name and level once it has
		if type(entry) == "table" and (not entry.level or strfind(entry.name or "", "^item %d")) then
			local name, _, quality, _, minLevel = C_Item.GetItemInfo(itemID)
			if name then
				entry.name, entry.quality, entry.level = name, quality or entry.quality, minLevel or entry.level
			end
		end
		if type(entry) == "table" and GearCatalog:CanUse(entry, classID) then
			tinsert(out, { itemID = itemID, entry = entry, starred = goals[itemID] == true, missing = GearCatalog:Missing(entry) })
		end
	end
	sort(out, function(a, b)
		if a.starred ~= b.starred then
			return a.starred
		end
		if (a.entry.rank or 0) ~= (b.entry.rank or 0) then
			return (a.entry.rank or 0) < (b.entry.rank or 0)
		end
		if (a.entry.slot or "") ~= (b.entry.slot or "") then
			return (a.entry.slot or "") < (b.entry.slot or "")
		end
		return (a.entry.name or "") < (b.entry.name or "")
	end)
	return out
end

---This character's starred items: itemID -> true.
---@return table
function GearCatalog:Goals()
	local guid = UnitGUID("player") or "?"
	Wanted.db.gearGoals[guid] = Wanted.db.gearGoals[guid] or {}
	return Wanted.db.gearGoals[guid]
end

---Stars an item to chase, or takes the star off.
---@param itemID number
function GearCatalog:ToggleGoal(itemID)
	local goals = GearCatalog:Goals()
	goals[itemID] = not goals[itemID] or nil
	private.Changed()
end
