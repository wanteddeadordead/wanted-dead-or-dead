-- Wanted: the zone HUD. In a campaign zone while wars are on, a small frame under the game's top-centre widgets: the
-- zone, who holds it (crest, guild in its side's colour, since when) or "Unclaimed", the protection left, what comes
-- next there (a race or a war) and the tax when the site gave one. It gives way to the race HUD and the war HUD, which
-- take over in their zone, and hides in instances. Off in Settings (Guild wars, Zone HUD), with its own size, and
-- dragged where the player wants it.

local _, Wanted = ...
local ZoneHUD = Wanted:NewModule("ZoneHUD")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local GuildWars = Wanted.GuildWars
local Races = Wanted.Races
local private = {}
local WIDTH, HEIGHT = 280, 112
-- The protection countdown moves by the minute
local MINUTE = 60
-- A race is "live now" this long after it starts (as on the Zones page)
local RACE_SECONDS = 45 * 60
local TAG_TIPS = {
	war = { "War", "A guild war: one guild attacks the zone's holder, 40 a side. Only the rosters take points." },
	race = { "Race", "An influence race: open to everyone in the zone, Horde v Alliance. Nothing is captured." },
}

function ZoneHUD:OnEnable()
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	frame:SetScript("OnEvent", function()
		-- The zone's map is known a moment after the event
		C_Timer.After(1, function() ZoneHUD:Update() end)
	end)
	C_Timer.NewTicker(MINUTE, Wanted:Timed("Zone HUD", function() ZoneHUD:Update() end))
	GuildWars:OnChange(function() ZoneHUD:Update() end)
	Races:OnChange(function() ZoneHUD:Update() end)
end

function private.Build()
	local f = CreateFrame("Frame", "WantedZoneHUD", UIParent)
	f:SetSize(WIDTH, HEIGHT)
	f:SetFrameStrata("LOW")
	f:SetClampedToScreen(true)
	Theme:Skin(f, { 0.067, 0.067, 0.067, 0.85 }, { 1, 1, 1, 0.15 })
	-- Dragged where the player wants it, kept for the account
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) self:StartMoving() end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relative, x, y = self:GetPoint(1)
		Wanted.db.settings.zoneHudPos = { point = point, relative = relative, x = x, y = y }
	end)
	private.Place(f)
	f.zone = Theme:Text(f, "heading", "", C.gold)
	f.zone:SetPoint("TOPLEFT", 10, -8)
	f.zone:SetWidth(WIDTH - 20 - 70)
	f.zone:SetWordWrap(false)
	f.tax = Theme:Text(f, "small", "", C.muted)
	f.tax:SetPoint("TOPRIGHT", -10, -10)
	f.tax:SetJustifyH("RIGHT")
	W:Explain(f.tax, "Tax", "The share of a war's winnings and the zone's income the holder's guild takes.", "ANCHOR_BOTTOM")
	f.crest = f:CreateTexture(nil, "ARTWORK")
	f.crest:SetSize(26, 26)
	f.crest:SetPoint("TOPLEFT", 10, -32)
	f.guild = Theme:Text(f, "body", "", C.text)
	f.guild:SetWidth(WIDTH - 20 - 34)
	f.guild:SetWordWrap(false)
	f.since = Theme:Text(f, "small", "", C.muted)
	f.since:SetWidth(WIDTH - 20 - 34)
	f.since:SetWordWrap(false)
	f.protection = Theme:Text(f, "small", "", C.text)
	f.protection:SetPoint("TOPLEFT", 10, -66)
	f.protection:SetWidth(WIDTH - 20)
	f.protection:SetWordWrap(false)
	-- The next race or war, with its tag on hover
	f.nextHit = CreateFrame("Frame", nil, f)
	f.nextHit:SetSize(WIDTH - 20, 16)
	f.nextHit:SetPoint("TOPLEFT", 10, -86)
	f.next = Theme:Text(f.nextHit, "small", "", C.text)
	f.next:SetPoint("LEFT")
	f.next:SetWidth(WIDTH - 20)
	f.next:SetWordWrap(false)
	f:Hide()
	private.frame = f
	return f
end

---Where the HUD goes: where the player dragged it, else under the game's top-centre widgets (the race HUD's place);
---at its size (Settings).
function private.Place(f)
	f:SetScale(Theme:ClampScale(Wanted.db.settings.zoneHudScale))
	f:ClearAllPoints()
	local pos = Wanted.db.settings.zoneHudPos
	if type(pos) == "table" and type(pos.point) == "string" and type(pos.x) == "number" and type(pos.y) == "number" then
		f:SetPoint(pos.point, UIParent, type(pos.relative) == "string" and pos.relative or pos.point, pos.x, pos.y)
	elseif UIWidgetTopCenterContainerFrame then
		f:SetPoint("TOP", UIWidgetTopCenterContainerFrame, "BOTTOM", 0, -4)
	else
		f:SetPoint("TOP", UIParent, "TOP", 0, -60)
	end
end

---Sizes the HUD (Settings), saved for the account; where it was dragged stays where it is.
---@param scale number 0.8 to 1.5
function ZoneHUD:SetScale(scale)
	scale = Theme:ClampScale(scale)
	Wanted.db.settings.zoneHudScale = scale
	local f = private.frame
	if not f then
		return
	end
	local pos = Wanted.db.settings.zoneHudPos
	if type(pos) == "table" then
		local x, y = Theme:RescaleInPlace(f, scale)
		if x then
			pos.x, pos.y = x, y
		end
	else
		private.Place(f)
	end
end

---"2d 4h", "5h", "40m".
function private.Span(seconds)
	local days, hours = floor(seconds / 86400), floor(seconds % 86400 / 3600)
	if days > 0 then
		return format("%dd %dh", days, hours)
	elseif hours > 0 then
		return format("%dh", hours)
	end
	return format("%dm", max(floor(seconds / 60), 1))
end

---"Race tonight 8:40 PM" (gold today), "War Tue 7:50 PM" (red today, else amber), "Live now" (green), and the kind.
---@return string text
---@return string? kind "war" or "race"
function private.Next(next_, now)
	if type(next_) ~= "table" then
		return "", nil
	end
	local kind = next_.kind == "war" and "war" or "race"
	local at = type(next_.at) == "number" and next_.at or nil
	if kind == "race" and at and now >= at and now < at + RACE_SECONDS then
		return Theme:Colorize("Live now", C.green), kind
	end
	local label = kind == "war" and "War" or "Race"
	local today = at and date("%Y-%m-%d", at) == date("%Y-%m-%d", now)
	local line = label..(at and " "..GuildWars:When(at, now) or kind == "war" and " soon" or "")
	if kind == "war" then
		return Theme:Colorize(line, today and C.red or C.amber), kind
	end
	return today and Theme:Colorize(line, C.gold) or line, kind
end

---The zone's catch-up row (GuildWars:Zones) for the campaign zone the player is in, with the zone's map data; nil
---outside a campaign zone, or when the site said nothing about it.
function private.Info()
	local _, _, _, mapId = Wanted.Recorder:GetPosition()
	local zone = mapId and Wanted.WarZones.byMap[mapId]
	if not zone then
		return nil
	end
	for _, z in ipairs(GuildWars:Zones()) do
		if type(z) == "table" and z.zone == zone.name then
			return z, zone, mapId
		end
	end
	return nil
end

---Whether the war HUD or the race HUD is showing here, as their own updates decide.
function private.TakenOver(now, mapId)
	local war = GuildWars:Here(now)
	if war and Wanted.db.settings.warHud ~= false then
		return true
	end
	local race = Races:Live(now)
	return race ~= nil and race.mapId == mapId
end

---Wakes the HUD when a war's prep or end, or a race's start or end, falls in this zone: the HUD gives way to theirs
---then, between the minute's ticks.
function private.Schedule(now, mapId)
	local edge
	local function Consider(t)
		if type(t) == "number" and t > now and (not edge or t < edge) then
			edge = t
		end
	end
	for _, war in ipairs(GuildWars:LiveWars()) do
		local known = Wanted.WarZones:Get(war.zone)
		if known and known.mapId == mapId and type(war.battle) == "table" then
			Consider(war.battle.prep)
			Consider(war.battle.stop)
		end
	end
	for _, race in ipairs(Races:Tonight()) do
		if race.mapId == mapId then
			Consider(race.start)
			Consider(race.stop)
		end
	end
	private.generation = (private.generation or 0) + 1
	if edge and edge - now < MINUTE then
		local generation = private.generation
		C_Timer.After(edge - now + 1, function()
			if generation == private.generation then
				ZoneHUD:Update()
			end
		end)
	end
end

---Shows the HUD in a campaign zone while wars are on; hides it otherwise.
function ZoneHUD:Update()
	local now = GetServerTime()
	local f = private.frame
	local info, _, mapId
	if Wanted.db.settings.zoneHud ~= false and GuildWars:On() and not IsInInstance() then
		info, _, mapId = private.Info()
	end
	if not info or private.TakenOver(now, mapId) then
		if f then
			f:Hide()
		end
		if info then
			private.Schedule(now, mapId)
		end
		return
	end
	private.Schedule(now, mapId)
	f = f or private.Build()
	local holder = type(info.holder) == "table" and type(info.holder.guild) == "string" and info.holder or nil
	f.zone:SetText(info.zone or "?")
	local tax = tonumber(info.tax)
	f.tax:SetText(tax and format("Tax %d%%", tax) or "")
	f.crest:SetShown(holder ~= nil)
	f.guild:ClearAllPoints()
	f.since:ClearAllPoints()
	if holder then
		f.crest:SetTexture(GuildWars:CrestFile(holder))
		f.guild:SetPoint("TOPLEFT", 42, -31)
		f.since:SetPoint("TOPLEFT", 42, -48)
		f.guild:SetText(holder.guild)
		local color = GuildWars.SIDE_COLORS[holder.faction] or C.text
		f.guild:SetTextColor(color[1], color[2], color[3])
		f.since:SetText(type(info.since) == "number" and "since "..GuildWars:Day(info.since) or "")
	else
		f.guild:SetPoint("TOPLEFT", 10, -37)
		f.since:SetPoint("TOPLEFT", 10, -48)
		f.guild:SetText("Unclaimed")
		f.guild:SetTextColor(C.faint[1], C.faint[2], C.faint[3])
		f.since:SetText("")
	end
	local protected = holder ~= nil and type(info.protectedUntil) == "number" and info.protectedUntil > now
	f.protection:SetText(protected and Theme:Colorize("Protected "..private.Span(info.protectedUntil - now), C.amber)
		or Theme:Colorize("Open to war", C.muted))
	W:Explain(f.protection, protected and "Protected" or "Open to war", protected
		and format("No war can be declared on this zone until %s.", date("%a ", info.protectedUntil)..GuildWars:Clock(info.protectedUntil))
		or "A guild on the other side can declare war here after winning a race.", "ANCHOR_BOTTOM")
	local line, kind = private.Next(info.next, now)
	f.next:SetText(line)
	f.nextHit:SetShown(kind ~= nil)
	if kind then
		W:Explain(f.nextHit, TAG_TIPS[kind][1], TAG_TIPS[kind][2], "ANCHOR_BOTTOM")
	end
	f:Show()
end
