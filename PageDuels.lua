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
	GameTooltip:SetText(Theme:Plain(Duels:Opponent(duel.them)), 1, 1, 1)
	GameTooltip:AddLine(Theme:Plain(duel.zone)..(duel.toTheDeath and ", to the death" or "")..", "..date("%A %b %d, %H:%M", duel.startAt),
		C.muted[1], C.muted[2], C.muted[3])
	GameTooltip:AddLine("Them: "..Side(duel.them), 1, 1, 1)
	GameTooltip:AddLine("You: "..Side(duel.me), 1, 1, 1)
	GameTooltip:Show()
end

---A click on a matchup opens it to its duels, or closes it.
function private.OnClick(item)
	if private.view == "matchups" and not item.duel then
		private.open[item.label] = not private.open[item.label] or nil
		private.Refresh()
	end
end

-- What the notice beside the tabs says about the last duel's fight report, and whether a reload would help
local REPORT_NOTES = {
	save = { "Your last duel isn't saved for the Wanted app yet.", true },
	reading = { "The Wanted app is reading your last duel from the combat log. Reload in a minute.", true },
	noapp = { "Fight reports need the Wanted app running on this PC." },
	nolog = { "No combat log for your last duel, so no fight report." },
}

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
	end,
	refresh = private.Refresh,
})
