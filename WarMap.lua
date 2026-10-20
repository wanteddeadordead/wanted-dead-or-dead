-- Wanted: guild wars and races on the maps. On a war zone's map: the guild's war there as its lanes (the attackers'
-- rally, each lane's tower and inhibitor on the defenders' half, the keep, ringed while it's open), and during a race
-- its three flags in their holders' colours; a plate in the corner says who holds the zone and what's on. On a
-- continent's map: an icon on each war zone (its holder's emblem, a keep while a war is on, a flag while a race is),
-- with who holds it, since when and what's next on hover. With OpenMap's stitched map up (OpenMapAPI), the same pieces
-- go on its canvas wherever the zones are in view. Seals are flat icons a fixed size on screen: the keep 32 px, the
-- rest 24. Clicking one sets a waypoint. The Guild wars button on the map turns it all off and on.
--
-- The state is the site's last count (the catch-up's warLive, else the war's result as this client last saw it live),
-- provisional; race holders are Races'.

local _, Wanted = ...
local WarMap = Wanted:NewModule("WarMap")
local Theme = Wanted.Theme
local C = Theme.C
local GuildWars = Wanted.GuildWars
local Races = Wanted.Races
local private = { textures = {}, lines = {}, buttons = {}, used = {} }
local KEEP_PX, SEAL_PX, ICON_PX, LINE_PX = 32, 24, 24, 3
local SIDE = { Horde = "horde", Alliance = "alliance" }
local COLORS = { Horde = { 0.82, 0.24, 0.2 }, Alliance = { 0.24, 0.48, 0.92 } }
local ORANGE = { 1, 0.55, 0.1 }
local RING = "Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\pieces\\ring"
local MAP_TYPE_CONTINENT = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2
-- The stitched map shows each zone's pieces from this zoom (1: the whole world fits); further out, one icon a zone
local STITCHED_DETAIL = 4
-- The map overlay's slot in the map's pin levels (as CapturesMap's, one index above it)
local FRAME_LEVEL, FRAME_LEVEL_INDEX = "PIN_FRAME_LEVEL_WORLD_QUEST", 101



-- ============================================================================
-- Lifecycle
-- ============================================================================

function WarMap:OnEnable()
	C_Timer.After(2, private.Attach)
	GuildWars:OnChange(function() WarMap:Refresh() end)
	Races:OnChange(function() WarMap:Refresh() end)
	-- The plate's clock, and the pieces as the race and the war move on
	C_Timer.NewTicker(1, Wanted:Timed("War map", function() private.Tick() end))
	local om = OpenMapAPI
	if type(om) == "table" and om.major == 1 and om.RegisterCallback then
		om.RegisterCallback(private, "OpenMap_ViewChanged", function() WarMap:Refresh() end)
		om.RegisterCallback(private, "OpenMap_StitchedChanged", function() WarMap:Refresh() end)
	end
end

---Whether the layer is on (the map's Guild wars button).
function WarMap:Shown()
	return Wanted.db.settings.warMap ~= false
end

function WarMap:SetShown(shown)
	Wanted.db.settings.warMap = shown and true or false
	WarMap:Refresh()
end

function private.Attach()
	if private.provider or not WorldMapFrame or not WorldMapFrame.AddDataProvider then
		return
	end
	private.provider = private.Provider
	WorldMapFrame:AddDataProvider(private.Provider)
	private.AddMapButton()
end

---The Guild wars button on the map, top right under the game's buttons (and the capture fronts' when siege nights are on).
function private.AddMapButton()
	local container = WorldMapFrame.GetCanvasContainer and WorldMapFrame:GetCanvasContainer() or WorldMapFrame
	local above = (WorldMapFrame.WorldMapTrackingOptionsButton and 1 or 2) + (WorldMapFrame.WorldMapTrackingPinButton and 1 or 0) + (Wanted:SiegeOn() and 1 or 0)
	local button = CreateFrame("Button", nil, container)
	button:SetSize(28, 28)
	button:SetPoint("TOPRIGHT", -4, -2 - 32 * above)
	button:SetFrameLevel(container:GetFrameLevel() + 3000)
	button.icon = button:CreateTexture(nil, "ARTWORK")
	button.icon:SetAllPoints()
	button.icon:SetTexture(GuildWars.MEDIA.."nexus-keep-sealed-"..(SIDE[UnitFactionGroup("player")] or "horde"))
	button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	button:SetScript("OnClick", function()
		WarMap:SetShown(not WarMap:Shown())
		GameTooltip:Hide()
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Wanted: guild wars", 1, 0.82, 0)
		GameTooltip:AddLine(WarMap:Shown() and "Shown. Click to hide." or "Hidden. Click to show.", 1, 1, 1)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)
	private.mapButton = button
	private.UpdateMapButton()
end

function private.UpdateMapButton()
	local button = private.mapButton
	if button then
		button:SetShown(GuildWars:On() or Races:On())
		button.icon:SetDesaturated(not WarMap:Shown())
		button.icon:SetAlpha(WarMap:Shown() and 1 or 0.6)
	end
end

---Shows the tour's sample war on the map of its zone (opening it): its lanes, towers, inhibitors and keep through the
---same drawing as a real war's, from the war and zone row given here, not from GuildWars' state. Nothing is reported or
---saved; a click sets no waypoint. Cleared by HideSample.
---@param war table the sample war (GuildWars.Page:War)
---@param info table the zone's row (GuildWars.Page:Zones)
function WarMap:ShowSample(war, info)
	private.sample = { war = war, info = info }
	local zone = Wanted.WarZones:Get(war.zone)
	if zone and OpenWorldMap and not InCombatLockdown() and not (WorldMapFrame and WorldMapFrame:IsShown()) then
		OpenWorldMap(zone.mapId)
		private.sampleOpened = true
	elseif zone and WorldMapFrame and WorldMapFrame.SetMapID and WorldMapFrame:IsShown() then
		WorldMapFrame:SetMapID(zone.mapId)
	end
	WarMap:Refresh()
end

---Takes the sample off the map, and closes the map if the sample opened it.
function WarMap:HideSample()
	if not private.sample then
		return
	end
	private.sample = nil
	if private.sampleOpened then
		private.sampleOpened = nil
		if WorldMapFrame and WorldMapFrame:IsShown() then
			if HideUIPanel then HideUIPanel(WorldMapFrame) else WorldMapFrame:Hide() end
		end
	end
	WarMap:Refresh()
end

---Redraws the layer while the map is open.
function WarMap:Refresh()
	private.UpdateMapButton()
	if private.provider and WorldMapFrame:IsShown() then
		private.provider:RefreshAllData()
	end
end

---Each second with the map open: the plate's clock; and a redraw when a race or a war starts or ends.
function private.Tick()
	if not (private.provider and WorldMapFrame:IsShown()) then
		return
	end
	local now = GetServerTime()
	local key = tostring(Races:Live(now) ~= nil)..":"..tostring(GuildWars:Here(now) ~= nil)
	if key ~= private.lastKey then
		private.lastKey = key
		WarMap:Refresh()
	elseif private.plate and private.plate:IsShown() and private.plateZone then
		private.FillPlate(private.plateZone, now)
	end
end



-- ============================================================================
-- What's on in a zone
-- ============================================================================

---Whether a war is the tour's sample (WarMap:ShowSample).
function private.IsSample(war)
	return private.sample ~= nil and war == private.sample.war
end

---The guild's war in a zone, from its draw to a day after the result, or nil.
function private.WarIn(zone)
	if private.sample and private.sample.war.zone == zone.name then
		return private.sample.war
	end
	for _, war in ipairs(GuildWars:LiveWars()) do
		if war.zone == zone.name and war.step ~= "declare" and war.state ~= "withdrawn" and not (type(war.result) == "table" and (war.result.void or war.result.cancelled)) then
			return war
		end
	end
	return nil
end

---A war's lanes and keep as they stand: live in prep or battle, else as the result left them (as last seen live).
function private.Lanes(war)
	local b, r = war.battle or {}, war.result or {}
	local lanes = type(b.lanes) == "table" and b.lanes or type(r.lanes) == "table" and r.lanes or {}
	local byId = {}
	for _, lane in ipairs(lanes) do
		byId[lane.id] = lane
	end
	local keep = type(b.keep) == "table" and b.keep.state or (type(r.keep) == "table" and r.keep.state == "fallen" and "fallen") or "sealed"
	return byId, keep
end

---The zone's holder from the Zones list: { holder, since, protectedUntil, next }, or nil.
function private.ZoneInfo(zone)
	if private.sample and private.sample.info and private.sample.info.zone == zone.name then
		return private.sample.info
	end
	for _, z in ipairs(GuildWars:Zones()) do
		if z.zone == zone.name then
			return z
		end
	end
	return nil
end

---A tooltip's lines on a zone: who holds it, since when, and the war now, the protection or what's next.
function private.ZoneLines(zone, now)
	local info = private.ZoneInfo(zone)
	local holder = info and info.holder
	local lines = {}
	tinsert(lines, { holder and holder.guild and format("Held by <%s> (%s)%s", holder.guild, holder.faction or "?", info.since and (" since "..GuildWars:Day(info.since)) or "") or "Unclaimed", C.text })
	local war = private.WarIn(zone)
	local race = Races:Live(now)
	if war and war.battle and war.battle.prep and now >= war.battle.prep and now < (war.battle.stop or 0) then
		tinsert(lines, { format("Guild war now: %s attacks, %s left", war.attacker.guild or "?", private.Left(war.battle.stop - now)), C.red })
	elseif race and race.zone == zone.name then
		tinsert(lines, { format("Race now, %s left", private.Left(race.stop - now)), C.gold })
	elseif info and type(info.protectedUntil) == "number" and info.protectedUntil > now then
		tinsert(lines, { "Protected until "..date("%a ", info.protectedUntil)..GuildWars:Clock(info.protectedUntil), C.muted })
	elseif info and type(info.next) == "table" and type(info.next.at) == "number" then
		tinsert(lines, { format("Next %s %s", info.next.kind == "war" and "war" or "race", GuildWars:When(info.next.at, now)), C.muted })
	end
	return lines
end

---"18:42": minutes and seconds.
function private.Left(seconds)
	seconds = max(floor(seconds), 0)
	return format("%d:%02d", floor(seconds / 60), seconds % 60)
end



-- ============================================================================
-- The overlay
-- ============================================================================

private.Provider = CreateFromMixins(MapCanvasDataProviderMixin)

function private.Provider:RemoveAllData()
	private.ReleaseAll()
	if private.plate then
		private.plate:Hide()
	end
end

function private.Provider:OnCanvasScaleChanged()
	self:RefreshAllData()
end

---Whether OpenMap's stitched map is up.
function private.Stitched()
	local om = OpenMapAPI
	return type(om) == "table" and om.major == 1 and type(om.IsStitched) == "function" and om.IsStitched() == true
end

function private.Provider:RefreshAllData()
	self:RemoveAllData()
	if not Wanted.db or not WarMap:Shown() or not (GuildWars:On() or Races:On() or private.sample) then
		return
	end
	local map = self:GetMap()
	local canvas = map.GetCanvas and map:GetCanvas()
	if not canvas then
		return
	end
	private.Overlay(canvas)
	local mapId = map:GetMapID()
	local now = GetServerTime()
	if private.Stitched() then
		local om = OpenMapAPI
		local _, _, zoom = om.GetView()
		for _, zone in ipairs(Wanted.WarZones.LIST) do
			local place = function(x, y)
				local u, v = om.WorldFromMap(zone.mapId, x / 100, y / 100)
				if not u then
					return nil
				end
				return om.MapFromWorld(mapId, u, v)
			end
			if type(zoom) == "number" and zoom >= STITCHED_DETAIL then
				private.DrawZone(zone, place, now)
			else
				local fx, fy = place(50, 50)
				private.ZoneIcon(zone, fx, fy, now)
			end
		end
		return
	end
	local zone = Wanted.WarZones.byMap[mapId]
	if zone then
		private.DrawZone(zone, function(x, y) return x / 100, y / 100 end, now)
		private.ShowPlate(zone, now)
		return
	end
	local info = C_Map.GetMapInfo(mapId)
	if info and info.mapType == MAP_TYPE_CONTINENT then
		for _, z in ipairs(Wanted.WarZones.LIST) do
			local fx, fy = private.MiddleOn(z.mapId, mapId)
			if fx then
				private.ZoneIcon(z, fx, fy, now)
			end
		end
	end
end

---Our frame over the map's canvas, the size of it, above the stitched map's art when OpenMap's is up.
function private.Overlay(canvas)
	local overlay = private.overlay
	if not overlay then
		overlay = CreateFrame("Frame", nil, canvas)
		private.overlay = overlay
	end
	overlay:SetParent(canvas)
	overlay:ClearAllPoints()
	overlay:SetAllPoints(canvas)
	local map = private.provider:GetMap()
	local levels = map and map.GetPinFrameLevelsManager and map:GetPinFrameLevelsManager()
	local level = levels and levels.GetValidFrameLevel and levels:GetValidFrameLevel(FRAME_LEVEL, FRAME_LEVEL_INDEX)
	level = type(level) == "number" and level > 0 and level or canvas:GetFrameLevel() + 5
	local art = private.Stitched() and OpenMapAPI.ArtTopLevel and OpenMapAPI.ArtTopLevel()
	if type(art) == "number" and art >= level then
		level = art + 1
	end
	private.level = level
	overlay:SetFrameLevel(level)
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

---Canvas units for a size in screen pixels: the canvas is scaled with the map's zoom.
function private.Px(px)
	local canvas = private.overlay:GetParent()
	local scale = canvas and canvas.GetEffectiveScale and tonumber(canvas:GetEffectiveScale()) or 1
	local ui = UIParent and UIParent.GetEffectiveScale and tonumber(UIParent:GetEffectiveScale()) or 1
	return px * ui / (scale > 0 and scale or 1)
end

---Where a map lies on a bigger one: its middle, 0 to 1.
function private.MiddleOn(mapId, onMapId)
	if not C_Map.GetMapRectOnMap then
		return nil
	end
	local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, mapId, onMapId)
	if not ok or type(minX) ~= "number" or type(maxX) ~= "number" or type(minY) ~= "number" or type(maxY) ~= "number" then
		return nil
	end
	return (minX + maxX) / 2, (minY + maxY) / 2
end

---A line between two canvas places (0 to 1).
function private.Line(fx1, fy1, fx2, fy2, color)
	local w, h = private.overlay:GetWidth(), private.overlay:GetHeight()
	local line = private.Acquire("lines", function() return private.overlay:CreateLine(nil, "ARTWORK") end)
	line:SetThickness(private.Px(LINE_PX))
	line:SetColorTexture(color[1], color[2], color[3], 0.85)
	line:SetStartPoint("TOPLEFT", private.overlay, fx1 * w, -fy1 * h)
	line:SetEndPoint("TOPLEFT", private.overlay, fx2 * w, -fy2 * h)
end

---A ring round a canvas place, orange and pulsing: the open keep.
function private.Ring(fx, fy, px)
	local w, h = private.overlay:GetWidth(), private.overlay:GetHeight()
	local ring = private.Acquire("textures", function()
		local t = private.overlay:CreateTexture(nil, "ARTWORK")
		if t.CreateAnimationGroup then
			t.pulse = t:CreateAnimationGroup()
			local fade = t.pulse:CreateAnimation("Alpha")
			fade:SetFromAlpha(1)
			fade:SetToAlpha(0.3)
			fade:SetDuration(0.7)
			t.pulse:SetLooping("BOUNCE")
		end
		return t
	end)
	ring:SetTexture(RING)
	ring:SetVertexColor(ORANGE[1], ORANGE[2], ORANGE[3], 1)
	ring:SetSize(private.Px(px), private.Px(px))
	ring:ClearAllPoints()
	ring:SetPoint("CENTER", private.overlay, "TOPLEFT", fx * w, -fy * h)
	if ring.pulse then
		ring.pulse:Play()
	end
end

---A piece at a canvas place: a button with its icon, a tooltip and a waypoint on click.
---@param spec table { texture, px, fx, fy, desaturated, title, lines = { { text, color } }, waypoint = { mapId, x, y }, label }
function private.Piece(spec)
	local w, h = private.overlay:GetWidth(), private.overlay:GetHeight()
	local button = private.Acquire("buttons", function()
		local b = CreateFrame("Button", nil, private.overlay)
		b.icon = b:CreateTexture(nil, "OVERLAY")
		b.icon:SetAllPoints()
		b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.label:SetPoint("LEFT", b, "RIGHT", 2, 0)
		b:SetScript("OnEnter", private.OnEnterPiece)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b:SetScript("OnClick", function(self)
			local to = self.spec and self.spec.waypoint
			if to and Wanted.Captures:Track({ id = self.spec.title, x = to.x, y = to.y, front = { mapId = to.mapId } }) then
				Wanted:Print("Waypoint set on %s.", self.spec.title)
			end
		end)
		return b
	end)
	button.spec = spec
	button:SetFrameLevel((private.level or private.overlay:GetFrameLevel()) + 2)
	local size = private.Px(spec.px)
	button:SetSize(size, size)
	button:ClearAllPoints()
	button:SetPoint("CENTER", private.overlay, "TOPLEFT", spec.fx * w, -spec.fy * h)
	button.icon:SetTexture(spec.texture)
	button.icon:SetDesaturated(spec.desaturated == true)
	button.label:SetText(spec.label or "")
	return button
end

function private.OnEnterPiece(self)
	local spec = self.spec
	GameTooltip:SetOwner(self, spec.fx > 0.5 and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
	GameTooltip:SetText(spec.title, 1, 0.82, 0)
	for _, line in ipairs(spec.lines or {}) do
		local color = line[2] or C.text
		GameTooltip:AddLine(line[1], color[1], color[2], color[3], true)
	end
	if spec.waypoint then
		GameTooltip:AddLine("Click: set a waypoint", 0.6, 0.62, 0.68)
	end
	GameTooltip:Show()
end



-- ============================================================================
-- A zone's pieces
-- ============================================================================

---A zone's war (its lanes, rally and keep) and its race's flags, at places given by place(x, y) (0 to 100 on the
---zone's map, to the canvas's 0 to 1, or nil off it).
function private.DrawZone(zone, place, now)
	local war = private.WarIn(zone)
	if war then
		private.DrawWar(war, zone, place, now)
	end
	local race = Races:Live(now)
	if race and race.zone == zone.name then
		private.DrawRace(race, zone, place)
	end
end

function private.DrawWar(war, zone, place, now)
	local attacker, defender = war.attacker or {}, war.defender or {}
	local d, a = SIDE[defender.faction] or "alliance", SIDE[attacker.faction] or "horde"
	local lanes, keep = private.Lanes(war)
	local prep = war.battle and war.battle.start and now < war.battle.start
	local points = GuildWars:Points(war, zone)
	-- The tour's sample: tagged, and a click sets no waypoint
	local tag = private.IsSample(war) and "SAMPLE · " or ""
	local byRole = {}
	for _, p in ipairs(points) do
		byRole[(p.lane or "")..p.role] = p
	end
	local keepPoint, rally = byRole.keep, byRole.rally or byRole.keep
	local kx, ky = place(keepPoint.x, keepPoint.y)
	local rx, ry = place(rally.x, rally.y)
	if not (kx and rx) then
		return
	end
	-- The lanes: the attackers' road from the rally to each tower, the defenders' from the tower in to the keep
	local attackColor, defendColor = COLORS[attacker.faction] or C.text, COLORS[defender.faction] or C.text
	for _, laneId in ipairs({ "top", "mid", "bot" }) do
		local tower, inhib = byRole[laneId.."tower"], byRole[laneId.."inhibitor"]
		local tx, ty, ix, iy
		if tower and inhib then
			tx, ty = place(tower.x, tower.y)
			ix, iy = place(inhib.x, inhib.y)
		end
		if tx and ix then
			private.Line(rx, ry, tx, ty, attackColor)
			private.Line(tx, ty, ix, iy, defendColor)
			private.Line(ix, iy, kx, ky, defendColor)
		end
	end
	if keep == "open" then
		private.Ring(kx, ky, KEEP_PX * 1.6)
	end
	-- The seals
	for _, p in ipairs(points) do
		local fx, fy = place(p.x, p.y)
		if fx then
			local spec = { fx = fx, fy = fy, px = SEAL_PX, desaturated = prep, waypoint = tag == "" and { mapId = zone.mapId, x = p.x, y = p.y } or nil }
			if p.role == "keep" then
				spec.texture, spec.px = GuildWars:KeepFile(keep, d, a), KEEP_PX
				spec.title = tag.."The keep · "..p.name
				spec.lines = { { keep == "open" and "Open: pulses orange. Take it to win." or keep == "fallen" and ("Taken by "..(attacker.guild or "the attackers")) or "Sealed until an inhibitor falls." } }
			elseif p.role == "rally" then
				spec.texture = GuildWars.MEDIA.."rally-"..a
				spec.title = tag..format("%s's rally point", attacker.guild or "The attackers'")
				spec.lines = { { p.name, C.muted } }
			else
				local state = type(lanes[p.lane]) == "table" and lanes[p.lane][p.role] or nil
				spec.texture = GuildWars:SealFile(state, p.role, d, a)
				spec.title = tag..format("%s%s %s", strupper(strsub(p.lane, 1, 1)), strsub(p.lane, 2), p.role)
				local s = type(state) == "table" and state or {}
				spec.lines = { { p.name, C.muted }, { s.state == "taken" and ("Taken by "..(attacker.guild or "the attackers"))
					or s.state == "taking" and format("Being taken: %d%%", s.pct or 0) or format("Standing (%s)", defender.guild or "the holders"), s.state and C.gold or C.text } }
				local estimate = type(war.battle) == "table" and type(war.battle.estimate) == "table" and war.battle.estimate[p.id]
				spec.label = not prep and s.state ~= "taken" and (estimate and estimate > (s.pct or 0) and format("%d%% live", estimate)
					or s.state == "taking" and format("%d%%", s.pct or 0)) or nil
			end
			private.Piece(spec)
		end
	end
end

function private.DrawRace(race, zone, place)
	for _, point in ipairs(race.points) do
		local fx, fy = place(point.x, point.y)
		if fx then
			local holder = point.holder
			private.Piece({ fx = fx, fy = fy, px = SEAL_PX, texture = GuildWars.MEDIA.."race-"..(SIDE[holder] or "neutral"),
				title = point.name..(point.bonus and " (+20%)" or ""), waypoint = { mapId = zone.mapId, x = point.x, y = point.y },
				lines = { { holder and ("Held by the "..holder) or "Nobody holds it yet", holder and COLORS[holder] or C.muted },
					point.bonus and { "The middle point: a minute here counts +20%.", C.gold } or nil } })
		end
	end
end

---One icon on a zone seen from further out: a keep while a war is on, a flag while a race is, else its holder's emblem.
function private.ZoneIcon(zone, fx, fy, now)
	if not fx then
		return
	end
	local info = private.ZoneInfo(zone)
	local holder = info and info.holder
	local war = private.WarIn(zone)
	local race = Races:Live(now)
	local texture
	if war and war.battle and war.battle.prep and now >= war.battle.prep and now < (war.battle.stop or 0) then
		local d = SIDE[type(war.defender) == "table" and war.defender.faction] or "alliance"
		local a = SIDE[type(war.attacker) == "table" and war.attacker.faction] or "horde"
		local _, keep = private.Lanes(war)
		texture = GuildWars:KeepFile(keep, d, a)
	elseif race and race.zone == zone.name then
		texture = GuildWars.MEDIA.."race-contested"
	elseif holder and holder.guild then
		texture = GuildWars:CrestFile(holder)
	else
		return
	end
	private.Piece({ fx = fx, fy = fy, px = ICON_PX, texture = texture, title = zone.name, lines = private.ZoneLines(zone, now) })
end



-- ============================================================================
-- The plate on a war zone's map
-- ============================================================================

function private.BuildPlate()
	local container = WorldMapFrame.GetCanvasContainer and WorldMapFrame:GetCanvasContainer() or WorldMapFrame
	local plate = CreateFrame("Frame", nil, container)
	plate:SetSize(380, 64)
	plate:SetPoint("BOTTOMLEFT", 16, 16)
	plate:SetFrameLevel(container:GetFrameLevel() + 2900)
	Theme:Skin(plate, { 0.067, 0.067, 0.067, 0.88 }, { 1, 1, 1, 0.15 })
	plate.crest = plate:CreateTexture(nil, "ARTWORK")
	plate.crest:SetSize(40, 40)
	plate.crest:SetPoint("LEFT", 10, 0)
	plate.holder = Theme:Text(plate, "heading", "", C.text)
	plate.holder:SetPoint("TOPLEFT", 58, -9)
	plate.now = Theme:Text(plate, "small", "")
	plate.now:SetPoint("TOPLEFT", 58, -28)
	plate.lanes = Theme:Text(plate, "tiny", "", C.muted)
	plate.lanes:SetPoint("TOPLEFT", 58, -45)
	plate:EnableMouse(true)
	plate:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(self.tipTitle or "", 1, 0.82, 0)
		GameTooltip:AddLine(self.tip or "", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	plate:SetScript("OnLeave", function() GameTooltip:Hide() end)
	private.plate = plate
	return plate
end

function private.ShowPlate(zone, now)
	local plate = private.plate or private.BuildPlate()
	private.plateZone = zone
	private.FillPlate(zone, now)
	plate:Show()
end

---The plate: who holds the zone; the war on (its clock and lanes), the race on, the protection, or what's next.
function private.FillPlate(zone, now)
	local plate = private.plate
	local info = private.ZoneInfo(zone)
	local holder = info and info.holder
	plate.crest:SetTexture(holder and holder.guild and GuildWars:CrestFile(holder) or "Interface\\Timer\\"..(UnitFactionGroup("player") == "Alliance" and "Alliance" or "Horde").."-Logo")
	plate.crest:SetDesaturated(not (holder and holder.guild))
	plate.holder:SetText(holder and holder.guild and ("Held by <"..holder.guild..">") or "Unclaimed")
	local color = holder and COLORS[holder.faction] or C.text
	plate.holder:SetTextColor(color[1], color[2], color[3])
	local war = private.WarIn(zone)
	local race = Races:Live(now)
	local b = war and war.battle or {}
	plate.lanes:SetText("")
	if war and b.prep and now >= b.prep and now < (b.stop or 0) then
		local prep = now < b.start
		plate.now:SetText(Theme:Colorize(private.IsSample(war) and "SAMPLE WAR" or "WAR", C.red).."  ·  "..format("%s attacks · %s", war.attacker.guild or "?", prep and ("prep, battle in "..private.Left(b.start - now)) or (private.Left(b.stop - now).." left")))
		local lanes, keep = private.Lanes(war)
		local parts = {}
		for _, laneId in ipairs({ "top", "mid", "bot" }) do
			local lane = lanes[laneId] or {}
			local name = strupper(strsub(laneId, 1, 1))..strsub(laneId, 2)
			local tower, inhib = type(lane.tower) == "table" and lane.tower or {}, type(lane.inhibitor) == "table" and lane.inhibitor or {}
			if inhib.state == "taken" then
				tinsert(parts, name.." down")
			elseif tower.state == "taken" then
				tinsert(parts, name.." tower down"..(inhib.state == "taking" and format(", %d%%", inhib.pct or 0) or ""))
			elseif tower.state == "taking" then
				tinsert(parts, format("%s %d%%", name, tower.pct or 0))
			end
		end
		tinsert(parts, "keep "..keep)
		plate.lanes:SetText(b.live and table.concat(parts, " · ") or "No live data")
		plate.tipTitle, plate.tip = "Guild war", "Live from the rosters' clients: provisional until the site counts the result."
	elseif race and race.zone == zone.name then
		plate.now:SetText(Theme:Colorize("RACE", C.muted).."  ·  "..private.Left(race.stop - now).." left")
		plate.tipTitle, plate.tip = "Race", "Open to everyone here, Horde v Alliance. Influence only: nothing is captured."
	else
		local lines = private.ZoneLines(zone, now)
		plate.now:SetText(lines[2] and Theme:Colorize(lines[2][1], lines[2][2]) or "")
		plate.tipTitle, plate.tip = zone.name, "Who holds the zone, as the site last said."
	end
end
