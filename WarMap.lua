-- Wanted: guild wars and races on the maps. On a war zone's map: the guild's war there as its lanes (the attackers'
-- rally, each lane's tower and inhibitor on the defenders' half, the keep, ringed while it's open), and during a race
-- its three flags (tonight's races all day: neutral and labelled with the race time before it, in their holders'
-- colours while it runs and after); a plate in the corner says who holds the zone and what's on. On a
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
local MAP_TYPE_ZONE = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
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

---Whether tonight's races are drawn (the map button's Races, Settings).
function WarMap:RacesShown()
	return Wanted.db.settings.raceMap ~= false
end

function WarMap:SetRacesShown(shown)
	Wanted.db.settings.raceMap = shown and true or false
	WarMap:Refresh()
end

function private.Attach()
	if private.provider or not WorldMapFrame or not WorldMapFrame.AddDataProvider then
		return
	end
	private.provider = private.Provider
	WorldMapFrame:AddDataProvider(private.Provider)
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
	Wanted.MapButton:Update()
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

---The war drawn in a zone: the tour's sample whatever the switches say, else a real one when Guild wars is ticked.
function private.WarShown(zone)
	local war = private.WarIn(zone)
	if war and (private.IsSample(war) or WarMap:Shown()) then
		return war
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
	elseif private.RaceFor(zone.mapId, now) then
		tinsert(lines, { "Race "..GuildWars:When(private.RaceFor(zone.mapId, now).start, now), C.gold })
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

---The zones the layer draws: the campaign's, and any other zone tonight's races are run in (Moonglade has a race and
---no war, so it is not in WarZones).
function private.Zones()
	local list = {}
	for _, zone in ipairs(Wanted.WarZones.LIST) do
		tinsert(list, zone)
	end
	for _, race in ipairs(Races:Tonight()) do
		if not Wanted.WarZones.byMap[race.mapId] then
			tinsert(list, { name = race.zone, mapId = race.mapId, raceOnly = true })
		end
	end
	-- Any other zone with kills or enemies seen: only its stats
	if Wanted.StatsMap:Shown() then
		for _, zone in ipairs(Wanted.StatsMap:OtherZones()) do
			local taken = false
			for _, z in ipairs(list) do
				taken = taken or z.mapId == zone.mapId
			end
			if not taken then
				tinsert(list, zone)
			end
		end
	end
	return list
end

---Tonight's race in a zone that is live or still to come, or nil.
function private.RaceFor(mapId, now)
	for _, race in ipairs(Races:Tonight()) do
		if race.mapId == mapId and now < race.stop then
			return race
		end
	end
	return nil
end

function private.Provider:RemoveAllData()
	private.ReleaseAll()
	if private.plate then
		private.plate:Hide()
	end
	if private.statsPlate then
		private.statsPlate:Hide()
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
	if not Wanted.db then
		return
	end
	-- The tour's sample war draws whatever the layer switches say
	local wars, races, stats = WarMap:Shown() and GuildWars:On(), WarMap:RacesShown() and Races:On(), Wanted.StatsMap:Shown()
	if not (wars or races or stats or private.sample) then
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
		for _, zone in ipairs(private.Zones()) do
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
	local zone
	for _, z in ipairs(private.Zones()) do
		if z.mapId == mapId then
			zone = z
		end
	end
	if zone then
		private.DrawZone(zone, function(x, y) return x / 100, y / 100 end, now)
		if (wars or private.sample) and not zone.raceOnly and not zone.statsOnly then
			private.ShowPlate(zone, now)
		end
		if stats then
			private.ShowStatsPlate(zone, now)
		end
		return
	end
	local info = C_Map.GetMapInfo(mapId)
	if stats and info and info.mapType == MAP_TYPE_ZONE and type(info.name) == "string" and Wanted.StatsMap:Zone(mapId, info.name, now).active then
		private.ShowStatsPlate({ mapId = mapId, name = info.name }, now)
	end
	if info and info.mapType == MAP_TYPE_CONTINENT then
		for _, z in ipairs(private.Zones()) do
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
		-- A guild's own crest in place of the icon (spec.guild)
		b.crest = GuildWars:NewCrest(b, "OVERLAY")
		b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.label:SetPoint("LEFT", b, "RIGHT", 2, 0)
		b:SetScript("OnEnter", private.OnEnterPiece)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b:SetScript("OnClick", function(self)
			local to = self.spec and self.spec.waypoint
			if to and Wanted.Presence:Track(to.mapId, to.x, to.y) then
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
	button.crest:SetShown(spec.guild ~= nil)
	button.icon:SetShown(spec.guild == nil)
	if spec.guild then
		-- Its own size, so the crest knows when it is small
		button.crest:ClearAllPoints()
		button.crest:SetPoint("CENTER")
		button.crest:SetSize(size, size)
		button.crest:SetGuild(spec.guild)
		button.crest:SetDesaturated(false)
		-- A keep: the crest of those who hold it, its state a ring
		button.crest:SetKeep(spec.keep, spec.d, spec.a)
		if spec.desaturated then
			button.crest:SetDesaturated(true)
		end
	end
	button.icon:SetTexture(spec.texture)
	button.icon:SetDesaturated(spec.desaturated == true)
	local tint = spec.color or { 1, 1, 1 }
	button.icon:SetVertexColor(tint[1], tint[2], tint[3], 1)
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
	local war = private.WarShown(zone)
	if war then
		private.DrawWar(war, zone, place, now)
	end
	for _, race in ipairs(WarMap:RacesShown() and Races:Tonight() or {}) do
		-- A finished race gives way to the war fought in its zone
		if race.mapId == zone.mapId and not (war and Races:Phase(race, now) == "ended") then
			private.DrawRace(race, zone, place, now)
		end
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
				-- The defenders' crest, the keep's state a ring on it (their side's keep art until the tabard is known)
				spec.guild, spec.keep, spec.d, spec.a = defender, keep, d, a
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

function private.DrawRace(race, zone, place, now)
	local phase = Races:Phase(race, now)
	local clock = GuildWars:Clock(race.start)
	for _, point in ipairs(race.points) do
		local fx, fy = place(point.x, point.y)
		if fx then
			-- Before the race nobody holds a point
			local holder = phase ~= "upcoming" and point.holder or nil
			local first = phase == "upcoming" and ("Race "..GuildWars:When(race.start, now)) or phase == "live" and "Race now"
				or "Race ended"
			private.Piece({ fx = fx, fy = fy, px = SEAL_PX, texture = GuildWars.MEDIA.."race-"..(SIDE[holder] or "neutral"),
				title = point.name..(point.bonus and " (+20%)" or ""), label = clock, waypoint = { mapId = zone.mapId, x = point.x, y = point.y },
				lines = { { first, phase == "live" and C.gold or C.muted },
					phase ~= "upcoming" and { holder and ("Held by the "..holder) or "Nobody holds it yet", holder and COLORS[holder] or C.muted } or nil,
					point.bonus and { "The middle point: a minute here counts +20%.", C.gold } or nil } })
		end
	end
end

---One icon on a zone seen from further out: a keep while a war is on, a flag while a race is, else its holder's emblem.
function private.ZoneIcon(zone, fx, fy, now)
	if not fx then
		return
	end
	local info = WarMap:Shown() and private.ZoneInfo(zone) or nil
	local holder = info and info.holder
	local war = private.WarShown(zone)
	local race = WarMap:RacesShown() and private.RaceFor(zone.mapId, now) or nil
	local piece = { fx = fx, fy = fy, px = ICON_PX, title = zone.name, lines = private.ZoneLines(zone, now) }
	if war and war.battle and war.battle.prep and now < (war.battle.stop or 0) then
		-- A war: the keep, the defenders' crest with its state
		local _, keep = private.Lanes(war)
		piece.guild, piece.keep = war.defender or {}, keep
		piece.d = SIDE[type(war.defender) == "table" and war.defender.faction] or "alliance"
		piece.a = SIDE[type(war.attacker) == "table" and war.attacker.faction] or "horde"
	elseif race then
		piece.texture = GuildWars.MEDIA.."race-"..(now < race.start and "neutral" or "contested")
	elseif holder and holder.guild then
		-- The holder's own crest (its tabard), else its side's emblem
		piece.guild = holder
	else
		piece = nil
	end
	if piece then
		private.Piece(piece)
	end
	if Wanted.StatsMap:Shown() then
		private.StatsBadge(zone, fx, fy, now)
	end
end

---A zone's stats under its icon on a continent's map: a dot in its holder's (else the leader's) tint, and the kills.
function private.StatsBadge(zone, fx, fy, now)
	local stats = Wanted.StatsMap:Zone(zone.mapId, zone.name, now)
	if not stats.active then
		return
	end
	local color = Wanted.StatsMap:Color(stats)
	private.Piece({ fx = fx, fy = fy + 0.035, px = 12, texture = GuildWars.MEDIA.."disc", color = color, title = zone.name,
		label = Wanted.StatsMap:Short(stats), lines = Wanted.StatsMap:Lines(stats) })
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
	plate.crest = GuildWars:NewCrest(plate)
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
	plate.crest:SetGuild(holder and holder.guild and holder or { faction = UnitFactionGroup("player") })
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



-- ============================================================================
-- The stats plate on a zone's map
-- ============================================================================

function private.BuildStatsPlate()
	local container = WorldMapFrame.GetCanvasContainer and WorldMapFrame:GetCanvasContainer() or WorldMapFrame
	local plate = CreateFrame("Frame", nil, container)
	plate:SetSize(380, 64)
	-- Over the war plate in the same corner
	plate:SetPoint("BOTTOMLEFT", 16, 86)
	plate:SetFrameLevel(container:GetFrameLevel() + 2900)
	Theme:Skin(plate, { 0.067, 0.067, 0.067, 0.88 }, { 1, 1, 1, 0.15 })
	plate.dot = plate:CreateTexture(nil, "ARTWORK")
	plate.dot:SetSize(14, 14)
	plate.dot:SetPoint("TOPLEFT", 12, -11)
	plate.dot:SetTexture(GuildWars.MEDIA.."disc")
	plate.holder = Theme:Text(plate, "body", "", C.text)
	plate.holder:SetPoint("TOPLEFT", 32, -8)
	plate.holder:SetWidth(336)
	plate.holder:SetWordWrap(false)
	plate.kills = Theme:Text(plate, "small", "", C.text)
	plate.kills:SetPoint("TOPLEFT", 12, -28)
	plate.kills:SetWidth(356)
	plate.kills:SetWordWrap(false)
	plate.busy = Theme:Text(plate, "small", "", C.muted)
	plate.busy:SetPoint("TOPLEFT", 12, -44)
	plate.busy:SetWidth(356)
	plate.busy:SetWordWrap(false)
	private.statsPlate = plate
	return plate
end

---The zone's current stats in the corner of its map.
function private.ShowStatsPlate(zone, now)
	local plate = private.statsPlate or private.BuildStatsPlate()
	local stats = Wanted.StatsMap:Zone(zone.mapId, zone.name, now)
	local lines = Wanted.StatsMap:Lines(stats)
	local color = Wanted.StatsMap:Color(stats)
	plate.dot:SetVertexColor(color[1], color[2], color[3], 1)
	local kills = stats.kills > 0 and { lines[2][1].."  ·  "..lines[3][1], C.text } or lines[2]
	for field, line in pairs({ holder = lines[1], kills = kills, busy = lines[#lines] }) do
		plate[field]:SetText(line[1])
		plate[field]:SetTextColor(line[2][1], line[2][2], line[2][3])
	end
	plate:Show()
end
