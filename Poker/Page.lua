-- Wanted: Dead Man's Hand Poker. The Poker page in the Wanted window: host a table, or sit at one another Wanted
-- player of your faction is hosting; your seat, with the table window a click away. Also /wanted poker.
local _, Poker = ...
local Page = Poker:NewModule("PokerPage")
local Wanted = Poker.Wanted
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Net = Poker.PokerNet
local Protocol = Poker.PokerProtocol
local TableUI = Poker.PokerTable
local Gold = Poker.PokerGold
local private = { list = nil, form = nil, seat = nil, view = "tables" }
local ROW_HEIGHT = 42
local CARD_HEIGHT = 292 -- the form (three rows) with the guide to the table under it
-- Blinds to pick from: the card room's standard structures, in chips, or at a gold table in copper, silver or gold
-- (a gold table's chip is a copper piece)
local UNITS = { { key = "copper", label = "Copper", mult = 1 }, { key = "silver", label = "Silver", mult = 100 }, { key = "gold", label = "Gold", mult = 10000 } }
local STRUCTURES = { { 1, 2 }, { 2, 5 }, { 5, 10 }, { 10, 20 }, { 25, 50 }, { 50, 100 }, { 100, 200 } }
local BLINDS = { chips = {} }
for _, st in ipairs(STRUCTURES) do BLINDS.chips[#BLINDS.chips + 1] = { key = st[1].."/"..st[2], sb = st[1], bb = st[2] } end
for _, u in ipairs(UNITS) do
	BLINDS[u.key] = {}
	for _, st in ipairs(STRUCTURES) do BLINDS[u.key][#BLINDS[u.key] + 1] = { key = u.key..":"..st[1].."/"..st[2], sb = st[1] * u.mult, bb = st[2] * u.mult } end
end
local BUYIN_MIN_BB, BUYIN_MAX_BB = 20, 100 -- the buy-in range offered when the blinds are picked; the host sets their own

local function Settings()
	Poker.db.host = Poker.db.host or { blinds = "10/20", seats = 6, turn = 30, title = "", stakes = "chips", kind = "cash", startStack = 1500, levelMinutes = 10, unit = "silver", lateLevels = Protocol.DEFAULT_LATE_LEVELS, antes = false }
	return Poker.db.host
end

local function Ordinal(n)
	local last, tens = n % 10, n % 100
	local suffix = (tens >= 11 and tens <= 13) and "th" or (last == 1 and "st") or (last == 2 and "nd") or (last == 3 and "rd") or "th"
	return n..suffix
end

-- What the table plays for: gold, play money that looks like gold (a practice table), or chips
local function Stakes()
	local s = Settings().stakes
	return s == "gold" and "gold" or s == "practice" and "play" or "chips"
end

-- The money a gold table's blinds are in: copper, silver or gold
local function Unit()
	local unit = Settings().unit
	return BLINDS[unit] and unit ~= "chips" and unit or "silver"
end

local function BlindsList()
	return Protocol:IsMoney(Stakes()) and BLINDS[Unit()] or BLINDS.chips
end

local function Blinds(key)
	local list = BlindsList()
	for _, b in ipairs(list) do
		if b.key == key then return b end
	end
	return Protocol:IsMoney(Stakes()) and list[1] or list[4]
end

local function Money(n)
	return Protocol:Money(n, Stakes())
end

local function Name(full)
	return Ambiguate and Ambiguate(full, "none") or (full:match("^([^%-]+)") or full)
end

-- ============================================================================
-- The form and the seat card
-- ============================================================================

-- The host form is a wizard: four steps, one choice to a row, and a plain-language review before the table opens
local STEPS = { "Game", "Players and money", "Table", "Review" }
local ROW = 34
local LABEL_X, CONTROL_X = 18, 180

function private.BuildForm(parent, width)
	local form = W:Card(parent)
	form:SetPoint("TOPLEFT")
	form:SetSize(width, CARD_HEIGHT)
	local s = Settings()
	private.stepTitle = Theme:Text(form, "tiny", "", C.faint)
	private.stepTitle:SetPoint("TOPLEFT", 14, -12)
	-- One frame per step, filling the card under the title and above the footer
	private.steps = {}
	for i = 1, #STEPS do
		local step = CreateFrame("Frame", nil, form)
		step:SetPoint("TOPLEFT", 0, -30)
		step:SetPoint("BOTTOMRIGHT", 0, 44)
		step:Hide()
		private.steps[i] = step
	end
	local function Label(step, y, text)
		local label = Theme:Text(step, "small", text, C.muted)
		label:SetPoint("TOPLEFT", LABEL_X, y - 6)
		return label
	end
	local function At(control, step, y, x)
		control:SetPoint("TOPLEFT", step, "TOPLEFT", x or CONTROL_X, y)
		return control
	end

	-- Step 1: the game
	local g = private.steps[1]
	private.kind = W:Segmented(g, { { key = "cash", label = "Cash game" }, { key = "tournament", label = "Tournament" } }, function(key)
		Settings().kind = key
		private.RefreshBuyin(true)
	end, 150)
	At(private.kind, g, -8, LABEL_X)
	private.kindNote = Theme:Text(g, "body", "", C.text)
	private.kindNote:SetPoint("TOPLEFT", LABEL_X, -48)
	private.kindNote:SetPoint("RIGHT", -18, 0)
	private.kindNote:SetWordWrap(true)
	private.kindNote:SetJustifyH("LEFT")
	private.kind:Select(s.kind or "cash", true)

	-- Step 2: who plays, and for what
	local m = private.steps[2]
	Label(m, -4, "Opponents")
	private.stakes = W:Segmented(m, { { key = "people", label = "People" }, { key = "practice", label = "Practice" } }, function(key)
		if key == "practice" then
			if Settings().stakes ~= "practice" then Settings().peopleStakes = Settings().stakes end
			Settings().stakes = "practice"
		else
			Settings().stakes = Settings().peopleStakes or "chips"
		end
		private.RefreshBuyin(true)
	end, 100)
	At(private.stakes, m, -4)
	private.opponentsNote = Theme:Text(m, "tiny", "", C.faint)
	private.opponentsNote:SetPoint("LEFT", private.stakes, "RIGHT", 12, 0)
	private.opponentsNote:SetPoint("RIGHT", -18, 0)
	private.opponentsNote:SetWordWrap(false)
	private.playForLabel = Label(m, -4 - ROW, "Play for")
	private.playFor = W:Segmented(m, { { key = "chips", label = "Chips" }, { key = "gold", label = "Gold" } }, function(key)
		Settings().stakes = key
		Settings().peopleStakes = key
		private.RefreshBuyin(true)
	end, 100)
	At(private.playFor, m, -4 - ROW)
	private.playForNote = Theme:Text(m, "tiny", "", C.faint)
	private.playForNote:SetPoint("TOPLEFT", private.playFor, "BOTTOMLEFT", 0, -3)
	private.playForNote:SetPoint("RIGHT", -18, 0)
	private.playForNote:SetWordWrap(false)
	private.unitLabel = Theme:Text(m, "small", "in", C.muted)
	private.unitLabel:SetPoint("LEFT", private.playFor, "RIGHT", 14, 0)
	local unitChoices = {}
	for _, u in ipairs(UNITS) do unitChoices[#unitChoices + 1] = { key = u.key, label = u.label } end
	private.unit = W:Choice(m, 90, unitChoices, function(key) Settings().unit = key private.RefreshBuyin(true) end)
	private.unit:SetPoint("LEFT", private.unitLabel, "RIGHT", 6, 0)
	private.unit:SetChoice(s.unit or "silver")
	-- A cash game's rows
	local NOTE = 14 -- the room the note under Play for takes
	private.blindsLabel = Label(m, -4 - ROW * 2 - NOTE, "Blinds")
	private.blinds = W:Choice(m, 120, {}, function(key) Settings().blinds = key private.RefreshBuyin(true) end)
	At(private.blinds, m, -4 - ROW * 2 - NOTE)
	private.buyinNote = Label(m, -4 - ROW * 3 - NOTE, "Buy-in from")
	private.minBox = W:Input(m, 104, "least", function() private.Guide() end)
	At(private.minBox, m, -4 - ROW * 3 - NOTE)
	private.toLabel = Theme:Text(m, "small", "to", C.muted)
	private.toLabel:SetPoint("LEFT", private.minBox, "RIGHT", 8, 0)
	private.maxBox = W:Input(m, 104, "most", function() private.Guide() end)
	private.maxBox:SetPoint("LEFT", private.toLabel, "RIGHT", 8, 0)
	private.yoursLabel = Label(m, -4 - ROW * 4 - NOTE, "Your buy-in")
	private.buyinBox = W:Input(m, 104, "yours", function() private.Guide() end)
	At(private.buyinBox, m, -4 - ROW * 4 - NOTE)
	-- A tournament's rows
	private.entryLabel = Label(m, -4 - ROW * 2 - NOTE, "Entry")
	private.entryBox = W:Input(m, 104, "e.g. 2g", function() private.Guide() end)
	At(private.entryBox, m, -4 - ROW * 2 - NOTE)
	private.stackLabel = Label(m, -4 - ROW * 3 - NOTE, "Starting stack")
	local stacks = {}
	for _, n in ipairs(Protocol.START_STACKS) do stacks[#stacks + 1] = { key = n, label = tostring(n).." chips" } end
	private.stack = W:Choice(m, 120, stacks, function(key) Settings().startStack = key private.Guide() end)
	At(private.stack, m, -4 - ROW * 3 - NOTE)
	private.stack:SetChoice(s.startStack or 1500)
	private.levelLabel = Label(m, -4 - ROW * 4 - NOTE, "Levels every")
	private.levels = W:Choice(m, 120, { { key = 3, label = "3 min" }, { key = 5, label = "5 min" }, { key = 10, label = "10 min" }, { key = 15, label = "15 min" }, { key = 20, label = "20 min" }, { key = 30, label = "30 min" } }, function(key) Settings().levelMinutes = key private.Guide() end)
	At(private.levels, m, -4 - ROW * 4 - NOTE)
	private.levels:SetChoice(s.levelMinutes or 10)
	private.lengthNote = Theme:Text(m, "tiny", "", C.faint)
	private.lengthNote:SetPoint("LEFT", private.levels, "RIGHT", 12, 0)
	private.lateLabel = Label(m, -4 - ROW * 5 - NOTE, "Late entry")
	private.late = W:Choice(m, 120, { { key = 0, label = "none" }, { key = 2, label = "to level 2" }, { key = 4, label = "to level 4" }, { key = 6, label = "to level 6" } }, function(key) Settings().lateLevels = key private.Guide() end)
	At(private.late, m, -4 - ROW * 5 - NOTE)
	private.late:SetChoice(s.lateLevels == nil and Protocol.DEFAULT_LATE_LEVELS or s.lateLevels)
	private.antes = W:Toggle(m, "Antes from level "..Protocol.ANTE_FROM_LEVEL..", a tenth of the big blind", function(on) Settings().antes = on private.Guide() end)
	private.antes:SetPoint("LEFT", private.late, "RIGHT", 16, 0)
	private.antes:SetChecked(s.antes == true)

	-- How to type money, on every money box
	for _, box in ipairs({ private.minBox, private.maxBox, private.buyinBox, private.entryBox }) do
		W:AttachTooltip(box, "Amounts", "Gold, silver and copper as 1g 50s 25c, any of the three alone (75s, 5c), or a plain number for gold (2.5 is 2g 50s). Chips tables take a number of chips.")
	end
	-- Step 3: the table
	local t = private.steps[3]
	Label(t, -4, "Table name")
	private.titleBox = W:Input(t, 240, "e.g. The Saloon", function() private.Guide() end)
	At(private.titleBox, t, -4)
	private.titleBox:SetValue(s.title or "")
	Label(t, -4 - ROW, "Seats")
	local seatChoices = {}
	for n = Protocol.MIN_SEATS, Protocol.MAX_SEATS do seatChoices[#seatChoices + 1] = { key = n, label = tostring(n) } end
	private.seats = W:Choice(t, 90, seatChoices, function(key) Settings().seats = key private.Guide() end)
	At(private.seats, t, -4 - ROW)
	private.seats:SetChoice(s.seats)
	Label(t, -4 - ROW * 2, "Time to act")
	private.turn = W:Choice(t, 90, { { key = 20, label = "20 s" }, { key = 30, label = "30 s" }, { key = 45, label = "45 s" }, { key = 60, label = "60 s" } }, function(key) Settings().turn = key private.Guide() end)
	At(private.turn, t, -4 - ROW * 2)
	private.turn:SetChoice(s.turn)
	private.passwordLabel = Label(t, -4 - ROW * 3, "Password")
	private.passwordBox = W:Input(t, 160, "none: open to everyone", function() private.Guide() end)
	At(private.passwordBox, t, -4 - ROW * 3)
	private.passwordNote = Theme:Text(t, "tiny", "With one, the table shows as locked and anyone sitting down is asked for it.", C.faint)
	private.passwordNote:SetPoint("LEFT", private.passwordBox, "RIGHT", 12, 0)

	-- Step 4: the review
	local r = private.steps[4]
	private.how = Theme:Text(r, "small", "", C.text)
	private.how:SetPoint("TOPLEFT", LABEL_X, -4)
	private.how:SetPoint("RIGHT", -18, 0)
	private.how:SetWordWrap(true)
	private.how:SetJustifyH("LEFT")
	private.how:SetSpacing(3)

	-- The footer: where you are, Back and Next, and the table at the end
	private.back = W:Button(form, "Back", "secondary", 80, 26, function() private.ShowStep(private.step - 1) end)
	private.back:SetPoint("BOTTOMLEFT", 14, 10)
	private.next = W:Button(form, "Next", "primary", 100, 26, function() private.ShowStep(private.step + 1) end)
	private.next:SetPoint("BOTTOMRIGHT", -14, 10)
	private.go = W:Button(form, "Host table", "primary", 110, 26, private.Host)
	private.go:SetPoint("BOTTOMRIGHT", -14, 10)
	local report = W:Button(form, "Report a bug", "ghost", 100, 26, function() Poker.PokerTable:ReportBug() end)
	report:SetPoint("RIGHT", private.next, "LEFT", -8, 0)
	W:AttachTooltip(report, "Report a bug", "Say what went wrong and the report goes to the developers with the table's log.")
	private.dots = Theme:Text(form, "small", "", C.muted)
	private.dots:SetPoint("LEFT", private.back, "RIGHT", 12, 0)
	private.RefreshBuyin()
	private.ShowStep(1)
	return form
end

-- Shows one step of the wizard
function private.ShowStep(n)
	n = max(1, min(#STEPS, n))
	private.step = n
	for i, step in ipairs(private.steps) do step:SetShown(i == n) end
	private.stepTitle:SetText(("HOST A TABLE  -  STEP %d OF %d: %s"):format(n, #STEPS, strupper(STEPS[n])))
	private.back:SetShown(n > 1)
	private.next:SetShown(n < #STEPS)
	private.go:SetShown(n == #STEPS)
	local dots = {}
	for i = 1, #STEPS do dots[i] = i == n and "|cffffffff"..STEPS[i].."|r" or STEPS[i] end
	private.dots:SetText(table.concat(dots, "  >  "))
	if n == #STEPS then private.Guide() end
end

---Fills the blinds list for the stakes and, when the blinds or stakes changed, a buy-in range of 20 to 100 big
---blinds for the host to change.
---@param reset boolean? the blinds or stakes changed: offer the range again
function private.RefreshBuyin(reset)
	local stakes = Stakes()
	local s = Settings()
	local practice = s.stakes == "practice"
	local tournament = s.kind == "tournament"
	local money = Protocol:IsMoney(stakes)
	local choices = {}
	for _, b in ipairs(BlindsList()) do
		choices[#choices + 1] = { key = b.key, label = Protocol:Money(b.sb, stakes).."/"..Protocol:Money(b.bb, stakes) }
	end
	local cashLine = "CASH GAME: players buy in for what they like, within your range, and leave whenever they like with what's in front of them."
	local tourneyLine = "TOURNAMENT: everyone starts with the same chips and plays until one player has them all. The blinds rise on a clock. No rebuys."
	private.kindNote:SetText(Theme:Colorize(cashLine, tournament and C.faint or C.text).."\n\n"..Theme:Colorize(tourneyLine, tournament and C.text or C.faint))
	private.stakes:Select(practice and "practice" or "people", true)
	private.opponentsNote:SetText(practice and "Computer players fill the other seats; nothing is advertised or owed." or "Anyone with Wanted on your faction can sit down.")
	private.playForLabel:SetShown(not practice)
	private.playFor:SetShown(not practice)
	if not practice then private.playFor:Select(s.stakes == "gold" and "gold" or "chips", true) end
	private.playForNote:SetShown(not practice)
	private.playForNote:SetText(s.stakes == "gold" and "Real gold. Each buy-in goes to the host up front; your stack comes back from them when you leave."
		or "A friendly game for no stakes. Nothing is sent, nothing is owed.")
	private.unitLabel:SetShown(money)
	private.unit:SetShown(money)
	private.unitLabel:ClearAllPoints()
	if practice then private.unitLabel:SetPoint("TOPLEFT", private.steps[2], "TOPLEFT", LABEL_X, -4 - ROW - 6) private.unitLabel:SetText("Money") else private.unitLabel:SetPoint("LEFT", private.playFor, "RIGHT", 14, 0) private.unitLabel:SetText("in") end
	private.unit:ClearAllPoints()
	if practice then private.unit:SetPoint("TOPLEFT", private.steps[2], "TOPLEFT", CONTROL_X, -4 - ROW) else private.unit:SetPoint("LEFT", private.unitLabel, "RIGHT", 6, 0) end
	private.unit:SetChoice(Unit())
	private.blinds:SetChoices(choices)
	local b = Blinds(s.blinds)
	s.blinds = b.key
	private.blinds:SetChoice(b.key)
	local low, high = b.bb * BUYIN_MIN_BB, b.bb * BUYIN_MAX_BB
	if reset or private.minBox:GetText() == "" then
		private.minBox:SetValue(Money(low))
		private.maxBox:SetValue(Money(high))
		private.buyinBox:SetValue(Money(high))
	end
	for _, f in ipairs({ private.blindsLabel, private.blinds, private.buyinNote, private.minBox, private.toLabel, private.maxBox, private.yoursLabel, private.buyinBox }) do f:SetShown(not tournament) end
	for _, f in ipairs({ private.stackLabel, private.stack, private.levelLabel, private.levels, private.lateLabel, private.late, private.antes, private.lengthNote }) do f:SetShown(tournament) end
	-- A chips tournament has no entry; the blinds come from the schedule
	local entry = tournament and money
	private.entryLabel:SetShown(entry)
	private.entryBox:SetShown(entry)
	private.passwordLabel:SetShown(not practice)
	private.passwordBox:SetShown(not practice)
	private.passwordNote:SetShown(not practice)
	for _, box in ipairs({ private.minBox, private.maxBox, private.buyinBox, private.entryBox }) do
		box.placeholder:SetText(money and "1|TInterface\\MoneyFrame\\UI-GoldIcon:12|t 50|TInterface\\MoneyFrame\\UI-SilverIcon:12|t 25|TInterface\\MoneyFrame\\UI-CopperIcon:12|t" or "chips")
	end
	private.Guide()
end

-- The guide under the form: the table being set up, step by step, in the choices made so far, and how its money works
function private.Guide()
	if not private.how then return end
	local s = Settings()
	local stakes = Stakes()
	local money = Protocol:IsMoney(stakes)
	local b = Blinds(s.blinds)
	local tournament = s.kind == "tournament"
	local practice = s.stakes == "practice"
	local function M(n) return Protocol:Money(n or 0, stakes) end
	local lines = {}
	local length = Protocol:AboutMinutes(Protocol:TournamentMinutes(s.startStack or 1500, s.seats or 6, s.levelMinutes or 10, s.antes))
	if private.lengthNote then private.lengthNote:SetText(("%s with %d players"):format(length, s.seats or 6)) end
	local what = stakes == "gold" and "gold" or practice and "play money that looks like gold" or "chips"
	if tournament then
		local entry = money and Protocol:ParseAmount(private.entryBox:GetText(), stakes) or 0
		lines[#lines + 1] = ("1.  A TOURNAMENT for %s. Everyone starts with %d chips; the blinds start at 10/20 and rise every %d minutes until one player has them all. No rebuys.%s%s"):format(
			what, s.startStack or 1500, s.levelMinutes or 10, (s.lateLevels or 0) > 0 and (" Late entry stays open to level %d."):format(s.lateLevels) or " Nobody enters after the start.",
			s.antes and (" Antes from level %d."):format(Protocol.ANTE_FROM_LEVEL) or "")..(" Expect %s with %d players."):format(length, s.seats or 6)
		if stakes == "gold" then
			lines[#lines + 1] = ("2.  ENTRY %s each, paid to you before they're dealt in, by a trade or by mail. You hold the pool. The prizes are the entries: winner takes all up to four entered, 65/35 from five, 50/30/20 from seven."):format(entry and entry > 0 and M(entry) or "(type one)")
			lines[#lines + 1] = "3.  PAYING OUT: when it ends, each prize is a line under Settlement from you to the player, paid by trade or with Pay at a mailbox. You hold the money, so the table stays with you until it ends: bust early and you can close the window and play on while it runs."
		else
			lines[#lines + 1] = practice and "2.  FREE ENTRY against computer players; the prizes are play money." or "2.  FREE ENTRY; the chips are play money and nothing is owed."
		end
	else
		local lo, hi, yours = Protocol:ParseAmount(private.minBox:GetText(), stakes), Protocol:ParseAmount(private.maxBox:GetText(), stakes), Protocol:ParseAmount(private.buyinBox:GetText(), stakes)
		lines[#lines + 1] = ("1.  A CASH GAME for %s, blinds %s/%s. Players buy in for %s to %s and leave whenever they like with what's in front of them. You sit with %s."):format(
			what, M(b.sb), M(b.bb), lo and M(lo) or "?", hi and M(hi) or "?", yours and M(yours) or "?")
		if stakes == "gold" then
			lines[#lines + 1] = "2.  CASH ON THE TABLE: each buy-in (and rebuy) goes to you first, by a trade in person or by mail, and the seat is dealt in once it has. You hold the money; nobody can run up a debt."
			lines[#lines + 1] = "3.  PAYING OUT: when a player leaves you owe them their stack, a line under Settlement, paid by trade or with Pay at a mailbox. The table stays with you while it's open; Close table settles everyone from one set of books."
		elseif practice then
			lines[#lines + 1] = "2.  PLAY MONEY: the other seats are computer players who buy in for the most. It looks and counts like gold, nothing is owed, and nothing is advertised."
		else
			lines[#lines + 1] = "2.  CHIPS: a friendly game for no stakes. Nothing is sent and nothing is owed."
		end
	end
	local password = strtrim(private.passwordBox:GetText() or "")
	lines[#lines + 1] = ("%d.  SEATS %d, %ds a turn. %s"):format(#lines, s.seats or 6, s.turn or 30,
		practice and ("You and %d computer players."):format((s.seats or 6) - 1) or (password ~= "" and "Password set: the table shows as locked and anyone sitting down is asked for it." or "Everyone with Wanted on your faction sees it in Open tables; a password keeps it to friends."))
	lines[#lines + 1] = ("%d.  THE DEAL: before each hand every client makes a secret and the deck is shuffled from all of them, so nobody, you included, can choose it; every client checks the hand afterwards. Your client deals, so play for gold only with people you'd deal cards to."):format(#lines)
	private.how:SetText(table.concat(lines, "\n"))
end

function private.Host()
	local s = Settings()
	local b = Blinds(s.blinds)
	local stakes = Stakes()
	s.title = strtrim(private.titleBox:GetText() or "")
	local password = strtrim(private.passwordBox:GetText() or "")
	if #password > 20 or strfind(password, "[|%c]") then
		UI:Toast("A password is up to 20 characters.", C.red)
		return
	end
	local cfg, buyin
	if s.kind == "tournament" then
		local entry = Protocol:IsMoney(stakes) and Protocol:ParseAmount(private.entryBox:GetText(), stakes) or 0
		if not entry then
			UI:Toast("The entry is an amount, like 2g or 50s.", C.red)
			return
		end
		cfg = { kind = "tournament", entry = entry, startStack = s.startStack, levelMinutes = s.levelMinutes, maxSeats = s.seats, turnSeconds = s.turn, stakes = stakes,
			title = s.title ~= "" and s.title or nil, bots = s.stakes == "practice" and (s.seats - 1) or 0, lateLevels = s.lateLevels, antes = s.antes == true }
		buyin = entry
	else
		local buyMin, buyMax = Protocol:ParseAmount(private.minBox:GetText(), stakes), Protocol:ParseAmount(private.maxBox:GetText(), stakes)
		buyin = Protocol:ParseAmount(private.buyinBox:GetText(), stakes)
		if not buyMin or not buyMax or buyMin < b.bb or buyMax < buyMin then
			UI:Toast(("The buy-in range is two amounts, the least at least a big blind (%s)."):format(Money(b.bb)), C.red)
			return
		end
		cfg = { sb = b.sb, bb = b.bb, buyMin = buyMin, buyMax = buyMax, maxSeats = s.seats, turnSeconds = s.turn, stakes = stakes,
			title = s.title ~= "" and s.title or nil, bots = s.stakes == "practice" and (s.seats - 1) or 0 }
		if not buyin or buyin < cfg.buyMin or buyin > cfg.buyMax then
			UI:Toast(("Your buy-in is %s to %s."):format(Money(cfg.buyMin), Money(cfg.buyMax)), C.red)
			return
		end
	end
	if cfg.stakes == "gold" and buyin > 0 then
		local ok, why = Gold:CanBuyIn(buyin)
		if not ok then
			UI:Toast("You can't host for that: "..why..".", C.red)
			return
		end
	end
	local ok, why = Net:HostTable(cfg, buyin, password ~= "" and password or nil)
	if not ok then
		UI:Toast(why or "Couldn't open a table.", C.red)
		return
	end
	TableUI:Reset()
	TableUI:Show()
	private.Refresh()
end

function private.BuildSeatCard(parent, width)
	local card = W:Card(parent)
	card:SetPoint("TOPLEFT")
	card:SetSize(width, 96)
	local label = Theme:Text(card, "tiny", "YOUR TABLE", C.faint)
	label:SetPoint("TOPLEFT", 14, -12)
	private.seatTitle = Theme:Text(card, "heading", "")
	private.seatTitle:SetPoint("TOPLEFT", 14, -30)
	private.seatSub = Theme:Text(card, "small", "", C.muted)
	private.seatSub:SetPoint("TOPLEFT", 14, -52)
	private.seatSub:SetWidth(width - 420)
	local open = W:Button(card, "Open table", "primary", 110, 26, function() TableUI:Show() end)
	open:SetPoint("BOTTOMRIGHT", -14, 12)
	private.payButton = W:Button(card, "Pay by mail", "secondary", 110, 26, function()
		local ok, why = Gold:PrefillBuyIn()
		UI:Toast(ok and "Mail to the host filled in: check it and press Send. Trading it to them in person is quicker." or ("Can't fill the mail in: "..tostring(why).."."), ok and C.green or C.red)
	end)
	private.payButton:SetPoint("BOTTOMLEFT", 14, 12)
	private.payButton:Hide()
	private.startButton = W:Button(card, "Start", "primary", 150, 26, function()
		local ok, why = Net:StartTournament()
		if not ok then UI:Toast(why or "Couldn't start.", C.red) end
		private.Refresh()
	end)
	private.startButton:SetPoint("RIGHT", open, "LEFT", -6, 0)
	private.startButton:Hide()
	private.leaveButton = W:Button(card, "Leave", "danger", 90, 26, function()
		local hosting = Net:HostedTable() ~= nil
		W:Dialog({
			title = hosting and "Close the table?" or "Leave the table?",
			text = hosting and ((Net:State() and Net:State().cfg.stakes == "gold") and "The table closes and you owe every player their stack: the lines go under Settlement, to pay by trade or by mail." or "Everyone at your table is sent their final stacks and the table closes.")
				or "Your chips leave with you. A hand under way is folded.",
			confirmLabel = hosting and "Close table" or "Leave",
			confirmStyle = "danger",
			onConfirm = function()
				Net:Leave()
				TableUI:Hide()
				private.Refresh()
			end,
		})
	end)
	private.leaveButton:SetPoint("RIGHT", private.startButton, "LEFT", -6, 0)
	private.handoffButton = W:Button(card, "Hand off", "secondary", 90, 26, private.Handoff)
	private.handoffButton:SetPoint("RIGHT", private.leaveButton, "LEFT", -6, 0)
	private.handoffButton:Hide()
	W:AttachTooltip(private.handoffButton, "Hand off the table", "The next seat hosts from here and you keep your chair, so you can leave without ending the game. Chips tables only: a gold table stays with the host who holds the money.")
	return card
end

-- ============================================================================
-- The list of open tables
-- ============================================================================

function private.CreateRow(row)
	row.title = Theme:Text(row, "body", "")
	row.title:SetPoint("TOPLEFT", 14, -8)
	row.title:SetWidth(420)
	row.sub = Theme:Text(row, "tiny", "")
	row.sub:SetPoint("TOPLEFT", 14, -26)
	row.sub:SetWidth(460)
	row.action = Theme:Text(row, "small", "")
	row.action:SetPoint("RIGHT", -14, 0)
	row.action:SetJustifyH("RIGHT")
	row.pay = W:Button(row, "Pay", "primary", 70, 22, function() private.Pay(row.item) end)
	row.pay:SetPoint("RIGHT", -14, 0)
	row.mark = W:Button(row, "Mark paid", "chip", 84, 22, function() private.MarkPaid(row.item) end)
	row.mark:SetPoint("RIGHT", -14, 0)
end

function private.UpdateRow(row, item)
	if private.view == "settlement" then
		return private.UpdateLine(row, item)
	end
	row.pay:Hide()
	row.mark:Hide()
	local ad = item
	local title = ad.n and ad.n ~= "" and ad.n or (Name(ad.h).."'s table")
	row.title:SetText(title..Theme:Colorize("  "..Name(ad.h), C.muted).."  "..Wanted.Reputation:GetPosterBadge(ad.h))
	local stakes = ad.g and "gold" or "chips"
	local lock = ad.p and Theme:Colorize("  -  password", C.amber) or ""
	if ad.k == "t" then
		local standing = ad.on and (ad.la and ("  -  under way, level %d, late entry open"):format(ad.lv or 1) or "  -  under way") or ((ad.ll or 0) > 0 and ("  -  late entry to level %d"):format(ad.ll) or "")
		row.sub:SetText(("Tournament  -  %s  -  %d of %d registered  -  stacks of %d, levels every %d min%s%s%s"):format(
			ad.g and ("entry "..Protocol:Money(ad.e, stakes)) or "free entry", ad.s or 0, ad.m or 0, ad.ss or 0, ad.lm or 0, ad.an and ", antes" or "", standing, lock))
	else
		row.sub:SetText(("blinds %s/%s  -  %d of %d seats  -  buy-in %s to %s%s%s"):format(Protocol:Money(ad.sb, stakes), Protocol:Money(ad.bb, stakes), ad.s or 0, ad.m or 0,
			Protocol:Money(ad.lo, stakes), Protocol:Money(ad.hi, stakes), ad.g and "  -  gold, settled by mail" or "", lock))
	end
	local st = Net:State()
	if st and st.t == ad.id then
		row.action:SetText(Theme:Colorize("Seated", C.green))
	elseif ad.k == "t" and ad.on and not ad.la then
		row.action:SetText(Theme:Colorize("Under way", C.muted))
	elseif (ad.s or 0) >= (ad.m or 0) then
		row.action:SetText(Theme:Colorize("Full", C.muted))
	else
		row.action:SetText(Theme:Colorize(ad.k == "t" and "Click to enter" or "Click to sit", C.gold))
	end
end

-- A settlement line: a debt you owe or are owed, paid or not, or a receipt (a buy-in paid, money received)
local KIND_WORDS = { cashout = "cash-out", prize = "prize", refund = "refund", buyin = "buy-in", received = "not asked for", pool = "the table's pool" }
function private.UpdateLine(row, line)
	local me = Net:Me()
	local mine = strlower((gsub(line.from, "%-.*$", ""))) == strlower((gsub(me, "%-.*$", "")))
	local other = Name(mine and line.to or line.from)
	local amount = Protocol:Money(line.amount, "gold")
	local kind = KIND_WORDS[line.kind or "cashout"] or line.kind
	local debt = Gold:IsDebt(line)
	if not debt then
		row.title:SetText(mine and ("Paid %s %s"):format(other, amount) or ("Received %s from %s"):format(amount, other))
	elseif line.paid then
		row.title:SetText(mine and ("Paid %s %s"):format(other, amount) or ("%s paid you %s"):format(other, amount))
	else
		row.title:SetText(mine and ("You owe %s %s"):format(other, amount) or ("%s owes you %s"):format(other, amount))
	end
	local how = line.paidHow and (", by "..(line.paidHow == "hand" and "your word" or line.paidHow)) or ""
	local note = line.claim and "  -  the host dropped; your client reminds them" or ""
	row.sub:SetText((line.title and line.title ~= "" and line.title or "Poker")..Theme:Colorize("  -  "..kind..how.."  -  "..Theme:Ago(time() - (line.at or time())).." ago"..note, C.faint))
	row.pay:SetShown(debt and mine and not line.paid)
	row.mark:SetShown(debt and not mine and not line.paid and not line.claim)
	row.action:SetText(line.paid and Theme:Colorize("Paid", C.green) or "")
	if Gold:IsOverdue(line) then
		row.sub:SetText(row.sub:GetText()..Theme:Colorize("  -  OVERDUE", C.red))
	end
end

function private.Pay(line)
	if not line or private.view ~= "settlement" then return end
	local ok, why = Gold:Prefill(line)
	UI:Toast(ok and ("Mail to %s filled in: check it and press Send."):format(Name(line.to)) or ("Can't fill the mail in: "..tostring(why).."."), ok and C.green or C.red)
end

function private.MarkPaid(line)
	if not line or private.view ~= "settlement" then return end
	W:Dialog({
		title = "Mark as paid?",
		text = ("Only if %s has paid you the %s some other way (a trade, a mail your client missed). It counts for their reputation as paid."):format(Name(line.from), Protocol:Money(line.amount, "gold")),
		confirmLabel = "Mark paid",
		onConfirm = function()
			Gold:MarkPaid(line.id, "hand")
			private.Refresh()
		end,
	})
end

function private.Sit(ad)
	if private.view == "settlement" then return end
	local st = Net:State()
	if st and st.phase ~= "closed" and st.open ~= false then
		UI:Toast("You're at a table already. Leave it first.", C.red)
		return
	end
	if (ad.s or 0) >= (ad.m or 0) then
		UI:Toast("That table is full.", C.red)
		return
	end
	if ad.k == "t" and ad.on and not ad.la then
		UI:Toast("That tournament is under way and late entry has closed.", C.red)
		return
	end
	local stakes = ad.g and "gold" or "chips"
	local function M(n) return Protocol:Money(n or 0, stakes) end
	local title = ad.n and ad.n ~= "" and ad.n or (Name(ad.h).."'s table")
	-- The host's record of paying what they owe, for the player to weigh before buying in
	local trustLabel = Wanted.Reputation:GetPosterTrust(Wanted.Reputation:GetTally(ad.h))
	local hostTrust = ad.g and (" %s's record of paying what they owe: %s."):format(Name(ad.h), trustLabel or "none yet") or ""
	local function Go(amount, password)
		local ok, why = Net:JoinTable(ad.id, amount, password)
		if not ok then
			UI:Toast(why or "Couldn't sit down.", C.red)
			return
		end
		TableUI:Reset()
		TableUI:Show()
		private.Refresh()
	end
	local function AskPassword(then_)
		W:Dialog({
			title = "Password for "..title,
			text = "The host set a password for this table.",
			input = { placeholder = "Password" },
			confirmLabel = "Continue",
			validate = function(value) if strtrim(value or "") == "" then return "Type the password." end end,
			onConfirm = function(value) then_(strtrim(value)) end,
		})
	end
	if ad.k == "t" then
		local entry = ad.e or 0
		local function Enter(password)
			if ad.g and entry > 0 then
				local ok, why = Gold:CanBuyIn(entry)
				if not ok then UI:Toast("You can't enter: "..why..".", C.red) return end
			end
			W:Dialog({
				title = "Enter "..title,
				text = (ad.g and ("Tournament, entry %s. "):format(M(entry)) or "Tournament, free to enter. ")..(ad.on and ("Under way at level %d: you enter late with the starting stack. "):format(ad.lv or 1) or "")..("Everyone starts with %d chips; the blinds rise every %d minutes until one player has them all. No rebuys.%s"):format(
					ad.ss or 0, ad.lm or 0, ad.g and (" Your entry goes to %s first, by trade or by mail; the prizes are the entries, split by place, and come back from them the same way.%s"):format(Name(ad.h), hostTrust) or ""),
				confirmLabel = "Enter",
				onConfirm = function() Go(entry, password) end,
			})
		end
		if ad.p then AskPassword(Enter) else Enter(nil) end
		return
	end
	local function BuyIn(password)
	W:Dialog({
		title = "Sit at "..(ad.n and ad.n ~= "" and ad.n or (Name(ad.h).."'s table")),
		text = ad.g and ("Blinds %s/%s, for gold. Buy in for %s to %s. Cash on the table: your buy-in goes to %s first, by trade or by mail, and your stack comes back from them when you leave.%s"):format(M(ad.sb), M(ad.bb), M(ad.lo), M(ad.hi), Name(ad.h), hostTrust)
			or ("Blinds %s/%s. Buy in for %s to %s chips. Your client checks every deal; chips are play money."):format(M(ad.sb), M(ad.bb), M(ad.lo), M(ad.hi)),
		input = { placeholder = ad.g and "e.g. 2g 50s" or "Buy-in", value = M(ad.hi) },
		confirmLabel = "Sit down",
		validate = function(value)
			local n = Protocol:ParseAmount(value, stakes)
			if not n or n < (ad.lo or 0) or n > (ad.hi or 0) then return ("From %s to %s."):format(M(ad.lo), M(ad.hi)) end
			if ad.g then
				local ok, why = Gold:CanBuyIn(n)
				if not ok then return "You can't buy in for that: "..why.."." end
			end
		end,
		onConfirm = function(value)
			Go(Protocol:ParseAmount(value, stakes), password)
		end,
	})
	end
	if ad.p then AskPassword(BuyIn) else BuyIn(nil) end
end

-- ============================================================================
-- The page
-- ============================================================================

-- The host hands the table to the next seat (chips tables)
function private.Handoff()
	local st = Net:State()
	local host = Net:HostedTable()
	if not st or not host then return end
	local seat = host:Successor()
	local next_ = seat and host.seats[seat] and Name(host.seats[seat].name) or "?"
	W:Dialog({
		title = "Hand the table to "..next_.."?",
		text = ("%s hosts from the next hand and you keep your seat. Leave whenever you like after that."):format(next_),
		confirmLabel = "Hand off",
		onConfirm = function()
			local ok, why = Net:Handoff()
			if not ok then UI:Toast(why or "Couldn't hand the table off.", C.red) end
			private.Refresh()
		end,
	})
end

function private.Refresh()
	if not private.list then return end
	local st = Net:State()
	local seated = st ~= nil and st.phase ~= "closed"
	private.form:SetShown(not seated)
	private.seat:SetShown(seated)
	private.views:ClearAllPoints()
	private.views:SetPoint("TOPLEFT", seated and private.seat or private.form, "BOTTOMLEFT", 0, -8)
	private.list:ClearAllPoints()
	private.list:SetPoint("TOPLEFT", private.views, "BOTTOMLEFT", 0, -6)
	private.list:SetPoint("TOPRIGHT", seated and private.seat or private.form, "BOTTOMRIGHT", 0, -48)
	if seated then
		local n = 0
		for _ in pairs(st.seats) do n = n + 1 end
		private.seatTitle:SetText(st.cfg.title and st.cfg.title ~= "" and st.cfg.title or (Name(st.host).."'s table"))
		local hosting = Net:HostedTable() ~= nil
		if st.cfg.kind == "tournament" then
			local standing = st.phase == "finished" and "finished" or (st.started and ("level %d, %s/%s"):format(st.level or 1, st.levelBlinds and st.levelBlinds[1] or "?", st.levelBlinds and st.levelBlinds[2] or "?") or "registering")
			private.seatSub:SetText(("Tournament, %s  -  %d of %d  -  host %s%s"):format(standing, n, st.cfg.maxSeats, Name(st.host), hosting and " (you)" or ""))
			private.startButton:SetShown(hosting and not st.started and st.phase ~= "closed")
			private.startButton:SetText(("Start (%d entered)"):format(n))
			private.startButton:SetEnabled(n >= Protocol.MIN_SEATS)
		else
			private.seatSub:SetText(("blinds %s/%s  -  %d of %d seated  -  host %s%s"):format(Protocol:Money(st.cfg.sb, st.cfg.stakes), Protocol:Money(st.cfg.bb, st.cfg.stakes), n, st.cfg.maxSeats, Name(st.host), hosting and " (you)" or ""))
			private.startButton:Hide()
		end
		private.leaveButton:SetText(hosting and "Close table" or "Leave")
		local canHand = hosting and st.cfg.bots == 0 and st.cfg.stakes ~= "gold" and n >= 2 and st.phase ~= "closed" and st.phase ~= "finished"
		private.handoffButton:SetShown(canHand)
		if hosting and st.handingTo then
			private.seatSub:SetText(private.seatSub:GetText()..Theme:Colorize(("  -  handing the table to %s"):format(Name(st.handingTo)), C.amber))
		end
		local mine = st.me and st.seats[st.me]
		local due
		if mine and st.cfg.stakes == "gold" then due = (mine.unpaid and mine.unpaid - (mine.received or 0)) or mine.rebuyDue end
		private.payButton:SetShown(due ~= nil and due > 0 and st.phase ~= "closed")
		if due and due > 0 then
			private.seatSub:SetText(private.seatSub:GetText()..Theme:Colorize(("  -  pay %s your %s of %s: trade it, or Pay by mail"):format(Name(st.host), mine.unpaid and "buy-in" or "rebuy", Protocol:Money(due, "gold")), C.amber))
		elseif hosting and st.cfg.stakes == "gold" then
			local waiting = {}
			for _, p in pairs(st.seats) do if p.unpaid then waiting[#waiting + 1] = Name(p.n) end end
			private.seatSub:SetText(private.seatSub:GetText()..Theme:Colorize(("  -  holding %s"):format(Protocol:Money(st.holding or 0, "gold")), C.gold)
				..(#waiting > 0 and Theme:Colorize("  -  waiting on "..table.concat(waiting, ", ").." to pay", C.amber) or ""))
		end
	end
	local lines = Gold:Lines()
	local open = 0
	for _, l in ipairs(lines) do if not l.paid then open = open + 1 end end
	for _, button in ipairs(private.views.buttons) do
		if button.key == "settlement" then button:SetText(open > 0 and ("Settlement ("..open..")") or "Settlement") end
	end
	if private.view == "settlement" then
		private.list:SetItems(lines, "Nothing to settle.", "Gold tables settle with the host when you leave; the lines show here.")
	else
		private.list:SetItems(Net:Tables(), "No open tables right now.", "Host one above: every Wanted player of your faction sees it.")
	end
end

---Shows a step of the host wizard (1 to 4).
---@param n number
function Page:GoToStep(n)
	if private.steps then private.ShowStep(n) end
end

---Redraws the page (the ledger changed).
function Page:Refresh()
	private.Refresh()
end

function Page:OnEnable()
	Net:On(function(event, ...)
		if event == "tables" then
			private.Refresh()
		elseif event == "state" then
			local st = ...
			TableUI:Refresh(st)
			if st and st.me and not TableUI:IsShown() and not private.shownOnce then
				private.shownOnce = true
				TableUI:Show()
			end
			private.Refresh()
		elseif event == "said" then
			TableUI:OnSaid(...)
		elseif event == "audit" then
			local key, ok, reason = ...
			TableUI:OnAudit(key, ok, reason)
		elseif event == "refused" then
			local why = ...
			UI:Toast("Poker: "..tostring(why), C.red)
			private.shownOnce = nil
			private.Refresh()
		elseif event == "settle" then
			TableUI:OnSettle(...)
			private.Refresh()
		elseif event == "hostGone" or event == "newHost" then
			TableUI:OnHost(event, ...)
		elseif event == "blocked" then
			TableUI:OnBlocked(...)
		elseif event == "hosting" then
			private.Refresh()
		elseif event == "host" then
			local what, name = ...
			if what == "handing" then
				TableUI:Log("Handing the table to "..Name(name).."...", C.amber)
			elseif what == "handed" then
				TableUI:Log(Name(name).." hosts the table now. You keep your seat.", C.amber)
				private.Refresh()
			elseif what == "handoffFailed" then
				TableUI:Log(Name(name).." didn't take the table; it stays with you.", C.amber)
				UI:Toast(Name(name).." didn't take the table; it stays with you.", C.amber)
				private.Refresh()
			elseif what == "eliminated" and name == Net:Me() and Net:HostedTable() and Net:HostedTable().cfg.bots == 0 then
				UI:Toast(Net:HostedTable().cfg.stakes == "gold" and "You're out. The table runs on your client until it ends: close the window and play on, or Close table to settle everyone." or "You're out. Hand off the table from the Poker page if you want to leave before it ends.", C.amber)
			end
		elseif event == "left" then
			private.shownOnce = nil
			private.Refresh()
		end
	end)
	Wanted:RegisterCommand("poker", "Opens the Poker page: host a table or sit at one. 'poker probe' checks tables work where you stand.", function(args)
		if strtrim(args or "") == "probe" then
			Net:Probe()
		else
			UI:Show("poker")
		end
	end)
end

UI:RegisterPage("poker", {
	group = "World PvP",
	title = "Poker",
	subtitle = "Texas hold'em at the Wanted table: a deal no player can rig, checked by every seat after each hand.",
	order = 3.2,
	badge = function()
		local n = #Net:Tables()
		return n > 0 and n or nil, C.blue
	end,
	build = function(container, width, height)
		private.form = private.BuildForm(container, width)
		private.seat = private.BuildSeatCard(container, width)
		private.views = W:Segmented(container, { { key = "tables", label = "Open tables" }, { key = "settlement", label = "Settlement" } }, function(key)
			private.view = key
			if key == "settlement" then Gold:AskForLines() end
			private.Refresh()
		end, 130)
		private.views:Select("tables", true)
		local listTop = CARD_HEIGHT + 12 + 34
		local list = W:List(container, ROW_HEIGHT, floor((height - listTop) / ROW_HEIGHT), private.CreateRow, private.UpdateRow)
		list.onClick = private.Sit
		private.list = list
		private.Refresh()
	end,
	refresh = private.Refresh,
})
