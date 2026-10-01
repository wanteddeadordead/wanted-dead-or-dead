-- Wanted: bounty board and reputation for world PvP, shared peer to peer between players running it.
-- Core: load order, saved variables, settings and the /wanted command.

local ADDON_NAME, Wanted = ...
_G.Wanted = Wanted

Wanted.VERSION = C_AddOns and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "?"
Wanted.FOLDER = ADDON_NAME
---Whether a version is a development build: deployed with a "-dev" version (scripts/deploy.sh). A copy
---straight from GitHub, which the packager hasn't stamped, is not one.
function Wanted:IsDevVersion(version)
	return strfind(tostring(version), "%-dev") ~= nil
end
-- Only development builds have the test data commands (/wanted simulate, /wanted purge); released versions don't.
Wanted.DEV = Wanted:IsDevVersion(Wanted.VERSION)
-- The newest release another player's client has reported, when it is newer than this one
Wanted.newerVersion = nil
-- Beta: a label in the window, a one-time welcome, and bug reports
Wanted.BETA = false
Wanted.ISSUES_URL = "https://github.com/wanteddeadordead/wanted-dead-or-dead/issues"
-- The saved data layout. Bump it only together with an upgrade step in MIGRATIONS (see docs/DATA.md).
Wanted.DB_VERSION = 1
-- Which game world the saved data belongs to. The first time a release for the live game loads beta data,
-- it keeps the settings and drops the rest (docs/DATA.md). The launch release sets this to "live".
Wanted.WORLD = "beta"

local DEFAULTS = {
	version = Wanted.DB_VERSION,
	settings = {
		minBounty = 0, -- copper; the board hides bounties under this
		zoneFilter = nil, -- a zone name, or nil for all
		announce = false, -- nothing is announced in public chat (decided 2026-09-24)
		showPassed = false,
		emotes = { -- the emote buttons in the Nearby window (Emotes)
			enabled = true,
			tipShown = false,
			state = { lol = "fav", flex = "fav", doom = "fav", rude = "fav", train = "fav", violin = "fav", bye = "fav" },
		},
		boardSort = "amount", -- the board's order: amount, newest, name, zone or seen (Model.BOARD_SORTS)
		minimap = { angle = 200, hide = false },
		iconStyle = "crest", -- class icon style (Theme.ICON_STYLES)
		showTools = false, -- the Tools page (network details, test data, debug log)
		proofShots = true, -- a stamped screenshot when your kill claims a bounty (Proof)
		liveLog = true, -- combat logging on in the open world, written out during fights, for the app (LiveLog)
		appPrompt = true, -- the popup at login offering the desktop app when it isn't set up (PageWeb)
		bridge = true, -- carry bounty notices to and from Battle.net friends on the other faction (Bridge)
		streaks = { -- kill streak and multi-kill callouts (Streaks)
			callout = true, -- the big text in the middle of the screen
			sound = true,
			announce = "none", -- "none", "party" or "guild"; never a public channel
		},
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
			pvp = true, -- your own PvP status under the tabs
			opacity = 1,
		},
		detect = {
			enabled = true,
			alerts = "all", -- "all" enemies, "important" (Kill on Sight, bounties, stealth) or "none"
			sound = true,
			stealth = true,
			inSight = 60, -- seconds an enemy who drops out of view still shows as in sight (they're likely still around)
			timeout = 30, -- then seconds they stay on the Nearby list, shaded, before leaving it
			risingAlerts = true, -- warn when a zone fills up with enemies fast (Hotspots)
			onlyWhenExposed = false, -- quiet mode: alerts and the Nearby window only while you can be attacked
			quietTipShown = false, -- the one-time tip offering quiet mode after the first encounter
			autoHide = 300, -- seconds with no enemies before the Nearby window hides (0 = never)
			autoShow = true, -- open the Nearby window when an enemy appears
			share = true, -- tell other Wanted users about enemies seen
			sharedAlerts = true, -- alert when others see a Kill on Sight or bounty target
			mapPins = true,
			targetWarn = true, -- warning while an enemy has you targeted
			targetSound = true,
			sounds = { enemy = "wanted", important = "wanted", stealth = "wanted", targeted = "wanted" }, -- each alert's sound (Alerts:GetSoundChoice)
			targetHold = true, -- keep it up while targeted (otherwise a few seconds)
			targetNames = true, -- list who in the warning (off: just TARGETED; the Nearby window shows who)
			hudPos = nil,
			window = nil,
			tab = "nearby",
		},
		window = nil, -- { point, x, y }
	},
	kos = {}, -- guid -> { name, reason, t }
	seenNotices = {}, -- bounty id -> amount of the bounties on this player already announced (Bridge)
	bountyRequests = {}, -- request id -> bounty asked for from Discord, waiting to be asked on its character (Catchup)
	requestAnswers = {}, -- request id -> { state = "posted"|"discarded"|"refused", reason, t }, read by the app (Catchup)
	farPeers = {}, -- name -> { realm, seen } players on other realm names linked by whisper (Sync realm links)
	recentPeers = {}, -- name -> seen: the last players heard on the sync channel, to whisper if locked out of it
	homeCheck = { wait = 15 * 60, tried = 0 }, -- trying the first sync channel again after a takeover (Sync CheckHome)
	channel = nil, -- { name, realm, members, t }: the sync channel's size as the game last said (read by the app)
	posterShots = {}, -- { t, who, l, top, r, b }: poster pictures for the app to upload (Poster)
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

-- Upgrades between saved data layouts. MIGRATIONS[n] turns a layout n-1 table into layout n, in place,
-- keeping everything it can. Saved data is never wiped for being old. Add a step here, bump DB_VERSION, and
-- add a test that loads a table in the old layout (docs/DATA.md).
local MIGRATIONS = {
	-- [2] = function(db) ... end,
}

---Loads (or starts) the saved data, upgrading an older layout step by step. Data saved by a newer version
---(someone went back to an older release) is left exactly as it is: this session runs on a scratch copy and
---saves nothing, so going forward again finds it intact.
function Wanted:LoadSavedData()
	if type(WantedDB) ~= "table" then
		WantedDB = { version = Wanted.DB_VERSION }
	end
	-- Tables saved before the layout was numbered are layout 1
	local version = tonumber(WantedDB.version) or 1
	private.newerData = nil
	local db = WantedDB
	if version > Wanted.DB_VERSION then
		private.newerData = version
		db = { version = Wanted.DB_VERSION }
	else
		for step = version + 1, Wanted.DB_VERSION do
			if MIGRATIONS[step] then
				MIGRATIONS[step](WantedDB)
			end
			WantedDB.version = step
		end
		WantedDB.version = Wanted.DB_VERSION
		private.EnterWorld(WantedDB)
		WantedDB.accountMark = WantedDB.accountMark or private.NewAccountMark()
	end
	CopyDefaults(db, DEFAULTS)
	Wanted.db = db
	private.FixSettings(db)
	private.CheckRequiredUpdate(db)
end

-- What survives the move from the beta to the live game: the player's settings, not the beta's characters
local KEPT_FOR_NEW_WORLD = { version = true, settings = true, welcomed = true, accountMark = true, devLog = true }

local MARK_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

---A random id for this WoW account's saved data. The desktop app finds it in the saved file and leaves the
---account's link code under it (the !!WantedLink addon), so every character links itself (Store:AutoLink).
function private.NewAccountMark()
	local out = {}
	for i = 1, 16 do
		local n = math.random(#MARK_CHARS)
		out[i] = strsub(MARK_CHARS, n, n)
	end
	return table.concat(out)
end

---Drops the beta's data the first time a release for the live game loads it, keeping the settings (decided
---with Chris 2026-09-26 for the launch reset). Data saved in the live world is never touched.
function private.EnterWorld(db)
	local saved = db.world or "beta"
	if saved == "beta" and Wanted.WORLD ~= "beta" then
		for key in pairs(db) do
			if not KEPT_FOR_NEW_WORLD[key] then
				db[key] = nil
			end
		end
	end
	db.world = Wanted.WORLD
end

---Whether this session is running without saving because the saved data came from a newer version.
---@return number? layout the saved data's layout, when newer
function Wanted:GetNewerSavedLayout()
	return private.newerData
end

function private.LoadDB()
	Wanted:LoadSavedData()
end

---Small corrections to settings that don't need a layout change.
function private.FixSettings(db)
	-- Square and Classic icons are no longer offered (the same artwork as Crest on this client)
	local iconStyle = db.settings.iconStyle
	if iconStyle == "square" or iconStyle == "classic" then
		db.settings.iconStyle = "crest"
	end
	-- The first default was a minute; gone enemies now leave sooner
	local detect = db.settings.detect
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

-- What Wanted last did to its windows, newest last, for blocked-action reports: the client often can't name what
-- it blocked
private.trail = {}
private.trailPos = 0
local MAX_TRAIL = 8

---Notes a window action for the next blocked-action report. A repeat of the last one is counted, not added.
---@param what string a fixed label, e.g. "Nearby: redraw in combat" (built once, so it costs nothing to note)
function Wanted:Trail(what)
	local last = private.trail[private.trailPos]
	if last and last.what == what then
		last.count, last.t = last.count + 1, GetTime()
		return
	end
	private.trailPos = private.trailPos % MAX_TRAIL + 1
	local entry = private.trail[private.trailPos] or {}
	entry.what, entry.count, entry.t = what, 1, GetTime()
	private.trail[private.trailPos] = entry
end

---"Nearby: row emptied in combat 0.1s ago; Nearby: redraw in combat x12 0.3s ago; ...", newest first.
function private.TrailText()
	local parts, now = {}, GetTime()
	for i = 0, MAX_TRAIL - 1 do
		local entry = private.trail[(private.trailPos - 1 - i) % MAX_TRAIL + 1]
		if entry then
			tinsert(parts, format("%s%s %.1fs ago", entry.what, entry.count > 1 and " x"..entry.count or "", now - entry.t))
		end
	end
	return #parts > 0 and table.concat(parts, "; ") or "nothing yet"
end

---Where in Wanted's code a blocked action was asked for. The event fires inside the blocked call, so the stack
---holds the caller; none of Wanted's files on it means the client blocked it later, laying frames out.
function private.BlockedFrom()
	local stack = debugstack and debugstack(3, 12, 0) or ""
	-- The game's own function the call went into, when the stack starts there: [C]: in function 'Hide'
	local places = { strmatch(stack, "^%[C%]: in function [`'\"]?([%w_:%.]+)") }
	for file, line in string.gmatch(stack, ADDON_NAME.."[/\\]([^\"%]:]+)[\"%]]*:(%d+)") do
		if #places < 5 then
			tinsert(places, file..":"..line)
		end
	end
	return #places > 0 and table.concat(places, " < ") or "no Wanted code on the stack"
end

---Wraps an event handler or timer so development builds can time it (Debug.lua); released builds get it as is.
---@param label string
---@param func function
---@return function
function Wanted:Timed(label, func)
	return func
end

---Appends a line to the debug log, and in development builds to the client's log file on disk (Logs\General.log):
---every player's copy writing its chatter to disk would be wasted work.
function Wanted:Log(fmt, ...)
	local msg = select("#", ...) > 0 and format(fmt, ...) or fmt
	local line = date("%H:%M:%S").." "..msg
	private.logPos = private.logPos % MAX_LOG + 1
	private.log[private.logPos] = line
	if Wanted.DEV and C_Log and C_Log.LogMessage then
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

---Parses "1.2.3", "1.2.3-beta.4" or "1.2.3-alpha.4", with or without a leading "v" (anything after, like
---"-dev", is ignored).
---@param version any
---@return table? { major, minor, patch, stage (1 alpha, 2 beta, 3 release), pre }
function Wanted:ParseVersion(version)
	if type(version) ~= "string" or #version > 32 then
		return nil
	end
	-- Released versions carry the tag's "v" (v0.1.0-beta.1); development ones don't
	local major, minor, patch, rest = strmatch(version, "^v?(%d+)%.(%d+)%.(%d+)(.*)$")
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

---Whether a version is a release (tagged and published) rather than a development build ("-dev"). Only
---releases tell anyone to update: a build on a developer's PC is not out.
---@param version any
---@return boolean
function Wanted:IsRelease(version)
	return Wanted:ParseVersion(version) ~= nil and not strfind(version, "%-dev")
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

-- The newest version wins: once another player's client reports a newer release, the shared side of Wanted
-- (bounties, claims, payments, sync) pauses until this client is updated, so old and new never write
-- different things to the same network. What only reads the game (Nearby window, alerts, hotspots, map)
-- keeps working. Anyone can claim any version number, so a claim has to look like a real release (at most
-- one major version ahead), and a lock lifts when nobody on that version has been seen for three days.
local REQUIRED_KEEP_SECONDS = 3 * 24 * 60 * 60

---Whether a reported version could be a real release after ours.
function private.IsPlausibleUpdate(version)
	local theirs, ours = Wanted:ParseVersion(version), Wanted:ParseVersion(Wanted.VERSION)
	return theirs ~= nil and ours ~= nil and theirs[1] <= ours[1] + 1
end

---The desktop app's version, if it's set up on this computer: it writes it into !!WantedLink (WantedAppInfo)
---as it runs. Nil without the app.
---@return string?
function Wanted:AppVersion()
	local info = WantedAppInfo
	if type(info) == "table" and Wanted:ParseVersion(info.running) then
		return info.running
	end
	return nil
end

-- The app says when it last ran, to the half hour (from 0.2.1). Longer ago than this, it isn't running.
local APP_STALE_SECONDS = 3 * 60 * 60

-- When the game read !!WantedLink: at login or /reload only, like every addon file. It loads before this addon
-- ("!!" sorts first), so this is the moment its "seen" was current.
local APP_INFO_READ_AT = GetServerTime()

---How long ago the app last ran, when it had already stopped by the time the game read its file; nil when it
---was running then, isn't set up, or is too old to say (before 0.2.1). The file is read only at login or /reload,
---so hours into a session its time is old even while the app runs: it's judged against the moment it was read.
---@return number? seconds
function Wanted:AppNotRunningFor()
	local info = WantedAppInfo
	local seen = type(info) == "table" and Wanted:AppVersion() and tonumber(info.seen)
	if not seen or APP_INFO_READ_AT - seen <= APP_STALE_SECONDS then
		return nil
	end
	return GetServerTime() - seen
end

---How many apps the network has running, for development builds to show; nil when the app hasn't said.
---@return number?
function Wanted:AppsRunning()
	local info = WantedAppInfo
	local n = type(info) == "table" and tonumber(info.apps)
	return n and n > 0 and floor(n) or nil
end

---The Wanted desktop app writes its own version and the newest one out into !!WantedLink (WantedAppInfo).
---When it's behind, says so once a login: most players are in game, not looking at the tray. The versions
---are rebuilt from what they parse to, so nothing another addon put there is shown as is.
---@return boolean told
function Wanted:CheckAppVersion()
	local info = WantedAppInfo
	if type(info) ~= "table" then
		return false
	end
	local running, latest = Wanted:ParseVersion(info.running), Wanted:ParseVersion(info.latest)
	if not running or not latest or not Wanted:IsNewerVersion(info.latest, info.running) then
		return false
	end
	Wanted:Print("The Wanted app %s is out (you have %s). Get it from the app's tray menu or wanteddeadordead.com/app.",
		private.VersionText(latest), private.VersionText(running))
	return true
end

---Another player's client reported its version. A newer, plausible one means this client must update.
---@param version any
function Wanted:NoteVersion(version)
	if not Wanted:IsRelease(version) or not Wanted:IsNewerVersion(version, Wanted.VERSION) or not Wanted.db then
		return
	end
	if not private.IsPlausibleUpdate(version) then
		Wanted:Log("Version %s reported, too far ahead to be real; ignored", tostring(version))
		return
	end
	local text = private.VersionText(Wanted:ParseVersion(version))
	local required = Wanted.db.requiredVersion
	if required and not Wanted:IsNewerVersion(text, required.version) then
		if text == required.version then
			required.seen = GetServerTime()
		end
		return
	end
	Wanted.db.requiredVersion = { version = text, seen = GetServerTime() }
	Wanted:Log("!! Version: %s is newer than ours; shared features wait for the update", text)
	Wanted.newerVersion = text
	private.TellUpdate()
	if Wanted.UI and Wanted.UI.Refresh then
		Wanted.UI:Refresh()
	end
end

local DOWNLOAD_URL = "https://www.curseforge.com/wow/addons/wanted-dead-or-dead"

---Says this client is behind and where to get the new one: when a newer release is first seen, and at each
---login until it's updated.
function private.TellUpdate()
	Wanted:Print("Your version is outdated. Wanted %s is out; download it from %s. Bounties, claims and sharing are paused until you update. The Nearby window, alerts, hotspots and the map keep working.",
		Wanted:GetRequiredUpdate(), DOWNLOAD_URL)
end

---At login: repeats the update notice while this client is behind.
---@return boolean told
function Wanted:RemindUpdate()
	if not Wanted:GetRequiredUpdate() then
		return false
	end
	private.TellUpdate()
	return true
end

---The version this client has to update to before its shared side works again, or nil.
---@return string?
function Wanted:GetRequiredUpdate()
	local required = Wanted.db and Wanted.db.requiredVersion
	return required and required.version or nil
end

---Lifts the update lock once this client is on that version, or when nobody on it has been seen for a while.
function private.CheckRequiredUpdate(db)
	local required = db.requiredVersion
	if not required then
		return
	end
	if not Wanted:IsNewerVersion(required.version, Wanted.VERSION) or GetServerTime() - (required.seen or 0) > REQUIRED_KEEP_SECONDS then
		db.requiredVersion = nil
		return
	end
	Wanted.newerVersion = required.version
end

-- Commands that change shared records; paused while an update is required
local SHARED_COMMANDS = { post = true, raise = true, pass = true, confirm = true, dispute = true, pay = true, link = true }

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
	if info and SHARED_COMMANDS[cmd] and Wanted:GetRequiredUpdate() then
		Wanted:Print("Update Wanted to %s first: bounties, claims and payments are paused until you do.", Wanted:GetRequiredUpdate())
	elseif info then
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
	Wanted:RunCommand(cmd, args)
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
	-- The desktop app's restore sets WantedRestoreFilled when the game didn't load the saved data itself
	local restored = type(WantedRestoreFilled) == "table" and WantedRestoreFilled.WantedDB
	Wanted:Print("Saved data: %s.", restored and "restored by the desktop app (the game didn't load it)" or "loaded by the game")
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

---What was going on when the client blocked something: the blocked function is often UNKNOWN on this
---client, so combat, what the mouse was over and which windows were open are the clues.
function private.BlockContext()
	local parts = { InCombatLockdown() and "in combat" or "out of combat" }
	local ok, text = pcall(function()
		local foci = GetMouseFoci and GetMouseFoci() or (GetMouseFocus and { GetMouseFocus() }) or {}
		local focus = foci[1]
		if focus and focus.GetDebugName then
			tinsert(parts, "mouse over "..tostring(focus:GetDebugName()))
		end
		if WorldMapFrame and WorldMapFrame:IsShown() then
			tinsert(parts, "world map open")
		end
		if Wanted.NearbyWindow and Wanted.NearbyWindow.IsShown and Wanted.NearbyWindow:IsShown() then
			tinsert(parts, "Nearby window open")
		end
		if Wanted.UI and Wanted.UI.IsShown and Wanted.UI:IsShown() then
			tinsert(parts, "Wanted window open")
		end
		return table.concat(parts, ", ")
	end)
	return ok and text or table.concat(parts, ", ")
end

-- ============================================================================
-- Fights and background work
-- ============================================================================

-- In a fight the addon keeps recording and does nothing else it can put off: sync work waits until combat has
-- been over a few seconds, then runs a few milliseconds a frame so it never stalls the game.
local COMBAT_SETTLE_SECONDS = 3
local WORK_MS_PER_FRAME = 3
private.inCombat = false
private.combatGen = 0
private.combatEndListeners = {}
private.work, private.workHead, private.workTail = {}, 1, 0
private.workFrame = CreateFrame("Frame")
private.workFrame:Hide()

---Whether the player is in a fight (and for a few seconds after), when only recording should happen.
---@return boolean
function Wanted:InCombat()
	return private.inCombat
end

---Whether the player is in a battleground or arena: the game blocks addon messages and hides chat text from addons
---there, and world PvP (kills, sightings, bounties, alerts) doesn't count.
---@return boolean
function Wanted:InPvPMatch()
	local _, kind = IsInInstance()
	return kind == "pvp" or kind == "arena"
end

---Registers a function called once each fight is over.
---@param func function
function Wanted:OnCombatEnd(func)
	tinsert(private.combatEndListeners, func)
end

---Queues work to run between frames, a little at a time, and never during a fight.
---@param func function
function Wanted:QueueWork(func)
	private.workTail = private.workTail + 1
	private.work[private.workTail] = func
	private.workFrame:Show()
end

---How many pieces of queued work are waiting.
---@return number
function Wanted:QueuedWork()
	return private.workTail - private.workHead + 1
end

---Runs queued work for up to ms milliseconds (none during a fight). The work frame calls it every frame.
---@param ms number
function Wanted:DoQueuedWork(ms)
	if private.inCombat then
		return
	end
	local start = debugprofilestop()
	while private.workHead <= private.workTail and debugprofilestop() - start < ms do
		local func = private.work[private.workHead]
		private.work[private.workHead] = nil
		private.workHead = private.workHead + 1
		func()
	end
	if private.workHead > private.workTail then
		private.work, private.workHead, private.workTail = {}, 1, 0
		private.workFrame:Hide()
	end
end

private.workFrame:SetScript("OnUpdate", function()
	Wanted:DoQueuedWork(WORK_MS_PER_FRAME)
end)

function private.OnCombatChanged(inCombat)
	private.combatGen = private.combatGen + 1
	if inCombat then
		if not private.inCombat then
			Wanted:Log("Combat: recording only until the fight is over")
		end
		private.inCombat = true
		return
	end
	local gen = private.combatGen
	C_Timer.After(COMBAT_SETTLE_SECONDS, function()
		if gen ~= private.combatGen or not private.inCombat then
			return
		end
		private.inCombat = false
		Wanted:Log("Combat: over, %d pieces of work to catch up on", Wanted:QueuedWork())
		for _, func in ipairs(private.combatEndListeners) do
			func()
		end
	end)
end

private.frame:RegisterEvent("ADDON_LOADED")
private.frame:RegisterEvent("PLAYER_LOGIN")
private.frame:RegisterEvent("PLAYER_REGEN_DISABLED")
private.frame:RegisterEvent("PLAYER_REGEN_ENABLED")
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
		if private.newerData then
			Wanted:Print("Your saved data is from a newer version of Wanted. Update the addon to use it; until then nothing you do this session is saved, and your data is left as it is.")
		end
		private.CallModules("OnEnable")
		Wanted:RemindUpdate()
		Wanted:CheckAppVersion()
		-- A moment after the loading screen, so it isn't lost behind it
		C_Timer.After(6, function() Wanted:PromptForApp() end)
	elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
		private.OnCombatChanged(event == "PLAYER_REGEN_DISABLED")
	elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		if arg1 == ADDON_NAME then
			Wanted:NoteProblem(format("%s: %s (%s) from %s; last: %s", event, tostring(arg2), private.BlockContext(),
				private.BlockedFrom(), private.TrailText()))
			Wanted:Print("The client blocked %s. /wanted bug makes a report you can send.", tostring(arg2))
		end
	end
end)
