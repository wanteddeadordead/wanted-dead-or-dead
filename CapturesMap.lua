-- Wanted: capture fronts on the maps. On a front's zone map: each point as a circle at its real radius coloured by who
-- holds it, the lanes between them coloured up to each lane's front line, the sides' crests on their flight masters,
-- and an icon on each point (a tower, an inhibitor crystal, the Nexus keep: our own drawings in Media) to click for a
-- waypoint. A point its side lost shows grey in its taker's ring; a downed inhibitor its respawn time; a point our side
-- is taking now a pulsing ring. On a continent map, a crest on each front for the side ahead there; on the Azeroth map,
-- one per continent for the side ahead on most of its fronts. On the minimap, the icons in view. The circles and lines
-- take no mouse, so quest and other icons' tooltips still work through them.
--
-- The overlay hangs off the map's own canvas through its data provider (as MapPins does), so it moves and zooms with
-- the map. Holders are the site's (the app's catch-up, read at login); "taking" is our side's channel, provisional.

local _, Wanted = ...
local CapturesMap = Wanted:NewModule("CapturesMap")
local Captures = Wanted.Captures
local private = { provider = nil, overlay = nil, lines = {}, textures = {}, buttons = {}, used = {} }
-- The sides' colours, and gold for a point our side is taking
local COLORS = { Horde = { 0.82, 0.24, 0.2 }, Alliance = { 0.24, 0.48, 0.92 }, taking = { 1, 0.8, 0.32 } }
CapturesMap.COLORS = COLORS
-- The sides' crests (the game's own, as its inspect frame shows them) and a white disc to tint for the circles. To
-- confirm in game: both are textures of the client's Mainline family.
local CREST = { Horde = "Interface\\Timer\\Horde-Logo", Alliance = "Interface\\Timer\\Alliance-Logo" }
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
-- Our icons for each kind of point, white to tint, and the ring around one
local ICONS = {}
for _, kind in ipairs({ "tower", "inhibitor", "nexus", "ring" }) do
	ICONS[kind] = "Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\capture-"..kind
end
CapturesMap.ICONS = ICONS
local GREY = { 0.55, 0.55, 0.55 }
-- Sizes as a share of the map's width
local LINE_WIDTH, ICON_SIZE, NEXUS_SIZE, BASE_CREST, MAP_CREST = 0.004, 0.024, 0.034, 0.04, 0.04
local MAP_TYPE_WORLD = Enum and Enum.UIMapType and Enum.UIMapType.World or 1
local MAP_TYPE_CONTINENT = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2
-- The minimap's dots: how often they move, and their size in pixels
local MINIMAP_SECONDS = 0.5
local MINIMAP_DOT = 14



-- ============================================================================
-- Lifecycle
-- ============================================================================

function CapturesMap:OnEnable()
	C_Timer.After(2, private.Attach)
	Captures:OnChange(function() CapturesMap:Refresh() end)
	C_Timer.NewTicker(MINIMAP_SECONDS, Wanted:Timed("Captures minimap", function() CapturesMap:UpdateMinimap() end))
	private.AddMinimapToggle()
end

function private.Attach()
	if private.provider or not WorldMapFrame or not WorldMapFrame.AddDataProvider then
		return
	end
	private.provider = private.Provider
	WorldMapFrame:AddDataProvider(private.Provider)
	if Menu and Menu.ModifyMenu then
		Menu.ModifyMenu("MENU_WORLD_MAP_TRACKING", function(_, rootDescription)
			rootDescription:CreateCheckbox("Capture fronts (Wanted)", function() return Captures:Settings().map end, function()
				Captures:Settings().map = not Captures:Settings().map
				CapturesMap:Refresh()
			end)
		end)
	end
end

---Redraws the map overlay while the map is open.
function CapturesMap:Refresh()
	if private.provider and WorldMapFrame:IsShown() then
		private.provider:RefreshAllData()
	end
end

---The colour a point shows: its holder's.
function CapturesMap:ColorOf(point)
	return COLORS[Captures:Holder(point.id)]
end

---Dresses an icon texture for a point: its kind's icon in its holder's colour, or grey when its home side lost it (the
---ring then shows who took it). Returns whether it's lost.
function CapturesMap:DressIcon(texture, point)
	local holder = Captures:Holder(point.id)
	local lost = holder ~= point.home
	texture:SetTexture(ICONS[Captures:Kind(point)])
	local color = lost and GREY or COLORS[holder]
	texture:SetVertexColor(color[1], color[2], color[3], 1)
	return lost
end



-- ============================================================================
-- The map overlay
-- ============================================================================

private.Provider = CreateFromMixins(MapCanvasDataProviderMixin)

function private.Provider:RemoveAllData()
	private.ReleaseAll()
end

function private.Provider:RefreshAllData()
	private.ReleaseAll()
	if not Wanted.db or not Captures:Settings().map then
		return
	end
	local map = self:GetMap()
	local canvas = map.GetCanvas and map:GetCanvas()
	if not canvas then
		return
	end
	private.Overlay(canvas)
	local mapId = map:GetMapID()
	local front = Captures:FrontOn(mapId)
	if front then
		private.DrawFront(front)
		return
	end
	local info = C_Map.GetMapInfo(mapId)
	if info and info.mapType == MAP_TYPE_CONTINENT then
		private.DrawContinent(mapId)
	elseif info and info.mapType == MAP_TYPE_WORLD then
		private.DrawWorld(mapId)
	end
end

---Our frame over the map's canvas, the size of it.
function private.Overlay(canvas)
	local overlay = private.overlay
	if not overlay then
		overlay = CreateFrame("Frame", nil, canvas)
		private.overlay = overlay
	end
	overlay:SetParent(canvas)
	overlay:ClearAllPoints()
	overlay:SetAllPoints(canvas)
	overlay:SetFrameLevel(canvas:GetFrameLevel() + 5)
	overlay:Show()
	return overlay
end

function private.ReleaseAll()
	for _, kind in ipairs({ "lines", "textures", "buttons" }) do
		for _, object in ipairs(private[kind]) do
			object:Hide()
		end
		private.used[kind] = 0
	end
end

---The next free object of a kind on the overlay, made when there's none.
function private.Acquire(kind, make)
	local n = (private.used[kind] or 0) + 1
	private.used[kind] = n
	local object = private[kind][n]
	if not object then
		object = make()
		private[kind][n] = object
	end
	object:Show()
	return object
end

---The overlay's size: the canvas's, in its own units.
function private.Size()
	return private.overlay:GetWidth(), private.overlay:GetHeight()
end

function private.Line(x1, y1, x2, y2, color, alpha)
	local w, h = private.Size()
	local line = private.Acquire("lines", function() return private.overlay:CreateLine(nil, "ARTWORK") end)
	line:SetThickness(max(w * LINE_WIDTH, 2))
	line:SetColorTexture(color[1], color[2], color[3], alpha or 0.9)
	line:SetStartPoint("TOPLEFT", private.overlay, x1 / 100 * w, -y1 / 100 * h)
	line:SetEndPoint("TOPLEFT", private.overlay, x2 / 100 * w, -y2 / 100 * h)
	return line
end

---A texture centred on a map place (0 to 100), w and h in canvas units.
function private.Texture(file, x, y, w, h, color, alpha, layer)
	local cw, ch = private.Size()
	local texture = private.Acquire("textures", function() return private.overlay:CreateTexture(nil, "ARTWORK") end)
	texture:SetDrawLayer(layer or "ARTWORK")
	texture:SetTexture(file)
	texture:SetVertexColor(color and color[1] or 1, color and color[2] or 1, color and color[3] or 1, alpha or 1)
	texture:SetSize(w, h)
	texture:ClearAllPoints()
	texture:SetPoint("CENTER", private.overlay, "TOPLEFT", x / 100 * cw, -y / 100 * ch)
	return texture
end

---A front's lanes, points and bases on its zone map.
function private.DrawFront(front)
	local w = private.Size()
	local yards = Captures.MAP_YARDS[front.mapId]
	-- Each side's crest on its flight master, in the town behind its Nexus
	for _, base in ipairs({ front.horde, front.alliance }) do
		private.Texture(CREST[Captures:Get(base.id).home], base.x, base.y, w * BASE_CREST, w * BASE_CREST, nil, 1, "OVERLAY")
	end
	for _, lane in ipairs(front.lanes) do
		local nodes = { Captures:Get(front.horde.id) }
		for _, p in ipairs(lane.points) do
			tinsert(nodes, Captures:Get(p.id))
		end
		tinsert(nodes, Captures:Get(front.alliance.id))
		for i = 2, #nodes do
			local a, b = nodes[i - 1], nodes[i]
			local ha, hb = Captures:Holder(a.id), Captures:Holder(b.id)
			-- A stretch one side holds at both ends is theirs; the one between is the front line, in gold
			private.Line(a.x, a.y, b.x, b.y, ha == hb and COLORS[ha] or COLORS.taking, ha == hb and 0.85 or 0.6)
		end
	end
	for _, point in ipairs(Captures.POINTS) do
		if point.front == front then
			local color = CapturesMap:ColorOf(point)
			local cw, ch = point.r * 2 / yards[1] * w, point.r * 2 / yards[2] * private.overlay:GetHeight()
			private.Texture(DISC, point.x, point.y, cw, ch, color, 0.3, "BORDER")
			private.Button(point)
		end
	end
end

---A point's icon: hover for what it is, click for a waypoint. A ring shows who took a lost point, pulses while our side
---is taking it, and a downed inhibitor carries its respawn time.
function private.Button(point)
	local w, h = private.Size()
	local button = private.Acquire("buttons", function()
		local b = CreateFrame("Button", nil, private.overlay)
		b.ring = b:CreateTexture(nil, "ARTWORK")
		b.ring:SetPoint("CENTER")
		b.ring:SetTexture(ICONS.ring)
		b.pulse = b.ring:CreateAnimationGroup()
		local fade = b.pulse:CreateAnimation("Alpha")
		fade:SetFromAlpha(1)
		fade:SetToAlpha(0.2)
		fade:SetDuration(0.6)
		b.pulse:SetLooping("BOUNCE")
		b.icon = b:CreateTexture(nil, "OVERLAY")
		b.icon:SetAllPoints()
		b.timer = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.timer:SetPoint("TOP", b, "BOTTOM", 0, -1)
		b:SetScript("OnEnter", private.OnEnterPoint)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b:SetScript("OnClick", function(self)
			if Captures:Track(self.point) then
				Wanted:Print("Waypoint set on the %s at %s.", Captures:Role(self.point), self.point.name)
			end
		end)
		return b
	end)
	button.point = point
	button:SetFrameLevel(private.overlay:GetFrameLevel() + 2)
	local size = w * (point.lane and ICON_SIZE or NEXUS_SIZE)
	button:SetSize(size, size)
	button:ClearAllPoints()
	button:SetPoint("CENTER", private.overlay, "TOPLEFT", point.x / 100 * w, -point.y / 100 * h)
	local lost = CapturesMap:DressIcon(button.icon, point)
	local taking = Captures:Taking(point)
	local hold = Captures:Hold(point.id)
	local respawn = lost and hold and hold.r and hold.r - GetServerTime()
	button.ring:SetSize(size * 1.6, size * 1.6)
	local ringColor = taking and COLORS.taking or COLORS[Captures:Holder(point.id)]
	button.ring:SetVertexColor(ringColor[1], ringColor[2], ringColor[3], 1)
	button.ring:SetShown(lost or taking)
	if taking then
		button.pulse:Play()
	else
		button.pulse:Stop()
	end
	button.timer:SetText(respawn and respawn > 0 and format("%d:%02d", floor(respawn / 60), respawn % 60) or "")
end

---What a point is, for its tooltip: "Mid Tower, Darrow Hill" and its side; a Nexus as its side's base.
function private.OnEnterPoint(self)
	local point = self.point
	GameTooltip:SetOwner(self, point.x > 50 and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
	if point.lane then
		GameTooltip:SetText(format("%s %s", point.home, Captures:Role(point)), 1, 1, 1)
		GameTooltip:AddLine(point.name, 0.8, 0.8, 0.8)
	else
		GameTooltip:SetText(format("%s: %s base", Captures.TERMS.nexus, point.home), 1, 1, 1)
		GameTooltip:AddLine(format("On the road into %s, by its flight master", point.name), 0.8, 0.8, 0.8)
	end
	GameTooltip:AddLine(Captures:HolderText(point.id), 1, 0.82, 0, true)
	local hold = Captures:Hold(point.id)
	if hold and hold.r and Captures:Holder(point.id) ~= point.home then
		GameTooltip:AddLine(format("Respawns for the %s at %s unless its takers hold it.", point.home, date("%H:%M", hold.r)), 0.8, 0.8, 0.8, true)
	end
	local allies = Captures:Allies(point.id)
	if allies > 0 then
		GameTooltip:AddLine(format("%d of your side there now%s (provisional)", allies, Captures:Taking(point) and ", attacking it" or ""), 1, 0.8, 0.32)
	end
	GameTooltip:AddLine("Click: set a waypoint", 0.6, 0.62, 0.68)
	GameTooltip:Show()
end

---The side ahead on a front: its winner, else the side holding more points (nil when level).
function CapturesMap:Ahead(front)
	local winner = Captures:Winner(front)
	if winner then
		return winner
	end
	local horde, alliance = Captures:Count(front)
	return horde > alliance and "Horde" or alliance > horde and "Alliance" or nil
end

---Where a map lies on a bigger one: its middle, 0 to 100.
function private.MiddleOn(mapId, onMapId)
	if not C_Map.GetMapRectOnMap then
		return nil
	end
	local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, mapId, onMapId)
	if not ok or type(minX) ~= "number" then
		return nil
	end
	return (minX + maxX) / 2 * 100, (minY + maxY) / 2 * 100
end

---A crest on each front of a continent, for the side ahead there.
function private.DrawContinent(mapId)
	local w = private.Size()
	for _, front in ipairs(Captures.FRONTS) do
		local side = CapturesMap:Ahead(front)
		local x, y = private.MiddleOn(front.mapId, mapId)
		if side and x then
			private.Texture(CREST[side], x, y, w * MAP_CREST, w * MAP_CREST, nil, 1, "OVERLAY")
		end
	end
end

---One crest on each continent of the world map, for the side ahead on most of its fronts.
function private.DrawWorld(mapId)
	local w = private.Size()
	local tally = {}
	for _, front in ipairs(Captures.FRONTS) do
		local info = C_Map.GetMapInfo(front.mapId)
		local side = CapturesMap:Ahead(front)
		if info and info.parentMapID and side then
			tally[info.parentMapID] = tally[info.parentMapID] or { Horde = 0, Alliance = 0 }
			tally[info.parentMapID][side] = tally[info.parentMapID][side] + 1
		end
	end
	for continent, t in pairs(tally) do
		local side = t.Horde > t.Alliance and "Horde" or t.Alliance > t.Horde and "Alliance" or nil
		local x, y = private.MiddleOn(continent, mapId)
		if side and x then
			private.Texture(CREST[side], x, y, w * MAP_CREST * 1.5, w * MAP_CREST * 1.5, nil, 1, "OVERLAY")
		end
	end
end



-- ============================================================================
-- The minimap
-- ============================================================================

---Moves the minimap's dots to where the points are around the player.
function CapturesMap:UpdateMinimap()
	local dots = private.minimapDots
	local _, x, y, mapId = Wanted.Recorder:GetPosition()
	local front = Captures:FrontOn(mapId)
	local show = front and x and Captures:Settings().minimap and Minimap and C_Minimap and C_Minimap.GetViewRadius
	if not show then
		for _, dot in pairs(dots or {}) do
			dot:Hide()
		end
		return
	end
	if not dots then
		dots = {}
		private.minimapDots = dots
	end
	local yards = Captures.MAP_YARDS[mapId]
	local radius = C_Minimap.GetViewRadius()
	local half = Minimap:GetWidth() / 2
	local facing = GetCVarBool and GetCVarBool("rotateMinimap") and GetPlayerFacing and GetPlayerFacing() or nil
	if issecretvalue and issecretvalue(facing) then
		facing = nil
	end
	for _, point in ipairs(Captures.POINTS) do
		local dot = dots[point.id]
		if point.front ~= front then
			if dot then
				dot:Hide()
			end
		else
			-- Yards east and south of the player, turned with the minimap when it rotates (the way you face is up)
			local dx, dy = (point.x - x) / 100 * yards[1], (point.y - y) / 100 * yards[2]
			if facing then
				local c, s = math.cos(facing), math.sin(facing)
				dx, dy = dx * c - dy * s, dx * s + dy * c
			end
			if type(radius) ~= "number" or radius <= 0 or dx * dx + dy * dy > radius * radius then
				if dot then
					dot:Hide()
				end
			else
				if not dot then
					dot = Minimap:CreateTexture(nil, "OVERLAY")
					dot:SetSize(MINIMAP_DOT, MINIMAP_DOT)
					dots[point.id] = dot
				end
				CapturesMap:DressIcon(dot, point)
				if Captures:Taking(point) then
					dot:SetVertexColor(COLORS.taking[1], COLORS.taking[2], COLORS.taking[3], 1)
				end
				dot:ClearAllPoints()
				dot:SetPoint("CENTER", Minimap, "CENTER", dx / radius * half, -dy / radius * half)
				dot:Show()
			end
		end
	end
end

---A "Capture points" checkbox in the minimap's tracking menu.
function private.AddMinimapToggle()
	if not (Menu and Menu.ModifyMenu) then
		return
	end
	Menu.ModifyMenu("MENU_MINIMAP_TRACKING", function(_, rootDescription)
		rootDescription:CreateDivider()
		rootDescription:CreateCheckbox("Capture points (Wanted)", function() return Captures:Settings().minimap end, function()
			Captures:Settings().minimap = not Captures:Settings().minimap
			CapturesMap:UpdateMinimap()
		end)
	end)
end
