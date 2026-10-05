-- Wanted: Rank & Gear, under Battlegrounds. Your Blizzard PvP rank as the game tells it: the ladder of fourteen ranks
-- with what each unlocks at the rank vendors, your points toward the next, this week's cap, Honor Points and your
-- battleground Marks of Honor. Wanted has no ranks of its own (docs/pvp-restructure-plan.md).

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local BlizzRank = Wanted.BlizzRank
local private = { rows = {}, marks = {} }
local LADDER_WIDTH = 400
local TITLE_LEFT, TITLE_WIDTH = 38, 166
local TAG_WIDTH = 40
local ROW_HEIGHT = 26
local BODY_TOP = 82 -- below the tiles

---A number with thousands separators: 12,500.
function private.Count(n)
	local text = tostring(floor(n or 0))
	repeat
		local changed
		text, changed = gsub(text, "^(%d+)(%d%d%d)", "%1,%2")
	until changed == 0
	return text
end

function private.RefreshTiles(r)
	local tile = private.rankTile
	if not r then
		tile.value:SetText("Not read yet")
		tile.note:SetText("")
	elseif r.rank < 1 then
		-- The Next card says when ranks start: the note would run into the value on a tile this wide
		tile.value:SetText("No rank yet")
		tile.note:SetText("")
	else
		-- "Lieutenant Commander (10)" doesn't fit a tile at the big font: smaller, then without the number
		local title = BlizzRank:Title(r.rank) or ""
		tile.value:SetWidth(tile:GetWidth() - 32)
		Theme:FitText(tile.value, tile:GetWidth() - 32, { title.."  ("..r.rank..")", title }, "heading")
		tile.note:SetText(r.rank < BlizzRank.MAX_RANK and r.toNext > 0 and format("%s / %s", private.Count(r.earned), private.Count(r.toNext)) or "")
	end
	tile = private.capTile
	if r and r.weekMax > 0 then
		tile.value:SetText(format("Rank %d of %d", r.weekMax, r.seasonMax))
		tile.note:SetText(r.week >= 0 and "week "..r.week or "")
	else
		tile.value:SetText("None")
		tile.note:SetText("when a season runs")
	end
	local have, most = BlizzRank:Honor()
	tile = private.honorTile
	tile.value:SetText(have and private.Count(have) or "Not read yet")
	tile.note:SetText(have and most and most > 0 and "of "..private.Count(most) or "")
end

---A rank's unlock, longest first, for the ladder's narrow column: "Elite Wrist Upgrade + Elite Waist Upgrade", then
---without "Elite" and "Faction", then "Wrist + Waist Upgrade", then "Wrist + Waist".
function private.UnlockLabels(unlock)
	local plain = gsub(gsub(unlock, "Elite ", ""), "Faction ", "")
	local labels = { unlock, plain }
	if strfind(plain, " %+ ") then
		local parts = {}
		for part in gmatch(plain, "[^+]+") do
			tinsert(parts, strtrim(part))
		end
		local last = parts[#parts]
		local suffix = strmatch(last, " (%a+)$")
		if suffix then
			local short = {}
			for k, part in ipairs(parts) do
				short[k] = gsub(part, " "..suffix.."$", "")
			end
			tinsert(labels, table.concat(short, " + ").." "..suffix)
			tinsert(labels, table.concat(short, " + "))
		end
	end
	return labels
end

function private.RefreshLadder(r)
	local unlocks = BlizzRank:Unlocks()
	local rank, cap = r and r.rank or 0, r and r.weekMax or 0
	for i, row in ipairs(private.rows) do
		local done, current = i < rank, i == rank
		local locked = i > rank
		local overCap = locked and cap > 0 and i > cap
		row.badge:SetTexture(BlizzRank:Badge(i))
		row.badge:SetDesaturated(locked)
		row.badge:SetAlpha(locked and 0.5 or 1)
		row.title:SetText(i.."  "..(BlizzRank:Title(i) or ""))
		row.title:SetTextColor(unpack(current and C.white or done and C.text or C.muted))
		Theme:FitText(row.unlock, row.unlockWidth, private.UnlockLabels(unlocks[i] or ""))
		row.unlock:SetTextColor(unpack(current and C.gold or done and C.muted or C.faint))
		row.tag:SetText(current and "You" or overCap and "capped" or "")
		row.tag:SetTextColor(unpack(current and C.accentHover or C.faint))
		row.bg:SetColorTexture(1, 1, 1, current and 0.06 or 0)
	end
end

function private.RefreshSide(r)
	for _, line in ipairs(private.marks) do
		local count = BlizzRank:MarkCount(line.mark.id)
		line.icon:SetTexture(BlizzRank:MarkIcon(line.mark.id) or 134400)
		line.count:SetText(count)
		line.count:SetTextColor(unpack(count > 0 and C.text or C.faint))
	end
	local card = private.nextCard
	local rank = r and r.rank or 0
	if not r or rank >= BlizzRank.MAX_RANK then
		card.title:SetText(r and "You're at the top rank" or "Your rank isn't read yet")
		card.unlock:SetText("")
		card.need:SetText("")
		card.cap:SetText("")
		return
	end
	local nextRank = rank + 1
	card.title:SetText(format("Rank %d  %s", nextRank, BlizzRank:Title(nextRank) or ""))
	Theme:FitText(card.unlock, card.width, { BlizzRank:Unlocks()[nextRank] or "", "" }, nil, true)
	if r.weekMax <= 0 then
		card.need:SetText("Ranks start with the PvP season.")
		card.cap:SetText("")
	else
		card.need:SetText(r.toNext > 0 and format("%s more points", private.Count(r.toNext - r.earned)) or "")
		card.cap:SetText(nextRank > r.weekMax and format("Not this week: the cap is Rank %d.", r.weekMax) or "")
	end
end

function private.Refresh()
	if not private.rankTile then
		return
	end
	local r = BlizzRank:Get()
	private.RefreshTiles(r)
	private.RefreshLadder(r)
	private.RefreshSide(r)
end

function private.BuildLadder(container, height)
	local card = W:Card(container)
	card:SetPoint("TOPLEFT", 0, -BODY_TOP)
	card:SetSize(LADDER_WIDTH, height - BODY_TOP)
	local heading = W:SectionLabel(card, "Blizzard's PvP ranks")
	local capNote = Theme:Text(card, "tiny", "capped: above this week's cap", C.faint)
	capNote:SetPoint("TOPRIGHT", -12, -12)
	heading:SetPoint("TOPLEFT", 14, -12)
	for i = 1, BlizzRank.MAX_RANK do
		local row = CreateFrame("Frame", nil, card)
		row:SetSize(LADDER_WIDTH - 2, ROW_HEIGHT)
		row:SetPoint("TOPLEFT", 1, -30 - (i - 1) * ROW_HEIGHT)
		row.bg = Theme:Fill(row, C.transparent)
		row.badge = row:CreateTexture(nil, "ARTWORK")
		row.badge:SetSize(18, 18)
		row.badge:SetPoint("LEFT", 12, 0)
		row.title = Theme:Text(row, "body", "")
		row.title:SetPoint("LEFT", TITLE_LEFT, 0)
		row.title:SetWidth(TITLE_WIDTH)
		row.unlock = Theme:Text(row, "small", "")
		row.unlock:SetPoint("LEFT", TITLE_LEFT + TITLE_WIDTH + 4, 0)
		row.unlockWidth = LADDER_WIDTH - TITLE_LEFT - TITLE_WIDTH - 4 - TAG_WIDTH - 10
		-- Bounded, so a text cut short ends in "..." inside its space
		row.unlock:SetWidth(row.unlockWidth)
		row.tag = Theme:Text(row, "tiny", "")
		row.tag:SetPoint("RIGHT", -10, 0)
		row.tag:SetJustifyH("RIGHT")
		private.rows[i] = row
	end
end

function private.BuildSide(container, width)
	local left = LADDER_WIDTH + 14
	local sideWidth = width - left
	local marks = W:Card(container)
	marks:SetPoint("TOPLEFT", left, -BODY_TOP)
	marks:SetSize(sideWidth, 30 + #BlizzRank.MARKS * 24 + 8)
	local heading = W:SectionLabel(marks, "Marks of Honor")
	heading:SetPoint("TOPLEFT", 14, -12)
	for i, mark in ipairs(BlizzRank.MARKS) do
		local line = CreateFrame("Frame", nil, marks)
		line:SetSize(sideWidth - 28, 22)
		line:SetPoint("TOPLEFT", 14, -30 - (i - 1) * 24)
		line.icon = line:CreateTexture(nil, "ARTWORK")
		line.icon:SetSize(18, 18)
		line.icon:SetPoint("LEFT")
		line.name = Theme:Text(line, "body", mark.name)
		line.name:SetPoint("LEFT", 26, 0)
		line.count = Theme:Text(line, "body", "")
		line.count:SetPoint("RIGHT")
		line.count:SetJustifyH("RIGHT")
		line.mark = mark
		private.marks[i] = line
	end
	local card = W:Card(container)
	card:SetPoint("TOPLEFT", marks, "BOTTOMLEFT", 0, -12)
	card:SetSize(sideWidth, 124)
	card.width = sideWidth - 28
	local label = W:SectionLabel(card, "Next")
	label:SetPoint("TOPLEFT", 14, -12)
	card.title = Theme:Text(card, "heading", "")
	card.title:SetPoint("TOPLEFT", 14, -32)
	card.title:SetWidth(card.width)
	card.unlock = Theme:Text(card, "body", "", C.gold)
	card.unlock:SetPoint("TOPLEFT", 14, -54)
	card.unlock:SetWidth(card.width)
	card.need = Theme:Text(card, "small", "")
	card.need:SetPoint("TOPLEFT", 14, -84)
	card.need:SetWidth(card.width)
	card.cap = Theme:Text(card, "small", "", C.amber)
	card.cap:SetPoint("TOPLEFT", 14, -100)
	card.cap:SetWidth(card.width)
	private.nextCard = card
	-- Where the rank rewards are bought, in the game's own words
	local vendor = Theme:Text(container, "tiny", "", C.faint)
	vendor:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -10)
	vendor:SetWidth(sideWidth)
	vendor:SetWordWrap(true)
	local line = UnitFactionGroup("player") == "Alliance" and _G.PVP_RANK_REWARDS_VENDOR_ALLIANCE or _G.PVP_RANK_REWARDS_VENDOR_HORDE
	vendor:SetText(type(line) == "string" and (gsub(line, "|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) or "")
end

UI:RegisterPage("rank", {
	group = "Battlegrounds",
	title = "Rank & Gear",
	tabLabel = "Rank",
	tabs = { "rank", "gear" },
	subtitle = "Your Blizzard PvP rank, what each rank unlocks at the rank vendors, and your honor and marks.",
	order = 7,
	build = function(container, width, height)
		local tileWidth = floor((width - 24) / 3)
		private.rankTile = W:StatTile(container, "Your rank", C.accent)
		private.rankTile:SetPoint("TOPLEFT")
		private.rankTile:SetWidth(tileWidth)
		private.capTile = W:StatTile(container, "This week's cap", C.amber)
		private.capTile:SetPoint("LEFT", private.rankTile, "RIGHT", 12, 0)
		private.capTile:SetWidth(tileWidth)
		private.honorTile = W:StatTile(container, "Honor Points", C.gold)
		private.honorTile:SetPoint("LEFT", private.capTile, "RIGHT", 12, 0)
		private.honorTile:SetWidth(tileWidth)
		private.BuildLadder(container, height)
		private.BuildSide(container, width)
		BlizzRank:OnChange(function()
			if container:IsVisible() then
				private.Refresh()
			end
		end)
	end,
	refresh = function()
		private.Refresh()
	end,
})
