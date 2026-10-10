-- Wanted: the capture front's HUD, made to look like the battlegrounds'. In a front's zone, under the game's own
-- top-centre world-state widgets, the same layout as Alterac Valley's: each side's tower icon with "Towers: N" (the
-- IconAndText widget's 42-pixel icon and GameFontNormalSmall), and a compact lane row, Top / Mid / Bot, each lane's
-- points as the map's battleground icons. While the player stands in a point, the battlegrounds' capture bar under the
-- minimap (the CaptureBar widget's "factions" art: Alliance fill left, Horde right, the spark moving as a side takes
-- it): how far our side is toward taking it, as our side's channel tells it (provisional; the site decides), or why the
-- player's presence doesn't count. Announcements in the middle of the screen the way a battleground's are, on our own
-- frame made from Blizzard's RaidWarningFrameTemplate (CapturesHUD.xml), worded the MOBA way. Our own frames only,
-- nothing protected and nothing of Blizzard's touched: safe in combat.

local _, Wanted = ...
local CapturesHUD = Wanted:NewModule("CapturesHUD")
local Captures = Wanted.Captures
local private = {
	bar = nil,
	takingSince = {},
	alerted = {},
	holders = {},
	shownFront = nil, -- the front the widget was last placed and dressed for
	dirty = true, -- something changed since the widget was last drawn
}
local UPDATE_SECONDS = 1
local ICON, GAP = 16, 3
-- One live alert per point and kind this often, and enemies counted as an attack on our point from this many
local ALERT_SECONDS = 5 * 60
local ENEMY_ALERT = 2
-- What each announcement says and plays (the game's own sounds, SoundKitConstants): title, side whose colour it takes
-- ("ours", "theirs" or "neutral"), SOUNDKIT name
local ALERTS = {
	lost = { "Your %s has been destroyed", "theirs", "RAID_WARNING" },
	lostInhibitor = { "Your inhibitor is down", "theirs", "RAID_WARNING" },
	taken = { "Enemy %s destroyed", "ours", "PVP_THROUGH_QUEUE" },
	takenInhibitor = { "Enemy inhibitor down", "ours", "PVP_THROUGH_QUEUE" },
	respawned = { "Inhibitor respawned", "neutral", "IG_PVP_UPDATE" },
	won = { "Victory: the enemy %s has fallen", "ours", "UI_BATTLEGROUND_COUNTDOWN_FINISHED" },
	beaten = { "Defeat: your %s has fallen", "theirs", "RAID_WARNING" },
	attacking = { "Your side is attacking the enemy %s", "ours", "PVP_ENTER_QUEUE" },
	enemyNexus = { "Enemy %s under attack", "ours", "RAID_BOSS_EMOTE_WARNING" },
	underAttack = { "Your %s is under attack", "theirs", "RAID_BOSS_EMOTE_WARNING" },
}
-- Which news matters most, when several came at once
local PRIORITY = { won = 1, beaten = 1, lostInhibitor = 2, takenInhibitor = 2, lost = 3, taken = 3, respawned = 4 }
-- The CaptureBar widget's geometry (Blizzard_UIWidgetTemplateCaptureBar: its default bar) and its "factions" art
local CAPTURE_W, CAPTURE_H, BAR_OFFSET, BAR_WIDTH, NEUTRAL = 196, 26, 36, 124, 0.2
local CAPTURE_ART = { frame = "worldstate-capturebar-frame-factions", left = "worldstate-capturebar-leftfill-factions",
	right = "worldstate-capturebar-rightfill-factions", neutral = "worldstate-capturebar-neutralfill-factions",
	spark = "worldstate-capturebar-spark-factions", line = "worldstate-capturebar-frame-separater" }
-- The world-state widgets' faction tower icons (the IconAndText widget's texture kit icons)
local TOWER_ATLAS = { Alliance = "alliance_tower-icon", Horde = "horde_tower-icon" }
local LANE_ICON = 14



-- ============================================================================
-- Lifecycle
-- ============================================================================

function CapturesHUD:OnEnable()
	-- Our announcement frame shows only what Wanted gives it, never the game's own BG messages
	if WantedCaptureAnnounceFrame then
		WantedCaptureAnnounceFrame:UnregisterAllEvents()
	end
	C_Timer.NewTicker(UPDATE_SECONDS, Wanted:Timed("Captures bar", function() CapturesHUD:Update() end))
	Captures:OnChange(function(fresh)
		private.dirty = true
		if fresh then
			-- The site's holds just came in: what they changed is news of its own, not a respawn seen live
			private.CheckRespawns(true)
			CapturesHUD:DeliverNews()
		end
		private.CheckLive()
	end)
	-- The catch-up read at login came before this module was enabled: its news waits for us
	private.CheckRespawns(true)
	CapturesHUD:DeliverNews()
end

---Announces the news of the site's last holds, if any waits.
function CapturesHUD:DeliverNews()
	local news = Captures:TakeNews()
	if news and #news > 0 then
		private.TellNews(news)
	end
end



-- ============================================================================
-- The bar
-- ============================================================================

---Whether the client has an atlas: the art is the game's, looked up before it's used.
function private.HasAtlas(name)
	return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

---Sets an atlas at its own size, or a plain colour where the client lacks it (a stand-in, to tell apart in game).
function private.Atlas(texture, name, color, w, h)
	if private.HasAtlas(name) then
		texture:SetAtlas(name, w == nil)
	else
		texture:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
	end
	if w then
		texture:SetSize(w, h)
	end
end

---One side's half of the top widget: its tower icon and "Towers: N", as the IconAndText widget lays them out.
function private.Side(parent, side)
	local s = CreateFrame("Frame", nil, parent)
	s:SetSize(100, 24)
	s.icon = s:CreateTexture(nil, "BACKGROUND")
	s.icon:SetSize(42, 42)
	s.icon:SetPoint("TOPLEFT")
	s.text = s:CreateFontString(nil, "BACKGROUND", "GameFontNormalSmall")
	s.text:SetJustifyH("LEFT")
	-- The widget's own offsets: its icon doesn't fill its tile
	s.text:SetPoint("TOPLEFT", s.icon, "TOPRIGHT", -12, -6)
	return s
end

---Makes the HUD: the top widget (both sides, the lane row) and the capture bar.
function private.Build()
	local bar = CreateFrame("Frame", "WantedCaptureBar", UIParent)
	bar:SetSize(260, 64)
	bar:SetFrameStrata("LOW")
	bar.alliance = private.Side(bar, "Alliance")
	bar.alliance:SetPoint("TOPLEFT", 10, 0)
	bar.horde = private.Side(bar, "Horde")
	bar.horde:SetPoint("TOPLEFT", 140, 0)
	bar.count = bar.alliance.text -- the first side's text, for the tests' and screen readers' sake
	bar.title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	bar.title:SetPoint("TOP", 0, -30)
	bar.rows = {}
	local previous
	for lane = 1, 3 do
		local r = { icons = {} }
		r.label = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		if previous then
			r.label:SetPoint("LEFT", previous, "RIGHT", 8, 0)
		else
			r.label:SetPoint("TOPLEFT", 4, -46)
		end
		local last = r.label
		for i = 1, 4 do
			local icon = bar:CreateTexture(nil, "ARTWORK")
			icon:SetSize(LANE_ICON, LANE_ICON)
			icon:SetPoint("LEFT", last, "RIGHT", i == 1 and 3 or 0, 0)
			r.icons[i] = icon
			last = icon
		end
		previous = last
		bar.rows[lane] = r
	end
	bar.capture = private.BuildCapture()
	private.bar = bar
	return bar
end

---The battlegrounds' capture bar: the "factions" frame, Alliance fill left, Horde fill right, a neutral middle with its
---separators, the spark, and our line of text under it.
function private.BuildCapture()
	local C = Wanted.CapturesMap.COLORS
	local capture = CreateFrame("Frame", "WantedCaptureProgress", UIParent)
	capture:SetSize(CAPTURE_W, CAPTURE_H)
	capture:SetFrameStrata("LOW")
	capture.left = capture:CreateTexture(nil, "BACKGROUND")
	capture.left:SetPoint("LEFT", BAR_OFFSET, 0)
	private.Atlas(capture.left, CAPTURE_ART.left, C.Alliance, BAR_WIDTH * (0.5 - NEUTRAL / 2), 9)
	capture.right = capture:CreateTexture(nil, "BACKGROUND")
	capture.right:SetPoint("RIGHT", -BAR_OFFSET, 0)
	private.Atlas(capture.right, CAPTURE_ART.right, C.Horde, BAR_WIDTH * (0.5 - NEUTRAL / 2), 9)
	capture.neutral = capture:CreateTexture(nil, "BORDER")
	capture.neutral:SetPoint("CENTER")
	private.Atlas(capture.neutral, CAPTURE_ART.neutral, { 0.6, 0.6, 0.6 }, BAR_WIDTH * NEUTRAL, 9)
	capture.frame = capture:CreateTexture(nil, "ARTWORK")
	capture.frame:SetPoint("TOP")
	private.Atlas(capture.frame, CAPTURE_ART.frame, { 0, 0, 0, 0 })
	for _, side in ipairs({ "LEFT", "RIGHT" }) do
		local line = capture:CreateTexture(nil, "ARTWORK")
		private.Atlas(line, CAPTURE_ART.line, { 0, 0, 0 })
		line:SetPoint(side == "LEFT" and "RIGHT" or "LEFT", capture.neutral, side, side == "LEFT" and 1 or -1, 0)
	end
	capture.spark = capture:CreateTexture(nil, "OVERLAY")
	private.Atlas(capture.spark, CAPTURE_ART.spark, { 1, 0.82, 0 })
	capture.text = capture:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	capture.text:SetPoint("TOP", capture, "BOTTOM", 0, -2)
	return capture
end

---Where the HUD goes: the top widget under the game's top-centre widgets, the capture bar under the minimap's, as a
---battleground's sit.
function private.Place(bar)
	bar:ClearAllPoints()
	if UIWidgetTopCenterContainerFrame then
		bar:SetPoint("TOP", UIWidgetTopCenterContainerFrame, "BOTTOM", 0, -4)
	else
		bar:SetPoint("TOP", UIParent, "TOP", 0, -60)
	end
	local capture = bar.capture
	capture:ClearAllPoints()
	if UIWidgetBelowMinimapContainerFrame then
		capture:SetPoint("TOP", UIWidgetBelowMinimapContainerFrame, "BOTTOM", 0, -4)
	else
		capture:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -40, -220)
	end
end

---Shows the HUD for the front the player is in, or hides it; and notes inhibitors respawning as their time comes. The
---widget is placed and given its art when the player comes into a front, and redrawn only when something changed;
---each second only the capture bar's spark and line move, and only when they changed.
function CapturesHUD:Update()
	private.CheckRespawns()
	local _, _, _, mapId = Wanted.Recorder:GetPosition()
	local front = Captures:FrontOn(mapId)
	private.TrackTaking(front)
	if not front or not Captures:Settings().bar then
		if private.bar then
			private.bar:Hide()
			private.bar.capture:Hide()
		end
		private.shownFront = nil
		return
	end
	local bar = private.bar or private.Build()
	if front ~= private.shownFront then
		private.shownFront, private.dirty = front, true
		private.Place(bar)
		for side, half in pairs({ Alliance = bar.alliance, Horde = bar.horde }) do
			private.Atlas(half.icon, TOWER_ATLAS[side], Wanted.CapturesMap.COLORS[side], 42, 42)
		end
	end
	if private.dirty then
		private.dirty = false
		local horde, alliance = private.Towers(front)
		bar.alliance.text:SetText(format("Towers: %d", alliance))
		bar.horde.text:SetText(format("Towers: %d", horde))
		local winner = Captures:Winner(front)
		bar.title:SetText(winner and format("%s: won by the %s this week", front.zone, winner) or front.zone)
		for row, lane in ipairs(front.lanes) do
			local r = bar.rows[row]
			r.label:SetText(lane.name)
			for i, p in ipairs(lane.points) do
				Wanted.CapturesMap:SetIcon(r.icons[i], Captures:Get(p.id))
			end
		end
	end
	private.UpdateCapture(bar.capture)
	bar:Show()
end

---How many of a front's towers and inhibitors each side holds: horde, alliance.
function private.Towers(front)
	local horde, alliance = 0, 0
	for _, lane in ipairs(front.lanes) do
		for _, p in ipairs(lane.points) do
			if Captures:Holder(p.id) == "Horde" then
				horde = horde + 1
			else
				alliance = alliance + 1
			end
		end
	end
	return horde, alliance
end

---Puts the capture bar's spark at a place along it, 0 (the Alliance's end, on the left) to 1 (the Horde's), moving it
---only when it moved a pixel.
function private.Spark(capture, at)
	local x = floor(BAR_OFFSET + BAR_WIDTH * min(max(at, 0), 1) + 0.5)
	if capture.sparkX ~= x then
		capture.sparkX = x
		capture.spark:ClearAllPoints()
		capture.spark:SetPoint("CENTER", capture, "LEFT", x, 0)
	end
end

---Sets the line under the capture bar, only when it changed.
function private.Line(capture, text)
	if capture.line ~= text then
		capture.line = text
		capture.text:SetText(text)
	end
end

---The capture bar while the player stands in a point: the spark at its holder's end, moving toward the middle and on to
---our end as our side takes it.
function private.UpdateCapture(capture)
	local point = Captures:Current()
	if not point then
		capture:Hide()
		return
	end
	local side = UnitFactionGroup("player")
	local holder = Captures:Holder(point.id)
	local from = holder == "Alliance" and 0 or 1
	local allies = Captures:Allies(point.id)
	local name = format("%s %s", point.home, Captures:Role(point))
	local blocked = Captures:BlockedReason()
	if capture.blocked ~= (blocked ~= nil) then
		capture.blocked = blocked ~= nil
		capture.left:SetDesaturated(capture.blocked)
		capture.right:SetDesaturated(capture.blocked)
	end
	if blocked then
		private.Spark(capture, from)
		private.Line(capture, format("%s: %s, so you don't count here", name, blocked))
	elseif holder == side then
		private.Spark(capture, from)
		private.Line(capture, format("Holding the %s: %d of your side here", name, allies))
	elseif not Captures:CanAttack(side, point) then
		private.Spark(capture, from)
		private.Line(capture, format("%s: take the lane before it first", name))
	else
		local need = (point.lane and Captures.CAPTURE_SLOTS or Captures.NEXUS_SLOTS) * Captures.SLOT_SECONDS
		local since = private.takingSince[point.id]
		local done = since and min(GetTime() - since, need) or 0
		private.Spark(capture, from + (1 - 2 * from) * done / need)
		if allies < Captures.MIN_PEOPLE then
			private.Line(capture, format("%s: %d of your side here, %d needed", name, allies, Captures.MIN_PEOPLE))
		else
			private.Line(capture, format("Taking the %s: %d:%02d of %d:00 (provisional)", name, floor(done / 60), floor(done % 60), need / 60))
		end
	end
	capture:Show()
end

---Notes when our side started taking each point of the front, for the capture bar.
function private.TrackTaking(front)
	for _, point in ipairs(Captures.POINTS) do
		if point.front == front and Captures:Taking(point) then
			private.takingSince[point.id] = private.takingSince[point.id] or GetTime()
		else
			private.takingSince[point.id] = nil
		end
	end
end



-- ============================================================================
-- Alerts
-- ============================================================================

-- The colour an announcement falls back on when the chat colours aren't there: the game's gold
local GOLD = { r = 1, g = 0.82, b = 0 }

---Announces in the middle of the screen as a battleground does: on our own frame from Blizzard's RaidWarningFrameTemplate
---(WantedCaptureAnnounceFrame, CapturesHUD.xml, BG system messages only), in that side's BG system colour, and plays its
---sound: key from ALERTS, what (the role, for the title), sub (where, in chat). Falls back to Wanted's own warning when
---the frame isn't there.
function private.Alert(key, what, sub)
	local alert = ALERTS[key]
	local side = UnitFactionGroup("player")
	local colorSide = alert[2] == "ours" and side or alert[2] == "theirs" and (side == "Horde" and "Alliance" or "Horde") or nil
	local text = format(alert[1], what or "")
	local info = ChatTypeInfo and ChatTypeInfo[colorSide == "Alliance" and "BG_SYSTEM_ALLIANCE" or colorSide == "Horde" and "BG_SYSTEM_HORDE" or "BG_SYSTEM_NEUTRAL"]
	if type(info) ~= "table" or type(info.r) ~= "number" or type(info.g) ~= "number" or type(info.b) ~= "number" then
		info = GOLD
	end
	local frame = WantedCaptureAnnounceFrame
	local shown = frame and frame.AddMessage and RaidWarningUtil and RaidWarningUtil.MessageType
		and pcall(frame.AddMessage, frame, text, info, nil, RaidWarningUtil.MessageType.BGSystem)
	if not shown then
		local C = Wanted.CapturesMap.COLORS
		Wanted.Alerts:Warn(text, sub, colorSide and C[colorSide] or Wanted.Theme.C.white)
	elseif sub then
		Wanted:Print("%s (%s)", text, sub)
	end
	if not Wanted.Alerts:IsMuted() and SOUNDKIT and SOUNDKIT[alert[3]] then
		PlaySound(SOUNDKIT[alert[3]], "Master")
	end
end

---Where a point is, for an alert's second line: "Mid Tower, Darrow Hill, Hillsbrad Foothills".
function private.Where(point)
	return format("%s, %s, %s", Captures:Role(point), point.name, point.front.zone)
end

---What the site's holds changed since the addon last showed them (at login): the most important as an alert, the rest
---in chat.
function private.TellNews(news)
	if not Captures:Settings().alerts or not Wanted.Alerts then
		return
	end
	local function Key(item)
		local kind, point = item.kind, item.point
		local inhibitor = Captures:Kind(point) == "inhibitor"
		if (kind == "lost" or kind == "taken") and inhibitor then
			return kind.."Inhibitor"
		end
		-- An inhibitor of ours back is good news; one of theirs back is theirs: both say it respawned
		return kind == "respawned" and "respawned" or kind
	end
	sort(news, function(a, b) return (PRIORITY[Key(a)] or 9) < (PRIORITY[Key(b)] or 9) end)
	for i, item in ipairs(news) do
		local key = Key(item)
		local what = nil
		if key == "won" or key == "beaten" then
			what = Captures.TERMS.nexus
		elseif key == "lost" or key == "taken" then
			what = strlower(Captures.TERMS.tower)
		end
		if i == 1 then
			private.Alert(key, what, nil)
		end
		Wanted:Print("Capture fronts since you last looked: %s (%s).", format(ALERTS[key][1], what or ""), private.Where(item.point))
	end
end

---Live alerts, from our side's channel and nameplates: our side attacking an enemy point or Nexus, enemies at the
---player's own point.
function private.CheckLive()
	if not Captures:Settings().alerts or not Wanted.Alerts then
		return
	end
	local _, _, _, mapId = Wanted.Recorder:GetPosition()
	local front = Captures:FrontOn(mapId)
	if not front then
		return
	end
	local now = GetTime()
	local current = Captures:Current()
	for _, point in ipairs(Captures.POINTS) do
		if point.front == front and point ~= current and Captures:Taking(point) and private.Due("taking:"..point.id, now) then
			local sub = format("%d of your side at %s (provisional)", Captures:Allies(point.id), point.name)
			if point.lane then
				private.Alert("attacking", Captures:Role(point), sub)
			else
				private.Alert("enemyNexus", Captures.TERMS.nexus, sub)
			end
		end
	end
	local enemies = Wanted.Enemies and Wanted.Enemies:CountNearby() or 0
	local side = UnitFactionGroup("player")
	if current and Captures:Holder(current.id) == side and enemies >= ENEMY_ALERT and private.Due("enemies:"..current.id, now) then
		private.Alert("underAttack", current.lane and strlower(Captures:Kind(current)) or Captures.TERMS.nexus, format("%d enemies near you at %s", enemies, current.name))
	end
end

---An inhibitor whose respawn time passes while playing goes back to its side (provisionally): say so once. Quiet only
---notes who holds what.
function private.CheckRespawns(quiet)
	for _, point in ipairs(Captures.POINTS) do
		local holder = Captures:Holder(point.id)
		local before = private.holders[point.id]
		private.holders[point.id] = holder
		if before and before ~= holder then
			private.dirty = true
		end
		if not quiet and before and before ~= holder and holder == point.home and Captures:Kind(point) == "inhibitor" and Captures:Settings().alerts and Wanted.Alerts then
			private.Alert("respawned", nil, private.Where(point))
		end
	end
end

---Whether an alert is due: none of its kind in the last ALERT_SECONDS.
function private.Due(key, now)
	if private.alerted[key] and now - private.alerted[key] < ALERT_SECONDS then
		return false
	end
	private.alerted[key] = now
	return true
end
