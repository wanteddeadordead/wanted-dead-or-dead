-- Wanted: Blizzard's PvP rank, as the game tells it. The rank track (rank, points, this week's cap, the season's
-- most), what each rank unlocks at the rank vendors, Honor Points and the battleground Marks of Honor. Wanted has no
-- ranks of its own: every rank it shows is Blizzard's (docs/pvp-restructure-plan.md).

local _, Wanted = ...
local BlizzRank = Wanted:NewModule("BlizzRank")
local private = { listeners = {}, unlocks = nil }

BlizzRank.MAX_RANK = 14
BlizzRank.FACTION = 2800 -- PVP_RANK_POINTS_FACTION_ID in Blizzard's PVPRankFrame.lua (a local there)
BlizzRank.HONOR = 1792 -- Honor Points (the rank vendors' currency, cap 25,000)
-- The battleground Marks of Honor the rank vendors take, in the order the page lists them
BlizzRank.MARKS = {
	{ id = 20560, name = "Alterac Valley", short = "AV" },
	{ id = 20559, name = "Arathi Basin", short = "AB" },
	{ id = 20558, name = "Warsong Gulch", short = "WSG" },
	{ id = 274895, name = "Darkspear Islands", short = "DI" },
}
-- Blizzard's rank titles, as the rank vendors' tooltips name them ("Knight-Captain / Legionnaire (Rank 8)")
BlizzRank.TITLES = {
	Alliance = { "Private", "Corporal", "Sergeant", "Master Sergeant", "Sergeant Major", "Knight", "Knight-Lieutenant",
		"Knight-Captain", "Knight-Champion", "Lieutenant Commander", "Commander", "Marshal", "Field Marshal", "Grand Marshal" },
	Horde = { "Scout", "Grunt", "Sergeant", "Senior Sergeant", "First Sergeant", "Stone Guard", "Blood Guard", "Legionnaire",
		"Centurion", "Champion", "Lieutenant General", "General", "Warlord", "High Warlord" },
}

function BlizzRank:OnEnable()
	local frame = CreateFrame("Frame")
	for _, event in ipairs({ "MAJOR_FACTION_RENOWN_LEVEL_CHANGED", "MAJOR_FACTION_UNLOCKED", "CURRENCY_DISPLAY_UPDATE", "BAG_UPDATE_DELAYED" }) do
		pcall(frame.RegisterEvent, frame, event)
	end
	frame:SetScript("OnEvent", function()
		for _, func in ipairs(private.listeners) do
			func()
		end
	end)
end

---Registers a function called when the rank, honor or marks may have changed.
function BlizzRank:OnChange(func)
	tinsert(private.listeners, func)
end

---One of the game's answers, or nil when the call is missing, fails or answers with a secret.
function private.Ask(func, ...)
	if type(func) ~= "function" then
		return nil
	end
	local ok, value = pcall(func, ...)
	if not ok or (issecretvalue and issecretvalue(value)) then
		return nil
	end
	return value
end

---A whole number from the game, or nil.
function private.Number(value)
	return type(value) == "number" and value == floor(value) and value or nil
end

---A rank's title on a side ("Horde" or "Alliance", or "H" / "A"); this character's side by default.
---@param rank number
---@param faction string?
---@return string?
function BlizzRank:Title(rank, faction)
	faction = faction == "A" and "Alliance" or faction == "H" and "Horde" or faction or UnitFactionGroup("player")
	return (BlizzRank.TITLES[faction] or BlizzRank.TITLES.Horde)[rank]
end

---The game's PvP rank badge for a rank (1 to 14), or nil.
---@param rank number
---@return string?
function BlizzRank:Badge(rank)
	if type(rank) ~= "number" or rank < 1 or rank > BlizzRank.MAX_RANK or rank ~= floor(rank) then
		return nil
	end
	return format("Interface\\PvPRankBadges\\PvPRank%02d", rank)
end

---Your Blizzard rank: { rank, earned, toNext, weekMax, seasonMax, week }. rank 0 is none yet; earned/toNext are the
---points into this rank and the points it takes to the next; weekMax is this week's highest reachable rank (0 or
---less before a season runs). nil when the game doesn't answer.
---@return table?
function BlizzRank:Get()
	local info = private.Ask(C_MajorFactions and C_MajorFactions.GetMajorFactionProgressionInfo, BlizzRank.FACTION)
	if type(info) ~= "table" then
		return nil
	end
	local rank = private.Number(info.renownLevel)
	if not rank then
		return nil
	end
	return {
		rank = rank,
		earned = private.Number(info.renownReputationEarned) or 0,
		toNext = private.Number(info.renownLevelThreshold) or 0,
		weekMax = private.Number(info.currentWeekProgressiveMaxLevel) or 0,
		seasonMax = private.Number(info.maxLevel) or BlizzRank.MAX_RANK,
		week = private.Number(info.weekNumber) or -1,
	}
end

---What each rank unlocks at the rank vendors, as the game describes it: unlocks[rank] = "Elite Wrist Upgrade +
---Elite Waist Upgrade". Read once a session; ranks the game says nothing about are missing.
---@return table<number, string>
function BlizzRank:Unlocks()
	if private.unlocks and next(private.unlocks) then
		return private.unlocks
	end
	local unlocks = {}
	for rank = 1, BlizzRank.MAX_RANK do
		local rewards = private.Ask(C_MajorFactions and C_MajorFactions.GetRenownRewardsForLevel, BlizzRank.FACTION, rank)
		local parts = {}
		for _, reward in ipairs(type(rewards) == "table" and rewards or {}) do
			local text = type(reward) == "table" and reward.description
			if type(text) == "string" and text ~= "" and not (issecretvalue and issecretvalue(text)) then
				tinsert(parts, text)
			end
		end
		if #parts > 0 then
			unlocks[rank] = table.concat(parts, " + ")
		end
	end
	private.unlocks = unlocks
	return unlocks
end

---Your Honor Points and the most you can hold: have, max. nil when the game doesn't answer.
---@return number? have
---@return number? max
function BlizzRank:Honor()
	local info = private.Ask(C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo, BlizzRank.HONOR)
	if type(info) ~= "table" then
		return nil
	end
	return private.Number(info.quantity), private.Number(info.maxQuantity)
end

---How many of a Mark of Honor you hold, bags and bank.
---@param itemID number
---@return number
function BlizzRank:MarkCount(itemID)
	return private.Number(private.Ask(GetItemCount, itemID, true)) or 0
end

---A mark's icon, or nil until the game has the item.
---@param itemID number
---@return number|string?
function BlizzRank:MarkIcon(itemID)
	return private.Ask(C_Item and C_Item.GetItemIconByID, itemID)
end
