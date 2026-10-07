-- Wanted: your calling card. The banner players build on wanteddeadordead.com from the art their badges unlock: a
-- background inside a border, an emblem, and a plate with their name, with three stats under it. This window shows
-- yours (from the site, through the app's catch-up) and steps through every piece of each part: the ones you haven't
-- unlocked are marked locked, and Save keeps a card of unlocked pieces for the app to send (WantedDB.cardPicks; the
-- site checks it again). "Try anything" shows any combination, to see how it would look.
-- The art is Media/cards/<id>.blp; the catalogue (each piece's part, name and what unlocks it) is CardCatalogue.lua.
-- Card data only ever comes from the site's catch-up, never from other players, and only ids the catalogue knows are
-- drawn: anything else is dropped.

local _, Wanted = ...
local CallingCard = Wanted:NewModule("CallingCard")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local private = {
	frame = nil,
	parts = nil, -- the catalogue by part, in its order
	byID = nil, -- the catalogue by id
	at = {}, -- the piece shown of each part: an index into private.parts[part] (0 for no emblem)
	stats = {}, -- the three stats shown: ids
	mine = {}, -- your characters' cards from the site, by name: { card, unlocked = { [id] = true }, stats = { [id] = value } }
	trying = false, -- "Try anything": any combination, nothing to save
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
local SAMPLE_STATS = { kills = "2,000", streak = "35", rank = "Arcanite" }
-- The stats a card can show, in the site's order (stats.CardStats), with their labels
local STATS = {
	{ id = "kills", label = "Challenge kills" }, { id = "honor", label = "Honorable kills" }, { id = "score", label = "Badge score" },
	{ id = "rank", label = "Rank" }, { id = "streak", label = "Best streak" }, { id = "multi", label = "Best multi-kill" },
	{ id = "bounties", label = "Bounties collected" }, { id = "paid", label = "Bounties paid" }, { id = "battles", label = "Battles won" },
	{ id = "medals", label = "Weekly medals" }, { id = "challenges", label = "Weekly challenges" }, { id = "defender", label = "Defender kills" },
	{ id = "underdog", label = "Underdog kills" }, { id = "witness", label = "Deaths witnessed" }, { id = "zone", label = "Best zone" },
	{ id = "class", label = "Most killed" },
}
local STAT_LABELS = {}
for _, st in ipairs(STATS) do
	STAT_LABELS[st.id] = st.label
end
local DEFAULT_STATS = { "kills", "honor", "rank" }
local NO_EMBLEM = "none"
local MAX_UNLOCKED = 400
local MAX_VALUE = 32
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
	private.byID = {}
	for _, item in ipairs(Wanted.CardCatalogue or {}) do
		local list = parts[item.part]
		if list then
			list[#list + 1] = item
			private.byID[item.id] = item
		end
	end
	private.parts = parts
	return parts
end

---The index of a piece in its part; 0 for no emblem; 1 for one unknown.
function private.IndexOf(part, id)
	if part == "emblem" and id == NO_EMBLEM then
		return 0
	end
	for i, item in ipairs(private.Parts()[part]) do
		if item.id == id then
			return i
		end
	end
	return 1
end

---A piece the catalogue knows, of this part; nil for anything else.
function private.Known(id, part)
	private.Parts()
	local item = type(id) == "string" and private.byID[id]
	return item and item.part == part and item or nil
end

---Text from the site made safe to show: a string, cut short, with the game's escape character taken out (so it can't
---draw a texture or make a link).
function private.Clean(text, max)
	if type(text) ~= "string" then
		return nil
	end
	text = gsub(text, "|", "")
	return strsub(text, 1, max)
end



-- ============================================================================
-- Your cards, from the site
-- ============================================================================

---Takes in the catch-up's cards of your own characters: by name, { card = { plate, border, emblem, background, stats },
---unlocked = { ids }, stats = { [id] = value } }. Pieces the catalogue doesn't know, unknown stats and malformed
---entries are dropped.
---@param cards table?
function CallingCard:TakeMine(cards)
	private.mine = {}
	for name, c in pairs(type(cards) == "table" and cards or {}) do
		local card = type(c) == "table" and type(c.card) == "table" and c.card
		if type(name) == "string" and #name <= 40 and strfind(name, " ", 1, true) and not strfind(name, "|", 1, true) and card then
			local unlocked, count = {}, 0
			for _, id in ipairs(type(c.unlocked) == "table" and c.unlocked or {}) do
				if count >= MAX_UNLOCKED then
					break
				end
				if type(id) == "string" and private.byID[id] then
					unlocked[id], count = true, count + 1
				end
			end
			local values = {}
			for id, v in pairs(type(c.stats) == "table" and c.stats or {}) do
				if STAT_LABELS[id] then
					values[id] = private.Clean(v, MAX_VALUE)
				end
			end
			local picked = {}
			for i = 1, 3 do
				local id = type(card.stats) == "table" and card.stats[i]
				picked[i] = STAT_LABELS[id] and id or DEFAULT_STATS[i]
			end
			local mine = {
				background = private.Known(card.background, "background") and card.background,
				border = private.Known(card.border, "border") and card.border,
				plate = private.Known(card.plate, "plate") and card.plate,
				emblem = private.Known(card.emblem, "emblem") and card.emblem or NO_EMBLEM,
				stats = picked,
			}
			if mine.background and mine.border and mine.plate then
				private.mine[name] = { card = mine, unlocked = unlocked, stats = values }
			end
		end
	end
	if private.frame and private.frame:IsShown() then
		private.Load()
		private.Refresh()
	end
end

---Your card from the site, for the character you're playing; nil before the app has brought it.
function private.Mine()
	return private.mine[private.MyName()]
end

---Your full name ("First Last" on Forever), without a realm.
function private.MyName()
	return strmatch(Wanted.Store:GetOrigin() or "", "^([^%-]+)") or "Your Name"
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
	if card.emblem and card.emblem ~= NO_EMBLEM then
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

---Shows the window: your card if the site has sent it, else the sample to try things on.
function CallingCard:Show()
	local frame = private.GetFrame()
	private.trying = private.Mine() == nil
	private.Load()
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

---Puts the card to start from in the window: yours, or the sample when trying anything.
function private.Load()
	local mine = private.Mine()
	local card = (not private.trying and mine) and mine.card or SAMPLE
	for _, p in ipairs(PARTS) do
		private.at[p.part] = private.IndexOf(p.part, card[p.part])
	end
	for i = 1, 3 do
		private.stats[i] = (not private.trying and mine) and mine.card.stats[i] or DEFAULT_STATS[i]
	end
end

---The card the window shows now.
function private.Current()
	local parts, card = private.Parts(), {}
	for _, p in ipairs(PARTS) do
		local item = parts[p.part][private.at[p.part]]
		card[p.part] = item and item.id or NO_EMBLEM
	end
	return card
end

---Whether you may keep a piece: unlocked (no emblem always), in your own card's mode.
function private.Unlocked(id)
	local mine = private.Mine()
	return id == NO_EMBLEM or (mine and mine.unlocked[id]) or false
end

function private.Refresh()
	local frame, parts, mine = private.frame, private.Parts(), private.Mine()
	local card = private.Current()
	local values = (not private.trying and mine) and mine.stats or SAMPLE_STATS
	local stats = {}
	for i, id in ipairs(private.stats) do
		stats[i] = { STAT_LABELS[id], values[id] or "-" }
	end
	CallingCard:Draw(frame.banner, card, private.MyName(), stats)
	local allUnlocked = true
	for _, p in ipairs(PARTS) do
		local row, item = frame.rows[p.part], parts[p.part][private.at[p.part]]
		local open = private.trying or private.Unlocked(card[p.part])
		allUnlocked = allUnlocked and open
		row.name:SetText(item and item.name or "No emblem")
		row.unlock:SetText(item and (open and item.unlock or "Locked: "..item.unlock) or "")
		row.unlock:SetTextColor(unpack(open and { 0.6, 0.62, 0.68 } or { 0.95, 0.45, 0.35 }))
		row.count:SetText(format("%d of %d", max(private.at[p.part], 0), #parts[p.part]))
	end
	frame.mode:SetText(private.trying and "Show my card" or "Try anything")
	frame.mode:SetShown(mine ~= nil)
	frame.save:SetShown(not private.trying and mine ~= nil)
	frame.save:SetEnabled(allUnlocked)
	if private.trying then
		frame.note:SetText(mine and "Trying anything: step through every piece, or shuffle. Nothing here is saved."
			or "Try any combination. Your own card shows here once the Wanted app has brought it from wanteddeadordead.com.")
	else
		frame.note:SetText(allUnlocked and "Your card. Step through the pieces, click a stat to change it, then Save."
			or "Locked pieces can be tried but not saved: earn them through their challenges.")
	end
end

---Steps a part to its next (1) or previous (-1) piece, round the end; the emblem has "no emblem" before the first.
function private.Step(part, by)
	local n = #private.Parts()[part]
	if n == 0 then
		return
	end
	local low = part == "emblem" and 0 or 1
	local span = n - low + 1
	private.at[part] = (private.at[part] - low + by) % span + low
	private.Refresh()
end

---Moves a stat slot to the next stat not shown in another slot.
function private.NextStat(slot)
	local at = 1
	for i, st in ipairs(STATS) do
		if st.id == private.stats[slot] then
			at = i
		end
	end
	for step = 1, #STATS do
		local id = STATS[(at - 1 + step) % #STATS + 1].id
		local taken = false
		for i = 1, 3 do
			taken = taken or (i ~= slot and private.stats[i] == id)
		end
		if not taken then
			private.stats[slot] = id
			break
		end
	end
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

---Keeps your card for the app to send to wanteddeadordead.com (which checks it against what you've unlocked).
function private.Save()
	local mine, card = private.Mine(), private.Current()
	if private.trying or not mine then
		return
	end
	for _, p in ipairs(PARTS) do
		if not private.Unlocked(card[p.part]) then
			return
		end
	end
	Wanted.db.cardPicks = Wanted.db.cardPicks or {}
	Wanted.db.cardPicks[private.MyName()] = { t = time(), p = card.plate, b = card.border, e = card.emblem, g = card.background,
		s1 = private.stats[1], s2 = private.stats[2], s3 = private.stats[3] }
	mine.card = { plate = card.plate, border = card.border, emblem = card.emblem, background = card.background,
		stats = { private.stats[1], private.stats[2], private.stats[3] } }
	private.frame.note:SetText("Saved. The Wanted app sends it to wanteddeadordead.com after your next /reload or logout.")
end

function private.GetFrame()
	if private.frame then
		return private.frame
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
	frame.note = Theme:Text(frame, "small", "", { 0.6, 0.62, 0.68 })
	frame.note:SetPoint("TOP", frame.title, "BOTTOM", 0, -6)
	frame.banner = CallingCard:Banner(frame, BANNER_WIDTH)
	frame.banner:SetPoint("TOP", frame.note, "BOTTOM", 0, -18)
	-- A stat is changed by clicking it
	for i, box in ipairs(frame.banner.stats) do
		box:EnableMouse(true)
		box:SetScript("OnMouseUp", function() private.NextStat(i) end)
		W:AttachTooltip(box, "Change this stat", "Click for the next stat.")
	end

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
	buttons:SetSize(480, 30)
	buttons:SetPoint("TOP", previous, "BOTTOM", 0, -14)
	frame.save = W:Button(buttons, "Save", "primary", 110, 28, private.Save)
	frame.save:SetPoint("LEFT")
	W:AttachTooltip(frame.save, "Save your calling card", "The Wanted app sends it to wanteddeadordead.com after your next /reload or logout. Only unlocked pieces can be saved.")
	frame.mode = W:Button(buttons, "Try anything", "secondary", 130, 28, function()
		private.trying = not private.trying
		private.Load()
		private.Refresh()
	end)
	frame.mode:SetPoint("LEFT", frame.save, "RIGHT", 8, 0)
	frame.shuffle = W:Button(buttons, "Shuffle", "secondary", 100, 28, private.Shuffle)
	frame.shuffle:SetPoint("LEFT", frame.mode, "RIGHT", 8, 0)
	local close = W:Button(buttons, "Close", "secondary", 100, 28, function() frame:Hide() end)
	close:SetPoint("RIGHT")
	private.frame = frame
	return frame
end

Wanted:RegisterCommand("card", "Your calling card: change it (pieces you've unlocked) or try any combination.", function()
	CallingCard:Show()
end)
