-- Wanted: bug reports and the beta welcome. An addon can't open a web page or send anything outside the
-- game, so a report the player sends (a bug, or a duel tip that looks wrong) waits in the saved data for the
-- desktop app to pass on to the developers. "Report a bug" also builds a ready-made report to copy, with the
-- address to paste it at.

local _, Wanted = ...
local Report = Wanted:NewModule("Report")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local private = { frame = nil }
local LOG_LINES = 40
local MIN_NAME = 2 -- shorter names aren't looked for
-- Reports waiting for the app (docs/DATA.md): the most kept, how long one waits, and the most each part may be (bytes)
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

---A line with other players left out: GUIDs (any case), the names Wanted knows (with a realm or not), any other
---"Name-Realm", and this realm's name. The log names whoever a message came from or was about; the report shouldn't.
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

---The report text: versions, settings that matter, network state, problems this session, recent log.
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
---its "[Name]"; any other "|" goes), at most maxBytes and never cut inside a letter.
---@return string
function private.Clip(text, maxBytes)
	if type(text) ~= "string" then
		return ""
	end
	text = gsub(gsub(text, "|c%x%x%x%x%x%x%x%x", ""), "|r", "")
	text = gsub(gsub(text, "|H.-|h(.-)|h", "%1"), "|T.-|t", "")
	text = strtrim((gsub(gsub(gsub(text, "|", ""), "[\r\n]+", " "), "%c", "")))
	if #text > maxBytes then
		local cutInside = (text:byte(maxBytes + 1) or 0) >= 128 and text:byte(maxBytes + 1) < 192
		text = strsub(text, 1, maxBytes)
		if cutInside then
			text = gsub(text, "[\192-\255][\128-\191]*$", "")
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
---@param report table kind and its fields; text, at, character and addonVersion are filled in here
---@return string? id nil when the queue is full
function Report:Queue(report)
	local queue = Wanted.db.reports
	if Report:IsQueueFull() then
		return nil
	end
	local character = Wanted.Store:GetOrigin()
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

---Queues a duel tip the player says looks wrong, with the duel's classes, specs and level.
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

---Queues a bug report: what the player said and the last 40 log lines (other players' names left out), oldest
---first, the oldest dropped past 8 KB.
---@param text string
---@return string? id
function Report:QueueBug(text)
	local names = private.KnownNames()
	local log, bytes = {}, 0
	for _, line in ipairs(Wanted:GetLogLines(LOG_LINES)) do
		line = private.Scrub(line, names)
		tinsert(log, line)
		bytes = bytes + #line
	end
	while #log > 0 and bytes > MAX_LOG_BYTES do
		bytes = bytes - #tremove(log, 1)
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

---What happens to a report now, by whether the app is running.
function private.SentText()
	if not Wanted:AppVersion() then
		return "Thanks. It waits until the Wanted app runs on this PC (wanteddeadordead.com/app), then goes to the developers after a /reload or logout."
	elseif Wanted:AppNotRunningFor() then
		return "Thanks. The Wanted app isn't running, so it waits until you start it, then goes to the developers after a /reload or logout."
	end
	return "Thanks. It goes to the developers next time the Wanted app syncs (after a /reload or logout)."
end

---Tells the player the queue is full.
function private.ShowFull()
	W:Dialog({
		title = "Reports waiting",
		text = format("%d reports are already waiting for the Wanted app to send them. Start the app and /reload, then you can send more.", MAX_QUEUED),
		confirmLabel = "OK",
	})
end

---Asks what's wrong, then queues the report and says where it goes.
---@param options table title, text, validate (as W:Dialog's), queue(text) -> id?
function private.Ask(options)
	if Report:IsQueueFull() then
		private.ShowFull()
		return
	end
	W:Dialog({
		title = options.title,
		text = options.text,
		width = 440,
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

local function ReadOnlyBox(parent, getText)
	local box = CreateFrame("EditBox", nil, parent)
	box:SetAutoFocus(false)
	box:SetFontObject(Theme.Fonts.small)
	box:SetScript("OnEscapePressed", box.ClearFocus)
	box:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			self:SetText(getText())
			self:HighlightText()
		end
	end)
	box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	return box
end

function private.Create()
	local frame = CreateFrame("Frame", "WantedBugReport", UIParent)
	frame:SetSize(620, 526)
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
	local copyLabel = W:SectionLabel(frame, "Or copy it for GitHub")
	copyLabel:SetPoint("TOPLEFT", 20, -88)
	local steps = Theme:Text(frame, "body", "", C.text)
	steps:SetPoint("TOPLEFT", 20, -106)
	steps:SetPoint("RIGHT", -20, 0)
	steps:SetWordWrap(true)
	steps:SetText("1. Copy the address below (click it, Ctrl+C) and open it in a browser.\n2. Choose \"Bug report\", say what happened and what you expected.\n3. Click the report box, Ctrl+A, Ctrl+C, and paste it into the form.")
	local urlBox = ReadOnlyBox(frame, function() return Wanted.ISSUES_URL end)
	urlBox:SetSize(580, 26)
	urlBox:SetPoint("TOPLEFT", 20, -170)
	urlBox:SetTextInsets(9, 9, 0, 0)
	Theme:Skin(urlBox, C.input, C.accent)
	urlBox:SetText(Wanted.ISSUES_URL)
	local label = W:SectionLabel(frame, "Report (nothing personal: versions, settings, errors and the recent log)")
	label:SetPoint("TOPLEFT", 20, -210)
	local holder = CreateFrame("Frame", nil, frame)
	holder:SetPoint("TOPLEFT", 20, -228)
	holder:SetPoint("BOTTOMRIGHT", -20, 52)
	Theme:Skin(holder, C.input, C.border)
	local scroll = CreateFrame("ScrollFrame", nil, holder, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 8, -8)
	scroll:SetPoint("BOTTOMRIGHT", -28, 8)
	local reportBox = ReadOnlyBox(scroll, function() return private.text or "" end)
	reportBox:SetMultiLine(true)
	reportBox:SetWidth(540)
	scroll:SetScrollChild(reportBox)
	local refresh = W:Button(frame, "Refresh", "ghost", 90, 28, function() Report:Show() end)
	refresh:SetPoint("BOTTOMLEFT", 20, 14)
	local note = Theme:Text(frame, "tiny", "Also useful: a screenshot, and the exact red error text if the game showed one.")
	note:SetPoint("LEFT", refresh, "RIGHT", 12, 0)
	frame.reportBox = reportBox
	private.frame = frame
end

---Opens the report window with a fresh report.
function Report:Show()
	if not private.frame then
		private.Create()
	end
	private.text = Report:Build()
	private.frame.reportBox:SetText(private.text)
	private.frame.reportBox:SetCursorPosition(0)
	private.frame:Show()
end

Wanted:RegisterCommand("bug", "Opens a bug report to send to the developers or copy.", function()
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
			text = "Thanks for trying the Wanted: Dead or... Dead beta. If anything looks off, Report a bug in the title bar (or /wanted bug) puts together the details and shows where to send them.",
			confirmLabel = "Let's hunt",
		})
	end)
end
