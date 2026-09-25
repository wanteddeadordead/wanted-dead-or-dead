-- Wanted: the "Your record" panel, one per role: how far other players can trust you as a poster (on Your
-- bounties) or as a hunter (on Your hunts), your numbers, what the level means, how to improve it, and a key
-- to every level for that role.

local _, Wanted = ...
local TrustPanel = {}
Wanted.TrustPanel = TrustPanel
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Reputation = Wanted.Reputation
local CARD_HEIGHT = 196

local KEYS = {
	poster = {
		{ "Trusted", C.green, "Five or more claims paid, none left unpaid." },
		{ "Reliable", C.green, "Every claim owed so far paid." },
		{ "New poster", C.muted, "No claim on your bounties has come due yet." },
		{ "Doubtful", C.amber, "Some claims unpaid, though more paid than not." },
		{ "Untrustworthy", C.red, "As many claims unpaid as paid, or more." },
	},
	hunter = {
		{ "Trusted", C.green, "Five or more kills verified, none disputed." },
		{ "Reliable", C.green, "Verified kills, none disputed." },
		{ "Unproven", C.muted, "No kill verified by a witness or the poster yet." },
		{ "Doubtful", C.amber, "Some claims disputed, though most were verified." },
		{ "Untrustworthy", C.red, "As many claims disputed as verified, or more." },
	},
}

---Builds the panel for a role at the given offset from the top of the page.
---@param parent table the page container
---@param top number offset from the top
---@param width number
---@param height number the page height
---@param role string "poster" or "hunter"
---@param onOwe function? poster only: shows what's owed (a button appears when claims are unpaid)
---@return table panel with :Refresh()
function TrustPanel:Create(parent, top, width, height, role, onOwe)
	local panel = CreateFrame("Frame", nil, parent)
	panel:SetPoint("TOPLEFT", 0, -top)
	panel:SetSize(width, height - top)

	local card = W:Card(panel)
	card:SetPoint("TOPLEFT")
	card:SetSize(width, CARD_HEIGHT)
	local label = W:SectionLabel(card, role == "poster" and "Your trust as a poster" or "Your trust as a hunter")
	label:SetPoint("TOPLEFT", 16, -14)
	card.level = Theme:Text(card, "stat", "")
	card.level:SetPoint("TOPLEFT", 16, -34)
	card.detail = Theme:Text(card, "small", "", C.muted)
	card.detail:SetPoint("TOPLEFT", 16, -64)
	card.detail:SetPoint("RIGHT", -16, 0)
	card.detail:SetWordWrap(true)
	card.meaning = Theme:Text(card, "small", "", C.text)
	card.meaning:SetPoint("TOPLEFT", card.detail, "BOTTOMLEFT", 0, -10)
	card.meaning:SetPoint("RIGHT", -16, 0)
	card.meaning:SetWordWrap(true)
	card.adviceLabel = Theme:Text(card, "tiny", "", C.faint)
	card.adviceLabel:SetPoint("TOPLEFT", card.meaning, "BOTTOMLEFT", 0, -12)
	card.advice = Theme:Text(card, "small", "", C.text)
	card.advice:SetPoint("TOPLEFT", card.adviceLabel, "BOTTOMLEFT", 0, -4)
	card.advice:SetPoint("RIGHT", -16, 0)
	card.advice:SetWordWrap(true)
	local oweButton
	if onOwe then
		oweButton = W:Button(card, "Show what you owe", "primary", 150, 26, onOwe)
		oweButton:SetPoint("TOPRIGHT", -16, -36)
	end

	local key = W:Card(panel)
	key:SetPoint("TOPLEFT", 0, -CARD_HEIGHT - 12)
	key:SetPoint("BOTTOMRIGHT")
	local keyLabel = W:SectionLabel(key, "What the trust levels mean")
	keyLabel:SetPoint("TOPLEFT", 16, -14)
	local note = Theme:Text(key, "tiny", "Shown to other players on your "..(role == "poster" and "bounties" or "claims")..". From records only.", C.faint)
	note:SetPoint("TOPRIGHT", -16, -15)
	for i, entry in ipairs(KEYS[role]) do
		local name = Theme:Text(key, "body", entry[1], entry[2])
		name:SetPoint("TOPLEFT", 16, -36 - (i - 1) * 20)
		local text = Theme:Text(key, "small", entry[3], C.muted)
		text:SetPoint("TOPLEFT", 150, -38 - (i - 1) * 20)
	end

	function panel:Refresh()
		local tally = Reputation:GetTally(Wanted.Store:GetOrigin())
		local level, color, detail, meaning, advice
		if role == "poster" then
			level, color, detail = Reputation:GetPosterTrust(tally)
			meaning, advice = Reputation:GetPosterAdvice(tally)
		else
			level, color, detail = Reputation:GetHunterTrust(tally)
			meaning, advice = Reputation:GetHunterAdvice(tally)
		end
		card.level:SetText(level or "No record yet")
		local c = color or C.muted
		card.level:SetTextColor(c[1], c[2], c[3])
		card.detail:SetText(detail or "")
		card.meaning:SetText(meaning or "")
		card.adviceLabel:SetText(level == "Trusted" and "HOW TO STAY THERE" or "HOW TO IMPROVE")
		card.advice:SetText(advice or "")
		if oweButton then
			oweButton:SetShown(tally.unpaid > 0)
		end
	end
	panel:Hide()
	return panel
end
