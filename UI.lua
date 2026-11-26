-- Wanted: the main window. A title bar with the connection state, a sidebar of pages with a badge for
-- what needs the player, a page header, and a status line for the result of the last action.

local _, Wanted = ...
local UI = Wanted:NewModule("UI")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local private = {
	frame = nil,
	pages = {}, -- ordered page definitions
	pageByKey = {},
	current = nil, -- the page shown; the last one shown (settings.lastPage) when the window first opens
	refreshQueued = false,
	toastTimer = nil,
}
-- EllesmereUI's window size: 1300 by 946 screen pixels, which is 1090 by 795 at the usual UI scale (2026-10-17)
local WIDTH, HEIGHT = 1090, 795
local TITLE_HEIGHT = 48
local SIDEBAR_WIDTH = 188
local CONTENT_PAD = 22
local HEADER_HEIGHT = 58
local BARE_HEADER = 38 -- a page with its title or tabs but no subtitle: the subtitle's line goes back to the page
local FOOTER_HEIGHT = 30
local NAV_HEIGHT = 34
local FOOT_TOP = 136 -- the top of the menu's foot (Safety, Suggest a feature, Report a bug): a page at the foot sits on it
local GROUP_HEIGHT = 26
local SIZE_CONTROL_WIDTH = 130 -- the title bar's size slider and its box
local TITLE_GAP = 16 -- between the title bar's brand, tagline, size control and lights
local TAB_ROW = 38 -- a page without a header that has tabs: they take this much off its top
-- The menu is one short list (Dashboard, Guild Wars, Bounties, Enemies, Raids, Progress, You): every other page is a tab of one of
-- them (under), so the menu has no group headings. A page's group is kept only as a note of where it belongs.
local GROUPS = {}



-- ============================================================================
-- Pages
-- ============================================================================

---Registers a page.
---@param key string
---@param def table title, subtitle (a string, or a function returning one for a subtitle that changes), order, group
---(one of GROUPS), noHeader (the page takes the header's room too),
---build(container, width, height), refresh(), badge() -> number|string?, color?; tabs (page keys shown as tabs in
---the header, the first opened from the menu), under (the page whose menu entry and tabs this page is one of, kept
---out of the menu itself), tabLabel (its tab's label, or a function returning it for a tab named by what it shows), tabTip = { title, body } (its tab's tooltip: what the page is, now
---that pages have no subtitle), menuLabel (its menu entry's label, when not its title), atFoot (its menu entry at the
---foot of the menu, above Safety, rather than in the list)
---def.news = { kind, ids = function() -> ids } marks a page whose items count as new until it shows them: its badge is
---that count, in blue, unless it has its own.
function UI:RegisterPage(key, def)
	def.key = key
	if def.news and not def.badge then
		def.badge = function()
			local new = UI:NewCount(def.news.kind, def.news.ids())
			return new > 0 and new or nil, C.blue
		end
	end
	tinsert(private.pages, def)
	private.pageByKey[key] = def
	sort(private.pages, function(a, b) return a.order < b.order end)
end

---How much of the content's top a page's header takes.
function private.HeaderHeight(def)
	return def.noHeader and 0 or def.subtitle and HEADER_HEIGHT or BARE_HEADER
end

---The size a page has to lay itself out in.
---@param noHeader boolean? for a page without the title and subtitle
---@return number width
---@return number height (a page with tabs along its top gets less: build is given its real size)
function UI:GetPageSize(noHeader)
	return WIDTH - SIDEBAR_WIDTH - CONTENT_PAD * 2, HEIGHT - TITLE_HEIGHT - CONTENT_PAD - (noHeader and 0 or HEADER_HEIGHT) - FOOTER_HEIGHT
end



-- ============================================================================
-- Lifecycle
-- ============================================================================

function UI:OnEnable()
	-- Enemies appearing, leaving and list changes (not the once-a-second updates of ones already listed)
	-- A list change (Kill on Sight, ignored) is the player's doing; the rest arrives by itself (IsPassiveRefresh)
	Wanted.Enemies:OnChange(function(event)
		if event ~= "update" then
			private.QueueRefresh(event ~= "lists")
		end
	end)
	for _, kind in ipairs({ "bounty", "claim", "confirm", "payment", "raise", "pass", "death", "kill", "mark", "withdraw", "hunt", "sighting" }) do
		Wanted.Store:OnRecord(kind, function() private.QueueRefresh(true) end)
	end
end

---Whether the refresh under way is one nothing the player did asked for: the 15-second tick, or a record or an enemy
---arriving. A page whose rows are costly to build (Enemies: every enemy known, described and sorted, over 100 ms with
---3,000 of them) keeps the rows it has through these, and builds them when it's opened or the player changes
---something.
---@return boolean
function UI:IsPassiveRefresh()
	return private.passive == true
end

function private.PassiveRefresh()
	private.passive = true
	local ok, err = pcall(UI.Refresh, UI)
	private.passive = nil
	if not ok then
		error(err, 0)
	end
end

---@param passive boolean? nothing the player did asks for it (IsPassiveRefresh); one that isn't, queued with it, wins
function private.QueueRefresh(passive)
	if not private.frame or not private.frame:IsShown() then
		return
	end
	if not passive then
		private.queuedActive = true
	end
	if private.refreshQueued then
		return
	end
	private.refreshQueued = true
	C_Timer.After(0.15, Wanted:Timed("Window refresh", function()
		private.refreshQueued = false
		local active = private.queuedActive
		private.queuedActive = nil
		if not active then
			private.PassiveRefresh()
			return
		end
		UI:Refresh()
	end))
end

---The window frame (created on first use).
function UI:GetFrame()
	if not private.frame then
		private.Create()
	end
	return private.frame
end



-- ============================================================================
-- Building the window
-- ============================================================================

function private.Create()
	-- The theme first: everything below takes its colours
	local theme = Theme:Apply(Wanted.db.settings.theme)
	local frame = CreateFrame("Frame", "WantedFrame", UIParent)
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	Theme:Skin(frame, C.bg, C.borderLight)
	-- The theme's felt under everything, darkened, with its emblem showing through the see-through panels; a shadow
	-- along the top and bottom edges
	frame.felt = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
	frame.felt:SetPoint("TOPLEFT", 1, -1)
	frame.felt:SetPoint("BOTTOMRIGHT", -1, 1)
	frame.felt:SetTexture(Theme:FeltFile(theme))
	frame.felt:SetVertexColor(theme.shade, theme.shade, theme.shade, 1)
	for _, edge in ipairs({ "TOP", "BOTTOM" }) do
		local shadow = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
		shadow:SetPoint(edge.."LEFT", 1, edge == "TOP" and -1 or 1)
		shadow:SetPoint(edge.."RIGHT", -1, edge == "TOP" and -1 or 1)
		shadow:SetHeight(140)
		shadow:SetColorTexture(1, 1, 1, 1)
		if shadow.SetGradient and CreateColor then
			local dark, clear = CreateColor(0, 0, 0, 0.55), CreateColor(0, 0, 0, 0)
			if edge == "TOP" then
				shadow:SetGradient("VERTICAL", clear, dark)
			else
				shadow:SetGradient("VERTICAL", dark, clear)
			end
		else
			shadow:Hide()
		end
	end
	private.theme = theme
	-- Its size first: the saved place is in the window's own units at that size
	frame:SetScale(private.PixelBase() * UI:GetScale())
	local saved = Wanted.db.settings.window
	if saved and saved.point then
		frame:SetPoint(saved.point, UIParent, saved.point, saved.x, saved.y)
	else
		frame:SetPoint("CENTER")
	end
	frame:Hide()
	tinsert(UISpecialFrames, "WantedFrame")
	frame:SetScript("OnShow", function()
		-- The game's UI scale or the screen may have changed since: the same size in screen pixels
		private.ApplyScale()
		UI:Refresh(true)
		-- Keep "4m ago" style times and the connection state current while the window is open
		private.ticker = C_Timer.NewTicker(15, Wanted:Timed("Window refresh", private.PassiveRefresh))
	end)
	frame:SetScript("OnHide", function()
		if private.ticker then
			private.ticker:Cancel()
			private.ticker = nil
		end
	end)
	private.frame = frame
	frame:RegisterEvent("UI_SCALE_CHANGED")
	frame:RegisterEvent("DISPLAY_SIZE_CHANGED")
	frame:SetScript("OnEvent", function(self)
		if self:IsShown() then
			private.ApplyScale()
		end
	end)
	-- Shift + mouse wheel anywhere on it sizes it (its lists and scrolling areas pass it on: W:PassShiftWheel)
	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(self, delta)
		private.ShiftWheel(self, delta)
	end)

	-- Title bar
	local titleBar = CreateFrame("Frame", nil, frame)
	titleBar:SetPoint("TOPLEFT", 1, -1)
	titleBar:SetPoint("TOPRIGHT", -1, -1)
	titleBar:SetHeight(TITLE_HEIGHT)
	Theme:Fill(titleBar, C.titleBar)
	titleBar:EnableMouse(true)
	titleBar:RegisterForDrag("LeftButton")
	titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
	titleBar:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		local point, _, _, x, y = frame:GetPoint(1)
		Wanted.db.settings.window = { point = point, x = x, y = y }
	end)

	-- The wax seal, as on the website
	local mark = titleBar:CreateTexture(nil, "ARTWORK")
	mark:SetSize(32, 32)
	mark:SetPoint("LEFT", 12, 0)
	mark:SetTexture("Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\seal")
	local brand = titleBar:CreateFontString(nil, "ARTWORK", "WantedFontDisplay")
	local function Brand()
		brand:SetText(Theme:Colorize("WANTED:", C.accent).." "..Theme:Colorize("DEAD OR...", C.text).." "..Theme:Colorize("DEAD", C.red))
	end
	Brand()
	-- Another theme chosen: what holds its colours in text (the brand, the menu's selected entry, the pages) is drawn
	-- again, and the felt changes
	Theme:OnApplied(function(applied)
		Brand()
		UI:PreviewTheme(applied.key)
		if frame:IsShown() then
			UI:Refresh(true)
		end
	end)
	brand:SetPoint("LEFT", mark, "RIGHT", 8, 1)
	-- Under heavy development through the WoW Forever beta (Wanted.BETA): a tag beside the brand says so, its tooltip how
	local anchor = brand
	private.betaWidth = 0
	if Wanted.BETA then
		local beta = W:Pill(titleBar)
		beta:Set("BETA", C.amber)
		beta:SetPoint("LEFT", brand, "RIGHT", 10, 0)
		W:Explain(beta, "Beta", "Wanted is under heavy development through the WoW Forever beta. Expect frequent updates, and possible issues while we work through the game's changes.", "ANCHOR_BOTTOM")
		anchor = beta
		private.betaWidth = 10 + beta:GetWidth()
	end
	local tagline = Theme:Text(titleBar, "small", "World PvP bounties, player to player")
	tagline:SetPoint("LEFT", anchor, "RIGHT", 12, -1)

	local close = W:Button(titleBar, "X", "ghost", 30, 30, function() frame:Hide() end)
	close:SetPoint("RIGHT", -10, 0)
	W:AttachTooltip(close, "Close", "Escape also closes the window.")

	-- Two status lights: the desktop app, and the in-game WantedNet channel. No player count: an empty count
	-- early on only tells people nobody uses Wanted.
	local function Indicator(width, onClick)
		local light = CreateFrame("Button", nil, titleBar)
		light:SetSize(width, 30)
		light.dot = light:CreateTexture(nil, "ARTWORK")
		light.dot:SetSize(8, 8)
		light.text = Theme:Text(light, "small", "")
		light.text:SetPoint("RIGHT", 0, 0)
		light.text:SetJustifyH("RIGHT")
		light.dot:SetPoint("RIGHT", light.text, "LEFT", -8, 0)
		light:SetScript("OnClick", onClick)
		light:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
			GameTooltip:SetText(self.tooltipTitle or "", 1, 1, 1)
			GameTooltip:AddLine(self.tooltipText or "", C.muted[1], C.muted[2], C.muted[3], true)
			GameTooltip:Show()
		end)
		light:SetScript("OnLeave", function() GameTooltip:Hide() end)
		return light
	end
	private.netStatus = Indicator(150, function()
		UI:Show(Wanted.db.settings.showTools and "tools" or "settings")
	end)
	private.netStatus:SetPoint("RIGHT", close, "LEFT", -10, 0)
	private.appStatus = Indicator(140, function() UI:Show("web") end)
	private.appStatus:SetPoint("RIGHT", private.netStatus, "LEFT", -6, 0)
	-- The window's size, left of the lights; the same as Settings, Theme: UI size
	local size = W:SizeSlider(titleBar, SIZE_CONTROL_WIDTH, UI.SCALE_LOW, UI.SCALE_HIGH, function(scale, slider)
		UI:SetScale(scale, slider.thumb)
	end)
	size:SetPoint("RIGHT", private.appStatus, "LEFT", -TITLE_GAP, 0)
	size:SetValue(UI:GetScalePercent())
	W:Explain(size.slider, "Window size", "This window's size, with its popups and menus. Shift + mouse wheel over the window changes it too, in 5% steps; Settings, Theme has it as UI size.", "ANCHOR_BOTTOM")
	UI:OnScaleChanged(function(percent)
		if not size.pending then
			size:SetValue(percent)
		end
	end)
	private.sizeControl, private.brand, private.tagline, private.close = size, brand, tagline, close

	-- Sidebar
	local sidebar = CreateFrame("Frame", nil, frame)
	sidebar:SetPoint("TOPLEFT", 1, -TITLE_HEIGHT - 1)
	sidebar:SetPoint("BOTTOMLEFT", 1, 1)
	sidebar:SetWidth(SIDEBAR_WIDTH)
	Theme:Fill(sidebar, C.sidebar)
	local sideLine = sidebar:CreateTexture(nil, "BORDER")
	sideLine:SetPoint("TOPRIGHT")
	sideLine:SetPoint("BOTTOMRIGHT")
	sideLine:SetWidth(1)
	sideLine:SetColorTexture(C.border[1], C.border[2], C.border[3], C.border[4])
	private.navButtons = {}
	private.groupLabels = {}
	for _, group in ipairs(GROUPS) do
		private.groupLabels[group] = W:SectionLabel(sidebar, group)
	end
	for _, def in ipairs(private.pages) do
		local nav = CreateFrame("Button", nil, sidebar)
		nav:SetSize(SIDEBAR_WIDTH - 1, NAV_HEIGHT)
		nav.bg = Theme:Fill(nav, C.transparent)
		-- EllesmereUI's menu entry: shown, a 3px accent bar, the accent fading from 15% across the row and grey lines
		-- fading out along its top and bottom; under the mouse, a faint white fade and a white bar at 25%
		nav.bar = nav:CreateTexture(nil, "ARTWORK")
		nav.bar:SetPoint("TOPLEFT")
		nav.bar:SetPoint("BOTTOMLEFT")
		nav.bar:SetWidth(3)
		Theme:Paint(nav.bar, C.accent, 1)
		nav.edges = {}
		for _, edge in ipairs({ "TOP", "BOTTOM" }) do
			local line = nav:CreateTexture(nil, "BORDER")
			line:SetPoint(edge.."LEFT")
			line:SetPoint(edge.."RIGHT")
			line:SetHeight(1)
			line:SetColorTexture(0.7, 0.7, 0.7, 0.5)
			if line.SetGradient and CreateColor then
				line:SetGradient("HORIZONTAL", CreateColor(0.7, 0.7, 0.7, 0.5), CreateColor(0.7, 0.7, 0.7, 0))
			end
			line:Hide()
			tinsert(nav.edges, line)
		end
		nav.hoverBar = nav:CreateTexture(nil, "ARTWORK")
		nav.hoverBar:SetPoint("TOPLEFT")
		nav.hoverBar:SetPoint("BOTTOMLEFT")
		nav.hoverBar:SetWidth(3)
		nav.hoverBar:SetColorTexture(0.85, 0.95, 0.9, 0.25)
		nav.hoverBar:Hide()
		nav.label = Theme:Text(nav, "body", def.menuLabel or def.title)
		nav.label:SetSpacing(0)
		nav.label:SetPoint("LEFT", 22, 0)
		nav.badge = W:Pill(nav)
		nav.badge:SetPoint("RIGHT", -14, 0)
		nav.key = def.key
		nav:SetScript("OnClick", function() UI:Show(private.FirstTab(def)) end)
		nav:SetScript("OnEnter", function(self)
			if (private.owner or private.current) ~= self.key then
				self.bg:SetColorTexture(1, 1, 1, 0.03)
				if self.bg.SetGradient and CreateColor then
					self.bg:SetGradient("HORIZONTAL", CreateColor(0.85, 0.95, 0.9, 0.03), CreateColor(0.85, 0.95, 0.9, 0))
				end
				self.hoverBar:Show()
				self.label:SetTextColor(C.text[1], C.text[2], C.text[3])
			end
		end)
		nav:SetScript("OnLeave", function(self)
			self.hoverBar:Hide()
			if (private.owner or private.current) ~= self.key then
				self.bg:SetColorTexture(0, 0, 0, 0)
				self.label:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
			end
		end)
		private.navButtons[def.key] = nav
	end
	private.LayoutNav()
	local version = Theme:Text(sidebar, "tiny", Wanted:VersionLabel(Wanted.VERSION).."   /wanted")
	version:SetPoint("BOTTOMLEFT", 22, 14)
	-- Report a bug and Suggest a feature stay in reach with the Tools page hidden, and off the title bar, which the
	-- status lights fill: the foot of the menu, above the version
	local function Foot(label, bottom, onClick, tooltip)
		local row = CreateFrame("Button", nil, sidebar)
		row:SetSize(SIDEBAR_WIDTH - 1, 34)
		row:SetPoint("BOTTOMLEFT", 0, bottom)
		row.bg = Theme:Fill(row, C.transparent)
		row.line = Theme:Line(row)
		row.line:SetPoint("TOPLEFT", 16, 0)
		row.line:SetPoint("TOPRIGHT", -16, 0)
		row.label = Theme:Text(row, "body", label, C.amber)
		row.label:SetPoint("LEFT", 22, 0)
		row:SetScript("OnClick", onClick)
		row:SetScript("OnEnter", function(self) self.bg:SetColorTexture(1, 1, 1, 0.035) end)
		row:SetScript("OnLeave", function(self) self.bg:SetColorTexture(0, 0, 0, 0) end)
		W:AttachTooltip(row, label, tooltip)
		return row
	end
	private.bugButton = Foot("Report a bug", 34, function() Wanted.Report:Show() end,
		"Builds a report to copy (versions, settings, errors, recent log) and shows where to send it. Also /wanted bug.")
	private.ideaButton = Foot("Suggest a feature", 68, function() Wanted.Report:AskAboutIdea() end,
		"Tells the developers what Wanted should do, through the Wanted app. Also /wanted idea.")
	private.safetyButton = Foot("Safety", FOOT_TOP - 34, function() UI:ShowSafety() end,
		"Wanted takes online bullying seriously. What the addon shares and never does, what to do if someone makes you feel unsafe, and where to find help: the website's Safety page. Also /wanted safety.")

	-- Content
	local content = CreateFrame("Frame", nil, frame)
	content:SetPoint("TOPLEFT", SIDEBAR_WIDTH + 1 + CONTENT_PAD, -TITLE_HEIGHT - CONTENT_PAD)
	content:SetPoint("BOTTOMRIGHT", -CONTENT_PAD, 1)
	private.title = Theme:Text(content, "title", "")
	private.title:SetPoint("TOPLEFT", 0, 0)
	private.subtitle = Theme:Text(content, "small", "")
	private.subtitle:SetPoint("TOPLEFT", 0, -30)
	private.subtitle:SetPoint("RIGHT", 0, 0)
	private.subtitle:SetWordWrap(false)
	-- Tabs for pages that share a menu entry: along the top of the header, in place of the title (the tab says which
	-- page this is); the subtitle sits under them
	private.tabBars = {}
	for _, def in ipairs(private.pages) do
		if def.tabs then
			local items = {}
			for _, key in ipairs(def.tabs) do
				local page = private.pageByKey[key]
				local label = page and (page.tabLabel or page.title) or key
				tinsert(items, { key = key, label = type(label) == "function" and (label() or "") or label, tip = page and page.tabTip })
			end
			local bar = W:Tabs(content, items, function(key) UI:Show(key) end, 110)
			bar:SetPoint("TOPLEFT", 0, 0)
			bar:Hide()
			private.tabBars[def.key] = bar
		end
	end
	private.toast = Theme:Text(content, "small", "")
	private.toast:SetPoint("BOTTOMLEFT", 0, 10)
	private.toast:SetPoint("BOTTOMRIGHT", 0, 10)
	local pageWidth, pageHeight = UI:GetPageSize()
	for _, def in ipairs(private.pages) do
		local container = CreateFrame("Frame", nil, content)
		local width, height = UI:GetPageSize(true)
		local header = private.HeaderHeight(def)
		height = height - header
		local owner = def.under and private.pageByKey[def.under] or def
		-- Without a header, a page's tabs sit along its top (Home | Calendar)
		local tabRow = def.noHeader and owner.tabs and TAB_ROW or 0
		container:SetPoint("TOPLEFT", 0, def.noHeader and -tabRow or -header)
		container:SetSize(width, height - tabRow)
		container:Hide()
		def.container = container
		def.build(container, width, height)
	end

	-- Waiting for an update: the pages that share records with other players are covered by this
	local update = CreateFrame("Frame", nil, content)
	update:SetPoint("TOPLEFT", 0, -HEADER_HEIGHT)
	update:SetSize(pageWidth, pageHeight)
	update:SetFrameLevel(content:GetFrameLevel() + 50)
	update:EnableMouse(true)
	Theme:Fill(update, C.bg)
	update.title = Theme:Text(update, "title", "Update required", C.red)
	update.title:SetPoint("TOP", 0, -90)
	update.text = Theme:Text(update, "body", "", C.text)
	update.text:SetPoint("TOP", update.title, "BOTTOM", 0, -14)
	update.text:SetWidth(pageWidth - 120)
	update.text:SetJustifyH("CENTER")
	update.text:SetWordWrap(true)
	update.text:SetSpacing(4)
	update:Hide()
	private.updateCover = update
end

-- Pages that share records with other players: paused while an update is required
local SHARED_PAGES = { board = true, mine = true, hunts = true, hunters = true }

function private.UpdateCover()
	local required = Wanted:GetRequiredUpdate()
	local cover = private.updateCover
	cover:SetShown(required ~= nil and SHARED_PAGES[private.current] or false)
	-- Over the page, under its header
	local header = private.HeaderHeight(private.pageByKey[private.current])
	local width, height = UI:GetPageSize(true)
	cover:SetPoint("TOPLEFT", 0, -header)
	cover:SetSize(width, height - header)
	if required then
		cover.text:SetText(format("Other players are on Wanted %s and you have %s. Bounties, claims, payments and sharing are paused until you update from CurseForge, then /reload.\n\nThe Nearby window, alerts, Enemies, Hotspots, Activity and the map keep working.", required, tostring(Wanted.VERSION)))
	end
end



-- ============================================================================
-- Showing and refreshing
-- ============================================================================

---Shows the window on a page (or the current one: the last one shown, Home the first time).
---@param key string?
function UI:Show(key)
	UI:GetFrame()
	if key and private.pageByKey[key] then
		private.current = key
	end
	-- The first open since login goes to the page remembered, the Dashboard (Home) when there's none: the window opens
	-- on the Dashboard, races or not (the maintainer, 2026-11-21: "open on dash")
	private.current = private.UsablePage(private.current or Wanted.db.settings.lastPage)
	Wanted.db.settings.lastPage = private.current
	for _, def in ipairs(private.pages) do
		def.container:SetShown(def.key == private.current)
	end
	-- Opening it refreshes it (OnShow); an open window is refreshed here, with every badge worked out afresh
	local wasShown = private.frame:IsShown()
	private.frame:Show()
	if wasShown then
		UI:Refresh(true)
	end
end

---The page a menu entry opens: its first tab that isn't switched off (the entry's own page when it has no tabs).
---@param def table
---@return string
function private.FirstTab(def)
	for _, key in ipairs(def.tabs or {}) do
		local page = private.pageByKey[key]
		if page and not (page.hidden and page.hidden()) then
			return key
		end
	end
	return def.key
end

---The page to show for a key: Home when there is no such page, or it's switched off. An entry whose own page is off
---but has tabs left (You without the Calling card) shows its first tab.
---@param key string?
---@return string
function private.UsablePage(key)
	local def = key and private.pageByKey[key]
	if def and def.hidden and def.hidden() and private.FirstTab(def) ~= def.key then
		return private.FirstTab(def)
	end
	if not def or (def.hidden and def.hidden()) then
		-- The main page: the Dashboard
		return "home"
	end
	return key
end

---Places the menu's entries, top to bottom in page order: every page that isn't a tab of another, leaving out pages
---that are switched off.
function private.LayoutNav()
	local y = -12
	for _, def in ipairs(private.pages) do
		local nav = private.navButtons[def.key]
		nav:ClearAllPoints()
		if def.under or (def.hidden and def.hidden() and private.FirstTab(def) == def.key) then
			nav:Hide()
		elseif def.atFoot then
			nav:SetPoint("BOTTOMLEFT", 0, FOOT_TOP)
			nav:Show()
		else
			nav:SetPoint("TOPLEFT", 0, y)
			nav:Show()
			y = y - NAV_HEIGHT
		end
	end
	for _, label in pairs(private.groupLabels) do
		label:Hide()
	end
end

---Safety: the statement, and the website's Safety page to copy (the game can't open a browser). The foot of the
---menu and /wanted safety.
function UI:ShowSafety()
	W:Dialog({
		title = "Safety",
		text = "Wanted: Dead or... Dead takes online bullying seriously. No one should feel unsafe because of this addon. Misuse, griefing or bullying gets you banned from the system.\n\n"
			.."If someone is making you feel unsafe: hide your character on the website, and write to admin@wanteddeadordead.com. The website's Safety page says what the addon shares and never does, and where to find help with online bullying. Copy the address:",
		input = { value = "https://wanteddeadordead.com/safety", copy = true },
		confirmLabel = "Close",
		onConfirm = function() end,
	})
end

Wanted:RegisterCommand("safety", "Wanted takes online bullying seriously: the statement and the website's Safety page: /wanted safety", function()
	UI:ShowSafety()
end)

function UI:Toggle()
	if private.frame and private.frame:IsShown() then
		private.frame:Hide()
	else
		UI:Show()
	end
end

---The menu as shown, top first: { key, label, selected, badge } (for the tests, and anything that needs to know).
---@return table[]
function UI:Menu()
	local out = {}
	for _, def in ipairs(private.pages) do
		local nav = private.navButtons and private.navButtons[def.key]
		if nav and nav:IsShown() then
			tinsert(out, { key = def.key, label = def.menuLabel or def.title, selected = (private.owner or private.current) == def.key,
				badge = private.menuBadges and private.menuBadges[def.key], color = private.menuColors and private.menuColors[def.key] })
		end
	end
	return out
end

---The current page's tabs: { labels, selected }, or nil for a page without tabs.
---@return table?
function UI:Tabs()
	local bar = private.tabBars and private.tabBars[private.owner]
	if not bar then
		return nil
	end
	local labels = {}
	for _, button in ipairs(bar.buttons) do
		if button:IsShown() then
			tinsert(labels, button.label and button.label:GetText() or button:GetText() or button.key)
		end
	end
	return { labels = labels, selected = bar.selected }
end


-- The parts of the window the tour borders (Tour), by name: a function returning the frame, or nil when the page
-- hasn't been built
local marks = {}

local reveals = {}

---Names a frame for the tour: pages register the parts worth pointing at. reveal, if given, brings the frame into
---view first (a page's tab it sits on).
---@param name string
---@param get fun(): table?
---@param reveal fun()?
function UI:Mark(name, get, reveal)
	marks[name], reveals[name] = get, reveal
end

---The frame a mark names, brought into view, if it exists now.
---@param name string
---@return table?
function UI:MarkFrame(name)
	local get = marks[name]
	if not get then
		return nil
	end
	if reveals[name] then
		reveals[name]()
	end
	return get()
end

UI:Mark("app", function() return private.appStatus end)
UI:Mark("net", function() return private.netStatus end)
UI:Mark("setup", function() return Wanted.Setup and Wanted.Setup.cards.home end)

function UI:IsShown(key)
	return private.frame and private.frame:IsShown() and (not key or private.current == key)
end

-- The menu's badges scan every record, and the window refreshes often in a busy fight, so a badge is worked out
-- again at most this often, and only one per refresh, except when the window opens or changes page
local BADGE_SECONDS = 5

---A page's badge and its colour, from the last time it was worked out unless that's stale and this refresh hasn't
---worked one out yet (or all is set).
function private.Badge(page, all)
	private.badges = private.badges or {}
	private.badgeColors = private.badgeColors or {}
	private.badgeAt = private.badgeAt or {}
	local at = private.badgeAt[page.key]
	if all or not at or (not private.badgeDone and GetTime() - at >= BADGE_SECONDS) then
		private.badges[page.key], private.badgeColors[page.key] = page.badge()
		private.badgeAt[page.key] = GetTime()
		private.badgeDone = not all
	end
	return private.badges[page.key], private.badgeColors[page.key]
end

-- ============================================================================
-- New since you looked
-- ============================================================================

---This character's record of what each page last showed: kind -> { [id] = true } (WantedDB.viewed[character]).
function private.ViewedStore()
	local db = Wanted.db
	db.viewed = type(db.viewed) == "table" and db.viewed or {}
	local me = Wanted.Store:GetOrigin() or "?"
	db.viewed[me] = type(db.viewed[me]) == "table" and db.viewed[me] or {}
	return db.viewed[me]
end

---What a page last showed; the first time, everything there is now (so nothing old counts as new).
function private.Viewed(kind, ids)
	local store = private.ViewedStore()
	if type(store[kind]) ~= "table" then
		local set = {}
		for _, id in ipairs(ids) do
			set[id] = true
		end
		store[kind] = set
	end
	return store[kind]
end

---How many of a page's items (ids: bounty ids, zone keys, badges...) it hasn't shown this character yet.
---@param kind string
---@param ids table
---@return number
function UI:NewCount(kind, ids)
	local seen = private.Viewed(kind, ids)
	local n = 0
	for _, id in ipairs(ids) do
		if not seen[id] then
			n = n + 1
		end
	end
	return n
end

---A page has shown its items: they're what it last showed (anything gone drops out, and is new if it comes back).
---Returns whether any were new.
---@param kind string
---@param ids table
---@return boolean
function UI:MarkViewed(kind, ids)
	local seen = private.Viewed(kind, ids)
	local set, changed = {}, false
	for _, id in ipairs(ids) do
		changed = changed or not seen[id]
		set[id] = true
	end
	private.ViewedStore()[kind] = set
	return changed
end

---Redraws the window. allBadges: work every menu badge out afresh (opening the window, changing page).
---@param allBadges boolean?
function UI:Refresh(allBadges)
	-- A closed window isn't drawn: opening it refreshes it, every badge worked out afresh (OnShow)
	if not private.frame or not private.frame:IsShown() then
		return
	end
	private.badgeDone = false
	private.LayoutNav()
	local usable = private.UsablePage(private.current)
	if usable ~= private.current then
		-- Its page was switched off while open
		private.current = usable
		Wanted.db.settings.lastPage = usable
		for _, page in ipairs(private.pages) do
			page.container:SetShown(page.key == private.current)
		end
	end
	local def = private.pageByKey[private.current]
	-- The menu entry and tabs the current page belongs to
	local owner = def.under or def.key
	private.owner = owner
	local tabbed = private.tabBars[owner] ~= nil
	private.title:SetText((def.noHeader or tabbed) and "" or def.title)
	local subtitle = type(def.subtitle) == "function" and def.subtitle() or def.subtitle
	private.subtitle:SetText(def.noHeader and "" or subtitle or "")
	private.subtitle:ClearAllPoints()
	private.subtitle:SetPoint("TOPLEFT", 0, tabbed and -32 or -26)
	private.subtitle:SetPoint("RIGHT", 0, 0)
	for key, bar in pairs(private.tabBars) do
		bar:SetShown(key == owner)
		if key == owner then
			-- A tab whose page is switched off (Tools, a war that's over) isn't shown, and the tabs after it close up; a
			-- tab named by what it shows (a war, by its zone) is named afresh
			local x = 0
			for _, button in ipairs(bar.buttons) do
				local page = private.pageByKey[button.key]
				local shown = not (page and page.hidden and page.hidden())
				button:SetShown(shown)
				if shown then
					if page and type(page.tabLabel) == "function" then
						button:SetText(page.tabLabel() or "")
						-- Refitted to its label (a long zone and a badge), never narrower than it was built
						private.builtWidths = private.builtWidths or setmetatable({}, { __mode = "k" })
						private.builtWidths[button] = private.builtWidths[button] or tonumber(button:GetWidth()) or 0
						if button.label then
							button:SetWidth(max(private.builtWidths[button], ceil(button.label:GetStringWidth()) + 24))
						end
					end
					button:ClearAllPoints()
					button:SetPoint("LEFT", x, 0)
					x = x + button:GetWidth() - 1
				end
			end
			-- The bar as wide as its tabs now
			bar:SetWidth(x + 1)
			if bar.selected ~= private.current then
				bar:Select(private.current, true)
			end
		end
	end
	-- The page shown, with the window open: what it shows isn't new any more, so every count is worked out again
	if def.news and private.frame:IsShown() and UI:MarkViewed(def.news.kind, def.news.ids()) then
		allBadges = true
	end
	-- A menu entry's badge adds up its tabs' counts (a text badge, when no tab has a count, shows as it is), in a to-do's
	-- colour over the blue of what's new
	local function Merge(a, b)
		if a == C.blue then
			return b
		end
		return a
	end
	local underBadges = {}
	for _, page in ipairs(private.pages) do
		if page.under and page.badge then
			local badge, color = private.Badge(page, allBadges)
			local sum = underBadges[page.under]
			if type(badge) == "number" and badge > 0 then
				local counted = sum and type(sum[1]) == "number"
				underBadges[page.under] = { (counted and sum[1] or 0) + badge, counted and Merge(sum[2], color) or color }
			elseif not sum and type(badge) == "string" and badge ~= "" then
				underBadges[page.under] = { badge, color }
			end
		end
	end
	for _, page in ipairs(private.pages) do
		local nav = private.navButtons[page.key]
		local selected = page.key == owner
		nav.bar:SetShown(selected)
		for _, line in ipairs(nav.edges) do
			line:SetShown(selected)
		end
		-- EllesmereUI's selected entry: the accent bar, and the accent fading out to the right
		nav.bg:SetColorTexture(1, 1, 1, selected and 1 or 0)
		if selected and nav.bg.SetGradient and CreateColor then
			nav.bg:SetGradient("HORIZONTAL", CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.16), CreateColor(C.accent[1], C.accent[2], C.accent[3], 0))
		elseif selected then
			nav.bg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.1)
		end
		nav.label:SetTextColor(unpack(selected and C.white or C.muted))
		local badge, color = nil, nil
		if page.badge then
			badge, color = private.Badge(page, allBadges)
		end
		local tabs = underBadges[page.key]
		if tabs and type(tabs[1]) == "number" then
			local own = type(badge) == "number" and badge > 0
			badge, color = (own and badge or 0) + tabs[1], own and Merge(color, tabs[2]) or tabs[2]
		elseif tabs and not badge then
			badge, color = tabs[1], tabs[2]
		end
		private.menuBadges = private.menuBadges or {}
		private.menuBadges[page.key] = badge
		private.menuColors = private.menuColors or {}
		private.menuColors[page.key] = color
		if (type(badge) == "number" and badge > 0) or (type(badge) == "string" and badge ~= "") then
			nav.badge:Set(tostring(badge), color or C.accent)
		else
			nav.badge:Hide()
		end
	end
	if def.refresh then
		def.refresh()
	end
	private.UpdateConnection()
	private.UpdateCover()
end

function private.UpdateConnection()
	if not private.netStatus then
		return
	end
	local function Set(light, color, text, title, tip)
		light.dot:SetColorTexture(color[1], color[2], color[3], 1)
		light.text:SetText(text)
		-- As wide as its text and dot, so a longer label (a development build's counts) pushes the next one along
		-- rather than running under it
		light:SetWidth(ceil(light.text:GetStringWidth() or 0) + 16)
		light.tooltipTitle, light.tooltipText = title, tip
	end
	local info = Wanted.Sync and Wanted.Sync:GetInfo()
	if Wanted:GetRequiredUpdate() then
		Set(private.netStatus, C.red, "Update required", "Update required",
			"Wanted "..Wanted:GetRequiredUpdate().." is out. Update from CurseForge, then /reload.")
	elseif not info or not info.channelId then
		Set(private.netStatus, C.red, "WantedNet", "Not connected to WantedNet",
			"Joining the in-game channel Wanted shares bounties, kills and sightings on. It connects a little after login.")
	elseif info.paused then
		Set(private.netStatus, C.amber, "WantedNet paused", "WantedNet paused",
			"Too much traffic for a moment: sharing resumes shortly.")
	else
		-- Development builds also show how many are in the channel (the game's member list) and how many other
		-- players were heard from in the last 10 minutes; releases don't, so a quiet channel doesn't look like
		-- nobody uses Wanted
		local text, tip = "WantedNet", "Sharing bounties, kills and sightings with other Wanted players in game, in "..info.channelName.."."
		if Wanted.DEV then
			local heard = format("%d heard", info.peers or 0)
			text = info.members and format("WantedNet (%d, %s)", info.members, heard) or format("WantedNet (%s)", heard)
			tip = format("%s\n\n%s in the channel; %d other players heard from in the last 10 minutes. An idle addon only sends when it has something new.",
				tip, info.members and tostring(info.members) or "Not yet known how many are", info.peers or 0)
		end
		Set(private.netStatus, C.green, text, "Connected to WantedNet", tip)
	end
	local app, notRunning = Wanted:AppVersion(), Wanted:AppNotRunningFor()
	if app and notRunning then
		Set(private.appStatus, C.amber, "App not running", "The Wanted app isn't running",
			"It last ran "..Theme:Ago(notRunning).." ago. Start it (Wanted Dead or Dead in the Start menu, or Wanted in Applications on a Mac) so "
				.."your kills reach the website.")
	elseif app then
		-- Development builds also count the apps running across the network
		local apps = Wanted.DEV and Wanted:AppsRunning()
		Set(private.appStatus, C.green, apps and format("App (%d running)", apps) or "App", "The Wanted app is set up",
			"Version "..app..". It puts your records on wanteddeadordead.com and keeps your addon data safe.")
	else
		Set(private.appStatus, C.red, "Get the app", "No Wanted app on this computer",
			"The desktop app puts your kills on wanteddeadordead.com and confirms other players' kills. Click for the link.")
	end
	private.FitTitle()
end

---The title bar's tagline goes when it would run into the size control (a raised Text Size, longer status lights), and
---the size control when even the brand would; Settings and Shift + mouse wheel still size the window then.
function private.FitTitle()
	local brandEnd = 12 + 32 + 8 + private.brand:GetStringWidth() + private.betaWidth
	local lights = 10 + private.close:GetWidth() + 10 + private.netStatus:GetWidth() + 6 + private.appStatus:GetWidth()
	local room = WIDTH - 2 - lights - TITLE_GAP
	local sizeShown = brandEnd + TITLE_GAP + SIZE_CONTROL_WIDTH <= room
	private.sizeControl:SetShown(sizeShown)
	local sizeTakes = sizeShown and SIZE_CONTROL_WIDTH + TITLE_GAP or 0
	private.tagline:SetShown(brandEnd + 12 + private.tagline:GetStringWidth() + sizeTakes <= room)
end

---Shows the result of an action under the page, fading after a while.
---@param text string
---@param color table?
function UI:Toast(text, color)
	if not private.toast then
		return
	end
	color = color or C.muted
	private.toast:SetText(text or "")
	private.toast:SetTextColor(color[1], color[2], color[3])
	private.toast:SetAlpha(1)
	if private.toastTimer then
		private.toastTimer:Cancel()
	end
	private.toastTimer = C_Timer.NewTimer(8, function()
		private.toast:SetText("")
	end)
end

---Runs a chat command and shows what it printed as a toast.
---@param command string
---@param args string?
function UI:Run(command, args)
	local lines = Wanted:CapturePrints(function()
		Wanted:RunCommand(command, args or "")
	end)
	UI:Toast(table.concat(lines, "  "), C.text)
	UI:Refresh()
end



-- ============================================================================
-- Commands
-- ============================================================================

Wanted:RegisterCommand("show", "Opens the window: /wanted show [home|board|mine|hunts|hotspots|enemies|hunters|activity|challenges|web|settings].", function(args)
	local key = strtrim(args or "")
	UI:Show(key ~= "" and key or nil)
end)

Wanted:RegisterCommand("hotspots", "Opens the Hotspots page: where enemy players are right now.", function()
	UI:Show("hotspots")
end)

-- ============================================================================
-- Size
-- ============================================================================

-- The window's size (settings.windowScale) is a share of its size at one unit to one screen pixel, so a size looks
-- the same at any game UI scale and text is drawn on whole pixels at 100%. The player picks 75% to 150% in 5% steps
-- (the title bar's control, Settings and Shift + mouse wheel); a size converted from the old setting can be anything,
-- and is kept until the player changes it.
UI.SCALE_LOW, UI.SCALE_HIGH = 75, 150
local scaleListeners = {}

---The window's scale on UIParent at which one of its units is one screen pixel.
---@return number
function private.PixelBase()
	local _, physicalHeight = GetPhysicalScreenSize()
	local height = UIParent:GetHeight()
	if type(physicalHeight) ~= "number" or physicalHeight <= 0 or type(height) ~= "number" or height <= 0 then
		return 1
	end
	return height / physicalHeight
end

---A saved size as it can be used: a number from 25% to 400%, else nil.
function private.SaneScale(scale)
	scale = tonumber(scale)
	if not scale or scale ~= scale or scale < 0.25 or scale > 4 then
		return nil
	end
	return scale
end

---A fresh install's size: the window's look at the size it was drawn for (1440 pixels high at a UI scale of 0.64,
---1.2 screen pixels a unit: 120%), as the same share of a taller or shorter screen, from 100% (so text is never drawn
---smaller than its size) to 150%.
function private.DefaultScale()
	local _, physicalHeight = GetPhysicalScreenSize()
	if type(physicalHeight) ~= "number" or physicalHeight <= 0 then
		return 1
	end
	local percent = floor(physicalHeight / 1200 * 100 / Theme.SIZE_STEP + 0.5) * Theme.SIZE_STEP
	return max(100, min(UI.SCALE_HIGH, percent)) / 100
end

---The size the window had before sizes were in screen pixels (up to 1.30.0): settings.uiScale on UIParent, 80% to
---150%, and never made smaller than 100% to fit the screen.
function private.OldScale(uiScale)
	local room = min(UIParent:GetWidth() / WIDTH, UIParent:GetHeight() / HEIGHT)
	room = floor(room * 100 / Theme.SIZE_STEP) * Theme.SIZE_STEP / 100
	return min(Theme:ClampScale(uiScale), max(1, room))
end

---The size saved for the window. Once, the first time the window is made after the update: the old setting
---(settings.uiScale, a scale on UIParent) is turned into the size that keeps the window as large on screen as it was;
---a save without one (a fresh install) takes DefaultScale. settings.windowScale being there marks it done.
---@return number
function private.SavedScale()
	local settings = Wanted.db.settings
	if settings.windowScale == nil then
		if tonumber(settings.uiScale) then
			settings.windowScale = private.OldScale(settings.uiScale) / private.PixelBase()
		else
			settings.windowScale = private.DefaultScale()
		end
	end
	return private.SaneScale(settings.windowScale) or private.DefaultScale()
end

---A size that keeps the whole window on screen: no larger than the screen has room for (on the 5% steps, rounded down
---so it still fits), but not made smaller than 75% for it, where its title bar stays on screen. At 150% the window ran
---off the bottom of most screens, and with it the control to size it back.
---@param scale number a size (SavedScale)
---@return number
function private.FitScale(scale)
	local room = min(UIParent:GetWidth() / WIDTH, UIParent:GetHeight() / HEIGHT) / private.PixelBase()
	room = floor(room * 100 / Theme.SIZE_STEP + 1e-6) * Theme.SIZE_STEP / 100
	return min(scale, max(UI.SCALE_LOW / 100, room))
end

---The window's size as it is shown: 1.2 for 120%.
---@return number
function UI:GetScale()
	return private.FitScale(private.SavedScale())
end

---The window's size in percent, for the controls that show it.
---@return number
function UI:GetScalePercent()
	return UI:GetScale() * 100
end

---Calls fn(percent) whenever the window's size changes (the Settings row follows the title bar's control).
function UI:OnScaleChanged(fn)
	tinsert(scaleListeners, fn)
end

---Where a region's centre is, in UIParent's units, for a pin.
function private.RegionPin(region)
	local x, y = region:GetCenter()
	if type(x) ~= "number" or type(y) ~= "number" then
		return nil
	end
	local ratio = region:GetEffectiveScale() / UIParent:GetEffectiveScale()
	return { x * ratio, y * ratio }
end

---Where the mouse is, in UIParent's units, for a pin.
function private.CursorPin()
	local x, y = GetCursorPosition()
	local scale = UIParent:GetEffectiveScale()
	return { x / scale, y / scale }
end

---Sizes the window frame to the size shown (UI:GetScale), keeping the pin where it is on screen and the window on
---screen; the place is saved. Popups and the menu over it follow.
---@param pin table? { x, y } in UIParent's units; the window's centre when nil
function private.ApplyScale(pin)
	local frame = private.frame
	if not frame then
		return
	end
	local scale = private.PixelBase() * UI:GetScale()
	if math.abs(frame:GetScale() - scale) < 1e-9 then
		return
	end
	Wanted.db.settings.window = Theme:ScaleAbout(frame, scale, pin and pin[1], pin and pin[2]) or Wanted.db.settings.window
	W:HideMenu()
	W:RescalePopups()
end

---Sizes the window (the title bar's control, Settings, Theme: UI size, and Shift + mouse wheel), saved for the
---account; its cog popups and menus follow it. What's under the pin (the control being used, or the mouse) stays where
---it is on screen, and the window stays on screen. The size saved is the one that fits (FitScale).
---@param scale number 0.75 to 1.5 from the controls
---@param pin (table|Region)? a region of the window, { x, y } in UIParent's units, or nil for the window's centre
function UI:SetScale(scale, pin)
	scale = tonumber(scale)
	if not scale or scale ~= scale then
		return
	end
	private.SetSize(max(UI.SCALE_LOW / 100, min(UI.SCALE_HIGH / 100, scale)), pin)
end

---UI:SetScale without its range, for a step from a size outside it.
function private.SetSize(scale, pin)
	Wanted.db.settings.windowScale = private.FitScale(private.SaneScale(scale) or private.DefaultScale())
	if type(pin) == "table" and pin.GetCenter then
		pin = private.RegionPin(pin)
	end
	private.ApplyScale(pin)
	local percent = UI:GetScalePercent()
	for _, fn in ipairs(scaleListeners) do
		fn(percent)
	end
end

---One 5% step bigger (delta > 0) or smaller, from the size shown: a size off the steps goes to the next step, and
---one outside 75% to 150% (converted from before) only steps back toward that range. True when the size changed.
---@param delta number
---@param pin (table|Region)? as UI:SetScale
---@return boolean
function UI:StepScale(delta, pin)
	local step = Theme.SIZE_STEP
	local current = UI:GetScalePercent()
	local percent
	if delta > 0 then
		percent = min(floor(current / step + 1e-6) * step + step, max(current, UI.SCALE_HIGH))
	else
		percent = max(ceil(current / step - 1e-6) * step - step, min(current, UI.SCALE_LOW))
	end
	if math.abs(percent - current) < 1e-6 then
		return false
	end
	private.SetSize(percent / 100, pin)
	return math.abs(UI:GetScalePercent() - current) > 1e-6
end

---Shift + mouse wheel over the window: one step about the mouse. True when the wheel was used for it (Shift held,
---over the open window).
---@param frame Frame what the wheel turned over
---@param delta number
---@return boolean
function private.ShiftWheel(frame, delta)
	if not IsShiftKeyDown() or not private.frame or not private.frame:IsShown() or not private.InWindow(frame) then
		return false
	end
	UI:StepScale(delta, private.CursorPin())
	return true
end
W.shiftWheel = private.ShiftWheel

---Whether a frame is the window or inside it.
function private.InWindow(frame)
	for _ = 1, 40 do
		if frame == private.frame then
			return true
		end
		if type(frame) ~= "table" or not frame.GetParent then
			return false
		end
		frame = frame:GetParent()
	end
	return false
end

---Shows a theme's felt behind the window at once, before the /reload that applies its colours (Settings).
---@param key string
function UI:PreviewTheme(key)
	local frame = private.frame
	if not frame then
		return
	end
	local theme = Theme:Get(key)
	frame.felt:SetTexture(Theme:FeltFile(theme))
	frame.felt:SetVertexColor(theme.shade, theme.shade, theme.shade, 1)
end
