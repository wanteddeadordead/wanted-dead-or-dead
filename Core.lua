-- Wanted: bounty board and reputation for world PvP, shared peer to peer between players running it.
-- Core: load order, saved variables, settings and the /wanted command.

local ADDON_NAME, Wanted = ...
_G.Wanted = Wanted

Wanted.VERSION = C_AddOns and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "?"
Wanted.FOLDER = ADDON_NAME
-- The newest release another player's client has reported, when it is newer than this one
Wanted.newerVersion = nil
-- Beta: a label in the window, a one-time welcome, and bug reports
Wanted.BETA = true
Wanted.ISSUES_URL = "https://github.com/wanteddeadordead/wanted-dead-or-dead/issues"
-- Bumped when the saved data layout changes; an older layout is reset rather than migrated while in beta
Wanted.DB_VERSION = 1

local DEFAULTS = {
	version = Wanted.DB_VERSION,
	settings = {
		minBounty = 0, -- copper; the board hides bounties under this
		zoneFilter = nil, -- a zone name, or nil for all
		announce = false, -- nothing is announced in public chat (decided 2026-09-24)
		showPassed = false,
		minimap = { angle = 200, hide = false },
		iconStyle = "crest", -- class icon style (Theme.ICON_STYLES)
		showTools = false, -- the Tools page (network details, test data, debug log)
		nearby = { -- what the Nearby window shows
			layout = "auto", -- "auto" (compact above 8 enemies), "normal" or "compact"
			icon = true,
			className = true,
			level = true,
			guild = true,
			bounty = true,
			kos = true, -- Kill on Sight tag and reason
			state = true, -- active / in sight / not seen
			record = true, -- wins-losses
			health = true,
			tint = true, -- class colour wash
			targeting = true, -- ">" when they target you
			fade = true, -- shade enemies out of sight
			opacity = 1,
		},
		detect = {
			enabled = true,
			alerts = "all", -- "all" enemies, "important" (Kill on Sight, bounties, stealth) or "none"
			sound = true,
			stealth = true,
			timeout = 30, -- seconds an unseen enemy stays on the Nearby list
			autoShow = true, -- open the Nearby window when an enemy appears
			share = true, -- tell other Wanted users about enemies seen
			sharedAlerts = true, -- alert when others see a Kill on Sight or bounty target
			mapPins = true,
			targetWarn = true, -- warning while an enemy has you targeted
			targetSound = true,
			targetHold = true, -- keep it up while targeted (otherwise a few seconds)
			targetNames = true, -- list who in the warning (off: just TARGETED; the Nearby window shows who)
			hudPos = nil,
			window = nil,
			tab = "nearby",
		},
		window = nil, -- { point, x, y }
	},
	kos = {}, -- guid -> { name, reason, t }
	ignore = {}, -- guid -> { name, t }
	enemyStats = {}, -- guid -> { wins, losses, detections, first, last }
}

local private = {
	frame = CreateFrame("Frame"),
	modules = {}, -- name -> module, in load order
	loaded = false,
}



-- ============================================================================
-- Module registration
-- ============================================================================

---Registers a module; its OnLoad runs once the saved data is ready, its OnEnable at PLAYER_LOGIN.
---@param name string
---@return table
function Wanted:NewModule(name)
	assert(not Wanted[name], "duplicate module "..name)
	local module = {}
	Wanted[name] = module
	tinsert(private.modules, module)
	return module
end

function private.CallModules(funcName)
	for _, module in ipairs(private.modules) do
		if module[funcName] then
			module[funcName](module)
		end
	end
end



-- ============================================================================
-- Saved data
-- ============================================================================

local function CopyDefaults(target, defaults)
	for key, value in pairs(defaults) do
		if type(value) == "table" then
			if type(target[key]) ~= "table" then
				target[key] = {}
			end
			CopyDefaults(target[key], value)
		elseif target[key] == nil then
			target[key] = value
		end
	end
end

function private.LoadDB()
	if type(WantedDB) ~= "table" or WantedDB.version ~= Wanted.DB_VERSION then
		-- Nothing saved, or an older layout: start fresh. The Forever client does not write saved variables on
		-- logout, so an empty table here is the normal case until the restore watcher includes WantedDB.
		WantedDB = { version = Wanted.DB_VERSION }
	end
	CopyDefaults(WantedDB, DEFAULTS)
	Wanted.db = WantedDB
	-- The first default was a minute; gone enemies now leave sooner
	local detect = WantedDB.settings.detect
	if detect and not detect.timeoutV2 then
		detect.timeoutV2 = true
		if detect.timeout == 60 then
			detect.timeout = 30
		end
	end
end



-- ============================================================================
-- Chat output
-- ============================================================================

private.capture = nil

function Wanted:Print(fmt, ...)
	local msg = select("#", ...) > 0 and format(fmt, ...) or fmt
	if private.capture then
		tinsert(private.capture, msg)
		return
	end
	DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Wanted:|r "..msg)
end

---Runs a function and returns the lines it would have printed instead of printing them.
---@param func function
---@return string[]
function Wanted:CapturePrints(func)
	local lines = {}
	private.capture = lines
	local ok, err = pcall(func)
	private.capture = nil
	if not ok then
		tinsert(lines, "error: "..tostring(err))
	end
	return lines
end



-- ============================================================================
-- Debug log
-- ============================================================================

private.log = {}
private.logPos = 0
local MAX_LOG = 300

private.problems = {} -- errors and blocked actions this session, for bug reports
local MAX_PROBLEMS = 20

---Notes an error or a blocked action for the bug report.
function Wanted:NoteProblem(text)
	if #private.problems >= MAX_PROBLEMS then
		tremove(private.problems, 1)
	end
	tinsert(private.problems, date("%H:%M:%S").." "..tostring(text))
	Wanted:Log("Problem: %s", tostring(text))
end

function Wanted:GetProblems()
	return private.problems
end

---Appends a line to the debug log, and to the client's log file on disk when the client offers it.
function Wanted:Log(fmt, ...)
	local msg = select("#", ...) > 0 and format(fmt, ...) or fmt
	local line = date("%H:%M:%S").." "..msg
	private.logPos = private.logPos % MAX_LOG + 1
	private.log[private.logPos] = line
	if C_Log and C_Log.LogMessage then
		C_Log.LogMessage("WANTED "..line)
	end
end

---The last lines of the debug log, oldest first.
---@param count number?
---@return string[]
function Wanted:GetLogLines(count)
	count = min(count or MAX_LOG, MAX_LOG)
	local lines = {}
	for i = count - 1, 0, -1 do
		local index = (private.logPos - i - 1) % MAX_LOG + 1
		if private.log[index] then
			tinsert(lines, private.log[index])
		end
	end
	return lines
end

---Prints the last lines of the debug log.
function Wanted:PrintLog(count)
	local lines = Wanted:GetLogLines(count or 30)
	if #lines == 0 then
		Wanted:Print("Debug log is empty.")
		return
	end
	for _, line in ipairs(lines) do
		Wanted:Print("%s", line)
	end
end



-- ============================================================================
-- Slash command
-- ============================================================================

private.commands = {}

---Parses "1.2.3", "1.2.3-beta.4" or "1.2.3-alpha.4" (anything after that, like "-dev", is ignored).
---@param version any
---@return table? { major, minor, patch, stage (1 alpha, 2 beta, 3 release), pre }
function Wanted:ParseVersion(version)
	if type(version) ~= "string" or #version > 32 then
		return nil
	end
	local major, minor, patch, rest = strmatch(version, "^(%d+)%.(%d+)%.(%d+)(.*)$")
	if not major then
		return nil
	end
	local stage, pre = 3, 0
	local alpha, beta = strmatch(rest, "^%-alpha%.(%d+)"), strmatch(rest, "^%-beta%.(%d+)")
	if alpha then
		stage, pre = 1, tonumber(alpha)
	elseif beta then
		stage, pre = 2, tonumber(beta)
	end
	return { tonumber(major), tonumber(minor), tonumber(patch), stage, pre }
end

---Whether version a is newer than version b. False when either can't be read.
function Wanted:IsNewerVersion(a, b)
	local pa, pb = Wanted:ParseVersion(a), Wanted:ParseVersion(b)
	if not pa or not pb then
		return false
	end
	for i = 1, 5 do
		if pa[i] ~= pb[i] then
			return pa[i] > pb[i]
		end
	end
	return false
end

---Formats a parsed version back into text, so nothing a peer sent is shown as is.
function private.VersionText(parsed)
	local text = format("%d.%d.%d", parsed[1], parsed[2], parsed[3])
	if parsed[4] == 1 then
		return text.."-alpha."..parsed[5]
	elseif parsed[4] == 2 then
		return text.."-beta."..parsed[5]
	end
	return text
end

---Another player's client reported its version: note it once when it's newer than ours.
---@param version any
function Wanted:NoteVersion(version)
	if not Wanted:IsNewerVersion(version, Wanted.VERSION) then
		return
	end
	if Wanted.newerVersion and not Wanted:IsNewerVersion(version, Wanted.newerVersion) then
		return
	end
	local announce = not Wanted.newerVersion
	Wanted.newerVersion = private.VersionText(Wanted:ParseVersion(version))
	if announce then
		Wanted:Print("A newer version (%s) is out. Update from CurseForge to get the latest fixes.", Wanted.newerVersion)
	end
end

---Registers a /wanted subcommand.
---@param name string
---@param help string
---@param func fun(args: string)
function Wanted:RegisterCommand(name, help, func)
	private.commands[name] = { help = help, func = func }
end

---Runs a subcommand by name.
---@param cmd string
---@param args string
function Wanted:RunCommand(cmd, args)
	local info = private.commands[cmd]
	if info then
		info.func(args or "")
	else
		Wanted:Print("No such view: %s", tostring(cmd))
	end
end

function private.OnSlashCommand(input)
	local cmd, args = strmatch(strtrim(input or ""), "^(%S*)%s*(.*)$")
	cmd = strlower(cmd)
	if cmd == "" then
		if Wanted.UI and Wanted.UI.Toggle then
			Wanted.UI:Toggle()
			return
		end
		cmd = "status"
	end
	local info = private.commands[cmd]
	if not info then
		Wanted:Print("Commands:")
		local names = {}
		for name in pairs(private.commands) do
			tinsert(names, name)
		end
		sort(names)
		for _, name in ipairs(names) do
			Wanted:Print("  /wanted %s - %s", name, private.commands[name].help)
		end
		return
	end
	info.func(args)
end

SLASH_WANTED1 = "/wanted"
SlashCmdList["WANTED"] = private.OnSlashCommand

Wanted:RegisterCommand("debug", "Prints the last lines of the debug log (/wanted debug 100 for more).", function(args)
	Wanted:PrintLog(tonumber(args) or (private.capture and 300) or 30)
end)

Wanted:RegisterCommand("status", "Shows the version and what is stored.", function()
	local db = Wanted.db
	local settings = db.settings
	Wanted:Print("v%s, data layout %d, faction %s.", Wanted.VERSION, db.version, UnitFactionGroup("player") or "?")
	Wanted:Print("Board filter: minimum %s, zone %s. Announce new bounties: %s.", settings.minBounty > 0 and GetCoinTextureString(settings.minBounty) or "none", settings.zoneFilter or "all", settings.announce and "yes" or "no")
	for _, module in ipairs(private.modules) do
		if module.Status then
			Wanted:Print("  %s", module:Status())
		end
	end
end)



-- ============================================================================
-- Error capture (for bug reports)
-- ============================================================================

---Notes Lua errors that come from this addon's files, then hands every error on to whatever handler was
---there before (the default one, or an error-collecting addon), so nothing else changes.
function private.WatchErrors()
	if not geterrorhandler or not seterrorhandler then
		return
	end
	local previous = geterrorhandler()
	seterrorhandler(function(err, ...)
		if type(err) == "string" and strfind(err, "AddOns[/\\]"..ADDON_NAME.."[/\\]") then
			pcall(Wanted.NoteProblem, Wanted, err)
		end
		if previous then
			return previous(err, ...)
		end
	end)
end



-- ============================================================================
-- Lifecycle
-- ============================================================================

private.frame:RegisterEvent("ADDON_LOADED")
private.frame:RegisterEvent("PLAYER_LOGIN")
-- These name the function the client refused, which the popup on this client does not
private.frame:RegisterEvent("ADDON_ACTION_BLOCKED")
private.frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
private.frame:SetScript("OnEvent", function(_, event, arg1, arg2)
	if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
		private.WatchErrors()
		private.LoadDB()
		Wanted:Log("Loaded v%s, data layout %d", Wanted.VERSION, Wanted.db.version)
		private.CallModules("OnLoad")
		private.loaded = true
	elseif event == "PLAYER_LOGIN" then
		Wanted:Log("Login as %s (%s)", UnitName("player"), UnitFactionGroup("player") or "?")
		private.CallModules("OnEnable")
	elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		if arg1 == ADDON_NAME then
			Wanted:NoteProblem(event..": "..tostring(arg2))
			Wanted:Print("The client blocked %s. /wanted bug makes a report you can send.", tostring(arg2))
		end
	end
end)
