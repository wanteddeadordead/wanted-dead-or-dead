-- Wanted: reputation from records only. Nobody types an opinion into it: posters are judged by what
-- they posted and paid, hunters by claims witnessed, confirmed or disputed and by gold collected. The
-- weights live in the table below so they can be tuned without touching the logic.

local _, Wanted = ...
local Reputation = Wanted:NewModule("Reputation")
local Store = Wanted.Store
local Bounties = Wanted.Bounties
local Payments = Wanted.Payments
local private = {
	frame = CreateFrame("Frame"),
	whispered = {}, -- sender -> true once told about this session
}
-- Rank points per event; a level is every RANK_POINTS_PER_LEVEL points
local WEIGHTS = {
	claimWitnessed = 10, -- level 2
	claimConfirmed = 8, -- level 3 without a witness
	claimLone = 2, -- level 1, never confirmed
	claimDisputed = -15,
	bountyPaid = 4, -- as a poster
	bountyUnpaid = -20,
}
local RANK_POINTS_PER_LEVEL = 20
local TRUSTED_AT = 5 -- verified kills (hunter) or paid claims (poster) with a clean record to be Trusted
local DECAY_DAYS = 90



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Reputation:OnEnable()
	if TooltipDataProcessor and Enum and Enum.TooltipDataType then
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, private.OnTooltipUnit)
	end
	private.frame:RegisterEvent("CHAT_MSG_WHISPER")
	private.frame:SetScript("OnEvent", function(_, _, _, sender)
		if sender and not private.whispered[sender] then
			private.whispered[sender] = true
			local line = Reputation:GetLine(sender)
			if line then
				Wanted:Print("%s: %s", sender, line)
			end
		end
	end)
end



-- ============================================================================
-- Tallies
-- ============================================================================

local function Decay(t)
	local age = (GetServerTime() - t) / 86400
	return age >= DECAY_DAYS and 0 or (1 - age / DECAY_DAYS)
end

---Everything the records say about one origin (a character name as the server writes it).
---@param origin string
---@return table tally
function Reputation:GetTally(origin, since)
	since = since or 0
	local tally = {
		posted = 0, paid = 0, unpaid = 0, pending = 0, postedGold = 0, paidGold = 0,
		claims = 0, witnessed = 0, confirmed = 0, lone = 0, disputed = 0, earned = 0,
		points = 0, kills = 0,
	}
	local killsSeen = {}
	for bounty in Store:Iterator("bounty") do
		if bounty.origin == origin and bounty.t >= since then
			tally.posted = tally.posted + 1
			tally.postedGold = tally.postedGold + Bounties:GetAmount(bounty)
		end
	end
	for claim in Store:Iterator("claim") do
		if claim.t < since then
			-- outside the period
		else
		local bounty = Store:Get(claim.data.bounty)
		local level = Bounties:GetClaimLevel(claim)
		local payment = Payments:GetForClaim(claim.id)
		local decay = Decay(claim.t)
		if claim.origin == origin then
			tally.claims = tally.claims + 1
			-- One kill can claim several bounties on the same target; count it once
			local killKey = claim.data.deathId or claim.data.kill or claim.id
			if level > 0 and not killsSeen[killKey] then
				killsSeen[killKey] = true
				tally.kills = tally.kills + 1
			end
			if level == 0 then
				tally.disputed = tally.disputed + 1
				tally.points = tally.points + WEIGHTS.claimDisputed * decay
			elseif level == 2 then
				tally.witnessed = tally.witnessed + 1
				tally.points = tally.points + WEIGHTS.claimWitnessed * decay
			elseif level == 3 then
				tally.confirmed = tally.confirmed + 1
				tally.points = tally.points + WEIGHTS.claimConfirmed * decay
			else
				tally.lone = tally.lone + 1
				tally.points = tally.points + WEIGHTS.claimLone * decay
			end
			if payment then
				tally.earned = tally.earned + (payment.data.amount or 0)
			end
		end
		if bounty and bounty.origin == origin and level >= 2 then
			if payment then
				tally.paid = tally.paid + 1
				tally.paidGold = tally.paidGold + (payment.data.amount or 0)
				tally.points = tally.points + WEIGHTS.bountyPaid * decay
			elseif Payments:IsUnpaid(claim) then
				tally.unpaid = tally.unpaid + 1
				tally.points = tally.points + WEIGHTS.bountyUnpaid * decay
			else
				tally.pending = tally.pending + 1
			end
		end
		end
	end
	return tally
end

---Hunter rank from points: level and stars (reliability).
---@param tally table
---@return number level
---@return number stars 0-5
function Reputation:GetRank(tally)
	local level = max(floor(tally.points / RANK_POINTS_PER_LEVEL), 0)
	local decided = tally.witnessed + tally.confirmed + tally.disputed
	local stars = 0
	if decided > 0 then
		stars = floor(5 * (tally.witnessed + tally.confirmed) / decided + 0.5)
	end
	return level, stars
end

---One line summing a player up, or nil if the records say nothing about them.
---@param origin string
---@return string?
function Reputation:GetLine(origin)
	local tally = Reputation:GetTally(origin)
	if tally.posted == 0 and tally.claims == 0 then
		return nil
	end
	local parts = {}
	local posterTrust = Reputation:GetPosterTrust(tally)
	local hunterTrust = Reputation:GetHunterTrust(tally)
	if posterTrust then
		tinsert(parts, "as a poster: "..posterTrust)
	end
	if hunterTrust then
		tinsert(parts, "as a hunter: "..hunterTrust)
	end
	if tally.posted > 0 then
		local poster = format("posted %d, paid %d", tally.posted, tally.paid)
		if tally.unpaid > 0 then
			poster = poster..format(", %d UNPAID", tally.unpaid)
		end
		tinsert(parts, poster)
	end
	if tally.claims > 0 then
		local level, stars = Reputation:GetRank(tally)
		tinsert(parts, format("hunter level %d %s, %d kills, earned %s", level, strrep("*", stars)..strrep("-", 5 - stars), tally.kills, Bounties:FormatMoney(tally.earned)))
		if tally.disputed > 0 then
			tinsert(parts, format("%d disputed", tally.disputed))
		end
	end
	return table.concat(parts, "; ")
end

---How far to trust a hunter's claims, from how many were verified and how many were disputed.
---@param tally table
---@return string? label nil when they've never claimed
---@return table? color
---@return string? detail
function Reputation:GetHunterTrust(tally)
	if tally.claims == 0 then
		return nil
	end
	local C = Wanted.Theme.C
	local good = tally.witnessed + tally.confirmed
	local level, stars = Reputation:GetRank(tally)
	local detail = format("Level %d. %d of %d kill%s verified, %d unseen, %d disputed.", level, good, tally.claims, tally.claims == 1 and "" or "s", tally.lone, tally.disputed)
	if tally.earned > 0 then
		detail = detail.." Earned "..Bounties:FormatMoney(tally.earned).."."
	end
	if good + tally.disputed == 0 then
		return "Unproven", C.muted, detail
	elseif stars <= 2 then
		return "Untrustworthy", C.red, detail
	elseif tally.disputed > 0 then
		return "Doubtful", C.amber, detail
	elseif good >= TRUSTED_AT then
		return "Trusted", C.green, detail
	end
	return "Reliable", C.green, detail
end

---How far to trust a poster to pay, from claims paid against claims left unpaid.
---@param tally table
---@return string? label nil when they've never posted
---@return table? color
---@return string? detail
function Reputation:GetPosterTrust(tally)
	if tally.posted == 0 then
		return nil
	end
	local C = Wanted.Theme.C
	local detail = format("Paid %d of %d claim%s owed, %d unpaid. %d bount%s posted.", tally.paid, tally.paid + tally.unpaid, tally.paid + tally.unpaid == 1 and "" or "s", tally.unpaid, tally.posted, tally.posted == 1 and "y" or "ies")
	if tally.paid + tally.unpaid == 0 then
		return "New poster", C.muted, detail
	elseif tally.unpaid > 0 and tally.unpaid >= tally.paid then
		return "Untrustworthy", C.red, detail
	elseif tally.unpaid > 0 then
		return "Doubtful", C.amber, detail
	elseif tally.paid >= TRUSTED_AT then
		return "Trusted", C.green, detail
	end
	return "Reliable", C.green, detail
end

local POSTER_MEANING = {
	["Trusted"] = "Hunters can count on you: you've paid every claim you owed, five or more.",
	["Reliable"] = "You've paid every claim you owed so far.",
	["New poster"] = "No claim on your bounties has come due yet, so hunters can't tell whether you pay.",
	["Doubtful"] = "You've left some claims unpaid, though you've paid more than you haven't.",
	["Untrustworthy"] = "You've left as many claims unpaid as you've paid, or more. Hunters may pass on your bounties.",
}
local HUNTER_MEANING = {
	["Trusted"] = "Your kills check out: five or more verified by a witness or the poster, none disputed.",
	["Reliable"] = "Your verified kills check out and none were disputed.",
	["Unproven"] = "Nobody else saw your kills and no poster has confirmed one yet.",
	["Doubtful"] = "Some of your claims were disputed, though most were verified.",
	["Untrustworthy"] = "At least as many of your claims were disputed as verified. Posters may doubt your claims.",
}

---What a player's poster trust means and what to do about it.
---@param tally table
---@return string meaning
---@return string advice
function Reputation:GetPosterAdvice(tally)
	local label = Reputation:GetPosterTrust(tally)
	if not label then
		return "You haven't posted a bounty yet.", "Post one from the Board. Paying the hunters who claim it builds your trust."
	end
	local advice
	if tally.unpaid > 0 then
		advice = format("Pay your %d unpaid claim%s: find %s under Your live bounties and press Pay at a mailbox. A late payment still counts as paid.", tally.unpaid, tally.unpaid == 1 and "" or "s", tally.unpaid == 1 and "it" or "them")
	elseif label == "New poster" then
		advice = "When a hunter claims one of your bounties, confirm a real kill and pay them by mail within 2 days."
	elseif label == "Reliable" then
		local more = TRUSTED_AT - tally.paid
		advice = format("Pay %d more claim%s, with none left unpaid, to become Trusted.", more, more == 1 and "" or "s")
	else
		advice = "Keep paying confirmed claims within 2 days to stay Trusted."
	end
	return POSTER_MEANING[label], advice
end

---What a player's hunter trust means and what to do about it.
---@param tally table
---@return string meaning
---@return string advice
function Reputation:GetHunterAdvice(tally)
	local label = Reputation:GetHunterTrust(tally)
	if not label then
		return "You haven't claimed a bounty yet.", "Pick a bounty on the Board and press Hunt. The claim files itself when you get the kill."
	end
	local good = tally.witnessed + tally.confirmed
	local advice
	if tally.disputed > 0 then
		advice = "Disputes stay on your record, and every verified kill counts in your favour. Hunt where other Wanted users can see the kill, and only claim kills you made."
	elseif label == "Unproven" then
		advice = "A kill is verified when another Wanted user sees it or the poster confirms it. Hunt near other players running Wanted."
	elseif label == "Reliable" then
		local more = TRUSTED_AT - good
		advice = format("%d more verified kill%s, with no disputes, makes you Trusted.", more, more == 1 and "" or "s")
	else
		advice = "Keep claiming only kills you made to stay Trusted."
	end
	return HUNTER_MEANING[label], advice
end

---Adds a trust line and its detail to the game tooltip.
---@param title string "Poster trust" or "Hunter trust"
---@param label string?
---@param color table?
---@param detail string?
function Reputation:AddTrustLines(title, label, color, detail)
	if not label then
		return
	end
	local C = Wanted.Theme.C
	GameTooltip:AddDoubleLine(title, label, 1, 1, 1, color[1], color[2], color[3])
	GameTooltip:AddLine(detail, C.muted[1], C.muted[2], C.muted[3], true)
end

---A few words on a poster's record for a bounty row: red when they've left claims unpaid, green once
---they've paid, nothing for a newcomer.
---@param origin string
---@return string?
function Reputation:GetPosterBadge(origin)
	local tally = Reputation:GetTally(origin)
	local C = Wanted.Theme.C
	if tally.unpaid > 0 then
		return Wanted.Theme:Colorize(format("%d unpaid", tally.unpaid), C.red)
	elseif tally.paid > 0 then
		return Wanted.Theme:Colorize(format("paid %d", tally.paid), C.green)
	end
	return nil
end

---A few words on a hunter's record for a claim: red with disputed claims, green with a level.
---@param origin string
---@return string?
function Reputation:GetHunterBadge(origin)
	local tally = Reputation:GetTally(origin)
	local C = Wanted.Theme.C
	if tally.disputed > 0 then
		return Wanted.Theme:Colorize(format("%d disputed", tally.disputed), C.red)
	elseif tally.claims > 0 then
		local level = Reputation:GetRank(tally)
		return Wanted.Theme:Colorize(format("level %d", level), level > 0 and C.green or C.muted)
	end
	return nil
end

---All origins the records mention as posters or hunters.
---@return string[]
function Reputation:GetOrigins()
	local set = {}
	for bounty in Store:Iterator("bounty") do
		set[bounty.origin] = true
	end
	for claim in Store:Iterator("claim") do
		set[claim.origin] = true
	end
	local list = {}
	for origin in pairs(set) do
		tinsert(list, origin)
	end
	return list
end



-- ============================================================================
-- Tooltip
-- ============================================================================

function private.OnTooltipUnit(tooltip)
	if tooltip ~= GameTooltip or not TooltipUtil or not TooltipUtil.GetDisplayedUnit then
		return
	end
	local _, unit = TooltipUtil.GetDisplayedUnit(tooltip)
	if not unit or not UnitIsPlayer(unit) then
		return
	end
	-- The origin form of a name on this client is "First Last"
	local name, surname = UnitName(unit)
	if issecretvalue and (issecretvalue(name) or issecretvalue(surname)) then
		return
	end
	local origin = (surname and surname ~= "") and (name.." "..surname) or name
	local line = Reputation:GetLine(origin)
	if line then
		tooltip:AddLine("Wanted: "..line, 1, 0.82, 0, true)
	end
	-- Open bounties on this player
	local guid = UnitGUID(unit)
	if guid and not (issecretvalue and issecretvalue(guid)) then
		local total = 0
		for _, bounty in ipairs(Bounties:GetOpenForTarget(guid)) do
			if not Bounties:GetPendingClaim(bounty) then
				total = total + Bounties:GetAmount(bounty)
			end
		end
		if total > 0 then
			tooltip:AddLine("WANTED: "..Bounties:FormatMoney(total).." bounty", 1, 0.2, 0.2, true)
		end
		local guild = Wanted.Recorder:GetUnitGuild(unit)
		local guildTotal = 0
		for _, bounty in ipairs(Bounties:GetOpenForGuild(guild)) do
			guildTotal = guildTotal + Bounties:GetAmount(bounty)
		end
		if guildTotal > 0 then
			tooltip:AddLine("WANTED: "..Bounties:FormatMoney(guildTotal).." on their guild <"..guild..">", 1, 0.45, 0.2, true)
		end
	end
end



-- ============================================================================
-- Commands
-- ============================================================================

Wanted:RegisterCommand("rep", "Shows a player's record: /wanted rep <First Last>.", function(args)
	local origin = strtrim(args or "")
	if origin == "" then
		origin = Store:GetOrigin()
	end
	Wanted:Print("%s: %s", origin, Reputation:GetLine(origin) or "no record")
end)

Wanted:RegisterCommand("top", "Scoreboard: hunters by rank and earnings, posters by bounties paid.", function()
	local hunters, posters = {}, {}
	for _, origin in ipairs(Reputation:GetOrigins()) do
		local tally = Reputation:GetTally(origin)
		if tally.claims > 0 then
			local level, stars = Reputation:GetRank(tally)
			tinsert(hunters, { origin = origin, level = level, stars = stars, earned = tally.earned, kills = tally.kills, points = tally.points })
		end
		if tally.posted > 0 then
			tinsert(posters, { origin = origin, posted = tally.posted, paid = tally.paid, unpaid = tally.unpaid, gold = tally.paidGold })
		end
	end
	sort(hunters, function(a, b) return a.points > b.points end)
	sort(posters, function(a, b) return a.gold > b.gold end)
	Wanted:Print("Top hunters:")
	if #hunters == 0 then
		Wanted:Print("  none yet")
	end
	for i = 1, min(#hunters, 10) do
		local h = hunters[i]
		Wanted:Print("  %d. %s - level %d %s, %d kills, %s earned", i, h.origin, h.level, strrep("*", h.stars)..strrep("-", 5 - h.stars), h.kills, Bounties:FormatMoney(h.earned))
	end
	Wanted:Print("Top posters:")
	if #posters == 0 then
		Wanted:Print("  none yet")
	end
	for i = 1, min(#posters, 10) do
		local p = posters[i]
		Wanted:Print("  %d. %s - %d posted, %d paid (%s)%s", i, p.origin, p.posted, p.paid, Bounties:FormatMoney(p.gold), p.unpaid > 0 and format(", %d UNPAID", p.unpaid) or "")
	end
end)

Wanted:RegisterCommand("filter", "Board filters: /wanted filter min <amount> | zone <name> | clear.", function(args)
	local what, value = strmatch(strtrim(args or ""), "^(%S*)%s*(.*)$")
	local settings = Wanted.db.settings
	if what == "min" then
		local amount = Bounties:ParseMoney(value)
		if not amount then
			Wanted:Print("Usage: /wanted filter min <amount like 1g>")
			return
		end
		settings.minBounty = amount
	elseif what == "zone" then
		settings.zoneFilter = value ~= "" and value or GetZoneText()
	elseif what == "clear" then
		settings.minBounty = 0
		settings.zoneFilter = nil
	else
		Wanted:Print("Usage: /wanted filter min <amount> | zone [name] | clear")
		return
	end
	Wanted:Print("Board shows bounties of %s and up%s.", settings.minBounty > 0 and Bounties:FormatMoney(settings.minBounty) or "any amount", settings.zoneFilter and (" in "..settings.zoneFilter) or "")
end)
