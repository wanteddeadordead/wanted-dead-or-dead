-- Wanted: the widget set. Flat buttons with hover and pressed states, inputs with placeholders, toggles,
-- segmented controls, pills, cards, stat tiles, a virtual scrolling list, and a modal dialog.

local _, Wanted = ...
local W = {}
Wanted.Widgets = W
local Theme = Wanted.Theme
local C = Theme.C

local STYLES = {
	primary = { bg = C.accent, hover = C.accentHover, border = C.accent, text = C.white },
	secondary = { bg = C.panelAlt, hover = { 0.15, 0.155, 0.185, 1 }, border = C.border, text = C.text },
	ghost = { bg = C.transparent, hover = C.hover, border = C.transparent, text = C.muted, hoverText = C.text },
	success = { bg = { 0.2, 0.46, 0.27, 1 }, hover = { 0.25, 0.56, 0.33, 1 }, border = { 0.28, 0.6, 0.36, 1 }, text = C.white },
	danger = { bg = C.transparent, hover = C.redDim, border = C.red, text = C.red },
	selected = { bg = C.accentDim, hover = C.accentDim, border = C.accent, text = C.white },
	chip = { bg = C.transparent, hover = C.hover, border = C.border, text = C.muted, hoverText = C.text },
}



-- ============================================================================
-- Tooltip helper
-- ============================================================================

function W:AttachTooltip(frame, title, text)
	frame.tooltipTitle = title
	frame.tooltipText = text
end

local function ShowTooltip(frame)
	if not frame.tooltipTitle then
		return
	end
	GameTooltip:SetOwner(frame, "ANCHOR_TOP")
	GameTooltip:SetText(frame.tooltipTitle, 1, 1, 1)
	if frame.tooltipText then
		GameTooltip:AddLine(frame.tooltipText, C.muted[1], C.muted[2], C.muted[3], true)
	end
	GameTooltip:Show()
end



-- ============================================================================
-- Button
-- ============================================================================

local function RefreshButton(button)
	local style = button.style
	local enabled = button:IsEnabled()
	local bg = (enabled and button.hovered) and style.hover or style.bg
	if not enabled then
		-- A disabled button must not look pressable, whatever its style
		bg = style.bg[4] == 0 and style.bg or C.panelAlt
	end
	Theme:SetBg(button, bg)
	Theme:SetBorderColor(button, enabled and style.border or C.border)
	local text = (enabled and button.hovered and style.hoverText) or style.text
	if not enabled then
		-- Dimmed but still readable
		text = C.muted
	end
	button.label:SetTextColor(text[1], text[2], text[3])
end

function W:Button(parent, text, style, width, height, onClick)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(width or 96, height or 26)
	Theme:Skin(button, C.transparent, C.transparent)
	button.label = Theme:Text(button, "body", text)
	button.label:SetJustifyH("CENTER")
	button.label:SetPoint("CENTER")
	button:SetFontString(button.label)
	button.style = STYLES[style or "secondary"]
	function button:SetStyle(name)
		self.style = STYLES[name] or STYLES.secondary
		RefreshButton(self)
	end
	button:SetScript("OnEnter", function(self)
		self.hovered = true
		RefreshButton(self)
		ShowTooltip(self)
	end)
	button:SetScript("OnLeave", function(self)
		self.hovered = false
		RefreshButton(self)
		GameTooltip:Hide()
	end)
	button:SetScript("OnEnable", RefreshButton)
	button:SetScript("OnDisable", RefreshButton)
	button:SetScript("OnMouseDown", function(self)
		if self:IsEnabled() then
			self.label:SetPoint("CENTER", 1, -1)
		end
	end)
	button:SetScript("OnMouseUp", function(self)
		self.label:SetPoint("CENTER", 0, 0)
	end)
	if onClick then
		button:SetScript("OnClick", onClick)
	end
	RefreshButton(button)
	return button
end



-- ============================================================================
-- Input
-- ============================================================================

---A box holding text to copy (a link): click it and it selects all, typing puts the text back.
function W:CopyBox(parent, width, text)
	local box = CreateFrame("EditBox", nil, parent)
	box:SetSize(width, 26)
	box:SetAutoFocus(false)
	box:SetFontObject(Theme.Fonts.small)
	box:SetTextInsets(9, 9, 0, 0)
	Theme:Skin(box, C.input, C.border)
	box:SetText(text)
	box:SetCursorPosition(0)
	box:SetScript("OnEscapePressed", box.ClearFocus)
	box:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			self:SetText(text)
			self:HighlightText()
		end
	end)
	box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	return box
end

function W:Input(parent, width, placeholder, onChange)
	local box = CreateFrame("EditBox", nil, parent)
	box:SetSize(width, 26)
	box:SetAutoFocus(false)
	box:SetFontObject(Theme.Fonts.body)
	box:SetTextInsets(9, 9, 0, 0)
	box:SetMaxLetters(48)
	Theme:Skin(box, C.input, C.border)
	box.placeholder = Theme:Text(box, "body", placeholder, C.faint)
	box.placeholder:SetPoint("LEFT", 9, 0)
	local function UpdatePlaceholder()
		-- Shown until something is typed, focused or not: a dialog focuses its box straight away
		box.placeholder:SetShown(box:GetText() == "")
	end
	box:SetScript("OnEditFocusGained", function(self)
		Theme:SetBorderColor(self, C.accent)
		UpdatePlaceholder()
	end)
	box:SetScript("OnEditFocusLost", function(self)
		Theme:SetBorderColor(self, C.border)
		UpdatePlaceholder()
	end)
	box:SetScript("OnTextChanged", function(self, userInput)
		UpdatePlaceholder()
		if userInput and onChange then
			onChange(self:GetText())
		end
	end)
	box:SetScript("OnEscapePressed", box.ClearFocus)
	box:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
		if self.onEnter then
			self.onEnter()
		end
	end)
	function box:SetValue(text)
		self:SetText(text or "")
		UpdatePlaceholder()
	end
	UpdatePlaceholder()
	return box
end



-- ============================================================================
-- Toggle
-- ============================================================================

function W:Toggle(parent, text, onChange)
	local toggle = CreateFrame("Button", nil, parent)
	toggle:SetHeight(20)
	toggle.box = CreateFrame("Frame", nil, toggle)
	toggle.box:SetSize(15, 15)
	toggle.box:SetPoint("LEFT")
	Theme:Skin(toggle.box, C.input, C.borderLight)
	toggle.check = toggle.box:CreateTexture(nil, "ARTWORK")
	toggle.check:SetPoint("TOPLEFT", 3, -3)
	toggle.check:SetPoint("BOTTOMRIGHT", -3, 3)
	toggle.check:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)
	toggle.label = Theme:Text(toggle, "small", text, C.muted)
	toggle.label:SetPoint("LEFT", toggle.box, "RIGHT", 7, 0)
	toggle:SetWidth(15 + 7 + toggle.label:GetStringWidth() + 4)
	function toggle:SetChecked(checked)
		self.checked = checked and true or false
		self.check:SetShown(self.checked)
		self.label:SetTextColor(unpack(self.checked and C.text or C.muted))
	end
	toggle:SetScript("OnClick", function(self)
		self:SetChecked(not self.checked)
		if onChange then
			onChange(self.checked)
		end
	end)
	toggle:SetScript("OnEnter", function(self)
		Theme:SetBorderColor(self.box, C.accent)
		ShowTooltip(self)
	end)
	toggle:SetScript("OnLeave", function(self)
		Theme:SetBorderColor(self.box, C.borderLight)
		GameTooltip:Hide()
	end)
	toggle:SetChecked(false)
	return toggle
end



-- ============================================================================
-- Segmented control
-- ============================================================================

function W:Segmented(parent, items, onSelect, width)
	local control = CreateFrame("Frame", nil, parent)
	control:SetHeight(26)
	control.buttons = {}
	local x = 0
	for _, item in ipairs(items) do
		local button = W:Button(control, item.label, "secondary", width or 110, 26)
		button:SetPoint("LEFT", x, 0)
		button.key = item.key
		button:SetScript("OnClick", function()
			control:Select(item.key)
		end)
		tinsert(control.buttons, button)
		x = x + (width or 110) - 1
	end
	control:SetWidth(x + 1)
	function control:Select(key, silent)
		self.selected = key
		for _, button in ipairs(self.buttons) do
			button:SetStyle(button.key == key and "selected" or "secondary")
		end
		if not silent and onSelect then
			onSelect(key)
		end
	end
	return control
end



-- ============================================================================
-- Pill, card, stat tile
-- ============================================================================

function W:Pill(parent)
	local pill = CreateFrame("Frame", nil, parent)
	pill:SetHeight(18)
	pill._bg = Theme:Fill(pill, C.transparent)
	Theme:Border(pill, C.transparent)
	pill.text = Theme:Text(pill, "tiny", "")
	pill.text:SetPoint("CENTER", 0, 0)
	function pill:Set(text, color)
		if not text or text == "" then
			self:Hide()
			return
		end
		color = color or C.muted
		self.text:SetText(text)
		self.text:SetTextColor(color[1], color[2], color[3])
		self._bg:SetColorTexture(color[1], color[2], color[3], 0.14)
		Theme:SetBorderColor(self, { color[1], color[2], color[3], 0.45 })
		self:SetWidth(self.text:GetStringWidth() + 16)
		self:Show()
	end
	return pill
end


function W:Card(parent)
	local card = CreateFrame("Frame", nil, parent)
	Theme:Skin(card, C.panel, C.border)
	return card
end

function W:StatTile(parent, label, accent)
	local tile = W:Card(parent)
	tile:SetHeight(66)
	tile.bar = tile:CreateTexture(nil, "ARTWORK")
	tile.bar:SetPoint("TOPLEFT", 1, -1)
	tile.bar:SetPoint("BOTTOMLEFT", 1, 1)
	tile.bar:SetWidth(3)
	local color = accent or C.accent
	tile.bar:SetColorTexture(color[1], color[2], color[3], 1)
	tile.label = Theme:Text(tile, "tiny", strupper(label))
	tile.label:SetPoint("TOPLEFT", 16, -12)
	tile.value = Theme:Text(tile, "stat", "")
	tile.value:SetPoint("TOPLEFT", 16, -28)
	-- The note sits beside the value, not the label: on a narrow tile a long label and note ran together
	tile.note = Theme:Text(tile, "tiny", "")
	tile.note:SetPoint("BOTTOMRIGHT", -12, 14)
	tile.note:SetJustifyH("RIGHT")
	return tile
end

function W:SectionLabel(parent, text)
	return Theme:Text(parent, "tiny", strupper(text))
end



-- ============================================================================
-- List
-- ============================================================================

---A virtual list: a fixed number of rows reused for any number of items, scrolled by the mouse wheel.
---@param parent Frame
---@param rowHeight number
---@param numRows number
---@param createRow fun(row: Button)
---@param updateRow fun(row: Button, item: any, index: number)
function W:List(parent, rowHeight, numRows, createRow, updateRow)
	local list = CreateFrame("Frame", nil, parent)
	list:SetHeight(rowHeight * numRows)
	list.rows = {}
	list.items = {}
	list.offset = 0
	list.numRows = numRows
	for i = 1, numRows do
		local row = CreateFrame("Button", nil, list)
		row:SetHeight(rowHeight)
		row:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
		row:SetPoint("TOPRIGHT", -12, -(i - 1) * rowHeight)
		row.stripe = Theme:Fill(row, i % 2 == 0 and C.rowAlt or C.transparent)
		row.highlight = Theme:Fill(row, C.hover, "BACKGROUND")
		row.highlight:Hide()
		row.divider = Theme:Line(row, { 1, 1, 1, 0.04 })
		row.divider:SetPoint("BOTTOMLEFT")
		row.divider:SetPoint("BOTTOMRIGHT")
		row:SetScript("OnEnter", function(self)
			self.highlight:Show()
			if list.onEnter and self.item then
				list.onEnter(self, self.item)
			end
		end)
		row:SetScript("OnLeave", function(self)
			self.highlight:Hide()
			GameTooltip:Hide()
		end)
		row:SetScript("OnClick", function(self)
			if list.onClick and self.item then
				list.onClick(self.item, self)
			end
		end)
		createRow(row)
		list.rows[i] = row
	end
	-- Scroll bar
	list.track = list:CreateTexture(nil, "BORDER")
	list.track:SetPoint("TOPRIGHT", -3, 0)
	list.track:SetPoint("BOTTOMRIGHT", -3, 0)
	list.track:SetWidth(2)
	list.track:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)
	list.thumb = list:CreateTexture(nil, "ARTWORK")
	list.thumb:SetWidth(4)
	list.thumb:SetColorTexture(C.muted[1], C.muted[2], C.muted[3], 0.8)
	list.empty = Theme:Text(list, "body", "", C.faint)
	list.empty:SetPoint("CENTER", 0, 10)
	list.empty:SetJustifyH("CENTER")
	list.emptyHint = Theme:Text(list, "small", "", C.faint)
	list.emptyHint:SetPoint("TOP", list.empty, "BOTTOM", 0, -6)
	list.emptyHint:SetJustifyH("CENTER")
	list:EnableMouseWheel(true)
	list:SetScript("OnMouseWheel", function(self, delta)
		local maxOffset = max(#self.items - self.numRows, 0)
		self.offset = max(0, min(self.offset - delta * 2, maxOffset))
		self:Draw()
	end)
	function list:SetItems(items, emptyText, emptyHint)
		self.items = items or {}
		self.emptyText = emptyText
		self.emptyHintText = emptyHint
		self.offset = min(self.offset, max(#self.items - self.numRows, 0))
		self:Draw()
	end
	function list:Draw()
		for i, row in ipairs(self.rows) do
			local item = self.items[i + self.offset]
			row.item = item
			if item then
				updateRow(row, item, i + self.offset)
				row:Show()
			else
				row:Hide()
			end
		end
		local total = #self.items
		local empty = total == 0
		self.empty:SetText(empty and (self.emptyText or "Nothing here yet.") or "")
		self.emptyHint:SetText(empty and (self.emptyHintText or "") or "")
		if total > self.numRows then
			local trackHeight = self:GetHeight()
			local thumbHeight = max(trackHeight * self.numRows / total, 24)
			local position = (self.offset / (total - self.numRows)) * (trackHeight - thumbHeight)
			self.thumb:SetHeight(thumbHeight)
			self.thumb:ClearAllPoints()
			self.thumb:SetPoint("TOPRIGHT", -2, -position)
			self.thumb:Show()
			self.track:Show()
		else
			self.thumb:Hide()
			self.track:Hide()
		end
	end
	return list
end



-- ============================================================================
-- Dialog
-- ============================================================================

local dialog = nil

local function CreateDialog()
	-- The dialog lives on UIParent so it shows from the Nearby window with the main window closed too. When
	-- the main window is open, a dim layer over it keeps its buttons from being clicked meanwhile.
	local blocker = CreateFrame("Frame", nil, UIParent)
	blocker:SetFrameStrata("FULLSCREEN_DIALOG")
	blocker:EnableMouse(true)
	blocker:EnableMouseWheel(true)
	blocker:SetScript("OnMouseWheel", function() end)
	blocker._bg = Theme:Fill(blocker, { 0, 0, 0, 0.55 })
	blocker:Hide()

	local frame = CreateFrame("Frame", nil, blocker)
	frame:SetSize(400, 170)
	frame:SetFrameStrata("FULLSCREEN_DIALOG")
	frame:SetFrameLevel(blocker:GetFrameLevel() + 5)
	Theme:Skin(frame, C.panel, C.borderLight)
	frame.bar = frame:CreateTexture(nil, "ARTWORK")
	frame.bar:SetPoint("TOPLEFT", 1, -1)
	frame.bar:SetPoint("TOPRIGHT", -1, -1)
	frame.bar:SetHeight(3)
	frame.title = Theme:Text(frame, "heading", "")
	frame.title:SetPoint("TOPLEFT", 20, -20)
	frame.message = Theme:Text(frame, "body", "", C.muted)
	frame.message:SetPoint("TOPLEFT", 20, -44)
	frame.message:SetPoint("TOPRIGHT", -20, -44)
	frame.message:SetWordWrap(true)
	frame.message:SetJustifyV("TOP")
	frame.input = W:Input(frame, 200, "")
	frame.cancel = W:Button(frame, "Cancel", "ghost", 90, 28)
	frame.cancel:SetPoint("BOTTOMRIGHT", -118, 16)
	frame.confirm = W:Button(frame, "OK", "primary", 100, 28)
	frame.confirm:SetPoint("BOTTOMRIGHT", -16, 16)
	frame.cancel:SetScript("OnClick", function()
		blocker:Hide()
	end)
	frame.confirm:SetScript("OnClick", function()
		local options = frame.options
		local value = options.input and frame.input:GetText() or nil
		if options.validate then
			local err = options.validate(value)
			if err then
				frame.error:SetText(err)
				return
			end
		end
		blocker:Hide()
		if options.onConfirm then
			options.onConfirm(value)
		end
	end)
	frame.input.onEnter = function()
		frame.confirm:Click()
	end
	frame.error = Theme:Text(frame, "small", "", C.red)
	frame.error:SetPoint("BOTTOMLEFT", 20, 24)
	-- Escape in the input cancels; keyboard capture on the blocker would be blocked in combat
	frame.input:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
		blocker:Hide()
	end)
	blocker.frame = frame
	return blocker
end

---Shows a modal dialog over the Wanted window.
---@param options table title, text, input = { placeholder, value }, confirmLabel, confirmStyle, validate(value) -> err?, onConfirm(value)
function W:Dialog(options)
	dialog = dialog or CreateDialog()
	local frame = dialog.frame
	-- Dim the main window if it's open, and centre the dialog on it; otherwise centre on the screen with
	-- nothing dimmed (the blocker shrinks to nothing so the game stays clickable)
	local host = Wanted.UI and Wanted.UI:IsShown() and Wanted.UI:GetFrame() or nil
	dialog:ClearAllPoints()
	frame:ClearAllPoints()
	if host then
		dialog:SetAllPoints(host)
		dialog._bg:SetShown(true)
		frame:SetPoint("CENTER", host, "CENTER", 0, 20)
	else
		dialog:SetPoint("CENTER", UIParent, "CENTER")
		dialog:SetSize(1, 1)
		dialog._bg:SetShown(false)
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
	end
	frame.options = options
	local accent = options.confirmStyle == "danger" and C.red or C.accent
	frame.bar:SetColorTexture(accent[1], accent[2], accent[3], 1)
	frame.title:SetText(options.title or "")
	frame.message:SetText(options.text or "")
	frame.error:SetText("")
	frame.confirm:SetText(options.confirmLabel or "OK")
	frame.confirm:SetStyle(options.confirmStyle == "danger" and "danger" or (options.confirmStyle or "primary"))
	frame.input:ClearAllPoints()
	if options.input then
		frame.input:SetPoint("BOTTOMLEFT", 20, 56)
		frame.input.placeholder:SetText(options.input.placeholder or "")
		frame.input:SetValue(options.input.value or "")
		frame.input:Show()
	else
		frame.input:Hide()
	end
	-- Tall enough for the whole message: title and top margin, the text, the input if any, the buttons
	local messageHeight = ceil(frame.message:GetStringHeight() or 0)
	frame:SetHeight(max(options.input and 190 or 150, 44 + messageHeight + (options.input and 52 or 12) + 60))
	dialog:Show()
	if options.input then
		frame.input:SetFocus()
	end
end



-- ============================================================================
-- Menu
-- ============================================================================

local menu = nil

local function CreateMenu()
	local frame = CreateFrame("Frame", nil, UIParent)
	frame:SetFrameStrata("TOOLTIP")
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	Theme:Skin(frame, C.panel, C.borderLight)
	frame.items = {}
	frame:Hide()
	-- Close on any click outside it
	frame:RegisterEvent("GLOBAL_MOUSE_DOWN")
	frame:SetScript("OnEvent", function(self)
		if self:IsShown() and not self:IsMouseOver() then
			self:Hide()
		end
	end)
	return frame
end

---Shows a menu at the cursor.
---@param items table[] { text, color?, onClick?, header?, disabled? } or "-" for a divider
function W:Menu(items)
	menu = menu or CreateMenu()
	for _, item in ipairs(menu.items) do
		item:Hide()
	end
	local y, width = -6, 160
	local index = 0
	for _, def in ipairs(items) do
		index = index + 1
		local item = menu.items[index]
		if not item then
			item = CreateFrame("Button", nil, menu)
			item:SetHeight(22)
			item.highlight = Theme:Fill(item, C.transparent)
			item.label = Theme:Text(item, "body", "")
			item.label:SetPoint("LEFT", 12, 0)
			item.line = Theme:Line(item)
			item.line:SetPoint("LEFT", 8, 0)
			item.line:SetPoint("RIGHT", -8, 0)
			item:SetScript("OnEnter", function(self)
				if self.def and self.def.onClick and not self.def.disabled then
					self.highlight:SetColorTexture(1, 1, 1, 0.07)
				end
			end)
			item:SetScript("OnLeave", function(self)
				self.highlight:SetColorTexture(0, 0, 0, 0)
			end)
			item:SetScript("OnClick", function(self)
				local d = self.def
				if d and d.onClick and not d.disabled then
					menu:Hide()
					d.onClick()
				end
			end)
			menu.items[index] = item
		end
		item.def = def ~= "-" and def or nil
		item:ClearAllPoints()
		item:SetPoint("TOPLEFT", 1, y)
		item:SetPoint("TOPRIGHT", -1, y)
		if def == "-" then
			item:SetHeight(9)
			item.label:SetText("")
			item.line:Show()
			y = y - 9
		else
			item:SetHeight(def.header and 24 or 22)
			item.line:Hide()
			item.label:SetFontObject(def.header and Theme.Fonts.heading or Theme.Fonts.body)
			item.label:SetText(def.text)
			local color = def.disabled and C.faint or (def.color or (def.header and C.white or C.text))
			item.label:SetTextColor(color[1], color[2], color[3])
			width = max(width, item.label:GetStringWidth() + 32)
			y = y - (def.header and 24 or 22)
		end
		item.highlight:SetColorTexture(0, 0, 0, 0)
		item:Show()
	end
	menu:SetSize(width, -y + 6)
	local scale = UIParent:GetEffectiveScale()
	local x, cy = GetCursorPosition()
	menu:ClearAllPoints()
	menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, cy / scale)
	menu:Show()
end
