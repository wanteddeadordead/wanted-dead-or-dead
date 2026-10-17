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
local W = Wanted.Widgets
local private = {
	bar = nil,
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
	-- %s names the point: its lane and role ("Mid Inhibitor"), or the Nexus
	lost = { "Your %s has been destroyed", "theirs", "RAID_WARNING" },
	lostInhibitor = { "Your %s is down", "theirs", "RAID_WARNING" },
	taken = { "Enemy %s destroyed", "ours", "PVP_THROUGH_QUEUE" },
	takenInhibitor = { "Enemy %s down", "ours", "PVP_THROUGH_QUEUE" },
	respawned = { "%s respawned", "neutral", "IG_PVP_UPDATE" },
	won = { "Victory: the enemy %s has fallen", "ours", "UI_BATTLEGROUND_COUNTDOWN_FINISHED" },
	beaten = { "Defeat: your %s has fallen", "theirs", "RAID_WARNING" },
	attacking = { "Your side is attacking the enemy %s", "ours", "PVP_ENTER_QUEUE" },
	enemyNexus = { "Enemy %s under attack", "ours", "RAID_BOSS_EMOTE_WARNING" },
	underAttack = { "Your %s is under attack", "theirs", "RAID_BOSS_EMOTE_WARNING" },
	-- Siege nights: the text is made whole by private.SiegeAlert
	siegeCall = { "%s", "neutral", "IG_PVP_UPDATE" },
	siegeOpen = { "%s", "neutral", "PVP_ENTER_QUEUE" },
	siegeWon = { "%s", "ours", "UI_BATTLEGROUND_COUNTDOWN_FINISHED" },
	siegeLost = { "%s", "theirs", "RAID_WARNING" },
	siegeRound = { "%s", "neutral", "PVP_ENTER_QUEUE" },
	siegeOver = { "%s", "neutral", "UI_BATTLEGROUND_COUNTDOWN_FINISHED" },
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
local LANE_ICON = 18



-- ============================================================================
-- Lifecycle
-- ============================================================================

---At load, before anything else and also on a Normal-ruleset character where Wanted stays idle: our announcement frame
---(made from Blizzard's template, which registers the BG system message events) shows only what Wanted gives it, never
---the game's own messages.
function CapturesHUD:OnLoad()
	if WantedCaptureAnnounceFrame then
		WantedCaptureAnnounceFrame:UnregisterAllEvents()
	end
end

function CapturesHUD:OnEnable()
	if not Wanted:SiegeOn() then
		return -- siege nights are off on this client (Wanted:SiegeOn)
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
	Captures:OnSiege(function(kind, a, b) private.SiegeAlert(kind, a, b) end)
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
	s.icon:SetPoint("LEFT")
	s.text = s:CreateFontString(nil, "BACKGROUND", "GameFontNormalSmall")
	s.text:SetJustifyH("LEFT")
	-- The widget's own offsets: its icon doesn't fill its tile
	s.text:SetPoint("LEFT", s.icon, "RIGHT", -12, 0)
	return s
end

-- The widget's rows: the title, then the three lanes one under another (each its four points, Horde end to
-- Alliance end), the two sides' Nexus and tower count beside them, centred on the middle lane, then the siege line
local ROW_TOP, ROW_STEP, ROWS_X = 22, 22, 118

---Makes the HUD: the top widget (both sides, the lane rows) and the capture bar.
function private.Build()
	local bar = CreateFrame("Frame", "WantedCaptureBar", UIParent)
	bar:SetSize(330, 112)
	bar:SetFrameStrata("LOW")
	local middle = -(ROW_TOP + ROW_STEP + LANE_ICON / 2)
	bar.horde = private.Side(bar, "Horde")
	bar.horde:SetPoint("LEFT", bar, "TOPLEFT", 6, middle)
	bar.alliance = private.Side(bar, "Alliance")
	bar.alliance:SetPoint("RIGHT", bar, "TOPRIGHT", -6, middle)
	bar.count = bar.alliance.text -- the first side's text, for the tests' and screen readers' sake
	bar.title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	bar.title:SetPoint("TOP", 0, -4)
	bar.rows = {}
	for lane = 1, 3 do
		local r = { icons = {}, marks = {} }
		r.label = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		r.label:SetPoint("TOPLEFT", ROWS_X, -(ROW_TOP + (lane - 1) * ROW_STEP + 3))
		r.label:SetWidth(28)
		r.label:SetJustifyH("RIGHT")
		local last = r.label
		for i = 1, 4 do
			local icon = bar:CreateTexture(nil, "ARTWORK")
			icon:SetSize(LANE_ICON, LANE_ICON)
			icon:SetPoint("LEFT", last, "RIGHT", i == 1 and 3 or 0, 0)
			r.icons[i] = icon
			-- An X in its taker's colour, with a dark edge, over a point its home side lost: the piece keeps its home
			-- side's colour, so a blue tower under a red X is an Alliance tower the Horde took (2026-10-16)
			local mark = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
			mark:SetPoint("CENTER", icon, "CENTER", 0, 1)
			mark:SetText("X")
			mark:SetShadowColor(0, 0, 0, 1)
			mark:SetShadowOffset(1, -1)
			mark:Hide()
			r.marks[i] = mark
			last = icon
		end
		bar.rows[lane] = r
	end
	-- Tonight's siege, under the lane rows
	bar.siege = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	bar.siege:SetPoint("TOP", 0, -(ROW_TOP + 3 * ROW_STEP + 4))
	-- During the siege: its layer and whether we're on it (Shard), with Hop, or the hop under way with Stay
	bar.hop = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	bar.hop:SetPoint("TOP", -26, -(ROW_TOP + 3 * ROW_STEP + 22))
	bar.hopButton = W:Button(bar, "Hop", "chip", 44, 16, function()
		local why = Wanted.Shard:Holding() and Wanted.Shard:Stay() or Wanted.Shard:Hop()
		if why then
			Wanted:Print("%s", why)
		end
	end)
	bar.hopButton.label:SetFontObject(Wanted.Theme.Fonts.small)
	bar.hopButton:SetPoint("LEFT", bar.hop, "RIGHT", 6, 0)
	W:AttachTooltip(bar.hopButton, "Hop to the siege's layer", "Asks a Wanted player of your side on the siege's layer for a group invite: your addon accepts it, holds the group so the move sticks, then leaves it, unless you click Stay or the host leads the rally. One hop every ten minutes.")
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
	-- Which way the spark is going, over it: chevrons toward the end the attackers are pushing it to
	capture.arrow = capture:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	capture.arrow:SetPoint("BOTTOM", capture.spark, "TOP", 0, -3)
	return capture
end

---Where the HUD goes: the top widget under the game's top-centre widgets, and the capture bar right under it. (A
---battleground's capture bar sits under the minimap; ours did too, and under a moved minimap or another addon's
---panels it was never seen: the maintainer stood in a point on 2026-10-16 with the bar shown and nothing on screen.)
function private.Place(bar)
	bar:ClearAllPoints()
	if UIWidgetTopCenterContainerFrame then
		bar:SetPoint("TOP", UIWidgetTopCenterContainerFrame, "BOTTOM", 0, -4)
	else
		bar:SetPoint("TOP", UIParent, "TOP", 0, -60)
	end
	local capture = bar.capture
	capture:ClearAllPoints()
	capture:SetPoint("TOP", bar, "BOTTOM", 0, -6)
	-- The announcements under the capture bar's line, never over it (the XML's fixed spot crossed it, 2026-10-16)
	local announce = WantedCaptureAnnounceFrame
	if announce and announce.ClearAllPoints and announce.SetPoint then
		announce:ClearAllPoints()
		announce:SetPoint("TOP", capture, "BOTTOM", 0, -30)
	end
end

---Shows the HUD for the front the player is in, or hides it; and notes inhibitors respawning as their time comes. The
---widget is placed and given its art when the player comes into a front, and redrawn only when something changed;
---each second only the capture bar's spark and line move, and only when they changed.
function CapturesHUD:Update()
	private.CheckRespawns()
	local _, _, _, mapId = Wanted.Recorder:GetPosition()
	local front = Captures:FrontOn(mapId)
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
		bar.alliance.text:SetText(format("Points: %d", alliance))
		bar.horde.text:SetText(format("Points: %d", horde))
		local winner = Captures:Winner(front)
		local wins = Captures:FrontWins(front)
		bar.title:SetText(winner and format("%s: won by the %s this week", front.zone, winner)
			or wins and format("%s: Horde %d, Alliance %d this week", front.zone, wins.Horde, wins.Alliance) or front.zone)
		for row, lane in ipairs(front.lanes) do
			local r = bar.rows[row]
			r.label:SetText(lane.name)
			for i, p in ipairs(lane.points) do
				local point = Captures:Get(p.id)
				local lost = Wanted.CapturesMap:SetIcon(r.icons[i], point)
				r.marks[i]:SetShown(lost)
				if lost then
					local c = Wanted.CapturesMap.COLORS[Captures:Holder(p.id)] or { 1, 1, 1 }
					r.marks[i]:SetTextColor(c[1], c[2], c[3])
				end
			end
		end
	end
	local siege = private.SiegeLine()
	if bar.siegeText ~= siege then
		bar.siegeText = siege
		bar.siege:SetText(siege)
	end
	local hop, button = private.HopLine(front)
	if hop then
		bar.hop:SetText(hop)
		bar.hopButton:SetText(button or "Hop")
		-- Centred on its own ("You're on the siege's layer"); left of the middle when its button sits beside it
		bar.hop:ClearAllPoints()
		bar.hop:SetPoint("TOP", button and -26 or 0, -(ROW_TOP + 3 * ROW_STEP + 22))
	end
	bar.hop:SetShown(hop ~= nil)
	bar.hopButton:SetShown(button ~= nil)
	bar:SetHeight(hop and 132 or 112)
	private.UpdateCapture(bar.capture)
	bar:Show()
end

---The top widget's layer line while the siege is on at this front (from an hour before the window until it's over):
---the siege's layer and whether we're on it, or the hop under way (Shard:Line), and its button; nil otherwise.
---@param front table
---@return string? text
---@return string? button
function private.HopLine(front)
	local s = Captures:Siege()
	if not s or s.front ~= front or not Captures:RespawnPaused(front) then
		return nil, nil
	end
	return Wanted.Shard:Line(front.zone, front.mapId)
end

---An hour of the day as the client's clock shows it, "7 PM" (date() formats a server time in the PC's own zone, as
---the respawn times on the map are shown).
function private.Hour(t)
	local ok, text = pcall(date, "%I %p", t)
	if not ok or type(text) ~= "string" then
		return "?"
	end
	return (text:gsub("^0", ""))
end

---A siege window as the client's clock shows it: "7 to 10 PM", or "11 AM to 2 PM" across noon; on another day than
---today, with the day first: "Fri 7 to 10 PM" (the catch-up names the next siege as soon as it's picked), unless
---plain asks for the hours alone.
function private.Window(s, plain)
	local from, to = private.Hour(s.start), private.Hour(s["end"])
	local fromSuffix, toSuffix = from:match("%a+$"), to:match("%a+$")
	if fromSuffix and fromSuffix == toSuffix then
		from = from:gsub(" %a+$", "")
	end
	local day = not plain and date("%j", s.start) ~= date("%j") and date("%a", s.start).." " or ""
	return format("%s%s to %s", day, from, to)
end

---A siege's window as the client's clock shows it, "Fri 7 to 10 PM" (the hours alone with plain), for the Siege page.
---@param s table a siege (Captures:Siege), or anything with start and ["end"]
---@param plain boolean?
---@return string
function CapturesHUD:WindowText(s, plain)
	return private.Window(s, plain)
end

---An hour of the day as the client's clock shows it, "7 PM".
---@param t number a server time
---@return string
function CapturesHUD:HourText(t)
	return private.Hour(t)
end

---"12:40" from seconds.
function private.Clock(seconds)
	seconds = max(floor(seconds), 0)
	return format("%d:%02d", floor(seconds / 60), seconds % 60)
end

---The top widget's siege line: the window before it opens, the round and the score during, the truce's clock
---between rounds, the result after; nothing when the catch-up named no siege.
function private.SiegeLine()
	local s = Captures:Siege()
	local phase = Captures:Phase()
	if not s then
		return ""
	end
	local score = format("Horde %d Alliance %d", s.wins.Horde, s.wins.Alliance)
	if phase == "before" then
		return format("Siege: %s %s", s.front.zone, private.Window(s))
	elseif phase == "truce" then
		return format("Truce %s · %s", private.Clock(s.round.truceUntil - GetServerTime()), score)
	elseif phase == "over" then
		return format("Siege over · %s", score)
	end
	-- A round runs until a Nexus falls or the window closes: the window's clock, then overtime (a round still moving
	-- past the window plays out, up to an hour)
	local left = s["end"] - GetServerTime()
	return format("Round %d · %s · %s", s.round and s.round.n or 1, score, left > 0 and private.Clock(left).." left" or "overtime")
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
	local p = Captures:Progress(point)
	-- The spark moves toward the attacking side's end as the point's samples near its cost; the chevrons over it say
	-- which way, in the attackers' colour, only while it's moving
	local toward = p.side == "Alliance" and 0 or 1
	private.Spark(capture, from + (toward - from) * min(p.n / p.cost, 1))
	if p.attackers > 0 and p.net > 0 and not blocked then
		local c = Wanted.CapturesMap.COLORS[p.side] or { 1, 0.82, 0 }
		capture.arrow:SetText(toward == 0 and "<<" or ">>")
		capture.arrow:SetTextColor(c[1], c[2], c[3])
		capture.arrow:Show()
	else
		capture.arrow:Hide()
	end
	-- How long at this tick's pace: "3:10 left"
	local left = p.net > 0 and format(", %s left", private.Clock(ceil((p.cost - p.n) / p.net) * Captures.SAMPLE_SECONDS)) or ""
	if blocked then
		private.Line(capture, format("%s: %s, so you don't count here", name, blocked))
	elseif holder == side then
		local attacked = p.attackers > 0 and format(", %d attacking%s", p.attackers, left) or ""
		private.Line(capture, format("Holding the %s: %d of your side%s%s", name, p.defenders, attacked, p.attackers > 0 and " (provisional)" or ""))
	elseif Captures:TruceOn(point.front) then
		private.Line(capture, format("%s: a truce holds the front until %s", name, private.Clock(Captures:Siege().round.truceUntil - GetServerTime())))
	elseif not point.lane and not Captures:RoundOn(point.front) then
		private.Line(capture, format("%s: only falls in a siege round", name))
	elseif not Captures:CanAttack(side, point) then
		private.Line(capture, format("%s: take the lane before it first", name))
	elseif allies < Captures.MIN_PEOPLE then
		private.Line(capture, format("%s: %d of your side here, %d needed", name, allies, Captures.MIN_PEOPLE))
	else
		local held = p.net <= 0 and ", held off" or left
		private.Line(capture, format("Taking the %s: %d of your side, %d defending%s (provisional)", name, p.attackers, p.defenders, held))
	end
	capture:Show()
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
		else
			what = Captures:Role(item.point)
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
	if current and Captures:Holder(current.id) == side and enemies >= ENEMY_ALERT and not Captures:TruceOn(current.front) and private.Due("enemies:"..current.id, now) then
		private.Alert("underAttack", Captures:Role(current), format("%d enemies near you at %s", enemies, current.name))
	end
end

---Whether the player is in a front's zone or has its map open: where the siege's rounds and falls are announced.
function private.InZone(front)
	local _, _, _, mapId = Wanted.Recorder:GetPosition()
	if Captures:FrontOn(mapId) == front then
		return true
	end
	return WorldMapFrame ~= nil and WorldMapFrame:IsShown() and WorldMapFrame:GetMapID() == front.mapId
end

---The siege's announcements (Captures:OnSiege): the call half an hour before the window and the open go to every
---Wanted player wherever they are (the Siege call setting); a Nexus falling, the next round and the end only in the
---zone or with its map open (the alerts setting).
function private.SiegeAlert(kind, a, b)
	local s = Captures:Siege()
	if not s or not Wanted.Alerts then
		return
	end
	local settings = Captures:Settings()
	if kind == "call" and settings.siegeCall then
		private.Alert("siegeCall", format("The %ses of %s open at %s", Captures.TERMS.nexus, s.front.zone, private.Hour(s.start)))
	elseif kind == "open" and settings.siegeCall then
		private.Alert("siegeOpen", format("The siege of %s has begun", s.front.zone))
	elseif not settings.alerts or not private.InZone(s.front) then
		return
	elseif kind == "fell" then
		local point, side = a, b
		private.Alert(side == UnitFactionGroup("player") and "siegeWon" or "siegeLost", format("The %s %s has fallen", point.name, Captures.TERMS.nexus),
			format("Round %d to the %s (provisional)", s.round and s.round.n - 1 or 1, side))
	elseif kind == "round" then
		private.Alert("siegeRound", format("Round %d begins", a))
	elseif kind == "over" then
		private.Alert("siegeOver", format("The siege is over: Horde %d, Alliance %d", s.wins.Horde, s.wins.Alliance))
	end
end

---A point whose holder changed while playing: an inhibitor whose respawn time passed goes back to its side, a point
---this client saw taken (provisionally) changes hands: say so once. Quiet only notes who holds what.
function private.CheckRespawns(quiet)
	local side = UnitFactionGroup("player")
	for _, point in ipairs(Captures.POINTS) do
		local holder = Captures:Holder(point.id)
		local before = private.holders[point.id]
		private.holders[point.id] = holder
		if before and before ~= holder then
			private.dirty = true
		end
		if not quiet and before and before ~= holder and point.lane and Captures:Settings().alerts and Wanted.Alerts then
			local inhibitor = Captures:Kind(point) == "inhibitor"
			if holder == point.home then
				-- Not the siege front going back to level after a Nexus fell: that's the round's news
				if inhibitor and not Captures:RespawnPaused(point.front) then
					private.Alert("respawned", Captures:Role(point), private.Where(point))
				end
			elseif private.InZone(point.front) then
				local key = (holder == side and "taken" or "lost")..(inhibitor and "Inhibitor" or "")
				private.Alert(key, Captures:Role(point), private.Where(point).." (provisional)")
			end
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
