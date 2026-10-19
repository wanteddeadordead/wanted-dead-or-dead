-- Wanted: a war's Declare step. Whether the guild may declare (a checklist, each line with why), the terms (the stake
-- from the treasury, the roster, the chance in the draw), the declarations so far, and for a war officer: Declare war
-- (asked of the site through the app) or Not tonight. Members see it without the buttons.

local _, Wanted = ...
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local GuildWars = Wanted.GuildWars
local private = {}
local GAP = 12
local CHECKS = 6
local ROSTER_TIP = "One raid, 40 a side. No minimum and no forfeit: the war starts with whoever turns up."
local CHANCE_TIP = "Influence × stake, against every guild that declares. The site draws at 8:00 PM."

function private.Count(n)
	n = floor(tonumber(n) or 0)
	return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
end

---The checklist: { ok, text, value, tip } for each condition, from the war's declare record.
-- The checklist's lines as the site judged them (the catch-up's checks), and the refusal codes that fail each
local CHECK_KEYS = { "share", "members", "officer", "community", "protected", nil }
local REFUSED_LINE = { under_share = 1, under_members = 2, not_officer = 3, not_member = 3, protected = 5, war_on_zone = 5, window_closed = 6 }

function private.Checks(war, ctx)
	local d = type(war.declare) == "table" and war.declare or {}
	local side = ctx.ours.faction or UnitFactionGroup("player")
	local guild = ctx.ours.guild or "your guild"
	local short = GuildWars:Short(war.zone)
	local share = tonumber(d.share) or 0
	local need = tonumber(d.need) or 5
	local setting = GuildWars:OfficerSetting()
	local officerTip = "War officers: the guild master and the ranks ticked on the Guild tab, plus those added by name, less those left out. Set by the guild master."
	local protected = type(d.protectedUntil) == "number" and d.protectedUntil > ctx.now
	local lines = {
		{ share >= 0.1, format("10%% of the %s's influence", side),
			format("%d%%%s", floor(share * 100 + 0.5), (d.influence and d.sideInfluence) and format(": %s of %s", private.Count(d.influence), private.Count(d.sideInfluence)) or ""),
			"The guild's share of its side's influence in the race. Under 10% can't declare." },
		{ (tonumber(d.members) or 0) >= need, format("%d members with Wanted and the app", need), format("%d this week", tonumber(d.members) or 0),
			"Members count from their own signed presence, 72 hours after joining the guild." },
		{ ctx.officer, ctx.officer and ("You're a war officer of "..guild) or ("You're not a war officer of "..guild), ctx.officer and "Officer" or "",
			officerTip },
		{ type(d.officerInCommunity) == "string", "Officer in the Battle.net group"..Theme:Colorize(" (proposed)", C.amber),
			type(d.officerInCommunity) == "string" and d.officerInCommunity or (type(d.checks) == "table" and d.checks.community == true and "yes") or "none yet",
			"So the other side's officers can be told at once. Proposed until the cross-faction test passes." },
		{ not protected, short..(protected and " is protected" or " isn't protected"),
			protected and ("until "..date("%a ", d.protectedUntil)..GuildWars:Clock(d.protectedUntil)) or (type(d.protectedUntil) == "number" and ("ended "..date("%a ", d.protectedUntil)..GuildWars:Clock(d.protectedUntil))) or "",
			"A zone taken in a war is protected for 3 days: no declarations until then." },
		{ type(d.closesAt) == "number" and ctx.now < d.closesAt, "Within 15 minutes of the race", type(d.closesAt) == "number" and ("until "..GuildWars:Clock(d.closesAt)) or "",
			"Declarations close 15 minutes after the race ends." },
	}
	-- The site's word over this client's, and a refusal marks its line
	local _, code = GuildWars:Refused("declare", war.id)
	for i, line in ipairs(lines) do
		local key = CHECK_KEYS[i]
		if key and type(d.checks) == "table" and type(d.checks[key]) == "boolean" then
			line[1] = d.checks[key]
		end
		if REFUSED_LINE[code] == i then
			line[1] = false
		end
	end
	return lines, setting
end

---The chance in the draw for each declarer, and ours if we declare at this stake: influence × stake over the total.
function private.Chances(d, myShare, myStake)
	local total = 0
	local declared = type(d.declared) == "table" and d.declared or {}
	for _, entry in ipairs(declared) do
		if type(entry) == "table" and not entry.mine then
			total = total + (tonumber(entry.share) or 0) * (tonumber(entry.stake) or 0)
		end
	end
	local mine = myShare * myStake
	total = total + mine
	return total, total > 0 and mine / total or 0
end

GuildWars.PANELS.declare = {
	build = function(panel, width, height)
		local half = floor((width - GAP) / 2)
		-- Can we declare?
		local checks = W:Card(panel)
		checks:SetPoint("TOPLEFT")
		checks:SetSize(half - 10, 196)
		panel.checkLabel = W:SectionLabel(checks, "")
		panel.checkLabel:SetPoint("TOPLEFT", 16, -14)
		panel.checks = {}
		for i = 1, CHECKS do
			local line = CreateFrame("Frame", nil, checks)
			line:SetSize(half - 42, 22)
			line:SetPoint("TOPLEFT", 16, -34 - (i - 1) * 24)
			line.mark = Theme:Text(line, "body", "")
			line.mark:SetPoint("LEFT")
			line.text = Theme:Text(line, "body", "", C.text)
			line.text:SetPoint("LEFT", 16, 0)
			line.value = Theme:Text(line, "small", "")
			line.value:SetPoint("RIGHT")
			line.value:SetJustifyH("RIGHT")
			panel.checks[i] = line
		end
		-- The terms
		local terms = W:Card(panel)
		terms:SetPoint("TOPLEFT", half - 10 + GAP, 0)
		terms:SetSize(width - half + 10 - GAP, 196)
		W:SectionLabel(terms, "The terms"):SetPoint("TOPLEFT", 16, -14)
		panel.stake = W:Slider(terms, "Stake", width - half + 10 - GAP - 32, 300, 600, 50, function(v) return tostring(v) end, function()
			panel.tab.dirty = true
			GuildWars.PANELS.declare.refresh(panel, panel.war, panel.ctx)
		end)
		panel.stake:SetPoint("TOPLEFT", 16, -34)
		panel.treasury = Theme:Text(terms, "body", "", C.text)
		panel.treasury:SetPoint("TOPLEFT", 16, -86)
		local roster = Theme:Text(terms, "body", "Roster  "..Theme:Colorize("40 a side", C.text), C.muted)
		roster:SetPoint("TOPLEFT", 16, -112)
		W:InfoGlyph(terms, "Roster", ROSTER_TIP):SetPoint("LEFT", roster, "RIGHT", 6, 0)
		panel.chance = Theme:Text(terms, "body", "", C.muted)
		panel.chance:SetPoint("TOPLEFT", 16, -138)
		panel.chanceGlyph = W:InfoGlyph(terms, "Chance in the draw", CHANCE_TIP)
		-- Declared so far
		local declared = W:Card(panel)
		declared:SetPoint("TOPLEFT", 0, -196 - GAP)
		declared:SetSize(width, 104)
		W:SectionLabel(declared, "Declared so far"):SetPoint("TOPLEFT", 16, -14)
		panel.rows = {}
		for i = 1, 3 do
			local row = CreateFrame("Frame", nil, declared)
			row:SetSize(width - 32, 24)
			row:SetPoint("TOPLEFT", 16, -32 - (i - 1) * 24)
			row.crest = row:CreateTexture(nil, "ARTWORK")
			row.crest:SetSize(20, 20)
			row.crest:SetPoint("LEFT")
			row.guild = Theme:Text(row, "body", "", C.text)
			row.guild:SetPoint("LEFT", 28, 0)
			row.line = Theme:Text(row, "small", "")
			row.line:SetPoint("LEFT", 200, 0)
			row.pill = W:Pill(row)
			row.pill:SetPoint("RIGHT")
			panel.rows[i] = row
		end
		-- The buttons, a war officer's
		panel.declare = W:Button(panel, "Declare war", "primary", 210, 30, function()
			GuildWars:Act("declare", panel.war.id, { stake = panel.stakeValue })
		end)
		panel.declare:SetPoint("TOPRIGHT", 0, -196 - GAP - 104 - GAP)
		panel.notTonight = W:Button(panel, "Not tonight", "secondary", 110, 30, function()
			panel.tab.hidePrompt = true
			GuildWars.PANELS.declare.refresh(panel, panel.war, panel.ctx)
		end)
		panel.notTonight:SetPoint("RIGHT", panel.declare, "LEFT", -10, 0)
		W:Explain(panel.notTonight, "Not tonight", "Hides the prompt. The tab stays until the window closes.")
		panel.status = Theme:Text(panel, "small", "")
		panel.status:SetPoint("TOPLEFT", 0, -196 - GAP - 104 - GAP - 8)
	end,
	refresh = function(panel, war, ctx)
		panel.war, panel.ctx = war, ctx
		local d = type(war.declare) == "table" and war.declare or {}
		local guild = ctx.ours.guild or "your guild"
		panel.checkLabel:SetText(strupper("Can "..guild.." declare?"))
		local checks = private.Checks(war, ctx)
		-- Every line but the Battle.net group's (shown, not required, while it's proposed), and a treasury that covers the stake
		local all = not (type(d.checks) == "table" and d.checks.treasury == false)
		for i, line in ipairs(panel.checks) do
			local check = checks[i]
			all = all and (check[1] or i == 4)
			line.mark:SetText(Theme:Colorize(check[1] and "✓" or "✗", check[1] and C.green or C.red))
			line.text:SetText(check[2])
			line.value:SetText(check[3])
			W:Explain(line, gsub(check[2], "|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""), check[4])
		end
		-- The stake: the zone's minimum to twice that, in 50s, from the treasury
		local least = tonumber(d.minStake) or 300
		local most = tonumber(d.maxStake) or least * 2
		local slider = panel.stake.slider
		slider:SetMinMaxValues(least, most)
		local pending = GuildWars:Pending("declare", war.id)
		local mine = type(d.mine) == "table" and tonumber(d.mine.stake) or nil
		if not panel.tab.dirty then
			panel.stake:SetValue(mine or (pending and pending.data.stake) or least)
		end
		local stake = tonumber(slider:GetValue()) or least
	panel.stakeValue = stake
		local treasury = tonumber(d.treasury) or (GuildWars:Guild() and tonumber(GuildWars:Guild().treasury)) or 0
		panel.treasury:SetText(Theme:Colorize("Treasury  ", C.muted)..private.Count(treasury).." → "..private.Count(treasury - stake))
		local holder = ctx.theirs.guild or "the holders"
		W:Explain(panel.stake, "Stake", format("From %s's treasury: %s's minimum is %d, and you may raise it to twice that. A higher stake raises your chance in the draw.\n\nBack to the treasury if you aren't drawn or you withdraw; lost to %s if the attack fails; returned if you take the zone.",
			guild, GuildWars:Short(war.zone), least, holder))
		local myShare = tonumber(d.share) or 0
		local _, chance = private.Chances(d, myShare, stake)
		panel.chance:SetText("Chance in the draw  "..Theme:Colorize(format("%d%%", floor(chance * 100 + 0.5)), C.green))
		panel.chanceGlyph:ClearAllPoints()
		panel.chanceGlyph:SetPoint("LEFT", panel.chance, "LEFT", panel.chance:GetStringWidth() + 6, 0)
		-- Declared so far: the others, then us
		local total = private.Chances(d, myShare, stake)
		local list = {}
		for _, entry in ipairs(type(d.declared) == "table" and d.declared or {}) do
			if type(entry) == "table" and entry.guild ~= guild then
				tinsert(list, entry)
			end
		end
		tinsert(list, { guild = guild, crest = ctx.ours.crest, faction = ctx.ours.faction, share = myShare, stake = mine, mine = true })
		for i, row in ipairs(panel.rows) do
			local entry = list[i]
			row:SetShown(entry ~= nil)
			if entry then
				local share = tonumber(entry.share) or 0
				row.crest:SetTexture(GuildWars:CrestFile(entry))
				row.guild:SetText(entry.guild or "?")
				local declaredAt = type(entry.at) == "number" and (" at "..GuildWars:Clock(entry.at)) or ""
				if entry.mine and not entry.stake then
					row.line:SetText(format("%d%% influence · not declared yet", floor(share * 100 + 0.5)))
					row.pill:Set(format("%d%% IF YOU DECLARE", floor(chance * 100 + 0.5)), C.green)
				else
					local s = tonumber(entry.stake) or 0
					row.line:SetText(format("%d%% influence · stake %s%s%s", floor(share * 100 + 0.5), private.Count(s), entry.by and (" · by "..entry.by) or "", declaredAt))
					row.pill:Set(format("%d%% CHANCE", total > 0 and floor(share * s / total * 100 + 0.5) or 0), entry.mine and C.green or C.muted)
				end
			end
		end
		-- The buttons: a war officer's, with every check passed and the app running
		local declared = mine ~= nil
		local canAct = ctx.officer and not ctx.looking and not declared and not panel.tab.hidePrompt
		panel.declare:SetShown(canAct)
		panel.notTonight:SetShown(canAct)
		panel.declare:SetText("Declare war · stake "..private.Count(stake))
		panel.declare:SetEnabled(all and ctx.app and not pending)
		W:Explain(panel.declare, "Declare war", not ctx.app and "Start the Wanted app to act."
			or type(d.checks) == "table" and d.checks.treasury == false and "The treasury can't cover the stake."
			or not all and "Every line of the checklist must be ticked."
			or "Spends the stake from the treasury. It can't be undone until the draw.")
		panel.status:SetText(declared and Theme:Colorize(format("Declared, stake %s. The draw is at %s.", private.Count(mine), type(war.draw) == "table" and type(war.draw.at) == "number" and GuildWars:Clock(war.draw.at) or "8:00 PM"), C.green)
			or pending and Theme:Colorize("Sent; waiting for the site", C.amber)
			or GuildWars:Refused("declare", war.id) and Theme:Colorize(GuildWars:Refused("declare", war.id), C.red)
			or not ctx.officer and "Members see this page without its buttons." or "")
	end,
}
