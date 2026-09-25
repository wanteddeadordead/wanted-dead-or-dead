-- Wanted: the Nearby window. A small movable list of enemy players with four views (Nearby, Last hour,
-- Kill on Sight, Ignored). Left-click a row to target the player, right-click for the menu, Shift-click
-- to toggle Kill on Sight. Rows are secure buttons (targeting needs one), so during combat the rows
-- keep their places and only their text updates; the list is laid out again when combat ends.

local _, Wanted = ...
local Nearby = Wanted:NewModule("NearbyWindow")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Enemies = Wanted.Enemies
local private = {
	frame = nil,
	rows = {},
	items = {},
	pendingLayout = false,
	pendingShow = nil,
	offset = 0,
	compact = false,
	combatFrame = CreateFrame("Frame"),
}
local WIDTH = 260
local HEADER = 58
local ROW_HEIGHT = 32
local COMPACT_HEIGHT = 20
local MIN_ROWS = 3
local NORMAL_ROWS, COMPACT_ROWS = 10, 16
local MAX_ROWS = COMPACT_ROWS
local COMPACT_ABOVE = 8 -- more enemies than this switches to single-line rows
local FOOTER_GAP = 8 -- space above the footer text (a divider sits in it) and below it
local HELP_HEIGHT = 30 -- the Call for help bar under the Nearby list
local VIEWS = {
	{ key = "nearby", label = "Nearby" },
	{ key = "hour", label = "Last hour" },
	{ key = "kos", label = "KoS" },
	{ key = "ignore", label = "Ignored" },
}
local EMPTY_TEXT = {
	nearby = "No enemies nearby.",
	hour = "No enemies in the last hour.",
	kos = "Nobody on Kill on Sight yet.",
	ignore = "Nobody ignored.",
}

function private.Settings()
	return Wanted.db.settings.detect
end

---What the Nearby window shows (Settings > Nearby window).
function private.Show()
	return Wanted.db.settings.nearby
end



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Nearby:OnEnable()
	private.combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
	private.combatFrame:SetScript("OnEvent", function()
		if not private.frame then
			private.Create()
		end
		if private.pendingShow ~= nil then
			private.frame:SetShown(private.pendingShow)
			private.pendingShow = nil
		end
		if private.pendingLayout then
			Nearby:Refresh()
		end
	end)
	if not InCombatLockdown() then
		private.Create()
	end
	Enemies:OnChange(private.OnEnemyEvent)
	C_Timer.NewTicker(1, function()
		if private.frame and private.frame:IsShown() then
			Nearby:Refresh()
		end
	end)
end

function private.OnEnemyEvent(event, entry)
	local settings = private.Settings()
	if event == "new" and settings.autoShow and settings.enabled then
		if private.Settings().tab ~= "nearby" then
			private.Settings().tab = "nearby"
		end
		Nearby:SetShown(true)
	end
	if private.frame and private.frame:IsShown() then
		Nearby:Refresh()
	end
end

---Shows or hides the window (after combat, if in combat now).
function Nearby:SetShown(shown)
	if InCombatLockdown() or not private.frame then
		private.pendingShow = shown
		return
	end
	private.frame:SetShown(shown)
	if shown then
		Nearby:Refresh()
	end
end

---Lays the rows out again (after a display setting changed) and redraws.
function Nearby:ForceLayout()
	for _, row in ipairs(private.rows) do
		row.layoutKey = nil
	end
	Nearby:Refresh()
end

function Nearby:IsShown()
	return private.frame and private.frame:IsShown() or false
end

function Nearby:Toggle()
	Nearby:SetShown(not (private.frame and private.frame:IsShown()))
end



-- ============================================================================
-- Building
-- ============================================================================

function private.Create()
	if private.frame then
		return
	end
	local frame = CreateFrame("Frame", "WantedNearbyFrame", UIParent)
	frame:SetSize(WIDTH, HEADER + ROW_HEIGHT * MIN_ROWS + 8)
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	Theme:Skin(frame, C.bg, C.borderLight)
	local saved = private.Settings().window
	if saved and saved.point then
		frame:SetPoint(saved.point, UIParent, saved.point, saved.x, saved.y)
	else
		frame:SetPoint("TOPLEFT", 20, -220)
	end
	frame:Hide()

	-- Title row: drag handle, title and count, buttons
	local header = CreateFrame("Frame", nil, frame)
	header:SetPoint("TOPLEFT", 1, -1)
	header:SetPoint("TOPRIGHT", -1, -1)
	header:SetHeight(26)
	Theme:Fill(header, C.titleBar)
	header:EnableMouse(true)
	header:RegisterForDrag("LeftButton")
	header:SetScript("OnDragStart", function()
		if not InCombatLockdown() then
			frame:StartMoving()
		end
	end)
	header:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		local point, _, _, x, y = frame:GetPoint(1)
		private.Settings().window = { point = point, x = x, y = y }
	end)
	local mark = header:CreateTexture(nil, "ARTWORK")
	mark:SetSize(3, 14)
	mark:SetPoint("LEFT", 8, 0)
	mark:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)
	private.title = Theme:Text(header, "heading", "")
	private.title:SetPoint("LEFT", mark, "RIGHT", 7, 0)
	local close = W:Button(header, "X", "ghost", 22, 22, function() Nearby:SetShown(false) end)
	close:SetPoint("RIGHT", -2, 0)
	W:AttachTooltip(close, "Hide", "Wanted opens it again when the next enemy shows up (Settings to change).")
	local main = W:Button(header, "W", "ghost", 22, 22, function() Wanted.UI:Toggle() end)
	main:SetPoint("RIGHT", close, "LEFT", -2, 0)
	W:AttachTooltip(main, "Open Wanted", "The bounty board, your bounties, enemies and settings.")
	private.mute = W:Button(header, "", "ghost", 44, 22, function()
		Wanted.Alerts:SetMuted(not Wanted.Alerts:IsMuted())
		Nearby:Refresh()
	end)
	private.mute:SetPoint("RIGHT", main, "LEFT", -2, 0)
	W:AttachTooltip(private.mute, "Sound", "Turn alert sounds off or on for this session.")
	local clear = W:Button(header, "Clear", "ghost", 44, 22, function()
		Enemies:ClearNearby()
		Nearby:Refresh()
	end)
	clear:SetPoint("RIGHT", private.mute, "LEFT", -2, 0)
	-- The title stops at the buttons, whatever its length
	private.title:SetPoint("RIGHT", clear, "LEFT", -4, 0)
	private.title:SetJustifyH("LEFT")
	private.title:SetWordWrap(false)
	W:AttachTooltip(clear, "Clear", "Empty the Nearby list. Enemies still around come back on their next sighting.")

	-- View tabs
	private.tabs = W:Segmented(frame, VIEWS, function(key)
		private.Settings().tab = key
		Nearby:Refresh()
	end, 64)
	private.tabs:SetPoint("TOPLEFT", 1, -28)
	for _, button in ipairs(private.tabs.buttons) do
		button:SetHeight(24)
		button.label:SetFontObject(Theme.Fonts.small)
	end
	private.tabs:Select(private.Settings().tab or "nearby", true)

	-- Scroll with the wheel (not in combat: the rows are secure and can't be re-pointed then)
	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(_, delta)
		if InCombatLockdown() then
			return
		end
		private.offset = max(0, private.offset - delta * 3)
		Nearby:Refresh()
	end)
	private.footer = Theme:Text(frame, "tiny", "")
	private.footer:SetPoint("BOTTOMLEFT", 10, FOOTER_GAP)
	private.footer:SetWidth(WIDTH - 20)
	private.footer:SetWordWrap(true)
	private.footer:SetJustifyV("BOTTOM")
	private.footer:SetSpacing(2)
	-- Call for help: always there on the Nearby tab (the window can't change size in combat, when it's needed)
	private.help = W:Button(frame, "Call for help", "danger", WIDTH - 12, 24, function()
		Wanted.EnemyMenu:ShowHelpMenu()
	end)
	W:AttachTooltip(private.help, "Call for help", "Where you are and who's around, for Local Defense (typed into your chat box: press Enter to send), your party or raid, or your guild.")
	private.footerLine = Theme:Line(frame)
	private.footerLine:SetPoint("LEFT", 1, 0)
	private.footerLine:SetPoint("RIGHT", -1, 0)
	private.footerLine:SetPoint("BOTTOM", private.footer, "TOP", 0, FOOTER_GAP / 2)
	private.empty = Theme:Text(frame, "small", "", C.faint)
	private.empty:SetPoint("TOP", 0, -HEADER - 14)
	private.empty:SetJustifyH("CENTER")

	for i = 1, MAX_ROWS do
		private.rows[i] = private.CreateRow(frame, i)
	end
	private.frame = frame
end

---Places a row for normal (two lines) or compact (one line) layout. Out of combat only.
function private.LayoutRow(row, index, compact)
	local showIcon = private.Show().icon
	local height = compact and COMPACT_HEIGHT or ROW_HEIGHT
	row:SetHeight(height)
	row:ClearAllPoints()
	row:SetPoint("TOPLEFT", 1, -HEADER - (index - 1) * height)
	row:SetPoint("TOPRIGHT", -1, -HEADER - (index - 1) * height)
	row.name:ClearAllPoints()
	row.right:ClearAllPoints()
	row.icon:ClearAllPoints()
	local textX = showIcon and (compact and 27 or 32) or 10
	if compact then
		row.icon:SetSize(14, 14)
		row.icon:SetPoint("LEFT", 8, 0)
		row.name:SetPoint("LEFT", textX, 0)
		row.right:SetPoint("RIGHT", -8, 0)
		row.sub:Hide()
	else
		row.icon:SetSize(20, 20)
		row.icon:SetPoint("LEFT", 7, 0)
		row.name:SetPoint("TOPLEFT", textX, -4)
		row.right:SetPoint("TOPRIGHT", -8, -5)
		row.sub:ClearAllPoints()
		row.sub:SetPoint("BOTTOMLEFT", textX, 5)
		row.sub:SetWidth(WIDTH - textX - 10)
		row.sub:Show()
	end
	row.compact = compact
	row.layoutKey = (compact and "c" or "n")..(showIcon and "i" or "")
end

function private.CreateRow(parent, index)
	local row = CreateFrame("Button", nil, parent, "SecureActionButtonTemplate")
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 1, -HEADER - (index - 1) * ROW_HEIGHT)
	row:SetPoint("TOPRIGHT", -1, -HEADER - (index - 1) * ROW_HEIGHT)
	-- Act on the mouse release whatever the "cast on key down" setting says: with that setting on, a secure
	-- button otherwise waits for a press that a release-only button never gets, and nothing happens
	row:RegisterForClicks("AnyUp")
	row:SetAttribute("useOnKeyDown", false)
	row:SetAttribute("type1", "macro")
	row:SetAttribute("macrotext1", "")
	-- Shift-click and Ctrl-click are list actions, not targeting
	row:SetAttribute("shift-type1", "")
	row:SetAttribute("ctrl-type1", "")
	row.bg = Theme:Fill(row, index % 2 == 0 and C.rowAlt or C.transparent)
	-- A faint wash of the player's class colour
	row.tint = row:CreateTexture(nil, "BACKGROUND", nil, 1)
	row.tint:SetAllPoints()
	row.hover = Theme:Fill(row, C.hover, "BACKGROUND")
	row.hover:Hide()
	row.bar = row:CreateTexture(nil, "ARTWORK")
	row.bar:SetPoint("TOPLEFT")
	row.bar:SetPoint("BOTTOMLEFT")
	row.bar:SetWidth(3)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.name = Theme:Text(row, "body", "")
	row.name:SetPoint("TOPLEFT", 30, -4)
	row.name:SetWidth(140)
	row.right = Theme:Text(row, "small", "")
	row.right:SetPoint("TOPRIGHT", -8, -5)
	row.right:SetJustifyH("RIGHT")
	row.sub = Theme:Text(row, "tiny", "")
	row.sub:SetPoint("BOTTOMLEFT", 32, 5)
	row.sub:SetWidth(WIDTH - 42)
	-- Health is a secret value on this client: a status bar can draw it without the addon reading it
	row.health = CreateFrame("StatusBar", nil, row)
	row.health:SetPoint("BOTTOMLEFT", 3, 0)
	row.health:SetPoint("BOTTOMRIGHT", 0, 0)
	row.health:SetHeight(3)
	row.health:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	row.health:SetStatusBarColor(C.green[1], C.green[2], C.green[3], 0.85)
	row.health.bg = row.health:CreateTexture(nil, "BACKGROUND")
	row.health.bg:SetAllPoints()
	row.health.bg:SetColorTexture(0, 0, 0, 0.5)
	row.health:Hide()
	row:SetScript("OnEnter", function(self)
		self.hover:Show()
		if self.info then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(Theme:ClassName(self.info.name, self.info.class))
			Wanted.EnemyMenu:AddTooltip(self.info)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine(self.clickable and "Click: target   Right-click: menu   Shift-click: Kill on Sight" or "Right-click: menu (targeting returns after combat)", C.faint[1], C.faint[2], C.faint[3], true)
			GameTooltip:Show()
		end
	end)
	row:SetScript("OnLeave", function(self)
		self.hover:Hide()
		GameTooltip:Hide()
	end)
	row:HookScript("PostClick", function(self, button)
		local info = self.info
		if not info then
			return
		end
		if button == "RightButton" then
			Wanted.EnemyMenu:Show(info)
		elseif IsShiftKeyDown() then
			Enemies:SetKoS(info.guid, info.name, not info.kos)
			Nearby:Refresh()
		elseif IsControlKeyDown() then
			Enemies:SetIgnored(info.guid, info.name, not info.ignored)
			Nearby:Refresh()
		end
	end)
	return row
end

---The macro that targets a player. Names on this client are "First Last"; the lines are tried in turn and
---each only runs while nothing is targeted yet.
function private.TargetMacro(name)
	local first = strmatch(name, "^(%S+)")
	return table.concat({
		"/cleartarget",
		"/targetexact "..name,
		"/targetexact [noexists] "..gsub(name, " ", "-"),
		"/targetexact [noexists] "..first,
		"/target [noexists] "..name,
	}, "\n")
end



-- ============================================================================
-- Drawing
-- ============================================================================

function private.GetItems(view)
	if view == "hour" then
		return Enemies:GetLastHour()
	elseif view == "kos" then
		return Enemies:GetKoSList()
	elseif view == "ignore" then
		return Enemies:GetIgnoreList()
	end
	return Enemies:GetNearby()
end

function Nearby:Refresh()
	if not private.frame then
		return
	end
	local view = private.Settings().tab or "nearby"
	local items = private.GetItems(view)
	local inCombat = InCombatLockdown()
	local label = VIEWS[1].label
	for _, v in ipairs(VIEWS) do
		if v.key == view then
			label = v.label
		end
	end
	-- Just the count: "(2 in sight)" didn't fit beside the buttons, and shaded rows already show who's gone
	private.title:SetText(format("%s  %s", label, Theme:Colorize(tostring(#items), C.muted)))
	private.mute:SetText(Wanted.Alerts:IsMuted() and "Muted" or "Sound")
	private.mute:SetStyle(Wanted.Alerts:IsMuted() and "danger" or "ghost")
	private.tabs:Select(view, true)
	private.empty:SetText(#items == 0 and EMPTY_TEXT[view] or "")

	if inCombat then
		-- Rows keep their players; new players only fill empty rows, as text (not clickable until combat ends)
		private.pendingLayout = true
		local byGuid = {}
		for _, info in ipairs(items) do
			byGuid[info.guid] = info
		end
		local placed = {}
		for _, row in ipairs(private.rows) do
			if row.guid and byGuid[row.guid] then
				private.Draw(row, byGuid[row.guid])
				placed[row.guid] = true
			elseif row.guid then
				private.Draw(row, nil)
			end
		end
		for _, info in ipairs(items) do
			if not placed[info.guid] then
				for _, row in ipairs(private.rows) do
					if not row.guid and not row.textOnly then
						row.textOnly = true
						private.Draw(row, info)
						break
					end
				end
			end
		end
		return
	end

	private.pendingLayout = false
	local layout = private.Show().layout or "auto"
	local compact = layout == "compact" or (layout == "auto" and #items > COMPACT_ABOVE)
	local bg = C.bg
	Theme:SetBg(private.frame, { bg[1], bg[2], bg[3], (bg[4] or 1) * (private.Show().opacity or 1) })
	local capacity = compact and COMPACT_ROWS or NORMAL_ROWS
	local rowHeight = compact and COMPACT_HEIGHT or ROW_HEIGHT
	private.offset = min(private.offset, max(#items - capacity, 0))
	local numRows = min(max(#items - private.offset, MIN_ROWS), capacity)
	local overflow = #items > capacity
	-- The footer (position and classes) gets the height its text needs, so it never runs into the rows
	private.footer:SetText(overflow and private.FooterText(items, capacity) or "")
	private.footerLine:SetShown(overflow)
	local footerHeight = overflow and (ceil(private.footer:GetStringHeight()) + FOOTER_GAP * 2) or 8
	local showHelp = view == "nearby"
	private.help:SetShown(showHelp)
	if showHelp then
		private.help:ClearAllPoints()
		private.help:SetPoint("BOTTOM", 0, footerHeight)
		footerHeight = footerHeight + HELP_HEIGHT
	end
	private.frame:SetHeight(HEADER + numRows * rowHeight + footerHeight)
	for i, row in ipairs(private.rows) do
		if row.layoutKey ~= (compact and "c" or "n")..(private.Show().icon and "i" or "") then
			private.LayoutRow(row, i, compact)
		end
		local info = items[i + private.offset]
		row.textOnly = nil
		row.guid = info and info.guid or nil
		local macro = info and private.TargetMacro(info.name) or ""
		if row:GetAttribute("macrotext1") ~= macro then
			row:SetAttribute("macrotext1", macro)
		end
		row.clickable = info ~= nil
		private.Draw(row, info)
		row:SetShown(i <= numRows)
	end
end

---Fades a row's contents: full strength for someone in sight, shaded once they're gone. The row itself is
---a secure button, so the fade goes on its regions rather than the row.
function private.SetFade(row, alpha)
	for _, region in ipairs({ row.name, row.right, row.sub, row.bar, row.tint, row.health, row.icon }) do
		region:SetAlpha(alpha)
	end
end

---"11-26 of 38. Wheel to scroll." plus the classes, so a big group is visible even when not all listed.
function private.FooterText(items, capacity)
	local first = private.offset + 1
	local last = min(private.offset + capacity, #items)
	local classes = {}
	for _, info in ipairs(items) do
		local class = info.class or "?"
		classes[class] = (classes[class] or 0) + 1
	end
	local list = {}
	for class, count in pairs(classes) do
		tinsert(list, { class = class, count = count })
	end
	sort(list, function(a, b) return a.count > b.count end)
	local parts = {}
	for i = 1, min(#list, 6) do
		local entry = list[i]
		tinsert(parts, Theme:ClassName(entry.count.." "..Theme:ClassLabel(entry.class ~= "?" and entry.class or nil), entry.class))
	end
	local scroll = InCombatLockdown() and "Scroll after combat." or "Wheel to scroll."
	return format("%d-%d of %d. %s\n%s", first, last, #items, scroll, table.concat(parts, "  "))
end

function private.Draw(row, info)
	row.info = info
	local show = private.Show()
	if not info then
		row.name:SetText("")
		row.right:SetText("")
		row.sub:SetText("")
		row.bar:SetColorTexture(0, 0, 0, 0)
		row.tint:SetColorTexture(0, 0, 0, 0)
		row.health:Hide()
		row.icon:Hide()
		private.SetFade(row, 1)
		return
	end
	if show.icon then
		Theme:SetClassIcon(row.icon, info.class)
	else
		row.icon:Hide()
	end
	local classColor = info.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[info.class]
	if show.targeting and info.targetingMe then
		-- Someone targeting you stands out from the whole list
		row.tint:SetColorTexture(C.red[1], C.red[2], C.red[3], 0.28)
	elseif show.tint and classColor then
		row.tint:SetColorTexture(classColor.r, classColor.g, classColor.b, 0.14)
	else
		row.tint:SetColorTexture(0, 0, 0, 0)
	end
	local now = GetServerTime()
	local name = Theme:ClassName(info.name, info.class)
	if show.targeting and info.targetingMe then
		name = Theme:Colorize("> ", C.red)..name
	end
	row.name:SetText(name)
	-- Right side: bounty, then level and class
	local rightParts = {}
	if show.bounty and info.bounty > 0 then
		tinsert(rightParts, Theme:Colorize(Wanted.Bounties:FormatMoney(info.bounty), C.gold))
	end
	if row.compact and show.state and info.nearby and not info.inSight and not info.active then
		tinsert(rightParts, Theme:Colorize(format("%ds", info.goneFor or 0), C.faint))
	end
	local levelText = ""
	if show.level then
		levelText = info.level and tostring(info.level) or (info.skull and "??" or "")
	end
	if show.className and not row.compact and info.class then
		levelText = strtrim(levelText.." "..Theme:ClassLabel(info.class))
	end
	if levelText ~= "" then
		tinsert(rightParts, levelText)
	end
	row.right:SetText(table.concat(rightParts, "  "))
	-- Second line
	local sub = {}
	if show.state then
		if info.nearby then
			if info.active then
				tinsert(sub, Theme:Colorize("active", C.green))
			elseif info.inSight then
				tinsert(sub, Theme:Colorize("in sight", C.blue))
			else
				tinsert(sub, Theme:Colorize(format("not seen for %ds", info.goneFor or 0), C.faint))
			end
		elseif info.lastSeen then
			tinsert(sub, Theme:Ago(now - info.lastSeen))
		end
	end
	if info.stealthed then
		tinsert(sub, Theme:Colorize(strlower(info.stealthKind or "stealth"), C.amber))
	end
	if show.kos and info.kos then
		tinsert(sub, Theme:Colorize(info.reason and ("KoS: "..info.reason) or "Kill on Sight", C.red))
	end
	if show.guild and info.guild then
		tinsert(sub, "<"..info.guild..">")
	end
	if show.record and (info.wins > 0 or info.losses > 0) then
		tinsert(sub, format("%d-%d", info.wins, info.losses))
	end
	row.sub:SetText(table.concat(sub, "  "))
	local stateColor = info.active and C.green or ((info.inSight or not info.nearby) and C.blue) or C.faint
	local barColor = (show.kos and info.kos and C.red) or (show.bounty and info.bounty > 0 and C.gold) or stateColor
	row.bar:SetColorTexture(barColor[1], barColor[2], barColor[3], barColor[4] or 1)
	-- Out of sight on the Nearby list: shaded until they're back or dropped
	private.SetFade(row, (show.fade and info.nearby and not info.inSight and not info.active) and 0.4 or 1)
	-- Only while the unit token still points at this player
	local unit = info.unit
	if show.health and info.nearby and info.inSight and unit and UnitGUID(unit) == info.guid then
		row.health:SetMinMaxValues(0, UnitHealthMax(unit))
		row.health:SetValue(UnitHealth(unit))
		row.health:Show()
	else
		row.health:Hide()
	end
end

Wanted:RegisterCommand("nearby", "Shows or hides the Nearby window.", function()
	Nearby:Toggle()
end)
