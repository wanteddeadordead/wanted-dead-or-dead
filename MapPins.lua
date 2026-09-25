-- Wanted: enemies on the world map. Recent sightings (yours and those shared by other Wanted users) are
-- drawn where they were seen, for the last 30 minutes: red for Kill on Sight, gold for bounty targets,
-- class colour for everyone else. Hover a marker for who, when, and who saw them.

local _, Wanted = ...
local MapPins = Wanted:NewModule("MapPins")
local Theme = Wanted.Theme
local C = Theme.C
local Store = Wanted.Store
local private = { overlay = nil, pins = {}, hooked = false }
local WINDOW = 30 * 60
local PIN_SIZE = 12

function MapPins:OnEnable()
	C_Timer.After(2, private.Hook)
	Store:OnRecord("sighting", function()
		if WorldMapFrame and WorldMapFrame:IsShown() then
			MapPins:Refresh()
		end
	end)
end

function private.Hook()
	if private.hooked or not WorldMapFrame or not WorldMapFrame.GetCanvas then
		return
	end
	private.hooked = true
	WorldMapFrame:HookScript("OnShow", function() MapPins:Refresh() end)
	if WorldMapFrame.OnMapChanged then
		hooksecurefunc(WorldMapFrame, "OnMapChanged", function() MapPins:Refresh() end)
	end
end

function private.GetOverlay()
	if private.overlay then
		return private.overlay
	end
	local canvas = WorldMapFrame:GetCanvas()
	local overlay = CreateFrame("Frame", nil, canvas)
	overlay:SetAllPoints(canvas)
	overlay:SetFrameLevel(canvas:GetFrameLevel() + 50)
	private.overlay = overlay
	return overlay
end

function private.GetPin(index)
	local pin = private.pins[index]
	if pin then
		return pin
	end
	pin = CreateFrame("Frame", nil, private.GetOverlay())
	pin:SetSize(PIN_SIZE, PIN_SIZE)
	pin:EnableMouse(true)
	pin.border = pin:CreateTexture(nil, "BORDER")
	pin.border:SetAllPoints()
	pin.border:SetColorTexture(0, 0, 0, 1)
	pin.dot = pin:CreateTexture(nil, "ARTWORK")
	pin.dot:SetPoint("TOPLEFT", 2, -2)
	pin.dot:SetPoint("BOTTOMRIGHT", -2, 2)
	pin:SetScript("OnEnter", function(self)
		local d = self.info
		if not d then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(Theme:ClassName(d.name, d.class))
		Wanted.EnemyMenu:AddTooltip(d)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Seen here "..Theme:Ago(GetServerTime() - self.t).." by "..(self.by or "you"), C.muted[1], C.muted[2], C.muted[3])
		GameTooltip:Show()
	end)
	pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
	private.pins[index] = pin
	return pin
end

function MapPins:Refresh()
	if not WorldMapFrame or not WorldMapFrame:IsShown() or not WorldMapFrame.GetCanvas then
		return
	end
	local shown = 0
	if Wanted.db.settings.detect.mapPins then
		local mapId = WorldMapFrame:GetMapID()
		local canvas = WorldMapFrame:GetCanvas()
		local width, height = canvas:GetWidth(), canvas:GetHeight()
		local now = GetServerTime()
		-- The newest sighting of each enemy on this map
		local latest = {}
		for sighting in Store:SightingIterator() do
			if sighting.mapId == mapId and sighting.x and now - sighting.t <= WINDOW then
				local current = latest[sighting.guid]
				if not current or current.t < sighting.t then
					latest[sighting.guid] = sighting
				end
			end
		end
		local scale = 1
		if WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.GetCanvasScale then
			scale = WorldMapFrame.ScrollContainer:GetCanvasScale() or 1
		end
		for guid, sighting in pairs(latest) do
			local d = Wanted.Enemies:Describe(guid)
			if not d.ignored then
				shown = shown + 1
				local pin = private.GetPin(shown)
				pin.info, pin.t, pin.by = d, sighting.t, sighting.by
				local color = d.kos and C.red or (d.bounty > 0 and C.gold) or nil
				if not color then
					local classColor = d.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[d.class]
					color = classColor and { classColor.r, classColor.g, classColor.b } or C.muted
				end
				pin.dot:SetColorTexture(color[1], color[2], color[3], 1)
				pin:SetScale(1 / scale)
				pin:ClearAllPoints()
				pin:SetPoint("CENTER", private.GetOverlay(), "TOPLEFT", (sighting.x / 100) * width * scale, -(sighting.y / 100) * height * scale)
				pin:Show()
			end
		end
	end
	for i = shown + 1, #private.pins do
		private.pins[i]:Hide()
	end
end
