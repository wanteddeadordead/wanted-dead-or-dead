-- Wanted: the zone banner. Coming into a campaign zone (WarZones), once each time and out of combat, a line under the
-- game's own zone text: the holder's emblem and "Held by <guild>" in its side's colour (or "Unclaimed"), and under it
-- the war on now, the protection left, or the next war. Nothing when the site has said nothing about the zone. Off in
-- Settings (Guild wars, Zone banner).

local _, Wanted = ...
local WarBanner = Wanted:NewModule("WarBanner")
local Theme = Wanted.Theme
local C = Theme.C
local GuildWars = Wanted.GuildWars
local private = {}
local HOLD, FADE = 6, 1.5
local COLORS = { Horde = { 0.82, 0.24, 0.2 }, Alliance = { 0.24, 0.48, 0.92 } }

function WarBanner:OnEnable()
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	frame:RegisterEvent("PLAYER_REGEN_ENABLED")
	frame:SetScript("OnEvent", function(_, event)
		-- The zone's map is known a moment after the event
		C_Timer.After(event == "PLAYER_REGEN_ENABLED" and 0 or 1, function() WarBanner:Check() end)
	end)
end

---Shows the banner when the player has come into a campaign zone since the last one, out of combat.
function WarBanner:Check()
	local _, _, _, mapId = Wanted.Recorder:GetPosition()
	local zone = mapId and Wanted.WarZones.byMap[mapId]
	if not zone then
		private.shownFor = nil
		return
	end
	if private.shownFor == zone or Wanted.db.settings.warBanner == false or InCombatLockdown() then
		return
	end
	local title, line = WarBanner:Lines(zone, GetServerTime())
	if not title then
		return
	end
	private.shownFor = zone
	private.Show(zone, title, line)
end

---The banner's lines for a zone: "Held by <guild>" (or "Unclaimed"), and the war now, the protection left or the next
---war; nil when the site said nothing about it.
---@return string? title
---@return string? line
---@return table? holder
function WarBanner:Lines(zone, now)
	if not GuildWars:On() then
		return nil
	end
	local info
	for _, z in ipairs(GuildWars:Zones()) do
		if z.zone == zone.name then
			info = z
		end
	end
	if not info then
		return nil
	end
	local holder = info.holder
	local title = holder and holder.guild and ("Held by <"..holder.guild..">") or "Unclaimed"
	local war = GuildWars:Here(now)
	local line
	if war and war.zone == zone.name then
		local b = war.battle
		line = Theme:Colorize(now < b.start and format("Guild war: %s attacks, prep, battle in %s", war.attacker.guild or "?", private.Left(b.start - now))
			or format("Guild war now: %s attacks, %s left", war.attacker.guild or "?", private.Left(b.stop - now)), C.red)
	elseif type(info.protectedUntil) == "number" and info.protectedUntil > now then
		line = "Protected "..private.Span(info.protectedUntil - now)
	elseif type(info.next) == "table" and info.next.kind == "war" then
		line = Theme:Colorize("Guild war "..(type(info.next.at) == "number" and GuildWars:When(info.next.at, now) or "soon"), C.amber)
	end
	return title, line, holder
end

---"18:42".
function private.Left(seconds)
	seconds = max(floor(seconds), 0)
	return format("%d:%02d", floor(seconds / 60), seconds % 60)
end

---"2d 14h", "5h", "40m".
function private.Span(seconds)
	local days, hours = floor(seconds / 86400), floor(seconds % 86400 / 3600)
	if days > 0 then
		return format("%dd %dh", days, hours)
	elseif hours > 0 then
		return format("%dh", hours)
	end
	return format("%dm", max(floor(seconds / 60), 1))
end

function private.Build()
	local f = CreateFrame("Frame", "WantedWarBanner", UIParent)
	f:SetSize(420, 60)
	f:SetFrameStrata("MEDIUM")
	f:EnableMouse(false)
	-- Under the game's zone text ("Hillsbrad Foothills / (Contested Territory)")
	local under = PVPInfoTextString or SubZoneTextString or ZoneTextString
	if under then
		f:SetPoint("TOP", under, "BOTTOM", 0, -6)
	else
		f:SetPoint("TOP", UIParent, "TOP", 0, -250)
	end
	f.crest = f:CreateTexture(nil, "ARTWORK")
	f.crest:SetSize(36, 36)
	f.title = Theme:Text(f, "title", "")
	f.title:SetPoint("TOP", 20, 0)
	f.title:SetShadowColor(0, 0, 0, 1)
	f.title:SetShadowOffset(1, -1)
	f.crest:SetPoint("RIGHT", f.title, "LEFT", -8, 0)
	f.line = Theme:Text(f, "body", "", C.text)
	f.line:SetPoint("TOP", f.title, "BOTTOM", 0, -4)
	f.line:SetShadowColor(0, 0, 0, 1)
	f.line:SetShadowOffset(1, -1)
	-- Shown for a while, then faded out
	f:SetScript("OnUpdate", function(self, dt)
		self.age = (self.age or 0) + dt
		if self.age > HOLD + FADE then
			self:Hide()
		elseif self.age > HOLD then
			self:SetAlpha(1 - (self.age - HOLD) / FADE)
		end
	end)
	f:Hide()
	private.frame = f
	return f
end

function private.Show(zone, title, line)
	local f = private.frame or private.Build()
	local _, _, holder = WarBanner:Lines(zone, GetServerTime())
	f.crest:SetShown(holder ~= nil and holder.guild ~= nil)
	if holder and holder.guild then
		f.crest:SetTexture(GuildWars:CrestFile(holder))
	end
	local color = holder and COLORS[holder.faction] or C.text
	f.title:SetText(title)
	f.title:SetTextColor(color[1], color[2], color[3])
	f.line:SetText(line or "")
	f.age = 0
	f:SetAlpha(1)
	f:Show()
end
