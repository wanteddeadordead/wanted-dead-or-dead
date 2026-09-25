-- Wanted: what the interface shows, computed from the records. Every page asks this module rather than
-- reading records itself, so a bounty's state means the same thing everywhere.

local _, Wanted = ...
local Model = Wanted:NewModule("Model")
local Store = Wanted.Store
local Bounties = Wanted.Bounties
local Payments = Wanted.Payments
local Reputation = Wanted.Reputation
local LEVEL_BAND = 5

-- Bounty states, from the viewer's point of view
Model.STATE = {
	OPEN = "open", -- nobody has claimed it
	UNVERIFIED = "unverified", -- claimed on the hunter's word only
	CLAIMED = "claimed", -- claimed and witnessed, waiting for the poster
	OWED = "owed", -- confirmed, not yet paid
	PAID = "paid",
	EXPIRED = "expired",
	WITHDRAWN = "withdrawn", -- taken down by the poster before anyone claimed it
}
local STATE = Model.STATE



-- ============================================================================
-- Bounties
-- ============================================================================

---Everything the interface needs about one bounty.
---@param bounty table
---@return table info
function Model:GetBountyInfo(bounty)
	local me = Store:GetOrigin()
	local now = GetServerTime()
	local info = {
		bounty = bounty,
		id = bounty.id,
		amount = Bounties:GetAmount(bounty),
		expiry = Bounties:GetExpiry(bounty),
		mine = bounty.origin == me,
		poster = bounty.origin,
		targetGuid = bounty.data.target,
		targetName = bounty.data.targetName or "?",
		guild = bounty.data.guild, -- set on a bounty on a whole guild
		player = bounty.data.target and Store:GetPlayer(bounty.data.target) or nil,
		test = Store:IsTest(bounty),
		passed = Bounties:IsPassed(bounty),
		t = bounty.t,
	}
	-- A paid or confirmed claim is the poster's decision and stands; otherwise the earliest kill is the claim
	local paidClaim, owedClaim = nil, nil
	for claim in Store:Iterator("claim") do
		if claim.data.bounty == bounty.id then
			if Payments:GetForClaim(claim.id) then
				paidClaim = claim
			elseif Bounties:GetClaimLevel(claim) == 3 then
				owedClaim = claim
			end
		end
	end
	local winner = not paidClaim and not owedClaim and Bounties:GetWinningClaim(bounty) or nil
	if Bounties:IsWithdrawn(bounty) then
		info.state = STATE.WITHDRAWN
	elseif paidClaim then
		info.state, info.claim = STATE.PAID, paidClaim
	elseif owedClaim then
		info.state, info.claim = STATE.OWED, owedClaim
	elseif winner and Bounties:GetClaimLevel(winner) == 2 then
		info.state, info.claim = STATE.CLAIMED, winner
	elseif winner then
		info.state, info.claim = STATE.UNVERIFIED, winner
	elseif info.expiry <= now then
		info.state = STATE.EXPIRED
	else
		info.state = STATE.OPEN
	end
	info.hunter = info.claim and info.claim.origin
	info.myClaim = info.claim and info.claim.origin == me
	info.hunters = (info.state == STATE.OPEN or info.state == STATE.UNVERIFIED) and Bounties:GetActiveHunters(bounty) or {}
	info.iHunt = false
	for _, origin in ipairs(info.hunters) do
		if origin == me then
			info.iHunt = true
		end
	end
	info.huntEnds = info.iHunt and Bounties:GetMyHuntEnds(bounty) or nil
	-- What the viewer can do with it
	local actions = {}
	if info.mine then
		if info.state == STATE.OPEN then
			-- Someone hunting it means it can't be withdrawn
			if #info.hunters == 0 then
				tinsert(actions, "withdraw")
			end
			tinsert(actions, "raise")
		elseif info.state == STATE.CLAIMED or info.state == STATE.UNVERIFIED then
			tinsert(actions, "dispute")
			tinsert(actions, "confirm")
		elseif info.state == STATE.OWED then
			tinsert(actions, "pay")
		end
	elseif (info.state == STATE.OPEN or info.state == STATE.UNVERIFIED) and not info.passed then
		if info.iHunt then
			tinsert(actions, "stophunt")
			tinsert(actions, "renew")
		else
			tinsert(actions, "pass")
			tinsert(actions, "hunt")
		end
	end
	info.actions = actions
	info.needsMe = info.mine and (info.state == STATE.CLAIMED or info.state == STATE.UNVERIFIED or info.state == STATE.OWED)
	return info
end

---Short state label and colour for a pill.
---@param info table
---@return string label
---@return table color
function Model:GetStateLabel(info)
	local C = Wanted.Theme.C
	local state = info.state
	if state == STATE.OPEN then
		if info.iHunt then
			-- The hunt's time left belongs where it's always seen (the detail line gets cut off)
			return info.huntEnds and ("Hunting, "..Wanted.Theme:Left(info.huntEnds - GetServerTime())) or "You're hunting", C.blue
		elseif info.mine and #info.hunters > 0 then
			return "Being hunted", C.amber
		end
		return info.mine and "Your bounty" or "Open", info.mine and C.blue or C.green
	elseif state == STATE.UNVERIFIED then
		return info.mine and "Check claim" or "Unverified claim", C.amber
	elseif state == STATE.CLAIMED then
		return info.mine and "Confirm claim" or "Claimed", C.amber
	elseif state == STATE.OWED then
		if info.mine then
			return "You owe", C.red
		end
		return info.myClaim and "Awaiting payment" or "Confirmed", C.green
	elseif state == STATE.PAID then
		return "Paid", C.green
	elseif state == STATE.WITHDRAWN then
		return "Withdrawn", C.faint
	end
	return "Expired", C.faint
end

---The second line of a bounty row.
---@param info table
---@return string
function Model:GetDetail(info)
	local Theme = Wanted.Theme
	local now = GetServerTime()
	local parts = {}
	local Reputation = Wanted.Reputation
	-- Each name carries its record in a few words, right after it, so the line's cut-off never hides it
	local function Hunter()
		local badge = Reputation:GetHunterBadge(info.hunter)
		return info.hunter..(badge and (" "..badge) or "")
	end
	if info.mine then
		tinsert(parts, "Posted by you")
	else
		local badge = Reputation:GetPosterBadge(info.poster)
		tinsert(parts, "By "..info.poster..(badge and (" "..badge) or ""))
	end
	local state = info.state
	if state == STATE.OPEN then
		tinsert(parts, Theme:Left(info.expiry - now))
		local hunters = #info.hunters
		if hunters > 0 then
			tinsert(parts, info.iHunt and (hunters == 1 and "only you hunting" or format("you and %d other%s hunting", hunters - 1, hunters == 2 and "" or "s")) or format("%d hunting", hunters))
		end
	elseif state == STATE.UNVERIFIED then
		tinsert(parts, Hunter().." claims it, unseen")
	elseif state == STATE.CLAIMED then
		local witnesses = #Bounties:GetWitnesses(info.claim)
		tinsert(parts, format("%s claims it, %d witness%s", Hunter(), witnesses, witnesses == 1 and "" or "es"))
	elseif state == STATE.OWED then
		tinsert(parts, info.mine and ("pay "..info.hunter) or (info.hunter.." earned it"))
	elseif state == STATE.PAID then
		tinsert(parts, "paid to "..info.hunter)
	elseif state == STATE.WITHDRAWN then
		tinsert(parts, "taken down")
	else
		tinsert(parts, "no taker")
	end
	if info.test then
		tinsert(parts, "Test data")
	end
	return table.concat(parts, "  -  ")
end

---Players seen in a guild, most recently seen first.
---@param guild string
---@return table[] players (each with a guid field)
function Model:GetGuildMembers(guild)
	local members = {}
	for guid, player in pairs(Wanted.db.players) do
		if player.guild == guild then
			player.guid = guid
			tinsert(members, player)
		end
	end
	sort(members, function(a, b) return (a.lastSeen or 0) > (b.lastSeen or 0) end)
	return members
end

---Where the target was last seen (for a guild bounty: its most recently seen member), or nil.
---@param info table
---@return string?
function Model:GetLastSeen(info)
	local player = info.player
	if info.guild then
		player = Model:GetGuildMembers(info.guild)[1]
	end
	if not player or not player.lastSeen then
		return nil
	end
	return format("%s, %s", player.zone or "?", Wanted.Theme:Ago(GetServerTime() - player.lastSeen))
end

---The board: what a hunter or poster should see now, most urgent first.
---@param filters table search, minAmount, zone, showPassed
---@return table[] infos
function Model:GetBoard(filters)
	local items = {}
	local search = filters.search and strlower(strtrim(filters.search)) or ""
	for bounty in Store:Iterator("bounty") do
		local info = Model:GetBountyInfo(bounty)
		local show = false
		if info.state == STATE.PAID or info.state == STATE.EXPIRED or info.state == STATE.WITHDRAWN then
			show = false
		elseif info.state == STATE.OWED then
			show = info.mine or info.myClaim
		elseif info.mine then
			show = true
		else
			local zone = info.player and info.player.zone or bounty.data.zone
			if info.guild then
				local member = Model:GetGuildMembers(info.guild)[1]
				zone = member and member.zone
			end
			show = (filters.showPassed or not info.passed)
				and info.amount >= (filters.minAmount or 0)
				and (not filters.zone or zone == filters.zone)
		end
		if show and search ~= "" and not strfind(strlower(info.targetName), search, 1, true) then
			show = false
		end
		if show then
			info.order = info.needsMe and 0 or ((info.state == STATE.OPEN or info.state == STATE.UNVERIFIED) and 1 or 2)
			tinsert(items, info)
		end
	end
	sort(items, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		if a.amount ~= b.amount then
			return a.amount > b.amount
		end
		return a.t > b.t
	end)
	return items
end

local FINISHED = { paid = true, expired = true, withdrawn = true }

---Whether a bounty is over (paid, expired or withdrawn).
---@param info table
---@return boolean
function Model:IsFinished(info)
	return FINISHED[info.state] or false
end

---Bounties the player posted that are still live (open, claimed, owed).
---@return table[]
function Model:GetMyBounties()
	local items = {}
	local me = Store:GetOrigin()
	local rank = { owed = 0, claimed = 1, unverified = 1, open = 2 }
	for bounty in Store:Iterator("bounty") do
		if bounty.origin == me then
			local info = Model:GetBountyInfo(bounty)
			if not Model:IsFinished(info) then
				info.order = rank[info.state] or 3
				tinsert(items, info)
			end
		end
	end
	sort(items, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.t > b.t
	end)
	return items
end

---Bounties the player is hunting right now, biggest first.
---@return table[]
function Model:GetMyHunts()
	local items = {}
	for bounty in Store:Iterator("bounty") do
		local info = Model:GetBountyInfo(bounty)
		if info.iHunt then
			tinsert(items, info)
		end
	end
	sort(items, function(a, b)
		if a.amount ~= b.amount then
			return a.amount > b.amount
		end
		return a.t > b.t
	end)
	return items
end

---Claims the player made as a hunter that are still in play (not paid, beaten or disputed).
---@return table[]
function Model:GetMyActiveClaims()
	local items = {}
	for _, item in ipairs(Model:GetMyClaims()) do
		if not item.finished then
			tinsert(items, item)
		end
	end
	return items
end

---Finished bounties the player posted and finished claims they made, newest first.
---Finished business for one side: as a poster, bounties that were paid, expired or withdrawn; as a hunter,
---claims that were paid, beaten or disputed. Newest first.
---@param role string "poster" or "hunter"
---@return table[]
function Model:GetMyHistory(role)
	local items = {}
	local me = Store:GetOrigin()
	if role == "poster" then
		for bounty in Store:Iterator("bounty") do
			if bounty.origin == me then
				local info = Model:GetBountyInfo(bounty)
				if Model:IsFinished(info) then
					info.sortT = bounty.t
					tinsert(items, info)
				end
			end
		end
	else
		for _, item in ipairs(Model:GetMyClaims()) do
			if item.finished then
				item.sortT = item.t
				tinsert(items, item)
			end
		end
	end
	sort(items, function(a, b) return a.sortT > b.sortT end)
	return items
end

---Every claim the player made as a hunter.
---@return table[]
function Model:GetMyClaims()
	local items = {}
	local me = Store:GetOrigin()
	local C = Wanted.Theme.C
	for claim in Store:Iterator("claim") do
		if claim.origin == me then
			local bounty = Store:Get(claim.data.bounty)
			if bounty then
				local level = Bounties:GetClaimLevel(claim)
				local payment = Payments:GetForClaim(claim.id)
				local item = {
					claim = claim,
					bounty = bounty,
					amount = Bounties:GetAmount(bounty),
					poster = bounty.origin,
					targetName = claim.data.victimName or bounty.data.targetName or "?",
					player = Store:GetPlayer(bounty.data.target),
					t = claim.t,
					test = Store:IsTest(claim),
				}
				local winner = Bounties:GetWinningClaim(bounty)
				if payment then
					item.label, item.color, item.order, item.finished = "Paid", C.green, 3, true
				elseif level > 0 and level < 3 and winner and winner.id ~= claim.id then
					item.label, item.color, item.order, item.finished = "Beaten", C.faint, 2, true
				elseif level == 0 then
					item.label, item.color, item.order, item.finished = "Disputed", C.red, 2, true
				elseif Payments:IsUnpaid(claim) then
					item.label, item.color, item.order = "Overdue", C.red, 0
				elseif level == 3 then
					item.label, item.color, item.order = "Confirmed", C.green, 0
				elseif level == 2 then
					item.label, item.color, item.order = "Witnessed", C.amber, 1
				else
					item.label, item.color, item.order = "Unverified", C.amber, 1
				end
				tinsert(items, item)
			end
		end
	end
	sort(items, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.t > b.t
	end)
	return items
end

---Totals for the summary tiles.
---@return table
function Model:GetMySummary()
	local summary = {
		owe = 0, oweCount = 0, open = 0, openCount = 0, decide = 0, paidOut = 0, paidOutCount = 0, -- as a poster
		owed = 0, owedCount = 0, earned = 0, earnedCount = 0, hunting = 0, huntingCount = 0, -- as a hunter
	}
	local me = Store:GetOrigin()
	for _, info in ipairs(Model:GetMyBounties()) do
		if info.state == STATE.OWED then
			summary.owe = summary.owe + info.amount
			summary.oweCount = summary.oweCount + 1
		elseif info.state == STATE.OPEN then
			summary.open = summary.open + info.amount
			summary.openCount = summary.openCount + 1
		elseif info.state == STATE.CLAIMED or info.state == STATE.UNVERIFIED then
			summary.decide = summary.decide + 1
		end
	end
	for _, item in ipairs(Model:GetMyClaims()) do
		if item.label == "Confirmed" or item.label == "Witnessed" or item.label == "Overdue" then
			summary.owed = summary.owed + item.amount
			summary.owedCount = summary.owedCount + 1
		end
	end
	-- Payments: both sides record one, so each claim counts once
	local counted = {}
	for payment in Store:Iterator("payment") do
		local claimId = payment.data.claim
		local claim = claimId and Store:Get(claimId)
		local bounty = payment.data.bounty and Store:Get(payment.data.bounty)
		if claimId and not counted[claimId] then
			counted[claimId] = true
			local amount = payment.data.amount or 0
			if bounty and bounty.origin == me then
				summary.paidOut = summary.paidOut + amount
				summary.paidOutCount = summary.paidOutCount + 1
			end
			if claim and claim.origin == me then
				summary.earned = summary.earned + amount
				summary.earnedCount = summary.earnedCount + 1
			end
		end
	end
	for _, info in ipairs(Model:GetMyHunts()) do
		summary.hunting = summary.hunting + info.amount
		summary.huntingCount = summary.huntingCount + 1
	end
	return summary
end

---How many things wait on the player (sidebar badge).
---@return number
function Model:GetActionCount()
	local summary = Model:GetMySummary()
	return summary.decide + summary.oweCount
end



-- ============================================================================
-- Going rate
-- ============================================================================

---What bounties on players near a level have actually done.
---@param level number
---@param amount number? the amount being considered
---@return string?
function Model:GetGoingRate(level, amount)
	if not level then
		return nil
	end
	local paid, expired, under = {}, 0, 0
	for bounty in Store:Iterator("bounty") do
		local bountyLevel = bounty.data.level
		-- Test data must not set real prices
		if bountyLevel and abs(bountyLevel - level) <= LEVEL_BAND and not Store:IsTest(bounty) then
			local info = Model:GetBountyInfo(bounty)
			if info.state == STATE.PAID then
				tinsert(paid, info.amount)
			elseif info.state == STATE.EXPIRED then
				expired = expired + 1
				if amount and info.amount <= amount then
					under = under + 1
				end
			end
		end
	end
	local band = format("Levels %d-%d", max(level - LEVEL_BAND, 1), level + LEVEL_BAND)
	if #paid == 0 and expired == 0 then
		return band..": no finished bounties yet, so no going rate."
	end
	sort(paid)
	local text = band..": "
	if #paid > 0 then
		text = text..format("%d paid out, typically %s", #paid, Bounties:FormatMoney(paid[floor((#paid + 1) / 2)]))
	else
		text = text.."none paid out yet"
	end
	if expired > 0 then
		text = text..format(". %d expired with no taker", expired)
		if amount and under > 0 then
			text = text..format(", %d of them at or below this amount", under)
		end
	end
	return text.."."
end



-- ============================================================================
-- Leaderboards
-- ============================================================================

---@param since number
---@return table[] hunters
---@return table[] posters
function Model:GetLeaderboards(since)
	local hunters, posters = {}, {}
	local me = Store:GetOrigin()
	for _, origin in ipairs(Reputation:GetOrigins()) do
		local tally = Reputation:GetTally(origin, since)
		if tally.claims > 0 then
			tinsert(hunters, { origin = origin, me = origin == me, level = Reputation:GetRank(tally), rating = Reputation:GetHunterStars(tally), kills = tally.kills, earned = tally.earned, points = tally.points, disputed = tally.disputed, tally = tally })
		end
		if tally.posted > 0 then
			tinsert(posters, { origin = origin, me = origin == me, posted = tally.posted, paid = tally.paid, unpaid = tally.unpaid, gold = tally.paidGold, rating = Reputation:GetPosterStars(tally), tally = tally })
		end
	end
	sort(hunters, function(a, b)
		if a.points ~= b.points then
			return a.points > b.points
		end
		return a.earned > b.earned
	end)
	sort(posters, function(a, b)
		if a.gold ~= b.gold then
			return a.gold > b.gold
		end
		return a.posted > b.posted
	end)
	return hunters, posters
end



-- ============================================================================
-- Activity
-- ============================================================================

---Kills, deaths and sightings, newest first.
---@param kind string? "kill" | "death" | "seen" | nil for everything
---@return table[]
function Model:GetActivity(kind)
	local items = {}
	local me = Store:GetOrigin()
	if not kind or kind == "kill" then
		for record in Store:Iterator("kill") do
			local data = record.data
			tinsert(items, { kind = "kill", t = record.t, who = record.origin == me and "You" or record.origin, name = data.victimName, guid = data.victim, guild = data.victimGuild, zone = data.zone, x = data.x, y = data.y, test = Store:IsTest(record) })
		end
	end
	if not kind or kind == "death" then
		for record in Store:Iterator("death") do
			local data = record.data
			tinsert(items, { kind = "death", t = record.t, who = record.origin == me and "you" or record.origin, name = data.victimName, guid = data.victim, guild = data.victimGuild, zone = data.zone, x = data.x, y = data.y, test = Store:IsTest(record) })
		end
	end
	if not kind or kind == "seen" then
		local latest = {}
		for sighting in Store:SightingIterator() do
			if not latest[sighting.guid] or latest[sighting.guid].t < sighting.t then
				latest[sighting.guid] = sighting
			end
		end
		for guid, sighting in pairs(latest) do
			local player = Store:GetPlayer(guid)
			tinsert(items, { kind = "seen", t = sighting.t, name = player and player.name or "?", guid = guid, player = player, guild = player and player.guild or nil, zone = sighting.zone, x = sighting.x, y = sighting.y, test = strsub(guid, 1, 12) == "Player-TEST-" })
		end
	end
	sort(items, function(a, b) return a.t > b.t end)
	return items
end



-- ============================================================================
-- Guilds
-- ============================================================================

---Guilds ranked by what the records say: kills by their members (credited kills by addon users), deaths
---among their members (witnessed deaths and kills, each death counted once), and bounty gold on them.
---@param since number?
---@return table[]
function Model:GetGuildBoard(since)
	since = since or 0
	local guilds = {}
	local myFaction = UnitFactionGroup("player")
	local function Get(name)
		if not name then
			return nil
		end
		local guild = guilds[name]
		if not guild then
			guild = { name = name, kills = 0, deaths = 0, seen = 0, bounties = 0, gold = 0 }
			guilds[name] = guild
		end
		return guild
	end
	local countedDeaths = {}
	-- Test data stays off the guild board, like everywhere counts are public-facing
	for kill in Store:Iterator("kill") do
		if kill.t >= since and not Store:IsTest(kill) then
			local killer = Get(kill.data.killerGuild)
			if killer then
				killer.kills = killer.kills + 1
				killer.faction = killer.faction or myFaction
			end
			local key = kill.data.deathId or kill.id
			local victim = Get(kill.data.victimGuild)
			if victim and not countedDeaths[key] then
				countedDeaths[key] = true
				victim.deaths = victim.deaths + 1
			end
		end
	end
	for death in Store:Iterator("death") do
		if death.t >= since and not Store:IsTest(death) then
			local key = death.data.deathId or death.id
			local victim = Get(death.data.victimGuild)
			if victim and not countedDeaths[key] then
				countedDeaths[key] = true
				victim.deaths = victim.deaths + 1
			end
		end
	end
	for bounty in Store:Iterator("bounty") do
		if bounty.t >= since and not Store:IsTest(bounty) then
			local guild = Get(bounty.data.guild or bounty.data.targetGuild)
			if guild then
				guild.bounties = guild.bounties + 1
				guild.gold = guild.gold + Bounties:GetAmount(bounty)
			end
		end
	end
	for guid, player in pairs(Wanted.db.players) do
		if type(player.guild) == "string" and strsub(guid, 1, 12) ~= "Player-TEST-" then
			local guild = Get(player.guild)
			guild.seen = guild.seen + 1
			guild.faction = guild.faction or player.faction
		end
	end
	local list = {}
	for _, guild in pairs(guilds) do
		guild.mine = guild.faction == myFaction
		tinsert(list, guild)
	end
	sort(list, function(a, b)
		if a.kills ~= b.kills then
			return a.kills > b.kills
		elseif a.deaths ~= b.deaths then
			return a.deaths > b.deaths
		end
		return a.gold > b.gold
	end)
	return list
end
