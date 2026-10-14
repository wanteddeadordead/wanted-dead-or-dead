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
local CARD_HEIGHT = 244 -- the form with how it works under it
-- Blinds to pick from: chips, and at a gold table silver pieces (5s/10s up to 5g/10g)
local BLINDS = {
	chips = { { key = "1/2", sb = 1, bb = 2 }, { key = "5/10", sb = 5, bb = 10 }, { key = "10/20", sb = 10, bb = 20 }, { key = "25/50", sb = 25, bb = 50 }, { key = "50/100", sb = 50, bb = 100 }, { key = "100/200", sb = 100, bb = 200 } },
	gold = { { key = "5/10", sb = 5, bb = 10 }, { key = "10/20", sb = 10, bb = 20 }, { key = "25/50", sb = 25, bb = 50 }, { key = "50/100", sb = 50, bb = 100 }, { key = "100/200", sb = 100, bb = 200 }, { key = "500/1000", sb = 500, bb = 1000 } },
}
local BUYIN_MIN_BB, BUYIN_MAX_BB = 20, 100 -- the buy-in range offered when the blinds are picked; the host sets their own
local HOW_IT_WORKS = table.concat({
	"HOW IT WORKS",
	"1.  Host a table, or sit at one below. Everyone with Wanted on your faction sees open tables.",
	"2.  Before each hand every player's client makes a secret; the deck is shuffled from all of them together, so nobody, the host included, can choose it.",
	"3.  After each hand your client checks the host's account of it. A hand that doesn't check out is marked in red at the table.",
	"4.  The host's client deals, so a host who edited the addon could see cards. Play for stakes only with people you'd deal cards with.",
	"5.  Gold tables: the host is the bank. When you leave, what you won or lost against your buy-in is a line under Settlement, paid by mail at a mailbox (Pay fills it in, you press Send). A debt left two days counts against your reputation with everyone who was at the table.",
	"6.  Closing the table window keeps your seat; leave from the table or from here.",
	"7.  Practice: pick Practice instead of Chips or Gold and the other seats are taken by computer players. Nothing is advertised and nothing is owed.",
}, "\n")

local function Settings()
	Poker.db.host = Poker.db.host or { blinds = "10/20", seats = 6, turn = 30, title = "", stakes = "chips", kind = "cash", startStack = 1500, levelMinutes = 10 }
	return Poker.db.host
end

local function Ordinal(n)
	local last, tens = n % 10, n % 100
	local suffix = (tens >= 11 and tens <= 13) and "th" or (last == 1 and "st") or (last == 2 and "nd") or (last == 3 and "rd") or "th"
	return n..suffix
end

local function Stakes()
	return Settings().stakes == "gold" and "gold" or "chips"
end

local function Blinds(key)
	local list = BLINDS[Stakes()]
	for _, b in ipairs(list) do
		if b.key == key then return b end
	end
	return list[3]
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

function private.BuildForm(parent, width)
	local form = W:Card(parent)
	form:SetPoint("TOPLEFT")
	form:SetSize(width, CARD_HEIGHT)
	local label = Theme:Text(form, "tiny", "HOST A TABLE", C.faint)
	label:SetPoint("TOPLEFT", 14, -12)
	local s = Settings()
	private.titleBox = W:Input(form, 220, "Table name, e.g. The Saloon")
	private.titleBox:SetPoint("TOPLEFT", 14, -30)
	private.titleBox:SetValue(s.title or "")
	local blindsLabel = Theme:Text(form, "small", "Blinds", C.muted)
	blindsLabel:SetPoint("LEFT", private.titleBox, "RIGHT", 14, 0)
	private.blinds = W:Choice(form, 104, {}, function(key) Settings().blinds = key private.RefreshBuyin(true) end)
	private.blinds:SetPoint("LEFT", blindsLabel, "RIGHT", 6, 0)
	local seatsLabel = Theme:Text(form, "small", "Seats", C.muted)
	seatsLabel:SetPoint("LEFT", private.blinds, "RIGHT", 14, 0)
	local seatChoices = {}
	for n = Protocol.MIN_SEATS, Protocol.MAX_SEATS do seatChoices[#seatChoices + 1] = { key = n, label = tostring(n) } end
	private.seats = W:Choice(form, 56, seatChoices, function(key) Settings().seats = key end)
	private.seats:SetPoint("LEFT", seatsLabel, "RIGHT", 6, 0)
	private.seats:SetChoice(s.seats)
	local turnLabel = Theme:Text(form, "small", "Turn", C.muted)
	turnLabel:SetPoint("LEFT", private.seats, "RIGHT", 14, 0)
	private.turn = W:Choice(form, 64, { { key = 20, label = "20s" }, { key = 30, label = "30s" }, { key = 45, label = "45s" }, { key = 60, label = "60s" } }, function(key) Settings().turn = key end)
	private.turn:SetPoint("LEFT", turnLabel, "RIGHT", 6, 0)
	private.turn:SetChoice(s.turn)
	private.passwordBox = W:Input(form, 96, "Password")
	private.passwordBox:SetPoint("LEFT", private.turn, "RIGHT", 14, 0)
	W:AttachTooltip(private.passwordBox, "Password", "Leave it empty for an open table. With one, the table shows as locked and anyone sitting down is asked for it.")
	private.kind = W:Segmented(form, { { key = "cash", label = "Cash game" }, { key = "tournament", label = "Tournament" } }, function(key)
		Settings().kind = key
		private.RefreshBuyin(true)
	end, 92)
	private.kind:SetPoint("TOPLEFT", 14, -66)
	private.kind:Select(s.kind or "cash", true)
	private.stakes = W:Segmented(form, { { key = "chips", label = "Chips" }, { key = "gold", label = "Gold" }, { key = "practice", label = "Practice" } }, function(key)
		Settings().stakes = key
		private.RefreshBuyin(true)
	end, 70)
	private.stakes:SetPoint("LEFT", private.kind, "RIGHT", 12, 0)
	private.stakes:Select(s.stakes or "chips", true)
	-- A tournament: the entry, the starting stack and how long a level lasts
	private.entryLabel = Theme:Text(form, "small", "Entry", C.muted)
	private.entryLabel:SetPoint("LEFT", private.stakes, "RIGHT", 14, 0)
	private.entryBox = W:Input(form, 76, "e.g. 2g")
	private.entryBox:SetPoint("LEFT", private.entryLabel, "RIGHT", 6, 0)
	private.stackLabel = Theme:Text(form, "small", "Stack", C.muted)
	private.stackLabel:SetPoint("LEFT", private.entryBox, "RIGHT", 12, 0)
	local stacks = {}
	for _, n in ipairs(Protocol.START_STACKS) do stacks[#stacks + 1] = { key = n, label = tostring(n) } end
	private.stack = W:Choice(form, 70, stacks, function(key) Settings().startStack = key end)
	private.stack:SetPoint("LEFT", private.stackLabel, "RIGHT", 6, 0)
	private.stack:SetChoice(s.startStack or 1500)
	private.levelLabel = Theme:Text(form, "small", "Levels", C.muted)
	private.levelLabel:SetPoint("LEFT", private.stack, "RIGHT", 12, 0)
	private.levels = W:Choice(form, 76, { { key = 5, label = "5 min" }, { key = 10, label = "10 min" }, { key = 15, label = "15 min" }, { key = 20, label = "20 min" } }, function(key) Settings().levelMinutes = key end)
	private.levels:SetPoint("LEFT", private.levelLabel, "RIGHT", 6, 0)
	private.levels:SetChoice(s.levelMinutes or 10)
	private.buyinNote = Theme:Text(form, "small", "Buy-in from", C.muted)
	private.buyinNote:SetPoint("LEFT", private.stakes, "RIGHT", 14, 0)
	private.minBox = W:Input(form, 76, "least")
	private.minBox:SetPoint("LEFT", private.buyinNote, "RIGHT", 6, 0)
	local toLabel = Theme:Text(form, "small", "to", C.muted)
	toLabel:SetPoint("LEFT", private.minBox, "RIGHT", 6, 0)
	private.maxBox = W:Input(form, 76, "most")
	private.maxBox:SetPoint("LEFT", toLabel, "RIGHT", 6, 0)
	local yoursLabel = Theme:Text(form, "small", "yours", C.muted)
	yoursLabel:SetPoint("LEFT", private.maxBox, "RIGHT", 10, 0)
	private.buyinBox = W:Input(form, 76, "yours")
	private.buyinBox:SetPoint("LEFT", yoursLabel, "RIGHT", 6, 0)
	local go = W:Button(form, "Host table", "primary", 100, 26, private.Host)
	go:SetPoint("TOPRIGHT", -14, -66)
	local how = Theme:Text(form, "tiny", HOW_IT_WORKS, C.faint)
	how:SetPoint("TOPLEFT", 14, -102)
	how:SetPoint("RIGHT", -14, 0)
	how:SetWordWrap(true)
	how:SetJustifyH("LEFT")
	how:SetSpacing(2)
	private.RefreshBuyin()
	return form
end

---Fills the blinds list for the stakes and, when the blinds or stakes changed, a buy-in range of 20 to 100 big
---blinds for the host to change.
---@param reset boolean? the blinds or stakes changed: offer the range again
function private.RefreshBuyin(reset)
	local stakes = Stakes()
	local choices = {}
	for _, b in ipairs(BLINDS[stakes]) do
		choices[#choices + 1] = { key = b.key, label = Protocol:Money(b.sb, stakes).."/"..Protocol:Money(b.bb, stakes) }
	end
	private.blinds:SetChoices(choices)
	local b = Blinds(Settings().blinds)
	Settings().blinds = b.key
	private.blinds:SetChoice(b.key)
	local low, high = b.bb * BUYIN_MIN_BB, b.bb * BUYIN_MAX_BB
	if reset or private.minBox:GetText() == "" then
		private.minBox:SetValue(Money(low))
		private.maxBox:SetValue(Money(high))
		private.buyinBox:SetValue(Money(high))
	end
	local tournament = Settings().kind == "tournament"
	for _, f in ipairs({ private.buyinNote, private.minBox, private.maxBox, private.buyinBox }) do f:SetShown(not tournament) end
	for _, f in ipairs({ private.stackLabel, private.stack, private.levelLabel, private.levels }) do f:SetShown(tournament) end
	-- A chips tournament has no entry; the blinds come from the schedule
	local entry = tournament and stakes == "gold"
	private.entryLabel:SetShown(entry)
	private.entryBox:SetShown(entry)
	private.blinds:SetEnabled(not tournament)
	if tournament then
		private.blinds:SetText(Protocol:Money(Protocol.SCHEDULE[1][1], stakes).."/"..Protocol:Money(Protocol.SCHEDULE[1][2], stakes).." up")
	end
	for _, box in ipairs({ private.minBox, private.maxBox, private.buyinBox, private.entryBox }) do
		box.placeholder:SetText(stakes == "gold" and "e.g. 2g 50s" or "chips")
	end
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
		local entry = stakes == "gold" and Protocol:ParseAmount(private.entryBox:GetText(), stakes) or 0
		if not entry then
			UI:Toast("The entry is an amount, like 2g or 50s.", C.red)
			return
		end
		cfg = { kind = "tournament", entry = entry, startStack = s.startStack, levelMinutes = s.levelMinutes, maxSeats = s.seats, turnSeconds = s.turn, stakes = stakes,
			title = s.title ~= "" and s.title or nil, bots = s.stakes == "practice" and (s.seats - 1) or 0 }
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
			text = hosting and "Everyone at your table is sent their final stacks and the table closes." or "Your chips leave with you. A hand under way is folded.",
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
	row.title:SetText(title..Theme:Colorize("  "..Name(ad.h), C.muted))
	local stakes = ad.g and "gold" or "chips"
	local lock = ad.p and Theme:Colorize("  -  password", C.amber) or ""
	if ad.k == "t" then
		row.sub:SetText(("Tournament  -  %s  -  %d of %d registered  -  stacks of %d, levels every %d min%s%s"):format(
			ad.g and ("entry "..Protocol:Money(ad.e, stakes)) or "free entry", ad.s or 0, ad.m or 0, ad.ss or 0, ad.lm or 0, ad.on and "  -  under way" or "", lock))
	else
		row.sub:SetText(("blinds %s/%s  -  %d of %d seats  -  buy-in %s to %s%s%s"):format(Protocol:Money(ad.sb, stakes), Protocol:Money(ad.bb, stakes), ad.s or 0, ad.m or 0,
			Protocol:Money(ad.lo, stakes), Protocol:Money(ad.hi, stakes), ad.g and "  -  gold, settled by mail" or "", lock))
	end
	local st = Net:State()
	if st and st.t == ad.id then
		row.action:SetText(Theme:Colorize("Seated", C.green))
	elseif ad.k == "t" and ad.on then
		row.action:SetText(Theme:Colorize("Under way", C.muted))
	elseif (ad.s or 0) >= (ad.m or 0) then
		row.action:SetText(Theme:Colorize("Full", C.muted))
	else
		row.action:SetText(Theme:Colorize(ad.k == "t" and "Click to enter" or "Click to sit", C.gold))
	end
end

-- A settlement line: what you owe or are owed, paid or not
function private.UpdateLine(row, line)
	local me = Net:Me()
	local owe = strlower((gsub(line.from, "%-.*$", ""))) == strlower((gsub(me, "%-.*$", "")))
	local other = Name(owe and line.to or line.from)
	local amount = Protocol:Money(line.amount, "gold")
	row.title:SetText(owe and ("You owe %s %s"):format(other, amount) or ("%s owes you %s"):format(other, amount))
	row.sub:SetText((line.title and line.title ~= "" and line.title or "Poker")..Theme:Colorize("  -  "..Theme:Ago(time() - (line.at or time())).." ago", C.faint))
	row.pay:SetShown(owe and not line.paid)
	row.mark:SetShown(not owe and not line.paid)
	if line.paid then
		row.action:SetText(Theme:Colorize("Paid", C.green))
	elseif owe then
		row.action:SetText("")
	else
		row.action:SetText("")
	end
	if not line.paid and Gold:IsOverdue(line) then
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
	if ad.k == "t" and ad.on then
		UI:Toast("That tournament is under way.", C.red)
		return
	end
	local stakes = ad.g and "gold" or "chips"
	local function M(n) return Protocol:Money(n or 0, stakes) end
	local title = ad.n and ad.n ~= "" and ad.n or (Name(ad.h).."'s table")
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
				text = (ad.g and ("Tournament, entry %s. "):format(M(entry)) or "Tournament, free to enter. ")..("Everyone starts with %d chips; the blinds rise every %d minutes until one player has them all. No rebuys.%s"):format(
					ad.ss or 0, ad.lm or 0, ad.g and (" %s is the bank: the prizes are the entries, split by place and settled by mail."):format(Name(ad.h)) or ""),
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
		text = ad.g and ("Blinds %s/%s, for gold. Buy in for %s to %s. %s is the bank: when you leave, what you won or lost is settled with them by mail."):format(M(ad.sb), M(ad.bb), M(ad.lo), M(ad.hi), Name(ad.h))
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
