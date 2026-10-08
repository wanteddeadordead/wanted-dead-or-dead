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
Bounties.MIN_BOUNTY = MIN_BOUNTY
-- A death record from another client counts as a witness within this many seconds of the kill
local WITNESS_WINDOW = 30
Bounties.WITNESS_WINDOW = WITNESS_WINDOW



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Bounties:OnEnable()
	-- Whether a bounty is open depends on bounty records only: its raises (expiry), claims confirmed by the
	-- poster, payments, withdrawals and hunts. Deaths and kills in a busy fight don't change it.
	for _, kind in ipairs({ "bounty", "raise", "claim", "confirm", "payment", "withdraw", "hunt" }) do
		Store:OnRecord(kind, function() private.openCache = nil end)
	end
	Store:OnRecord("kill", private.OnKill)
	Store:OnRecord("bounty", private.LearnTarget)
	Store:OnRecord("bounty", private.OnBountyNews)
	Store:OnRecord("raise", private.OnBountyNews)
end

---What a bounty says about its target (the poster's notes when they posted it), for a client that doesn't know
---them: fills only what this client doesn't know, and a last sighting only if newer than its own, marked as
---seen by the poster. Never counts as this client seeing them.
function private.LearnTarget(bounty, isOwn)
	local d = bounty.data
	if isOwn or type(d.target) ~= "string" or Store:IsTest(bounty) then
		return
	end
	local player = Store:GetPlayer(d.target) or {}
	local info = {}
	local function Fill(key, value, kind)
		if player[key] == nil and type(value) == kind then
			info[key] = value
		end
	end
	Fill("name", d.targetName, "string")
	Fill("class", d.class, "string")
	Fill("race", d.race, "string")
	Fill("level", d.level, "number")
	Fill("guild", d.targetGuild, "string")
	Fill("faction", d.faction, "string")
	if type(d.seenAt) == "number" and d.seenAt <= GetServerTime() and d.seenAt > (player.lastSeen or 0) then
		info.lastSeen = d.seenAt
		info.seenBy = bounty.origin
		info.zone = type(d.zone) == "string" and d.zone or nil
		info.x = type(d.x) == "number" and d.x or nil
		info.y = type(d.y) == "number" and d.y or nil
		info.mapId = type(d.mapId) == "number" and d.mapId or nil
	end
	if next(info) then
		Store:UpdatePlayer(d.target, info, false)
	end
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
	local copper
	if strmatch(str, "^%d+%.?%d*$") then
		copper = floor(tonumber(str) * 10000 + 0.5)
	else
		copper = private.ParseUnits(str)
	end
	-- More than the game's money holds would be refused by everyone else (Store:IsWellFormed)
	return copper and copper <= Store.MAX_COPPER and copper or nil
end

---"1g 20s", "50s" or "150c" in copper, or nil.
function private.ParseUnits(str)
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

---The total amount on a bounty, including the poster's raises (those made by a time, when given).
---@param bounty table
---@param at number? a server time: only raises made at or before it count
---@return number
function Bounties:GetAmount(bounty, at)
	local amount = bounty.data.amount
	-- A record never read (Store:Iterator) can still reach a listener as it arrives
	if type(amount) ~= "number" then
		return 0
	end
	for raise in Store:Iterator("raise") do
		if (not at or raise.t <= at) and private.IsPostersWord(raise, bounty) then
			amount = amount + raise.data.amount
		end
	end
	-- At most what the game's money holds (a record from before the cap can say more)
	return min(amount, Store.MAX_COPPER)
end

---What a claim is owed: the bounty as it stood at the kill. A raise after it doesn't raise what's owed.
---@param claim table
---@return number
function Bounties:GetOwed(claim)
	local bounty = Store:Get(claim.data.bounty)
	if not bounty then
		return 0
	end
	local killT = claim.data.killT
	return Bounties:GetAmount(bounty, type(killT) == "number" and killT or claim.t)
end

---Whether a record about a bounty (a raise, a withdrawal, a payment) is its poster's: anyone else's raise doesn't add
---to what the poster owes, and anyone else's withdrawal or payment record doesn't end the bounty.
---@param record table
---@param bounty table
---@return boolean
function private.IsPostersWord(record, bounty)
	return record.data.bounty == bounty.id and record.origin == bounty.origin
end

---When a bounty expires (raises extend it from the raise).
---@param bounty table
---@return number
function Bounties:GetExpiry(bounty)
	local expiry = bounty.t + EXPIRY_SECONDS
	for raise in Store:Iterator("raise") do
		if private.IsPostersWord(raise, bounty) then
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
		if claim.data.bounty == bounty.id and (Bounties:GetClaimLevel(claim) >= 3 or Wanted.Payments:GetForClaim(claim.id)) then
			return true
		end
	end
	-- The poster's own record that they paid (its claim may not be here yet)
	for payment in Store:Iterator("payment") do
		if private.IsPostersWord(payment, bounty) then
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
	return private.WithdrawnAt(bounty) ~= nil
end

---When a bounty's withdrawal that counted was made (the earliest, if several), or nil.
---@param bounty table
---@return number? serverTime
function private.WithdrawnAt(bounty)
	local at = nil
	for withdraw in Store:Iterator("withdraw") do
		if withdraw.data.bounty == bounty.id and withdraw.origin == bounty.origin and (not at or withdraw.t < at) and #Bounties:GetActiveHunters(bounty, withdraw.t) == 0 then
			at = withdraw.t
		end
	end
	return at
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
	return private.CopyList(private.OpenCache().byTarget[guid])
end

-- Which bounties are open, by target and by guild. Working that out walks every record several times over, and
-- the Nearby window asks for each enemy it lists, so it's kept until any record arrives or a minute passes (or
-- the next bounty expires, if sooner).
local OPEN_CACHE_SECONDS = 60

function private.OpenCache()
	local now = GetServerTime()
	local cache = private.openCache
	if cache and now < cache.validUntil then
		return cache
	end
	cache = { byTarget = {}, byGuild = {}, validUntil = now + OPEN_CACHE_SECONDS }
	for bounty in Bounties:OpenIterator() do
		local target, guild = bounty.data.target, bounty.data.guild
		if target then
			cache.byTarget[target] = cache.byTarget[target] or {}
			tinsert(cache.byTarget[target], bounty)
		end
		if guild then
			cache.byGuild[guild] = cache.byGuild[guild] or {}
			tinsert(cache.byGuild[guild], bounty)
		end
		cache.validUntil = min(cache.validUntil, Bounties:GetExpiry(bounty))
	end
	private.openCache = cache
	return cache
end

function private.CopyList(list)
	local copy = {}
	for i, item in ipairs(list or {}) do
		copy[i] = item
	end
	return copy
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
	if not guild then
		return {}
	end
	return private.CopyList(private.OpenCache().byGuild[guild])
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

---Posts a bounty on a guild: the first kill of any one member claims it, once.
---@param guild string
---@param faction string? the guild's faction as seen
---@param amount number copper
---@return table? bounty
---@return string? err
function Bounties:PostGuild(guild, faction, amount)
	if amount < MIN_BOUNTY then
		return nil, "the minimum bounty is "..Bounties:FormatMoney(MIN_BOUNTY)
	elseif amount > Store.MAX_COPPER then
		return nil, "that's more than the game's money holds"
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
	elseif amount > Store.MAX_COPPER then
		return nil, "that's more than the game's money holds"
	end
	if Bounties:GetMyOpen(guid) then
		-- One bounty per poster per target; more gold goes onto the existing one
		return nil, "you already have a bounty on "..(name or "them")..", raise it instead"
	end
	local player = Store:GetPlayer(guid)
	if player and player.faction and player.faction == UnitFactionGroup("player") then
		return nil, "bounties are for the other faction only"
	end
	Store:UpdatePlayer(guid, { name = name }, false)
	-- What we know about them goes with it, so hunters who never saw them (another realm, or offline at the
	-- time) still know who and where to look (LearnTarget)
	local bounty = Store:NewRecord("bounty", {
		target = guid,
		targetName = name,
		targetGuild = player and player.guild or nil,
		amount = amount,
		level = player and player.level or nil,
		zone = player and player.zone or nil,
		class = player and player.class or nil,
		race = player and player.race or nil,
		faction = player and player.faction or nil,
		seenAt = player and player.lastSeen or nil,
		x = player and player.x or nil,
		y = player and player.y or nil,
		mapId = player and player.mapId or nil,
	})
	Wanted:Log("Bounties: posted %s on %s", Bounties:FormatMoney(amount), name)
	return bounty
end



---Adds to a bounty.
---@param bounty table
---@param amount number copper
---@return table? raise nil when the amount isn't one others would take
function Bounties:Raise(bounty, amount)
	if type(amount) ~= "number" or amount <= 0 or amount ~= floor(amount) or amount > Store.MAX_COPPER then
		return nil
	end
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
	if not Wanted:InInstance() and UnitExists("target") and UnitIsPlayer("target") then
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
	private.IndexOwnKill(kill)
	if not isOwn then
		return
	end
	-- Bounties on this player, and on the guild they belong to
	local matching = Bounties:GetOpenForTarget(kill.data.victim)
	for _, bounty in ipairs(Bounties:GetOpenForGuild(kill.data.victimGuild)) do
		tinsert(matching, bounty)
	end
	for _, bounty in ipairs(matching) do
		if private.FileClaim(bounty, kill) then
			local text = format("killed %s, wanted for %s by %s. Claim filed.", kill.data.victimName or "?", Bounties:FormatMoney(Bounties:GetAmount(bounty)), bounty.origin)
			private.AnnounceClaim("Bounty collected: you "..text, "You "..text)
		end
	end
end

---Files this client's claim on a bounty for one of its kills, unless it can't: the bounty is ours, we already
---claimed it, or this client waits for an update (claims are shared records). Returns the claim filed.
---@param bounty table
---@param kill table
---@return table? claim
function private.FileClaim(bounty, kill)
	local me = Store:GetOrigin()
	-- Your own bounty is not something you can collect on
	if bounty.origin == me or Wanted:GetRequiredUpdate() then
		return nil
	end
	for claim in Store:Iterator("claim") do
		if claim.data.bounty == bounty.id and claim.origin == me then
			return nil
		end
	end
	return Store:NewRecord("claim", {
		bounty = bounty.id,
		kill = kill.id,
		deathId = kill.data.deathId,
		victim = kill.data.victim,
		victimName = kill.data.victimName,
		victimGuild = kill.data.victimGuild,
		zone = kill.data.zone,
		killT = kill.t,
	})
end

---Says a claim was filed in chat and on screen: it's money owed, so it shows even with enemy alerts off (the
---sound still follows mute).
---@param chat string
---@param banner string? the line under the banner's title, default the chat line
function private.AnnounceClaim(chat, banner)
	Wanted:Print(chat)
	local Alerts = Wanted.Alerts
	Alerts:Warn("BOUNTY COLLECTED", banner or chat, Wanted.Theme.C.gold)
	Alerts:Sound("important")
end



-- ============================================================================
-- Late claims: a bounty learned of after the kill
-- ============================================================================

-- A bounty can reach this client after its kill (the sync channel, a peer's resync, the desktop app's
-- catch-up), and a raise it didn't know of can make a kill fall inside it. Each one is checked against this
-- client's own kills once the records arriving with it are in (queued work runs after them), so a withdrawal or
-- payment in the same batch counts.

---This client's own kills by victim GUID and by victim guild: built on first use, kept as kills arrive, built
---again when the records table is replaced (a fresh start).
function private.OwnKills()
	local records = Wanted.db.records
	local index = private.ownKills
	if not index or index.records ~= records then
		index = { records = records, byVictim = {}, byGuild = {} }
		private.ownKills = index
		for kill in Store:Iterator("kill") do
			private.IndexOwnKill(kill)
		end
	end
	return index
end

function private.IndexOwnKill(kill)
	local index = private.ownKills
	if not index or index.records ~= Wanted.db.records or kill.origin ~= Store:GetOrigin() or Store:IsTest(kill) then
		return
	end
	for key, list in pairs({ victim = index.byVictim, victimGuild = index.byGuild }) do
		local value = kill.data[key]
		if type(value) == "string" then
			list[value] = list[value] or {}
			tinsert(list[value], kill)
		end
	end
end

function private.OnBountyNews(record, isOwn)
	local id = record.kind == "bounty" and record.id or record.data.bounty
	if isOwn or type(id) ~= "string" then
		return
	end
	private.lateQueue = private.lateQueue or {}
	if not next(private.lateQueue) then
		Wanted:QueueWork(private.ClaimLateQueued)
	end
	private.lateQueue[id] = true
end

function private.ClaimLateQueued()
	local ids = private.lateQueue or {}
	private.lateQueue = {}
	for id in pairs(ids) do
		local bounty = Store:Get(id)
		if bounty and bounty.kind == "bounty" then
			private.ClaimLate(bounty)
		end
	end
end

---Claims a bounty with this client's latest kill of its target (or a member of its guild) made while it was
---open: at or after it was posted, before it expired or was withdrawn. Not one settled already.
---@param bounty table
---@return table? claim
function private.ClaimLate(bounty)
	if bounty.origin == Store:GetOrigin() or Store:IsTest(bounty) or Bounties:IsSettled(bounty) then
		return nil
	end
	local index = private.OwnKills()
	local d = bounty.data
	local kills = (type(d.target) == "string" and index.byVictim[d.target]) or (type(d.guild) == "string" and index.byGuild[d.guild])
	if not kills then
		return nil
	end
	local ends = min(Bounties:GetExpiry(bounty), private.WithdrawnAt(bounty) or math.huge)
	local latest = nil
	for _, kill in ipairs(kills) do
		if Store:Get(kill.id) == kill and kill.t >= bounty.t and kill.t < ends and (not latest or kill.t > latest.t) then
			latest = kill
		end
	end
	local claim = latest and private.FileClaim(bounty, latest)
	if claim then
		private.AnnounceClaim(format("You killed %s earlier, and there was a %s bounty on them. Claim filed.", latest.data.victimName or "?", Bounties:FormatMoney(Bounties:GetAmount(bounty))))
	end
	return claim
end

---Other clients that recorded the same death as a claim's kill (same victim, same place, within the window). Only
---a death record that is its origin's own word counts (Store:IsTrusted): one relayed by another player could be
---forged by them to make a claim look witnessed.
---@param claim table
---@return string[] origins
---@return boolean victimsOwn whether one of them is the victim's own record of the death naming the claim's killer
function Bounties:GetWitnesses(claim)
	local witnesses = {}
	local seen = {}
	local victimsOwn = false
	for death in Store:Iterator("death") do
		local data = death.data
		if death.origin ~= claim.origin and data.victim == claim.data.victim and data.zone == claim.data.zone
			and abs(death.t - claim.data.killT) <= WITNESS_WINDOW and Store:IsTrusted(death) then
			if not seen[death.origin] then
				seen[death.origin] = true
				tinsert(witnesses, death.origin)
			end
			victimsOwn = victimsOwn or private.IsVictimsOwn(death, claim)
		end
	end
	return witnesses, victimsOwn
end

---Whether a death record is the victim's own, naming the claim's killer: its origin is the victim's character (a
---trusted link record of that origin names the victim's GUID, or it's one of this account's characters) and it
---names the killer of the claim's kill. Nobody backs up the one who killed them, so it's the strongest witness.
function private.IsVictimsOwn(death, claim)
	local victim, killer = death.data.victim, death.data.killer
	local kill = type(claim.data.kill) == "string" and Store:Get(claim.data.kill)
	if type(killer) ~= "string" or not kill or kill.data.killer ~= killer then
		return false
	end
	local character = Wanted.db.characters and Wanted.db.characters[victim]
	if character and character.n == death.origin then
		return true
	end
	for link in Store:Iterator("link") do
		if link.origin == death.origin and link.data.guid == victim and Store:IsTrusted(link) then
			return true
		end
	end
	return false
end

-- A witness whose records started less than this long before the kill is new to the network
local NEW_WITNESS_SECONDS = 24 * 60 * 60
-- A witness who has backed up at least this many claims, all by one hunter, only ever backs up that hunter
local LOYAL_WITNESS_CLAIMS = 3

---Whether a witness is new: their first record came less than a day before the kill, or we hold so few of
---their records that we can't tell they've been around. The first record's time is kept with their chain, as the
---record itself may be pruned.
function private.IsNewWitness(origin, killT)
	local first = Store:Get(origin..":"..(Store:SeqBase() + 1))
	local firstT = first and first.t or Store:GetFirstSeen(origin)
	if firstT then
		return killT - firstT < NEW_WITNESS_SECONDS
	end
	return Store:GetChainSeq(origin) - Store:SeqBase() < 10
end

---The hunter a witness only ever backs up, when every claim they've witnessed (at least a few) is one hunter's.
function private.OnlyBacks(origin)
	local hunter, count = nil, 0
	for claim in Store:Iterator("claim") do
		for _, w in ipairs(Bounties:GetWitnesses(claim)) do
			if w == origin then
				if hunter and claim.origin ~= hunter then
					return nil
				end
				hunter, count = claim.origin, count + 1
				break
			end
		end
	end
	return count >= LOYAL_WITNESS_CLAIMS and hunter or nil
end

---What should give a poster pause before paying a claim: nobody else recorded the death, or its only witnesses
---are new to the network or only ever back up this hunter. A modified addon can fake a kill; these are the
---signs of it. Empty when the claim looks sound.
---@param claim table
---@return string[] warnings
function Bounties:GetClaimWarnings(claim)
	local warnings = {}
	local witnesses, victimsOwn = Bounties:GetWitnesses(claim)
	if #witnesses == 0 then
		tinsert(warnings, "Nobody else recorded this death: only the bounty hunter's own addon says it happened.")
		return warnings
	end
	-- The victim's own record of who killed them settles it
	if victimsOwn then
		return warnings
	end
	local killT = claim.data.killT or claim.t
	local sound = false
	for _, w in ipairs(witnesses) do
		local loyal = private.OnlyBacks(w)
		if loyal then
			tinsert(warnings, format("%s only ever backs up %s's claims.", w, loyal))
		elseif private.IsNewWitness(w, killT) then
			tinsert(warnings, format("%s is new to the network: their first record came less than a day before the kill.", w))
		else
			sound = true
		end
	end
	-- One sound witness is enough to trust the death happened
	if sound then
		return {}
	end
	return warnings
end

---The death's page on the website, with every record of it from both factions: who the victim's own record
---says killed them, what other players' apps saw, and how well the kill is backed.
---@param claim table
---@return string url
function Bounties:DeathPageURL(claim)
	return format("https://wanteddeadordead.com/death/%s/%d", claim.data.victim or "", claim.data.killT or claim.t)
end

---The claim that gets the bounty. Once the poster has paid (by their own record) or confirmed one, that one: their decision stands, and
---nobody else is owed for the same bounty. Otherwise the earliest kill among witnessed claims whose kill fell while
---the bounty was open (IsInWindow), and failing those (shown as unverified, owed nothing yet) among the rest. Every
---hunter can chase a bounty; whoever got the kill first wins it (ties go to the lower id, so every client agrees).
---@param bounty table
---@return table? claim
function Bounties:GetWinningClaim(bounty)
	local paid, confirmed, witnessed, lone
	for claim in Store:Iterator("claim") do
		if claim.data.bounty == bounty.id then
			local level = Bounties:GetClaimLevel(claim)
			-- Only the poster's own record of paying picks a claim: a hunter's record of being paid could be anyone's
			if Wanted.Payments:GetForClaim(claim.id, true) then
				paid = private.EarlierKill(paid, claim)
			elseif level == 3 then
				confirmed = private.EarlierKill(confirmed, claim)
			elseif level > 0 and Bounties:IsInWindow(claim, bounty) then
				if level == 2 then
					witnessed = private.EarlierKill(witnessed, claim)
				else
					lone = private.EarlierKill(lone, claim)
				end
			end
		end
	end
	return paid or confirmed or witnessed or lone
end

---When a claim's kill was: its killT, or the claim's own time when that isn't a number (older claims have none).
function private.KillTime(claim)
	local killT = claim.data.killT
	return type(killT) == "number" and killT or claim.t
end

---Whichever of two claims (the first may be nil) has the earlier kill, the lower id on a tie.
function private.EarlierKill(best, claim)
	if not best then
		return claim
	end
	local t, bestT = private.KillTime(claim), private.KillTime(best)
	if t < bestT or (t == bestT and claim.id < best.id) then
		return claim
	end
	return best
end

---Whether a claim's kill fell while its bounty was open: at or after it was posted, before it expired or was
---withdrawn, and no later than the claim itself.
---@param claim table
---@param bounty table
---@return boolean
function Bounties:IsInWindow(claim, bounty)
	local killT = private.KillTime(claim)
	return killT >= bounty.t and killT <= claim.t and killT < Bounties:GetExpiry(bounty)
		and killT < (private.WithdrawnAt(bounty) or math.huge)
end

---The claim's level: 1 own client, 2 witnessed (a trusted witness, the victim's own record included), 3 confirmed
---by the poster. Disputed returns 0.
---@param claim table
---@return number
function Bounties:GetClaimLevel(claim)
	local bounty = Store:Get(claim.data.bounty)
	-- The poster's latest decision stands (by time, then by seq), so every client agrees whatever order they came in
	local decision
	for confirm in Store:Iterator("confirm") do
		if confirm.data.claim == claim.id and bounty and confirm.origin == bounty.origin
			and (not decision or confirm.t > decision.t or (confirm.t == decision.t and confirm.seq > decision.seq)) then
			decision = confirm
		end
	end
	if decision then
		return decision.data.disputed and 0 or 3
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
		if not Wanted:InInstance() and UnitExists("target") and UnitIsPlayer("target") then
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
			local levelText = level == 0 and "disputed" or level == 1 and "bounty hunter's word only" or level == 2 and (#Bounties:GetWitnesses(claim).." witness(es)") or "confirmed"
			Wanted:Print("%s: %s killed %s for %s (%s)%s", claim.id, claim.origin, claim.data.victimName or "?", Bounties:FormatMoney(Bounties:GetOwed(claim)), levelText, bounty.origin == me and level < 3 and level > 0 and " - /wanted confirm or dispute "..claim.id or "")
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
		Wanted:Print("Confirmed claim %s: %s is owed %s.", claim.id, claim.origin, Bounties:FormatMoney(Bounties:GetOwed(claim)))
	end
end

Wanted:RegisterCommand("confirm", "Confirms a claim on your bounty: /wanted confirm <claim id>.", function(args)
	Decide(args, false)
end)

Wanted:RegisterCommand("dispute", "Disputes a claim on your bounty: /wanted dispute <claim id>.", function(args)
	Decide(args, true)
end)
