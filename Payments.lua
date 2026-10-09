-- Wanted: payments. The honour system made visible: a poster pays a hunter by mail, prefilled by the
-- addon and sent by the poster's own click (this client confirms mail money through its secure transfer
-- prompt, so an addon could not send it anyway). The poster's client records the send, the hunter's
-- client records the arrival, and the two records merge into "paid". A mail without Wanted's subject counts
-- when it carries at least the bounty between the poster and the hunter. A send another mail addon makes without
-- the SendMail hook seeing it (TSM) is recorded by the hunter's side when it arrives. Cash on delivery never counts.
-- Unpaid is computed from the records: a witnessed or confirmed claim with no payment after 48 hours.

local _, Wanted = ...
local Payments = Wanted:NewModule("Payments")
local Store = Wanted.Store
local Bounties = Wanted.Bounties
local private = {
	frame = CreateFrame("Frame"),
	pendingSend = nil, -- { claimId, recipient, amount, at, closedAt } between SendMail and MAIL_SEND_SUCCESS (or MAIL_FAILED)
	seenInbox = {}, -- claim id -> true once recorded from the inbox
}
local SUBJECT_PREFIX = "Wanted bounty "
local UNPAID_AFTER_SECONDS = 48 * 60 * 60
-- How long the game may take to say our send went through (or failed), and to say so after the mailbox closed
local SEND_ANSWER_SECONDS = 30
local CLOSE_GRACE_SECONDS = 10



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Payments:OnEnable()
	private.frame:RegisterEvent("MAIL_SEND_SUCCESS")
	private.frame:RegisterEvent("MAIL_FAILED")
	private.frame:RegisterEvent("MAIL_CLOSED")
	private.frame:RegisterEvent("MAIL_INBOX_UPDATE")
	private.frame:SetScript("OnEvent", Wanted:Timed("Payments events", private.OnEvent))
	-- If another addon replaced the SendMail global with a wrapper that calls the original, this hook lands on
	-- the wrapper and still runs for every send
	hooksecurefunc("SendMail", private.OnSendMail)
end

function Payments:Status()
	local paid, unpaid = 0, 0
	for claim in Store:Iterator("claim") do
		if Payments:GetForClaim(claim.id) then
			paid = paid + 1
		elseif Payments:IsUnpaid(claim) then
			unpaid = unpaid + 1
		end
	end
	return format("Payments: %d claims paid, %d overdue.", paid, unpaid)
end

function private.OnEvent(_, event, ...)
	if event == "MAIL_SEND_SUCCESS" then
		private.OnSendSuccess()
	elseif event == "MAIL_FAILED" then
		-- The game says this for taking an item from a mail too (it names the item): only a failure of our send, soon
		-- after it, clears what was waiting to go
		local itemID = ...
		local pending = private.pendingSend
		if pending and itemID == nil and GetTime() - pending.at <= SEND_ANSWER_SECONDS then
			private.pendingSend = nil
		end
	elseif event == "MAIL_CLOSED" then
		-- A send can still be on its way when the mailbox closes: it counts if the game says so soon after
		if private.pendingSend then
			private.pendingSend.closedAt = private.pendingSend.closedAt or GetTime()
		end
	elseif event == "MAIL_INBOX_UPDATE" then
		private.ScanInbox()
	end
end



-- ============================================================================
-- Queries
-- ============================================================================

---The payment record for a claim, from either side, if any: one that went between the claim's poster and hunter with
---at least what's owed (Pays). The poster's own record first.
---A hunter's own record of being paid only counts for the claim the bounty goes to without it (the poster's paid or
---confirmed claim, or the earliest witnessed kill): otherwise a hunter could make their own claim the paid one.
---@param claimId string
---@param posterOnly boolean? only the poster's own record of paying (what picks the bounty's claim)
---@return table?
function Payments:GetForClaim(claimId, posterOnly)
	local claim, payee
	for payment in Store:Iterator("payment") do
		local paid = payment.data.claim
		-- Addon 1.10.0 and older read the claim id from the mail subject only up to its first space, so a payment
		-- for "Mhureth Theolia:7515" says "Mhureth": it pays that claim too, if it came after it
		local legacy = type(paid) == "string" and not strfind(paid, ":", 1, true)
		if paid == claimId or legacy then
			Wanted.Verify:Want(payment, true)
			claim = claim or Store:Get(claimId) or false
			if claim and private.Pays(payment, claim, legacy) then
				if payment.data.side == "payer" then
					return payment
				end
				payee = payee or payment
			end
		end
	end
	if payee and not posterOnly then
		local bounty = Store:Get(claim.data.bounty)
		if Bounties:GetClaimLevel(claim) == 3 or (bounty and Bounties:GetWinningClaim(bounty) == claim) then
			return payee
		end
	end
	return nil
end

---Whether a payment record pays a claim: at least what's owed, and between the claim's poster and hunter: the poster's
---record of a mail to the hunter, or the hunter's of a mail from the poster. A legacy one names the hunter's first
---name and came after the claim.
function private.Pays(payment, claim, legacy)
	local bounty = Store:Get(claim.data.bounty)
	if not bounty or (tonumber(payment.data.amount) or 0) < Bounties:GetOwed(claim) then
		return false
	end
	if legacy and (payment.data.claim ~= strmatch(claim.origin or "", "^(%S+)") or payment.t < claim.t) then
		return false
	end
	if payment.data.side == "payer" then
		return payment.origin == bounty.origin and private.SameName(payment.data.to, claim.origin)
	end
	return payment.data.side == "payee" and payment.origin == claim.origin and private.SameName(payment.data.from, bounty.origin)
end

---The claim id in a Wanted payment mail's subject ("Wanted bounty Mhureth Theolia:7515"), or nil. Ids hold a space.
function private.SubjectClaim(subject)
	local claimId = type(subject) == "string" and strmatch(subject, "^"..SUBJECT_PREFIX.."(.-)%s*$")
	return claimId ~= "" and claimId or nil
end

---Whether a claim is the one its bounty is paid to and not paid yet: witnessed or confirmed, and the bounty's claim
---(Bounties:GetWinningClaim: the poster's paid or confirmed claim, else the earliest witnessed kill).
---@param claim table
---@return boolean
function private.Payable(claim)
	if Payments:GetForClaim(claim.id) or Bounties:GetClaimLevel(claim) < 2 then
		return false
	end
	local bounty = Store:Get(claim.data.bounty)
	local winner = bounty and Bounties:GetWinningClaim(bounty)
	return winner ~= nil and winner.id == claim.id
end

---A name as mail and records compare it: lower case, no realm.
function private.SameName(a, b)
	if type(a) ~= "string" or type(b) ~= "string" then
		return false
	end
	return strlower((gsub(a, "%-.*$", ""))) == strlower((gsub(b, "%-.*$", "")))
end

---The payable claim between a poster and a hunter that an amount covers, or nil: for a mail without Wanted's subject.
---@param poster string the poster's name (an origin)
---@param hunter string the hunter's name (an origin)
---@param amount number copper
---@return table?
function private.ClaimCovered(poster, hunter, amount)
	for claim in Store:Iterator("claim") do
		if private.Covers(claim, poster, hunter, amount) and private.Payable(claim) then
			return claim
		end
	end
	return nil
end

---Whether a mail between two players with an amount covers a claim: from its bounty's poster to its hunter, with at
---least what the claim is owed.
function private.Covers(claim, poster, hunter, amount)
	local bounty = Store:Get(claim.data.bounty)
	return bounty ~= nil and private.SameName(bounty.origin, poster) and private.SameName(claim.origin, hunter)
		and amount >= Bounties:GetOwed(claim)
end

---Whether a claim is overdue: witnessed or confirmed, older than 48 hours, and not paid.
---@param claim table
---@return boolean
function Payments:IsUnpaid(claim)
	-- Only the claim the bounty goes to can be owed (Payable), so a bounty is never owed twice
	return private.Payable(claim) and GetServerTime() - claim.t > UNPAID_AFTER_SECONDS
end



-- ============================================================================
-- Paying
-- ============================================================================

---Prefills the send mail form for a claim. The poster presses Send.
---@param claim table
---@return boolean ok
---@return string? err
function Payments:Prefill(claim)
	if not MailFrame or not MailFrame:IsShown() then
		return false, "open a mailbox first"
	end
	local bounty = Store:Get(claim.data.bounty)
	if not bounty then
		return false, "the bounty is missing"
	end
	local amount = Bounties:GetOwed(claim)
	MailFrameTab_OnClick(nil, 2)
	SendMailNameEditBox:SetText(claim.origin)
	SendMailSubjectEditBox:SetText(SUBJECT_PREFIX..claim.id)
	SendMailBodyEditBox:SetText(format("Bounty on %s. Thanks for the hunt.", claim.data.victimName or "?"))
	MoneyInputFrame_SetCopper(SendMailMoney, amount)
	if SendMailSendMoneyButton then
		SendMailSendMoneyButton:SetChecked(true)
	end
	if SendMailCODButton then
		SendMailCODButton:SetChecked(false)
	end
	Wanted:Log("Payments: prefilled %s to %s for claim %s", Bounties:FormatMoney(amount), claim.origin, claim.id)
	return true
end

function private.OnSendMail(recipient, subject)
	private.pendingSend = nil
	local amount = (GetSendMailMoney and GetSendMailMoney()) or (MoneyInputFrame_GetCopper and MoneyInputFrame_GetCopper(SendMailMoney)) or 0
	-- Cash on delivery takes money from the hunter: never a payment
	if (GetSendMailCOD and (GetSendMailCOD() or 0) > 0) or type(amount) ~= "number" or amount <= 0 then
		return
	end
	local claimId = private.SubjectClaim(subject)
	if claimId then
		-- Wanted's subject: a claim on one of our bounties, to its hunter, with at least the bounty
		local claim = Store:Get(claimId)
		if not claim or claim.kind ~= "claim" or not private.Covers(claim, Store:GetOrigin(), recipient, amount) then
			return
		end
	else
		-- Written by hand: a mail to a hunter we owe, with at least what we owe them
		local claim = private.ClaimCovered(Store:GetOrigin(), recipient, amount)
		claimId = claim and claim.id
	end
	if not claimId then
		return
	end
	private.pendingSend = { claimId = claimId, recipient = recipient, amount = amount, at = GetTime() }
	Wanted:Log("Payments: sending %s to %s for claim %s", Bounties:FormatMoney(amount), tostring(recipient), claimId)
end

function private.OnSendSuccess()
	local pending = private.pendingSend
	private.pendingSend = nil
	-- A success long after our send, or after the mailbox closed, is some other mail's
	if not pending or GetTime() - pending.at > SEND_ANSWER_SECONDS
		or (pending.closedAt and GetTime() - pending.closedAt > CLOSE_GRACE_SECONDS) or Payments:GetForClaim(pending.claimId) then
		return
	end
	local claim = Store:Get(pending.claimId)
	Store:NewRecord("payment", {
		claim = pending.claimId,
		bounty = claim and claim.data.bounty or nil,
		to = pending.recipient,
		amount = pending.amount,
		side = "payer",
	})
	Wanted:Print("Paid %s to %s for claim %s.", Bounties:FormatMoney(pending.amount), pending.recipient, pending.claimId)
end



-- ============================================================================
-- Receiving
-- ============================================================================

function private.ScanInbox()
	local numItems = GetInboxNumItems()
	local me = Store:GetOrigin()
	for i = 1, numItems do
		local _, _, sender, subject, money, cod = GetInboxHeaderInfo(i)
		local claimId = private.SubjectClaim(subject)
		if type(money) ~= "number" or money <= 0 or (type(cod) == "number" and cod > 0) then
			claimId = nil
		elseif claimId then
			-- Wanted's subject: our own claim, from its bounty's poster, with at least the bounty
			local claim = Store:Get(claimId)
			if not claim or claim.kind ~= "claim" or claim.origin ~= me or not private.Covers(claim, sender, me, money) then
				claimId = nil
			end
		else
			-- Written by hand: a mail from a poster whose bounty we're owed, with at least the bounty
			local claim = private.ClaimCovered(sender, me, money)
			claimId = claim and claim.id
		end
		if claimId and not private.seenInbox[claimId] then
			private.seenInbox[claimId] = true
			local claim = Store:Get(claimId)
			local alreadyMine = false
			for payment in Store:Iterator("payment") do
				if payment.data.claim == claimId and payment.origin == Store:GetOrigin() then
					alreadyMine = true
					break
				end
			end
			if not alreadyMine then
				Store:NewRecord("payment", {
					claim = claimId,
					bounty = claim and claim.data.bounty or nil,
					from = sender,
					amount = money,
					side = "payee",
				})
				Wanted:Print("Bounty payment received: %s from %s for claim %s.", Bounties:FormatMoney(money), tostring(sender), claimId)
			end
		end
	end
end



-- ============================================================================
-- Commands
-- ============================================================================

Wanted:RegisterCommand("pay", "Prefills a mail paying a claim on your bounty: /wanted pay <claim id> (at a mailbox).", function(args)
	local claim = Store:Get(strtrim(args or ""))
	local bounty = claim and claim.kind == "claim" and Store:Get(claim.data.bounty)
	if not bounty or bounty.origin ~= Store:GetOrigin() then
		Wanted:Print("That is not a claim on one of your bounties.")
		return
	end
	if Payments:GetForClaim(claim.id) then
		Wanted:Print("That claim is already paid.")
		return
	end
	local ok, err = Payments:Prefill(claim)
	if not ok then
		Wanted:Print("Cannot prefill: %s.", err)
		return
	end
	Wanted:Print("Mail prefilled for %s. Check it and press Send.", claim.origin)
end)

Wanted:RegisterCommand("owed", "Lists what you owe and what you are owed.", function()
	local me = Store:GetOrigin()
	local shown = 0
	for claim in Store:Iterator("claim") do
		local bounty = Store:Get(claim.data.bounty)
		if bounty and (bounty.origin == me or claim.origin == me) and Bounties:GetClaimLevel(claim) >= 2 then
			local payment = Payments:GetForClaim(claim.id)
			local amount = Bounties:FormatMoney(Bounties:GetOwed(claim))
			if bounty.origin == me then
				Wanted:Print("You owe %s to %s for %s: %s%s", amount, claim.origin, claim.data.victimName or "?", payment and "paid" or "unpaid", not payment and (" - /wanted pay "..claim.id) or "")
			else
				Wanted:Print("%s owes you %s for %s: %s", bounty.origin, amount, claim.data.victimName or "?", payment and "paid" or (Payments:IsUnpaid(claim) and "overdue" or "pending"))
			end
			shown = shown + 1
		end
	end
	if shown == 0 then
		Wanted:Print("Nothing owed either way.")
	end
end)
