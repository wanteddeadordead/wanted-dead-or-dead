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
local TRUSTED_AT = 4 -- verified kills (hunter) or paid claims (poster), next to none against, for 4.5 stars
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

---Hunter rank from points (how much they've done; the star rating says how far to trust it).
---@param tally table
---@return number level
function Reputation:GetRank(tally)
	return max(floor(tally.points / RANK_POINTS_PER_LEVEL), 0)
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
	local posterTrust, _, _, posterStars = Reputation:GetPosterTrust(tally)
	local hunterTrust, _, _, hunterStars = Reputation:GetHunterTrust(tally)
	if posterTrust then
		tinsert(parts, "as a poster: "..posterTrust..(posterStars and format(" (%s/5)", posterStars) or ""))
	end
	if hunterTrust then
		tinsert(parts, "as a hunter: "..hunterTrust..(hunterStars and format(" (%s/5)", hunterStars) or ""))
	end
	if tally.posted > 0 then
		local poster = format("posted %d, paid %d", tally.posted, tally.paid)
		if tally.unpaid > 0 then
			poster = poster..format(", %d UNPAID", tally.unpaid)
		end
		tinsert(parts, poster)
	end
	if tally.claims > 0 then
		tinsert(parts, format("hunter level %d, %d kills, earned %s", Reputation:GetRank(tally), tally.kills, Bounties:FormatMoney(tally.earned)))
		if tally.disputed > 0 then
			tinsert(parts, format("%d disputed", tally.disputed))
		end
	end
	return table.concat(parts, "; ")
end

---A star rating from good and bad results: the share that went well, in half stars. A newcomer can't reach
---the top on a few results: the most is 3 stars after one good result, rising half a star with each, to 5
---at five. Anyone rated has at least half a star, so a bad record never looks like no record.
---@param good number verified kills or paid claims
---@param bad number disputed claims or unpaid ones
---@return number? stars 0.5 to 5, nil with nothing to judge yet
local function StarsFrom(good, bad)
	if good + bad == 0 then
		return nil
	end
	local share = 5 * good / (good + bad)
	local most = min(5, 2.5 + 0.5 * good)
	return max(0.5, floor(min(share, most) * 2 + 0.5) / 2)
end

---The trust word and colour for a star rating.
local function TrustFromStars(stars)
	local C = Wanted.Theme.C
	if stars >= 4.5 then
		return "Trusted", C.green
	elseif stars >= 3 then
		return "Reliable", C.green
	elseif stars >= 2 then
		return "Doubtful", C.amber
	end
	return "Untrustworthy", C.red
end

---A hunter's star rating: verified kills against disputed ones (kills nobody saw don't count either way).
---@param tally table
---@return number?
function Reputation:GetHunterStars(tally)
	return StarsFrom(tally.witnessed + tally.confirmed, tally.disputed)
end

---A poster's star rating: claims paid against claims left unpaid.
---@param tally table
---@return number?
function Reputation:GetPosterStars(tally)
	return StarsFrom(tally.paid, tally.unpaid)
end

---How far to trust a hunter's claims.
---@param tally table
---@return string? label nil when they've never claimed
---@return table? color
---@return string? detail
---@return number? stars
function Reputation:GetHunterTrust(tally)
	if tally.claims == 0 then
		return nil
	end
	local good = tally.witnessed + tally.confirmed
	local level = Reputation:GetRank(tally)
	local detail = format("Level %d. %d of %d kill%s verified, %d unseen, %d disputed.", level, good, tally.claims, tally.claims == 1 and "" or "s", tally.lone, tally.disputed)
	if tally.earned > 0 then
		detail = detail.." Earned "..Bounties:FormatMoney(tally.earned).."."
	end
	local stars = Reputation:GetHunterStars(tally)
	if not stars then
		return "Unproven", Wanted.Theme.C.muted, detail, nil
	end
	local label, color = TrustFromStars(stars)
	return label, color, detail, stars
end

---How far to trust a poster to pay.
---@param tally table
---@return string? label nil when they've never posted
---@return table? color
---@return string? detail
---@return number? stars
function Reputation:GetPosterTrust(tally)
	if tally.posted == 0 then
		return nil
	end
	local detail = format("Paid %d of %d claim%s owed, %d unpaid. %d bount%s posted.", tally.paid, tally.paid + tally.unpaid, tally.paid + tally.unpaid == 1 and "" or "s", tally.unpaid, tally.posted, tally.posted == 1 and "y" or "ies")
	local stars = Reputation:GetPosterStars(tally)
	if not stars then
		return "New poster", Wanted.Theme.C.muted, detail, nil
	end
	local label, color = TrustFromStars(stars)
	return label, color, detail, stars
end

local POSTER_MEANING = {
	["Trusted"] = "Hunters can count on you: four or more claims paid, next to none left unpaid.",
	["Reliable"] = "You've mostly paid the claims you owed.",
	["New poster"] = "No claim on your bounties has come due yet, so hunters can't tell whether you pay.",
	["Doubtful"] = "You've left a fair share of the claims you owed unpaid.",
	["Untrustworthy"] = "You've left as many claims unpaid as you've paid, or more. Hunters may pass on your bounties.",
}
local HUNTER_MEANING = {
	["Trusted"] = "Your kills check out: four or more verified by a witness or the poster, next to none disputed.",
	["Reliable"] = "Your kills mostly check out.",
	["Unproven"] = "Nobody else saw your kills and no poster has confirmed one yet.",
	["Doubtful"] = "A fair share of your claims were disputed.",
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
		local more = max(1, TRUSTED_AT - tally.paid)
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
		local more = max(1, TRUSTED_AT - good)
		advice = format("%d more verified kill%s, with no disputes, makes you Trusted.", more, more == 1 and "" or "s")
	else
		advice = "Keep claiming only kills you made to stay Trusted."
	end
	return HUNTER_MEANING[label], advice
end


---A poster's stars for a bounty row, or "new" for a poster nobody has had to rely on yet.
---@param origin string
---@return string?
function Reputation:GetPosterBadge(origin)
	local stars = Reputation:GetPosterStars(Reputation:GetTally(origin))
	return stars and Wanted.Theme:Stars(stars, 10) or Wanted.Theme:Colorize("new", Wanted.Theme.C.faint)
end

---A hunter's stars for a claim, or "new" for a hunter with no verified or disputed kill yet.
---@param origin string
---@return string?
function Reputation:GetHunterBadge(origin)
	local stars = Reputation:GetHunterStars(Reputation:GetTally(origin))
	return stars and Wanted.Theme:Stars(stars, 10) or Wanted.Theme:Colorize("new", Wanted.Theme.C.faint)
end

---Adds a trust line to the game tooltip: stars and the trust word, then the numbers behind them.
---@param title string "Poster trust" or "Hunter trust"
---@param label string?
---@param color table?
---@param detail string?
---@param stars number?
function Reputation:AddTrustLines(title, label, color, detail, stars)
	if not label then
		return
	end
	local C = Wanted.Theme.C
	GameTooltip:AddDoubleLine(title, (stars and (Wanted.Theme:Stars(stars, 12).."  ") or "")..label, 1, 1, 1, color[1], color[2], color[3])
	GameTooltip:AddLine(detail, C.muted[1], C.muted[2], C.muted[3], true)
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
			tinsert(hunters, { origin = origin, level = Reputation:GetRank(tally), rating = Reputation:GetHunterStars(tally), earned = tally.earned, kills = tally.kills, points = tally.points })
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
		Wanted:Print("  %d. %s - level %d, %s, %d kills, %s earned", i, h.origin, h.level, h.rating and format("%s/5 stars", h.rating) or "new", h.kills, Bounties:FormatMoney(h.earned))
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
