-- Wanted: the player's own business. What they owe and are owed at a glance, the bounties they posted
-- (with the decisions waiting on them first), their history, and their own record:
-- how far other players can trust them as a poster and as a hunter, what that means, and how to improve it.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Model = Wanted.Model
local Rows = Wanted.Rows
local Reputation = Wanted.Reputation
local private = { view = "posted" }
local TRUST_KEY = {
	{ "Trusted", C.green, "Hunter: 5+ verified kills, none disputed.  Poster: 5+ claims paid, none unpaid." },
	{ "Reliable", C.green, "Hunter: verified kills, none disputed.  Poster: every claim owed so far paid." },
	{ "Unproven / New", C.muted, "Hunter: no kill verified yet.  Poster: no claim has come due yet." },
	{ "Doubtful", C.amber, "Hunter: some claims disputed.  Poster: some claims unpaid, more paid." },
	{ "Untrustworthy", C.red, "Hunter: as many disputed as verified.  Poster: as many unpaid as paid." },
}

---One side of the record: the trust level in its colour, the numbers, what it means and what to do.
function private.BuildTrustCard(parent, title, width, height)
	local card = W:Card(parent)
	card:SetSize(width, height)
	local label = W:SectionLabel(card, title)
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
	card.adviceLabel = Theme:Text(card, "tiny", "HOW TO IMPROVE", C.faint)
	card.adviceLabel:SetPoint("TOPLEFT", card.meaning, "BOTTOMLEFT", 0, -12)
	card.advice = Theme:Text(card, "small", "", C.text)
	card.advice:SetPoint("TOPLEFT", card.adviceLabel, "BOTTOMLEFT", 0, -4)
	card.advice:SetPoint("RIGHT", -16, 0)
	card.advice:SetWordWrap(true)
	return card
end

function private.FillTrustCard(card, label, color, detail, meaning, advice, isTop)
	card.level:SetText(label or "No record yet")
	local c = color or C.muted
	card.level:SetTextColor(c[1], c[2], c[3])
	card.detail:SetText(detail or "")
	card.meaning:SetText(meaning or "")
	card.advice:SetText(advice or "")
	card.adviceLabel:SetText(isTop and "HOW TO STAY THERE" or "HOW TO IMPROVE")
end

function private.BuildRecord(container, width, height)
	local panel = CreateFrame("Frame", nil, container)
	panel:SetPoint("TOPLEFT", 0, -122)
	panel:SetSize(width, height - 122)
	local cardWidth = floor((width - 12) / 2)
	local cardHeight = 220
	private.posterCard = private.BuildTrustCard(panel, "Your trust as a poster", cardWidth, cardHeight)
	private.posterCard:SetPoint("TOPLEFT")
	private.hunterCard = private.BuildTrustCard(panel, "Your trust as a hunter", cardWidth, cardHeight)
	private.hunterCard:SetPoint("TOPRIGHT")
	private.payButton = W:Button(private.posterCard, "Show what you owe", "primary", 150, 26, function()
		private.segment:Select("posted")
	end)
	private.payButton:SetPoint("TOPRIGHT", -16, -36)

	local key = W:Card(panel)
	key:SetPoint("TOPLEFT", 0, -cardHeight - 12)
	key:SetPoint("BOTTOMRIGHT")
	local keyLabel = W:SectionLabel(key, "What the trust levels mean")
	keyLabel:SetPoint("TOPLEFT", 16, -14)
	local note = Theme:Text(key, "tiny", "Shown to others on your bounties and claims. From records only.", C.faint)
	note:SetPoint("TOPRIGHT", -16, -15)
	for i, entry in ipairs(TRUST_KEY) do
		local name = Theme:Text(key, "body", entry[1], entry[2])
		name:SetPoint("TOPLEFT", 16, -34 - (i - 1) * 18)
		local text = Theme:Text(key, "small", entry[3], C.muted)
		text:SetPoint("TOPLEFT", 150, -36 - (i - 1) * 18)
	end
	private.record = panel
end

function private.RefreshRecord()
	local tally = Reputation:GetTally(Wanted.Store:GetOrigin())
	local label, color, detail = Reputation:GetPosterTrust(tally)
	local meaning, advice = Reputation:GetPosterAdvice(tally)
	private.FillTrustCard(private.posterCard, label, color, detail, meaning, advice, label == "Trusted")
	private.payButton:SetShown(tally.unpaid > 0)
	label, color, detail = Reputation:GetHunterTrust(tally)
	meaning, advice = Reputation:GetHunterAdvice(tally)
	private.FillTrustCard(private.hunterCard, label, color, detail, meaning, advice, label == "Trusted")
end

function private.Refresh()
	if not private.list then
		return
	end
	local summary = Model:GetMySummary()
	private.oweTile.value:SetText(Theme:Money(summary.owe))
	private.oweTile.note:SetText(summary.oweCount > 0 and format("%d to pay", summary.oweCount) or "all settled")
	private.owedTile.value:SetText(Theme:Money(summary.owed))
	private.owedTile.note:SetText(summary.owedCount > 0 and format("%d claim%s", summary.owedCount, summary.owedCount == 1 and "" or "s") or "")
	private.openTile.value:SetText(Theme:Money(summary.open))
	private.openTile.note:SetText(format("%d open%s", summary.openCount, summary.decide > 0 and format(", %d to decide", summary.decide) or ""))
	local showRecord = private.view == "record"
	private.record:SetShown(showRecord)
	private.list:SetShown(not showRecord)
	if showRecord then
		private.RefreshRecord()
	elseif private.view == "posted" then
		private.list:SetItems(Model:GetMyBounties(), "No live bounties.", "Post one from the Board. Finished ones are under History.")
	else
		private.list:SetItems(Model:GetMyHistory(), "Nothing finished yet.", "Paid, expired and withdrawn bounties, and finished claims, end up here.")
	end
end

UI:RegisterPage("mine", {
	title = "Your bounties",
	subtitle = "Your live bounties, what you owe and are owed. Finished bounties and claims move to History.",
	order = 2,
	badge = function() return Model:GetActionCount() end,
	build = function(container, width, height)
		local tileWidth = floor((width - 24) / 3)
		private.oweTile = W:StatTile(container, "You owe", C.red)
		private.oweTile:SetPoint("TOPLEFT")
		private.oweTile:SetWidth(tileWidth)
		private.owedTile = W:StatTile(container, "Owed to you", C.green)
		private.owedTile:SetPoint("LEFT", private.oweTile, "RIGHT", 12, 0)
		private.owedTile:SetWidth(tileWidth)
		private.openTile = W:StatTile(container, "Your open bounties", C.blue)
		private.openTile:SetPoint("LEFT", private.owedTile, "RIGHT", 12, 0)
		private.openTile:SetWidth(tileWidth)

		local segment = W:Segmented(container, {
			{ key = "posted", label = "Your live bounties" },
			{ key = "history", label = "History" },
			{ key = "record", label = "Your record" },
		}, function(key)
			private.view = key
			private.Refresh()
		end, 170)
		segment:SetPoint("TOPLEFT", 0, -84)
		segment:Select("posted", true)
		private.segment = segment

		local listTop = 122
		local numRows = floor((height - listTop) / Rows.HEIGHT)
		-- Bounty infos carry a state; claim items carry a label (history mixes both)
		local list = W:List(container, Rows.HEIGHT, numRows, function(row) Rows:Create(row) end, function(row, item)
			if item.state then
				Rows:UpdateBounty(row, item)
			else
				Rows:UpdateClaim(row, item)
			end
		end)
		list.onClick = function(item)
			if item.state then
				Wanted.TargetFile:ShowBounty(item)
			end
		end
		list.onEnter = function(row, item)
			if item.state then
				Rows:ShowBountyTooltip(row, item)
			end
		end
		list:SetPoint("TOPLEFT", 0, -listTop)
		list:SetPoint("TOPRIGHT", 0, -listTop)
		private.list = list
		private.BuildRecord(container, width, height)
	end,
	refresh = private.Refresh,
})

---Opens Your bounties on the Your record tab.
Wanted.MinePage = {}
function Wanted.MinePage:ShowRecord()
	UI:Show("mine")
	if private.segment then
		private.segment:Select("record")
	end
end

Wanted:RegisterCommand("record", "Your record: how far other players can trust you as a poster and a hunter, and how to improve it.", function()
	Wanted.MinePage:ShowRecord()
end)
