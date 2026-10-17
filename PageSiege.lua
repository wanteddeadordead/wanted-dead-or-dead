-- Wanted: the Siege page, the one the window opens on: everything about siege nights (Captures) in one place.
-- Tonight's siege (or the next one picked): its front, window and a countdown, or the round, the score and the
-- three lanes while it's on, with the rally leader and buttons for the map, the rally and a waypoint to the front;
-- the next seven evenings; the results (tonight's rounds as this client saw them, this week's wins per front); the three fronts, each with its
-- lanes' holders, a map and a waypoint; and the rules. The game can't open a browser, so each website address is in
-- a box to copy, as the Website & app page does. Everything scrolls together.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Captures = Wanted.Captures
local private = { cards = {} }
local SITE = "https://wanteddeadordead.com"
local GAP = 12
local PAD = 16
local LINE = 16 -- a line of small text
-- The lane block: a Nexus crest at each end, three lanes of four icons between
local LANE_ICON, LANE_PITCH, CREST = 22, 26, 40
local LANES_WIDTH = CREST + 8 + 30 + 4 * LANE_PITCH + 8 + CREST
local BUTTON_GAP = 6
local FRONT_ROW = 48
local EVENINGS = 7
local EVENING_ROW = 22
-- The site's window, said when no siege is known and so the client can't place it on its own clock
local WINDOW_EASTERN = "7 to 10 PM Eastern"
local RULES = {
	{ "One front a night.", "Every day one of Arathi Highlands, Hillsbrad Foothills and Ashenvale is the siege front, picked the evening before: the most fought front of the last week, never the same one twice in a row. Its Nexuses can fall from 7 to 10 PM Eastern. The other two fronts' lanes stay open as usual; their Nexuses don't." },
	{ "The lanes, all day.", "Each lane holds each side's tower and inhibitor. Take a lane from your end: the enemy's tower, then the inhibitor behind it. An inhibitor down opens that side's Nexus. It respawns 30 minutes after its takers last held it, except on the siege front from 6 PM, where it stays down until the siege ends: a lane broken before 7 is still broken at 7." },
	{ "Taking a point.", "Presence counts in samples: one player of a side inside the circle every 30 seconds, able to fight (not mounted, flying, stealthed, dead or away). Each defender inside cancels one attacker that tick, and at most 6 attackers count, so stacking more gains nothing. A tower or inhibitor costs 40 samples (two people ten minutes, six people under four); a Nexus 120 with one of its inhibitors down, 60 with two, 30 with all three." },
	{ "Rounds.", "A Nexus falling wins the round for its attackers: the front goes back to level, a 30-minute truce follows, then the next round. A win before 10 PM earns another round even when its truce ends after 10; a round running at 10 plays out and is the last. The last round ends with no winner after 15 minutes without Nexus progress, or at 11 PM." },
	{ "The week.", "The side with more siege wins on a front holds it for the campaign week, ties broken by how long each side held its points. The week turns over on Tuesday." },
	{ "Who decides.", "wanteddeadordead.com decides every hold from at least two different players' apps and the kills there; one player's addon never does. What you see in game between the app's updates is provisional." },
}



-- ============================================================================
-- Helpers
-- ============================================================================

---"12:40" from seconds.
function private.Clock(seconds)
	seconds = max(floor(seconds), 0)
	return format("%d:%02d", floor(seconds / 60), seconds % 60)
end

---A time of day as the client's clock shows it, "7:42 PM".
function private.TimeText(t)
	local ok, text = pcall(date, "%I:%M %p", t)
	if not ok or type(text) ~= "string" then
		return "?"
	end
	return (text:gsub("^0", ""))
end

---Whether a siege's day is today on the client's clock.
function private.Today(s)
	return date("%j", s.start) == date("%j")
end

---"Horde 1 · Alliance 0" in the sides' colours.
function private.Score(horde, alliance)
	local COLORS = Wanted.CapturesMap.COLORS
	return Theme:Colorize("Horde "..horde, COLORS.Horde).." · "..Theme:Colorize("Alliance "..alliance, COLORS.Alliance)
end

---Whether the player stands in a front's zone.
function private.OnFront(front)
	local _, _, _, mapId = Wanted.Recorder:GetPosition()
	return mapId == front.mapId
end

---Whether the player leads their group.
function private.GroupLeader()
	return IsInGroup() and type(UnitIsGroupLeader) == "function" and UnitIsGroupLeader("player") == true
end

---An address with a label over it, in a box to copy.
function private.AddLink(card, label, url, width)
	local text = Theme:Text(card, "small", label, C.muted)
	local box = W:CopyBox(card, width - 2 * PAD, url)
	box:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -4)
	return text, box
end

---A lane icon or a Nexus crest hovered: the point's role and name, who holds it, and how far it is toward being taken.
function private.OnEnterPoint(self)
	local point = self.point
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetText(format("%s %s", point.home, Captures:Role(point)), 1, 1, 1)
	GameTooltip:AddLine(point.name, 0.8, 0.8, 0.8)
	GameTooltip:AddLine(Captures:HolderText(point.id), C.gold[1], C.gold[2], C.gold[3], true)
	local p = Captures:Progress(point)
	if p.n > 0 then
		GameTooltip:AddLine(format("Being taken by the %s: %d of %d (provisional)", p.side, p.n, p.cost), C.amber[1], C.amber[2], C.amber[3])
	end
	GameTooltip:Show()
end

---What a Nexus crest says under it: "open" once one of its inhibitors is down, "fallen" once taken, else "closed".
function private.NexusState(point)
	if Captures:Holder(point.id) ~= point.home then
		return Theme:Colorize("fallen", C.red)
	elseif Captures:CanAttack(point.home == "Horde" and "Alliance" or "Horde", point) then
		return Theme:Colorize("open", C.gold)
	end
	return Theme:Colorize("closed", C.muted)
end

---A point frame (an icon or a crest) with a tooltip.
function private.PointFrame(parent, size)
	local frame = CreateFrame("Frame", nil, parent)
	frame:SetSize(size, size)
	frame:EnableMouse(true)
	frame.icon = frame:CreateTexture(nil, "ARTWORK")
	frame.icon:SetAllPoints()
	frame:SetScript("OnEnter", private.OnEnterPoint)
	frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return frame
end

---Lays shown buttons out from an anchor at the right, leftward.
function private.PlaceButtons(buttons, parent, point, x, y)
	local anchor
	for _, button in ipairs(buttons) do
		if button:IsShown() then
			button:ClearAllPoints()
			if anchor then
				button:SetPoint("RIGHT", anchor, "LEFT", -BUTTON_GAP, 0)
			else
				button:SetPoint(point, parent, point, x, y)
			end
			anchor = button
		end
	end
end



-- ============================================================================
-- Actions
-- ============================================================================

---Open the map: a front's zone map (the game can block an addon opening it in a fight).
function private.OpenMap(front)
	if not OpenWorldMap then
		return
	end
	if InCombatLockdown() then
		UI:Toast("The map can't be opened in a fight.", C.red)
		return
	end
	OpenWorldMap(front.mapId)
end

---Go there: a waypoint on the nearest point of a front our side can attack (the first from the Horde base when the
---player is elsewhere), or on our own Nexus's road when there's nothing left to take.
function private.GoTo(front)
	local side = UnitFactionGroup("player")
	local _, x, y, mapId = Wanted.Recorder:GetPosition()
	if mapId ~= front.mapId then
		x, y = nil, nil
	end
	local point = Captures:Nearest(front, x, y, function(p) return Captures:CanAttack(side, p) end)
		or Captures:Get(front[side == "Alliance" and "alliance" or "horde"].id)
	if Captures:Track(point) then
		UI:Toast(format("Waypoint set on the %s at %s.", Captures:Role(point), point.name), C.green)
	else
		UI:Toast("The waypoint couldn't be set.", C.red)
	end
end

---Lead the rally: claims the rally where the player stands (Rally says why not).
function private.LeadRally()
	local Rally = Wanted.Rally
	if not Rally then
		return
	end
	local why = Rally:Claim()
	UI:Toast(why or "You lead the rally here: your side sees you on the map and in Nearby.", why and C.red or C.green)
	private.Refresh()
end

---Set waypoint: the game's map waypoint where the rally leader stands.
function private.TrackRally()
	local s = Captures:Siege()
	local leader = s and private.rallyLeader
	if not leader then
		return
	end
	if Captures:Track({ front = s.front, x = leader.x, y = leader.y, id = "rally" }) then
		UI:Toast(format("Waypoint set on %s.", Theme:Plain(leader.name)), C.green)
	else
		UI:Toast("The waypoint couldn't be set.", C.red)
	end
end



-- ============================================================================
-- Building
-- ============================================================================

---Tonight's siege: the label and the front; the pill and the countdown or the score; the lane block at the left, the
---lines in the middle (what to do, or the rally leader and the layer note), the next siege at the right, and the
---buttons along the bottom. Without a siege, one text where the lanes go.
function private.BuildTonight(body, width)
	local card = W:Card(body)
	card:SetWidth(width)
	card.label = W:SectionLabel(card, "")
	card.label:SetPoint("TOPLEFT", PAD, -14)
	card.title = Theme:Text(card, "title", "")
	card.title:SetPoint("TOPLEFT", PAD, -30)
	card.title.fitWidth = 300
	card.pill = W:Pill(card)
	card.pill:SetPoint("LEFT", card.title, "RIGHT", 10, 0)
	card.next = Theme:Text(card, "small", "", C.muted)
	card.next:SetPoint("TOPRIGHT", -PAD, -14)
	card.next:SetJustifyH("RIGHT")
	card.next.fitWidth = 260
	card.text = Theme:Text(card, "body", "", C.muted)
	card.text:SetPoint("TOPLEFT", PAD, -62)
	card.text:SetWidth(width - 2 * PAD)
	card.text:SetWordWrap(true)
	card.text:SetSpacing(3)
	-- The lanes
	local top = -62
	card.crests = {}
	for i, side in ipairs({ "Horde", "Alliance" }) do
		local crest = private.PointFrame(card, CREST)
		crest:SetPoint("TOPLEFT", i == 1 and PAD or PAD + LANES_WIDTH - CREST, top)
		crest.state = Theme:Text(crest, "small", "")
		crest.state:SetPoint("TOP", crest, "BOTTOM", 0, -2)
		crest.state:SetJustifyH("CENTER")
		card.crests[side] = crest
	end
	card.lanes = {}
	local labelX, iconsX = PAD + CREST + 8, PAD + CREST + 8 + 30
	for row = 1, 3 do
		local lane = { icons = {} }
		lane.label = Theme:Text(card, "small", "")
		lane.label:SetPoint("TOPLEFT", labelX, top - 4 - (row - 1) * LANE_PITCH)
		for i = 1, 4 do
			local icon = private.PointFrame(card, LANE_ICON)
			icon:SetPoint("TOPLEFT", iconsX + (i - 1) * LANE_PITCH, top - (row - 1) * LANE_PITCH)
			lane.icons[i] = icon
		end
		card.lanes[row] = lane
	end
	-- The middle
	local middleX = PAD + LANES_WIDTH + 20
	card.status = Theme:Text(card, "heading", "")
	card.status:SetPoint("TOPLEFT", middleX, top)
	card.line = Theme:Text(card, "small", "", C.text)
	card.line:SetPoint("TOPLEFT", middleX, top - 22)
	card.line:SetWidth(width - PAD - middleX)
	card.line:SetWordWrap(true)
	card.waypoint = W:Button(card, "Set waypoint", "chip", 90, 20, function() private.TrackRally() end)
	card.waypoint:SetPoint("TOPLEFT", middleX, top - 44)
	W:AttachTooltip(card.waypoint, "Set waypoint", "Puts the game's map waypoint where the rally leader stands.")
	-- The siege's layer and whether we're on it (Shard), with Hop; Stay while a hop's group is held
	card.layer = Theme:Text(card, "small", "", C.amber)
	card.layer:SetPoint("TOPLEFT", middleX, top - 70)
	card.hop = W:Button(card, "Hop", "chip", 44, 16, function()
		local why = Wanted.Shard:Holding() and Wanted.Shard:Stay() or Wanted.Shard:Hop()
		if why then
			Wanted:Print("%s", why)
		end
	end)
	card.hop.label:SetFontObject(Wanted.Theme.Fonts.small)
	card.hop:SetPoint("LEFT", card.layer, "RIGHT", 8, 0)
	W:AttachTooltip(card.hop, "Hop to the siege's layer", "Asks a Wanted player of your side on the siege's layer for a group invite: your addon accepts it, holds the group so the move sticks, then leaves it, unless you click Stay or the host leads the rally. One hop every ten minutes; not in a fight, while dead, or in a group.")
	-- The buttons, on a row of their own under the lanes
	card.buttonsTop = -top + 3 * LANE_PITCH + 10
	card.map = W:Button(card, "Open the map", "secondary", 96, 24, function() private.OpenMap(Captures:Siege().front) end)
	W:AttachTooltip(card.map, "Open the map", "The front's zone map: its lanes, who holds each point, and a waypoint on any of them.")
	card.front = W:Button(card, "Go to the front", "primary", 110, 24, function() private.GoTo(Captures:Siege().front) end)
	W:AttachTooltip(card.front, "Go to the front", "A waypoint on the nearest point of the front your side can attack.")
	card.rally = W:Button(card, "Lead the rally", "secondary", 100, 24, function() private.LeadRally() end)
	W:AttachTooltip(card.rally, "Lead the rally", "As your group's leader, mark yourself the rally leader here: your side sees you on the map and in Nearby.")
	private.tonight = card
	return card
end

---A day as the client's clock shows it, "Fri 17 Oct".
function private.DayText(t)
	local ok, text = pcall(date, "%a %d %b", t)
	if not ok or type(text) ~= "string" then
		return "?"
	end
	return (text:gsub(" 0", " "))
end

---The upcoming evenings: one row per evening for the next week, its day, its window and its front where the catch-up
---named it, with the map for those; tonight's marked.
function private.BuildUpcoming(body, width)
	local card = W:Card(body)
	card:SetWidth(width)
	card.label = W:SectionLabel(card, "Upcoming")
	card.label:SetPoint("TOPLEFT", PAD, -14)
	card.rows = {}
	for i = 1, EVENINGS do
		local row = {}
		local y = -34 - (i - 1) * EVENING_ROW
		row.day = Theme:Text(card, "small", "", C.text)
		row.day:SetPoint("TOPLEFT", PAD, y)
		row.window = Theme:Text(card, "small", "", C.text)
		row.window:SetPoint("TOPLEFT", PAD + 90, y)
		row.front = Theme:Text(card, "small", "")
		row.front:SetPoint("TOPLEFT", PAD + 230, y)
		row.mark = W:Pill(card)
		row.mark:SetPoint("LEFT", row.front, "RIGHT", 10, 0)
		row.map = W:Button(card, "Open the map", "secondary", 96, 20, function() private.OpenMap(row.evening.front) end)
		row.map:SetPoint("TOPRIGHT", -PAD, y + 3)
		W:AttachTooltip(row.map, "Open the map", "The front's zone map: its lanes, who holds each point, and a waypoint on any of them.")
		card.rows[i] = row
	end
	card:SetHeight(34 + EVENINGS * EVENING_ROW + PAD - 4)
	private.upcoming = card
	return card
end

---The results: tonight's score and the rounds this client saw end, this week's siege wins per front, and the site's
---schedule and results.
function private.BuildResults(body, width)
	local card = W:Card(body)
	card:SetWidth(width)
	card.label = W:SectionLabel(card, "Results")
	card.label:SetPoint("TOPLEFT", PAD, -14)
	card.tonight = Theme:Text(card, "body", "")
	card.tonight:SetPoint("TOPLEFT", PAD, -32)
	card.rounds = {}
	card.weekLabel = W:SectionLabel(card, "This week")
	card.wins = {}
	for i = 1, 3 do
		local row = {}
		row.zone = Theme:Text(card, "small", "", C.text)
		row.zone.fitWidth = 150
		row.score = Theme:Text(card, "small", "")
		row.score:SetPoint("LEFT", row.zone, "LEFT", 156, 0)
		row.mark = Theme:Text(card, "small", "", C.gold)
		row.mark:SetPoint("LEFT", row.zone, "LEFT", 310, 0)
		card.wins[i] = row
	end
	card.linkLabel, card.link = private.AddLink(card, "Schedule and results", SITE.."/sieges", width)
	private.results = card
	return card
end

---The fronts: each with its zone, the week's wins, tonight's or the next siege's marker, its lanes' holders, and
---buttons for its map and a waypoint; and the fronts on the website.
function private.BuildFronts(body, width)
	local card = W:Card(body)
	card:SetWidth(width)
	card.label = W:SectionLabel(card, "The fronts")
	card.label:SetPoint("TOPLEFT", PAD, -14)
	card.rows = {}
	for i, front in ipairs(Captures.FRONTS) do
		local row = {}
		local y = -34 - (i - 1) * FRONT_ROW
		row.zone = Theme:Text(card, "heading", front.zone)
		row.zone:SetPoint("TOPLEFT", PAD, y)
		row.wins = Theme:Text(card, "small", "")
		row.wins:SetPoint("LEFT", row.zone, "RIGHT", 12, 0)
		row.mark = W:Pill(card)
		row.mark:SetPoint("LEFT", row.wins, "RIGHT", 10, 0)
		row.lanes = Theme:Text(card, "small", "", C.muted)
		row.lanes:SetPoint("TOPLEFT", PAD, y - 20)
		row.lanes.fitWidth = width - 2 * PAD - 96 - 80 - BUTTON_GAP - 12
		row.go = W:Button(card, "Go there", "secondary", 80, 22, function() private.GoTo(front) end)
		row.go:SetPoint("TOPRIGHT", -PAD, y + 2)
		W:AttachTooltip(row.go, "Go there", "A waypoint on the nearest point of "..front.zone.." your side can attack, or your Nexus's road when there's nothing left to take.")
		row.map = W:Button(card, "Open the map", "secondary", 96, 22, function() private.OpenMap(front) end)
		row.map:SetPoint("RIGHT", row.go, "LEFT", -BUTTON_GAP, 0)
		W:AttachTooltip(row.map, "Open the map", "The zone map: the lanes, who holds each point, and a waypoint on any of them.")
		card.rows[i] = row
	end
	card.linkLabel, card.link = private.AddLink(card, "The fronts on the website", SITE.."/war", width)
	local linkY = 34 + #Captures.FRONTS * FRONT_ROW + 4
	card.linkLabel:SetPoint("TOPLEFT", PAD, -linkY)
	card:SetHeight(linkY + 18 + 26 + PAD)
	private.fronts = card
	return card
end

---How it works: the rules, and where they are in full.
function private.BuildRules(body, width)
	local card = W:Card(body)
	card:SetWidth(width)
	card.label = W:SectionLabel(card, "How it works")
	card.label:SetPoint("TOPLEFT", PAD, -14)
	card.paragraphs = {}
	local previous
	for i, rule in ipairs(RULES) do
		local text = Theme:Text(card, "body", Theme:Colorize(rule[1], C.text).." "..Theme:Colorize(rule[2], C.muted))
		if previous then
			text:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -8)
		else
			text:SetPoint("TOPLEFT", PAD, -34)
		end
		text:SetWidth(width - 2 * PAD)
		text:SetWordWrap(true)
		text:SetSpacing(3)
		card.paragraphs[i] = text
		previous = text
	end
	card.linkLabel, card.link = private.AddLink(card, "The rules in full", SITE.."/rules#points", width)
	card.linkLabel:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -12)
	private.rules = card
	return card
end

---The page: everything in a scroll frame, the cards stacked (private.Stack).
function private.Build(container, width)
	local scroll = CreateFrame("ScrollFrame", nil, container, "UIPanelScrollFrameTemplate")
	scroll.scrollBarHideable = true
	scroll:SetPoint("TOPLEFT")
	scroll:SetPoint("BOTTOMRIGHT", -26, 0)
	local body = CreateFrame("Frame", nil, scroll)
	body:SetSize(width - 30, 1)
	scroll:SetScrollChild(body)
	private.body = body
	private.cards = {
		private.BuildTonight(body, width - 30),
		private.BuildUpcoming(body, width - 30),
		private.BuildResults(body, width - 30),
		private.BuildFronts(body, width - 30),
		private.BuildRules(body, width - 30),
	}
	Captures:OnChange(function()
		if UI:IsShown("siege") then
			private.Refresh()
		end
	end)
end



-- ============================================================================
-- Refreshing
-- ============================================================================

---The pill and the status line that carry a clock: before the window, the window and "Opens in 21:40" (hours and
---minutes; minutes and seconds under an hour); in a truce, its clock. Returns whether the clock needs the seconds, so
---a ticker keeps it moving.
function private.SiegeClock()
	local card = private.tonight
	local s = Captures:Siege()
	local phase = Captures:Phase()
	local now = GetServerTime()
	if not s then
		return false
	elseif phase == "before" then
		local left = s.start - now
		card.pill:Set(Wanted.CapturesHUD:WindowText(s), C.gold)
		card.status:SetText(Theme:Colorize("Opens in "..(left < 3600 and private.Clock(left) or format("%d:%02d", floor(left / 3600), floor(left % 3600 / 60))), C.gold))
		return left < 3600
	elseif phase == "truce" then
		card.pill:Set("Truce "..private.Clock(s.round.truceUntil - now), C.blue)
		return true
	end
	return false
end

---The rally on the siege front: the line ("Grimshaw leads at Darrow Hill", by the nearest point) and the leader when
---a waypoint can be set on them (not on ourselves). Nothing without the rally module.
---@return string? line
---@return table? leader
function private.RallyLine(front)
	local Rally = Wanted.Rally
	if not Rally then
		return nil, nil
	end
	local leader = Rally:Holder(front.mapId)
	if not leader then
		return Theme:Colorize("No rally leader on this front yet.", C.muted), nil
	end
	local point, yards = Captures:Nearest(front, leader.x, leader.y)
	local where = point and format(" %s %s", yards and yards <= point.r and "at" or "near", point.name) or ""
	if leader.mine then
		return Theme:Colorize("You lead the rally"..where, C.gold), nil
	end
	return Theme:ClassName(leader.name, leader.class)..Theme:Colorize(" leads"..where, C.text), leader
end

---Tonight's card, as private.BuildTonight lays it out. Returns its height.
function private.RefreshTonight()
	local card = private.tonight
	local CapturesMap = Wanted.CapturesMap
	local s = Captures:Siege()
	local phase = Captures:Phase()
	local front = s and s.front
	card.text:SetShown(s == nil)
	for _, crest in pairs(card.crests) do
		crest:SetShown(s ~= nil)
	end
	for _, lane in ipairs(card.lanes) do
		lane.label:SetShown(s ~= nil)
		for _, icon in ipairs(lane.icons) do
			icon:SetShown(s ~= nil)
		end
	end
	private.rallyLeader = nil
	if not s then
		card.label:SetText("SIEGE NIGHTS")
		card.title:SetText("No siege picked yet")
		card.pill:Hide()
		card.next:SetText("")
		card.status:SetText("")
		card.line:SetText("")
		card.text:SetText("wanteddeadordead.com picks each evening's front the day before, the most fought front of the week; the next one shows here once your app has synced.")
		card.waypoint:Hide()
		card.layer:Hide()
		card.hop:Hide()
		card.map:Hide()
		card.front:Hide()
		card.rally:Hide()
		card:SetHeight(62 + card.text:GetStringHeight() + PAD)
		return
	end
	card.label:SetText(private.Today(s) and "TONIGHT" or strupper("Next: "..date("%A", s.start)))
	private.Fit(card.title, { front.zone }, "heading")
	if s.next then
		private.Fit(card.next, { format("Then: %s, %s", s.next.front.zone, Wanted.CapturesHUD:WindowText(s.next)), "Then: "..s.next.front.zone }, "tiny")
	else
		card.next:SetText("")
	end
	for row, lane in ipairs(front.lanes) do
		local r = card.lanes[row]
		r.label:SetText(lane.name)
		for i, p in ipairs(lane.points) do
			local point = Captures:Get(p.id)
			r.icons[i].point = point
			CapturesMap:SetIcon(r.icons[i].icon, point)
		end
	end
	for side, crest in pairs(card.crests) do
		local point = Captures:Get(front[strlower(side)].id)
		crest.point = point
		CapturesMap:SetIcon(crest.icon, point)
		crest.state:SetText(private.NexusState(point))
	end
	local leader
	if phase == "before" then
		card.line:SetText(format("Break a lane before %s: towers and inhibitors are open all day, and on the siege front they stay down from %s.",
			Wanted.CapturesHUD:HourText(s.start), Wanted.CapturesHUD:HourText(s.start - 3600)))
	else
		if phase == "round" then
			card.pill:Set(format("Round %d", s.round and s.round.n or 1), C.red)
		elseif phase == "over" then
			card.pill:Set("Over", C.muted)
		end
		card.status:SetText(private.Score(s.wins.Horde, s.wins.Alliance))
		local line
		line, leader = private.RallyLine(front)
		card.line:SetText(line or "")
	end
	private.rallyLeader = leader
	card.waypoint:SetShown(leader ~= nil)
	-- The siege's layer, once the site has picked it
	local layerText, button
	if phase ~= "over" then
		if Captures:SiegeLayer() then
			layerText, button = Wanted.Shard:Line(front.zone, front.mapId)
		else
			layerText = Theme:Colorize("The siege's layer isn't picked yet.", C.muted)
		end
	end
	card.layer:SetText(layerText or "")
	card.layer:SetShown(layerText ~= nil)
	card.hop:SetText(button or "Hop")
	card.hop:SetShown(button ~= nil)
	card.map:SetShown(OpenWorldMap ~= nil)
	card.front:SetShown(phase ~= "over")
	card.rally:SetShown(Wanted.Rally ~= nil and phase ~= "over" and private.OnFront(front) and private.GroupLeader() and Wanted.Rally:Holder(front.mapId) == nil)
	private.PlaceButtons({ card.rally, card.front, card.map }, card, "TOPRIGHT", -PAD, -card.buttonsTop)
	card:SetHeight(card.buttonsTop + 24 + 12)
	if private.SiegeClock() and not private.ticker then
		private.ticker = C_Timer.NewTicker(1, Wanted:Timed("Siege page clock", function()
			if not UI:IsShown("siege") or not private.SiegeClock() then
				private.ticker:Cancel()
				private.ticker = nil
			end
		end))
	end
end

---The upcoming card's rows: the next week's evenings (Captures:Evenings).
function private.RefreshUpcoming()
	local card = private.upcoming
	for i, evening in ipairs(Captures:Evenings(EVENINGS)) do
		local row = card.rows[i]
		row.evening = evening
		row.day:SetText(private.DayText(evening.day))
		row.window:SetText(evening.start and Wanted.CapturesHUD:WindowText(evening, true) or WINDOW_EASTERN)
		row.front:SetText(evening.front and evening.front.zone or Theme:Colorize("front picked the evening before", C.muted))
		if evening.today then
			row.mark:Set("TONIGHT", C.gold)
		else
			row.mark:Hide()
		end
		row.map:SetShown(evening.front ~= nil and OpenWorldMap ~= nil)
	end
end

---The week's siege wins per front, from the catch-up, on three rows: "Horde 3 · Alliance 1" or "no wins yet", the
---siege front marked tonight (or its weekday).
function private.RefreshWeek(s)
	local card = private.results
	for i, front in ipairs(Captures.FRONTS) do
		local row = card.wins[i]
		local wins = Captures:FrontWins(front)
		private.Fit(row.zone, { front.zone }, "tiny")
		row.score:SetText(wins and private.Score(wins.Horde, wins.Alliance) or Theme:Colorize("no wins yet", C.faint))
		row.mark:SetText(s and s.front == front and (private.Today(s) and "tonight" or date("%a", s.start)) or "")
	end
end

---The results card: tonight's score and rounds, the week's wins, the link. Laid out top to bottom as the rounds come.
function private.RefreshResults()
	local card = private.results
	local s = Captures:Siege()
	local phase = Captures:Phase()
	local rounds = Captures:Rounds()
	if not s then
		card.tonight:SetText(Theme:Colorize("No siege tonight yet.", C.muted))
	elseif phase == "before" then
		card.tonight:SetText(Theme:Colorize(format("%s: not started.", private.Today(s) and "Tonight" or date("%A", s.start)), C.muted))
	else
		card.tonight:SetText(format("%s: %s%s", private.Today(s) and "Tonight" or date("%A", s.start), private.Score(s.wins.Horde, s.wins.Alliance),
			phase == "over" and Theme:Colorize("  (over)", C.muted) or ""))
	end
	local y = 32 + LINE + 4
	for i, round in ipairs(rounds) do
		local line = card.rounds[i]
		if not line then
			line = Theme:Text(card, "small", "", C.text)
			line:SetPoint("TOPLEFT", PAD, 0)
			card.rounds[i] = line
		end
		line:SetText(format("Round %d to the %s: the %s %s fell at %s", round.n, round.side, round.point.name, Captures.TERMS.nexus, private.TimeText(round.at)))
		line:ClearAllPoints()
		line:SetPoint("TOPLEFT", PAD, -y)
		line:Show()
		y = y + LINE
	end
	for i = #rounds + 1, #card.rounds do
		card.rounds[i]:Hide()
	end
	if s and s.wins.Horde + s.wins.Alliance > #rounds then
		local note = private.roundsNote or Theme:Text(card, "small", "Rounds before you logged in aren't listed: the website has them all.", C.faint)
		private.roundsNote = note
		note:ClearAllPoints()
		note:SetPoint("TOPLEFT", PAD, -y)
		note:Show()
		y = y + LINE
	elseif private.roundsNote then
		private.roundsNote:Hide()
	end
	y = y + 8
	card.weekLabel:ClearAllPoints()
	card.weekLabel:SetPoint("TOPLEFT", PAD, -y)
	y = y + 18
	for _, row in ipairs(card.wins) do
		row.zone:ClearAllPoints()
		row.zone:SetPoint("TOPLEFT", PAD, -y)
		y = y + LINE
	end
	private.RefreshWeek(s)
	y = y + 8
	card.linkLabel:ClearAllPoints()
	card.linkLabel:SetPoint("TOPLEFT", PAD, -y)
	card:SetHeight(y + 18 + 26 + PAD)
end

---A front's lanes in one line: "Top: Horde 2 · Alliance 2  Mid: ...", from who holds each point.
function private.LaneSummary(front)
	local parts = {}
	for _, lane in ipairs(front.lanes) do
		local horde, alliance = 0, 0
		for _, p in ipairs(lane.points) do
			if Captures:Holder(p.id) == "Horde" then
				horde = horde + 1
			else
				alliance = alliance + 1
			end
		end
		tinsert(parts, format("%s: %s", lane.name, private.Score(horde, alliance)))
	end
	return table.concat(parts, "   ")
end

---The fronts card's rows: the week's wins, the marker, the lanes' holders.
function private.RefreshFronts()
	local card = private.fronts
	local s = Captures:Siege()
	for i, front in ipairs(Captures.FRONTS) do
		local row = card.rows[i]
		local wins = Captures:FrontWins(front)
		local winner = Captures:Winner(front)
		row.wins:SetText(winner and Theme:Colorize(format("won by the %s this week", winner), Wanted.CapturesMap.COLORS[winner])
			or wins and private.Score(wins.Horde, wins.Alliance)..Theme:Colorize(" this week", C.muted) or Theme:Colorize("no siege wins this week yet", C.faint))
		if s and s.front == front then
			row.mark:Set(private.Today(s) and "TONIGHT" or strupper(date("%a", s.start)), C.gold)
		else
			row.mark:Hide()
		end
		private.Fit(row.lanes, { private.LaneSummary(front) }, "tiny")
		row.map:SetShown(OpenWorldMap ~= nil)
	end
end

---The rules card's height follows its text.
function private.RefreshRules()
	local card = private.rules
	local height = 34
	for _, text in ipairs(card.paragraphs) do
		height = height + text:GetStringHeight() + 8
	end
	card:SetHeight(height + 4 + 18 + 26 + PAD)
end

---Stacks the cards top to bottom and sizes the scroll child to them.
function private.Stack()
	local y = 0
	for _, card in ipairs(private.cards) do
		card:ClearAllPoints()
		card:SetPoint("TOPLEFT", 0, -y)
		y = y + card:GetHeight() + GAP
	end
	private.body:SetHeight(max(y - GAP, 1))
end

---Fits a line to the width it was given at build (fitWidth): the first text that fits, then smaller.
function private.Fit(fs, texts, smaller)
	Theme:FitText(fs, fs.fitWidth, texts, smaller)
end

function private.Refresh()
	if not private.tonight then
		return
	end
	private.RefreshTonight()
	private.RefreshUpcoming()
	private.RefreshResults()
	private.RefreshFronts()
	private.RefreshRules()
	private.Stack()
end

---The header's second line: the front and its window, or that none is picked.
function private.Subtitle()
	local s = Captures:Siege()
	if not s then
		return "No siege picked yet"
	end
	return format("%s, %s", s.front.zone, Wanted.CapturesHUD:WindowText(s))
end

UI:RegisterPage("siege", {
	title = "Siege",
	hidden = function() return not Wanted:SiegeOn() end,
	subtitle = private.Subtitle,
	order = -1,
	build = private.Build,
	refresh = private.Refresh,
})
