-- Wanted: Gear, a tab of Rank & Gear. The rank vendors' PvP gear that this character can use, from the catalogue
-- (GearCatalog): what each costs in honor and Marks of Honor, the rank and level it needs, and what's still missing.
-- Click an item to chase it: chased items stay at the top.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local BlizzRank = Wanted.BlizzRank
local GearCatalog = Wanted.GearCatalog
local private = {}
local ROW_HEIGHT = 40
local LIST_TOP = 40
local STATUS_WIDTH = 190

---A number with thousands separators: 4,650.
function private.Count(n)
	local text = tostring(floor(n or 0))
	repeat
		local changed
		text, changed = gsub(text, "^(%d+)(%d%d%d)", "%1,%2")
	until changed == 0
	return text
end

---An item's cost: "9,000 honor + 15 AV".
function private.Cost(entry)
	local parts = {}
	if (entry.honor or 0) > 0 then
		tinsert(parts, private.Count(entry.honor).." honor")
	end
	for _, mark in ipairs(BlizzRank.MARKS) do
		local n = entry.marks and entry.marks[mark.id]
		if n then
			tinsert(parts, n.." "..mark.short)
		end
	end
	if #parts == 0 and (entry.price or 0) > 0 then
		tinsert(parts, Wanted.Bounties:FormatMoney(entry.price))
	end
	return table.concat(parts, " + ")
end

function private.CreateRow(row)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(28, 28)
	row.icon:SetPoint("LEFT", 8, 0)
	row.name = Theme:Text(row, "body", "")
	row.name:SetPoint("TOPLEFT", 46, -5)
	row.detail = Theme:Text(row, "small", "")
	row.detail:SetPoint("TOPLEFT", 46, -22)
	row.status = Theme:Text(row, "small", "")
	row.status:SetPoint("RIGHT", -10, 0)
	row.status:SetJustifyH("RIGHT")
	row.status:SetWidth(STATUS_WIDTH)
	row.chasing = W:Pill(row)
	row.chasing:SetPoint("RIGHT", row.status, "LEFT", -6, 0)
end

function private.UpdateRow(row, item)
	local entry = item.entry
	-- From the page's width at build: a row may not be laid out yet the first time it's drawn
	local width = private.rowWidth - 46 - STATUS_WIDTH - 90
	row.icon:SetTexture(entry.icon or 134400)
	local r, g, b = 1, 1, 1
	if C_Item and C_Item.GetItemQualityColor then
		r, g, b = C_Item.GetItemQualityColor(entry.quality or 1)
	end
	row.name:SetTextColor(r or 1, g or 1, b or 1)
	row.name:SetWidth(width)
	Theme:FitText(row.name, width, { entry.name or "" })
	local slot = entry.slot and _G[entry.slot] or nil
	local parts = {}
	if entry.rank then
		tinsert(parts, "Rank "..entry.rank)
	end
	if type(slot) == "string" and slot ~= "" then
		tinsert(parts, slot)
	end
	tinsert(parts, private.Cost(entry))
	row.detail:SetWidth(width)
	Theme:FitText(row.detail, width, { table.concat(parts, "  ·  ") })
	if #item.missing == 0 then
		row.status:SetText("Ready to buy")
		row.status:SetTextColor(unpack(C.green))
	else
		Theme:FitText(row.status, STATUS_WIDTH, { table.concat(item.missing, ", "), item.missing[1]..(#item.missing > 1 and ", +"..(#item.missing - 1) or "") })
		row.status:SetTextColor(unpack(C.amber))
	end
	row.chasing:Set(item.starred and "Chasing" or nil, C.gold)
end

function private.Refresh()
	if not private.list then
		return
	end
	local items = GearCatalog:ForMe()
	local className = UnitClass("player")
	local chased = 0
	for _, item in ipairs(items) do
		chased = chased + (item.starred and 1 or 0)
	end
	private.summary:SetText(format("%s: %d items%s", className or "Your class", #items, chased > 0 and format(", %d chased", chased) or ""))
	local have = BlizzRank:Honor()
	local standing = { "Honor "..(have and private.Count(have) or "?") }
	for _, mark in ipairs(BlizzRank.MARKS) do
		tinsert(standing, mark.short.." "..BlizzRank:MarkCount(mark.id))
	end
	private.standing:SetText(table.concat(standing, "   "))
	local line = UnitFactionGroup("player") == "Alliance" and _G.PVP_RANK_REWARDS_VENDOR_ALLIANCE or _G.PVP_RANK_REWARDS_VENDOR_HORDE
	line = type(line) == "string" and (gsub(line, "|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) or "Rewards are sold at the rank vendors."
	private.list:SetItems(items, "No gear seen yet.", "Open the rank vendors once and Wanted remembers their gear. "..line)
end

UI:RegisterPage("gear", {
	title = "Gear",
	under = "rank", -- a tab of Rank & Gear
	subtitle = "The rank vendors' PvP gear for your class: what it costs and what you still need. Click an item to chase it.",
	order = 7.1,
	build = function(container, width, height)
		private.rowWidth = width - 12 -- the list keeps 12 for its scroll bar
		private.summary = Theme:Text(container, "heading", "")
		private.summary:SetPoint("TOPLEFT", 0, -6)
		private.standing = Theme:Text(container, "small", "")
		private.standing:SetPoint("TOPRIGHT", 0, -8)
		private.standing:SetJustifyH("RIGHT")
		local list = W:List(container, ROW_HEIGHT, floor((height - LIST_TOP) / ROW_HEIGHT), private.CreateRow, private.UpdateRow)
		list:SetPoint("TOPLEFT", 0, -LIST_TOP)
		list:SetPoint("TOPRIGHT", 0, -LIST_TOP)
		list.onClick = function(item) GearCatalog:ToggleGoal(item.itemID) end
		list.onEnter = function(row, item)
			GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
			if GameTooltip.SetItemByID then
				GameTooltip:SetItemByID(item.itemID)
			else
				GameTooltip:SetText(item.entry.name or "")
			end
			GameTooltip:AddLine(item.starred and "Click to stop chasing it." or "Click to chase it: it stays at the top.", 0.6, 0.62, 0.68, true)
			GameTooltip:Show()
		end
		private.list = list
		GearCatalog:OnChange(function()
			if container:IsVisible() then
				private.Refresh()
			end
		end)
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
