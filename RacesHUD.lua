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
local private = {}
local WIDTH, HEIGHT = 390, 100
local UPDATE_SECONDS = 1
-- Kills are read from the activity, which costs more than the clock: every few seconds
local MINE_SECONDS = 5
local MEDIA = "Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\"
local SIDE_COLORS = { Horde = { 0.82, 0.24, 0.2 }, Alliance = { 0.24, 0.48, 0.92 } }

function RacesHUD:OnEnable()
	C_Timer.NewTicker(UPDATE_SECONDS, Wanted:Timed("Races HUD", function() RacesHUD:Update() end))
	Races:OnChange(function() RacesHUD:Update() end)
end

function private.Build()
	local f = CreateFrame("Frame", "WantedRaceHUD", UIParent)
	f:SetSize(WIDTH, HEIGHT)
	f:SetFrameStrata("LOW")
	Theme:Skin(f, { 0.067, 0.067, 0.067, 0.85 }, { 1, 1, 1, 0.15 })
	if UIWidgetTopCenterContainerFrame then
		f:SetPoint("TOP", UIWidgetTopCenterContainerFrame, "BOTTOM", 0, -4)
	else
		f:SetPoint("TOP", UIParent, "TOP", 0, -60)
	end
	f.kind = W:Pill(f)
	f.kind:SetPoint("TOPLEFT", 10, -8)
	f.kind:Set("RACE", C.muted)
	W:Explain(f.kind, "Race", "Open to everyone here. Influence only: nothing is captured.", "ANCHOR_BOTTOM")
	f.zone = Theme:Text(f, "heading", "", C.gold)
	f.zone:SetPoint("LEFT", f.kind, "RIGHT", 8, 0)
	f.left = Theme:Text(f, "stat", "")
	f.left:SetPoint("TOPRIGHT", -10, -6)
	f.left:SetJustifyH("RIGHT")
	f.horde = Theme:Text(f, "small", "")
	f.horde:SetPoint("TOPLEFT", 10, -34)
	f.alliance = Theme:Text(f, "small", "")
	f.alliance:SetPoint("TOPRIGHT", -10, -34)
	f.alliance:SetJustifyH("RIGHT")
	local bar = CreateFrame("Frame", nil, f)
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
	local column = floor((WIDTH - 20) / 3)
	for i = 1, 3 do
		local p = CreateFrame("Frame", nil, f)
		p:SetSize(column, 16)
		p:SetPoint("TOPLEFT", 10 + (i - 1) * column, -60)
		p.dot = p:CreateTexture(nil, "ARTWORK")
		p.dot:SetSize(10, 10)
		p.dot:SetPoint("LEFT")
		p.dot:SetTexture(MEDIA.."disc")
		p.name = Theme:Text(p, "small", "", C.text)
		p.name:SetPoint("LEFT", 14, 0)
		p.name:SetWidth(column - 18)
		p.name:SetWordWrap(false)
		f.points[i] = p
	end
	f.you = Theme:Text(f, "small", "", C.text)
	f.you:SetPoint("TOPLEFT", 10, -80)
	W:Explain(f.you, "You", "Your kills on the other faction here while the race runs, and your minutes on its points, as this client counted them.", "ANCHOR_BOTTOM")
	-- Why the player's presence on a point doesn't count (Captures:Blocked), under the frame
	f.blocked = Theme:Text(f, "small", "", C.amber)
	f.blocked:SetPoint("TOP", f, "BOTTOM", 0, -4)
	f:Hide()
	private.frame = f
	return f
end

---Shows the HUD while a race is run in the player's zone, with its numbers; hides it otherwise.
function RacesHUD:Update()
	local now = GetServerTime()
	local race = Races:Live(now)
	local _, _, _, mapId = Wanted.Recorder:GetPosition()
	local f = private.frame
	if not race or mapId ~= race.mapId then
		if f then
			f:Hide()
		end
		return
	end
	f = f or private.Build()
	local left = max(race.stop - now, 0)
	f.zone:SetText(race.zone)
	f.left:SetText(format("%d:%02d", floor(left / 60), left % 60)..Theme:Colorize(" left", C.muted))
	f.horde:SetText(Theme:Colorize("Horde "..race.horde, SIDE_COLORS.Horde))
	f.alliance:SetText(Theme:Colorize("Alliance "..race.alliance, SIDE_COLORS.Alliance))
	local total = race.horde + race.alliance
	for _, side in ipairs({ "Horde", "Alliance" }) do
		local n = side == "Horde" and race.horde or race.alliance
		f.bar[side]:SetShown(total > 0)
		f.bar[side]:SetWidth(total > 0 and max((WIDTH - 20) * n / total, 1) or 1)
	end
	for i, p in ipairs(f.points) do
		local point = race.points[i]
		p:SetShown(point ~= nil)
		if point then
			local color = SIDE_COLORS[point.holder] or C.faint
			p.dot:SetVertexColor(color[1], color[2], color[3], 1)
			p.name:SetText(point.name..(point.bonus and Theme:Colorize(" +20%", C.gold) or ""))
			W:Explain(p, point.name, (point.holder and ("Held by the "..point.holder..".") or "Nobody has held it yet.")
				..(point.bonus and " The middle point: a minute here counts +20%." or ""), "ANCHOR_BOTTOM")
		end
	end
	if not private.mineAt or now - private.mineAt >= MINE_SECONDS or private.mineRace ~= race then
		private.mineAt, private.mineRace = now, race
		private.kills, private.minutes = Races:Mine(race)
	end
	f.you:SetText(format("You  ·  %d kill%s  ·  %d min", private.kills, private.kills == 1 and "" or "s", private.minutes))
	local point, blocked = Races:Current()
	f.blocked:SetText(point and blocked and format("Not counted on %s: %s", point.name, strlower(blocked)) or "")
	f:Show()
end
