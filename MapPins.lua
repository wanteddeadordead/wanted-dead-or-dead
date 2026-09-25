-- Wanted: enemies on the world map. Recent sightings (yours and those shared by other Wanted users) are
-- drawn where they were seen, for the last 30 minutes: red for Kill on Sight, gold for bounty targets,
-- class colour for everyone else. Hover a marker for who, when, and who saw them.
--
-- The markers go through the map's own data provider and pin system, the way Blizzard's icons and other
-- map addons add theirs. The map places, scales and layers them, so they keep working with addons that
-- resize, zoom or reveal the map (Leatrix Maps and the like).

local _, Wanted = ...
local MapPins = Wanted:NewModule("MapPins")
local Theme = Wanted.Theme
local C = Theme.C
local Store = Wanted.Store
local private = { provider = nil }
local WINDOW = 30 * 60
local PIN_TEMPLATE = "WantedDeadOrDeadEnemyPinTemplate"
local FRAME_LEVEL = "PIN_FRAME_LEVEL_WANTED_ENEMY"



-- ============================================================================
-- Pin (the template is in MapPins.xml, loaded after this file)
-- ============================================================================

WantedDeadOrDeadEnemyPinMixin = CreateFromMixins(MapCanvasPinMixin)
local PinMixin = WantedDeadOrDeadEnemyPinMixin

function PinMixin:OnLoad()
	-- The same size on screen at any zoom
	self:SetScalingLimits(1, 1, 1)
	self:UseFrameLevelType(FRAME_LEVEL)
end

---@param info table the enemy (Enemies:Describe)
---@param sighting table
function PinMixin:OnAcquired(info, sighting)
	self.info, self.t, self.by = info, sighting.t, sighting.by
	local color = info.kos and C.red or (info.bounty > 0 and C.gold) or nil
	if not color then
		local classColor = info.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[info.class]
		color = classColor and { classColor.r, classColor.g, classColor.b } or C.muted
	end
	self.Dot:SetColorTexture(color[1], color[2], color[3], 1)
	self:SetPosition(sighting.x / 100, sighting.y / 100)
end

function PinMixin:OnMouseEnter()
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
end

function PinMixin:OnMouseLeave()
	GameTooltip:Hide()
end



-- ============================================================================
-- Data provider
-- ============================================================================

local Provider = CreateFromMixins(MapCanvasDataProviderMixin)

function Provider:OnAdded(owningMap)
	MapCanvasDataProviderMixin.OnAdded(self, owningMap)
	-- Our own layer, just under group members: above the map artwork and other addons' icons, below you
	-- and your party
	local levels = owningMap:GetPinFrameLevelsManager()
	if levels then
		levels:InsertFrameLevelBelow(FRAME_LEVEL, "PIN_FRAME_LEVEL_GROUP_MEMBER")
	end
end

function Provider:RemoveAllData()
	self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
end

function Provider:RefreshAllData()
	self:RemoveAllData()
	if not Wanted.db or not Wanted.db.settings.detect.mapPins then
		return
	end
	local map = self:GetMap()
	local mapId = map:GetMapID()
	local now = GetServerTime()
	-- The newest sighting of each enemy on this map
	local latest = {}
	for sighting in Store:SightingIterator() do
		if sighting.mapId == mapId and sighting.x and sighting.y and now - sighting.t <= WINDOW then
			local current = latest[sighting.guid]
			if not current or current.t < sighting.t then
				latest[sighting.guid] = sighting
			end
		end
	end
	for guid, sighting in pairs(latest) do
		local info = Wanted.Enemies:Describe(guid)
		if not info.ignored then
			map:AcquirePin(PIN_TEMPLATE, info, sighting)
		end
	end
end



-- ============================================================================
-- Lifecycle
-- ============================================================================

function MapPins:OnEnable()
	C_Timer.After(2, private.Attach)
	Store:OnRecord("sighting", function()
		MapPins:Refresh()
	end)
end

function private.Attach()
	if private.provider or not WorldMapFrame or not WorldMapFrame.AddDataProvider then
		return
	end
	private.provider = Provider
	WorldMapFrame:AddDataProvider(Provider)
	private.AddMapToggle()
end

---Redraws the markers while the map is open (a new sighting, a setting changed).
function MapPins:Refresh()
	if private.toggleButton then
		private.toggleButton.icon:SetDesaturated(not MapPins:IsShown())
	end
	if private.provider and WorldMapFrame:IsShown() then
		private.provider:RefreshAllData()
	end
end

---Whether enemy markers are on.
function MapPins:IsShown()
	return Wanted.db.settings.detect.mapPins and true or false
end

---Turns the enemy markers on or off (the Hotspots page, Settings and the map itself all use this).
---@param shown boolean
function MapPins:SetShown(shown)
	Wanted.db.settings.detect.mapPins = shown and true or false
	MapPins:Refresh()
	if Wanted.UI then
		Wanted.UI:Refresh()
	end
end



-- ============================================================================
-- Show / hide on the map itself
-- ============================================================================

---An "Enemy sightings" checkbox in the map's own filter menu, where players look for map icon options. When
---the client has no filter menu (a game rule can turn it off), a small button on the map instead.
function private.AddMapToggle()
	if WorldMapFrame.WorldMapTrackingOptionsButton and Menu and Menu.ModifyMenu then
		Menu.ModifyMenu("MENU_WORLD_MAP_TRACKING", function(_, rootDescription)
			rootDescription:CreateDivider()
			rootDescription:CreateTitle("Wanted: Dead or... Dead")
			rootDescription:CreateCheckbox("Enemy sightings", function() return MapPins:IsShown() end, function()
				MapPins:SetShown(not MapPins:IsShown())
			end)
		end)
		return
	end
	local container = WorldMapFrame.GetCanvasContainer and WorldMapFrame:GetCanvasContainer() or WorldMapFrame
	local button = CreateFrame("Button", nil, container)
	button:SetSize(28, 28)
	button:SetPoint("TOPRIGHT", -4, -2)
	button:SetFrameLevel(container:GetFrameLevel() + 3000)
	button.icon = button:CreateTexture(nil, "ARTWORK")
	button.icon:SetAllPoints()
	button.icon:SetTexture("Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\icon")
	button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	button:SetScript("OnClick", function()
		MapPins:SetShown(not MapPins:IsShown())
		GameTooltip:Hide()
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Wanted: enemy sightings", 1, 0.82, 0)
		GameTooltip:AddLine(MapPins:IsShown() and "Shown. Click to hide." or "Hidden. Click to show.", 1, 1, 1)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)
	private.toggleButton = button
	button.icon:SetDesaturated(not MapPins:IsShown())
end
