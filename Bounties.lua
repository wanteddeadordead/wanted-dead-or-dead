-- Wanted: bounties and claims. A bounty is a record naming a target GUID and an amount; a claim is a
-- hunter's record that their honor-credited kill matched an open bounty. A claim's level is computed
-- from the records, never stored: 1 = the hunter's own client, 2 = another client witnessed the same
-- death, 3 = the poster confirmed it. Posters raise, confirm or dispute; hunters pass what is too low.

local _, Wanted = ...
local Bounties = Wanted:NewModule("Bounties")
local Store = Wanted.Store
local Recorder = Wanted.Recorder
local private = {}
local EXPIRY_SECONDS = 7 * 24 * 60 * 60
local MIN_BOUNTY = 10 * 100 -- 10s
-- A hunter's commitment holds this long (renewable); while it does, the poster can't withdraw the bounty
-- A hunt lasts a day: finding one player online in the open world can take days, and Renew starts the day
-- again. Every client must agree on this to agree whether a withdrawal counted, so it only changes with a
-- release everyone takes.
local HUNT_SECONDS = 24 * 60 * 60
Bounties.HUNT_SECONDS = HUNT_SECONDS
-- A death record from another client counts as a witness within this many seconds of the kill
local WITNESS_WINDOW = 30



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Bounties:OnEnable()
	Store:OnRecord("kill", private.OnKill)
end

function Bounties:Status()
	local open, mine = 0, 0
	for bounty in Bounties:OpenIterator() do
		open = open + 1
		if bounty.origin == Store:GetOrigin() then
			mine = mine + 1
		end
	end
	local claims = 0
	for _ in Store:Iterator("claim") do
		claims = claims + 1
	end
	return format("Bounties: %d open (%d yours), %d claims.", open, mine, claims)
end



-- ============================================================================
-- Money helpers (plain text, no colour codes)
-- ============================================================================

---Parses "1g 20s", "50s", "1g", "150c" or a bare number of gold into copper.
---@param str string
---@return number? copper
function Bounties:ParseMoney(str)
	str = strlower(strtrim(str or ""))
	if str == "" then
		return nil
	end
	if strmatch(str, "^%d+%.?%d*$") then
		return floor(tonumber(str) * 10000 + 0.5)
	end
	local copper, matched = 0, false
	for amount, unit in gmatch(str, "(%d+%.?%d*)%s*([gsc])") do
		matched = true
		local n = tonumber(amount)
		if unit == "g" then
			copper = copper + n * 10000
		elseif unit == "s" then
			copper = copper + n * 100
		else
			copper = copper + n
		end
	end
	return matched and floor(copper + 0.5) or nil
end

---Formats copper as "1g 2s 3c".
---@param copper number
---@return string
function Bounties:FormatMoney(copper)
	copper = floor(copper + 0.5)
	local gold = floor(copper / 10000)
	local silver = floor(copper % 10000 / 100)
	copper = copper % 100
	local parts = {}
	if gold > 0 then
		tinsert(parts, gold.."g")
	end
	if silver > 0 then
		tinsert(parts, silver.."s")
	end
	if copper > 0 or #parts == 0 then
		tinsert(parts, copper.."c")
	end
	return table.concat(parts, " ")
end



-- ============================================================================
-- Bounties
-- ============================================================================

---The total amount on a bounty, including raises.
---@param bounty table
---@return number
function Bounties:GetAmount(bounty)
	local amount = bounty.data.amount
	for raise in Store:Iterator("raise") do
		if raise.data.bounty == bounty.id then
			amount = amount + raise.data.amount
		end
	end
	return amount
end

---When a bounty expires (raises extend it from the raise).
---@param bounty table
---@return number
function Bounties:GetExpiry(bounty)
	local expiry = bounty.t + EXPIRY_SECONDS
	for raise in Store:Iterator("raise") do
		if raise.data.bounty == bounty.id then
			expiry = max(expiry, raise.t + EXPIRY_SECONDS)
		end
	end
	return expiry
end

---Whether a bounty has a claim that the poster confirmed or that was paid (later step).
---@param bounty table
---@return boolean
function Bounties:IsSettled(bounty)
	for claim in Store:Iterator("claim") do
		if claim.data.bounty == bounty.id and Bounties:GetClaimLevel(claim) >= 3 then
			return true
		end
	end
	for payment in Store:Iterator("payment") do
		if payment.data.bounty == bounty.id then
			return true
		end
	end
	return false
end

---The best pending claim on a bounty: witnessed (level 2) but not yet confirmed or paid by the poster.
---@param bounty table
---@return table? claim
function Bounties:GetPendingClaim(bounty)
	for claim in Store:Iterator("claim") do
		if claim.data.bounty == bounty.id and Bounties:GetClaimLevel(claim) == 2 then
			return claim
		end
	end
	return nil
end

---Hunters committed to a bounty at a moment: each hunter's latest hunt record at or before it, if that one
---started a hunt less than HUNT_SECONDS earlier (a stop record ends it).
---@param bounty table
---@param at number? a server time, default now
---@return string[] hunters
function Bounties:GetActiveHunters(bounty, at)
	at = at or GetServerTime()
	local latest = {}
	for hunt in Store:Iterator("hunt") do
		if hunt.data.bounty == bounty.id and hunt.t <= at then
			local previous = latest[hunt.origin]
			if not previous or hunt.t > previous.t or (hunt.t == previous.t and hunt.seq > previous.seq) then
				latest[hunt.origin] = hunt
			end
		end
	end
	local hunters = {}
	for origin, hunt in pairs(latest) do
		if not hunt.data.stop and at - hunt.t < HUNT_SECONDS then
			tinsert(hunters, origin)
		end
	end
	sort(hunters)
	return hunters
end

---When this client's hunt on a bounty runs out, or nil if it isn't hunting it.
---@param bounty table
---@return number? serverTime
function Bounties:GetMyHuntEnds(bounty)
	local me = Store:GetOrigin()
	local latest
	for hunt in Store:Iterator("hunt") do
		if hunt.origin == me and hunt.data.bounty == bounty.id and (not latest or hunt.t > latest.t or (hunt.t == latest.t and hunt.seq > latest.seq)) then
			latest = hunt
		end
	end
	if not latest or latest.data.stop or GetServerTime() - latest.t >= HUNT_SECONDS then
		return nil
	end
	return latest.t + HUNT_SECONDS
end

---Whether this client is hunting a bounty now.
---@param bounty table
---@return boolean
function Bounties:IsHunting(bounty)
	local me = Store:GetOrigin()
	for _, origin in ipairs(Bounties:GetActiveHunters(bounty)) do
		if origin == me then
			return true
		end
	end
	return false
end

---Starts (or renews) this client's hunt on a bounty, or stops it.
---@param bounty table
---@param stop boolean?
---@return boolean ok
---@return string? err
function Bounties:Hunt(bounty, stop)
	if bounty.origin == Store:GetOrigin() then
		return false, "you can't hunt your own bounty"
	end
	Store:NewRecord("hunt", { bounty = bounty.id, stop = stop or nil })
	Wanted:Log("Bounties: %s hunting %s", stop and "stopped" or "started", bounty.id)
	return true
end

---Whether the poster withdrew a bounty. A withdrawal made while someone was hunting it does not count,
---judged by the records' own times, so every client reaches the same answer whatever order they arrive in.
---@param bounty table
---@return boolean
function Bounties:IsWithdrawn(bounty)
	for withdraw in Store:Iterator("withdraw") do
		if withdraw.data.bounty == bounty.id and withdraw.origin == bounty.origin and #Bounties:GetActiveHunters(bounty, withdraw.t) == 0 then
			return true
		end
	end
	return false
end

---Takes down one of our bounties. Only allowed while nobody has claimed it.
---@param bounty table
---@return boolean ok
---@return string? err
function Bounties:Withdraw(bounty)
	if bounty.origin ~= Store:GetOrigin() then
		return false, "only the poster can withdraw a bounty"
	end
	for claim in Store:Iterator("claim") do
		if claim.data.bounty == bounty.id and Bounties:GetClaimLevel(claim) > 0 then
			return false, "someone has already claimed it"
		end
	end
	local hunters = Bounties:GetActiveHunters(bounty)
	if #hunters > 0 then
		return false, format("%s %s hunting it", table.concat(hunters, ", "), #hunters == 1 and "is" or "are")
	end
	Store:NewRecord("withdraw", { bounty = bounty.id })
	Wanted:Log("Bounties: withdrew %s", bounty.id)
	return true
end

---Whether this client passed on a bounty.
---@param bounty table
---@return boolean
function Bounties:IsPassed(bounty)
	for pass in Store:Iterator("pass") do
		if pass.data.bounty == bounty.id and pass.origin == Store:GetOrigin() then
			return true
		end
	end
	return false
end

---Iterates open bounties: not expired, not settled.
---@return fun(): table?
function Bounties:OpenIterator()
	local now = GetServerTime()
	local iterator = Store:Iterator("bounty")
	return function()
		local bounty = iterator()
		while bounty and (Bounties:GetExpiry(bounty) <= now or Bounties:IsSettled(bounty) or Bounties:IsWithdrawn(bounty)) do
			bounty = iterator()
		end
		return bounty
	end
end

---Open bounties on a target.
---@param guid string
---@return table[]
function Bounties:GetOpenForTarget(guid)
	local result = {}
	for bounty in Bounties:OpenIterator() do
		if bounty.data.target == guid then
			tinsert(result, bounty)
		end
	end
	return result
end

---This client's own open bounty on a target, if any.
---@param guid string
---@return table?
function Bounties:GetMyOpen(guid)
	for _, bounty in ipairs(Bounties:GetOpenForTarget(guid)) do
		if bounty.origin == Store:GetOrigin() then
			return bounty
		end
	end
	return nil
end

---Open bounties on a whole guild (any member's kill claims them).
---@param guild string
---@return table[]
function Bounties:GetOpenForGuild(guild)
	local result = {}
	if not guild then
		return result
	end
	for bounty in Bounties:OpenIterator() do
		if bounty.data.guild == guild then
			tinsert(result, bounty)
		end
	end
	return result
end

---This client's own open bounty on a guild, if any.
---@param guild string
---@return table?
function Bounties:GetMyOpenGuild(guild)
	for _, bounty in ipairs(Bounties:GetOpenForGuild(guild)) do
		if bounty.origin == Store:GetOrigin() then
			return bounty
		end
	end
	return nil
end

---Posts a bounty on every member of a guild; the first kill of any member claims it.
---@param guild string
---@param faction string? the guild's faction as seen
---@param amount number copper
---@return table? bounty
---@return string? err
function Bounties:PostGuild(guild, faction, amount)
	if amount < MIN_BOUNTY then
		return nil, "the minimum bounty is "..Bounties:FormatMoney(MIN_BOUNTY)
	end
	if Bounties:GetMyOpenGuild(guild) then
		return nil, "you already have a bounty on <"..guild..">, raise it instead"
	end
	if faction and faction == UnitFactionGroup("player") then
		return nil, "bounties are for the other faction only"
	end
	local bounty = Store:NewRecord("bounty", {
		guild = guild,
		targetName = "<"..guild..">",
		amount = amount,
	})
	Wanted:Log("Bounties: posted %s on guild %s", Bounties:FormatMoney(amount), guild)
	return bounty
end

---Posts a bounty. Returns the record, or nil and a reason.
---@param guid string
---@param name string
---@param amount number copper
---@return table? bounty
---@return string? err
function Bounties:Post(guid, name, amount)
	if amount < MIN_BOUNTY then
		return nil, "the minimum bounty is "..Bounties:FormatMoney(MIN_BOUNTY)
	end
	if Bounties:GetMyOpen(guid) then
		-- One bounty per poster per target; more gold goes onto the existing one
		return nil, "you already have a bounty on "..(name or "them")..", raise it instead"
	end
	local player = Store:GetPlayer(guid)
	if player and player.faction and player.faction == UnitFactionGroup("player") then
		return nil, "bounties are for the other faction only"
	end
	Store:UpdatePlayer(guid, { name = name })
	local bounty = Store:NewRecord("bounty", {
		target = guid,
		targetName = name,
		targetGuild = player and player.guild or nil,
		amount = amount,
		level = player and player.level or nil,
		zone = player and player.zone or nil,
	})
	Wanted:Log("Bounties: posted %s on %s", Bounties:FormatMoney(amount), name)
	return bounty
end



---Adds to a bounty.
---@param bounty table
---@param amount number copper
---@return table raise
function Bounties:Raise(bounty, amount)
	Wanted:Log("Bounties: raised %s by %s", bounty.id, Bounties:FormatMoney(amount))
	return Store:NewRecord("raise", { bounty = bounty.id, amount = amount })
end

---Hides a bounty from this client's board as too low.
---@param bounty table
function Bounties:Pass(bounty)
	return Store:NewRecord("pass", { bounty = bounty.id })
end

---Confirms or disputes a claim on one of our bounties. Returns false if the claim is not on ours.
---@param claim table
---@param disputed boolean
---@return boolean
function Bounties:Decide(claim, disputed)
	local bounty = Store:Get(claim.data.bounty)
	if not bounty or bounty.origin ~= Store:GetOrigin() then
		return false
	end
	Store:NewRecord("confirm", { claim = claim.id, disputed = disputed or nil })
	if disputed then
		Store:NewRecord("mark", { about = claim.origin, category = "disputed claim", evidence = claim.id })
	end
	return true
end

---Finds who a typed name means: the current target if it matches, else a player the addon has seen.
---@param name string
---@return string? guid
---@return string? name
function Bounties:ResolveName(name)
	name = strtrim(name or "")
	if name == "" then
		return nil, nil
	end
	if UnitExists("target") and UnitIsPlayer("target") then
		local targetName = GetUnitName("target", true)
		if targetName and strlower(targetName) == strlower(name) then
			return UnitGUID("target"), targetName
		end
	end
	local guid, player = Store:FindPlayerByName(name)
	return guid, player and player.name
end



-- ============================================================================
-- Claims
-- ============================================================================

---A kill of ours matched against open bounties creates claims.
function private.OnKill(kill, isOwn)
	if not isOwn then
		return
	end
	local victim = kill.data.victim
	-- Bounties on this player, and on the guild they belong to
	local matching = Bounties:GetOpenForTarget(victim)
	for _, bounty in ipairs(Bounties:GetOpenForGuild(kill.data.victimGuild)) do
		tinsert(matching, bounty)
	end
	for _, bounty in ipairs(matching) do
		-- Your own bounty is not something you can collect on
		local exists = bounty.origin == Store:GetOrigin()
		for claim in Store:Iterator("claim") do
			if claim.data.bounty == bounty.id and claim.origin == Store:GetOrigin() then
				exists = true
				break
			end
		end
		if not exists then
			Store:NewRecord("claim", {
				bounty = bounty.id,
				kill = kill.id,
				deathId = kill.data.deathId,
				victim = victim,
				victimName = kill.data.victimName,
				victimGuild = kill.data.victimGuild,
				zone = kill.data.zone,
				killT = kill.t,
			})
			Wanted:Print("You killed %s: claim filed for the %s bounty posted by %s.", kill.data.victimName or "?", Bounties:FormatMoney(Bounties:GetAmount(bounty)), bounty.origin)
		end
	end
end

---Other clients that recorded the same death as a claim's kill (same victim, same place, within the window).
---@param claim table
---@return string[] origins
function Bounties:GetWitnesses(claim)
	local witnesses = {}
	local seen = {}
	for death in Store:Iterator("death") do
		local data = death.data
		if death.origin ~= claim.origin and not seen[death.origin] and data.victim == claim.data.victim and data.zone == claim.data.zone and abs(death.t - claim.data.killT) <= WITNESS_WINDOW then
			seen[death.origin] = true
			tinsert(witnesses, death.origin)
		end
	end
	return witnesses
end

---The claim that gets the bounty: the earliest kill among claims that aren't disputed. Every hunter can
---chase a bounty; whoever got the kill first wins it (ties go to the lower id, so every client agrees).
---@param bounty table
---@return table? claim
function Bounties:GetWinningClaim(bounty)
	local best, bestT = nil, nil
	for claim in Store:Iterator("claim") do
		if claim.data.bounty == bounty.id and Bounties:GetClaimLevel(claim) > 0 then
			local t = claim.data.killT or claim.t
			if not best or t < bestT or (t == bestT and claim.id < best.id) then
				best, bestT = claim, t
			end
		end
	end
	return best
end

---The claim's level: 1 own client, 2 witnessed, 3 confirmed by the poster. Disputed returns 0.
---@param claim table
---@return number
function Bounties:GetClaimLevel(claim)
	local bounty = Store:Get(claim.data.bounty)
	for confirm in Store:Iterator("confirm") do
		if confirm.data.claim == claim.id and bounty and confirm.origin == bounty.origin then
			return confirm.data.disputed and 0 or 3
		end
	end
	if #Bounties:GetWitnesses(claim) > 0 then
		return 2
	end
	return 1
end



-- ============================================================================
-- Commands
-- ============================================================================

local function Ago(t)
	local seconds = max(GetServerTime() - t, 0)
	if seconds < 60 then
		return seconds.."s"
	elseif seconds < 3600 then
		return floor(seconds / 60).."m"
	elseif seconds < 86400 then
		return floor(seconds / 3600).."h"
	end
	return floor(seconds / 86400).."d"
end

local function ResolveTarget(nameArg)
	if nameArg == "" then
		if UnitExists("target") and UnitIsPlayer("target") then
			return UnitGUID("target"), GetUnitName("target", true)
		end
		return nil, nil, "no name given and no player targeted"
	end
	local guid, player = Store:FindPlayerByName(nameArg)
	if not guid then
		return nil, nil, "no player named "..nameArg.." has been seen; target them first"
	end
	return guid, player.name
end

Wanted:RegisterCommand("post", "Posts a bounty: /wanted post <amount> [name] (name defaults to your target).", function(args)
	local amountStr, nameArg = strmatch(args, "^(%S+)%s*(.*)$")
	local amount = Bounties:ParseMoney(amountStr or "")
	if not amount then
		Wanted:Print("Usage: /wanted post <amount like 1g 20s> [player name]")
		return
	end
	local guid, name, err = ResolveTarget(strtrim(nameArg or ""))
	if not guid then
		Wanted:Print("Cannot post: %s.", err)
		return
	end
	local bounty, postErr = Bounties:Post(guid, name, amount)
	if not bounty then
		Wanted:Print("Cannot post: %s.", postErr)
		return
	end
	Wanted:Print("Bounty posted: %s on %s, expires in 7 days.", Bounties:FormatMoney(amount), name)
end)

Wanted:RegisterCommand("raise", "Adds to a bounty you can see: /wanted raise <amount> <target name>.", function(args)
	local amountStr, nameArg = strmatch(args, "^(%S+)%s*(.*)$")
	local amount = Bounties:ParseMoney(amountStr or "")
	local guid = nameArg and Store:FindPlayerByName(strtrim(nameArg))
	if not amount or not guid then
		Wanted:Print("Usage: /wanted raise <amount> <player name>")
		return
	end
	local target = nil
	for _, bounty in ipairs(Bounties:GetOpenForTarget(guid)) do
		if bounty.origin == Store:GetOrigin() then
			target = bounty
			break
		end
	end
	if not target then
		Wanted:Print("You have no open bounty on that player.")
		return
	end
	Bounties:Raise(target, amount)
	Wanted:Print("Raised the bounty on %s to %s.", target.data.targetName, Bounties:FormatMoney(Bounties:GetAmount(target)))
end)

Wanted:RegisterCommand("pass", "Hides a bounty from your board as too low: /wanted pass <target name>.", function(args)
	local guid = Store:FindPlayerByName(strtrim(args or ""))
	local open = guid and Bounties:GetOpenForTarget(guid) or {}
	if #open == 0 then
		Wanted:Print("No open bounty on that player.")
		return
	end
	Store:NewRecord("pass", { bounty = open[1].id })
	Wanted:Print("Passed on the bounty on %s.", open[1].data.targetName)
end)

Wanted:RegisterCommand("bounties", "Lists open bounties, highest first (your board filters apply).", function()
	local settings = Wanted.db.settings
	local list = {}
	for bounty in Bounties:OpenIterator() do
		local amount = Bounties:GetAmount(bounty)
		if amount >= (settings.minBounty or 0) and not Bounties:IsPassed(bounty) and (not settings.zoneFilter or bounty.data.zone == settings.zoneFilter) then
			tinsert(list, { bounty = bounty, amount = amount })
		end
	end
	for _, entry in ipairs(list) do
		entry.claimed = Bounties:GetPendingClaim(entry.bounty) ~= nil
	end
	sort(list, function(a, b)
		if a.claimed ~= b.claimed then
			return not a.claimed
		end
		return a.amount > b.amount
	end)
	if #list == 0 then
		Wanted:Print("No open bounties.")
		return
	end
	for _, entry in ipairs(list) do
		local bounty = entry.bounty
		local player = Store:GetPlayer(bounty.data.target)
		local seen = player and player.lastSeen and (" seen "..Ago(player.lastSeen).." ago in "..(player.zone or "?")) or ""
		local left = Bounties:GetExpiry(bounty) - GetServerTime()
		local pending = Bounties:GetPendingClaim(bounty)
		local state = pending and format("CLAIMED by %s, awaiting poster", pending.origin) or (Ago(GetServerTime() - left).." left")
		Wanted:Print("%s on %s (%s %s), by %s, %s%s", Bounties:FormatMoney(entry.amount), bounty.data.targetName, player and player.level or "?", player and player.class or "?", bounty.origin, state, pending and "" or seen)
	end
end)

Wanted:RegisterCommand("claims", "Lists claims on your bounties and claims you made.", function()
	local me = Store:GetOrigin()
	local shown = 0
	for claim in Store:Iterator("claim") do
		local bounty = Store:Get(claim.data.bounty)
		if bounty and (bounty.origin == me or claim.origin == me) then
			local level = Bounties:GetClaimLevel(claim)
			local levelText = level == 0 and "disputed" or level == 1 and "hunter's word only" or level == 2 and (#Bounties:GetWitnesses(claim).." witness(es)") or "confirmed"
			Wanted:Print("%s: %s killed %s for %s (%s)%s", claim.id, claim.origin, claim.data.victimName or "?", Bounties:FormatMoney(Bounties:GetAmount(bounty)), levelText, bounty.origin == me and level < 3 and level > 0 and " - /wanted confirm or dispute "..claim.id or "")
			shown = shown + 1
		end
	end
	if shown == 0 then
		Wanted:Print("No claims involve you.")
	end
end)

local function Decide(args, disputed)
	local claimId = strtrim(args or "")
	local claim = Store:Get(claimId)
	local bounty = claim and Store:Get(claim.data.bounty)
	if not claim or claim.kind ~= "claim" or not bounty or bounty.origin ~= Store:GetOrigin() then
		Wanted:Print("That is not a claim on one of your bounties.")
		return
	end
	Bounties:Decide(claim, disputed)
	if disputed then
		Wanted:Print("Disputed claim %s by %s.", claim.id, claim.origin)
	else
		Wanted:Print("Confirmed claim %s: %s is owed %s.", claim.id, claim.origin, Bounties:FormatMoney(Bounties:GetAmount(bounty)))
	end
end

Wanted:RegisterCommand("confirm", "Confirms a claim on your bounty: /wanted confirm <claim id>.", function(args)
	Decide(args, false)
end)

Wanted:RegisterCommand("dispute", "Disputes a claim on your bounty: /wanted dispute <claim id>.", function(args)
	Decide(args, true)
end)
