-- Wanted: bug reports and the beta welcome. An addon can't open a web page or send anything outside the
-- game, so "Report a bug" builds a ready-made report to copy, with the address to paste it at.

local _, Wanted = ...
local Report = Wanted:NewModule("Report")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local private = { frame = nil }
local LOG_LINES = 40
local MIN_NAME = 2 -- shorter names aren't looked for

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
	frame:SetSize(620, 470)
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
	local steps = Theme:Text(frame, "body", "", C.text)
	steps:SetPoint("TOPLEFT", 20, -46)
	steps:SetPoint("RIGHT", -20, 0)
	steps:SetWordWrap(true)
	steps:SetText("1. Copy the address below (click it, Ctrl+C) and open it in a browser.\n2. Choose \"Bug report\", say what happened and what you expected.\n3. Click the report box, Ctrl+A, Ctrl+C, and paste it into the form.")
	local urlBox = ReadOnlyBox(frame, function() return Wanted.ISSUES_URL end)
	urlBox:SetSize(580, 26)
	urlBox:SetPoint("TOPLEFT", 20, -110)
	urlBox:SetTextInsets(9, 9, 0, 0)
	Theme:Skin(urlBox, C.input, C.accent)
	urlBox:SetText(Wanted.ISSUES_URL)
	local label = W:SectionLabel(frame, "Report (nothing personal: versions, settings, errors and the recent log)")
	label:SetPoint("TOPLEFT", 20, -150)
	local holder = CreateFrame("Frame", nil, frame)
	holder:SetPoint("TOPLEFT", 20, -168)
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

Wanted:RegisterCommand("bug", "Opens a bug report you can copy and send.", function()
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
