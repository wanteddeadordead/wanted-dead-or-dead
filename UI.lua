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
-- The development note under the title bar adds its height to the window, so pages keep their size
local NOTE_HEIGHT = 24
local WIDTH, HEIGHT = 960, 640 + NOTE_HEIGHT
local TITLE_HEIGHT = 48
local SIDEBAR_WIDTH = 188
local CONTENT_PAD = 22
local HEADER_HEIGHT = 58
local FOOTER_HEIGHT = 30
local NAV_HEIGHT = 30
local GROUP_HEIGHT = 26
local TAB_ROW = 38 -- a page without a header that has tabs: they take this much off its top
-- The sidebar's groups, in order; a page names its group (none: above them all, like Home)
local GROUPS = { "Bounties", "War", "You" }
local DEFAULT_PAGE = "home"



-- ============================================================================
-- Pages
-- ============================================================================

---Registers a page.
---@param key string
---@param def table title, subtitle, order, group (one of GROUPS), noHeader (the page takes the header's room too),
---build(container, width, height), refresh(), badge() -> number|string?, color?; tabs (page keys shown as tabs in
---the header, the first opened from the menu), under (the page whose menu entry and tabs this page is one of, kept
---out of the menu itself), tabLabel (its tab's label)
function UI:RegisterPage(key, def)
	def.key = key
	tinsert(private.pages, def)
	private.pageByKey[key] = def
	sort(private.pages, function(a, b) return a.order < b.order end)
end

---The size a page has to lay itself out in.
---@param noHeader boolean? for a page without the title and subtitle
---@return number width
---@return number height (a page with tabs along its top gets less: build is given its real size)
function UI:GetPageSize(noHeader)
	return WIDTH - SIDEBAR_WIDTH - CONTENT_PAD * 2, HEIGHT - TITLE_HEIGHT - NOTE_HEIGHT - CONTENT_PAD - (noHeader and 0 or HEADER_HEIGHT) - FOOTER_HEIGHT
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
	C_Timer.After(0.15, Wanted:Timed("Window refresh", function()
		private.refreshQueued = false
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
		UI:Refresh(true)
		-- Keep "4m ago" style times and the connection state current while the window is open
		private.ticker = C_Timer.NewTicker(15, Wanted:Timed("Window refresh", function() UI:Refresh() end))
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
	-- The wax seal, as on the website
	local mark = titleBar:CreateTexture(nil, "ARTWORK")
	mark:SetSize(32, 32)
	mark:SetPoint("LEFT", 12, 0)
	mark:SetTexture("Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\seal")
	local brand = Theme:Text(titleBar, "brand", "WANTED: "..Theme:Colorize("DEAD OR...", C.muted).." "..Theme:Colorize("DEAD", C.accent))
	brand:SetPoint("LEFT", mark, "RIGHT", 8, 1)
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
	private.netStatus:SetPoint("RIGHT", bug, "LEFT", -10, 0)
	private.appStatus = Indicator(140, function() UI:Show("web") end)
	private.appStatus:SetPoint("RIGHT", private.netStatus, "LEFT", -6, 0)

	-- Under heavy development through the WoW Forever beta: say so on every page
	local note = CreateFrame("Frame", nil, frame)
	note:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT")
	note:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT")
	note:SetHeight(NOTE_HEIGHT)
	Theme:Fill(note, { C.amber[1] * 0.22, C.amber[2] * 0.22, C.amber[3] * 0.22, 1 })
	local noteText = Theme:Text(note, "small", "Wanted is under heavy development through the WoW Forever beta. Expect frequent updates, and possible issues while we work through the game's changes.", C.amber)
	noteText:SetPoint("LEFT", 14, 0)
	noteText:SetPoint("RIGHT", -14, 0)
	noteText:SetJustifyH("LEFT")
	noteText:SetWordWrap(false)
	note.text = noteText

	-- Sidebar
	local sidebar = CreateFrame("Frame", nil, frame)
	sidebar:SetPoint("TOPLEFT", 1, -TITLE_HEIGHT - NOTE_HEIGHT - 1)
	sidebar:SetPoint("BOTTOMLEFT", 1, 1)
	sidebar:SetWidth(SIDEBAR_WIDTH)
	Theme:Fill(sidebar, C.sidebar)
	local sideLine = sidebar:CreateTexture(nil, "BORDER")
	sideLine:SetPoint("TOPRIGHT")
	sideLine:SetPoint("BOTTOMRIGHT")
	sideLine:SetWidth(1)
	sideLine:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)
	private.navButtons = {}
	private.groupLabels = {}
	for _, group in ipairs(GROUPS) do
		private.groupLabels[group] = W:SectionLabel(sidebar, group)
	end
	for _, def in ipairs(private.pages) do
		local nav = CreateFrame("Button", nil, sidebar)
		nav:SetSize(SIDEBAR_WIDTH - 1, NAV_HEIGHT)
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
		nav:SetScript("OnClick", function() UI:Show(def.tabs and def.tabs[1] or def.key) end)
		nav:SetScript("OnEnter", function(self)
			if (private.owner or private.current) ~= self.key then
				self.bg:SetColorTexture(1, 1, 1, 0.035)
			end
		end)
		nav:SetScript("OnLeave", function(self)
			if (private.owner or private.current) ~= self.key then
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
	content:SetPoint("TOPLEFT", SIDEBAR_WIDTH + 1 + CONTENT_PAD, -TITLE_HEIGHT - NOTE_HEIGHT - CONTENT_PAD)
	content:SetPoint("BOTTOMRIGHT", -CONTENT_PAD, 1)
	private.title = Theme:Text(content, "title", "")
	private.title:SetPoint("TOPLEFT", 0, 0)
	private.subtitle = Theme:Text(content, "small", "")
	private.subtitle:SetPoint("TOPLEFT", 0, -26)
	private.subtitle:SetPoint("RIGHT", 0, 0)
	private.subtitle:SetWordWrap(false)
	-- Tabs for pages that share a menu entry (Home and the calendar): at the right of the title, or along the top of
	-- a page without a header
	private.tabBars = {}
	for _, def in ipairs(private.pages) do
		if def.tabs then
			local items = {}
			for _, key in ipairs(def.tabs) do
				local page = private.pageByKey[key]
				tinsert(items, { key = key, label = page and (page.tabLabel or page.title) or key })
			end
			local bar = W:Segmented(content, items, function(key) UI:Show(key) end, 110)
			bar:SetPoint(def.noHeader and "TOPLEFT" or "TOPRIGHT", 0, 0)
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
		local width, height = UI:GetPageSize(def.noHeader)
		local owner = def.under and private.pageByKey[def.under] or def
		-- Without a header, a page's tabs sit along its top (Home | Calendar)
		local tabRow = def.noHeader and owner.tabs and TAB_ROW or 0
		container:SetPoint("TOPLEFT", 0, def.noHeader and -tabRow or -HEADER_HEIGHT)
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
	if Wanted.Report then
		Wanted.Report:MaybeWelcome()
	end
end

---The page to show for a key: Home when there is no such page, or it's switched off.
---@param key string?
---@return string
function private.UsablePage(key)
	local def = key and private.pageByKey[key]
	if not def or (def.hidden and def.hidden()) then
		return DEFAULT_PAGE
	end
	return key
end

---Places the sidebar buttons under their groups' labels, leaving out pages that are switched off (e.g. Tools).
function private.LayoutNav()
	local y = -12
	local function Place(group)
		for _, def in ipairs(private.pages) do
			local nav = private.navButtons[def.key]
			if def.group == group or (def.under and group == nil) then
				nav:ClearAllPoints()
				if def.under or (def.hidden and def.hidden()) then
					nav:Hide()
				else
					nav:SetPoint("TOPLEFT", 0, y)
					nav:Show()
					y = y - NAV_HEIGHT
				end
			end
		end
	end
	Place(nil)
	for _, group in ipairs(GROUPS) do
		local label = private.groupLabels[group]
		label:ClearAllPoints()
		label:SetPoint("TOPLEFT", 22, y - 12)
		y = y - GROUP_HEIGHT
		Place(group)
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

---Redraws the window. allBadges: work every menu badge out afresh (opening the window, changing page).
---@param allBadges boolean?
function UI:Refresh(allBadges)
	if not private.frame then
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
	private.title:SetText(def.noHeader and "" or def.title)
	private.subtitle:SetText(def.noHeader and "" or def.subtitle or "")
	-- The menu entry and tabs the current page belongs to
	local owner = def.under or def.key
	private.owner = owner
	for key, bar in pairs(private.tabBars) do
		bar:SetShown(key == owner)
		if key == owner and bar.selected ~= private.current then
			bar:Select(private.current, true)
		end
	end
	-- A page kept out of the menu shows its badge on its menu entry, when that has none of its own
	local underBadges = {}
	for _, page in ipairs(private.pages) do
		if page.under and page.badge then
			local badge, color = private.Badge(page, allBadges)
			underBadges[page.under] = underBadges[page.under] or (badge and { badge, color })
		end
	end
	for _, page in ipairs(private.pages) do
		local nav = private.navButtons[page.key]
		local selected = page.key == owner
		nav.bar:SetShown(selected)
		nav.bg:SetColorTexture(1, 1, 1, selected and 0.06 or 0)
		nav.label:SetTextColor(unpack(selected and C.white or C.muted))
		local badge, color = nil, nil
		if page.badge then
			badge, color = private.Badge(page, allBadges)
		end
		if not badge and underBadges[page.key] then
			badge, color = underBadges[page.key][1], underBadges[page.key][2]
		end
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
			"It last ran "..Theme:Ago(notRunning).." ago. Start it from the Start menu (Wanted Dead or Dead) so your kills reach the website.")
	elseif app then
		-- Development builds also count the apps running across the network
		local apps = Wanted.DEV and Wanted:AppsRunning()
		Set(private.appStatus, C.green, apps and format("App (%d running)", apps) or "App", "The Wanted app is set up",
			"Version "..app..". It puts your records on wanteddeadordead.com and keeps your addon data safe.")
	else
		Set(private.appStatus, C.red, "Get the app", "No Wanted app on this computer",
			"The desktop app puts your kills on wanteddeadordead.com and confirms other players' kills. Click for the link.")
	end
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
