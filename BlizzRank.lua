-- Wanted: Blizzard's PvP rank, as the game tells it. The rank track (rank, points, this week's cap, the season's
-- most), what each rank unlocks at the rank vendors, Honor Points and the battleground Marks of Honor. Wanted has no
-- ranks of its own: every rank it shows is Blizzard's (docs/pvp-restructure-plan.md).

local _, Wanted = ...
local BlizzRank = Wanted:NewModule("BlizzRank")
local private = { listeners = {}, unlocks = nil }
local SHARED_DAYS = 30 -- a rank heard from another player is forgotten after this long
local SHARED_MAX = 5000 -- players kept at most

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

function BlizzRank:OnLoad()
	-- Blizzard ranks heard from other Wanted players (in their sync hello), and our own: "Name" -> { r, s, t }
	Wanted.db.blizzRanks = type(Wanted.db.blizzRanks) == "table" and Wanted.db.blizzRanks or {}
	private.PruneShared()
end

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

---This character's rank and the season it's in, for the sync hello: rank, season. nil before it has a rank in a
---running season (nothing to share on the beta).
---@return number? rank
---@return number? season
function BlizzRank:Mine()
	local r = BlizzRank:Get()
	local s = Wanted.db.pvpSeason
	local season = type(s) == "table" and private.Number(s.season) or nil
	if not r or r.rank < 1 or not season or season < 1 then
		return nil
	end
	-- Kept with the others', so the app sends it up with theirs
	local me = Wanted.Store and Wanted.Store:GetOrigin()
	if type(me) == "string" then
		BlizzRank:Note(me, r.rank, season)
	end
	return r.rank, season
end

---Keeps a player's Blizzard rank as their hello told it (or our own, or the site's). Bad values are ignored. side ("H"
---or "A") names its titles when the game doesn't say the player's side: the site's say it; a hello's player is ours.
---@param name string the player's name as sync gives it
---@param rank any
---@param season any
---@param side string?
function BlizzRank:Note(name, rank, season, side)
	rank, season = private.Number(rank), private.Number(season)
	if type(name) ~= "string" or not rank or not season or rank < 1 or rank > BlizzRank.MAX_RANK or season < 1 or season > 1000 then
		return
	end
	name = strmatch(name, "^([^%-]+)") or name
	if name == "" or #name > 48 then
		return
	end
	side = (side == "H" or side == "A") and side or nil
	local entry = Wanted.db.blizzRanks[name]
	if entry and entry.r == rank and entry.s == season and GetServerTime() - (entry.t or 0) < 600 and (not side or entry.f == side) then
		return
	end
	Wanted.db.blizzRanks[name] = { r = rank, s = season, t = GetServerTime(), f = side or (entry and entry.f) or nil }
end

---Takes the ranks the site has heard from Wanted players (the catch-up's blizzRanks: "Name" -> { r, s, t }), each
---unless we heard that player more lately ourselves.
---@param raw any
function BlizzRank:Take(raw)
	if type(raw) ~= "table" then
		return
	end
	local book, taken = Wanted.db.blizzRanks, 0
	for name, entry in pairs(raw) do
		local at = type(entry) == "table" and private.Number(entry.t)
		local mine = type(name) == "string" and book[strmatch(name, "^([^%-]+)") or name]
		if at and at <= GetServerTime() + 86400 and (type(mine) ~= "table" or (mine.t or 0) < at) then
			BlizzRank:Note(name, entry.r, entry.s, entry.f)
			local kept = book[strmatch(name, "^([^%-]+)") or name]
			if kept then
				kept.t = at
				taken = taken + 1
			end
		end
	end
	if taken > 0 then
		Wanted:Log("BlizzRank: %d ranks from the site", taken)
	end
end

---A player's Blizzard rank as they last told it, in the season the game says is running now, and the side kept with
---it ("H", "A" or nil); nil otherwise.
---@param name string
---@return number?
---@return string?
function BlizzRank:Of(name)
	local entry = type(name) == "string" and Wanted.db.blizzRanks[strmatch(name, "^([^%-]+)") or name]
	local s = Wanted.db.pvpSeason
	local season = type(s) == "table" and s.season or nil
	if type(entry) ~= "table" or not season or entry.s ~= season then
		return nil
	end
	return entry.r, entry.f
end

---A player's Blizzard rank to show: { r, f } (f "H" or "A", the side whose titles name it), or nil. Our own from the
---game; anyone else's as their Wanted addon shared it, this season. faction is theirs when known.
---@param name string
---@param faction string?
---@return table?
function BlizzRank:RankOf(name, faction)
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local rank, kept
	local me = Wanted.Store and Wanted.Store:GetOrigin()
	if name == me or name == UnitName("player") then
		local r = BlizzRank:Get()
		rank = r and r.rank >= 1 and r.rank or nil
		faction = faction or UnitFactionGroup("player")
	else
		rank, kept = BlizzRank:Of(name)
	end
	if not rank then
		return nil
	end
	-- The player's side as the game says it picks the titles; the one kept with the rank only when it doesn't
	local side = (faction == "Alliance" or faction == "A") and "A" or (faction == "Horde" or faction == "H") and "H" or kept
	return { r = rank, f = side }
end

---Drops ranks not heard in SHARED_DAYS, and the oldest past SHARED_MAX.
function private.PruneShared()
	local book, now, kept = Wanted.db.blizzRanks, GetServerTime(), {}
	for name, entry in pairs(book) do
		if type(entry) ~= "table" or type(entry.t) ~= "number" or entry.t < now - SHARED_DAYS * 86400 then
			book[name] = nil
		else
			tinsert(kept, name)
		end
	end
	if #kept > SHARED_MAX then
		sort(kept, function(a, b) return book[a].t > book[b].t end)
		for i = SHARED_MAX + 1, #kept do
			book[kept[i]] = nil
		end
	end
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
