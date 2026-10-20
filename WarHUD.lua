-- Wanted: the war HUD. In the zone of one of the guild's wars, from prep to its end, a frame under the game's top-centre
-- widgets: both guilds' crests and their roster players here (with the outnumbered bonus when a side has it), the
-- clock (to the battle in prep, then the battle's time left), and the lanes as a strip: the attackers' rally, each
-- lane's tower and inhibitor, the keep. Under it, the friends here (on neither roster), the point the player stands
-- on with its capture bar, and why the player doesn't count when they don't. The state is the site's last count
-- (the catch-up's warLive), provisional; with none, only the clock. Hidden by the Battle step's Hide the HUD
-- (db.settings.warHud), and dragged where the player wants it.

local _, Wanted = ...
local WarHUD = Wanted:NewModule("WarHUD")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local GuildWars = Wanted.GuildWars
local HudKit = Wanted.HudKit
local private = {}
local WIDTH, HEIGHT = 440, 132
local LANES = { { "top", "Top" }, { "mid", "Mid" }, { "bot", "Bot" } }
local STRIP_TOP, LANE_ROW = -66, 26
local RALLY_X, TOWER_X, INHIB_X, KEEP_X = 70, 130, 270, 400
local SIDE = { Horde = "horde", Alliance = "alliance" }
local RED = { 0.9, 0.3, 0.25 }

function WarHUD:OnEnable()
	C_Timer.NewTicker(1, Wanted:Timed("War HUD", function() WarHUD:Update() end))
	GuildWars:OnChange(function() WarHUD:Update() end)
end

-- The Battle step's Show/Hide the HUD
function GuildWars:UpdateHUD()
	WarHUD:Update()
end

---A seal: its texture and size.
function private.Seal(parent, size)
	local seal = parent:CreateTexture(nil, "ARTWORK")
	seal:SetSize(size, size)
	return seal
end

---A line between two places on the frame (x right, y down from its top left).
function private.Line(f, x1, y1, x2, y2)
	local line = f:CreateLine(nil, "BORDER")
	line:SetThickness(2)
	line:SetColorTexture(1, 1, 1, 0.18)
	line:SetStartPoint("TOPLEFT", f, x1, y1)
	line:SetEndPoint("TOPLEFT", f, x2, y2)
	return line
end

---One guild's corner: its crest, name and roster players here.
function private.Side(f, right)
	local side = {}
	local anchor, sign = right and "TOPRIGHT" or "TOPLEFT", right and -1 or 1
	side.crest = GuildWars:NewCrest(f)
	side.crest:SetSize(30, 30)
	side.crest:SetPoint(anchor, 10 * sign, -8)
	side.name = Theme:Text(f, "heading", "")
	side.name:SetPoint(anchor, 46 * sign, -9)
	side.name:SetWidth(120)
	side.name:SetWordWrap(false)
	side.name:SetJustifyH(right and "RIGHT" or "LEFT")
	side.count = Theme:Text(f, "small", "", C.text)
	side.count:SetPoint(anchor, 46 * sign, -28)
	side.count:SetJustifyH(right and "RIGHT" or "LEFT")
	W:Explain(side.count, "Roster players here", "Roster players here / 40. Only the two rosters take and hold points.", "ANCHOR_BOTTOM")
	return side
end

function private.Build(sample)
	local f = CreateFrame("Frame", sample and "WantedWarHUDSample" or "WantedWarHUD", UIParent)
	f:SetSize(WIDTH, HEIGHT)
	f:SetFrameStrata("LOW")
	f:SetClampedToScreen(true)
	Theme:Skin(f, { 0.067, 0.067, 0.067, 0.88 }, { 1, 1, 1, 0.15 })
	local body = HudKit:Body(f)
	f.attacker = private.Side(body, false)
	f.defender = private.Side(body, true)
	f.clock = Theme:Text(body, "stat", "", C.text)
	f.clock:SetPoint("TOP", 0, -8)
	f.kind = Theme:Text(body, "tiny", "", RED)
	f.kind:SetPoint("TOP", 0, -32)
	local divider = body:CreateTexture(nil, "BORDER")
	divider:SetColorTexture(1, 1, 1, 0.08)
	divider:SetSize(WIDTH - 20, 1)
	divider:SetPoint("TOP", 0, -48)
	-- The strip: the rally, three lanes of a tower and an inhibitor, the keep
	local middle = STRIP_TOP - LANE_ROW
	f.rally = private.Seal(body, 24)
	f.rally:SetPoint("CENTER", f, "TOPLEFT", RALLY_X, middle)
	f.keep = private.Seal(body, 34)
	f.keep:SetPoint("CENTER", f, "TOPLEFT", KEEP_X, middle)
	f.keepHit = CreateFrame("Frame", nil, body)
	f.keepHit:SetSize(34, 34)
	f.keepHit:SetPoint("CENTER", f.keep)
	f.lanes = {}
	for i, lane in ipairs(LANES) do
		local y = STRIP_TOP - (i - 1) * LANE_ROW
		private.Line(body, RALLY_X + 12, middle, TOWER_X - 10, y)
		private.Line(body, TOWER_X + 10, y, INHIB_X - 10, y)
		private.Line(body, INHIB_X + 10, y, KEEP_X - 17, middle)
		local row = { id = lane[1] }
		row.label = Theme:Text(body, "small", lane[2], C.muted)
		-- Left of the rally, clear of the lanes' lines
		row.label:SetPoint("RIGHT", f, "TOPLEFT", RALLY_X - 18, y)
		row.tower = private.Seal(body, 20)
		row.tower:SetPoint("CENTER", f, "TOPLEFT", TOWER_X, y)
		row.inhibitor = private.Seal(body, 20)
		row.inhibitor:SetPoint("CENTER", f, "TOPLEFT", INHIB_X, y)
		row.pct = Theme:Text(body, "tiny", "", C.gold)
		-- Above the line out of the seal, not on it
		row.pct:SetPoint("BOTTOMLEFT", f, "TOPLEFT", TOWER_X + 12, y + 3)
		row.inhibPct = Theme:Text(body, "tiny", "", C.gold)
		row.inhibPct:SetPoint("BOTTOMLEFT", f, "TOPLEFT", INHIB_X + 12, y + 3)
		f.lanes[i] = row
	end
	-- Under the frame: the friends here, the point the player stands on, and why they don't count
	local friends = CreateFrame("Frame", nil, body)
	friends:SetSize(130, 20)
	friends:SetPoint("TOP", f, "BOTTOM", 0, -4)
	Theme:Skin(friends, { 0.067, 0.067, 0.067, 0.88 }, { 1, 1, 1, 0.15 })
	friends.text = Theme:Text(friends, "small", "", C.text)
	friends.text:SetPoint("CENTER")
	f.friends = friends
	local bar = CreateFrame("StatusBar", nil, body)
	bar:SetSize(240, 10)
	bar:SetPoint("TOP", friends, "BOTTOM", 0, -18)
	bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	bar:SetStatusBarColor(C.gold[1], C.gold[2], C.gold[3], 1)
	bar:SetMinMaxValues(0, 1)
	bar.track = Theme:Fill(bar, { 1, 1, 1, 0.08 }, "BACKGROUND")
	bar.label = Theme:Text(bar, "small", "", C.text)
	bar.label:SetPoint("BOTTOM", bar, "TOP", 0, 3)
	bar.pct = Theme:Text(bar, "small", "", C.gold)
	bar.pct:SetPoint("LEFT", bar, "RIGHT", 6, 0)
	W:Explain(bar, "Capture", "Net count here (yours minus theirs, up to 6); progress is kept if you leave.", "ANCHOR_BOTTOM")
	f.bar = bar
	f.status = Theme:Text(body, "small", "", C.amber)
	-- The tour's sample copy (ShowSample) is its own frame: not registered with the kit, so it has no grip, fold or close
	-- and no saved place, and it takes no clicks
	if sample then
		f:EnableMouse(false)
		f.summary = Theme:Text(f, "small", "")
		f.summary:Hide()
		private.Place(f)
	else
		HudKit:Attach("war", f)
	end
	f:Hide()
	if sample then
		private.sample = f
	else
		private.frame = f
	end
	return f
end

---Where the HUD goes without a place the player dragged it to: under the game's top-centre widgets (the race HUD's place:
---a race and a war are never in one zone at once).
function private.Place(f)
	if UIWidgetTopCenterContainerFrame then
		f:SetPoint("TOP", UIWidgetTopCenterContainerFrame, "BOTTOM", 0, -4)
	else
		f:SetPoint("TOP", UIParent, "TOP", 0, -60)
	end
end

HudKit:Register("war", { name = "War HUD", setting = function() return Wanted.db.settings end, field = "warHud",
	refresh = function() WarHUD:Update() end, place = private.Place, collapsedWidth = 300 })

---A point's capture: the site's percent, or the live estimate (WarLive) marked live when it's further on; nil for
---none or a point taken.
---@return string?
function private.Pct(state, estimate)
	if state.state == "taken" then
		return nil
	elseif estimate and estimate > (state.pct or 0) then
		return format("%d%%", estimate)..Theme:Colorize(" live", C.green)
	end
	return state.state == "taking" and format("%d%%", state.pct or 0) or nil
end

---"12:40": minutes and seconds.
function private.Clock(seconds)
	seconds = max(floor(seconds), 0)
	return format("%d:%02d", floor(seconds / 60), seconds % 60)
end

---Shows the HUD in the zone of a war of the guild's, from prep to its end; hides it otherwise.
function WarHUD:Update()
	local now = GetServerTime()
	local war, zone, x, y, mapId = GuildWars:Here(now)
	local f = private.frame
	if not war or Wanted.db.settings.warHud == false then
		if f then
			f:Hide()
		end
		return
	end
	f = f or private.Build()
	private.Draw(f, war, zone, x, y, mapId, now)
end

---A sample copy of the HUD for the tour (WarSample.lua): its own frame, drawn from the sample war, no place on the
---map, and nothing about it reaches the game's log, the messages or saved data. Hidden by HideSample.
---@param war table the sample war (GuildWars.Page:War)
function WarHUD:ShowSample(war)
	local zone = Wanted.WarZones:Get(war.zone)
	if not zone or type(war.battle) ~= "table" or not war.battle.start then
		return
	end
	local f = private.sample or private.Build(true)
	private.Draw(f, war, zone, nil, nil, nil, GetServerTime(), true)
end

function WarHUD:HideSample()
	if private.sample then
		private.sample:Hide()
	end
end

---Draws a war on a HUD frame; sample: the tour's, which says so and has the player on the roster.
function private.Draw(f, war, zone, x, y, mapId, now, sample)
	local b = war.battle
	local attacker, defender = war.attacker or {}, war.defender or {}
	local d, a = SIDE[defender.faction] or "alliance", SIDE[attacker.faction] or "horde"
	local prep = now < b.start
	-- The clock: to the battle in prep, then the battle's time left
	f.clock:SetText(prep and ("Prep "..private.Clock(b.start - now)) or private.Clock(b.stop - now))
	f.kind:SetText((sample and "SAMPLE · " or "")..(prep and "GUILD WAR · PREP" or "GUILD WAR"))
	-- The guilds: roster players here, and the outnumbered bonus when a side has it
	local turnout, mult = b.turnout or {}, b.mult or {}
	for _, key in ipairs({ "attacker", "defender" }) do
		local side, guild = f[key], key == "attacker" and attacker or defender
		side.crest:SetGuild(guild)
		-- Another guild's war: the holders by name, the attackers by their side
		side.name:SetText(guild.guild or guild.faction or "?")
		local color = GuildWars.SIDE_COLORS[guild.faction] or C.text
		side.name:SetTextColor(color[1], color[2], color[3])
		local bonus = tonumber(mult[key])
		-- Our side's members heard in game, marked live, when it isn't what the site last said
		local ourKey = war.role == "attack" and "attacker" or "defender"
		local live = key == ourKey and tonumber(b.liveTurnout) or nil
		side.count:SetText(format("%d / %d", tonumber(turnout[key]) or 0, GuildWars.MAX_ROSTER)
			..(live and live ~= tonumber(turnout[key]) and Theme:Colorize(format(" · %d live", live), C.green) or "")
			..(bonus and bonus > 1.005 and Theme:Colorize(format("  ×%.2f", bonus), C.gold) or ""))
		W:Explain(side.count, "Roster players here", "Roster players here / 40."..(bonus and bonus > 1.005
			and format("\n\nOutnumbered: fewer of them here than of the other side's friends and roster, so their roster counts ×%.2f at points (at most ×1.44).", bonus) or ""), "ANCHOR_BOTTOM")
	end
	-- The strip, greyed in prep
	f.rally:SetTexture(GuildWars.MEDIA.."rally-"..a)
	local lanes = {}
	for _, lane in ipairs(type(b.lanes) == "table" and b.lanes or {}) do
		lanes[lane.id] = lane
	end
	-- Each point's id, for the live estimates (WarLive)
	local ids = {}
	for _, p in ipairs(GuildWars:Points(war, zone)) do
		ids[(p.lane or "")..p.role] = p.id
	end
	local estimate = type(b.estimate) == "table" and b.estimate or {}
	for _, row in ipairs(f.lanes) do
		local lane = lanes[row.id] or {}
		row.tower:SetTexture(GuildWars:SealFile(lane.tower, "tower", d, a))
		row.inhibitor:SetTexture(GuildWars:SealFile(lane.inhibitor, "inhibitor", d, a))
		row.tower:SetDesaturated(prep)
		row.inhibitor:SetDesaturated(prep)
		local tower, inhib = type(lane.tower) == "table" and lane.tower or {}, type(lane.inhibitor) == "table" and lane.inhibitor or {}
		row.pct:SetText(not prep and private.Pct(tower, estimate[ids[row.id.."tower"]]) or "")
		row.inhibPct:SetText(not prep and private.Pct(inhib, estimate[ids[row.id.."inhibitor"]]) or "")
	end
	local keep = type(b.keep) == "table" and b.keep.state or "sealed"
	f.keep:SetTexture(GuildWars:KeepFile(keep, d, a))
	f.keep:SetDesaturated(prep)
	W:Explain(f.keepHit, "The keep", keep == "open" and "Open: one inhibitor down. Take it to win." or keep == "fallen" and "Taken: the attackers won."
		or "Sealed until an inhibitor falls.", "ANCHOR_BOTTOM")
	-- Friends here
	local friends = b.friends or {}
	f.friends.text:SetText("Friends  "..Theme:Colorize(tostring(tonumber(friends.horde) or 0), GuildWars.SIDE_COLORS.Horde).." · "
		..Theme:Colorize(tostring(tonumber(friends.alliance) or 0), GuildWars.SIDE_COLORS.Alliance))
	W:Explain(f.friends, "Friends in "..zone.name, format("%d Horde and %d Alliance players here who aren't on either roster. They fight freely; only the two rosters take and hold points.",
		tonumber(friends.horde) or 0, tonumber(friends.alliance) or 0), "ANCHOR_BOTTOM")
	-- The point the player stands on, and its capture
	local point = GuildWars:PointAt(war, zone, x, y, mapId)
	local state
	if point and point.lane then
		local lane = lanes[point.lane] or {}
		state = type(lane[point.role]) == "table" and lane[point.role] or {}
	end
	f.bar:SetShown(point ~= nil and point.role ~= "rally" and not prep)
	-- Under the capture bar, or the friends when there's none
	f.status:ClearAllPoints()
	f.status:SetPoint("TOP", f.bar:IsShown() and f.bar or f.friends, "BOTTOM", 0, -6)
	if point then
		local label = point.lane and (strupper(strsub(point.lane, 1, 1))..strsub(point.lane, 2).." "..point.role) or point.role == "keep" and "The keep" or "The rally"
		local pct = state and (state.state == "taken" and 100 or tonumber(state.pct)) or (point.role == "keep" and keep == "fallen" and 100) or 0
		f.bar:SetValue(pct / 100)
		f.bar.label:SetText(label.." · "..point.name)
		f.bar.pct:SetText(format("%d%%", pct))
	end
	-- Why the player doesn't count, or no live data
	f.status:SetText(not b.live and "No live data: only the clock"
		or not sample and not GuildWars:OnRoster(war) and "You can fight; you don't count"
		or "")
	f.summary:SetText(format("%s  ·  %s %d v %s %d", prep and ("Prep "..private.Clock(b.start - now)) or private.Clock(b.stop - now),
		attacker.guild or attacker.faction or "?", tonumber((b.turnout or {}).attacker) or 0, defender.guild or defender.faction or "?", tonumber((b.turnout or {}).defender) or 0))
	if sample then
		f.body:Show()
		f:SetSize(WIDTH, HEIGHT)
	else
		HudKit:Apply("war", f, WIDTH, HEIGHT)
	end
	f:Show()
end
