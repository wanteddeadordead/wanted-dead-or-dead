-- Wanted: the button on the world map. A round Wanted seal in the map's top-right corner, in the stack of the map's own
-- corner buttons (the filter, the tracking pin). Left click turns every Wanted layer on the map off, or back on as they
-- were; right click opens a menu with a checkbox for each layer, Open Wanted and Map settings. Each layer keeps its own
-- switch where it always had one (Settings, the Hotspots page), so the button, the menu and Settings always agree.
-- The button is our own frame on the map's canvas container, at the spot the map's own buttons would take: nothing is
-- added to the map's overlay frames or pin tables, which taints the game's map (621e631).

local _, Wanted = ...
local MapButton = Wanted:NewModule("MapButton")
local W = Wanted.Widgets
local C = Wanted.Theme.C
local private = {}
local SIZE, STEP = 31, 32
local MEDIA = "Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\"

function MapButton:OnEnable()
	C_Timer.After(2, private.Attach)
end

---The layers Wanted draws on the map: { key, label, get, set }. Their switches are the ones Settings shows.
---@return table[]
function MapButton:Layers()
	return {
		{ key = "sightings", label = "Enemy sightings", get = function() return Wanted.MapPins:IsShown() end,
			set = function(on) Wanted.MapPins:SetShown(on) end },
		{ key = "fronts", label = "Capture points", get = function() return Wanted.Captures:Settings().map == true end,
			set = function(on) Wanted.CapturesMap:SetMapShown(on) end },
		{ key = "war", label = "Guild wars and races", get = function() return Wanted.WarMap:Shown() end,
			set = function(on) Wanted.WarMap:SetShown(on) end },
	}
end

---Whether any layer shows: the button is dimmed when none does.
function MapButton:AnyShown()
	for _, layer in ipairs(MapButton:Layers()) do
		if layer.get() then
			return true
		end
	end
	return false
end

---Sets one layer, and brings the screens that show its switch up to date.
function private.SetLayer(layer, on)
	layer.set(on)
	if Wanted.UI then
		Wanted.UI:Refresh()
	end
	MapButton:Update()
end

---Left click: every layer off (the ones that showed are kept), or, with none showing, the kept ones back (all, the first time).
function MapButton:ToggleAll()
	local layers = MapButton:Layers()
	if MapButton:AnyShown() then
		local kept = {}
		for _, layer in ipairs(layers) do
			kept[layer.key] = layer.get()
			layer.set(false)
		end
		Wanted.db.settings.mapKept = kept
	else
		local kept = Wanted.db.settings.mapKept
		local any = false
		for _, layer in ipairs(layers) do
			any = any or (type(kept) == "table" and kept[layer.key] == true)
		end
		for _, layer in ipairs(layers) do
			layer.set(not any or kept[layer.key] == true)
		end
	end
	if Wanted.UI then
		Wanted.UI:Refresh()
	end
	MapButton:Update()
end

---Right click: a checkbox for each layer (the menu opens again after each, to set several), then Open Wanted and
---Map settings.
function MapButton:OpenMenu()
	local items = { { text = "Wanted on the map", header = true } }
	for _, layer in ipairs(MapButton:Layers()) do
		local on = layer.get()
		tinsert(items, { text = layer.label, checked = on == true, onClick = function()
			private.SetLayer(layer, not layer.get())
			MapButton:OpenMenu()
		end })
	end
	tinsert(items, "-")
	tinsert(items, { text = "Open Wanted", onClick = function() Wanted.UI:Show() end })
	tinsert(items, { text = "Map settings...", onClick = function() Wanted.UI:ShowMapSettings() end })
	W:Menu(items, private.button)
end

---Dims the button when no layer shows.
function MapButton:Update()
	local button = private.button
	if button then
		local on = MapButton:AnyShown()
		button.icon:SetDesaturated(not on)
		button:SetAlpha(on and 1 or 0.5)
	end
end

function private.Attach()
	if private.button or not WorldMapFrame then
		return
	end
	local container = WorldMapFrame.GetCanvasContainer and WorldMapFrame:GetCanvasContainer() or WorldMapFrame
	-- Under the game's own corner buttons there, as WorldMapMixin:AddOverlayFrames stacks them (-2, then 32 each)
	local above = (WorldMapFrame.WorldMapTrackingOptionsButton and 1 or 0) + (WorldMapFrame.WorldMapTrackingPinButton and 1 or 0)
	local button = CreateFrame("Button", "WantedMapButton", container)
	button:SetSize(SIZE, SIZE)
	button:SetPoint("TOPRIGHT", -4, -2 - STEP * above)
	button:SetFrameLevel(container:GetFrameLevel() + 3000)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	-- The minimap buttons' make (LibDBIcon): a round seal inside the tracking ring
	button.background = button:CreateTexture(nil, "BACKGROUND")
	button.background:SetSize(20, 20)
	button.background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	button.background:SetPoint("TOPLEFT", 7, -5)
	button.icon = button:CreateTexture(nil, "ARTWORK")
	button.icon:SetSize(17, 17)
	button.icon:SetTexture(MEDIA.."seal")
	button.icon:SetPoint("TOPLEFT", 8, -6)
	button.border = button:CreateTexture(nil, "OVERLAY")
	button.border:SetSize(50, 50)
	button.border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	button.border:SetPoint("TOPLEFT")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	button:SetScript("OnClick", function(_, which)
		GameTooltip:Hide()
		if which == "RightButton" then
			MapButton:OpenMenu()
		else
			MapButton:ToggleAll()
		end
	end)
	W:Explain(button, "Wanted "..tostring(Wanted.VERSION), "Left Click: Show/Hide Wanted on the map\nRight Click: Map options", "ANCHOR_LEFT")
	private.button = button
	MapButton:Update()
end
