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
	if item.tree then
		-- An open build's first line: its talents in the game's own talent frame
		cells[1]:SetText(Theme:Colorize("    See talent tree", C.gold))
		for i = 2, 4 do
			cells[i]:SetText("")
		end
		return
	end
	if duel then
		-- One duel of an open row: when, the result, how long, and the opponent's level (in a matchup) or who it was
		-- against and your points then (in a build)
		local result = RESULTS[duel.result] or RESULTS.none
		local when = "    "..private.When(duel.startAt)
		local last = type(duel.them.level) == "number" and Theme:Colorize("Level "..duel.them.level, C.faint) or ""
		if private.view == "builds" then
			when = when.."  vs "..Duels:Build(Duels:Side(duel, "them"))
			last = Theme:Colorize(Duels:Points(duel, "me") or "", C.faint)
		end
		cells[1]:SetText(Theme:Colorize(when, C.muted))
		cells[2]:SetText(Theme:Colorize(result[1]..(duel.fled and " (fled)" or ""), result[2]))
		cells[3]:SetText(private.Length(duel.length))
		cells[4]:SetText(last)
		return
	end
	local mark = Theme:Colorize(private.open[private.view..item.label] and "- " or "+ ", C.faint)
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

---A click on a matchup or build opens it to its duels, or closes it; a click on a duel shows its fight card, on See
---talent tree the build's newest loadout in the game's talent frame.
function private.OnClick(item)
	if item.tree then
		local row = item.tree
		private.ShowTree(row.loadout, row.specId, row.level)
	elseif item.duel then
		private.ShowCard(item.duel)
	else
		local key = private.view..item.label
		private.open[key] = not private.open[key] or nil
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
	-- Opens Blizzard's own talent frame on this side's build, as a talent build link does
	lane.tree = W:Button(card, "See talent tree", "secondary", 120, 22, function()
		private.ShowTree(lane.loadout, lane.specId, lane.level)
	end)
	lane.tree:SetPoint("BOTTOMRIGHT", lane.graph, "TOPRIGHT", 0, 4)
	-- What they wore, item by item, in the card's gear panel
	lane.gearButton = W:Button(card, "See gear", "secondary", 90, 22, function()
		private.ShowGear()
	end)
	lane.gearButton:SetPoint("RIGHT", lane.tree, "LEFT", -6, 0)
	lane.used = Theme:Text(card, "small", "", C.faint)
	lane.used:SetPoint("TOPLEFT", lane.strip, "BOTTOMLEFT", 0, -4)
	lane.used:SetWidth(graphWidth)
	lane.used:SetJustifyH("LEFT")
	lane.used:SetWordWrap(true)
	return lane
end

local QUALITY_NAMES = { [0] = "grey", [1] = "white", [2] = "green", [3] = "blue", [4] = "purple", [5] = "orange" }

---"Gear: item level 24.5 (3 blue, 10 green)", or what's known.
function private.GearText(gear)
	if type(gear) ~= "table" then
		return nil
	end
	local score = Duels:GearScore(gear)
	if not score then
		return "Gear: loading item levels..."
	end
	local counts = {}
	for q = 5, 2, -1 do
		if score.quality[q] then
			counts[#counts + 1] = score.quality[q].." "..QUALITY_NAMES[q]
		end
	end
	return format("Gear: item level %.1f%s", score.ilvl, #counts > 0 and (" ("..table.concat(counts, ", ")..")") or "")
end

---A headline when one side wore clearly better gear (3 or more average item levels): it explains a lot of a fight.
function private.GearGap(duel)
	local mine = Duels:GearScore(type(duel.me) == "table" and duel.me.gear)
	local theirs = Duels:GearScore(type(duel.them) == "table" and duel.them.gear)
	if not (mine and theirs) then
		return nil
	end
	local gap = theirs.ilvl - mine.ilvl
	if gap >= 3 then
		return Theme:Colorize(format("They out-geared you: average item level %.1f to your %.1f.", theirs.ilvl, mine.ilvl), C.red)
	elseif gap <= -3 then
		return Theme:Colorize(format("You out-geared them: average item level %.1f to their %.1f.", mine.ilvl, theirs.ilvl), C.green)
	end
	return nil
end

local SLOT_LABELS = { [1] = "Head", [2] = "Neck", [3] = "Shoulder", [4] = "Shirt", [5] = "Chest", [6] = "Waist", [7] = "Legs",
	[8] = "Feet", [9] = "Wrist", [10] = "Hands", [11] = "Finger", [12] = "Finger", [13] = "Trinket", [14] = "Trinket",
	[15] = "Back", [16] = "Main hand", [17] = "Off hand", [18] = "Ranged", [19] = "Tabard" }
-- The character window's own layout: its slot names (for the game's empty-slot art), left column, right column, and
-- the weapons along the bottom
local SLOT_NAMES = { [1] = "HeadSlot", [2] = "NeckSlot", [3] = "ShoulderSlot", [4] = "ShirtSlot", [5] = "ChestSlot",
	[6] = "WaistSlot", [7] = "LegsSlot", [8] = "FeetSlot", [9] = "WristSlot", [10] = "HandsSlot", [11] = "Finger0Slot",
	[12] = "Finger1Slot", [13] = "Trinket0Slot", [14] = "Trinket1Slot", [15] = "BackSlot", [16] = "MainHandSlot",
	[17] = "SecondaryHandSlot", [18] = "RangedSlot", [19] = "TabardSlot" }
local DOLL_LEFT = { 1, 2, 3, 15, 5, 4, 19, 9 }
local DOLL_RIGHT = { 10, 6, 7, 8, 11, 12, 13, 14 }
local DOLL_BOTTOM = { 16, 17, 18 }
local SLOT_SIZE, SLOT_GAP = 36, 5

---The game's empty-slot picture for a slot, as the character window shows it.
function private.EmptySlotTexture(slot)
	local info = C_PaperDollInfo and C_PaperDollInfo.GetInventorySlotInfo or GetInventorySlotInfo
	if info and SLOT_NAMES[slot] then
		local ok, _, texture = pcall(info, SLOT_NAMES[slot])
		if ok and texture then
			return texture
		end
	end
	return 136516 -- the plain empty slot
end

---One slot of the paper doll: the item's icon in a border of its quality, its level, the game's tooltip on hover.
function private.CreateDollSlot(panel, slot)
	local button = CreateFrame("Button", nil, panel)
	button:SetSize(SLOT_SIZE, SLOT_SIZE)
	button.slot = slot
	button.icon = button:CreateTexture(nil, "ARTWORK")
	button.icon:SetAllPoints()
	button.border = button:CreateTexture(nil, "OVERLAY")
	button.border:SetPoint("TOPLEFT", -2, 2)
	button.border:SetPoint("BOTTOMRIGHT", 2, -2)
	button.border:SetColorTexture(1, 1, 1, 0)
	button.level = Theme:Text(button, "tiny", "")
	button.level:SetPoint("BOTTOMRIGHT", -2, 2)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if self.item then
			GameTooltip:SetHyperlink(self.item)
		else
			GameTooltip:SetText(SLOT_LABELS[self.slot] or "", 1, 1, 1)
			GameTooltip:AddLine("Nothing worn here", C.muted[1], C.muted[2], C.muted[3])
		end
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return button
end

---The gear panel: a paper doll laid out like the character window, for you or for them (a toggle), with the
---average item level and the count by quality in the middle where the character would stand.
function private.BuildGearPanel(card, width)
	-- Scrolls inside the card when the card is shorter than the doll
	local frame = CreateFrame("ScrollFrame", nil, card, "UIPanelScrollFrameTemplate")
	frame.scrollBarHideable = true
	frame:SetPoint("TOPLEFT", 0, -38)
	frame:SetPoint("BOTTOMRIGHT", -26, 8)
	frame:Hide()
	local dollHeight = #DOLL_LEFT * (SLOT_SIZE + SLOT_GAP)
	local panel = CreateFrame("Frame", nil, frame)
	panel:SetSize(width - 30, 40 + dollHeight + SLOT_SIZE + 20)
	frame:SetScrollChild(panel)
	panel.frame = frame
	panel.back = W:Button(panel, "Back to the fight", "secondary", 140, 22, function() private.HideGear() end)
	panel.back:SetPoint("TOPRIGHT", -4, 0)
	panel.sideToggle = W:Segmented(panel, { { key = "them", label = "Them" }, { key = "me", label = "You" } }, function(key)
		private.gearSide = key
		private.FillDoll()
	end, 90)
	panel.sideToggle:SetPoint("TOPLEFT", 14, 0)
	local dollWidth = min(width - 60, 420)
	local left, top = floor((width - 30 - dollWidth) / 2), -36
	panel.slots = {}
	for i, slot in ipairs(DOLL_LEFT) do
		local b = private.CreateDollSlot(panel, slot)
		b:SetPoint("TOPLEFT", left, top - (i - 1) * (SLOT_SIZE + SLOT_GAP))
		panel.slots[slot] = b
	end
	for i, slot in ipairs(DOLL_RIGHT) do
		local b = private.CreateDollSlot(panel, slot)
		b:SetPoint("TOPLEFT", left + dollWidth - SLOT_SIZE, top - (i - 1) * (SLOT_SIZE + SLOT_GAP))
		panel.slots[slot] = b
	end
	local bottomLeft = left + floor((dollWidth - #DOLL_BOTTOM * (SLOT_SIZE + SLOT_GAP)) / 2)
	for i, slot in ipairs(DOLL_BOTTOM) do
		local b = private.CreateDollSlot(panel, slot)
		b:SetPoint("TOPLEFT", bottomLeft + (i - 1) * (SLOT_SIZE + SLOT_GAP), top - dollHeight - 6)
		panel.slots[slot] = b
	end
	panel.summary = Theme:Text(panel, "body", "")
	panel.summary:SetPoint("TOP", panel, "TOPLEFT", left + dollWidth / 2, top - dollHeight / 2 + 30)
	panel.summary:SetWidth(dollWidth - 2 * SLOT_SIZE - 30)
	panel.summary:SetJustifyH("CENTER")
	panel.summary:SetWordWrap(true)
	card.gearPanel = panel
end

---Fills the paper doll with one side's recorded gear.
function private.FillDoll()
	local card, duel = private.card, private.cardDuel
	if not (card and duel) then
		return
	end
	local panel = card.gearPanel
	local key = private.gearSide or "them"
	local side = type(duel[key]) == "table" and duel[key] or {}
	local gear = side.gear
	local items = type(gear) == "table" and type(gear.items) == "table" and gear.items or {}
	for slot, button in pairs(panel.slots) do
		local item = items[slot]
		button.item = item
		local level, quality
		if item then
			level, quality = Duels:ItemLevel(item)
			local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(tonumber(strmatch(item, "^item:(%d+)")) or 0)
			button.icon:SetTexture(icon or 134400)
			button.icon:SetDesaturated(false)
		else
			button.icon:SetTexture(private.EmptySlotTexture(slot))
		end
		local r, g, b = 1, 1, 1
		if quality and C_Item and C_Item.GetItemQualityColor then
			r, g, b = C_Item.GetItemQualityColor(quality)
		end
		button.border:SetColorTexture(r, g, b, item and quality and quality >= 2 and 0.6 or 0)
		button.border:SetDrawLayer("BACKGROUND")
		button.level:SetText(level and tostring(level) or "")
	end
	local score = Duels:GearScore(gear)
	local who = key == "me" and "You" or Duels:Describe(Duels:Side(duel, "them"))
	local lines = { who }
	if score then
		lines[#lines + 1] = format("Item level %.1f", score.ilvl)
		local counts = {}
		for q = 5, 2, -1 do
			if score.quality[q] then
				counts[#counts + 1] = score.quality[q].." "..QUALITY_NAMES[q]
			end
		end
		if #counts > 0 then
			lines[#lines + 1] = table.concat(counts, ", ")
		end
	elseif next(items) then
		lines[#lines + 1] = "Loading item levels..."
	else
		lines[#lines + 1] = key == "me" and "Not recorded for this duel" or "Not seen (the addon couldn't inspect them)"
	end
	panel.summary:SetText(table.concat(lines, "\n"))
	panel.sideToggle:Select(key, true)
end

function private.ShowGear()
	local card, duel = private.card, private.cardDuel
	if not (card and duel) then
		return
	end
	private.HideTimeline()
	private.gearSide = "them"
	private.FillDoll()
	card.scroll:Hide()
	card.gearPanel.frame:SetVerticalScroll(0)
	card.gearPanel.frame:Show()
end

function private.HideGear()
	if private.card then
		private.card.gearPanel.frame:Hide()
		private.card.scroll:Show()
	end
end

-- ============================================================================
-- The timeline: every cast, blow and control of the fight, in order (Duels:Timeline)
-- ============================================================================

local TIMELINE_ROW = 20
local TIMELINE_TOP = 34

function private.BuildTimelinePanel(card, width)
	local frame = CreateFrame("ScrollFrame", nil, card, "UIPanelScrollFrameTemplate")
	frame.scrollBarHideable = true
	frame:SetPoint("TOPLEFT", 0, -38)
	frame:SetPoint("BOTTOMRIGHT", -26, 8)
	frame:Hide()
	local panel = CreateFrame("Frame", nil, frame)
	panel:SetSize(width - 30, TIMELINE_TOP)
	frame:SetScrollChild(panel)
	panel.frame = frame
	panel.back = W:Button(panel, "Back to the fight", "secondary", 140, 22, function() private.HideTimeline() end)
	panel.back:SetPoint("TOPRIGHT", -4, 0)
	panel.filter = W:Segmented(panel, { { key = "all", label = "Both" }, { key = "mine", label = "You" }, { key = "theirs", label = "Them" } }, function(key)
		private.timelineFilter = key
		private.FillTimeline()
	end, 80)
	panel.filter:SetPoint("TOPLEFT", 14, 0)
	panel.note = Theme:Text(panel, "small", "", C.muted)
	panel.note:SetJustifyH("LEFT")
	panel.width = width - 30
	panel.rows = {}
	card.timelinePanel = panel
end

---The nth line of the timeline, made once: the time, whose, the spell's icon and name, and what it did; hovering it
---shows the spell's tooltip.
function private.TimelineRow(panel, i)
	local row = panel.rows[i]
	if row then
		return row
	end
	row = CreateFrame("Frame", nil, panel)
	row:SetHeight(TIMELINE_ROW)
	row:SetPoint("TOPLEFT", 0, -TIMELINE_TOP - (i - 1) * TIMELINE_ROW)
	row:SetPoint("TOPRIGHT", 0, -TIMELINE_TOP - (i - 1) * TIMELINE_ROW)
	row.clock = Theme:Text(row, "small", "", C.muted)
	row.clock:SetPoint("LEFT", 14, 0)
	row.who = Theme:Text(row, "small", "")
	row.who:SetPoint("LEFT", 56, 0)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", 104, 0)
	row.text = Theme:Text(row, "small", "")
	row.text:SetPoint("LEFT", 126, 0)
	row.text:SetPoint("RIGHT", -8, 0)
	row.text:SetJustifyH("LEFT")
	row.text:SetWordWrap(false)
	row:EnableMouse(true)
	row:SetScript("OnEnter", function(self)
		if self.spellId then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetSpellByID(self.spellId)
			GameTooltip:Show()
		end
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	panel.rows[i] = row
	return row
end

---Fills the timeline with the open duel's events, both sides' or one's.
function private.FillTimeline()
	local card, duel = private.card, private.cardDuel
	if not (card and duel) then
		return
	end
	local panel = card.timelinePanel
	local _, report = Duels:ReportState(duel)
	local lines, cut = Duels:Timeline(report)
	local filter = private.timelineFilter or "all"
	local n = 0
	for _, line in ipairs(lines or {}) do
		if filter == "all" or (filter == "mine") == line.mine then
			n = n + 1
			local row = private.TimelineRow(panel, n)
			row.spellId = line.id
			row.clock:SetText(line.clock)
			row.who:SetText(line.mine and Theme:Colorize("You", C.green) or Theme:Colorize("Them", C.red))
			row.icon:SetTexture(line.icon)
			row.icon:SetShown(line.icon ~= nil)
			local what = line.text ~= "" and ("  "..Theme:Colorize(line.text, line.low and C.red or C.muted)) or ""
			row.text:SetText(Theme:Plain(line.spell)..what)
			row:Show()
		end
	end
	for i = n + 1, #panel.rows do
		panel.rows[i].text:SetText("")
		panel.rows[i]:Hide()
	end
	panel.note:ClearAllPoints()
	panel.note:SetPoint("TOPLEFT", 14, -TIMELINE_TOP - n * TIMELINE_ROW - 6)
	panel.note:SetText(n == 0 and "Nothing here." or cut and "The fight ran long: its timeline ends here." or "")
	panel:SetHeight(TIMELINE_TOP + n * TIMELINE_ROW + 30)
	panel.filter:Select(filter, true)
end

function private.ShowTimeline()
	local card = private.card
	if not (card and private.cardDuel) then
		return
	end
	private.HideGear()
	private.timelineFilter = "all"
	private.FillTimeline()
	card.scroll:Hide()
	card.timelinePanel.frame:SetVerticalScroll(0)
	card.timelinePanel.frame:Show()
end

function private.HideTimeline()
	local card = private.card
	if card and card.timelinePanel and card.timelinePanel.frame:IsShown() then
		card.timelinePanel.frame:Hide()
		card.scroll:Show()
	end
end

---Opens the game's talent frame showing a recorded loadout (out of combat only: the talent frame is a protected
---panel). This client has the talent build link's own handler; without it, the frame is told the loadout directly.
function private.ShowTree(loadout, specId, level)
	if type(loadout) ~= "string" or loadout == "" then
		return
	end
	if InCombatLockdown() then
		Wanted:Print("The talent tree opens once you're out of combat.")
		return
	end
	-- The talent frame is a "center" panel: showing it closes every frame on UISpecialFrames, this window included.
	-- It's opened again beside it, on the same card
	local wasShown = UI:GetFrame():IsShown()
	local ok = pcall(function()
		if not PlayerSpellsFrame and PlayerSpellsFrame_LoadUI then
			PlayerSpellsFrame_LoadUI()
		end
		if PlayerSpellsUtil and PlayerSpellsUtil.InspectLoadout then
			PlayerSpellsUtil.InspectLoadout(format("%d:%d:%s", tonumber(specId) or 0, tonumber(level) or 0, loadout))
		else
			PlayerSpellsFrame:SetInspectString(loadout, tonumber(level))
			ShowUIPanel(PlayerSpellsFrame)
		end
	end)
	if wasShown and not UI:GetFrame():IsShown() then
		UI:GetFrame():Show()
	end
	if not ok then
		Wanted:Print("The game couldn't show that talent tree.")
	end
end

---Fills a lane from one side of a report (v1): health as the last reading at each bar's moment ({ t, pct } pairs),
---control as gold marks across the fight, and what they used (spells: every spell, from the timeline; without one, the
---defensives, escapes and controls and when).
function private.FillLane(lane, side, length, gearText, spells)
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
			controls[#controls + 1] = format("%s (%.1f s)", private.CleanText(c.spell), c.to - c.from)
		else
			mark:Hide()
		end
	end
	local used = {}
	for _, u in ipairs(type(side.cds) == "table" and side.cds or {}) do
		if type(u) == "table" then
			used[#used + 1] = private.CleanText(u.spell).." at "..private.Clock(u.t)
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
		-- The talents themselves are a click away (See talent tree)
		buildText = "Build: "..private.CleanText(build.spec)..(#points > 0 and (" ("..table.concat(points, "/")..")") or "").."\n"
	end
	-- Every spell this side used, from the timeline; a report without one (older than the newest 20) has the
	-- defensives, escapes and controls the app keeps for its tips
	local usedText = spells and ("Used: "..(#spells > 0 and table.concat(spells, ", ") or "nothing but melee"))
		or ("Defensives, escapes and controls used: "..(#used > 0 and table.concat(used, ", ") or "none"))
	lane.used:SetText(buildText..(gearText and (gearText.."\n") or "")..(#controls > 0 and ("Crowd-controlled by: "..table.concat(controls, ", ").."\n") or "")
		..usedText)
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
	-- Duel coaching is new: its tips are marked so, with a word on where to send a wrong one
	card.experimental = W:Pill(card)
	card.experimental:SetPoint("RIGHT", card.back, "LEFT", -8, 0)
	card.experimental:EnableMouse(true)
	card.experimental:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText("Experimental", 1, 1, 1)
		GameTooltip:AddLine("Duel coaching is new: a tip can be wrong. /wanted bug sends us one that is.", C.muted[1], C.muted[2], C.muted[3], true)
		GameTooltip:Show()
	end)
	card.experimental:SetScript("OnLeave", function() GameTooltip:Hide() end)
	-- Every cast, blow and control of the fight, in order (the newest reports carry it)
	card.timelineButton = W:Button(card, "Timeline", "secondary", 90, 24, function() private.ShowTimeline() end)
	card.timelineButton:SetPoint("RIGHT", card.experimental, "LEFT", -8, 0)
	-- Everything under the title scrolls together: the opener, both lanes and the findings with their tips
	card.scroll = CreateFrame("ScrollFrame", nil, card, "UIPanelScrollFrameTemplate")
	card.scroll.scrollBarHideable = true
	card.scroll:SetPoint("TOPLEFT", 0, -38)
	card.scroll:SetPoint("BOTTOMRIGHT", -26, 8)
	local body = CreateFrame("Frame", nil, card.scroll)
	body:SetSize(width - 30, 1)
	card.scroll:SetScrollChild(body)
	card.body = body
	card.note = Theme:Text(body, "small", "", C.muted)
	card.note:SetPoint("TOPLEFT", 14, 0)
	card.note:SetWidth(width - 60 - 130) -- clear of the first lane's "See talent tree" button
	card.note:SetJustifyH("LEFT")
	card.note:SetWordWrap(true)
	local graphWidth = max(width - 140, 120)
	card.lanes = {
		me = private.CreateLane(body, "You", -40, C.green, graphWidth),
		them = private.CreateLane(body, "Them", -150, C.red, graphWidth),
	}
	card.findings = Theme:Text(body, "body", "")
	card.findings:SetPoint("TOPLEFT", 14, -244)
	card.findings:SetWidth(width - 60)
	card.findings:SetJustifyH("LEFT")
	card.findings:SetWordWrap(true)
	card.findings:SetSpacing(3)
	private.BuildGearPanel(card, width)
	private.BuildTimelinePanel(card, width)
	private.card = card
end

---Shows a duel's fight card in place of the list.
function private.ShowCard(duel)
	local card = private.card
	if not card then
		return
	end
	-- Another duel opens at its top; the same one redrawn (the window's refresh) stays where it was
	local another = private.cardDuel ~= duel or not card:IsShown()
	if another then
		private.HideGear()
		private.HideTimeline()
	end
	private.cardDuel = duel
	local result = RESULTS[duel.result] or RESULTS.none
	card.title:SetText(format("vs %s   %s   %s   %s", Theme:ClassName(Duels:Opponent(Duels:Side(duel, "them")), duel.them.class),
		Theme:Colorize(result[1], result[2]), private.Length(duel.length), private.When(duel.startAt)))
	local state, report = Duels:ReportState(duel)
	local hasReport = state == "ready"
	card.experimental:Set(hasReport and "Experimental" or nil, C.gold)
	card.timelineButton:SetShown(hasReport and Duels:Timeline(report) ~= nil)
	local opener = hasReport and type(report.opener) == "string" and private.CleanText(report.opener) or ""
	-- The opener is often one of the findings too: said once, there
	for _, f in ipairs(hasReport and type(report.findings) == "table" and report.findings or {}) do
		if type(f) == "table" and private.CleanText(f.text) == opener then
			opener = ""
		end
	end
	opener = opener ~= "" and ("   "..opener) or ""
	if hasReport and report.partial then
		-- The app waited for the rest of the duel's combat log and it never came: what it read is all there is
		opener = opener.."   "..Theme:Colorize("(the combat log ends before the duel did: this is part of it)", C.gold)
	end
	-- Made under the Forever Open's rules (the app's tournament setting): its tips follow them
	if hasReport and report.mode == "tournament" then
		opener = "   "..Theme:Colorize("Tournament rules", C.gold)..opener
	end
	local gap = private.GearGap(duel)
	opener = opener..(gap and ("   "..gap) or "")
	card.note:SetText(hasReport and (Duels:Describe(Duels:Side(duel, "them"))..opener)
		or (state == "nolog" and type(report) == "table" and type(report.why) == "string" and ("No fight report: "..private.CleanText(report.why)))
		or private.AppNote()
		or ((REPORT_NOTES[state] or {})[1] or "No fight report for this duel."))
	for key, lane in pairs(card.lanes) do
		for _, part in ipairs({ lane.label, lane.graph, lane.strip, lane.used }) do
			part:SetShown(hasReport)
		end
		if hasReport then
			private.FillLane(lane, report[key], report.len, private.GearText(type(duel[key]) == "table" and duel[key].gear),
				Duels:SpellsUsed(report, key == "me"))
		end
		-- The loadout is the duel record's own (the addon read it by inspect), shown whether or not a report came
		local side = type(duel[key]) == "table" and duel[key] or {}
		lane.loadout, lane.specId, lane.level = side.loadout, side.specId, side.level
		lane.tree:SetShown(hasReport and type(side.loadout) == "string" and side.loadout ~= "")
		lane.gearButton:SetShown(hasReport and key == "them" and ((duel.me and duel.me.gear) or (duel.them and duel.them.gear)) and true or false)
	end
	local findings = hasReport and type(report.findings) == "table" and report.findings or {}
	local lines = {}
	for i = 1, CARD_FINDINGS do
		local f = findings[i]
		if type(f) == "table" and type(f.text) == "string" then
			local tip = type(f.tip) == "string" and ("\n"..Theme:Colorize(private.CleanText(f.tip), C.muted)) or ""
			lines[#lines + 1] = i..". "..private.CleanText(f.text)..tip
		end
	end
	card.findings:SetText(table.concat(lines, "\n\n"))
	card.findings:SetShown(#lines > 0)
	card.body:SetHeight(244 + max(card.findings:GetStringHeight(), 1) + 12)
	if another then
		card.scroll:SetVerticalScroll(0)
	end
	private.list:Hide()
	private.headerBar:Hide()
	card:Show()
end

function private.HideCard()
	private.HideGear()
	private.HideTimeline()
	private.cardDuel = nil
	if private.card then
		private.card:Hide()
	end
	if private.list then
		private.list:Show()
		private.headerBar:Show()
	end
end


---What to do about the app, when it's what keeps fight cards away: not installed, too old, or not running.
function private.AppNote()
	local state, version = Duels:AppState()
	if state == "none" then
		return "Fight cards need the free Wanted app: wanteddeadordead.com/app"
	elseif state == "old" then
		return format("Fight cards need Wanted app %s or newer (you have %s): update it from its tray menu or wanteddeadordead.com/app",
			Duels.MIN_APP, Theme:Plain(version))
	elseif state == "stopped" then
		return "Start the Wanted app, then /reload, for fight cards."
	end
	return nil
end

---The notice beside the tabs: the app, when it's what keeps fight cards away, else the last duel's fight report
---while it isn't in yet.
function private.ShowReportNote(last)
	local appNote = last and Duels:ReportState(last) ~= "ready" and private.AppNote()
	if appNote then
		private.reportText:SetText(Theme:Colorize(appNote, C.gold))
		private.reloadButton:Hide()
		return
	end
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
		if private.open[private.view..row.label] then
			if row.loadout then
				tinsert(items, { tree = row })
			end
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
