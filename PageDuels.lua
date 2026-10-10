-- Wanted: your duels, a tab of Progress. Your record, how you do against each class and spec (a click opens a matchup
-- to its duels, newest first), and how you do as each of your own builds. An opponent who runs Wanted shows by name; anyone else as
-- their spec and class ("Frost Mage").

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Duels = Wanted.Duels
local private = { view = "matchups", open = {} }
local ROW_HEIGHT = 32
local LIST_TOP = 146
local COLUMN_X = { 16, 300, 420, 520 }
local HEADERS = {
	matchups = { "Opponent", "Won-lost", "Duels", "Won" },
	builds = { "Your build", "Won-lost", "Duels", "Won" },
}
-- What the notice beside the tabs says about the last duel's fight report, and whether a reload would help
local REPORT_NOTES = {
	-- A /reload saves the duel and writes out the game's combat log together, so the app reads both at once
	save = { "Reload to send your last duel to the Wanted app.", true },
	reading = { "Reload once more to load your last duel's fight report.", true },
	noapp = { "Fight reports need the Wanted app running on this PC." },
	nolog = { "No combat log for your last duel, so no fight report." },
}
local RESULTS = {
	won = { "Won", C.green },
	lost = { "Lost", C.red },
	none = { "No result", C.faint },
}

---"12-7" with the wins in green and the losses in red.
function private.Record(won, lost)
	return Theme:Colorize(tostring(won), C.green).."-"..Theme:Colorize(tostring(lost), C.red)
end

---The share of duels won, as "63%" ("-" with none).
function private.Share(won, games)
	return games > 0 and format("%d%%", floor(won / games * 100 + 0.5)) or "-"
end

---"1:23" from seconds.
function private.Length(seconds)
	seconds = type(seconds) == "number" and max(floor(seconds), 0) or 0
	return format("%d:%02d", floor(seconds / 60), seconds % 60)
end

---When a duel was fought, in local time: "Oct 10 13:27".
function private.When(t)
	return date("%b %d %H:%M", t)
end

function private.CreateRow(row)
	row.cells = {}
	for i, x in ipairs(COLUMN_X) do
		local cell = Theme:Text(row, i == 1 and "body" or "small", "")
		cell:SetPoint("LEFT", x, 0)
		cell:SetWidth((COLUMN_X[i + 1] or x + 140) - x - 12)
		row.cells[i] = cell
	end
end

function private.UpdateRow(row, item)
	local cells = row.cells
	local duel = item.duel
	if duel then
		-- One duel of an open matchup: when, the result, how long, and the opponent's level
		local result = RESULTS[duel.result] or RESULTS.none
		cells[1]:SetText(Theme:Colorize("    "..private.When(duel.startAt), C.muted))
		cells[2]:SetText(Theme:Colorize(result[1]..(duel.fled and " (fled)" or ""), result[2]))
		cells[3]:SetText(private.Length(duel.length))
		cells[4]:SetText(type(duel.them.level) == "number" and Theme:Colorize("Level "..duel.them.level, C.faint) or "")
		return
	end
	local mark = private.view == "matchups" and Theme:Colorize(private.open[item.label] and "- " or "+ ", C.faint) or ""
	cells[1]:SetText(mark..Theme:ClassName(item.label, item.class))
	cells[2]:SetText(private.Record(item.won, item.lost))
	cells[3]:SetText(tostring(item.games))
	cells[4]:SetText(private.Share(item.won, item.games))
end

---One duel's details: where and when, both sides in full and what each had left.
function private.ShowTooltip(row, item)
	local duel = item.duel
	if not duel then
		return
	end
	local function Side(side)
		local left = type(side.health) == "number" and format(", %d%% health", side.health) or ""
		return Duels:Describe(side)..left
	end
	GameTooltip:SetOwner(row, "ANCHOR_CURSOR_RIGHT", 16, 0)
	GameTooltip:SetText(Theme:Plain(Duels:Opponent(Duels:Side(duel, "them"))), 1, 1, 1)
	GameTooltip:AddLine(Theme:Plain(duel.zone)..(duel.toTheDeath and ", to the death" or "")..", "..date("%A %b %d, %H:%M", duel.startAt),
		C.muted[1], C.muted[2], C.muted[3])
	GameTooltip:AddLine("Them: "..Side(Duels:Side(duel, "them")), 1, 1, 1)
	GameTooltip:AddLine("You: "..Side(Duels:Side(duel, "me")), 1, 1, 1)
	GameTooltip:Show()
end

---A click on a matchup opens it to its duels, or closes it; a click on a duel shows its fight card.
function private.OnClick(item)
	if item.duel then
		private.ShowCard(item.duel)
	elseif private.view == "matchups" then
		private.open[item.label] = not private.open[item.label] or nil
		private.Refresh()
	end
end



-- ============================================================================
-- The fight card: one duel as the Wanted app read it from the combat log (Duels:ReportState)
-- ============================================================================

local CARD_BARS = 40 -- health as this many bars across the fight
local GRAPH_HEIGHT = 34
local CARD_FINDINGS = 5
local CC_MARKS = 8

---A report's text as shown: no control characters or "|" (the game's escape codes), at most the app's 300 bytes.
function private.CleanText(text)
	return type(text) == "string" and strsub((gsub(text, "[%c|]", "")), 1, 300) or ""
end

---"0:15" from seconds into the fight.
function private.Clock(seconds)
	seconds = max(floor((tonumber(seconds) or 0) + 0.5), 0)
	return format("%d:%02d", floor(seconds / 60), seconds % 60)
end

---One side's lane on the card: a label, health bars, a strip of the control it suffered, what it used.
function private.CreateLane(card, label, y, color, graphWidth)
	local lane = { bars = {}, marks = {}, color = color, width = graphWidth }
	lane.label = Theme:Text(card, "small", label, C.muted)
	lane.label:SetPoint("TOPLEFT", 14, y - 10)
	lane.graph = CreateFrame("Frame", nil, card)
	lane.graph:SetPoint("TOPLEFT", 80, y)
	lane.graph:SetSize(graphWidth, GRAPH_HEIGHT)
	Theme:Fill(lane.graph, C.panelAlt or C.panel)
	local barWidth = graphWidth / CARD_BARS
	for i = 1, CARD_BARS do
		local bar = lane.graph:CreateTexture(nil, "ARTWORK")
		bar:SetColorTexture(color[1], color[2], color[3], 0.85)
		bar:SetPoint("BOTTOMLEFT", (i - 1) * barWidth, 0)
		bar:SetWidth(max(barWidth - 1, 1))
		lane.bars[i] = bar
	end
	lane.strip = CreateFrame("Frame", nil, card)
	lane.strip:SetPoint("TOPLEFT", lane.graph, "BOTTOMLEFT", 0, -3)
	lane.strip:SetSize(graphWidth, 5)
	for i = 1, CC_MARKS do
		local mark = lane.strip:CreateTexture(nil, "ARTWORK")
		mark:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.9)
		mark:SetPoint("TOPLEFT")
		mark:SetHeight(5)
		lane.marks[i] = mark
	end
	lane.used = Theme:Text(card, "small", "", C.faint)
	lane.used:SetPoint("TOPLEFT", lane.strip, "BOTTOMLEFT", 0, -4)
	lane.used:SetWidth(graphWidth)
	lane.used:SetJustifyH("LEFT")
	lane.used:SetWordWrap(true)
	return lane
end

---Fills a lane from one side of a report (v1): health as the last reading at each bar's moment ({ t, pct } pairs),
---control as gold marks across the fight, and the answers they used and when.
function private.FillLane(lane, side, length)
	side = type(side) == "table" and side or {}
	local hp = type(side.hp) == "table" and side.hp or {}
	length = (type(length) == "number" and length > 0) and length or 1
	local point, pct = 1, 100
	for i = 1, CARD_BARS do
		local at = length * (i - 0.5) / CARD_BARS
		while type(hp[point]) == "table" and type(hp[point][1]) == "number" and type(hp[point][2]) == "number" and hp[point][1] <= at do
			pct = hp[point][2]
			point = point + 1
		end
		lane.bars[i]:SetHeight(max(GRAPH_HEIGHT * min(max(pct, 0), 100) / 100, 1))
	end
	local cc = type(side.cc) == "table" and side.cc or {}
	local controls = {}
	for i, mark in ipairs(lane.marks) do
		local c = cc[i]
		if type(c) == "table" and type(c.from) == "number" and type(c.to) == "number" then
			local from, to = min(max(c.from / length, 0), 1), min(max(c.to / length, 0), 1)
			mark:ClearAllPoints()
			mark:SetPoint("TOPLEFT", from * lane.width, 0)
			mark:SetWidth(max((to - from) * lane.width, 2))
			mark:Show()
			controls[#controls + 1] = format("%s %.1f s", private.CleanText(c.spell), c.to - c.from)
		else
			mark:Hide()
		end
	end
	local used = {}
	for _, u in ipairs(type(side.cds) == "table" and side.cds or {}) do
		if type(u) == "table" then
			used[#used + 1] = private.CleanText(u.spell).." "..private.Clock(u.t)
		end
	end
	local build = type(side.build) == "table" and side.build or nil
	local buildText = ""
	if build and type(build.spec) == "string" then
		local points = {}
		for _, n in ipairs(type(build.points) == "table" and build.points or {}) do
			if type(n) == "number" then
				points[#points + 1] = tostring(floor(n))
			end
		end
		local talents = {}
		for _, t in ipairs(type(build.talents) == "table" and build.talents or {}) do
			talents[#talents + 1] = private.CleanText(t)
		end
		buildText = "Build: "..private.CleanText(build.spec)..(#points > 0 and (" ("..table.concat(points, "/")..")") or "")
			..(#talents > 0 and (": "..table.concat(talents, ", ")) or "").."\n"
	end
	lane.used:SetText(buildText..(#controls > 0 and ("Controlled: "..table.concat(controls, ", ").."   ") or "")
		..(#used > 0 and ("Used: "..table.concat(used, ", ")) or "Used nothing that counts"))
end

function private.BuildCard(container, width)
	local card = W:Card(container)
	card:SetPoint("TOPLEFT", 0, -LIST_TOP + 26)
	card:SetPoint("BOTTOMRIGHT")
	card:Hide()
	card.title = Theme:Text(card, "body", "")
	card.title:SetPoint("TOPLEFT", 14, -12)
	card.back = W:Button(card, "Back", "secondary", 70, 24, function() private.HideCard() end)
	card.back:SetPoint("TOPRIGHT", -10, -8)
	card.note = Theme:Text(card, "small", "", C.muted)
	card.note:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -6)
	local graphWidth = max(width - 110, 120)
	card.lanes = {
		me = private.CreateLane(card, "You", -56, C.green, graphWidth),
		them = private.CreateLane(card, "Them", -146, C.red, graphWidth),
	}
	card.findings = {}
	local above
	for i = 1, CARD_FINDINGS do
		local f = Theme:Text(card, "body", "")
		if above then
			f:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -8)
		else
			f:SetPoint("TOPLEFT", 14, -236)
		end
		f:SetWidth(width - 28)
		f:SetJustifyH("LEFT")
		f:SetWordWrap(true)
		card.findings[i] = f
		above = f
	end
	private.card = card
end

---Shows a duel's fight card in place of the list.
function private.ShowCard(duel)
	local card = private.card
	if not card then
		return
	end
	private.cardDuel = duel
	local result = RESULTS[duel.result] or RESULTS.none
	card.title:SetText(format("vs %s   %s   %s   %s", Theme:ClassName(Duels:Opponent(Duels:Side(duel, "them")), duel.them.class),
		Theme:Colorize(result[1], result[2]), private.Length(duel.length), private.When(duel.startAt)))
	local state, report = Duels:ReportState(duel)
	local hasReport = state == "ready"
	local opener = hasReport and type(report.opener) == "string" and ("   "..private.CleanText(report.opener)) or ""
	if hasReport and report.partial then
		-- The app waited for the rest of the duel's combat log and it never came: what it read is all there is
		opener = opener.."   "..Theme:Colorize("(the combat log ends before the duel did: this is part of it)", C.gold)
	end
	card.note:SetText(hasReport and (Duels:Describe(Duels:Side(duel, "them"))..opener)
		or (state == "nolog" and type(report) == "table" and type(report.why) == "string" and ("No fight report: "..private.CleanText(report.why)))
		or ((REPORT_NOTES[state] or {})[1] or "No fight report for this duel."))
	for key, lane in pairs(card.lanes) do
		for _, part in ipairs({ lane.label, lane.graph, lane.strip, lane.used }) do
			part:SetShown(hasReport)
		end
		if hasReport then
			private.FillLane(lane, report[key], report.len)
		end
	end
	local findings = hasReport and type(report.findings) == "table" and report.findings or {}
	for i, fs in ipairs(card.findings) do
		local f = findings[i]
		if type(f) == "table" and type(f.text) == "string" then
			local tip = type(f.tip) == "string" and ("\n"..Theme:Colorize(private.CleanText(f.tip), C.muted)) or ""
			fs:SetText(i..". "..private.CleanText(f.text)..tip)
			fs:Show()
		else
			fs:SetText("")
			fs:Hide()
		end
	end
	private.list:Hide()
	private.headerBar:Hide()
	card:Show()
end

function private.HideCard()
	private.cardDuel = nil
	if private.card then
		private.card:Hide()
	end
	if private.list then
		private.list:Show()
		private.headerBar:Show()
	end
end


---The notice beside the tabs: the last duel's fight report, while it isn't in yet.
function private.ShowReportNote(last)
	local note = last and REPORT_NOTES[(Duels:ReportState(last))]
	private.reportText:SetText(note and Theme:Colorize(note[1], C.muted) or "")
	private.reloadButton:SetShown(note and note[2] or false)
end

function private.Refresh()
	if not private.list then
		return
	end
	local sheet = Duels:GetSheet()
	private.ShowReportNote(sheet.recent[1])
	private.recordTile.value:SetText(private.Record(sheet.won, sheet.lost))
	private.recordTile.note:SetText(sheet.total > 0 and private.Share(sheet.won, sheet.total).." won" or "")
	local top = sheet.matchups[1]
	private.facedTile.value:SetText(top and Theme:Plain(top.label) or "-")
	private.facedTile.note:SetText(top and private.Record(top.won, top.lost) or "")
	local last = sheet.recent[1]
	local result = last and (RESULTS[last.result] or RESULTS.none)
	private.lastTile.value:SetText(result and Theme:Colorize(result[1], result[2]) or "-")
	private.lastTile.note:SetText(last and Theme:Ago(GetServerTime() - last.startAt) or "")
	for i, label in ipairs(private.headers) do
		label:SetText(strupper(HEADERS[private.view][i]))
	end
	local empty, hint = "No duels yet.", "Duel someone and it shows up here."
	local items = {}
	for _, row in ipairs(sheet[private.view]) do
		tinsert(items, row)
		if private.view == "matchups" and private.open[row.label] then
			for _, duel in ipairs(row.duels) do
				tinsert(items, { duel = duel })
			end
		end
	end
	private.list:SetItems(items, empty, hint)
	if private.cardDuel then
		private.ShowCard(private.cardDuel)
	end
end

UI:RegisterPage("duels", {
	group = "World PvP",
	title = "Duels",
	tabLabel = "Duels",
	subtitle = "Your duels: your record against each class and spec, and as each of your builds. Duels never count as kills.",
	order = 7.2,
	under = "challenges",
	build = function(container, width, height)
		local tileWidth = floor((width - 24) / 3)
		private.recordTile = W:StatTile(container, "Your record", C.accent)
		private.recordTile:SetPoint("TOPLEFT")
		private.recordTile:SetWidth(tileWidth)
		private.facedTile = W:StatTile(container, "Most faced", C.blue)
		private.facedTile:SetPoint("LEFT", private.recordTile, "RIGHT", 12, 0)
		private.facedTile:SetWidth(tileWidth)
		private.lastTile = W:StatTile(container, "Last duel", C.gold)
		private.lastTile:SetPoint("LEFT", private.facedTile, "RIGHT", 12, 0)
		private.lastTile:SetWidth(tileWidth)

		local segment = W:Segmented(container, {
			{ key = "matchups", label = "Matchups" },
			{ key = "builds", label = "Your builds" },
		}, function(key)
			private.view = key
			private.HideCard()
			private.Refresh()
		end, 150)
		segment:SetPoint("TOPLEFT", 0, -84)
		segment:Select(private.view, true)

		-- The game hands the app's fight reports to the addon only at a /reload: a button for it while one is due
		private.reloadButton = W:Button(container, "Reload", "secondary", 80, 26, function() C_UI.Reload() end)
		private.reloadButton:SetPoint("TOPRIGHT", 0, -84)
		private.reportText = Theme:Text(container, "small", "")
		private.reportText:SetPoint("LEFT", segment, "RIGHT", 16, 0)
		private.reportText:SetPoint("RIGHT", private.reloadButton, "LEFT", -12, 0)
		private.reportText:SetJustifyH("RIGHT")
		private.reportText:SetWordWrap(true)

		local headerBar = CreateFrame("Frame", nil, container)
		private.headerBar = headerBar
		headerBar:SetPoint("TOPLEFT", 0, -LIST_TOP + 26)
		headerBar:SetPoint("TOPRIGHT", 0, -LIST_TOP + 26)
		headerBar:SetHeight(24)
		local line = Theme:Line(headerBar)
		line:SetPoint("BOTTOMLEFT")
		line:SetPoint("BOTTOMRIGHT")
		private.headers = {}
		for i, x in ipairs(COLUMN_X) do
			private.headers[i] = W:SectionLabel(headerBar, "")
			private.headers[i]:SetPoint("LEFT", x, 0)
		end

		local list = W:List(container, ROW_HEIGHT, floor((height - LIST_TOP) / ROW_HEIGHT), private.CreateRow, private.UpdateRow)
		list:SetPoint("TOPLEFT", 0, -LIST_TOP)
		list:SetPoint("TOPRIGHT", 0, -LIST_TOP)
		list.onEnter = private.ShowTooltip
		list.onClick = private.OnClick
		private.list = list
		private.BuildCard(container, width)
	end,
	refresh = private.Refresh,
})
