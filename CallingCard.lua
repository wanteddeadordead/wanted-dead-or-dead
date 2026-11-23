-- Wanted: your calling card. The banner players build on wanteddeadordead.com from the art their badges unlock: a
-- background inside a border, an emblem, and a plate with their name, with three stats under it. This window shows
-- yours (from the site, through the app's catch-up) and steps through the pieces of each part you have unlocked (all of
-- them in "Try anything"; a locked piece shown is marked locked). Save keeps a card of unlocked pieces for the app to
-- send (WantedDB.cardPicks; the site checks it again). "Try anything" shows any combination, to see how it would look.
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
	saved = false, -- the card shown is the one just saved (until the next change to it)
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
-- The name fits the plate's open centre, this share of its width (the ornaments at its ends take the rest): full size
-- while it fits, smaller down to ONE_LINE_LEAST on one line, then on two lines at TWO_LINES_MOST or less (as the site)
local NAME_ROOM, ONE_LINE_LEAST, TWO_LINES_MOST = 0.52, 0.8, 0.8
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
-- The Browse view: each part's cell width (its height follows the art's shape), the gap between cells, and the grid's room
local BROWSE_CELL_WIDTH = { background = 168, border = 156, plate = 168, emblem = 92 }
local BROWSE_GAP, BROWSE_WIDTH, BROWSE_HEIGHT = 10, 708, 340
local BROWSE_PANEL = { BROWSE_WIDTH + 12 + 40, BROWSE_HEIGHT + 100 }



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

---Whether calling cards are on (Settings, "Show calling cards"). Off, there is no Calling card tab, no card window, no
---piece toasts, no card art and no card data kept; the saved picks (WantedDB.cardPicks) stay for when it's turned on.
---@return boolean
function CallingCard:On()
	local settings = Wanted.db and Wanted.db.settings
	return not settings or settings.callingCards ~= false
end

---Applies the setting at once: drops the cards held in memory and closes the window when it's off, and has the window
---refresh the You entry's tabs. The cards come back with the next catch-up (a /reload).
function CallingCard:Apply()
	if not CallingCard:On() then
		private.mine = {}
		CallingCard:Hide()
		Wanted.Achievements:DropCards()
	end
end

---Takes in the catch-up's cards of your own characters: by name, { card = { plate, border, emblem, background, stats },
---unlocked = { ids }, stats = { [id] = value } }. Pieces the catalogue doesn't know, unknown stats and malformed
---entries are dropped.
---@param cards table?
function CallingCard:TakeMine(cards)
	private.mine = {}
	if not CallingCard:On() then
		return
	end
	private.Parts() -- the catalogue by id: the catch-up comes at login, before the window has ever built it
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

---A card from the site made safe to draw: { background, border, plate, emblem, stats = { 3 ids } } of pieces the
---catalogue knows (no emblem for an unknown one), or nil when a background, border or plate is missing or unknown.
---@param card table?
---@return table?
function CallingCard:CleanCard(card)
	private.Parts()
	if type(card) ~= "table" then
		return nil
	end
	local picked = {}
	for i = 1, 3 do
		local id = type(card.stats) == "table" and card.stats[i]
		picked[i] = STAT_LABELS[id] and id or DEFAULT_STATS[i]
	end
	local clean = {
		background = private.Known(card.background, "background") and card.background,
		border = private.Known(card.border, "border") and card.border,
		plate = private.Known(card.plate, "plate") and card.plate,
		emblem = private.Known(card.emblem, "emblem") and card.emblem or NO_EMBLEM,
		stats = picked,
	}
	return clean.background and clean.border and clean.plate and clean or nil
end

---Another player's designed card, as their victims see it: the card and three { label, value }, or nil when they
---haven't designed one (the site's cosmetics, Achievements:CosmeticsOf).
---@param name string?
---@return table? card, table? stats
function CallingCard:CardOf(name)
	if not CallingCard:On() then
		return nil, nil
	end
	local looks = Wanted.Achievements:CosmeticsOf(name)
	local card = looks.card
	if not card then
		return nil, nil
	end
	local stats = {}
	for i = 1, 3 do
		local id = card.stats[i]
		stats[i] = { STAT_LABELS[id] or id, looks.values and looks.values[i] or "-" }
	end
	return card, stats
end

-- Each part's art, width over height, for drawing it whole (the toasts)
local PART_ASPECT = { emblem = 1, plate = 540 / 200, border = 1040 / 400, background = 3 }

---A catalogue item by id ({ id, part, name, unlock, via }), or nil.
---@param id string
---@return table?
function CallingCard:Item(id)
	private.Parts()
	return type(id) == "string" and private.byID[id] or nil
end

---A catalogue item's art (texture path) and its width over height, or nil for an unknown id.
---@param id string
---@return string?, number?
function CallingCard:Art(id)
	if not CallingCard:On() then
		return nil
	end
	local item = CallingCard:Item(id)
	if item then
		return ART..item.id, PART_ASPECT[item.part]
	end
end

---Toasts for the pieces you've unlocked since last time, on the character you're playing: one for each badge tier
---and each rank, with the art of what it unlocked. Achievement and medal pieces come with their badge's own toast;
---starters and playstyle pieces (which come and go with the season) never get one. The first time a character's
---pieces are seen they're only noted (WantedDB.cardsSeen).
function CallingCard:CheckNew()
	if not CallingCard:On() then
		return
	end
	local me = private.MyName()
	local mine = private.mine[me]
	if not mine then
		return
	end
	Wanted.db.cardsSeen = type(Wanted.db.cardsSeen) == "table" and Wanted.db.cardsSeen or {}
	local seen = Wanted.db.cardsSeen[me]
	local first = type(seen) ~= "table"
	seen = first and {} or seen
	local groups, order = {}, {}
	for _, item in ipairs(Wanted.CardCatalogue or {}) do
		if mine.unlocked[item.id] and not seen[item.id] then
			seen[item.id] = true
			if not first and (item.via == "tier" or item.via == "rank") then
				if not groups[item.unlock] then
					groups[item.unlock] = {}
					tinsert(order, item.unlock)
				end
				tinsert(groups[item.unlock], item)
			end
		end
	end
	Wanted.db.cardsSeen[me] = seen
	for _, unlock in ipairs(order) do
		local items = groups[unlock]
		local pieces = {}
		for _, item in ipairs(items) do
			tinsert(pieces, item.name.." "..item.part)
		end
		local rank = items[1].via == "rank"
		local art, aspect = CallingCard:Art(items[1].id)
		Wanted.Toast:Add({ kind = rank and "NEW RANK" or "BADGE TIER", name = rank and (gsub(unlock, " rank$", "")) or unlock,
			detail = "Unlocked: "..table.concat(pieces, ", "), art = art, aspect = aspect })
	end
end

---The pieces you've unlocked on the character you're playing, but for starters and playstyle pieces (which come and go
---with the season): their ids, for the You menu's count of new ones.
---@return string[]
function CallingCard:UnlockedIds()
	if not CallingCard:On() then
		return {}
	end
	local mine = private.Mine()
	local ids = {}
	for _, item in ipairs(mine and Wanted.CardCatalogue or {}) do
		if mine.unlocked[item.id] and item.via ~= "starter" and item.via ~= "playstyle" then
			tinsert(ids, item.id)
		end
	end
	return ids
end

---Your card as it shows, for the You page: { card, name, stats = { { label, value } x3 }, unlocked, total }, or nil
---before the app has brought it.
---@return table?
function CallingCard:MyCard()
	local mine = private.Mine()
	if not mine then
		return nil
	end
	local stats = {}
	for i = 1, 3 do
		local id = mine.card.stats and mine.card.stats[i] or DEFAULT_STATS[i]
		stats[i] = { STAT_LABELS[id] or id, mine.stats[id] or "-" }
	end
	local unlocked = 0
	for _ in pairs(mine.unlocked) do
		unlocked = unlocked + 1
	end
	return { card = mine.card, name = private.MyName(), stats = stats, unlocked = unlocked, total = #(Wanted.CardCatalogue or {}) }
end

---The sample card the editor starts on, for a preview before your own card has come.
---@return table card, table stats
function CallingCard:Sample()
	local stats = {}
	for i, id in ipairs(DEFAULT_STATS) do
		stats[i] = { STAT_LABELS[id], SAMPLE_STATS[id] or "-" }
	end
	return SAMPLE, stats
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

---Draws a name on a banner's plate, fitted to its open centre: full size while it fits, smaller down to ONE_LINE_LEAST
---on one line, then (a name with a space) on two lines at TWO_LINES_MOST or less. Each line is measured on its own.
function private.FitName(banner, name)
	local fs, full, room = banner.name, banner.nameSize, banner.nameRoom
	-- Measured unwrapped and unbounded: the string's set width would otherwise cap what it reports
	fs:SetWordWrap(false)
	local function Widest(size, lines)
		fs:SetFont(NAME_FONT, size, banner.nameFlags)
		local widest = 0
		for _, line in ipairs(lines) do
			fs:SetText(line)
			widest = max(widest, (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth()) or fs:GetStringWidth() or 0)
		end
		return widest
	end
	local function Scale(lines)
		local widest = Widest(full, lines)
		return widest > room and room / widest or 1
	end
	local first, rest = strmatch(name, "^(%S+)%s+(.+)$")
	local lines, scale = { name }, Scale({ name })
	if scale < ONE_LINE_LEAST and first then
		lines = { first, rest }
		scale = min(TWO_LINES_MOST, Scale(lines))
	end
	-- Whole sizes only, rounded down so it never comes out wider than measured
	local size = max(6, floor(full * scale))
	fs:SetFont(NAME_FONT, size, banner.nameFlags)
	fs:SetWordWrap(#lines > 1)
	fs:SetText(table.concat(lines, "\n"))
end

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
	banner.nameSize = max(10, floor(NAME_SIZE * width + 0.5))
	banner.name:SetFont(NAME_FONT, banner.nameSize, "OUTLINE")
	banner.name:SetPoint("CENTER", banner.plate)
	banner.name:SetWidth(plateWidth * 0.72)
	banner.name:SetWordWrap(false)
	banner.nameRoom = plateWidth * NAME_ROOM
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
		-- A long label or value stays in its box, cut short, on the narrower death card banner too
		for _, fs in ipairs({ box.label, box.value }) do
			fs:SetWidth(statWidth - 6)
			fs:SetWordWrap(false)
		end
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
	-- The game draws an outline in black only, which smears dark ink: on a light plate the name is dark with a light
	-- shadow under it, as if engraved; on the rest, light ink outlined in black with a dark shadow
	local dark = plate and plate.dark
	local ink = dark and DARK_NAME or LIGHT_NAME
	banner.nameFlags = dark and "" or "OUTLINE"
	banner.name:SetTextColor(ink[1], ink[2], ink[3])
	if dark then
		banner.name:SetShadowColor(1, 0.97, 0.9, 0.85)
		banner.name:SetShadowOffset(1, -1)
	else
		banner.name:SetShadowColor(0, 0, 0, 0.8)
		banner.name:SetShadowOffset(1, -2)
	end
	private.FitName(banner, name or "")
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
	if not CallingCard:On() then
		return
	end
	local frame = private.GetFrame()
	if private.browse then
		private.browse:Hide()
	end
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
	private.saved = false
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
		row.count:SetText(private.CountText(p.part))
	end
	frame.mode:SetText(private.trying and "Show my card" or "Try anything")
	frame.mode:SetShown(mine ~= nil)
	frame.save:SetShown(not private.trying and mine ~= nil)
	frame.save:SetEnabled(allUnlocked)
	frame.save.label:SetText(private.saved and "Saved" or "Save")
	frame.saved:SetText(private.saved and not private.trying and "Saved. It goes up at your next /reload or logout." or "")
	if private.trying then
		-- Without the app nothing carries the unlocks down or a card up: say so, instead of a Save that never comes
		if mine then
			frame.note:SetText("Trying anything: nothing is saved.")
			W:Explain(frame.note, nil)
		elseif not Wanted:HasApp() then
			frame.note:SetText("Needs the Wanted app to save")
			W:Explain(frame.note, "Needs the Wanted app", Wanted:NeedsApp("Saving a calling card").." It brings your unlocks from wanteddeadordead.com and sends your card up.")
		else
			frame.note:SetText("Try any combination")
			W:Explain(frame.note, "Try any combination", "Your own card shows here once the Wanted app has brought it from wanteddeadordead.com (a /reload after it starts).")
		end
	else
		-- The arrows, the stat boxes and Save say how; a locked piece is why Save is greyed out
		frame.note:SetText(allUnlocked and "" or "Locked pieces can't be saved.")
		W:Explain(frame.note, nil)
	end
end

---The places the arrows stop at in a part, as indexes into its pieces (0 for no emblem, which the emblem always has):
---every piece in "Try anything", the unlocked ones on your own card.
---@param part string
---@return number[]
function private.Stops(part)
	local stops = {}
	if part == "emblem" then
		stops[1] = 0
	end
	for i, item in ipairs(private.Parts()[part]) do
		if private.trying or private.Unlocked(item.id) then
			tinsert(stops, i)
		end
	end
	return stops
end

---The count beside a part's arrows: "3 of 12 unlocked" on your own card (the shown piece's place among the unlocked
---ones, and how many there are), "36 of 119" in "Try anything".
---@param part string
---@return string
function private.CountText(part)
	local items, at = private.Parts()[part], private.at[part]
	if private.trying then
		return format("%d of %d", max(at, 0), #items)
	end
	local count, place = 0, at == 0 and 0 or nil
	for i, item in ipairs(items) do
		if private.Unlocked(item.id) then
			count = count + 1
			if i == at then
				place = count
			end
		end
	end
	-- A piece you don't own (a seasonal one that went away) has no place among them
	return place and format("%d of %d unlocked", place, count) or format("%d unlocked", count)
end

---Steps a part to its next (1) or previous (-1) stop, round the end. A piece shown that isn't a stop (a locked one on
---your own card) goes to the nearest stop in that direction.
function private.Step(part, by)
	local stops = private.Stops(part)
	if #stops == 0 then
		return
	end
	local at, here, to = private.at[part], nil, nil
	for i, stop in ipairs(stops) do
		if stop == at then
			here = i
		end
	end
	if here then
		to = stops[(here - 1 + by) % #stops + 1]
	elseif by > 0 then
		to = stops[1]
		for _, stop in ipairs(stops) do
			if stop > at then
				to = stop
				break
			end
		end
	else
		to = stops[#stops]
		for i = #stops, 1, -1 do
			if stops[i] < at then
				to = stops[i]
				break
			end
		end
	end
	private.at[part] = to
	private.Changed()
end

---The card shown changed: what was saved no longer is.
function private.Changed()
	private.saved = false
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
	private.Changed()
end

function private.Shuffle()
	for _, p in ipairs(PARTS) do
		local pool = {}
		for _, stop in ipairs(private.Stops(p.part)) do
			if stop > 0 then
				tinsert(pool, stop)
			end
		end
		if #pool > 0 then
			private.at[p.part] = pool[random(#pool)]
		end
	end
	private.Changed()
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
	private.saved = true
	private.Refresh()
end

-- ============================================================================
-- Browse: one part's pieces as small pictures
-- ============================================================================

---The pieces the Browse view lists for a part: no emblem first (emblems only), then the ones you own, then the locked
---ones (left out with onlyEarned). Without your own card (no app) nothing is claimed earned or locked: every piece, in
---the catalogue's order.
---@param part string
---@param onlyEarned boolean?
---@return table[] entries { index (into the part's pieces; 0 for no emblem), item, earned }
---@return number earned how many pieces you own, or nil without your card
---@return number total
function private.BrowseItems(part, onlyEarned)
	local items, claims = private.Parts()[part], private.Mine() ~= nil
	local entries, locked, earned = {}, {}, 0
	if part == "emblem" then
		entries[1] = { index = 0, earned = true }
	end
	for i, item in ipairs(items) do
		if not claims then
			tinsert(entries, { index = i, item = item, earned = true })
		elseif private.Unlocked(item.id) then
			earned = earned + 1
			tinsert(entries, { index = i, item = item, earned = true })
		elseif not onlyEarned then
			tinsert(locked, { index = i, item = item, earned = false })
		end
	end
	for _, entry in ipairs(locked) do
		tinsert(entries, entry)
	end
	return entries, claims and earned or nil, #items
end

---Puts a piece on the card from the Browse view: yours if you own it, any in "Try anything"; a locked one on your own
---card does nothing.
function private.BrowsePick(entry)
	-- Judged now, not by how the grid was drawn: your card may have arrived since
	if not entry or not (private.trying or private.Unlocked(entry.item and entry.item.id or NO_EMBLEM)) then
		return
	end
	private.at[private.browse.part] = entry.index
	private.browse:Hide()
	private.Changed()
end

---Works out what the view lists (for the part, your card and the filter as they are now), and the header.
function private.BuildBrowse()
	local browse = private.browse
	local claims = private.Mine() ~= nil
	local onlyEarned = claims and Wanted.db.cardOnlyEarned == true
	local entries, earned, total = private.BrowseItems(browse.part, onlyEarned)
	browse.entries, browse.claims = entries, claims
	browse.title:SetText(private.Title(browse.part))
	browse.count:SetText(claims and format("%d of %d earned", earned, total) or format("%d pieces", total))
	browse.only:SetShown(claims)
	browse.only:SetChecked(onlyEarned)
	browse.offset = 0
end

---Draws the grid: only the cells in view, reused as it scrolls and for every part.
function private.DrawBrowse()
	local browse = private.browse
	local part = browse.part
	local width = BROWSE_CELL_WIDTH[part]
	local height = floor(width / PART_ASPECT[part])
	local cols = floor((BROWSE_WIDTH + BROWSE_GAP) / (width + BROWSE_GAP))
	local rows = floor((BROWSE_HEIGHT + BROWSE_GAP) / (height + BROWSE_GAP))
	local claims, entries = browse.claims, browse.entries
	browse.cols, browse.rows = cols, rows
	browse.empty:SetShown(#entries == 0)
	local lastRow = max(ceil(#entries / cols) - rows, 0)
	browse.offset = max(0, min(browse.offset, lastRow))
	local current = private.at[part]
	for slot = 1, max(#browse.cells, rows * cols) do
		local cell, entry = browse.cells[slot], nil
		if slot <= rows * cols then
			entry = entries[browse.offset * cols + slot]
		end
		if entry then
			if not cell then
				cell = private.BrowseCell(slot)
			end
			cell.entry = entry
			cell:SetSize(width, height)
			cell:ClearAllPoints()
			cell:SetPoint("TOPLEFT", ((slot - 1) % cols) * (width + BROWSE_GAP), -floor((slot - 1) / cols) * (height + BROWSE_GAP))
			local item, shut = entry.item, claims and not entry.earned
			if item then
				cell.art:SetTexture((CallingCard:Art(item.id)))
				cell.art:SetDesaturated(shut)
				cell.art:SetVertexColor(shut and 0.55 or 1, shut and 0.55 or 1, shut and 0.6 or 1)
				cell.art:Show()
			else
				cell.art:SetTexture(nil)
				cell.art:Hide()
			end
			cell.name:SetText(item and "" or "No emblem")
			cell.lock:SetShown(shut)
			Theme:SetBorderColor(cell, entry.index == current and { 0.95, 0.70, 0.30, 1 } or { 1, 1, 1, 0.10 })
			local title = item and item.name or "No emblem"
			local body = item and (shut and "Locked: "..item.unlock or item.unlock) or "Show the card without an emblem."
			W:Explain(cell, title, body)
			cell:Show()
		elseif cell then
			-- Art is only held for the part shown
			cell.entry = nil
			cell.art:SetTexture(nil)
			cell:Hide()
		end
	end
	-- The scroll bar
	if lastRow > 0 then
		local thumb = max(BROWSE_HEIGHT * rows / (lastRow + rows), 24)
		browse.thumb:SetHeight(thumb)
		browse.thumb:ClearAllPoints()
		browse.thumb:SetPoint("TOPRIGHT", browse.grid, "TOPRIGHT", -2, -(browse.offset / lastRow) * (BROWSE_HEIGHT - thumb))
	end
	browse.thumb:SetShown(lastRow > 0)
	browse.track:SetShown(lastRow > 0)
end

---A part's title ("Background").
function private.Title(part)
	for _, p in ipairs(PARTS) do
		if p.part == part then
			return p.title
		end
	end
	return part
end

---One cell of the grid, made when first needed.
function private.BrowseCell(slot)
	local browse = private.browse
	local cell = CreateFrame("Button", nil, browse.grid)
	Theme:Skin(cell, { 0.05, 0.05, 0.07, 1 }, { 1, 1, 1, 0.10 })
	cell.art = cell:CreateTexture(nil, "ARTWORK")
	cell.art:SetPoint("TOPLEFT", 1, -1)
	cell.art:SetPoint("BOTTOMRIGHT", -1, 1)
	cell.name = Theme:Text(cell, "small", "", { 0.6, 0.62, 0.68 })
	cell.name:SetPoint("CENTER")
	cell.lock = CreateFrame("Frame", nil, cell)
	cell.lock:SetSize(54, 14)
	cell.lock:SetPoint("BOTTOMRIGHT", -3, 3)
	Theme:Fill(cell.lock, { 0, 0, 0, 0.75 })
	cell.lock.text = Theme:Text(cell.lock, "small", "LOCKED", { 0.95, 0.45, 0.35 })
	cell.lock.text:SetPoint("CENTER")
	cell:SetScript("OnClick", function(self) private.BrowsePick(self.entry) end)
	browse.cells[slot] = cell
	return cell
end

---Puts a frame's name on the list of frames Escape closes, in place of another's.
function private.EscapeFor(add, remove)
	local have = false
	for i = #UISpecialFrames, 1, -1 do
		if UISpecialFrames[i] == remove then
			tremove(UISpecialFrames, i)
		elseif UISpecialFrames[i] == add then
			have = true
		end
	end
	if not have then
		tinsert(UISpecialFrames, add)
	end
end

---Opens the Browse view for a part.
---@param part string
function private.OpenBrowse(part)
	local browse = private.browse
	if not browse then
		browse = CreateFrame("Frame", "WantedCallingCardBrowse", private.frame)
		private.browse = browse
		browse.cells, browse.offset = {}, 0
		browse:SetAllPoints(private.frame)
		browse:SetFrameLevel(private.frame:GetFrameLevel() + 20)
		browse:EnableMouse(true)
		Theme:Fill(browse, { 0, 0, 0, 0.6 })
		browse:Hide()
		-- Escape closes this before the window: while it is open it takes the window's place on the list Escape closes
		-- (no keyboard capture, which is restricted in combat)
		browse:SetScript("OnShow", function() private.EscapeFor("WantedCallingCardBrowse", "WantedCallingCardFrame") end)
		browse:SetScript("OnHide", function() private.EscapeFor("WantedCallingCardFrame", "WantedCallingCardBrowse") end)
		local panel = CreateFrame("Frame", nil, browse)
		panel:SetSize(BROWSE_PANEL[1], BROWSE_PANEL[2])
		panel:SetPoint("CENTER")
		Theme:Skin(panel, { 0.07, 0.08, 0.10, 1 }, { 1, 1, 1, 0.10 })
		browse.title = Theme:Text(panel, "title", "", { 0.95, 0.70, 0.30 })
		browse.title:SetPoint("TOPLEFT", 20, -16)
		browse.count = Theme:Text(panel, "small", "", { 0.6, 0.62, 0.68 })
		browse.count:SetPoint("TOPLEFT", browse.title, "BOTTOMLEFT", 0, -4)
		local close = W:Button(panel, "Done", "secondary", 80, 28, function() browse:Hide() end)
		close:SetPoint("TOPRIGHT", -20, -16)
		browse.only = W:Toggle(panel, "Only show earned", function(on)
			Wanted.db.cardOnlyEarned = on or nil
			private.BuildBrowse()
			private.DrawBrowse()
		end)
		browse.only:SetPoint("RIGHT", close, "LEFT", -20, 0)
		W:Explain(browse.only, "Only show earned", "Hide the pieces you haven't unlocked.")
		browse.grid = CreateFrame("Frame", nil, panel)
		browse.grid:SetSize(BROWSE_WIDTH + 12, BROWSE_HEIGHT)
		browse.grid:SetPoint("TOPLEFT", 20, -70)
		browse.grid:EnableMouseWheel(true)
		browse.grid:SetScript("OnMouseWheel", function(_, delta)
			browse.offset = browse.offset - delta
			private.DrawBrowse()
		end)
		browse.empty = Theme:Text(browse.grid, "body", "Nothing earned in this part yet.", { 0.6, 0.62, 0.68 })
		browse.empty:SetPoint("CENTER")
		browse.track = browse.grid:CreateTexture(nil, "BORDER")
		browse.track:SetPoint("TOPRIGHT", -2, 0)
		browse.track:SetPoint("BOTTOMRIGHT", -2, 0)
		browse.track:SetWidth(4)
		browse.track:SetColorTexture(1, 1, 1, 0.02)
		browse.thumb = browse.grid:CreateTexture(nil, "ARTWORK")
		browse.thumb:SetWidth(4)
		browse.thumb:SetColorTexture(1, 1, 1, 0.27)
	end
	browse.part = part
	private.BuildBrowse()
	private.DrawBrowse()
	browse:Show()
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
		row.browse = W:Button(row, "Browse", "secondary", 80, 28, function() private.OpenBrowse(p.part) end)
		row.browse:SetPoint("LEFT", row, "RIGHT", 8, 0)
		W:Explain(row.browse, "Browse "..strlower(p.title).."s", "See every one as a picture, the ones you own first.")
		frame.rows[p.part] = row
		previous = row
	end

	local buttons = CreateFrame("Frame", nil, frame)
	buttons:SetSize(480, 30)
	buttons:SetPoint("TOP", previous, "BOTTOM", 0, -14)
	frame.save = W:Button(buttons, "Save", "primary", 110, 28, private.Save)
	frame.save:SetPoint("LEFT")
	W:AttachTooltip(frame.save, "Save your calling card", "Needs the Wanted app: it sends the card to wanteddeadordead.com after your next /reload or logout. Only unlocked pieces can be saved: earn them through their challenges.")
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
	-- What a save did, under the buttons it came from
	frame.saved = Theme:Text(frame, "small", "", { 0.45, 0.78, 0.50 })
	frame.saved:SetPoint("TOP", buttons, "BOTTOM", 0, -8)
	frame:SetScript("OnHide", function()
		if private.browse then
			private.browse:Hide()
		end
	end)
	private.frame = frame
	return frame
end

Wanted:RegisterCommand("card", "Your calling card: change it (pieces you've unlocked) or try any combination.", function()
	if not CallingCard:On() then
		Wanted:Print("Calling cards are off. Turn them on in Settings (Alerts).")
		return
	end
	CallingCard:Show()
end)
