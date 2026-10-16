-- Wanted: Home, the page the window opens on: what's happening now. First the siege (Captures): tonight's front, its
-- window and a countdown, or the round, the score and the three lanes while it's on, with this week's siege wins per
-- front and buttons for the map, the rally and a waypoint to the front. Then your challenge rank and daily streak,
-- today's challenge and hot zones, world PvP raids (yours, the one you signed up for, the ones forming: click to join),
-- and a strip of what's going on: your bounty money, enemies nearby, the busiest zone and the latest kill or sighting.
-- Every card opens its page; this week's challenges are on Progress. Challenges come from the Wanted app
-- (Challenges.lua); without it the top shows what the app adds, and the raids and the strip still work.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Challenges = Wanted.Challenges
local Captures = Wanted.Captures
local private = {}
local GAP = 12
local SIEGE_HEIGHT = 96
local BAND_TOP = -(SIEGE_HEIGHT + GAP)
local BAND_HEIGHT = 64
local CARD_TOP = BAND_TOP - BAND_HEIGHT - GAP
local CARD_HEIGHT = 116
local RAIDS_TOP = CARD_TOP - CARD_HEIGHT - GAP
local RAIDS_HEIGHT = 112
local STRIP_TOP = RAIDS_TOP - 18 - RAIDS_HEIGHT - GAP
local STRIP_HEIGHT = 68
local DAILY_WIDTH = 262
local STREAK_BOXES = 7
local BigFont = Theme:MakeFont("WantedFontHomeBig", 30, C.faint)
local TRENDS = { up = "rising", down = "falling", steady = "steady" }
-- Room the big "2x" takes at the right of a hot zone card, which the lines beside it stop short of
local BIG_ROOM = 56
-- The siege card's lane block (a Nexus crest at each end, three lanes of four icons between) at the left, the lines in
-- the middle, this week's wins per front at the right
local LANE_ICON, LANE_PITCH, CREST = 16, 18, 24
local LANES_WIDTH = 154
local WINS_WIDTH = 292
local WINS_PITCH = 14
local BUTTON_GAP = 6

---"6h 40m", "40m" or "2d 5h".
function private.Duration(seconds)
	seconds = max(floor(seconds or 0), 0)
	if seconds >= 86400 then
		return format("%dd %dh", floor(seconds / 86400), floor(seconds % 86400 / 3600))
	elseif seconds >= 3600 then
		return format("%dh %dm", floor(seconds / 3600), floor(seconds % 3600 / 60))
	end
	return format("%dm", max(floor(seconds / 60), 1))
end

---Progress text and bar for a challenge: "2 of 4" in gold, or "Done" in green.
function private.SetProgress(bar, label, challenge, progress)
	if not progress then
		bar:Hide()
		label:SetText("")
		return
	end
	bar:Show()
	if progress.done then
		bar:SetValue(1, C.green)
		label:SetText(Theme:Colorize("Done", C.green))
	else
		bar:SetValue(progress.n / challenge.target, C.gold)
		label:SetText(Theme:Colorize(min(progress.n, challenge.target), C.gold)..Theme:Colorize(" of "..challenge.target, C.muted))
	end
end

---Fits a card line to the width it was given at build (fitWidth): the first text that fits, then smaller.
function private.Fit(fs, texts, smaller, wrap)
	Theme:FitText(fs, fs.fitWidth, texts, smaller, wrap)
end

---Enemy counts by zone, lower-case zone name -> the Hotspots group.
function private.HotspotsByZone(groups)
	local byZone = {}
	for _, group in ipairs(groups) do
		byZone[strlower(group.zone)] = group
	end
	return byZone
end



-- ============================================================================
-- Building
-- ============================================================================

---The siege card at the top: the pill and title with the buttons at their right; under them the lane block (each
---Nexus as its crest with "open" or "closed" under it, the three lanes between as the HUD's lane row), the lines in
---the middle (the countdown and what to do, or the score and the rally leader) and this week's siege wins per front
---at the right. Without a siege, one text where the lanes and the lines go.
function private.BuildSiege(container, width)
	local card = W:Card(container)
	card:SetPoint("TOPLEFT")
	card:SetSize(width, SIEGE_HEIGHT)
	card.pill = W:Pill(card)
	card.pill:SetPoint("TOPLEFT", 16, -11)
	card.title = Theme:Text(card, "heading", "")
	card.title.fitWidth = 220
	card.text = Theme:Text(card, "small", "", C.muted)
	card.text:SetPoint("TOPLEFT", 16, -40)
	card.text:SetWidth(width - 32 - WINS_WIDTH - 16)
	card.text:SetWordWrap(true)
	card.crests = {}
	for i, side in ipairs({ "Horde", "Alliance" }) do
		local crest = CreateFrame("Frame", nil, card)
		crest:SetSize(CREST, LANE_PITCH * 3)
		crest:SetPoint("TOPLEFT", i == 1 and 16 or 16 + LANES_WIDTH - CREST, -38)
		crest:EnableMouse(true)
		crest.icon = crest:CreateTexture(nil, "ARTWORK")
		crest.icon:SetSize(CREST, CREST)
		crest.icon:SetPoint("TOP")
		crest.state = Theme:Text(crest, "tiny", "")
		crest.state:SetPoint("TOP", crest.icon, "BOTTOM", 0, -1)
		crest.state:SetJustifyH("CENTER")
		crest:SetScript("OnEnter", private.OnEnterPoint)
		crest:SetScript("OnLeave", function() GameTooltip:Hide() end)
		card.crests[side] = crest
	end
	card.lanes = {}
	local iconsX = 16 + CREST + 6 + 24
	for row = 1, 3 do
		local lane = { icons = {} }
		lane.label = Theme:Text(card, "tiny", "")
		lane.label:SetPoint("TOPLEFT", 16 + CREST + 6, -40 - (row - 1) * LANE_PITCH)
		for i = 1, 4 do
			local icon = CreateFrame("Frame", nil, card)
			icon:SetSize(LANE_ICON, LANE_ICON)
			icon:SetPoint("TOPLEFT", iconsX + (i - 1) * LANE_PITCH, -38 - (row - 1) * LANE_PITCH)
			icon:EnableMouse(true)
			icon.icon = icon:CreateTexture(nil, "ARTWORK")
			icon.icon:SetAllPoints()
			icon:SetScript("OnEnter", private.OnEnterPoint)
			icon:SetScript("OnLeave", function() GameTooltip:Hide() end)
			lane.icons[i] = icon
		end
		card.lanes[row] = lane
	end
	local middleX = 16 + LANES_WIDTH + 16
	local winsX = width - 16 - WINS_WIDTH
	-- The middle: the countdown or the score, then what to do or the rally leader
	card.status = Theme:Text(card, "small", "")
	card.status:SetPoint("TOPLEFT", middleX, -40)
	card.line = Theme:Text(card, "small", "", C.text)
	card.line:SetPoint("TOPLEFT", middleX, -54)
	card.line:SetWidth(winsX - 16 - middleX)
	card.line:SetWordWrap(true)
	card.waypoint = W:Button(card, "Set waypoint", "chip", 90, 20, function() private.TrackRally() end)
	card.waypoint:SetPoint("TOPLEFT", middleX, -72)
	W:AttachTooltip(card.waypoint, "Set waypoint", "Puts the game's map waypoint where the rally leader stands.")
	card.winsLabel = W:SectionLabel(card, "Siege wins this week")
	card.winsLabel:SetPoint("TOPLEFT", winsX, -40)
	card.wins = {}
	for i = 1, 3 do
		local row = {}
		local y = -40 - i * WINS_PITCH
		row.zone = Theme:Text(card, "tiny", "", C.text)
		row.zone:SetPoint("TOPLEFT", winsX, y)
		row.zone.fitWidth = 114
		row.score = Theme:Text(card, "tiny", "")
		row.score:SetPoint("TOPLEFT", winsX + 118, y)
		row.score.fitWidth = 130
		row.mark = Theme:Text(card, "tiny", "", C.gold)
		row.mark:SetPoint("TOPLEFT", winsX + 250, y)
		card.wins[i] = row
	end
	card.map = W:Button(card, "Open the map", "secondary", 96, 24, function() private.OpenFrontMap() end)
	W:AttachTooltip(card.map, "Open the map", "The front's zone map: its lanes, who holds each point, and a waypoint on any of them.")
	card.front = W:Button(card, "Go to the front", "primary", 110, 24, function() private.GoToFront() end)
	W:AttachTooltip(card.front, "Go to the front", "A waypoint on the nearest point of the front your side can attack.")
	card.rally = W:Button(card, "Lead the rally", "secondary", 100, 24, function() private.LeadRally() end)
	W:AttachTooltip(card.rally, "Lead the rally", "As your group's leader, mark yourself the rally leader here: your side sees you on the map and in Nearby.")
	private.siege = card
	Captures:OnChange(function()
		if UI:IsShown("home") then
			private.RefreshSiege()
		end
	end)
end

function private.BuildBand(container, width)
	local band = W:CardButton(container, function() UI:Show("rank") end)
	band:SetPoint("TOPLEFT", 0, BAND_TOP)
	band:SetSize(width, BAND_HEIGHT)
	W:AttachTooltip(band, "Your PvP rank", "Blizzard's PvP rank as the game tells it, and your challenge streak. Opens Rank & Gear.")
	band.badge = band:CreateTexture(nil, "ARTWORK")
	band.badge:SetSize(40, 40)
	band.badge:SetPoint("LEFT", 16, 0)
	band.label = W:SectionLabel(band, "")
	band.label:SetPoint("TOPLEFT", 68, -15)
	band.title = Theme:Text(band, "heading", "", C.gold)
	band.title:SetPoint("TOPLEFT", 68, -33)
	band.title:SetWidth(176)
	band.title.fitWidth = 176
	band.points = Theme:Text(band, "small", "", C.text)
	band.points:SetPoint("TOPLEFT", 250, -17)
	band.toNext = Theme:Text(band, "small", "")
	band.toNext:SetPoint("TOPRIGHT", band, "TOPLEFT", 500, -17)
	band.toNext:SetJustifyH("RIGHT")
	band.toNext:SetWidth(176)
	band.toNext.fitWidth = 176
	band.bar = W:ProgressBar(band, 8)
	band.bar:SetPoint("TOPLEFT", 250, -36)
	band.bar:SetWidth(250)
	band.nextBadge = band:CreateTexture(nil, "ARTWORK")
	band.nextBadge:SetSize(24, 24)
	band.nextBadge:SetPoint("LEFT", 510, 0)
	band.nextBadge:SetAlpha(0.45)
	local divider = band:CreateTexture(nil, "BORDER")
	divider:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)
	divider:SetSize(1, BAND_HEIGHT - 20)
	divider:SetPoint("LEFT", 548, 0)
	band.streakLabel = W:SectionLabel(band, "Daily streak")
	band.streakLabel:SetPoint("TOPLEFT", 562, -10)
	band.streak = Theme:Text(band, "heading", "", C.gold)
	band.streak:SetPoint("TOPLEFT", 562, -26)
	band.boxes = {}
	for i = 1, STREAK_BOXES do
		local box = CreateFrame("Frame", nil, band)
		box:SetSize(9, 9)
		box:SetPoint("TOPLEFT", 562 + (i - 1) * 13, -46)
		Theme:Skin(box, C.input, C.border)
		band.boxes[i] = box
	end
	-- Before a season, or without a rank yet: one line in place of the points and bar
	band.note = Theme:Text(band, "small", "", C.muted)
	band.note:SetPoint("TOPLEFT", 250, -26)
	band.note:SetWidth(280)
	band.note:SetWordWrap(true)
	private.band = band
end

function private.BuildDaily(container)
	local card = W:CardButton(container, function() UI:Show("challenges") end)
	card:SetPoint("TOPLEFT", 0, CARD_TOP)
	card:SetSize(DAILY_WIDTH, CARD_HEIGHT)
	card.label = W:SectionLabel(card, "Daily challenge")
	card.label:SetPoint("TOPLEFT", 16, -14)
	card.resets = Theme:Text(card, "tiny", "")
	card.resets:SetPoint("TOPRIGHT", -24, -14)
	card.resets:SetJustifyH("RIGHT")
	card.name = Theme:Text(card, "title", "")
	card.name:SetPoint("TOPLEFT", 16, -36)
	-- Room left for the points pill beside it
	card.name:SetWidth(DAILY_WIDTH - 100)
	card.name.fitWidth = DAILY_WIDTH - 100
	card.points = W:Pill(card)
	card.points:SetPoint("LEFT", card.name, "RIGHT", 10, 0)
	card.text = Theme:Text(card, "small", "")
	card.text:SetPoint("TOPLEFT", 16, -60)
	card.text:SetWidth(DAILY_WIDTH - 32)
	card.text.fitWidth = DAILY_WIDTH - 32
	card.bar = W:ProgressBar(card, 8)
	card.bar:SetPoint("TOPLEFT", 16, -88)
	card.bar:SetWidth(DAILY_WIDTH - 90)
	card.progress = Theme:Text(card, "small", "")
	card.progress:SetPoint("RIGHT", card, "TOPRIGHT", -16, -92)
	card.progress:SetJustifyH("RIGHT")
	card.note = Theme:Text(card, "tiny", "")
	card.note:SetPoint("TOPLEFT", 16, -104)
	card.note:SetWidth(DAILY_WIDTH - 32)
	private.daily = card
end

function private.BuildHot(container, width, index)
	local cardWidth = floor((width - DAILY_WIDTH - 2 * GAP) / 2)
	local card = W:CardButton(container, function() UI:Show("hotspots") end)
	card:SetPoint("TOPLEFT", DAILY_WIDTH + GAP + (index - 1) * (cardWidth + GAP), CARD_TOP)
	card:SetSize(cardWidth, CARD_HEIGHT)
	W:AttachTooltip(card, "Hotspots", "Where enemy players are right now.")
	card.edge = card:CreateTexture(nil, "ARTWORK")
	card.edge:SetPoint("TOPLEFT", 1, -1)
	card.edge:SetPoint("BOTTOMLEFT", 1, 1)
	card.edge:SetWidth(3)
	card.edge:SetColorTexture(C.red[1], C.red[2], C.red[3], 1)
	card.tag = W:Pill(card)
	card.tag:SetPoint("TOPLEFT", 16, -12)
	card.band = Theme:Text(card, "small", "")
	card.band:SetPoint("LEFT", card.tag, "RIGHT", 10, 0)
	card.zone = Theme:Text(card, "title", "")
	card.zone:SetPoint("TOPLEFT", 16, -44)
	card.zone:SetWidth(cardWidth - 32)
	card.zone.fitWidth = cardWidth - 32
	card.double = Theme:Text(card, "small", "Kills here count double", C.amber)
	card.double:SetPoint("TOPLEFT", 16, -72)
	card.double:SetWidth(cardWidth - 32 - BIG_ROOM)
	card.enemies = Theme:Text(card, "small", "")
	card.enemies:SetPoint("TOPLEFT", 16, -92)
	card.enemies:SetWidth(cardWidth - 32 - BIG_ROOM)
	card.enemies.fitWidth = cardWidth - 32 - BIG_ROOM
	card.big = card:CreateFontString(nil, "ARTWORK")
	card.big:SetFontObject(BigFont)
	card.big:SetText("2x")
	card.big:SetPoint("BOTTOMRIGHT", -12, 8)
	private.hot[index] = card
end

---The raids row: up to three cards (the raid you lead or joined first, then the ones forming).
function private.BuildRaids(container, width)
	local label = W:SectionLabel(container, "Raids")
	label:SetPoint("TOPLEFT", 0, RAIDS_TOP)
	local note = Theme:Text(container, "tiny", "Form or join one on the Raids page", C.faint)
	note:SetPoint("TOPRIGHT", 0, RAIDS_TOP)
	note:SetJustifyH("RIGHT")
	local cardWidth = floor((width - 2 * GAP) / 3)
	private.raids = {}
	for i = 1, 3 do
		local card = W:CardButton(container, function(self) private.OnRaid(self.item) end)
		card:SetPoint("TOPLEFT", (i - 1) * (cardWidth + GAP), RAIDS_TOP - 18)
		card:SetSize(cardWidth, RAIDS_HEIGHT)
		card.kind = W:Pill(card)
		card.kind:SetPoint("TOPLEFT", 16, -12)
		card.name = Theme:Text(card, "heading", "")
		card.name:SetPoint("TOPLEFT", 16, -42)
		card.name:SetWidth(cardWidth - 32)
		card.name.fitWidth = cardWidth - 32
		card.text = Theme:Text(card, "small", "")
		card.text:SetPoint("TOPLEFT", 16, -60)
		card.text:SetWidth(cardWidth - 32)
		card.text.fitWidth = cardWidth - 32
		card.action = Theme:Text(card, "small", "")
		card.action:SetPoint("BOTTOMLEFT", 16, 14)
		private.raids[i] = card
	end
end

---A raid card clicked: one you lead or joined (or none) opens the Raids page; any other is joined.
function private.OnRaid(item)
	if not item or item.mine or Wanted.Raids:Joined(item.raid.id) then
		UI:Show("raids")
		return
	end
	local why = Wanted.Raids:Join(item.raid.id)
	UI:Toast(why or (item.raid.startAt <= GetServerTime() and "Asked to join: the leader invites you." or "Going: you'll be asked to join when it starts."),
		why and C.red or C.green)
end

function private.RefreshRaids()
	local Raids = Wanted.Raids
	local now = GetServerTime()
	local items = {}
	local mine = Raids:Mine()
	if mine then
		tinsert(items, { raid = mine, mine = true })
	end
	local list = Raids:List()
	-- The raids we joined first, then the rest
	sort(list, function(a, b)
		local aj, bj = Raids:Joined(a.id), Raids:Joined(b.id)
		if aj ~= bj then
			return aj
		end
		return false
	end)
	for _, raid in ipairs(list) do
		if #items < #private.raids then
			tinsert(items, { raid = raid })
		end
	end
	for i, card in ipairs(private.raids) do
		local item = items[i]
		card.item = item
		if item then
			local raid, started = item.raid, item.raid.startAt <= now
			local joined = not item.mine and Raids:Joined(raid.id)
			card.kind:Set(item.mine and "YOUR RAID" or joined and (started and "JOINED" or strupper(Raids:Interest(raid.id) or "going")) or started and "FORMING" or "PLANNED",
				item.mine and C.gold or joined and C.green or started and C.red or C.blue)
			private.Fit(card.name, { Raids:Title(raid) }, "small")
			local count = item.mine and (IsInGroup() and max(1, GetNumGroupMembers()) or 1) or raid.members
			local when = started and "now" or Raids:When(raid.startAt)
			private.Fit(card.text, { format("%s, %s  %d/%d%s", raid.where, when, count, raid.size, item.mine and "" or ("  led by "..raid.leader)) }, "tiny", true)
			card.action:SetText(Theme:Colorize((item.mine or joined) and "Open the Raids page" or raid.members >= raid.size and "Full"
				or started and "Click to join" or "Click if you're going", (item.mine or joined) and C.muted or C.gold))
			card:Show()
		elseif i == 1 then
			card.kind:Set("NONE", C.muted)
			card.name:SetText("No raids forming")
			private.Fit(card.text, { "Form one, and every Wanted player of your faction sees it." }, "tiny", true)
			card.action:SetText(Theme:Colorize("Open the Raids page", C.muted))
			card:Show()
		else
			card:Hide()
		end
	end
end

---The panel in place of the challenges without the app's data: what the app adds, and what works without it.
function private.BuildEmpty(container, width)
	local panel = W:Card(container)
	panel:SetPoint("TOPLEFT", 0, BAND_TOP)
	panel:SetSize(width, BAND_TOP - RAIDS_TOP - GAP)
	panel.title = Theme:Text(panel, "title", "")
	panel.title:SetPoint("TOPLEFT", 24, -26)
	panel.line = Theme:Text(panel, "body", "", C.amber)
	panel.line:SetPoint("TOPLEFT", 24, -52)
	panel.line:SetWidth(width - 48 - 150)
	local about = Theme:Text(panel, "body", "A daily challenge, three weekly ones, hot zones where kills count double, and a challenge rank for each character that never resets. wanteddeadordead.com works them out from the kills the app sends, and the app brings them here.", C.muted)
	about:SetPoint("TOPLEFT", 24, -78)
	about:SetWidth(width - 48)
	about:SetWordWrap(true)
	about:SetSpacing(3)
	local works = W:SectionLabel(panel, "Works without the app")
	works:SetPoint("TOPLEFT", 24, -128)
	local list = Theme:Text(panel, "body", "Bounties on the Board, your hunts and claims, the Nearby window and alerts, Hotspots and the map, Enemies, Leaderboards and Activity: all shared with other Wanted players in game.")
	list:SetPoint("TOPLEFT", 24, -146)
	list:SetWidth(width - 48)
	list:SetWordWrap(true)
	list:SetSpacing(3)
	panel.button = W:Button(panel, "", "primary", 140, 30, function() UI:Show("web") end)
	panel.button:SetPoint("TOPRIGHT", -24, -22)
	W:AttachTooltip(panel.button, "Website & app", "Where to download the Wanted app for Windows or Mac.")
	private.empty = panel
end

---One card of the strip along the bottom.
function private.StripCard(container, index, cardWidth, label, color, page, tip)
	local card = W:CardButton(container, function() UI:Show(page) end)
	card:SetPoint("TOPLEFT", (index - 1) * (cardWidth + GAP), STRIP_TOP)
	card:SetSize(cardWidth, STRIP_HEIGHT)
	W:AttachTooltip(card, label, tip)
	local top = card:CreateTexture(nil, "ARTWORK")
	top:SetPoint("TOPLEFT", 1, -1)
	top:SetPoint("TOPRIGHT", -1, -1)
	top:SetHeight(2)
	top:SetColorTexture(color[1], color[2], color[3], 1)
	card.label = W:SectionLabel(card, label)
	card.label:SetPoint("TOPLEFT", 14, -14)
	card.value = Theme:Text(card, "body", "")
	card.value:SetPoint("TOPLEFT", 14, -32)
	card.value:SetWidth(cardWidth - 28)
	card.value.fitWidth = cardWidth - 28
	card.sub = Theme:Text(card, "tiny", "")
	card.sub:SetPoint("TOPLEFT", 14, -50)
	card.sub:SetWidth(cardWidth - 28)
	card.sub.fitWidth = cardWidth - 28
	return card
end

function private.BuildStrip(container, width)
	local cardWidth = floor((width - 3 * GAP) / 4)
	private.money = private.StripCard(container, 1, cardWidth, "Your bounty money", C.green, "hunts", "Your hunts: what you're hunting, owed and have earned.")
	private.nearby = private.StripCard(container, 2, cardWidth, "Enemies nearby", C.red, "enemies", "Every enemy you've met, and who's around now.")
	private.topZone = private.StripCard(container, 3, cardWidth, "Top hotspot", C.amber, "hotspots", "Where enemy players are right now.")
	private.latest = private.StripCard(container, 4, cardWidth, "Latest", C.blue, "activity", "Kills, deaths and sightings, newest first.")
	private.footer = Theme:Text(container, "tiny", "")
	private.footer:SetPoint("TOPLEFT", 0, STRIP_TOP - STRIP_HEIGHT - 10)
	private.footer:SetWidth(width)
end



-- ============================================================================
-- The siege
-- ============================================================================

---"12:40" from seconds.
function private.Clock(seconds)
	seconds = max(floor(seconds), 0)
	return format("%d:%02d", floor(seconds / 60), seconds % 60)
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

---Whether the player stands in a front's zone.
function private.OnFront(front)
	local _, _, _, mapId = Wanted.Recorder:GetPosition()
	return mapId == front.mapId
end

---Whether the player leads their group.
function private.GroupLeader()
	return IsInGroup() and type(UnitIsGroupLeader) == "function" and UnitIsGroupLeader("player") == true
end

---The pill and the line beside the title that carry a clock: before the window, the window and "Opens in 21:40"
---(hours and minutes; minutes and seconds under an hour); in a truce, its clock. Returns whether the clock needs the
---seconds, so a ticker keeps it moving.
function private.SiegeClock()
	local card = private.siege
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

---The rally on the siege front: the line ("Grimshaw leads at Darrow Hill", by the nearest point) and whether a
---waypoint can be set on its leader (not on ourselves). Nothing without the rally module.
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

---Lays the shown buttons out from the card's top right corner, leftward.
function private.PlaceButtons(card)
	local anchor
	for _, button in ipairs({ card.rally, card.front, card.map }) do
		if button:IsShown() then
			button:ClearAllPoints()
			if anchor then
				button:SetPoint("RIGHT", anchor, "LEFT", -BUTTON_GAP, 0)
			else
				button:SetPoint("TOPRIGHT", -16, -8)
			end
			anchor = button
		end
	end
end

---Open the map: the front's zone map (the game can block an addon opening it in a fight).
function private.OpenFrontMap()
	local s = Captures:Siege()
	if not s or not OpenWorldMap then
		return
	end
	if InCombatLockdown() then
		UI:Toast("The map can't be opened in a fight.", C.red)
		return
	end
	OpenWorldMap(s.front.mapId)
end

---Go to the front: a waypoint on the nearest point of the siege front our side can attack (the first from the Horde
---base when the player is elsewhere).
function private.GoToFront()
	local s = Captures:Siege()
	if not s then
		return
	end
	local side = UnitFactionGroup("player")
	local _, x, y, mapId = Wanted.Recorder:GetPosition()
	if mapId ~= s.front.mapId then
		x, y = nil, nil
	end
	local point = Captures:Nearest(s.front, x, y, function(p) return Captures:CanAttack(side, p) end)
	if not point then
		UI:Toast("Nothing left to take on this front.", C.muted)
	elseif Captures:Track(point) then
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
	private.RefreshSiege()
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

---This week's siege wins per front, from the catch-up: "Horde 3 · Alliance 1", or "no wins yet"; the siege front
---marked "tonight" (or its weekday, when the next siege is on another day). onlyKnown: nothing unless a front has any.
function private.RefreshWins(s, onlyKnown)
	local card = private.siege
	local COLORS = Wanted.CapturesMap.COLORS
	local known = false
	for _, front in ipairs(Captures.FRONTS) do
		known = known or Captures:FrontWins(front) ~= nil
	end
	local shown = known or not onlyKnown
	card.winsLabel:SetShown(shown)
	for i, front in ipairs(Captures.FRONTS) do
		local row = card.wins[i]
		local wins = shown and Captures:FrontWins(front)
		if not shown then
			row.zone:SetText("")
			row.score:SetText("")
			row.mark:SetText("")
		else
			private.Fit(row.zone, { front.zone })
			if wins then
				local horde, alliance = Theme:Colorize("Horde "..wins.Horde, COLORS.Horde), Theme:Colorize("Alliance "..wins.Alliance, COLORS.Alliance)
				private.Fit(row.score, { horde.." · "..alliance, Theme:Colorize("H "..wins.Horde, COLORS.Horde).." · "..Theme:Colorize("A "..wins.Alliance, COLORS.Alliance) })
			else
				row.score:SetText(Theme:Colorize("no wins yet", C.faint))
			end
			row.mark:SetText(s and s.front == front and (date("%j", s.start) == date("%j") and "tonight" or date("%a", s.start)) or "")
		end
	end
end

---The siege card: nothing known, before the window (the countdown and what to do), or the round, truce or result
---with the lanes; the buttons that apply; the week's wins. A clock that needs seconds runs on a one-second ticker
---while Home is shown.
function private.RefreshSiege()
	local card = private.siege
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
	-- The title follows the pill, or takes its place without one (a hidden pill would still hold its width)
	card.title:ClearAllPoints()
	if s then
		card.title:SetPoint("LEFT", card.pill, "RIGHT", 8, 0)
	else
		card.title:SetPoint("TOPLEFT", 16, -12)
	end
	if not s then
		card.pill:Hide()
		card.title:SetText("Siege nights")
		card.status:SetText("")
		card.text:SetText("wanteddeadordead.com picks each evening's front the day before; the next one shows here once your app has synced.")
		card.line:SetText("")
		card.waypoint:Hide()
		card.map:Hide()
		card.front:Hide()
		card.rally:Hide()
		private.RefreshWins(nil, true)
		return
	end
	private.Fit(card.title, { "Siege: "..front.zone }, "small")
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
	local COLORS = CapturesMap.COLORS
	if phase == "before" then
		card.line:SetText(format("Break a lane before %s: towers and inhibitors are open all day, and on the siege front they stay down from %s.",
			Wanted.CapturesHUD:HourText(s.start), Wanted.CapturesHUD:HourText(s.start - 3600)))
	else
		if phase == "round" then
			card.pill:Set(format("Round %d", s.round and s.round.n or 1), C.red)
		elseif phase == "over" then
			card.pill:Set("Over", C.muted)
		end
		card.status:SetText(Theme:Colorize("Horde "..s.wins.Horde, COLORS.Horde).." · "..Theme:Colorize("Alliance "..s.wins.Alliance, COLORS.Alliance))
		local line, leader = private.RallyLine(front)
		card.line:SetText(line or "")
		private.rallyLeader = leader
	end
	card.waypoint:SetShown(private.rallyLeader ~= nil)
	card.map:SetShown(OpenWorldMap ~= nil)
	card.front:SetShown(phase ~= "over")
	card.rally:SetShown(Wanted.Rally ~= nil and phase ~= "over" and private.OnFront(front) and private.GroupLeader() and Wanted.Rally:Holder(front.mapId) == nil)
	private.PlaceButtons(card)
	private.RefreshWins(s, false)
	if private.SiegeClock() and not private.siegeTicker then
		private.siegeTicker = C_Timer.NewTicker(1, Wanted:Timed("Home siege clock", function()
			if not UI:IsShown("home") or not private.SiegeClock() then
				private.siegeTicker:Cancel()
				private.siegeTicker = nil
			end
		end))
	end
end



-- ============================================================================
-- Refreshing
-- ============================================================================

---The band: your Blizzard PvP rank as the game tells it (Wanted has no ranks of its own), the points to the next and
---its badge; and your challenge streak, from the app.
function private.RefreshBand(data, mine)
	local band = private.band
	local BlizzRank = Wanted.BlizzRank
	local r = BlizzRank:Get()
	local rank = r and r.rank or 0
	local climbing = r ~= nil and r.weekMax > 0 and rank < BlizzRank.MAX_RANK and r.toNext > 0
	band.badge:SetShown(rank > 0)
	band.points:SetShown(climbing)
	band.toNext:SetShown(climbing)
	band.bar:SetShown(climbing)
	band.nextBadge:SetShown(climbing)
	band.note:SetShown(not climbing)
	if rank > 0 then
		band.badge:SetTexture(BlizzRank:Badge(rank))
		band.label:SetText("PVP RANK "..rank)
		private.Fit(band.title, { BlizzRank:Title(rank) or "" }, "small")
	else
		band.label:SetText("PVP RANK")
		band.title:SetText(r and "No rank yet" or "Not read yet")
	end
	if climbing then
		band.points:SetText(format("%d / %d points", r.earned, r.toNext))
		local toGo, nextTitle = max(r.toNext - r.earned, 0), Theme:Colorize(BlizzRank:Title(rank + 1) or "", C.gold)
		private.Fit(band.toNext, { Theme:Colorize(toGo.." to ", C.muted)..nextTitle, Theme:Colorize(toGo.." to go", C.muted) }, "tiny")
		band.bar:SetValue(r.earned / max(r.toNext, 1))
		band.nextBadge:SetTexture(BlizzRank:Badge(rank + 1))
	elseif rank >= BlizzRank.MAX_RANK then
		band.note:SetText(Theme:Colorize("The top rank", C.gold))
	else
		band.note:SetText("Ranks start with the PvP season: honor from world PvP and battlegrounds climbs Blizzard's ladder.")
	end
	-- The challenge streak needs the app
	local streak = mine ~= nil
	band.streakLabel:SetShown(streak)
	band.streak:SetShown(streak)
	for _, box in ipairs(band.boxes) do
		box:SetShown(streak)
	end
	if not streak then
		return
	end
	band.streak:SetText(mine.streak == 1 and "1 day" or format("%d days", mine.streak))
	-- Days kept filled; today's box outlined while today's challenge is still open
	local filled = min(mine.streak, STREAK_BOXES)
	local todayOpen = data.daily and not mine.daily.done and not Challenges:IsDayOver()
	for i, box in ipairs(band.boxes) do
		Theme:SetBg(box, i <= filled and C.gold or C.input)
		Theme:SetBorderColor(box, (i <= filled or (todayOpen and i == filled + 1)) and C.gold or C.border)
	end
end

function private.RefreshDaily(data, mine)
	local card = private.daily
	local daily = data.daily
	local dayOver = Challenges:IsDayOver()
	if not daily or dayOver then
		card.name:SetText(dayOver and "A new day" or "No challenge today")
		card.name:SetTextColor(C.text[1], C.text[2], C.text[3])
		card.points:Hide()
		card.text:SetText(dayOver and "Today's challenge comes with the app's next update (at login or /reload)." or "")
		card.resets:SetText("")
		private.SetProgress(card.bar, card.progress, nil, nil)
		card.note:SetText("")
		return
	end
	local done = mine and mine.daily.done
	private.Fit(card.name, { daily.name }, "heading")
	local color = done and C.green or C.text
	card.name:SetTextColor(color[1], color[2], color[3])
	card.points:Set("+"..daily.points.." pts", C.gold)
	private.Fit(card.text, { daily.text or "" }, "tiny", true)
	card.resets:SetText(data.dayEnds and ("resets in "..private.Duration(data.dayEnds - GetServerTime())) or "")
	private.SetProgress(card.bar, card.progress, daily, mine and mine.daily)
	card.note:SetText(mine and "" or "Link this character in the app to track it.")
end

function private.RefreshHot(data, byZone)
	local dayOver = Challenges:IsDayOver()
	for i, card in ipairs(private.hot) do
		local hot = not dayOver and data.hot[i]
		card.tag:Set("HOT ZONE", C.red)
		card.edge:SetShown(hot and true or false)
		card.double:SetShown(hot and true or false)
		card.big:SetShown(hot and true or false)
		if hot then
			private.Fit(card.zone, { hot.zone }, "heading")
			card.band:SetText(hot.band and ("Levels "..hot.band) or "")
			local group = byZone[strlower(hot.zone)]
			local now = group and group.recent or 0
			local trend = group and group.trend and TRENDS[group.trend]
			if now > 0 then
				local count = Theme:Colorize(format("%d enem%s", now, now == 1 and "y" or "ies"), C.red)
				local after = trend and (", "..trend) or ""
				private.Fit(card.enemies, { count..Theme:Colorize(" there now"..after, C.muted), count..Theme:Colorize(" now"..after, C.muted), count..Theme:Colorize(" now", C.muted) }, "tiny")
			else
				private.Fit(card.enemies, { Theme:Colorize("No enemies there now", C.faint) }, "tiny")
			end
		else
			card.zone:SetText(Theme:Colorize(i == 1 and "None yet today" or "", C.faint))
			card.band:SetText("")
			card.enemies:SetText("")
		end
	end
end


function private.RefreshStrip()
	local summary = Wanted.Model:GetMySummary()
	local hunting = Theme:Money(summary.hunting)
	private.Fit(private.money.value, { hunting..Theme:Colorize(format("  hunting, %d hunt%s", summary.huntingCount, summary.huntingCount == 1 and "" or "s"), C.muted),
		hunting..Theme:Colorize("  hunting", C.muted), hunting }, "small")
	-- Only what isn't zero
	local owed = summary.owed > 0 and ("Owed "..Theme:Money(summary.owed)) or nil
	local earned = summary.earned > 0 and Theme:Money(summary.earned) or nil
	if owed and earned then
		private.Fit(private.money.sub, { owed..", earned "..earned, owed })
	elseif owed or earned then
		private.Fit(private.money.sub, { owed or ("Earned "..earned) })
	else
		private.Fit(private.money.sub, { "Nothing owed or earned yet", "Nothing owed yet" })
	end

	local nearby = Wanted.Enemies:GetNearby()
	local kos = 0
	for _, d in ipairs(nearby) do
		if d.kos then
			kos = kos + 1
		end
	end
	if #nearby > 0 then
		local count = Theme:Colorize(#nearby.." nearby", C.red)
		if kos > 0 then
			private.Fit(private.nearby.value, { count..Theme:Colorize(format("  %d kill on sight", kos), C.text), count..Theme:Colorize(format("  %d KoS", kos), C.text) }, "small")
		else
			private.Fit(private.nearby.value, { count })
		end
		local first = nearby[1]
		local level = first.level
		if (issecretvalue and issecretvalue(level)) or type(level) ~= "number" then
			level = "?"
		elseif level < 0 then
			level = "??"
		end
		private.Fit(private.nearby.sub, { format("%s, level %s", first.name or "?", tostring(level)), first.name or "?" })
	else
		private.nearby.value:SetText(Theme:Colorize("None nearby", C.muted))
		private.nearby.sub:SetText("")
	end

	local top = Wanted.Hotspots:GetTop(1)[1]
	if top then
		private.Fit(private.topZone.value, { top.zone..Theme:Colorize(format("  %d now", top.recent), C.red), top.zone..Theme:Colorize("  "..top.recent, C.red) }, "small")
		local trend = top.trend and TRENDS[top.trend]
		private.topZone.sub:SetText("Levels "..Wanted.Hotspots:FormatLevels(top)..(trend and (", "..trend) or ""))
	else
		private.topZone.value:SetText(Theme:Colorize("All quiet", C.muted))
		private.topZone.sub:SetText("")
	end

	local latest = Wanted.Model:GetActivity()[1]
	if latest then
		local player = latest.player or (latest.guid and Wanted.Store:GetPlayer(latest.guid))
		local name = Theme:ClassName(latest.name or "?", player and player.class)
		if latest.kind == "kill" then
			private.Fit(private.latest.value, { format("%s killed %s", latest.who, name), Theme:Colorize("Killed ", C.muted)..name }, "small")
		elseif latest.kind == "death" then
			private.Fit(private.latest.value, { name..Theme:Colorize(" died", C.muted) }, "small")
		else
			private.Fit(private.latest.value, { name..Theme:Colorize(" seen", C.muted) }, "small")
		end
		local ago = Theme:Ago(GetServerTime() - latest.t)
		private.Fit(private.latest.sub, { (latest.zone or "?")..", "..ago, ago })
	else
		private.latest.value:SetText(Theme:Colorize("Nothing yet", C.muted))
		private.latest.sub:SetText("")
	end
end

function private.Refresh()
	if not private.band then
		return
	end
	local data = Challenges:Get()
	local shown = data ~= nil
	private.empty:SetShown(not shown)
	if not shown then
		local title, line, button = Challenges:EmptyText()
		private.empty.title:SetText(title)
		private.empty.line:SetText(line)
		private.empty.button:SetText(button)
	end
	private.band:SetShown(shown)
	private.daily:SetShown(shown)
	for _, card in ipairs(private.hot) do
		card:SetShown(shown)
	end
	if shown then
		local mine = Challenges:GetMine()
		private.RefreshBand(data, mine)
		private.RefreshDaily(data, mine)
		private.RefreshHot(data, private.HotspotsByZone(Wanted.Hotspots:Get()))
		if Challenges:IsDemo() then
			private.footer:SetText("Demo challenges, made up to show the page. /wanted demo again to turn them off.")
		else
			private.footer:SetText("Challenges and ranks come from wanteddeadordead.com through the app, updated "..Theme:Ago(GetServerTime() - data.t)..".")
		end
	else
		private.footer:SetText("")
	end
	private.RefreshSiege()
	private.RefreshRaids()
	private.RefreshStrip()
end

UI:RegisterPage("home", {
	title = "Home",
	order = 0,
	noHeader = true,
	build = function(container, width)
		private.hot = {}
		private.BuildSiege(container, width)
		private.BuildEmpty(container, width)
		private.BuildBand(container, width)
		private.BuildDaily(container)
		private.BuildHot(container, width, 1)
		private.BuildHot(container, width, 2)
		private.BuildRaids(container, width)
		private.BuildStrip(container, width)
	end,
	refresh = private.Refresh,
})
