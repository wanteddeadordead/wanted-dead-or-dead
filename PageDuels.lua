-- Wanted: your duels, a tab of Progress. Your record, how you do against each class and spec, how you do as each of
-- your own builds, and the duels themselves, newest first. An opponent who runs Wanted shows by name; anyone else as
-- their spec and class ("Frost Mage").

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Duels = Wanted.Duels
local private = { view = "matchups" }
local ROW_HEIGHT = 32
local LIST_TOP = 146
local COLUMN_X = { 16, 300, 420, 520 }
local HEADERS = {
	matchups = { "Opponent", "Won-lost", "Duels", "Won" },
	builds = { "Your build", "Won-lost", "Duels", "Won" },
	recent = { "Opponent", "Result", "Length", "When" },
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
	if private.view == "recent" then
		local result = RESULTS[item.result] or RESULTS.none
		cells[1]:SetText(Theme:ClassName(Duels:Opponent(item.them), item.them.class))
		cells[2]:SetText(Theme:Colorize(result[1]..(item.fled and " (fled)" or ""), result[2]))
		cells[3]:SetText(private.Length(item.length))
		cells[4]:SetText(private.When(item.startAt))
	else
		cells[1]:SetText(Theme:ClassName(item.label, item.class))
		cells[2]:SetText(private.Record(item.won, item.lost))
		cells[3]:SetText(tostring(item.games))
		cells[4]:SetText(private.Share(item.won, item.games))
	end
end

---A recent duel's details: where, both specializations and what each had left.
function private.ShowTooltip(row, item)
	if private.view ~= "recent" then
		return
	end
	local function Side(side)
		local left = type(side.health) == "number" and format(", %d%% health", side.health) or ""
		return Duels:Build(side)..left
	end
	GameTooltip:SetOwner(row, "ANCHOR_CURSOR_RIGHT", 16, 0)
	GameTooltip:SetText(Theme:Plain(Duels:Opponent(item.them)), 1, 1, 1)
	GameTooltip:AddLine(Theme:Plain(item.zone)..(item.toTheDeath and ", to the death" or "")..", "..date("%A %b %d, %H:%M", item.startAt),
		C.muted[1], C.muted[2], C.muted[3])
	GameTooltip:AddLine("Them: "..Side(item.them), 1, 1, 1)
	GameTooltip:AddLine("You: "..Side(item.me), 1, 1, 1)
	GameTooltip:Show()
end

function private.Refresh()
	if not private.list then
		return
	end
	local sheet = Duels:GetSheet()
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
	private.list:SetItems(private.view == "recent" and sheet.recent or sheet[private.view], empty, hint)
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
			{ key = "recent", label = "Recent duels" },
		}, function(key)
			private.view = key
			private.Refresh()
		end, 150)
		segment:SetPoint("TOPLEFT", 0, -84)
		segment:Select(private.view, true)

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
		private.list = list
	end,
	refresh = private.Refresh,
})
