-- Wanted: Home, the page the window opens on. Your challenge rank and daily streak, today's challenge and hot
-- zones, this week's three challenges, and a strip of what's going on: your bounty money, enemies nearby, the
-- busiest zone and the latest kill or sighting. Every card opens its page. Challenges come from the Wanted app
-- (Challenges.lua); without it the top shows what the app adds, and the strip still works.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Challenges = Wanted.Challenges
local private = {}
local GAP = 12
local BAND_HEIGHT = 64
local CARD_TOP = -(BAND_HEIGHT + GAP)
local CARD_HEIGHT = 124
local WEEK_TOP = CARD_TOP - CARD_HEIGHT - 16
local WEEK_HEIGHT = 112
local STRIP_TOP = WEEK_TOP - 18 - WEEK_HEIGHT - GAP
local STRIP_HEIGHT = 68
local DAILY_WIDTH = 262
local STREAK_BOXES = 7
local BigFont = Theme:MakeFont("WantedFontHomeBig", 30, C.faint)
local TRENDS = { up = "rising", down = "falling", steady = "steady" }

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

function private.BuildBand(container, width)
	local band = W:CardButton(container, function() UI:Show("challenges") end)
	band:SetPoint("TOPLEFT")
	band:SetSize(width, BAND_HEIGHT)
	W:AttachTooltip(band, "Challenges", "Your rank, streak and challenges, and the rank ladder.")
	band.badge = band:CreateTexture(nil, "ARTWORK")
	band.badge:SetSize(40, 40)
	band.badge:SetPoint("LEFT", 16, 0)
	band.label = W:SectionLabel(band, "")
	band.label:SetPoint("TOPLEFT", 68, -15)
	band.title = Theme:Text(band, "heading", "", C.gold)
	band.title:SetPoint("TOPLEFT", 68, -33)
	band.title:SetWidth(180)
	band.points = Theme:Text(band, "small", "", C.text)
	band.points:SetPoint("TOPLEFT", 250, -17)
	band.toNext = Theme:Text(band, "small", "")
	band.toNext:SetPoint("TOPRIGHT", band, "TOPLEFT", 500, -17)
	band.toNext:SetJustifyH("RIGHT")
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
	-- Without a rank for this character: one line in place of the rank and the streak
	band.note = Theme:Text(band, "small", "", C.muted)
	band.note:SetPoint("TOPLEFT", 250, -36)
	band.note:SetWidth(width - 270)
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
	card.points = W:Pill(card)
	card.points:SetPoint("LEFT", card.name, "RIGHT", 10, 0)
	card.text = Theme:Text(card, "small", "")
	card.text:SetPoint("TOPLEFT", 16, -60)
	card.text:SetWidth(DAILY_WIDTH - 32)
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
	card.double = Theme:Text(card, "small", "Kills here count double", C.amber)
	card.double:SetPoint("TOPLEFT", 16, -72)
	card.enemies = Theme:Text(card, "small", "")
	card.enemies:SetPoint("TOPLEFT", 16, -92)
	card.enemies:SetWidth(cardWidth - 70)
	card.big = card:CreateFontString(nil, "ARTWORK")
	card.big:SetFontObject(BigFont)
	card.big:SetText("2x")
	card.big:SetPoint("BOTTOMRIGHT", -12, 8)
	private.hot[index] = card
end

function private.BuildWeek(container, width)
	private.weekLabel = W:SectionLabel(container, "This week's challenges")
	private.weekLabel:SetPoint("TOPLEFT", 0, WEEK_TOP)
	private.weekEnds = Theme:Text(container, "tiny", "")
	private.weekEnds:SetPoint("TOPRIGHT", 0, WEEK_TOP)
	private.weekEnds:SetJustifyH("RIGHT")
	local cardWidth = floor((width - 2 * GAP) / 3)
	private.weekly = {}
	for i = 1, 3 do
		local card = W:CardButton(container, function() UI:Show("challenges") end)
		card:SetPoint("TOPLEFT", (i - 1) * (cardWidth + GAP), WEEK_TOP - 18)
		card:SetSize(cardWidth, WEEK_HEIGHT)
		card.points = W:Pill(card)
		card.points:SetPoint("TOPLEFT", 16, -12)
		card.hot = W:Pill(card)
		card.hot:SetPoint("LEFT", card.points, "RIGHT", 8, 0)
		card.name = Theme:Text(card, "heading", "")
		card.name:SetPoint("TOPLEFT", 16, -42)
		card.name:SetWidth(cardWidth - 32)
		card.text = Theme:Text(card, "small", "")
		card.text:SetPoint("TOPLEFT", 16, -60)
		card.text:SetWidth(cardWidth - 32)
		card.bar = W:ProgressBar(card, 6)
		card.bar:SetPoint("TOPLEFT", 16, -90)
		card.bar:SetWidth(cardWidth - 96)
		card.progress = Theme:Text(card, "small", "")
		card.progress:SetPoint("RIGHT", card, "TOPRIGHT", -16, -93)
		card.progress:SetJustifyH("RIGHT")
		private.weekly[i] = card
	end
end

---The panel in place of the challenges without the app's data: what the app adds, and what works without it.
function private.BuildEmpty(container, width)
	local panel = W:Card(container)
	panel:SetPoint("TOPLEFT")
	panel:SetSize(width, STRIP_TOP * -1 - GAP)
	panel.title = Theme:Text(panel, "title", "")
	panel.title:SetPoint("TOPLEFT", 24, -26)
	panel.line = Theme:Text(panel, "body", "", C.amber)
	panel.line:SetPoint("TOPLEFT", 24, -52)
	panel.line:SetWidth(width - 48)
	local about = Theme:Text(panel, "body", "A daily challenge, three weekly ones, hot zones where kills count double, and a challenge rank for each character that never resets. wanteddeadordead.com works them out from the kills the app sends, and the app brings them here.", C.muted)
	about:SetPoint("TOPLEFT", 24, -78)
	about:SetWidth(width - 48)
	about:SetWordWrap(true)
	about:SetSpacing(3)
	local works = W:SectionLabel(panel, "Works without the app")
	works:SetPoint("TOPLEFT", 24, -146)
	local list = Theme:Text(panel, "body", "Bounties on the Board, your hunts and claims, the Nearby window and alerts, Hotspots and the map, Enemies, Leaderboards and Activity: all shared with other Wanted players in game.")
	list:SetPoint("TOPLEFT", 24, -166)
	list:SetWidth(width - 48)
	list:SetWordWrap(true)
	list:SetSpacing(3)
	panel.button = W:Button(panel, "", "primary", 140, 30, function() UI:Show("web") end)
	panel.button:SetPoint("BOTTOMLEFT", 24, 24)
	W:AttachTooltip(panel.button, "Website & app", "Where to download the Wanted app for Windows.")
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
	card.sub = Theme:Text(card, "tiny", "")
	card.sub:SetPoint("TOPLEFT", 14, -50)
	card.sub:SetWidth(cardWidth - 28)
	return card
end

function private.BuildStrip(container, width)
	local cardWidth = floor((width - 3 * GAP) / 4)
	private.money = private.StripCard(container, 1, cardWidth, "Your bounty money", C.green, "hunts", "Your hunts: what you're hunting, owed and have earned.")
	private.nearby = private.StripCard(container, 2, cardWidth, "Enemies nearby", C.red, "enemies", "Every enemy you've met, and who's around now.")
	private.topZone = private.StripCard(container, 3, cardWidth, "Top hotspot", C.amber, "hotspots", "Where enemy players are right now.")
	private.latest = private.StripCard(container, 4, cardWidth, "Latest", C.blue, "activity", "Kills, deaths and sightings, newest first.")
	private.footer = Theme:Text(container, "tiny", "")
	private.footer:SetPoint("TOPLEFT", 0, STRIP_TOP - STRIP_HEIGHT - 16)
	private.footer:SetWidth(width)
end



-- ============================================================================
-- Refreshing
-- ============================================================================

function private.RefreshBand(data, mine)
	local band = private.band
	local ranked = mine ~= nil
	band.badge:SetShown(ranked and mine.rank > 0)
	band.points:SetShown(ranked)
	band.toNext:SetShown(ranked)
	band.bar:SetShown(ranked)
	band.nextBadge:SetShown(ranked and mine.rank < Challenges.MAX_RANK)
	band.streakLabel:SetShown(ranked)
	band.streak:SetShown(ranked)
	for _, box in ipairs(band.boxes) do
		box:SetShown(ranked)
	end
	band.note:SetShown(not ranked)
	if not ranked then
		band.label:SetText("CHALLENGE RANK")
		band.title:SetText("Not linked")
		band.note:SetText("This character isn't linked to the Wanted app yet. Log in with the app running and it links itself.")
		return
	end
	local rank = mine.rank
	if rank > 0 then
		band.badge:SetTexture(Challenges:Badge(rank))
		band.label:SetText("CHALLENGE RANK "..rank)
		band.title:SetText(Challenges:Title(rank))
	else
		band.label:SetText("NO RANK YET")
		band.title:SetText("Unranked")
	end
	band.points:SetText(format("%d points", mine.points))
	local floorPoints = Challenges:Threshold(rank)
	if rank < Challenges.MAX_RANK then
		local nextAt = mine.nextAt or Challenges:Threshold(rank + 1)
		band.toNext:SetText(Theme:Colorize(max(nextAt - mine.points, 0).." to ", C.muted)..Theme:Colorize(Challenges:Title(rank + 1), C.gold))
		band.bar:SetValue((mine.points - floorPoints) / max(nextAt - floorPoints, 1))
		band.nextBadge:SetTexture(Challenges:Badge(rank + 1))
	else
		band.toNext:SetText(Theme:Colorize("Top rank", C.gold))
		band.bar:SetValue(1)
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
	card.name:SetText(daily.name)
	local color = done and C.green or C.text
	card.name:SetTextColor(color[1], color[2], color[3])
	card.points:Set("+"..daily.points.." pts", C.gold)
	card.text:SetText(daily.text or "")
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
			card.zone:SetText(hot.zone)
			card.band:SetText(hot.band and ("Levels "..hot.band) or "")
			local group = byZone[strlower(hot.zone)]
			local now = group and group.recent or 0
			local trend = group and group.trend and TRENDS[group.trend]
			if now > 0 then
				card.enemies:SetText(Theme:Colorize(format("%d enem%s", now, now == 1 and "y" or "ies"), C.red)..Theme:Colorize(" there now"..(trend and (", "..trend) or ""), C.muted))
			else
				card.enemies:SetText(Theme:Colorize("No enemies seen there now", C.faint))
			end
		else
			card.zone:SetText(Theme:Colorize(i == 1 and "None yet today" or "", C.faint))
			card.band:SetText("")
			card.enemies:SetText("")
		end
	end
end

function private.RefreshWeek(data, mine)
	local weekOver = Challenges:IsWeekOver()
	if weekOver then
		private.weekEnds:SetText("this week's challenges come with the app's next update")
	elseif data.weekEnds then
		private.weekEnds:SetText("ends Sunday 11:59 PM ET, "..Theme:Left(data.weekEnds - GetServerTime()))
	else
		private.weekEnds:SetText("")
	end
	for i, card in ipairs(private.weekly) do
		local challenge = not weekOver and data.weekly[i]
		local progress = challenge and mine and mine.weekly[i]
		if challenge then
			local done = progress and progress.done
			if done then
				card.points:Set("DONE", C.green)
			else
				card.points:Set("+"..challenge.points.." pts", C.gold)
			end
			card.hot:Set(challenge.hot and "HOT" or nil, C.red)
			card.name:SetText(challenge.name)
			local color = done and C.green or C.text
			card.name:SetTextColor(color[1], color[2], color[3])
			card.text:SetText(challenge.text or "")
		else
			card.points:Hide()
			card.hot:Hide()
			card.name:SetText(Theme:Colorize(i == 1 and "None this week yet" or "", C.faint))
			card.text:SetText("")
		end
		private.SetProgress(card.bar, card.progress, challenge, progress)
	end
end

function private.RefreshStrip()
	local summary = Wanted.Model:GetMySummary()
	private.money.value:SetText(Theme:Money(summary.hunting)..Theme:Colorize(format("  hunting, %d hunt%s", summary.huntingCount, summary.huntingCount == 1 and "" or "s"), C.muted))
	private.money.sub:SetText("Owed to you "..Theme:Money(summary.owed)..", earned "..Theme:Money(summary.earned))

	local nearby = Wanted.Enemies:GetNearby()
	local kos = 0
	for _, d in ipairs(nearby) do
		if d.kos then
			kos = kos + 1
		end
	end
	if #nearby > 0 then
		private.nearby.value:SetText(Theme:Colorize(#nearby.." nearby", C.red)..(kos > 0 and Theme:Colorize(format("  %d kill on sight", kos), C.text) or ""))
		local first = nearby[1]
		local level = first.level
		if (issecretvalue and issecretvalue(level)) or type(level) ~= "number" then
			level = "?"
		elseif level < 0 then
			level = "??"
		end
		private.nearby.sub:SetText(format("%s, level %s", first.name or "?", tostring(level)))
	else
		private.nearby.value:SetText(Theme:Colorize("None nearby", C.muted))
		private.nearby.sub:SetText("")
	end

	local top = Wanted.Hotspots:GetTop(1)[1]
	if top then
		private.topZone.value:SetText(top.zone..Theme:Colorize(format("  %d now", top.recent), C.red))
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
			private.latest.value:SetText(format("%s killed %s", latest.who, name))
		elseif latest.kind == "death" then
			private.latest.value:SetText(name..Theme:Colorize(" died", C.muted))
		else
			private.latest.value:SetText(name..Theme:Colorize(" seen", C.muted))
		end
		private.latest.sub:SetText((latest.zone or "?")..", "..Theme:Ago(GetServerTime() - latest.t))
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
	private.weekLabel:SetShown(shown)
	private.weekEnds:SetShown(shown)
	for _, card in ipairs(private.hot) do
		card:SetShown(shown)
	end
	for _, card in ipairs(private.weekly) do
		card:SetShown(shown)
	end
	if shown then
		local mine = Challenges:GetMine()
		private.RefreshBand(data, mine)
		private.RefreshDaily(data, mine)
		private.RefreshHot(data, private.HotspotsByZone(Wanted.Hotspots:Get()))
		private.RefreshWeek(data, mine)
		if Challenges:IsDemo() then
			private.footer:SetText("Demo challenges, made up to show the page. /wanted demo again to turn them off.")
		else
			private.footer:SetText("Challenges and ranks come from wanteddeadordead.com through the app, updated "..Theme:Ago(GetServerTime() - data.t)..".")
		end
	else
		private.footer:SetText("")
	end
	private.RefreshStrip()
end

UI:RegisterPage("home", {
	title = "Home",
	order = 0,
	noHeader = true,
	build = function(container, width)
		private.hot = {}
		private.BuildEmpty(container, width)
		private.BuildBand(container, width)
		private.BuildDaily(container)
		private.BuildHot(container, width, 1)
		private.BuildHot(container, width, 2)
		private.BuildWeek(container, width)
		private.BuildStrip(container, width)
	end,
	refresh = private.Refresh,
})
