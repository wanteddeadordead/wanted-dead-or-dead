-- Wanted: a minimap button that opens the window and shows how many things wait on the player.

local ADDON_FOLDER, Wanted = ...
local Minimap_ = Wanted:NewModule("Minimap")
Wanted.Minimap = Minimap_
local private = {}
-- The addon's own icon, from the folder it's installed in
local ICON = "Interface\\AddOns\\"..ADDON_FOLDER.."\\Media\\icon"
-- The button is LibDBIcon's, so minimap button collectors and UI packs can gather, move and hide it
local NAME = "WantedDeadOrDead"
local LDB, DBIcon = LibStub("LibDataBroker-1.1"), LibStub("LibDBIcon-1.0")

function Minimap_:OnEnable()
	-- Only bounty records change what's waiting on you: a busy fight's deaths and sightings don't
	for _, kind in ipairs({ "bounty", "claim", "confirm", "payment", "withdraw", "raise", "pass", "hunt" }) do
		Wanted.Store:OnRecord(kind, function() private.actionCount = nil end)
	end
	local settings = Wanted.db.settings.minimap
	-- LibDBIcon keeps the position in minimapPos; older versions read angle, which is left for them
	settings.minimapPos = settings.minimapPos or settings.angle
	local launcher = LDB:NewDataObject(NAME, {
		type = "launcher",
		text = "Wanted",
		icon = ICON,
		OnClick = function(_, mouseButton)
			if mouseButton == "RightButton" then
				Wanted.NearbyWindow:Toggle()
			else
				Wanted.UI:Toggle()
			end
		end,
		OnEnter = function(frame) private.ShowTooltip(frame) end,
		OnLeave = function() GameTooltip:Hide() end,
	})
	DBIcon:Register(NAME, launcher, settings)
	local button = DBIcon:GetMinimapButton(NAME)
	button.badge = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	button.badge:SetPoint("BOTTOMRIGHT", -2, 2)
	button.badge:SetTextColor(1, 0.3, 0.3)
	private.button = button
	private.hidden = settings.hide
	Minimap_:Update()
	C_Timer.NewTicker(10, Wanted:Timed("Minimap update", function() Minimap_:Update() end))
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
		if Wanted:GetRequiredUpdate() then
			GameTooltip:AddLine("Update required: "..Wanted:GetRequiredUpdate()..". Bounties and sharing are paused until you update.", 1, 0.3, 0.3, true)
		end
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

function Minimap_:Update()
	local button = private.button
	if not button then
		return
	end
	-- Shown or hidden only when the setting changes: a button collector may have hidden it in its own bar
	local hide = Wanted.db.settings.minimap.hide
	if hide ~= private.hidden then
		private.hidden = hide
		if hide then
			DBIcon:Hide(NAME)
		else
			DBIcon:Show(NAME)
		end
	end
	-- Counting walks every bounty and claim, so it's only done again once a record has arrived, or a minute on
	-- (bounties expire with time)
	if not private.actionCount or GetTime() - private.actionCountAt > 60 then
		private.actionCount, private.actionCountAt = Wanted.Model:GetActionCount(), GetTime()
	end
	local count = private.actionCount
	button.badge:SetText(count > 0 and tostring(count) or "")
end
