-- Wanted: test data. /wanted simulate builds a whole bounty story out of records marked as test data,
-- so claims, witness levels, confirming, owed, reputation and the scoreboard can be checked without an
-- enemy in sight. Test records never leave this client and /wanted purge removes them.

local _, Wanted = ...
local Debug = Wanted:NewModule("Debug")
local Store = Wanted.Store
local Bounties = Wanted.Bounties
local Recorder = Wanted.Recorder

local TARGET_GUID = "Player-TEST-00000001"
local TARGET_NAME = "Corvin Ashdale"
local HUNTER = "Rhea Stormtide"
local WITNESS = "Tobin Greaves"
local OTHER_POSTER = "Hallam Voss"

-- Development builds only: released versions have no test data at all
if not Wanted.DEV then
	return
end

-- The reputation cast for /wanted simulate rep: made-up players with records that differ on purpose
-- Realistic names so screenshots and tests read like the real thing: a reliable hunter, a doubtful one, a
-- poster who pays and one who doesn't
local ACE, SHADY, HONEST, DEADBEAT = "Kaelen Duskbrand", "Vorn Ashgrip", "Maribel Stonehollow", "Grix Tallowbane"

---Builds a record history where good and bad reputations sit side by side:
---  Kaelen Duskbrand: witnessed and confirmed kills, paid. High level, full reliability.
---  Vorn Ashgrip: kills nobody saw, two disputed by the poster. Level 0, no reliability.
---  Maribel Stonehollow: posts and pays. Grix Tallowbane: two confirmed claims never paid (UNPAID).
---Plus open bounties from both posters on the Board, and two of yours with claims to confirm or dispute.
function Debug:SimulateReputation()
	Store:PurgeTest()
	local me = Store:GetOrigin()
	local zone, x, y, mapId = Recorder:GetPosition()
	local now = GetServerTime()
	local day = 86400
	local targets = {}
	for i, def in ipairs({ { "Elyra Moonwhisper", "MAGE", 21 }, { "Dorran Ironvale", "WARRIOR", 23 }, { "Sella Brightwell", "PRIEST", 20 }, { "Thane Oakcrest", "HUNTER", 22 } }) do
		local guid = format("Player-TEST-%08d", 100 + i)
		Store:UpdatePlayer(guid, { name = def[1], class = def[2], level = def[3], faction = "Alliance", guild = "Crimson Vanguard", zone = zone, mapId = mapId, x = x, y = y })
		targets[i] = { guid = guid, name = def[1], level = def[3] }
	end
	-- Ten days of made-up whereabouts for each target, mostly evenings, across a few zones
	local zones = { { zone, mapId, x or 50, y or 50 }, { "Ashenvale", 1440, 70, 60 }, { "Stonetalon Mountains", 1442, 60, 55 } }
	local spotters = { nil, "Tobin Greaves", "Maribel Stonehollow" }
	for i, target in ipairs(targets) do
		local list = {}
		for d = 10, 0, -1 do
			for n = 1, 2 + (i + d) % 3 do
				local hour = 19 + (n + i + d) % 5
				local t = now - d * day - (now % day) + hour * 3600 + n * 900
				if t < now then
					local z = zones[(n + d + i) % #zones + 1]
					tinsert(list, { t = t, zone = z[1], mapId = z[2], x = z[3] + n, y = z[4] - n, by = spotters[(n + d) % #spotters + 1] })
				end
			end
		end
		sort(list, function(a, b) return a.t < b.t end)
		Wanted.db.tracks[target.guid] = list
	end
	local function Bounty(poster, target, amount, t)
		return Store:InsertTest("bounty", poster, { target = target.guid, targetName = target.name, amount = amount, level = target.level, zone = zone }, t)
	end
	-- A kill by the hunter, seen by a witness when witnessed is set; returns the claim on the bounty
	local function Claim(hunter, bounty, target, t, witnessed)
		local deathId = Store:Hash(strjoin("|", target.guid, hunter, tostring(t)))
		local kill = Store:InsertTest("kill", hunter, { killer = "Player-TEST-"..hunter, killerName = hunter, victim = target.guid, victimName = target.name, victimGuild = "Crimson Vanguard", deathId = deathId, zone = zone, x = x, y = y, honor = true }, t)
		if witnessed then
			Store:InsertTest("death", WITNESS, { deathId = deathId, victim = target.guid, victimName = target.name, victimGuild = "Crimson Vanguard", zone = zone, x = x, y = y }, t + 1)
		end
		return Store:InsertTest("claim", hunter, { bounty = bounty.id, kill = kill.id, deathId = deathId, victim = target.guid, victimName = target.name, zone = zone, killT = t }, t + 2)
	end
	local function Confirm(poster, claim, disputed)
		Store:InsertTest("confirm", poster, { claim = claim.id, disputed = disputed or nil }, claim.t + 1800)
	end
	local function Pay(poster, hunter, claim, bounty)
		Store:InsertTest("payment", poster, { claim = claim.id, bounty = bounty.id, to = hunter, amount = Bounties:GetAmount(bounty), side = "payer" }, claim.t + 3600)
	end
	-- Kaelen Duskbrand: six kills on Maribel Stonehollow's bounties over three weeks, witnessed, confirmed and paid
	for i = 1, 6 do
		local t = now - (3 + i * 3) * day
		local target = targets[(i - 1) % #targets + 1]
		local bounty = Bounty(HONEST, target, (40 + i * 10) * 100, t - day)
		local claim = Claim(ACE, bounty, target, t, true)
		Confirm(HONEST, claim)
		Pay(HONEST, ACE, claim, bounty)
	end
	-- Grix Tallowbane: two of Ace's kills confirmed days ago and never paid
	for i = 1, 2 do
		local t = now - (3 + i) * day
		local bounty = Bounty(DEADBEAT, targets[i], 60 * 100, t - day)
		Confirm(DEADBEAT, Claim(ACE, bounty, targets[i], t, true))
	end
	-- Vorn Ashgrip: three kills nobody saw, two of them disputed by the poster
	for i = 1, 3 do
		-- Half a day off Ace's kills: a witness is matched by victim, zone and time
		local t = now - (8 + i) * day + day / 2
		local bounty = Bounty(HONEST, targets[i + 1], 30 * 100, t - day)
		local claim = Claim(SHADY, bounty, targets[i + 1], t, false)
		if i <= 2 then
			Confirm(HONEST, claim, true)
		end
	end
	-- Open bounties on the Board, so each poster's record shows on a row
	Bounty(HONEST, targets[3], 75 * 100, now - 7200)
	Bounty(DEADBEAT, targets[4], 90 * 100, now - 3600)
	-- Two of yours: Ace's witnessed kill to confirm and pay, Shady's unseen one to dispute
	local mine1 = Bounty(me, targets[1], 50 * 100, now - day)
	local aceClaim = Claim(ACE, mine1, targets[1], now - 1200, true)
	-- Kaelen's client saved a proof screenshot of that kill
	Store:InsertTest("proof", ACE, { claim = aceClaim.id, deathId = aceClaim.data.deathId, at = date("%H:%M:%S") }, now - 1190)
	local mine2 = Bounty(me, targets[2], 50 * 100, now - day)
	Claim(SHADY, mine2, targets[2], now - 900, false)
	Wanted:Print("Simulated reputations: %s (reliable hunter), %s (disputed claims), %s (pays), %s (2 unpaid). See the Board, Your bounties > Your live bounties, Leaderboards, and /wanted rep <name>. /wanted purge removes it all.", ACE, SHADY, HONEST, DEADBEAT)
end

Wanted:RegisterCommand("simulate", "Creates test data: a bounty of yours, a witnessed claim on it, and another poster's bounty. /wanted simulate paid adds the payment; /wanted simulate rep builds players with good and bad records.", function(args)
	local me = Store:GetOrigin()
	local zone, x, y, mapId = Recorder:GetPosition()
	local now = GetServerTime()
	if strtrim(args or "") == "rep" then
		Debug:SimulateReputation()
		return
	end
	if strtrim(args or "") == "paid" then
		-- Collect first: adding records while walking the record table can skip some
		local unpaid = {}
		for claim in Store:Iterator("claim") do
			if Store:IsTest(claim) and claim.origin == HUNTER and not Wanted.Payments:GetForClaim(claim.id) then
				tinsert(unpaid, claim)
			end
		end
		for _, claim in ipairs(unpaid) do
			Store:InsertTest("payment", HUNTER, { claim = claim.id, bounty = claim.data.bounty, from = me, amount = Bounties:GetAmount(Store:Get(claim.data.bounty)), side = "payee" })
		end
		local paid = #unpaid
		Wanted:Print("Simulated %d payment(s) received by %s.", paid, HUNTER)
		return
	end
	Store:PurgeTest()
	-- An enemy, seen twice
	Store:UpdatePlayer(TARGET_GUID, { name = TARGET_NAME, class = "ROGUE", level = 22, faction = "Alliance", guild = "Crimson Vanguard", zone = zone, mapId = mapId, x = x, y = y })
	Store:AddSighting(TARGET_GUID, zone, x, y, mapId)
	-- Your bounty on them, posted yesterday, raised today
	local bounty = Store:InsertTest("bounty", me, { target = TARGET_GUID, targetName = TARGET_NAME, amount = 50 * 100, level = 22, zone = zone }, now - 86400)
	Store:InsertTest("raise", me, { bounty = bounty.id, amount = 30 * 100 }, now - 3600)
	-- Someone else's bounty on the same target, too low for most
	Store:InsertTest("bounty", OTHER_POSTER, { target = TARGET_GUID, targetName = TARGET_NAME, amount = 15 * 100, level = 22, zone = zone }, now - 7200)
	-- A hunter killed them ten minutes ago with honor credit, and a bystander saw the death
	local killT = now - 600
	local deathId = Store:Hash(strjoin("|", TARGET_GUID, zone, floor(killT / 10)))
	local kill = Store:InsertTest("kill", HUNTER, { killer = "Player-TEST-00000002", killerName = HUNTER, killerGuild = "Bloodfang Syndicate", victim = TARGET_GUID, victimName = TARGET_NAME, victimGuild = "Crimson Vanguard", deathId = deathId, zone = zone, x = x, y = y, honor = true }, killT)
	Store:InsertTest("death", WITNESS, { deathId = deathId, victim = TARGET_GUID, victimName = TARGET_NAME, victimGuild = "Crimson Vanguard", zone = zone, x = x, y = y }, killT + 1)
	-- Their claims on both bounties
	Store:InsertTest("claim", HUNTER, { bounty = bounty.id, kill = kill.id, deathId = deathId, victim = TARGET_GUID, victimName = TARGET_NAME, zone = zone, killT = killT }, killT + 2)
	local others = {}
	for other in Store:Iterator("bounty") do
		if other.origin == OTHER_POSTER and Store:IsTest(other) then
			tinsert(others, other)
		end
	end
	for _, other in ipairs(others) do
		Store:InsertTest("claim", HUNTER, { bounty = other.id, kill = kill.id, deathId = deathId, victim = TARGET_GUID, victimName = TARGET_NAME, zone = zone, killT = killT }, killT + 2)
	end
	-- A history for the hunter: two older confirmed claims by the other poster, one paid
	for i = 1, 2 do
		local old = Store:InsertTest("bounty", OTHER_POSTER, { target = TARGET_GUID, targetName = TARGET_NAME, amount = 40 * 100, level = 22, zone = zone }, now - (10 + i) * 86400)
		local oldClaim = Store:InsertTest("claim", HUNTER, { bounty = old.id, kill = kill.id, deathId = deathId.."x"..i, victim = TARGET_GUID, victimName = TARGET_NAME, zone = zone, killT = old.t + 3600 }, old.t + 3601)
		Store:InsertTest("confirm", OTHER_POSTER, { claim = oldClaim.id }, old.t + 7200)
		if i == 1 then
			Store:InsertTest("payment", OTHER_POSTER, { claim = oldClaim.id, bounty = old.id, to = HUNTER, amount = 40 * 100, side = "payer" }, old.t + 7300)
		end
	end
	Wanted:Print("Simulated: %s (%s) has an 80s bounty from you and a 15s one from %s; %s killed them 10 minutes ago, %s saw it. Look at Bounties, Claims, Owed, Top, and /wanted rep %s. /wanted purge removes it all.", TARGET_NAME, "level 22 rogue", OTHER_POSTER, HUNTER, WITNESS, HUNTER)
end)

Wanted:RegisterCommand("purge", "Removes all test data.", function()
	local removed = Store:PurgeTest()
	Wanted:Print("Removed %d test records.", removed)
end)
