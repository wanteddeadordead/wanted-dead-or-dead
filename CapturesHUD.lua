-- Wanted: the capture front bar. In a front's zone, a battleground-style bar at the top of the screen: points each side
-- holds, and each lane as a row of squares from the Horde base to the Alliance's, coloured by holder. While the player
-- stands in a point, a capture bar under it: how many of our side are there and how far our side is toward taking it,
-- as our side's channel tells it (provisional; the site decides). Alerts when our side gathers at a point in the zone,
-- or enemies are close while the player stands in one. Plain frames only, nothing protected: safe in combat.

local _, Wanted = ...
local CapturesHUD = Wanted:NewModule("CapturesHUD")
local Captures = Wanted.Captures
local private = { bar = nil, takingSince = {}, alerted = {} }
local UPDATE_SECONDS = 1
local SQUARE, GAP = 12, 3
-- One alert per point this often, and enemies counted as a threat at a point from this many
local ALERT_SECONDS = 5 * 60
local ENEMY_ALERT = 2



-- ============================================================================
-- Lifecycle
-- ============================================================================

function CapturesHUD:OnEnable()
	C_Timer.NewTicker(UPDATE_SECONDS, Wanted:Timed("Captures bar", function() CapturesHUD:Update() end))
	Captures:OnChange(function() private.CheckAlerts() end)
end



-- ============================================================================
-- The bar
-- ============================================================================

function private.Square(parent)
	local square = parent:CreateTexture(nil, "ARTWORK")
	square:SetSize(SQUARE, SQUARE)
	square:SetColorTexture(1, 1, 1, 1)
	return square
end

---Makes the bar: a title, the count, three lane rows of six squares, and the capture bar.
function private.Build()
	local bar = CreateFrame("Frame", "WantedCaptureBar", UIParent)
	bar:SetSize(260, 92)
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
		local r = { squares = {} }
		r.label = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		r.label:SetPoint("TOPLEFT", 8, -28 - (row - 1) * (SQUARE + GAP + 2))
		r.label:SetWidth(110)
		r.label:SetJustifyH("LEFT")
		for i = 1, 6 do
			local square = private.Square(bar)
			square:SetPoint("LEFT", r.label, "RIGHT", 4 + (i - 1) * (SQUARE + GAP), 0)
			r.squares[i] = square
		end
		bar.rows[row] = r
	end
	local capture = CreateFrame("StatusBar", nil, bar)
	capture:SetSize(244, 14)
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

---Shows the bar for the front the player is in, or hides it.
function CapturesHUD:Update()
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
		for i = 1, #lane.points + 2 do
			local id = i == 1 and front.horde.id or i == #lane.points + 2 and front.alliance.id or lane.points[i - 1].id
			local color = Wanted.CapturesMap:ColorOf(Captures:Get(id))
			r.squares[i]:SetVertexColor(color[1], color[2], color[3], 1)
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
	local color = Wanted.CapturesMap.COLORS[side] or Wanted.CapturesMap.COLORS.taking
	capture:SetStatusBarColor(color[1], color[2], color[3])
	if Captures:Holder(point.id) == side then
		capture:SetValue(1)
		capture.text:SetText(format("Holding %s: %d of your side here", point.name, allies))
	elseif not Captures:CanAttack(side, point) then
		capture:SetValue(0)
		capture.text:SetText(format("%s: take the lane's points before it first", point.name))
	else
		local need = (point.lane and Captures.CAPTURE_SLOTS or Captures.BASE_SLOTS) * Captures.SLOT_SECONDS
		local since = private.takingSince[point.id]
		local done = since and min(GetTime() - since, need) or 0
		capture:SetValue(done / need)
		if allies < Captures.MIN_PEOPLE then
			capture.text:SetText(format("%s: %d of your side here, %d needed", point.name, allies, Captures.MIN_PEOPLE))
		else
			capture.text:SetText(format("Taking %s: %d:%02d of %d:00 (provisional)", point.name, floor(done / 60), floor(done % 60), need / 60))
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

---Warns when our side gathers at a point of the player's front, or enemies are close while the player stands in one.
function private.CheckAlerts()
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
			Wanted.Alerts:Warn("Your side is taking "..point.name, format("%d of you there (provisional)", Captures:Allies(point.id)), Wanted.CapturesMap.COLORS.taking)
		end
	end
	local enemies = Wanted.Enemies and Wanted.Enemies:CountNearby() or 0
	if current and enemies >= ENEMY_ALERT and private.Due("enemies:"..current.id, now) then
		Wanted.Alerts:Warn("Enemies at "..current.name, format("%d near you", enemies), Wanted.Theme.C.red)
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
