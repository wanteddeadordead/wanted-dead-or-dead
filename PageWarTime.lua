-- Wanted: a war's Time step. The defenders' officers pick one half-hour start over the next two evenings (6:00 to
-- 11:30 PM): cells closed by their guild's other war (two wars a day at least an hour apart) are marked with the
-- reason, and race times are marked but open; Set <time> asks the site. The attackers' officers see the time set and
-- accept or withdraw (with a confirm: the stake goes back and the holders keep the zone); no answer by prep counts as
-- accepting. Members see it read-only.

local _, Wanted = ...
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local GuildWars = Wanted.GuildWars
local Data = GuildWars.Page -- what the pages read: the tour's sample war while one is on (WarSample.lua)
local private = {}
local SLOTS, EVENINGS = 12, 2
local CELL_W, CELL_H, CELL_GAP = 52, 34, 6
local GRID_X, GRID_Y = 110, -60
local PREP, BATTLE = 15 * 60, 30 * 60
local GOLD = { 0.87, 0.72, 0.36 }

---"Tue 20 Oct, 7:00 to 7:30 PM".
function private.Window(start)
	return format("%s, %s to %s", date("%a %d %b", start), gsub(GuildWars:Clock(start), " [AP]M$", ""), GuildWars:Clock(start + BATTLE))
end

---Why a start is closed (the guild's other war), or nil; and the race at that time, or nil.
function private.Cell(t, start)
	for _, closed in ipairs(type(t.closed) == "table" and t.closed or {}) do
		if type(closed) == "table" and closed.start == start then
			return closed.reason or "Closed", nil
		end
	end
	for _, race in ipairs(type(t.races) == "table" and t.races or {}) do
		if type(race) == "table" and type(race.start) == "number" and start >= race.start and start < (tonumber(race.stop) or race.start + 2700) then
			return nil, race
		end
	end
	return nil, nil
end

-- ============================================================================
-- The defenders' grid
-- ============================================================================

function private.BuildDefend(panel, width)
	local card = W:Card(panel)
	card:SetPoint("TOPLEFT")
	card:SetSize(width, 196)
	panel.state = {} -- the start picked, and whether this player may pick
	W:SectionLabel(card, "Pick one start · your time · 15 minutes' prep, then 30 of battle"):SetPoint("TOPLEFT", 16, -14)
	panel.times, panel.days, panel.cells, panel.raceMarks = {}, {}, {}, {}
	for i = 1, SLOTS do
		local x = GRID_X + (i - 1) * (CELL_W + CELL_GAP)
		local label = Theme:Text(card, "small", "")
		label:SetPoint("TOP", card, "TOPLEFT", x + CELL_W / 2, -36)
		panel.times[i] = label
		local mark = card:CreateTexture(nil, "ARTWORK")
		mark:SetSize(CELL_W + CELL_GAP, 3)
		mark:SetPoint("TOPLEFT", x - CELL_GAP / 2, -52)
		mark:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.7)
		panel.raceMarks[i] = mark
	end
	for d = 1, EVENINGS do
		local y = GRID_Y - (d - 1) * (CELL_H + CELL_GAP)
		local day = Theme:Text(card, "body", "", C.text)
		day:SetPoint("TOPLEFT", 16, y - 10)
		panel.days[d] = day
		panel.cells[d] = {}
		for i = 1, SLOTS do
			local cell = CreateFrame("Button", nil, card)
			cell:SetSize(CELL_W, CELL_H)
			cell:SetPoint("TOPLEFT", GRID_X + (i - 1) * (CELL_W + CELL_GAP), y)
			Theme:Skin(cell, { 0, 0, 0, 0.25 }, C.border)
			cell.tick = Theme:Text(cell, "heading", "✓", C.white)
			cell.tick:SetPoint("CENTER")
			cell:SetScript("OnClick", function(self)
				if self.open and panel.state.canPick then
					panel.state.picked = self.start
					GuildWars.PANELS.time.refresh(panel.outer, panel.war, panel.ctx)
				end
			end)
			panel.cells[d][i] = cell
		end
	end
	local legend = Theme:Text(card, "small", Theme:Colorize("■", GOLD).." your pick    "..Theme:Colorize("■", C.red).." closed    "..Theme:Colorize("—", GOLD).." races")
	legend:SetPoint("TOPLEFT", GRID_X, GRID_Y - EVENINGS * (CELL_H + CELL_GAP) - 6)
	-- The war's time, as picked
	local when = W:Card(panel)
	when:SetPoint("TOPLEFT", 0, -196 - 12)
	when:SetSize(width, 104)
	W:SectionLabel(when, "The war's time"):SetPoint("TOPLEFT", 16, -14)
	panel.window = Theme:Text(when, "title", "")
	panel.window:SetPoint("TOPLEFT", 16, -34)
	panel.prep = Theme:Text(when, "small", "")
	panel.prep:SetPoint("TOPLEFT", 16, -64)
	panel.fallback = Theme:Text(when, "small", "")
	panel.fallback:SetPoint("TOPLEFT", 16, -82)
	panel.set = W:Button(panel, "Set", "primary", 170, 30, function()
		if panel.state.picked then
			Data:Act("time", panel.war.id, { start = panel.state.picked })
		end
	end)
	panel.set:SetPoint("TOPRIGHT", 0, -196 - 12 - 104 - 12)
	panel.defendStatus = Theme:Text(panel, "small", "")
	panel.defendStatus:SetPoint("TOPLEFT", 0, -196 - 12 - 104 - 20)
end

function private.RefreshDefend(panel, war, ctx)
	panel.war, panel.ctx = war, ctx
	local t = type(war.time) == "table" and war.time or {}
	local evenings = type(t.evenings) == "table" and t.evenings or {}
	local pending = Data:Pending("time", war.id)
	local set = tonumber(t.start) or (pending and pending.data.start)
	panel.state.canPick = ctx.officer and not ctx.looking and not tonumber(t.start)
	panel.state.picked = panel.state.picked or set
	for i = 1, SLOTS do
		local start = type(evenings[1]) == "number" and evenings[1] + (i - 1) * 1800 or nil
		panel.times[i]:SetText(start and gsub(GuildWars:Clock(start), " [AP]M$", "") or "")
		local _, race = start and private.Cell(t, start)
		panel.raceMarks[i]:SetShown(race ~= nil)
	end
	for d = 1, EVENINGS do
		local base = type(evenings[d]) == "number" and evenings[d] or nil
		panel.days[d]:SetText(base and date("%a %d %b", base) or "")
		for i, cell in ipairs(panel.cells[d]) do
			local start = base and base + (i - 1) * 1800 or nil
			cell:SetShown(start ~= nil)
			if start then
				local closed, race = private.Cell(t, start)
				local mine = panel.state.picked == start
				cell.start, cell.open = start, closed == nil and start > ctx.now + PREP
				cell.tick:SetShown(mine)
				Theme:SetBg(cell, closed and C.redDim or mine and { GOLD[1], GOLD[2], GOLD[3], 0.18 } or { 0, 0, 0, 0.25 })
				Theme:SetBorderColor(cell, mine and { GOLD[1], GOLD[2], GOLD[3], 1 } or closed and { C.red[1], C.red[2], C.red[3], 0.45 } or C.border)
				local label = date("%a ", start)..GuildWars:Clock(start)
				local anchor = d == 1 and "ANCHOR_BOTTOM" or "ANCHOR_TOP"
				-- The first evening's under the cell (not over the hours and the race marks), the second's over it (not over the legend)
				if closed then
					W:Explain(cell, "Closed: "..label, closed.." A guild's two wars in a day must be at least 1 hour apart.", anchor)
				elseif race then
					W:Explain(cell, label, format("A race in %s then: open, but your players may be racing.", race.zone or "?"), anchor)
				else
					W:Explain(cell, label, format("Prep from %s, battle %s to %s.", GuildWars:Clock(start - PREP), GuildWars:Clock(start), GuildWars:Clock(start + BATTLE)), anchor)
				end
			end
		end
	end
	local shown = panel.state.picked
	panel.window:SetText(shown and private.Window(shown) or "Not picked yet")
	panel.prep:SetText(shown and (Theme:Colorize("Prep  ", C.muted)..Theme:Colorize(GuildWars:Clock(shown - PREP), C.text)) or "")
	local fallback = tonumber(t.defaultStart)
	panel.fallback:SetText(fallback and (Theme:Colorize("If no pick  ", C.muted)..Theme:Colorize(date("%a ", fallback)..GuildWars:Clock(fallback), C.text)) or "")
	local attackers = ctx.theirs.guild or "the attackers"
	panel.set:SetShown(panel.state.canPick)
	panel.set:SetText(shown and ("Set "..date("%a ", shown)..GuildWars:Clock(shown)) or "Pick a start")
	panel.set:SetEnabled(shown ~= nil and ctx.app and not (pending and pending.data.start == shown))
	W:Explain(panel.set, "Set the time", not ctx.app and "Start the Wanted app to act."
		or format("%s's officers in the Wanted Battle.net community get it at once; otherwise on the site now and in game after their next /reload. They accept, or withdraw and take their stake back.", attackers))
	local deadline = tonumber(t.deadline)
	panel.defendStatus:SetText(tonumber(t.start) and format("Set %s; %s %s.", date("%a ", t.start)..GuildWars:Clock(t.start), attackers, t.accepted and "accepted" or "hasn't answered")
		or pending and Theme:Colorize("Sent; waiting for the site", C.amber)
		or Data:Refused("time", war.id) and Theme:Colorize(Data:Refused("time", war.id), C.red)
		or deadline and ctx.now > deadline and fallback and format("No pick: %s, set by the site.", date("%a ", fallback)..GuildWars:Clock(fallback))
		or not ctx.officer and "Members see this page without its buttons."
		or deadline and format("No pick by %s and the war is at %s.", date("%a ", deadline)..GuildWars:Clock(deadline), fallback and (date("%a ", fallback)..GuildWars:Clock(fallback)) or "8:00 PM the next evening")
		or "")
end

-- ============================================================================
-- The attackers' answer
-- ============================================================================

function private.BuildAttack(panel, width)
	local card = W:Card(panel)
	card:SetPoint("TOPLEFT")
	card:SetSize(width, 140)
	panel.setLabel = W:SectionLabel(card, "")
	panel.setLabel:SetPoint("TOPLEFT", 16, -14)
	panel.attackWindow = Theme:Text(card, "title", "")
	panel.attackWindow:SetPoint("TOPLEFT", 16, -34)
	panel.attackPrep = Theme:Text(card, "small", "")
	panel.attackPrep:SetPoint("TOPLEFT", 16, -64)
	panel.clashes = {}
	for i = 1, 2 do
		local line = Theme:Text(card, "small", "", C.text)
		line:SetPoint("TOPLEFT", 16, -86 - (i - 1) * 20)
		panel.clashes[i] = line
	end
	panel.answerLabel = W:SectionLabel(card, "Answer by")
	panel.answerLabel:SetPoint("TOPLEFT", floor(width * 0.62), -14)
	panel.answerBy = Theme:Text(card, "body", "", C.text)
	panel.answerBy:SetPoint("TOPLEFT", floor(width * 0.62), -34)
	panel.noAnswer = Theme:Text(card, "small", "No answer  "..Theme:Colorize("accepted", C.text), C.muted)
	panel.noAnswer:SetPoint("TOPLEFT", floor(width * 0.62), -54)
	panel.accept = W:Button(panel, "Accept", "primary", 120, 30, function()
		Data:Act("answer", panel.war.id, { accept = true })
	end)
	panel.accept:SetPoint("TOPRIGHT", 0, -140 - 12)
	W:Explain(panel.accept, "Accept", "The war is on. Pick your roster on the Roster step; reminders 1 hour before.")
	panel.withdraw = W:Button(panel, "Withdraw", "danger", 120, 30, function()
		local war = panel.war
		local stake = tonumber(war.stake)
		W:Dialog({
			title = "Withdraw from the war?",
			text = format("No war. Your stake%s goes back to the treasury and %s keeps %s.", stake and (" of "..stake) or "", panel.ctx.theirs.guild or "the holder", GuildWars:Short(war.zone)),
			confirmLabel = "Withdraw",
			confirmStyle = "danger",
			cancelLabel = "Cancel",
			onConfirm = function() Data:Act("answer", war.id, { accept = false }) end,
		})
	end)
	panel.withdraw:SetPoint("RIGHT", panel.accept, "LEFT", -10, 0)
	panel.attackStatus = Theme:Text(panel, "small", "")
	panel.attackStatus:SetPoint("TOPLEFT", 0, -140 - 20)
end

function private.RefreshAttack(panel, war, ctx)
	panel.war, panel.ctx = war, ctx
	local t = type(war.time) == "table" and war.time or {}
	local start = tonumber(t.start)
	local holder = ctx.theirs.guild or "The holders"
	local ours = ctx.ours.guild or "your guild"
	panel.setLabel:SetText(strupper(start and format("%s set the time%s", holder, type(t.setAt) == "number" and (" at "..GuildWars:Clock(t.setAt)) or "")
		or format("Waiting for %s to pick", holder)))
	panel.attackWindow:SetText(start and private.Window(start) or (tonumber(t.deadline) and ("By "..date("%a ", t.deadline)..GuildWars:Clock(t.deadline)) or ""))
	local prep = start and start - PREP
	panel.attackPrep:SetText(prep and (Theme:Colorize("Prep  ", C.muted)..Theme:Colorize(GuildWars:Clock(prep), C.text)..Theme:Colorize("  ·  in "..gsub(Theme:Left(prep - ctx.now), " left$", ""), C.muted)) or "")
	-- What else is on then: the guild's other wars, the races
	local clashes = {}
	if start then
		local _, race = private.Cell(t, start)
		local other = type(t.otherWar) == "string" and t.otherWar or nil
		tinsert(clashes, other and Theme:Colorize("! ", C.amber).."Also "..other or Theme:Colorize("✓ ", C.green)..format("No other %s war that day", ours))
		if race then
			tinsert(clashes, Theme:Colorize("! ", C.amber)..format("Same time as the %s race", GuildWars:Clock(race.start)))
		end
	end
	for i, line in ipairs(panel.clashes) do
		line:SetText(clashes[i] or "")
		if i == 2 then
			W:Explain(line, "Race clash", "Your racers may be busy.")
		end
	end
	panel.answerLabel:SetShown(start ~= nil)
	panel.answerBy:SetText(prep and (date("%a ", prep)..GuildWars:Clock(prep)..", when prep starts") or "")
	panel.noAnswer:SetShown(start ~= nil)
	local answer = Data:Pending("answer", war.id)
	local pendingAccept, pendingWithdraw = answer and answer.data.accept == true, answer and answer.data.accept == false
	local answered = t.accepted or t.withdrawn or pendingAccept or pendingWithdraw
	local open = start and ctx.now < prep
	local canAct = ctx.officer and not ctx.looking and open and not answered
	panel.accept:SetShown(canAct)
	panel.withdraw:SetShown(canAct)
	panel.accept:SetEnabled(ctx.app)
	panel.withdraw:SetEnabled(ctx.app)
	W:Explain(panel.withdraw, "Withdraw", format("No war. Your stake goes back to the treasury and %s keeps %s.\n\nYou can accept or withdraw until prep starts; no answer counts as accepting.", holder, GuildWars:Short(war.zone)))
	panel.attackStatus:SetText(t.withdrawn and Theme:Colorize("Withdrawn: the stake is back in the treasury.", C.muted)
		or t.accepted and Theme:Colorize("Accepted. The roster is next.", C.green)
		or (pendingAccept or pendingWithdraw) and Theme:Colorize("Sent; waiting for the site", C.amber)
		or Data:Refused("answer", war.id) and Theme:Colorize(Data:Refused("answer", war.id), C.red)
		or start and not open and "Prep has started: no answer counted as accepting."
		or not start and tonumber(t.deadline) and format("%s picks by %s, or the war is at 8:00 PM the next evening.", holder, date("%a ", t.deadline)..GuildWars:Clock(t.deadline))
		or not ctx.officer and "Members see this page without its buttons." or "")
end

GuildWars.PANELS.time = {
	-- Two views on one step, each on its own frame: the defenders' grid, the attackers' answer
	build = function(panel, width)
		panel.defend = CreateFrame("Frame", nil, panel)
		panel.defend:SetAllPoints()
		panel.defend.outer = panel
		private.BuildDefend(panel.defend, width)
		panel.attack = CreateFrame("Frame", nil, panel)
		panel.attack:SetAllPoints()
		private.BuildAttack(panel.attack, width)
	end,
	refresh = function(panel, war, ctx)
		local defending = war.role == "defend"
		panel.defend:SetShown(defending)
		panel.attack:SetShown(not defending)
		if defending then
			private.RefreshDefend(panel.defend, war, ctx)
		else
			private.RefreshAttack(panel.attack, war, ctx)
		end
	end,
}
