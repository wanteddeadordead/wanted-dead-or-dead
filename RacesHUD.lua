-- Wanted: the race HUD. While an influence race is run in the player's zone (Races), a small frame under the game's
-- top-centre widgets: the RACE tag, the zone and the time left, each side's influence and the bar between them, the
-- three points in their holders' colours (the middle one +20%), and the player's own kills and minutes on the points.
-- Under it, why the player's presence on a point doesn't count, when it doesn't. Hidden outside a race's zone and time.

local _, Wanted = ...
local RacesHUD = Wanted:NewModule("RacesHUD")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Races = Wanted.Races
local HudKit = Wanted.HudKit
local private = {}
-- The points one under another, each the frame's width: the longest real names ("east of Dabyrie's Farmstead +20%")
-- didn't fit a third of it
local WIDTH, HEIGHT = 390, 136
local POINT_TOP, POINT_ROW = -60, 18
local UPDATE_SECONDS = 1
-- Kills are read from the activity, which costs more than the clock: every few seconds
local MINE_SECONDS = 5
local MEDIA = "Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\"
local SIDE_COLORS = { Horde = { 0.82, 0.24, 0.2 }, Alliance = { 0.24, 0.48, 0.92 } }

function RacesHUD:OnEnable()
	C_Timer.NewTicker(UPDATE_SECONDS, Wanted:Timed("Races HUD", function() RacesHUD:Update() end))
	Races:OnChange(function() RacesHUD:Update() end)
end

---Where the HUD goes without a place the player dragged it to: under the game's top-centre widgets.
function private.Place(f)
	if UIWidgetTopCenterContainerFrame then
		f:SetPoint("TOP", UIWidgetTopCenterContainerFrame, "BOTTOM", 0, -4)
	else
		f:SetPoint("TOP", UIParent, "TOP", 0, -60)
	end
end

HudKit:Register("race", { name = "Race HUD", setting = function() return Wanted.db.settings end, field = "raceHud",
	refresh = function() RacesHUD:Update() end, place = private.Place, collapsedWidth = 300 })

function private.Build()
	local f = CreateFrame("Frame", "WantedRaceHUD", UIParent)
	f:SetSize(WIDTH, HEIGHT)
	f:SetFrameStrata("LOW")
	Theme:Skin(f, { 0.067, 0.067, 0.067, 0.85 }, { 1, 1, 1, 0.15 })
	local body = HudKit:Body(f)
	f.kind = W:Pill(body)
	f.kind:SetPoint("TOPLEFT", 10, -8)
	f.kind:Set("RACE", C.muted)
	W:Explain(f.kind, "Race", "Open to everyone here. Influence only: nothing is captured.", "ANCHOR_BOTTOM")
	f.zone = Theme:Text(body, "heading", "", C.gold)
	f.zone:SetPoint("LEFT", f.kind, "RIGHT", 8, 0)
	f.left = Theme:Text(body, "stat", "")
	f.left:SetPoint("TOPRIGHT", -10, -6)
	f.left:SetJustifyH("RIGHT")
	f.horde = Theme:Text(body, "small", "")
	f.horde:SetPoint("TOPLEFT", 10, -34)
	f.alliance = Theme:Text(body, "small", "")
	f.alliance:SetPoint("TOPRIGHT", -10, -34)
	f.alliance:SetJustifyH("RIGHT")
	local bar = CreateFrame("Frame", nil, body)
	bar:SetPoint("TOPLEFT", 10, -50)
	bar:SetSize(WIDTH - 20, 4)
	bar.track = Theme:Fill(bar, { 1, 1, 1, 0.08 }, "BACKGROUND")
	for side, point in pairs({ Horde = "LEFT", Alliance = "RIGHT" }) do
		local fill = bar:CreateTexture(nil, "ARTWORK")
		fill:SetPoint("TOP"..point)
		fill:SetPoint("BOTTOM"..point)
		fill:SetColorTexture(SIDE_COLORS[side][1], SIDE_COLORS[side][2], SIDE_COLORS[side][3], 1)
		bar[side] = fill
	end
	f.bar = bar
	f.points = {}
	for i = 1, 3 do
		local p = CreateFrame("Frame", nil, body)
		p:SetSize(WIDTH - 20, 16)
		p:SetPoint("TOPLEFT", 10, POINT_TOP - (i - 1) * POINT_ROW)
		p.dot = p:CreateTexture(nil, "ARTWORK")
		p.dot:SetSize(10, 10)
		p.dot:SetPoint("LEFT")
		p.dot:SetTexture(MEDIA.."disc")
		p.name = Theme:Text(p, "small", "", C.text)
		p.name:SetPoint("LEFT", 14, 0)
		p.name:SetWidth(WIDTH - 20 - 14)
		p.name:SetWordWrap(false)
		f.points[i] = p
	end
	f.you = Theme:Text(body, "small", "", C.text)
	f.you:SetPoint("TOPLEFT", 10, POINT_TOP - 3 * POINT_ROW - 4)
	W:Explain(f.you, "You", "Your kills on the other faction here while the race runs, and your minutes on its points, as this client counted them.", "ANCHOR_BOTTOM")
	-- Why the player's presence on a point doesn't count (Captures:Blocked), under the frame
	f.blocked = Theme:Text(body, "small", "", C.amber)
	f.blocked:SetPoint("TOP", f, "BOTTOM", 0, -4)
	HudKit:Attach("race", f)
	f:Hide()
	private.frame = f
	return f
end

---1,342: thousands apart, as the Guild Wars page shows them.
function private.Count(n)
	return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
end

---Players of our side here with the player: themselves and the group members the game says are in range.
function private.FriendsNear()
	local friends = 1
	local raid = IsInRaid and IsInRaid()
	local count = GetNumGroupMembers and GetNumGroupMembers() or 0
	for i = 1, raid and count or max(count - 1, 0) do
		local unit = (raid and "raid" or "party")..i
		local ok, inRange = pcall(UnitInRange, unit)
		if ok and inRange == true and not (issecretvalue and issecretvalue(inRange)) and not UnitIsUnit(unit, "player") then
			friends = friends + 1
		end
	end
	return friends
end

---Who holds the point the player stands on, as the player sees it now: the side with more players here (enemies on
---the Nearby list against our side in range), or nil when they're even.
function private.LocalHolder()
	local enemies = Wanted.Enemies:CountNearby()
	local friends = private.FriendsNear()
	local side = UnitFactionGroup("player")
	local other = side == "Horde" and "Alliance" or "Horde"
	return friends > enemies and side or enemies > friends and other or nil, friends, enemies
end

---Shows the HUD while a race is run in the player's zone, with its numbers; hides it otherwise.
function RacesHUD:Update()
	local now = GetServerTime()
	local race = Races:Live(now)
	local _, _, _, mapId = Wanted.Recorder:GetPosition()
	local f = private.frame
	if not race or mapId ~= race.mapId or Wanted.db.settings.raceHud == false then
		if f then
			f:Hide()
		end
		return
	end
	f = f or private.Build()
	local left = max(race.stop - now, 0)
	f.zone:SetText(race.zone)
	f.left:SetText(format("%d:%02d", floor(left / 60), left % 60)..Theme:Colorize(" left", C.muted))
	-- The site's numbers, or our side's live estimate when it's more (Races:SideInfluence)
	local horde, hordeLive = Races:SideInfluence(race, "Horde")
	local alliance, allianceLive = Races:SideInfluence(race, "Alliance")
	local hordeText = Theme:Colorize("Horde "..private.Count(horde), SIDE_COLORS.Horde)..(hordeLive and Theme:Colorize(" live", C.green) or "")
	local allianceText = (allianceLive and Theme:Colorize("live ", C.green) or "")..Theme:Colorize("Alliance "..private.Count(alliance), SIDE_COLORS.Alliance)
	f.horde:SetText(hordeText)
	f.alliance:SetText(allianceText)
	f.summary:SetText(format("%d:%02d", floor(left / 60), left % 60)..Theme:Colorize(" left", C.muted).."  ·  "..hordeText.."  ·  "..allianceText)
	local total = horde + alliance
	for _, side in ipairs({ "Horde", "Alliance" }) do
		local n = side == "Horde" and horde or alliance
		f.bar[side]:SetShown(total > 0)
		f.bar[side]:SetWidth(total > 0 and max((WIDTH - 20) * n / total, 1) or 1)
	end
	local here = Races:Current()
	for i, p in ipairs(f.points) do
		local point = race.points[i]
		p:SetShown(point ~= nil)
		if point then
			-- The point the player stands on: by who's here now; the others by the site's last count
			local holder, now_ = point.holder, ""
			if point == here then
				local seen, friends, enemies = private.LocalHolder()
				holder = seen or holder
				now_ = format("\n\nHere now: %d of your side, %d %s nearby.", friends, enemies, enemies == 1 and "enemy" or "enemies")
			elseif Races:HereNow(point) > 0 then
				now_ = format("\n\nHere now: %d of your side's Wanted players.", Races:HereNow(point))
			end
			local color = SIDE_COLORS[holder] or C.faint
			p.dot:SetVertexColor(color[1], color[2], color[3], 1)
			p.name:SetText(point.name..(point.bonus and Theme:Colorize(" +20%", C.gold) or ""))
			W:Explain(p, point.name, (point.holder and ("The site last counted it held by the "..point.holder..".") or "Nobody has held it yet.")
				..(point.bonus and " The middle point: a minute here counts +20%." or "")..now_, "ANCHOR_RIGHT")
		end
	end
	if not private.mineAt or now - private.mineAt >= MINE_SECONDS or private.mineRace ~= race then
		private.mineAt, private.mineRace = now, race
		private.kills, private.minutes = Races:Mine(race)
	end
	f.you:SetText(format("You  ·  %d kill%s  ·  %d min", private.kills, private.kills == 1 and "" or "s", private.minutes))
	local point, blocked = Races:Current()
	f.blocked:SetText(point and blocked and format("Not counted on %s: %s", point.name, strlower(blocked)) or "")
	HudKit:Apply("race", f, WIDTH, HEIGHT)
	f:Show()
end
