-- Wanted: test data. /wanted simulate builds a whole bounty story out of records marked as test data,
-- so claims, witness levels, confirming, owed, reputation and the scoreboard can be checked without an
-- enemy in sight. Test records never leave this client and /wanted purge removes them.

local _, Wanted = ...
local Debug = Wanted:NewModule("Debug")
local Store = Wanted.Store
local Bounties = Wanted.Bounties
local Recorder = Wanted.Recorder

local TARGET_GUID = "Player-TEST-00000001"
local TARGET_NAME = "Testy Alliance"
local HUNTER = "Test Hunter"
local WITNESS = "Test Witness"
local OTHER_POSTER = "Test Poster"

-- Development builds only: released versions have no test data at all
if not Wanted.DEV then
	return
end

Wanted:RegisterCommand("simulate", "Creates test data: a bounty of yours, a witnessed claim on it, and another poster's bounty. /wanted simulate paid adds the payment.", function(args)
	local me = Store:GetOrigin()
	local zone, x, y, mapId = Recorder:GetPosition()
	local now = GetServerTime()
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
	Store:UpdatePlayer(TARGET_GUID, { name = TARGET_NAME, class = "ROGUE", level = 22, faction = "Alliance", guild = "Test Gankers", zone = zone, mapId = mapId, x = x, y = y })
	Store:AddSighting(TARGET_GUID, zone, x, y, mapId)
	-- Your bounty on them, posted yesterday, raised today
	local bounty = Store:InsertTest("bounty", me, { target = TARGET_GUID, targetName = TARGET_NAME, amount = 50 * 100, level = 22, zone = zone }, now - 86400)
	Store:InsertTest("raise", me, { bounty = bounty.id, amount = 30 * 100 }, now - 3600)
	-- Someone else's bounty on the same target, too low for most
	Store:InsertTest("bounty", OTHER_POSTER, { target = TARGET_GUID, targetName = TARGET_NAME, amount = 15 * 100, level = 22, zone = zone }, now - 7200)
	-- A hunter killed them ten minutes ago with honor credit, and a bystander saw the death
	local killT = now - 600
	local deathId = Store:Hash(strjoin("|", TARGET_GUID, zone, floor(killT / 10)))
	local kill = Store:InsertTest("kill", HUNTER, { killer = "Player-TEST-00000002", killerName = HUNTER, killerGuild = "Test Hunters Guild", victim = TARGET_GUID, victimName = TARGET_NAME, victimGuild = "Test Gankers", deathId = deathId, zone = zone, x = x, y = y, honor = true }, killT)
	Store:InsertTest("death", WITNESS, { deathId = deathId, victim = TARGET_GUID, victimName = TARGET_NAME, victimGuild = "Test Gankers", zone = zone, x = x, y = y }, killT + 1)
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
