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
	current = "board",
	refreshQueued = false,
	toastTimer = nil,
}
local WIDTH, HEIGHT = 960, 640
local TITLE_HEIGHT = 48
local SIDEBAR_WIDTH = 188
local CONTENT_PAD = 22
local HEADER_HEIGHT = 58
local FOOTER_HEIGHT = 30



-- ============================================================================
-- Pages
-- ============================================================================

---Registers a page.
---@param key string
---@param def table title, subtitle, order, icon, build(container, width, height), refresh(), badge() -> number?
function UI:RegisterPage(key, def)
	def.key = key
	tinsert(private.pages, def)
	private.pageByKey[key] = def
	sort(private.pages, function(a, b) return a.order < b.order end)
end

---The size a page has to lay itself out in.
---@return number width
---@return number height
function UI:GetPageSize()
	return WIDTH - SIDEBAR_WIDTH - CONTENT_PAD * 2, HEIGHT - TITLE_HEIGHT - CONTENT_PAD - HEADER_HEIGHT - FOOTER_HEIGHT
end



-- ============================================================================
-- Lifecycle
-- ============================================================================

function UI:OnEnable()
	-- Enemies appearing, leaving and list changes (not the once-a-second updates of ones already listed)
	Wanted.Enemies:OnChange(function(event)
		if event ~= "update" then
			private.QueueRefresh()
		end
	end)
	for _, kind in ipairs({ "bounty", "claim", "confirm", "payment", "raise", "pass", "death", "kill", "mark", "withdraw", "hunt", "sighting" }) do
		Wanted.Store:OnRecord(kind, private.QueueRefresh)
	end
end

function private.QueueRefresh()
	if private.refreshQueued or not private.frame or not private.frame:IsShown() then
		return
	end
	private.refreshQueued = true
	C_Timer.After(0.15, function()
		private.refreshQueued = false
		UI:Refresh()
	end)
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
	local frame = CreateFrame("Frame", "WantedFrame", UIParent)
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	Theme:Skin(frame, C.bg, C.borderLight)
	local saved = Wanted.db.settings.window
	if saved and saved.point then
		frame:SetPoint(saved.point, UIParent, saved.point, saved.x, saved.y)
	else
		frame:SetPoint("CENTER")
	end
	frame:Hide()
	tinsert(UISpecialFrames, "WantedFrame")
	frame:SetScript("OnShow", function()
		UI:Refresh()
		-- Keep "4m ago" style times and the connection state current while the window is open
		private.ticker = C_Timer.NewTicker(15, function() UI:Refresh() end)
	end)
	frame:SetScript("OnHide", function()
		if private.ticker then
			private.ticker:Cancel()
			private.ticker = nil
		end
	end)
	private.frame = frame

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
	local titleLine = Theme:Line(titleBar)
	titleLine:SetPoint("BOTTOMLEFT")
	titleLine:SetPoint("BOTTOMRIGHT")
	local mark = titleBar:CreateTexture(nil, "ARTWORK")
	mark:SetSize(4, 22)
	mark:SetPoint("LEFT", 18, 0)
	mark:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)
	local brand = Theme:Text(titleBar, "brand", "WANTED: "..Theme:Colorize("DEAD OR...", C.muted).." "..Theme:Colorize("DEAD", C.accent))
	brand:SetPoint("LEFT", mark, "RIGHT", 10, 1)
	local anchor = brand
	if Wanted.BETA then
		local beta = W:Pill(titleBar)
		beta:Set("BETA", C.amber)
		beta:SetPoint("LEFT", brand, "RIGHT", 10, 0)
		anchor = beta
	end
	local tagline = Theme:Text(titleBar, "small", "World PvP bounties, player to player")
	tagline:SetPoint("LEFT", anchor, "RIGHT", 12, -1)

	local close = W:Button(titleBar, "X", "ghost", 30, 30, function() frame:Hide() end)
	close:SetPoint("RIGHT", -10, 0)
	W:AttachTooltip(close, "Close", "Escape also closes the window.")
	local bug = W:Button(titleBar, "Report a bug", "ghost", 100, 26, function() Wanted.Report:Show() end)
	bug:SetPoint("RIGHT", close, "LEFT", -6, 0)
	W:AttachTooltip(bug, "Report a bug", "Builds a report to copy (versions, settings, errors, recent log) and shows where to send it.")

	-- Connection indicator
	local connection = CreateFrame("Button", nil, titleBar)
	connection:SetSize(210, 30)
	connection:SetPoint("RIGHT", bug, "LEFT", -10, 0)
	connection.dot = connection:CreateTexture(nil, "ARTWORK")
	connection.dot:SetSize(8, 8)
	connection.text = Theme:Text(connection, "small", "")
	connection.text:SetPoint("RIGHT", 0, 0)
	connection.text:SetJustifyH("RIGHT")
	connection.dot:SetPoint("RIGHT", connection.text, "LEFT", -8, 0)
	connection:SetScript("OnClick", function()
		UI:Show(Wanted.db.settings.showTools and "tools" or "settings")
	end)
	W:AttachTooltip(connection, "Network", "Other players running Wanted share bounties, kills and payments with you.")
	connection:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText(self.tooltipTitle, 1, 1, 1)
		GameTooltip:AddLine(self.tooltipText, C.muted[1], C.muted[2], C.muted[3], true)
		GameTooltip:Show()
	end)
	connection:SetScript("OnLeave", function() GameTooltip:Hide() end)
	private.connection = connection

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
	sideLine:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)
	private.navButtons = {}
	for _, def in ipairs(private.pages) do
		local nav = CreateFrame("Button", nil, sidebar)
		nav:SetSize(SIDEBAR_WIDTH - 1, 38)
		nav.bg = Theme:Fill(nav, C.transparent)
		nav.bar = nav:CreateTexture(nil, "ARTWORK")
		nav.bar:SetPoint("TOPLEFT")
		nav.bar:SetPoint("BOTTOMLEFT")
		nav.bar:SetWidth(3)
		nav.bar:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)
		nav.label = Theme:Text(nav, "body", def.title)
		nav.label:SetPoint("LEFT", 22, 0)
		nav.badge = W:Pill(nav)
		nav.badge:SetPoint("RIGHT", -14, 0)
		nav.key = def.key
		nav:SetScript("OnClick", function() UI:Show(def.key) end)
		nav:SetScript("OnEnter", function(self)
			if private.current ~= self.key then
				self.bg:SetColorTexture(1, 1, 1, 0.035)
			end
		end)
		nav:SetScript("OnLeave", function(self)
			if private.current ~= self.key then
				self.bg:SetColorTexture(0, 0, 0, 0)
			end
		end)
		private.navButtons[def.key] = nav
	end
	private.LayoutNav()
	local version = Theme:Text(sidebar, "tiny", "v"..(Wanted.VERSION or "?").."   /wanted")
	version:SetPoint("BOTTOMLEFT", 22, 14)

	-- Content
	local content = CreateFrame("Frame", nil, frame)
	content:SetPoint("TOPLEFT", SIDEBAR_WIDTH + 1 + CONTENT_PAD, -TITLE_HEIGHT - CONTENT_PAD)
	content:SetPoint("BOTTOMRIGHT", -CONTENT_PAD, 1)
	private.title = Theme:Text(content, "title", "")
	private.title:SetPoint("TOPLEFT", 0, 0)
	private.subtitle = Theme:Text(content, "small", "")
	private.subtitle:SetPoint("TOPLEFT", 0, -26)
	private.subtitle:SetPoint("RIGHT", 0, 0)
	private.subtitle:SetWordWrap(false)
	private.toast = Theme:Text(content, "small", "")
	private.toast:SetPoint("BOTTOMLEFT", 0, 10)
	private.toast:SetPoint("BOTTOMRIGHT", 0, 10)
	local pageWidth, pageHeight = UI:GetPageSize()
	for _, def in ipairs(private.pages) do
		local container = CreateFrame("Frame", nil, content)
		container:SetPoint("TOPLEFT", 0, -HEADER_HEIGHT)
		container:SetSize(pageWidth, pageHeight)
		container:Hide()
		def.container = container
		def.build(container, pageWidth, pageHeight)
	end
end



-- ============================================================================
-- Showing and refreshing
-- ============================================================================

---Shows the window on a page (or the current one).
---@param key string?
function UI:Show(key)
	UI:GetFrame()
	if key and private.pageByKey[key] then
		private.current = key
	end
	for _, def in ipairs(private.pages) do
		def.container:SetShown(def.key == private.current)
	end
	private.frame:Show()
	UI:Refresh()
	if Wanted.Report then
		Wanted.Report:MaybeWelcome()
	end
end

---Places the sidebar buttons, leaving out pages that are switched off (e.g. Tools).
function private.LayoutNav()
	local y = -16
	for _, def in ipairs(private.pages) do
		local nav = private.navButtons[def.key]
		local hidden = def.hidden and def.hidden()
		nav:ClearAllPoints()
		if hidden then
			nav:Hide()
		else
			nav:SetPoint("TOPLEFT", 0, y)
			nav:Show()
			y = y - 40
		end
	end
end

function UI:Toggle()
	if private.frame and private.frame:IsShown() then
		private.frame:Hide()
	else
		UI:Show()
	end
end

function UI:IsShown(key)
	return private.frame and private.frame:IsShown() and (not key or private.current == key)
end

function UI:Refresh()
	if not private.frame then
		return
	end
	private.LayoutNav()
	local def = private.pageByKey[private.current]
	if def.hidden and def.hidden() then
		-- Its page was switched off while open
		private.current = "board"
		for _, page in ipairs(private.pages) do
			page.container:SetShown(page.key == private.current)
		end
		def = private.pageByKey[private.current]
	end
	private.title:SetText(def.title)
	private.subtitle:SetText(def.subtitle or "")
	for _, page in ipairs(private.pages) do
		local nav = private.navButtons[page.key]
		local selected = page.key == private.current
		nav.bar:SetShown(selected)
		nav.bg:SetColorTexture(1, 1, 1, selected and 0.06 or 0)
		nav.label:SetTextColor(unpack(selected and C.white or C.muted))
		local badge = page.badge and page.badge()
		if badge and badge > 0 then
			nav.badge:Set(tostring(badge), C.accent)
		else
			nav.badge:Hide()
		end
	end
	if def.refresh then
		def.refresh()
	end
	private.UpdateConnection()
end

function private.UpdateConnection()
	if not private.connection then
		return
	end
	local info = Wanted.Sync and Wanted.Sync:GetInfo()
	local color, text
	if not info or not info.channelId then
		color, text = C.red, "Offline"
	elseif info.paused then
		color, text = C.amber, "Paused (flood protection)"
	elseif info.peers == 0 then
		color, text = C.amber, "Online, no other players yet"
	else
		color, text = C.green, format("Online, %d player%s", info.peers, info.peers == 1 and "" or "s")
	end
	private.connection.dot:SetColorTexture(color[1], color[2], color[3], 1)
	private.connection.text:SetText(text)
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

Wanted:RegisterCommand("show", "Opens the window: /wanted show [board|mine|hunters|activity|tools].", function(args)
	local key = strtrim(args or "")
	UI:Show(key ~= "" and key or nil)
end)
