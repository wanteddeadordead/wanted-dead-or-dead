-- Wanted: the calendar, a tab of Home. The season calendar: Blizzard's PvP season and this week's rank cap as the game tells them,
-- Wanted's season and weekly challenge reset, and the game's holidays (battleground weekends marked), on a month grid
-- with what's coming up beside it. Arenas aren't on WoW Forever yet.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local PvPCalendar = Wanted.PvPCalendar
local private = { cells = {}, upcoming = {} }
local GRID_TOP = 116 -- below the tiles and the month bar
local WEEKDAY_HEIGHT = 18
local CELL_GAP = 3
local SIDE_WIDTH = 190
local CELL_PAD_LEFT, CELL_PAD_RIGHT = 5, 3
local CELL_LINES = 2 -- events starting or ending written in a day's box; the rest are in its tooltip
local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
	"November", "December" }
-- Six kinds, six colours that don't pass for each other: battleground weekends are purple, as amber sat too close to
-- the Wanted season's gold
local BATTLEGROUND_PURPLE = { 0.74, 0.52, 1 }
local KIND_COLORS = { game = C.green, pvpseason = C.accentHover, wanted = C.gold, weekly = C.blue,
	pvpholiday = BATTLEGROUND_PURPLE, holiday = C.muted }



-- ============================================================================
-- The tiles
-- ============================================================================

function private.RefreshTiles()
	local now = GetServerTime()
	local s = Wanted.db.pvpSeason
	local tile = private.blizzTile
	if type(s) ~= "table" then
		tile.value:SetText("Not read yet")
		tile.note:SetText("")
	elseif s.season > 0 then
		tile.value:SetText("Season "..s.season)
		tile.note:SetText(s.endsAt > now and Theme:Left(s.endsAt - now) or "end not announced")
	else
		tile.value:SetText("None running")
		tile.note:SetText("")
	end
	tile = private.capTile
	if type(s) == "table" and s.season > 0 and s.week >= 0 and s.weekMax > 0 then
		tile.value:SetText(format("Rank %d of %d", s.weekMax, s.seasonMax))
		tile.note:SetText(format("week %d", s.week))
	else
		tile.value:SetText("None")
		tile.note:SetText("when a season runs")
	end
	local c = Wanted.Challenges:Get()
	local season = c and c.season
	tile = private.wantedTile
	if season then
		tile.value:SetText(season.name)
		tile.note:SetText(season.endsAt and season.endsAt > now and Theme:Left(season.endsAt - now) or "")
	else
		-- From the Wanted app's catch-up; the note would run into the value on a tile this wide
		tile.value:SetText("Not known yet")
		tile.note:SetText("")
	end
end



-- ============================================================================
-- The month grid
-- ============================================================================

function private.ShowDayTooltip(cell)
	if not cell.events or #cell.events == 0 then
		return
	end
	GameTooltip:SetOwner(cell, "ANCHOR_RIGHT")
	GameTooltip:AddLine(format("%s %d", MONTHS[private.month], cell.day), 1, 1, 1)
	-- Like Blizzard's calendar: what begins or ends that day and at what time, then what's running and its dates,
	-- each holiday that begins or ends with the game's description of it
	for _, e in ipairs(cell.events) do
		local color = KIND_COLORS[e.kind] or C.text
		local d = e.detail or {}
		local text = e.text
		if e.running then
			text = text.." (running"..(d.range and ", "..d.range or "")..")"
		elseif d.seq == "START" and d.begins then
			text = text.." begins "..d.begins
		elseif d.seq == "END" and d.ends then
			text = text.." ends "..d.ends
		end
		GameTooltip:AddLine(text, color[1], color[2], color[3], true)
		if d.description and not e.running then
			GameTooltip:AddLine(d.description, C.muted[1], C.muted[2], C.muted[3], true)
		end
	end
	GameTooltip:Show()
end

function private.CreateCell(parent, width, height)
	local cell = CreateFrame("Button", nil, parent)
	cell:SetSize(width, height)
	Theme:Skin(cell, C.panel, C.border)
	cell.number = Theme:Text(cell, "small", "")
	cell.number:SetPoint("TOPLEFT", CELL_PAD_LEFT, -5)
	cell.textWidth = width - CELL_PAD_LEFT - CELL_PAD_RIGHT
	cell.lines = {}
	for i = 1, CELL_LINES do
		local line = Theme:Text(cell, "tiny", "")
		line:SetPoint("TOPLEFT", CELL_PAD_LEFT, -8 - i * 12)
		line:SetPoint("RIGHT", -CELL_PAD_RIGHT, 0)
		cell.lines[i] = line
	end
	-- What's running that day (the battleground weekend first), faint, under what starts or ends
	cell.running = Theme:Text(cell, "tiny", "")
	cell.running:SetPoint("TOPLEFT", CELL_PAD_LEFT, -8 - (CELL_LINES + 1) * 12)
	cell.running:SetPoint("RIGHT", -CELL_PAD_RIGHT, 0)
	cell.running:SetAlpha(0.6)
	cell.more = Theme:Text(cell, "tiny", "", C.faint)
	cell.more:SetPoint("TOPRIGHT", -5, -6)
	cell:SetScript("OnEnter", private.ShowDayTooltip)
	cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return cell
end

function private.RefreshGrid()
	local year, month = private.year, private.month
	private.monthTitle:SetText(MONTHS[month].." "..year)
	local days = PvPCalendar:GetMonth(year, month)
	local firstWeekday = date("*t", time({ year = year, month = month, day = 1, hour = 12 })).wday
	local numDays = date("*t", time({ year = year, month = month + 1, day = 0, hour = 12 })).day
	local todayYear, todayMonth, today = PvPCalendar:Today()
	for index, cell in ipairs(private.cells) do
		local day = index - firstWeekday + 1
		if day >= 1 and day <= numDays then
			local events = days[day] or {}
			cell.day, cell.events = day, events
			-- The box names what starts or ends that day; the tooltip also has what's running
			local named, running = {}, nil
			for _, e in ipairs(events) do
				if not e.running then
					tinsert(named, e)
				elseif not running then
					running = e
				end
			end
			Theme:FitText(cell.running, cell.textWidth, running and running.labels or { "" })
			if running then
				local color = KIND_COLORS[running.kind] or C.text
				cell.running:SetTextColor(color[1], color[2], color[3])
			end
			local isToday = year == todayYear and month == todayMonth and day == today
			cell.number:SetText(day)
			cell.number:SetTextColor(unpack(isToday and C.white or C.muted))
			Theme:SetBorderColor(cell, isToday and C.accent or C.border)
			for i, line in ipairs(cell.lines) do
				local e = named[i]
				Theme:FitText(line, cell.textWidth, e and e.labels or { "" })
				if e then
					local color = KIND_COLORS[e.kind] or C.text
					line:SetTextColor(color[1], color[2], color[3])
				end
			end
			cell.more:SetText(#named > CELL_LINES and "+"..(#named - CELL_LINES) or "")
			cell:Show()
		else
			cell.events = nil
			cell:Hide()
		end
	end
end

function private.RefreshUpcoming()
	local items = PvPCalendar:GetUpcoming()
	for i, line in ipairs(private.upcoming) do
		local e = items[i]
		if e then
			local color = KIND_COLORS[e.kind] or C.text
			line.date:SetText(format("%s %d", strsub(MONTHS[e.month], 1, 3), e.day))
			Theme:FitText(line.text, line.textWidth, e.labels)
			line.text:SetTextColor(color[1], color[2], color[3])
			line:Show()
		else
			line:Hide()
		end
	end
	private.upcomingEmpty:SetShown(#items == 0)
	-- Under the list, before launch: why there are no battleground weekends yet
	private.noSeasonNote:SetShown(not PvPCalendar:Launched())
	private.noSeasonNote:ClearAllPoints()
	private.noSeasonNote:SetPoint("TOPLEFT", 14, -44 - max(#items, 1) * 20 - 8)
end

function private.Refresh()
	if not private.cells[1] then
		return
	end
	private.RefreshTiles()
	private.RefreshGrid()
	private.RefreshUpcoming()
end

function private.ShowMonth(months)
	if months == 0 then
		private.year, private.month = PvPCalendar:Today()
	else
		private.year, private.month = PvPCalendar:AddMonths(private.year, private.month, months)
	end
	private.Refresh()
end



-- ============================================================================
-- The page
-- ============================================================================

UI:RegisterPage("calendar", {
	title = "Calendar",
	under = "home", -- a tab of Home
	noHeader = true,
	order = 0.1,
	build = function(container, width, height)
		local tileWidth = floor((width - 24) / 3)
		private.blizzTile = W:StatTile(container, "Blizzard PvP season", C.accent)
		private.blizzTile:SetPoint("TOPLEFT")
		private.blizzTile:SetWidth(tileWidth)
		private.capTile = W:StatTile(container, "This week's rank cap", C.amber)
		private.capTile:SetPoint("LEFT", private.blizzTile, "RIGHT", 12, 0)
		private.capTile:SetWidth(tileWidth)
		private.wantedTile = W:StatTile(container, "Wanted season", C.gold)
		private.wantedTile:SetPoint("LEFT", private.capTile, "RIGHT", 12, 0)
		private.wantedTile:SetWidth(tileWidth)

		-- The month bar
		local gridWidth = width - SIDE_WIDTH - 16
		local prev = W:Button(container, "<", "secondary", 28, 24, function() private.ShowMonth(-1) end)
		prev:SetPoint("TOPLEFT", 0, -82)
		local nextButton = W:Button(container, ">", "secondary", 28, 24, function() private.ShowMonth(1) end)
		nextButton:SetPoint("LEFT", prev, "RIGHT", 4, 0)
		private.monthTitle = Theme:Text(container, "heading", "")
		private.monthTitle:SetPoint("LEFT", nextButton, "RIGHT", 12, 0)
		local todayButton = W:Button(container, "Today", "secondary", 64, 24, function() private.ShowMonth(0) end)
		todayButton:SetPoint("TOPLEFT", gridWidth - 64, -82)

		-- The grid: six weeks, Sunday first
		local cellWidth = floor((gridWidth - CELL_GAP * 6) / 7)
		local cellHeight = floor((height - GRID_TOP - WEEKDAY_HEIGHT - CELL_GAP * 5) / 6)
		for col, name in ipairs(WEEKDAYS) do
			local label = Theme:Text(container, "tiny", strupper(name))
			label:SetPoint("TOPLEFT", (col - 1) * (cellWidth + CELL_GAP) + 6, -GRID_TOP)
		end
		for index = 1, 42 do
			local row, col = floor((index - 1) / 7), (index - 1) % 7
			local cell = private.CreateCell(container, cellWidth, cellHeight)
			cell:SetPoint("TOPLEFT", col * (cellWidth + CELL_GAP), -(GRID_TOP + WEEKDAY_HEIGHT + row * (cellHeight + CELL_GAP)))
			private.cells[index] = cell
		end

		-- Beside it: what's coming up, and what the colours mean
		local side = W:Card(container)
		side:SetPoint("TOPRIGHT", 0, -82)
		side:SetPoint("BOTTOMRIGHT")
		side:SetWidth(SIDE_WIDTH)
		local heading = W:SectionLabel(side, "Coming up")
		heading:SetPoint("TOPLEFT", 14, -12)
		for i = 1, 10 do
			local line = CreateFrame("Frame", nil, side)
			line:SetSize(SIDE_WIDTH - 28, 16)
			line:SetPoint("TOPLEFT", 14, -24 - i * 20)
			line.date = Theme:Text(line, "small", "")
			line.date:SetPoint("LEFT")
			line.date:SetWidth(46)
			line.text = Theme:Text(line, "small", "")
			line.text:SetPoint("LEFT", 50, 0)
			line.text:SetPoint("RIGHT")
			line.textWidth = SIDE_WIDTH - 28 - 50
			private.upcoming[i] = line
		end
		private.upcomingEmpty = Theme:Text(side, "small", "Nothing on the calendar yet.", C.faint)
		private.upcomingEmpty:SetPoint("TOPLEFT", 14, -44)
		private.noSeasonNote = Theme:Text(side, "tiny", "Battleground weekends start with launch, Nov 4.", C.faint)
		private.noSeasonNote:SetWidth(SIDE_WIDTH - 28)
		private.noSeasonNote:SetWordWrap(true)
		local legend = {
			{ "WoW Forever", "game" }, { "Blizzard PvP season", "pvpseason" }, { "Wanted season", "wanted" }, { "Weekly challenge reset", "weekly" },
			{ "Battleground weekend", "pvpholiday" }, { "Other holiday", "holiday" },
		}
		for i, item in ipairs(legend) do
			local key = Theme:Text(side, "tiny", item[1], KIND_COLORS[item[2]])
			-- Above the arena note, which wraps to two lines
			key:SetPoint("BOTTOMLEFT", 14, 12 + (#legend - i) * 14 + 34)
		end
		local arenas = Theme:Text(side, "tiny", "Arena seasons: not on WoW Forever yet.", C.faint)
		arenas:SetPoint("BOTTOMLEFT", 14, 12)
		arenas:SetWidth(SIDE_WIDTH - 28)
		arenas:SetWordWrap(true)

		PvPCalendar:OnUpdate(function()
			if container:IsVisible() then
				private.Refresh()
			end
		end)
		private.year, private.month = PvPCalendar:Today()
	end,
	refresh = function()
		PvPCalendar:Open()
		private.Refresh()
	end,
})
