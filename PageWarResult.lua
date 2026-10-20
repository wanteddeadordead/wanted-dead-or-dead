-- Wanted: a war's Result step, as the site counted it. How each lane and the keep ended, the turnout and the kills;
-- who holds the zone now and how long it's protected; the stake and the War Marks for the treasury and the roster.
-- Until the site has counted: "The site is counting". The tab closes 24 hours after the result.

local _, Wanted = ...
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local GuildWars = Wanted.GuildWars
local Data = GuildWars.Page -- what the pages read: the tour's sample war while one is on (WarSample.lua)
local private = {}
local GAP = 12
local LANES = { { "top", "Top" }, { "mid", "Mid" }, { "bot", "Bot" } }
local SIDE = { Horde = "horde", Alliance = "alliance" }

---How a lane point ended: its seal, and "taken 7:06" or "held".
function private.End(point, role, defender, attacker)
	point = type(point) == "table" and point or {}
	local d, a = SIDE[defender] or "horde", SIDE[attacker] or "alliance"
	if point.state == "taken" then
		return GuildWars.MEDIA..(role == "tower" and ("tower-"..a) or ("inhib-broken-by-"..a)), type(point.at) == "number" and gsub(GuildWars:Clock(point.at), " [AP]M$", "") or "taken"
	end
	return GuildWars.MEDIA..(role == "tower" and ("tower-"..d) or ("inhib-"..d)), "held"
end

function private.Count(n)
	n = floor(tonumber(n) or 0)
	return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
end

GuildWars.PANELS.result = {
	build = function(panel, width)
		panel.state = {}
		local wide = floor((width - GAP) * 0.66)
		local war = W:Card(panel)
		war:SetPoint("TOPLEFT")
		war:SetSize(wide, 152)
		W:SectionLabel(war, "The war"):SetPoint("TOPLEFT", 16, -14)
		panel.lanes = {}
		for i, lane in ipairs(LANES) do
			local y = -36 - (i - 1) * 30
			local row = { name = Theme:Text(war, "body", lane[2], C.text) }
			row.name:SetPoint("TOPLEFT", 16, y - 6)
			row.tower = war:CreateTexture(nil, "ARTWORK")
			row.tower:SetSize(24, 24)
			row.tower:SetPoint("TOPLEFT", 60, y)
			row.inhibitor = war:CreateTexture(nil, "ARTWORK")
			row.inhibitor:SetSize(24, 24)
			row.inhibitor:SetPoint("TOPLEFT", 88, y)
			row.text = Theme:Text(war, "small", "")
			row.text:SetPoint("TOPLEFT", 124, y - 6)
			panel.lanes[i] = row
		end
		panel.keep = war:CreateTexture(nil, "ARTWORK")
		panel.keep:SetSize(48, 48)
		panel.keep:SetPoint("TOPLEFT", floor(wide * 0.55), -44)
		local keepName = Theme:Text(war, "body", "The keep", C.text)
		keepName:SetPoint("TOPLEFT", panel.keep, "TOPRIGHT", 10, -8)
		panel.keepLine = Theme:Text(war, "small", "")
		panel.keepLine:SetPoint("TOPLEFT", keepName, "BOTTOMLEFT", 0, -4)
		panel.summary = Theme:Text(war, "small", "")
		panel.summary:SetPoint("BOTTOMLEFT", 16, 12)
		-- The zone now
		local zone = W:Card(panel)
		zone:SetPoint("TOPLEFT", wide + GAP, 0)
		zone:SetSize(width - wide - GAP, 152)
		panel.zoneLabel = W:SectionLabel(zone, "")
		panel.zoneLabel:SetPoint("TOPLEFT", 16, -14)
		panel.crest = zone:CreateTexture(nil, "ARTWORK")
		panel.crest:SetSize(32, 32)
		panel.crest:SetPoint("TOPLEFT", 16, -36)
		panel.holder = Theme:Text(zone, "body", "", C.text)
		panel.holder:SetPoint("TOPLEFT", 58, -38)
		panel.protected = Theme:Text(zone, "small", "")
		panel.protected:SetPoint("TOPLEFT", 58, -56)
		-- War Marks
		local marks = W:Card(panel)
		marks:SetPoint("TOPLEFT", 0, -152 - GAP)
		marks:SetSize(width, 112)
		local coin = marks:CreateTexture(nil, "ARTWORK")
		coin:SetSize(14, 14)
		coin:SetPoint("TOPLEFT", 16, -13)
		coin:SetTexture(GuildWars.MEDIA.."coin")
		W:SectionLabel(marks, "War Marks"):SetPoint("TOPLEFT", 36, -14)
		panel.marks = {}
		for i, label in ipairs({ "Stake", "Treasury", "Your purse" }) do
			local name = Theme:Text(marks, "body", label, C.muted)
			name:SetPoint("TOPLEFT", 16, -36 - (i - 1) * 22)
			local value = Theme:Text(marks, "body", "", C.text)
			value:SetPoint("TOPLEFT", 130, -36 - (i - 1) * 22)
			panel.marks[i] = value
		end
		W:Explain(panel.marks[2], "War Marks", "Count toward today's 150 cap; the treasury takes the guild tax first.")
		panel.counting = Theme:Text(panel, "heading", "The site is counting", C.muted)
		panel.counting:SetPoint("TOPLEFT", 0, -6)
		local y = -152 - GAP - 112 - GAP
		panel.map = W:Button(panel, "Open the map", "secondary", 120, 30, function()
			local zoneData = panel.state.record and Wanted.WarZones:Get(panel.state.record.zone)
			if zoneData and OpenWorldMap and not InCombatLockdown() and not GuildWars:Sampling() then
				OpenWorldMap(zoneData.mapId)
			end
		end)
		panel.map:SetPoint("TOPLEFT", 0, y)
		panel.site = W:Button(panel, "Open on the site", "secondary", 140, 30, function()
			if panel.state.record then
				GuildWars:OpenOnSite(panel.state.record)
			end
		end)
		panel.site:SetPoint("LEFT", panel.map, "RIGHT", 10, 0)
		panel.cards = { war, zone, marks }
	end,
	refresh = function(panel, war, ctx)
		if not war then
			return
		end
		panel.state.record = war
		local r = type(war.result) == "table" and war.result or {}
		local counted = r.won ~= nil
		for _, card in ipairs(panel.cards) do
			card:SetShown(counted)
		end
		panel.counting:SetShown(not counted)
		panel.counting:SetText(r.void and "Void: the realm or the site was down. The stake is back; the war is rescheduled."
			or r.cancelled and "Cancelled. The stake is back." or "The site is counting")
		if not counted then
			return
		end
		local attacker = type(war.attacker) == "table" and war.attacker or {}
		local defender = type(war.defender) == "table" and war.defender or {}
		local laneData, seen = {}, type(r.lanes) == "table"
		for _, lane in ipairs(type(r.lanes) == "table" and r.lanes or {}) do
			if type(lane) == "table" and lane.id then
				laneData[lane.id] = lane
			end
		end
		for i, row in ipairs(panel.lanes) do
			local lane = laneData[LANES[i][1]] or {}
			local tower, towerLine = private.End(lane.tower, "tower", defender.faction, attacker.faction)
			local inhibitor, inhibitorLine = private.End(lane.inhibitor, "inhibitor", defender.faction, attacker.faction)
			row.tower:SetTexture(tower)
			row.inhibitor:SetTexture(inhibitor)
			-- Each lane as this client last saw it live; not seen, the summary's counts say what fell
			row.tower:SetDesaturated(not seen)
			row.inhibitor:SetDesaturated(not seen)
			row.text:SetText(not seen and "" or towerLine == "held" and "held" or (inhibitorLine == "held" and ("taken "..towerLine.." / held") or ("taken "..towerLine.." / "..inhibitorLine)))
		end
		local keep = type(r.keep) == "table" and r.keep or {}
		local fell = keep.state == "fallen"
		panel.keep:SetTexture(GuildWars.MEDIA..(fell and ("nexus-keep-fallen-to-"..(SIDE[attacker.faction] or "alliance")) or ("nexus-keep-sealed-"..(SIDE[defender.faction] or "horde"))))
		panel.keepLine:SetText(fell and ("fell"..(type(keep.at) == "number" and (" at "..GuildWars:Clock(keep.at)) or "")) or "held")
		local turnout = type(r.turnout) == "table" and r.turnout or {}
		panel.summary:SetText(format("%d / %d v %d / %d%s", tonumber(turnout.attacker) or 0, GuildWars.MAX_ROSTER, tonumber(turnout.defender) or 0, GuildWars.MAX_ROSTER,
			type(r.kills) == "table" and format(" · kills %d v %d", tonumber(r.kills.attacker) or 0, tonumber(r.kills.defender) or 0)
				or tonumber(r.towers) and format(" · towers %d · inhibitors %d", r.towers, tonumber(r.inhibitors) or 0) or ""))
		-- The zone now
		local holder = type(r.holder) == "table" and r.holder or {}
		panel.zoneLabel:SetText(strupper(GuildWars:Short(war.zone).." now"))
		panel.crest:SetTexture(GuildWars:CrestFile(holder))
		panel.holder:SetText(holder.guild and ("Held by <"..holder.guild..">") or "No one holds it")
		local until_ = tonumber(r.protectedUntil)
		panel.protected:SetText(until_ and ("Protected until "..date("%a ", until_)..GuildWars:Clock(until_)) or "")
		W:Explain(panel.holder, "Held by "..(holder.guild or "?"), until_ and format("No declarations on %s until %s; races go on.", GuildWars:Short(war.zone), date("%a ", until_)..GuildWars:Clock(until_)) or "Races go on.")
		-- War Marks
		local marks = type(r.marks) == "table" and r.marks or {}
		local stake = tonumber(marks.stake) or 0
		panel.marks[1]:SetText(stake <= 0 and "none"
			or marks.stakeBack and Theme:Colorize(private.Count(stake).." returned", C.green)
			or marks.stakeWon and Theme:Colorize(format("%s won from %s", private.Count(stake), ctx.theirs.guild or "them"), C.green)
			or war.role == "defend" and format("%s back to %s", private.Count(stake), ctx.theirs.guild or "them")
			or Theme:Colorize(format("%s lost to %s", private.Count(stake), ctx.theirs.guild or "them"), C.red))
		-- The treasury's movement from the site's ledger; nothing until it's sent
		local treasury, purse = tonumber(marks.treasury), tonumber(marks.purse) or 0
		panel.marks[2]:SetText(not treasury and "" or treasury ~= 0 and Theme:Colorize((treasury > 0 and "+" or "")..private.Count(treasury), treasury > 0 and C.green or C.red) or "0")
		panel.marks[3]:SetText(purse ~= 0 and (Theme:Colorize("+"..private.Count(purse), C.green).." for you") or "0")
	end,
}
