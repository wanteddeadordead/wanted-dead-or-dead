-- Wanted: Dead Man's Hand Poker. Gold tables: cash on the table, the host holding it. A player's buy-in goes to
-- the host before they're dealt in, by a trade window (seen here from the trade events and the money that changed
-- hands) or by mail (seen in the inbox); the host's table is told (Host:Paid). When a player leaves, the host owes
-- them their stack: a settlement line from the host to the player, kept in both clients' ledgers and paid by trade
-- (seen the same way) or by mail (Pay fills the mail in, the player presses Send). Nobody but the host ever owes
-- anyone. A line the host leaves unpaid two days counts against their Wanted reputation on every client that holds
-- it. Receipts (a buy-in paid, money received) are lines too, marked paid as they're made, so the ledger tells the
-- whole story of a table. The open debts and the table under way are mirrored to the vault (Vault) after every
-- change, so a crash loses nothing: at the next login the vault is read back, and a table it holds is settled
-- from where it stood.
local _, Poker = ...
local Gold = Poker:NewModule("PokerGold")
local Wanted = Poker.Wanted
local Net = Poker.PokerNet
local Vault = Poker.PokerVault
local Protocol = Poker.PokerProtocol
local private = {
	frame = CreateFrame("Frame"),
	pendingSend = nil, -- { lineId?, buyin?, recipient, amount, at, closedAt }
	seenInbox = {}, -- line id, or a mail's mark -> true once recorded from the inbox
	trade = nil, -- the trade window open: { name, give, get, before, accepted }
	pools = {}, -- pools traded to this character by a host handing the table on: { name, amount, at }
	asked = {}, -- name -> GetTime() we last asked them for the lines they owe us
}
local SUBJECT_PREFIX = "Wanted poker "
local BUYIN_SUBJECT = SUBJECT_PREFIX.."buy-in "
Gold.UNPAID_AFTER_SECONDS = 48 * 60 * 60
local SEND_ANSWER_SECONDS = 30
local CLOSE_GRACE_SECONDS = 10
local ASK_SECONDS = 60
local COPPER = 1 -- a gold table's chip is a copper piece: the game's own money unit, so mail and trades need no conversion
-- Lines that are debts (the host owes), as against receipts, which are paid as they're made
local DEBT = { cashout = true, prize = true, refund = true }
local function Money(chips) return Protocol:Money(chips, "gold") end

local function SameName(a, b)
	if type(a) ~= "string" or type(b) ~= "string" then
		return false
	end
	return strlower((gsub(a, "%-.*$", ""))) == strlower((gsub(b, "%-.*$", "")))
end

local function Short(name)
	return type(name) == "string" and (strmatch(name, "^(.-)%-") or name) or "?"
end

function Gold:OnLoad()
	Poker.db.ledger = type(Poker.db.ledger) == "table" and Poker.db.ledger or {}
end

function Gold:OnEnable()
	for _, event in ipairs({ "MAIL_SEND_SUCCESS", "MAIL_FAILED", "MAIL_CLOSED", "MAIL_INBOX_UPDATE", "TRADE_SHOW", "TRADE_ACCEPT_UPDATE", "TRADE_CLOSED" }) do
		private.frame:RegisterEvent(event)
	end
	private.frame:SetScript("OnEvent", private.OnEvent)
	hooksecurefunc("SendMail", private.OnSendMail)
	Net:On(function(event, ...)
		if event == "settle" or event == "hostLost" then
			Gold:Add((...))
		elseif event == "host" then
			private.OnHostEvent(...)
		elseif event == "state" then
			-- The vault follows the table: who's paid, the stacks after each hand
			local st = ...
			if st and st.cfg and st.cfg.stakes == "gold" and Net:HostedTable() then Gold:Persist() end
		end
	end)
	Wanted.Reputation:AddTallySource(private.Tally)
	Gold:Recover()
end

-- ============================================================================
-- The ledger
-- ============================================================================

---Whether a line is a debt the host owes, as against a receipt.
---@param line table
---@return boolean
function Gold:IsDebt(line)
	return DEBT[line.kind or "cashout"] == true
end

---Records a line, once. A real line from the host replaces a claim this client made for the same table and player
---when the host dropped; a claim never replaces a real line.
---@param line table { id, table, title?, host, at, from, to, amount (copper), kind?, paid?, paidHow?, claim? }
function Gold:Add(line)
	if type(line) ~= "table" or type(line.id) ~= "string" then
		return
	end
	for _, l in ipairs(Poker.db.ledger) do
		if l.id == line.id then
			return
		end
	end
	if line.claim then
		for _, l in ipairs(Poker.db.ledger) do
			if not l.claim and l.table == line.table and Gold:IsDebt(l) and SameName(l.to, line.to) and SameName(l.from, line.from) then
				return -- the host's own word on it is already here
			end
		end
	elseif Gold:IsDebt(line) then
		for i = #Poker.db.ledger, 1, -1 do
			local l = Poker.db.ledger[i]
			if l.claim and l.table == line.table and SameName(l.to, line.to) and SameName(l.from, line.from) then
				tremove(Poker.db.ledger, i)
			end
		end
	end
	tinsert(Poker.db.ledger, line)
	private.Notify()
	local me = Net:Me()
	if Gold:IsDebt(line) and not line.paid then
		if SameName(line.from, me) then
			Wanted:Print("Poker: you owe %s %s from %s (%s). Trade it to them, or Pay from the Poker page at a mailbox.", Short(line.to), Money(line.amount), line.title or "the table", line.kind or "cash-out")
		elseif SameName(line.to, me) then
			Wanted:Print("Poker: %s owes you %s from %s (%s).%s", Short(line.from), Money(line.amount), line.title or "the table", line.kind or "cash-out",
				line.claim and " The host dropped; your client reminds them when they're back." or "")
		end
	end
	Gold:Persist()
end

---Every line, newest first.
---@return table[]
function Gold:Lines()
	local list = {}
	for _, l in ipairs(Poker.db.ledger) do
		list[#list + 1] = l
	end
	sort(list, function(a, b) return (a.at or 0) > (b.at or 0) end)
	return list
end

---Marks a line paid.
---@param id string
---@param how string "mail" | "trade" | "hand"
function Gold:MarkPaid(id, how)
	for _, l in ipairs(Poker.db.ledger) do
		if l.id == id and not l.paid then
			l.paid, l.paidHow = time(), how
			private.Notify()
			Gold:Persist()
			return true
		end
	end
	return false
end

---Whether a line is overdue: a debt unpaid two days after the game.
---@param line table
---@return boolean
function Gold:IsOverdue(line)
	return Gold:IsDebt(line) and not line.paid and time() - (line.at or 0) > Gold.UNPAID_AFTER_SECONDS
end

---What this character still owes, in copper, across every line.
---@return number
function Gold:Owing()
	local me, total = Net:Me(), 0
	for _, l in ipairs(Poker.db.ledger) do
		if Gold:IsDebt(l) and not l.paid and SameName(l.from, me) then
			total = total + l.amount
		end
	end
	return total
end

---The open debts this character owes one player (the lines they're sent when they ask).
---@param name string
---@return table[]
function Gold:DebtsTo(name)
	local me, list = Net:Me(), {}
	for _, l in ipairs(Poker.db.ledger) do
		if Gold:IsDebt(l) and not l.paid and not l.claim and SameName(l.from, me) and SameName(l.to, name) then
			list[#list + 1] = l
		end
	end
	return list
end

---Whether this character can buy in for an amount (copper): the money in their bags, less what they still owe.
---@param amount number copper
---@return boolean ok
---@return string? reason
function Gold:CanBuyIn(amount)
	local bags = floor((GetMoney and GetMoney() or 0) / COPPER)
	local owing = Gold:Owing()
	if bags - owing < amount then
		return false, owing > 0 and ("you have %s and still owe %s from earlier games"):format(Money(bags), Money(owing)) or ("you have %s"):format(Money(bags))
	end
	return true
end

function private.Notify()
	if Poker.PokerPage and Poker.PokerPage.Refresh then
		Poker.PokerPage:Refresh()
	end
end

-- The oldest unpaid debt from one player to another that an amount covers
local function LineCovered(from, to, copper)
	local best
	for _, l in ipairs(Poker.db.ledger) do
		if Gold:IsDebt(l) and not l.paid and not l.claim and SameName(l.from, from) and SameName(l.to, to) and copper >= l.amount and (not best or (l.at or 0) < (best.at or 0)) then
			best = l
		end
	end
	return best
end

local function LineById(id)
	for _, l in ipairs(Poker.db.ledger) do
		if l.id == id then return l end
	end
end

local function SubjectLine(subject)
	if type(subject) ~= "string" or strsub(subject, 1, #BUYIN_SUBJECT) == BUYIN_SUBJECT then
		return nil
	end
	local id = strmatch(subject, "^"..SUBJECT_PREFIX.."(.-)%s*$")
	return id ~= "" and id or nil
end

local function SubjectBuyIn(subject)
	local id = type(subject) == "string" and strmatch(subject, "^"..BUYIN_SUBJECT.."(.-)%s*$")
	return id ~= "" and id or nil
end

-- A receipt: money that changed hands for a table, recorded on the spot
local function Receipt(tableId, title, from, to, copper, kind, how)
	private.receipts = (private.receipts or 0) + 1
	Gold:Add({ id = tableId..":in:"..Short(from)..":"..time()..":"..private.receipts, table = tableId, title = title, host = Protocol:HostOf(tableId) or to, at = time(),
		from = from, to = to, amount = copper, kind = kind, paid = time(), paidHow = how })
end

-- ============================================================================
-- Money arriving
-- ============================================================================

---Money came in from a player (a trade, a mail): a buy-in for the table this character hosts, or the payment of a
---line they owed. Returns what it was.
---@param name string
---@param copper number
---@param how string "trade" | "mail"
---@return string? "buyin" | "paid" | "received"
function Gold:Received(name, copper, how)
	local me = Net:Me()
	local host = Net:HostedTable()
	local st = Net:State()
	if how == "trade" and st and st.cfg and st.cfg.stakes == "gold" and SameName(st.host, name) and SameName(st.handingTo, me) and (st.pool or 0) > 0 and copper >= st.pool then
		-- The host hands this character the table: the pool first, the table once it's seen (TakePool)
		tinsert(private.pools, { name = name, amount = copper, at = GetTime() })
		Receipt(st.t, st.cfg.title, name, me, copper, "pool", how)
		Wanted:Print("Poker: %s traded you the table's pool of %s.", Short(name), Money(copper))
		return "pool"
	end
	if host and host.cfg.stakes == "gold" and host.open then
		local due = host:Paid(name, copper, how)
		Receipt(host.id, host.cfg.title, name, me, copper, due and "buyin" or "received", how)
		Wanted:Print(due and "Poker: %s paid %s for their seat (%s)." or "Poker: %s sent %s nobody asked for (%s): it's owed back, see Settlement.", Short(name), Money(copper), how)
		return due and "buyin" or "received"
	end
	local line = LineCovered(name, me, copper)
	if line and Gold:MarkPaid(line.id, how) then
		Wanted:Print("Poker: %s paid you %s (%s).", Short(name), Money(copper), how)
		return "paid"
	end
	return nil
end

---Whether a pool of at least this much came by trade from a host handing the table on, lately; taken once.
---@param name string
---@param copper number
---@return boolean
function Gold:TakePool(name, copper)
	for i, pool in ipairs(private.pools) do
		if SameName(pool.name, name) and pool.amount >= copper and GetTime() - pool.at <= Protocol.POOL_SECONDS then
			tremove(private.pools, i)
			return true
		end
	end
	return false
end

---Money went out to a player (a trade, a mail): this character's buy-in to their host, or a line paid.
---@param name string
---@param copper number
---@param how string
---@return string? "buyin" | "paid"
function Gold:Gave(name, copper, how)
	local me = Net:Me()
	local st = Net:State()
	local mine = st and st.me and st.seats[st.me]
	local host = Net:HostedTable()
	if how == "trade" and host and host.handoffPending and SameName(host.handoffPending.name, name) and copper >= host.handoffPending.pool then
		Receipt(host.id, host.cfg.title, me, name, copper, "pool", how)
		local ok, why = host:Handoff(copper)
		Wanted:Print(ok and "Poker: the pool went to %s; the table passes to them." or "Poker: the pool went to %s, but the table couldn't pass: %s.", Short(name), tostring(why))
		return "pool"
	end
	if st and st.cfg and st.cfg.stakes == "gold" and SameName(st.host, name) and mine and (mine.unpaid or mine.rebuyDue) then
		Receipt(st.t, st.cfg.title, me, st.host, copper, "buyin", how)
		Wanted:Print("Poker: %s paid to %s for your seat (%s).", Money(copper), Short(name), how)
		return "buyin"
	end
	local line = LineCovered(me, name, copper)
	if line and Gold:MarkPaid(line.id, how) then
		Wanted:Print("Poker: paid %s to %s (%s).", Money(copper), Short(name), how)
		return "paid"
	end
	return nil
end

-- A trade with another player: who, and once both have accepted, the money each side put up. The game closes the
-- window whether it went through or not; the money in the bags says which
function private.OnTrade(event, ...)
	if event == "TRADE_SHOW" then
		local name = (GetUnitName and GetUnitName("NPC", true)) or (UnitName and UnitName("NPC"))
		private.trade = type(name) == "string" and name ~= "" and { name = name } or nil
	elseif event == "TRADE_ACCEPT_UPDATE" then
		local player, target = ...
		local t = private.trade
		if t and player == 1 and target == 1 then
			t.give, t.get, t.before, t.accepted = tonumber(GetPlayerTradeMoney and GetPlayerTradeMoney()) or 0, tonumber(GetTargetTradeMoney and GetTargetTradeMoney()) or 0, GetMoney(), true
		end
	elseif event == "TRADE_CLOSED" then
		local t = private.trade
		private.trade = nil
		if t and t.accepted and (t.give > 0 or t.get > 0) then
			private.ConfirmTrade(t, 0)
		end
	end
end

function private.ConfirmTrade(t, tries)
	if GetMoney() == t.before - t.give + t.get then
		if t.get >= COPPER then Gold:Received(t.name, floor(t.get / COPPER), "trade") end
		if t.give >= COPPER then Gold:Gave(t.name, floor(t.give / COPPER), "trade") end
	elseif tries < 4 then
		C_Timer.After(0.5, function() private.ConfirmTrade(t, tries + 1) end)
	end
end

-- ============================================================================
-- Paying by mail
-- ============================================================================

---Fills the send mail form in for a line this character owes. They press Send.
---@param line table
---@return boolean ok
---@return string? reason
function Gold:Prefill(line)
	if not MailFrame or not MailFrame:IsShown() then
		return false, "open a mailbox first"
	end
	if line.paid or not SameName(line.from, Net:Me()) then
		return false, "not a debt of yours"
	end
	MailFrameTab_OnClick(nil, 2)
	SendMailNameEditBox:SetText(line.to)
	SendMailSubjectEditBox:SetText(SUBJECT_PREFIX..line.id)
	SendMailBodyEditBox:SetText(("Poker at %s. Good game."):format(line.title or "the table"))
	MoneyInputFrame_SetCopper(SendMailMoney, line.amount * COPPER)
	if SendMailSendMoneyButton then
		SendMailSendMoneyButton:SetChecked(true)
	end
	if SendMailCODButton then
		SendMailCODButton:SetChecked(false)
	end
	return true
end

---Fills the send mail form in for this character's buy-in (or rebuy) at the table they sit at. They press Send.
---@return boolean ok
---@return string? reason
function Gold:PrefillBuyIn()
	if not MailFrame or not MailFrame:IsShown() then
		return false, "open a mailbox first"
	end
	local st = Net:State()
	local mine = st and st.me and st.seats[st.me]
	local due = mine and (mine.unpaid and (mine.unpaid - (mine.received or 0)) or mine.rebuyDue)
	if not st or st.cfg.stakes ~= "gold" or not due or due <= 0 then
		return false, "nothing due"
	end
	MailFrameTab_OnClick(nil, 2)
	SendMailNameEditBox:SetText(st.host)
	SendMailSubjectEditBox:SetText(BUYIN_SUBJECT..st.t)
	SendMailBodyEditBox:SetText(("My buy-in at %s."):format(st.cfg.title or "your table"))
	MoneyInputFrame_SetCopper(SendMailMoney, due * COPPER)
	if SendMailSendMoneyButton then
		SendMailSendMoneyButton:SetChecked(true)
	end
	if SendMailCODButton then
		SendMailCODButton:SetChecked(false)
	end
	return true
end

function private.OnSendMail(recipient, subject)
	private.pendingSend = nil
	local amount = (GetSendMailMoney and GetSendMailMoney()) or (MoneyInputFrame_GetCopper and MoneyInputFrame_GetCopper(SendMailMoney)) or 0
	if (GetSendMailCOD and (GetSendMailCOD() or 0) > 0) or type(amount) ~= "number" or amount < COPPER then
		return
	end
	local copper = floor(amount / COPPER)
	local tableId = SubjectBuyIn(subject)
	if tableId then
		private.pendingSend = { buyin = true, recipient = recipient, amount = copper, at = GetTime() }
		return
	end
	local line
	local id = SubjectLine(subject)
	if id then
		line = LineById(id)
		if not line or line.paid or not SameName(line.from, Net:Me()) or not SameName(line.to, recipient) or copper < line.amount then
			return
		end
	else
		line = LineCovered(Net:Me(), recipient, copper)
	end
	if not line then
		return
	end
	private.pendingSend = { lineId = line.id, recipient = recipient, amount = copper, at = GetTime() }
end

function private.OnEvent(_, event, ...)
	if event == "MAIL_SEND_SUCCESS" then
		local pending = private.pendingSend
		private.pendingSend = nil
		if not pending or GetTime() - pending.at > SEND_ANSWER_SECONDS or (pending.closedAt and GetTime() - pending.closedAt > CLOSE_GRACE_SECONDS) then
			return
		end
		if pending.buyin then
			Gold:Gave(pending.recipient, pending.amount, "mail")
		elseif Gold:MarkPaid(pending.lineId, "mail") then
			Wanted:Print("Poker: paid %s to %s (mail).", Money(pending.amount), Short(pending.recipient))
		end
	elseif event == "MAIL_FAILED" then
		local itemID = ...
		local pending = private.pendingSend
		if pending and itemID == nil and GetTime() - pending.at <= SEND_ANSWER_SECONDS then
			private.pendingSend = nil
		end
	elseif event == "MAIL_CLOSED" then
		if private.pendingSend then
			private.pendingSend.closedAt = private.pendingSend.closedAt or GetTime()
		end
	elseif event == "MAIL_INBOX_UPDATE" then
		private.ScanInbox()
	elseif event == "TRADE_SHOW" or event == "TRADE_ACCEPT_UPDATE" or event == "TRADE_CLOSED" then
		private.OnTrade(event, ...)
	end
end

-- The inbox: a buy-in mailed to the table this character hosts, or the payment of a line owed to them. Each mail is
-- taken once, by its sender, subject and amount
function private.ScanInbox()
	local me = Net:Me()
	local host = Net:HostedTable()
	for i = 1, GetInboxNumItems() do
		local _, _, sender, subject, money, cod = GetInboxHeaderInfo(i)
		if type(money) == "number" and money >= COPPER and not (type(cod) == "number" and cod > 0) and type(sender) == "string" then
			local copper = floor(money / COPPER)
			local buyinFor = SubjectBuyIn(subject)
			local mark = sender.."|"..tostring(subject).."|"..money
			if host and host.cfg.stakes == "gold" and host.open and (buyinFor == host.id or (not buyinFor and private.SeatDue(host, sender))) then
				if not private.seenInbox[mark] then
					private.seenInbox[mark] = true
					Gold:Received(sender, copper, "mail")
				end
			else
				local line
				local id = SubjectLine(subject)
				if id then
					line = LineById(id)
					if line and (line.paid or not SameName(line.to, me) or not SameName(line.from, sender) or copper < line.amount) then
						line = nil
					end
				else
					line = LineCovered(sender, me, copper)
				end
				if line and not private.seenInbox[line.id] then
					private.seenInbox[line.id] = true
					if Gold:MarkPaid(line.id, "mail") then
						Wanted:Print("Poker: %s paid you %s (mail).", Short(sender), Money(copper))
					end
				end
			end
		end
	end
end

-- Whether a player has a buy-in or rebuy due at the table
function private.SeatDue(host, name)
	for _, p in pairs(host.seats) do
		if SameName(p.name, name) and (p.unpaid or p.rebuyDue) then return true end
	end
	return false
end

-- ============================================================================
-- Asking for what's owed
-- ============================================================================

---Asks every host who owes this character for their open lines, so a line lost to their crash (or a claim made
---when they dropped) is set straight. At most once a minute per host.
function Gold:AskForLines()
	local me, now = Net:Me(), GetTime()
	for _, l in ipairs(Poker.db.ledger) do
		if Gold:IsDebt(l) and not l.paid and SameName(l.to, me) and not SameName(l.from, me) and (now - (private.asked[l.from] or -math.huge)) >= ASK_SECONDS then
			private.asked[l.from] = now
			Net:AskLines(l.from)
		end
	end
end

-- ============================================================================
-- The vault: a crash loses nothing
-- ============================================================================

-- What the host's table looks like for the vault: enough to owe every seat the right amount if this client dies
local function Snapshot(host)
	if not host or host.cfg.stakes ~= "gold" or not host.open then
		return nil
	end
	local seats = {}
	for _, p in pairs(host.seats) do
		if p.name ~= host.name then
			seats[#seats + 1] = { n = p.name, s = p.stack + (p.pendingChips or 0), b = p.bought or 0, u = p.unpaid, r = p.received }
		end
	end
	return { id = host.id, title = host.cfg.title, kind = host.cfg.kind, finished = host.phase == "finished" or nil, seats = seats, at = time() }
end

---Writes the open debts and the table under way to the vault.
function Gold:Persist()
	local lines = {}
	for _, l in ipairs(Poker.db.ledger) do
		if Gold:IsDebt(l) and not l.paid then
			lines[#lines + 1] = l
		end
	end
	local snapshot = Snapshot(Net:HostedTable())
	if #lines == 0 and not snapshot then
		Vault:Save(nil)
	else
		Vault:Save({ v = 1, lines = lines, table = snapshot })
	end
end

---At login: what the vault kept. Lines the saved variables lost come back; a table the vault still holds ended
---with a crash (or a reload), and every seat is owed what it had.
function Gold:Recover()
	local kept = Vault:Load()
	if not kept then
		return
	end
	local me = Net:Me()
	for _, l in ipairs(kept.lines or {}) do
		if type(l) == "table" and type(l.id) == "string" and not LineById(l.id) then
			tinsert(Poker.db.ledger, l)
		end
	end
	local t = kept.table
	if type(t) == "table" and type(t.id) == "string" and type(t.seats) == "table" then
		local owed = {}
		for _, s in ipairs(t.seats) do
			local amount, kind
			if s.u then
				amount, kind = s.r or 0, "refund"
			elseif t.kind == "tournament" and not t.finished then
				amount, kind = s.b, "refund"
			elseif t.kind ~= "tournament" then
				amount, kind = s.s, "cashout"
			end
			if amount and amount >= 1 and not LineById(t.id..":out:"..Short(s.n)) then
				tinsert(Poker.db.ledger, { id = t.id..":out:"..Short(s.n), table = t.id, title = t.title, host = me, at = time(), from = me, to = s.n, amount = amount, kind = kind })
				owed[#owed + 1] = ("%s %s"):format(Short(s.n), Money(amount))
			end
		end
		if #owed > 0 then
			Wanted:Print("Poker: your table %s ended with the last session. You owe %s: see Settlement on the Poker page.", t.title or "", table.concat(owed, ", "))
		end
	end
	private.Notify()
	Gold:Persist()
end

-- The table this character hosts: the vault follows it, and a closed table is summed up for them
function private.OnHostEvent(event, ...)
	if event == "closed" then
		local me, owed = Net:Me(), {}
		for _, l in ipairs(Poker.db.ledger) do
			if Gold:IsDebt(l) and not l.paid and SameName(l.from, me) then
				owed[#owed + 1] = ("%s %s"):format(Short(l.to), Money(l.amount))
			end
		end
		if #owed > 0 then
			Wanted:Print("Poker: table closed. You owe %s. Trade it to them, or Pay from the Poker page at a mailbox.", table.concat(owed, ", "))
		end
	end
	if event == "closed" or event == "paid" or event == "sat" or event == "stood" or event == "hand" or event == "rebuy" or event == "finished" or event == "handed" then
		Gold:Persist()
	end
end

-- ============================================================================
-- Reputation
-- ============================================================================

-- A debt left unpaid two days after the game counts like a bounty left unpaid; one paid, like a bounty paid
function private.Tally(origin, tally, since, weights)
	for _, l in ipairs(Poker.db.ledger) do
		if Gold:IsDebt(l) and not l.claim and SameName(l.from, origin) and (l.at or 0) >= since then
			if l.paid then
				tally.paid = tally.paid + 1
				tally.points = tally.points + weights.bountyPaid
			elseif Gold:IsOverdue(l) then
				tally.unpaid = tally.unpaid + 1
				tally.points = tally.points + weights.bountyUnpaid
			end
		end
	end
end
