-- Wanted: the PvP page. The season calendar: Blizzard's PvP season and this week's rank cap as the game tells them,
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
local SIDE_WIDTH = 220
local CELL_LINES = 2 -- events written in a day's box; the rest are in its tooltip
local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
	"November", "December" }
local KIND_COLORS = { pvpseason = C.accentHover, wanted = C.gold, weekly = C.blue, pvpholiday = C.amber, holiday = C.muted }



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
		tile.value:SetText("Not known")
		tile.note:SetText("comes with the Wanted app")
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
	for _, e in ipairs(cell.events) do
		local color = KIND_COLORS[e.kind] or C.text
		GameTooltip:AddLine(e.text, color[1], color[2], color[3], true)
	end
	GameTooltip:Show()
end

function private.CreateCell(parent, width, height)
	local cell = CreateFrame("Button", nil, parent)
	cell:SetSize(width, height)
	Theme:Skin(cell, C.panel, C.border)
	cell.number = Theme:Text(cell, "small", "")
	cell.number:SetPoint("TOPLEFT", 6, -5)
	cell.lines = {}
	for i = 1, CELL_LINES do
		local line = Theme:Text(cell, "tiny", "")
		line:SetPoint("TOPLEFT", 6, -8 - i * 12)
		line:SetPoint("RIGHT", -4, 0)
		cell.lines[i] = line
	end
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
			local isToday = year == todayYear and month == todayMonth and day == today
			cell.number:SetText(day)
			cell.number:SetTextColor(unpack(isToday and C.white or C.muted))
			Theme:SetBorderColor(cell, isToday and C.accent or C.border)
			for i, line in ipairs(cell.lines) do
				local e = events[i]
				line:SetText(e and e.text or "")
				if e then
					local color = KIND_COLORS[e.kind] or C.text
					line:SetTextColor(color[1], color[2], color[3])
				end
			end
			cell.more:SetText(#events > CELL_LINES and "+"..(#events - CELL_LINES) or "")
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
			line.text:SetText(e.text)
			line.text:SetTextColor(color[1], color[2], color[3])
			line:Show()
		else
			line:Hide()
		end
	end
	private.upcomingEmpty:SetShown(#items == 0)
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

UI:RegisterPage("pvp", {
	group = "You",
	title = "PvP",
	subtitle = "The season calendar: Blizzard's PvP season, Wanted's season and weekly resets, and the game's holidays.",
	order = 5.3,
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
			private.upcoming[i] = line
		end
		private.upcomingEmpty = Theme:Text(side, "small", "Nothing on the calendar yet.", C.faint)
		private.upcomingEmpty:SetPoint("TOPLEFT", 14, -44)
		local legend = {
			{ "Blizzard PvP season", "pvpseason" }, { "Wanted season", "wanted" }, { "Weekly challenge reset", "weekly" },
			{ "PvP holiday (battlegrounds)", "pvpholiday" }, { "Other holiday", "holiday" },
		}
		for i, item in ipairs(legend) do
			local key = Theme:Text(side, "tiny", item[1], KIND_COLORS[item[2]])
			key:SetPoint("BOTTOMLEFT", 14, 12 + (#legend - i) * 14 + 22)
		end
		local arenas = Theme:Text(side, "tiny", "Arena seasons: not on WoW Forever yet.", C.faint)
		arenas:SetPoint("BOTTOMLEFT", 14, 12)

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
