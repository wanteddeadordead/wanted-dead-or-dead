-- Wanted: what the PvP page's calendar shows, one month at a time. Blizzard's PvP season as the game tells it
-- (Challenges:ReadSeason), Wanted's season and the weekly challenge reset from the catch-up, the events the operator
-- puts on wanteddeadordead.com's calendar (from the catch-up, kept in WantedDB.calendarEvents), and the holidays in the
-- game's own calendar, the PvP ones (battleground weekends) marked. Dates are the player's local dates.

local _, Wanted = ...
local PvPCalendar = Wanted:NewModule("PvPCalendar")
local private = {
	opened = false, -- the game's calendar asked to load this session
	listeners = {},
	logged = {}, -- holiday titles already written to the log this session
}
local WEEK = 7 * 24 * 60 * 60
local MAX_DAY_EVENTS = 8 -- the game's events read per day, at most
local MAX_UPCOMING = 10
-- The order a day's events are listed in: Wanted's and Blizzard's dates before the game's holidays
local KIND_ORDER = { raid = -1, game = 0, event = 1, pvpseason = 2, wanted = 3, weekly = 4, pvpholiday = 5, holiday = 6 }
-- The site's events: the most kept, their text's longest (the site's limits), and how long one stays after it ends
local MAX_EVENTS = 20
local MAX_EVENT_TEXT = 80
local MAX_EVENT_LINK = 200
local EVENT_KEEP_SECONDS = 2 * 24 * 60 * 60
-- WoW Forever's own dates, from Blizzard's beta schedule (forum post, BlizzCon 2026): the beta ends on October 21,
-- 2026 (no time given: that day everywhere), and the game launches on November 4, 2026 at 3:00 p.m. PST
local BETA_ENDS = { year = 2026, month = 10, day = 21 }
local LAUNCH_AT = Wanted.LAUNCH_AT -- 2026-11-04 23:00 UTC
-- The game marks no holiday as PvP (every one is event type Other on Forever, build 70205); its battleground
-- weekends are titled "Call to Arms: <battleground>"
local BATTLEGROUND_WEEKEND = "^Call to Arms: "

function PvPCalendar:OnLoad()
	-- { t = the catch-up's time, list = { { id, title, startsAt, endsAt, allDay, location, link, kind }, ... } }
	local saved = Wanted.db.calendarEvents
	if type(saved) ~= "table" or type(saved.list) ~= "table" or type(saved.t) ~= "number" then
		saved = { t = 0, list = {} }
	end
	Wanted.db.calendarEvents = saved
	private.DropPastEvents()
end

function PvPCalendar:OnEnable()
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("CALENDAR_UPDATE_EVENT_LIST")
	frame:SetScript("OnEvent", function()
		for _, func in ipairs(private.listeners) do
			func()
		end
	end)
end

---Registers a function called when the game's calendar has new events.
function PvPCalendar:OnUpdate(func)
	tinsert(private.listeners, func)
end

---Asks the game to load its calendar, once a session: its events come with CALENDAR_UPDATE_EVENT_LIST.
function PvPCalendar:Open()
	if private.opened or not C_Calendar or not C_Calendar.OpenCalendar then
		return
	end
	private.opened = true
	pcall(C_Calendar.OpenCalendar)
end

-- ============================================================================
-- The site's events
-- ============================================================================

---Text from the site, safe to show: a string, no escape codes, trimmed and cut to a length. nil otherwise.
function private.Text(value, maxLength)
	if type(value) ~= "string" then
		return nil
	end
	local text = strtrim((gsub(value, "[|%c]", "")))
	if text == "" then
		return nil
	end
	return strsub(text, 1, maxLength)
end

---A time in Unix seconds, or nil.
function private.Time(value)
	if type(value) ~= "number" or value ~= value or value < 1 or value ~= floor(value) then
		return nil
	end
	return value
end

---When an event is over: its end, else the end of its day when all day, else its start.
function private.EventEnd(e)
	return e.endsAt or (e.allDay and e.startsAt + 24 * 60 * 60) or e.startsAt
end

---One of the catch-up's events, checked field by field: { id, title, startsAt, endsAt, allDay, location, link, kind },
---or nil without a title or a start. A link is kept only when it's http(s).
function private.CleanEvent(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local e = {
		id = private.Time(raw.id), title = private.Text(raw.title, MAX_EVENT_TEXT), startsAt = private.Time(raw.startsAt),
		endsAt = private.Time(raw.endsAt), allDay = raw.allDay == true or nil, location = private.Text(raw.location, MAX_EVENT_TEXT),
		link = private.Text(raw.link, MAX_EVENT_LINK), kind = raw.kind == "tournament" and "tournament" or "event",
	}
	if not e.title or not e.startsAt or (e.endsAt and e.endsAt < e.startsAt) then
		return nil
	end
	if e.link and not (strfind(e.link, "^https?://[^%s/]") and not strfind(e.link, "%s")) then
		e.link = nil
	end
	return e
end

---Forgets the events that ended over EVENT_KEEP_SECONDS ago.
function private.DropPastEvents()
	local list, kept = Wanted.db.calendarEvents.list, {}
	local cutoff = GetServerTime() - EVENT_KEEP_SECONDS
	for _, e in ipairs(list) do
		if type(e) == "table" and type(e.startsAt) == "number" and private.EventEnd(e) >= cutoff then
			tinsert(kept, e)
		end
	end
	Wanted.db.calendarEvents.list = kept
end

---Takes the events from this login's catch-up (Catchup:Import): a list replaces the ones kept, unless the catch-up is
---older than theirs; none (an older app, or the site couldn't read them) keeps them. Past ones go either way.
---@param raw any entry.events as the app wrote it
---@param t number the catch-up's time
function PvPCalendar:TakeEvents(raw, t)
	local saved = Wanted.db.calendarEvents
	if type(raw) == "table" and type(t) == "number" and t >= saved.t then
		local list = {}
		for i = 1, #raw do
			local e = private.CleanEvent(raw[i])
			if e then
				tinsert(list, e)
			end
		end
		sort(list, function(a, b) return a.startsAt < b.startsAt end)
		for i = #list, MAX_EVENTS + 1, -1 do
			list[i] = nil
		end
		saved.t, saved.list = t, list
		Wanted:Log("PvPCalendar: %d events from the site", #list)
	end
	private.DropPastEvents()
end

---What the tooltip says about one of the site's events, under its title: the kind and local times, the location and
---the link (as text: the game opens no web links).
function private.EventLines(e)
	local function Clock(t)
		local d = date("*t", t)
		return private.Clock({ hour = d.hour, minute = d.min })
	end
	local function EndClock(dayOf)
		local d, from = date("*t", e.endsAt), date(e.allDay and "!*t" or "*t", dayOf)
		local sameDay = d.year == from.year and d.month == from.month and d.day == from.day
		return (sameDay and "" or format("%d/%02d ", d.month, d.day))..Clock(e.endsAt)
	end
	local when
	if e.allDay then
		when = "start time not announced"..(e.endsAt and ", ends "..EndClock(e.startsAt) or "")
	else
		when = Clock(e.startsAt)..(e.endsAt and " - "..EndClock(e.startsAt) or "")
	end
	local lines = { (e.kind == "tournament" and "Tournament, " or "Event, ")..when }
	if e.location then
		tinsert(lines, e.location)
	end
	if e.link then
		tinsert(lines, e.link)
	end
	return lines
end

---Today's local date.
---@return number year
---@return number month
---@return number day
function PvPCalendar:Today()
	local d = date("*t", GetServerTime())
	return d.year, d.month, d.day
end

---The year and month a number of months away.
function PvPCalendar:AddMonths(year, month, months)
	local index = year * 12 + (month - 1) + months
	return floor(index / 12), index % 12 + 1
end

---A value the addon may use: not a secret.
function private.Readable(value)
	return not (issecretvalue and issecretvalue(value))
end

---A CalendarTime's clock time as Blizzard's calendar shows it: "8:00 AM". nil without one.
function private.Clock(t)
	if type(t) ~= "table" or type(t.hour) ~= "number" or type(t.minute) ~= "number" then
		return nil
	end
	local hour = t.hour % 12
	return format("%d:%02d %s", hour == 0 and 12 or hour, t.minute, t.hour < 12 and "AM" or "PM")
end

---A holiday's dates as Blizzard's calendar shows them: "9/29 - 10/06". nil without both.
function private.Range(from, to)
	if type(from) ~= "table" or type(to) ~= "table" or type(from.month) ~= "number" or type(to.month) ~= "number" then
		return nil
	end
	return format("%d/%02d - %d/%02d", from.month, from.monthDay or 0, to.month, to.monthDay or 0)
end

---What the tooltip says about a holiday: when it begins or ends that day, its dates, and the game's description.
function private.Detail(offset, day, index, e)
	local detail = { seq = private.Readable(e.sequenceType) and e.sequenceType or nil }
	if private.Readable(e.startTime) and private.Readable(e.endTime) then
		detail.begins, detail.ends = private.Clock(e.startTime), private.Clock(e.endTime)
		detail.range = private.Range(e.startTime, e.endTime)
	end
	if C_Calendar.GetHolidayInfo then
		local ok, info = pcall(C_Calendar.GetHolidayInfo, offset, day, index)
		if ok and type(info) == "table" and private.Readable(info.description) and type(info.description) == "string"
			and info.description ~= "" then
			detail.description = info.description
		end
	end
	return detail
end

-- Shorter names for long holidays, longest first, for a day's box and the coming-up list
local SHORTER = {
	["Stranglethorn Fishing Extravaganza"] = { "Fishing Extravaganza", "Fishing contest", "Fishing" },
}

---An event's labels, longest first: the page shows the longest that fits its space. A name's first word is the last
---resort ("Hallow's End", "Hallow's"; "Warsong Gulch", "Warsong").
function private.Labels(text, short, kind)
	local labels = { short }
	for _, shorter in ipairs(SHORTER[text] or {}) do
		tinsert(labels, shorter)
	end
	if kind == "weekly" then
		tinsert(labels, "Reset")
	elseif kind == "pvpseason" or kind == "wanted" then
		local starts = strfind(text, " starts$") ~= nil
		tinsert(labels, starts and "Season starts" or "Season ends")
		tinsert(labels, starts and "Starts" or "Ends")
	elseif kind == "game" and short == "Launch day" then
		tinsert(labels, "Launch")
	elseif kind == "event" and strfind(text, ": .") then
		-- "Forever Open: check-in", "Check-in"
		tinsert(labels, (gsub(strmatch(text, ": (.+)$"), "^%l", strupper)))
	elseif strfind(short, " ") then
		tinsert(labels, (strmatch(short, "^(%S+)")))
	end
	return labels
end

---A holiday's label for a day's box: the part after "Call to Arms: " (the battleground), or the whole title.
function private.ShortTitle(title)
	return (gsub(title, BATTLEGROUND_WEEKEND, ""))
end

---The game's holidays in a month, added to days: battleground weekends as "pvpholiday", the rest as "holiday". The
---game's calendar lists battleground weekends on the beta too, where none run: those show from launch day on. The
---game's calendar reads months by offset from the one it is on (which Blizzard's calendar window may have moved).
function private.AddGameEvents(year, month, Add)
	if not C_Calendar or not C_Calendar.GetMonthInfo or not C_Calendar.GetNumDayEvents or not C_Calendar.GetDayEvent then
		return
	end
	local ok, info = pcall(C_Calendar.GetMonthInfo, 0)
	if not ok or type(info) ~= "table" or type(info.year) ~= "number" or type(info.month) ~= "number" then
		return
	end
	local offset = (year * 12 + month) - (info.year * 12 + info.month)
	local okShown, shown = pcall(C_Calendar.GetMonthInfo, offset)
	local numDays = okShown and type(shown) == "table" and type(shown.numDays) == "number" and shown.numDays or 0
	local pvpType = Enum and Enum.CalendarEventType and Enum.CalendarEventType.PvP
	local launch = date("*t", LAUNCH_AT)
	local launchKey = launch.year * 10000 + launch.month * 100 + launch.day
	for day = 1, numDays do
		local beforeLaunch = year * 10000 + month * 100 + day < launchKey
		local okCount, count = pcall(C_Calendar.GetNumDayEvents, offset, day)
		if okCount and type(count) == "number" and private.Readable(count) then
			for i = 1, min(count, MAX_DAY_EVENTS) do
				local okEvent, e = pcall(C_Calendar.GetDayEvent, offset, day, i)
				if okEvent and type(e) == "table" and private.Readable(e.title) and private.Readable(e.calendarType)
					and private.Readable(e.eventType) and e.calendarType == "HOLIDAY" and type(e.title) == "string" and e.title ~= "" then
					local pvp = (pvpType ~= nil and e.eventType == pvpType) or strfind(e.title, BATTLEGROUND_WEEKEND) ~= nil
					if not private.logged[e.title] then
						-- Which of the game's holidays Forever has, with their icons: a way to tell battleground weekends
						-- in any language
						private.logged[e.title] = true
						Wanted:Log("PvPCalendar: holiday %q, event type %s, icon %s", e.title, tostring(e.eventType),
							private.Readable(e.iconTexture) and tostring(e.iconTexture) or "secret")
					end
					-- Like Blizzard's calendar, a holiday over several days is named on its first and last days; the days
					-- between are marked running (a Call to Arms runs Tuesday to Tuesday)
					local running = private.Readable(e.sequenceType) and e.sequenceType == "ONGOING"
					if not (pvp and beforeLaunch) then
						Add(day, e.title, pvp and "pvpholiday" or "holiday", private.ShortTitle(e.title), running,
							private.Detail(offset, day, i, e))
					end
				end
			end
		end
	end
end

---Whether WoW Forever has launched: battleground weekends run from then.
---@return boolean
function PvPCalendar:Launched()
	return GetServerTime() >= LAUNCH_AT
end

---A month's events by day, WoW Forever's, Wanted's and Blizzard's first: days[day] = { { text, short, kind }, ... },
---kinds "raid", "game", "event", "pvpseason", "wanted", "weekly", "pvpholiday" and "holiday"; short is the label for a
---day's box and labels its shorter forms, longest first;
---running marks a day between a holiday's first and last; detail is a holiday's { seq, begins, ends, range,
---description } from the game, or a site event's { lines } for its tooltip.
---@param year number
---@param month number
---@return table<number, table[]>
function PvPCalendar:GetMonth(year, month)
	local days = {}
	local function Add(day, text, kind, short, running, detail)
		days[day] = days[day] or {}
		-- A holiday the game lists twice on one day shows once
		for _, e in ipairs(days[day]) do
			if e.text == text then
				return
			end
		end
		short = short or text
		tinsert(days[day], { text = text, short = short, labels = private.Labels(text, short, kind), kind = kind,
			running = running or nil, detail = detail })
	end
	local function AddAt(t, text, kind, short)
		local d = date("*t", t)
		if d.year == year and d.month == month then
			Add(d.day, text, kind, short)
		end
	end
	local monthStart = time({ year = year, month = month, day = 1, hour = 0 })
	local nextYear, nextMonth = PvPCalendar:AddMonths(year, month, 1)
	local monthEnd = time({ year = nextYear, month = nextMonth, day = 1, hour = 0 })
	if year == BETA_ENDS.year and month == BETA_ENDS.month then
		Add(BETA_ENDS.day, "WoW Forever beta ends", "game", "Beta ends")
	end
	AddAt(LAUNCH_AT, "WoW Forever launches (3 p.m. PST)", "game", "Launch day")
	-- Blizzard's season: only its end is told
	local s = Wanted.db.pvpSeason
	if type(s) == "table" and type(s.season) == "number" and s.season > 0 and type(s.endsAt) == "number" and s.endsAt > 0 then
		AddAt(s.endsAt, format("PvP Season %d ends", s.season), "pvpseason")
	end
	local c = Wanted.Challenges:Get()
	local season = c and c.season
	if season then
		AddAt(season.startsAt, season.name.." starts", "wanted")
		if season.endsAt then
			AddAt(season.endsAt, season.name.." ends", "wanted")
		end
	end
	-- Each week's challenge reset in the month, within the Wanted season
	if c and c.weekEnds then
		local t = c.weekEnds
		while t - WEEK >= monthStart do
			t = t - WEEK
		end
		while t < monthStart do
			t = t + WEEK
		end
		while t < monthEnd do
			if (not season or t >= season.startsAt) and (not season or not season.endsAt or t <= season.endsAt) then
				AddAt(t, "Weekly reset", "weekly")
			end
			t = t + WEEK
		end
	end
	-- The site's events: on their local day, or an all-day one on its own date (the site keeps it at midnight UTC)
	for _, e in ipairs(Wanted.db.calendarEvents.list) do
		local d = date(e.allDay and "!*t" or "*t", e.startsAt)
		if d.year == year and d.month == month then
			Add(d.day, e.title, "event", nil, nil, { lines = private.EventLines(e) })
		end
	end
	-- Our world PvP raid, and the ones we're going to or interested in
	for _, raid in ipairs(Wanted.Raids:Calendar()) do
		AddAt(raid.at, raid.text, "raid", raid.short)
	end
	private.AddGameEvents(year, month, Add)
	for _, events in pairs(days) do
		sort(events, function(a, b)
			if KIND_ORDER[a.kind] ~= KIND_ORDER[b.kind] then
				return KIND_ORDER[a.kind] < KIND_ORDER[b.kind]
			end
			return a.text < b.text
		end)
	end
	return days
end

---What's coming from today, soonest first, each event once (a holiday over several days at its first day):
---{ year, month, day, text, kind }.
---@return table[]
function PvPCalendar:GetUpcoming()
	local out, seen = {}, {}
	local year, month, today = PvPCalendar:Today()
	for ahead = 0, 2 do
		local y, m = PvPCalendar:AddMonths(year, month, ahead)
		local days = PvPCalendar:GetMonth(y, m)
		local numDays = date("*t", time({ year = y, month = m + 1, day = 0, hour = 12 })).day
		for day = (ahead == 0 and today or 1), numDays do
			for _, e in ipairs(days[day] or {}) do
				if not seen[e.text] and not e.running then
					seen[e.text] = true
					tinsert(out, { year = y, month = m, day = day, text = e.text, short = e.short, labels = e.labels, kind = e.kind })
					if #out == MAX_UPCOMING then
						return out
					end
				end
			end
		end
	end
	return out
end
