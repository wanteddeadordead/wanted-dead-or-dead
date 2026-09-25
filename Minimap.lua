-- Wanted: a minimap button that opens the window and shows how many things wait on the player.

local ADDON_FOLDER, Wanted = ...
local Minimap_ = Wanted:NewModule("Minimap")
Wanted.Minimap = Minimap_
local private = {}
-- The addon's own icon, from the folder it's installed in
local ICON = "Interface\\AddOns\\"..ADDON_FOLDER.."\\Media\\icon"
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01"
-- How far outside the minimap's edge the button's centre sits
local EDGE_OFFSET = 10

function Minimap_:OnEnable()
	local button = CreateFrame("Button", "WantedMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("AnyUp")
	button:RegisterForDrag("LeftButton")
	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetSize(20, 20)
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetPoint("TOPLEFT", 7, -5)
	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetSize(17, 17)
	if not icon:SetTexture(ICON) then
		icon:SetTexture(FALLBACK_ICON)
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end
	icon:SetPoint("TOPLEFT", 7, -6)
	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetPoint("TOPLEFT")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	button.badge = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	button.badge:SetPoint("BOTTOMRIGHT", -2, 2)
	button.badge:SetTextColor(1, 0.3, 0.3)
	button:SetScript("OnClick", function(_, mouseButton)
		if mouseButton == "RightButton" then
			Wanted.NearbyWindow:Toggle()
		else
			Wanted.UI:Toggle()
		end
	end)
	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", private.OnDragUpdate)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	button:SetScript("OnEnter", function(self)
		private.ShowTooltip(self)
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)
	private.button = button
	Minimap_:Update()
	C_Timer.NewTicker(10, function() Minimap_:Update() end)
end

---The tooltip for the minimap button and the entry in the game's addon menu.
function private.ShowTooltip(owner)
	do
		GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
		GameTooltip:SetText("Wanted: Dead or... Dead", 1, 0.82, 0)
		local count = Wanted.Model:GetActionCount()
		if count > 0 then
			GameTooltip:AddLine(format("%d thing%s waiting for you", count, count == 1 and "" or "s"), 1, 0.4, 0.4)
		end
		local nearby = Wanted.Enemies:GetNearby()
		local kos = {}
		for _, d in ipairs(nearby) do
			if d.kos or d.bounty > 0 then
				tinsert(kos, d.name)
			end
		end
		GameTooltip:AddLine(format("%d enem%s nearby", #nearby, #nearby == 1 and "y" or "ies"), 1, 1, 1)
		if #kos > 0 then
			GameTooltip:AddLine("Wanted nearby: "..table.concat(kos, ", "), 1, 0.3, 0.3, true)
		end
		local hotspots = Wanted.Hotspots:GetTop(3)
		if #hotspots > 0 then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Hotspots, last 15 minutes", 1, 0.82, 0)
			for _, group in ipairs(hotspots) do
				GameTooltip:AddDoubleLine(group.zone, format("%d enem%s", group.recent, group.recent == 1 and "y" or "ies"), 1, 1, 1, 1, 1, 1)
			end
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Click: open Wanted.  Right-click: Nearby window.  Drag: move.", 0.7, 0.7, 0.7, true)
		if Wanted.BETA then
			GameTooltip:AddLine("Beta: found a problem? /wanted bug", 1, 0.7, 0.2, true)
		end
		GameTooltip:Show()
	end
end

-- The game's addon menu on the minimap (toc: AddonCompartmentFunc and friends) calls these globals
function WantedDeadOrDead_OnCompartmentClick(_, mouseButton)
	if mouseButton == "RightButton" then
		Wanted.NearbyWindow:Toggle()
	else
		Wanted.UI:Toggle()
	end
end

function WantedDeadOrDead_OnCompartmentEnter(_, menuButton)
	private.ShowTooltip(menuButton)
end

function WantedDeadOrDead_OnCompartmentLeave()
	GameTooltip:Hide()
end

function private.OnDragUpdate()
	local mx, my = Minimap:GetCenter()
	local px, py = GetCursorPosition()
	local scale = Minimap:GetEffectiveScale()
	px, py = px / scale, py / scale
	Wanted.db.settings.minimap.angle = math.deg(math.atan2(py - my, px - mx))
	Minimap_:Update()
end

function Minimap_:Update()
	local button = private.button
	if not button then
		return
	end
	local settings = Wanted.db.settings.minimap
	if settings.hide then
		button:Hide()
		return
	end
	local angle = math.rad(settings.angle or 200)
	-- Sit on the rim of whatever minimap this client has, rather than a distance tuned for another client
	local radius = (Minimap:GetWidth() / 2) + EDGE_OFFSET
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
	local count = Wanted.Model:GetActionCount()
	button.badge:SetText(count > 0 and tostring(count) or "")
	button:Show()
end
