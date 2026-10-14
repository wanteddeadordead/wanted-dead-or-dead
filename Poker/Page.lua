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
local private = { list = nil, form = nil, seat = nil }
local ROW_HEIGHT = 42
local CARD_HEIGHT = 196
local BLINDS = { { key = "1/2", sb = 1, bb = 2 }, { key = "5/10", sb = 5, bb = 10 }, { key = "10/20", sb = 10, bb = 20 }, { key = "25/50", sb = 25, bb = 50 }, { key = "50/100", sb = 50, bb = 100 }, { key = "100/200", sb = 100, bb = 200 } }
local BUYIN_MIN_BB, BUYIN_MAX_BB = 20, 100
local HOW_IT_WORKS = table.concat({
	"HOW IT WORKS",
	"1.  Host a table, or sit at one below. Everyone with Wanted on your faction sees open tables.",
	"2.  Before each hand every player's client makes a secret; the deck is shuffled from all of them together, so nobody, the host included, can choose it.",
	"3.  After each hand your client checks the host's account of it. A hand that doesn't check out is marked in red at the table.",
	"4.  The host's client deals, so a host who edited the addon could see cards. Play for stakes only with people you'd deal cards with.",
	"5.  Chips are play money for now. Close the table window and you stay seated; leave from the table or here.",
}, "\n")

local function Settings()
	Poker.db.host = Poker.db.host or { blinds = "10/20", seats = 6, turn = 30, title = "" }
	return Poker.db.host
end

local function Blinds(key)
	for _, b in ipairs(BLINDS) do
		if b.key == key then return b end
	end
	return BLINDS[3]
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
	local blindChoices = {}
	for _, b in ipairs(BLINDS) do blindChoices[#blindChoices + 1] = { key = b.key, label = b.key } end
	private.blinds = W:Choice(form, 90, blindChoices, function(key) Settings().blinds = key private.RefreshBuyin() end)
	private.blinds:SetPoint("LEFT", blindsLabel, "RIGHT", 6, 0)
	private.blinds:SetChoice(s.blinds)
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
	private.buyinNote = Theme:Text(form, "small", "", C.muted)
	private.buyinNote:SetPoint("TOPLEFT", 14, -66)
	private.buyinBox = W:Input(form, 90, "Your buy-in")
	private.buyinBox:SetPoint("LEFT", private.buyinNote, "RIGHT", 10, 0)
	local go = W:Button(form, "Host table", "primary", 110, 26, private.Host)
	go:SetPoint("LEFT", private.buyinBox, "RIGHT", 10, 0)
	local how = Theme:Text(form, "tiny", HOW_IT_WORKS, C.faint)
	how:SetPoint("TOPLEFT", 14, -100)
	how:SetPoint("RIGHT", -14, 0)
	how:SetWordWrap(true)
	how:SetJustifyH("LEFT")
	how:SetSpacing(2)
	private.RefreshBuyin()
	return form
end

function private.RefreshBuyin()
	local b = Blinds(Settings().blinds)
	local low, high = b.bb * BUYIN_MIN_BB, b.bb * BUYIN_MAX_BB
	private.buyinNote:SetText(("Buy-in %d to %d chips"):format(low, high))
	local current = tonumber(private.buyinBox:GetText())
	if not current or current < low or current > high then
		private.buyinBox:SetValue(tostring(high))
	end
end

function private.Host()
	local s = Settings()
	local b = Blinds(s.blinds)
	s.title = strtrim(private.titleBox:GetText() or "")
	local buyin = tonumber(private.buyinBox:GetText())
	local cfg = { sb = b.sb, bb = b.bb, buyMin = b.bb * BUYIN_MIN_BB, buyMax = b.bb * BUYIN_MAX_BB, maxSeats = s.seats, turnSeconds = s.turn, stakes = "chips",
		title = s.title ~= "" and s.title or nil }
	if not buyin or buyin ~= floor(buyin) or buyin < cfg.buyMin or buyin > cfg.buyMax then
		UI:Toast(("Your buy-in is %d to %d chips."):format(cfg.buyMin, cfg.buyMax), C.red)
		return
	end
	local ok, why = Net:HostTable(cfg, buyin)
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
	private.seatSub:SetWidth(width - 300)
	local open = W:Button(card, "Open table", "primary", 110, 26, function() TableUI:Show() end)
	open:SetPoint("BOTTOMRIGHT", -14, 12)
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
	private.leaveButton:SetPoint("RIGHT", open, "LEFT", -6, 0)
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
end

function private.UpdateRow(row, ad)
	local title = ad.n and ad.n ~= "" and ad.n or (Name(ad.h).."'s table")
	row.title:SetText(title..Theme:Colorize("  "..Name(ad.h), C.muted))
	row.sub:SetText(("blinds %d/%d  -  %d of %d seats  -  buy-in %d to %d%s"):format(ad.sb or 0, ad.bb or 0, ad.s or 0, ad.m or 0, ad.lo or 0, ad.hi or 0, ad.g and "  -  gold" or ""))
	local st = Net:State()
	if st and st.t == ad.id then
		row.action:SetText(Theme:Colorize("Seated", C.green))
	elseif (ad.s or 0) >= (ad.m or 0) then
		row.action:SetText(Theme:Colorize("Full", C.muted))
	else
		row.action:SetText(Theme:Colorize("Click to sit", C.gold))
	end
end

function private.Sit(ad)
	local st = Net:State()
	if st and st.phase ~= "closed" and st.open ~= false then
		UI:Toast("You're at a table already. Leave it first.", C.red)
		return
	end
	if (ad.s or 0) >= (ad.m or 0) then
		UI:Toast("That table is full.", C.red)
		return
	end
	W:Dialog({
		title = "Sit at "..(ad.n and ad.n ~= "" and ad.n or (Name(ad.h).."'s table")),
		text = ("Blinds %d/%d. Buy in for %d to %d chips. Your client checks every deal; chips are play money for now."):format(ad.sb or 0, ad.bb or 0, ad.lo or 0, ad.hi or 0),
		input = { placeholder = "Buy-in", value = tostring(ad.hi or 0) },
		confirmLabel = "Sit down",
		validate = function(value)
			local n = tonumber(value)
			if not n or n ~= floor(n) or n < (ad.lo or 0) or n > (ad.hi or 0) then return ("A whole number from %d to %d."):format(ad.lo or 0, ad.hi or 0) end
		end,
		onConfirm = function(value)
			local ok, why = Net:JoinTable(ad.id, tonumber(value))
			if not ok then
				UI:Toast(why or "Couldn't sit down.", C.red)
				return
			end
			TableUI:Reset()
			TableUI:Show()
			private.Refresh()
		end,
	})
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
	private.list:ClearAllPoints()
	private.list:SetPoint("TOPLEFT", seated and private.seat or private.form, "BOTTOMLEFT", 0, -12)
	private.list:SetPoint("TOPRIGHT", seated and private.seat or private.form, "BOTTOMRIGHT", 0, -12)
	if seated then
		local n = 0
		for _ in pairs(st.seats) do n = n + 1 end
		private.seatTitle:SetText(st.cfg.title and st.cfg.title ~= "" and st.cfg.title or (Name(st.host).."'s table"))
		private.seatSub:SetText(("blinds %d/%d  -  %d of %d seated  -  host %s%s"):format(st.cfg.sb, st.cfg.bb, n, st.cfg.maxSeats, Name(st.host), Net:HostedTable() and " (you)" or ""))
		private.leaveButton:SetText(Net:HostedTable() and "Close table" or "Leave")
	end
	private.list:SetItems(Net:Tables(), "No open tables right now.", "Host one above: every Wanted player of your faction sees it.")
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
		elseif event == "hostGone" or event == "newHost" then
			TableUI:OnHost(event, ...)
		elseif event == "left" then
			private.shownOnce = nil
			private.Refresh()
		end
	end)
	Wanted:RegisterCommand("poker", "Opens the Poker page: host a table or sit at one.", function()
		UI:Show("poker")
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
		local listTop = CARD_HEIGHT + 12
		local list = W:List(container, ROW_HEIGHT, floor((height - listTop) / ROW_HEIGHT), private.CreateRow, private.UpdateRow)
		list.onClick = private.Sit
		private.list = list
		private.Refresh()
	end,
	refresh = private.Refresh,
})
