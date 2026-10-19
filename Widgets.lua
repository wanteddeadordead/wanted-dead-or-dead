-- Wanted: the widget set. Flat buttons with hover and pressed states, inputs with placeholders, toggles,
-- segmented controls, pills, cards, stat tiles, a virtual scrolling list, and a modal dialog.

local _, Wanted = ...
local W = {}
Wanted.Widgets = W
local Theme = Wanted.Theme
local C = Theme.C

local STYLES = {
	primary = { bg = C.accent, hover = C.accentHover, border = C.accent, text = C.white },
	-- EllesmereUI's buttons: a dark see-through fill, a white border at 30% that brightens to 45% under the mouse
	secondary = { bg = { 0.09, 0.08, 0.07, 0.6 }, hover = { 0.13, 0.12, 0.11, 0.7 }, border = { 1, 1, 1, 0.3 }, hoverBorder = { 1, 1, 1, 0.45 },
		text = { 0.86, 0.86, 0.88 }, hoverText = C.white },
	ghost = { bg = C.transparent, hover = C.hover, border = C.transparent, text = C.muted, hoverText = C.text },
	success = { bg = { 0.2, 0.46, 0.27, 1 }, hover = { 0.25, 0.56, 0.33, 1 }, border = { 0.28, 0.6, 0.36, 1 }, text = C.white },
	danger = { bg = C.transparent, hover = C.redDim, border = C.red, text = C.red },
	selected = { bg = C.accentDim, hover = C.accentDim, border = C.accent, text = C.white },
	-- Tabs: words with an accent line under the one shown, as EllesmereUI draws them
	tab = { bg = C.transparent, hover = C.transparent, border = C.transparent, text = C.muted, hoverText = C.text },
	tabSelected = { bg = C.transparent, hover = C.transparent, border = C.transparent, text = C.white },
	chip = { bg = C.transparent, hover = C.hover, border = C.border, text = C.muted, hoverText = C.text },
	-- EllesmereUI's dropdown field: a warm near-black, its value at 62% white
	field = { bg = C.field, hover = C.fieldHover, border = C.fieldBorder, hoverBorder = C.fieldBorderHover, text = { 1, 1, 1, 0.62 },
		hoverText = { 1, 1, 1, 0.75 } },
}



-- ============================================================================
-- Tooltip helper
-- ============================================================================

-- EllesmereUI's tooltip box with a gold title over a light body. It is our own frame, not GameTooltip: GameTooltip
-- is shared with the game and every other addon (skins, unit and item hooks), and restyling it for our owners would
-- have to be undone on every hide, by us and in the right order with them.
local TIP_WIDTH, TIP_PAD, TIP_GAP = 260, 8, 4
local MEDIA = "Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\"
-- GameTooltip's anchor names: the tip's point, the owner's point it sits on, and the offset
local TIP_ANCHORS = {
	ANCHOR_TOP = { "BOTTOM", "TOP", 0, TIP_GAP },
	ANCHOR_BOTTOM = { "TOP", "BOTTOM", 0, -TIP_GAP },
	ANCHOR_LEFT = { "BOTTOMRIGHT", "TOPLEFT", 0, TIP_GAP },
	ANCHOR_RIGHT = { "BOTTOMLEFT", "TOPRIGHT", 0, TIP_GAP },
}
local tip = nil

local function CreateTip()
	local frame = CreateFrame("Frame", "WantedTooltip", UIParent)
	frame:SetFrameStrata("TOOLTIP")
	frame:SetFrameLevel(100) -- over the menu, which shares the strata
	frame:SetClampedToScreen(true)
	Theme:Skin(frame, C.tipBg, C.tipBorder)
	frame.title = Theme:Text(frame, "body", "", C.tipTitle)
	frame.title:SetPoint("TOPLEFT", TIP_PAD, -TIP_PAD)
	frame.title:SetWordWrap(true)
	frame.body = Theme:Text(frame, "small", "")
	frame.body:SetTextColor(C.tipBody[1], C.tipBody[2], C.tipBody[3], C.tipBody[4])
	frame.body:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 0, -4)
	frame.body:SetWordWrap(true)
	frame:Hide()
	-- Gone with its owner: a menu closing under the mouse, a page switched
	frame:SetScript("OnUpdate", function(self)
		if not (self.owner and self.owner:IsVisible()) then
			self:Hide()
		end
	end)
	-- Many OnLeave handlers, ours and the pages', hide GameTooltip: that hides this too
	hooksecurefunc(GameTooltip, "Hide", function() frame:Hide() end)
	return frame
end

local function HideTooltip()
	if tip then
		tip:Hide()
	end
end

local function ShowTooltip(frame)
	local title = frame.tooltipTitle
	-- A FontString's hit button: nothing to explain while its text is hidden
	if not title or (frame.explainedText and not frame.explainedText:IsVisible()) then
		return
	end
	local body = frame.tooltipText
	if type(body) == "function" then
		body = body()
	end
	local hasBody = body ~= nil and body ~= ""
	tip = tip or CreateTip()
	tip.owner = frame
	tip.title:SetText(title)
	tip.body:SetText(hasBody and body or "")
	tip.body:SetShown(hasBody)
	-- As wide as the longer line, wrapping past TIP_WIDTH
	local width = ceil(min(TIP_WIDTH - TIP_PAD * 2,
		max(tip.title:GetUnboundedStringWidth(), hasBody and tip.body:GetUnboundedStringWidth() or 0)))
	tip.title:SetWidth(width)
	tip.body:SetWidth(width)
	local height = tip.title:GetStringHeight() + (hasBody and 4 + tip.body:GetStringHeight() or 0)
	tip:SetSize(width + TIP_PAD * 2, ceil(height) + TIP_PAD * 2)
	local anchor = TIP_ANCHORS[frame.tooltipAnchor or "ANCHOR_TOP"] or TIP_ANCHORS.ANCHOR_TOP
	tip:ClearAllPoints()
	tip:SetPoint(anchor[1], frame, anchor[2], anchor[3], anchor[4])
	tip:Show()
end

---A FontString can't take the mouse: a Button over its text does, and lets clicks through to what is under it.
local function HitButton(text)
	local parent = text:GetParent()
	local hit = CreateFrame("Button", nil, parent)
	hit:SetMouseClickEnabled(false)
	hit:SetMouseMotionEnabled(true)
	hit.explainedText = text
	hit.showsTooltip = true
	text.explainHit = hit
	-- Inside a clickable row the text takes the mouse from the row: the row's own OnEnter and OnLeave still run, so it
	-- stays lit, and its own GameTooltip gives way to the text's
	local clickable = parent:IsObjectType("Button")
	hit:SetScript("OnEnter", function(self)
		local enter = clickable and parent:GetScript("OnEnter")
		if enter then
			enter(parent)
			if GameTooltip:IsOwned(parent) then
				GameTooltip:Hide()
			end
		end
		ShowTooltip(self)
	end)
	hit:SetScript("OnLeave", function()
		local leave = clickable and parent:GetScript("OnLeave")
		if leave then
			leave(parent)
		end
		HideTooltip()
	end)
	local function Fit()
		local justify = text:GetJustifyH()
		local point = (justify == "CENTER" or justify == "RIGHT") and justify or "LEFT"
		hit:ClearAllPoints()
		hit:SetPoint(point, text, point)
		hit:SetSize(max(text:GetStringWidth(), 1), max(text:GetStringHeight(), 1))
	end
	hooksecurefunc(text, "SetText", Fit)
	Fit()
	return hit
end

---Explains a frame on hover: our tooltip with a gold title and a light body. Call it again to change the text.
---@param frame table a widget, a plain frame or a FontString (a FontString gets a hit button sized to its text)
---@param title string
---@param body string|fun(): string?|nil a function is called on each hover, for text that follows the state
---@param anchor string? a GameTooltip anchor: ANCHOR_TOP (default), ANCHOR_BOTTOM, ANCHOR_LEFT or ANCHOR_RIGHT
---@return table owner the frame that shows the tooltip
function W:Explain(frame, title, body, anchor)
	local owner = frame
	if frame.GetObjectType and frame:GetObjectType() == "FontString" then
		owner = frame.explainHit or HitButton(frame)
	end
	owner.tooltipTitle, owner.tooltipText, owner.tooltipAnchor = title, body, anchor
	-- Our widgets show it from their own OnEnter; anything else is hooked once, for motion only, so clicks still
	-- reach what is underneath
	if not owner.showsTooltip then
		owner.showsTooltip = true
		owner:SetMouseMotionEnabled(true)
		owner:HookScript("OnEnter", ShowTooltip)
		owner:HookScript("OnLeave", HideTooltip)
	end
	-- A disabled button still says why it is disabled
	if owner.SetMotionScriptsWhileDisabled then
		owner:SetMotionScriptsWhileDisabled(true)
	end
	return owner
end

-- The older name, kept for its callers
W.AttachTooltip = W.Explain

---A small (i) that only explains: a rule for a whole card or section, or how to fill an empty list. Anchor it
---yourself, usually glyph:SetPoint("LEFT", label, "RIGHT", 4, 0).
---@param parent table
---@param title string
---@param body string|fun(): string?
---@param size number? default 14
---@return table glyph a Button
function W:InfoGlyph(parent, title, body, size)
	local glyph = CreateFrame("Button", nil, parent)
	glyph:SetSize(size or 14, size or 14)
	glyph.ring = glyph:CreateTexture(nil, "ARTWORK")
	glyph.ring:SetAllPoints()
	glyph.ring:SetTexture(MEDIA.."ring")
	glyph.letter = glyph:CreateTexture(nil, "OVERLAY")
	glyph.letter:SetAllPoints()
	glyph.letter:SetTexture(MEDIA.."info-i")
	local function Light(ring, letter)
		glyph.ring:SetVertexColor(1, 1, 1, ring)
		glyph.letter:SetVertexColor(1, 1, 1, letter)
	end
	glyph:SetScript("OnEnter", function(self)
		Light(0.8, 0.8)
		ShowTooltip(self)
	end)
	glyph:SetScript("OnLeave", function()
		Light(0.3, 0.55)
		HideTooltip()
	end)
	glyph.showsTooltip = true
	Light(0.3, 0.55)
	return W:Explain(glyph, title, body)
end



-- ============================================================================
-- Button
-- ============================================================================

-- A disabled button: EllesmereUI's faded text and edge
local DISABLED_TEXT, DISABLED_BORDER = { 1, 1, 1, 0.3 }, { 1, 1, 1, 0.12 }

local function RefreshButton(button)
	-- A segment paints itself (W:Segmented)
	if button.paint then
		return button:paint()
	end
	local style = button.style
	local enabled = button:IsEnabled()
	local bg = (enabled and button.hovered) and style.hover or style.bg
	if not enabled then
		-- A disabled button must not look pressable, whatever its style
		bg = style.bg[4] == 0 and style.bg or C.panelAlt
	end
	Theme:SetBg(button, bg)
	Theme:SetBorderColor(button, enabled and (button.hovered and style.hoverBorder or style.border) or DISABLED_BORDER)
	local text = (enabled and button.hovered and style.hoverText) or style.text
	if not enabled then
		text = DISABLED_TEXT
	end
	button.label:SetTextColor(text[1], text[2], text[3], text[4] or 1)
end

---@param template string? e.g. "SecureActionButtonTemplate" for a button that runs a macro
---@param name string? a global name, for a button a macro clicks (/click)
function W:Button(parent, text, style, width, height, onClick, template, name)
	local button = CreateFrame("Button", name, parent, template)
	button:SetSize(width or 96, height or 26)
	Theme:Skin(button, C.transparent, C.transparent)
	button.label = Theme:Text(button, "label", text)
	button.label:SetJustifyH("CENTER")
	button.label:SetPoint("CENTER")
	button:SetFontString(button.label)
	button.style = STYLES[style or "secondary"]
	function button:SetStyle(name)
		self.style = STYLES[name] or STYLES.secondary
		RefreshButton(self)
	end
	button.showsTooltip = true
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
	-- The label is the button's font string, so the game moves it while pressed and back on release. Moving it here
	-- as well left it a little higher after every click.
	button:SetPushedTextOffset(1, -1)
	if onClick then
		button:SetScript("OnClick", onClick)
	end
	RefreshButton(button)
	return button
end



-- ============================================================================
-- Input
-- ============================================================================

-- EllesmereUI's text field: typed text at 85% white, the placeholder at 35%
local FIELD_TEXT, FIELD_PLACEHOLDER = { 1, 1, 1, 0.85 }, { 1, 1, 1, 0.35 }

---A box holding text to copy (a link): click it and it selects all, typing puts the text back.
function W:CopyBox(parent, width, text)
	local box = CreateFrame("EditBox", nil, parent)
	box:SetSize(width, 28)
	box:SetAutoFocus(false)
	box:SetFontObject(Theme.Fonts.small)
	box:SetTextColor(FIELD_TEXT[1], FIELD_TEXT[2], FIELD_TEXT[3], FIELD_TEXT[4])
	box:SetTextInsets(10, 10, 0, 0)
	Theme:Skin(box, C.field, C.fieldBorder)
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
	box:SetSize(width, 28)
	box:SetAutoFocus(false)
	box:SetFontObject(Theme.Fonts.body)
	box:SetTextColor(FIELD_TEXT[1], FIELD_TEXT[2], FIELD_TEXT[3], FIELD_TEXT[4])
	box:SetTextInsets(10, 10, 0, 0)
	box:SetMaxLetters(48)
	Theme:Skin(box, C.field, C.fieldBorder)
	box.placeholder = Theme:Text(box, "body", placeholder)
	box.placeholder:SetTextColor(FIELD_PLACEHOLDER[1], FIELD_PLACEHOLDER[2], FIELD_PLACEHOLDER[3], FIELD_PLACEHOLDER[4])
	box.placeholder:SetPoint("LEFT", 10, 0)
	local function UpdatePlaceholder()
		-- Shown until something is typed, focused or not: a dialog focuses its box straight away
		box.placeholder:SetShown(box:GetText() == "")
	end
	box:SetScript("OnEditFocusGained", function(self)
		Theme:SetBorderColor(self, C.accent)
		UpdatePlaceholder()
	end)
	box:SetScript("OnEditFocusLost", function(self)
		Theme:SetBorderColor(self, C.fieldBorder)
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

-- EllesmereUI's checkbox: an 18 px box, its edge brighter when checked and under the mouse, the accent filling it
local CHECK_FILL = { 0.112, 0.105, 0.098, 1 }
local CHECK_EDGE, CHECK_EDGE_ON, CHECK_EDGE_HOVER = { 1, 1, 1, 0.05 }, { 1, 1, 1, 0.15 }, { 1, 1, 1, 0.25 }
local CHECK_LABEL = { 1, 1, 1, 0.8 }

function W:Toggle(parent, text, onChange)
	local toggle = CreateFrame("Button", nil, parent)
	toggle:SetHeight(20)
	toggle.box = CreateFrame("Frame", nil, toggle)
	toggle.box:SetSize(18, 18)
	toggle.box:SetPoint("LEFT")
	Theme:Skin(toggle.box, CHECK_FILL, CHECK_EDGE)
	toggle.check = toggle.box:CreateTexture(nil, "ARTWORK")
	toggle.check:SetPoint("TOPLEFT", 2, -2)
	toggle.check:SetPoint("BOTTOMRIGHT", -2, 2)
	toggle.check:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)
	toggle.label = Theme:Text(toggle, "label", text)
	toggle.label:SetPoint("LEFT", toggle.box, "RIGHT", 8, 0)
	toggle:SetWidth(18 + 8 + toggle.label:GetStringWidth() + 4)
	local function Edge(self)
		Theme:SetBorderColor(self.box, self.hovered and CHECK_EDGE_HOVER or (self.checked and CHECK_EDGE_ON or CHECK_EDGE))
	end
	function toggle:SetChecked(checked)
		self.checked = checked and true or false
		self.check:SetShown(self.checked)
		local color = self.checked and C.white or CHECK_LABEL
		self.label:SetTextColor(color[1], color[2], color[3], color[4] or 1)
		Edge(self)
	end
	toggle:SetScript("OnClick", function(self)
		self:SetChecked(not self.checked)
		if onChange then
			onChange(self.checked)
		end
	end)
	toggle.showsTooltip = true
	toggle:SetScript("OnEnter", function(self)
		self.hovered = true
		Edge(self)
		ShowTooltip(self)
	end)
	toggle:SetScript("OnLeave", function(self)
		self.hovered = false
		Edge(self)
		GameTooltip:Hide()
	end)
	toggle:SetChecked(false)
	return toggle
end



---A horizontal slider with its label above it and its value in a box at its right, where a number can be typed (Enter
---applies it, Escape puts the value back): SetValue(value) without calling onChange.
---@param format fun(value: number): string the value as shown
function W:Slider(parent, label, width, low, high, step, format, onChange)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(width, 34)
	holder.label = Theme:Text(holder, "small", label, C.muted)
	holder.label:SetPoint("TOPLEFT")
	-- EllesmereUI's value box: 40 by 26, 16 px after the track, centred on it
	local box = CreateFrame("EditBox", nil, holder)
	box:SetSize(40, 26)
	box:SetPoint("BOTTOMRIGHT")
	box:SetAutoFocus(false)
	box:SetFontObject(Theme.Fonts.small)
	box:SetTextColor(FIELD_TEXT[1], FIELD_TEXT[2], FIELD_TEXT[3], FIELD_TEXT[4])
	box:SetJustifyH("CENTER")
	box:SetMaxLetters(8)
	Theme:Skin(box, { 0.03, 0.023, 0.018, 0.25 }, C.border)
	holder.box = box
	holder.value = box
	local slider = CreateFrame("Slider", nil, holder)
	slider:SetOrientation("HORIZONTAL")
	slider:SetPoint("BOTTOMLEFT", 0, 7)
	slider:SetSize(width - 40 - 16, 12)
	slider:SetMinMaxValues(low, high)
	slider:SetValueStep(step)
	slider:SetObeyStepOnDrag(true)
	slider:EnableMouse(true)
	-- EllesmereUI's slider: a 4px track at white 16%, the accent filling it up to a 14px square thumb
	slider:SetHitRectInsets(0, 0, -4, -4)
	local track = slider:CreateTexture(nil, "BACKGROUND")
	track:SetPoint("LEFT")
	track:SetPoint("RIGHT")
	track:SetHeight(4)
	track:SetColorTexture(1, 1, 1, 0.16)
	local thumb = slider:CreateTexture(nil, "OVERLAY")
	thumb:SetSize(14, 14)
	thumb:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)
	slider:SetThumbTexture(thumb)
	local fill = slider:CreateTexture(nil, "BORDER")
	fill:SetPoint("LEFT", track, "LEFT")
	fill:SetPoint("RIGHT", thumb, "CENTER")
	fill:SetHeight(4)
	fill:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.75)
	holder.slider = slider
	function holder:SetValue(value)
		self.quiet = true
		self.slider:SetValue(value)
		self.box:SetText(format(value))
		self.quiet = false
	end
	slider:SetScript("OnValueChanged", function(_, value)
		-- Steps as the slider shows them, without float dust
		value = floor(value / step + 0.5) * step
		box:SetText(format(value))
		if not holder.quiet and onChange then
			onChange(value)
		end
	end)
	-- A typed number: kept within the range, on a step; anything else puts the value back
	local function Revert()
		box:SetText(format(floor(slider:GetValue() / step + 0.5) * step))
	end
	box:SetScript("OnEnterPressed", function(self)
		local typed = tonumber(strmatch(self:GetText() or "", "%-?[%d%.]+") or "")
		self:ClearFocus()
		if not typed then
			Revert()
			return
		end
		slider:SetValue(max(low, min(high, floor(typed / step + 0.5) * step)))
		Revert()
	end)
	box:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
		Revert()
	end)
	box:SetScript("OnEditFocusLost", Revert)
	box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	return holder
end

---EllesmereUI's dropdown: a field showing the current choice with a chevron, opening a menu of all of them with the
---current one in the accent. SetChoice(key) shows one.
---@param choices table[] { key, label }
function W:Choice(parent, width, choices, onSelect)
	local button = W:Button(parent, "", "field", width, 28)
	button.label:SetFontObject(Theme.Fonts.body)
	button.label:ClearAllPoints()
	button.label:SetPoint("LEFT", 10, 0)
	button.label:SetPoint("RIGHT", -26, 0)
	button.label:SetJustifyH("LEFT")
	button.chevron = button:CreateTexture(nil, "ARTWORK")
	button.chevron:SetSize(12, 12)
	button.chevron:SetPoint("RIGHT", -9, 0)
	button.chevron:SetTexture(MEDIA.."chevron")
	button.chevron:SetVertexColor(1, 1, 1, 0.5)
	button:HookScript("OnEnter", function(self) self.chevron:SetVertexColor(1, 1, 1, 0.75) end)
	button:HookScript("OnLeave", function(self) self.chevron:SetVertexColor(1, 1, 1, 0.5) end)
	---Changes what can be chosen.
	function button:SetChoices(list)
		choices = list
	end
	function button:SetChoice(key)
		self.key = key
		for _, choice in ipairs(choices) do
			if choice.key == key then
				self:SetText(choice.label)
			end
		end
	end
	button:SetScript("OnClick", function(self)
		local items = {}
		for _, choice in ipairs(choices) do
			tinsert(items, { text = choice.label, selected = choice.key == self.key, onClick = function()
				self:SetChoice(choice.key)
				onSelect(choice.key)
			end })
		end
		W:Menu(items, self)
	end)
	return button
end



-- ============================================================================
-- Segmented control
-- ============================================================================

-- EllesmereUI's segmented control: 28 px cells with a grey edge, the chosen one in the accent (edge, text and a 5%
-- wash), lighter under the mouse; the end cells round off
local SEGMENT_HEIGHT = 28
local SEGMENT_FILL, SEGMENT_EDGE = { 0.125, 0.125, 0.137, 0.95 }, { 0.467, 0.471, 0.482, 0.5 }
local SEGMENT_TEXT, SEGMENT_HOVER_TEXT = { 1, 1, 1, 0.6 }, { 1, 1, 1, 0.8 }

---Paints a cell for its state (it's a W:Button whose refresh lands here).
local function PaintSegment(button)
	local hovered = button.hovered and button:IsEnabled()
	local wash, lift, f, a = button.selected and 0.05 or 0, hovered and 0.04 or 0, SEGMENT_FILL, C.accent
	local r, g, b = f[1] + (a[1] - f[1]) * wash + lift, f[2] + (a[2] - f[2]) * wash + lift, f[3] + (a[3] - f[3]) * wash + lift
	button._bg:SetColorTexture(r, g, b, f[4])
	local edge = button.selected and C.accent or SEGMENT_EDGE
	Theme:SetBorderColor(button, edge)
	local text = button.selected and C.accent or (hovered and SEGMENT_HOVER_TEXT or SEGMENT_TEXT)
	button.label:SetTextColor(text[1], text[2], text[3], text[4] or 1)
	for _, cap in ipairs(button.caps or {}) do
		if cap.isFill then
			cap:SetVertexColor(r, g, b, f[4])
		else
			cap:SetVertexColor(edge[1], edge[2], edge[3], edge[4] or 1)
		end
	end
end

---Rounds a cell's outer ends: a half-disc of fill and a half-ring of edge (our Media\cap-fill and cap-ring, mirrored
---for the right) where the square corners were.
local function RoundEnds(button, left, right)
	local radius = SEGMENT_HEIGHT / 2
	local l, r = left and radius or 0, right and radius or 0
	local top, bottom, leftEdge, rightEdge = unpack(button._edges)
	button._bg:ClearAllPoints()
	button._bg:SetPoint("TOPLEFT", l, 0)
	button._bg:SetPoint("BOTTOMRIGHT", -r, 0)
	top:ClearAllPoints()
	top:SetPoint("TOPLEFT", l, 0)
	top:SetPoint("TOPRIGHT", -r, 0)
	bottom:ClearAllPoints()
	bottom:SetPoint("BOTTOMLEFT", l, 0)
	bottom:SetPoint("BOTTOMRIGHT", -r, 0)
	leftEdge:SetShown(not left)
	rightEdge:SetShown(not right)
	button.caps = {}
	local function Cap(side)
		for _, file in ipairs({ "cap-fill", "cap-ring" }) do
			local cap = button:CreateTexture(nil, file == "cap-fill" and "BACKGROUND" or "BORDER")
			cap:SetTexture(MEDIA..file)
			cap:SetSize(radius, SEGMENT_HEIGHT)
			cap:SetPoint(side)
			if side == "RIGHT" then
				cap:SetTexCoord(1, 0, 0, 1)
			end
			cap.isFill = file == "cap-fill"
			tinsert(button.caps, cap)
		end
	end
	if left then
		Cap("LEFT")
	end
	if right then
		Cap("RIGHT")
	end
end

local function Segments(parent, items, onSelect, width, tabs)
	local height = tabs and 26 or SEGMENT_HEIGHT
	local control = CreateFrame("Frame", nil, parent)
	control:SetHeight(height)
	control.buttons = {}
	local x = 0
	for _, item in ipairs(items) do
		local button = W:Button(control, item.label, "tab", width or 110, height)
		button:SetPoint("LEFT", x, 0)
		button.key = item.key
		if tabs then
			button.underline = button:CreateTexture(nil, "ARTWORK")
			button.underline:SetPoint("BOTTOM", 0, 0)
			button.underline:SetHeight(2)
			button.underline:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)
			button.underline:Hide()
		else
			button.paint = PaintSegment
		end
		button:SetScript("OnClick", function()
			control:Select(item.key)
		end)
		if item.tip then
			W:Explain(button, item.tip[1], item.tip[2])
		end
		tinsert(control.buttons, button)
		x = x + (width or 110) - 1
	end
	-- A label too long for its equal share: each button as wide as its label plus an equal share of the room left,
	-- never wider in all than the row was given (the Nearby window's tabs ran past its edge). Tight: less padding,
	-- down to MIN_PADDING; tighter still: the labels in a smaller font.
	local share, MIN_PADDING = width or 110, 10
	local count, room = #control.buttons, (width or 110) * #control.buttons - (#control.buttons - 1)
	local function Labels()
		local widths, total, tooLong = {}, 0, false
		for i, button in ipairs(control.buttons) do
			widths[i] = ceil(button.label:GetStringWidth())
			total = total + widths[i]
			tooLong = tooLong or widths[i] + 24 > share
		end
		return widths, total, tooLong
	end
	local widths, total, tooLong = Labels()
	if tooLong then
		if total + MIN_PADDING * count > room then
			for _, button in ipairs(control.buttons) do
				button.label:SetFontObject(Theme.Fonts.labelSmall)
			end
			widths, total = Labels()
		end
		local spare = max(room - total, 0) / count
		x = 0
		for i, button in ipairs(control.buttons) do
			local buttonWidth = i < count and floor(widths[i] + spare) or (room - x)
			button:SetWidth(buttonWidth)
			button:ClearAllPoints()
			button:SetPoint("LEFT", x, 0)
			x = x + buttonWidth - 1
		end
	end
	control:SetWidth(x + 1)
	if not tabs and count > 0 then
		RoundEnds(control.buttons[1], true, count == 1)
		if count > 1 then
			RoundEnds(control.buttons[count], false, true)
		end
	end
	function control:Select(key, silent)
		self.selected = key
		-- The buttons overlap by a pixel so their borders join: the selected one sits above its neighbours, so its
		-- whole outline shows (its left edge was drawn under the button before it)
		local level = self:GetFrameLevel()
		for _, button in ipairs(self.buttons) do
			button:SetFrameLevel(level + (button.key == key and 2 or 1))
			if tabs then
				button:SetStyle(button.key == key and "tabSelected" or "tab")
				button.underline:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)
				button.underline:SetWidth(min(button:GetWidth(), button.label:GetStringWidth() + 14))
				button.underline:SetShown(button.key == key)
			else
				button.selected = button.key == key
				PaintSegment(button)
			end
		end
		if not silent and onSelect then
			onSelect(key)
		end
	end
	if not tabs then
		for _, button in ipairs(control.buttons) do
			PaintSegment(button)
		end
	end
	return control
end

---EllesmereUI's segmented control, for a choice between a few options: Select(key, silent) picks one.
---@param items table[] { key, label, tip? = { title, body } }
function W:Segmented(parent, items, onSelect, width)
	return Segments(parent, items, onSelect, width, false)
end

---Tabs between the views of a page: words with an accent line under the one shown. Select(key, silent) as Segmented.
---@param items table[] { key, label, tip? = { title, body } }
function W:Tabs(parent, items, onSelect, width)
	return Segments(parent, items, onSelect, width, true)
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

---A card that opens something: it lights up under the mouse and shows a ">" in its top right corner.
---@param parent Frame
---@param onClick function
function W:CardButton(parent, onClick)
	local card = CreateFrame("Button", nil, parent)
	Theme:Skin(card, C.panel, C.border)
	card.arrow = Theme:Text(card, "small", ">", C.faint)
	card.arrow:SetPoint("TOPRIGHT", -10, -10)
	card:SetScript("OnClick", onClick)
	card.showsTooltip = true
	card:SetScript("OnEnter", function(self)
		Theme:SetBg(self, C.panelAlt)
		Theme:SetBorderColor(self, C.borderLight)
		ShowTooltip(self)
	end)
	card:SetScript("OnLeave", function(self)
		Theme:SetBg(self, C.panel)
		Theme:SetBorderColor(self, C.border)
		GameTooltip:Hide()
	end)
	return card
end

---A thin progress bar: SetValue(fraction, color).
---@param parent Frame
---@param height number?
function W:ProgressBar(parent, height)
	local bar = CreateFrame("Frame", nil, parent)
	bar:SetHeight(height or 8)
	Theme:Skin(bar, C.input, C.border)
	bar.fill = bar:CreateTexture(nil, "ARTWORK")
	bar.fill:SetPoint("TOPLEFT", 1, -1)
	bar.fill:SetPoint("BOTTOMLEFT", 1, 1)
	function bar:SetValue(fraction, color)
		fraction = max(0, min(1, fraction or 0))
		color = color or C.gold
		self.fill:SetColorTexture(color[1], color[2], color[3], 1)
		self.fill:SetWidth(max((self:GetWidth() - 2) * fraction, 0.01))
		self.fill:SetShown(fraction > 0)
	end
	return bar
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
	-- The value and the note share the bottom row: whenever either changes, the value fits what the note leaves it
	-- (a smaller font, then cut short), so "Wanted Season 1" never runs into "60d 0h left"
	local setValue, setNote = tile.value.SetText, tile.note.SetText
	local fitting = false
	function tile:Fit()
		if fitting then
			return
		end
		fitting = true
		local noteWidth = self.note:GetText() ~= "" and self.note:GetUnboundedStringWidth() + 12 or 0
		local room = self:GetWidth() - 16 - 12 - noteWidth
		if room > 0 then
			self.value:SetWidth(room)
			Theme:FitText(self.value, room, { self.value:GetText() or "" }, "heading")
		end
		fitting = false
	end
	tile.value.SetText = function(fs, text)
		setValue(fs, text)
		tile:Fit()
	end
	tile.note.SetText = function(fs, text)
		setNote(fs, text)
		tile:Fit()
	end
	return tile
end

---A section header: small capitals at 41% white, with a faint line under it when given a width.
---@param width number?
function W:SectionLabel(parent, text, width)
	local label = Theme:Text(parent, "labelSmall", strupper(text))
	label:SetTextColor(1, 1, 1, 0.41)
	if width then
		label.rule = Theme:Line(parent, { 1, 1, 1, 0.06 })
		label.rule:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -5)
		label.rule:SetWidth(width)
	end
	return label
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
	list.track:SetPoint("TOPRIGHT", -2, 0)
	list.track:SetPoint("BOTTOMRIGHT", -2, 0)
	list.track:SetWidth(4)
	list.track:SetColorTexture(1, 1, 1, 0.02)
	list.thumb = list:CreateTexture(nil, "ARTWORK")
	list.thumb:SetWidth(4)
	list.thumb:SetColorTexture(1, 1, 1, 0.27)
	list.empty = Theme:Text(list, "body", "", C.faint)
	list.empty:SetPoint("CENTER", 0, 10)
	list.empty:SetJustifyH("CENTER")
	-- How to fill it, on hover: an (i) after the empty text
	list.emptyGlyph = W:InfoGlyph(list, "")
	list.emptyGlyph:SetPoint("LEFT", list.empty, "RIGHT", 6, 0)
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
		local hint = empty and self.emptyHintText ~= nil and self.emptyHintText ~= ""
		W:Explain(self.emptyGlyph, self.empty:GetText(), hint and self.emptyHintText or nil)
		self.emptyGlyph:SetShown(hint)
		-- The text and its glyph centred together
		self.empty:SetPoint("CENTER", hint and -10 or 0, 10)
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
local AREA_HEIGHT = 74 -- a multiline dialog box: about four lines
local DIALOG_WIDTH = 390
local FIELD_Y = 62 -- the input's foot: above the error line, which sits over the buttons
local hookedHosts = {} -- windows whose closing closes the dialog over them
local waiting = {} -- { options, host } dialogs asked for while another was up: shown in turn, so none loses its answer
local waitingForCombat = false -- the next waits for the fight to end
local ShowNext -- below

local function CreateDialog()
	-- The dialog lives on UIParent so it shows from the Nearby window with the main window closed too. When
	-- the main window is open, a dim layer over it keeps its buttons from being clicked meanwhile.
	local blocker = CreateFrame("Frame", "WantedDialog", UIParent)
	blocker:SetFrameStrata("FULLSCREEN_DIALOG")
	blocker:EnableMouse(true)
	blocker:EnableMouseWheel(true)
	blocker:SetScript("OnMouseWheel", function() end)
	blocker._bg = Theme:Fill(blocker, { 0, 0, 0, 0.25 })
	blocker:Hide()

	local frame = CreateFrame("Frame", nil, blocker)
	-- EllesmereUI's popup: a warm dark box, its title and message centred, the buttons side by side at its foot
	frame:SetSize(DIALOG_WIDTH, 170)
	frame:SetFrameStrata("FULLSCREEN_DIALOG")
	frame:SetFrameLevel(blocker:GetFrameLevel() + 5)
	Theme:Skin(frame, { 0.077, 0.068, 0.058, 1 }, C.borderLight)
	frame.title = Theme:Text(frame, "dialogTitle", "")
	frame.title:SetPoint("TOPLEFT", 20, -20)
	frame.title:SetPoint("TOPRIGHT", -20, -20)
	frame.title:SetJustifyH("CENTER")
	frame.message = Theme:Text(frame, "body", "")
	frame.message:SetTextColor(1, 1, 1, 0.53)
	frame.message:SetPoint("TOPLEFT", 20, -46)
	frame.message:SetPoint("TOPRIGHT", -20, -46)
	frame.message:SetWordWrap(true)
	frame.message:SetJustifyH("CENTER")
	frame.message:SetJustifyV("TOP")
	frame.input = W:Input(frame, 200, "")
	frame.cancel = W:Button(frame, "Cancel", "secondary", 100, 27)
	frame.cancel:SetPoint("BOTTOMRIGHT", frame, "BOTTOM", -8, 16)
	frame.confirm = W:Button(frame, "OK", "primary", 100, 27)
	frame.confirm:SetPoint("BOTTOMLEFT", frame, "BOTTOM", 8, 16)
	-- Only the Cancel button is Cancel. Closed any other way (Escape, the game closing every window when control is
	-- lost to a fear or a flight, the main window closing under it) it's dismissed with no answer: onClose, if any.
	frame.cancel:SetScript("OnClick", function()
		if frame.decided then
			return
		end
		frame.decided = true
		local options = frame.options
		blocker:Hide()
		if options.onCancel then
			options.onCancel()
		end
	end)
	blocker:SetScript("OnHide", function()
		if blocker:IsShown() then
			return -- only out of sight with the whole interface (Alt+Z): still up, still waiting for an answer
		end
		if not frame.decided then
			frame.decided = true
			if frame.options and frame.options.onClose then
				frame.options.onClose()
			end
		end
		-- The next dialog waiting, a moment after this one closes (its answer may have opened another first)
		if #waiting > 0 then
			C_Timer.After(0, function() ShowNext() end)
		end
	end)
	-- Escape closes it (the game's list of windows Escape closes: keyboard capture would be blocked in combat)
	if UISpecialFrames then
		tinsert(UISpecialFrames, "WantedDialog")
	end
	frame.confirm:SetScript("OnClick", function()
		if frame.decided then
			return
		end
		local options = frame.options
		local value = options.input and (options.input.multiline and frame.area:GetText() or frame.input:GetText()) or nil
		if options.validate then
			local err = options.validate(value)
			if err then
				frame.error:SetText(err)
				return
			end
		end
		frame.decided = true
		blocker:Hide()
		if options.onConfirm then
			options.onConfirm(value, options.choice and frame.choiceKey or nil)
		end
	end)
	frame.input.onEnter = function()
		frame.confirm:Click()
	end
	-- A box for a longer text (input.multiline): the dialog's full width, wrapping over a few lines and scrolling past
	-- them (the game's scrolling edit box functions keep the cursor in view); Enter still confirms
	local areaBox = CreateFrame("Frame", nil, frame)
	Theme:Skin(areaBox, C.input, C.border)
	areaBox:Hide()
	local areaScroll = CreateFrame("ScrollFrame", nil, areaBox, "UIPanelScrollFrameTemplate")
	areaScroll.scrollBarHideable = true
	areaScroll:SetPoint("TOPLEFT")
	areaScroll:SetPoint("BOTTOMRIGHT", -24, 0)
	local area = CreateFrame("EditBox", nil, areaScroll)
	area:SetMultiLine(true)
	area:SetAutoFocus(false)
	area:SetFontObject(Theme.Fonts.body)
	area:SetTextInsets(9, 9, 7, 7)
	area:SetMaxLetters(255)
	area:SetHeight(AREA_HEIGHT)
	areaScroll:SetScrollChild(area)
	area:SetScript("OnCursorChanged", ScrollingEdit_OnCursorChanged)
	area:SetScript("OnUpdate", function(self, elapsed) ScrollingEdit_OnUpdate(self, elapsed, areaScroll) end)
	area:SetScript("OnEnterPressed", function() frame.confirm:Click() end)
	area:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
		blocker:Hide()
	end)
	-- A click below the last line still puts the cursor in the box
	areaBox:EnableMouse(true)
	areaBox:SetScript("OnMouseDown", function() area:SetFocus() end)
	frame.area, frame.areaBox, frame.areaScroll = area, areaBox, areaScroll
	-- A choice above the input (options.choice): a label and a dropdown
	frame.choiceLabel = Theme:Text(frame, "small", "", C.muted)
	frame.choice = W:Choice(frame, 260, {}, function(key)
		frame.choiceKey = key
	end)
	frame.choice:SetPoint("LEFT", frame.choiceLabel, "RIGHT", 10, 0)
	frame.error = Theme:Text(frame, "small", "", C.red)
	frame.error:SetPoint("BOTTOMLEFT", 20, 48)
	frame.error:SetPoint("BOTTOMRIGHT", -20, 48)
	frame.error:SetJustifyH("CENTER")
	-- Escape in the input closes it with no answer; keyboard capture on the blocker would be blocked in combat
	frame.input:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
		blocker:Hide()
	end)
	blocker.frame = frame
	return blocker
end

---Shows the next dialog waiting, unless one is up, a fight is on (it waits for the end), or the window it was
---asked for over has closed since (it's dropped).
ShowNext = function()
	if (dialog and dialog:IsShown()) or #waiting == 0 then
		return
	end
	if InCombatLockdown() or Wanted:InCombat() then
		if not waitingForCombat then
			waitingForCombat = true
			Wanted:OnCombatEnd(function() ShowNext() end)
		end
		return
	end
	local next = tremove(waiting, 1)
	if next.host and not next.host:IsShown() then
		ShowNext()
		return
	end
	W:Dialog(next.options)
end

---Shows a modal dialog over the Wanted window.
---@param options table title, text, input = { placeholder, value, multiline (a wide box wrapping a longer text), maxLetters
---(of a multiline box, default 255) }, over (a window to centre on, rather than the Wanted window or the screen), width
---(of the dialog, default 390), choice = { label, items = { { key, label } }, selected } (a dropdown above the input),
---confirmLabel, confirmStyle, validate(value) -> err?, onConfirm(value, chosen key), onCancel (the Cancel button only),
---onClose (closed with no answer: Escape, the game closing its windows, the main window closing)
---Whether a dialog is up (one at a time).
function W:IsDialogShown()
	return dialog ~= nil and dialog:IsShown()
end

function W:Dialog(options)
	dialog = dialog or CreateDialog()
	-- Dim the main window if it's open, and centre the dialog on it; otherwise centre on the screen with
	-- nothing dimmed (the blocker shrinks to nothing so the game stays clickable)
	local host = Wanted.UI and Wanted.UI:IsShown() and Wanted.UI:GetFrame() or nil
	if dialog:IsShown() then
		-- One at a time: this one waits its turn rather than take the open one's place (and its answer)
		tinsert(waiting, { options = options, host = host })
		return
	end
	local frame = dialog.frame
	dialog:ClearAllPoints()
	frame:ClearAllPoints()
	if host then
		dialog:SetAllPoints(host)
		dialog._bg:SetShown(true)
		frame:SetPoint("CENTER", host, "CENTER", 0, 20)
		-- The window closing takes its dialog with it, rather than leave the dim layer over nothing
		if not hookedHosts[host] then
			hookedHosts[host] = true
			host:HookScript("OnHide", function()
				if host:IsShown() then
					return -- only out of sight with the whole interface (Alt+Z)
				end
				-- Dialogs waiting to show over it go with it
				for i = #waiting, 1, -1 do
					if waiting[i].host == host then
						tremove(waiting, i)
					end
				end
				if dialog:IsShown() and dialog.host == host then
					dialog:Hide()
				end
			end)
		end
	else
		dialog:SetPoint("CENTER", UIParent, "CENTER")
		dialog:SetSize(1, 1)
		dialog._bg:SetShown(false)
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
	end
	-- Opened from another window (the bug report): over it
	if options.over and options.over:IsShown() then
		frame:ClearAllPoints()
		frame:SetPoint("CENTER", options.over, "CENTER")
	end
	frame.options, frame.decided, dialog.host = options, false, host
	frame.title:SetText(options.title or "")
	frame.message:SetText(options.text or "")
	frame.error:SetText("")
	frame.confirm:SetText(options.confirmLabel or "OK")
	frame.cancel:SetText(options.cancelLabel or "Cancel")
	frame.confirm:SetStyle(options.confirmStyle == "danger" and "danger" or (options.confirmStyle or "primary"))
	frame:SetWidth(options.width or DIALOG_WIDTH)
	frame.input:ClearAllPoints()
	frame.areaBox:Hide()
	local area = options.input and options.input.multiline
	if area then
		frame.input:Hide()
		frame.areaBox:ClearAllPoints()
		frame.areaBox:SetPoint("BOTTOMLEFT", 20, FIELD_Y)
		frame.areaBox:SetPoint("BOTTOMRIGHT", -20, FIELD_Y)
		frame.areaBox:SetHeight(AREA_HEIGHT)
		-- The dialog's width less its margins and the scroll bar's room
		frame.area:SetWidth((options.width or DIALOG_WIDTH) - 40 - 24)
		frame.area:SetMaxLetters(options.input.maxLetters or 255)
		-- At the top, whatever the last dialog's box was scrolled to
		frame.areaScroll:SetVerticalScroll(0)
		frame.area:SetText(options.input.value or "")
		frame.areaBox:Show()
	elseif options.input then
		frame.input:SetPoint("BOTTOMLEFT", 20, FIELD_Y)
		frame.input.placeholder:SetText(options.input.placeholder or "")
		-- Typed answers are held to 48 letters; a longer value to copy (a death page's address) fits whole
		frame.input:SetMaxLetters(max(48, #(options.input.value or "")))
		frame.input:SetValue(options.input.value or "")
		frame.input:Show()
	else
		frame.input:Hide()
	end
	local choice = options.choice
	frame.choiceLabel:SetShown(choice ~= nil)
	frame.choice:SetShown(choice ~= nil)
	if choice then
		frame.choiceLabel:ClearAllPoints()
		frame.choiceLabel:SetPoint("BOTTOMLEFT", 20, FIELD_Y + (area and AREA_HEIGHT or 28) + 16)
		frame.choiceLabel:SetText(choice.label or "")
		frame.choice:SetChoices(choice.items)
		frame.choice:SetChoice(choice.selected)
		frame.choiceKey = choice.selected
	end
	-- Tall enough for the whole message: title and top margin, the text, the choice and input if any, the buttons
	local messageHeight = ceil(frame.message:GetStringHeight() or 0)
	local inputRoom = (area and AREA_HEIGHT + 26 or options.input and 52 or 12) + (choice and 36 or 0)
	frame:SetHeight(max(options.input and 196 or 150, 46 + messageHeight + inputRoom + 66))
	dialog:Show()
	-- In front of anything else full screen (the wanted poster)
	dialog:Raise()
	if area then
		frame.area:SetFocus()
	elseif options.input then
		frame.input:SetFocus()
	end
end



-- ============================================================================
-- Menu
-- ============================================================================

local menu = nil

-- EllesmereUI's dropdown menu: the field's colours, 28 px rows, grey headers with a rule under them
local MENU_ROW, MENU_HEADER, MENU_DIVIDER = 28, 22, 9
local MENU_HEADER_TEXT = { 0.5, 0.5, 0.5 }

local function CreateMenu()
	local frame = CreateFrame("Frame", "WantedMenu", UIParent)
	-- Over the dialogs, which can open one
	frame:SetFrameStrata("FULLSCREEN_DIALOG")
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	Theme:Skin(frame, C.fieldHover, C.fieldBorder)
	frame.items = {}
	frame:Hide()
	-- Close on any click outside it
	frame:RegisterEvent("GLOBAL_MOUSE_DOWN")
	frame:SetScript("OnEvent", function(self)
		if self:IsShown() and not self:IsMouseOver() then
			self:Hide()
		end
	end)
	-- And on Escape (the game's list of windows Escape closes)
	if UISpecialFrames then
		tinsert(UISpecialFrames, "WantedMenu")
	end
	return frame
end

---Shows a menu under the frame that opened it (at least as wide), or at the cursor.
---@param items table[] { text, color?, onClick?, header?, disabled?, selected? (the current choice: in the accent),
---tip? = { title, body } } or "-" for a divider
---@param anchor table? the button that opened it
function W:Menu(items, anchor)
	menu = menu or CreateMenu()
	for _, item in ipairs(menu.items) do
		item:Hide()
	end
	local y, width = -4, max(160, anchor and anchor:GetWidth() or 0)
	local index = 0
	for _, def in ipairs(items) do
		index = index + 1
		local item = menu.items[index]
		if not item then
			item = CreateFrame("Button", nil, menu)
			item.highlight = Theme:Fill(item, C.transparent)
			item.label = Theme:Text(item, "body", "")
			item.label:SetPoint("LEFT", 12, 0)
			item.line = Theme:Line(item, C.fieldBorder)
			item.showsTooltip = true
			item:SetScript("OnEnter", function(self)
				if self.def and self.def.onClick and not self.def.disabled then
					self.highlight:SetColorTexture(1, 1, 1, 0.08)
				end
				ShowTooltip(self)
			end)
			item:SetScript("OnLeave", function(self)
				self.highlight:SetColorTexture(1, 1, 1, self.rest or 0)
				HideTooltip()
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
		-- Beside the menu, so it doesn't cover the items above
		local itemTip = def ~= "-" and def.tip
		W:Explain(item, itemTip and itemTip[1], itemTip and itemTip[2], "ANCHOR_RIGHT")
		item:ClearAllPoints()
		item:SetPoint("TOPLEFT", 1, y)
		item:SetPoint("TOPRIGHT", -1, y)
		item.line:ClearAllPoints()
		item.rest = 0
		if def == "-" then
			item:SetHeight(MENU_DIVIDER)
			item.label:SetText("")
			item.line:SetPoint("LEFT", 8, 0)
			item.line:SetPoint("RIGHT", -8, 0)
			item.line:Show()
			y = y - MENU_DIVIDER
		else
			local height = def.header and MENU_HEADER or MENU_ROW
			item:SetHeight(height)
			-- A header has a rule under it
			item.line:SetPoint("BOTTOMLEFT", 8, 1)
			item.line:SetPoint("BOTTOMRIGHT", -8, 1)
			item.line:SetShown(def.header == true)
			item.label:SetFontObject(def.header and Theme.Fonts.labelSmall or Theme.Fonts.body)
			item.label:SetText(def.text)
			local color = def.disabled and C.faint or (def.selected and C.accent) or def.color or (def.header and MENU_HEADER_TEXT or C.text)
			item.label:SetTextColor(color[1], color[2], color[3])
			item.rest = def.selected and 0.04 or 0
			width = max(width, item.label:GetStringWidth() + 32)
			y = y - height
		end
		item.highlight:SetColorTexture(1, 1, 1, item.rest)
		item:Show()
	end
	menu:SetSize(width, -y + 4)
	menu:ClearAllPoints()
	menu:SetClampedToScreen(true)
	if anchor then
		menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
	else
		local scale = menu:GetEffectiveScale()
		local x, cy = GetCursorPosition()
		menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, cy / scale)
	end
	menu:Show()
	-- Above whatever else is up in its strata (a dialog raised itself on showing)
	menu:Raise()
end

---Hides the menu, if it's up.
function W:HideMenu()
	if menu then
		menu:Hide()
	end
end



-- ============================================================================
-- Suggestions
-- ============================================================================

local MOST_SUGGESTIONS = 8

---The names that match what's typed, ignoring case: those starting with it, then those with it anywhere, at most
---MOST_SUGGESTIONS. Nothing typed matches nothing.
---@param names string[]
---@param text string
---@return string[]
function W:Matches(names, text)
	local typed = strlower(strtrim and strtrim(text or "") or text or "")
	local starts, inside = {}, {}
	if typed == "" then
		return starts
	end
	for _, name in ipairs(names) do
		local at = strfind(strlower(name), typed, 1, true)
		if at == 1 then
			tinsert(starts, name)
		elseif at then
			tinsert(inside, name)
		end
	end
	for _, name in ipairs(inside) do
		tinsert(starts, name)
	end
	for i = #starts, MOST_SUGGESTIONS + 1, -1 do
		starts[i] = nil
	end
	return starts
end

---Suggests names under an input as you type (a menu of matches from source(), called each time): click one, or
---press Tab for the first, to fill it in. Anything else typed stays as typed.
---@param box table an input from W:Input
---@param source fun(): string[]
function W:Suggest(box, source)
	local first
	local function Take(name)
		box:SetValue(name)
		W:HideMenu()
		first = nil
	end
	box:HookScript("OnTextChanged", function(self, userInput)
		if not userInput then
			return
		end
		local matches = W:Matches(source(), self:GetText())
		first = matches[1]
		-- Nothing to offer, or it's already typed in full
		if not first or (#matches == 1 and strlower(first) == strlower(self:GetText())) then
			first = nil
			W:HideMenu()
			return
		end
		local items = {}
		for _, name in ipairs(matches) do
			tinsert(items, { text = name, onClick = function() Take(name) end })
		end
		W:Menu(items, self)
	end)
	box:HookScript("OnTabPressed", function()
		if first then
			Take(first)
		end
	end)
	-- Escape, Enter or clicking elsewhere ends it; a click on a suggestion is the menu's own
	box:HookScript("OnEditFocusLost", function()
		if menu and not menu:IsMouseOver() then
			menu:Hide()
			first = nil
		end
	end)
end
