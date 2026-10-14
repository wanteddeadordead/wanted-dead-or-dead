-- Wanted: Dead Man's Hand Poker. The table window: the felt with up to eight seats around it (yours at the
-- bottom), the board and pot in the middle, the action bar on your turn, and the hand log beside it. It draws
-- whatever state the host last sent (Net) and sends your actions back; nothing here decides a rule.
local _, Poker = ...
local TableUI = Poker:NewModule("PokerTable")
local Wanted = Poker.Wanted
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Engine = Poker.PokerEngine
local Cards = Poker.PokerCards
local Bots = Poker.PokerBots
local Engine = Poker.PokerEngine
local Protocol = Poker.PokerProtocol
local Net = Poker.PokerNet
local private = {
	frame = nil,
	seats = {}, -- display index -> seat frame
	board = {},
	state = nil,
	deadlineAt = nil, -- when the player to act runs out of time, by our clock
	turnSeconds = Protocol.DEFAULT_TURN_SECONDS,
	loggedKey = nil, loggedActions = 0, loggedStreet = nil, loggedResults = false,
	acts = {}, -- seat -> what they did last this hand (NoteActions)
}
local WIDTH, HEIGHT = 900, 560
local HEADER = 26
local LOG_WIDTH = 220
local ACTION_H = 58
local DEFAULT_SCALE, MIN_SCALE, MAX_SCALE = 1.2, 0.7, 2 -- the whole table scales: dragged at its corner grip, kept in the saved window
local STATUS_H = 24 -- the strip of rail under the felt where the status line goes (no seat can cover it there)
local RAIL = { 0.26, 0.14, 0.07, 1 }
local FELT = { 0.08, 0.21, 0.13, 1 }
local FELT_LINE = { 0.16, 0.34, 0.2, 1 }
local SEAT_BG = { 0, 0, 0, 0.5 }
local SEAT_BORDER = { 1, 1, 1, 0.1 }
local SEAT_W, SEAT_H = 150, 86 -- the name across the top, the stack and status at the left, the cards under the name at the right
local CARD_W, CARD_H = 46, 64
local CHIP = 14 -- a chip by a bet
local CHIP_COLORS = { { 1, 1, 1 }, { 1, 0.82, 0.35 }, { 0.35, 1, 0.45 }, { 0.45, 0.65, 1 }, { 0.3, 0.3, 0.32 } } -- white, gold, green, blue, black
local SMALL_W, SMALL_H = 34, 48

local function Name(full)
	return Ambiguate and Ambiguate(full, "none") or (full:match("^([^%-]+)") or full)
end

local function Chips(n, cfg)
	return Protocol:Money(n or 0, cfg and cfg.stakes)
end

local function Ordinal(n)
	local last, tens = n % 10, n % 100
	local suffix = (tens >= 11 and tens <= 13) and "th" or (last == 1 and "st") or (last == 2 and "nd") or (last == 3 and "rd") or "th"
	return n..suffix
end

local function Clock(seconds)
	seconds = max(0, floor(seconds + 0.5))
	return ("%d:%02d"):format(floor(seconds / 60), seconds % 60)
end

-- ============================================================================
-- Building
-- ============================================================================

local function TimerBar(parent)
	local bar = CreateFrame("Frame", nil, parent)
	bar:SetHeight(3)
	bar.track = Theme:Fill(bar, { 1, 1, 1, 0.08 })
	bar.fill = bar:CreateTexture(nil, "ARTWORK")
	bar.fill:SetPoint("TOPLEFT")
	bar.fill:SetPoint("BOTTOMLEFT")
	bar.fill:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 1)
	function bar:SetFraction(f)
		local width = max(1, (self:GetWidth() or 100) * max(0, min(1, f)))
		self.fill:SetWidth(width)
		local color = f < 0.25 and C.red or C.gold
		self.fill:SetColorTexture(color[1], color[2], color[3], 1)
	end
	return bar
end

-- A seat box's border, so many pixels wide: the winner's thick, the player to act's a little thicker than the rest
local function BorderWidth(frame, px)
	local edges = frame._edges
	if not edges then return end
	edges[1]:SetHeight(px)
	edges[2]:SetHeight(px)
	edges[3]:SetWidth(px)
	edges[4]:SetWidth(px)
end

local function BuildSeat(felt, k)
	local seat = CreateFrame("Frame", nil, felt)
	seat:SetSize(SEAT_W, SEAT_H)
	Theme:Skin(seat, SEAT_BG, SEAT_BORDER)
	seat.name = Theme:Text(seat, "body", "")
	seat.name:SetPoint("TOPLEFT", 8, -6)
	seat.name:SetWidth(SEAT_W - 44) -- room for the dealer pill
	seat.name:SetJustifyH("LEFT")
	seat.name:SetWordWrap(false)
	seat.stack = Theme:Text(seat, "small", "", C.gold)
	seat.stack:SetPoint("TOPLEFT", 8, -28)
	seat.status = W:Pill(seat)
	seat.status:SetPoint("BOTTOMLEFT", 6, 5)
	seat.cards = { Cards:New(seat, SMALL_W, SMALL_H, "small"), Cards:New(seat, SMALL_W, SMALL_H, "small") }
	seat.cards[1]:SetPoint("BOTTOMRIGHT", -6 - SMALL_W - 3, 6)
	seat.cards[2]:SetPoint("BOTTOMRIGHT", -6, 6)
	-- The dealer button: a white disc with a black D, outside the box at a corner (Place)
	seat.dealer = CreateFrame("Frame", nil, seat)
	seat.dealer:SetSize(20, 20)
	seat.dealer:SetPoint("BOTTOM", seat, "TOPRIGHT", -14, 3)
	seat.dealer.disc = seat.dealer:CreateTexture(nil, "ARTWORK")
	seat.dealer.disc:SetAllPoints()
	seat.dealer.disc:SetTexture("Interface\\AddOns\\"..Poker.FOLDER.."\\Media\\suit-disc")
	seat.dealer.disc:SetVertexColor(0.96, 0.95, 0.9, 1)
	seat.dealer.text = seat.dealer:CreateFontString(nil, "OVERLAY")
	seat.dealer.text:SetFont("Fonts\\ARIALN.TTF", 13, "")
	seat.dealer.text:SetPoint("CENTER", 0, 0)
	seat.dealer.text:SetTextColor(0.08, 0.08, 0.1)
	function seat.dealer:Set(text)
		self.text:SetText(text or "")
		self:SetShown(text ~= nil)
	end
	seat.dealer:Set(nil)
	seat.bet = Theme:Text(felt, "body", "", C.text) -- what they did and what it cost, on the felt beside them
	seat.bet:SetJustifyH("CENTER")
	-- A stack of chips by the bet: Wanted's seal, one to four high by how big the bet is against the blind
	seat.chips = {}
	for i = 1, 4 do
		local chip = felt:CreateTexture(nil, "ARTWORK", nil, i)
		chip:SetSize(CHIP, CHIP)
		chip:SetTexture("Interface\\AddOns\\WantedDeadOrDead\\Media\\seal")
		chip:SetPoint("RIGHT", seat.bet, "LEFT", -5, (i - 1) * 3)
		chip:Hide()
		seat.chips[i] = chip
	end
	seat.timer = TimerBar(seat)
	seat.timer:SetPoint("BOTTOMLEFT", 1, 1)
	seat.timer:SetPoint("BOTTOMRIGHT", -1, 1)
	seat.timer:Hide()
	seat.won = Theme:Text(felt, "small", "", C.green) -- at the showdown, the hand they showed, above the box, clear of the dealer button at the corner
	seat.won:SetPoint("BOTTOMLEFT", seat, "TOPLEFT", 4, 4)
	seat.won:SetWidth(SEAT_W - 36)
	seat.won:SetJustifyH("LEFT")
	seat.won:SetWordWrap(true) -- onto a second line rather than cut short
	seat.won:SetMaxLines(2)
	seat.won:Hide()
	seat.empty = Theme:Text(seat, "small", "", C.faint)
	seat.empty:SetPoint("CENTER")
	seat.empty:SetJustifyH("CENTER")
	seat.k = k
	return seat
end

-- Where display position k of n seats sits around the felt: you at the bottom, the next seat to your left
local function Place(seat, k, n, felt)
	local angle = -math.pi / 2 - k * (2 * math.pi / n)
	local w, h = felt:GetWidth() or 600, felt:GetHeight() or 400
	local rx, ry = w / 2 - SEAT_W / 2 - 10, h / 2 - SEAT_H / 2 - 8
	local x, y = rx * math.cos(angle), ry * math.sin(angle)
	seat:ClearAllPoints()
	seat:SetPoint("CENTER", felt, "CENTER", x, y)
	-- The bet sits between the seat and the middle; the dealer button rests on the box's corner, on the side facing the middle
	-- The bet label a set distance in from the box toward the middle, with room for the chips on its outer side; for
	-- the lower seats above the hand named over the box, for the upper ones below the box
	local function toward(v, inset) if v > 1 then return v - math.min(v, inset) elseif v < -1 then return v + math.min(-v, inset) end return 0 end
	local lx = toward(x, SEAT_W / 2 + 40)
	local ly = y > 1 and (y - SEAT_H / 2 - 16) or y < -1 and (y + SEAT_H / 2 + 38) or 0
	if math.abs(x) > 1 and math.abs(y) <= 1 then ly = 0 end
	seat.bet:ClearAllPoints()
	seat.bet:SetPoint("CENTER", felt, "CENTER", lx, ly)
	-- The chips on the label's outer side, away from the board
	for i, chip in ipairs(seat.chips) do
		chip:ClearAllPoints()
		if x > 1 then chip:SetPoint("LEFT", seat.bet, "RIGHT", 5, (i - 1) * 3) else chip:SetPoint("RIGHT", seat.bet, "LEFT", -5, (i - 1) * 3) end
	end
	-- The dealer button on the corner facing the middle vertically, and on the side AWAY from the bet label (which sits
	-- toward the middle): the left corner for seats on the left half, the right corner otherwise
	seat.dealer:ClearAllPoints()
	local corner = x < -1 and "LEFT" or "RIGHT"
	local dx = x < -1 and 14 or -14
	if y > 0 then
		seat.dealer:SetPoint("TOP", seat, "BOTTOM"..corner, dx, -3)
	else
		seat.dealer:SetPoint("BOTTOM", seat, "TOP"..corner, dx, 3)
	end
end

-- The player's choices for the table: sounds (each one picked from the game's own sounds, a SharedMedia sound, or
-- none), a four-colour deck, the window opening on their turn
local SOUND_DEFAULTS = { deal = "kit:IG_ABILITY_PAGE_TURN", chips = "kit:LOOT_WINDOW_COIN_SOUND", fold = "kit:IG_SPELLBOOK_OPEN", turn = "kit:READY_CHECK", win = "kit:IG_QUEST_LIST_COMPLETE", tick = "kit:IG_CREATURE_NEUTRAL_SELECT" }
local SOUND_KINDS = { { "deal", "Deal", "Cards dealt, and each new street." }, { "chips", "Chips", "A bet, a raise, a call." }, { "fold", "Fold", "Cards thrown in." }, { "turn", "Your turn", "The moment it's yours to act." },
	{ "win", "Pot won", "A pot that comes to you." }, { "tick", "Five seconds", "Once, when five seconds are left on your clock." } }
-- The game's sounds offered, { SOUNDKIT name, label }; ones this client lacks aren't offered
local GAME_SOUNDS = {
	{ "IG_ABILITY_PAGE_TURN", "Page turn" }, { "LOOT_WINDOW_COIN_SOUND", "Coins" }, { "READY_CHECK", "Ready check" }, { "IG_QUEST_LIST_COMPLETE", "Quest complete" },
	{ "IG_CREATURE_NEUTRAL_SELECT", "Tick" }, { "MAP_PING", "Map ping" }, { "TELL_MESSAGE", "Whisper" }, { "IG_PLAYER_INVITE", "Invite" }, { "IG_BACKPACK_OPEN", "Bag open" },
	{ "IG_MAINMENU_OPEN", "Menu open" }, { "IG_SPELLBOOK_OPEN", "Spellbook" }, { "IG_QUEST_LOG_OPEN", "Quest log" }, { "AUCTION_WINDOW_OPEN", "Auction house" },
	{ "GS_TITLE_OPTION_OK", "Click" }, { "UI_EPICLOOT_TOAST", "Epic loot" }, { "UI_LEGENDARY_LOOT_TOAST", "Legendary loot" }, { "UI_BONUS_LOOT_ROLL_END", "Bonus roll" },
	{ "PVP_THROUGH_QUEUE", "Queue ready" }, { "RAID_WARNING", "Raid warning" }, { "RAID_BOSS_EMOTE_WARNING", "Boss emote" }, { "UI_RAID_BOSS_WHISPER_WARNING", "Boss whisper" },
	{ "ALARM_CLOCK_WARNING_1", "Alarm clock 1" }, { "ALARM_CLOCK_WARNING_2", "Alarm clock 2" }, { "ALARM_CLOCK_WARNING_3", "Alarm clock 3" },
}
local SOUND_MENU_PAGE = 12
local function Options()
	Poker.db.options = Poker.db.options or { sounds = true, fourColor = false, popOnTurn = true }
	Poker.db.options.sound = Poker.db.options.sound or {}
	return Poker.db.options
end
TableUI.Options = Options

---A poker sound's choice: "kit:NAME", "lsm:Name" or "none".
---@param what string "deal" | "chips" | "turn" | "win" | "tick"
---@return string
function TableUI:SoundChoice(what)
	return Options().sound[what] or SOUND_DEFAULTS[what] or "none"
end

---@param what string
---@param choice string
function TableUI:SetSound(what, choice)
	Options().sound[what] = choice
end

---A sound choice as shown.
---@param choice string
---@return string
function TableUI:SoundLabel(choice)
	if choice == "none" then return "None" end
	for _, entry in ipairs(GAME_SOUNDS) do
		if choice == "kit:"..entry[1] then return entry[2] end
	end
	return choice:match("^lsm:(.+)$") or choice
end

-- Plays a poker sound as chosen, when sounds are on (or regardless, for a preview)
local function Play(what, preview)
	if not preview and not Options().sounds then return end
	local choice = TableUI:SoundChoice(what)
	local kit = choice:match("^kit:(.+)$")
	if kit then
		if SOUNDKIT and SOUNDKIT[kit] and PlaySound then PlaySound(SOUNDKIT[kit], "Master") end
		return
	end
	local name = choice:match("^lsm:(.+)$")
	local media = name and LibStub and LibStub("LibSharedMedia-3.0", true)
	local path = media and media:Fetch("sound", name, true)
	if path and PlaySoundFile then PlaySoundFile(path, "Master") end
end
TableUI.Play = Play

-- The sound choices for one poker sound, under its button: the game's sounds, then SharedMedia's a page at a time
function private.SoundMenu(what, anchor, page)
	local current = TableUI:SoundChoice(what)
	local function Item(choice, text)
		return { text = text, color = choice == current and C.accent or nil, onClick = function()
			TableUI:SetSound(what, choice)
			Play(what, true)
			private.RefreshSettings()
		end }
	end
	local items = {}
	local shared = Wanted.Alerts and Wanted.Alerts:GetSharedMediaSounds() or {}
	if page then
		tinsert(items, { text = "SharedMedia sounds", header = true })
		local first = (page - 1) * SOUND_MENU_PAGE + 1
		for i = first, min(#shared, first + SOUND_MENU_PAGE - 1) do
			tinsert(items, Item("lsm:"..shared[i], shared[i]))
		end
		tinsert(items, "-")
		if #shared > page * SOUND_MENU_PAGE then
			tinsert(items, { text = "More...", onClick = function() private.SoundMenu(what, anchor, page + 1) end })
		end
		tinsert(items, { text = "Back", onClick = function() private.SoundMenu(what, anchor) end })
	else
		tinsert(items, Item("none", "None"))
		for _, entry in ipairs(GAME_SOUNDS) do
			if SOUNDKIT and SOUNDKIT[entry[1]] then tinsert(items, Item("kit:"..entry[1], entry[2])) end
		end
		if #shared > 0 then
			tinsert(items, "-")
			tinsert(items, { text = ("SharedMedia sounds (%d)..."):format(#shared), onClick = function() private.SoundMenu(what, anchor, 1) end })
		end
	end
	W:Menu(items, anchor)
end

-- The settings panel over the felt
function private.BuildSettings()
	local panel = CreateFrame("Frame", nil, private.frame)
	panel:SetSize(400, 330)
	panel:SetPoint("CENTER", private.felt, "CENTER", 0, 0)
	panel:SetFrameLevel(private.frame:GetFrameLevel() + 30)
	panel:EnableMouse(true)
	Theme:Skin(panel, C.bg, C.borderLight)
	local title = Theme:Text(panel, "heading", "Table settings")
	title:SetPoint("TOPLEFT", 14, -12)
	local close = W:Button(panel, "X", "ghost", 22, 22, function() panel:Hide() end)
	close:SetPoint("TOPRIGHT", -6, -6)
	local o = Options()
	panel.sounds = W:Toggle(panel, "Sounds", function(on) o.sounds = on end)
	panel.sounds:SetPoint("TOPLEFT", 14, -40)
	panel.picks = {}
	local y = -66
	for _, kind in ipairs(SOUND_KINDS) do
		local label = Theme:Text(panel, "small", kind[2], C.muted)
		label:SetPoint("TOPLEFT", 30, y - 5)
		local pick = W:Button(panel, "", "secondary", 150, 22, function(self) private.SoundMenu(kind[1], self) end)
		pick:SetPoint("TOPLEFT", 120, y)
		pick.label:SetWidth(132)
		pick.label:SetWordWrap(false)
		W:AttachTooltip(pick, kind[2], kind[3])
		panel.picks[kind[1]] = pick
		local hear = W:Button(panel, "Hear it", "chip", 56, 22, function() Play(kind[1], true) end)
		hear:SetPoint("LEFT", pick, "RIGHT", 6, 0)
		y = y - 28
	end
	panel.fourColor = W:Toggle(panel, "Four-colour deck (green clubs, blue diamonds)", function(on)
		o.fourColor = on
		if private.state then TableUI:Refresh(private.state) end
	end)
	panel.fourColor:SetPoint("TOPLEFT", 14, y - 8)
	panel.popOnTurn = W:Toggle(panel, "Open the table on my turn", function(on) o.popOnTurn = on end)
	panel.popOnTurn:SetPoint("TOPLEFT", 14, y - 34)
	local hint = Theme:Text(panel, "tiny", "Add your own sounds with a SharedMedia addon.", C.faint)
	hint:SetPoint("BOTTOMLEFT", 14, 10)
	panel:Hide()
	private.settings = panel
end

function private.RefreshSettings()
	local panel = private.settings
	if not panel then return end
	local o = Options()
	panel.sounds:SetChecked(o.sounds ~= false)
	panel.fourColor:SetChecked(o.fourColor == true)
	panel.popOnTurn:SetChecked(o.popOnTurn ~= false)
	for what, pick in pairs(panel.picks) do
		pick:SetText(TableUI:SoundLabel(TableUI:SoundChoice(what)))
	end
end

---Shows or hides the table's settings.
function TableUI:ToggleSettings()
	if not private.frame then private.Build() end
	if not private.settings then private.BuildSettings() end
	if private.settings:IsShown() then
		private.settings:Hide()
	else
		private.RefreshSettings()
		private.settings:Show()
	end
end

function private.Build()
	local frame = CreateFrame("Frame", "WantedPokerTableFrame", UIParent)
	frame:SetSize(WIDTH, HEIGHT)
	-- On the Wanted window's layer and above it when shown: below, it opened behind the window and seemed not to open
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	Theme:Skin(frame, C.bg, C.borderLight)
	local saved = Poker.db and Poker.db.window
	if saved and saved.point then
		frame:SetPoint(saved.point, UIParent, saved.point, saved.x, saved.y)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
	end
	frame:SetScale(saved and saved.scale or DEFAULT_SCALE)
	frame:Hide()
	tinsert(UISpecialFrames, "WantedPokerTableFrame")
	local function SaveWindow()
		local point, _, _, x, y = frame:GetPoint(1)
		if Poker.db then Poker.db.window = { point = point, x = x, y = y, scale = frame:GetScale() } end
	end
	private.SaveWindow = SaveWindow

	local header = CreateFrame("Frame", nil, frame)
	header:SetPoint("TOPLEFT", 1, -1)
	header:SetPoint("TOPRIGHT", -1, -1)
	header:SetHeight(HEADER)
	Theme:Fill(header, C.titleBar)
	header:EnableMouse(true)
	header:RegisterForDrag("LeftButton")
	header:SetScript("OnDragStart", function() frame:StartMoving() end)
	header:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		SaveWindow()
	end)
	local mark = header:CreateTexture(nil, "ARTWORK")
	mark:SetSize(3, 14)
	mark:SetPoint("LEFT", 8, 0)
	mark:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)
	private.title = Theme:Text(header, "heading", "Dead Man's Hand")
	private.title:SetPoint("LEFT", mark, "RIGHT", 7, 0)
	private.subtitle = Theme:Text(header, "small", "", C.muted)
	private.subtitle:SetPoint("LEFT", private.title, "RIGHT", 10, 0)
	local close = W:Button(header, "X", "ghost", 22, 22, function() frame:Hide() end)
	close:SetPoint("RIGHT", -2, 0)
	W:AttachTooltip(close, "Hide", "You stay seated. Open the table again from the Poker page, or /wanted poker.")
	local main = W:Button(header, "W", "ghost", 22, 22, function() Wanted.UI:Show("poker") end)
	main:SetPoint("RIGHT", close, "LEFT", -2, 0)
	W:AttachTooltip(main, "Open Wanted", "The Poker page: open tables and your seat.")
	private.leave = W:Button(header, "Leave", "ghost", 60, 22, private.ConfirmLeave)
	private.leave:SetPoint("RIGHT", main, "LEFT", -2, 0)
	local options = W:Button(header, "...", "ghost", 22, 22, function() TableUI:ToggleSettings() end)
	options:SetPoint("RIGHT", private.leave, "LEFT", -2, 0)
	W:AttachTooltip(options, "Table settings", "Which sound plays for what, a four-colour deck, and whether the table opens on your turn.")

	-- The felt, with its rail
	local rail = CreateFrame("Frame", nil, frame)
	rail:SetPoint("TOPLEFT", 1, -HEADER - 1)
	rail:SetPoint("BOTTOMRIGHT", -LOG_WIDTH - 1, ACTION_H + 1)
	Theme:Fill(rail, RAIL)
	local felt = CreateFrame("Frame", nil, rail)
	felt:SetPoint("TOPLEFT", 10, -10)
	felt:SetPoint("BOTTOMRIGHT", -10, 10 + STATUS_H)
	Theme:Skin(felt, FELT, FELT_LINE)
	private.felt = felt
	private.status = Theme:Text(rail, "body", "", C.text)
	private.status:SetPoint("BOTTOMLEFT", 10, 6)
	private.status:SetPoint("BOTTOMRIGHT", -10, 6)
	private.status:SetHeight(STATUS_H - 6)
	private.status:SetJustifyH("CENTER")
	private.status:SetWordWrap(false)
	-- Bet presets on the strip's right, on your turn: a share of the pot, or the most you can
	private.presets = {}
	local PRESETS = { { "Min", 0 }, { "1/4", 0.25 }, { "1/2", 0.5 }, { "3/4", 0.75 }, { "Pot", 1 }, { "2x", 2 }, { "Max", nil } }
	local last
	for i = #PRESETS, 1, -1 do
		local def = PRESETS[i]
		local b = W:Button(rail, def[1], "ghost", 36, 20, function() private.Preset(def[2]) end)
		if last then b:SetPoint("RIGHT", last, "LEFT", -2, 0) else b:SetPoint("BOTTOMRIGHT", -8, 2) end
		b:Hide()
		private.presets[#private.presets + 1] = b
		last = b
	end
	-- Pre-actions on the strip's left, while waiting for your turn
	private.checkFold = W:Toggle(rail, "Check/fold", function(on) if on then private.callAny:SetChecked(false) end end)
	private.checkFold:SetPoint("BOTTOMLEFT", 10, 4)
	private.checkFold:Hide()
	private.callAny = W:Toggle(rail, "Call any", function(on) if on then private.checkFold:SetChecked(false) end end)
	private.callAny:SetPoint("LEFT", private.checkFold, "RIGHT", 12, 0)
	private.callAny:Hide()
	-- What your cards make, above your seat
	private.strength = Theme:Text(felt, "small", "", C.gold)
	private.strength:SetJustifyH("LEFT")
	private.strength:SetWordWrap(true) -- onto a second line rather than cut short
	private.strength:SetMaxLines(2)
	private.strength:SetWidth(SEAT_W - 36) -- clear of the dealer button at the corner
	private.pot = Theme:Text(felt, "money", "")
	private.pot:SetPoint("CENTER", 0, CARD_H / 2 + 22)
	private.pot:SetJustifyH("CENTER")
	-- The pot's chips: up to five stacks of five, a chip a big blind, left of the amount
	private.potChips = {}
	for col = 1, 5 do
		for row = 1, 5 do
			local chip = felt:CreateTexture(nil, "ARTWORK", nil, row)
			chip:SetSize(CHIP, CHIP)
			chip:SetTexture("Interface\\AddOns\\WantedDeadOrDead\\Media\\seal")
			chip:SetPoint("RIGHT", private.pot, "LEFT", -6 - (col - 1) * (CHIP - 2), (row - 1) * 3)
			local tint = CHIP_COLORS[col]
			chip:SetVertexColor(tint[1], tint[2], tint[3], 1)
			chip:Hide()
			private.potChips[(col - 1) * 5 + row] = chip
		end
	end
	for i = 1, 5 do
		local card = Cards:New(felt, CARD_W, CARD_H)
		card:SetPoint("CENTER", felt, "CENTER", (i - 3) * (CARD_W + 6), 0)
		private.board[i] = card
	end
	private.info = Theme:Text(felt, "tiny", "", C.muted)
	private.info:SetPoint("TOP", felt, "CENTER", 0, -CARD_H / 2 - 8)
	private.info:SetJustifyH("CENTER")
	-- The deal's check, once the hand is over: a green check mark, or a red cross; what it means on hover
	private.lock = CreateFrame("Frame", nil, felt)
	private.lock:SetSize(18, 18)
	private.lock:SetPoint("TOP", private.info, "BOTTOM", 0, -3)
	private.lock.icon = private.lock:CreateTexture(nil, "ARTWORK")
	private.lock.icon:SetAllPoints()
	function private.lock:Set(state)
		self.state = state
		if state == "ok" then
			self.icon:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
		elseif state == "failed" then
			self.icon:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
		end
		self:SetShown(state ~= nil)
	end
	private.lock:Set(nil)
	private.lock:EnableMouse(true)
	private.lock:SetScript("OnEnter", function(self)
		local st = private.state
		if not st or not st.hand then return end
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(self.state == "failed" and "The deal FAILED its check" or "The deal checked out", 1, 1, 1)
		GameTooltip:AddLine("Every player's secret went into this shuffle, so nobody could choose the deck. Your client checks the host's account of the hand once it's over.", C.muted[1], C.muted[2], C.muted[3], true)
		if st.hand.dh then GameTooltip:AddLine("Deck "..strsub(st.hand.dh, 1, 16).."...", C.text[1], C.text[2], C.text[3]) end
		local audit = private.audits and private.audits[st.hand.key]
		if audit then
			GameTooltip:AddLine(audit.ok and "Verified by this client." or ("FAILED: "..tostring(audit.reason)), unpack(audit.ok and C.green or C.red))
		end
		GameTooltip:Show()
	end)
	private.lock:SetScript("OnLeave", function() GameTooltip:Hide() end)
	for k = 0, Protocol.MAX_SEATS - 1 do
		private.seats[k] = BuildSeat(felt, k)
	end

	-- The action bar
	local bar = CreateFrame("Frame", nil, frame)
	bar:SetPoint("BOTTOMLEFT", 1, 1)
	bar:SetPoint("BOTTOMRIGHT", -LOG_WIDTH - 1, 1)
	bar:SetHeight(ACTION_H)
	Theme:Fill(bar, C.titleBar)
	private.bar = bar
	private.sitOut = W:Button(bar, "Sit out", "ghost", 70, 24, private.ToggleSitOut)
	private.sitOut:SetPoint("LEFT", 10, 0)
	private.rebuy = W:Button(bar, "Rebuy", "secondary", 70, 24, private.AskRebuy)
	private.rebuy:SetPoint("LEFT", private.sitOut, "RIGHT", 6, 0)
	private.rebuy:Hide()
	private.start = W:Button(bar, "Start tournament", "primary", 140, 24, function()
		local ok, why = Net:StartTournament()
		if not ok then Wanted.UI:Toast(why or "Couldn't start.", C.red) end
	end)
	private.start:SetPoint("LEFT", private.rebuy, "RIGHT", 6, 0)
	private.start:Hide()
	private.countdown = Theme:Text(bar, "small", "", C.muted)
	private.countdown:SetPoint("LEFT", private.start, "RIGHT", 10, 0)
	private.allin = W:Button(bar, "All-in", "danger", 90, 28, function()
		local st = private.state
		if st and st.cfg.stakes == "gold" then
			local mine = st.me and st.seats[st.me]
			W:Dialog({ title = "All in?", text = ("Everything in front of you, %s, goes in."):format(Chips((mine and mine.s or 0) + (mine and mine.b or 0), st.cfg)), confirmLabel = "All in", confirmStyle = "danger",
				onConfirm = function() private.Act("allin") end })
		else
			private.Act("allin")
		end
	end)
	private.allin:SetPoint("RIGHT", -10, 0)
	private.raise = W:Button(bar, "Raise", "primary", 100, 28, function() private.Act(private.raiseAction, private.amount) end)
	private.raise:SetPoint("RIGHT", private.allin, "LEFT", -6, 0)
	private.amountBox = W:Input(bar, 60, "", function(text)
		local n = Protocol:ParseAmount(text, private.state and private.state.cfg and private.state.cfg.stakes)
		if n and private.range then
			n = max(private.range[1], min(private.range[2], floor(n)))
			private.amount = n
			private.slider:SetValue(n)
			private.raise:SetText(private.raiseLabel.." "..Chips(n, private.state and private.state.cfg))
		end
	end)
	private.amountBox:SetPoint("RIGHT", private.raise, "LEFT", -6, 0)
	private.slider = W:Slider(bar, "", 120, 0, 1, 1, function(v) return "" end, function(v)
		private.amount = v
		private.amountBox:SetValue(Chips(v, private.state and private.state.cfg))
		private.raise:SetText(private.raiseLabel.." "..Chips(v, private.state and private.state.cfg))
	end)
	private.slider:SetPoint("RIGHT", private.amountBox, "LEFT", -8, 4)
	private.call = W:Button(bar, "Call", "secondary", 90, 28, function() private.Act(private.callAction) end)
	private.call:SetPoint("RIGHT", private.slider, "LEFT", -12, -4)
	private.fold = W:Button(bar, "Fold", "ghost", 60, 28, function() private.Act("fold") end)
	private.fold:SetPoint("RIGHT", private.call, "LEFT", -6, 0)

	-- The hand log
	local side = CreateFrame("Frame", nil, frame)
	side:SetPoint("TOPLEFT", frame, "TOPRIGHT", -LOG_WIDTH - 1, -HEADER - 1)
	side:SetPoint("BOTTOMRIGHT", -1, 1)
	Theme:Fill(side, C.sidebar)
	local label = Theme:Text(side, "tiny", "HAND LOG", C.faint)
	label:SetPoint("TOPLEFT", 10, -8)
	local log = CreateFrame("ScrollingMessageFrame", nil, side)
	log:SetPoint("TOPLEFT", 10, -24)
	log:SetPoint("BOTTOMRIGHT", -8, 8)
	log:SetFontObject(Theme.Fonts.small)
	log:SetJustifyH("LEFT")
	log:SetFading(false)
	log:SetMaxLines(300)
	log:SetInsertMode(SCROLLING_MESSAGE_FRAME_INSERT_MODE_TOP or 1) -- the game's constant is a number; a string means bottom
	log:EnableMouseWheel(true)
	log:SetScript("OnMouseWheel", function(self, delta)
		if delta > 0 then self:ScrollUp() else self:ScrollDown() end
	end)
	private.log = log

	-- The grip at the corner: drag it out for a bigger table, in for a smaller one (the whole window scales)
	local grip = CreateFrame("Frame", nil, frame)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -3, 3)
	grip:SetFrameLevel(frame:GetFrameLevel() + 20)
	grip:EnableMouse(true)
	local gripTexture = grip:CreateTexture(nil, "OVERLAY")
	gripTexture:SetAllPoints()
	gripTexture:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetScript("OnMouseDown", function()
		local x, y = GetCursorPosition()
		private.sizing = { x = x, y = y, scale = frame:GetScale() }
	end)
	grip:SetScript("OnMouseUp", function()
		private.sizing = nil
		SaveWindow()
	end)
	W:AttachTooltip(grip, "Size", "Drag to make the table bigger or smaller.")

	-- Hotkeys on your turn: F folds, C checks or calls, R raises the amount set. Other keys go on to the game
	frame:EnableKeyboard(true)
	if frame.SetPropagateKeyboardInput then frame:SetPropagateKeyboardInput(true) end
	frame:SetScript("OnKeyDown", function(self, key)
		local st = private.state
		if not st or not st.hand or st.hand.toAct ~= st.me or not st.hand.legal or (private.amountBox.HasFocus and private.amountBox:HasFocus()) then return end
		if key == "F" then private.Act("fold")
		elseif key == "C" then private.Act(private.callAction)
		elseif key == "R" and private.raise:IsShown() then private.Act(private.raiseAction, private.amount)
		end
	end)
	frame:SetScript("OnUpdate", function(_, elapsed)
		if private.sizing then private.Size() end
		private.sinceTick = (private.sinceTick or 0) + elapsed
		if private.sinceTick >= 0.2 then
			private.sinceTick = 0
			private.TickClock()
		end
	end)
	private.frame = frame
	return frame
end

-- A card dealt: it slides in from the middle of the felt (where the deck would be), a beat after the one before
local function Dealt(card, order)
	local felt = private.felt
	local cx, cy = card:GetCenter()
	local fx, fy = felt:GetCenter()
	if type(cx) ~= "number" or type(fx) ~= "number" then
		card:Arrive(0, 40, (order or 0) * 0.12)
		return
	end
	card:Arrive(fx - cx, fy - cy + 30, (order or 0) * 0.12)
end

-- The grip is held: the table's scale follows the cursor's distance from the window's middle
function private.Size()
	local s, frame = private.sizing, private.frame
	local x, y = GetCursorPosition()
	local eff = frame:GetEffectiveScale()
	local cx = (frame:GetLeft() + frame:GetRight()) / 2 * eff
	local cy = (frame:GetTop() + frame:GetBottom()) / 2 * eff
	local was = max(math.abs(s.x - cx), math.abs(s.y - cy))
	local now = max(math.abs(x - cx), math.abs(y - cy))
	if was > 1 then
		frame:SetScale(max(MIN_SCALE, min(MAX_SCALE, s.scale * now / was)))
	end
end

-- ============================================================================
-- Actions
-- ============================================================================

function private.Act(action, amount)
	local player = Net:Player()
	if player and action then
		player:Act(action, amount)
	end
end

-- The raise amount set on the bar: slider, box and button together
function private.SetAmount(n)
	if not private.range then return end
	n = max(private.range[1], min(private.range[2], floor(n)))
	private.amount = n
	private.slider:SetValue(n)
	private.amountBox:SetValue(Chips(n, private.state and private.state.cfg))
	private.raise:SetText(private.raiseLabel.." "..Chips(n, private.state and private.state.cfg))
end

---A preset: the least, a share of the pot (what's in it plus the call, on top of the bet to match), or the most.
---@param share number? nil for the most, 0 for the least
function private.Preset(share)
	local st = private.state
	if not st or not st.hand or not private.range then return end
	if share == nil then return private.SetAmount(private.range[2]) end
	if share == 0 then return private.SetAmount(private.range[1]) end
	local hand, legal = st.hand, st.hand.legal
	local call = legal and legal.call or 0
	private.SetAmount((hand.cur or 0) + floor(share * ((hand.pot or 0) + call)))
end
TableUI.Preset = private.Preset

function private.ToggleSitOut()
	local player, st = Net:Player(), private.state
	if not player or not st or not st.me then return end
	local me = st.seats[st.me]
	if me and me.out then
		player:Back()
	else
		player:SitOut()
	end
end

function private.AskRebuy()
	local st = private.state
	local player = Net:Player()
	if not st or not st.me or not player then return end
	local room = st.cfg.buyMax - (st.seats[st.me].s or 0)
	W:Dialog({
		title = "Rebuy",
		text = ("Add chips to your stack, up to %s (the table's most)."):format(Chips(room, st.cfg)),
		input = { placeholder = st.cfg.stakes == "gold" and "e.g. 2g 50s" or "Chips", value = Chips(min(room, st.cfg.buyMin), st.cfg) },
		confirmLabel = "Buy",
		over = private.frame,
		validate = function(value)
			local n = tonumber(value)
			n = Protocol:ParseAmount(value, st.cfg.stakes)
			if not n or n < 1 or n > room then return ("From %s to %s."):format(Chips(1, st.cfg), Chips(room, st.cfg)) end
		end,
		onConfirm = function(value) player:Rebuy(Protocol:ParseAmount(value, st.cfg.stakes)) end,
	})
end

function private.ConfirmLeave()
	local hosting = Net:HostedTable() ~= nil
	local st = private.state
	local tournament = st and st.cfg and st.cfg.kind == "tournament"
	local text
	if tournament and st.started and st.phase ~= "finished" then
		text = hosting and "The tournament is cancelled: nothing is settled, nobody owes anything." or "You forfeit your entry and take your current place."
	else
		text = hosting and "Everyone at your table is sent their final stacks and the table closes." or "Your chips leave with you. A hand under way is folded."
	end
	W:Dialog({
		title = hosting and "Close the table?" or "Leave the table?",
		text = text,
		confirmLabel = hosting and "Close table" or "Leave",
		confirmStyle = "danger",
		over = private.frame,
		onConfirm = function()
			Net:Leave()
			if private.frame then private.frame:Hide() end
		end,
	})
end

-- ============================================================================
-- Drawing
-- ============================================================================

local function Describe(entry, st)
	local who = Name(st.seats[entry.seat] and st.seats[entry.seat].n or ("Seat "..entry.seat))
	local cfg = st.cfg
	if entry.action == "fold" then return who.." folds" end
	if entry.action == "check" then return who.." checks" end
	if entry.action == "call" then return who.." calls "..Chips(entry.amount, cfg) end
	if entry.action == "bet" then return who.." bets "..Chips(entry.amount, cfg) end
	if entry.action == "raise" then return who.." raises to "..Chips(entry.amount, cfg) end
	if entry.action == "allin" then return who.." is all in for "..Chips(entry.amount, cfg) end
	if entry.action == "leave" then return who.." leaves the table" end
	return who.." "..tostring(entry.action)
end

local function Board(board, from, to)
	local names = {}
	for i = from, to do
		if board[i] then names[#names + 1] = Engine:Name(board[i]) end
	end
	return table.concat(names, " ")
end

---Adds a line to the hand log.
---@param text string
---@param color table?
-- The kicker that won a seat its pot, when a shown hand of the same kind lost to it on one: "king", or nil
function private.Kicker(st, seat)
	local hand = st.hand
	local me = st.seats[seat]
	if not hand or not hand.board or #hand.board < 3 or not me or not me.hole or not me.hole[1] then return nil end
	local function Cards(p) local c = { p.hole[1], p.hole[2] } for _, b in ipairs(hand.board) do c[#c + 1] = b end return c end
	local mine = Cards(me)
	for other, p in pairs(st.seats) do
		if other ~= seat and p.hole and p.hole[1] and p.hole[2] then
			local kicker = Engine:DecidingKicker(mine, Cards(p))
			if kicker then return kicker end
		end
	end
	return nil
end

-- A pot's result as one line: who wins it, or a split pot and who shares it; with more than one pot, the main pot and
-- the side pots are named (the engine builds them from the smallest stake up, so the first is the main pot)
local function PotLine(st, pot, index, count)
	local names = {}
	for _, seat in ipairs(pot.winners or {}) do names[#names + 1] = Name(st.seats[seat] and st.seats[seat].n or "?") end
	local which = count > 1 and (index == 1 and "the main pot of " or "a side pot of ") or ""
	local kicker = #(pot.winners or {}) == 1 and private.Kicker(st, pot.winners[1])
	local with = pot.description and (" with "..pot.description..(kicker and (", "..kicker.." kicker") or "")) or ""
	if #names > 1 then
		return ("Split pot: %s split %s%s%s"):format(table.concat(names, " and "), which, Chips(pot.amount, st.cfg), with)
	end
	return ("%s wins %s%s%s"):format(names[1] or "?", which, Chips(pot.amount, st.cfg), with)
end

function TableUI:Log(text, color)
	if not private.log then return end
	color = color or C.text
	private.log:AddMessage(text, color[1], color[2], color[3])
	private.lines = private.lines or {}
	tinsert(private.lines, text)
	if #private.lines > 300 then tremove(private.lines, 1) end
end

-- What's new in this state, said in the log (and heard: the deal, chips going in, a pot won)
function private.LogChanges(st)
	local hand = st.hand
	if st.standings and st.phase == "finished" and not private.loggedFinish then
		private.loggedFinish = true
		for _, row in ipairs(st.standings) do
			if row.place then
				TableUI:Log(("%s: %s%s"):format(Ordinal(row.place), Name(row.name), row.prize and row.prize > 0 and (", "..Protocol:Money(row.prize, "gold")) or ""), row.place == 1 and C.gold or C.text)
			end
		end
	end
	if not hand or not hand.key then return end
	if hand.key ~= private.loggedKey then
		private.loggedKey, private.loggedActions, private.loggedStreet, private.loggedResults, private.loggedDealt = hand.key, 0, nil, false, false
	end
	if hand.street and not private.loggedDealt then
		-- The hand's key is known from the shuffle on; the deal is the first street
		private.loggedDealt = true
		local button = st.seats[hand.button]
		TableUI:Log(("Hand %d: dealt. Button: %s."):format(st.h, button and Name(button.n) or "?"), C.gold)
		Play("deal")
	end
	if hand.street and hand.street ~= private.loggedStreet then
		local board = hand.board or {}
		if hand.street == "flop" and #board >= 3 then TableUI:Log("Flop: "..Board(board, 1, 3), C.muted) end
		if hand.street == "turn" and #board >= 4 then TableUI:Log("Turn: "..Board(board, 4, 4), C.muted) end
		if hand.street == "river" and #board >= 5 then TableUI:Log("River: "..Board(board, 5, 5), C.muted) end
		if private.loggedStreet and (hand.street == "flop" or hand.street == "turn" or hand.street == "river") then Play("deal") end
		private.loggedStreet = hand.street
	end
	if hand.log then
		for i = private.loggedActions + 1, #hand.log do
			TableUI:Log(Describe(hand.log[i], st))
			local a = hand.log[i].action
			if a == "bet" or a == "raise" or a == "call" or a == "allin" then Play("chips") elseif a == "fold" then Play("fold") end
		end
		private.loggedActions = #hand.log
	end
	if hand.results and not private.loggedResults then
		private.loggedResults = true
		local pots = hand.results.pots or {}
		local won = false
		for i, pot in ipairs(pots) do
			TableUI:Log(PotLine(st, pot, i, #pots), C.green)
			for _, seat in ipairs(pot.winners or {}) do if seat == st.me then won = true end end
		end
		if won then Play("win") end
	end
end

---Shows the host's latest state.
---@param st table
-- What two hole cards make with the board, in words: before the flop the cards themselves, after it the hand and
-- any draw ("a pair of kings, flush draw")
local RANK_WORDS = { [2] = "deuce", [3] = "three", [4] = "four", [5] = "five", [6] = "six", [7] = "seven", [8] = "eight", [9] = "nine", [10] = "ten", [11] = "jack", [12] = "queen", [13] = "king", [14] = "ace" }
function private.Strength(hole, board)
	local Engine = Poker.PokerEngine
	if #board < 3 then
		local r1, r2 = Engine:RankOf(hole[1]), Engine:RankOf(hole[2])
		if r1 < r2 then r1, r2 = r2, r1 end
		if r1 == r2 then return "a pair of "..RANK_WORDS[r1].."s" end
		return RANK_WORDS[r1].."-"..RANK_WORDS[r2]..(Engine:SuitOf(hole[1]) == Engine:SuitOf(hole[2]) and " suited" or " offsuit")
	end
	local cards = { hole[1], hole[2] }
	for _, c in ipairs(board) do cards[#cards + 1] = c end
	local text = Engine:Describe(cards)
	if #board < 5 then
		local flush, straight = Bots:Draws(cards)
		if flush and straight then text = text..", flush and straight draws"
		elseif flush then text = text..", flush draw"
		elseif straight then text = text..", straight draw" end
	end
	return text
end

-- What each seat did last in this hand, for its pill: the blinds at the deal, then every action as it comes. Folds and
-- all-ins hold for the hand; the rest clear when the next street is dealt. A raise after a raise on the same street is
-- a re-raise
function private.NoteActions(st)
	local hand = st.hand
	if not hand or not hand.key then
		private.acts, private.actsKey = {}, nil
		return
	end
	if hand.key ~= private.actsKey then
		private.acts, private.actsKey, private.notedActions, private.actsStreet, private.raises = {}, hand.key, 0, nil, 0
	end
	local log = hand.log or {}
	-- The hand's key is known from the shuffle on; the blinds once it's dealt, before anyone has acted
	if hand.sb and hand.bb and #log == 0 and not private.acts[hand.bb] then
		private.acts[hand.sb] = { action = "blind", text = "SB" }
		private.acts[hand.bb] = { action = "blind", text = "BB" }
	end
	for i = (private.notedActions or 0) + 1, #log do
		local e = log[i]
		local text
		if e.action == "fold" then text = "Fold"
		elseif e.action == "check" then text = "Check"
		elseif e.action == "call" then text = "Call "..Chips(e.amount or 0, st.cfg)
		elseif e.action == "bet" then text = "Bet "..Chips(e.amount or 0, st.cfg) private.raises = 1
		elseif e.action == "raise" then
			private.raises = (private.raises or 0) + 1
			text = (private.raises >= 2 and "Re-raise to " or "Raise to ")..Chips(e.amount or 0, st.cfg)
		elseif e.action == "allin" then text = "All-in "..Chips(e.amount or 0, st.cfg)
		end
		if text then private.acts[e.seat] = { action = e.action, text = text } end
	end
	private.notedActions = #log
	if private.actsStreet and hand.street ~= private.actsStreet then
		for seat, a in pairs(private.acts) do
			if a.action ~= "fold" and a.action ~= "allin" then private.acts[seat] = nil end
		end
		private.raises = 0
	end
	private.actsStreet = hand.street
end

function TableUI:Refresh(st)
	if not private.frame then private.Build() end
	private.state = st
	if not st then
		private.frame:Hide()
		return
	end
	local cfg = st.cfg
	local n = cfg.maxSeats
	local me = st.me
	local hand = st.hand
	local playing = hand and hand.stage == "play" and hand.street ~= "done"
	private.subtitle:SetText((cfg.title and cfg.title ~= "" and cfg.title or (Name(st.host).."'s table")).."  -  "..Chips(cfg.sb, cfg).."/"..Chips(cfg.bb, cfg).."  -  host "..Name(st.host))
	private.leave:SetText(Net:HostedTable() and "Close table" or "Leave")
	-- The clock for the player to act
	if hand and hand.left and (playing or hand.stage == "commits" or hand.stage == "reveals") then
		private.deadlineAt = GetTime() + hand.left
		private.turnSeconds = playing and cfg.turnSeconds or (hand.stage == "commits" and Protocol.COMMIT_SECONDS or Protocol.REVEAL_SECONDS)
	else
		private.deadlineAt = nil
	end
	private.nextAt = st.nextIn and (GetTime() + st.nextIn) or nil
	private.levelAt = st.levelLeft and (GetTime() + st.levelLeft) or nil
	-- Winners and their best five, at a showdown
	local winners, best = {}, {}
	if hand and hand.results then
		for _, pot in ipairs(hand.results.pots or {}) do
			for _, seat in ipairs(pot.winners or {}) do winners[seat] = (#pot.winners == 1 or winners[seat] == "sole") and "sole" or "split" end
			for _, card in ipairs(pot.best or {}) do best[card] = true end
		end
	end
	local showdown = hand and hand.results ~= nil
	private.NoteActions(st)
	-- Seats
	for k = 0, Protocol.MAX_SEATS - 1 do
		local seatFrame = private.seats[k]
		local seat = me and ((me - 1 + k) % n) + 1 or (k + 1)
		local p = st.seats[seat]
		if k >= n then
			seatFrame:Hide()
			seatFrame.bet:Hide()
		else
			seatFrame:Show()
			Place(seatFrame, k, n, private.felt)
			if not p then
				seatFrame.name:SetText("")
				seatFrame.stack:SetText("")
				seatFrame.status:Set(nil)
				seatFrame.won:Hide()
				for i = 1, 4 do seatFrame.chips[i]:Hide() end
				seatFrame.dealer:Set(nil)
				seatFrame.cards[1]:Hide()
				seatFrame.cards[2]:Hide()
				seatFrame.bet:Hide()
				seatFrame.timer:Hide()
				seatFrame.empty:SetText("Seat "..seat)
				Theme:SetBorderColor(seatFrame, SEAT_BORDER)
				BorderWidth(seatFrame, 1)
			else
				seatFrame.empty:SetText("")
				seatFrame.name:SetText(Name(p.n))
				local net = cfg.stakes == "gold" and p.bought and (p.s or 0) - p.bought or nil
				seatFrame.stack:SetText(Chips(p.s, cfg)..(net and net ~= 0 and Theme:Colorize("  "..(net > 0 and "+" or "-")..Chips(math.abs(net), cfg), net > 0 and C.green or C.red) or ""))
				-- Cards: yours face up, others' backs while they're in the hand, everyone's at a showdown. Dealt (slid in from
				-- the middle) when the hand is new, a beat apart around the table
				local inHand = hand and (p.b ~= nil or p.tot ~= nil) and not p.f
				local newDeal = playing and hand.key ~= private.dealtKey
				for i = 1, 2 do
					local card = seatFrame.cards[i]
					if p.hole and p.hole[i] then
						card:SetCard(p.hole[i])
						card:SetHighlight(showdown and next(best) and (best[p.hole[i]] or false) or nil)
						card:Show()
					elseif inHand and playing then
						card:SetCard(true)
						card:SetHighlight(nil)
						card:Show()
					else
						card:Hide()
					end
					if newDeal and card:IsShown() then Dealt(card, k * 2 + (i - 1)) end
				end
				-- Status
				local status, color
				if p.unpaid then status, color = "Paying", C.amber
				elseif p.place and p.out == "busted" then status, color = "Out "..Ordinal(p.place), C.red
				elseif p.place == 1 then status, color = "Winner", C.green
				elseif p.out == "busted" then status, color = "Busted", C.red
				elseif p.out == "sitting" then status, color = "Sitting out", C.muted
				elseif p.out == "away" then status, color = "Away", C.amber
				elseif p.out == "missed" then status, color = "Reconnecting", C.amber
				elseif p.f then status, color = "Folded", C.muted
				elseif p.a then status, color = "All-in", C.red
				elseif playing and hand.toAct == seat then status, color = seat == me and "Your turn" or "To act", C.gold
				elseif hand and (hand.stage == "commits" or hand.stage == "reveals") and p.inHand then status, color = "Shuffling", C.blue
				elseif showdown and winners[seat] then status, color = winners[seat] == "split" and "Split" or "Winner", C.green
				elseif private.acts[seat] and (playing or showdown) then
					local a = private.acts[seat]
					status = a.text
					color = (a.action == "bet" or a.action == "raise") and C.amber or (a.action == "allin" and C.red) or (a.action == "blind" and C.muted) or C.text
				elseif p.away and p.away > 0 and not p.out then status, color = "Slow", C.amber
				end
				seatFrame.status:Set(status, color)
				seatFrame.dealer:Set(hand and hand.button == seat and "D" or nil, C.gold)
				-- At the showdown, the hand they showed, above the box: the winner's in green, the rest muted
				local shownHand
				if showdown and p.hole and p.hole[1] and p.hole[2] and hand.board and #hand.board >= 3 then
					local cards = { p.hole[1], p.hole[2] }
					for _, c in ipairs(hand.board) do cards[#cards + 1] = c end
					shownHand = Engine:Describe(cards)
				end
				if shownHand and winners[seat] then
					local kicker = private.Kicker(st, seat)
					if kicker then shownHand = shownHand..", "..kicker.." kicker" end
				end
				if shownHand then
					seatFrame.won:SetText(Theme:Colorize(shownHand, winners[seat] and C.green or C.muted))
					seatFrame.won:Show()
				else
					seatFrame.won:Hide()
				end
				-- The bet in front of them, or what they won
				-- The chips by a bet: one to four high by its size against the big blind, and coloured like a rack: the small
				-- blind's white, the big blind's gold, then green, blue and black as the bets grow
				local stack, tint = 0, CHIP_COLORS[1]
				if not showdown and playing and p.b and p.b > 0 then
					local bb = (st.levelBlinds and st.levelBlinds[2]) or cfg.bb or 1
					local x = p.b / bb
					stack = x <= 2 and 1 or x <= 5 and 2 or x <= 20 and 3 or 4
					tint = CHIP_COLORS[x < 1 and 1 or x <= 1 and 2 or x <= 5 and 3 or x <= 25 and 4 or 5]
				end
				for i = 1, 4 do
					seatFrame.chips[i]:SetShown(i <= stack)
					seatFrame.chips[i]:SetVertexColor(tint[1], tint[2], tint[3], 1)
				end
				if showdown and hand.results.payouts and hand.results.payouts[seat] then
					seatFrame.bet:SetText(Theme:Colorize("+"..Chips(hand.results.payouts[seat], cfg), C.green))
					seatFrame.bet:Show()
				elseif p.b and p.b > 0 then
					-- The amount by the chips; what it was for is in the pill
					seatFrame.bet:SetText(Chips(p.b, cfg))
					seatFrame.bet:Show()
				else
					seatFrame.bet:Hide()
				end
				local acting = playing and hand.toAct == seat
				seatFrame.timer:SetShown(acting)
				Theme:SetBorderColor(seatFrame, acting and C.gold or (showdown and winners[seat] and C.green) or SEAT_BORDER)
				BorderWidth(seatFrame, (showdown and winners[seat]) and 3 or acting and 2 or 1)
			end
		end
	end
	if playing then private.dealtKey = hand.key end
	-- The middle: a card new to its slot is dealt, the flop's three one after another
	local fresh = 0
	for i = 1, 5 do
		local card = hand and hand.board and hand.board[i]
		local was = private.board[i].card
		private.board[i]:SetCard(card or nil)
		if type(card) == "number" and was ~= card then
			Dealt(private.board[i], fresh)
			fresh = fresh + 1
		end
		private.board[i]:SetHighlight(card and showdown and next(best) and (best[card] or false) or nil)
	end
	private.pot:SetText(hand and hand.pot and hand.pot > 0 and ("Pot "..Chips(hand.pot, cfg)) or "")
	local potChips = 0
	if hand and hand.pot and hand.pot > 0 and not showdown then
		local bb = (st.levelBlinds and st.levelBlinds[2]) or cfg.bb or 1
		potChips = max(1, min(25, floor(hand.pot / bb)))
	end
	for i, chip in ipairs(private.potChips) do chip:SetShown(i <= potChips) end
	if cfg.kind == "tournament" and st.started then
		private.info:SetText(("Level %d  -  blinds %d/%d%s%s%s"):format(st.level or 1, st.levelBlinds and st.levelBlinds[1] or 0, st.levelBlinds and st.levelBlinds[2] or 0,
			(st.ante or 0) > 0 and ("  -  ante "..st.ante) or "", st.lateOpen and "  -  late entry open" or "", hand and hand.key and ("  -  hand "..st.h) or ""))
	else
		private.info:SetText(hand and hand.key and ("Hand "..st.h) or "")
	end
	if hand and hand.dh then
		local audit = private.audits and private.audits[hand.key]
		private.lock:Set(audit and (audit.ok and "ok" or "failed") or nil)
	else
		private.lock:Set(nil)
	end
	-- The status line
	local seated = 0
	for _ in pairs(st.seats) do seated = seated + 1 end
	local text, color = "", C.text
	if st.phase == "closed" then
		text, color = "The table is closed.", C.muted
	elseif st.phase == "finished" and st.standings then
		local parts = {}
		for _, row in ipairs(st.standings) do
			if row.place and row.place <= 3 then
				parts[#parts + 1] = ("%s %s%s"):format(Ordinal(row.place), Name(row.name), row.prize and row.prize > 0 and (" ("..Protocol:Money(row.prize, "gold")..")") or "")
			end
		end
		text, color = "Finished: "..table.concat(parts, ", "), C.green
	elseif cfg.kind == "tournament" and not st.started then
		text, color = ("Registering: %d of %d entered. The host starts the tournament.%s"):format(seated, n, (st.lateLevels or 0) > 0 and (" Late entry stays open to level "..st.lateLevels..".") or ""), C.muted
	elseif st.phase == "waiting" then
		text, color = seated < Protocol.MIN_SEATS and ("Waiting for players: %d of %d seated"):format(seated, n) or "Next hand soon", C.muted
	elseif st.phase == "seeding" then
		text, color = "Shuffling: every player's secret goes into the deck", C.blue
	elseif st.phase == "playing" and hand then
		local actor = st.seats[hand.toAct]
		text, color = hand.toAct == me and "Your turn" or ((actor and Name(actor.n) or "?").." to act"), hand.toAct == me and C.gold or C.text
	elseif st.phase == "showdown" and hand and hand.results then
		local lines = {}
		local pots = hand.results.pots or {}
		for i, pot in ipairs(pots) do
			lines[#lines + 1] = PotLine(st, pot, i, #pots)
		end
		text, color = table.concat(lines, "; "), C.green
	end
	local mine = me and st.seats[me]
	if private.blocked then
		text, color = "The game is refusing table messages here (a boss fight or a PvP match). The table waits for it to lift.", C.amber
	elseif mine and mine.unpaid and st.phase ~= "closed" then
		text, color = ("Pay %s your buy-in of %s: trade it to them, or Pay by mail from the Poker page."):format(Name(st.host), Chips(mine.unpaid - (mine.received or 0), cfg)), C.amber
	elseif mine and mine.rebuyDue and st.phase ~= "closed" then
		text, color = ("Your rebuy of %s: trade it to %s, or Pay by mail from the Poker page."):format(Chips(mine.rebuyDue, cfg), Name(st.host)), C.amber
	elseif private.hostGone then
		text, color = "The host has gone quiet. The next seat takes over if they don't come back.", C.amber
	end
	private.status:SetText(text)
	private.status:SetTextColor(color[1], color[2], color[3])
	-- The action bar
	local legal = playing and hand.legal and hand.toAct == me and hand.legal or nil
	private.fold:SetShown(legal ~= nil)
	private.call:SetShown(legal ~= nil)
	private.raise:SetShown(legal ~= nil and (legal.minBet or legal.minRaise) ~= nil)
	private.slider:SetShown(legal ~= nil and (legal.minBet or legal.minRaise) ~= nil)
	private.amountBox:SetShown(legal ~= nil and (legal.minBet or legal.minRaise) ~= nil)
	private.allin:SetShown(legal ~= nil)
	if legal then
		if legal.check then
			private.callAction = "check"
			private.call:SetText("Check")
		else
			private.callAction = "call"
			private.call:SetText("Call "..Chips(legal.call, cfg))
		end
		local low, high = legal.minBet or legal.minRaise, legal.maxBet or legal.maxRaise
		if low then
			private.raiseAction = legal.minBet and "bet" or "raise"
			private.raiseLabel = legal.minBet and "Bet" or "Raise to"
			private.range = { low, high }
			private.slider.slider:SetMinMaxValues(low, high)
			private.slider:SetValue(low)
			private.amount = low
			private.amountBox:SetValue(Chips(low, cfg))
			private.raise:SetText(private.raiseLabel.." "..Chips(low, cfg))
			private.slider.label:SetText(("%s to %s"):format(Chips(low, cfg), Chips(high, cfg)))
		end
		local myStack = st.seats[me] and st.seats[me].s or 0
		private.allin:SetText("All-in "..Chips(myStack + (st.seats[me] and st.seats[me].b or 0), cfg))
	end
	for _, b in ipairs(private.presets) do b:SetShown(legal ~= nil and (legal.minBet or legal.minRaise) ~= nil) end
	-- Pre-actions: offered while waiting in a hand, acted on the moment the turn comes, forgotten with the hand
	local inHand = playing and me and hand.seats and false or (playing and me and st.seats[me] and not st.seats[me].f and not st.seats[me].a)
	if hand and hand.key ~= private.preKey then
		private.preKey = hand.key
		private.checkFold:SetChecked(false)
		private.callAny:SetChecked(false)
	end
	private.checkFold:SetShown(inHand and not legal)
	private.callAny:SetShown(inHand and not legal)
	if legal and (private.checkFold.checked or private.callAny.checked) then
		local action = private.checkFold.checked and (legal.check and "check" or "fold") or (legal.call and "call" or "check")
		private.checkFold:SetChecked(false)
		private.callAny:SetChecked(false)
		private.Act(action)
		legal = nil
	end
	-- Your turn: a sound, the window if it's hidden and wanted, a word in the log otherwise
	local turnKey = legal and (hand.key..":"..#(hand.log or {})) or nil
	if turnKey and turnKey ~= private.turnKey then
		Play("turn")
		private.tickedAt = nil
		if not private.frame:IsShown() then
			if Options().popOnTurn then TableUI:Show() else Wanted.UI:Toast("Poker: your turn.", C.gold) end
		end
	end
	private.turnKey = turnKey
	-- What your cards make
	local mine0 = me and st.seats[me]
	if mine0 and mine0.hole and hand and hand.stage == "play" and not mine0.f and not showdown then
		private.strength:SetText(private.Strength(mine0.hole, hand.board or {}))
		private.strength:ClearAllPoints()
		private.strength:SetPoint("BOTTOMLEFT", private.seats[0], "TOPLEFT", 4, 4)
		private.strength:Show()
	else
		private.strength:Hide()
	end
	local mine = me and st.seats[me]
	local tournament = cfg.kind == "tournament"
	private.sitOut:SetShown(mine ~= nil and st.phase ~= "closed" and st.phase ~= "finished")
	if mine then
		private.sitOut:SetText(mine.out and mine.out ~= "busted" and "I'm back" or "Sit out")
		private.sitOut:SetEnabled(mine.out ~= "busted")
		-- A rebuy any time you're not in a hand: between hands, or while one plays without you (busted, sitting out, folded)
		local dealtIn = playing and mine.tot ~= nil and not mine.f
		private.rebuy:SetShown(not tournament and st.phase ~= "closed" and not dealtIn and (mine.s or 0) < cfg.buyMax and (mine.out == "busted" or (mine.s or 0) < cfg.buyMin))
	else
		private.rebuy:Hide()
	end
	private.start:SetShown(tournament and not st.started and st.phase ~= "closed" and Net:HostedTable() ~= nil)
	private.start:SetEnabled(seated >= Protocol.MIN_SEATS)
	private.leave:SetText(Net:HostedTable() and "Close table" or (tournament and st.started and st.phase ~= "finished" and mine and not mine.place and "Forfeit" or "Leave"))
	private.LogChanges(st)
	private.TickClock()
end

-- Seconds left for the player to act, and for the next hand, by our own clock between states
function private.TickClock()
	local st = private.state
	if not st or not private.frame or not private.frame:IsShown() then return end
	local now = GetTime()
	if private.deadlineAt and st.hand then
		local left = max(0, private.deadlineAt - now)
		for k = 0, Protocol.MAX_SEATS - 1 do
			local seatFrame = private.seats[k]
			if seatFrame.timer:IsShown() then
				seatFrame.timer:SetFraction(left / max(1, private.turnSeconds))
			end
		end
		if st.phase == "playing" and st.hand.toAct then
			local actor = st.seats[st.hand.toAct]
			local mine = st.hand.toAct == st.me
			local who = mine and "Your turn" or ((actor and Name(actor.n) or "?").." to act")
			if not private.hostGone and not private.blocked then
				private.status:SetText(("%s  -  %ds"):format(who, ceil(left)))
				-- The last five seconds of your own clock: red, with one tick
				if mine and left <= 5 then
					private.status:SetTextColor(C.red[1], C.red[2], C.red[3])
					if not private.tickedAt then private.tickedAt = now Play("tick") end
				elseif mine then
					private.status:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
				end
			end
		end
	end
	if private.nextAt and (st.phase == "showdown" or st.phase == "waiting") then
		local left = max(0, private.nextAt - now)
		private.countdown:SetText(left > 0 and ("Next hand in %ds"):format(ceil(left)) or "")
	else
		private.countdown:SetText("")
	end
	if private.levelAt and st.cfg.kind == "tournament" and st.started and st.phase ~= "finished" and st.nextBlinds then
		private.info:SetText(("Level %d  -  blinds %d/%d%s  -  %d/%d in %s%s%s"):format(st.level or 1, st.levelBlinds and st.levelBlinds[1] or 0, st.levelBlinds and st.levelBlinds[2] or 0,
			(st.ante or 0) > 0 and ("  -  ante "..st.ante) or "", st.nextBlinds[1], st.nextBlinds[2], Clock(private.levelAt - now), st.lateOpen and "  -  late entry open" or "", st.hand and st.hand.key and ("  -  hand "..st.h) or ""))
	end
end

---Notes an audit's result for the lock pill and the log.
function TableUI:OnAudit(key, ok, reason)
	private.audits = private.audits or {}
	private.audits[key] = { ok = ok, reason = reason }
	local handNo = key:match("^(%d+)") or key
	-- A deal that checks out shows as the check mark under the board, not in the log
	if not ok then
		TableUI:Log(("Hand %s FAILED verification: %s. Don't settle this hand."):format(handNo, tostring(reason)), C.red)
		Wanted:Print("Poker: hand %s failed verification (%s).", handNo, tostring(reason))
	end
	if private.state then TableUI:Refresh(private.state) end
end

---A settlement line from the host (gold tables): said in the log.
function TableUI:OnSettle(line)
	local me = Net:Me()
	local owe = strlower((gsub(line.from, "%-.*$", ""))) == strlower((gsub(me, "%-.*$", "")))
	TableUI:Log(owe and ("Settlement: you owe %s %s. Pay from the Poker page at a mailbox."):format(Name(line.to), Protocol:Money(line.amount, "gold"))
		or ("Settlement: %s owes you %s."):format(Name(line.from), Protocol:Money(line.amount, "gold")), C.gold)
end

---The host went quiet, or a new one took over.
function TableUI:OnHost(event, name)
	if event == "hostGone" then
		private.hostGone = true
		TableUI:Log("The host has gone quiet.", C.amber)
	elseif event == "newHost" then
		private.hostGone = false
		TableUI:Log(Name(name).." is the host now.", C.amber)
	end
	if private.state then TableUI:Refresh(private.state) end
end

---The game started or stopped refusing table messages (its lockdown in a boss fight or a PvP match).
---@param blocked boolean
function TableUI:OnBlocked(blocked)
	private.blocked = blocked
	TableUI:Log(blocked and "The game is refusing table messages: the table waits." or "Table messages go through again.", C.amber)
	if private.state then TableUI:Refresh(private.state) end
end

---Shows the window, building it first.
function TableUI:Show()
	if not private.frame then private.Build() end
	private.frame:Show()
	private.frame:Raise()
	if private.state then TableUI:Refresh(private.state) end
end

function TableUI:Hide()
	if private.frame then private.frame:Hide() end
end

function TableUI:IsShown()
	return private.frame ~= nil and private.frame:IsShown()
end

---Forgets the last table: a new one starts with a clean window and an empty log (the log stays readable after a
---table closes, until the next one).
function TableUI:Reset()
	private.state, private.deadlineAt, private.nextAt, private.hostGone = nil, nil, nil, false
	private.dealtKey, private.turnKey, private.preKey = nil, nil, nil
	if private.log then private.log:Clear() end
	private.lines = {}
	private.loggedKey, private.loggedActions, private.loggedStreet, private.loggedResults, private.loggedDealt, private.loggedFinish = nil, 0, nil, false, false, false
	private.audits = {}
end

-- For the tests
function TableUI:GetFrame() return private.frame end
function TableUI:GetParts() return private end
