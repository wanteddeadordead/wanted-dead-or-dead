-- Wanted: Dead Man's Hand Poker. Gold tables: the ledger of what the game settled (the host is the bank: each
-- player's win or loss against what they bought in for is a line between them and the host), paid by mail the
-- way bounties are (Payments): the payer's client fills the mail in and records the send, the payee's client
-- records the arrival, and a mail written by hand counts when it carries the amount between the two. Nothing
-- here moves gold; the player presses Send. What's left unpaid after two days counts against the debtor's
-- Wanted reputation on every client that holds the line: the players who were at the table.
local _, Poker = ...
local Gold = Poker:NewModule("PokerGold")
local Wanted = Poker.Wanted
local Net = Poker.PokerNet
local private = {
	frame = CreateFrame("Frame"),
	pendingSend = nil, -- { lineId, recipient, amount, at, closedAt }
	seenInbox = {}, -- line id -> true once recorded from the inbox
}
local Protocol = Poker.PokerProtocol
local SUBJECT_PREFIX = "Wanted poker "
Gold.UNPAID_AFTER_SECONDS = 48 * 60 * 60
local SEND_ANSWER_SECONDS = 30
local CLOSE_GRACE_SECONDS = 10
local COPPER = 100 -- a gold table's chip is a silver piece
local function Money(chips) return Protocol:Money(chips, "gold") end

local function SameName(a, b)
	if type(a) ~= "string" or type(b) ~= "string" then
		return false
	end
	return strlower((gsub(a, "%-.*$", ""))) == strlower((gsub(b, "%-.*$", "")))
end

function Gold:OnLoad()
	Poker.db.ledger = type(Poker.db.ledger) == "table" and Poker.db.ledger or {}
end

function Gold:OnEnable()
	private.frame:RegisterEvent("MAIL_SEND_SUCCESS")
	private.frame:RegisterEvent("MAIL_FAILED")
	private.frame:RegisterEvent("MAIL_CLOSED")
	private.frame:RegisterEvent("MAIL_INBOX_UPDATE")
	private.frame:SetScript("OnEvent", private.OnEvent)
	hooksecurefunc("SendMail", private.OnSendMail)
	Net:On(function(event, line)
		if event == "settle" or event == "hostSettle" then
			Gold:Add(line)
		end
	end)
	Wanted.Reputation:AddTallySource(private.Tally)
end

-- ============================================================================
-- The ledger
-- ============================================================================

---Records a settlement line, once.
---@param line table { id, table, title?, host, at, from, to, amount (gold) }
function Gold:Add(line)
	for _, l in ipairs(Poker.db.ledger) do
		if l.id == line.id then
			return
		end
	end
	tinsert(Poker.db.ledger, line)
	private.Notify()
	local me = Net:Me()
	if SameName(line.from, me) then
		Wanted:Print("Poker: you owe %s %s from %s. Pay from the Poker page at a mailbox.", line.to, Money(line.amount), line.title or "the table")
	elseif SameName(line.to, me) then
		Wanted:Print("Poker: %s owes you %s from %s.", line.from, Money(line.amount), line.title or "the table")
	end
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
---@param how string "mail" | "hand"
function Gold:MarkPaid(id, how)
	for _, l in ipairs(Poker.db.ledger) do
		if l.id == id and not l.paid then
			l.paid, l.paidHow = time(), how
			private.Notify()
			return true
		end
	end
	return false
end

---Whether a line is overdue: unpaid two days after the game.
---@param line table
---@return boolean
function Gold:IsOverdue(line)
	return not line.paid and time() - (line.at or 0) > Gold.UNPAID_AFTER_SECONDS
end

---What this character still owes, in silver, across every line.
---@return number
function Gold:Owing()
	local me, total = Net:Me(), 0
	for _, l in ipairs(Poker.db.ledger) do
		if not l.paid and SameName(l.from, me) then
			total = total + l.amount
		end
	end
	return total
end

---Whether this character can buy in for an amount (silver): the money in their bags, less what they still owe.
---@param amount number silver
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

-- The oldest unpaid line from one player to another that an amount covers
local function LineCovered(from, to, gold)
	local best
	for _, l in ipairs(Poker.db.ledger) do
		if not l.paid and SameName(l.from, from) and SameName(l.to, to) and gold >= l.amount and (not best or (l.at or 0) < (best.at or 0)) then
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
	local id = type(subject) == "string" and strmatch(subject, "^"..SUBJECT_PREFIX.."(.-)%s*$")
	return id ~= "" and id or nil
end

-- ============================================================================
-- Paying
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

function private.OnSendMail(recipient, subject)
	private.pendingSend = nil
	local amount = (GetSendMailMoney and GetSendMailMoney()) or (MoneyInputFrame_GetCopper and MoneyInputFrame_GetCopper(SendMailMoney)) or 0
	if (GetSendMailCOD and (GetSendMailCOD() or 0) > 0) or type(amount) ~= "number" or amount <= 0 then
		return
	end
	local gold = floor(amount / COPPER)
	local line
	local id = SubjectLine(subject)
	if id then
		line = LineById(id)
		if not line or line.paid or not SameName(line.from, Net:Me()) or not SameName(line.to, recipient) or gold < line.amount then
			return
		end
	else
		line = LineCovered(Net:Me(), recipient, gold)
	end
	if not line then
		return
	end
	private.pendingSend = { lineId = line.id, recipient = recipient, amount = amount, at = GetTime() }
end

function private.OnEvent(_, event, ...)
	if event == "MAIL_SEND_SUCCESS" then
		local pending = private.pendingSend
		private.pendingSend = nil
		if not pending or GetTime() - pending.at > SEND_ANSWER_SECONDS or (pending.closedAt and GetTime() - pending.closedAt > CLOSE_GRACE_SECONDS) then
			return
		end
		if Gold:MarkPaid(pending.lineId, "mail") then
			Wanted:Print("Poker: paid %s to %s.", Money(floor(pending.amount / COPPER)), pending.recipient)
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
	end
end

-- ============================================================================
-- Receiving
-- ============================================================================

function private.ScanInbox()
	local me = Net:Me()
	for i = 1, GetInboxNumItems() do
		local _, _, sender, subject, money, cod = GetInboxHeaderInfo(i)
		if type(money) == "number" and money > 0 and not (type(cod) == "number" and cod > 0) and type(sender) == "string" then
			local gold = floor(money / COPPER)
			local line
			local id = SubjectLine(subject)
			if id then
				line = LineById(id)
				if line and (line.paid or not SameName(line.to, me) or not SameName(line.from, sender) or gold < line.amount) then
					line = nil
				end
			else
				line = LineCovered(sender, me, gold)
			end
			if line and not private.seenInbox[line.id] then
				private.seenInbox[line.id] = true
				if Gold:MarkPaid(line.id, "mail") then
					Wanted:Print("Poker: %s paid you %s.", sender, Money(gold))
				end
			end
		end
	end
end

-- ============================================================================
-- Reputation
-- ============================================================================

-- A debt left unpaid two days after the game counts like a bounty left unpaid; one paid, like a bounty paid
function private.Tally(origin, tally, since, weights)
	for _, l in ipairs(Poker.db.ledger) do
		if SameName(l.from, origin) and (l.at or 0) >= since then
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
