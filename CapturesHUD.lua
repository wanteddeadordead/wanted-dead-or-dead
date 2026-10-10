-- Wanted: the capture front bar. In a front's zone, a battleground-style bar at the top of the screen: points each side
-- holds, and each lane (Top, Mid, Bot) as a row of icons from the Horde Nexus to the Alliance's: towers, inhibitors and
-- the Nexuses in their holder's colour, grey where their side lost them. While the player stands in a point, a capture
-- bar under it: how many of our side are there and how far our side is toward taking it, as our side's channel tells it
-- (provisional; the site decides), or why the player's presence doesn't count. Alerts in the MOBA way: towers
-- destroyed, inhibitors down and respawned, a Nexus under attack. Plain frames only, nothing protected: safe in combat.

local _, Wanted = ...
local CapturesHUD = Wanted:NewModule("CapturesHUD")
local Captures = Wanted.Captures
local private = { bar = nil, takingSince = {}, alerted = {}, holders = {} }
local UPDATE_SECONDS = 1
local ICON, GAP = 16, 3
-- One live alert per point and kind this often, and enemies counted as an attack on our point from this many
local ALERT_SECONDS = 5 * 60
local ENEMY_ALERT = 2
-- What each alert says and plays (the game's own sounds, SoundKitConstants): title, colour key, SOUNDKIT name
local ALERTS = {
	lost = { "Your %s has been destroyed", "red", "RAID_WARNING" },
	lostInhibitor = { "Your inhibitor is down", "red", "RAID_WARNING" },
	taken = { "Enemy %s destroyed", "taking", "PVP_THROUGH_QUEUE" },
	takenInhibitor = { "Enemy inhibitor down", "taking", "PVP_THROUGH_QUEUE" },
	respawned = { "Inhibitor respawned", "white", "IG_PVP_UPDATE" },
	won = { "Victory: the enemy %s has fallen", "taking", "PVP_THROUGH_QUEUE" },
	beaten = { "Defeat: your %s has fallen", "red", "RAID_WARNING" },
	attacking = { "Your side is attacking the enemy %s", "taking", "PVP_ENTER_QUEUE" },
	enemyNexus = { "Enemy %s under attack", "taking", "RAID_BOSS_EMOTE_WARNING" },
	underAttack = { "Your %s is under attack", "red", "RAID_BOSS_EMOTE_WARNING" },
}
-- Which news matters most, when several came at once
local PRIORITY = { won = 1, beaten = 1, lostInhibitor = 2, takenInhibitor = 2, lost = 3, taken = 3, respawned = 4 }



-- ============================================================================
-- Lifecycle
-- ============================================================================

function CapturesHUD:OnEnable()
	C_Timer.NewTicker(UPDATE_SECONDS, Wanted:Timed("Captures bar", function() CapturesHUD:Update() end))
	Captures:OnChange(function(news)
		if news then
			-- The site's holds just came in: what they changed is news of its own, not a respawn seen live
			private.CheckRespawns(true)
			if #news > 0 then
				private.TellNews(news)
			end
		end
		private.CheckLive()
	end)
end



-- ============================================================================
-- The bar
-- ============================================================================

---Makes the bar: a title, the count, three lane rows of six icons, and the capture bar.
function private.Build()
	local bar = CreateFrame("Frame", "WantedCaptureBar", UIParent)
	bar:SetSize(280, 100)
	bar:SetPoint("TOP", UIParent, "TOP", 0, -60)
	bar:SetFrameStrata("LOW")
	bar.bg = bar:CreateTexture(nil, "BACKGROUND")
	bar.bg:SetAllPoints()
	bar.bg:SetColorTexture(0, 0, 0, 0.45)
	bar.title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	bar.title:SetPoint("TOP", 0, -4)
	bar.count = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	bar.count:SetPoint("TOP", bar.title, "BOTTOM", 0, -2)
	bar.rows = {}
	for row = 1, 3 do
		local r = { icons = {} }
		r.label = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		r.label:SetPoint("TOPLEFT", 10, -32 - (row - 1) * (ICON + GAP + 2))
		r.label:SetWidth(40)
		r.label:SetJustifyH("LEFT")
		for i = 1, 6 do
			local icon = bar:CreateTexture(nil, "ARTWORK")
			icon:SetSize(ICON, ICON)
			icon:SetPoint("LEFT", r.label, "RIGHT", 6 + (i - 1) * (ICON + GAP * 6), 0)
			r.icons[i] = icon
		end
		bar.rows[row] = r
	end
	local capture = CreateFrame("StatusBar", nil, bar)
	capture:SetSize(264, 14)
	capture:SetPoint("TOP", bar, "BOTTOM", 0, -4)
	capture:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	capture:SetMinMaxValues(0, 1)
	capture.bg = capture:CreateTexture(nil, "BACKGROUND")
	capture.bg:SetAllPoints()
	capture.bg:SetColorTexture(0, 0, 0, 0.6)
	capture.text = capture:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	capture.text:SetPoint("CENTER")
	bar.capture = capture
	private.bar = bar
	return bar
end

---Shows the bar for the front the player is in, or hides it; and notes inhibitors respawning as their time comes.
function CapturesHUD:Update()
	private.CheckRespawns()
	local _, _, _, mapId = Wanted.Recorder:GetPosition()
	local front = Captures:FrontOn(mapId)
	private.TrackTaking(front)
	if not front or not Captures:Settings().bar then
		if private.bar then
			private.bar:Hide()
		end
		return
	end
	local bar = private.bar or private.Build()
	local horde, alliance = Captures:Count(front)
	local winner = Captures:Winner(front)
	bar.title:SetText(front.zone)
	bar.count:SetText(winner and format("Won by the %s this week", winner) or format("|cffd23d33Horde %d|r  |cff3d7aebAlliance %d|r", horde, alliance))
	for row, lane in ipairs(front.lanes) do
		local r = bar.rows[row]
		r.label:SetText(lane.name)
		local last = #lane.points + 2
		for i = 1, last do
			local id = i == 1 and front.horde.id or i == last and front.alliance.id or lane.points[i - 1].id
			Wanted.CapturesMap:DressIcon(r.icons[i], Captures:Get(id))
		end
	end
	private.UpdateCapture(bar.capture)
	bar:Show()
end

---The capture bar while the player stands in a point.
function private.UpdateCapture(capture)
	local point = Captures:Current()
	if not point then
		capture:Hide()
		return
	end
	local side = UnitFactionGroup("player")
	local allies = Captures:Allies(point.id)
	local name = format("%s %s", point.home, Captures:Role(point))
	local color = Wanted.CapturesMap.COLORS[side] or Wanted.CapturesMap.COLORS.taking
	capture:SetStatusBarColor(color[1], color[2], color[3])
	local blocked = Captures:BlockedReason()
	if blocked then
		capture:SetValue(0)
		capture.text:SetText(format("%s: %s, so you don't count here", name, blocked))
	elseif Captures:Holder(point.id) == side then
		capture:SetValue(1)
		capture.text:SetText(format("Holding the %s: %d of your side here", name, allies))
	elseif not Captures:CanAttack(side, point) then
		capture:SetValue(0)
		capture.text:SetText(format("%s: take the lane before it first", name))
	else
		local need = (point.lane and Captures.CAPTURE_SLOTS or Captures.NEXUS_SLOTS) * Captures.SLOT_SECONDS
		local since = private.takingSince[point.id]
		local done = since and min(GetTime() - since, need) or 0
		capture:SetValue(done / need)
		if allies < Captures.MIN_PEOPLE then
			capture.text:SetText(format("%s: %d of your side here, %d needed", name, allies, Captures.MIN_PEOPLE))
		else
			capture.text:SetText(format("Taking the %s: %d:%02d of %d:00 (provisional)", name, floor(done / 60), floor(done % 60), need / 60))
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

---Shows an alert and plays its sound: key from ALERTS, what (the role, for the title), sub (where).
function private.Alert(key, what, sub)
	local alert = ALERTS[key]
	local C = Wanted.Theme.C
	local color = alert[2] == "taking" and Wanted.CapturesMap.COLORS.taking or C[alert[2]] or C.white
	Wanted.Alerts:Warn(format(alert[1], what or ""), sub, color)
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
			private.Alert(key, what, private.Where(item.point).." (since you last looked)")
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
