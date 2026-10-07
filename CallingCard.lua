-- Wanted: your calling card. The banner players build on wanteddeadordead.com from the art their badges unlock: a
-- background inside a border, an emblem, and a plate with their name, with three stats under it. This window shows
-- one, and steps through every piece of each part (any combination, to see how it would look). The art is
-- Media/cards/<id>.blp; the catalogue (each piece's part, name and what unlocks it) is CardCatalogue.lua.

local _, Wanted = ...
local CallingCard = Wanted:NewModule("CallingCard")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local private = {
	frame = nil,
	parts = nil, -- the catalogue by part, in its order
	at = {}, -- the piece shown of each part: an index into private.parts[part]
}
local ART = "Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\cards\\"
-- Rye (SIL Open Font License, see THIRD_PARTY_NOTICES.md), as on the site's plates
local NAME_FONT = "Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\Rye.ttf"
-- The banner is 1040x400 like the site's art; where each part sits, as fractions of it (left, top, width, height)
local ASPECT = 400 / 1040
local BACKGROUND = { 40 / 1040, 0.10, 960 / 1040, 0.80 }
local EMBLEM = { 0.065, 0.19, 0.21 } -- left, top, width (square)
local PLATE = { 0.29, 0.47, 0.45 } -- left, top, width (540:200)
local PLATE_ASPECT = 200 / 540
local NAME_SIZE = 0.029 -- of the banner's width
local LIGHT_NAME, DARK_NAME = { 0.97, 0.93, 0.82 }, { 0.16, 0.09, 0.05 }
-- The parts in the order the window lists them, with their titles
local PARTS = {
	{ part = "background", title = "Background" },
	{ part = "border", title = "Border" },
	{ part = "emblem", title = "Emblem" },
	{ part = "plate", title = "Plate" },
}
-- What the window starts from: an Arcanite card
local SAMPLE = { background = "killer-legend", border = "killer-legend-border", emblem = "multi-emblem", plate = "mat-arcanite" }
local SAMPLE_STATS = { { "Challenge kills", "2,000" }, { "Best streak", "35" }, { "Rank", "Arcanite" } }
local BANNER_WIDTH = 720



-- ============================================================================
-- The catalogue
-- ============================================================================

---The catalogue by part, in its order, and each piece's place.
function private.Parts()
	if private.parts then
		return private.parts
	end
	local parts = {}
	for _, p in ipairs(PARTS) do
		parts[p.part] = {}
	end
	for _, item in ipairs(Wanted.CardCatalogue or {}) do
		local list = parts[item.part]
		if list then
			list[#list + 1] = item
		end
	end
	private.parts = parts
	return parts
end

---The index of a piece in its part, or 1.
function private.IndexOf(part, id)
	for i, item in ipairs(private.Parts()[part]) do
		if item.id == id then
			return i
		end
	end
	return 1
end



-- ============================================================================
-- The banner
-- ============================================================================

---A calling-card banner of a width: its parts' textures, the name on the plate and three stats under it.
---@param parent Frame
---@param width number
---@return Frame
function CallingCard:Banner(parent, width)
	local height = width * ASPECT
	local banner = CreateFrame("Frame", nil, parent)
	banner:SetSize(width, height + 46)
	local art = CreateFrame("Frame", nil, banner)
	art:SetSize(width, height)
	art:SetPoint("TOP")
	banner.background = art:CreateTexture(nil, "BACKGROUND")
	banner.background:SetPoint("TOPLEFT", BACKGROUND[1] * width, -BACKGROUND[2] * height)
	banner.background:SetSize(BACKGROUND[3] * width, BACKGROUND[4] * height)
	banner.border = art:CreateTexture(nil, "BORDER")
	banner.border:SetAllPoints(art)
	banner.emblem = art:CreateTexture(nil, "ARTWORK")
	banner.emblem:SetPoint("TOPLEFT", EMBLEM[1] * width, -EMBLEM[2] * height)
	banner.emblem:SetSize(EMBLEM[3] * width, EMBLEM[3] * width)
	local plateWidth = PLATE[3] * width
	banner.plate = art:CreateTexture(nil, "ARTWORK", nil, 1)
	banner.plate:SetPoint("TOPLEFT", PLATE[1] * width, -PLATE[2] * height)
	banner.plate:SetSize(plateWidth, plateWidth * PLATE_ASPECT)
	banner.name = art:CreateFontString(nil, "OVERLAY")
	banner.name:SetFont(NAME_FONT, max(10, floor(NAME_SIZE * width + 0.5)), "OUTLINE")
	banner.name:SetPoint("CENTER", banner.plate)
	banner.name:SetWidth(plateWidth * 0.72)
	banner.name:SetWordWrap(false)
	banner.stats = {}
	local statWidth = (width - 2 * BACKGROUND[1] * width - 8) / 3
	for i = 1, 3 do
		local box = CreateFrame("Frame", nil, banner)
		box:SetSize(statWidth, 40)
		box:SetPoint("TOPLEFT", art, "BOTTOMLEFT", BACKGROUND[1] * width + (i - 1) * (statWidth + 4), -4)
		Theme:Fill(box, { 0.05, 0.13, 0.15, 0.95 })
		box.label = Theme:Text(box, "small", "", { 0.56, 0.70, 0.68 })
		box.label:SetPoint("TOP", 0, -5)
		box.value = Theme:Text(box, "body", "", { 0.96, 0.92, 0.82 })
		box.value:SetPoint("BOTTOM", 0, 6)
		banner.stats[i] = box
	end
	return banner
end

---Shows a card on a banner: piece ids for each part (no emblem for none), the name and up to three { label, value }.
---@param banner Frame
---@param card table
---@param name string
---@param stats table?
function CallingCard:Draw(banner, card, name, stats)
	banner.background:SetTexture(ART..card.background)
	banner.border:SetTexture(ART..card.border)
	banner.plate:SetTexture(ART..card.plate)
	if card.emblem then
		banner.emblem:SetTexture(ART..card.emblem)
		banner.emblem:Show()
	else
		banner.emblem:Hide()
	end
	local plate = private.Parts().plate[private.IndexOf("plate", card.plate)]
	local ink = plate and plate.dark and DARK_NAME or LIGHT_NAME
	banner.name:SetTextColor(ink[1], ink[2], ink[3])
	banner.name:SetShadowColor(0, 0, 0, plate and plate.dark and 0 or 0.8)
	banner.name:SetShadowOffset(1, -2)
	banner.name:SetText(name or "")
	for i, box in ipairs(banner.stats) do
		local s = stats and stats[i]
		box.label:SetText(s and strupper(s[1]) or "")
		box.value:SetText(s and s[2] or "")
		box:SetShown(s ~= nil)
	end
end



-- ============================================================================
-- The window
-- ============================================================================

---Shows the window.
function CallingCard:Show()
	local frame = private.GetFrame()
	private.Refresh()
	frame:Show()
end

function CallingCard:IsShown()
	return private.frame and private.frame:IsShown() or false
end

function CallingCard:Hide()
	if private.frame then
		private.frame:Hide()
	end
end

---The card the window shows now.
function private.Current()
	local parts, card = private.Parts(), {}
	for _, p in ipairs(PARTS) do
		local item = parts[p.part][private.at[p.part]]
		card[p.part] = item and item.id
	end
	return card
end

function private.Refresh()
	local frame, parts = private.frame, private.Parts()
	-- Your full name ("First Last" on Forever), without a realm
	local name = strmatch(Wanted.Store:GetOrigin() or "", "^([^%-]+)") or "Your Name"
	CallingCard:Draw(frame.banner, private.Current(), name, SAMPLE_STATS)
	for _, p in ipairs(PARTS) do
		local row, item = frame.rows[p.part], parts[p.part][private.at[p.part]]
		row.name:SetText(item and item.name or "")
		row.unlock:SetText(item and item.unlock or "")
		row.count:SetText(format("%d of %d", private.at[p.part], #parts[p.part]))
	end
end

---Steps a part to its next (1) or previous (-1) piece, round the end.
function private.Step(part, by)
	local n = #private.Parts()[part]
	if n == 0 then
		return
	end
	private.at[part] = (private.at[part] - 1 + by) % n + 1
	private.Refresh()
end

function private.Shuffle()
	for _, p in ipairs(PARTS) do
		local n = #private.Parts()[p.part]
		if n > 0 then
			private.at[p.part] = random(n)
		end
	end
	private.Refresh()
end

function private.GetFrame()
	if private.frame then
		return private.frame
	end
	for _, p in ipairs(PARTS) do
		private.at[p.part] = private.IndexOf(p.part, SAMPLE[p.part])
	end
	local frame = CreateFrame("Frame", "WantedCallingCardFrame", UIParent)
	frame:SetFrameStrata("FULLSCREEN_DIALOG")
	frame:SetAllPoints(UIParent)
	frame:EnableMouse(true)
	frame:Hide()
	tinsert(UISpecialFrames, "WantedCallingCardFrame")
	local backdrop = frame:CreateTexture(nil, "BACKGROUND")
	backdrop:SetAllPoints()
	backdrop:SetColorTexture(0.03, 0.03, 0.04, 0.92)

	frame.title = Theme:Text(frame, "title", "Your calling card", { 0.95, 0.70, 0.30 })
	frame.title:SetPoint("TOP", 0, -60)
	frame.note = Theme:Text(frame, "small", "Try any combination: step through every piece, or shuffle. Build yours on wanteddeadordead.com, Characters.", { 0.6, 0.62, 0.68 })
	frame.note:SetPoint("TOP", frame.title, "BOTTOM", 0, -6)
	frame.banner = CallingCard:Banner(frame, BANNER_WIDTH)
	frame.banner:SetPoint("TOP", frame.note, "BOTTOM", 0, -18)

	-- A row for each part: back, the piece and what unlocks it, forward
	frame.rows = {}
	local previous = frame.banner
	for _, p in ipairs(PARTS) do
		local row = CreateFrame("Frame", nil, frame)
		row:SetSize(BANNER_WIDTH * 0.8, 44)
		row:SetPoint("TOP", previous, "BOTTOM", 0, previous == frame.banner and -12 or -6)
		Theme:Fill(row, { 0.07, 0.08, 0.10, 0.95 })
		local back = W:Button(row, "<", "secondary", 34, 34, function() private.Step(p.part, -1) end)
		back:SetPoint("LEFT", 5, 0)
		local forward = W:Button(row, ">", "secondary", 34, 34, function() private.Step(p.part, 1) end)
		forward:SetPoint("RIGHT", -5, 0)
		row.title = Theme:Text(row, "small", strupper(p.title), { 0.95, 0.70, 0.30 })
		row.title:SetPoint("TOPLEFT", back, "TOPRIGHT", 12, -1)
		row.count = Theme:Text(row, "small", "", { 0.6, 0.62, 0.68 })
		row.count:SetPoint("TOPRIGHT", forward, "TOPLEFT", -12, -1)
		row.name = Theme:Text(row, "body", "", { 0.96, 0.93, 0.85 })
		row.name:SetPoint("BOTTOMLEFT", back, "BOTTOMRIGHT", 12, 1)
		row.unlock = Theme:Text(row, "small", "", { 0.6, 0.62, 0.68 })
		row.unlock:SetPoint("BOTTOMRIGHT", forward, "BOTTOMLEFT", -12, 2)
		row.back, row.forward = back, forward
		frame.rows[p.part] = row
		previous = row
	end

	local buttons = CreateFrame("Frame", nil, frame)
	buttons:SetSize(240, 30)
	buttons:SetPoint("TOP", previous, "BOTTOM", 0, -14)
	local shuffle = W:Button(buttons, "Shuffle", "primary", 110, 28, private.Shuffle)
	shuffle:SetPoint("LEFT")
	frame.shuffle = shuffle
	local close = W:Button(buttons, "Close", "secondary", 110, 28, function() frame:Hide() end)
	close:SetPoint("RIGHT")
	private.frame = frame
	return frame
end

Wanted:RegisterCommand("card", "Your calling card: try any combination of backgrounds, borders, emblems and plates.", function()
	CallingCard:Show()
end)
