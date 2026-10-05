-- Wanted: other players' challenge ranks, where you meet them: a line in the unit tooltip, a label over the target
-- frame, a small number over nameplates, a tag in chat (off by default), and beside names in the Nearby window and
-- the Who list. Ranks come only from wanteddeadordead.com through the Wanted app (Challenges:GetRank); a player
-- never says their own. Each place has its own switch (settings.ranks).
--
-- Nothing here touches a secure frame: the target label is a frame of our own that follows the target frame (ElvUI's
-- when it's there), the nameplate numbers are our own frames on the plates the game lets addons have (never forbidden
-- ones), on the frame a nameplate addon draws there when there is one (ElvUI and Plater: plate.unitFrame), and the Who
-- list gets its own text beside the name rather than a changed name (the game reads that name back to whisper).

local _, Wanted = ...
local Ranks = Wanted:NewModule("Ranks")
local private = {
	frame = CreateFrame("Frame"),
	plates = {}, -- nameplate frame -> our label on it
	whoLabels = {}, -- Who list button -> our label on it
}
local BADGE_SIZE = 14
-- Chat where a player says something; the tag goes at the start of what they said
local CHAT_EVENTS = {
	"CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_CHANNEL", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_PARTY",
	"CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_INSTANCE_CHAT",
	"CHAT_MSG_INSTANCE_CHAT_LEADER", "CHAT_MSG_WHISPER", "CHAT_MSG_EMOTE",
}

function private.Settings()
	return Wanted.db.settings.ranks
end

---A value the addon may read (not one of the client's secret values).
function private.Readable(value)
	return not (issecretvalue and issecretvalue(value))
end



-- ============================================================================
-- Looking ranks up
-- ============================================================================

---A unit's challenge rank ({ r, f }), or nil: players only, by their full name ("First Last").
---@param unit string
---@return table?
function Ranks:ForUnit(unit)
	-- A tooltip can hand over a secret unit token, which UnitIsPlayer refuses from addon code
	-- Nor any unit in an instance, where identity is secret
	if Wanted:InInstance() or not private.Readable(unit) or not UnitIsPlayer(unit) then
		return nil
	end
	local name, surname = UnitName(unit)
	if type(name) ~= "string" or not private.Readable(name) or not private.Readable(surname) then
		return nil
	end
	local full = (type(surname) == "string" and surname ~= "") and (name.." "..surname) or name
	local faction = UnitFactionGroup(unit)
	if not private.Readable(faction) or (faction ~= "Horde" and faction ~= "Alliance") then
		faction = nil
	end
	local rank = Wanted.Challenges:GetRank(full, faction)
	-- The unit's own side picks the titles; the data's side only counts when the game doesn't say
	if rank and faction then
		return { r = rank.r, f = faction == "Alliance" and "A" or "H" }
	end
	return rank
end

---"Rank 7, Blood Guard" in the title set of the player's side.
---@param rank table { r, f }
---@return string
function Ranks:Label(rank)
	local title = Wanted.Challenges:Title(rank.r, rank.f)
	return title and format("Rank %d, %s", rank.r, title) or format("Rank %d", rank.r)
end

---The rank's badge as inline text, for tooltips and labels.
---@param rank table { r, f }
---@param size number?
---@return string
function Ranks:BadgeText(rank, size)
	local badge = Wanted.Challenges:Badge(rank.r)
	return badge and format("|T%s:%d:%d|t", badge, size or BADGE_SIZE, size or BADGE_SIZE) or ""
end

---"R7", for tight places (nameplates, chat, the Nearby window).
---@param rank table
---@return string
function Ranks:Short(rank)
	return "R"..rank.r
end



-- ============================================================================
-- Tooltip
-- ============================================================================

function private.OnTooltipUnit(tooltip)
	if tooltip ~= GameTooltip or not private.Settings().tooltip or not TooltipUtil or not TooltipUtil.GetDisplayedUnit then
		return
	end
	local _, unit = TooltipUtil.GetDisplayedUnit(tooltip)
	local rank = unit and Ranks:ForUnit(unit)
	if rank then
		tooltip:AddLine(Ranks:BadgeText(rank).." Wanted: "..Ranks:Label(rank), 1, 0.8, 0.32)
	end
end



-- ============================================================================
-- Placing a label
-- ============================================================================

-- Where a label can go, each as the label's point on the anchor's point and its own offset from it, before the
-- player's offsets. Nameplates: centred over what's drawn on the plate (the default), around the name text (the plate
-- when there's none), or on the health bar's top corners. The target label: around the target frame.
Ranks.PLATE_ANCHORS = {
	{ key = "centre", label = "Centre of plate", point = "BOTTOM", to = "TOP", x = 0, y = -2, plate = true },
	{ key = "above", label = "Above name", point = "BOTTOM", to = "TOP", x = 0, y = 2 },
	{ key = "left", label = "Left of name", point = "RIGHT", to = "LEFT", x = -3, y = 0 },
	{ key = "right", label = "Right of name", point = "LEFT", to = "RIGHT", x = 3, y = 0 },
	{ key = "below", label = "Below name", point = "TOP", to = "BOTTOM", x = 0, y = -2 },
	{ key = "barTopLeft", label = "Top-left of bar", point = "BOTTOMLEFT", to = "TOPLEFT", x = 0, y = 2, bar = true },
	{ key = "barTopRight", label = "Top-right of bar", point = "BOTTOMRIGHT", to = "TOPRIGHT", x = 0, y = 2, bar = true },
}
Ranks.TARGET_ANCHORS = {
	{ key = "above", label = "Above the frame", point = "BOTTOM", to = "TOP", x = 0, y = -6 },
	{ key = "below", label = "Below the frame", point = "TOP", to = "BOTTOM", x = 0, y = 6 },
	{ key = "left", label = "Left of the frame", point = "RIGHT", to = "LEFT", x = -4, y = 0 },
	{ key = "right", label = "Right of the frame", point = "LEFT", to = "RIGHT", x = 4, y = 0 },
}
local OFFSET_LIMIT = 50
local MIN_SCALE, MAX_SCALE = 0.6, 1.6

---An anchor by key from a list; the first (the default) for anything else.
function private.Anchor(list, key)
	for _, anchor in ipairs(list) do
		if anchor.key == key then
			return anchor
		end
	end
	return list[1]
end

---A saved offset or scale kept within its range, whatever the saved data says.
function private.Clamp(value, low, high, default)
	return type(value) == "number" and value == value and max(low, min(high, value)) or default
end

---Where a layout puts a label: the anchor's spec, the x and y from the saved offsets, and the scale.
function private.Placement(list, layout)
	local anchor = private.Anchor(list, layout.anchor)
	return anchor, anchor.x + private.Clamp(layout.x, -OFFSET_LIMIT, OFFSET_LIMIT, 0),
		anchor.y + private.Clamp(layout.y, -OFFSET_LIMIT, OFFSET_LIMIT, 0), private.Clamp(layout.scale, MIN_SCALE, MAX_SCALE, 1)
end



-- ============================================================================
-- Target frame
-- ============================================================================

---The target frame on screen: ElvUI's when it's loaded (it hides the game's), otherwise the game's.
function private.TargetAnchor()
	return _G.ElvUF_Target or TargetFrame
end

---Our label at the target frame: our own frame, never a child of the secure one. It follows whichever target frame
---is there, checked each time (ElvUI may make its frames after us).
function private.TargetLabel()
	local anchor = private.TargetAnchor()
	if not anchor then
		return nil
	end
	local label = private.target
	if not label then
		label = CreateFrame("Frame", nil, UIParent)
		label:SetSize(220, 18)
		label:SetFrameStrata("MEDIUM")
		label.text = label:CreateFontString(nil, "OVERLAY")
		label.text:SetFontObject(Wanted.Theme.Fonts.small)
		label.text:SetPoint("CENTER")
		label.text:SetTextColor(1, 0.8, 0.32)
		label:Hide()
		label.hooked = {}
		private.target = label
	end
	label.anchor = anchor
	local spec, x, y, scale = private.Placement(Ranks.TARGET_ANCHORS, private.Settings().targetLabel)
	label:ClearAllPoints()
	label:SetPoint(spec.point, anchor, spec.to, x, y)
	label:SetScale(scale)
	-- Hidden with no target; HookScript doesn't taint the frame
	if not label.hooked[anchor] and anchor.HookScript then
		label.hooked[anchor] = true
		anchor:HookScript("OnShow", function() private.UpdateTarget() end)
		anchor:HookScript("OnHide", function() if label.anchor == anchor then label:Hide() end end)
	end
	return label
end

function private.UpdateTarget()
	local label = private.TargetLabel()
	if not label then
		return
	end
	local rank = private.Settings().target and label.anchor:IsVisible() and Ranks:ForUnit("target")
	if rank then
		label.text:SetText(Ranks:BadgeText(rank, 16).." "..Ranks:Label(rank))
		label:Show()
	else
		label:Hide()
	end
end



-- ============================================================================
-- Nameplates
-- ============================================================================

---What's drawn on a plate: a nameplate addon's frame (ElvUI and Plater keep theirs in plate.unitFrame), the game's
---(plate.UnitFrame), or the plate itself.
function private.PlateHost(plate)
	for _, host in ipairs({ plate.unitFrame, plate.UnitFrame }) do
		if type(host) == "table" and host.GetFrameLevel then
			return host
		end
	end
	return plate
end

local PLATE_BADGE = 13

---The name text on what's drawn on a plate (ElvUI's Name, the game's name), when it's shown.
function private.PlateName(host)
	local name = host.Name or host.name
	if type(name) == "table" and name.GetText and name.IsShown and name:IsShown() then
		return name
	end
	return nil
end

---The health bar on what's drawn on a plate (ElvUI's Health, the game's healthBar).
function private.PlateBar(host)
	local bar = host.Health or host.healthBar
	if type(bar) == "table" and bar.GetFrameLevel then
		return bar
	end
	return nil
end

---How far a name's text starts in from its region's left and right edges: a centred or right-justified name sits
---inside a wider region, and Left of name or Right of name go by the text. 0 when it can't be read.
---@return number left
---@return number right
function private.TextInset(name)
	local justify = name.GetJustifyH and name:GetJustifyH() or "LEFT"
	local ok, width = pcall(name.GetUnboundedStringWidth, name)
	local okRegion, regionWidth = pcall(name.GetWidth, name)
	if justify == "LEFT" or not ok or not okRegion or type(width) ~= "number" or type(regionWidth) ~= "number"
		or not private.Readable(width) or not private.Readable(regionWidth) or width >= regionWidth then
		return 0, 0
	end
	local spare = regionWidth - width
	if justify == "CENTER" then
		return spare / 2, spare / 2
	end
	return spare, 0
end

---Places a plate's label by the nameplate settings: around the name text (the plate without one), or on the
---health bar's corners (the plate without one), offset and scaled.
function private.PlacePlate(label)
	local host = label.host
	local spec, x, y, scale = private.Placement(Ranks.PLATE_ANCHORS, private.Settings().plate)
	local anchor
	if spec.plate then
		anchor = host
	elseif spec.bar then
		anchor = private.PlateBar(host) or label.plate
	else
		local name = private.PlateName(host)
		anchor = name or label.plate
		if name then
			local left, right = private.TextInset(name)
			x = x + (spec.key == "left" and left or 0) - (spec.key == "right" and right or 0)
		end
	end
	label:ClearAllPoints()
	label:SetPoint(spec.point, anchor, spec.to, x, y)
	label:SetScale(scale)
	label:SetFrameLevel(host:GetFrameLevel() + 20)
end

---Fills a plate's label: the badge then the number, each when switched on; hidden with neither.
function private.FillPlate(label)
	local layout = private.Settings().plate
	local showBadge, showNumber = layout.badge ~= false, layout.number ~= false
	local rank = label.rank
	label.badge:SetShown(showBadge)
	label.text:SetShown(showNumber)
	label.badge:SetTexture(Wanted.Challenges:Badge(rank.r))
	label.text:SetText(tostring(rank.r))
	label.text:ClearAllPoints()
	label.text:SetPoint("LEFT", label, "LEFT", showBadge and PLATE_BADGE + 1 or 0, 0)
	local width = (showBadge and PLATE_BADGE or 0) + (showBadge and showNumber and 1 or 0) + (showNumber and label.text:GetUnboundedStringWidth() or 0)
	label:SetSize(max(width, 1), PLATE_BADGE)
	label:SetShown(showBadge or showNumber)
end

---A plate's label, made the first time: our own frame on what's drawn there (so it moves and hides with it), above it.
function private.PlateLabel(plate)
	local host = private.PlateHost(plate)
	local label = private.plates[plate]
	if not label then
		label = CreateFrame("Frame", nil, host)
		label.plate = plate
		label.text = label:CreateFontString(nil, "OVERLAY")
		label.text:SetFontObject(Wanted.Theme.Fonts.tiny)
		label.text:SetTextColor(1, 0.8, 0.32)
		label.badge = label:CreateTexture(nil, "OVERLAY")
		label.badge:SetSize(PLATE_BADGE, PLATE_BADGE)
		label.badge:SetPoint("LEFT")
		private.plates[plate] = label
	end
	if label.host ~= host then
		label.host = host
		label:SetParent(host)
	end
	return label
end

---A nameplate came up: its rank, when the player has one. Forbidden plates (the game keeps some from addons) are
---never asked for.
function private.OnPlateAdded(unit)
	if Wanted:InInstance() then
		return
	end
	-- After the other addons' handlers for the same event, so a nameplate addon has made its frame
	C_Timer.After(0, function() private.ShowPlate(unit) end)
end

---A unit's nameplate, or nil (none, or one the game keeps from addons: asking for that one can fail).
function private.Plate(unit)
	if not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then
		return nil
	end
	local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
	return ok and plate or nil
end

function private.ShowPlate(unit)
	if not private.Settings().nameplates then
		return
	end
	local plate = private.Plate(unit)
	if not plate then
		return
	end
	local rank = Ranks:ForUnit(unit)
	local label = private.plates[plate]
	if rank then
		label = private.PlateLabel(plate)
		label.rank = rank
		private.FillPlate(label)
		private.PlacePlate(label)
	elseif label then
		label.rank = false
		label:Hide()
	end
end

function private.OnPlateRemoved(unit)
	local plate = private.Plate(unit)
	local label = plate and private.plates[plate]
	if label then
		label.rank = false
		label:Hide()
	end
end

---Applies the nameplate settings to every plate showing a rank now: hidden with the switch off, otherwise placed and
---filled again.
function private.UpdatePlates()
	local on = private.Settings().nameplates
	for _, label in pairs(private.plates) do
		if on and label.rank then
			private.FillPlate(label)
			private.PlacePlate(label)
		else
			label:Hide()
		end
	end
end



-- ============================================================================
-- Chat
-- ============================================================================

---Puts "[R7]" at the start of what a ranked player said, in your own chat windows (the name itself is the game's
---link, so it's left as it is). Off by default.
function private.ChatFilter(_, _, message, author, ...)
	if not private.Settings().chat or type(message) ~= "string" or type(author) ~= "string"
		or not private.Readable(message) or not private.Readable(author) then
		return false
	end
	local rank = Wanted.Challenges:GetRank(author)
	if not rank then
		return false
	end
	return false, "|cffffcc52["..Ranks:Short(rank).."]|r "..message, author, ...
end



-- ============================================================================
-- Who list
-- ============================================================================

---Our text beside a Who list name (the name's text stays the game's: it's read back to whisper and invite).
function private.UpdateWhoButton(button, info)
	if type(button) ~= "table" or not button.Name then
		return
	end
	local label = private.whoLabels[button]
	if not label then
		label = button:CreateFontString(nil, "OVERLAY")
		label:SetFontObject(Wanted.Theme.Fonts.tiny)
		label:SetTextColor(1, 0.8, 0.32)
		private.whoLabels[button] = label
	end
	local name = type(info) == "table" and info.fullName
	local rank = private.Settings().who and type(name) == "string" and private.Readable(name) and Wanted.Challenges:GetRank(name)
	label:ClearAllPoints()
	label:SetPoint("LEFT", button.Name, "LEFT", min(button.Name:GetStringWidth(), button.Name:GetWidth()) + 4, 0)
	label:SetText(rank and Ranks:Short(rank) or "")
end

function private.HookWho()
	if WhoList_InitButton and not private.whoHooked then
		private.whoHooked = true
		hooksecurefunc("WhoList_InitButton", function(button, elementData)
			private.UpdateWhoButton(button, elementData and elementData.info)
		end)
	end
	-- The group finder's own Who list (loaded on demand)
	if LFGWhoListButtonMixin and not private.lfgWhoHooked then
		private.lfgWhoHooked = true
		hooksecurefunc(LFGWhoListButtonMixin, "InitButton", function(button, elementData)
			private.UpdateWhoButton(button, elementData and elementData.info)
		end)
	end
end



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Ranks:OnEnable()
	if TooltipDataProcessor and Enum and Enum.TooltipDataType then
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, private.OnTooltipUnit)
	end
	local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
	if addFilter then
		for _, event in ipairs(CHAT_EVENTS) do
			addFilter(event, private.ChatFilter)
		end
	end
	private.HookWho()
	private.TargetLabel()
	local frame = private.frame
	frame:RegisterEvent("PLAYER_TARGET_CHANGED")
	frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
	frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
	frame:RegisterEvent("ADDON_LOADED")
	frame:SetScript("OnEvent", function(_, event, arg1)
		if event == "PLAYER_TARGET_CHANGED" then
			private.UpdateTarget()
		elseif event == "NAME_PLATE_UNIT_ADDED" then
			private.OnPlateAdded(arg1)
		elseif event == "NAME_PLATE_UNIT_REMOVED" then
			private.OnPlateRemoved(arg1)
		elseif event == "ADDON_LOADED" then
			private.HookWho()
		end
	end)
end

---A setting changed (Settings): the target label and the plates already shown follow at once.
function Ranks:Update()
	private.UpdateTarget()
	private.UpdatePlates()
end

---A Nearby window name's rank tag, or nil (when the player has one and the switch is on).
---@param name string?
---@return string?
function Ranks:NearbyTag(name)
	if not private.Settings().nearby or type(name) ~= "string" then
		return nil
	end
	local rank = Wanted.Challenges:GetRank(name)
	return rank and Ranks:Short(rank) or nil
end
