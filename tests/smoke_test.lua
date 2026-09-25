-- Loads the Wanted addon under a stubbed WoW API, builds every page, runs the simulation and every row
-- action, and fails on any Lua error. It checks the code paths, not the look.
-- Usage (from the repository root): lua tests/smoke_test.lua

local ADDON = "./"

-- Lua 5.1 names the addon code uses
unpack = unpack or table.unpack
loadstring = loadstring or load
math.ldexp = math.ldexp or function(m, e) return m * 2.0 ^ e end
math.frexp = math.frexp or function(x)
	if x == 0 then return 0, 0 end
	local e = math.floor(math.log(math.abs(x), 2)) + 1
	return x / 2 ^ e, e
end
math.atan2 = math.atan2 or math.atan
format, strfind, strmatch, strsub, strlower, strupper, strrep, gsub, gmatch, strlen = string.format, string.find, string.match, string.sub, string.lower, string.upper, string.rep, string.gsub, string.gmatch, string.len
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
strjoin = function(sep, ...) local t = { ... } for i = 1, select("#", ...) do t[i] = tostring(t[i]) end return table.concat(t, sep) end
strsplit = function(sep, s) local out = {} for part in (s..sep):gmatch("(.-)"..sep:gsub("%p", "%%%0")) do out[#out + 1] = part end return unpack(out) end
tinsert, tremove, sort = table.insert, table.remove, table.sort
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs
date = os.date
bit = { band = function(a, b) local r, p = 0, 1 while a > 0 and b > 0 do if a % 2 == 1 and b % 2 == 1 then r = r + p end a, b, p = a // 2, b // 2, p * 2 end return r end }

-- Frames
local registry = {}
local Mock = {}
local Methods = {}
local function NewMock(kind)
	return setmetatable({ _scripts = {}, _shown = true, _text = "", _enabled = true, _w = 100, _h = 20, _kind = kind }, Mock)
end
Mock.__index = function(t, k)
	if Methods[k] then return Methods[k] end
	if type(k) == "string" and k:sub(1, 1) == "_" then return nil end
	-- Fields the addon stores on frames are plain values; anything else is a method returning a frame
	return function() return NewMock() end
end
function Methods:SetScript(name, f) self._scripts[name] = f end
function Methods:GetScript(name) return self._scripts[name] end
function Methods:HookScript(name, f) local old = self._scripts[name] self._scripts[name] = function(...) if old then old(...) end f(...) end end
function Methods:Show() self._shown = true if self._scripts.OnShow then self._scripts.OnShow(self) end end
function Methods:Hide() self._shown = false if self._scripts.OnHide then self._scripts.OnHide(self) end end
function Methods:SetShown(v) if v then self:Show() else self:Hide() end end
function Methods:IsShown() return self._shown end
function Methods:IsVisible() return self._shown end
function Methods:SetText(t) self._text = t or "" if self._fs then self._fs._text = t or "" end end
function Methods:GetText() return self._text end
function Methods:GetStringWidth() return #tostring(self._text) * 6 end
function Methods:GetStringHeight() return 12 * (select(2, tostring(self._text):gsub("\n", "")) + 1) end
function Methods:IsEnabled() return self._enabled end
function Methods:SetEnabled(v) self._enabled = v and true or false end
function Methods:Enable() self._enabled = true end
function Methods:Disable() self._enabled = false end
function Methods:SetWidth(w) self._w = w end
function Methods:SetHeight(h) self._h = h end
function Methods:SetSize(w, h) self._w, self._h = w, h end
function Methods:GetWidth() return self._w end
function Methods:GetHeight() return self._h end
function Methods:HasFocus() return false end
function Methods:GetFrameLevel() return 1 end
function Methods:SetFrameLevel(level) self._level = level lastFrameLevel = level end
function Methods:GetCenter() return 0, 0 end
function Methods:GetEffectiveScale() return 1 end
function Methods:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
function Methods:SetFontString(fs) self._fs = fs end
function Methods:Click() if self._scripts.OnClick then self._scripts.OnClick(self, "LeftButton") end end
function Methods:RegisterEvent(e) registry[e] = registry[e] or {} table.insert(registry[e], self) end
function Methods:SetChecked(v) self._checked = v end
function Methods:GetChecked() return self._checked end
function CreateFrame(kind) return NewMock(kind) end
function CreateFont() return NewMock("Font") end
UIParent, Minimap, GameTooltip, DEFAULT_CHAT_FRAME, MailFrame = NewMock(), NewMock(), NewMock(), NewMock(), NewMock()
MailFrame._shown = false
local printed = {}
function Methods:AddMessage(msg) printed[#printed + 1] = msg end
UISpecialFrames = {}
local function Fire(event, ...)
	for _, frame in ipairs(registry[event] or {}) do
		frame._scripts.OnEvent(frame, event, ...)
	end
end

-- Timers
local timers = {}
tickers = {}
C_Timer = {
	After = function(_, f) timers[#timers + 1] = f end,
	NewTicker = function(_, f) tickers[#tickers + 1] = f return NewMock() end,
	NewTimer = function() return NewMock() end,
}
local function RunTimers()
	for _ = 1, 5 do
		local batch = timers
		timers = {}
		for _, f in ipairs(batch) do f() end
		if #timers == 0 then return end
	end
end

-- Game state
clock = 1790270000
function GetServerTime() return clock end
function GetTime() return clock end
function UnitName(unit) if unit == "player" then return "Test", "Player" end return nil end
function UnitFactionGroup(unit) if unit and enemyUnits[unit] then return "Alliance" end return "Horde" end
function UnitGUID(unit) if unit == "player" then return "Player-1-ME" end local e = enemyUnits[unit] return e and e.guid end
function UnitExists(unit) return enemyUnits[unit] ~= nil end
function UnitIsPlayer(unit) return enemyUnits[unit] ~= nil end
function GetRealmName() return "Realm" end
function GetNormalizedRealmName() return "Realm" end
function RegionalUniqueNamesEnabled() return true end
function GetZoneText() return "Durotar" end
function IsInInstance() return false end
function GetChannelName() return 6 end
function JoinPermanentChannel() end
function LeaveChannelByName() end
function hooksecurefunc() end
function GetInboxNumItems() return 0 end
function GetCursorPosition() return 0, 0 end
-- An enemy on nameplate1 and, when set, as the target
enemyUnits = {}
local function enemy(unit) return enemyUnits[unit] end
function GetUnitName(unit) local e = enemy(unit) return e and e.name end
function UnitIsEnemy(_, unit) return enemy(unit) ~= nil end
function UnitClass(unit) local e = enemy(unit) return e and "Rogue", e and e.class end
function UnitLevel(unit) local e = enemy(unit) return e and e.level or 10 end
function UnitRace(unit) return enemy(unit) and "Human" end
function UnitHealth(unit) return enemy(unit) and 50 or 100 end
function UnitHealthMax() return 100 end
function UnitIsUnit(a, b) local e = enemy((a:gsub("target$", ""))) return (e and e.targetsMe and b == "player") and true or false end
function UnitIsDeadOrGhost(unit) local e = enemyUnits[unit] return e and e.dead or false end
function GetGuildInfo(unit) local e = enemy(unit) return e and e.guild end
function GetPlayerInfoByGUID(guid) if guid == "Player-9-ENEMY" then return "Rogue", "ROGUE", "Human", "Human", 2, "Stabby Mcstab" end return nil end
function InCombatLockdown() return false end
function IsInGroup() return true end
function IsInRaid() return false end
function IsInGuild() return true end
function IsShiftKeyDown() return false end
function IsControlKeyDown() return false end
function PlaySound() end
function GetBuildInfo() return "1.60.1", "69977" end
function GetLocale() return "enUS" end
function GetClassAtlas(c) return "classicon-"..c:lower() end
function PlaySoundFile() return true end
SOUNDKIT = { RAID_WARNING = 1, UI_RAID_BOSS_WHISPER_WARNING = 2, IG_PLAYER_INVITE = 3 }
C_Spell = { GetSpellName = function() return nil end }
local MAP_NAMES = { [1] = "Durotar", [10] = "The Barrens" }
C_Map = { GetBestMapForUnit = function() return 1 end, GetPlayerMapPosition = function() return { x = 0.446, y = 0.25 } end, GetMapInfo = function(id) return MAP_NAMES[id] and { name = MAP_NAMES[id] } end }
local mapOpened
function OpenWorldMap(mapId) mapOpened = mapId end
-- The world map's pin system, enough to drive a data provider
function CreateFromMixins(...) local t = {} for _, m in ipairs({ ... }) do for k, v in pairs(m) do t[k] = v end end return t end
MapCanvasPinMixin = { SetScalingLimits = function() end, UseFrameLevelType = function(self, levelType) self._levelType = levelType end, SetPosition = function(self, x, y) self._x, self._y = x, y end }
MapCanvasDataProviderMixin = { OnAdded = function(self, map) self.owningMap = map end, GetMap = function(self) return self.owningMap end }
local insertedLevel
WorldMapFrame = NewMock()
WorldMapFrame.pins = {}
WorldMapFrame.GetMapID = function() return 1 end
WorldMapFrame.AddDataProvider = function(self, provider) self.provider = provider provider:OnAdded(self) end
WorldMapFrame.GetPinFrameLevelsManager = function() return { InsertFrameLevelBelow = function(_, name, below) insertedLevel = name.." below "..below end } end
WorldMapFrame.RemoveAllPinsByTemplate = function(self) self.pins = {} end
WorldMapFrame.AcquirePin = function(self, template, ...)
	local pin = {} -- plain, so unset fields read as nil like a real frame's
	for k, v in pairs(_G[template:gsub("Template$", "Mixin")]) do pin[k] = v end
	pin.Dot = NewMock()
	pin:OnLoad()
	pin:OnAcquired(...)
	table.insert(self.pins, pin)
	return pin
end
WorldMapFrame.WorldMapTrackingOptionsButton = NewMock()
local menus = {}
Menu = { ModifyMenu = function(tag, f) menus[tag] = f end }
local chatSent = {}
addonSent = {}
C_ChatInfo = { RegisterAddonMessagePrefix = function() return 0 end, SendAddonMessage = function(prefix, text)
	if throttleNext and throttleNext > 0 then throttleNext = throttleNext - 1 return 3 end
	addonSent[#addonSent + 1] = { prefix = prefix, text = text } return 0
end, SendChatMessage = function(msg, channel) chatSent[#chatSent + 1] = channel..": "..msg end }
C_AddOns = { GetAddOnMetadata = function() return "0.1.0" end }
C_CurrencyInfo = { GetCoinTextureString = function(c) return tostring(c).."c" end }
C_Log = nil
Enum = { TooltipDataType = { Unit = 2 } }
TooltipDataProcessor = { AddTooltipPostCall = function() end }
RAID_CLASS_COLORS = { ROGUE = { r = 1, g = 0.96, b = 0.41, WrapTextInColorCode = function(_, t) return t end } }
LOCALIZED_CLASS_NAMES_MALE = { ROGUE = "Rogue" }
SlashCmdList = {}

-- Load the addon in .toc order
local ns = {}
for line in io.lines(ADDON.."WantedDeadOrDead.toc") do
	line = line:gsub("\r", "")
	if line ~= "" and not line:match("^#") and not line:match("%.xml$") then
		local chunk = assert(loadfile(ADDON..line:gsub("\\", "/")))
		chunk("WantedDeadOrDead", ns)
	end
end
Fire("ADDON_LOADED", "WantedDeadOrDead")
Fire("PLAYER_LOGIN")
RunTimers()

local W = ns.Widgets
local lastDialog
local origDialog = W.Dialog
W.Dialog = function(self, options) lastDialog = options return origDialog(self, options) end
local function ConfirmDialog(value)
	assert(lastDialog, "no dialog shown")
	local options = lastDialog
	lastDialog = nil
	if options.validate then
		local err = options.validate(value)
		assert(not err, "validation failed: "..tostring(err))
	end
	if options.onConfirm then options.onConfirm(value) end
end

local function check(cond, msg) if not cond then error("CHECK FAILED: "..msg, 2) end end

-- Every page with no data
for _, key in ipairs({ "board", "mine", "hunters", "activity", "tools" }) do
	ns.UI:Show(key)
end

-- The simulation, then every page again
ns:RunCommand("simulate", "")
for _, key in ipairs({ "board", "mine", "hunters", "activity", "tools" }) do
	ns.UI:Show(key)
end
local board = ns.Model:GetBoard({ minAmount = 0 })
check(#board == 2, "board shows 2 bounties, got "..#board)
check(board[1].mine and board[1].state == "claimed", "your claimed bounty sorts first, got "..tostring(board[1].state))
check(board[1].actions[1] == "dispute" and board[1].actions[2] == "confirm", "claimed bounty offers dispute and confirm")

-- Row actions: pass the other bounty, confirm the claim, pay prompt, raise needs an open one
ns.Rows:DoAction("pass", board[2])
check(#ns.Model:GetBoard({ minAmount = 0 }) == 1, "passed bounty hidden")
check(#ns.Model:GetBoard({ minAmount = 0, showPassed = true }) == 2, "show passed brings it back")
ns.Rows:DoAction("confirm", board[1])
ConfirmDialog()
local info = ns.Model:GetBountyInfo(board[1].bounty)
check(info.state == "owed" and info.actions[1] == "pay", "confirmed bounty is owed with pay, got "..info.state)
check(ns.Model:GetActionCount() == 1, "one thing waits: the payment")
ns.Rows:DoAction("pay", info)
ConfirmDialog()
ns:RunCommand("simulate", "paid")
check(ns.Model:GetBountyInfo(board[1].bounty).state == "paid", "paid after simulate paid")

-- Post a bounty through the board page, then raise it and dispute nothing
ns.Store:UpdatePlayer("Player-TEST-00000001", { name = "Testy Alliance", faction = "Alliance", level = 22 })
local bounty = ns.Bounties:Post("Player-TEST-00000001", "Testy Alliance", 20000)
check(bounty, "post works")
local mine = ns.Model:GetBountyInfo(bounty)
check(mine.state == "open" and mine.actions[2] == "raise", "own open bounty offers raise")
ns.Rows:DoAction("raise", mine)
ConfirmDialog("50s")
check(ns.Bounties:GetAmount(bounty) == 25000, "raise adds 50s")
check(ns.Bounties:Post("Player-TEST-00000001", "Testy Alliance", 500) == nil, "minimum enforced")
check(ns.Bounties:Post("Player-TEST-00000001", "Testy Alliance", 30000) == nil, "no second bounty on the same target")
check(mine.actions[1] == "withdraw" and mine.actions[2] == "raise", "own open bounty offers withdraw and raise")
ns.Rows:DoAction("withdraw", ns.Model:GetBountyInfo(bounty))
ConfirmDialog()
check(ns.Model:GetBountyInfo(bounty).state == "withdrawn", "withdrawn")
check(ns.Bounties:GetMyOpen("Player-TEST-00000001") == nil, "withdrawn bounty is not open")
local again = ns.Bounties:Post("Player-TEST-00000001", "Testy Alliance", 20000)
check(again, "can post again after withdrawing")
-- Another hunter commits: the poster can no longer withdraw
ns.Store:InsertTest("hunt", "Test Hunter", { bounty = again.id }, clock)
local hunted = ns.Model:GetBountyInfo(again)
check(#hunted.hunters == 1 and hunted.actions[1] == "raise", "hunted bounty offers raise only")
check(not ns.Bounties:Withdraw(again), "withdraw refused while hunted")
-- A withdrawal record that raced a hunt does not count
ns.Store:InsertTest("withdraw", ns.Store:GetOrigin(), { bounty = again.id }, clock + 1)
check(not ns.Bounties:IsWithdrawn(again), "withdrawal during a hunt is void")
-- The hunt ends after 2 hours, then a withdrawal counts
clock = clock + ns.Bounties.HUNT_SECONDS + 10
check(#ns.Bounties:GetActiveHunters(again) == 0, "hunt expired")
check(ns.Bounties:Withdraw(again), "withdraw allowed after the hunt lapsed")
check(ns.Bounties:IsWithdrawn(again), "withdrawn after the hunt lapsed")
local again2 = ns.Bounties:Post("Player-TEST-00000001", "Testy Alliance", 20000)
check(again2, "repost")
-- Two hunters on it; the later kill is filed first but the earlier kill wins
ns.Store:InsertTest("hunt", "Test Hunter", { bounty = again2.id }, clock)
ns.Store:InsertTest("hunt", "Rival Hunter", { bounty = again2.id }, clock)
check(#ns.Bounties:GetActiveHunters(again2) == 2, "two hunters at once")
ns.Store:InsertTest("claim", "Rival Hunter", { bounty = again2.id, victim = "Player-TEST-00000001", victimName = "Testy Alliance", zone = "Durotar", killT = clock + 120 }, clock + 121)
ns.Store:InsertTest("claim", "Test Hunter", { bounty = again2.id, victim = "Player-TEST-00000001", victimName = "Testy Alliance", zone = "Durotar", killT = clock + 60 }, clock + 200)
for _, item in ipairs(ns.Model:GetMyBounties()) do
	check(not ns.Model:IsFinished(item), "live list has no finished bounties")
end
local foundWithdrawn = false
for _, item in ipairs(ns.Model:GetMyHistory()) do
	if item.state == "withdrawn" then foundWithdrawn = true end
end
check(foundWithdrawn, "withdrawn bounty is in history")
-- Guild bounty: posted on the guild, claimed by a member's kill
local guildBounty = ns.Bounties:PostGuild("Test Gankers", "Alliance", 30000)
check(guildBounty, "guild bounty posts")
check(ns.Bounties:PostGuild("Test Gankers", "Alliance", 30000) == nil, "one guild bounty per poster per guild")
check(ns.Bounties:PostGuild("Our Guild", "Horde", 30000) == nil, "no guild bounty on your own faction")
ns.Store:NewRecord("kill", { killer = "Player-1-ME", killerName = ns.Store:GetOrigin(), victim = "Player-TEST-00000001", victimName = "Testy Alliance", victimGuild = "Test Gankers", deathId = "g1", zone = "Durotar", honor = true })
local guildClaimed = false
for claim in ns.Store:Iterator("claim") do
	if claim.data.bounty == guildBounty.id then guildClaimed = true end
end
check(not guildClaimed, "own guild bounty is not claimed by yourself")
local gboard = ns.Model:GetGuildBoard()
check(#gboard > 0 and gboard[1].name ~= nil, "guild board lists guilds")
local foundGankers = false
for _, g in ipairs(gboard) do if g.name == "Test Gankers" then foundGankers = g.deaths > 0 and g.bounties > 0 end end
check(foundGankers, "Test Gankers has deaths and a bounty")
local raced = ns.Model:GetBountyInfo(again2)
check(raced.hunter == "Test Hunter", "earliest kill wins, got "..tostring(raced.hunter))

-- Leaderboards, going rate, activity, and a refresh of every page after all that
local hunters, posters = ns.Model:GetLeaderboards()
check(#hunters == 2 and hunters[1].origin == "Test Hunter" and hunters[1].kills == 4, "two hunters, the test hunter first with 4 kills")
check(#posters == 2, "two posters")
check(ns.Model:GetGoingRate(22, 10000), "going rate text")
check(#ns.Model:GetActivity() > 0, "activity has entries")
for _, key in ipairs({ "board", "mine", "hunters", "activity", "tools" }) do
	ns.UI:Show(key)
end
ns.UI:Toggle()
ns.UI:Toggle()
ns.Minimap:Update()
ns:RunCommand("purge", "")
check(#ns.Model:GetBoard({ minAmount = 0, showPassed = true }) == 2, "purge leaves the reposted bounty and the guild bounty")

-- Enemy detection: a nameplate appears, gets listed, alerts, targets us, casts stealth
local STAB = { guid = "Player-9-ENEMY", name = "Stabby Mcstab", class = "ROGUE", level = 19, guild = "Test Gankers", targetsMe = true }
enemyUnits.nameplate1 = STAB
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
local near = ns.Enemies:GetNearby()
check(#near == 1 and near[1].name == "Stabby Mcstab" and near[1].guild == "Test Gankers", "enemy listed as nearby")
check(ns.Enemies:GetStats("Player-9-ENEMY").detections == 1, "detection counted")
ns.NearbyWindow:SetShown(true)
ns.NearbyWindow:Refresh()
ns.Enemies:SetKoS("Player-9-ENEMY", "Stabby Mcstab", true)
ns.Enemies:SetReason("Player-9-ENEMY", "camps the road")
check(ns.Enemies:Describe("Player-9-ENEMY").reason == "camps the road", "KoS reason")
Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "cast", 1784)
check(ns.Enemies:Describe("Player-9-ENEMY").stealthed, "stealth seen")
-- We kill them: the client's kill event records a kill and a win
Fire("PARTY_KILL", "Player-1-ME", "Player-9-ENEMY")
check(ns.Enemies:GetStats("Player-9-ENEMY").wins == 1, "win counted from the kill event")
local killRecorded = false
for record in ns.Store:Iterator("kill") do if record.data.victim == "Player-9-ENEMY" then killRecorded = true end end
check(killRecorded, "kill record from the kill event")
Fire("CHAT_MSG_COMBAT_HONOR_GAIN", "Stabby Mcstab dies, honorable kill Rank: Private")
local kills = 0
for record in ns.Store:Iterator("kill") do if record.data.victim == "Player-9-ENEMY" then kills = kills + 1 end end
check(kills == 1, "honor message doesn't duplicate the kill")
-- They kill us: the one enemy targeting us gets the loss
ns.Enemies:SetIgnored("Player-9-ENEMY", "Stabby Mcstab", false)
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
Fire("PLAYER_DEAD")
RunTimers()
check(ns.Enemies:GetStats("Player-9-ENEMY").losses == 1, "loss from the enemy targeting us")
-- Targeting: the enemy targets us, the warning comes up and stays, then clears when they stop
ns.Enemies:SetIgnored("Player-9-ENEMY", "Stabby Mcstab", false)
enemyUnits.nameplate1 = STAB
STAB.targetsMe = true
Fire("UNIT_TARGET", "nameplate1")
check(#ns.Enemies:GetTargeters() == 1, "targeting noticed at once")
ns.Alerts:SetHudMoving(true)
ns.Alerts:SetHudMoving(false)
STAB.targetsMe = false
Fire("UNIT_TARGET", "nameplate1")
check(#ns.Enemies:GetTargeters() == 0, "targeting cleared when they switch")
STAB.targetsMe = true
-- The client's death event for a watched enemy is a witnessed death
local deathsBefore = 0
for _ in ns.Store:Iterator("death") do deathsBefore = deathsBefore + 1 end
clock = clock + 60
Fire("UNIT_DIED", "Player-9-ENEMY")
local deathsAfter = 0
for _ in ns.Store:Iterator("death") do deathsAfter = deathsAfter + 1 end
check(deathsAfter == deathsBefore + 1, "UNIT_DIED records a witnessed death")
-- A party member's kill is a witnessed death naming the killer
Fire("PARTY_KILL", "Player-2-FRIEND", "Player-9-ENEMY")
local witnessed = false
for record in ns.Store:Iterator("death") do if record.data.killer == "Player-2-FRIEND" then witnessed = true end end
check(witnessed, "party kill recorded as a witnessed death")
-- A sighting shared by another user
ns.Enemies:OnSharedSighting({ g = "Player-9-OTHER", n = "Sneaky Pete", c = "MAGE", l = 20, z = "The Barrens", m = 10, x = 50, y = 40 }, "Some Friend")
check(ns.Store:GetPlayer("Player-9-OTHER").name == "Sneaky Pete", "shared sighting stored")
check(#ns.Enemies:GetLastHour() >= 2, "last hour lists both")
-- Menus, lists, ignore, and every page again
ns.EnemyMenu:Show(ns.Enemies:Describe("Player-9-ENEMY"))
-- The reason dialog from the Nearby window with the main window closed
if ns.UI:IsShown() then ns.UI:Toggle() end
ns.EnemyMenu:SetReason(ns.Enemies:Describe("Player-9-ENEMY"))
ConfirmDialog("still camps")
check(ns.Enemies:Describe("Player-9-ENEMY").reason == "still camps", "reason saved from the dialog")
ns.Enemies:SetIgnored("Player-9-OTHER", "Sneaky Pete", true)
check(#ns.Enemies:GetIgnoreList() == 1, "ignore list")
check(#ns.Enemies:GetAll("kos") == 1 and #ns.Enemies:GetAll() >= 2, "stats lists")
for _, view in ipairs({ "nearby", "hour", "kos", "ignore" }) do
	ns.db.settings.detect.tab = view
	ns.NearbyWindow:Refresh()
end
ns.db.settings.showTools = true
for _, key in ipairs({ "board", "mine", "enemies", "hotspots", "hunters", "activity", "settings", "tools" }) do
	ns.UI:Show(key)
end
ns.db.settings.showTools = false
ns.UI:Refresh()
-- A 40-player raid: compact rows, scrolling, the summary footer, and Last hour lists them all
local CLASSES = { "WARRIOR", "PRIEST", "MAGE", "ROGUE", "PALADIN" }
for i = 1, 40 do
	enemyUnits["nameplate"..(i + 1)] = { guid = format("Player-9-RAID%02d", i), name = "Raider Number"..i, class = CLASSES[i % 5 + 1], level = 20 }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate"..(i + 1))
end
ns.db.settings.detect.tab = "nearby"
ns.NearbyWindow:Refresh()
check(#ns.Enemies:GetNearby() >= 40, "raid all on Nearby")
check(#ns.Enemies:GetLastHour() >= 40, "raid all on Last hour, got "..#ns.Enemies:GetLastHour())
for i = 1, 40 do enemyUnits["nameplate"..(i + 1)] = nil end
-- Hotspots: the raid makes Durotar the busiest; three of one guild in the Barrens name that guild
for i = 1, 3 do
	ns.Store:UpdatePlayer("Player-9-GANK"..i, { name = "Ganker"..i, class = "WARRIOR", level = i == 3 and -1 or 30 + i, faction = "Alliance", guild = "Road Campers", zone = "The Barrens", mapId = 10 })
end
local function FindZone(list, zone)
	for _, group in ipairs(list) do
		if group.zone == zone then
			return group
		end
	end
end
local spots = ns.Hotspots:Get()
local durotar, barrens = FindZone(spots, "Durotar"), FindZone(spots, "The Barrens")
check(spots[1] == durotar and durotar.mapId == 1 and durotar.recent >= 40, "Durotar is the busiest hotspot, got "..tostring(spots[1] and spots[1].zone))
check(durotar.deaths >= 1, "the kill in Durotar joins the Durotar hotspot by name")
check(durotar.trend == "up", "the raid makes Durotar rising, got "..tostring(durotar.trend))
check(barrens and barrens.guild == "Road Campers" and barrens.guildCount == 3, "three of one guild are named")
check(barrens.hour == 3, "the ignored enemy in the Barrens is left out, got "..tostring(barrens and barrens.hour))
check(ns.Hotspots:FormatLevels(barrens) == "31-32 + ??", "level range with a skull, got "..ns.Hotspots:FormatLevels(barrens))
check(#ns.Hotspots:GetTop(3) == 2, "two zones busy now")
check(ns.Hotspots:OpenMap(durotar) and mapOpened == 1, "clicking a hotspot opens its map")
ns.UI:Show("hotspots")
WantedDeadOrDead_OnCompartmentEnter(nil, NewMock())
-- The world map: markers come through the map's own pin system, in their own layer under group members
check(insertedLevel == "PIN_FRAME_LEVEL_WANTED_ENEMY below PIN_FRAME_LEVEL_GROUP_MEMBER", "own map layer, got "..tostring(insertedLevel))
ns.MapPins:Refresh()
check(#WorldMapFrame.pins >= 40, "a marker per enemy seen on this map, got "..#WorldMapFrame.pins)
local pin = WorldMapFrame.pins[1]
check(pin._levelType == "PIN_FRAME_LEVEL_WANTED_ENEMY" and pin._x > 0 and pin._x < 1, "marker in our layer at a map position")
pin:OnMouseEnter()
pin:OnMouseLeave()
-- Show / hide from the map's filter menu
local checkbox
local root = { CreateDivider = function() end, CreateTitle = function() end, CreateCheckbox = function(_, text, isSelected, setSelected) checkbox = { text = text, isSelected = isSelected, setSelected = setSelected } end }
menus.MENU_WORLD_MAP_TRACKING(nil, root)
check(checkbox and checkbox.text == "Enemy sightings" and checkbox.isSelected(), "map filter menu has a checked Enemy sightings entry")
checkbox.setSelected()
check(not ns.db.settings.detect.mapPins and #WorldMapFrame.pins == 0, "unchecking it hides the markers")
ns.UI:Show("hotspots")
ns.MapPins:SetShown(true)
check(#WorldMapFrame.pins >= 40 and checkbox.isSelected(), "the Hotspots switch brings them back")
-- 20 minutes on nobody is there now: Durotar is quiet and falling, but still in the hour
local savedClock = clock
clock = clock + 20 * 60
durotar = FindZone(ns.Hotspots:Get(), "Durotar")
check(durotar.recent == 0 and durotar.hour >= 40 and durotar.trend == "down", "Durotar quiet and falling later, got "..tostring(durotar.trend))
check(#ns.Hotspots:GetTop(3) == 0, "no zone busy now")
ns.UI:Refresh()
-- After an hour it drops off
clock = clock + 3600
check(FindZone(ns.Hotspots:Get(), "The Barrens") == nil, "the Barrens drops off after an hour")
clock = savedClock
-- Display settings: every option off, compact forced, then back
local show = ns.db.settings.nearby
for _, key in ipairs({ "icon", "className", "level", "guild", "bounty", "kos", "state", "record", "health", "tint", "targeting", "fade" }) do show[key] = false end
show.layout = "compact"
show.opacity = 0.5
ns.NearbyWindow:ForceLayout()
show.layout = "normal"
for _, key in ipairs({ "icon", "className", "level", "guild", "bounty", "kos", "state", "record", "health", "tint", "targeting", "fade" }) do show[key] = true end
ns.NearbyWindow:ForceLayout()
ns.UI:Show("settings")
-- Versions: newer releases are noticed from other clients' hellos, never shown as sent
check(ns:IsNewerVersion("0.1.0-beta.2", "0.1.0-beta.1"), "beta 2 is newer than beta 1")
check(ns:IsNewerVersion("0.1.0", "0.1.0-beta.9"), "a release is newer than its betas")
check(ns:IsNewerVersion("0.1.0-beta.1", "0.1.0-alpha.3"), "beta is newer than alpha")
check(ns:IsNewerVersion("1.0.0", "0.9.9"), "major wins")
check(not ns:IsNewerVersion("0.1.0-beta.1-dev", "0.1.0-beta.1"), "a dev build is not newer")
check(not ns:IsNewerVersion("@project-version@", "0.1.0"), "an unpackaged version is ignored")
ns:NoteVersion("0.0.9")
check(ns.newerVersion == nil, "an older peer is not news")
-- A real hello, sent as version 0.3.0, comes back from another player
ns.VERSION = "0.3.0"
addonSent = {}
clock = clock + 61 -- the earlier tests used up this minute's send limit
SlashCmdList.WANTED("synctest")
ns.VERSION = "0.1.0"
check(#addonSent == 1 and addonSent[1].text:find("^H:"), "the sync test sends a hello")
local hello = addonSent[1].text:gsub("^H:%w+:", "H:zz9:")
Fire("CHAT_MSG_ADDON", "WNTD", hello, "CHANNEL", "Other Player", nil, nil, nil, "WantedNetHorde")
check(ns.newerVersion == "0.3.0", "a newer peer's version is noticed, got "..tostring(ns.newerVersion))
ns:NoteVersion("0.2.5")
check(ns.newerVersion == "0.3.0", "an older one doesn't replace it")
ns:NoteVersion("0.4.0|cffff0000evil")
check(ns.newerVersion == "0.4.0", "peer text is rebuilt, not shown as sent, got "..tostring(ns.newerVersion))
WantedDeadOrDead_OnCompartmentEnter(nil, NewMock())
check(ns.Report:Build():find("newer version seen: 0.4.0", 1, true), "the bug report names the newer version")
-- Sync under load: a 40-player raid goes out as a few batched messages within the sightings budget, and
-- never holds up the records
clock = clock + 61
addonSent = {}
for i = 1, 40 do
	enemyUnits["nameplate"..(i + 1)] = { guid = format("Player-9-INVADE%02d", i), name = "Invader Number"..i, class = CLASSES[i % 5 + 1], level = 24 }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate"..(i + 1))
end
RunTimers()
local sightingParts, singleParts = 0, 0
for _, m in ipairs(addonSent) do
	if m.text:find("^S:") then sightingParts = sightingParts + 1 elseif m.text:find("^E:") then singleParts = singleParts + 1 end
end
check(singleParts == 0 and sightingParts >= 1 and sightingParts <= 6, "raid sightings batched within budget, got "..sightingParts.." batch parts and "..singleParts.." single")
check(not ns.Sync:GetInfo().paused, "a raid doesn't pause sync")
addonSent = {}
SlashCmdList.WANTED("synctest")
check(#addonSent == 1 and addonSent[1].text:find("^H:"), "records still go out after the raid")
for i = 1, 40 do enemyUnits["nameplate"..(i + 1)] = nil end
-- Another player's batch: stored, shown, and not sent again by us
local LibSerialize, LibDeflate = LibStub("LibSerialize"), LibStub("LibDeflate")
local function Message(tag, tbl)
	return tag..":zz"..tag..":1/1:"..LibDeflate:EncodeForWoWAddonChannel(LibDeflate:CompressDeflate(LibSerialize:Serialize(tbl)))
end
Fire("CHAT_MSG_ADDON", "WNTD", Message("S", { s = { { g = "Player-9-SHARED", n = "Shared Sam", c = "MAGE", l = 25, z = "The Barrens", m = 10, x = 50, y = 50 } } }), "CHANNEL", "Other Player", nil, nil, nil, "WantedNetHorde")
check(ns.Store:GetPlayer("Player-9-SHARED") and ns.Store:GetPlayer("Player-9-SHARED").seenBy == "Other Player", "a shared batch is stored")
local skippedBefore = ns.Sync:GetInfo().stats.skipped
ns.Sync:QueueSighting({ g = "Player-9-SHARED", n = "Shared Sam" }, false)
check(ns.Sync:GetInfo().stats.skipped == skippedBefore + 1, "an enemy someone just shared isn't sent again")
-- A first-version single sighting is still understood
Fire("CHAT_MSG_ADDON", "WNTD", Message("E", { g = "Player-9-OLDCLIENT", n = "Old Client", z = "Durotar", m = 1, x = 40, y = 40 }), "CHANNEL", "Older Player", nil, nil, nil, "WantedNetHorde")
check(ns.Store:GetPlayer("Player-9-OLDCLIENT") ~= nil, "a single sighting from an older client is stored")
-- The game throttles a message: it is sent again a few seconds later
addonSent = {}
throttleNext = 1
local throttledBefore = ns.Sync:GetInfo().stats.throttled
SlashCmdList.WANTED("synctest")
check(ns.Sync:GetInfo().stats.throttled == throttledBefore + 1 and #addonSent == 0, "throttled message counted, nothing sent")
RunTimers()
check(#addonSent == 1 and addonSent[1].text:find("^H:"), "throttled message sent again")
-- A corpse we come across is not a new death; someone we saw alive who then dies is
local function CountDeaths() local n = 0 for _ in ns.Store:Iterator("death") do n = n + 1 end return n end
local deathsNow = CountDeaths()
enemyUnits.nameplate30 = { guid = "Player-9-CORPSE", name = "Lying Dead", class = "MAGE", level = 20, dead = true }
Fire("NAME_PLATE_UNIT_ADDED", "nameplate30")
Fire("UNIT_HEALTH", "nameplate30")
check(CountDeaths() == deathsNow, "a corpse at first sight records no death")
enemyUnits.nameplate31 = { guid = "Player-9-DIESNOW", name = "About Todie", class = "MAGE", level = 20 }
Fire("NAME_PLATE_UNIT_ADDED", "nameplate31")
Fire("UNIT_HEALTH", "nameplate31")
enemyUnits.nameplate31.dead = true
Fire("UNIT_HEALTH", "nameplate31")
check(CountDeaths() == deathsNow + 1, "seen alive, then dead: one death")
Fire("UNIT_HEALTH", "nameplate31")
check(CountDeaths() == deathsNow + 1, "the corpse doesn't die twice")
enemyUnits.nameplate30, enemyUnits.nameplate31 = nil, nil
-- A blocked action is noted with what was going on
Fire("ADDON_ACTION_BLOCKED", "WantedDeadOrDead", "UNKNOWN()")
check(ns.Report:Build():find("ADDON_ACTION_BLOCKED: UNKNOWN() (out of combat", 1, true), "blocked action noted with context")
-- Bug report and the beta welcome
ns:NoteProblem("test problem")
local report = ns.Report:Build()
check(report:find("test problem", 1, true) and report:find("Game client 1.60.1", 1, true), "bug report text")
ns.Report:Show()
ns.db.welcomed = nil
ns.UI:Show("board")
RunTimers()
-- Call for help: finds Local Defense by its zone channel id, lists who's around (whoever is on you first),
-- stays within a chat line, and waits a few seconds between calls to the same channel
enemyUnits.nameplate1.targetsMe = true
for _, f in ipairs(tickers) do f() end
local localDefense = nil
C_ChatInfo.GetChannelInfoFromIdentifier = function(id) if id == localDefense then return { name = "LocalDefense - Durotar", zoneChannelID = 22, localID = 4 } end end
check(ns.EnemyMenu:GetLocalDefenseChannel() == nil, "no Local Defense channel here")
check(not ns.EnemyMenu:CallForHelp("CHANNEL"), "no call without Local Defense")
localDefense = "4"
check(ns.EnemyMenu:GetLocalDefenseChannel() == 4, "Local Defense found as channel 4")
local help = ns.EnemyMenu:BuildHelpText()
check(help:find("^Need help at Durotar 45,25 %- %d+ enem") and help:find("Stabby Mcstab %d+ Rogue %(on me%)") and help:find("%+%d+ more$") and #help <= 255 and not help:find("|", 1, true), "help text: "..help)
check(help:find("Stabby Mcstab", 1, true) < (help:find("Invader", 1, true) or 1e9), "whoever is on you comes first")
chatSent = {}
check(ns.EnemyMenu:CallForHelp("CHANNEL") and chatSent[1] and chatSent[1]:find("^CHANNEL: Need help"), "help sent to Local Defense")
check(not ns.EnemyMenu:CallForHelp("CHANNEL"), "a second call right away waits")
check(ns.EnemyMenu:CallForHelp("GUILD"), "the guild is a separate channel")
ns.EnemyMenu:ShowHelpMenu()
ns.EnemyMenu:Show(ns.Enemies:Describe("Player-9-ENEMY"))
enemyUnits.nameplate1.targetsMe = nil
-- A zone filling up fast gets one RISING FAST warning, not one per check
local warnings = {}
local realWarn = ns.Alerts.Warn
ns.Alerts.Warn = function(self, title, ...) warnings[#warnings + 1] = title return realWarn(self, title, ...) end
local surgeClock = clock
clock = clock + 11 * 60
for i = 1, 6 do
	local guid = "Player-9-SURGE"..i
	ns.Store:UpdatePlayer(guid, { name = "Surger"..i, class = "WARRIOR", level = 25, faction = "Alliance", zone = "The Barrens", mapId = 10, x = 50, y = 50 })
	ns.Store:AddSighting(guid, "The Barrens", 50, 50, 10)
end
local surging = ns.Hotspots:GetSurging()
check(#surging == 1 and surging[1].zone == "The Barrens" and surging[1].recent == 6, "the Barrens is rising fast, got "..tostring(surging[1] and surging[1].zone))
ns.Hotspots:CheckSurges()
ns.Hotspots:CheckSurges()
check(#warnings == 1 and warnings[1] == "RISING FAST: The Barrens", "one rising warning, got "..#warnings)
ns.db.settings.detect.risingAlerts = false
warnings = {}
clock = clock + 16 * 60
for i = 7, 12 do
	ns.Store:UpdatePlayer("Player-9-SURGE"..i, { name = "Surger"..i, class = "MAGE", level = 25, faction = "Alliance", zone = "The Barrens", mapId = 10 })
	ns.Store:AddSighting("Player-9-SURGE"..i, "The Barrens", 50, 50, 10)
end
ns.Hotspots:CheckSurges()
check(#warnings == 0, "no rising warning when switched off")
ns.db.settings.detect.risingAlerts = true
ns.Alerts.Warn = realWarn
ns.UI:Show("hotspots")
ns.UI:Show("settings")
clock = surgeClock
-- Leaving: out of view the enemy still shows as in sight for a minute, then shaded for 30s, then leaves
local function Tick() for _, f in ipairs(tickers) do f() end end
Tick() -- a scan while their nameplate is still up
enemyUnits.nameplate1 = nil
Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
local function Near(guid) for _, d in ipairs(ns.Enemies:GetNearby()) do if d.guid == guid then return d end end end
clock = clock + 45
Tick()
check(Near("Player-9-ENEMY") and Near("Player-9-ENEMY").inSight, "45s out of view still shows as in sight")
clock = clock + 30
Tick()
check(Near("Player-9-ENEMY") and not Near("Player-9-ENEMY").inSight, "75s out of view is listed but shaded")
ns.NearbyWindow:Refresh()
clock = clock + 20
Tick()
check(not Near("Player-9-ENEMY"), "95s out of view has left the list")
-- The settings change the timing
ns.db.settings.detect.inSight, ns.db.settings.detect.timeout = 120, 60
enemyUnits.nameplate1 = { guid = "Player-9-ENEMY", name = "Stabby Mcstab", class = "ROGUE", level = 22 }
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
Tick()
enemyUnits.nameplate1 = nil
Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
clock = clock + 100
Tick()
check(Near("Player-9-ENEMY") and Near("Player-9-ENEMY").inSight, "a 2 minute in-sight setting keeps them in sight at 100s")
clock = clock + 70
Tick()
check(Near("Player-9-ENEMY") and not Near("Player-9-ENEMY").inSight, "then shaded")
clock = clock + 60
Tick()
check(not Near("Player-9-ENEMY"), "then gone after 3 minutes")
ns.db.settings.detect.inSight, ns.db.settings.detect.timeout = 60, 30
RunTimers()
print("wanted smoke: all checks pass")
