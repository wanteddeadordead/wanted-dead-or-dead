-- Wanted: the honor scout. Players' lifetime honorable kills, read from the game for anyone a Wanted player targets
-- or mouses over, either side, Wanted or not: the achievement comparison's "Total Honorable Kills" statistic (588),
-- probed on Forever build 70205 (2026-10-05). One player at a time, a few seconds apart, never in combat or an
-- instance, never while the achievement window is open, each player again only after RECHECK_SECONDS. Kept in
-- WantedDB.hkBook for the app, which sends them to wanteddeadordead.com for its Honorable Kills board.

local _, Wanted = ...
local HonorScout = Wanted:NewModule("HonorScout")
local private = {
	pending = nil, -- { guid, name, faction, at }: the comparison asked for and not answered yet
	lastAt = -math.huge, -- GetTime() of the last comparison asked for
}
local HK_STATISTIC = 588 -- "Total Honorable Kills"
local RECHECK_SECONDS = 6 * 60 * 60
local GAP_SECONDS = 3
local TIMEOUT_SECONDS = 5
local KEEP_DAYS = 30
local MAX_BOOK = 5000

function HonorScout:OnLoad()
	-- character GUID -> { n = name, f = "H" | "A", hk = lifetime honorable kills, t = when read } (docs/DATA.md)
	Wanted.db.hkBook = type(Wanted.db.hkBook) == "table" and Wanted.db.hkBook or {}
	private.Prune()
end

function HonorScout:OnEnable()
	local frame = CreateFrame("Frame")
	for _, event in ipairs({ "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "INSPECT_ACHIEVEMENT_READY" }) do
		pcall(frame.RegisterEvent, frame, event)
	end
	frame:SetScript("OnEvent", function(_, event, arg1)
		if event == "INSPECT_ACHIEVEMENT_READY" then
			private.OnReady(arg1)
		else
			private.Consider(event == "PLAYER_TARGET_CHANGED" and "target" or "mouseover")
		end
	end)
end

---A value the addon may use: not a secret.
function private.Readable(value)
	return not (issecretvalue and issecretvalue(value))
end

---Whether the scout may ask the game now.
function private.MayAsk()
	if not Wanted.db.settings.honorScout or private.pending or GetTime() - private.lastAt < GAP_SECONDS then
		return false
	end
	if Wanted:InInstance() or Wanted:InCombat() or InCombatLockdown() then
		return false
	end
	-- The player's own comparison: never in its way
	if AchievementFrame and AchievementFrame:IsShown() then
		return false
	end
	return SetAchievementComparisonUnit ~= nil and GetComparisonStatistic ~= nil
end

---Asks for a player's honorable kills when they're due.
function private.Consider(unit)
	if not private.MayAsk() then
		return
	end
	local okPlayer, isPlayer = pcall(UnitIsPlayer, unit)
	if not okPlayer or not private.Readable(isPlayer) or not isPlayer then
		return
	end
	local guid = UnitGUID(unit)
	if not private.Readable(guid) or type(guid) ~= "string" or not strfind(guid, "^Player%-") or guid == UnitGUID("player") then
		return
	end
	local entry = Wanted.db.hkBook[guid]
	if type(entry) == "table" and GetServerTime() - (entry.t or 0) < RECHECK_SECONDS then
		return
	end
	local name, surname = UnitName(unit)
	local faction = UnitFactionGroup(unit)
	if not private.Readable(name) or not private.Readable(surname) or not private.Readable(faction) or type(name) ~= "string" then
		return
	end
	if not pcall(SetAchievementComparisonUnit, unit) then
		return
	end
	local pending = { guid = guid, name = (type(surname) == "string" and surname ~= "") and (name.." "..surname) or name,
		faction = faction == "Alliance" and "A" or faction == "Horde" and "H" or nil, at = GetTime() }
	private.pending, private.lastAt = pending, GetTime()
	C_Timer.After(TIMEOUT_SECONDS, function()
		if private.pending == pending then
			private.Done()
		end
	end)
end

---The game's answer: the statistic for the player asked about ("--" when they have none).
function private.OnReady(guid)
	local pending = private.pending
	if not pending or not private.Readable(guid) or guid ~= pending.guid then
		return
	end
	local ok, value = pcall(GetComparisonStatistic, HK_STATISTIC)
	local hk = ok and private.Readable(value) and (tonumber(value) or (value == "--" and 0)) or nil
	if hk and hk >= 0 and hk == floor(hk) then
		Wanted.db.hkBook[guid] = { n = pending.name, f = pending.faction, hk = hk, t = GetServerTime() }
	end
	private.Done()
end

---Done with the comparison: let it go.
function private.Done()
	private.pending = nil
	if ClearAchievementComparisonUnit then
		pcall(ClearAchievementComparisonUnit)
	end
end

---Drops readings older than KEEP_DAYS, and the oldest past MAX_BOOK.
function private.Prune()
	local book, now, kept = Wanted.db.hkBook, GetServerTime(), {}
	for guid, entry in pairs(book) do
		if type(entry) ~= "table" or type(entry.t) ~= "number" or entry.t < now - KEEP_DAYS * 86400 then
			book[guid] = nil
		else
			tinsert(kept, guid)
		end
	end
	if #kept > MAX_BOOK then
		sort(kept, function(a, b) return book[a].t > book[b].t end)
		for i = MAX_BOOK + 1, #kept do
			book[kept[i]] = nil
		end
	end
end
