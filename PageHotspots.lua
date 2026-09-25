-- Wanted: PvP hotspots. The zones where enemy players were seen in the last hour, busiest first: how many
-- now and in the hour, their levels, the biggest guild there, PvP deaths, and whether it's getting
-- busier. Hover a zone for who was there; click it to open the map on it.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Hotspots = Wanted.Hotspots
local private = {}
local ROW_HEIGHT = 40
local TOOLTIP_NAMES = 12
local COLUMNS = {
	{ label = "Zone", x = 16 },
	{ label = "Now", x = 250 },
	{ label = "Hour", x = 310 },
	{ label = "Levels", x = 370 },
	{ label = "Trend", x = 460 },
	{ label = "Deaths", x = 540 },
	{ label = "Last seen", x = 610 },
}
local TRENDS = {
	up = { "Rising", C.red },
	down = { "Falling", C.green },
	steady = { "Steady", C.muted },
}

function private.CreateRow(row)
	row.bar = row:CreateTexture(nil, "ARTWORK")
	row.bar:SetPoint("TOPLEFT")
	row.bar:SetPoint("BOTTOMLEFT")
	row.bar:SetWidth(3)
	row.zone = Theme:Text(row, "body", "")
	row.zone:SetPoint("TOPLEFT", 16, -6)
	row.zone:SetWidth(225)
	row.sub = Theme:Text(row, "tiny", "")
	row.sub:SetPoint("TOPLEFT", 16, -23)
	row.sub:SetWidth(225)
	row.recent = Theme:Text(row, "body", "")
	row.recent:SetPoint("LEFT", 250, 0)
	row.hour = Theme:Text(row, "body", "")
	row.hour:SetPoint("LEFT", 310, 0)
	row.levels = Theme:Text(row, "body", "")
	row.levels:SetPoint("LEFT", 370, 0)
	row.trend = Theme:Text(row, "small", "")
	row.trend:SetPoint("LEFT", 460, 0)
	row.deaths = Theme:Text(row, "body", "")
	row.deaths:SetPoint("LEFT", 540, 0)
	row.last = Theme:Text(row, "small", "")
	row.last:SetPoint("LEFT", 610, 0)
end

---Red for a busy zone, gold for a few enemies, green for one or two, nothing when quiet.
function private.HeatColor(group)
	if group.recent >= 10 then
		return C.red
	elseif group.recent >= 3 then
		return C.gold
	elseif group.recent > 0 then
		return C.green
	end
	return C.transparent
end

function private.UpdateRow(row, group)
	local heat = private.HeatColor(group)
	row.bar:SetColorTexture(heat[1], heat[2], heat[3], heat[4] or 1)
	row.zone:SetText(group.zone)
	if group.guild then
		row.sub:SetText(Theme:Colorize(format("%d from <%s>", group.guildCount, group.guild), C.gold))
	elseif group.hour > 0 then
		row.sub:SetText(Theme:Colorize(format("%d enem%s in the last hour", group.hour, group.hour == 1 and "y" or "ies"), C.faint))
	else
		row.sub:SetText(Theme:Colorize("PvP deaths only", C.faint))
	end
	row.recent:SetText(group.recent > 0 and Theme:Colorize(tostring(group.recent), heat) or Theme:Colorize("0", C.faint))
	row.hour:SetText(group.hour)
	row.levels:SetText(group.hour > 0 and Hotspots:FormatLevels(group) or Theme:Colorize("-", C.faint))
	local trend = group.trend and TRENDS[group.trend]
	row.trend:SetText(trend and Theme:Colorize(trend[1], trend[2]) or Theme:Colorize("-", C.faint))
	row.deaths:SetText(group.deaths > 0 and Theme:Colorize(tostring(group.deaths), C.red) or Theme:Colorize("0", C.faint))
	local last = max(group.lastSeen or 0, group.lastFight or 0)
	row.last:SetText(last > 0 and Theme:Ago(GetServerTime() - last) or "")
end

function private.ShowTooltip(row, group)
	GameTooltip:SetOwner(row, "ANCHOR_CURSOR_RIGHT", 16, 0)
	GameTooltip:SetText(group.zone, 1, 1, 1)
	local now = GetServerTime()
	for i, enemy in ipairs(group.enemies) do
		if i > TOOLTIP_NAMES then
			GameTooltip:AddLine(format("and %d more", #group.enemies - TOOLTIP_NAMES), 0.6, 0.62, 0.68)
			break
		end
		local level = type(enemy.level) == "number" and (enemy.level < 0 and "??" or tostring(enemy.level)) or "?"
		GameTooltip:AddDoubleLine(Theme:ClassName(enemy.name, enemy.class).."  "..level, Theme:Ago(now - enemy.lastSeen), 1, 1, 1, 0.6, 0.62, 0.68)
	end
	if group.deaths > 0 then
		GameTooltip:AddLine(format("%d PvP death%s here in the last hour", group.deaths, group.deaths == 1 and "" or "s"), 0.93, 0.33, 0.31)
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine(group.mapId and "Click to open the map on this zone." or "No map for this zone yet.", 0.6, 0.62, 0.68)
	GameTooltip:Show()
end

function private.Refresh()
	if not private.list then
		return
	end
	private.mapToggle:SetChecked(Wanted.MapPins:IsShown())
	local groups = Hotspots:Get()
	local busy = 0
	for _, group in ipairs(groups) do
		if group.recent > 0 then
			busy = busy + 1
		end
	end
	private.count:SetText(format("%d zone%s with enemies in the last 15 minutes", busy, busy == 1 and "" or "s"))
	private.list:SetItems(groups, "No enemies seen in the last hour.", "Zones fill in as you and other Wanted users spot enemy players.")
end

UI:RegisterPage("hotspots", {
	title = "Hotspots",
	subtitle = "Where enemy players are right now, from what you and other Wanted users have seen. Busiest first.",
	order = 3.5,
	build = function(container, width, height)
		private.count = Theme:Text(container, "small", "")
		private.count:SetPoint("TOPLEFT", 0, -2)
		private.mapToggle = W:Toggle(container, "Enemies on the world map", function(checked)
			Wanted.MapPins:SetShown(checked)
		end)
		private.mapToggle:SetPoint("TOPRIGHT", 0, 0)
		W:AttachTooltip(private.mapToggle, "Enemies on the world map", "Dots where enemies were seen in the last 30 minutes. Also in the map's own filter menu.")
		local note = Theme:Text(container, "tiny", "Now = last 15 minutes. Counts only enemies a Wanted user has seen.", C.faint)
		note:SetPoint("TOPLEFT", 0, -18)

		local headerBar = CreateFrame("Frame", nil, container)
		headerBar:SetPoint("TOPLEFT", 0, -34)
		headerBar:SetPoint("TOPRIGHT", 0, -34)
		headerBar:SetHeight(24)
		local line = Theme:Line(headerBar)
		line:SetPoint("BOTTOMLEFT")
		line:SetPoint("BOTTOMRIGHT")
		for _, col in ipairs(COLUMNS) do
			local label = W:SectionLabel(headerBar, col.label)
			label:SetPoint("LEFT", col.x, 0)
		end

		local listTop = 62
		local list = W:List(container, ROW_HEIGHT, floor((height - listTop) / ROW_HEIGHT), private.CreateRow, private.UpdateRow)
		list:SetPoint("TOPLEFT", 0, -listTop)
		list:SetPoint("TOPRIGHT", 0, -listTop)
		list.onClick = function(group)
			if InCombatLockdown() then
				UI:Toast("The map opens after combat.")
			elseif not Hotspots:OpenMap(group) then
				UI:Toast("No map for "..group.zone.." yet.")
			end
		end
		list.onEnter = private.ShowTooltip
		private.list = list
	end,
	refresh = private.Refresh,
})
