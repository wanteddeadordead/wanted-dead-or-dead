-- Wanted: Home, the Dashboard in the menu (the Siege page opens first): what's happening now. Your challenge rank and daily streak, today's
-- challenge, the hot zone and the next siege evenings (click for the Siege page), world PvP raids (yours, the one you signed up for, the ones forming: click to join), and a
-- strip of what's going on: your bounty money, enemies nearby, the busiest zone and the latest kill or sighting. Every
-- card opens its page; this week's challenges are on Progress. Challenges come from the Wanted app (Challenges.lua);
-- without it the top shows what the app adds, and the raids and the strip still work.

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
local RAIDS_TOP = CARD_TOP - CARD_HEIGHT - 16
local RAIDS_HEIGHT = 112
local STRIP_TOP = RAIDS_TOP - 18 - RAIDS_HEIGHT - GAP
local STRIP_HEIGHT = 68
local EMPTY_HEIGHT = 74 -- the panel without the app's data: its title and button, what the app adds behind its (i)
local DAILY_WIDTH = 262
local STREAK_BOXES = 7
local BigFont = Theme:MakeFont("WantedFontHomeBig", 30, C.faint)
local TRENDS = { up = "rising", down = "falling", steady = "steady" }
-- Room the big "2x" takes at the right of a hot zone card, which the lines beside it stop short of
local BIG_ROOM = 56

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

function private.BuildBand(container, width)
	local band = W:CardButton(container, function() UI:Show("rank") end)
	band:SetPoint("TOPLEFT")
	band:SetSize(width, BAND_HEIGHT)
	W:Explain(band, "Your PvP rank", function()
		local body = "Blizzard's PvP rank as the game tells it, and your challenge streak. Opens Rank & Gear."
		return band.beforeSeason and "Ranks start with the PvP season: honor from world PvP and battlegrounds climbs Blizzard's "
			.."ladder.\n\n"..body or body
	end)
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
	-- Before a season, or at the top: a label in place of the points and bar
	band.note = Theme:Text(band, "small", "", C.muted)
	band.note:SetPoint("TOPLEFT", 250, -26)
	band.note:SetWidth(280)
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
	W:Explain(card, "Daily challenge", function()
		if Challenges:IsDayOver() then
			return "Today's challenge comes with the app's next update (at login or /reload)."
		elseif not Challenges:GetMine() then
			return "Link this character in the Wanted app to track its progress."
		end
		return "Opens this week's challenges."
	end)
	private.daily = card
end

function private.BuildHot(container, width, index)
	local cardWidth = floor((width - DAILY_WIDTH - 2 * GAP) / 2)
	local card = W:CardButton(container, function() UI:Show("hotspots") end)
	card:SetPoint("TOPLEFT", DAILY_WIDTH + GAP + (index - 1) * (cardWidth + GAP), CARD_TOP)
	card:SetSize(cardWidth, CARD_HEIGHT)
	W:Explain(card, "Hotspots", function()
		return card.big:IsShown() and "Kills here count double today.\n\nWhere enemy players are right now." or "Where enemy players are right now."
	end)
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
	card.enemies = Theme:Text(card, "small", "")
	card.enemies:SetPoint("TOPLEFT", 16, -72)
	card.enemies:SetWidth(cardWidth - 32 - BIG_ROOM)
	card.enemies.fitWidth = cardWidth - 32 - BIG_ROOM
	card.big = card:CreateFontString(nil, "ARTWORK")
	card.big:SetFontObject(BigFont)
	card.big:SetText("2x")
	card.big:SetPoint("BOTTOMRIGHT", -12, 8)
	private.hot[index] = card
end

---The upcoming sieges, in the second hot zone's place: the next three evenings, each its day, hour and front (or that
---it's to be picked); opens the Siege page.
function private.BuildUpcoming(container, width)
	local cardWidth = floor((width - DAILY_WIDTH - 2 * GAP) / 2)
	local card = W:CardButton(container, function() UI:Show("siege") end)
	card:SetPoint("TOPLEFT", DAILY_WIDTH + GAP + cardWidth + GAP, CARD_TOP)
	card:SetSize(cardWidth, CARD_HEIGHT)
	W:AttachTooltip(card, "Upcoming sieges", "The next siege evenings and their fronts, each picked the evening before. Opens the Siege page.")
	card.label = W:SectionLabel(card, "Upcoming sieges")
	card.label:SetPoint("TOPLEFT", 16, -14)
	card.lines = {}
	for i = 1, 3 do
		local line = Theme:Text(card, "small", "", C.text)
		line:SetPoint("TOPLEFT", 16, -38 - (i - 1) * 22)
		line:SetWidth(cardWidth - 32)
		line.fitWidth = cardWidth - 32
		card.lines[i] = line
	end
	private.upcoming = card
end

---The raids row: up to three cards (the raid you lead or joined first, then the ones forming).
function private.BuildRaids(container, width)
	local label = W:SectionLabel(container, "Raids")
	label:SetPoint("TOPLEFT", 0, RAIDS_TOP)
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
		W:Explain(card, "Raids", function() return card.tip end)
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
	UI:Toast(why or (item.raid.startAt <= GetServerTime() and "Asked to join." or "Going."),
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
			-- The one we lead or joined opens the Raids page; any other says what a click does
			local full = not (item.mine or joined) and raid.members >= raid.size
			card.action:SetText((item.mine or joined) and "" or Theme:Colorize(full and "Full" or started and "Join" or "Going?", full and C.muted or C.gold))
			card.tip = (item.mine or joined or full) and "Opens the Raids page." or started and "Click to join. The leader invites you."
				or "Click if you're going: you'll be asked to join when it starts."
			card:Show()
		elseif i == 1 then
			card.kind:Set("NONE", C.muted)
			card.name:SetText("No raids forming")
			card.text:SetText("")
			card.action:SetText("")
			card.tip = "Form one, and every Wanted player of your faction sees it. Opens the Raids page."
			card:Show()
		else
			card:Hide()
		end
	end
end

---The panel in place of the challenges without the app's data: get or update the app; what it adds, and what works
---without it, behind an (i).
function private.BuildEmpty(container, width)
	local panel = W:Card(container)
	panel:SetPoint("TOPLEFT")
	panel:SetSize(width, EMPTY_HEIGHT)
	panel.title = Theme:Text(panel, "title", "")
	panel.title:SetPoint("LEFT", 24, 0)
	panel.title:SetWidth(width - 48 - 140 - 40)
	panel.title:SetWordWrap(false)
	panel.glyph = W:InfoGlyph(panel, "What the app adds", "A daily challenge, three weekly ones, hot zones where kills count double, "
		.."and a challenge rank for each character that never resets. wanteddeadordead.com works them out from the kills the "
		.."app sends, and the app brings them here.\n\nWorks without the app: bounties on the Board, your hunts and claims, the "
		.."Nearby window and alerts, Hotspots and the map, Enemies, Leaderboards and Activity, all shared with other Wanted "
		.."players in game.")
	panel.button = W:Button(panel, "", "primary", 140, 30, function() UI:Show("web") end)
	panel.button:SetPoint("RIGHT", -24, 0)
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
	private.footer:SetPoint("TOPLEFT", 0, STRIP_TOP - STRIP_HEIGHT - 16)
	private.footer:SetWidth(width)
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
		band.note:SetText("Season not started")
	end
	band.beforeSeason = not climbing and rank < BlizzRank.MAX_RANK
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
		card.text:SetText("")
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
	card.note:SetText(mine and "" or Theme:Colorize("Not linked", C.amber))
end

function private.RefreshHot(data, byZone)
	local dayOver = Challenges:IsDayOver()
	for i, card in ipairs(private.hot) do
		local hot = not dayOver and data.hot[i]
		card.tag:Set("HOT ZONE", C.red)
		card.edge:SetShown(hot and true or false)
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


---The upcoming sieges card: "Fri 7 PM · Hillsbrad Foothills", "Sat 7 PM · to be picked"; nothing known, said so.
function private.RefreshUpcoming()
	local card = private.upcoming
	local Captures = Wanted.Captures
	if not Captures:Siege() then
		card.lines[1]:SetText("No siege picked yet")
		card.lines[2]:SetText("")
		card.lines[3]:SetText("")
		return
	end
	for i, evening in ipairs(Captures:Evenings(#card.lines)) do
		local day, hour = date("%a", evening.day), Wanted.CapturesHUD:HourText(evening.start)
		local front = evening.front and evening.front.zone or Theme:Colorize("to be picked", C.muted)
		private.Fit(card.lines[i], { format("%s %s · %s", day, hour, front), format("%s · %s", day, front) }, "tiny")
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
	local setupHeight = private.setup.Refresh()
	private.content:ClearAllPoints()
	private.content:SetPoint("TOPLEFT", 0, -(setupHeight + GAP))
	private.content:SetPoint("BOTTOMRIGHT")
	local data = Challenges:Get()
	local shown = data ~= nil
	private.empty:SetShown(not shown)
	-- The raids and the strip close up under the short panel
	private.lower:SetPoint("TOPLEFT", 0, shown and 0 or -RAIDS_TOP - EMPTY_HEIGHT - GAP)
	if not shown then
		local title, tip, button = Challenges:EmptyText()
		local empty = private.empty
		empty.title:SetText(title)
		empty.glyph:ClearAllPoints()
		empty.glyph:SetPoint("LEFT", empty.title, "LEFT", min(empty.title:GetStringWidth(), empty.title:GetWidth()) + 8, 0)
		empty.button:SetText(button)
		W:Explain(empty.button, button, tip)
	end
	private.band:SetShown(shown)
	private.daily:SetShown(shown)
	private.upcoming:SetShown(shown)
	for _, card in ipairs(private.hot) do
		card:SetShown(shown)
	end
	if shown then
		local mine = Challenges:GetMine()
		private.RefreshBand(data, mine)
		private.RefreshDaily(data, mine)
		private.RefreshHot(data, private.HotspotsByZone(Wanted.Hotspots:Get()))
		private.RefreshUpcoming()
		if Challenges:IsDemo() then
			private.footer:SetText(Theme:Colorize("Demo challenges", C.amber))
			W:Explain(private.footer, "Demo challenges", "Made up to show the page. /wanted demo again to turn them off.")
		else
			private.footer:SetText("Updated "..Theme:Ago(GetServerTime() - data.t))
			W:Explain(private.footer, "Challenges", "Challenges and ranks come from wanteddeadordead.com through the Wanted app.")
		end
	else
		private.footer:SetText("")
	end
	private.RefreshRaids()
	private.RefreshStrip()
end

UI:RegisterPage("home", {
	title = "Home",
	menuLabel = "Dashboard",
	order = 0,
	noHeader = true,
	build = function(container, width)
		private.hot = {}
		-- The setup marks first (Setup); everything else in a frame that moves down under them
		private.setup = Wanted.Setup:BuildCard(container, width, true, function() UI:Show("web") end)
		private.setup:SetPoint("TOPLEFT")
		W:AttachTooltip(private.setup, "Your setup", "What Wanted needs to work in full, and what's missing. Opens Website & app, where the addresses are.")
		local content = CreateFrame("Frame", nil, container)
		content:SetPoint("TOPLEFT")
		content:SetPoint("BOTTOMRIGHT")
		private.content = content
		private.BuildEmpty(content, width)
		private.BuildBand(content, width)
		private.BuildDaily(content)
		private.BuildHot(content, width, 1)
		private.BuildUpcoming(content, width)
		-- The raids and the strip: where the challenges leave off, or under the short panel without them
		local lower = CreateFrame("Frame", nil, content)
		lower:SetPoint("TOPLEFT")
		lower:SetSize(width, 1) -- only its top matters: the cards hang below it
		private.lower = lower
		private.BuildRaids(lower, width)
		private.BuildStrip(lower, width)
	end,
	refresh = private.Refresh,
})
