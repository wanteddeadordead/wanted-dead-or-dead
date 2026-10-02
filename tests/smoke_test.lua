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
Mock.created = {} -- every frame made, so tests can find one by its fields
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
function Methods:GetUnboundedStringWidth() return #tostring(self._text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) * 6 end
function Methods:SetFontObject(font) self._font = font end
function Methods:SetWordWrap(wrap) self._wrap = wrap end
function Methods:GetFontObject() return self._font end
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
function Methods:SetAttribute(k, v) self._attrs = self._attrs or {} self._attrs[k] = v end
function Methods:GetAttribute(k) return self._attrs and self._attrs[k] end
function CreateFrame(kind, name, parent) local f = NewMock(kind) f._parent = parent if name then _G[name] = f end Mock.created[#Mock.created + 1] = f return f end
function Methods:GetParent() return self._parent or NewMock() end
function Methods:SetParent(parent) self._parent = parent end
function Methods:SetPoint(...) self._point = { ... } end
function Methods:SetScale(scale) self._scale = scale end
function Methods:CreateTexture() local t = NewMock("Texture") t._parent = self return t end
Mock.fontStrings = {} -- every font string made, so tests can find text on screen
function Methods:CreateFontString() local t = NewMock("FontString") t._parent = self Mock.fontStrings[#Mock.fontStrings + 1] = t return t end
function CreateColor(r, g, b, a) return { r = r, g = g, b = b, a = a } end
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
-- Frames passing: the addon's background work runs until it's done (as it would over the next frames)
function RunFrames()
	if WantedTestNS and WantedTestNS.DoQueuedWork then
		WantedTestNS:DoQueuedWork(1e9)
	end
end

local function RunTimers()
	for _ = 1, 5 do
		local batch = timers
		timers = {}
		for _, f in ipairs(batch) do f() end
		RunFrames()
		if #timers == 0 then return end
	end
end

-- Game state
clock = 1790270000
function GetServerTime() return clock end
function GetTime() return clock end
function debugprofilestop() return os.clock() * 1000 end
function UnitName(unit) if unit == "player" then return "Test", "Player" end return nil end
function UnitFactionGroup(unit) if unit and enemyUnits[unit] then return enemyUnits[unit].faction or "Alliance" end return "Horde" end
function UnitGUID(unit) if unit == "player" then return "Player-1-ME" end local e = enemyUnits[unit] return e and e.guid end
function UnitExists(unit) return enemyUnits[unit] ~= nil end
function UnitIsPlayer(unit) return enemyUnits[unit] ~= nil end
function GetRealmName() return "Realm" end
function GetNormalizedRealmName() return "Realm" end
function RegionalUniqueNamesEnabled() return true end
function GetZoneText() return "Durotar" end
local subZone = ""
function GetSubZoneText() return subZone end
function IsInInstance() return false end
-- The game's combat log switch; switching it off counts as writing out what the game held
combatLogging, combatLogWrites = false, 0
function LoggingCombat(on)
	if on ~= nil then
		if combatLogging and not on then combatLogWrites = combatLogWrites + 1 end
		combatLogging = on and true or false
	end
	return combatLogging
end
groupSize = 0
function GetNumGroupMembers() return groupSize end
hkCount = 0
function GetPVPSessionStats() return hkCount, 0 end
function GetChannelName() return 6 end
channelMembers = 0 -- global: the main chunk is at its limit of locals
displayChannels = 2 -- global, see channelMembers
function GetNumDisplayChannels() return displayChannels end
selectedDisplayChannel = nil -- the channel whose member list was last asked for
function ListChannelByName(name) selectedDisplayChannel = name end
function GetChannelDisplayInfo(i) if i == 1 then return "General", false, false, 1, 999, true, "CHANNEL_CATEGORY_WORLD" end return "WantedNetHorde", false, false, 6, channelMembers, true, "CHANNEL_CATEGORY_CUSTOM" end
local joinedWith = {}
function JoinPermanentChannel(name, password) joinedWith[#joinedWith + 1] = { name = name, password = password } end
local hiddenPopups = {}
function StaticPopup_Hide(which, data) hiddenPopups[#hiddenPopups + 1] = { which = which, data = data } end
leftChannels = {}
function LeaveChannelByName(name) leftChannels[#leftChannels + 1] = name end
-- Muted sound files, and how often the game was asked to mute and unmute (globals, see channelMembers)
mutedSounds, muteCalls, unmuteCalls = {}, 0, 0
function MuteSoundFile(file) mutedSounds[file] = true muteCalls = muteCalls + 1 end
function UnmuteSoundFile(file) mutedSounds[file] = nil unmuteCalls = unmuteCalls + 1 end
function hooksecurefunc() end
function GetInboxNumItems() return 0 end
function GetCursorPosition() return 0, 0 end
-- An enemy on nameplate1 and, when set, as the target
enemyUnits = {}
local function enemy(unit) return enemyUnits[unit] end
function GetUnitName(unit) local e = enemy(unit) return e and e.name end
function UnitIsEnemy(_, unit) local e = enemy(unit) return e ~= nil and (e.faction or "Alliance") ~= "Horde" end
function UnitClass(unit) if unit == "player" then return "Warrior", "WARRIOR" end local e = enemy(unit) return e and "Rogue", e and e.class end
function UnitLevel(unit) local e = enemy(unit) return e and e.level or 10 end
function UnitRace(unit) if unit == "player" then return "Orc", "Orc" end local e = enemy(unit) return e and (e.raceName or "Human"), e and (e.raceFile or "Human") end
function UnitSex(unit) if unit == "player" then return 2 end local e = enemy(unit) return e and (e.sex or 3) or 1 end
function UnitHealth(unit) return enemy(unit) and 50 or 100 end
function UnitHealthMax() return 100 end
function UnitIsUnit(a, b) local e = enemy((a:gsub("target$", ""))) return (e and e.targetsMe and b == "player") and true or false end
function UnitIsDeadOrGhost(unit) local e = enemyUnits[unit] return e and e.dead or false end
function CheckInteractDistance(unit, index) local e = enemyUnits[unit] return e and e.close == true or false end
playerOnTaxi = false
function UnitOnTaxi(unit) return unit == "player" and playerOnTaxi end
function GetGuildInfo(unit) local e = enemy(unit) return e and e.guild end
function GetPlayerInfoByGUID(guid)
	if guid == "Player-9-ENEMY" then return "Rogue", "ROGUE", "Human", "Human", 2, "Stabby Mcstab" end
	if guid == "Player-1-TAUREN" then return "Druid", "DRUID", "Tauren", "Tauren", 2, "Hoof Hearted" end
	if guid == "Player-1-ME" then return "Warrior", "WARRIOR", "Orc", "Orc", 2, "Test Player" end
	if guid == "Player-1-SKYHORDE" then return "Hunter", "HUNTER", "Horde Skyborne", "Skyborne", 2, "Sky Ours" end
	if guid == "Player-9-SKYALLY" then return "Hunter", "HUNTER", "High Order Skyborne", "Skyborne", 2, "Sky Theirs" end
	return nil
end
inCombat = false
function InCombatLockdown() return inCombat end
pvpFlag, pvpTimer = false, nil
function UnitIsPVP(unit) return unit == "player" and pvpFlag end
function UnitIsPVPFreeForAll() return false end
pvpSanctuary = false
function UnitIsPVPSanctuary() return pvpSanctuary end
function IsPVPTimerRunning() return pvpTimer ~= nil end
function GetPVPTimer() return pvpTimer or 301000 end
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
-- Named areas on the map as the world map's hover labels find them: { name, left, top, right, bottom }
local exploredAreas = {}
function CreateVector2D(x, y) return { x = x, y = y } end
C_Map.GetAreaInfo = function(areaId) return exploredAreas[areaId] and exploredAreas[areaId][1] end
C_Map.GetMapWorldSize = function() return 5000, 3333 end
C_MapExplorationInfo = { GetExploredAreaIDsAtPosition = function(_, pos)
	local ids = {}
	for id, a in pairs(exploredAreas) do
		if pos.x >= a[2] and pos.x <= a[4] and pos.y >= a[3] and pos.y <= a[5] then
			ids[#ids + 1] = id
		end
	end
	return #ids > 0 and ids or nil
end }
local mapOpened
function OpenWorldMap(mapId) mapOpened = mapId end
-- The world map's pin system, enough to drive a data provider
function CreateFromMixins(...) local t = {} for _, m in ipairs({ ... }) do for k, v in pairs(m) do t[k] = v end end return t end
MapCanvasPinMixin = { CheckMouseButtonPassthrough = function(self) self:SetPassThroughButtons() end, SetPassThroughButtons = function() error("protected: SetPassThroughButtons") end, SetScalingLimits = function() end, UseFrameLevelType = function(self, levelType) self._levelType = levelType end, SetPosition = function(self, x, y) self._x, self._y = x, y end, GetMap = function() return WorldMapFrame end }
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
	pin.Dot, pin.Count = NewMock(), NewMock()
	pin.SetSize = function() end
	pin:OnLoad()
	pin:OnAcquired(...)
	-- As the game's map does for every pin it hands out; the real SetPassThroughButtons is protected
	pin:CheckMouseButtonPassthrough("LeftButton", "RightButton")
	table.insert(self.pins, pin)
	return pin
end
WorldMapFrame.WorldMapTrackingOptionsButton = NewMock()
local optionsCategory
Settings = {
	RegisterCanvasLayoutCategory = function(frame, name) optionsCategory = { frame = frame, name = name } return optionsCategory end,
	RegisterAddOnCategory = function(category) category.registered = true end,
}
SettingsPanel = NewMock()
SettingsPanel.ExitWithCommit = function(self) self._shown = false end
screenshotResult = "SCREENSHOT_SUCCEEDED"
screenshots = 0
function Screenshot() screenshots = screenshots + 1 Fire(screenshotResult) end
cvars = {}
function GetCVar(name) return cvars[name] end
function SetCVar(name, value) cvars[name] = value end
local menus = {}
Menu = { ModifyMenu = function(tag, f) menus[tag] = f end }
local chatSent = {}
addonSent = {}
-- Chat filters (the realm links hide "No player named ..." for someone just greeted)
local chatFilters = {}
ChatFrameUtil = { AddMessageEventFilter = function(event, func) chatFilters[event] = func end }
-- Chat windows: the game lists a channel in a window when it was joined by hand there, and shows its notices
NUM_CHAT_WINDOWS = 2
removedChannels = {}
for i = 1, NUM_CHAT_WINDOWS do
	local frame = NewMock("ChatFrame")
	frame.RemoveChannel = function(_, name) removedChannels[#removedChannels + 1] = i..":"..name end
	_G["ChatFrame"..i] = frame
end
ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
-- Battle.net friends (Bridge): who each is in game, as C_BattleNet reports them
local bnFriends = {
	{ id = 101, program = "WoW", faction = "Alliance", realm = "Realm", name = "Ally Bridge" },
	{ id = 102, program = "WoW", faction = "Horde", realm = "Realm", name = "Horde Pal" },
	{ id = 103, program = "Pro" },
	{ id = 104, program = "WoW", faction = "Alliance", realm = "Other Realm", name = "Far Away" },
}
local bnSent = {}
local function BnGame(f) return f and { gameAccountID = f.id, isOnline = true, isAppearOffline = false, clientProgram = f.program, factionName = f.faction, realmName = f.realm, characterName = f.name, wowProjectID = f.program == "WoW" and (f.project or 1) or nil } end
WOW_PROJECT_ID = 1
-- Battle.net accounts by id, as GetAccountInfoByID shows them (the community's members); none = not shown
bnAccounts = {}
function BNGetNumFriends() return #bnFriends end
C_BattleNet = {
	GetFriendAccountInfo = function(i) return { bnetAccountID = 1000 + i, gameAccountInfo = BnGame(bnFriends[i]) } end,
	GetAccountInfoByID = function(id) local f = bnAccounts[id] return f and { bnetAccountID = id, gameAccountInfo = BnGame(f) } end,
	GetGameAccountInfoByID = function(id) for _, f in ipairs(bnFriends) do if f.id == id then return BnGame(f) end end end,
	SendGameData = function(id, prefix, data) bnSent[#bnSent + 1] = { id = id, prefix = prefix, data = data } end,
}
C_ChatInfo = { RegisterAddonMessagePrefix = function() return 0 end, SendAddonMessage = function(prefix, text, chatType, target)
	if throttleSkip and throttleSkip > 0 then throttleSkip = throttleSkip - 1
	elseif throttleNext and throttleNext > 0 then throttleNext = throttleNext - 1 return 3
	elseif lockdownNext and lockdownNext > 0 then lockdownNext = lockdownNext - 1 return 11 end
	addonSent[#addonSent + 1] = { prefix = prefix, text = text, chatType = chatType, target = target } return 0
end, SendChatMessage = function(msg, channel) chatSent[#chatSent + 1] = channel..": "..msg end }
C_AddOns = { GetAddOnMetadata = function() return "0.1.0-dev" end }
C_CurrencyInfo = { GetCoinTextureString = function(c) return tostring(c).."c" end }
C_Log = nil
Enum = { TooltipDataType = { Unit = 2 } }
tooltipPostCalls = {} -- global: the main chunk is at its limit of locals
TooltipDataProcessor = { AddTooltipPostCall = function(_, f) tooltipPostCalls[#tooltipPostCalls + 1] = f end }
RAID_CLASS_COLORS = { ROGUE = { r = 1, g = 0.96, b = 0.41, WrapTextInColorCode = function(_, t) return t end } }
LOCALIZED_CLASS_NAMES_MALE = { ROGUE = "Rogue" }
SlashCmdList = {}

-- Load the addon in .toc order
local ns = {}
WantedTestNS = ns
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

-- Gives a hand-made record the hash its contents make, as its origin's addon would (Store.lua's Canonical), so it
-- isn't flagged as altered
function Sealed(r) -- a global: the main chunk is at its limit of locals
	local keys = {}
	for key in pairs(r.data) do keys[#keys + 1] = key end
	table.sort(keys)
	local parts = { r.kind, r.id, r.prev, tostring(r.t) }
	for _, key in ipairs(keys) do parts[#parts + 1] = key.."="..tostring(r.data[key]) end
	r.hash = ns.Store:Hash(table.concat(parts, "\n"))
	return r
end

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
check(lastDialog and lastDialog.input and lastDialog.input.value:find("^https://wanteddeadordead.com/death/") and lastDialog.text:find("Before you pay", 1, true),
	"confirming a claim nobody witnessed warns first and gives the death's page")
ConfirmDialog()
local info = ns.Model:GetBountyInfo(board[1].bounty)
check(info.state == "owed" and info.actions[1] == "pay", "confirmed bounty is owed with pay, got "..info.state)
check(ns.Model:GetActionCount() == 1, "one thing waits: the payment")
ns.Rows:DoAction("pay", info)
ConfirmDialog()
ns:RunCommand("simulate", "paid")
check(ns.Model:GetBountyInfo(board[1].bounty).state == "paid", "paid after simulate paid")

-- Post a bounty through the board page, then raise it and dispute nothing
ns.Store:UpdatePlayer("Player-TEST-00000001", { name = "Corvin Ashdale", faction = "Alliance", level = 22 })
local bounty = ns.Bounties:Post("Player-TEST-00000001", "Corvin Ashdale", 20000)
check(bounty, "post works")
local mine = ns.Model:GetBountyInfo(bounty)
check(mine.state == "open" and mine.actions[2] == "raise", "own open bounty offers raise")
ns.Rows:DoAction("raise", mine)
ConfirmDialog("50s")
check(ns.Bounties:GetAmount(bounty) == 25000, "raise adds 50s")
check(ns.Bounties:Post("Player-TEST-00000001", "Corvin Ashdale", 500) == nil, "minimum enforced")
check(ns.Bounties:Post("Player-TEST-00000001", "Corvin Ashdale", 30000) == nil, "no second bounty on the same target")
check(mine.actions[1] == "withdraw" and mine.actions[2] == "raise", "own open bounty offers withdraw and raise")
ns.Rows:DoAction("withdraw", ns.Model:GetBountyInfo(bounty))
ConfirmDialog()
check(ns.Model:GetBountyInfo(bounty).state == "withdrawn", "withdrawn")
check(ns.Bounties:GetMyOpen("Player-TEST-00000001") == nil, "withdrawn bounty is not open")
local again = ns.Bounties:Post("Player-TEST-00000001", "Corvin Ashdale", 20000)
check(again, "can post again after withdrawing")
-- Another hunter commits: the poster can no longer withdraw
ns.Store:InsertTest("hunt", "Rhea Stormtide", { bounty = again.id }, clock)
local hunted = ns.Model:GetBountyInfo(again)
check(#hunted.hunters == 1 and hunted.actions[1] == "raise", "hunted bounty offers raise only")
check(not ns.Bounties:Withdraw(again), "withdraw refused while hunted")
-- A withdrawal record that raced a hunt does not count
ns.Store:InsertTest("withdraw", ns.Store:GetOrigin(), { bounty = again.id }, clock + 1)
check(not ns.Bounties:IsWithdrawn(again), "withdrawal during a hunt is void")
-- The hunt ends after a day, then a withdrawal counts
clock = clock + ns.Bounties.HUNT_SECONDS + 10
check(#ns.Bounties:GetActiveHunters(again) == 0, "hunt expired")
check(ns.Bounties:Withdraw(again), "withdraw allowed after the hunt lapsed")
check(ns.Bounties:IsWithdrawn(again), "withdrawn after the hunt lapsed")
local again2 = ns.Bounties:Post("Player-TEST-00000001", "Corvin Ashdale", 20000)
check(again2, "repost")
-- Two hunters on it; the later kill is filed first but the earlier kill wins
ns.Store:InsertTest("hunt", "Rhea Stormtide", { bounty = again2.id }, clock)
ns.Store:InsertTest("hunt", "Rival Hunter", { bounty = again2.id }, clock)
check(#ns.Bounties:GetActiveHunters(again2) == 2, "two hunters at once")
ns.Store:InsertTest("claim", "Rival Hunter", { bounty = again2.id, victim = "Player-TEST-00000001", victimName = "Corvin Ashdale", zone = "Durotar", killT = clock + 120 }, clock + 121)
ns.Store:InsertTest("claim", "Rhea Stormtide", { bounty = again2.id, victim = "Player-TEST-00000001", victimName = "Corvin Ashdale", zone = "Durotar", killT = clock + 60 }, clock + 200)
for _, item in ipairs(ns.Model:GetMyBounties()) do
	check(not ns.Model:IsFinished(item), "live list has no finished bounties")
end
local foundWithdrawn = false
for _, item in ipairs(ns.Model:GetMyHistory("poster")) do
	if item.state == "withdrawn" then foundWithdrawn = true end
end
check(foundWithdrawn, "withdrawn bounty is in history")
-- Guild bounty: posted on the guild, claimed by a member's kill
local guildBounty = ns.Bounties:PostGuild("Crimson Vanguard", "Alliance", 30000)
check(guildBounty, "guild bounty posts")
check(ns.Bounties:PostGuild("Crimson Vanguard", "Alliance", 30000) == nil, "one guild bounty per poster per guild")
check(ns.Bounties:PostGuild("Our Guild", "Horde", 30000) == nil, "no guild bounty on your own faction")
ns.Store:NewRecord("kill", { killer = "Player-1-ME", killerName = ns.Store:GetOrigin(), victim = "Player-TEST-00000001", victimName = "Corvin Ashdale", victimGuild = "Crimson Vanguard", deathId = "g1", zone = "Durotar", honor = true })
local guildClaimed = false
for claim in ns.Store:Iterator("claim") do
	if claim.data.bounty == guildBounty.id then guildClaimed = true end
end
check(not guildClaimed, "own guild bounty is not claimed by yourself")
local gboard = ns.Model:GetGuildBoard()
check(#gboard > 0 and gboard[1].name ~= nil, "guild board lists guilds")
local foundGankers = false
for _, g in ipairs(gboard) do if g.name == "Crimson Vanguard" then foundGankers = g.deaths > 0 and g.bounties > 0 end end
check(foundGankers, "Crimson Vanguard has deaths and a bounty")
local raced = ns.Model:GetBountyInfo(again2)
check(raced.hunter == "Rhea Stormtide", "earliest kill wins, got "..tostring(raced.hunter))

-- Leaderboards, going rate, activity, and a refresh of every page after all that
local hunters, posters = ns.Model:GetLeaderboards()
check(#hunters == 2 and hunters[1].origin == "Rhea Stormtide" and hunters[1].kills == 4, "two hunters, the test hunter first with 4 kills")
check(#posters == 2, "two posters")
check(ns.Model:GetGoingRate(22, 10000), "going rate text")
check(#ns.Model:GetActivity() > 0, "activity has entries")
for _, key in ipairs({ "board", "mine", "hunters", "activity", "tools" }) do
	ns.UI:Show(key)
end
ns.UI:Toggle()
ns.UI:Toggle()
ns.Minimap:Update()
-- The minimap button is LibDBIcon's, so button collectors find it; the old angle carries over as its position
do
	local DBIcon = LibStub("LibDBIcon-1.0")
	local listed = false
	for _, name in ipairs(DBIcon:GetButtonList()) do listed = listed or name == "WantedDeadOrDead" end
	check(listed, "the minimap button is registered with LibDBIcon")
	check(ns.db.settings.minimap.minimapPos == ns.db.settings.minimap.angle, "the saved angle becomes LibDBIcon's position")
	local button = DBIcon:GetMinimapButton("WantedDeadOrDead")
	button:Hide() -- as a button collector does when it takes the button into its bar
	ns.Minimap:Update()
	check(not button:IsShown(), "an update doesn't show a button a collector has hidden")
	ns.db.settings.minimap.hide = true
	ns.Minimap:Update()
	ns.db.settings.minimap.hide = false
	ns.Minimap:Update()
	check(button:IsShown(), "turning the button back on shows it")
end
ns:RunCommand("purge", "")
check(#ns.Model:GetBoard({ minAmount = 0, showPassed = true }) == 2, "purge leaves the reposted bounty and the guild bounty")

-- Enemy detection: a nameplate appears, gets listed, alerts, targets us, casts stealth
local STAB = { guid = "Player-9-ENEMY", name = "Stabby Mcstab", class = "ROGUE", level = 19, guild = "Crimson Vanguard", targetsMe = true }
enemyUnits.nameplate1 = STAB
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
local near = ns.Enemies:GetNearby()
check(#near == 1 and near[1].name == "Stabby Mcstab" and near[1].guild == "Crimson Vanguard", "enemy listed as nearby")
check(ns.Enemies:GetStats("Player-9-ENEMY").detections == 1, "detection counted")
ns.NearbyWindow:SetShown(true)
ns.NearbyWindow:Refresh()
ns.Enemies:SetKoS("Player-9-ENEMY", "Stabby Mcstab", true)
ns.Enemies:SetReason("Player-9-ENEMY", "camps the road")
check(ns.Enemies:Describe("Player-9-ENEMY").reason == "camps the road", "KoS reason")
Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "cast", 1784)
check(ns.Enemies:Describe("Player-9-ENEMY").stealthed, "stealth seen")
-- Vanish: the rogue is invisible by the time the cast arrives, so the nameplate no longer resolves; the
-- alarm still goes off for whoever that nameplate was, even just after the nameplate was removed
local stealthEvents = {}
ns.Enemies:OnChange(function(event, entry) if event == "stealth" then stealthEvents[#stealthEvents + 1] = entry end end)
local stabUnit = enemyUnits.nameplate1
enemyUnits.nameplate1 = nil
Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "cast", 1856)
check(#stealthEvents == 1 and stealthEvents[1].guid == "Player-9-ENEMY" and stealthEvents[1].stealthKind == "Vanish", "a Vanish from a nameplate that no longer resolves still raises the alarm")
Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "cast", 1857)
check(#stealthEvents == 2, "and just after its nameplate was removed")
clock = clock + 5
Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "cast", 26889)
check(#stealthEvents == 2, "but not long after, when the token may be someone else")
enemyUnits.nameplate1 = stabUnit
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
-- The game hides enemy spells (a secret value) and doesn't report Stealth or Vanish at all: the nameplate just
-- goes, and the target with it. Only your target counts (a nameplate also goes when the camera turns away,
-- and the target stays), and only within 28 yards (walking out of view drops both, far away).
SECRET_SPELL = setmetatable({}, { __tostring = function() return "secret" end })
function issecretvalue(value) return value == SECRET_SPELL end
for i = #stealthEvents, 1, -1 do stealthEvents[i] = nil end
local function Vanish(unit) Fire("NAME_PLATE_UNIT_REMOVED", unit) enemyUnits[unit] = nil enemyUnits.target = nil Fire("PLAYER_TARGET_CHANGED") RunTimers() end
local function Appear(unit, who) clock = clock + 10 enemyUnits[unit] = who enemyUnits.target = who Fire("NAME_PLATE_UNIT_ADDED", unit) Fire("PLAYER_TARGET_CHANGED") end
stabUnit.close = true
Appear("nameplate1", stabUnit)
Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "cast", SECRET_SPELL)
check(#stealthEvents == 0, "a hidden cast on its own is no alarm")
Vanish("nameplate1")
check(#stealthEvents == 1 and stealthEvents[1].guid == "Player-9-ENEMY" and stealthEvents[1].stealthKind == "Stealth", "your target gone from view within 28 yards went into stealth")
Appear("nameplate1", stabUnit)
Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
RunTimers()
check(#stealthEvents == 1, "the nameplate going while you keep the target (camera turned, a wall) is not stealth")
enemyUnits.target = nil
Fire("PLAYER_TARGET_CHANGED")
Appear("nameplate1", stabUnit)
enemyUnits.target = nil
Fire("PLAYER_TARGET_CHANGED")
Vanish("nameplate1")
check(#stealthEvents == 1, "someone you haven't targeted is not checked (no way to tell stealth from the camera)")
stabUnit.close = false
Appear("nameplate1", stabUnit)
clock = clock + 5
Vanish("nameplate1")
check(#stealthEvents == 1, "a rogue walking out of view far away is not stealth")
stabUnit.close = true
Appear("nameplate1", stabUnit)
stabUnit.close = false
clock = clock + 1
Vanish("nameplate1")
check(#stealthEvents == 2, "within 28 yards at the last scan a moment ago still counts")
stabUnit.close = true
Appear("nameplate1", stabUnit)
Fire("UNIT_SPELLCAST_STOP", "nameplate1")
Vanish("nameplate1")
check(#stealthEvents == 2, "a finished cast bar (Hearthstone, teleport) right before vanishing is not stealth")
Appear("nameplate1", stabUnit)
stabUnit.dead = true
Vanish("nameplate1")
stabUnit.dead = nil
check(#stealthEvents == 2, "a dead rogue's nameplate going is not stealth")
Appear("nameplate1", stabUnit)
playerOnTaxi = true
Vanish("nameplate1")
playerOnTaxi = false
check(#stealthEvents == 2, "nothing while you're on a flight path")
local warrior = { guid = "Player-9-WARRIOR", name = "War Rior", class = "WARRIOR", level = 20, close = true }
local mage = { guid = "Player-9-MAGE", name = "Frost Mage", class = "MAGE", level = 20, close = true }
local elf = { guid = "Player-9-ELF", name = "Night Hunter", class = "HUNTER", level = 20, raceFile = "NightElf", close = true }
Appear("nameplate1", stabUnit)
enemyUnits.nameplate60, enemyUnits.nameplate62 = warrior, mage
Fire("NAME_PLATE_UNIT_ADDED", "nameplate60")
Fire("NAME_PLATE_UNIT_ADDED", "nameplate62")
Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
Fire("NAME_PLATE_UNIT_REMOVED", "nameplate60")
Fire("NAME_PLATE_UNIT_REMOVED", "nameplate62")
enemyUnits.nameplate1, enemyUnits.nameplate60, enemyUnits.nameplate62 = nil, nil, nil
RunTimers()
check(#stealthEvents == 2, "every nameplate going at once (a loading screen) is not stealth")
Appear("nameplate60", warrior)
Vanish("nameplate60")
check(#stealthEvents == 2, "a warrior can't stealth")
Appear("nameplate62", mage)
Vanish("nameplate62")
check(#stealthEvents == 3 and stealthEvents[3].stealthKind == "Invisibility", "a mage close by is Invisibility")
Appear("nameplate61", elf)
Vanish("nameplate61")
check(#stealthEvents == 4 and stealthEvents[4].stealthKind == "Shadowmeld", "a night elf of any class can Shadowmeld")
stabUnit.close = nil
enemyUnits.nameplate1 = stabUnit
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
-- We kill them: the client's kill event records a kill and a win
Fire("PARTY_KILL", "Player-1-ME", "Player-9-ENEMY")
check(ns.Enemies:GetStats("Player-9-ENEMY").wins == 1, "win counted from the kill event")
local killRecorded = false
for record in ns.Store:Iterator("kill") do if record.data.victim == "Player-9-ENEMY" then killRecorded = true end end
check(killRecorded, "kill record from the kill event")
local ownKill
for record in ns.Store:Iterator("kill") do if record.data.victim == "Player-9-ENEMY" then ownKill = record.data end end
check(ownKill.victimClass == "ROGUE" and ownKill.victimRace == "Human" and ownKill.victimLevel == 19 and ownKill.victimFaction == "Alliance",
	"the kill names the victim's class, race, level and faction")
check(ownKill.killerClass == "WARRIOR" and ownKill.killerRace == "Orc" and ownKill.killerLevel == 10 and ownKill.killerFaction == "Horde",
	"the kill names our own class, race, level and faction")
check(ownKill.killerGroup == 1, "a kill made alone has a group of 1")
Fire("CHAT_MSG_COMBAT_HONOR_GAIN", "Stabby Mcstab dies, honorable kill Rank: Private")
local kills = 0
for record in ns.Store:Iterator("kill") do if record.data.victim == "Player-9-ENEMY" then kills = kills + 1 end end
check(kills == 1, "honor message doesn't duplicate the kill")
groupSize = 3
Fire("CHAT_MSG_COMBAT_HONOR_GAIN", "Never Seen dies, honorable kill Rank: Private")
local unseen
for record in ns.Store:Iterator("kill") do if record.data.victimName == "Never Seen" then unseen = record.data end end
check(unseen and unseen.victimFaction == "Alliance" and unseen.victimClass == nil and unseen.killerClass == "WARRIOR",
	"an honor kill of someone never seen still names their faction and ours, and guesses nothing else")
check(unseen.killerGroup == 3, "a kill in a party of three has a group of 3")
groupSize = 0
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
Fire("UNIT_TARGET", "nameplate1")
local hud = WantedTargetedHud
check(hud:IsShown() and hud:GetHeight() == 64, "the warning fits the title and one name, got "..tostring(hud:GetHeight()))
enemyUnits.nameplate9 = { guid = "Player-9-SECOND", name = "Second Hunter", class = "HUNTER", level = 22, targetsMe = true }
Fire("NAME_PLATE_UNIT_ADDED", "nameplate9")
Fire("UNIT_TARGET", "nameplate9")
check(#ns.Enemies:GetTargeters() == 2 and hud:GetHeight() == 84, "the warning grows a line for the second name, got "..tostring(hud:GetHeight()))
enemyUnits.nameplate9 = nil
Fire("NAME_PLATE_UNIT_REMOVED", "nameplate9")
-- The client's death event for a watched enemy is a witnessed death
local deathsBefore = 0
for _ in ns.Store:Iterator("death") do deathsBefore = deathsBefore + 1 end
clock = clock + 60
STAB.dead = true
Fire("UNIT_DIED", "Player-9-ENEMY")
RunTimers()
STAB.dead = nil
local deathsAfter = 0
for _ in ns.Store:Iterator("death") do deathsAfter = deathsAfter + 1 end
check(deathsAfter == deathsBefore + 1, "UNIT_DIED records a witnessed death")
local seenDeath
for record in ns.Store:Iterator("death") do seenDeath = record.data end
check(seenDeath.victimClass == "ROGUE" and seenDeath.victimLevel == 19 and seenDeath.victimFaction == "Alliance" and seenDeath.killerClass == nil,
	"a witnessed death names the victim's class, level and faction")
-- A party member's kill is a witnessed death naming the killer
Fire("PARTY_KILL", "Player-2-FRIEND", "Player-9-ENEMY")
local witnessed = false
local partyDeath
for record in ns.Store:Iterator("death") do if record.data.killer == "Player-2-FRIEND" then witnessed, partyDeath = true, record.data end end
check(witnessed, "party kill recorded as a witnessed death")
check(partyDeath.victimClass == "ROGUE" and partyDeath.killerFaction == "Horde" and partyDeath.killerClass == nil,
	"a party member's kill names the victim and our faction for the killer, no guessed class")
check(partyDeath.killerGroup == nil, "only our own kills carry a group size")
-- A sighting shared by another user
ns.Enemies:OnSharedSighting({ g = "Player-9-OTHER", n = "Sneaky Pete", c = "MAGE", l = 20, z = "The Barrens", m = 10, x = 50, y = 40 }, "Some Friend")
check(ns.Store:GetPlayer("Player-9-OTHER").name == "Sneaky Pete", "shared sighting stored")
check(#ns.Enemies:GetLastHour() >= 2, "last hour lists both")
-- A peer's name with a newline must never become a second macro line on a Nearby row: a click would run it
ns.Enemies:OnSharedSighting({ g = "Player-9-EVIL", n = "Evil Name\n/run Pwned=1\r/run Pwned=2|cff", c = "MAGE", l = 20, z = "The Barrens", m = 10, x = 50, y = 41 }, "Some Friend")
check(ns.Store:GetPlayer("Player-9-EVIL").name == "Evil Name/run Pwned=1/run Pwned=2cff", "shared name loses control characters and |")
ns.db.players["Player-9-OLDEVIL"] = { name = "Old Evil\n/run Pwned=3", faction = "Alliance", lastSeen = GetServerTime(), zone = "Ashenvale" }
do
ns.db.settings.detect.tab = "hour"
ns.NearbyWindow:Refresh()
local macros = 0
for _, f in ipairs(Mock.created) do
	local macro = f:GetAttribute("macrotext1")
	if type(macro) == "string" and macro:find("^/cleartarget") then
		macros = macros + 1
		for line in macro:gmatch("[^\n]+") do
			check(line:find("^/cleartarget$") or line:find("^/target"), "every Nearby macro line targets, got "..line)
		end
		check(not macro:find("\r"), "no carriage return in a Nearby macro")
	end
end
check(macros >= 2, "Nearby rows carry target macros, got "..macros)
end
ns.db.players["Player-9-OLDEVIL"], ns.db.players["Player-9-EVIL"] = nil, nil
ns.db.sightings[ns.db.sightingsPos], ns.db.sightingsPos = nil, ns.db.sightingsPos - 1
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
for _, key in ipairs({ "board", "mine", "hunts", "enemies", "hotspots", "hunters", "activity", "settings", "tools" }) do
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
;(function()
	local function NavBadge(title)
		for _, f in ipairs(Mock.created) do
			local label = rawget(f, "label")
			if type(label) == "table" and label._text == title and rawget(f, "badge") then
				return f.badge._shown and f.badge.text._text or nil
			end
		end
	end
	check(NavBadge("Hotspots") == "2", "the Hotspots menu item counts the busy zones, got "..tostring(NavBadge("Hotspots")))
end)()
WantedDeadOrDead_OnCompartmentEnter(nil, NewMock())
-- The world map: markers come through the map's own pin system, in their own layer under group members
check(insertedLevel == "PIN_FRAME_LEVEL_WANTED_ENEMY below PIN_FRAME_LEVEL_GROUP_MEMBER", "own map layer, got "..tostring(insertedLevel))
ns.MapPins:Refresh()
local markedEnemies = 0
for _, p in ipairs(WorldMapFrame.pins) do markedEnemies = markedEnemies + #p.group.members end
check(markedEnemies >= 40 and #WorldMapFrame.pins < markedEnemies, "enemies seen from one spot share a marker: "..#WorldMapFrame.pins.." markers for "..markedEnemies)
local pin = WorldMapFrame.pins[1]
for _, p in ipairs(WorldMapFrame.pins) do if #p.group.members > 1 then pin = p end end
check(pin.Count._text ~= "" and tonumber(pin.Count._text) == #pin.group.members, "a merged marker shows its count")
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
check(#WorldMapFrame.pins >= 1 and checkbox.isSelected(), "the Hotspots switch brings them back")
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
-- Your PvP status on the Nearby window
check(ns.NearbyWindow:GetPvPStatus() == "PvP off", "not flagged")
pvpFlag = true
check(ns.NearbyWindow:GetPvPStatus():find("^PvP ON"), "flagged")
pvpTimer = 272000
check(ns.NearbyWindow:GetPvPStatus() == "PvP ON, off in 4:32", "wearing off, got "..ns.NearbyWindow:GetPvPStatus())
pvpFlag, pvpTimer = false, nil
-- Display settings: every option off, compact forced, then back
local show = ns.db.settings.nearby
for _, key in ipairs({ "icon", "className", "level", "guild", "bounty", "kos", "state", "record", "health", "tint", "targeting", "fade", "pvp" }) do show[key] = false end
show.layout = "compact"
show.opacity = 0.5
ns.NearbyWindow:ForceLayout()
show.layout = "normal"
for _, key in ipairs({ "icon", "className", "level", "guild", "bounty", "kos", "state", "record", "health", "tint", "targeting", "fade", "pvp" }) do show[key] = true end
ns.NearbyWindow:ForceLayout()
ns.UI:Show("settings")
-- Versions: newer releases are noticed from other clients' hellos, never shown as sent
check(ns:IsNewerVersion("0.1.0-beta.2", "0.1.0-beta.1"), "beta 2 is newer than beta 1")
check(ns:IsNewerVersion("v0.1.0-beta.2", "v0.1.0-beta.1") and ns:IsNewerVersion("v0.2.0", "0.1.0-beta.1-dev"), "released versions carry a v and still compare")
check(not ns:IsNewerVersion("v0.1.0-beta.1", "0.1.0-beta.1-dev"), "a release and the dev build of it are the same version")
check(ns:IsNewerVersion("0.1.0", "0.1.0-beta.9"), "a release is newer than its betas")
check(ns:IsNewerVersion("0.1.0-beta.1", "0.1.0-alpha.3"), "beta is newer than alpha")
check(ns:IsNewerVersion("1.0.0", "0.9.9"), "major wins")
check(not ns:IsNewerVersion("0.1.0-beta.1-dev", "0.1.0-beta.1"), "a dev build is not newer")
check(not ns:IsNewerVersion("@project-version@", "0.1.0"), "an unpackaged version is ignored")
-- Only the "-dev" builds deploy.sh stamps are development builds: a copy straight from GitHub has no test data
-- commands or debug log either
check(ns:IsDevVersion("1.2.6-dev") and not ns:IsDevVersion("@project-version@") and not ns:IsDevVersion("1.2.6"), "only -dev versions are development builds")
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
-- The newest version wins: that newer peer locked the shared side until this client updates
check(ns:GetRequiredUpdate() == "0.4.0", "a newer version on the network requires an update, got "..tostring(ns:GetRequiredUpdate()))
;(function()
	local function Told(from)
		for i = from + 1, #printed do
			if printed[i]:find("outdated", 1, true) and printed[i]:find("https://www.curseforge.com/wow/addons/wanted-dead-or-dead", 1, true) then return true end
		end
	end
	check(Told(0), "the update notice says the version is outdated and where to download")
	local before = #printed
	check(ns:RemindUpdate() and Told(before), "each login repeats the update notice while this client is behind")
end)()
addonSent = {}
clock = clock + 61
ns:RunCommand("post", "1g Stabby Mcstab")
SlashCmdList.WANTED("synctest")
ns.Sync:QueueSighting({ g = "Player-9-LOCKTEST", n = "Lock Test" }, true)
RunTimers()
local sentWhileLocked = {}
for _, m in ipairs(addonSent) do sentWhileLocked[#sentWhileLocked + 1] = m.text:sub(1, 1) end
check(table.concat(sentWhileLocked) == "H", "locked: only a hello goes out, got "..table.concat(sentWhileLocked, ","))
ns.UI:Show("board")
ns.UI:Show("enemies")
WantedDeadOrDead_OnCompartmentEnter(nil, NewMock())
-- A made-up version far ahead doesn't lock anyone
ns.db.requiredVersion = nil
ns:NoteVersion("99.0.0")
check(ns:GetRequiredUpdate() == nil, "an implausible version is ignored")
-- Updating lifts the lock at load; so does nobody on that version being seen for three days
ns:NoteVersion("0.4.0")
ns.VERSION = "0.4.0"
ns:LoadSavedData()
check(ns:GetRequiredUpdate() == nil, "on the new version the lock is gone")
ns.VERSION = "0.1.0"
ns:NoteVersion("0.4.0")
clock = clock + 4 * 86400
ns:LoadSavedData()
check(ns:GetRequiredUpdate() == nil, "a version nobody has shown for days stops locking")
-- A player on an older version is told to update, privately, and their news isn't taken in
addonSent = {}
local LibSerialize0, LibDeflate0 = LibStub("LibSerialize"), LibStub("LibDeflate")
local function OldMessage(tag, tbl) return tag..":zo"..tag..":1/1:"..LibDeflate0:EncodeForWoWAddonChannel(LibDeflate0:CompressDeflate(LibSerialize0:Serialize(tbl))) end
Fire("CHAT_MSG_ADDON", "WNTD", OldMessage("S", { v = "0.0.5", s = { { g = "Player-9-OLDNEWS", n = "Old News", z = "Durotar", m = 1, x = 1, y = 1 } } }), "CHANNEL", "Old Timer", nil, nil, nil, "WantedNetHorde")
check(ns.Store:GetPlayer("Player-9-OLDNEWS") == nil, "an older version's news isn't taken in")
check(#addonSent == 1 and addonSent[1].text:find("^U:"), "the older player is told to update")
-- Every hidden whisper hides the game's "No player named ..." for its target, not just realm-link greetings: an
-- offline player told to update (or asked where everyone went) mustn't fill the chat with it
check(chatFilters.CHAT_MSG_SYSTEM(nil, "CHAT_MSG_SYSTEM", "No player named 'Old Timer' is currently playing.") == true,
	"the 'not online' for someone just told to update is hidden")
check(ns.db.addonVersions["Old Timer"] and ns.db.addonVersions["Old Timer"].v == "0.0.5", "the version book notes the older player's version")
-- And an update notice whispered to us locks us
Fire("CHAT_MSG_ADDON", "WNTD", OldMessage("U", { v = "0.2.0" }), "WHISPER", "New Timer")
check(ns:GetRequiredUpdate() == "0.2.0", "an update notice locks this client")
ns.db.requiredVersion, ns.newerVersion = nil, nil
-- 1.4.0 needs everyone on it (older versions pick channels themselves): a 1.3.x client hearing a 1.4.0 message locks
-- its shared side, and is told to update at once and at each login
ns.VERSION = "1.3.4"
Fire("CHAT_MSG_ADDON", "WNTD", OldMessage("H", { v = "1.4.0", c = {} }), "WHISPER", "New Hand")
check(ns:GetRequiredUpdate() == "1.4.0" and printed[#printed]:find("Wanted 1.4.0 is out", 1, true), "a 1.3.x client hearing 1.4.0 is told to update, and its sharing pauses")
ns.db.requiredVersion, ns.newerVersion = nil, nil
ns.VERSION = "0.1.0"
-- Only released versions count: a development build never locks anyone, tells anyone to update, or turns away
-- an older player's news
ns:NoteVersion("0.9.0-dev")
check(ns:GetRequiredUpdate() == nil and ns.newerVersion == nil, "a newer development build is not an update")
Fire("CHAT_MSG_ADDON", "WNTD", OldMessage("U", { v = "0.9.0-dev" }), "WHISPER", "Dev Timer")
check(ns:GetRequiredUpdate() == nil, "an update notice naming a development build is ignored")
ns.VERSION = "0.1.0-dev"
addonSent = {}
Fire("CHAT_MSG_ADDON", "WNTD", OldMessage("S", { v = "0.0.5", s = { { g = "Player-9-DEVNEWS", n = "Dev News", z = "Durotar", m = 1, x = 1, y = 1 } } }), "CHANNEL", "Older Timer", nil, nil, nil, "WantedNetHorde")
check(#addonSent == 0, "a development build tells nobody to update")
check(ns.Store:GetPlayer("Player-9-DEVNEWS") ~= nil, "a development build takes in an older player's news")
ns.VERSION = "0.1.0"
-- Crafted parts that don't fit their message's total are dropped, never a Lua error
Fire("CHAT_MSG_ADDON", "WNTD", "S:zbad:1/2:abc", "CHANNEL", "Bad Framer", nil, nil, nil, "WantedNetHorde")
Fire("CHAT_MSG_ADDON", "WNTD", "S:zbad:5/2:def", "CHANNEL", "Bad Framer", nil, nil, nil, "WantedNetHorde")
Fire("CHAT_MSG_ADDON", "WNTD", "S:zbad:2/3:ghi", "CHANNEL", "Bad Framer", nil, nil, nil, "WantedNetHorde")
Fire("CHAT_MSG_ADDON", "WNTD", "S:zzero:0/0:x", "CHANNEL", "Bad Framer", nil, nil, nil, "WantedNetHorde")
-- Saved data from a newer layout is left alone; older tables load and upgrade
local realDB = WantedDB
WantedDB = { version = 99, marker = true }
ns:LoadSavedData()
check(WantedDB.marker and ns.db ~= WantedDB and ns:GetNewerSavedLayout() == 99, "newer saved data is left untouched")
WantedDB = { records = {} }
ns:LoadSavedData()
check(WantedDB.version == ns.DB_VERSION and ns.db == WantedDB, "a table without a layout number loads as layout 1")
-- Layout 2 (1.4.0): a channel 1.3.x moved to, with its password, is dropped, and remembered once to be left
WantedDB = { version = 1, syncChannel = { e = 3, n = "WantedNetHordefsvltx", p = "wnt1", t = 5 }, homeCheck = { wait = 3600, tried = 9, home = 1 },
	settings = { channelMoves = false } }
ns:LoadSavedData()
check(WantedDB.version == 2 and WantedDB.syncChannel == nil and WantedDB.oldSyncChannel == "WantedNetHordefsvltx", "a 1.3.x channel is dropped on the upgrade")
check(WantedDB.homeCheck.wait == 300 and WantedDB.homeCheck.home == nil and WantedDB.settings.channelMoves == nil
	and WantedDB.syncChannelState.mainRefused == false and WantedDB.syncChannelState.epoch == 0, "with the main channel's tries and state starting afresh")
WantedDB = { version = 1, syncChannel = { e = 4, n = "WantedNetHorde", p = "wnt1", t = 5 } }
ns:LoadSavedData()
check(WantedDB.syncChannel == nil and WantedDB.oldSyncChannel == nil, "a 1.3.x move back to the main channel is dropped, with nothing to leave")
do
-- The launch: beta data keeps only its settings when the live world starts
check(ns.WORLD == "beta", "this release is for the beta")
WantedDB = { version = 1, settings = { minBounty = 500 }, welcomed = true, accountMark = "Mark123456789012", records = { ["A:1"] = {} }, kos = { g = {} },
	ignore = { g = {} }, players = { g = {} }, chains = { A = {} }, tracks = { g = {} }, enemyStats = { g = {} } }
ns:LoadSavedData()
check(WantedDB.world == "beta" and next(WantedDB.records) and next(WantedDB.kos), "the beta keeps its data")
ns.WORLD = "live"
ns:LoadSavedData()
check(WantedDB.world == "live" and WantedDB.settings.minBounty == 500 and WantedDB.welcomed and WantedDB.accountMark == "Mark123456789012",
	"the live world keeps settings and the account mark")
local function empty(t) return t == nil or next(t) == nil end
check(empty(WantedDB.records) and empty(WantedDB.kos) and empty(WantedDB.ignore) and empty(WantedDB.players)
	and empty(WantedDB.chains) and empty(WantedDB.tracks) and empty(WantedDB.enemyStats), "and drops the beta's data")
WantedDB.records = WantedDB.records or {}
WantedDB.records["B:1"] = {}
ns:LoadSavedData()
check(WantedDB.records["B:1"], "live data is never dropped again")
end
ns.WORLD = "beta"
WantedDB = realDB
ns:LoadSavedData()
check(ns.db == realDB, "back on the real data")
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
check(singleParts == 0 and sightingParts >= 1 and sightingParts <= 10, "raid sightings batched within budget, got "..sightingParts.." batch parts and "..singleParts.." single")
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
-- The game throttles a message: it waits, and is sent again a few seconds later
addonSent = {}
throttleNext = 1
local throttledBefore = ns.Sync:GetInfo().stats.throttled
SlashCmdList.WANTED("synctest")
check(ns.Sync:GetInfo().stats.throttled == throttledBefore + 1 and #addonSent == 0, "throttled message counted, nothing sent")
RunTimers()
check(#addonSent == 0, "a refused part waits for the game's allowance to come back (sent again: see the send queue tests)")
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
-- Feign Death: down, then up again before the death is confirmed
enemyUnits.nameplate31.dead = true
Fire("UNIT_HEALTH", "nameplate31")
enemyUnits.nameplate31.dead = nil
RunTimers()
check(CountDeaths() == deathsNow, "Feign Death isn't a death")
enemyUnits.nameplate31.dead = true
Fire("UNIT_HEALTH", "nameplate31")
RunTimers()
check(CountDeaths() == deathsNow + 1, "seen alive, then dead and still dead: one death")
Fire("UNIT_HEALTH", "nameplate31")
check(CountDeaths() == deathsNow + 1, "the corpse doesn't die twice")
enemyUnits.nameplate30, enemyUnits.nameplate31 = nil, nil
-- A blocked action is noted with what was going on
Fire("ADDON_ACTION_BLOCKED", "WantedDeadOrDead", "UNKNOWN()")
check(ns.Report:Build():find("ADDON_ACTION_BLOCKED: UNKNOWN() (out of combat", 1, true), "blocked action noted with context")
-- The reputation cast: good and bad records side by side
ns:RunCommand("simulate", "rep")
local R = ns.Reputation
local ace, shady = R:GetTally("Kaelen Duskbrand"), R:GetTally("Vorn Ashgrip")
local aceLevel, shadyLevel = R:GetRank(ace), R:GetRank(shady)
check(aceLevel >= 3 and ace.disputed == 0, "Kaelen: high level, got "..aceLevel)
check(shadyLevel == 0 and shady.disputed == 2 and shady.lone >= 1, "Vorn: level 0, 2 disputed, got level "..shadyLevel.." disputed "..shady.disputed)
check(R:GetTally("Grix Tallowbane").unpaid == 2, "Deadbeat: 2 unpaid, got "..R:GetTally("Grix Tallowbane").unpaid)
check(R:GetTally("Maribel Stonehollow").paid == 6 and R:GetTally("Maribel Stonehollow").unpaid == 0, "Honest: 6 paid, none unpaid")
check(R:GetHunterStars(ace) == 5 and R:GetHunterStars(shady) == 0.5, "stars: Kaelen 5, Vorn half a star, got "..tostring(R:GetHunterStars(ace)).." / "..tostring(R:GetHunterStars(shady)))
check(R:GetPosterStars(R:GetTally("Maribel Stonehollow")) == 5 and R:GetPosterStars(R:GetTally("Grix Tallowbane")) == 0.5, "poster stars: Maribel 5, Grix half")
check(R:GetHunterStars(R:GetTally("Nobody Atall")) == nil, "no record, no stars")
check(select(2, ns.Theme:Stars(3.5):gsub("|T", "")) == 5, "five star images")
check(R:GetHunterTrust(ace) == "Trusted" and R:GetHunterTrust(shady) == "Untrustworthy", "hunter trust: Kaelen trusted, Vorn untrustworthy, got "..tostring(R:GetHunterTrust(ace)).." / "..tostring(R:GetHunterTrust(shady)))
check(R:GetPosterTrust(R:GetTally("Maribel Stonehollow")) == "Trusted" and R:GetPosterTrust(R:GetTally("Grix Tallowbane")) == "Untrustworthy", "poster trust: Maribel trusted, Grix untrustworthy")
check(R:GetLine("Grix Tallowbane"):find("as a poster: Untrustworthy", 1, true), "rep line leads with trust")
for _, item in ipairs(ns.Model:GetBoard({ minAmount = 0 })) do ns.Rows:ShowBountyTooltip(NewMock(), item) end
check(R:GetLine("Grix Tallowbane"):find("2 UNPAID", 1, true) and R:GetLine("Vorn Ashgrip"):find("2 disputed", 1, true), "record lines show UNPAID and disputed")
local posters = {}
for _, item in ipairs(ns.Model:GetBoard({ minAmount = 0 })) do posters[item.poster] = true end
check(posters["Maribel Stonehollow"] and posters["Grix Tallowbane"], "both posters have open bounties on the Board")
local details = {}
for _, item in ipairs(ns.Model:GetBoard({ minAmount = 0 })) do details[#details + 1] = ns.Model:GetDetail(item) end
local all = table.concat(details, "\n")
check(all:find("By Grix Tallowbane |T", 1, true) and all:find("By Maribel Stonehollow |T", 1, true), "posters carry stars on their rows")
check(all:find("Vorn Ashgrip |T", 1, true) and all:find("Kaelen Duskbrand |T", 1, true), "hunters carry stars on their claims")
for _, key in ipairs({ "board", "mine", "hunters" }) do ns.UI:Show(key) end
-- Advice for each record
local meaning, advice = R:GetPosterAdvice(R:GetTally("Grix Tallowbane"))
check(meaning:find("as many claims unpaid") and advice:find("Pay your 2 unpaid claims"), "Grix is told to pay his 2 unpaid claims")
meaning, advice = R:GetHunterAdvice(R:GetTally("Vorn Ashgrip"))
check(advice:find("Disputes stay on your record"), "Vorn is told how disputes work")
meaning, advice = R:GetHunterAdvice(R:GetTally("Kaelen Duskbrand"))
check(advice:find("stay Trusted"), "Kaelen is told how to stay trusted")
ns:RunCommand("record", "")
check(ns.UI:IsShown("mine"), "/wanted record opens Your bounties")
ns.UI:Refresh()
meaning, advice = R:GetPosterAdvice(R:GetTally("Nobody Atall"))
check(meaning:find("haven't posted"), "no record: told how to start")
ns:RunCommand("rep", "Grix Tallowbane")
ns:RunCommand("purge", "")
check(R:GetTally("Kaelen Duskbrand").claims == 0, "purge clears the cast")
-- Kill proof: a kill that claims a bounty gets a stamped screenshot and a proof record on its claim
local function OwnClaimOn(guid)
	for claim in ns.Store:Iterator("claim") do
		if claim.data.victim == guid and claim.origin == ns.Store:GetOrigin() and not ns.Store:IsTest(claim) then return claim end
	end
end
enemyUnits.nameplate40 = { guid = "Player-9-ENEMY", name = "Stabby Mcstab", class = "ROGUE", level = 19 }
Fire("NAME_PLATE_UNIT_ADDED", "nameplate40")
local proofBounty = ns.Store:InsertTest("bounty", "Maribel Stonehollow", { target = "Player-9-ENEMY", targetName = "Stabby Mcstab", amount = 7000, level = 19, zone = "Durotar" }, clock - 60)
local shotsBefore = screenshots
Fire("PARTY_KILL", "Player-1-ME", "Player-9-ENEMY")
RunTimers()
local proofClaim = OwnClaimOn("Player-9-ENEMY")
check(proofClaim, "the kill claimed the bounty")
check(screenshots == shotsBefore + 1, "one screenshot for the kill")
local proof = ns.Proof:Get(proofClaim.id)
check(proof and proof.data.deathId == proofClaim.data.deathId, "a proof record on the claim")
local title, line1, line2 = ns.Proof:BuildStamp({ claims = { proofClaim }, victimName = "Stabby Mcstab", zone = "Durotar", key = proofClaim.data.deathId })
check(title == "WANTED: KILL PROOF" and line1:find("killed Stabby Mcstab in Durotar", 1, true) and line2:find("70s from Maribel Stonehollow", 1, true) and line2:find(proofClaim.data.deathId, 1, true), "the stamp names the kill, the bounty and the kill id: "..line1.." / "..line2)
-- In combat the screenshot waits for the fight to end (saving one hitches the game)
ns.Store:InsertTest("bounty", "Maribel Stonehollow", { target = "Player-9-ENEMY", targetName = "Stabby Mcstab", amount = 6000, level = 19, zone = "Durotar" }, clock - 5)
clock = clock + 30
inCombat = true
shotsBefore = screenshots
Fire("PARTY_KILL", "Player-1-ME", "Player-9-ENEMY")
RunTimers()
check(screenshots == shotsBefore, "no screenshot during combat")
inCombat = false
Fire("PLAYER_REGEN_ENABLED")
RunTimers()
check(screenshots == shotsBefore + 1, "the screenshot comes when combat ends")
-- A proof only counts from the hunter's own client
local otherBounty = ns.Store:InsertTest("bounty", "Maribel Stonehollow", { target = "Player-9-ENEMY", targetName = "Stabby Mcstab", amount = 100, level = 19, zone = "Durotar" }, clock)
local otherClaim = ns.Store:InsertTest("claim", "Vorn Ashgrip", { bounty = otherBounty.id, victim = "Player-9-ENEMY", zone = "Durotar", killT = clock }, clock)
ns.Store:InsertTest("proof", "Someone Else", { claim = otherClaim.id }, clock)
check(ns.Proof:Get(otherClaim.id) == nil, "a proof from someone other than the hunter doesn't count")
-- A failed screenshot writes no proof; switched off, no screenshot at all
screenshotResult = "SCREENSHOT_FAILED"
local proofsBefore = 0
for _ in ns.Store:Iterator("proof") do proofsBefore = proofsBefore + 1 end
ns.Store:InsertTest("bounty", "Maribel Stonehollow", { target = "Player-9-ENEMY", targetName = "Stabby Mcstab", amount = 5000, level = 19, zone = "Durotar" }, clock - 30)
clock = clock + 30
Fire("PARTY_KILL", "Player-1-ME", "Player-9-ENEMY")
RunTimers()
local proofsAfter = 0
for _ in ns.Store:Iterator("proof") do proofsAfter = proofsAfter + 1 end
check(proofsAfter == proofsBefore, "a failed screenshot writes no proof")
screenshotResult = "SCREENSHOT_SUCCEEDED"
ns.db.settings.proofShots = false
shotsBefore = screenshots
ns.Store:InsertTest("bounty", "Maribel Stonehollow", { target = "Player-9-ENEMY", targetName = "Stabby Mcstab", amount = 4000, level = 19, zone = "Durotar" }, clock - 10)
clock = clock + 30
Fire("PARTY_KILL", "Player-1-ME", "Player-9-ENEMY")
RunTimers()
check(screenshots == shotsBefore, "no screenshot when switched off")
ns.db.settings.proofShots = true
enemyUnits.nameplate40 = nil
-- The rep test data gives Kaelen's claim a proof, shown in its tooltip
ns:RunCommand("simulate", "rep")
local kaelenProof = false
for _, item in ipairs(ns.Model:GetMyBounties()) do
	if item.hunter == "Kaelen Duskbrand" and item.claim and ns.Proof:Get(item.claim.id) then kaelenProof = true end
	ns.Rows:ShowBountyTooltip(NewMock(), item)
end
check(kaelenProof, "Kaelen's test claim has a proof")
local proofRow = { buttons = {} }
for slot = 1, 2 do proofRow.buttons[slot] = NewMock() end
for _, item in ipairs(ns.Model:GetMyBounties()) do
	if item.hunter == "Kaelen Duskbrand" then
		local row = NewMock()
		ns.Rows:Create(row)
		ns.Rows:UpdateBounty(row, item)
		local found = false
		for _, button in ipairs(row.buttons) do
			if button.action == "confirm" and tostring(button.tooltipText):find("Kaelen Duskbrand has a screenshot", 1, true) then found = true end
		end
		check(found, "the Confirm button says Kaelen has a screenshot")
		ns.Rows:DoAction("confirm", item)
	end
end
ns.Store:InsertTest("kill", "Kaelen Duskbrand", { victim = "Player-TEST-00000777", victimName = "Only Test", victimGuild = "Test Only Guild", deathId = "testonly", zone = "The Barrens" }, clock)
for _, guild in ipairs(ns.Model:GetGuildBoard()) do check(guild.name ~= "Test Only Guild", "test data stays off the guild board") end
check(#ns.Tracks:Get("Player-TEST-00000101") >= 10 and ns.Tracks:Summarize(ns.Tracks:Get("Player-TEST-00000101")).days >= 5, "the rep test data gives its targets a history")
ns.UI:Show("settings")
ns:RunCommand("purge", "")
check(ns.db.tracks["Player-TEST-00000101"] == nil, "purge clears test histories")
-- Your hunts: a bounty you hunt shows there with its time left, and can be renewed or stopped
local huntBounty = ns.Store:InsertTest("bounty", "Maribel Stonehollow", { target = "Player-9-OTHER", targetName = "Sneaky Pete", amount = 6000, level = 20, zone = "The Barrens" }, clock - 60)
check(#ns.Model:GetMyHunts() == 0 or not ns.Model:GetBountyInfo(huntBounty).iHunt, "not hunting it yet")
ns.Bounties:Hunt(huntBounty)
local hunts = ns.Model:GetMyHunts()
local hunted
for _, item in ipairs(hunts) do if item.bounty == huntBounty then hunted = item end end
check(hunted and hunted.huntEnds and ns.Model:GetStateLabel(hunted) == "Hunting, "..ns.Theme:Left(ns.Bounties.HUNT_SECONDS), "the hunt shows its time left on the label, got "..(hunted and ns.Model:GetStateLabel(hunted) or "nothing"))
check(hunted.actions[1] == "stophunt" and hunted.actions[2] == "renew", "a hunt offers Stop and Renew")
ns.UI:Show("hunts")
check(ns.UI:IsShown("hunts"), "Your hunts is its own page")
ns.HuntsPage:ShowClaims()
check(ns.UI:IsShown("hunts"), "Your claims is on Your hunts")
ns:RunCommand("record", "hunter")
check(ns.UI:IsShown("hunts"), "/wanted record hunter opens Your hunts")
for _, item in ipairs(ns.Model:GetMyHistory("poster")) do check(item.state, "poster history holds only bounties") end
for _, item in ipairs(ns.Model:GetMyHistory("hunter")) do check(not item.state and item.claim, "hunter history holds only claims") end
ns.Rows:DoAction("renew", hunted)
ns.Rows:DoAction("stophunt", ns.Model:GetBountyInfo(huntBounty))
check(not ns.Model:GetBountyInfo(huntBounty).iHunt, "stopped")
-- Whereabouts of wanted players: kept for anyone with a bounty, merged within a minute, summarised
local clockBeforeTracks = clock
local trackedGuid, strangerGuid = "Player-9-TRACKED", "Player-9-STRANGER"
ns.Store:UpdatePlayer(trackedGuid, { name = "Wanted Walter", class = "PALADIN", level = 24, faction = "Alliance", guild = "Road Campers", zone = "The Barrens", mapId = 10 })
ns.Store:UpdatePlayer(strangerGuid, { name = "Passing Paul", class = "MAGE", level = 20, faction = "Alliance", zone = "The Barrens", mapId = 10 })
local trackedBounty = ns.Store:InsertTest("bounty", "Maribel Stonehollow", { target = trackedGuid, targetName = "Wanted Walter", amount = 9000, level = 24, zone = "The Barrens" }, clock)
clock = clock + 31 -- past the watched-list cache
local trackStart = clock
ns.Store:AddSighting(trackedGuid, "The Barrens", 50, 40, 10)
clock = clock + 20
ns.Store:AddSighting(trackedGuid, "The Barrens", 51, 41, 10, "Some Friend")
clock = clock + 3600
ns.Store:AddSighting(trackedGuid, "Ashenvale", 30, 60, 11, "Some Friend")
clock = clock + 86400
ns.Store:AddSighting(trackedGuid, "The Barrens", 62, 38, 10)
ns.Store:AddSighting(strangerGuid, "The Barrens", 62, 38, 10)
check(ns.db.tracks[trackedGuid] and #ns.db.tracks[trackedGuid] == 3, "a wanted player's sightings are kept, one a minute, got "..(ns.db.tracks[trackedGuid] and #ns.db.tracks[trackedGuid] or 0))
check(ns.db.tracks[strangerGuid] == nil, "a player nobody wants isn't kept")
local entries = ns.Tracks:Get(trackedGuid)
check(entries[1].zone == "The Barrens" and entries[1].t == clock, "newest first")
local summary = ns.Tracks:Summarize(entries)
check(summary.zones[1].zone == "The Barrens" and summary.zones[1].count >= 2 and summary.days == 2 and #summary.hours >= 1, "zones, hours and days summarised")
-- A kill of them shows in the file's record
ns.Store:InsertTest("kill", "Kaelen Duskbrand", { victim = trackedGuid, victimName = "Wanted Walter", deathId = "walter1", zone = "The Barrens", x = 62, y = 38 }, clock - 100)
check(#ns.Tracks:GetDeaths(trackedGuid) == 1 and ns.Tracks:GetDeaths(trackedGuid)[1].killer == "Kaelen Duskbrand", "deaths found")
-- The file: from the Board, from a command, and for a guild bounty
ns.TargetFile:ShowBounty(ns.Model:GetBountyInfo(trackedBounty))
check(ns.TargetFile:IsShown(), "the file opens from a bounty")
ns.Store:UpdatePlayer(trackedGuid, { zone = "Durotar", mapId = 1 })
clock = clock + 600
ns.Store:UpdatePlayer(trackedGuid, { zone = "Durotar", mapId = 1 })
ns.TargetFile:ShowPlayer(trackedGuid)
ns:RunCommand("file", "Wanted Walter")
local guildBounty2 = ns.Store:InsertTest("bounty", "Maribel Stonehollow", { guild = "Road Campers", targetFaction = "Alliance", amount = 20000 }, clock)
ns.TargetFile:ShowBounty(ns.Model:GetBountyInfo(guildBounty2))
check(ns.db.tracks[trackedGuid][1].name == nil, "the guild file doesn't write into the saved history")
ns:RunCommand("file", "Nobody Here")
clock = clockBeforeTracks
-- Report a bug from the foot of the menu
ns.UI:Show("board")
ns.Report:Show()
-- The game's Options > AddOns entry: registered, and its buttons close Options and open Wanted
check(optionsCategory and optionsCategory.registered and optionsCategory.name == "Wanted: Dead or... Dead", "Options > AddOns entry registered")
SettingsPanel._shown = true
ns.OptionsPanel.openButton:Click()
check(not SettingsPanel._shown and ns.UI:IsShown(), "Open Wanted closes Options and opens Wanted")
SettingsPanel._shown = true
ns.OptionsPanel.nearbyButton:Click()
check(not SettingsPanel._shown and ns.NearbyWindow:IsShown(), "Nearby window button opens it")
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
check(help:find("^Need help in Durotar 45,25 %- %d+ enem") and help:find("Stabby Mcstab %d+ Rogue %(on me%)") and help:find("%+%d+ more$") and #help <= 255 and not help:find("|", 1, true), "help text: "..help)
check(help:find("Stabby Mcstab", 1, true) < (help:find("Invader", 1, true) or 1e9), "whoever is on you comes first")
subZone = "Razor Hill"
help = ns.EnemyMenu:BuildHelpText()
check(help:find("^Need help in Razor Hill, Durotar 45,25 %- "), "help names the area when there is one: "..help)
subZone = "Durotar"
help = ns.EnemyMenu:BuildHelpText()
check(help:find("^Need help in Durotar 45,25 %- "), "an area named like the zone isn't repeated: "..help)
subZone = ""
exploredAreas = { [101] = { "Razor Hill", 0.55, 0.2, 0.65, 0.3 }, [102] = { "Durotar", 0, 0, 1, 1 } }
Fire("ZONE_CHANGED_NEW_AREA")
help = ns.EnemyMenu:BuildHelpText()
check(help:find("^Need help west of Razor Hill, Durotar 45,25 %- "), "help names the nearest area and which way it is: "..help)
exploredAreas[103] = { "Kolkar Crag", 0.4, 0.2, 0.5, 0.3 }
Fire("ZONE_CHANGED_NEW_AREA")
help = ns.EnemyMenu:BuildHelpText()
check(help:find("^Need help near Kolkar Crag, Durotar 45,25 %- "), "an area you're standing in that the game doesn't name says near: "..help)
exploredAreas = { [101] = { "Razor Hill", 0.4, 0.5, 0.5, 0.6 } }
Fire("ZONE_CHANGED_NEW_AREA")
help = ns.EnemyMenu:BuildHelpText()
check(help:find("^Need help north of Razor Hill, Durotar 45,25 %- "), "north is up the map: "..help)
exploredAreas = {}
Fire("ZONE_CHANGED_NEW_AREA")
help = ns.EnemyMenu:BuildHelpText()
check(help:find("^Need help in Durotar 45,25 %- "), "no named areas leaves the zone and coordinates: "..help)
chatSent = {}
local typed
ChatFrameUtil = { OpenChat = function(text) typed = text end }
check(ns.EnemyMenu:CallForHelp("CHANNEL") and #chatSent == 0 and typed and typed:find("^/4 Need help in Durotar") and #typed <= 255, "Local Defense help is typed into the chat box, not sent, got "..tostring(typed))
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
ns.Store:UpdatePlayer("Player-TEST-99999999", { name = "Fake Person", class = "MAGE", level = 25, faction = "Alliance", zone = "The Barrens", mapId = 10 })
local surging = ns.Hotspots:GetSurging()
check(#surging == 1 and surging[1].zone == "The Barrens" and surging[1].recent == 6, -- the test player isn't counted
 "the Barrens is rising fast, got "..tostring(surging[1] and surging[1].zone))
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
-- Leaving: on screen they're in sight (clickable); out of view they still show as nearby for a minute, then
-- shaded for 30s, then leave
local function Tick() for _, f in ipairs(tickers) do f() end end
Tick() -- a scan while their nameplate is still up
local function Near(guid) for _, d in ipairs(ns.Enemies:GetNearby()) do if d.guid == guid then return d end end end
check(Near("Player-9-ENEMY").visible, "on screen: in sight")
enemyUnits.nameplate1 = nil
Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
clock = clock + 45
Tick()
check(Near("Player-9-ENEMY") and Near("Player-9-ENEMY").inSight and not Near("Player-9-ENEMY").visible, "45s out of view: nearby, no longer in sight")
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
-- Only when you can be attacked: unflagged, a new enemy neither opens the window nor alerts; getting
-- flagged with enemies around opens it; a sanctuary counts as safe even flagged
local function Ticks() for _, f in ipairs(tickers) do f() end end
check(ns.db.settings.detect.onlyWhenExposed == false, "quiet mode is off by default")
ns.db.settings.detect.onlyWhenExposed = true
ns.NearbyWindow:UpdateExposure()
ns.db.settings.detect.autoShow = true
ns.NearbyWindow:SetShown(false)
ns.Enemies:ClearNearby()
pvpFlag = false
local warnings2 = {}
local realWarn2 = ns.Alerts.Warn
ns.Alerts.Warn = function(self, title, ...) warnings2[#warnings2 + 1] = title return realWarn2(self, title, ...) end
ns.Enemies:SetKoS("Player-9-QUIET", "Quiet Kos", true)
enemyUnits.nameplate50 = { guid = "Player-9-QUIET", name = "Quiet Kos", class = "MAGE", level = 20 }
Fire("NAME_PLATE_UNIT_ADDED", "nameplate50")
check(not ns.NearbyWindow:IsShown() and #warnings2 == 0, "unflagged: no window and no alert for a new enemy")
check(not ns.Enemies:IsExposed(), "unflagged is not exposed")
pvpFlag = true
Fire("PLAYER_FLAGS_CHANGED", "player")
check(ns.NearbyWindow:IsShown(), "getting flagged with enemies around opens the window")
pvpSanctuary = true
check(not ns.Enemies:IsExposed(), "a sanctuary is safe even flagged")
pvpSanctuary = false
-- Auto-hide: five minutes with nobody around and the window goes
enemyUnits.nameplate50 = nil
Fire("NAME_PLATE_UNIT_REMOVED", "nameplate50")
ns.Enemies:ClearNearby()
Ticks()
clock = clock + 200
Ticks()
check(ns.NearbyWindow:IsShown(), "still up after 200s")
clock = clock + 120
Ticks()
check(not ns.NearbyWindow:IsShown(), "hidden after five minutes with no enemies")
-- Quiet mode off: unflagged, a new enemy opens the window; once that encounter is over (nobody left, out of
-- combat) a one-time tip offers quiet mode
ns.db.settings.detect.onlyWhenExposed = false
ns.db.settings.detect.quietTipShown = false -- earlier tests ran with quiet mode off too
pvpFlag = false
lastDialog = nil
enemyUnits.nameplate51 = { guid = "Player-9-TIPPED", name = "Tip Rogue", class = "ROGUE", level = 20 }
Fire("NAME_PLATE_UNIT_ADDED", "nameplate51")
check(ns.NearbyWindow:IsShown(), "quiet mode off: unflagged, a new enemy opens the window")
Ticks()
check(lastDialog == nil, "no tip while the enemy is still around")
enemyUnits.nameplate51 = nil
Fire("NAME_PLATE_UNIT_REMOVED", "nameplate51")
ns.Enemies:ClearNearby()
inCombat = true
Ticks()
check(lastDialog == nil, "no tip in combat")
inCombat = false
Ticks()
check(lastDialog and lastDialog.title == "Quiet mode" and lastDialog.cancelLabel, "the quiet mode tip once the encounter is over")
ConfirmDialog()
check(ns.db.settings.detect.onlyWhenExposed == true, "the tip's button turns quiet mode on")
ns.db.settings.detect.onlyWhenExposed = false
ns.NearbyWindow:SetShown(false)
enemyUnits.nameplate51 = { guid = "Player-9-TIPPED2", name = "Tip Mage", class = "MAGE", level = 20 }
Fire("NAME_PLATE_UNIT_ADDED", "nameplate51")
enemyUnits.nameplate51 = nil
Fire("NAME_PLATE_UNIT_REMOVED", "nameplate51")
ns.Enemies:ClearNearby()
Ticks()
check(lastDialog == nil, "the tip shows only once")
ns.NearbyWindow:SetShown(false)
ns.Alerts.Warn = realWarn2
ns.Enemies:SetKoS("Player-9-QUIET", "Quiet Kos", false)
pvpFlag = false
-- Bounty notices across factions (Bridge): a hello only to the friend in WoW on this ruleset and the other
-- faction; their answer makes them a bridge; our bounties go across as notices (again when raised); notices
-- about us become records once, add up to the price on our head, and raise one alert
local function ClearBn() for i = #bnSent, 1, -1 do bnSent[i] = nil end end
local function BnDecode(i) return ns.Sync:Decode(bnSent[i].data) end
ClearBn()
clock = clock + 601
Fire("BN_FRIEND_ACCOUNT_ONLINE", 1)
RunTimers()
check(#bnSent == 1 and bnSent[1].id == 101 and bnSent[1].prefix == "WNTDB" and BnDecode(1).k == "H", "hello only to the Alliance friend on this ruleset, got "..#bnSent)
ClearBn()
Fire("BN_CHAT_MSG_ADDON", "WNTDB", ns.Sync:Encode({ k = "A", v = "0.1.0" }), "WHISPER", 101)
RunTimers()
check(ns.Bridge:Status():find("^Bridge: 1 players on the other faction run Wanted"), "the answer makes a bridge: "..ns.Bridge:Status())
ClearBn()
local crossBounty = ns.Store:NewRecord("bounty", { target = "Player-9-ALLY", targetName = "Ally Target", amount = 50000 })
RunTimers()
local sentNotice = #bnSent == 1 and BnDecode(1)
check(sentNotice and sentNotice.k == "N" and sentNotice.n[1].b == crossBounty.id and sentNotice.n[1].a == 50000 and sentNotice.n[1].p ~= "Test Player", "a new bounty goes across as a notice, poster hashed")
ClearBn()
ns.Store:NewRecord("raise", { bounty = crossBounty.id, amount = 25000 })
RunTimers()
check(#bnSent == 1 and BnDecode(1).n[1].a == 75000, "a raise sends the notice again at the new amount")
ClearBn()
ns.Store:NewRecord("bounty", { guild = "Some Guild", targetName = "<Some Guild>", amount = 90000 })
RunTimers()
check(#bnSent == 0, "guild bounties don't go across")
local warnedPrice
local realWarn3 = ns.Alerts.Warn
ns.Alerts.Warn = function(self, title, sub, ...) if title == "PRICE ON YOUR HEAD" then warnedPrice = sub end return realWarn3(self, title, sub, ...) end
local onMe = { b = "Horde Poster:7", g = "Player-1-ME", n = "Test Player", a = 20000, p = "abcd1234", t = clock - 100 }
local noticeMsg = ns.Sync:Encode({ k = "N", n = { onMe, { b = "Horde Poster:8", g = "Player-1-OTHER", n = "Someone Else", a = 5000, p = "abcd1234", t = clock } } })
Fire("BN_CHAT_MSG_ADDON", "WNTDB", noticeMsg, "WHISPER", 101)
RunTimers()
local total, count, posters = ns.Bridge:GetPriceOnMe()
check(total == 20000 and count == 1 and posters == 1, "a notice about us counts toward the price on our head, got "..total.." "..count.." "..posters)
check(warnedPrice and warnedPrice:find("A bounty of") and warnedPrice:find("Lifetime"), "one alert for the new bounty: "..tostring(warnedPrice))
local noticesBefore = 0
for _ in ns.Store:Iterator("notice") do noticesBefore = noticesBefore + 1 end
warnedPrice = nil
Fire("BN_CHAT_MSG_ADDON", "WNTDB", noticeMsg, "WHISPER", 101)
RunTimers()
local noticesAfter = 0
for _ in ns.Store:Iterator("notice") do noticesAfter = noticesAfter + 1 end
check(noticesAfter == noticesBefore and not warnedPrice, "the same notices again make no new records and no alert")
onMe.a = 35000
Fire("BN_CHAT_MSG_ADDON", "WNTDB", ns.Sync:Encode({ k = "N", n = { onMe, { b = "Horde Poster:9", g = "Player-1-ME", n = "Test Player", a = 10000, p = "ffff0000", t = clock } } }), "WHISPER", 101)
RunTimers()
total, count, posters = ns.Bridge:GetPriceOnMe()
check(total == 45000 and count == 2 and posters == 2, "a raise counts once at its new amount; paid or not, every bounty adds up, got "..total.." "..count.." "..posters)
check(warnedPrice and warnedPrice:find("^1 new bount") == nil, "raise plus new bounty make one alert: "..tostring(warnedPrice))
Fire("BN_CHAT_MSG_ADDON", "WNTDB", ns.Sync:Encode({ k = "N", n = { { b = "Horde Poster:10", g = "Player-1-ME", n = "Test Player", a = 99999, p = "x", t = clock } } }), "WHISPER", 102)
Fire("BN_CHAT_MSG_ADDON", "WNTDB", ns.Sync:Encode({ k = "N", n = { { b = "Horde Poster:11", g = "Player-1-ME", n = "Test Player", a = -5, p = "x", t = clock } } }), "WHISPER", 101)
RunTimers()
check(ns.Bridge:GetPriceOnMe() == 45000, "notices from our own faction or with a bad amount are ignored")
ns.Alerts.Warn = realWarn3
ns.db.settings.bridge = false
ClearBn()
ns.Store:NewRecord("bounty", { target = "Player-9-ALLY2", targetName = "Ally Two", amount = 10000 })
RunTimers()
check(#bnSent == 0, "with the setting off nothing goes across")
ns.db.settings.bridge = true
-- The wanted poster: the player's model, name and the price on their head; Take screenshot hides the buttons
-- for the shot and brings them back
local posterButtons = {}
local realButton = ns.Widgets.Button
ns.Widgets.Button = function(self, parent, label, ...) local b = realButton(self, parent, label, ...) posterButtons[label] = b return b end
ns:RunCommand("poster", "")
ns.Widgets.Button = realButton
local posterFrame = WantedPosterFrame
check(ns.Poster:IsShown() and posterFrame.reward:GetText() == "4 GOLD 50 SILVER", "the poster shows the price on our head, poster style: "..tostring(posterFrame.reward:GetText()))
check(posterFrame.name:GetText() == "TEST PLAYER" and posterFrame.rewardNote:GetText() == "2 bounties from 2 players", "name and how many bounties: "..tostring(posterFrame.rewardNote:GetText()))
local shotsBefore = screenshots
do
local upload = posterButtons["Upload your wanted poster"]
posterFrame.waitingToSend = false -- an earlier test took a picture
-- Without the app there's nothing to upload it: say so, take nothing
local savedAppInfo = WantedAppInfo
WantedAppInfo = nil
upload:GetScript("OnClick")(upload)
check(screenshots == shotsBefore and posterFrame.buttons:IsShown(), "no app: no picture")
WantedAppInfo = { running = "0.2.13", latest = "0.2.13" }
-- The studio: the model alone on a plain backdrop, where the screen says it is
UIParent._w, UIParent._h = 1600, 900
local model = posterFrame.studioModel
model.GetLeft, model.GetRight = function() return 400 end, function() return 1200 end
model.GetTop, model.GetBottom = function() return 750 end, function() return 150 end
cvars.screenshotFormat = "jpeg"
upload:GetScript("OnClick")(upload)
check(not posterFrame.buttons:IsShown() and not posterFrame.painting:IsShown() and posterFrame.studio:IsShown(), "the studio shows alone for the picture")
RunTimers()
check(screenshots == shotsBefore + 1 and posterFrame.buttons:IsShown() and posterFrame.painting:IsShown() and not posterFrame.studio:IsShown(), "the picture is taken and the poster comes back")
check(cvars.screenshotFormat == "jpeg", "the player's screenshot format is put back")
local shot = ns.db.posterShots[#ns.db.posterShots]
check(shot and shot.who == ns.Store:GetOrigin() and shot.t == clock and math.abs(shot.l - 0.25) < 1e-9 and math.abs(shot.r - 0.75) < 1e-9
	and math.abs(shot.top - 1/6) < 1e-9 and math.abs(shot.b - 5/6) < 1e-9, "the shot is saved for the app with where the model was")
-- The same button now sends it: the app only sees the picture once the game saves, on a /reload
check(upload:GetText() == "Send it now (/reload)", "after the picture the button offers the reload: "..tostring(upload:GetText()))
local reloads = 0
local realReload = ReloadUI
ReloadUI = function() reloads = reloads + 1 end
upload:GetScript("OnClick")(upload)
check(reloads == 1 and screenshots == shotsBefore + 1, "clicking it reloads, and takes no second picture")
ReloadUI = realReload
for _ = 1, 6 do posterFrame.waitingToSend = false upload:GetScript("OnClick")(upload) RunTimers() end
check(#ns.db.posterShots == 5, "only the newest few shots are kept")
WantedAppInfo = savedAppInfo
end
-- Set amount: any gold, just for fun, marked "(allegedly)"; Real amount puts the true total back
local amountButton = posterButtons["Set amount"]
amountButton:GetScript("OnClick")(amountButton)
check(lastDialog and lastDialog.validate("lots") and lastDialog.validate("0") and lastDialog.validate("2000000"), "the amount must be real gold")
ConfirmDialog("1,250g")
check(posterFrame.reward:GetText() == "1,250 GOLD" and posterFrame.rewardNote:GetText() == "(allegedly)", "a made-up reward, allegedly: "..tostring(posterFrame.reward:GetText()))
check(amountButton:GetText() == "Real amount", "the button offers the real amount back")
amountButton:GetScript("OnClick")(amountButton)
check(posterFrame.reward:GetText() == "4 GOLD 50 SILVER" and amountButton:GetText() == "Set amount", "Real amount puts the true total back")
posterButtons["Close"]:GetScript("OnClick")(posterButtons["Close"])
check(not ns.Poster:IsShown(), "Close hides the poster")
-- Sorting the board: by amount (the default), newest, name, last-seen zone, and how recently they were seen
local function SortTarget(guid, name, amount, zone, seenAgo)
	ns.Store:UpdatePlayer(guid, { name = name, zone = zone })
	ns.Store:GetPlayer(guid).lastSeen = seenAgo and (clock - seenAgo) or nil
	clock = clock + 1
	return ns.Store:NewRecord("bounty", { target = guid, targetName = name, amount = amount })
end
SortTarget("Player-9-SORTA", "Sortme Alpha", 10000, "Durotar", 10)
SortTarget("Player-9-SORTB", "Sortme Bravo", 20000, "The Barrens", nil)
SortTarget("Player-9-SORTC", "Sortme Charlie", 30000, "Ashenvale", 100)
local function SortedNames(sortKey)
	local names = {}
	for _, info in ipairs(ns.Model:GetBoard({ minAmount = 0, search = "sortme", sort = sortKey })) do
		names[#names + 1] = info.targetName:gsub("Sortme ", "")
	end
	return table.concat(names, ",")
end
check(SortedNames(nil) == "Charlie,Bravo,Alpha", "the board sorts by amount by default: "..SortedNames(nil))
check(SortedNames("newest") == "Charlie,Bravo,Alpha", "newest first")
check(SortedNames("name") == "Alpha,Bravo,Charlie", "by name: "..SortedNames("name"))
check(SortedNames("zone") == "Charlie,Alpha,Bravo", "by last-seen zone (Ashenvale, Durotar, The Barrens): "..SortedNames("zone"))
check(SortedNames("seen") == "Alpha,Charlie,Bravo", "most recently seen first, never seen last: "..SortedNames("seen"))
-- Emote buttons: seven favourites by default in list order; clicking an emote in Settings moves it from
-- favourite to the list to hidden and back, never past seven favourites; the one-time tip can turn them off
local Emotes = ns.Emotes
local function FavKeys() local keys = {} for _, def in ipairs(Emotes:GetFavourites()) do keys[#keys + 1] = def[1] end return table.concat(keys, ",") end
check(FavKeys() == "lol,flex,rude,train,violin,doom,bye", "the default favourites: "..FavKeys())
check(Emotes:GetState("gloat") == "list" and select(2, Emotes:CountShown()) == #Emotes.LIST - 7, "every other emote is in the list")
check(Emotes:CycleState("lol") == "list" and Emotes:CycleState("lol") == "hidden" and Emotes:CycleState("lol") == "fav", "favourite, list, hidden, favourite")
Emotes:CycleState("gloat")
check(Emotes:CycleState("gloat") == "list", "an eighth favourite goes to the list instead")
ns.db.settings.emotes.state.gloat = nil
check(#Emotes:GetFavourites() == 7 and WantedEmoteFlyout and not WantedEmoteFlyout:IsShown(), "the pop-out starts closed")
ns.db.settings.emotes.tipShown = false
ns.Enemies:ClearNearby()
local autoHideBefore = ns.db.settings.detect.autoHide
ns.db.settings.detect.autoHide = 0 -- the empty list would hide the window before the tip
ns.NearbyWindow:SetShown(true)
local realIsDialogShown = ns.Widgets.IsDialogShown
ns.Widgets.IsDialogShown = function() return false end -- earlier tests left their dialogs up
lastDialog = nil
for _, f in ipairs(tickers) do f() end
check(lastDialog and lastDialog.title == "Emote buttons" and lastDialog.cancelLabel == "Turn off", "the one-time emote tip")
lastDialog.onCancel()
check(ns.db.settings.emotes.enabled == false, "Turn off hides the emote buttons")
lastDialog = nil
for _, f in ipairs(tickers) do f() end
check(lastDialog == nil, "the tip shows once")
ns.Widgets.IsDialogShown = realIsDialogShown
ns.db.settings.detect.autoHide = autoHideBefore
ns.db.settings.emotes.enabled = true
ns.NearbyWindow:ForceLayout()
-- Posting a bounty doesn't count as seeing the target: "last seen" stays when they were really last seen
ns.Store:UpdatePlayer("Player-9-SEENOLD", { name = "Seen Long Ago", zone = "Stranglethorn Vale", faction = "Alliance" })
local seenAt = clock - 3 * 3600
ns.Store:GetPlayer("Player-9-SEENOLD").lastSeen = seenAt
ns.Bounties:Post("Player-9-SEENOLD", "Seen Long Ago", 10000)
check(ns.Store:GetPlayer("Player-9-SEENOLD").lastSeen == seenAt, "posting a bounty leaves last seen alone")
-- Wanted joins without a password (from 1.4.0): the game asking for one means the main channel has one now. Its box
-- is closed, the main channel is marked refused for the app, and no other channel is picked; another channel is left
-- alone
for i = #joinedWith, 1, -1 do joinedWith[i] = nil end
check(ns.Sync:GetInfo().channelName == "WantedNetHorde" and ns.db.syncChannelState.mainOpen and not ns.db.syncChannelState.mainRefused,
	"the main channel let us in at login, and that's noted for the app")
Fire("CHANNEL_PASSWORD_REQUEST", "WantedNetHorde")
RunTimers()
check(#joinedWith == 0, "a password request isn't answered with a join")
check(#hiddenPopups >= 1 and hiddenPopups[#hiddenPopups].which == "CHAT_CHANNEL_PASSWORD", "and closes the game's password box")
check(ns.db.syncChannelState.mainRefused and not ns.db.syncChannelState.mainOpen and ns.db.syncChannelState.epoch == 0
	and ns.db.syncChannelState.at == clock, "the main channel is marked refused")
check(not ns.Sync:GetInfo().channelId and ns.Sync:GetInfo().channelName == "WantedNetHorde" and ns.db.syncChannel == nil, "locked out, and no channel picked")
do
local popupsBefore = #hiddenPopups
Fire("CHANNEL_PASSWORD_REQUEST", "SomeoneElsesChannel")
RunTimers()
check(#joinedWith == 0 and #hiddenPopups == popupsBefore, "someone else's channel is left to the player")
end
ns:RunCommand("reconnect")
RunTimers()
check(ns.Sync:GetInfo().channelId == 6 and ns.db.syncChannelState.mainOpen and not ns.db.syncChannelState.mainRefused, "let in again: marked open")
check(#joinedWith == 0 or joinedWith[#joinedWith].password == nil, "never with a password")
-- Realm links: a player on another realm name can't hear our channel, so the sync reaches them by hidden
-- whisper. Greet, link, catch each other up, forward new records both ways, share theirs once on our
-- channel, never send a record back where it came from; strangers are ignored
local function Sent(chatType, target)
	-- Whole messages, reassembled from their parts, in the order they finished
	local out, partial = {}, {}
	for _, m in ipairs(addonSent) do
		if m.chatType == chatType and (not target or m.target == target) then
			local tag, msgId, part, total, chunk = m.text:match("^(%u):(%w+):(%d+)/(%d+):(.*)$")
			if tag then
				local key = tag..msgId
				partial[key] = partial[key] or {}
				partial[key][tonumber(part)] = chunk
				if #partial[key] == tonumber(total) then
					out[#out + 1] = { tag = tag, tbl = ns.Sync:Decode(table.concat(partial[key])) }
				end
			end
		end
	end
	return out
end
local function ClearSent() for i = #addonSent, 1, -1 do addonSent[i] = nil end end
local function FarRecord(seq) return { kind = "pass", id = "Far Origin:"..seq, origin = "Far Origin", seq = seq, prev = "0", t = clock, data = { bounty = "far-"..seq } } end
ClearSent()
clock = clock + 700
ns.Sync:Greet("Far Friend", "Other Realm")
local hellos = Sent("WHISPER", "Far Friend")
check(#hellos == 1 and hellos[1].tag == "H" and hellos[1].tbl.r == "Realm" and type(hellos[1].tbl.c) == "table" and not hellos[1].tbl.a, "a realm link starts with a whispered hello carrying our realm")
check(chatFilters.CHAT_MSG_SYSTEM(nil, "CHAT_MSG_SYSTEM", "No player named 'Far Friend' is currently playing.") == true
	and chatFilters.CHAT_MSG_SYSTEM(nil, "CHAT_MSG_SYSTEM", "No player named 'Someone Else' is currently playing.") == false, "the game's 'not online' for someone just greeted is hidden, others aren't")
ClearSent()
Fire("CHAT_MSG_ADDON", "WNTD", Message("H", { c = { ["Far Origin"] = 2 }, r = "Other Realm", a = 1 }), "WHISPER", "Far Friend")
local needs = Sent("WHISPER", "Far Friend")
check(ns.Sync:GetLinks()["Far Friend"] and #needs == 1 and needs[1].tag == "N" and needs[1].tbl.n["Far Origin"] == 1, "their answer makes the link and we ask for what we lack")
check(ns.db.farPeers["Far Friend"] and ns.db.farPeers["Far Friend"].realm == "Other Realm", "and they're remembered for next time")
check(ns.Sync:GetInfo().peers >= 1, "a realm link counts as another player online")
ClearSent()
Fire("CHAT_MSG_ADDON", "WNTD", Message("F", { r = { FarRecord(1), FarRecord(2) } }), "WHISPER", "Far Friend")
check(ns.Store:Get("Far Origin:1") and ns.Store:Get("Far Origin:2"), "their records are merged")
RunTimers()
local reshared = Sent("CHANNEL")
check(#reshared >= 1 and reshared[1].tag == "F" and #reshared[1].tbl.r == 2, "and shared once on our realm's channel")
check(#Sent("WHISPER", "Far Friend") == 0, "never sent back to the link they came from")

-- A wrong password: the main channel has one now, so we're locked out (a player on our realm answering our whisper
-- is heard)
do
local netName = ns.Sync:GetInfo().channelName
ClearSent()
Fire("CHAT_MSG_CHANNEL_NOTICE", "WRONG_PASSWORD", "", "", "", "", "", "", "", netName)
check(not ns.Sync:GetInfo().channelId and ns.db.syncChannelState.mainRefused, "a wrong password locks the client out, and marks the main channel refused")
ClearSent()
ns.Sync:Greet("Near Friend", nil) -- as the lockout does for the players last heard on the channel
check(#Sent("WHISPER", "Near Friend") == 1, "locked out, a player on our realm is greeted by whisper")
Fire("CHAT_MSG_ADDON", "WNTD", Message("H", { c = { ["Near Origin"] = 1 }, r = "Realm", a = 1 }), "WHISPER", "Near Friend")
check(ns.Sync:GetLinks()["Near Friend"], "and their answer from our own realm makes the link")
check(not ns.db.farPeers["Near Friend"], "but a player on our realm isn't remembered as a far one")
ns.db.farPeers["Old Link"] = { realm = "?", seen = clock }
ns.db.homeCheck.tried = clock - 5 * 60
Tick() -- the main channel's retry (CheckMain), every few minutes
RunTimers()
check(ns.Sync:GetInfo().channelId == 6, "the channel is joined again")
check(ns.Sync:GetInfo().members == nil and not ns.db.channel, "no member count until the game's channel list gives one")
check(selectedDisplayChannel == netName, "after joining, the channel's member list is asked for so the game sends its count")
-- Right after a reload the game's list is empty: the request waits for it
selectedDisplayChannel = nil
displayChannels = 0
Fire("CHANNEL_UI_UPDATE")
RunTimers()
check(selectedDisplayChannel == nil, "an empty channel list is not asked from")
-- More triggers while a retry is waiting don't start chains of their own
local function FirstAttempts()
	local n = 0
	for _, line in ipairs(ns:GetLogLines(400)) do
		if line:find("channel list yet (0 channels; attempt 1)", 1, true) then n = n + 1 end
	end
	return n
end
local chains = FirstAttempts()
Fire("CHANNEL_UI_UPDATE")
Fire("CHANNEL_UI_UPDATE")
Fire("CHANNEL_UI_UPDATE")
RunTimers()
check(FirstAttempts() == chains + 1, "triggers while a member request is retrying start one chain, not one each")
displayChannels = 2
clock = clock + 10
Fire("CHANNEL_UI_UPDATE")
RunTimers()
check(selectedDisplayChannel == netName, "once the game builds its list, the member list is asked for")
channelMembers = 37
Fire("CHANNEL_COUNT_UPDATE", 2, 37)
check(ns.Sync:GetInfo().members == 37 and ns.db.channel and ns.db.channel.members == 37 and ns.db.channel.name == netName and ns.db.channel.realm == "Realm", "the channel's size is read from the game's list and saved for the app")
check(ns.Sync:Status():find(", 37 in it", 1, true), "/wanted sync says how many are in the channel")
-- The game's notices for our own refused sends show under a public channel's name: hidden right after a send,
-- never otherwise, and a join or zone change never
ClearSent()
ns.Sync:QueueSighting({ g = "Player-9-NOTICE", n = "Notice Test" }, true)
RunTimers()
local noticeFilter = chatFilters.CHAT_MSG_CHANNEL_NOTICE
check(noticeFilter(nil, "CHAT_MSG_CHANNEL_NOTICE", "THROTTLED", "", "", "1. General - Undercity", "", "", 0, 1, "General") == true, "a throttle notice right after our send is hidden")
check(noticeFilter(nil, "CHAT_MSG_CHANNEL_NOTICE", "YOU_CHANGED", "", "", "1. General - Undercity", "", "", 0, 1, "General") == false, "a zone change notice is never hidden")
clock = clock + 10
check(noticeFilter(nil, "CHAT_MSG_CHANNEL_NOTICE", "THROTTLED", "", "", "1. General - Undercity", "", "", 0, 1, "General") == false, "long after our send, the player's own notices show")
-- Moderation on in the sync channel: nobody but moderators can send, so we stop and whisper until it's off
Fire("CHAT_MSG_CHANNEL_NOTICE_USER", "MODERATION_ON", "Bad Owner", "", "6. "..netName, "", "", 0, 6, netName)
check(ns.Sync:GetInfo().channelId == nil, "moderation on: out of the channel for sending")
tickers[#tickers]()
RunTimers()
check(ns.Sync:GetInfo().channelId == nil, "and it stays out while moderation is on")
Fire("CHAT_MSG_CHANNEL_NOTICE_USER", "MODERATION_OFF", "Bad Owner", "", "6. "..netName, "", "", 0, 6, netName)
RunTimers()
check(ns.Sync:GetInfo().channelId == 6, "moderation off: back in the channel")
-- The list itself: counted when it comes, and kept out of the chat windows
Fire("CHAT_MSG_CHANNEL_LIST", "Khal Drogash, *Torso Muncher, Bikuti Fowlfisher", "", "", "6. "..netName, "", "", 0, 6, netName)
check(ns.Sync:GetInfo().members == 3, "the member list is counted")
check(chatFilters.CHAT_MSG_CHANNEL_LIST(nil, "CHAT_MSG_CHANNEL_LIST", "Khal Drogash", "", "", "6. "..netName, "", "", 0, 6, netName) == true
	and not chatFilters.CHAT_MSG_CHANNEL_LIST(nil, "CHAT_MSG_CHANNEL_LIST", "Someone", "", "", "1. General", "", "", 0, 1, "General"), "our channel's member list is hidden from chat, other channels' lists aren't")
end
ClearSent()
local mine = ns.Store:NewRecord("pass", { bounty = "near-1" })
RunTimers()
local forwarded = Sent("WHISPER", "Far Friend")
check(#forwarded == 1 and forwarded[1].tag == "F" and forwarded[1].tbl.r[1].id == mine.id, "a new record here is forwarded to the realm link")
ClearSent()
Fire("CHAT_MSG_ADDON", "WNTD", Message("N", { n = { [ns.Store:GetOrigin()] = 1 } }), "WHISPER", "Far Friend")
check(#Sent("WHISPER", "Far Friend") == 0, "a catch-up goes out a batch a frame, not all at once")
RunFrames()
local fills = Sent("WHISPER", "Far Friend")
check(#fills >= 1 and fills[1].tag == "F", "a link asking for records gets them back over the next frames")
ClearSent()
Fire("CHAT_MSG_ADDON", "WNTD", Message("F", { r = { { kind = "pass", id = "Stranger:1", origin = "Stranger", seq = 1, prev = "0", t = clock, data = {} } } }), "WHISPER", "Stranger")
check(ns.Store:Get("Stranger:1") == nil, "records whispered by someone who isn't a link are ignored")
Fire("CHAT_MSG_ADDON", "WNTD", Message("H", { c = {}, r = "Realm" }), "WHISPER", "Same Realmer")
check(ns.Sync:GetLinks()["Same Realmer"] == nil and #Sent("WHISPER", "Same Realmer") == 0, "a whispered hello from our own realm isn't a link (the channel covers them)")
clock = clock + 61 -- the catch-up above used this minute's realm link budget
Fire("CHAT_MSG_ADDON", "WNTD", Message("H", { c = {}, r = "Third Realm" }), "WHISPER", "Newcomer")
local answer = Sent("WHISPER", "Newcomer")
check(ns.Sync:GetLinks()["Newcomer"] and #answer == 1 and answer[1].tbl.a, "someone greeting us from another realm is linked and answered")
-- Someone we greeted can answer out of order (their request arrives before their longer hello): it still counts
ClearSent()
clock = clock + 400
ns.Sync:Greet("Quick Asker", "Fourth Realm")
ClearSent()
Fire("CHAT_MSG_ADDON", "WNTD", Message("N", { n = { [ns.Store:GetOrigin()] = 1 } }), "WHISPER", "Quick Asker")
RunFrames()
check(ns.Sync:GetLinks()["Quick Asker"] and #Sent("WHISPER", "Quick Asker") >= 1, "a request from someone we just greeted is answered before their hello arrives")
-- A link who logs off: the game's "No player named ... is currently playing" for them ends the link at once
-- (nothing more is sent to them) and the message is hidden
check(ns.Sync:GetLinks()["Far Friend"] ~= nil, "Far Friend is still a link")
local offlineMsg = "No player named 'Far Friend' is currently playing."
check(chatFilters.CHAT_MSG_SYSTEM(nil, "CHAT_MSG_SYSTEM", offlineMsg) == true, "the offline message for a link is hidden")
Fire("CHAT_MSG_SYSTEM", offlineMsg)
check(ns.Sync:GetLinks()["Far Friend"] == nil, "and the link ends")
check(chatFilters.CHAT_MSG_SYSTEM(nil, "CHAT_MSG_SYSTEM", offlineMsg) == true, "the message stays hidden even if the link ended first")
ClearSent()
ns.Store:NewRecord("pass", { bounty = "after-offline" })
RunTimers()
check(#Sent("WHISPER", "Far Friend") == 0, "nothing more is sent to them")
-- Battle.net friends on our faction and another realm name are greeted as realm links
ClearSent()
bnFriends[#bnFriends + 1] = { id = 105, program = "WoW", faction = "Horde", realm = "Other Realm", name = "Horde Far" }
clock = clock + 700
Fire("BN_FRIEND_ACCOUNT_ONLINE", 1)
RunTimers()
check(#Sent("WHISPER", "Horde Far") == 1 and Sent("WHISPER", "Horde Far")[1].tag == "H", "a Battle.net friend on our faction and another realm is greeted as a realm link")
bnFriends[#bnFriends] = nil
-- Players on other realm names from the app (the server's realm-link directory): greeted a few at a time per realm
-- until one answers, then that realm is left alone; junk and our own realm are dropped
do
	ClearSent()
	clock = clock + 700
	WantedAppCatchup = { [ns.db.accountMark] = { t = 1, records = {}, links = {
		{ n = "Dir One", r = "Dir Realm", t = clock }, { n = "Dir Two", r = "Dir Realm", t = clock }, { n = "Dir Three", r = "Dir Realm", t = clock },
		{ n = "Dir Four", r = "Dir Realm", t = clock }, { n = "Same Realmer Two", r = "Realm", t = clock }, { n = "Bad|cffName", r = "Dir Realm", t = clock },
		42, { n = "", r = "Dir Realm" }, { n = "Other Place", r = "Sixth Realm", t = clock },
	} } }
	ns.Catchup:Import()
	check(ns.Sync:GetDirectory().names == 5, "the app's realm-link names are kept, junk and our own realm dropped, got "..ns.Sync:GetDirectory().names)
	ns.Sync:GreetDirectory()
	local greeted = {}
	for _, name in ipairs({ "Dir One", "Dir Two", "Dir Three", "Dir Four", "Same Realmer Two", "Other Place" }) do
		greeted[name] = #Sent("WHISPER", name) == 1 and Sent("WHISPER", name)[1].tag == "H"
	end
	check(greeted["Dir One"] and greeted["Dir Two"] and greeted["Dir Three"] and not greeted["Dir Four"], "three names a realm are greeted at a time")
	check(greeted["Other Place"] and not greeted["Same Realmer Two"], "every other realm gets its own greetings, ours none")
	Fire("CHAT_MSG_SYSTEM", "No player named 'Dir One' is currently playing.")
	Fire("CHAT_MSG_SYSTEM", "No player named 'Dir One' is currently playing.") -- once per message part
	local said = 0
	for _, line in ipairs(ns:GetLogLines(5)) do said = said + (line:find("Dir One isn't online", 1, true) and 1 or 0) end
	check(said == 1, "a greeted player the game says is offline is logged once, got "..said)
	Fire("CHAT_MSG_ADDON", "WNTD", Message("H", { c = {}, r = "Dir Realm", a = 1 }), "WHISPER", "Dir Two")
	RunFrames()
	check(ns.Sync:GetLinks()["Dir Two"], "an answer makes the realm link")
	ClearSent()
	clock = clock + 300
	Fire("CHAT_MSG_ADDON", "WNTD", Message("H", { c = {}, r = "Dir Realm", a = 1 }), "WHISPER", "Dir Two") -- still there
	RunFrames()
	ClearSent()
	ns.Sync:GreetDirectory()
	check(#Sent("WHISPER", "Dir Four") == 0 and #Sent("WHISPER", "Dir One") == 0, "a realm with a live link isn't greeted any more")
	check(#Sent("WHISPER", "Other Place") == 1, "one without is greeted again, five minutes on")
	check(ns.Sync:GetDirectory().linked == 1, "the directory counts the realms it reaches")
	-- A catch-up without names (an older app) leaves the list as it was
	WantedAppCatchup = { [ns.db.accountMark] = { t = 1, records = {} } }
	ns.Catchup:Import()
	check(ns.Sync:GetDirectory().names == 5, "no names from an older app keeps the list")
end
-- A bounty carries what its poster knew about the target, so a client that never saw them (another realm, or
-- offline at the time) still has their class, level, guild and where they were last seen, by the poster;
-- it only fills gaps and never counts as this client seeing them
ns.Store:UpdatePlayer("Player-9-SNAP", { name = "Snap Shot", class = "HUNTER", race = "NightElf", level = 20, guild = "Polarity Check", faction = "Alliance", zone = "Stranglethorn Vale", x = 21.8, y = 68.9, mapId = 1434 })
local snapSeen = clock - 7 * 3600
ns.Store:GetPlayer("Player-9-SNAP").lastSeen = snapSeen
local snapBounty = ns.Bounties:Post("Player-9-SNAP", "Snap Shot", 5000)
local sd = snapBounty.data
check(sd.class == "HUNTER" and sd.race == "NightElf" and sd.level == 20 and sd.targetGuild == "Polarity Check" and sd.seenAt == snapSeen and sd.x == 21.8 and sd.mapId == 1434, "a bounty records what the poster knew about the target")
local farBounty = { kind = "bounty", id = "Far Poster:1", origin = "Far Poster", seq = 1, prev = "0", t = clock, data = {
	target = "Player-9-UNKNOWN", targetName = "Never Seen", targetGuild = "Some Guild", amount = 5000, level = 22, zone = "The Barrens",
	class = "ROGUE", race = "Human", faction = "Alliance", seenAt = clock - 3600, x = 50, y = 40, mapId = 1413 } }
ns.Store:MergeRelayed(farBounty)
local learnt = ns.Store:GetPlayer("Player-9-UNKNOWN")
check(learnt and learnt.class == "ROGUE" and learnt.level == 22 and learnt.guild == "Some Guild" and learnt.zone == "The Barrens"
	and learnt.lastSeen == clock - 3600 and learnt.seenBy == "Far Poster", "a client that never saw the target learns them from the bounty, seen by the poster")
ns.Store:UpdatePlayer("Player-9-KNOWN", { name = "Known One", class = "MAGE", level = 30, zone = "Durotar" })
local knownSeen = ns.Store:GetPlayer("Player-9-KNOWN").lastSeen
ns.Store:MergeRelayed({ kind = "bounty", id = "Far Poster:2", origin = "Far Poster", seq = 2, prev = "0", t = clock, data = {
	target = "Player-9-KNOWN", targetName = "Known One", amount = 5000, level = 12, class = "WARRIOR", zone = "Elsewhere", seenAt = clock - 86400 } })
local known = ns.Store:GetPlayer("Player-9-KNOWN")
check(known.class == "MAGE" and known.level == 30 and known.zone == "Durotar" and known.lastSeen == knownSeen, "what this client already knows, and a newer sighting of its own, are kept")
-- Shared sightings: seeing someone with an open bounty records a "spotted" record (at most every 5 minutes per
-- target), which syncs like any record, so every hunter's target file has everyone's sightings; others'
-- spotted records land in the history "by" them, even before their bounty arrives; old ones are pruned
local function SpottedCount(guid) local n = 0 for r in ns.Store:Iterator("spotted") do if r.data.target == guid then n = n + 1 end end return n end
clock = clock + 31 -- the wanted list is rebuilt every 30 seconds
ns.Store:AddSighting("Player-9-SNAP", "Stranglethorn Vale", 22, 69, 1434)
check(SpottedCount("Player-9-SNAP") == 1, "seeing a wanted player records a shared sighting")
local spot = nil
for r in ns.Store:Iterator("spotted") do if r.data.target == "Player-9-SNAP" then spot = r end end
check(spot.data.zone == "Stranglethorn Vale" and spot.data.x == 22 and spot.data.mapId == 1434, "with where they were")
clock = clock + 60
ns.Store:AddSighting("Player-9-SNAP", "Stranglethorn Vale", 23, 70, 1434)
check(SpottedCount("Player-9-SNAP") == 1, "not again within five minutes")
clock = clock + 300
ns.Store:AddSighting("Player-9-SNAP", "Stranglethorn Vale", 24, 71, 1434)
check(SpottedCount("Player-9-SNAP") == 2, "again after five minutes")
ns.Store:AddSighting("Player-9-NOTWANTED", "Durotar", 50, 50, 1411)
check(SpottedCount("Player-9-NOTWANTED") == 0, "someone without a bounty isn't shared (sightings stay passing news)")
ns.Store:MergeRelayed({ kind = "spotted", id = "Spotter Far:1", origin = "Spotter Far", seq = 1, prev = "0", t = clock - 7200,
	data = { target = "Player-9-FARWANTED", zone = "Ashenvale", x = 30, y = 40, mapId = 1440 } })
local farTrack = ns.Tracks:Get("Player-9-FARWANTED")
check(#farTrack == 1 and farTrack[1].zone == "Ashenvale" and farTrack[1].by == "Spotter Far" and farTrack[1].t == clock - 7200, "someone else's sighting lands in the history by them, even before the bounty arrives")
ns.Store:MergeRelayed({ kind = "spotted", id = "Spotter Far:2", origin = "Spotter Far", seq = 2, prev = "0", t = clock - 9000,
	data = { target = "Player-9-FARWANTED", zone = "Darkshore", x = 10, y = 10, mapId = 1439 } })
farTrack = ns.Tracks:Get("Player-9-FARWANTED")
check(#farTrack == 2 and farTrack[1].zone == "Ashenvale" and farTrack[2].zone == "Darkshore", "an older sighting arriving later still sorts into place")
ns.Store:MergeRelayed({ kind = "spotted", id = "Spotter Far:3", origin = "Spotter Far", seq = 3, prev = "0", t = clock - 40 * 86400,
	data = { target = "Player-9-FARWANTED", zone = "Old Place", x = 1, y = 1, mapId = 1 } })
ns.Tracks:PruneSpotted()
check(ns.Store:Get("Spotter Far:3") == nil and ns.Store:Get("Spotter Far:1") ~= nil, "shared sightings over a month old are pruned")
-- Development builds keep the debug log in the saved data; /wanted netlog shows the weird (!!) lines
ns:Log("!! Test: something odd")
local kept = ns.Debug:GetDevLog()
check(#kept > 0 and kept[#kept]:find("!! Test: something odd", 1, true), "the log is kept in the saved data: "..tostring(kept[#kept]))
check(ns.db.devLog and ns.db.devLog.pos > 0, "as WantedDB.devLog")
ns:RunCommand("netlog", "")
-- /wanted netwatch prints network lines to chat while on, weird ones in red, but not the low-level ones
local watched = #printed
ns:RunCommand("netwatch", "")
ns:Log("Sync: send R, 200 bytes in 1 part(s)")
ns:Log("Sync: SendAddonMessage part 1/1 -> 0")
ns:Log("!! Sync: badly framed message from Someone")
ns:Log("Enemies: not network")
local netLines = {}
for i = watched + 1, #printed do if printed[i]:find("net|r") then netLines[#netLines + 1] = printed[i] end end
check(#netLines == 2 and netLines[2]:find("ff4040", 1, true), "netwatch shows sends and weird lines, not message parts: "..#netLines)
ns:RunCommand("netwatch", "")
check(not ns.db.devNetwatch, "and turns off again")
-- Fresh start: every shared record gone, the record chain starts again, the rest stays
local kosBefore = 0
for _ in pairs(ns.db.kos) do kosBefore = kosBefore + 1 end
ns.Store:FreshStart()
check(next(ns.db.records) == nil, "fresh start clears the records")
local first = ns.Store:NewRecord("pass", { bounty = "x" })
check(first.seq == 1 and first.prev == "0", "the chain starts again")
local kosAfter = 0
for _ in pairs(ns.db.kos) do kosAfter = kosAfter + 1 end
check(kosAfter == kosBefore and next(ns.db.players) ~= nil, "Kill on Sight and players stay")
ns:RunCommand("freshstart", "")
ns.Poster:Show()
check(WantedPosterFrame.reward:GetText() == "No price on your head yet", "with no bounties the poster says so")
ns.Poster:Hide()
-- /wanted link: a link record with the code and our GUID, for the desktop app to tie this character to its key
local function LinkRecords() local out = {} for r in ns.Store:Iterator("link") do out[#out + 1] = r end return out end
ns:RunCommand("link", "ab12cd34")
local links = LinkRecords()
check(#links == 1 and links[1].data.code == "AB12CD34" and links[1].data.guid == "Player-1-ME", "link makes a record with the code and our GUID")
ns:RunCommand("link", "x!")
ns:RunCommand("link", "")
check(#LinkRecords() == 1, "a malformed code makes no record")
-- Honorable kill credit without the killing blow is an assist on the death just seen; our own kill is not
;(function()
	local function Assists() local out = {} for r in ns.Store:Iterator("assist") do out[#out + 1] = r end return out end
	local me = ns.Store:GetOrigin()
	clock = clock + 120
	ns.Store:NewRecord("death", { deathId = "hk1", victim = "Player-9-HKV", victimName = "Hk Victim", victimGuild = "Silver Accord",
		victimClass = "MAGE", victimRace = "Gnome", victimLevel = 20, victimFaction = "Alliance", zone = "Undercity", x = 0.4, y = 0.6 })
	Fire("CHAT_MSG_COMBAT_HONOR_GAIN", "You have been awarded 1 Honor.")
	hkCount = hkCount + 1
	Fire("PLAYER_PVP_KILLS_CHANGED", "player")
	RunTimers()
	local a = Assists()
	check(#a == 1 and a[1].origin == me and a[1].data.victim == "Player-9-HKV" and a[1].data.deathId == "hk1", "HK credit after a death we saw is an assist on it")
	check(a[1].data.victimClass == "MAGE" and a[1].data.victimLevel == 20 and a[1].data.killerClass == "WARRIOR" and a[1].data.killerGroup == 1
		and a[1].data.zone == "Undercity", "the assist carries the victim's details and ours")
	hkCount = hkCount + 1
	Fire("PLAYER_PVP_KILLS_CHANGED", "player")
	RunTimers()
	check(#Assists() == 1, "one death gives one assist, however many HKs arrive")
	-- Our own killing blow also raises the HK count; that's the kill, not an assist
	clock = clock + 120
	Fire("PARTY_KILL", "Player-1-ME", "Player-9-ENEMY")
	hkCount = hkCount + 1
	Fire("PLAYER_PVP_KILLS_CHANGED", "player")
	RunTimers()
	check(#Assists() == 1, "an HK from our own kill is not an assist")
	-- The death seen a few seconds after the credit (the usual order in game): still an assist on it
	clock = clock + 120
	hkCount = hkCount + 1
	Fire("PLAYER_PVP_KILLS_CHANGED", "player")
	RunTimers() -- the first tries find nothing yet
	check(#Assists() == 1, "no assist before the death is seen")
	clock = clock + 3
	ns.Store:NewRecord("death", { deathId = "hk-late", victim = "Player-9-LATE", victimName = "Late Seen", victimFaction = "Alliance", zone = "Undercity" })
	RunTimers()
	local late = Assists()
	check(#late == 2 and (late[1].data.deathId == "hk-late" or late[2].data.deathId == "hk-late"), "a death seen after the HK credit still gets the assist")
	-- Long after any death: nothing to credit, and it stops trying
	clock = clock + 120
	hkCount = hkCount + 1
	Fire("PLAYER_PVP_KILLS_CHANGED", "player")
	for _ = 1, 3 do RunTimers() end
	check(#Assists() == 2, "an HK with no death seen records nothing")
	clock = clock + 60
	ns.Store:NewRecord("death", { deathId = "hk-much-later", victim = "Player-9-LATER", victimName = "Much Later", victimFaction = "Alliance", zone = "Undercity" })
	RunTimers()
	check(#Assists() == 2, "a death long after gives up waiting HKs nothing")
end)()
-- The desktop app's account code links this character by itself, once per code
;(function()
	local mark = ns.db.accountMark
	check(type(mark) == "string" and #mark == 16 and mark:match("^%w+$"), "the saved data has an account mark")
	WantedAppLinks = { someOtherAccount1 = "OTHR2345" }
	ns.Store:AutoLink()
	check(#LinkRecords() == 1, "another account's code isn't used")
	WantedAppLinks = { [mark] = "ACCT2345" }
	ns.Store:AutoLink()
	local links = LinkRecords()
	local auto
	for _, r in ipairs(links) do if r.data.code == "ACCT2345" then auto = r end end
	check(#links == 2 and auto and auto.data.guid == "Player-1-ME", "the account code makes a link record")
	ns.Store:AutoLink()
	check(#LinkRecords() == 2, "and only once")
	WantedAppLinks = { [mark] = "bad code!" }
	ns.Store:AutoLink()
	check(#LinkRecords() == 2, "a malformed code is ignored")
	WantedAppLinks = nil
end)()
-- Records straight from their origin are marked live; relayed ones aren't, whatever flags they arrive with
local function Rec(origin, seq, extra)
	local r = { kind = "pass", id = origin..":"..seq, origin = origin, seq = seq, prev = "0", t = clock, data = { bounty = "b"..seq } }
	for k, v in pairs(extra or {}) do r[k] = v end
	return r
end
ns.Store:Merge(Rec("Live Origin", 1), "Live Origin")
check(ns.db.records["Live Origin:1"].live == true, "a record from its origin is live")
ns.Store:MergeRelayed(Rec("Relay Origin", 1, { live = true, tampered = true, brokenChain = true }))
local relayed = ns.db.records["Relay Origin:1"]
check(relayed and not relayed.live, "a relayed record is not live, even if it says so")
check(not relayed.brokenChain, "flags a sender set are not kept")
ns.Store:Merge(Rec("Relay Origin", 1), "Relay Origin")
check(ns.db.records["Relay Origin:1"].live == true, "a relayed record later heard from its origin becomes live")
;(function()
	local isNew, why = ns.Store:MergeRelayed(Rec("Relay Origin", 1))
	check(ns.db.records["Relay Origin:1"].live == true, "and stays live")
	check(isNew == false and why == "already held", "a record we hold is reported as already held, got "..tostring(why))
	isNew, why = ns.Store:Merge(Rec("Someone Else", 1), "Relay Origin")
	check(isNew == false and why == "not sent by its origin", "a live record from someone else is refused, got "..tostring(why))
	isNew, why = ns.Store:MergeRelayed({ id = "x" })
	check(isNew == false and why == "malformed", "a malformed record is refused, got "..tostring(why))
end)()
-- /wanted status says where saved data came from when the desktop app had to restore it
WantedRestoreFilled = { WantedDB = true }
local before = #printed
ns:RunCommand("status", "")
local saysRestored = false
for i = before + 1, #printed do if printed[i]:find("restored by the desktop app", 1, true) then saysRestored = true end end
check(saysRestored, "status names the desktop app's restore")
WantedRestoreFilled = nil
;(function()
	-- The raid keeps changing targets: the window redraws once for the lot, and no alert looks anyone up
	local CLASSES = { "WARRIOR", "PRIEST", "MAGE", "ROGUE", "PALADIN" }
	for i = 1, 40 do
		enemyUnits["nameplate"..(i + 1)] = { guid = format("Player-9-LAG%02d", i), name = "Lagger Number"..i, class = CLASSES[i % 5 + 1], level = 20 }
		Fire("NAME_PLATE_UNIT_ADDED", "nameplate"..(i + 1))
	end
	ns.NearbyWindow:SetShown(true)
	RunTimers()
	local refreshes, describes = 0, 0
	local realRefresh, realDescribe = ns.NearbyWindow.Refresh, ns.Enemies.Describe
	ns.NearbyWindow.Refresh = function(...) refreshes = refreshes + 1 return realRefresh(...) end
	ns.Enemies.Describe = function(...) describes = describes + 1 return realDescribe(...) end
	for _ = 1, 5 do
		for i = 1, 40 do Fire("UNIT_TARGET", "nameplate"..(i + 1)) end
	end
	local describesDuring = describes
	RunTimers()
	ns.NearbyWindow.Refresh, ns.Enemies.Describe = realRefresh, realDescribe
	check(refreshes == 1, "200 target changes redraw the Nearby window once, got "..refreshes)
	check(describesDuring == 0, "target changes don't make the alerts look enemies up, got "..describesDuring)
	for i = 1, 40 do enemyUnits["nameplate"..(i + 1)] = nil end
end)()
;(function()
	-- In a fight the addon only records: our records, catch-ups and incoming records wait until it's over.
	-- Sightings still go both ways.
	local function RunFrames()
		for _ = 1, 50 do
			for _, f in ipairs(Mock.created) do
				if f._shown and f._scripts.OnUpdate then f._scripts.OnUpdate(f, 0.1) end
			end
		end
	end
	local function Sent(tag)
		local n = 0
		for _, m in ipairs(addonSent) do if m.text:find("^"..tag..":") then n = n + 1 end end
		return n
	end
	clock = clock + 120
	RunTimers()
	RunFrames()
	addonSent = {}
	Fire("PLAYER_REGEN_DISABLED")
	check(ns:InCombat(), "a fight starts")
	ns.Store:NewRecord("pass", { bounty = "in-a-fight" })
	ns.Sync:QueueSighting({ g = "Player-9-FIGHT", n = "Fight Sighting" }, true)
	RunTimers()
	clock = clock + 30
	RunTimers()
	check(Sent("R") == 0, "our new record waits out the fight")
	check(Sent("S") >= 1, "sightings still go out in a fight")
	Fire("CHAT_MSG_ADDON", "WNTD", OldMessage("R", { v = ns.VERSION, r = { Rec("Fight Origin", 1) } }), "CHANNEL", "Fight Origin", nil, nil, nil, "WantedNetHorde")
	RunFrames()
	check(ns.db.records["Fight Origin:1"] == nil, "a record heard in a fight waits, unopened")
	Fire("PLAYER_REGEN_ENABLED")
	RunTimers()
	check(not ns:InCombat(), "the fight is over a few seconds after combat ends")
	clock = clock + 5
	RunTimers()
	check(Sent("R") >= 1, "our record goes once the fight is over")
	RunFrames()
	check(ns.db.records["Fight Origin:1"] ~= nil and ns.db.records["Fight Origin:1"].live == true, "the waiting record is taken in after the fight, still as heard live")
end)()
;(function()
	-- Our own side's deaths are recorded too, but only with an enemy player in view: that's world PvP. They
	-- never join the enemy list.
	local function FriendDeaths()
		local n = 0
		for r in ns.Store:Iterator("death") do if r.data.victim == "Player-1-FRIEND" then n = n + 1 end end
		return n
	end
	clock = clock + 300
	RunTimers()
	enemyUnits.nameplate40 = { guid = "Player-1-FRIEND", name = "Horde Friend", class = "WARRIOR", level = 30, faction = "Horde" }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate40")
	Fire("UNIT_HEALTH", "nameplate40")
	enemyUnits.nameplate40.dead = true
	Fire("UNIT_HEALTH", "nameplate40")
	RunTimers()
	check(FriendDeaths() == 0, "a friend dying with no enemy around isn't recorded")
	enemyUnits.nameplate40.dead = nil
	clock = clock + 60
	Fire("UNIT_HEALTH", "nameplate40")
	enemyUnits.nameplate41 = { guid = "Player-9-ATTACKER", name = "Alliance Attacker", class = "ROGUE", level = 30 }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate41")
	enemyUnits.nameplate40.dead = true
	Fire("UNIT_HEALTH", "nameplate40")
	RunTimers()
	check(FriendDeaths() == 1, "a friend dying with an enemy in view is recorded, got "..FriendDeaths())
	local death
	for r in ns.Store:Iterator("death") do if r.data.victim == "Player-1-FRIEND" then death = r end end
	check(death.data.victimFaction == "Horde" and death.data.victimLevel == 30, "our side's death names our faction and their level")
	check(ns.Store:GetPlayer("Player-1-FRIEND") == nil, "a friend never joins the enemy list")
	-- One of ours we never had a unit for: the game's death event and their race are enough
	Fire("UNIT_DIED", "Player-1-TAUREN")
	RunTimers()
	local tauren
	for r in ns.Store:Iterator("death") do if r.data.victim == "Player-1-TAUREN" then tauren = r end end
	check(tauren and tauren.data.victimFaction == "Horde" and tauren.data.victimName == "Hoof Hearted", "a Tauren dying nearby in a fight is recorded as ours")
	-- Skyborne are on both sides under different names: once an Alliance one has been seen, a Skyborne by
	-- another name is ours, and one by the Alliance's name isn't
	local function Died(guid)
		for r in ns.Store:Iterator("death") do if r.data.victim == guid then return r end end
	end
	enemyUnits.nameplate42 = { guid = "Player-9-SKYSEEN", name = "Sky Seen", class = "HUNTER", level = 30, raceName = "High Order Skyborne", raceFile = "Skyborne" }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate42")
	Fire("UNIT_DIED", "Player-1-SKYHORDE")
	Fire("UNIT_DIED", "Player-9-SKYALLY")
	RunTimers()
	local ours = Died("Player-1-SKYHORDE")
	check(ours and ours.data.victimFaction == "Horde", "a Skyborne not named like the Alliance's is ours")
	local theirs = Died("Player-9-SKYALLY")
	check(theirs and theirs.data.victimFaction == "Alliance", "an Alliance Skyborne we never had a unit for is recorded as theirs")
	enemyUnits.nameplate42 = nil
	enemyUnits.nameplate40, enemyUnits.nameplate41 = nil, nil
end)()
;(function()
	-- The app's versions arrive through !!WantedLink: an app behind the newest is mentioned at login
	local function Said(text)
		for i = #printed, math.max(1, #printed - 3), -1 do
			if printed[i]:find(text, 1, true) then return true end
		end
		return false
	end
	WantedAppInfo = { running = "0.1.1", latest = "0.1.2" }
	check(ns:CheckAppVersion() and Said("The Wanted app 0.1.2 is out (you have 0.1.1)"), "an app behind the newest is mentioned")
	WantedAppInfo = { running = "0.1.2", latest = "0.1.2" }
	check(not ns:CheckAppVersion(), "a current app isn't")
	WantedAppInfo = { running = "dev", latest = "0.1.2" }
	check(not ns:CheckAppVersion(), "nor is a development build")
	WantedAppInfo = { running = "0.1.1", latest = "0.2.0|cffff0000evil" }
	check(not ns:CheckAppVersion() or not Said("evil"), "text another addon put there isn't shown as is")
	WantedAppInfo = nil
	check(not ns:CheckAppVersion(), "without the app, nothing")
	-- The Website & app page: addresses to copy, including this character's own page
	WantedAppInfo = { running = "0.1.1", latest = "0.1.2" }
	ns.UI:Show("web")
	local found = {}
	for _, f in ipairs(Mock.created) do
		local text = rawget(f, "_text")
		if type(text) == "string" and text:find("^https://wanteddeadordead%.com") then found[text] = true end
	end
	check(found["https://wanteddeadordead.com"] and found["https://wanteddeadordead.com/app"], "the page has the site and the app to copy")
	local mine = "https://wanteddeadordead.com/player/"..(ns.Store:GetOrigin():gsub("[^%w]", function(ch) return string.format("%%%02X", ch:byte()) end))
	check(found[mine], "and this character's own page, got none of "..mine)
	WantedAppInfo = nil
end)()
;(function()
	-- Our own death names who killed us, from the death recap: a witnessed kill for them on the network
	clock = clock + 120
	RunTimers()
	C_DeathRecap = {
		GetRecapLink = function() return "|Hdeath:4242|h[Death]|h" end,
		GetRecapEvents = function() return { { sourceGUID = "Player-9-ENEMY" } } end,
	}
	enemyUnits.nameplate43 = { guid = "Player-9-ENEMY", name = "Stabby Mcstab", class = "ROGUE", level = 20 }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate43")
	Fire("PLAYER_DEAD")
	Fire("UNIT_DIED", "Player-1-ME")
	RunTimers()
	local mine
	for r in ns.Store:Iterator("death") do if r.data.victim == "Player-1-ME" and r.t >= clock - 10 then mine = r end end
	check(mine and mine.data.killer == "Player-9-ENEMY" and mine.data.killerName == "Stabby Mcstab", "our death names the killer the recap gave")
	check(mine.data.killerFaction == "Alliance" and mine.data.victimFaction == "Horde", "with each side")
	C_DeathRecap = nil
	enemyUnits.nameplate43 = nil
end)()
;(function()
	-- The title bar has two lights and no player count: the app (or a way to get it) and WantedNet
	local function Lights()
		local out = {}
		for _, f in ipairs(Mock.created) do
			local text = rawget(f, "text")
			if rawget(f, "dot") and type(text) == "table" then out[#out + 1] = text._text end
		end
		return table.concat(out, "|")
	end
	WantedAppInfo = nil
	ns.UI:Show("board")
	ns.UI:Refresh()
	check(Lights():find("Get the app", 1, true), "without the app, a light offers it: "..Lights())
	check(not Lights():find("player", 1, true), "no player count: "..Lights())
	WantedAppInfo = { running = "0.1.3", latest = "0.1.3" }
	ns.UI:Refresh()
	check(Lights():find("App", 1, true) and not Lights():find("Get the app", 1, true), "with the app, the light says so: "..Lights())
	WantedAppInfo = nil
	-- Development builds show how many other players are on WantedNet; releases never do
	local getInfo, dev = ns.Sync.GetInfo, ns.DEV
	ns.Sync.GetInfo = function() return { channelId = 5, channelName = "WantedNetHorde", peers = 3 } end
	ns.DEV = false
	ns.UI:Refresh()
	check(not Lights():find("(3)", 1, true), "a release shows no player count: "..Lights())
	ns.DEV = true
	ns.UI:Refresh()
	check(Lights():find("WantedNet (3)", 1, true), "a development build shows the player count: "..Lights())
	ns.Sync.GetInfo, ns.DEV = getInfo, dev
	ns.UI:Refresh()
end)()
;(function()
	-- Records that arrive ahead of a gap join the chain once the gap fills, so we stop asking for them
	local function Linked(origin, seq, prev)
		local r = Rec(origin, seq)
		r.prev = prev
		r.hash = ns.Store:Hash("gap"..origin..seq)
		return r
	end
	local r1 = Linked("Gap Origin", 1, "0")
	local r2 = Linked("Gap Origin", 2, r1.hash)
	local r3 = Linked("Gap Origin", 3, r2.hash)
	ns.Store:MergeRelayed(r2)
	ns.Store:MergeRelayed(r3)
	check(ns.Store:GetChainSeq("Gap Origin") == 0, "records past a gap wait for it")
	ns.Store:MergeRelayed(r1)
	check(ns.Store:GetChainSeq("Gap Origin") == 3, "filling the gap takes in the records already held, got "..ns.Store:GetChainSeq("Gap Origin"))
	-- Saved data from before this fix: a chain stuck behind records it holds is moved on at login
	ns.db.chains["Gap Origin"] = { seq = 1, lastHash = r1.hash }
	ns.Store:RepairChains()
	check(ns.Store:GetChainSeq("Gap Origin") == 3, "a stuck chain is repaired at login")
end)()
;(function()
	-- Channel parts go out at the game's pace: a burst, then one every few seconds, never refused
	clock = clock + 60
	addonSent = {}
	for _ = 1, 12 do SlashCmdList.WANTED("synctest") end
	check(#addonSent == 8, "a burst of 8 parts goes at once, got "..#addonSent)
	-- A new record jumps the queue ahead of the waiting hellos
	ns.Store:NewRecord("pass", { bounty = "queue-jump" })
	RunTimers()
	clock = clock + 3
	RunTimers()
	check(#addonSent == 9 and addonSent[9].text:find("^R:"), "our new record goes before the waiting hellos")
	clock = clock + 20
	RunTimers()
	check(#addonSent == 13, "the rest follow as the allowance comes back, got "..#addonSent)
	-- A part the game refuses is sent again on its own, not the whole message from the start
	clock = clock + 60
	addonSent = {}
	for i = 1, 6 do ns.Store:NewRecord("pass", { bounty = "big-"..i..string.rep("x", 200) }) end
	throttleSkip, throttleNext = 1, 1
	RunTimers()
	clock = clock + 5
	RunTimers()
	local parts = {}
	for _, m in ipairs(addonSent) do
		local n, total = m.text:match("^R:%w+:(%d+)/(%d+):")
		if n then parts[#parts + 1] = n.."/"..total end
	end
	check(#parts >= 2 and parts[1] == "1/"..parts[1]:match("/(%d+)") and parts[2] == "2/"..parts[1]:match("/(%d+)"), "after a refusal the next part is the refused one, got "..table.concat(parts, " "))
	throttleSkip, throttleNext = nil, nil
end)()
;(function()
	-- Our own new records go out in batches, a few seconds' worth to one message, and every kind goes out
	local function LiveMessages()
		local ids = {}
		for _, m in ipairs(addonSent) do
			local id = m.text:match("^R:(%w+):")
			if id then ids[id] = true end
		end
		local n = 0
		for _ in pairs(ids) do n = n + 1 end
		return n
	end
	clock = clock + 120
	addonSent = {}
	ns.Store:NewRecord("pass", { bounty = "batch1" })
	ns.Store:NewRecord("pass", { bounty = "batch2" })
	ns.Store:NewRecord("link", { code = "BATCH234", guid = "Player-1-ME" })
	ns.Store:NewRecord("assist", { victim = "Player-9-X", deathId = "d-batch", zone = "Durotar" })
	check(LiveMessages() == 0, "new records wait a moment to go out together")
	RunTimers()
	check(LiveMessages() == 1, "four new records, links and assists included, go out as one message, got "..LiveMessages())
	-- A record its own origin sends to fill a gap was still heard straight from it
	local fill = Rec("Fill Origin", 1)
	Fire("CHAT_MSG_ADDON", "WNTD", OldMessage("F", { v = ns.VERSION, r = { fill } }), "CHANNEL", "Fill Origin", nil, nil, nil, "WantedNetHorde")
	local got = ns.db.records["Fill Origin:1"]
	check(got and got.live == true, "a gap fill from the record's own origin counts as heard live")
end)()
;(function()
	-- Live battle reports: combat logging is on in the open world, for the desktop app to read
	local LiveLog = ns.LiveLog
	check(combatLogging and ns.db.settings.liveLog == true, "combat logging is on by default")
	-- The setting
	ns.db.settings.liveLog = false
	LiveLog:Update()
	check(not combatLogging, "turning live reports off turns off the logging Wanted turned on")
	ns.db.settings.liveLog = true
	LiveLog:Update()
	check(combatLogging, "and back on")
	-- Instances aren't world PvP: logging Wanted turned on goes off inside, and back on outside
	local outside = IsInInstance
	IsInInstance = function() return true end
	LiveLog:Update()
	check(not combatLogging, "logging goes off in an instance")
	IsInInstance = outside
	LiveLog:Update()
	check(combatLogging, "and back on outside")
	-- Logging the player turned on themselves (for Warcraft Logs, say) is theirs: Wanted never turns it off
	LoggingCombat(false)
	ns.db.liveLogOn = nil
	LoggingCombat(true)
	LiveLog:Update()
	ns.db.settings.liveLog = false
	LiveLog:Update()
	check(combatLogging, "the player's own logging stays on")
	ns.db.settings.liveLog = true
	LiveLog:Update()
	-- Your nemesis: who killed you most, who you killed most, who you've fought most
	local Enemies = ns.Enemies
	local saved = ns.db.enemyStats
	ns.db.enemyStats = {}
	check(Enemies:GetNemeses().killedYou == nil, "no fights, no nemesis")
	local function Foe(guid, name, wins, losses)
		ns.Store:UpdatePlayer(guid, { name = name, faction = "Alliance", class = "ROGUE" })
		ns.db.enemyStats[guid] = { wins = wins, losses = losses, detections = 1 }
	end
	Foe("Player-9-NEM1", "Stabby Nemesis", 1, 6) -- killed you most
	Foe("Player-9-NEM2", "Easy Mark", 7, 0) -- you killed most
	Foe("Player-9-NEM3", "Old Rival", 5, 4) -- 9 fights: fought most
	local n = Enemies:GetNemeses()
	check(n.killedYou and n.killedYou.name == "Stabby Nemesis" and n.killedYou.losses == 6, "who killed you most")
	check(n.youKilled and n.youKilled.name == "Easy Mark" and n.youKilled.wins == 7, "who you killed most")
	check(n.fought and n.fought.name == "Old Rival", "who you fought most")
	ns.UI:Show("enemies")
	ns.UI:Refresh()
	ns.db.enemyStats = saved
end)()
;(function()
	-- The window says Wanted is under heavy development through the Forever beta
	ns.UI:Show("board")
	local found = false
	for _, f in ipairs(Mock.created) do
		local text = rawget(f, "text")
		if type(text) == "table" and tostring(text._text):find("heavy development through the WoW Forever beta", 1, true) then found = true end
	end
	check(found, "the window shows the development note")
end)()
;(function()
	-- At login, without the app, a popup offers it (like TSM's); "Don't remind me" stops it for good
	WantedAppInfo = nil
	ns.db.settings.appPrompt = true
	lastDialog = nil
	-- An earlier test left a dialog open; the popup never goes over another one
	local shown = ns.Widgets.IsDialogShown
	ns.Widgets.IsDialogShown = function() return true end
	ns:PromptForApp()
	check(lastDialog == nil, "the popup waits while another dialog is open")
	ns.Widgets.IsDialogShown = function() return false end
	ns:PromptForApp()
	check(lastDialog and lastDialog.title == "Get the Wanted app" and lastDialog.input and lastDialog.input.value == "https://wanteddeadordead.com/app",
		"without the app, a popup offers it with the address to copy")
	lastDialog.onCancel()
	lastDialog = nil
	check(ns.db.settings.appPrompt == false, "Don't remind me turns it off")
	ns:PromptForApp()
	check(lastDialog == nil, "and it doesn't come back")
	ns.db.settings.appPrompt = true
	WantedAppInfo = { running = "0.2.0", latest = "0.2.0" }
	ns:PromptForApp()
	check(lastDialog == nil, "with the app set up, no popup")
	-- Set up, but it hadn't run for hours when the game read its file: the popup asks whether it's running, and
	-- the light says so (1790270000 is the clock when the addon loaded)
	WantedAppInfo = { running = "0.2.1", latest = "0.2.1", seen = 1790270000 - 5 * 3600, apps = 12 }
	ns:PromptForApp()
	check(lastDialog and lastDialog.title == "Is the Wanted app running?" and lastDialog.text:find("Start menu", 1, true),
		"an app that hasn't run for hours: the popup asks if it's running")
	lastDialog = nil
	ns.UI:Show("board")
	ns.UI:Refresh()
	local function AppLight()
		for _, f in ipairs(Mock.created) do
			local text = rawget(f, "text")
			if rawget(f, "dot") and type(text) == "table" and tostring(text._text):find("^App") then return text._text end
		end
	end
	check(AppLight() == "App not running", "and the light says it isn't running, got "..tostring(AppLight()))
	-- Running (seen within the half hour it writes): no popup; a development build counts the apps running
	WantedAppInfo.seen = clock - 600
	ns:PromptForApp()
	check(lastDialog == nil, "a running app: no popup")
	local dev = ns.DEV
	ns.DEV = true
	ns.UI:Refresh()
	check(AppLight() == "App (12 running)", "a development build counts the apps running, got "..tostring(AppLight()))
	ns.DEV = false
	ns.UI:Refresh()
	check(AppLight() == "App", "a release doesn't, got "..tostring(AppLight()))
	ns.DEV = dev
	WantedAppInfo = nil
	ns.Widgets.IsDialogShown = shown
	ns.UI:Show("web")
end)()
;(function()
	-- Before a poster pays, the addon warns about weak claims and links the death's page on the website
	local B = ns.Bounties
	local victim = "Player-9-WEAKCLAIM"
	local function Claim(hunter, t)
		return ns.Store:InsertTest("claim", hunter, { bounty = "b-weak", victim = victim, victimName = "Weak Victim", zone = "Silverpine Forest", killT = t }, t)
	end
	local function Death(witness, t)
		ns.Store:InsertTest("death", witness, { victim = victim, victimName = "Weak Victim", zone = "Silverpine Forest" }, t)
	end
	local function Has(list, text)
		for _, w in ipairs(list) do if w:find(text, 1, true) then return true end end
		return false
	end
	local t0 = clock - 7200
	-- Nobody else recorded it
	local lonely = Claim("Sly Hunter", t0)
	check(Has(B:GetClaimWarnings(lonely), "Nobody else recorded this death"), "a claim nobody witnessed is flagged")
	check(B:DeathPageURL(lonely) == "https://wanteddeadordead.com/death/"..victim.."/"..t0, "and links the death's page, got "..tostring(B:DeathPageURL(lonely)))
	-- Its only witness is brand new to the network
	local t1 = t0 + 300
	local fresh = Claim("Sly Hunter", t1)
	Death("Brand New Alt", t1 + 1)
	check(Has(B:GetClaimWarnings(fresh), "new to the network"), "a witness nobody has seen before is flagged")
	-- A witness who has only ever backed up this one hunter
	for i = 1, 3 do
		local t = t0 + 600 * (i + 1)
		Claim("Sly Hunter", t)
		Death("Loyal Friend", t + 2)
	end
	local lastT = t0 + 600 * 4
	local loyal
	for c in ns.Store:Iterator("claim") do
		if c.origin == "Sly Hunter" and c.data.killT == lastT then loyal = c end
	end
	check(Has(B:GetClaimWarnings(loyal), "only ever backs up Sly Hunter"), "a witness who only backs one hunter is flagged")
	-- An established witness who backs up others too: no warnings
	ns.Store:Merge({ kind = "death", id = "Old Hand:1", origin = "Old Hand", seq = 1, prev = "0", t = clock - 30 * 86400,
		data = { victim = "Player-9-SOMEONE", zone = "Durotar" } }, "Old Hand")
	local fair = Claim("Honest Hunter", t0 + 5000)
	Death("Old Hand", t0 + 5001)
	check(#B:GetClaimWarnings(fair) == 0, "a claim an established player witnessed has no warnings, got "..table.concat(B:GetClaimWarnings(fair), " / "))
end)()
-- Only a death record that is its origin's own word witnesses a claim: one another player relayed could be forged
;(function()
	local B = ns.Bounties
	local victim = "Player-9-TRUSTV"
	local t0 = clock - 3000
	local hunterKill = ns.Store:InsertTest("kill", "Trust Hunter", { killer = "Player-1-TRUSTH", victim = victim, zone = "Barrens" }, t0)
	local claim = ns.Store:InsertTest("claim", "Trust Hunter", { bounty = "b-trust", kill = hunterKill.id, victim = victim, victimName = "Trust Victim", zone = "Barrens", killT = t0 }, t0)
	local function Death(origin, data)
		data.victim, data.zone = victim, "Barrens"
		return Sealed({ kind = "death", id = origin..":1", origin = origin, seq = 1, prev = "0", t = t0 + 2, data = data })
	end
	ns.Store:MergeRelayed(Death("Relayed Witness", {}))
	check(#B:GetWitnesses(claim) == 0 and B:GetClaimLevel(claim) == 1, "a death relayed by another player is not a witness")
	ns.Store:MergeRelayed(Death("Relayed Witness", {}), true)
	check(ns.Store:Get("Relayed Witness:1").app == true, "the app's catch-up marks a record it brings, even one already held")
	check(#B:GetWitnesses(claim) == 1 and B:GetClaimLevel(claim) == 2, "a death from the app's catch-up is a witness")
	ns.Store:MergeRelayed(Death("Forger", { app = true, live = true }))
	check(not ns.Store:Get("Forger:1").app and #B:GetWitnesses(claim) == 1, "a relayed record saying it came from the app isn't believed")
	ns.Store:Merge(Death("Live Witness", {}), "Live Witness")
	check(#B:GetWitnesses(claim) == 2, "a death heard live from its origin is a witness")
	local altered = Death("Altered Witness", {})
	altered.hash = "00000000"
	ns.Store:Merge(altered, "Altered Witness")
	check(ns.Store:Get("Altered Witness:1").tampered and #B:GetWitnesses(claim) == 2, "a tampered death is not a witness")
	local flagged
	for death in ns.Store:Iterator("death") do if death.id == "Altered Witness:1" then flagged = true end end
	check(not flagged and ns.Store:CountFlagged() >= 1, "a tampered record is never read, and counted")
	check(ns.Report:Build():find("Records flagged: %d+ tampered %(never used%), %d+ broken chain %(never a witness%)"), "/wanted bug counts both flags")
	-- A broken chain can be innocent (a reinstall): the record is listed, but never a witness
	local first = Death("Forked Witness", {})
	ns.Store:Merge(first, "Forked Witness")
	ns.Store:Merge(Sealed({ kind = "death", id = "Forked Witness:2", origin = "Forked Witness", seq = 2, prev = "not-first", t = t0 + 3,
		data = { victim = victim, zone = "Barrens" } }), "Forked Witness")
	local forked = ns.Store:Get("Forked Witness:2")
	local listed
	for death in ns.Store:Iterator("death") do if death == forked then listed = true end end
	check(forked.brokenChain and listed, "a death with a broken chain is still listed")
	local _, broken = ns.Store:CountFlagged()
	check(broken >= 1, "and counted")
	ns.Store:Get("Forked Witness:1").live = nil
	check(#B:GetWitnesses(claim) == 2, "but never a witness")
	-- The victim's own record of their death, naming the claim's killer, is the strongest witness
	local victimsClaim = ns.Store:InsertTest("claim", "Trust Hunter", { bounty = "b-trust2", kill = hunterKill.id, victim = victim, victimName = "Trust Victim", zone = "Barrens", killT = t0 + 600 }, t0 + 600)
	local function Own(seq, prev, t)
		return Sealed({ kind = "death", id = "Trust Victim:"..seq, origin = "Trust Victim", seq = seq, prev = prev, t = t,
			data = { victim = victim, zone = "Barrens", killer = "Player-1-TRUSTH" } })
	end
	local link = Sealed({ kind = "link", id = "Trust Victim:1", origin = "Trust Victim", seq = 1, prev = "0", t = t0 + 500, data = { code = "VICT2345", guid = victim } })
	ns.Store:Merge(link, "Trust Victim")
	local own = Own(2, link.hash, t0 + 601)
	ns.Store:MergeRelayed(own)
	check(B:GetClaimLevel(victimsClaim) == 1, "the victim's own death relayed by another player is not a witness")
	ns.Store:Merge(Own(2, link.hash, t0 + 601), "Trust Victim")
	local witnesses, victimsOwn = B:GetWitnesses(victimsClaim)
	check(#witnesses == 1 and victimsOwn and B:GetClaimLevel(victimsClaim) == 2, "the victim's own death heard live gives the witnessed level alone")
	check(#B:GetClaimWarnings(victimsClaim) == 0, "and no warnings, though the victim is new to the network, got "..table.concat(B:GetClaimWarnings(victimsClaim), " / "))
end)()
;(function()
	-- In a dungeon or raid the Nearby window closes, and comes back outside if it was open; battlegrounds keep it
	local Nearby, outside = ns.NearbyWindow, IsInInstance
	Nearby:SetShown(true)
	IsInInstance = function() return true, "party" end
	Fire("PLAYER_ENTERING_WORLD")
	check(not Nearby:IsShown(), "entering a dungeon closes the Nearby window")
	IsInInstance = outside
	Fire("PLAYER_ENTERING_WORLD")
	check(Nearby:IsShown(), "leaving it opens the window again")
	IsInInstance = function() return true, "pvp" end
	Fire("PLAYER_ENTERING_WORLD")
	check(Nearby:IsShown(), "a battleground keeps it open")
	IsInInstance = outside
	Fire("PLAYER_ENTERING_WORLD")
	-- A GUID the game keeps secret (in an instance) is never compared: the health bar just doesn't show
	local secret = SECRET_SPELL
	local unitGUID = UnitGUID
	UnitGUID = function(unit) if unit ~= "player" then return secret end return unitGUID(unit) end
	Nearby:Refresh()
	UnitGUID = unitGUID
end)()
;(function()
	-- The name book: every player seen, both sides, by GUID with their full name, for the app (the combat log
	-- only has first names)
	enemyUnits.target = { guid = "Player-4613-FRIEND01", name = "Tusk Ironhide", faction = "Horde" }
	Fire("PLAYER_TARGET_CHANGED")
	enemyUnits.target = nil
	local entry = ns.db.names["Player-4613-FRIEND01"]
	check(entry and entry.n == "Tusk Ironhide" and entry.t == clock, "a friendly player seen goes in the name book")
	-- Old names go at load; the book never grows past its cap
	ns.db.names["Player-4613-OLDNAME"] = { n = "Long Gone", t = clock - 31 * 86400 }
	for i = 1, ns.Store.NAME_BOOK_MAX + 10 do
		ns.db.names["Player-4613-FILL"..i] = { n = "Fill "..i, t = clock - i }
	end
	ns.Store:OnLoad()
	local count = 0
	for _ in pairs(ns.db.names) do count = count + 1 end
	check(ns.db.names["Player-4613-OLDNAME"] == nil, "a name not seen for a month is dropped")
	check(count == ns.Store.NAME_BOOK_MAX and ns.db.names["Player-4613-FRIEND01"] ~= nil, "the book keeps the newest up to its cap, got "..count)
end)()
;(function()
	-- Walking one kind of record uses an index by kind; it stays right when records are pruned, when the whole
	-- table is replaced, and when a record arrives during a walk
	local Store = ns.Store
	local function Count(kind)
		local n = 0
		for _ in Store:Iterator(kind) do n = n + 1 end
		return n
	end
	Store:InsertTest("raise", "Index Seed", { bounty = "b-seed", amount = 1 }) -- at least one to walk
	local before = Count("raise")
	Store:InsertTest("raise", "Index Test", { bounty = "b-index", amount = 1 })
	check(Count("raise") == before + 1, "a new record is found by kind")
	for id, r in pairs(ns.db.records) do
		if r.kind == "raise" and r.origin == "Index Test" then ns.db.records[id] = nil end
	end
	check(Count("raise") == before, "a pruned record is gone from the walk")
	local walked = 0
	for _ in Store:Iterator("raise") do
		walked = walked + 1
		Store:InsertTest("raise", "Index Test", { bounty = "b-index", amount = 2 })
	end
	check(walked == before and Count("raise") == before * 2, "records added during a walk wait for the next one")
	local saved = ns.db.records
	ns.db.records = {}
	check(Count("raise") == 0, "a replaced records table is indexed afresh")
	ns.db.records = saved
	check(Count("raise") == before * 2, "and back again")
end)()
;(function()
	-- In combat the game blocks Show and Hide on frames inside the Nearby rows' secure buttons (UNKNOWN()
	-- blocked): the health bars are shown once and faded in and out instead
	local calls = 0
	local watched = {}
	for _, f in ipairs(Mock.created) do
		if rawget(f, "_kind") == "StatusBar" then
			watched[#watched + 1] = f
			local show, hide = f.Show, f.Hide
			f.Show = function(self, ...) if InCombatLockdown() then calls = calls + 1 end return show(self, ...) end
			f.Hide = function(self, ...) if InCombatLockdown() then calls = calls + 1 end return hide(self, ...) end
		end
	end
	check(#watched > 0, "the Nearby rows have health bars to watch")
	local lockdown = InCombatLockdown
	InCombatLockdown = function() return true end
	ns.NearbyWindow:SetShown(true)
	ns.NearbyWindow:Refresh()
	InCombatLockdown = lockdown
	check(calls == 0, "no health bar is shown or hidden in combat, got "..calls)
end)()
;(function()
	-- Issue #79: nothing inside a Nearby row's secure button is shown or hidden in combat (the game blocks it as
	-- UNKNOWN()): not the class icon when a player leaves or joins a row, not the hover, and a health bar never
	-- sits at its minimum, where the game hides its fill, as it would for a target just killed
	local rows = {}
	for _, f in ipairs(Mock.created) do
		if rawget(f, "_kind") == "Button" and rawget(f, "health") then
			rows[#rows + 1] = f
		end
	end
	check(#rows > 0, "the Nearby rows are there to watch")
	local changes, restore = {}, {}
	for _, row in ipairs(rows) do
		for _, key in ipairs({ "icon", "hover", "health", "name", "right", "sub", "bar", "tint" }) do
			local region = row[key]
			for _, method in ipairs({ "Show", "Hide" }) do
				local original = rawget(region, method)
				restore[#restore + 1] = function() region[method] = original end
				local call = region[method]
				region[method] = function(self, ...)
					if InCombatLockdown() then
						changes[#changes + 1] = key..":"..method
					end
					return call(self, ...)
				end
			end
		end
		row.health.SetMinMaxValues = function(self, low) self._min = low end
		row.health.SetValue = function(self, value) self._value = value end
		restore[#restore + 1] = function() row.health.SetMinMaxValues, row.health.SetValue = nil, nil end
	end
	local lockdown, health = InCombatLockdown, UnitHealth
	ns.Enemies:ClearNearby()
	enemyUnits.nameplate1 = { guid = "Player-9-KILLED", name = "Soon Dead", class = "MAGE", level = 20 }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
	ns.NearbyWindow:SetShown(true)
	ns.NearbyWindow:Refresh()
	InCombatLockdown = function() return true end
	-- The target is killed: its health is 0
	UnitHealth = function() return 0 end
	ns.NearbyWindow:Refresh()
	local drawn
	for _, row in ipairs(rows) do
		if row.health._value == 0 then
			drawn = row.health
		end
	end
	check(drawn and drawn._min < drawn._value, "a killed enemy's health bar stays above its minimum")
	UnitHealth = health
	-- Someone new fills an empty row as text, then everyone leaves the list
	enemyUnits.nameplate2 = { guid = "Player-9-LATE", name = "Late Comer", class = "ROGUE", level = 20 }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
	ns.NearbyWindow:Refresh()
	enemyUnits.nameplate1, enemyUnits.nameplate2 = nil, nil
	ns.Enemies:ClearNearby()
	ns.NearbyWindow:Refresh()
	rows[1].info = false -- the mock would answer a nil field with a function
	rows[1]:GetScript("OnEnter")(rows[1])
	rows[1]:GetScript("OnLeave")(rows[1])
	check(#changes == 0, "nothing in a Nearby row is shown or hidden in combat, got "..table.concat(changes, ", "))
	-- And a blocked action says what Wanted last did to its windows, and where in Wanted it was asked for
	Fire("ADDON_ACTION_BLOCKED", "WantedDeadOrDead", "UNKNOWN()")
	local problems = ns:GetProblems()
	local last = problems[#problems]
	check(last:find("last: Nearby: ", 1, true), "a blocked action lists Wanted's last window actions, got "..last)
	debugstack = function()
		return "[C]: in function 'Hide'\n[string \"@Interface/AddOns/WantedDeadOrDead/NearbyWindow.lua\"]:654: in function 'Draw'\n"
			.."Interface/AddOns/WantedDeadOrDead/NearbyWindow.lua:700: in function 'Refresh'\n"
	end
	Fire("ADDON_ACTION_BLOCKED", "WantedDeadOrDead", "UNKNOWN()")
	debugstack = nil
	last = problems[#problems]
	check(last:find("from Hide < NearbyWindow.lua:654 < NearbyWindow.lua:700;", 1, true), "and the call and Wanted's lines it came from, got "..last)
	InCombatLockdown = lockdown
	for _, undo in ipairs(restore) do
		undo()
	end
	ns.NearbyWindow:Refresh()
end)()
;(function()
	-- An enemy who turns up in combat fills one empty row, as text, and keeps it through every refresh: they
	-- used to go into another empty row each refresh, so one player filled the list three times
	local function Rows(name)
		local n = 0
		for _, f in ipairs(Mock.created) do
			local label = rawget(f, "name")
			if rawget(f, "_kind") == "Button" and type(label) == "table" and f:IsShown() and tostring(label._text):find(name, 1, true) then
				n = n + 1
			end
		end
		return n
	end
	ns.Enemies:ClearNearby()
	ns.NearbyWindow:SetShown(true)
	ns.NearbyWindow:Refresh()
	local lockdown = InCombatLockdown
	InCombatLockdown = function() return true end
	enemyUnits.nameplate1 = { guid = "Player-9-PENN", name = "Penn Dragon", class = "DRUID", level = 20 }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
	for _ = 1, 3 do
		ns.NearbyWindow:Refresh()
	end
	check(Rows("Penn Dragon") == 1, "an enemy found in combat is on one row, got "..Rows("Penn Dragon"))
	enemyUnits.nameplate1 = nil
	ns.Enemies:ClearNearby()
	ns.NearbyWindow:Refresh()
	check(Rows("Penn Dragon") == 0, "and off it when they leave the list in combat")
	InCombatLockdown = lockdown
	ns.NearbyWindow:Refresh()
end)()
;(function()
	-- A hello lists only chains active in the last week, newest first, at most 150: listing every origin ever
	-- seen outgrew the send queue at about 1,000 origins, and then no hello went out at all
	local db = ns.db
	local savedRecords, savedChains = db.records, db.chains
	local records, chains = {}, {}
	for id, r in pairs(savedRecords) do records[id] = r end
	for origin, c in pairs(savedChains) do chains[origin] = c end
	local function Add(origin, t)
		records[origin..":1"] = { kind = "death", id = origin..":1", origin = origin, seq = 1, prev = "0", t = t, data = {}, hash = "x" }
		chains[origin] = { seq = 1, lastHash = "x" }
	end
	for i = 1, 2000 do
		Add(format("Active %04d Player", i), clock - i)
	end
	for i = 1, 50 do
		Add(format("Quiet %02d Player", i), clock - 30 * 86400)
	end
	db.records, db.chains = records, chains -- a new table: the index is built again over it
	addonSent = {}
	clock = clock + 61
	-- Entering the world (the dungeon tests left it) rejoins the channel, which says hello
	Fire("PLAYER_ENTERING_WORLD")
	RunTimers()
	local chunks, total = {}, nil
	for _, m in ipairs(addonSent) do
		local part, of, chunk = m.text:match("^H:%w+:(%d+)/(%d+):(.*)$")
		if part then chunks[tonumber(part)], total = chunk, tonumber(of) end
	end
	check(total and total <= 8 and #chunks == total, "a network of 2,050 players sends a hello of 8 parts or fewer, got "..tostring(total))
	local hello = total and ns.Sync:Decode(table.concat(chunks)) or { c = {} }
	local n = 0
	for _ in pairs(hello.c) do n = n + 1 end
	check(n == 150, "the hello lists 150 chains, got "..n)
	check(hello.c["Active 0001 Player"] and not hello.c["Active 0200 Player"], "the most recently active first")
	check(not hello.c["Quiet 01 Player"], "a chain quiet for a month is left out")
	db.records, db.chains = savedRecords, savedChains
end)()
;(function()
	-- The desktop app's catch-up (!!WantedLink/Catchup.lua): what this account's saved data lacked, from the server.
	-- Taken in at login in the background, never in a fight, as gap fills are, and not passed on to realm links
	local db = ns.db
	check(db.faction == "Horde", "the account's side is saved for the app, got "..tostring(db.faction))
	-- A realm link that would otherwise get every new record forwarded
	ClearSent()
	clock = clock + 700
	ns.Sync:Greet("Catch Linker", "Fifth Realm")
	Fire("CHAT_MSG_ADDON", "WNTD", Message("H", { c = {}, r = "Fifth Realm", a = 1 }), "WHISPER", "Catch Linker")
	check(ns.Sync:GetLinks()["Catch Linker"], "a realm link to watch")
	RunTimers()
	ClearSent()
	local function Rec(seq, extra)
		local r = { kind = "pass", id = "Catch Origin:"..seq, origin = "Catch Origin", seq = seq, prev = "0", t = clock - 3600, data = { bounty = "c"..seq }, hash = "x" }
		for k, v in pairs(extra or {}) do r[k] = v end
		return r
	end
	local on = { b = "Ally Poster:9", g = "Player-1-ME", n = "Test Player", a = 7500, p = "0badf00d", t = clock - 600 }
	WantedAppCatchup = { [db.accountMark] = { t = clock, records = {
		Rec(1), Rec(2, { live = true }), Rec(3, { data = "not a table" }), Rec(4, { id = "Someone Else:4" }), Rec(5, { data = { nested = {} } }),
	}, notices = { on, { b = "bad" } } }, ["otherAccountMark"] = { t = clock, records = { Rec(9) } } }
	Fire("PLAYER_REGEN_DISABLED")
	ns.Catchup:Import()
	RunFrames()
	check(ns.Store:Get("Catch Origin:1") == nil, "nothing is taken in during a fight")
	Fire("PLAYER_REGEN_ENABLED")
	RunTimers()
	RunFrames()
	check(ns.Store:Get("Catch Origin:1") and ns.Store:Get("Catch Origin:2"), "after the fight the records are taken in")
	check(not ns.Store:Get("Catch Origin:2").live, "a caught-up record is never live, whatever it says")
	check(not ns.Store:Get("Catch Origin:3") and not ns.Store:Get("Someone Else:4") and not ns.Store:Get("Catch Origin:5"),
		"malformed records are skipped: data not a table, an id that isn't origin:seq, a nested table")
	check(not ns.Store:Get("Catch Origin:9"), "another account's catch-up is left alone")
	check(ns.Store:GetChainSeq("Catch Origin") == 2, "the chain moves on over them")
	check(WantedAppCatchup == nil, "the file's table is let go once read")
	local notice
	for n in ns.Store:Iterator("notice") do if n.data.bounty == "Ally Poster:9" then notice = n end end
	check(notice and notice.data.amount == 7500 and notice.data.target == "Player-1-ME", "the other side's bounty on us arrives as a notice")
	check(db.catchupT == clock, "the catch-up's time is kept")
	RunTimers()
	local forwarded = 0
	for _, m in ipairs(Sent("WHISPER", "Catch Linker")) do
		for _, r in ipairs(m.tbl.r or {}) do if r.origin == "Catch Origin" then forwarded = forwarded + 1 end end
	end
	check(forwarded == 0, "caught-up records aren't forwarded to realm links, got "..forwarded)
	-- The same catch-up again (a /reload before the app wrote a new one) is skipped
	WantedAppCatchup = { [db.accountMark] = { t = clock, records = { Rec(6) } } }
	ns.Catchup:Import()
	RunFrames()
	check(not ns.Store:Get("Catch Origin:6"), "a catch-up already taken in is skipped")
	WantedAppCatchup = { [db.accountMark] = { t = clock + 1, records = { Rec(6) } } }
	ns.Catchup:Import()
	RunFrames()
	check(ns.Store:Get("Catch Origin:6"), "a newer one is taken in")
	-- Players the app's combat log named by first name only are looked up, even in a catch-up already taken in
	WantedAppCatchup = { [db.accountMark] = { t = clock + 1, records = {}, unnamed = { "Player-9-ENEMY", "Player-7-00AB12", "not a guid", 42 } } }
	ns.Catchup:Import()
	local stabby = db.names["Player-9-ENEMY"]
	check(stabby and stabby.n == "Stabby Mcstab" and stabby.class == "ROGUE" and stabby.sex == "male", "a player the game knows goes in the name book with class and sex")
	check(db.names["Player-7-00AB12"] == nil, "one the game doesn't know is left out")
	ns.Store:NoteName("Player-9-ENEMY", "Stabby Mcstab")
	check(db.names["Player-9-ENEMY"].class == "ROGUE", "a later sighting without a class keeps the one known")
	-- Guilds, with when they were seen; a change is kept, leaving needs two readings apart
	local book = db.names["Player-9-ENEMY"]
	ns.Store:NoteGuild("Player-9-ENEMY", "Night Watch")
	check(book.g == "Night Watch" and book.gt == clock, "a guild is noted with its time")
	clock = clock + 5
	ns.Store:NoteGuild("Player-9-ENEMY", "Dawn Blades")
	check(book.g == "Dawn Blades" and book.gt == clock, "a new guild replaces the old at once")
	ns.Store:NoteGuild("Player-9-ENEMY", nil)
	check(book.g == "Dawn Blades", "one reading of no guild doesn't drop a known one (the game may not have loaded it)")
	clock = clock + 40
	ns.Store:NoteGuild("Player-9-ENEMY", nil)
	check(book.g == "" and book.gt == clock, "a second reading of no guild, later, records that they left")
	ns.Store:NoteName("Player-9-ENEMY", "Stabby Mcstab", "ROGUE")
	check(book.g == "" and db.names["Player-9-ENEMY"] == book, "noting the name again keeps the guild")
	ns.Store:NoteGuild("Player-404-NOBODY", "Ghosts")
	check(db.names["Player-404-NOBODY"] == nil, "no guild is noted for a player not in the book")
end)()
;(function()
	-- The sync channel only carries addon data, so it has no place in a chat window: the game listed it in one
	-- when a player joined it by hand (the /join tip), and then showed every join, leave and owner change
	removedChannels = {}
	Fire("PLAYER_ENTERING_WORLD")
	RunTimers()
	check(#removedChannels == NUM_CHAT_WINDOWS and removedChannels[1] == "1:WantedNetHorde", "joining takes the channel out of every chat window, got "..table.concat(removedChannels, " "))
	local notice = chatFilters.CHAT_MSG_CHANNEL_NOTICE
	local userNotice = chatFilters.CHAT_MSG_CHANNEL_NOTICE_USER
	check(notice and userNotice, "channel notices are filtered")
	check(notice(nil, "CHAT_MSG_CHANNEL_NOTICE", "YOU_JOINED", "", nil, "6. WantedNetHorde", "", "", 0, 6, "WantedNetHorde") == true, "a notice for the sync channel is hidden")
	check(userNotice(nil, "CHAT_MSG_CHANNEL_NOTICE_USER", "OWNER_CHANGED", "Melyn Perdition", nil, "6. wantednethorde", "", "", 0, 6, "wantednethorde") == true, "an owner change on it is hidden, whatever the case")
	check(notice(nil, "CHAT_MSG_CHANNEL_NOTICE", "YOU_JOINED", "", nil, "1. General", "", "", 1, 1, "General") == false, "other channels' notices show")
end)()
;(function()
	-- Pruning: other players' kills, deaths and assists older than 3 days go at login, deaths this account's
	-- characters only witnessed too. Their own kills, deaths and assists stay, and so do bounties, claims, what a
	-- claim rests on, links and what the app may not have uploaded
	local db = ns.db
	local old, fresh = clock - 4 * 86400, clock - 2 * 86400
	local seq = 0
	local function Put(kind, t, data, origin)
		seq = seq + 1
		origin = origin or "Pruner"
		local id = origin..":"..seq
		db.records[id] = { kind = kind, id = id, origin = origin, seq = seq, prev = "0", t = t, data = data or {}, hash = "x" }
		db.chains[origin] = { seq = 100, lastHash = "x" }
		return id
	end
	local gone = { Put("kill", old), Put("death", old, { victim = "Player-9-V" }), Put("assist", old),
		Put("death", old - 200, { victim = "Player-9-T" }), -- the claim's victim, but minutes from the kill
		Put("death", old, { victim = "Player-9-V" }, ns.Store:GetOrigin()) } -- a death this character only witnessed
	local bounty = Put("bounty", old, { amount = 1, target = "Player-9-T" })
	local claimedKill = Put("kill", old, { victim = "Player-9-T" })
	local kept = { Put("kill", fresh), Put("death", fresh), bounty, claimedKill,
		Put("claim", old, { bounty = bounty, kill = claimedKill, victim = "Player-9-T", killT = old }),
		Put("death", old + 20, { victim = "Player-9-T" }), -- witnesses the claim
		Put("death", old, { victim = UnitGUID("player") }), -- this character's death
		Put("death", old, { victim = "Player-9-V", killer = UnitGUID("player") }), -- a death this character caused
		Put("kill", old, {}, ns.Store:GetOrigin()), -- this character's own
		Put("death", old, { victim = UnitGUID("player") }, ns.Store:GetOrigin()), -- this character's own death, as it recorded it
		Put("link", old, { code = "OLDCODE1", guid = "Player-9-L" }) }
	-- Another character of this account, known by its link record with the account's app code
	WantedAppLinks = { [db.accountMark] = "ACCT7777" }
	Put("link", old, { code = "ACCT7777", guid = "Player-1-ALT" }, "Alt Two")
	tinsert(kept, Put("kill", old, {}, "Alt Two"))
	-- Past a gap nobody filled: pruned, and the chain moves past it so it isn't asked for again
	seq = seq + 1 -- the gap
	local ahead = Put("death", old)
	db.chains.Pruner.seq = seq - 2
	tinsert(gone, ahead)
	local pruned = ns.Store:Prune(clock)
	WantedAppLinks = nil
	check(db.chains.Pruner.seq == seq, "the chain moved past the pruned record beyond the gap, got "..db.chains.Pruner.seq)
	check(pruned >= #gone, "the old kills, deaths and assists are pruned (with any older test records), got "..pruned)
	for _, id in ipairs(gone) do check(not db.records[id], id.." is pruned") end
	for _, id in ipairs(kept) do check(db.records[id], id.." is kept") end
	check(db.characters["Player-1-ALT"] and db.characters["Player-1-ALT"].n == "Alt Two", "a link with the account's app code names one of its characters")
	check(db.characters[UnitGUID("player")], "this character is in the account's book")
	local walked = 0
	for _ in ns.Store:Iterator("kill") do walked = walked + 1 end
	check(walked >= 2 and ns.Store:Prune(clock) == 0, "the index is rebuilt and a second prune finds nothing")
	-- The app hasn't read the last save: what came since its last catch-up stays until it has
	local appOld, appOlder = Put("death", clock - 9 * 86400), Put("death", clock - 12 * 86400)
	db.savedAt, db.catchupT = clock - 60, clock - 10 * 86400
	ns.Store:Prune(clock)
	check(db.records[appOld] and not db.records[appOlder], "records since the app's last catch-up wait for it; older ones go")
	db.catchupT = clock - 30
	ns.Store:Prune(clock)
	check(not db.records[appOld], "once the app caught up after the last save they go")
	db.savedAt, db.catchupT = nil, nil
	-- Pruned records aren't asked for again: our chain still says how far we got
	ClearSent()
	Fire("CHAT_MSG_ADDON", "WNTD", Message("H", { c = { Pruner = db.chains.Pruner.seq }, v = ns.VERSION }), "CHANNEL", "Some Peer", nil, nil, nil, "WantedNetHorde")
	RunTimers()
	for _, m in ipairs(Sent("CHANNEL")) do
		check(m.tag ~= "N", "a hello from a peer holding what we pruned asks for nothing")
	end
	ClearSent()
	Fire("CHAT_MSG_ADDON", "WNTD", Message("H", { c = { Pruner = db.chains.Pruner.seq + 3 }, v = ns.VERSION }), "CHANNEL", "Some Peer", nil, nil, nil, "WantedNetHorde")
	RunTimers()
	local asked
	for _, m in ipairs(Sent("CHANNEL")) do if m.tag == "N" then asked = m.tbl.n.Pruner end end
	check(asked == db.chains.Pruner.seq + 1, "only what's past our chain is asked for, got "..tostring(asked))
	-- And one a peer sends again (answering someone else) isn't taken back in
	local back = { kind = "death", id = gone[2], origin = "Pruner", seq = tonumber(gone[2]:match("%d+$")), prev = "0", t = old, data = { victim = "Player-9-V" } }
	check(select(2, ns.Store:MergeRelayed(back)) == "pruned" and not db.records[gone[2]], "a pruned record sent again isn't stored")
	-- Players not seen for a month go with it, unless a page still needs them; then the book keeps its cap
	local savedPlayers, savedStats, savedKos = db.players, db.enemyStats, db.kos
	local month = clock - 31 * 86400
	db.players = { ["Player-9-GONE"] = { name = "Gone", lastSeen = month }, ["Player-9-T"] = { name = "Target", lastSeen = month },
		["Player-9-KOS"] = { name = "Kos", lastSeen = month }, ["Player-9-FOE"] = { name = "Foe", lastSeen = month },
		["Player-9-NOW"] = { name = "Now", lastSeen = clock } }
	db.kos = { ["Player-9-KOS"] = { name = "Kos" } }
	db.enemyStats = { ["Player-9-FOE"] = { wins = 1, losses = 0, detections = 3, last = month },
		["Player-9-GONE"] = { wins = 0, losses = 0, detections = 1, last = month } }
	ns.Store:Prune(clock)
	check(db.players["Player-9-GONE"] == nil and db.players["Player-9-NOW"], "a player not seen for a month is dropped, a recent one kept")
	check(db.players["Player-9-T"] and db.players["Player-9-KOS"] and db.players["Player-9-FOE"], "a bounty target, Kill on Sight and a fought enemy are kept")
	for i = 1, ns.Store.PLAYERS_MAX + 10 do db.players["Player-9-FILL"..i] = { name = "Fill", lastSeen = clock - i } end
	ns.Store:Prune(clock)
	local numPlayers = 0
	for _ in pairs(db.players) do numPlayers = numPlayers + 1 end
	check(numPlayers == ns.Store.PLAYERS_MAX + 3 and db.players["Player-9-NOW"] and db.players["Player-9-FILL1"], "the most recent are kept up to the cap (plus the needed ones), got "..numPlayers)
	ns.Enemies:OnLoad()
	check(db.enemyStats["Player-9-GONE"] == nil and db.enemyStats["Player-9-FOE"], "an enemy only ever seen, not for a month, leaves the statistics; one fought stays")
	db.players, db.enemyStats, db.kos = savedPlayers, savedStats, savedKos
	-- Pages still show what's left
	for _, key in ipairs({ "board", "mine", "hunters", "activity", "enemies", "tools" }) do ns.UI:Show(key) end
	for id, r in pairs(db.records) do if r.origin == "Pruner" or r.origin == "Alt Two" then db.records[id] = nil end end
	db.chains.Pruner, db.chains["Alt Two"], db.characters["Player-1-ALT"] = nil, nil, nil
end)()
;(function()
	-- The app's catch-up can bring records already too old to keep: their chain moves on over them and they aren't
	-- stored (only to be pruned at the next login), so the app doesn't send them again. What's kept is stored.
	local db = ns.db
	local old, fresh = clock - 4 * 86400, clock - 60
	local function Rec(seq, t, kind, data)
		return { kind = kind or "death", id = "Catchup Far:"..seq, origin = "Catchup Far", seq = seq, prev = "h"..(seq - 1),
			hash = "h"..seq, t = t, data = data or { victim = "Player-9-FARV"..seq } }
	end
	local batch = { Rec(1, old), Rec(2, old), Rec(3, old, "death", { victim = UnitGUID("player") }), Rec(4, old),
		Rec(5, fresh), Rec(6, old, "bounty", { target = "Player-9-FARB", targetName = "Far Bounty", amount = 1000 }),
		Rec(7, old + 10, "death", { victim = "Player-9-CLAIMV" }) } -- witnesses a claim
	local claim = ns.Store:InsertTest("claim", "Some Hunter", { bounty = "b-far", victim = "Player-9-CLAIMV", killT = old })
	local savedT = db.catchupT
	WantedAppCatchup = { [db.accountMark] = { t = clock + 1000000, records = batch } }
	ns.Catchup:Import()
	RunFrames()
	check(ns.Store:GetChainSeq("Catchup Far") == 7, "the chain moved on over the old records, got "..ns.Store:GetChainSeq("Catchup Far"))
	for _, seq in ipairs({ 1, 2, 4 }) do check(not db.records["Catchup Far:"..seq], "an old death of others isn't stored: "..seq) end
	for _, seq in ipairs({ 3, 5, 6, 7 }) do check(db.records["Catchup Far:"..seq], "own, fresh, bounty and claim witness records are stored: "..seq) end
	check(ns.Store:GetFirstSeen("Catchup Far") == old, "the first record's time is kept with its chain")
	-- The same batch again (the app asks from the chain, so it wouldn't send it; a peer's fill might): nothing new
	local before = 0
	for _ in pairs(db.records) do before = before + 1 end
	WantedAppCatchup = { [db.accountMark] = { t = clock + 1000001, records = batch } }
	ns.Catchup:Import()
	RunFrames()
	local after = 0
	for _ in pairs(db.records) do after = after + 1 end
	check(after == before and not db.records["Catchup Far:1"], "a second catch-up of the same records stores nothing")
	for id, r in pairs(db.records) do if r.origin == "Catchup Far" then db.records[id] = nil end end
	db.records[claim.id] = nil
	db.chains["Catchup Far"], db.catchupT = nil, savedT
end)()
;(function()
	-- A fill answering for records pruned here says where our copy starts, and a receiver moves its chain on
	local function Rec(seq, prev, hash)
		return { kind = "death", id = "Old Timer:"..seq, origin = "Old Timer", seq = seq, prev = prev, t = clock - 60, data = { victim = "Player-9-V" }, hash = hash }
	end
	-- Receiving: we hold nothing of Old Timer; a fill starting at 50 with p moves the chain to 49 and on
	ClearSent()
	Fire("CHAT_MSG_ADDON", "WNTD", Message("F", { p = { ["Old Timer"] = 50 }, r = { Rec(50, "abc", "h50"), Rec(51, "h50", "h51") } }), "CHANNEL", "Some Peer", nil, nil, nil, "WantedNetHorde")
	check(ns.Store:GetChainSeq("Old Timer") == 51, "the chain moved on past the pruned start, got "..ns.Store:GetChainSeq("Old Timer"))
	check(ns.Store:Get("Old Timer:50") and not ns.Store:Get("Old Timer:50").brokenChain, "the first record after the skip isn't flagged")
	-- Sending: someone asks for Old Timer from 1; we answer with what we hold and where it starts
	ClearSent()
	clock = clock + 61
	Fire("CHAT_MSG_ADDON", "WNTD", Message("N", { n = { ["Old Timer"] = 1 } }), "CHANNEL", "New Asker", nil, nil, nil, "WantedNetHorde")
	clock = clock + 11 -- past the "someone answered first" window our own receipt above would trip
	RunTimers()
	RunFrames()
	local fills = {}
	for _, m in ipairs(Sent("CHANNEL")) do if m.tag == "F" then fills[#fills + 1] = m end end
	check(#fills >= 1 and fills[1].tbl.p and fills[1].tbl.p["Old Timer"] == 50 and #fills[1].tbl.r == 2, "the fill says our copy starts at 50 and carries what we hold")
	-- Pruning leaves holes inside a chain too (kept records between pruned ones). Sending: each hole is described
	local function Holey(origin, seq)
		return { kind = "death", id = origin..":"..seq, origin = origin, seq = seq, prev = "h"..(seq - 1), t = clock - 60, data = { victim = "Player-9-V" }, hash = "h"..seq }
	end
	for _, s in ipairs({ 1, 2, 5, 6, 20 }) do ns.db.records["Holey:"..s] = Holey("Holey", s) end
	ns.db.chains.Holey = { seq = 30, lastHash = "h30" }
	ClearSent()
	clock = clock + 11
	Fire("CHAT_MSG_ADDON", "WNTD", Message("N", { n = { Holey = 1 } }), "CHANNEL", "New Asker", nil, nil, nil, "WantedNetHorde")
	RunTimers()
	RunFrames()
	local gaps
	for _, m in ipairs(Sent("CHANNEL")) do
		if m.tag == "F" and m.tbl.g then
			gaps = {}
			for i, s in ipairs(m.tbl.g.Holey) do gaps[i] = format("%d", s) end
			gaps = table.concat(gaps, ",")
		end
	end
	check(gaps == "2,5,6,20,20,31", "the fill lists each hole as the seq before and after it, got "..tostring(gaps))
	-- Receiving: the chain moves over every hole in one fill, and past the pruned end. The records after the holes
	-- are held already (they came ahead of the gap), so the harness's decoded seqs (floats in Lua 5.4) don't matter
	local fill = { r = { Holey("Holey2", 1), Holey("Holey2", 2) }, g = { Holey2 = { 2, 5, 6, 20, 20, 31 } } }
	for _, s in ipairs({ 5, 6, 20 }) do ns.db.records["Holey2:"..s] = Holey("Holey2", s) end
	Fire("CHAT_MSG_ADDON", "WNTD", Message("F", fill), "CHANNEL", "Some Peer", nil, nil, nil, "WantedNetHorde")
	check(ns.Store:GetChainSeq("Holey2") == 30, "the chain moved over the holes to the sender's end, got "..ns.Store:GetChainSeq("Holey2"))
	check(not ns.Store:Get("Holey2:5").brokenChain and not ns.Store:Get("Holey2:20").brokenChain, "records after a hole aren't flagged")
	-- A hole past what we hold (an earlier message didn't arrive) isn't skipped
	Fire("CHAT_MSG_ADDON", "WNTD", Message("F", { r = { Holey("Holey2", 45) }, g = { Holey2 = { 40, 45 } } }), "CHANNEL", "Some Peer", nil, nil, nil, "WantedNetHorde")
	check(ns.Store:GetChainSeq("Holey2") == 30, "a hole starting past our chain is left for a later ask")
	for id, r in pairs(ns.db.records) do if r.origin == "Holey" or r.origin == "Holey2" then ns.db.records[id] = nil end end
	ns.db.chains.Holey, ns.db.chains.Holey2 = nil, nil
	-- A marker never moves our own chain
	local mine = ns.Store:GetChainSeq(ns.Store:GetOrigin())
	ns.Store:SkipTo(ns.Store:GetOrigin(), mine + 100, nil)
	check(ns.Store:GetChainSeq(ns.Store:GetOrigin()) == mine, "our own chain is never skipped")
end)()
;(function()
	-- Channel owners: what they do is said and logged; a kick is undone; a ban or new password falls back to whisper
	local function Notice(kind, player, actor)
		Fire("CHAT_MSG_CHANNEL_NOTICE_USER", kind, player, "", "6. WantedNetHorde", actor or "", "", 0, 6, "WantedNetHorde")
	end
	local function Said(text)
		for i = #printed, math.max(1, #printed - 3), -1 do if printed[i]:find(text, 1, true) then return true end end
		return false
	end
	Notice("PLAYER_KICKED", "Some Victim", "Bad Owner")
	check(Said("Some Victim was kicked from the sync channel by Bad Owner"), "a kick names the victim and the owner")
	Notice("MODERATION_ON", "Bad Owner")
	check(Said("Bad Owner turned moderation on"), "moderation names who turned it on")
	Notice("MODERATION_OFF", "Bad Owner")
	RunTimers()
	-- The game doesn't always name who did it (Chris's client, 2026-09-28: a Lua error on every such notice)
	Notice("SET_MODERATOR", "Melyn Perdition")
	check(not Said("made a moderator"), "a new moderator is logged, not said")
	Notice("PLAYER_BANNED", "Some Other", nil)
	check(Said("Some Other was banned from the sync channel by someone"), "a notice without an actor still reads")
	Notice("PLAYER_KICKED", (ns.Store:GetOrigin():match("^(%S+)")))
	check(Said("You were kicked from the sync channel by someone"), "a kick of us, by our first name as the game says it, is ours: "..tostring(printed[#printed]))
	RunTimers()
	Notice("OWNER_CHANGED", "Quiet Owner")
	check(not Said("Quiet Owner"), "an owner change is logged, not said")
	Fire("CHAT_MSG_CHANNEL_NOTICE_USER", "PLAYER_KICKED", "Nobody", "", "1. General", "Someone", "", 1, 1, "General")
	check(not Said("Nobody was kicked"), "other channels' notices are ignored")
	-- Kicked ourselves: out, then back in ten seconds later (a kick long after the last one)
	clock = clock + 11 * 60
	Notice("PLAYER_KICKED", ns.Store:GetOrigin(), "Bad Owner")
	check(Said("You were kicked from the sync channel by Bad Owner"), "a kick of ourselves is said in the second person")
	check(ns.Sync:GetInfo().channelId == nil, "after a kick we're out of the channel")
	RunTimers()
	check(ns.Sync:GetInfo().channelId == 6, "and back in after the retry")
	-- Banned: locked out; the players last heard on the channel are whispered a hello saying so
	check(ns.db.recentPeers["Some Peer"] and ns.db.recentPeers["New Asker"], "players heard on the channel are remembered")
	ClearSent()
	clock = clock + 700 -- past the greeting spacing
	Fire("CHAT_MSG_CHANNEL_NOTICE", "BANNED", "", "", "6. WantedNetHorde", "", "", 0, 6, "WantedNetHorde")
	check(Said("can't get into its sync channel (banned)"), "a ban is said")
	local hello = Sent("WHISPER", "Some Peer")
	check(#hello == 1 and hello[1].tag == "H" and hello[1].tbl.x == 1 and hello[1].tbl.r == "Realm", "a remembered channel peer is greeted by whisper, saying we're locked out")
	check(ns.Sync:GetInfo().channelId == nil, "locked out: not in the channel")
	-- Locked out and in a guild: what would go on the channel goes to the guild, and the guild is heard like the channel
	local guildHello = Sent("GUILD")
	check(#guildHello == 1 and guildHello[1].tag == "H" and type(guildHello[1].tbl.c) == "table", "locked out, a hello goes to the guild")
	ClearSent()
	ns.Store:NewRecord("pass", { bounty = "via-guild" })
	RunTimers()
	local guildLive = Sent("GUILD")
	check(#guildLive == 1 and guildLive[1].tag == "R" and guildLive[1].tbl.r[1].data.bounty == "via-guild", "locked out, our new record goes to the guild")
	Fire("CHAT_MSG_ADDON", "WNTD", addonSent[#addonSent].text, "GUILD", ns.Store:GetOrigin())
	check(ns.Sync:GetInfo().stats.echoed >= 1, "our own guild message coming back is recognised")
	Fire("CHAT_MSG_ADDON", "WNTD", Message("R", { v = ns.VERSION, r = { Rec("Guild Mate", 1) } }), "GUILD", "Guild Mate")
	RunFrames()
	check(ns.db.records["Guild Mate:1"] ~= nil, "a guildmate's record sent to the guild is taken like the channel's")
	local invalidBefore = ns.Sync:GetInfo().stats.invalid
	Fire("CHAT_MSG_ADDON", "WNTD", "not framed", "GUILD", "Guild Mate")
	check(ns.Sync:GetInfo().stats.invalid == invalidBefore + 1, "a guild message gets the same checks")
	Fire("CHAT_MSG_ADDON", "WNTD", Message("R", { v = ns.VERSION, r = { Rec("Party Mate", 1) } }), "PARTY", "Party Mate")
	RunFrames()
	check(ns.db.records["Party Mate:1"] == nil, "other chat types are still ignored")
	-- A same-realm player who says they're locked out is accepted as a link; one who doesn't isn't (as before)
	Fire("CHAT_MSG_ADDON", "WNTD", Message("H", { c = {}, r = "Realm", x = 1 }), "WHISPER", "Locked Friend")
	check(ns.Sync:GetLinks()["Locked Friend"] ~= nil, "a locked-out player on our realm links by whisper")
	Fire("CHAT_MSG_ADDON", "WNTD", Message("H", { c = {}, r = "Realm" }), "WHISPER", "Still Same Realmer")
	check(ns.Sync:GetLinks()["Still Same Realmer"] == nil, "a same-realm hello without the flag is still refused")
	-- The main channel is tried again every few minutes (CheckMain): while it still refuses us the lockout holds,
	-- and once it answers the lockout is over
	local function Retry() ns.db.homeCheck.tried = clock - ns.db.homeCheck.wait Tick() RunTimers() end
	local gcn = GetChannelName
	GetChannelName = function() return 0 end
	Retry()
	check(ns.Sync:GetInfo().channelId == nil, "still locked out while the channel refuses us")
	GetChannelName = gcn
	Retry()
	check(ns.Sync:GetInfo().channelId == 6, "back in the channel on a later retry")
	Fire("CHAT_MSG_CHANNEL_NOTICE", "BANNED", "", "", "6. WantedNetHorde", "", "", 0, 6, "WantedNetHorde")
	check(Said("can't get into its sync channel (banned)"), "a second lockout is said again (the first ended)")
	Retry()
	check(ns.Sync:GetInfo().channelId == 6, "and ends the same way")
	RunTimers()
	-- In the channel, nothing goes to the guild
	ClearSent()
	ns.Store:NewRecord("pass", { bounty = "channel-again" })
	clock = clock + 10
	RunTimers()
	check(#Sent("GUILD") == 0 and #Sent("CHANNEL") >= 1, "with the channel back, records go on the channel only")
end)()
;(function()
	-- Outlaws: four kills within twenty minutes, each backed by another record, make a player Wanted in game
	local now = clock
	local function Kill(i, killerGuid, killerName, victim, t, backed)
		local deathId = "od-"..killerGuid.."-"..i
		ns.Store:InsertTest("kill", killerName, { killer = killerGuid, killerName = killerName, victim = victim, victimName = "Victim "..i, deathId = deathId, zone = "Durotar" }, t)
		if backed then
			ns.Store:InsertTest("death", "Some Witness", { victim = victim, victimName = "Victim "..i, deathId = deathId, zone = "Durotar" }, t + 1)
		end
	end
	for i = 1, 4 do Kill(i, "Player-9-GANK", "Gank Lord", "Player-9-V"..i, now - 1200 + i * 200, true) end
	local o = ns.Reputation:GetOutlaw("Player-9-GANK")
	check(o and o.rank == "Wanted" and o.kills == 4, "four backed kills in twenty minutes: Wanted, got "..tostring(o and o.rank))
	for i = 5, 8 do Kill(i, "Player-9-GANK", "Gank Lord", "Player-9-W"..i, now - 300 + i * 30, false) end
	check(ns.Reputation:GetOutlaw("Player-9-GANK").kills == 4, "kills only the killer recorded don't count")
	for i = 1, 4 do Kill(i, "Player-9-SLOW", "Slow Poke", "Player-9-S"..i, now - 3000 + i * 500, true) end
	check(ns.Reputation:GetOutlaw("Player-9-SLOW") == nil, "four kills over twenty-five minutes: not an outlaw")
	for i = 1, 5 do Kill(i, "Player-9-CAMP", "Camp Lord", "Player-9-SAME", now - 600 + i * 60, true) end
	check(ns.Reputation:GetOutlaw("Player-9-CAMP") == nil, "camping one player counts as one kill")
	-- The victim's own record naming the killer counts as a backed kill too
	for i = 1, 4 do ns.Store:InsertTest("death", "Poor Victim "..i, { victim = "Player-9-PV"..i, victimName = "Poor Victim "..i, killer = "Player-9-RECAP", killerName = "Recap Killer", deathId = "rc"..i, zone = "Durotar" }, now - 900 + i * 100) end
	check(ns.Reputation:GetOutlaw("Player-9-RECAP") ~= nil, "kills named by the victims' own records count")
	-- Nearby, the alert and Call for help say so
	local warnings = {}
	local realWarn = ns.Alerts.Warn
	ns.Alerts.Warn = function(self, title, ...) warnings[#warnings + 1] = title return realWarn(self, title, ...) end
	local exposedBefore = ns.db.settings.detect.onlyWhenExposed
	ns.db.settings.detect.onlyWhenExposed = false
	enemyUnits.nameplate1 = { guid = "Player-9-GANK", name = "Gank Lord", class = "ROGUE", level = 30 }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
	local d = ns.Enemies:Describe("Player-9-GANK")
	check(d.outlaw and d.outlaw.rank == "Wanted", "an outlaw's description carries the rank")
	if ns.Enemies:ShouldAlert() then
		check(warnings[#warnings] == "OUTLAW: Gank Lord", "a new outlaw nearby is announced, got "..tostring(warnings[#warnings]))
	end
	local text = ns.EnemyMenu:BuildHelpText()
	check(text:find("Gank Lord", 1, true) and text:find("OUTLAW", 1, true), "Call for help names the outlaw: "..text)
	ns.Alerts.Warn = realWarn
	ns.db.settings.detect.onlyWhenExposed = exposedBefore
	enemyUnits.nameplate1 = nil
	Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
	ns.Enemies:ClearNearby()
end)()
;(function()
	-- Posses: a call against an outlaw goes out as an urgent sighting with the call attached; others in the zone
	-- are asked to join; a joiner whispers the caller and is invited
	invited = {}
	C_PartyInfo = { InviteUnit = function(name) invited[#invited + 1] = name end }
	local function Said(text)
		for i = #printed, math.max(1, #printed - 3), -1 do if printed[i]:find(text, 1, true) then return true end end
		return false
	end
	enemyUnits.nameplate1 = { guid = "Player-9-GANK", name = "Gank Lord", class = "ROGUE", level = 30 }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
	enemyUnits.nameplate2 = { guid = "Player-9-PLAIN", name = "Plain Player", class = "MAGE", level = 30 }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
	check(not ns.Posse:Call("Player-9-PLAIN") and Said("is neither"), "no posse against a player who isn't an outlaw or bountied")
	ClearSent()
	clock = clock + 61
	check(ns.Posse:Call("Player-9-GANK") and Said("Posse called against Gank Lord"), "a posse against an outlaw is called")
	RunTimers()
	local calls = {}
	for _, m in ipairs(Sent("CHANNEL")) do
		if m.tag == "S" then for _, sd in ipairs(m.tbl.s or {}) do if sd.p then calls[#calls + 1] = sd end end end
	end
	check(#calls == 1 and calls[1].g == "Player-9-GANK" and calls[1].p.c == ns.Store:GetOrigin() and calls[1].p.k == "Wanted", "the call is a sighting with the caller and why attached")
	check(not ns.Posse:Call("Player-9-GANK") and Said("already out"), "one posse per target at a time")
	-- Someone else's call reaches us: a dialog to join, in our zone only
	local realIsDialogShown = ns.Widgets.IsDialogShown
	ns.Widgets.IsDialogShown = function() return false end -- earlier tests left their dialogs up
	lastDialog = nil
	Fire("CHAT_MSG_ADDON", "WNTD", Message("S", { s = { { g = "Player-9-FAR", n = "Far Foe", z = "Elsewhere", x = 1, y = 2, p = { c = "Caller Guy", k = "Wanted" } } } }), "CHANNEL", "Caller Guy", nil, nil, nil, "WantedNetHorde")
	check(lastDialog == nil, "a posse in another zone doesn't ask")
	Fire("CHAT_MSG_ADDON", "WNTD", Message("S", { s = { { g = "Player-9-NEAR", n = "Near Foe", z = GetZoneText(), x = 10, y = 20, p = { c = "Caller Guy", k = "Notorious" } } } }), "CHANNEL", "Caller Guy", nil, nil, nil, "WantedNetHorde")
	check(lastDialog and lastDialog.title == "Posse: Near Foe" and lastDialog.text:find("Caller Guy is calling a posse against Near Foe (Notorious)", 1, true), "a posse in our zone asks us to join: "..tostring(lastDialog and lastDialog.text))
	ClearSent()
	chatSent = {}
	lastDialog.onConfirm()
	check(chatSent[#chatSent] and chatSent[#chatSent]:find("^WHISPER: Wanted: joining your posse against Near Foe"), "joining whispers the caller: "..tostring(chatSent[#chatSent]))
	local joins = Sent("WHISPER", "Caller Guy")
	check(#joins == 1 and joins[1].tag == "J" and joins[1].tbl.g == "Player-9-NEAR", "and tells their addon")
	-- Someone joins ours: invited. A join for a posse we haven't called is ignored.
	Fire("CHAT_MSG_ADDON", "WNTD", Message("J", { g = "Player-9-GANK" }), "WHISPER", "Joiner Jane")
	check(#invited == 1 and invited[1] == "Joiner Jane" and Said("Joiner Jane joins the posse against Gank Lord"), "a joiner is invited, got "..#invited)
	Fire("CHAT_MSG_ADDON", "WNTD", Message("J", { g = "Player-9-NOPOSSE" }), "WHISPER", "Random Guy")
	check(#invited == 1, "a join for no posse of ours invites nobody")
	-- A death record carries the map id
	enemyUnits.nameplate1, enemyUnits.nameplate2 = nil, nil
	Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
	Fire("NAME_PLATE_UNIT_REMOVED", "nameplate2")
	ns.Enemies:ClearNearby()
	ns.Widgets.IsDialogShown = realIsDialogShown
	lastDialog = nil
end)()
;(function()
	-- Sex, from the game's numbers (2 male, 3 female): on enemies seen and on the records they end up in
	enemyUnits.nameplate1 = { guid = "Player-9-SHE", name = "Sheila Sharp", class = "ROGUE", level = 30, sex = 3 }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
	check(ns.Store:GetPlayer("Player-9-SHE").sex == "female", "an enemy seen is recorded as female")
	enemyUnits.nameplate1 = nil
	Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
	ns.Enemies:ClearNearby()
	local found
	for k in ns.Store:Iterator("kill") do if k.data.killerSex then found = k end end
	for d in ns.Store:Iterator("death") do if d.data.victimSex then found = found or d end end
	check(found ~= nil, "a record made this session carries a sex")
end)()
-- 1.4.0: the main channel, joined without a password. Turning us away (a ban, a password, moderation) is marked for
-- the Wanted app; the addon never picks a channel itself, and tries the main one again quietly, waiting twice as
-- long after each refusal. With no server channel known, being let in brings sync back to the main channel
;(function()
	local main = "WantedNetHorde"
	local realJoin, realName = JoinPermanentChannel, GetChannelName
	local inChannel, mainOpen = { [main] = true }, false
	JoinPermanentChannel = function(name, password)
		realJoin(name, password)
		if name == main and not mainOpen then
			Fire("CHANNEL_PASSWORD_REQUEST", name)
			Fire("CHAT_MSG_CHANNEL_NOTICE", "WRONG_PASSWORD", "", "", "", "", "", "", "", name)
		else
			inChannel[name] = true
		end
	end
	GetChannelName = function(name) return inChannel[name] and 6 or 0 end
	local function MainTries() local n = 0 for _, j in ipairs(joinedWith) do if j.name == main then n = n + 1 end end return n end
	ns:RunCommand("reconnect")
	RunTimers()
	check(ns.Sync:GetInfo().channelName == main and ns.Sync:GetInfo().channelId == 6 and ns.db.syncChannel == nil, "on the main channel, no server channel known")
	ns.db.recentPeers["Peer One"], ns.db.recentPeers["Peer Two"], ns.db.recentPeers["Peer Three"] = clock, clock, clock
	ClearSent()
	for i = #joinedWith, 1, -1 do joinedWith[i] = nil end
	local leftBefore = #leftChannels
	inChannel[main] = nil
	Fire("CHAT_MSG_CHANNEL_NOTICE", "BANNED", "", "", "6. "..main, "", "", 0, 6, main)
	RunTimers()
	local state = ns.db.syncChannelState
	check(state.mainRefused and not state.mainOpen and state.epoch == 0 and state.at == clock, "a ban marks the main channel refused")
	check(ns.db.syncChannel == nil and ns.Sync:GetInfo().channelName == main and #joinedWith == 0 and #leftChannels == leftBefore, "and the addon moves nowhere by itself")
	local moves = 0
	for _, m in ipairs(addonSent) do if m.text:find("^M:") then moves = moves + 1 end end
	check(moves == 0, "nor tells anyone to move")
	Tick()
	RunTimers()
	check(MainTries() == 0, "not tried again before 5 minutes")
	clock = clock + 5 * 60
	Tick()
	RunTimers()
	check(MainTries() == 1 and joinedWith[1].password == nil, "tried again after 5 minutes, without a password")
	check(ns.db.homeCheck.wait == 10 * 60 and ns.Sync:GetInfo().channelId == nil and ns.db.syncChannel == nil, "still refused: the next wait doubles, and still no channel of our own")
	check(chatFilters["CHAT_MSG_CHANNEL_NOTICE"](nil, "CHAT_MSG_CHANNEL_NOTICE", "WRONG_PASSWORD", "", "", "", "", "", "", "", main) == true, "its notices are hidden")
	clock = clock + 10 * 60
	Tick()
	RunTimers()
	check(MainTries() == 2 and ns.db.homeCheck.wait == 20 * 60, "and doubles again")
	clock = clock + 20 * 60
	Tick()
	RunTimers()
	check(MainTries() == 3 and ns.db.homeCheck.wait == 25 * 60 and ns.db.syncChannelState.at == clock, "never more than 25 minutes, so a report is never older than the server's 30")
	-- Not in a fight or an instance
	clock = clock + 60 * 60
	local outside = IsInInstance
	IsInInstance = function() return true, "party" end
	Tick()
	IsInInstance = outside
	check(MainTries() == 3, "not tried in an instance")
	mainOpen = true
	Tick()
	RunTimers()
	check(ns.Sync:GetInfo().channelName == main and ns.Sync:GetInfo().channelId == 6, "no server channel known: back on the main channel once it lets us in")
	check(state.mainOpen and not state.mainRefused and ns.db.homeCheck.wait == 5 * 60, "marked open, and the wait starts over")
	-- Kicked twice in a few minutes: turned away
	Fire("CHAT_MSG_CHANNEL_NOTICE_USER", "PLAYER_KICKED", ns.Store:GetOrigin(), "", "6. "..main, "Griefer", "", 0, 6, main)
	RunTimers()
	check(ns.Sync:GetInfo().channelId == 6 and state.mainOpen, "one kick: back in")
	Fire("CHAT_MSG_CHANNEL_NOTICE_USER", "PLAYER_KICKED", ns.Store:GetOrigin(), "", "6. "..main, "Griefer", "", 0, 6, main)
	check(state.mainRefused and ns.Sync:GetInfo().channelId == nil, "kicked again soon after: the main channel turns us away")
	ns:RunCommand("reconnect")
	RunTimers()
	JoinPermanentChannel, GetChannelName = realJoin, realName
end)()
-- The server's channel comes through the app's catch-up: followed (no password), told to the players we know as the
-- server's. The main channel is still tried; letting us in is noted, but we stay until the server's pointer says main
;(function()
	local main = "WantedNetHorde"
	local realJoin, realName = JoinPermanentChannel, GetChannelName
	local inChannel, mainOpen = {}, false
	JoinPermanentChannel = function(name, password)
		realJoin(name, password)
		if name == main and not mainOpen then
			Fire("CHANNEL_PASSWORD_REQUEST", name)
			Fire("CHAT_MSG_CHANNEL_NOTICE", "WRONG_PASSWORD", "", "", "", "", "", "", "", name)
		else
			inChannel[name] = true
		end
	end
	GetChannelName = function(name) return inChannel[name] and 6 or 0 end
	Fire("CHAT_MSG_CHANNEL_NOTICE", "WRONG_PASSWORD", "", "", "", "", "", "", "", main)
	local state = ns.db.syncChannelState
	check(state.mainRefused and ns.Sync:GetInfo().channelId == nil, "a password on the main channel: refused")
	ns.Sync:AdoptFromApp({ e = 1, n = "WantedNetHordefsvltx", p = "wnt1" })
	ns.Sync:AdoptFromApp({ e = 1, n = "WantedNetAllianceabc" })
	ns.Sync:AdoptFromApp({ e = 1, n = "SomethingElse" })
	check(ns.db.syncChannel == nil, "a pointer with a password (from before 1.4.0), or not on our side, isn't followed")
	ClearSent()
	for i = #joinedWith, 1, -1 do joinedWith[i] = nil end
	local function Catchup(pointer)
		WantedAppCatchup = { [ns.db.accountMark] = { t = clock, records = {}, channel = pointer } }
		ns.Catchup:Import()
		RunTimers()
	end
	Catchup({ e = 7, n = "WantedNetHordesrvone" })
	local pointer = ns.db.syncChannel
	check(pointer and pointer.e == 7 and pointer.n == "WantedNetHordesrvone" and pointer.p == nil, "the app's channel is followed")
	check(ns.Sync:GetInfo().channelName == "WantedNetHordesrvone" and ns.Sync:GetInfo().channelId == 6, "and synced on")
	check(joinedWith[#joinedWith].name == "WantedNetHordesrvone" and joinedWith[#joinedWith].password == nil, "joined without a password")
	local move
	for _, m in ipairs(Sent("WHISPER", "Peer One")) do if m.tag == "M" then move = m end end
	check(move and move.tbl.e == 7 and move.tbl.n == "WantedNetHordesrvone" and move.tbl.a == 1 and move.tbl.h == 1 and move.tbl.p == nil,
		"the players we know are told, marked as the server's, one whisper from the app")
	ClearSent()
	Catchup({ e = 7, n = "WantedNetHordesrvone" })
	Catchup({ e = 6, n = "WantedNetHordeolder" })
	check(ns.db.syncChannel.e == 7 and #Sent("WHISPER") == 0, "the same or an older pointer again changes nothing and tells nobody")
	Catchup({ e = 0, n = main })
	Catchup({ e = 7, n = "WantedNetHordesrvone", p = "wnt1" })
	check(ns.db.syncChannel.e == 7 and ns.db.syncChannel.n == "WantedNetHordesrvone", "the app's default main pointer at epoch 0, or one with a password, changes nothing")
	Catchup({ e = 7, n = "WantedNetHordesrvfix" })
	check(ns.db.syncChannel.e == 7 and ns.Sync:GetInfo().channelName == "WantedNetHordesrvfix", "the app's pointer at the same epoch with another name is followed")
	Catchup({ e = 7, n = "WantedNetHordesrvone" })
	ClearSent()
	-- The server's channel turns us away too: reported the same way, at its epoch; we stay, try it again, and wait
	inChannel["WantedNetHordesrvone"] = nil
	clock = clock + 60
	Fire("CHAT_MSG_CHANNEL_NOTICE", "WRONG_PASSWORD", "", "", "", "", "", "", "", "WantedNetHordesrvone")
	RunTimers()
	check(state.mainRefused and state.epoch == 7 and state.at == clock and ns.Sync:GetInfo().channelId == nil, "the server's channel refusing us is reported, at its epoch")
	check(ns.Sync:GetInfo().channelName == "WantedNetHordesrvone" and ns.db.syncChannel.e == 7, "and we stay on it")
	Tick()
	RunTimers()
	check(ns.Sync:GetInfo().channelId == 6 and not state.mainRefused and state.epoch == 7, "tried again: let in, reported open")
	-- The main channel lets us in again: noted for the app, but we stay
	mainOpen = true
	ns.db.homeCheck.tried = clock - ns.db.homeCheck.wait
	Tick()
	RunTimers()
	check(state.mainOpen and not state.mainRefused and state.epoch == 7 and state.at == clock, "the main channel letting us in is noted, with the server's epoch and when")
	check(ns.Sync:GetInfo().channelName == "WantedNetHordesrvone" and ns.Sync:GetInfo().channelId == 6, "but we stay on the server's channel")
	check(leftChannels[#leftChannels] == main, "and leave the main one again")
	-- The server points back to the main channel
	Catchup({ e = 8, n = main })
	check(ns.Sync:GetInfo().channelName == main and ns.Sync:GetInfo().channelId == 6 and ns.db.syncChannel.e == 8, "back on the main channel when the server says so")
	check(leftChannels[#leftChannels] == "WantedNetHordesrvone", "the server's channel is left")
	JoinPermanentChannel, GetChannelName = realJoin, realName
end)()
-- A pointer by whisper: followed only when it's the server's (the via-app mark), from a player we know, and newer;
-- passed on once more, never past the hop cap
;(function()
	local function Move(from, tbl) Fire("CHAT_MSG_ADDON", "WNTD", "M:1:1/1:"..ns.Sync:Encode(tbl), "WHISPER", from) end
	local e = ns.db.syncChannel.e
	Move("Peer One", { e = e + 1, n = "WantedNetHordemadeup" })
	Move("Peer Two", { e = e + 1, n = "WantedNetHordemadeup", p = "pass12345" })
	Move("Peer Three", { e = e + 1, n = "WantedNetHordemadeup", p = "wnt1", a = 1, h = 1 })
	check(ns.db.syncChannel.e == e, "a move without the server's mark, or with a password, isn't followed")
	Move("Peer One", { e = e, n = "WantedNetHordesame", a = 1, h = 1 })
	Move("Peer One", { e = e - 1, n = "WantedNetHordeolder", a = 1, h = 1 })
	check(ns.db.syncChannel.e == e and ns.db.syncChannel.n == "WantedNetHorde", "nor one no newer than ours")
	Move("Stranger Danger", { e = e + 1, n = "WantedNetHordestrange", a = 1, h = 1 })
	check(ns.db.syncChannel.e == e, "nor one from a player we don't know")
	ClearSent()
	Move("Peer One", { e = e + 1, n = "WantedNetHordesrvtwo", a = 1, h = 1 })
	RunTimers()
	check(ns.db.syncChannel.e == e + 1 and ns.Sync:GetInfo().channelName == "WantedNetHordesrvtwo", "the server's pointer from a player we know is followed")
	local move
	for _, m in ipairs(Sent("WHISPER", "Peer Two")) do if m.tag == "M" then move = m end end
	check(move and move.tbl.h == 2 and move.tbl.a == 1 and move.tbl.e == e + 1, "and passed on once more, a whisper further")
	ClearSent()
	Move("Peer One", { e = e + 2, n = "WantedNetHordesrvthree", a = 1, h = 2 })
	RunTimers()
	local spread = 0
	for _, m in ipairs(Sent("WHISPER")) do if m.tag == "M" then spread = spread + 1 end end
	check(ns.db.syncChannel.e == e + 2 and spread == 0, "at the hop cap: followed, not passed on")
	Move("Peer Three", { e = 0, q = 1 })
	local answer = Sent("WHISPER", "Peer Three")
	check(#answer == 1 and answer[1].tbl.e == e + 2 and answer[1].tbl.n == "WantedNetHordesrvthree" and answer[1].tbl.a == 1 and answer[1].tbl.h == 3,
		"a player behind who asks is told, past the cap so they don't pass it on")
end)()
-- The game's password box plays the party-invite sound: it's muted around each of our joins and comes back after;
-- overlapping joins unmute once, after the last
;(function()
	local INVITE = 567451
	RunTimers()
	check(not mutedSounds[INVITE], "the invite sound isn't muted between joins")
	local realJoin, realName = JoinPermanentChannel, GetChannelName
	local mutedAtJoin = {}
	JoinPermanentChannel = function(name, password) mutedAtJoin[#mutedAtJoin + 1] = mutedSounds[INVITE] realJoin(name, password) end
	GetChannelName = function() return 0 end
	local mutes, unmutes = muteCalls, unmuteCalls
	ns:RunCommand("reconnect")
	local batch = timers
	timers = {}
	for _, f in ipairs(batch) do f() end
	check(mutedAtJoin[1] == true, "the invite sound is muted while we join")
	ns.db.homeCheck.tried = clock - ns.db.homeCheck.wait
	Tick() -- on the server's channel, the main one is tried at the same time
	check(#mutedAtJoin == 2 and mutedAtJoin[2] == true and muteCalls == mutes + 1, "a second join while muted doesn't mute again")
	RunTimers()
	check(not mutedSounds[INVITE] and unmuteCalls == unmutes + 1, "both joins over: unmuted once")
	-- Logging out mid-join unmutes at once
	ns:RunCommand("reconnect")
	batch = timers
	timers = {}
	for _, f in ipairs(batch) do f() end
	Fire("PLAYER_LOGOUT")
	check(not mutedSounds[INVITE], "logging out unmutes")
	RunTimers()
	check(unmuteCalls == unmutes + 2, "and the timer after doesn't unmute twice")
	JoinPermanentChannel, GetChannelName = realJoin, realName
	ns:RunCommand("reconnect")
	RunTimers()
end)()
-- The member list is asked for at most once in 10 seconds, and not at all once the count is known, however often
-- the game rebuilds its channel list (seven requests in a second at login, 2026-10-01)
;(function()
	local realList = ListChannelByName
	local asks = 0
	ListChannelByName = function(name) asks = asks + 1 realList(name) end
	clock = clock + 60
	-- The game's channel list (GetChannelDisplayInfo) has the main channel
	ns.Sync:AdoptFromApp({ e = ns.db.syncChannel.e + 1, n = "WantedNetHorde" })
	RunTimers()
	check(ns.Sync:GetMembers() == nil and asks == 1, "a fresh channel: its member list is asked for once")
	for _ = 1, 7 do Fire("CHANNEL_UI_UPDATE") end
	RunTimers()
	check(asks == 1, "a rebuilt channel list right after doesn't ask again")
	clock = clock + 10
	-- Rebuilt lists before the answer: their timers find the count known by the time they run
	for _ = 1, 7 do Fire("CHANNEL_UI_UPDATE") end
	Fire("CHAT_MSG_CHANNEL_LIST", "Peer One, Peer Two", "", "", "", "", "", "", "", "WantedNetHorde")
	check(ns.Sync:GetMembers() == 2, "the answer gives the count")
	RunTimers()
	check(asks == 1, "the requests they had queued aren't sent")
	for _ = 1, 7 do Fire("CHANNEL_UI_UPDATE") end
	RunTimers()
	check(asks == 1, "once the count is known, a rebuilt list doesn't ask")
	ListChannelByName = realList
end)()
-- The wait before the next try of the main channel is logged once, not every tick
;(function()
	ns.Sync:AdoptFromApp({ e = ns.db.syncChannel.e + 1, n = "WantedNetHordewaiting" })
	RunTimers()
	ns.db.homeCheck.tried = clock
	local realLog, said = ns.Log, 0
	ns.Log = function(self, fmt, ...)
		if fmt:find("next try of", 1, true) then said = said + 1 end
		return realLog(self, fmt, ...)
	end
	Tick()
	Tick()
	Tick()
	check(said == 1, "the next try's time is logged once")
	ns.db.homeCheck.tried = clock + 60
	Tick()
	check(said == 2, "and again for a new wait")
	ns.Log = realLog
end)()
-- /wanted who: a /who search, its results printed with full names and guilds
;(function()
	C_FriendList = {
		SetWhoToUi = function() end,
		SendWho = function() Fire("WHO_LIST_UPDATE") end,
		GetNumWhoResults = function() return 1 end,
		GetWhoInfo = function() return { fullName = "Stabby Mcstab", fullGuildName = "Night Watch", level = 20, classStr = "Rogue", area = "Durotar", filename = "ROGUE", gender = 2 } end,
	}
	local before = #printed
	ns:RunCommand("who", "Stabby")
	local found = false
	for i = before + 1, #printed do
		if printed[i]:find("Stabby Mcstab", 1, true) and printed[i]:find("Night Watch", 1, true) then found = true end
	end
	check(found, "/wanted who prints the full name and guild the game returns")
	C_FriendList = nil
end)()
-- /wanted who reads the game's chat answer: name, level, race, class, guild and zone
;(function()
	ns:RunCommand("who", "Hexgatha Soulwither")
	Fire("CHAT_MSG_SYSTEM", "|Hplayer:Hexgatha Soulwither|h[Hexgatha Soulwither]|h: Level 20 Orc Warlock <who pulled> - Tarren Mill")
	local read
	for i = #printed, math.max(1, #printed - 5), -1 do if printed[i]:find("read from chat: Hexgatha Soulwither, level 20 Orc Warlock, guild who pulled, in Tarren Mill", 1, true) then read = true end end
	check(read, "the who probe reads the chat answer")
	RunTimers()
end)()
-- The channel's number is asked for before every message: the game renumbers channels, and a kept number once
-- pointed at General
;(function()
	local realName = GetChannelName
	local netName = ns.Sync:GetInfo().channelName
	local function Channel(n) return function(name) if name == netName then return n, netName end return 0 end end
	local function SendTo()
		ClearSent()
		ns.Store:NewRecord("death", { deathId = "number"..clock, victim = "Player-9-NUMBER", victimName = "Number Test", victimFaction = "Alliance", zone = "Durotar" })
		clock = clock + 120
		RunTimers()
		local targets = {}
		for _, m in ipairs(addonSent) do if m.chatType == "CHANNEL" then targets[m.target] = true end end
		return targets
	end
	GetChannelName = Channel(7)
	local to = SendTo()
	check(to["7"] and not to["6"] and ns.Sync:GetInfo().channelId == 7, "after the game renumbers the channel, messages go to its new number")
	GetChannelName = Channel(0)
	to = SendTo()
	check(next(to) == nil and ns.Sync:GetInfo().channelId == nil, "with the channel at no number, nothing is sent and it rejoins")
	GetChannelName = realName
	RunTimers()
	check(ns.Sync:GetInfo().channelId == 6, "and it's back once the game has it again")
end)()
;(function()
	-- The version book: each player's Wanted version from their messages, for the app to pass on
	local book = ns.db.addonVersions
	check(book[UnitName("player")] and book[UnitName("player")].v == ns.VERSION, "the version book has this player's own version")
	ns.Store:NoteAddonVersion("Realm Walker-SomeRealm", "1.2.20")
	check(book["Realm Walker"] and book["Realm Walker"].v == "1.2.20", "a realm on the sender's name is dropped")
	for _, junk in ipairs({ { "Junk One", "not a version" }, { "Junk Two", 12 }, { "Junk Three", string.rep("1", 30) } }) do
		ns.Store:NoteAddonVersion(junk[1], junk[2])
		check(book[junk[1]] == nil, "a bad version isn't noted: "..tostring(junk[2]))
	end
	-- Old entries go at load; the book never grows past its cap
	local now = GetServerTime()
	book["Long Gone"] = { v = "1.0.0", t = now - 15 * 86400 }
	for i = 1, ns.Store.VERSION_BOOK_MAX + 10 do
		book["Fill "..i] = { v = "1.2.0", t = now - i }
	end
	ns.Store:OnLoad()
	local count = 0
	for _ in pairs(book) do count = count + 1 end
	check(book["Long Gone"] == nil, "a version not seen for two weeks is dropped")
	check(count == ns.Store.VERSION_BOOK_MAX, "the version book keeps the newest up to its cap, got "..count)
end)()
;(function()
	-- Kill streaks: multi-kills within 30 s, streaks since our last death, callouts, and party or guild lines only
	-- when asked for
	local Streaks = ns.Streaks
	local settings = ns.db.settings.streaks
	check(settings.callout == true and settings.sound == true and settings.announce == "none", "streak callout and sound on, announcing off by default")
	local played = 0
	local realPlay = PlaySoundFile
	PlaySoundFile = function() played = played + 1 return true end
	-- The callout frame: the one frame whose title reads a callout (earlier tests' kills may have made it already)
	local calloutFrame
	local function Callout()
		if not calloutFrame then
			local names = {}
			for n = 2, 5 do names[strupper(Streaks:MultiLabel(n))] = true end
			for _, n in ipairs({ 3, 5, 8 }) do names[strupper(Streaks:StreakLabel(n))] = true end
			for _, f in ipairs(Mock.created) do
				local t = rawget(f, "title")
				if t and rawget(f, "sub") and names[t._text] then calloutFrame = f end
			end
		end
		if calloutFrame and calloutFrame._shown then
			return calloutFrame.title._text, calloutFrame.sub._text
		end
	end
	chatSent = {}
	Streaks:OnDeath()
	clock = clock + 100
	Streaks:OnKill("Victim One")
	local chain, streak = Streaks:GetCounts()
	check(chain == 1 and streak == 1 and played == 0, "one kill is no callout")
	Streaks:OnKill("Victim One")
	check(select(2, Streaks:GetCounts()) == 1, "the same victim recorded twice counts once")
	clock = clock + 30
	Streaks:OnKill("Victim Two")
	check(Callout() == "DOUBLE KILL" and played == 1, "a kill 30 s after the last is a double kill, with a sound")
	clock = clock + 31
	Streaks:OnKill("Victim Three")
	chain, streak = Streaks:GetCounts()
	check(chain == 1 and streak == 3, "31 s later the multi-kill starts again, the streak goes on")
	local title, sub = Callout()
	check(title == "KILLING SPREE" and sub == "3 kills without dying", "three kills without dying is a killing spree, got "..tostring(title))
	check(#chatSent == 0, "nothing is announced by default")
	-- Streak thresholds and multi-kill names
	check(Streaks:StreakLabel(3) == "Killing spree" and Streaks:StreakLabel(4) == nil and Streaks:StreakLabel(5) == "Unstoppable"
		and Streaks:StreakLabel(8) == "Legendary" and Streaks:StreakLabel(9) == nil and Streaks:StreakLabel(10) == "Legendary (10)"
		and Streaks:StreakLabel(12) == nil and Streaks:StreakLabel(15) == "Legendary (15)", "streak callouts at 3, 5, 8, 10 and every 5 after")
	check(Streaks:MultiLabel(1) == nil and Streaks:MultiLabel(2) == "Double kill" and Streaks:MultiLabel(3) == "Triple kill"
		and Streaks:MultiLabel(4) == "Quad kill" and Streaks:MultiLabel(5) == "Rampage" and Streaks:MultiLabel(7) == "Rampage", "multi-kill names")
	-- Our death resets the streak (the game's own death event)
	Fire("PLAYER_DEAD")
	RunTimers()
	chain, streak = Streaks:GetCounts()
	check(chain == 0 and streak == 0, "dying resets the streak")
	-- The kill records Recorder makes are what count; another player's kill record doesn't
	clock = clock + 100
	Fire("PARTY_KILL", "Player-1-ME", "Player-9-ENEMY")
	check(select(2, Streaks:GetCounts()) == 1, "our own kill record counts")
	-- Announcing: only to the chosen party or guild, throttled, never anywhere else
	settings.announce = "party"
	Streaks:OnDeath()
	for i = 1, 3 do
		clock = clock + 31
		Streaks:OnKill("Party Victim "..i)
	end
	check(#chatSent == 1 and chatSent[1] == "PARTY: Wanted: Test is on a killing spree (3 kills)", "a streak goes to the party when asked, got "..tostring(chatSent[1]))
	clock = clock + 5
	Streaks:OnKill("Party Victim 4")
	check(#chatSent == 1, "a second line within 10 s is held back")
	clock = clock + 10
	Streaks:OnKill("Party Victim 5")
	check(#chatSent == 2 and chatSent[2] == "PARTY: Wanted: Test is unstoppable (5 kills)", "another line once 10 s have passed, got "..tostring(chatSent[2]))
	for _, bad in ipairs({ "say", "yell", "channel", "SAY", "YELL", "CHANNEL", "raid" }) do
		settings.announce = bad
		clock = clock + 60
		check(not Streaks:Announce("test") and #chatSent == 2, "never announced to "..bad)
	end
	local realInGroup = IsInGroup
	IsInGroup = function() return false end
	settings.announce = "party"
	clock = clock + 60
	check(not Streaks:Announce("test"), "no party line when not in a party")
	IsInGroup = realInGroup
	settings.announce = "guild"
	check(Streaks:Announce("test") and chatSent[#chatSent] == "GUILD: test", "a guild line when asked for and in a guild")
	-- Callout and sound can be turned off
	settings.announce = "none"
	settings.callout, settings.sound = false, false
	Streaks:OnDeath()
	calloutFrame:Hide()
	played = 0
	clock = clock + 100
	Streaks:OnKill("Quiet One")
	Streaks:OnKill("Quiet Two")
	check(Callout() == nil and played == 0, "no callout or sound when both are off")
	settings.callout, settings.sound = true, true
	PlaySoundFile = realPlay
	ns.UI:Show("settings")
end)()
;(function()
	-- Each alert kind's sound: Wanted's beep by default, none, a game sound, or a SharedMedia sound when another
	-- addon brought LibSharedMedia (and Wanted's beep again once that sound is gone)
	local Alerts = ns.Alerts
	local detect = ns.db.settings.detect
	local files, kits = {}, {}
	local realFile, realKit = PlaySoundFile, PlaySound
	PlaySoundFile = function(path) files[#files + 1] = path return true end
	PlaySound = function(kit) kits[#kits + 1] = kit end
	local function Reset() files, kits = {}, {} end
	for _, kind in ipairs({ "enemy", "important", "stealth", "targeted" }) do
		check(detect.sounds[kind] == "wanted", kind.." plays Wanted's beep by default")
	end
	Alerts:PlayRaw("important")
	check(#files == 1 and files[1]:find("important%.mp3$") and #kits == 0, "the default plays Wanted's own file")
	Reset()
	Alerts:SetSoundChoice("enemy", "none")
	Alerts:PlayRaw("enemy")
	clock = clock + 10
	Alerts:Sound("enemy")
	check(#files == 0 and #kits == 0, "a kind set to None plays nothing")
	Alerts:Sound("stealth")
	check(#files == 1 and files[1]:find("stealth%.mp3$"), "a silent kind doesn't hold back the next alert's sound")
	Reset()
	Alerts:SetSoundChoice("stealth", "kit:RAID_WARNING")
	Alerts:PlayRaw("stealth")
	check(#kits == 1 and kits[1] == SOUNDKIT.RAID_WARNING and #files == 0, "a game sound plays its sound kit")
	local offered = {}
	for _, entry in ipairs(Alerts:GetGameSounds()) do offered[entry[1]] = entry[2] end
	check(offered["kit:RAID_WARNING"] == "Raid warning" and not offered["kit:READY_CHECK"], "only the game sounds this client has are offered")
	check(Alerts:SoundLabel("kit:RAID_WARNING") == "Raid warning" and Alerts:SoundLabel("wanted", "enemy") == "One beep" and Alerts:SoundLabel("wanted", "stealth") == "Falling tone" and Alerts:SoundLabel("lsm:Gong") == "Gong", "choices have readable labels")
	Reset()
	Alerts:SetSoundChoice("targeted", "lsm:Gong")
	check(#Alerts:GetSharedMediaSounds() == 0, "no SharedMedia sounds without the library")
	Alerts:PlayRaw("targeted")
	check(#files == 1 and files[1]:find("targeted%.mp3$"), "a SharedMedia choice falls back to Wanted's beep without the library")
	Reset()
	local media = LibStub:NewLibrary("LibSharedMedia-3.0", 1)
	local registered = { None = "Interface\\Quiet.ogg", Gong = "Interface\\AddOns\\SharedMedia\\gong.ogg" }
	function media:List() local names = {} for name in pairs(registered) do names[#names + 1] = name end table.sort(names) return names end
	function media:Fetch(_, name) return registered[name] end
	local shared = Alerts:GetSharedMediaSounds()
	check(#shared == 1 and shared[1] == "Gong", "SharedMedia sounds are listed, without its own None")
	Alerts:PlayRaw("targeted")
	check(#files == 1 and files[1] == registered.Gong, "a SharedMedia choice plays its file")
	Reset()
	registered.Gong = nil
	Alerts:PlayRaw("targeted")
	check(#files == 1 and files[1]:find("targeted%.mp3$"), "a SharedMedia sound that's gone falls back to Wanted's beep")
	Reset()
	-- The master toggles still silence them
	Alerts:SetSoundChoice("important", "kit:RAID_WARNING")
	detect.sound = false
	clock = clock + 10
	Alerts:Sound("important")
	check(#files == 0 and #kits == 0, "Alert sounds off still silences a chosen sound")
	detect.sound = true
	ns.UI:Show("settings")
	for _, kind in ipairs({ "enemy", "important", "stealth", "targeted" }) do
		detect.sounds[kind] = "wanted"
	end
	PlaySoundFile, PlaySound = realFile, realKit
end)()
print("wanted smoke: all checks pass")
;(function()
	-- Underground, where no zone map reaches, the game places the player on the continent's map, where a tenth of
	-- a percent is about 35 yards: positions there keep a hundredth. On a zone's map a tenth, as before.
	local realBest, realPos, realInfo = C_Map.GetBestMapForUnit, C_Map.GetPlayerMapPosition, C_Map.GetMapInfo
	C_Map.GetPlayerMapPosition = function() return { x = 0.41123, y = 0.79268 } end
	C_Map.GetBestMapForUnit = function() return 1415 end
	C_Map.GetMapInfo = function() return { name = "Eastern Kingdoms", mapType = 2 } end
	clock = clock + 1 -- the position is read once a moment
	local _, x, y, mapId = ns.Recorder:GetPosition()
	check(x == 41.12 and y == 79.27 and mapId == 1415, "on a continent's map the position keeps a hundredth: "..tostring(x)..", "..tostring(y))
	C_Map.GetBestMapForUnit = function() return 1436 end
	C_Map.GetMapInfo = function() return { name = "Westfall", mapType = 3 } end
	_, x = ns.Recorder:GetPosition()
	check(x == 41.12, "within the same moment the position isn't read again")
	clock = clock + 1
	_, x, y = ns.Recorder:GetPosition()
	check(x == 41.1 and y == 79.3, "on a zone's map it keeps a tenth: "..tostring(x)..", "..tostring(y))
	C_Map.GetBestMapForUnit, C_Map.GetPlayerMapPosition, C_Map.GetMapInfo = realBest, realPos, realInfo
end)()
;(function()
	-- The game reads !!WantedLink only at login or /reload, so whether the app is running is judged at that moment:
	-- hours into a session, a running app mustn't look stopped
	local savedInfo, savedClock = WantedAppInfo, clock
	local loadedAt = 1790270000 -- the clock when the addon loaded
	WantedAppInfo = { running = "0.2.20", latest = "0.2.20", seen = loadedAt - 1800 }
	clock = loadedAt + 6 * 3600
	check(ns:AppNotRunningFor() == nil, "six hours after login, an app that had run half an hour before login still counts as running")
	WantedAppInfo.seen = loadedAt - 4 * 3600
	check(ns:AppNotRunningFor() == clock - WantedAppInfo.seen, "an app that last ran four hours before login isn't running")
	WantedAppInfo, clock = savedInfo, savedClock
end)()
;(function()
	-- Guild ranks, for guild mode on Discord: the character's own rank, and the roster's officers only
	local GuildRank = ns.GuildRank
	local real = { GetGuildInfo = GetGuildInfo, IsInGuild = IsInGuild, IsGuildLeader = IsGuildLeader, C_GuildInfo = C_GuildInfo, C_Club = C_Club, clock = clock }
	local me = UnitGUID("player")
	local guild = { name = "Blood Oath", rankName = "Grunt", rankIndex = 4, leader = false, officer = false, inGuild = true }
	local roster = {
		{ guid = "Player-1-GM", order = 1 },
		{ guid = me, order = 5 },
		{ guid = "Player-1-OFFICER", order = 2 },
		{ guid = "Player-1-MEMBER", order = 5 },
		{ guid = "Player-1-RECRUIT", order = 7 },
	}
	GetGuildInfo = function(unit) if unit == "player" and guild.inGuild then return guild.name, guild.rankName, guild.rankIndex end end
	IsInGuild = function() return guild.inGuild end
	IsGuildLeader = function() return guild.leader end
	C_GuildInfo = { IsGuildOfficer = function() return guild.officer end, GuildRoster = function() end }
	C_Club = {
		GetGuildClubId = function() return 77 end,
		GetClubMembers = function() local ids = {} for i = 1, #roster do ids[i] = i end return ids end,
		GetMemberInfo = function(_, id) local m = roster[id] return { guid = m.guid, guildRankOrder = m.order, name = "x" } end,
	}
	local ranks, officers = ns.db.guildRanks, ns.db.guildOfficers

	-- A plain member: noted as no officer, and the roster keeps only the guild master
	GuildRank:NoteOwn()
	local own = ranks[me]
	check(own and own.g == "Blood Oath" and own.rn == "Grunt" and own.ri == 4 and own.o == false, "a plain member's own rank is noted, not an officer")
	GuildRank:ReadRoster()
	local book = officers["Blood Oath"]
	check(book and book.m["Player-1-GM"] == 0, "the guild master is kept")
	check(book.m[me] == nil and book.m["Player-1-MEMBER"] == nil and book.m["Player-1-RECRUIT"] == nil and book.m["Player-1-OFFICER"] == nil,
		"a plain member's roster keeps no plain members, nor ranks it can't tell are officers'")

	-- Promoted: an officer, whose rank marks the officers
	guild.rankName, guild.rankIndex, guild.officer = "Officer", 1, true
	roster[2].order = 2
	GuildRank:NoteOwn()
	check(ranks[me].o == true and ranks[me].ri == 1, "a promotion is noted")
	GuildRank:ReadRoster()
	check(officers["Blood Oath"].m["Player-1-OFFICER"] == nil, "the roster isn't read again within ten minutes")
	clock = clock + GuildRank.ROSTER_SECONDS
	GuildRank:ReadRoster()
	book = officers["Blood Oath"].m
	check(book["Player-1-OFFICER"] == 1 and book[me] == 1 and book["Player-1-GM"] == 0, "an officer's roster keeps the officers at its rank")
	check(book["Player-1-MEMBER"] == nil and book["Player-1-RECRUIT"] == nil, "plain members are never kept")

	-- Unchanged: not noted again
	local t = ranks[me].t
	clock = clock + 60
	GuildRank:NoteOwn()
	check(ranks[me].t == t, "an unchanged rank isn't noted again")

	-- A secret value: nothing noted
	local realSecret = issecretvalue
	issecretvalue = function(v) return v == "Officer" end
	guild.rankIndex = 2
	GuildRank:NoteOwn()
	check(ranks[me].ri == 1, "a rank the game keeps secret isn't noted")
	issecretvalue = function(v) return v == true end
	GuildRank:NoteOwn()
	check(ranks[me].ri == 1, "a secret officer flag isn't noted")
	issecretvalue = realSecret

	-- The guild not loaded yet at login: nothing noted; out of a guild: noted as none
	guild.name = nil
	GuildRank:NoteOwn()
	check(ranks[me].g == "Blood Oath", "a guild the game hasn't loaded yet isn't taken for leaving it")
	guild.inGuild = false
	GuildRank:NoteOwn()
	check(ranks[me].g == "" and ranks[me].o == false and ranks[me].ri == -1, "leaving the guild is noted as no guild")
	clock = clock + GuildRank.ROSTER_SECONDS
	officers["Blood Oath"].t = clock - 1
	GuildRank:ReadRoster()
	check(officers["Blood Oath"].t == clock - 1, "out of a guild, no roster is read")

	-- Old officer books go
	officers["Old Guild"] = { t = clock - GuildRank.KEEP_SECONDS - 1, m = { ["Player-1-X"] = 0 } }
	GuildRank:OnLoad()
	check(officers["Old Guild"] == nil and officers["Blood Oath"] ~= nil, "an officers book not read for a month goes")

	GetGuildInfo, IsInGuild, IsGuildLeader, C_GuildInfo, C_Club, clock = real.GetGuildInfo, real.IsInGuild, real.IsGuildLeader, real.C_GuildInfo, real.C_Club, real.clock
	ranks[me] = nil
	officers["Blood Oath"] = nil
end)()
;(function()
	-- Bounties asked for from Discord: the app hands on the requests for this account's characters in its catch-up;
	-- each is asked once, on its own character, out of combat and instances, and the answer goes back through the app
	local db = ns.db
	local realShown = ns.Widgets.IsDialogShown
	ns.Widgets.IsDialogShown = function() return false end
	lastDialog = nil
	ns.Store:UpdatePlayer("Player-2-SAME", { name = "Same Side", faction = "Horde" }, false)
	local n = 0
	local function Req(id, extra)
		n = n + 1
		local r = { id = id, character = "Player-1-ME", target = "Player-2-AAAA", targetName = "Grim Tooth", amount = 50000, t = clock - 100 + n, expires = clock + 3600 }
		for k, v in pairs(extra or {}) do r[k] = v end
		if r.target == false then r.target = nil end
		return r
	end
	local function Offer(requests) WantedAppCatchup = { [db.accountMark] = { t = db.catchupT or 0, requests = requests } } ns.Catchup:Import() end
	Offer({
		Req("r1"),
		Req("r2", { target = "Player-2-SAME", targetName = "Same Side" }),
		Req("g1", { target = false, guild = "Dawnguard", targetName = "<Dawnguard>", amount = 20000 }),
		Req("r10"),
		Req("r3", { character = "Player-1-ALT" }),
		Req("r4", { expires = clock - 1 }),
		Req("bad id!"), Req("r6", { amount = 5 }), Req("r7", { amount = 1.5 }), Req("r8", { target = "nope" }), Req("r9", { targetName = 42 }),
		Req("r5", { character = "not a guid" }), Req("r11", { amount = 2000000000 }), "not a table",
	})
	for _, id in ipairs({ "r1", "r2", "g1", "r10", "r3" }) do
		check(db.bountyRequests[id], "request "..id.." is kept")
	end
	for _, id in ipairs({ "r4", "bad id!", "r6", "r7", "r8", "r9", "r5", "r11" }) do
		check(db.bountyRequests[id] == nil, "request "..id.." is dropped")
	end
	check(db.bountyRequests.g1.target == nil and db.bountyRequests.g1.guild == "Dawnguard", "a guild request has a guild, not a target")

	-- Asked a moment after login, oldest first: posted as the normal path posts it
	RunTimers()
	check(lastDialog and lastDialog.text:find("You asked from Discord to post 5g on Grim Tooth.", 1, true), "the first request is asked, got "..tostring(lastDialog and lastDialog.text))
	ConfirmDialog()
	local posted
	for r in ns.Store:Iterator("bounty") do if r.data.target == "Player-2-AAAA" and r.data.amount == 50000 then posted = r end end
	check(posted and posted.origin == ns.Store:GetOrigin(), "Post it makes the bounty record")
	check(db.requestAnswers.r1 and db.requestAnswers.r1.state == "posted" and db.bountyRequests.r1 == nil, "and answers posted")
	-- The addon refuses: its reason goes back
	RunTimers()
	check(lastDialog and lastDialog.text:find("Same Side", 1, true), "the next one is asked")
	ConfirmDialog()
	check(db.requestAnswers.r2.state == "refused" and db.requestAnswers.r2.reason == "bounties are for the other faction only", "a refusal keeps the addon's reason, got "..tostring(db.requestAnswers.r2.reason))
	-- Discard
	RunTimers()
	check(lastDialog and lastDialog.text:find("<Dawnguard>", 1, true), "the guild request is asked")
	local options = lastDialog
	lastDialog = nil
	options.onCancel()
	check(db.requestAnswers.g1.state == "discarded" and db.bountyRequests.g1 == nil, "Discard answers discarded")
	-- Already open on that target
	RunTimers()
	ConfirmDialog()
	check(db.requestAnswers.r10.state == "refused" and db.requestAnswers.r10.reason:find("already have a bounty", 1, true), "a second bounty on the same target is refused")
	-- Another character's request is never shown here
	RunTimers()
	check(lastDialog == nil, "another character's request isn't asked, got "..tostring(lastDialog and lastDialog.text))
	check(db.bountyRequests.r3 and not db.requestAnswers.r3, "and it stays for that character")

	-- Never asked twice: the same requests again change nothing
	Offer({ Req("r1"), Req("r2"), Req("g1", { target = false, guild = "Dawnguard", targetName = "<Dawnguard>" }) })
	RunTimers()
	check(lastDialog == nil and db.bountyRequests.r1 == nil, "an answered request isn't asked again")

	-- Not in a fight, an instance, or while the update lock holds: kept, unanswered, asked later
	Fire("PLAYER_REGEN_DISABLED")
	Offer({ Req("c1", { target = "Player-2-CCCC", targetName = "Cee Cee" }) })
	RunTimers()
	check(lastDialog == nil, "not asked in a fight")
	Fire("PLAYER_REGEN_ENABLED")
	RunTimers()
	check(lastDialog and lastDialog.text:find("Cee Cee", 1, true), "asked once the fight is over")
	lastDialog.onCancel()
	lastDialog = nil
	local outside = IsInInstance
	IsInInstance = function() return true, "party" end
	Offer({ Req("i1", { target = "Player-2-DDDD", targetName = "Dee Dee" }) })
	RunTimers()
	check(lastDialog == nil, "not asked in an instance")
	IsInInstance = outside
	db.requiredVersion = { version = "9.9.9", t = clock }
	Fire("PLAYER_ENTERING_WORLD")
	RunTimers()
	check(lastDialog == nil and db.bountyRequests.i1 and not db.requestAnswers.i1, "not asked while an update is required, and not answered")
	db.requiredVersion = nil
	Fire("PLAYER_ENTERING_WORLD")
	RunTimers()
	check(lastDialog and lastDialog.text:find("Dee Dee", 1, true), "asked once out of the instance and updated")
	lastDialog.onCancel()
	lastDialog = nil

	-- Answers and leftover requests go after a week; an expired request goes without an answer
	db.requestAnswers.old = { state = "posted", t = clock - 8 * 24 * 3600 }
	db.bountyRequests.r3.expires = clock - 1
	Offer({})
	check(db.requestAnswers.old == nil and db.requestAnswers.r1, "week-old answers go, newer ones stay")
	check(db.bountyRequests.r3 == nil and db.requestAnswers.r3 == nil, "an expired request is dropped silently")
	ns.Widgets.IsDialogShown = realShown
end)()
;(function()
	-- Battlegrounds: the game blocks addon messages and hides chat text in a PvP match, and every enemy there is
	-- new. Nothing is sent, tracked or alerted inside one; what was waiting goes once outside.
	local outside = IsInInstance
	ns.db.requiredVersion, ns.newerVersion = nil, nil
	clock = clock + 61
	RunTimers()
	addonSent = {}
	IsInInstance = function() return true, "pvp" end
	Fire("PLAYER_ENTERING_WORLD")
	check(ns:InPvPMatch(), "a battleground is a PvP match")
	SlashCmdList.WANTED("synctest")
	RunTimers()
	check(#addonSent == 0, "nothing is sent inside a battleground, got "..#addonSent)
	-- Text the game hides from addons during a match is never read
	Fire("CHAT_MSG_SYSTEM", SECRET_SPELL)
	Fire("CHAT_MSG_CHANNEL_NOTICE", SECRET_SPELL, SECRET_SPELL, "", "", SECRET_SPELL, "", 0, 0, SECRET_SPELL)
	Fire("CHAT_MSG_ADDON", "WNTD", SECRET_SPELL, "CHANNEL", SECRET_SPELL, nil, nil, nil, "WantedNetHorde")
	-- An enemy in the battleground isn't listed, counted, sighted or alerted on
	local alerts = 0
	ns.Enemies:OnChange(function(event) if event == "new" then alerts = alerts + 1 end end)
	enemyUnits.nameplate5 = { guid = "Player-9-BGFOE", name = "Bg Foe", class = "WARRIOR", level = 20 }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate5")
	check(not ns.Enemies:ShouldAlert(), "no alerts in a battleground")
	check(alerts == 0 and not ns.Enemies:GetStats("Player-9-BGFOE"), "an enemy in a battleground isn't counted or alerted on")
	check(not ns.db.players["Player-9-BGFOE"], "nor saved as a sighting")
	Fire("NAME_PLATE_UNIT_REMOVED", "nameplate5")
	enemyUnits.nameplate5 = nil
	-- Back outside, the waiting hello goes
	IsInInstance = outside
	Fire("PLAYER_ENTERING_WORLD")
	RunTimers()
	check(#addonSent >= 1 and addonSent[1].text:find("^H:"), "the hello goes once out of the battleground, got "..#addonSent)
	-- A send the game refuses in lockdown isn't counted as sent: it waits and goes again
	addonSent = {}
	clock = clock + 61
	lockdownNext = 1
	SlashCmdList.WANTED("synctest")
	RunTimers()
	check(lockdownNext == 0, "the lockdown refusal was hit")
	clock = clock + 61
	RunTimers()
	check(#addonSent >= 1 and addonSent[1].text:find("^H:"), "a part refused in lockdown is sent again later, got "..#addonSent)
end)()

-- Auto-claims: a kill of a known bounty's target claims it on the spot, and a bounty learned of after the kill
-- is claimed late; either way a banner, the important sound and a chat line say so
;(function()
	local me = ns.Store:GetOrigin()
	local warns, sounds = {}, {}
	local origWarn, origSound = ns.Alerts.Warn, ns.Alerts.Sound
	ns.Alerts.Warn = function(self, title, sub, color) warns[#warns + 1] = title.." / "..tostring(sub) return origWarn(self, title, sub, color) end
	ns.Alerts.Sound = function(self, kind) sounds[#sounds + 1] = kind return origSound(self, kind) end
	local function Relay(origin, seq, kind, data, t)
		local before = ns.Store:Get(origin..":"..(seq - 1))
		ns.Store:MergeRelayed(Sealed({ kind = kind, id = origin..":"..seq, origin = origin, seq = seq, prev = before and before.hash or "0", t = t, data = data }))
		return ns.Store:Get(origin..":"..seq)
	end
	local function Kill(guid, name, guild)
		return ns.Store:NewRecord("kill", { killer = "Player-1-ME", killerName = me, victim = guid, victimName = name, victimGuild = guild, deathId = "late-"..guid..clock, zone = "Durotar", honor = true })
	end
	local function MyClaims(bounty)
		local list = {}
		for claim in ns.Store:Iterator("claim") do
			if claim.data.bounty == bounty.id and claim.origin == me then list[#list + 1] = claim end
		end
		return list
	end
	local function Printed(text)
		for i = #printed, math.max(1, #printed - 5), -1 do if printed[i]:find(text, 1, true) then return true end end
	end
	-- On the spot
	local spot = Relay("Spot Poster", 1, "bounty", { target = "Player-9-SPOT", targetName = "Spot Target", amount = 5000 }, clock - 60)
	RunTimers()
	check(#MyClaims(spot) == 0 and #warns == 0, "a bounty with no kill of ours isn't claimed")
	Kill("Player-9-SPOT", "Spot Target")
	check(#MyClaims(spot) == 1, "a kill of a known bounty's target claims it")
	check(warns[#warns] == "BOUNTY COLLECTED / You killed Spot Target, wanted for 50s by Spot Poster. Claim filed.", "the on-the-spot banner: "..tostring(warns[#warns]))
	check(sounds[#sounds] == "important", "with the important sound")
	check(Printed("Bounty collected: you killed Spot Target, wanted for 50s by Spot Poster. Claim filed."), "and a chat line")
	RunTimers()
	-- Late: the latest of two kills made while the bounty was open
	local killT = clock
	Kill("Player-9-LATE", "Late Target")
	clock = clock + 20
	local latest = Kill("Player-9-LATE", "Late Target")
	clock = clock + 100
	local late = Relay("Late Poster", 1, "bounty", { target = "Player-9-LATE", targetName = "Late Target", amount = 3000 }, killT - 50)
	check(#MyClaims(late) == 0, "a late claim waits for the records arriving with the bounty")
	local warnsBefore = #warns
	RunTimers()
	local claims = MyClaims(late)
	check(#claims == 1 and claims[1].data.kill == latest.id and claims[1].data.killT == latest.t and claims[1].data.deathId == latest.data.deathId, "a bounty learned of after a kill is claimed with the latest kill")
	check(warns[#warns] == "BOUNTY COLLECTED / You killed Late Target earlier, and there was a 30s bounty on them. Claim filed.", "the late banner: "..tostring(warns[#warns]))
	check(Printed("You killed Late Target earlier, and there was a 30s bounty on them. Claim filed."), "and its chat line")
	check(ns.Proof:Get(claims[1].id) == nil, "a late claim takes no screenshot")
	-- A raise on it later doesn't claim it twice
	warnsBefore = #warns
	Relay("Late Poster", 2, "raise", { bounty = late.id, amount = 1000 }, clock)
	RunTimers()
	check(#MyClaims(late) == 1 and #warns == warnsBefore, "no second claim on the same bounty")
	-- A kill before the bounty was posted, after it expired, or after it was withdrawn doesn't count
	local early = Relay("Early Poster", 1, "bounty", { target = "Player-9-LATE", targetName = "Late Target", amount = 3000 }, clock - 10)
	local expired = Relay("Old Poster", 1, "bounty", { target = "Player-9-LATE", targetName = "Late Target", amount = 3000 }, killT - 8 * 86400)
	local withdrawn = Relay("Gone Poster", 1, "bounty", { target = "Player-9-LATE", targetName = "Late Target", amount = 3000 }, killT - 100)
	Relay("Gone Poster", 2, "withdraw", { bounty = withdrawn.id }, killT - 50)
	RunTimers()
	check(#MyClaims(early) == 0, "a kill before the bounty was posted doesn't claim it")
	check(#MyClaims(expired) == 0, "a kill after the bounty expired doesn't claim it")
	check(#MyClaims(withdrawn) == 0, "a kill after the bounty was withdrawn doesn't claim it")
	-- A raise this client hadn't heard of kept the expired one open at the kill
	Relay("Old Poster", 2, "raise", { bounty = expired.id, amount = 1000 }, killT - 2 * 86400)
	RunTimers()
	check(#MyClaims(expired) == 1, "a raise that kept the bounty open at the kill claims it late")
	-- Your own bounty is never claimed
	local own = ns.Bounties:Post("Player-9-LATE", "Late Target", 2000)
	RunTimers()
	check(own and #MyClaims(own) == 0, "your own bounty is never claimed")
	-- A guild bounty is claimed by a kill of a member
	Kill("Player-9-GMEMBER", "Guild Member", "Late Guild")
	clock = clock + 60
	local guildLate = Relay("Guild Poster", 1, "bounty", { guild = "Late Guild", targetName = "<Late Guild>", amount = 4000 }, clock - 120)
	RunTimers()
	check(#MyClaims(guildLate) == 1, "a guild bounty learned of after a member's kill is claimed")
	ns.Alerts.Warn, ns.Alerts.Sound = origWarn, origSound
end)()
;(function()
	-- The Wanted Battle.net community: its online members in WoW Forever on this ruleset and the other faction are
	-- bridges alongside friends; nobody else, and nobody while it isn't set up or we're not in it. A bridge that comes
	-- back is pushed the current notices once; long messages go in parts and come back whole; parts that stop
	-- coming are dropped
	local function SentTo(id, prefix)
		local out = {}
		for _, m in ipairs(bnSent) do
			if m.id == id and (not prefix or m.prefix == prefix) then out[#out + 1] = m end
		end
		return out
	end
	local function Tags(list)
		local tags = {}
		for _, m in ipairs(list) do local tbl = m.prefix == "WNTDB" and ns.Sync:Decode(m.data) tags[#tags + 1] = tbl and tbl.k or m.prefix end
		return table.concat(tags, ",")
	end
	local function Drain() for _ = 1, 20 do RunTimers() end end
	local function Rescan(event, ...) clock = clock + 31 Fire(event, ...) Drain() end
	local function Notices() local n = 0 for _ in ns.Store:Iterator("notice") do n = n + 1 end return n end
	clubSubscribed, clubMembers = {}, {}
	C_Club = {
		GetSubscribedClubs = function() return clubSubscribed end,
		GetClubMembers = function() local ids = {} for _, m in ipairs(clubMembers) do ids[#ids + 1] = m.memberId end return ids end,
		GetMemberInfo = function(_, id)
			for _, m in ipairs(clubMembers) do
				if m.memberId == id then return { isSelf = m.isSelf or false, memberId = id, presence = m.presence, bnetAccountId = m.bnet, faction = m.faction } end
			end
		end,
		FocusMembers = function() end,
	}
	clubMembers = {
		{ memberId = 1, bnet = 201, presence = 1 },
		{ memberId = 2, bnet = 202, presence = 1 },
		{ memberId = 3, bnet = 203, presence = 4 },
		{ memberId = 4, bnet = 204, presence = 1 },
		{ memberId = 5, bnet = 205, presence = 3 },
		{ memberId = 6, bnet = 206, presence = 1, isSelf = true },
	}
	bnAccounts[201] = { id = 301, program = "WoW", faction = "Alliance", realm = "Realm", name = "Club Ally" }
	bnAccounts[202] = { id = 302, program = "WoW", faction = "Horde", realm = "Realm", name = "Club Horde" }
	bnAccounts[203] = { id = 303, program = "WoW", faction = "Alliance", realm = "Realm", name = "Club Retail", project = 2 }
	bnAccounts[205] = { id = 305, program = "WoW", faction = "Alliance", realm = "Realm", name = "Club Offline" }
	bnAccounts[206] = { id = 306, program = "WoW", faction = "Alliance", realm = "Realm", name = "Club Me" }
	-- 204 isn't a friend and Battle.net doesn't show their game
	bnFriends[#bnFriends + 1] = { id = 106, program = "WoW", faction = "Alliance", realm = "Realm", name = "Retail Ally", project = 2 }
	ns.db.settings.bridge = true
	local wantedClub = ns.Bridge.clubId
	check(tostring(wantedClub) == "23053871", "the Wanted community is set up")
	-- Settings shows its invite link in a copy box
	ns.UI:Show("settings")
	local inviteBox
	for _, f in ipairs(Mock.created) do
		if f._text == "https://blizzard.com/invite/7mmzbzC47G" then inviteBox = f end
	end
	check(inviteBox and inviteBox._scripts.OnEditFocusGained, "Settings has the community's invite link in a copy box")
	ns.Bridge.clubId = 0
	bnSent = {}
	Rescan("BN_FRIEND_INFO_CHANGED")
	check(#SentTo(301) == 0, "no community while it isn't set up")
	check(#SentTo(106) == 0, "a friend in another game version on the other faction is no bridge")
	ns.Bridge.clubId = "77"
	Rescan("CLUB_MEMBER_PRESENCE_UPDATED", "77", 1, 1)
	check(#SentTo(301) == 0, "no community bridges when we're not in it")
	local outside = table.concat(ns.Bridge:CommunityReport(), "\n")
	check(outside:find("not in the Wanted community", 1, true) and outside:find("https://blizzard.com/invite/7mmzbzC47G", 1, true), "/wanted community gives the invite link to a player not in it: "..outside)
	clubSubscribed = { { clubId = "77", name = "Wanted", clubType = 0, memberCount = 6 } }
	Rescan("CLUB_MEMBER_PRESENCE_UPDATED", "88", 1, 1)
	check(#SentTo(301) == 0, "another community's events don't rescan")
	Rescan("CLUB_MEMBER_PRESENCE_UPDATED", "77", 1, 1)
	local hello = SentTo(301)
	check(#hello == 1 and Tags(hello) == "H" and ns.Sync:Decode(hello[1].data).f == 1, "a community member online on the other faction is greeted, saying we read parts: "..Tags(hello))
	for _, id in ipairs({ 302, 303, 304, 305, 306 }) do
		check(#SentTo(id) == 0, "not greeted: same faction, another game version, not shown, offline or ourselves ("..id..")")
	end
	local report = table.concat(ns.Bridge:CommunityReport(), "\n")
	check(report:find("id 77, Battle.net community") and report:find("1 bridges, 1 whose game Battle.net doesn't show"), "/wanted community lists the communities and what it saw: "..report)
	-- Their answer makes them a bridge and they're sent the backlog
	bnSent = {}
	Fire("BN_CHAT_MSG_ADDON", "WNTDB", ns.Sync:Encode({ k = "A", v = "0.1.0", f = 1 }), "WHISPER", 301)
	Drain()
	check(Tags(SentTo(301)):find("^N"), "a community bridge gets the recent notices: "..Tags(SentTo(301)))
	-- Logged off: nothing goes to them meanwhile
	clubMembers[1].presence = 3
	Rescan("CLUB_MEMBER_PRESENCE_UPDATED", "77", 1, 3)
	bnSent = {}
	math.randomseed(7)
	local function Noise(n) local t = {} for i = 1, n do t[i] = string.char(math.random(33, 126)) end return table.concat(t) end
	for i = 1, 50 do
		ns.Store:NewRecord("bounty", { target = "Player-9-"..Noise(55), targetName = Noise(48), amount = 1000 + i })
	end
	Drain()
	check(#SentTo(301) == 0, "a bridge that logged off is sent nothing")
	-- Back: pushed the notices it missed at once, in parts (they don't fit one piece of game data)
	clubMembers[1].presence = 1
	Rescan("CLUB_MEMBER_PRESENCE_UPDATED", "77", 1, 1)
	local parts = SentTo(301, "WNTDP")
	check(#parts >= 2 and #parts <= 8, "the backlog goes in parts, got "..#parts)
	for _, part in ipairs(parts) do
		check(#part.data <= 3800 and part.data:match("^%w+:%d+/"..#parts..":"), "each part fits and says where it belongs")
	end
	check(ns.Bridge:Status():find("1 pushed on return"), "the push is counted: "..ns.Bridge:Status())
	-- The parts come back together: the 50 notices are read whole
	local before = Notices()
	for i = #parts, 1, -1 do
		Fire("BN_CHAT_MSG_ADDON", "WNTDP", parts[i].data, "WHISPER", 101)
	end
	Drain()
	check(Notices() == before + 50, "parts in any order make the whole message, got "..(Notices() - before))
	-- Gone and back again soon: greeted, not pushed again; what it missed goes once it answers
	clubMembers[1].presence = 3
	Rescan("CLUB_MEMBER_PRESENCE_UPDATED", "77", 1, 3)
	ns.Store:NewRecord("bounty", { target = "Player-9-MISSED", targetName = "Missed Twice", amount = 4000 })
	Drain()
	bnSent = {}
	clubMembers[1].presence = 1
	Rescan("CLUB_MEMBER_PRESENCE_UPDATED", "77", 1, 1)
	check(Tags(SentTo(301)) == "H", "a second return within minutes is only greeted: "..Tags(SentTo(301)))
	Fire("BN_CHAT_MSG_ADDON", "WNTDB", ns.Sync:Encode({ k = "A", v = "0.1.0", f = 1 }), "WHISPER", 301)
	Drain()
	local missed = SentTo(301)
	check(Tags(missed) == "H,N" and #ns.Sync:Decode(missed[2].data).n == 1, "its answer brings only what it missed: "..Tags(missed))
	-- Parts that stop coming are dropped, and a message claiming too many parts is refused
	before = Notices()
	local whole = ns.Sync:Encode({ k = "N", n = { { b = "Horde Poster:50", g = "Player-1-ME", n = "Test Player", a = 7000, p = "abcd1234", t = clock } } })
	local half = math.floor(#whole / 2)
	Fire("BN_CHAT_MSG_ADDON", "WNTDP", "zz:1/2:"..whole:sub(1, half), "WHISPER", 101)
	clock = clock + 31
	Fire("BN_CHAT_MSG_ADDON", "WNTDP", "zz:2/2:"..whole:sub(half + 1), "WHISPER", 101)
	check(Notices() == before and ns.Bridge:Status():find("1 expired"), "a part arriving after the rest timed out completes nothing: "..ns.Bridge:Status())
	Fire("BN_CHAT_MSG_ADDON", "WNTDP", "yy:1/9:"..whole, "WHISPER", 101)
	Fire("BN_CHAT_MSG_ADDON", "WNTDP", "yy:9/9:x", "WHISPER", 101)
	check(Notices() == before, "a message in more parts than allowed is refused")
	Fire("BN_CHAT_MSG_ADDON", "WNTDP", "xx:1/2:"..whole:sub(1, half), "WHISPER", 102)
	Fire("BN_CHAT_MSG_ADDON", "WNTDP", "xx:2/2:"..whole:sub(half + 1), "WHISPER", 102)
	check(Notices() == before, "parts from our own faction are refused like whole messages")
	Fire("BN_CHAT_MSG_ADDON", "WNTDP", "ww:2/2:"..whole:sub(half + 1), "WHISPER", 101)
	Fire("BN_CHAT_MSG_ADDON", "WNTDP", "ww:1/2:"..whole:sub(1, half), "WHISPER", 101)
	check(Notices() == before + 1, "and in time they make the message")
	-- One sender gets a limited number of messages a minute
	clock = (math.floor(clock / 60) + 1) * 60
	bnSent = {}
	for _ = 1, 35 do
		Fire("BN_CHAT_MSG_ADDON", "WNTDB", ns.Sync:Encode({ k = "H", v = "0.1.0", f = 1 }), "WHISPER", 101)
	end
	Drain()
	check(#SentTo(101) == 30, "only 30 messages a minute are taken from one sender, got "..#SentTo(101))
	ns.Bridge.clubId = wantedClub
	bnFriends[#bnFriends] = nil
	C_Club = nil
end)()
;(function()
	-- Challenges from the app's catch-up (Challenges.lua): read field by field, missing or partial data never an error
	local Challenges = ns.Challenges
	local db = ns.db
	local function Sample(over)
		local c = {
			t = clock - 60, day = "2026-10-02", dayEnds = clock + 3600, weekEnds = clock + 3 * 86400,
			hot = { { zone = "Ashenvale", band = "16-30" }, { zone = "The Barrens", band = "10-25" } },
			daily = { id = "d:1", name = "Ambush", text = "4 killing blows in a hot zone", target = 4, points = 5 },
			weekly = {
				{ id = "w:1", name = "Hold the line", text = "Win 2 rounds", target = 2, points = 10, hot = false },
				{ id = "w:2", name = "Headhunter", text = "Collect any bounty", target = 1, points = 10 },
				{ id = "w:3", name = "Road warrior", text = "10 killing blows in Ashenvale", target = 10, points = 10, hot = true },
			},
			allThreeBonus = 15,
			me = { ["Player-1-ME"] = { daily = { n = 2, done = false }, weekly = { { n = 1 }, { n = 1, done = true }, { n = 4 } },
				streak = 4, rank = 4, points = 302, nextAt = 480, recent = { { name = "Headhunter", points = 10, at = clock - 86400 } } } },
			ranks = { ["khal drogash"] = { r = 4, f = "H" }, ["Thane Oakcrest"] = { r = 7, f = "A" } },
		}
		for k, v in pairs(over or {}) do c[k] = v end
		return c
	end
	check(Challenges:Clean(nil) == nil and Challenges:Clean({}) == nil and Challenges:Clean("x") == nil, "no challenges, or no time: nothing")
	local clean = Challenges:Clean(Sample())
	check(clean and #clean.hot == 2 and clean.daily.name == "Ambush" and #clean.weekly == 3 and clean.weekly[3].hot, "a whole catch-up reads")
	check(clean.me["Player-1-ME"].rank == 4 and clean.me["Player-1-ME"].weekly[2].done and not clean.me["Player-1-ME"].weekly[1].done, "progress reads")
	local partial = Challenges:Clean({ t = clock, hot = "no", daily = { name = "No id" }, weekly = { { id = "w", name = "Only", target = 1 }, 5 },
		me = { ["not a guid"] = {}, ["Player-1-ME"] = { rank = 99, streak = -1, points = "lots", weekly = "x", recent = { { name = "|cffff0000Red|r", at = clock } } } },
		ranks = { ["a"] = { r = 15, f = "H" }, ["b"] = { r = 3, f = "X" }, ["c|r"] = { r = 3, f = "H" }, ["ok"] = { r = 2, f = "A" } } })
	local me = partial.me["Player-1-ME"]
	check(partial and #partial.hot == 0 and partial.daily == nil and #partial.weekly == 1, "malformed parts are left out, the rest kept")
	check(me and me.rank == 0 and me.streak == 0 and me.points == 0 and #me.weekly == 3 and me.recent[1].name == "cffff0000Redr", "bad numbers fall back and escape codes are dropped")
	check(partial.ranks.a == nil and partial.ranks.b == nil and partial.ranks["c|r"] == nil and partial.ranks.ok.r == 2, "only well-formed ranks are kept")
	local many = {}
	for i = 1, 6000 do many["p"..i] = { r = 1, f = "H" } end
	local count = 0
	for _ in pairs(Challenges:Clean({ t = clock, ranks = many }).ranks) do count = count + 1 end
	check(count == 5000, "ranks are capped at 5000, got "..count)

	-- Read at every login, even from a catch-up already taken in; none from the app: the empty state
	local warned = {}
	local origWarn = ns.Alerts.Warn
	ns.Alerts.Warn = function(_, title, sub) warned[#warned + 1] = title.." / "..tostring(sub) end
	db.challengeNotes = {}
	WantedAppCatchup = { [db.accountMark] = { t = 1, records = {}, challenges = Sample() } }
	ns.Catchup:Import()
	RunTimers()
	check(Challenges:Get() and Challenges:GetMine().points == 302, "challenges are read from a catch-up already taken in")
	check(#warned == 0 and db.challengeNotes["Player-1-ME"].done["w:2"], "the first catch-up only notes what's already done")
	check(Challenges:GetRank("Khal Drogash") and Challenges:GetRank("Khal Drogash-Realm").r == 4 and Challenges:GetRank("thane oakcrest").f == "A", "ranks are found by name, any case, realm or not")
	check(Challenges:GetRank("Nobody") == nil and Challenges:GetRank(nil) == nil, "no rank for players not listed")
	check(Challenges:Title(4, "H") == "Senior Sergeant" and Challenges:Title(4, "A") == "Master Sergeant" and Challenges:Title(14, "Alliance") == "Grand Marshal", "rank titles by side")
	check(Challenges:Badge(4) == "Interface\\PvPRankBadges\\PvPRank04" and Challenges:Badge(0) == nil and Challenges:Badge(15) == nil, "badges for ranks 1 to 14")
	check(Challenges:GetHot("ashenvale") and not Challenges:GetHot("Durotar"), "hot zones by name, any case")
	local done, total = Challenges:CountDone()
	check(done == 1 and total == 4, "1 of 4 done, got "..tostring(done).."/"..tostring(total))
	for _, key in ipairs({ "home", "challenges", "hotspots" }) do
		ns.UI:Show(key)
	end
	ns.UI:Refresh(true)
	local function Shown(text)
		local shown = nil
		for _, f in ipairs(Mock.fontStrings) do
			if f._text == text then
				shown = shown or false
				-- On screen: it and every frame it sits in are shown
				local on, p = f._shown, f._parent
				while on and p do on, p = p._shown, p._parent end
				if on then shown = true end
			end
		end
		return shown
	end
	check(Shown("1/4"), "the Challenges menu item shows 1/4 done")
	check(not Shown("Get the Wanted app to track challenges and ranks") and not Shown("Update the Wanted app to track challenges and ranks"), "the empty state is hidden with challenges")

	-- A later catch-up: the daily done and a rank up are announced once
	local later = Sample({ t = clock })
	later.me["Player-1-ME"].daily = { n = 4, done = true }
	later.me["Player-1-ME"].rank = 5
	WantedAppCatchup = { [db.accountMark] = { t = 1, records = {}, challenges = later } }
	ns.Catchup:Import()
	RunTimers()
	check(#warned == 1 and warned[1]:find("RANK UP: FIRST SERGEANT", 1, true) and warned[1]:find("Ambush (+5)", 1, true), "a rank up and the daily done: one banner, got "..tostring(warned[1]))
	WantedAppCatchup = { [db.accountMark] = { t = 1, records = {}, challenges = later } }
	ns.Catchup:Import()
	RunTimers()
	check(#warned == 1, "the same completion is never announced again")
	later.me["Player-1-ME"].weekly[3] = { n = 10, done = true }
	WantedAppCatchup = { [db.accountMark] = { t = 1, records = {}, challenges = later } }
	ns.Catchup:Import()
	RunTimers()
	check(#warned == 2 and warned[2]:find("CHALLENGE DONE / Road warrior (+10)", 1, true), "a weekly done: its banner, got "..tostring(warned[2]))

	-- The day ends: no hot zones until the app brings the next ones
	clock = clock + 7200
	check(Challenges:IsDayOver() and not Challenges:GetHot("Ashenvale"), "yesterday's hot zones aren't hot")
	ns.UI:Show("home")
	ns.UI:Show("challenges")

	-- No challenges in the catch-up: the empty state, and the strip still shows
	WantedAppCatchup = { [db.accountMark] = { t = 1, records = {} } }
	ns.Catchup:Import()
	check(Challenges:Get() == nil and Challenges:CountDone() == nil, "no challenges without the app's")
	ns.UI:Show("home")
	ns.UI:Show("challenges")
	check(Shown("Update the Wanted app to track challenges and ranks") and Shown("Already updated it? Type /reload to load your challenges. Otherwise open the app and it updates itself, or download 0.2.27 from wanteddeadordead.com/app.")
		and not Shown("Get the Wanted app to track challenges and ranks"), "an app catch-up without challenges: update the app")
	ns.UI:Show("home")
	check(Shown("Update the Wanted app to track challenges and ranks") and Shown("Update the app"), "Home says update the app too")
	-- No catch-up for this account and no app version: get the app, on both pages
	local appInfo = WantedAppInfo
	WantedAppInfo = nil
	WantedAppCatchup = nil
	ns.Catchup:Import()
	ns.UI:Refresh()
	check(Shown("Get the Wanted app to track challenges and ranks") and Shown("Get the app") and not Shown("Update the Wanted app to track challenges and ranks"), "no app: get the app on Home")
	ns.UI:Show("challenges")
	check(Shown("Get the Wanted app to track challenges and ranks") and Shown("Download it for Windows or Mac from wanteddeadordead.com/app."), "no app: get the app on Challenges")
	-- The app's version alone says it's there (an app that wrote no catch-up yet)
	WantedAppInfo = { running = "0.2.26" }
	ns.UI:Refresh()
	check(Shown("Update the Wanted app to track challenges and ranks"), "an app that says its version: update it")
	WantedAppInfo = appInfo
	ns.UI:Show("home")
	check(Shown("YOUR BOUNTY MONEY"), "the strip still shows")

	-- The demo (development builds)
	ns:RunCommand("demo", "")
	check(Challenges:IsDemo() and Challenges:GetMine().rank == 4, "the demo shows made-up challenges")
	ns.UI:Show("challenges")
	ns:RunCommand("demo", "banner")
	check(warned[#warned]:find("RANK UP", 1, true), "the demo's banner")
	ns:RunCommand("demo", "")
	check(not Challenges:IsDemo() and Challenges:Get() == nil, "the demo turns off")
	ns.Alerts.Warn = origWarn

	-- Long names fit their cards: every fitted line on Home and Challenges fits its width
	local long = Sample()
	long.hot = { { zone = "Hillsbrad Foothills", band = "20-30" }, { zone = "Stranglethorn Vale", band = "30-45" } }
	long.daily.name, long.daily.text = "Stranglethorn bloodbath", "Win 2 rounds at Hillsbrad Foothills"
	long.weekly[1].name = "Lieutenant General's errand"
	long.me["Player-1-ME"].rank, long.me["Player-1-ME"].nextAt = 10, 5100
	ns.Challenges:SetDemo(long)
	for _, key in ipairs({ "home", "challenges" }) do
		ns.UI:Show(key)
		for _, fs in ipairs(Mock.fontStrings) do
			if rawget(fs, "fitWidth") and fs._text ~= "" and fs._parent._shown and not fs._wrap then
				check(fs:GetUnboundedStringWidth() <= fs.fitWidth, "a line too long for its card: "..fs._text)
			end
		end
	end
	long.daily.text = "Win 2 rounds at Hillsbrad Foothills and Stranglethorn Vale"
	ns.Challenges:SetDemo(long)
	ns.UI:Show("home")
	local wrapped = false
	for _, fs in ipairs(Mock.fontStrings) do if fs._text == long.daily.text and fs._wrap then wrapped = true end end
	check(wrapped, "a challenge too long for one line goes on two")
	local enemiesLine
	for _, fs in ipairs(Mock.fontStrings) do if tostring(fs._text):find("No enemies there now", 1, true) then enemiesLine = fs end end
	check(enemiesLine and rawget(enemiesLine, "fitWidth") and enemiesLine:GetUnboundedStringWidth() <= enemiesLine.fitWidth, "the hot zone line stops short of the 2x")
	local moneyLine
	for _, fs in ipairs(Mock.fontStrings) do if fs._text == "Nothing owed or earned yet" or fs._text == "Nothing owed yet" then moneyLine = fs end end
	check(moneyLine, "no zero amounts on the bounty money card")
	ns.Challenges:SetDemo(nil)

	-- The window remembers its page; a page switched off falls back to Home
	ns.UI:Show("hotspots")
	check(db.settings.lastPage == "hotspots", "the page shown is remembered")
	db.settings.showTools = false
	ns.UI:Show("tools")
	check(db.settings.lastPage == "home" and ns.UI:IsShown("home"), "a hidden page opens Home instead")
	check(Shown("BOUNTIES") and Shown("WAR") and Shown("YOU"), "the menu's groups are labelled")
end)()
;(function()
	-- Other players' ranks (Ranks.lua): only from the app's ranks, each place behind its switch
	local Challenges, settings = ns.Challenges, ns.db.settings.ranks
	check(settings.tooltip and settings.target and settings.nameplates and settings.nearby and settings.who and not settings.chat, "rank switches: all on but chat")
	WantedAppCatchup = { [ns.db.accountMark] = { t = 1, records = {}, challenges = { t = clock, ranks = { ["thane oakcrest"] = { r = 7, f = "A" }, ["khal drogash"] = { r = 4, f = "H" } } } } }
	ns.Catchup:Import()
	RunTimers()
	local origName = UnitName
	local names = { nameplate7 = { "Thane", "Oakcrest" }, target = { "Khal", "Drogash" }, nameplate8 = { "Nobody", "Here" } }
	UnitName = function(unit) local n = names[unit] if n then return n[1], n[2] end return origName(unit) end
	local origIsPlayer = UnitIsPlayer
	UnitIsPlayer = function(unit) return names[unit] ~= nil or origIsPlayer(unit) end
	check(ns.Ranks:ForUnit("nameplate7").r == 7 and ns.Ranks:ForUnit("nameplate8") == nil, "a unit's rank by its full name")
	-- The unit's own side picks the titles, whatever side the data says; the data's only when the game doesn't say
	check(ns.Ranks:Label(ns.Ranks:ForUnit("nameplate7")) == "Rank 7, Blood Guard", "a Horde unit listed as Alliance gets the Horde title")
	local origFaction = UnitFactionGroup
	UnitFactionGroup = function(unit) if unit == "nameplate7" then return nil end return origFaction(unit) end
	check(ns.Ranks:Label(ns.Ranks:ForUnit("nameplate7")) == "Rank 7, Knight-Lieutenant", "the data's side when the game doesn't say")
	UnitFactionGroup = origFaction
	check(ns.Ranks:Label({ r = 7, f = "A" }) == "Rank 7, Knight-Lieutenant" and ns.Ranks:Label({ r = 7, f = "H" }) == "Rank 7, Blood Guard", "labels in the player's side's titles")
	-- Tooltip
	local lines = {}
	local origAdd = GameTooltip.AddLine
	GameTooltip.AddLine = function(_, text) lines[#lines + 1] = text end
	TooltipUtil = { GetDisplayedUnit = function() return "Khal Drogash", "target" end }
	for _, f in ipairs(tooltipPostCalls) do f(GameTooltip) end
	local found = false
	for _, l in ipairs(lines) do if l:find("Wanted: Rank 4, Senior Sergeant", 1, true) and l:find("PvPRank04", 1, true) then found = true end end
	check(found, "the tooltip line with the badge")
	settings.tooltip, lines = false, {}
	for _, f in ipairs(tooltipPostCalls) do f(GameTooltip) end
	for _, l in ipairs(lines) do check(not l:find("Wanted: Rank", 1, true), "no tooltip line with the switch off") end
	settings.tooltip = true
	GameTooltip.AddLine = origAdd
	-- Target frame
	TargetFrame = CreateFrame("Frame")
	Fire("PLAYER_TARGET_CHANGED")
	local label
	for _, fs in ipairs(Mock.fontStrings) do if tostring(fs._text):find("Rank 4, Senior Sergeant", 1, true) then label = fs end end
	check(label and label._parent._shown, "the target frame label shows")
	settings.target = false
	ns.Ranks:Update()
	check(not label._parent._shown, "and hides with its switch off")
	settings.target = true
	-- Nameplates: a forbidden plate isn't handed to addons (nil), so nothing is added there
	local plates = { nameplate7 = CreateFrame("Frame"), nameplate8 = CreateFrame("Frame") }
	C_NamePlate = { GetNamePlateForUnit = function(unit) return plates[unit] end }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate7")
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate8")
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate9")
	RunTimers()
	local plateLabel
	for _, fs in ipairs(Mock.fontStrings) do if fs._text == "7" and fs._parent._parent == plates.nameplate7 then plateLabel = fs end end
	check(plateLabel and plateLabel._parent._shown, "the rank on a ranked player's nameplate")
	local point = plateLabel._parent._point
	check(point[1] == "BOTTOM" and point[2] == plates.nameplate7 and point[3] == "TOP" and point[5] == -2, "centred over the plate by default")
	for _, fs in ipairs(Mock.fontStrings) do check(not (fs._parent and fs._parent._parent == plates.nameplate8), "nothing on an unranked player's plate") end
	Fire("NAME_PLATE_UNIT_REMOVED", "nameplate7")
	check(not plateLabel._parent._shown, "the number goes with the plate")
	C_NamePlate = nil
	-- Chat: off by default, then "[R7]" before what they said
	local filter = chatFilters.CHAT_MSG_SAY
	check(filter(nil, "CHAT_MSG_SAY", "hi", "Thane Oakcrest-Realm") == false, "no chat tag by default")
	local _, msg, author = (function() settings.chat = true return filter(nil, "CHAT_MSG_SAY", "hi", "Thane Oakcrest-Realm") end)()
	check(msg and msg:find("[R7]", 1, true) and msg:find("hi$") and author == "Thane Oakcrest-Realm", "the chat tag, the name left alone")
	check(select(2, filter(nil, "CHAT_MSG_SAY", "hi", "Nobody Here")) == nil, "no tag for unranked players")
	settings.chat = false
	-- Who list: our own text beside the name
	local origHook = hooksecurefunc
	hooksecurefunc = function(a, b, c)
		if type(a) == "table" then local o = a[b] a[b] = function(...) o(...) c(...) end
		else local o = _G[a] _G[a] = function(...) o(...) b(...) end end
	end
	WhoList_InitButton = function(button, data) button.Name:SetText(data.info.fullName) end
	Fire("ADDON_LOADED", "Blizzard_FriendsFrame")
	local button = CreateFrame("Button")
	button.Name = button:CreateFontString()
	WhoList_InitButton(button, { info = { fullName = "Khal Drogash" } })
	local whoTag
	for _, fs in ipairs(Mock.fontStrings) do if fs._parent == button and fs ~= button.Name then whoTag = fs end end
	check(button.Name._text == "Khal Drogash" and whoTag and whoTag._text == "R4", "R4 beside the Who list name, the name untouched")
	hooksecurefunc, WhoList_InitButton = origHook, nil
	-- Nearby window
	check(ns.Ranks:NearbyTag("Thane Oakcrest") == "R7" and ns.Ranks:NearbyTag("Nobody") == nil, "the Nearby window's tag")
	settings.nearby = false
	check(ns.Ranks:NearbyTag("Thane Oakcrest") == nil, "none with its switch off")
	settings.nearby = true
	ns.UI:Show("settings")

	-- The demo ranks every player, the same rank for the same name, on their side's titles
	ns:RunCommand("demo", "")
	local nobody = ns.Ranks:ForUnit("nameplate8")
	check(nobody and nobody.r >= 1 and nobody.r <= 14 and ns.Ranks:ForUnit("nameplate8").r == nobody.r, "the demo gives everyone a steady rank")
	check(ns.Ranks:ForUnit("nameplate7").r == 7, "a real rank still wins in the demo")
	check(Challenges:GetRank("Some Body", "Alliance").f == "A" and Challenges:GetRank("Some Body", "Horde").f == "H", "the demo's side follows the player's")
	lines = {}
	GameTooltip.AddLine = function(_, text) lines[#lines + 1] = text end
	TooltipUtil = { GetDisplayedUnit = function() return "Nobody Here", "nameplate8" end }
	for _, f in ipairs(tooltipPostCalls) do f(GameTooltip) end
	check(#lines > 0 and table.concat(lines, "\n"):find("Wanted: Rank "..nobody.r, 1, true), "the demo's rank in a real player's tooltip")
	GameTooltip.AddLine = origAdd
	ns:RunCommand("demo", "")

	-- ElvUI: its target frame and its nameplate frames (plate.unitFrame, as Plater's too) carry the labels
	ElvUF_Target = CreateFrame("Button")
	Fire("PLAYER_TARGET_CHANGED")
	local elvLabel
	for _, fs in ipairs(Mock.fontStrings) do if tostring(fs._text):find("Rank 4, Senior Sergeant", 1, true) and fs._parent._shown then elvLabel = fs end end
	check(elvLabel and elvLabel._parent.anchor == ElvUF_Target, "the target label follows ElvUI's target frame")
	ElvUF_Target:Hide()
	check(not elvLabel._parent._shown, "and hides with it")
	ElvUF_Target = nil
	local elvPlate = CreateFrame("Frame")
	elvPlate.unitFrame = CreateFrame("Button", nil, elvPlate)
	elvPlate.unitFrame.Health = CreateFrame("StatusBar", nil, elvPlate.unitFrame)
	elvPlate.unitFrame.Name = elvPlate.unitFrame:CreateFontString()
	elvPlate.unitFrame.Name._text = "Thane Oakcrest"
	elvPlate.unitFrame.Name.GetJustifyH = function() return "CENTER" end
	plates.nameplate7 = elvPlate
	C_NamePlate = { GetNamePlateForUnit = function(unit) return plates[unit] end }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate7")
	RunTimers()
	local onElv
	for _, fs in ipairs(Mock.fontStrings) do if fs._text == "7" and fs._parent._parent == elvPlate.unitFrame and fs._parent._shown then onElv = fs end end
	check(onElv, "the rank on ElvUI's nameplate frame")
	local label, layout = onElv._parent, ns.db.settings.ranks.plate
	local function Spot() local p = label._point return p[1].." "..(p[2] == elvPlate.unitFrame.Name and "name" or p[2] == elvPlate.unitFrame.Health and "bar" or p[2] == elvPlate.unitFrame and "frame" or "?").." "..p[3].." "..format("%g %g", p[4], p[5]) end
	check(Spot() == "BOTTOM frame TOP 0 -2", "centred over ElvUI's plate frame by default, got "..Spot())
	-- Each anchor, live on the plate already shown; the centred name's text starts 8px in from its 100px region
	local expected = { left = "RIGHT name LEFT 5 0", right = "LEFT name RIGHT -5 0", below = "TOP name BOTTOM 0 -2",
		barTopLeft = "BOTTOMLEFT bar TOPLEFT 0 2", barTopRight = "BOTTOMRIGHT bar TOPRIGHT 0 2", above = "BOTTOM name TOP 0 2", centre = "BOTTOM frame TOP 0 -2" }
	for _, key in ipairs({ "left", "right", "below", "barTopLeft", "barTopRight", "centre", "above" }) do
		layout.anchor = key
		ns.Ranks:Update()
		check(Spot() == expected[key], key..": got "..Spot())
	end
	-- Offsets and scale, kept within their ranges
	layout.x, layout.y, layout.scale = 10, -5, 1.4
	ns.Ranks:Update()
	check(Spot() == "BOTTOM name TOP 10 -3" and label._scale == 1.4, "offsets and scale, got "..Spot())
	layout.x, layout.y, layout.scale = 99, "x", 9
	ns.Ranks:Update()
	check(Spot() == "BOTTOM name TOP 50 2" and label._scale == 1.6, "out of range values are held to their limits, got "..Spot())
	layout.x, layout.y, layout.scale = 0, 0, 1
	-- Badge and number
	local badge = rawget(label, "badge")
	check(badge._shown and onElv._shown and onElv._point[4] == 14, "badge then number")
	layout.badge = false
	ns.Ranks:Update()
	check(not badge._shown and onElv._shown and onElv._point[4] == 0 and label._shown, "the number alone")
	layout.badge, layout.number = true, false
	ns.Ranks:Update()
	check(badge._shown and not onElv._shown and label._shown, "the badge alone")
	layout.badge = false
	ns.Ranks:Update()
	check(not label._shown, "neither: nothing")
	layout.badge, layout.number = true, true
	ns.Ranks:Update()
	check(label._shown, "both back")
	-- From the Settings page: the X offset slider moves the plate already shown
	ns.UI:Show("settings")
	local xSlider
	for _, fs in ipairs(Mock.fontStrings) do if fs._text == "X offset" and not xSlider then xSlider = fs._parent end end
	xSlider.slider._scripts.OnValueChanged(xSlider.slider, 12)
	check(layout.x == 12 and Spot() == "BOTTOM name TOP 12 2", "the slider changes the setting and the plate at once, got "..Spot())
	layout.x = 0
	ns.Ranks:Update()
	-- No name text shown: by the plate itself; the bar anchors still use the bar
	elvPlate.unitFrame.Name._shown = false
	ns.Ranks:Update()
	check(label._point[2] == elvPlate and label._point[3] == "TOP", "above the plate without a name")
	layout.anchor = "barTopRight"
	ns.Ranks:Update()
	check(Spot() == "BOTTOMRIGHT bar TOPRIGHT 0 2", "the bar's corner without a name")
	layout.anchor = "above"
	elvPlate.unitFrame.Name._shown = true
	-- The target label: each anchor, offsets and scale, live
	local tl = ns.db.settings.ranks.targetLabel
	TargetFrame = CreateFrame("Frame")
	Fire("PLAYER_TARGET_CHANGED")
	local targetLabel
	for _, fs in ipairs(Mock.fontStrings) do if tostring(fs._text):find("Rank 4, Senior Sergeant", 1, true) then targetLabel = fs._parent end end
	local function TSpot() local p = targetLabel._point return p[1].." "..p[3].." "..format("%g %g", p[4], p[5]) end
	check(TSpot() == "BOTTOM TOP 0 -6" and targetLabel._point[2] == TargetFrame, "the target label above the frame by default")
	local targetExpected = { below = "TOP BOTTOM 0 6", left = "RIGHT LEFT -4 0", right = "LEFT RIGHT 4 0" }
	for key, want in pairs(targetExpected) do
		tl.anchor = key
		ns.Ranks:Update()
		check(TSpot() == want, "target "..key..": got "..TSpot())
	end
	tl.anchor, tl.x, tl.y, tl.scale = "above", -20, 7, 0.8
	ns.Ranks:Update()
	check(TSpot() == "BOTTOM TOP -20 1" and targetLabel._scale == 0.8, "target offsets and scale, got "..TSpot())
	tl.x, tl.y, tl.scale = 0, 0, 1
	ns.Ranks:Update()
	-- A plate the game keeps from addons: asking for it fails, nothing happens
	C_NamePlate = { GetNamePlateForUnit = function() error("forbidden") end }
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate7")
	RunTimers()
	Fire("NAME_PLATE_UNIT_REMOVED", "nameplate7")
	C_NamePlate = nil

	UnitName, UnitIsPlayer = origName, origIsPlayer
	WantedAppCatchup = { [ns.db.accountMark] = { t = 1, records = {} } }
	ns.Catchup:Import()
	TargetFrame, TooltipUtil = nil, nil
end)()

-- 1.5.1: /wanted bug says why messages were dropped, most first
do
	local reasons = ns.Sync:DropReasons()
	check(type(reasons) == "string", "drop reasons are a line of text")
	if ns.Sync:GetInfo().stats.dropped > 0 then
		check(reasons ~= "" and reasons:find("%a+ %d+"), "drops this session come with their reasons: "..reasons)
	end
end
print("wanted smoke: 1.5.1 checks pass")
