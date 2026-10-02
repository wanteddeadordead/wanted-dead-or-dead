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
	if not UnitIsPlayer(unit) then
		return nil
	end
	local name, surname = UnitName(unit)
	if type(name) ~= "string" or not private.Readable(name) or not private.Readable(surname) then
		return nil
	end
	local full = (type(surname) == "string" and surname ~= "") and (name.." "..surname) or name
	local faction = UnitFactionGroup(unit)
	return Wanted.Challenges:GetRank(full, private.Readable(faction) and faction or nil)
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
-- Target frame
-- ============================================================================

---The target frame on screen: ElvUI's when it's loaded (it hides the game's), otherwise the game's.
function private.TargetAnchor()
	return _G.ElvUF_Target or TargetFrame
end

---Our label over the target frame: our own frame, never a child of the secure one. It follows whichever target
---frame is there, checked each time (ElvUI may make its frames after us).
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
	if label.anchor ~= anchor then
		label.anchor = anchor
		label:ClearAllPoints()
		label:SetPoint("BOTTOM", anchor, "TOP", 0, -6)
	end
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

-- The badge and number left of the name on a plate
local PLATE_BADGE = 13
local PLATE_GAP = 3

---Where the rank goes on a plate: left of the name text (ElvUI's Name, the game's name), else left of the health bar
---(ElvUI's Health, the game's healthBar), else the plate's left edge; never over the level and health texts.
---@return Region anchor
---@return string point the anchor's point the label's right edge goes to
---@return number x
function private.PlateSpot(host)
	local name = host.Name or host.name
	if type(name) == "table" and name.GetText and name.IsShown and name:IsShown() then
		-- The name's region can be wider than its text (a centred tag): go to where the text starts
		local justify = name.GetJustifyH and name:GetJustifyH() or "LEFT"
		local ok, width = pcall(name.GetUnboundedStringWidth, name)
		if justify ~= "LEFT" and ok and type(width) == "number" and private.Readable(width) then
			if justify == "CENTER" then
				return name, "CENTER", -width / 2 - PLATE_GAP
			end
			return name, "RIGHT", -width - PLATE_GAP
		end
		return name, "LEFT", -PLATE_GAP
	end
	local health = host.Health or host.healthBar
	if type(health) == "table" and health.GetFrameLevel then
		return health, "LEFT", -PLATE_GAP
	end
	return host, "LEFT", -PLATE_GAP
end

---A plate's label, made the first time: our own frame on what's drawn there (so it moves and hides with it), above
---it, with the rank's badge and number in gold, left of the name.
function private.PlateLabel(plate)
	local host = private.PlateHost(plate)
	local label = private.plates[plate]
	if not label then
		label = CreateFrame("Frame", nil, host)
		label:SetSize(PLATE_BADGE + 22, PLATE_BADGE)
		label.text = label:CreateFontString(nil, "OVERLAY")
		label.text:SetFontObject(Wanted.Theme.Fonts.tiny)
		label.text:SetPoint("RIGHT")
		label.text:SetJustifyH("RIGHT")
		label.text:SetTextColor(1, 0.8, 0.32)
		label.badge = label:CreateTexture(nil, "OVERLAY")
		label.badge:SetSize(PLATE_BADGE, PLATE_BADGE)
		label.badge:SetPoint("RIGHT", label.text, "LEFT", -1, 0)
		private.plates[plate] = label
	end
	if label.host ~= host then
		label.host = host
		label:SetParent(host)
	end
	local anchor, point, x = private.PlateSpot(host)
	label:ClearAllPoints()
	label:SetPoint("RIGHT", anchor, point, x, 0)
	label:SetFrameLevel(host:GetFrameLevel() + 20)
	return label
end

---A nameplate came up: its rank, when the player has one. Forbidden plates (the game keeps some from addons) are
---never asked for.
function private.OnPlateAdded(unit)
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
		label.text:SetText(tostring(rank.r))
		label.badge:SetTexture(Wanted.Challenges:Badge(rank.r))
		label:Show()
	elseif label then
		label:Hide()
	end
end

function private.OnPlateRemoved(unit)
	local plate = private.Plate(unit)
	local label = plate and private.plates[plate]
	if label then
		label:Hide()
	end
end

---Hides every nameplate number (the switch went off).
function private.HidePlates()
	for _, label in pairs(private.plates) do
		label:Hide()
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

---A switch changed (Settings): what's on screen follows at once; plates as they come up again.
function Ranks:Update()
	private.UpdateTarget()
	if not private.Settings().nameplates then
		private.HidePlates()
	end
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
