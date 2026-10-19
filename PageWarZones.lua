-- Wanted: Guild Wars › Zones. Who holds each zone of the campaign, since when, how long it's protected, and what comes
-- next there (a race or a war). A row opens the zone's map. From the app's catch-up (GuildWars), as of its time.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local GuildWars = Wanted.GuildWars
local private = { filter = "all", heldOnly = false }
local ROW_HEIGHT = 44
local HEADER = 30
-- Columns: x from the row's left
local COLUMNS = { zone = 16, held = 210, since = 420, protected = 520, next = 650 }
local CONTINENTS = { all = true, ["Eastern Kingdoms"] = true, Kalimdor = true }
local TAG_TIPS = {
	war = { "War", "A guild war: one guild attacks the zone's holder, 40 a side. Only the rosters take points." },
	race = { "Race", "An influence race: open to everyone in the zone, Horde v Alliance. Nothing is captured." },
}

---The zone's continent: the catch-up's, else the campaign's map data (WarZones).
function private.Continent(zone)
	if type(zone.continent) == "string" then
		return zone.continent
	end
	local known = Wanted.WarZones:Get(zone.zone)
	return known and known.continent or ""
end

---"tonight 8:40 PM" in gold, "live now" in green, "Tue 7:50 PM": what comes next at a zone, after its tag.
function private.Next(next_, now)
	if type(next_) ~= "table" then
		return "", nil
	end
	local kind = next_.kind == "war" and "war" or "race"
	local at = type(next_.at) == "number" and next_.at or nil
	local text = type(next_.text) == "string" and next_.text or nil
	if kind == "race" and at and now >= at and now < at + 45 * 60 then
		return Theme:Colorize("live now", C.green), kind
	end
	local when = at and GuildWars:When(at, now) or ""
	if kind == "war" then
		local line = text and ((at and when..": " or "")..text) or when
		return Theme:Colorize(line, at and date("%Y-%m-%d", at) == date("%Y-%m-%d", now) and C.red or C.amber), kind
	end
	return at and date("%Y-%m-%d", at) == date("%Y-%m-%d", now) and Theme:Colorize(when, C.gold) or when, kind
end

function private.CreateRow(row)
	row.zone = Theme:Text(row, "body", "", C.text)
	row.zone:SetPoint("LEFT", COLUMNS.zone, 0)
	row.zone:SetWidth(COLUMNS.held - COLUMNS.zone - 12)
	row.zone:SetWordWrap(false)
	row.crest = row:CreateTexture(nil, "ARTWORK")
	row.crest:SetSize(26, 26)
	row.crest:SetPoint("LEFT", COLUMNS.held, 0)
	row.guild = Theme:Text(row, "body", "", C.text)
	row.guild:SetPoint("TOPLEFT", COLUMNS.held + 34, -7)
	row.guild:SetWidth(COLUMNS.since - COLUMNS.held - 46)
	row.guild:SetWordWrap(false)
	row.faction = Theme:Text(row, "tiny", "")
	row.faction:SetPoint("TOPLEFT", COLUMNS.held + 34, -25)
	row.unowned = Theme:Text(row, "body", "unowned", C.faint)
	row.unowned:SetPoint("LEFT", COLUMNS.held, 0)
	row.since = Theme:Text(row, "small", "")
	row.since:SetPoint("LEFT", COLUMNS.since, 0)
	row.protected = Theme:Text(row, "small", "")
	row.protected:SetPoint("LEFT", COLUMNS.protected, 0)
	row.tag = W:Pill(row)
	row.tag:SetPoint("LEFT", COLUMNS.next, 0)
	row.next = Theme:Text(row, "small", "")
	row.next:SetPoint("LEFT", row.tag, "RIGHT", 6, 0)
	row.next:SetPoint("RIGHT", -12, 0)
	row.next:SetWordWrap(false)
end

function private.UpdateRow(row, zone)
	local now = GetServerTime()
	local holder = type(zone.holder) == "table" and type(zone.holder.guild) == "string" and zone.holder or nil
	row.zone:SetText(zone.zone or "?")
	row.crest:SetShown(holder ~= nil)
	row.guild:SetShown(holder ~= nil)
	row.faction:SetShown(holder ~= nil)
	row.unowned:SetShown(holder == nil)
	if holder then
		row.crest:SetTexture(GuildWars:CrestFile(holder))
		row.guild:SetText(holder.guild)
		local color = GuildWars.SIDE_COLORS[holder.faction] or C.muted
		row.faction:SetText(Theme:Colorize(holder.faction or "", color))
	end
	row.since:SetText(holder and type(zone.since) == "number" and GuildWars:Day(zone.since) or "")
	local protected = type(zone.protectedUntil) == "number" and zone.protectedUntil > now
	row.protected:SetText(holder and (protected and ("until "..date("%a ", zone.protectedUntil)..GuildWars:Clock(zone.protectedUntil)) or "no") or "")
	local line, kind = private.Next(zone.next, now)
	row.tag:Set(kind == "war" and "WAR" or kind and "RACE" or nil, kind == "war" and C.red or C.muted)
	if kind then
		W:Explain(row.tag, TAG_TIPS[kind][1], TAG_TIPS[kind][2])
	end
	row.next:SetText(line)
	-- The whole story on hover
	local tip = holder and format("Held by %s (%s)%s.", holder.guild, holder.faction or "?", type(zone.since) == "number" and (" since "..GuildWars:Day(zone.since)) or "")
		or "Nobody holds it yet. Win a race here, then a war."
	if holder and protected then
		tip = tip..format(" Protected until %s: no declarations until then.", date("%a ", zone.protectedUntil)..GuildWars:Clock(zone.protectedUntil))
	end
	if kind then
		tip = tip.." Next: "..gsub(line, "|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "").."."
	end
	W:Explain(row, zone.zone or "?", tip.."\n\nClick to open its map.")
end

---The zones shown: the continent picked, and only held ones when ticked.
function private.Shown()
	local list = {}
	for _, zone in ipairs(GuildWars:Zones()) do
		if type(zone) == "table" and (private.filter == "all" or private.Continent(zone) == private.filter)
			and (not private.heldOnly or (type(zone.holder) == "table" and zone.holder.guild)) then
			tinsert(list, zone)
		end
	end
	return list
end

function private.Refresh()
	if not private.list then
		return
	end
	local zones = GuildWars:Zones()
	local held = 0
	for _, zone in ipairs(zones) do
		if type(zone) == "table" and type(zone.holder) == "table" and zone.holder.guild then
			held = held + 1
		end
	end
	local at = GuildWars:At()
	private.count:SetText(format("%d zone%s in the campaign · %d held", #zones, #zones == 1 and "" or "s", held)
		..(at and Theme:Colorize("  ·  as of "..GuildWars:Clock(at), C.faint) or ""))
	private.list:SetItems(private.Shown(), held == 0 and #zones > 0 and private.heldOnly and "Nobody holds a zone yet. Win a race, then a war."
		or "No zones to show.")
end

---Open the map: the zone's (a row), or the continent's (the button). The game can block it in a fight.
function private.OpenMap(mapId)
	if not OpenWorldMap then
		return
	end
	if InCombatLockdown() then
		UI:Toast("The map can't be opened in a fight.", C.red)
		return
	end
	OpenWorldMap(mapId)
end

UI:RegisterPage("warzones", {
	title = "Zones",
	tabLabel = "Zones",
	tabTip = { "Zones", "Who holds each zone of the campaign, how long it's protected, and what comes next there." },
	under = "guildwars",
	order = -2,
	hidden = function() return not GuildWars:On() end,
	build = function(container, width, height)
		local filter = W:Segmented(container, {
			{ key = "all", label = "All" },
			{ key = "Eastern Kingdoms", label = "Eastern Kingdoms" },
			{ key = "Kalimdor", label = "Kalimdor" },
		}, function(key)
			private.filter = CONTINENTS[key] and key or "all"
			private.Refresh()
		end, 110)
		filter:SetPoint("TOPLEFT")
		filter:Select("all", true)
		local held = W:Toggle(container, "Only zones someone holds", function(on)
			private.heldOnly = on
			private.Refresh()
		end)
		held:SetPoint("LEFT", filter, "RIGHT", 40, 0)
		private.count = Theme:Text(container, "small", "")
		private.count:SetPoint("TOPRIGHT", 0, -8)
		private.count:SetJustifyH("RIGHT")
		local card = W:Card(container)
		card:SetPoint("TOPLEFT", 0, -38)
		card:SetSize(width, height - 38 - 48)
		for key, x in pairs(COLUMNS) do
			local label = W:SectionLabel(card, ({ zone = "Zone", held = "Held by", since = "Since", protected = "Protected", next = "Next" })[key])
			label:SetPoint("TOPLEFT", x, -12)
		end
		local list = W:List(card, ROW_HEIGHT, floor((card:GetHeight() - HEADER - 2) / ROW_HEIGHT), private.CreateRow, private.UpdateRow)
		list:SetPoint("TOPLEFT", 1, -HEADER)
		list:SetPoint("TOPRIGHT", -1, -HEADER)
		list.onClick = function(zone)
			local known = Wanted.WarZones:Get(zone.zone)
			private.OpenMap(type(zone.mapID) == "number" and zone.mapID or known and known.mapId)
		end
		private.list = list
		local map = W:Button(container, "Open the map", "secondary", 120, 28, function()
			-- The Eastern Kingdoms or Kalimdor, as filtered; else the world
			private.OpenMap(private.filter == "Kalimdor" and 1414 or private.filter == "Eastern Kingdoms" and 1415 or 947)
		end)
		map:SetPoint("BOTTOMLEFT", 0, 4)
		W:Explain(map, "Open the map", "The continent's map, with each zone's holder on it.")
		GuildWars:OnChange(function()
			if container:IsVisible() then
				private.Refresh()
			end
		end)
		private.Refresh()
	end,
	refresh = private.Refresh,
})
