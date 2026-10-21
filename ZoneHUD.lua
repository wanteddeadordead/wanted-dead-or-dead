-- Wanted: the zone HUD. In a campaign zone while wars are on, a small frame under the game's top-centre widgets: the
-- zone, who holds it (crest, guild in its side's colour, since when) or "Unclaimed", the protection left, and what
-- comes next there (a race or a war). It gives way to the race HUD and the war HUD, which
-- take over in their zone, and hides in instances. Off in Settings (Guild wars, Zone HUD), with its own size; dragged,
-- folded and hidden as the other HUDs are (HudKit).

local _, Wanted = ...
local ZoneHUD = Wanted:NewModule("ZoneHUD")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local GuildWars = Wanted.GuildWars
local Races = Wanted.Races
local HudKit = Wanted.HudKit
local private = {}
local WIDTH, HEIGHT = 280, 112
-- The protection countdown moves by the minute
local MINUTE = 60

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

function private.Build(sample)
	local f = CreateFrame("Frame", sample and "WantedZoneHUDSample" or "WantedZoneHUD", UIParent)
	f:SetSize(WIDTH, HEIGHT)
	f:SetFrameStrata("LOW")
	Theme:Skin(f, { 0.067, 0.067, 0.067, 0.85 }, { 1, 1, 1, 0.15 })
	local body = HudKit:Body(f)
	f.zone = Theme:Text(body, "heading", "", C.gold)
	f.zone:SetPoint("TOPLEFT", 10, -8)
	f.zone:SetWidth(WIDTH - 20)
	f.zone:SetWordWrap(false)
	f.crest = GuildWars:NewCrest(body)
	f.crest:SetSize(26, 26)
	f.crest:SetPoint("TOPLEFT", 10, -32)
	f.guild = Theme:Text(body, "body", "", C.text)
	f.guild:SetWidth(WIDTH - 20 - 34)
	f.guild:SetWordWrap(false)
	f.since = Theme:Text(body, "small", "", C.muted)
	f.since:SetWidth(WIDTH - 20 - 34)
	f.since:SetWordWrap(false)
	f.protection = Theme:Text(body, "small", "", C.text)
	f.protection:SetPoint("TOPLEFT", 10, -66)
	f.protection:SetWidth(WIDTH - 20)
	f.protection:SetWordWrap(false)
	-- The next race or war, with its tag on hover
	f.nextHit = CreateFrame("Frame", nil, body)
	f.nextHit:SetSize(WIDTH - 20, 16)
	f.nextHit:SetPoint("TOPLEFT", 10, -86)
	f.next = Theme:Text(f.nextHit, "small", "", C.text)
	f.next:SetPoint("LEFT")
	f.next:SetWidth(WIDTH - 20)
	f.next:SetWordWrap(false)
	-- The tour's sample copy (ShowSample) is not registered with the kit: no grip, fold or close, no saved place or size,
	-- and it takes no clicks
	if sample then
		f:EnableMouse(false)
		f.summary = Theme:Text(f, "small", "")
		f.summary:Hide()
		private.Place(f)
	else
		f:SetScale(Theme:ClampScale(Wanted.db.settings.zoneHudScale))
		HudKit:Attach("zone", f)
	end
	f:Hide()
	if sample then
		private.sample = f
	else
		private.frame = f
	end
	return f
end

---Where the HUD goes without a place the player dragged it to: under the game's top-centre widgets (the race HUD's place).
function private.Place(f)
	if UIWidgetTopCenterContainerFrame then
		f:SetPoint("TOP", UIWidgetTopCenterContainerFrame, "BOTTOM", 0, -4)
	else
		f:SetPoint("TOP", UIParent, "TOP", 0, -60)
	end
end

HudKit:Register("zone", { name = "Zone HUD", setting = function() return Wanted.db.settings end, field = "zoneHud",
	refresh = function() ZoneHUD:Update() end, place = private.Place, collapsedWidth = 220 })

---Sizes the HUD (Settings), saved for the account; where it was dragged stays where it is.
---@param scale number 0.8 to 1.5
function ZoneHUD:SetScale(scale)
	scale = Theme:ClampScale(scale)
	Wanted.db.settings.zoneHudScale = scale
	if private.frame then
		HudKit:Rescale("zone", private.frame, scale)
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

---"Race tonight 8:40 PM", "War Tue 7:50 PM" or "Live now": the Zones page's wording (PageWarZones), the kind named first.
---@return string text
---@return string? kind "war" or "race"
function private.Next(next_, now)
	local line, kind, live = Wanted.WarZoneText.Next(next_, now)
	if not kind then
		return "", nil
	elseif live then
		return (gsub(line, "live now", "Live now")), kind
	end
	return (kind == "war" and "War" or "Race")..(line ~= "" and " "..line or ""), kind
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
	private.Draw(f, info, now)
end

---A sample copy of the HUD for the tour (WarSample.lua), for a zone row of the sample (GuildWars.Page:Zones): its own
---frame, nothing about it saved or reported. Hidden by HideSample.
---@param info table
function ZoneHUD:ShowSample(info)
	private.Draw(private.sample or private.Build(true), info, GetServerTime(), true)
end

function ZoneHUD:HideSample()
	if private.sample then
		private.sample:Hide()
	end
end

---Draws a zone row on a HUD frame; sample: the tour's, which says so.
function private.Draw(f, info, now, sample)
	local holder = type(info.holder) == "table" and type(info.holder.guild) == "string" and info.holder or nil
	f.zone:SetText((sample and "SAMPLE · " or "")..(info.zone or "?"))
	f.crest:SetShown(holder ~= nil)
	f.guild:ClearAllPoints()
	f.since:ClearAllPoints()
	if holder then
		f.crest:SetGuild(holder)
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
	if protected then
		f.protection:SetText(Theme:Colorize("Protected "..private.Span(info.protectedUntil - now), C.amber))
		W:Explain(f.protection, "Protected", format("No war can be declared on this zone until %s.",
			date("%a ", info.protectedUntil)..GuildWars:Clock(info.protectedUntil)), "ANCHOR_BOTTOM")
	elseif holder then
		f.protection:SetText(Theme:Colorize("Open to war", C.muted))
		W:Explain(f.protection, "Open to war", "A guild on the other side can declare war here after winning a race.", "ANCHOR_BOTTOM")
	else
		f.protection:SetText(Theme:Colorize("Open to claim", C.muted))
		W:Explain(f.protection, "Open to claim", "Any guild, Horde or Alliance, can claim it. The top guild in a race here "
			.."takes it with no war, and no war can be declared on it for 3 days.", "ANCHOR_BOTTOM")
	end
	local line, kind = private.Next(info.next, now)
	f.next:SetText(line)
	f.nextHit:SetShown(kind ~= nil)
	if kind then
		local tip = Wanted.WarZoneText.TAG_TIPS[kind]
		W:Explain(f.nextHit, tip[1], tip[2], "ANCHOR_BOTTOM")
	end
	f.summary:SetText(info.zone.."  ·  "..(holder and Theme:Colorize(holder.guild, GuildWars.SIDE_COLORS[holder.faction] or C.text) or Theme:Colorize("Unclaimed", C.faint)))
	if sample then
		f.body:Show()
		f:SetSize(WIDTH, HEIGHT)
	else
		HudKit:Apply("zone", f, WIDTH, HEIGHT)
	end
	f:Show()
end
