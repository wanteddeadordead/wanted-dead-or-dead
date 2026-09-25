-- Wanted: payments. The honour system made visible: a poster pays a hunter by mail, prefilled by the
-- addon and sent by the poster's own click (this client confirms mail money through its secure transfer
-- prompt, so an addon could not send it anyway). The poster's client records the send, the hunter's
-- client records the arrival, and the two records merge into "paid". Unpaid is computed from the
-- records: a witnessed or confirmed claim with no payment after 48 hours.

local _, Wanted = ...
local Payments = Wanted:NewModule("Payments")
local Store = Wanted.Store
local Bounties = Wanted.Bounties
local private = {
	frame = CreateFrame("Frame"),
	pendingSend = nil, -- { claimId, recipient, amount } between SendMail and MAIL_SEND_SUCCESS
	seenInbox = {}, -- claim id -> true once recorded from the inbox
}
local SUBJECT_PREFIX = "Wanted bounty "
local UNPAID_AFTER_SECONDS = 48 * 60 * 60



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Payments:OnEnable()
	private.frame:RegisterEvent("MAIL_SEND_SUCCESS")
	private.frame:RegisterEvent("MAIL_INBOX_UPDATE")
	private.frame:SetScript("OnEvent", private.OnEvent)
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

function private.OnEvent(_, event)
	if event == "MAIL_SEND_SUCCESS" then
		private.OnSendSuccess()
	elseif event == "MAIL_INBOX_UPDATE" then
		private.ScanInbox()
	end
end



-- ============================================================================
-- Queries
-- ============================================================================

---The payment record for a claim, from either side, if any.
---@param claimId string
---@return table?
function Payments:GetForClaim(claimId)
	for payment in Store:Iterator("payment") do
		if payment.data.claim == claimId then
			return payment
		end
	end
	return nil
end

---Whether a claim is overdue: witnessed or confirmed, older than 48 hours, and not paid.
---@param claim table
---@return boolean
function Payments:IsUnpaid(claim)
	if Payments:GetForClaim(claim.id) then
		return false
	end
	local level = Bounties:GetClaimLevel(claim)
	if level < 2 then
		return false
	end
	-- Only the claim the bounty goes to can be owed: one the poster confirmed, or the earliest kill
	if level ~= 3 then
		local bounty = Store:Get(claim.data.bounty)
		local winner = bounty and Bounties:GetWinningClaim(bounty)
		if not winner or winner.id ~= claim.id then
			return false
		end
	end
	return GetServerTime() - claim.t > UNPAID_AFTER_SECONDS
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
	local amount = Bounties:GetAmount(bounty)
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
	local claimId = subject and strmatch(subject, "^"..SUBJECT_PREFIX.."(%S+)")
	if not claimId then
		return
	end
	local amount = (GetSendMailMoney and GetSendMailMoney()) or (MoneyInputFrame_GetCopper and MoneyInputFrame_GetCopper(SendMailMoney)) or 0
	private.pendingSend = { claimId = claimId, recipient = recipient, amount = amount }
	Wanted:Log("Payments: sending %s to %s for claim %s", Bounties:FormatMoney(amount), tostring(recipient), claimId)
end

function private.OnSendSuccess()
	local pending = private.pendingSend
	private.pendingSend = nil
	if not pending then
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
	for i = 1, numItems do
		local _, _, sender, subject, money = GetInboxHeaderInfo(i)
		local claimId = subject and strmatch(subject, "^"..SUBJECT_PREFIX.."(%S+)")
		if claimId and money and money > 0 and not private.seenInbox[claimId] then
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
			local amount = Bounties:FormatMoney(Bounties:GetAmount(bounty))
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
