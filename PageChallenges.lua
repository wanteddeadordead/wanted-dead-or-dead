-- Wanted: Challenges. Today's challenge and hot zones, this week's three, what this character finished lately,
-- the rules, and the 14-rank ladder with where this character stands. Everything comes from wanteddeadordead.com
-- through the Wanted app (Challenges.lua); without it the page says what the app adds.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Challenges = Wanted.Challenges
local private = {}
local GAP = 10
local LEFT_WIDTH = 478
local DAILY_WIDTH = 262
local TOP_HEIGHT = 112
local WEEK_TOP = -(TOP_HEIGHT + GAP)
local WEEK_ROW = 40
local WEEK_HEIGHT = 36 + 3 * WEEK_ROW
local RECENT_TOP = WEEK_TOP - WEEK_HEIGHT - GAP
local RECENT_ROWS = 3
local RECENT_HEIGHT = 34 + RECENT_ROWS * 18
local LADDER_ROW = 24

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

---Fits a line to the width it was given at build (fitWidth): the first text that fits, then smaller.
function private.Fit(fs, texts, smaller, wrap)
	Theme:FitText(fs, fs.fitWidth, texts, smaller, wrap)
end

---"Today", "Yesterday", a weekday within the week, otherwise "Last week" or older.
function private.When(at)
	local days = floor((GetServerTime() - at) / 86400)
	if date("%Y-%m-%d", at) == date("%Y-%m-%d", GetServerTime()) then
		return "Today"
	elseif days <= 1 then
		return "Yesterday"
	elseif days < 7 then
		return date("%A", at)
	elseif days < 14 then
		return "Last week"
	end
	return format("%d weeks ago", floor(days / 7))
end



-- ============================================================================
-- Building
-- ============================================================================

function private.BuildDaily(container)
	local card = W:Card(container)
	card:SetPoint("TOPLEFT")
	card:SetSize(DAILY_WIDTH, TOP_HEIGHT)
	card.label = W:SectionLabel(card, "Daily challenge")
	card.label:SetPoint("TOPLEFT", 16, -14)
	card.resets = Theme:Text(card, "tiny", "")
	card.resets:SetPoint("TOPRIGHT", -16, -14)
	card.resets:SetJustifyH("RIGHT")
	card.name = Theme:Text(card, "title", "")
	card.name:SetPoint("TOPLEFT", 16, -32)
	-- Room left for the points pill beside it
	card.name:SetWidth(DAILY_WIDTH - 100)
	card.name.fitWidth = DAILY_WIDTH - 100
	card.points = W:Pill(card)
	card.points:SetPoint("LEFT", card.name, "RIGHT", 10, 0)
	card.text = Theme:Text(card, "small", "")
	card.text:SetPoint("TOPLEFT", 16, -56)
	card.text:SetWidth(DAILY_WIDTH - 32)
	card.text.fitWidth = DAILY_WIDTH - 32
	card.bar = W:ProgressBar(card, 8)
	card.bar:SetPoint("TOPLEFT", 16, -82)
	card.bar:SetWidth(DAILY_WIDTH - 90)
	card.progress = Theme:Text(card, "small", "")
	card.progress:SetPoint("RIGHT", card, "TOPRIGHT", -16, -86)
	card.progress:SetJustifyH("RIGHT")
	private.daily = card
end

function private.BuildHot(container)
	local width = LEFT_WIDTH - DAILY_WIDTH - GAP
	local card = W:CardButton(container, function() UI:Show("hotspots") end)
	card:SetPoint("TOPLEFT", DAILY_WIDTH + GAP, 0)
	card:SetSize(width, TOP_HEIGHT)
	W:AttachTooltip(card, "Hotspots", "Where enemy players are right now.")
	local label = W:SectionLabel(card, "Today's hot zones")
	label:SetPoint("TOPLEFT", 16, -14)
	card.zones = {}
	for i = 1, 2 do
		local zone = Theme:Text(card, "body", "")
		zone:SetPoint("TOPLEFT", 16, -32 - (i - 1) * 34)
		zone:SetWidth(width - 32)
		zone.fitWidth = width - 32
		local enemies = Theme:Text(card, "tiny", "")
		enemies:SetPoint("TOPLEFT", 16, -49 - (i - 1) * 34)
		card.zones[i] = { zone = zone, enemies = enemies }
	end
	card.double = Theme:Text(card, "tiny", "Kills count double", C.amber)
	card.double:SetPoint("BOTTOMLEFT", 16, 10)
	private.hot = card
end

function private.BuildWeek(container)
	local card = W:Card(container)
	card:SetPoint("TOPLEFT", 0, WEEK_TOP)
	card:SetSize(LEFT_WIDTH, WEEK_HEIGHT)
	local label = W:SectionLabel(card, "This week")
	label:SetPoint("TOPLEFT", 16, -14)
	card.ends = Theme:Text(card, "tiny", "")
	card.ends:SetPoint("TOPRIGHT", -16, -14)
	card.ends:SetJustifyH("RIGHT")
	card.rows = {}
	for i = 1, 3 do
		local y = -30 - (i - 1) * WEEK_ROW
		local row = {}
		if i > 1 then
			local line = Theme:Line(card)
			line:SetPoint("TOPLEFT", 16, y + 2)
			line:SetPoint("TOPRIGHT", -16, y + 2)
		end
		row.number = Theme:Text(card, "small", tostring(i), C.faint)
		row.number:SetPoint("TOPLEFT", 16, y - 6)
		row.name = Theme:Text(card, "body", "")
		row.name:SetPoint("TOPLEFT", 40, y - 4)
		-- Room left for the HOT pill and the bar
		row.name:SetWidth(200)
		row.name.fitWidth = 200
		row.hot = W:Pill(card)
		row.hot:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
		row.text = Theme:Text(card, "tiny", "")
		row.text:SetPoint("TOPLEFT", 40, y - 21)
		row.text:SetWidth(260)
		row.text.fitWidth = 260
		row.bar = W:ProgressBar(card, 6)
		row.bar:SetPoint("TOPRIGHT", -16, y - 8)
		row.bar:SetWidth(130)
		row.progress = Theme:Text(card, "tiny", "")
		row.progress:SetPoint("TOPRIGHT", -16, y - 21)
		row.progress:SetJustifyH("RIGHT")
		card.rows[i] = row
	end
	private.week = card
end

function private.BuildRecent(container)
	local card = W:Card(container)
	card:SetPoint("TOPLEFT", 0, RECENT_TOP)
	card:SetSize(LEFT_WIDTH, RECENT_HEIGHT)
	local label = W:SectionLabel(card, "Recent completions")
	label:SetPoint("TOPLEFT", 16, -14)
	card.rows = {}
	for i = 1, RECENT_ROWS do
		local y = -32 - (i - 1) * 18
		local row = {}
		row.when = Theme:Text(card, "small", "", C.faint)
		row.when:SetPoint("TOPLEFT", 16, y)
		row.name = Theme:Text(card, "small", "", C.text)
		row.name:SetPoint("TOPLEFT", 106, y)
		row.name:SetWidth(280)
		row.name.fitWidth = 280
		row.points = Theme:Text(card, "small", "", C.green)
		row.points:SetPoint("TOPRIGHT", -16, y)
		row.points:SetJustifyH("RIGHT")
		card.rows[i] = row
	end
	card.none = Theme:Text(card, "small", "Nothing finished yet. Your completions show here.", C.faint)
	card.none:SetPoint("TOPLEFT", 16, -32)
	private.recent = card
end

function private.BuildLadder(container, width, height)
	local ladderWidth = width - LEFT_WIDTH - GAP
	local card = W:Card(container)
	card:SetPoint("TOPLEFT", LEFT_WIDTH + GAP, 0)
	card:SetSize(ladderWidth, height - 10)
	card.label = W:SectionLabel(card, "")
	card.label:SetPoint("TOPLEFT", 16, -14)
	card.bar = W:ProgressBar(card, 8)
	card.bar:SetPoint("TOPLEFT", 16, -32)
	card.bar:SetWidth(ladderWidth - 32)
	card.points = Theme:Text(card, "tiny", "")
	card.points:SetPoint("TOPLEFT", 16, -46)
	card.points:SetWidth(ladderWidth - 32)
	card.rows = {}
	for rank = 1, Challenges.MAX_RANK do
		local row = CreateFrame("Frame", nil, card)
		row:SetPoint("TOPLEFT", 10, -66 - (rank - 1) * LADDER_ROW)
		row:SetSize(ladderWidth - 20, LADDER_ROW - 2)
		Theme:Skin(row, C.transparent, C.transparent)
		row.number = Theme:Text(row, "tiny", tostring(rank), C.faint)
		row.number:SetPoint("LEFT", 6, 0)
		row.badge = row:CreateTexture(nil, "ARTWORK")
		row.badge:SetSize(18, 18)
		row.badge:SetPoint("LEFT", 26, 0)
		row.badge:SetTexture(Challenges:Badge(rank))
		row.title = Theme:Text(row, "small", "")
		row.title:SetPoint("LEFT", 52, 0)
		-- Up to the points on the right
		row.title:SetWidth(ladderWidth - 20 - 52 - 48)
		row.title.fitWidth = ladderWidth - 20 - 52 - 48
		row.at = Theme:Text(row, "tiny", "")
		row.at:SetPoint("RIGHT", -6, 0)
		row.at:SetJustifyH("RIGHT")
		card.rows[rank] = row
	end
	local foot = Theme:Text(card, "tiny", "Each character has its own rank. It never resets.", C.faint)
	foot:SetPoint("BOTTOMLEFT", 16, 12)
	foot:SetWidth(ladderWidth - 32)
	foot:SetWordWrap(true)
	private.ladder = card
end

function private.BuildEmpty(container, width)
	local panel = W:Card(container)
	panel:SetPoint("TOPLEFT")
	panel:SetSize(width, 210)
	panel.title = Theme:Text(panel, "title", "")
	panel.title:SetPoint("TOPLEFT", 24, -26)
	panel.line = Theme:Text(panel, "body", "", C.amber)
	panel.line:SetPoint("TOPLEFT", 24, -52)
	panel.line:SetWidth(width - 48)
	local about = Theme:Text(panel, "body", "wanteddeadordead.com sets a daily challenge, three weekly ones and today's hot zones, counts your kills toward them, and gives each character a rank. The app brings it all here when you log in.", C.muted)
	about:SetPoint("TOPLEFT", 24, -78)
	about:SetWidth(width - 48)
	about:SetWordWrap(true)
	about:SetSpacing(3)
	panel.button = W:Button(panel, "", "primary", 140, 30, function() UI:Show("web") end)
	panel.button:SetPoint("BOTTOMLEFT", 24, 24)
	private.empty = panel
end



-- ============================================================================
-- Refreshing
-- ============================================================================

function private.SetProgress(bar, label, challenge, progress, points)
	if not progress then
		bar:Hide()
		label:SetText(points and Theme:Colorize("+"..points, C.muted) or "")
		return
	end
	bar:Show()
	local suffix = points and (", +"..points) or ""
	if progress.done then
		bar:SetValue(1, C.green)
		label:SetText(Theme:Colorize("Done"..suffix, C.green))
	else
		bar:SetValue(progress.n / challenge.target, C.gold)
		label:SetText(Theme:Colorize(format("%d of %d%s", min(progress.n, challenge.target), challenge.target, suffix), C.muted))
	end
end

function private.RefreshDaily(data, mine)
	local card, daily = private.daily, data.daily
	if not daily or Challenges:IsDayOver() then
		card.name:SetText(Challenges:IsDayOver() and "A new day" or "No challenge today")
		card.name:SetTextColor(C.text[1], C.text[2], C.text[3])
		card.points:Hide()
		card.text:SetText(Challenges:IsDayOver() and "Today's challenge comes with the app's next update." or "")
		card.resets:SetText("")
		private.SetProgress(card.bar, card.progress, nil, nil)
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
end

function private.RefreshHot(data)
	local byZone = {}
	for _, group in ipairs(Wanted.Hotspots:Get()) do
		byZone[strlower(group.zone)] = group
	end
	local dayOver = Challenges:IsDayOver()
	for i, slot in ipairs(private.hot.zones) do
		local hot = not dayOver and data.hot[i]
		if hot then
			private.Fit(slot.zone, { hot.zone..(hot.band and Theme:Colorize("  "..hot.band, C.faint) or ""), hot.zone }, "small")
			local group = byZone[strlower(hot.zone)]
			local now = group and group.recent or 0
			slot.enemies:SetText(now > 0 and Theme:Colorize(format("%d enem%s now", now, now == 1 and "y" or "ies"), C.red) or Theme:Colorize("No enemies seen there now", C.faint))
		else
			slot.zone:SetText(i == 1 and Theme:Colorize("None yet today", C.faint) or "")
			slot.enemies:SetText("")
		end
	end
	private.hot.double:SetShown(not dayOver and #data.hot > 0)
end

function private.RefreshWeek(data, mine)
	local card = private.week
	local weekOver = Challenges:IsWeekOver()
	if weekOver then
		card.ends:SetText("the new week's come with the app's next update")
	else
		card.ends:SetText(data.weekEnds and ("ends Sunday 11:59 PM ET, "..Theme:Left(data.weekEnds - GetServerTime())) or "")
	end
	for i, row in ipairs(card.rows) do
		local challenge = not weekOver and data.weekly[i]
		local progress = challenge and mine and mine.weekly[i]
		row.number:SetShown(challenge and true or false)
		if challenge then
			private.Fit(row.name, { challenge.name }, "small")
			local color = progress and progress.done and C.green or C.text
			row.name:SetTextColor(color[1], color[2], color[3])
			row.hot:Set(challenge.hot and "HOT" or nil, C.red)
			private.Fit(row.text, { challenge.text or "" })
			private.SetProgress(row.bar, row.progress, challenge, progress, challenge.points)
		else
			row.name:SetText(i == 1 and Theme:Colorize("None this week yet", C.faint) or "")
			row.hot:Hide()
			row.text:SetText("")
			private.SetProgress(row.bar, row.progress, nil, nil)
		end
	end
end

function private.RefreshRecent(mine)
	local card = private.recent
	local recent = mine and mine.recent or {}
	card.none:SetShown(#recent == 0)
	if not mine then
		card.none:SetText("Link this character in the app to track its challenges.")
	else
		card.none:SetText("Nothing finished yet. Your completions show here.")
	end
	for i, row in ipairs(card.rows) do
		local r = recent[i]
		row.when:SetText(r and private.When(r.at) or "")
		private.Fit(row.name, { r and r.name or "" }, "tiny")
		row.points:SetText(r and ("+"..r.points) or "")
	end
end

function private.RefreshLadder(mine)
	local card = private.ladder
	local faction = UnitFactionGroup("player")
	local rank = mine and mine.rank or 0
	card.label:SetText(strupper("Challenge rank, "..(faction == "Alliance" and "Alliance" or "Horde")))
	if mine then
		local floorPoints = Challenges:Threshold(rank)
		if rank < Challenges.MAX_RANK then
			local nextAt = mine.nextAt or Challenges:Threshold(rank + 1)
			card.bar:SetValue((mine.points - floorPoints) / max(nextAt - floorPoints, 1))
			card.points:SetText(format("%d points, %d to %s", mine.points, max(nextAt - mine.points, 0), Challenges:Title(rank + 1, faction)))
		else
			card.bar:SetValue(1)
			card.points:SetText(format("%d points, the top rank", mine.points))
		end
	else
		card.bar:SetValue(0)
		card.points:SetText("This character isn't linked to the app yet.")
	end
	for r, row in ipairs(card.rows) do
		local you = r == rank
		local title = Challenges:Title(r, faction)
		private.Fit(row.title, you and { title.." (you)", title } or { title }, "tiny")
		local color = you and C.gold or (r <= rank and C.text or C.faint)
		row.title:SetTextColor(color[1], color[2], color[3])
		row.at:SetText(BreakUpLargeNumbers and BreakUpLargeNumbers(Challenges:Threshold(r)) or tostring(Challenges:Threshold(r)))
		row.badge:SetAlpha(r <= rank and 1 or 0.4)
		Theme:SetBg(row, you and { C.gold[1], C.gold[2], C.gold[3], 0.12 } or C.transparent)
		Theme:SetBorderColor(row, you and { C.gold[1], C.gold[2], C.gold[3], 0.6 } or C.transparent)
	end
end

function private.RefreshRules(data)
	local points = {}
	if data.daily then
		tinsert(points, "daily "..data.daily.points)
	end
	if data.weekly[1] then
		tinsert(points, "weekly "..data.weekly[1].points)
	end
	if data.allThreeBonus and data.allThreeBonus > 0 then
		tinsert(points, "all three in a week +"..data.allThreeBonus)
	end
	private.rules:SetText("Rules: a kill counts when your app logged it or another player confirmed it. World PvP only; kills on players 10 or more levels below you never count."
		..(#points > 0 and (" Points: "..table.concat(points, ", ")..".") or ""))
end

function private.Refresh()
	if not private.ladder then
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
	for _, part in ipairs({ private.daily, private.hot, private.week, private.recent, private.ladder, private.rules }) do
		part:SetShown(shown)
	end
	if not shown then
		return
	end
	local mine = Challenges:GetMine()
	private.RefreshDaily(data, mine)
	private.RefreshHot(data)
	private.RefreshWeek(data, mine)
	private.RefreshRecent(mine)
	private.RefreshLadder(mine)
	private.RefreshRules(data)
end

UI:RegisterPage("challenges", {
	title = "Challenges",
	subtitle = "Daily and weekly goals for both factions, and a lifetime rank. Kills in today's hot zones count double.",
	under = "pvp", -- a tab of the PvP page
	order = 5.2,
	badge = function()
		local done, total = Challenges:CountDone()
		if not done then
			return nil
		end
		return done.."/"..total, C.gold
	end,
	build = function(container, width, height)
		private.BuildEmpty(container, width)
		private.BuildDaily(container)
		private.BuildHot(container)
		private.BuildWeek(container)
		private.BuildRecent(container)
		private.BuildLadder(container, width, height)
		private.rules = Theme:Text(container, "tiny", "", C.faint)
		private.rules:SetPoint("TOPLEFT", 0, RECENT_TOP - RECENT_HEIGHT - 10)
		private.rules:SetWidth(LEFT_WIDTH)
		private.rules:SetWordWrap(true)
		private.rules:SetSpacing(2)
	end,
	refresh = private.Refresh,
})
