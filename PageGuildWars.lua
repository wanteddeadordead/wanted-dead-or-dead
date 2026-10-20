-- Wanted: the Guild Wars menu entry, where the site runs influence races (Races). Its Tonight tab: the evening's races
-- on a timeline (each one's time, zone, state and influence), tomorrow's zones, and the race picked on it: influence
-- by faction, its three points and who holds them, and the guilds of both sides as the site last counted them.
-- Explanations are tooltips; the numbers are the site's from the app's catch-up, provisional until the race is final.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Races = Wanted.Races
local private = { rows = {}, guildRows = {}, points = {} }
local LEFT_WIDTH, GAP = 290, 14
local ROW_HEIGHT = 104 -- a zone name and its sub-line can each take two lines (Stonetalon Mountains, "Horde won · Alliance may declare")
local GUILDS_TOP = -242 -- under the points, whose names can take two lines (east of Dabyrie's Farmstead)
local MAX_ROWS = 4
local MAX_GUILDS = 6
local GUILD_ROW, GUILD_GAP = 30, 24 -- each side's guild list: a row of name and influence over its share bar
local MEDIA = "Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\"
local SIDE_COLORS = { Horde = { 0.82, 0.24, 0.2 }, Alliance = { 0.24, 0.48, 0.92 } }
local TONIGHT_TIP = "Every night: three races, 45 minutes each. Zones are picked the evening before."
local RACE_TIP = "Open to everyone in the zone, Horde v Alliance. Influence only: nothing is captured or owned.\n\n"
	.."Influence: witnessed kills on the other faction here, and minutes holding its 3 points. The middle point counts "
	.."+20%.\n\nThe faction that doesn't hold the zone may declare a war when it ends."
local SITE_RACES = "https://wanteddeadordead.com/races"
local BAR_TIP = "Provisional, as the site last counted it when your app synced. The site counts the result."
local AS_OF_TIP = "As the site last counted it when your app synced (at login or /reload). The live numbers are on "
	.."wanteddeadordead.com/races: Copy address."

---"7:50 PM" in this computer's clock.
function private.Clock(t)
	return (gsub(date("%I:%M %p", t), "^0", ""))
end

---"33:10" from seconds.
function private.MinSec(seconds)
	seconds = max(floor(seconds), 0)
	return format("%d:%02d", floor(seconds / 60), seconds % 60)
end

---A count with thousands separators.
function private.Count(n)
	return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
end

---"IN 38 MIN", "IN 1:38" (hours and minutes).
function private.Until(seconds)
	seconds = max(seconds, 0)
	if seconds < 3600 then
		return format("IN %d MIN", max(ceil(seconds / 60), 1))
	end
	return format("IN %d:%02d", floor(seconds / 3600), floor(seconds % 3600 / 60))
end

---"Horde 1,284  Alliance 1,107", each in its colour.
function private.Score(race)
	return Theme:Colorize("Horde "..private.Count(race.horde), SIDE_COLORS.Horde).."  "..Theme:Colorize("Alliance "..private.Count(race.alliance), SIDE_COLORS.Alliance)
end

---A race's state pill and the line under its score, by the clock.
---@return string pill
---@return table color
---@return string line
function private.State(race, now)
	local phase = Races:Phase(race, now)
	if phase == "upcoming" then
		return private.Until(race.start - now), C.gold, ""
	elseif phase == "live" then
		return "LIVE", C.green, private.MinSec(race.stop - now).." left"
	end
	local line = race.winner and (race.winner.." won") or ""
	if race.mayDeclare then
		line = line..(line ~= "" and " · " or "")..race.mayDeclare.." may declare"
	end
	return race.final and "ENDED" or "COUNTING", C.muted, line
end



-- ============================================================================
-- Building
-- ============================================================================

function private.BuildTimeline(container, height)
	local card = W:Card(container)
	private.timeline = card
	card:SetPoint("TOPLEFT")
	card:SetSize(LEFT_WIDTH, height)
	private.dayLabel = W:SectionLabel(card, "")
	private.dayLabel:SetPoint("TOPLEFT", 16, -14)
	private.dayGlyph = W:InfoGlyph(card, "Tonight", TONIGHT_TIP)
	for i = 1, MAX_ROWS do
		local row = CreateFrame("Button", nil, card)
		row:SetSize(LEFT_WIDTH - 2, ROW_HEIGHT)
		row:SetPoint("TOPLEFT", 1, -36 - (i - 1) * ROW_HEIGHT)
		row.bg = Theme:Fill(row, C.transparent, "BACKGROUND")
		row.edge = row:CreateTexture(nil, "ARTWORK")
		row.edge:SetPoint("TOPLEFT")
		row.edge:SetPoint("BOTTOMLEFT")
		row.edge:SetWidth(3)
		row.time = Theme:Text(row, "heading", "")
		row.time:SetPoint("TOPLEFT", 16, -12)
		row.kind = W:Pill(row)
		row.kind:SetPoint("TOPLEFT", 16, -34)
		row.kind:Set("RACE", C.muted)
		row.zone = Theme:Text(row, "body", "", C.text)
		row.zone:SetPoint("TOPLEFT", 96, -12)
		row.zone:SetWidth(LEFT_WIDTH - 96 - 86)
		-- Long names wrap to a second line rather than be cut short; the score and sub-line follow under them
		row.zone:SetWordWrap(true)
		row.zone:SetMaxLines(2)
		row.score = Theme:Text(row, "small", "")
		row.score:SetPoint("TOPLEFT", row.zone, "BOTTOMLEFT", 0, -4)
		row.sub = Theme:Text(row, "tiny", "")
		row.sub:SetPoint("TOPLEFT", row.score, "BOTTOMLEFT", 0, -4)
		row.sub:SetWidth(LEFT_WIDTH - 96 - 12)
		row.sub:SetWordWrap(true)
		row.sub:SetMaxLines(2)
		row.state = W:Pill(row)
		row.state:SetPoint("TOPRIGHT", -12, -10)
		row:SetScript("OnClick", function(self)
			private.picked = self.race and private.Key(self.race)
			private.Refresh()
		end)
		row:SetScript("OnEnter", function(self) if self.race ~= private.Picked() then self.bg:SetColorTexture(1, 1, 1, 0.04) end end)
		row:SetScript("OnLeave", function() private.Refresh() end)
		private.rows[i] = row
	end
	private.tomorrowLabel = W:SectionLabel(card, "Tomorrow")
	private.tomorrow = Theme:Text(card, "small", "", C.text)
	private.tomorrow:SetWidth(LEFT_WIDTH - 32)
	private.tomorrow:SetJustifyH("LEFT")
	private.tomorrow:SetWordWrap(true)
	private.empty = Theme:Text(card, "body", "", C.muted)
	private.empty:SetPoint("TOPLEFT", 16, -44)
	private.empty:SetWidth(LEFT_WIDTH - 32)
	private.empty:SetJustifyH("LEFT")
	private.empty:SetWordWrap(true)
	return card
end

function private.BuildRace(container, width, height)
	local inner = width - 28
	local card = W:Card(container)
	card:SetPoint("TOPLEFT", LEFT_WIDTH + GAP, 0)
	card:SetSize(width, height)
	private.head = W:SectionLabel(card, "")
	private.head:SetPoint("TOPLEFT", 14, -14)
	private.title = Theme:Text(card, "title", "")
	private.title:SetPoint("TOPLEFT", 14, -34)
	private.kind = W:Pill(card)
	private.kind:SetPoint("LEFT", private.title, "RIGHT", 12, 0)
	W:Explain(private.kind, "Race", "Open to everyone here. Influence only: nothing is captured.")
	private.left = W:Pill(card)
	private.left:SetPoint("LEFT", private.kind, "RIGHT", 8, 0)
	private.raceGlyph = W:InfoGlyph(card, "Influence race", RACE_TIP)
	private.raceGlyph:SetPoint("LEFT", private.left, "RIGHT", 8, 0)
	-- Influence by faction: Horde from the left, Alliance from the right
	private.hordeLabel = Theme:Text(card, "body", "")
	private.hordeLabel:SetPoint("TOPLEFT", 14, -76)
	private.allianceLabel = Theme:Text(card, "body", "")
	private.allianceLabel:SetPoint("TOPRIGHT", -14, -76)
	private.allianceLabel:SetJustifyH("RIGHT")
	local bar = CreateFrame("Frame", nil, card)
	bar:SetPoint("TOPLEFT", 14, -96)
	bar:SetSize(inner, 10)
	bar.track = Theme:Fill(bar, { 1, 1, 1, 0.06 }, "BACKGROUND")
	bar.horde = bar:CreateTexture(nil, "ARTWORK")
	bar.horde:SetPoint("TOPLEFT")
	bar.horde:SetPoint("BOTTOMLEFT")
	bar.horde:SetColorTexture(SIDE_COLORS.Horde[1], SIDE_COLORS.Horde[2], SIDE_COLORS.Horde[3], 1)
	bar.alliance = bar:CreateTexture(nil, "ARTWORK")
	bar.alliance:SetPoint("TOPRIGHT")
	bar.alliance:SetPoint("BOTTOMRIGHT")
	bar.alliance:SetColorTexture(SIDE_COLORS.Alliance[1], SIDE_COLORS.Alliance[2], SIDE_COLORS.Alliance[3], 1)
	bar.width = inner
	W:Explain(bar, "Influence", BAR_TIP)
	private.bar = bar
	-- The three points, by place, and who holds them
	W:SectionLabel(card, "Points held", inner):SetPoint("TOPLEFT", 14, -124)
	local column = floor(inner / 3)
	for i = 1, 3 do
		local p = CreateFrame("Frame", nil, card)
		p:SetSize(column - 8, 52)
		p:SetPoint("TOPLEFT", 14 + (i - 1) * column, -148)
		p.dot = p:CreateTexture(nil, "ARTWORK")
		p.dot:SetSize(12, 12)
		p.dot:SetPoint("TOPLEFT", 0, -2)
		p.dot:SetTexture(MEDIA.."disc")
		p.name = Theme:Text(p, "body", "", C.text)
		p.name:SetPoint("TOPLEFT", 18, 0)
		p.name:SetWidth(column - 30)
		-- A long point name wraps to a second line, its holder under it
		p.name:SetWordWrap(true)
		p.name:SetMaxLines(2)
		p.holder = Theme:Text(p, "tiny", "")
		p.holder:SetPoint("TOPLEFT", p.name, "BOTTOMLEFT", 0, -4)
		p.holder:SetWidth(column - 30)
		p.holder:SetWordWrap(false)
		private.points[i] = p
	end
	-- Each side's guilds, side by side: Horde on the left, Alliance on the right, each with its share of its side
	local half = floor((inner - GUILD_GAP) / 2)
	private.guildLabels = {}
	for i, side in ipairs({ "Horde", "Alliance" }) do
		local x = 14 + (i - 1) * (half + GUILD_GAP)
		local label = W:SectionLabel(card, side.." guilds", half)
		label:SetPoint("TOPLEFT", x, GUILDS_TOP + 26)
		label:SetTextColor(SIDE_COLORS[side][1], SIDE_COLORS[side][2], SIDE_COLORS[side][3])
		private.guildLabels[side] = label
		private.guildRows[side] = {}
		for n = 1, MAX_GUILDS do
			local g = CreateFrame("Frame", nil, card)
			g:SetSize(half, GUILD_ROW - 4)
			g:SetPoint("TOPLEFT", x, GUILDS_TOP - (n - 1) * GUILD_ROW)
			g.influence = Theme:Text(g, "small", "", C.text)
			g.influence:SetPoint("TOPRIGHT")
			g.influence:SetJustifyH("RIGHT")
			g.name = Theme:Text(g, "body", "", C.text)
			g.name:SetPoint("TOPLEFT")
			g.name:SetPoint("RIGHT", g.influence, "LEFT", -8, 0)
			g.name:SetWordWrap(false)
			g.track = g:CreateTexture(nil, "BACKGROUND")
			g.track:SetPoint("BOTTOMLEFT")
			g.track:SetPoint("BOTTOMRIGHT")
			g.track:SetHeight(4)
			g.track:SetColorTexture(1, 1, 1, 0.06)
			g.fill = g:CreateTexture(nil, "ARTWORK")
			g.fill:SetPoint("LEFT", g.track, "LEFT")
			g.fill:SetHeight(4)
			g.fill:SetColorTexture(SIDE_COLORS[side][1], SIDE_COLORS[side][2], SIDE_COLORS[side][3], 1)
			g.width = half
			private.guildRows[side][n] = g
		end
	end
	private.asOf = Theme:Text(card, "tiny", "")
	private.asOf:SetPoint("BOTTOMLEFT", 14, 14)
	-- The site's live numbers: the game can't open a browser, so the address to copy
	private.copy = W:Button(card, "Copy address", "chip", 100, 20, function()
		W:Dialog({ title = "Live race numbers", input = { value = SITE_RACES }, confirmLabel = "Close" })
	end)
	private.copy:SetPoint("LEFT", private.asOf, "RIGHT", 10, 0)
	W:Explain(private.copy, "Live race numbers", "wanteddeadordead.com/races: click the address, Ctrl+C, and paste it into your browser.")
	private.raceCard = card
	return card
end



-- ============================================================================
-- Refreshing
-- ============================================================================

function private.Key(race)
	return race.zone..":"..race.start
end

---The race shown on the right: the one clicked, else the live one, else the next tonight, else the last.
function private.Picked(now)
	now = now or GetServerTime()
	local tonight = Races:Tonight()
	for _, race in ipairs(tonight) do
		if private.picked and private.Key(race) == private.picked then
			return race
		end
	end
	local live = Races:Live(now)
	if live then
		return live
	end
	for _, race in ipairs(tonight) do
		if race.start > now then
			return race
		end
	end
	return tonight[#tonight]
end

function private.RefreshTimeline(now, picked)
	local tonight = Races:Tonight()
	private.dayLabel:SetText(strupper("Tonight · "..date("%a %d %b", now)))
	private.dayGlyph:ClearAllPoints()
	private.dayGlyph:SetPoint("LEFT", private.dayLabel, "LEFT", private.dayLabel:GetStringWidth() + 6, 0)
	for i, row in ipairs(private.rows) do
		local race = tonight[i]
		row.race = race
		row:SetShown(race ~= nil)
		if race then
			local pill, color, line = private.State(race, now)
			row.time:SetText(private.Clock(race.start))
			row.zone:SetText(race.zone)
			row.score:SetText(Races:Phase(race, now) == "upcoming" and "" or private.Score(race))
			row.sub:SetText(line)
			row.state:Set(pill, color)
			local selected = race == picked
			row.bg:SetColorTexture(1, 1, 1, selected and 0.06 or 0)
			row.edge:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], selected and 1 or 0)
		end
	end
	local y = -36 - min(#tonight, MAX_ROWS) * ROW_HEIGHT - 16
	-- No races tonight: when the next one is
	local next_ = Races:Next(now)
	private.empty:SetShown(#tonight == 0)
	private.empty:SetText(next_ and format("Next race: %s %s, %s", date("%a", next_.start), private.Clock(next_.start), next_.zone) or "No races tonight.")
	if #tonight == 0 then
		y = -44 - private.empty:GetStringHeight() - 20
	end
	local tomorrow = Races:Tomorrow()
	private.tomorrowLabel:SetShown(#tomorrow > 0)
	private.tomorrow:SetShown(#tomorrow > 0)
	private.tomorrowLabel:ClearAllPoints()
	private.tomorrowLabel:SetPoint("TOPLEFT", 16, y)
	private.tomorrow:ClearAllPoints()
	private.tomorrow:SetPoint("TOPLEFT", 16, y - 20)
	local zones = {}
	for _, race in ipairs(tomorrow) do
		tinsert(zones, race.zone)
	end
	private.tomorrow:SetText(#tomorrow > 0 and (table.concat(zones, ", ").."\n"..Theme:Colorize("From "..private.Clock(tomorrow[1].start), C.muted)) or "")
end

function private.RefreshRace(now, race)
	private.raceCard:SetShown(race ~= nil)
	if not race then
		return
	end
	local phase = Races:Phase(race, now)
	local of = #Races:Tonight()
	private.head:SetText(strupper(format("Influence race · %s · %d of %d · %s to %s", phase == "live" and "live" or phase == "upcoming" and "next" or "ended",
		race.n > 0 and race.n or 1, max(of, race.n), private.Clock(race.start), private.Clock(race.stop))))
	private.title:SetText(race.zone)
	private.kind:Set("RACE", C.muted)
	private.left:Set(phase == "live" and (private.MinSec(race.stop - now).." LEFT") or (private.State(race, now)), phase == "live" and C.green or phase == "upcoming" and C.gold or C.muted)
	-- Influence: the site's, or our side's live estimate while the race runs (Races:SideInfluence)
	local horde, hordeLive = Races:SideInfluence(race, "Horde")
	local alliance, allianceLive = Races:SideInfluence(race, "Alliance")
	private.hordeLabel:SetText(Theme:Colorize("Horde "..private.Count(horde), SIDE_COLORS.Horde)..(hordeLive and Theme:Colorize("  live", C.green) or ""))
	private.allianceLabel:SetText((allianceLive and Theme:Colorize("live  ", C.green) or "")..Theme:Colorize("Alliance "..private.Count(alliance), SIDE_COLORS.Alliance))
	local total = horde + alliance
	local bar = private.bar
	bar.horde:SetShown(total > 0)
	bar.alliance:SetShown(total > 0)
	if total > 0 then
		bar.horde:SetWidth(max(bar.width * horde / total, 1))
		bar.alliance:SetWidth(max(bar.width * alliance / total, 1))
	end
	local live = phase == "live" and Races:LiveSide(race)
	W:Explain(bar, "Influence", BAR_TIP..(live and format("\n\nLive, provisional: %d of your side's Wanted players counting now, %d kills, %d minutes on the points.",
		live.players, live.kills, live.minutes) or ""))
	-- The points
	for i, p in ipairs(private.points) do
		local point = race.points[i]
		p:SetShown(point ~= nil)
		if point then
			local color = SIDE_COLORS[point.holder] or C.faint
			p.dot:SetVertexColor(color[1], color[2], color[3], 1)
			p.name:SetText(point.name)
			local here = phase == "live" and Races:HereNow(point) or 0
			p.holder:SetText(Theme:Colorize(point.holder or "Nobody yet", color)..(point.bonus and Theme:Colorize(" · +20%", C.gold) or "")
				..(here > 0 and Theme:Colorize(format(" · %d of yours here", here), C.green) or ""))
			W:Explain(p, point.name, (point.holder and ("Held by the "..point.holder.." as the site last counted it.") or "Nobody has held it yet.")
				..(point.bonus and "\n\nThe middle point: a minute here counts +20%." or ""))
		end
	end
	-- Guilds: each side's by influence, with each one's share of its side's (the site's count); yours marked
	local myGuild = GetGuildInfo and GetGuildInfo("player")
	local mySide = UnitFactionGroup("player")
	for _, side in ipairs({ "Horde", "Alliance" }) do
		local guilds = Races:Guilds(race, side)
		local sideTotal = side == "Horde" and race.horde or race.alliance
		private.guildLabels[side]:SetShown(#guilds > 0)
		for i, g in ipairs(private.guildRows[side]) do
			local guild = guilds[i]
			g:SetShown(guild ~= nil)
			if guild then
				local name = guild.name ~= "" and guild.name or "No guild"
				local yours = side == mySide and myGuild and guild.name == myGuild
				g.name:SetText(name..(yours and Theme:Colorize("  you", C.muted) or ""))
				local share = sideTotal > 0 and guild.influence / sideTotal or 0
				g.influence:SetText(private.Count(guild.influence)..Theme:Colorize(format("  %d%%", floor(share * 100 + 0.5)), C.muted))
				g.fill:SetWidth(max(g.width * min(share, 1), 1))
				W:Explain(g, name, format("%d kills, %d minutes on the points.", guild.kills, guild.minutes))
			end
		end
	end
	-- When the site counted it
	private.asOf:SetText(race.final and "Final" or race.at and ("Counted as of "..private.Clock(race.at)) or "")
	W:Explain(private.asOf, race.final and "Final" or "Provisional", race.final and "The site's result." or AS_OF_TIP)
end

function private.Refresh()
	if not private.raceCard then
		return
	end
	local now = GetServerTime()
	local picked = private.Picked(now)
	private.RefreshTimeline(now, picked)
	private.RefreshRace(now, picked)
	private.mapButton:SetShown(picked ~= nil)
	private.goButton:SetShown(picked ~= nil)
	if picked then
		private.goButton:SetText("Go to "..(strmatch(picked.zone, "^(%S+)") or picked.zone))
	end
end



-- ============================================================================
-- Actions
-- ============================================================================

---Open the map: the race's zone map (the game can block an addon opening it in a fight).
function private.OpenMap()
	local race = private.Picked()
	if not race or not OpenWorldMap then
		return
	end
	if InCombatLockdown() then
		UI:Toast("The map can't be opened in a fight.", C.red)
		return
	end
	OpenWorldMap(race.mapId)
end

---Go there: a waypoint on the race's point nearest the player (its first when the player is elsewhere).
function private.GoTo()
	local race = private.Picked()
	if not race then
		return
	end
	local _, x, y, mapId = Wanted.Recorder:GetPosition()
	if mapId ~= race.mapId then
		x, y = nil, nil
	end
	local point = Races:Nearest(race, x, y)
	if Wanted.Captures:Track({ id = point.id, x = point.x, y = point.y, front = { mapId = race.mapId } }) then
		UI:Toast(format("Waypoint set on %s.", point.name), C.green)
	else
		UI:Toast("The waypoint couldn't be set.", C.red)
	end
end



UI:RegisterPage("guildwars", {
	title = "Guild Wars",
	menuLabel = "Guild Wars",
	tabLabel = "Tonight",
	tabs = { "guildwars", "warzones", "war1", "war2", "war3", "warmarks", "warguild" },
	order = -2,
	-- Where the site runs races or guild wars (the catch-up names them)
	hidden = function() return not (Races:On() or Wanted.GuildWars.Page:On()) end,
	-- LIVE while a race is run
	badge = function()
		if Races:Live() then
			return "LIVE", C.green
		end
		return nil
	end,
	build = function(container, width, height)
		local cardHeight = height - 44
		private.BuildTimeline(container, cardHeight)
		private.BuildRace(container, width - LEFT_WIDTH - GAP, cardHeight)
		private.mapButton = W:Button(container, "Open the map", "secondary", 130, 28, private.OpenMap)
		private.mapButton:SetPoint("BOTTOMLEFT", 0, 4)
		private.goButton = W:Button(container, "Go to", "primary", 150, 28, private.GoTo)
		private.goButton:SetPoint("LEFT", private.mapButton, "RIGHT", 10, 0)
		W:Explain(private.goButton, "Go there", "A waypoint on the race's nearest point.")
		-- The clocks tick while the page is up
		local elapsed = 0
		container:SetScript("OnUpdate", function(_, dt)
			elapsed = elapsed + dt
			if elapsed >= 1 then
				elapsed = 0
				private.Refresh()
			end
		end)
		Races:OnChange(function()
			if container:IsVisible() then
				private.Refresh()
			end
		end)
		private.Refresh()
	end,
	refresh = private.Refresh,
})

-- The tour's Guild Wars stops border these (Tour)
UI:Mark("racetonight", function() return private.timeline end)
UI:Mark("racecard", function() return private.raceCard end)
