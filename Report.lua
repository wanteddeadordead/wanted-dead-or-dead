-- Wanted: bug reports and the beta welcome. An addon can't open a web page or send anything outside the
-- game, so "Report a bug" builds a ready-made report to copy, with the address to paste it at.

local _, Wanted = ...
local Report = Wanted:NewModule("Report")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local private = { frame = nil }
local LOG_LINES = 40

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
		Add("Network: channel %s, peers %d, sent %d, received %d, merged %d, invalid %d, dropped %d%s", info.channelId and ("#"..info.channelId) or "not joined", info.peers, stats.sent, stats.received, stats.merged, stats.invalid, stats.dropped, info.paused and ", PAUSED" or "")
	end
	Add("")
	local problems = Wanted:GetProblems()
	Add("Problems this session (%d):", #problems)
	if #problems == 0 then
		Add("  none recorded")
	end
	for _, problem in ipairs(problems) do
		Add("  %s", problem)
	end
	Add("")
	Add("Last %d log lines:", LOG_LINES)
	for _, line in ipairs(Wanted:GetLogLines(LOG_LINES)) do
		Add("  %s", line)
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

---Shown once per version the first time the main window opens.
function Report:MaybeWelcome()
	local db = Wanted.db
	if not Wanted.BETA or db.welcomed == Wanted.VERSION then
		return
	end
	db.welcomed = Wanted.VERSION
	C_Timer.After(0.2, function()
		W:Dialog({
			title = "Welcome, hunter",
			text = "Thanks for trying the Wanted: Dead or... Dead beta. If anything looks off, Report a bug in the title bar (or /wanted bug) puts together the details and shows where to send them.",
			confirmLabel = "Let's hunt",
		})
	end)
end
