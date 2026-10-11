-- Wanted: bug reports and the beta welcome. An addon can't open a web page or send anything outside the
-- game, so a report the player sends (a bug, or a duel tip that looks wrong) waits in the saved data for the
-- desktop app to pass on to the developers.

local _, Wanted = ...
local Report = Wanted:NewModule("Report")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local private = { frame = nil }
local LOG_LINES = 40
local MAX_PROBLEM_LINES = 5 -- this session's newest problems a bug's log carries ahead of the recent lines
local MIN_NAME = 2 -- shorter names aren't looked for
-- Reports waiting for the app (docs/DATA.md): the most kept, how long one waits, and the most each part may be (letters;
-- the log in bytes)
local MAX_QUEUED = 20
local REPORT_KEEP_SECONDS = 30 * 24 * 60 * 60
local MAX_TEXT = 500
local MAX_TIP = 1000
local MAX_LOG_BYTES = 8 * 1024
local MAX_RULE = 64

function Report:OnLoad()
	-- A report the app never sent within 30 days goes
	local cutoff = GetServerTime() - REPORT_KEEP_SECONDS
	for id, report in pairs(Wanted.db.reports) do
		if type(report) ~= "table" or type(report.at) ~= "number" or report.at < cutoff then
			Wanted.db.reports[id] = nil
		end
	end
end

---Whether a byte can be part of a name: a letter, an apostrophe, or part of an accented letter.
local function NameByte(byte)
	return byte ~= nil and (byte >= 128 or byte == 39 or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122))
end

---The names Wanted knows, longest first: players seen, every record's origin, the guild roster, the lists, this
---character's own. Each with its realm cut off as well.
function private.KnownNames()
	local set = {}
	local function Add(name)
		if type(name) == "string" and not (issecretvalue and issecretvalue(name)) then
			set[name] = true
			local bare = strmatch(name, "^([^%-]+)%-")
			if bare then
				set[bare] = true
			end
		end
	end
	local db = Wanted.db or {}
	for _, player in pairs(type(db.players) == "table" and db.players or {}) do
		Add(type(player) == "table" and player.name)
	end
	for origin in pairs(type(db.chains) == "table" and db.chains or {}) do
		Add(origin)
	end
	for _, list in ipairs({ db.kos, db.ignore }) do
		for _, entry in pairs(type(list) == "table" and list or {}) do
			Add(type(entry) == "table" and entry.name)
		end
	end
	for _, entry in pairs(type(db.hkBook) == "table" and db.hkBook or {}) do
		Add(type(entry) == "table" and entry.n)
	end
	for _, book in pairs(type(db.guildKos) == "table" and db.guildKos or {}) do
		for _, e in pairs(type(book) == "table" and type(book.entries) == "table" and book.entries or {}) do
			if type(e) == "table" then
				Add(e.kind == "player" and e.name)
				Add(e.by)
				Add(e.dby)
				Add(e.eby)
			end
		end
	end
	local ok, members = pcall(function() return Wanted.GuildRank and Wanted.GuildRank:Members() end)
	for _, m in ipairs(ok and type(members) == "table" and members or {}) do
		Add(m.name)
	end
	Add(Wanted.Store and Wanted.Store:GetOrigin())
	local names = {}
	for name in pairs(set) do
		if #name >= MIN_NAME then
			tinsert(names, name)
		end
	end
	sort(names, function(a, b) return #a > #b end)
	return names
end

-- Where the log puts a name Wanted may never have stored: the sender in Sync's own formats (any name), each as a
-- pattern whose captures are what comes before the name and, if anything, what comes after it
local SENDER_FORMATS = {
	"(received %d+ bytes from )[^<]-( %(self%))",
	"(received %d+ bytes from )[^<]-( on [^ ]+)$",
	"(received %d+ bytes from )[^<]-( by whisper)$",
	"(received %d+ bytes from )[^<]-( in the guild)$",
	"(handling %u+ from )[^<]-( %(realm link%))$",
	"(handling %u+ from )[^<]-$",
	"(message from )[^<]-$",
	"(part %d+/%d+ from )[^<]-( doesn't fit)",
	"(record %S+ from )[^<]-(: )",
}
-- The words a "First Surname" name follows in the log's formats ("killed by", "UNIT_DIED for", "Sync: ... says"); not
-- "in", which comes before a zone, or a duel's "against", which comes before a class
local NAME_MARKERS = { "from", "to", "by", "for", "with", "of", "as", "on", "one against", "killer", "origin", "greeting",
	"told", "notice [%u_]+", "Sync:", "Posse:", "Enemies:", "Recorder:", "Bridge:", "GuildKoS:", "KeyBook:", "Version:",
	"Store:", "Verify:" }
local NAME_PAIR = "[%u\128-\255][%l\128-\255'][%a\128-\255]* [%u\128-\255][%l\128-\255'][%a\128-\255]*%f[^%w\128-\255]"

---A line with other players left out: GUIDs (any case), the names Wanted knows (with a realm or not), the sender in
---Sync's formats and any "First Surname" after a word that comes before a name, any other "Name-Realm", and this
---realm's name. The log names whoever a message came from or was about; the report shouldn't.
function private.Scrub(line, names)
	line = gsub(line, "[Pp][Ll][Aa][Yy][Ee][Rr]%-%d+%-%x+", "Player-?")
	for _, name in ipairs(names) do
		local from = 1
		while true do
			local first, last = strfind(line, name, from, true)
			if not first then
				break
			end
			if NameByte(line:byte(first - 1)) or NameByte(line:byte(last + 1)) then
				from = last + 1 -- part of a longer word
			else
				line = strsub(line, 1, first - 1).."<name>"..strsub(line, last + 1)
				from = first + 6
			end
		end
	end
	-- Names never stored, found by where they stand in the line
	for _, pattern in ipairs(SENDER_FORMATS) do
		line = gsub(line, pattern, function(before, after) return before.."<name>"..(after or "") end)
	end
	for _, marker in ipairs(NAME_MARKERS) do
		line = gsub(line, "(%f[%w]"..marker.." )"..NAME_PAIR, "%1<name>")
	end
	-- A name with a realm, known or not, and a realm after a name left out
	line = gsub(line, "<name>%-[%w\128-\255']+", "<name>")
	line = gsub(line, "[%w\128-\255']+%-[%u\128-\255][%w\128-\255']*", function(token)
		return strfind(token, "^Player%-") and token or "<name>"
	end)
	local realm = GetRealmName and GetRealmName()
	if type(realm) == "string" and realm ~= "" then
		line = gsub(line, "%f[%w]"..gsub(realm, "%p", "%%%0").."%f[%W]", "<realm>")
	end
	return line
end

---The report text: versions, settings that matter, network state, problems this session, recent log. No longer
---shown (Report a bug only sends); kept for the tests, which read what it gathers.
---@return string
function Report:Build()
	local lines = {}
	local function Add(fmt, ...)
		tinsert(lines, select("#", ...) > 0 and format(fmt, ...) or fmt)
	end
	local version, build = GetBuildInfo()
	Add("Wanted: Dead or... Dead %s%s%s", tostring(Wanted.VERSION), Wanted.BETA and " (beta)" or "", Wanted.newerVersion and (", newer version seen: "..Wanted.newerVersion) or "")
	Add("Game client %s (build %s), locale %s", tostring(version), tostring(build), tostring(GetLocale and GetLocale() or "?"))
	Add("Faction %s, level %s, zone %s", tostring(UnitFactionGroup("player")), tostring(UnitLevel("player")), tostring(GetZoneText()))
	local detect = Wanted.db and Wanted.db.settings.detect or {}
	Add("Detection %s, alerts %s, sound %s, share %s, timeout %ss", tostring(detect.enabled), tostring(detect.alerts), tostring(detect.sound), tostring(detect.share), tostring(detect.timeout))
	local info = Wanted.Sync and Wanted.Sync:GetInfo()
	if info then
		local stats = info.stats
		Add("Network: channel %s, members %s, peers %d, sent %d, received %d, merged %d, invalid %d, dropped %d, throttled %d, repeats skipped %d%s", info.channelId and ("#"..info.channelId) or "not joined", tostring(info.members), info.peers, stats.sent, stats.received, stats.merged, stats.invalid, stats.dropped, stats.throttled, stats.skipped, info.paused and ", PAUSED" or "")
		local reasons = Wanted.Sync and Wanted.Sync.DropReasons and Wanted.Sync:DropReasons() or ""
		if reasons ~= "" then
			Add("Dropped: %s", reasons)
		end
	end
	if Wanted.Store and Wanted.db then
		Add("Records flagged: %d tampered (never used), %d broken chain (never a witness)", Wanted.Store:CountFlagged())
		-- Signing (1.19.0): this character's key, the self-test, the keys known and what checks found
		local _, kid = Wanted.Signing:PublicKey()
		Add("Signing: %s, self-test %s", kid and format("key %s (%s seed)", kid, tostring(Wanted.Signing:Source())) or "no key yet", Wanted.Crypto:SelfTestText())
		local origins, keys = Wanted.KeyBook:Count()
		local good, bad, waiting = Wanted.Verify:Counts()
		Add("Signatures: %d keys known for %d players; %d records checked out, %d bad, %d waiting", keys, origins, good, bad, waiting)
	end
	Add("")
	local problems = Wanted:GetProblems()
	Add("Problems this session (%d):", #problems)
	if #problems == 0 then
		Add("  none recorded")
	end
	local names = private.KnownNames()
	for _, problem in ipairs(problems) do
		Add("  %s", private.Scrub(problem, names))
	end
	Add("")
	Add("Last %d log lines (other players' names left out):", LOG_LINES)
	for _, line in ipairs(Wanted:GetLogLines(LOG_LINES)) do
		Add("  %s", private.Scrub(line, names))
	end
	return table.concat(lines, "\n")
end



-- ============================================================================
-- Reports for the developers, sent on by the Wanted app
-- ============================================================================

---Text as it's sent: on one line, without control characters or the game's escape codes (a link pasted in keeps
---its "[Name]"; icons, atlases and the like go whole, and any other "|"), at most maxLetters letters (UTF-8, as the
---app and the server count them, never cut inside one).
---@return string
function private.Clip(text, maxLetters)
	if type(text) ~= "string" then
		return ""
	end
	text = gsub(gsub(text, "|c%x%x%x%x%x%x%x%x", ""), "|r", "")
	text = gsub(gsub(text, "|H.-|h(.-)|h", "%1"), "|T.-|t", "")
	text = gsub(gsub(text, "|A.-|a", ""), "|K.-|k", "")
	text = strtrim((gsub(gsub(gsub(text, "|", ""), "[\r\n]+", " "), "%c", "")))
	-- Each letter starts with a byte that isn't a UTF-8 continuation byte
	local letters = 0
	for at in gmatch(text, "()[^\128-\191]") do
		letters = letters + 1
		if letters > maxLetters then
			return strsub(text, 1, at - 1)
		end
	end
	return text
end

---How many reports are waiting for the app.
function Report:CountQueued()
	local n = 0
	for _ in pairs(Wanted.db.reports) do
		n = n + 1
	end
	return n
end

---Whether the queue is full: nothing more is taken until the app sends what's there.
function Report:IsQueueFull()
	return Report:CountQueued() >= MAX_QUEUED
end

---Puts a report in the queue for the app, under an id no other report has.
---@param report table kind and its fields, and character when it isn't this one; text, at, character and
---addonVersion are filled in here
---@return string? id nil when the queue is full
function Report:Queue(report)
	local queue = Wanted.db.reports
	if Report:IsQueueFull() then
		return nil
	end
	local character = report.character or Wanted.Store:GetOrigin()
	local at = floor(GetServerTime())
	while queue[character..":report:"..at] do
		at = at + 1
	end
	local id = character..":report:"..at
	report.at, report.character, report.addonVersion = at, character, tostring(Wanted.VERSION)
	report.text = private.Clip(report.text, MAX_TEXT)
	queue[id] = report
	Wanted:Log("Report %s waiting for the Wanted app (%d waiting)", id, Report:CountQueued())
	return id
end

---Queues a duel tip the player says looks wrong, with the duel's classes, specs and level, in the name of the
---character who fought it (the account's duels are all listed on any of its characters).
---@param duel table
---@param finding table the report's finding the tip belongs to
---@param text string? what the player said
---@return string? id
function Report:QueueTip(duel, finding, text)
	local Duels = Wanted.Duels
	local me, them = Duels:Side(duel, "me"), Duels:Side(duel, "them")
	local function Name(value)
		return type(value) == "string" and Wanted.Store:CleanName(value) or nil
	end
	return Report:Queue({
		kind = "tip",
		character = type(duel.id) == "string" and strmatch(duel.id, "^(.+):duel:%d+$") or nil,
		text = text,
		duelId = duel.id,
		rule = type(finding.rule) == "string" and private.Clip(finding.rule, MAX_RULE) or nil,
		tip = private.Clip(type(finding.tip) == "string" and finding.tip or finding.text, MAX_TIP),
		finding = private.Clip(finding.text, MAX_TIP),
		myClass = Name(me.class),
		mySpec = Name(me.spec),
		theirClass = Name(them.class),
		theirSpec = Name(them.spec),
		myLevel = type(me.level) == "number" and me.level or nil,
	})
end

---Queues a bug report: what the player said and a log of at most 40 lines and 8 KB (each line and its break, as the
---app and the server count it), other players' names left out. This session's newest problems the recent lines
---don't have come first, then the recent lines, oldest first; the oldest recent lines go first to make room.
---@param text string
---@return string? id
function Report:QueueBug(text)
	local names = private.KnownNames()
	local log, logged = {}, {}
	for _, line in ipairs(Wanted:GetLogLines(LOG_LINES)) do
		line = private.Scrub(line, names)
		tinsert(log, line)
		logged[line] = true
	end
	-- A problem is logged as "<time> Problem: <text>" too: one still in the recent lines isn't sent twice
	local problems, all = {}, Wanted:GetProblems()
	for i = #all, 1, -1 do
		local at, what = strmatch(all[i], "^(%S+) (.*)$")
		local line = private.Scrub(format("%s Problem: %s", at or "", what or all[i]), names)
		if #problems < MAX_PROBLEM_LINES and not logged[line] then
			tinsert(problems, 1, line)
		end
	end
	local bytes = 0
	for _, line in ipairs(problems) do
		bytes = bytes + #line + 1
	end
	for _, line in ipairs(log) do
		bytes = bytes + #line + 1
	end
	while #log > 0 and (#problems + #log > LOG_LINES or bytes > MAX_LOG_BYTES) do
		bytes = bytes - #tremove(log, 1) - 1
	end
	while #problems > 0 and bytes > MAX_LOG_BYTES do
		bytes = bytes - #tremove(problems, 1) - 1
	end
	for i, line in ipairs(problems) do
		tinsert(log, i, line)
	end
	return Report:Queue({ kind = "bug", text = text, log = log })
end

---Lets go the reports the app says it has sent on (the catch-up's reportsReceived, read at every login).
---@param ids table? a list of report ids
function Report:TakeReceived(ids)
	if type(ids) ~= "table" then
		return
	end
	local removed = 0
	for _, id in ipairs(ids) do
		if type(id) == "string" and Wanted.db.reports[id] then
			Wanted.db.reports[id] = nil
			removed = removed + 1
		end
	end
	if removed > 0 then
		Wanted:Log("Catch-up: the Wanted app sent on %d reports", removed)
	end
end

-- The first desktop app that sends reports on
Report.MIN_APP = "0.2.46"

---What happens to a report now, by whether the app is set up, new enough and running.
function private.SentText()
	local version = Wanted:AppVersion()
	if not version then
		return "Thanks. It waits until the Wanted app runs on this PC (wanteddeadordead.com/app), then goes to the developers after a /reload or logout."
	elseif Wanted:IsNewerVersion(Report.MIN_APP, version) then
		return format("Thanks. It waits until the Wanted app is updated to %s or newer (you have %s): update it from its tray menu, then it goes to the developers after a /reload or logout.",
			Report.MIN_APP, Theme:Plain(version))
	elseif Wanted:AppNotRunningFor() then
		return "Thanks. The Wanted app isn't running, so it waits until you start it, then goes to the developers after a /reload or logout."
	end
	return "Thanks. It goes to the developers next time the Wanted app syncs (after a /reload or logout)."
end

---Where a bug report goes from here, for the report window: whether the app sends it, or what it waits for.
---@return string text
---@return table color
function private.AppText()
	local version = Wanted:AppVersion()
	if not version then
		return "A report waits until the Wanted app is running on this PC. Get it at wanteddeadordead.com/app.", C.amber
	elseif Wanted:IsNewerVersion(Report.MIN_APP, version) then
		return format("A report waits until the Wanted app is updated to %s or newer (you have %s): update it from its tray menu or wanteddeadordead.com/app.",
			Report.MIN_APP, Theme:Plain(version)), C.amber
	elseif Wanted:AppNotRunningFor() then
		return "The Wanted app isn't running: a report waits until you start it. Get it at wanteddeadordead.com/app.", C.amber
	end
	return "The Wanted app is set up: a report goes the next time it syncs (after a /reload or logout).", C.muted
end

---Tells the player the queue is full, and what gets the app sending.
function private.ShowFull()
	local version = Wanted:AppVersion()
	local todo = "Start the app and /reload"
	if not version then
		todo = "Get the app (wanteddeadordead.com/app), start it and /reload"
	elseif Wanted:IsNewerVersion(Report.MIN_APP, version) then
		todo = format("Update the app to %s or newer from its tray menu (you have %s) and /reload", Report.MIN_APP, Theme:Plain(version))
	end
	W:Dialog({
		title = "Reports waiting",
		text = format("%d reports are already waiting for the Wanted app to send them. %s, then you can send more.", MAX_QUEUED, todo),
		confirmLabel = "OK",
	})
end

---Asks what's wrong, then queues the report and says where it goes.
---@param options table title, text, validate, over (as W:Dialog's), queue(text) -> id?
function private.Ask(options)
	-- A second click while it asks does nothing (it would wait its turn behind this one)
	if W:IsDialogShown() then
		return
	end
	if Report:IsQueueFull() then
		private.ShowFull()
		return
	end
	W:Dialog({
		title = options.title,
		text = options.text,
		width = 440,
		over = options.over,
		input = { multiline = true, maxLetters = MAX_TEXT },
		confirmLabel = "Send",
		validate = options.validate,
		onConfirm = function(text)
			if not options.queue(text) then
				private.ShowFull()
				return
			end
			W:Dialog({ title = "Report saved", text = private.SentText(), confirmLabel = "OK" })
		end,
	})
end

---Asks the player what looks wrong with a duel's tip, and queues it for the developers.
---@param duel table
---@param finding table
function Report:AskAboutTip(duel, finding)
	private.Ask({
		title = "Something not right?",
		text = "Tell the developers what looks wrong with this tip, if you like. The tip and both sides' classes and specs go with it.",
		queue = function(text) return Report:QueueTip(duel, finding, text) end,
	})
end

---Asks the player what happened, and queues a bug report for the developers.
function Report:AskAboutBug()
	private.Ask({
		title = "Send to the developers",
		over = private.frame,
		text = "What happened, and what did you expect? Wanted's last 40 log lines go with it, other players' names left out.",
		validate = function(text)
			return private.Clip(text, MAX_TEXT) == "" and "Say what happened first." or nil
		end,
		queue = function(text) return Report:QueueBug(text) end,
	})
end



-- ============================================================================
-- Report window
-- ============================================================================

function private.Create()
	local frame = CreateFrame("Frame", "WantedBugReport", UIParent)
	frame:SetSize(620, 156)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetClampedToScreen(true)
	Theme:Skin(frame, C.panel, C.borderLight)
	tinsert(UISpecialFrames, "WantedBugReport")
	frame:Hide()
	local bar = frame:CreateTexture(nil, "ARTWORK")
	bar:SetPoint("TOPLEFT", 1, -1)
	bar:SetPoint("TOPRIGHT", -1, -1)
	bar:SetHeight(3)
	bar:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)
	local title = Theme:Text(frame, "heading", "Report a bug")
	title:SetPoint("TOPLEFT", 20, -20)
	local close = W:Button(frame, "X", "ghost", 28, 28, function() frame:Hide() end)
	close:SetPoint("TOPRIGHT", -8, -8)
	-- The app sends it on: the player only says what happened
	local send = W:Button(frame, "Send to the developers", "primary", 180, 28, function() Report:AskAboutBug() end)
	send:SetPoint("TOPRIGHT", -20, -44)
	local sendNote = Theme:Text(frame, "body", "Say what happened and the Wanted app sends it, with the recent log.", C.text)
	sendNote:SetPoint("TOPLEFT", 20, -51)
	sendNote:SetPoint("RIGHT", send, "LEFT", -12, 0)
	sendNote:SetWordWrap(true)
	-- Whether the app will send it, or what the report waits for (set at each Show)
	local appNote = Theme:Text(frame, "small", "")
	appNote:SetPoint("TOPLEFT", 20, -84)
	appNote:SetPoint("RIGHT", -20, 0)
	appNote:SetWordWrap(true)
	local note = Theme:Text(frame, "tiny", "Also useful: a screenshot, and the exact red error text if the game showed one.")
	note:SetPoint("BOTTOMLEFT", 20, 18)
	frame.appNote = appNote
	private.frame = frame
end

---Opens the report window, saying where a report goes from here.
function Report:Show()
	if not private.frame then
		private.Create()
	end
	local text, color = private.AppText()
	private.frame.appNote:SetText(text)
	private.frame.appNote:SetTextColor(color[1], color[2], color[3])
	private.frame:Show()
end

Wanted:RegisterCommand("bug", "Opens a bug report to send to the developers.", function()
	Report:Show()
end)



-- ============================================================================
-- Beta welcome
-- ============================================================================

---Shown once per version the first time the main window opens with no other dialog up.
function Report:MaybeWelcome()
	local db = Wanted.db
	if not Wanted.BETA or db.welcomed == Wanted.VERSION or W:IsDialogShown() then
		return
	end
	db.welcomed = Wanted.VERSION
	C_Timer.After(0.2, function()
		if W:IsDialogShown() then
			db.welcomed = nil -- another came up meanwhile: next time
			return
		end
		W:Dialog({
			title = "Welcome, bounty hunter",
			text = "Thanks for trying the Wanted: Dead or... Dead beta. If anything looks off, Report a bug in the title bar (or /wanted bug) sends the details to the developers through the Wanted app.",
			confirmLabel = "Let's hunt",
		})
	end)
end
