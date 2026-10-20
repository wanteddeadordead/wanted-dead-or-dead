-- Wanted: a war's Battle step. The defenders' three lanes (a tower, then an inhibitor) and the keep, live from the
-- rosters' clients (provisional: the site counts the result); each guild's turnout and the friends present; the
-- player's own part; what happened. Go to the rally sets a waypoint on the player's side's rally point (defenders:
-- the keep); Show the HUD shows or hides the war HUD.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local GuildWars = Wanted.GuildWars
local Data = GuildWars.Page -- what the pages read: the tour's sample war while one is on (WarSample.lua)
local private = {}
local GAP = 12
local LANES = { { "top", "Top" }, { "mid", "Mid" }, { "bot", "Bot" } }
local LANES_HEIGHT = 166
local EVENTS = 5
local SIDE = { Horde = "horde", Alliance = "alliance" }
local LANES_TIP = "Live from the rosters' clients, so provisional: the site counts the result from everyone's records when the war ends."
local FRIENDS_TIP = "Players here who aren't on either roster. They fight freely; only the rosters take points."

---A point's seal and its line: standing, being taken (with the count), or taken (and when).
function private.Point(point, role, defender, attacker)
	point = type(point) == "table" and point or {}
	local d, a = SIDE[defender] or "horde", SIDE[attacker] or "alliance"
	local state = point.state
	if state == "taken" then
		return GuildWars.MEDIA..(role == "tower" and ("tower-"..a) or ("inhib-broken-by-"..a)),
			"taken"..(type(point.at) == "number" and (" "..GuildWars:Clock(point.at)) or "")
	elseif state == "taking" then
		return GuildWars.MEDIA..(role == "tower" and "tower-contested" or ("inhib-"..d)),
			format("%d%%%s", tonumber(point.pct) or 0, (point.us and point.them) and format(", %d v %d", point.us, point.them) or "")
	end
	return GuildWars.MEDIA..(role == "tower" and ("tower-"..d) or ("inhib-"..d)), "standing"
end

---The keep's state ("sealed", "open" or "fallen"), its line, and the two sides' codes; the crest paints the seal.
function private.Keep(keep, defender, attacker)
	keep = type(keep) == "table" and keep or {}
	local d, a = SIDE[defender] or "horde", SIDE[attacker] or "alliance"
	if keep.state == "fallen" then
		return "fallen", "fell"..(type(keep.at) == "number" and (" at "..GuildWars:Clock(keep.at)) or ""), d, a
	elseif keep.state == "open" then
		return "open", "open"..(type(keep.since) == "number" and (" since "..GuildWars:Clock(keep.since)) or ""), d, a
	end
	return "sealed", "sealed", d, a
end

---Go to the rally: a waypoint on the player's side's rally point; the defenders' is their keep.
function GuildWars:GoToRally(war)
	if GuildWars:Sampling() then
		return
	end
	local zone = Wanted.WarZones:Get(war.zone)
	if not zone then
		UI:Toast("This zone's war map isn't known yet.", C.red)
		return
	end
	local side = war.role == "defend" and war.defender or war.attacker
	local base = type(side) == "table" and side.faction == "Alliance" and zone.alliance or zone.horde
	if Wanted.Captures:Track({ id = base.id, x = base.x, y = base.y, front = { mapId = zone.mapId } }) then
		UI:Toast(format("Waypoint set on %s.", war.role == "defend" and ("the keep at "..base.name) or ("the rally at "..base.name)), C.green)
	else
		UI:Toast("The waypoint couldn't be set.", C.red)
	end
end

GuildWars.PANELS.battle = {
	build = function(panel, width)
		panel.state = {}
		local lanes = W:Card(panel)
		panel.lanesCard = lanes
		lanes:SetPoint("TOPLEFT")
		lanes:SetSize(width, LANES_HEIGHT)
		panel.lanesLabel = W:SectionLabel(lanes, "")
		panel.lanesLabel:SetPoint("TOPLEFT", 16, -14)
		panel.lanesGlyph = W:InfoGlyph(lanes, "The lanes", LANES_TIP)
		panel.lanes = {}
		for i, lane in ipairs(LANES) do
			local y = -38 - (i - 1) * 36
			local row = { name = Theme:Text(lanes, "body", lane[2], C.text) }
			row.name:SetPoint("TOPLEFT", 16, y - 8)
			for j, role in ipairs({ "tower", "inhibitor" }) do
				local x = 70 + (j - 1) * 175
				local seal = lanes:CreateTexture(nil, "ARTWORK")
				seal:SetSize(28, 28)
				seal:SetPoint("TOPLEFT", x, y)
				local text = Theme:Text(lanes, "small", "", C.text)
				text:SetPoint("LEFT", seal, "RIGHT", 6, 0)
				row[role] = { seal = seal, text = text }
			end
			panel.lanes[i] = row
		end
		panel.keep = GuildWars:NewCrest(lanes)
		panel.keep:SetSize(56, 56)
		panel.keep:SetPoint("TOPLEFT", 420, -50)
		panel.keepName = Theme:Text(lanes, "body", "The keep", C.text)
		panel.keepName:SetPoint("TOPLEFT", panel.keep, "TOPRIGHT", 10, -10)
		panel.keepLine = Theme:Text(lanes, "small", "")
		panel.keepLine:SetPoint("TOPLEFT", panel.keepName, "BOTTOMLEFT", 0, -4)
		local turnoutX = width - 230
		local divider = lanes:CreateTexture(nil, "BORDER")
		divider:SetColorTexture(1, 1, 1, 0.07)
		divider:SetSize(1, LANES_HEIGHT - 24)
		divider:SetPoint("TOPLEFT", turnoutX - 16, -12)
		W:SectionLabel(lanes, "Turnout"):SetPoint("TOPLEFT", turnoutX, -14)
		panel.turnout = {}
		for i = 1, 2 do
			local crest = GuildWars:NewCrest(lanes)
			crest:SetSize(18, 18)
			crest:SetPoint("TOPLEFT", turnoutX, -36 - (i - 1) * 26)
			local text = Theme:Text(lanes, "body", "", C.text)
			text:SetPoint("LEFT", crest, "RIGHT", 8, 0)
			panel.turnout[i] = { crest = crest, text = text }
		end
		panel.friends = Theme:Text(lanes, "small", "")
		panel.friends:SetPoint("TOPLEFT", turnoutX, -94)
		panel.friendsGlyph = W:InfoGlyph(lanes, "Friends", FRIENDS_TIP)
		panel.prep = Theme:Text(lanes, "heading", "", C.gold)
		panel.prep:SetPoint("BOTTOMLEFT", 16, 12)
		-- You, and what happened
		local half = floor((width - GAP) / 2)
		local you = W:Card(panel)
		you:SetPoint("TOPLEFT", 0, -LANES_HEIGHT - GAP)
		you:SetSize(half - 20, 96)
		W:SectionLabel(you, "You"):SetPoint("TOPLEFT", 16, -14)
		panel.you = Theme:Text(you, "body", "", C.text)
		panel.you:SetPoint("TOPLEFT", 16, -36)
		panel.youStats = Theme:Text(you, "small", "")
		panel.youStats:SetPoint("TOPLEFT", 16, -58)
		local events = W:Card(panel)
		events:SetPoint("TOPLEFT", half - 20 + GAP, -LANES_HEIGHT - GAP)
		events:SetSize(width - half + 20 - GAP, 140)
		W:SectionLabel(events, "What happened"):SetPoint("TOPLEFT", 16, -14)
		panel.events = {}
		for i = 1, EVENTS do
			local time = Theme:Text(events, "small", "")
			time:SetPoint("TOPLEFT", 16, -36 - (i - 1) * 19)
			local text = Theme:Text(events, "small", "", C.text)
			text:SetPoint("TOPLEFT", 70, -36 - (i - 1) * 19)
			text:SetPoint("RIGHT", -16, 0)
			text:SetWordWrap(false)
			panel.events[i] = { time = time, text = text }
		end
		-- The buttons
		local y = -LANES_HEIGHT - GAP - 96 - GAP
		panel.rally = W:Button(panel, "Go to the rally", "primary", 130, 30, function()
			if panel.state.record then
				GuildWars:GoToRally(panel.state.record)
			end
		end)
		panel.rally:SetPoint("TOPLEFT", 0, y)
		W:Explain(panel.rally, "Go to the rally", "A waypoint to your side's rally point (defenders: the keep).")
		panel.map = W:Button(panel, "Open the map", "secondary", 120, 30, function()
			local zone = panel.state.record and Wanted.WarZones:Get(panel.state.record.zone)
			if zone and OpenWorldMap and not InCombatLockdown() and not GuildWars:Sampling() then
				OpenWorldMap(zone.mapId)
			end
		end)
		panel.map:SetPoint("LEFT", panel.rally, "RIGHT", 10, 0)
		panel.hud = W:Button(panel, "Show the HUD", "secondary", 120, 30, function()
			if GuildWars:Sampling() then
				return
			end
			local settings = Wanted.db.settings
			settings.warHud = settings.warHud == false
			if GuildWars.UpdateHUD then
				GuildWars:UpdateHUD()
			end
			GuildWars.PANELS.battle.refresh(panel, panel.state.record, panel.ctx)
		end)
		panel.hud:SetPoint("LEFT", panel.map, "RIGHT", 10, 0)
		W:Explain(panel.hud, "The war HUD", "Shows or hides the war's frame at the top of the screen in its zone.")
	end,
	refresh = function(panel, war, ctx)
		if not war then
			return
		end
		panel.state.record, panel.ctx = war, ctx
		local b = type(war.battle) == "table" and war.battle or {}
		local attacker = type(war.attacker) == "table" and war.attacker or {}
		local defender = type(war.defender) == "table" and war.defender or {}
		local prep = type(b.start) == "number" and ctx.now < b.start
		local live = b.live == true
		panel.lanesLabel:SetText(strupper("The lanes"..(prep and " · prep" or live and " · live" or "")))
		panel.lanesGlyph:ClearAllPoints()
		panel.lanesGlyph:SetPoint("LEFT", panel.lanesLabel, "LEFT", panel.lanesLabel:GetStringWidth() + 6, 0)
		local laneData = {}
		for _, lane in ipairs(type(b.lanes) == "table" and b.lanes or {}) do
			if type(lane) == "table" and lane.id then
				laneData[lane.id] = lane
			end
		end
		for i, row in ipairs(panel.lanes) do
			local lane = laneData[LANES[i][1]] or {}
			for _, role in ipairs({ "tower", "inhibitor" }) do
				local texture, line = private.Point(lane[role], role, defender.faction, attacker.faction)
				row[role].seal:SetTexture(texture)
				row[role].seal:SetDesaturated(prep)
				row[role].text:SetText(prep and "" or line)
			end
		end
		local keepState, keepLine, kd, ka = private.Keep(b.keep, defender.faction, attacker.faction)
		panel.keep:SetGuild(defender)
		panel.keep:SetDesaturated(false)
		panel.keep:SetKeep(keepState, kd, ka)
		if prep then
			panel.keep:SetDesaturated(true)
		end
		panel.keepLine:SetText(prep and "" or Theme:Colorize(keepLine, type(b.keep) == "table" and b.keep.state == "open" and C.amber or C.muted))
		W:Explain(panel.keepName, "The keep", "One inhibitor down opens it; it pulses orange on the map. Take it to win.")
		-- Turnout: ours first
		local turnout = type(b.turnout) == "table" and b.turnout or {}
		for i, guild in ipairs({ ctx.ours, ctx.theirs }) do
			local ourKey = war.role == "defend" and "defender" or "attacker"
			local n = turnout[i == 1 and ourKey or (ourKey == "attacker" and "defender" or "attacker")]
			panel.turnout[i].crest:SetGuild(guild)
			panel.turnout[i].text:SetText((guild.guild or "?").."  "..Theme:Colorize(tostring(tonumber(n) or 0), i == 1 and C.green or C.text)..Theme:Colorize(" / "..GuildWars.MAX_ROSTER, C.muted))
		end
		local friends = type(b.friends) == "table" and b.friends or {}
		panel.friends:SetText("Friends  "..Theme:Colorize(tostring(tonumber(friends.horde) or 0), GuildWars.SIDE_COLORS.Horde).." · "
			..Theme:Colorize(tostring(tonumber(friends.alliance) or 0), GuildWars.SIDE_COLORS.Alliance))
		W:Explain(panel.friendsGlyph, "Friends", format("%d Horde and %d Alliance players here who aren't on either roster. They fight freely; only the two rosters take and hold points.",
			tonumber(friends.horde) or 0, tonumber(friends.alliance) or 0))
		panel.friendsGlyph:ClearAllPoints()
		panel.friendsGlyph:SetPoint("LEFT", panel.friends, "LEFT", panel.friends:GetStringWidth() + 6, 0)
		panel.prep:SetText(prep and ("Battle at "..GuildWars:Clock(b.start))
			or (not live and type(b.stop) == "number") and Theme:Colorize("No live data: the result comes from the site at "..GuildWars:Clock(b.stop), C.muted) or "")
		-- You
		local me = type(b.me) == "table" and b.me or {}
		panel.you:SetText(me.counting and (Theme:Colorize("✓ ", C.green).."Counting at "..(me.point or "a point"))
			or me.onRoster == false and "You can fight; you don't count"
			or me.inZone == false and "Go to the rally"
			or me.why and (Theme:Colorize("! ", C.amber)..me.why) or "On the roster")
		panel.youStats:SetText(format("Kills %d · deaths %d · %d min on points", tonumber(me.kills) or 0, tonumber(me.deaths) or 0, tonumber(me.minutes) or 0))
		-- What happened, newest first
		local events = type(b.events) == "table" and b.events or {}
		for i, line in ipairs(panel.events) do
			local event = type(events[i]) == "table" and events[i] or nil
			line.time:SetText(event and type(event.t) == "number" and gsub(GuildWars:Clock(event.t), " [AP]M$", "") or "")
			line.text:SetText(event and event.text or "")
		end
		panel.hud:SetText(Wanted.db.settings.warHud == false and "Show the HUD" or "Hide the HUD")
	end,
}
