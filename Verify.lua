-- Wanted: checking other players' signatures. A signed record from an origin whose key is known is checked once and
-- what was found is kept (WantedDB.sigChecked[id]: true or false). A bad signature from a known key marks it tampered, so it's never
-- read, like a record altered in transit. From 1.19.3 an authority record passed on in a keyed player's name counts
-- only once its signature checks out (Store:Authority); until then it decides nothing.
-- A check takes about 23 ms in the game, so it's done only when wanted, a slice a frame (Crypto:Check), never in a
-- fight: first the records something is reading or showing (on demand), then, one a second, the rest held (in the
-- background, which can be turned off in the settings).

local _, Wanted = ...
local Verify = Wanted:NewModule("Verify")
local Crypto = Wanted.Crypto
local private = {
	urgent = {}, -- record ids to check next (something reads or shows them)
	background = {}, -- record ids to check one a second
	queued = {}, -- id -> true while in either list
	challengers = {}, -- sender -> records (not held) waiting to be checked before they may replace a held one
	challengerSenders = {}, -- the senders with challengers waiting, taken in turn
	running = nil, -- the record being checked
	checked = 0, -- this session: checks done
	bad = 0, -- this session: bad signatures found
}
-- Bounties posted, hunted or claimed by this character: records arriving about them are checked at once. Worked out
-- again at most this often
local MINE_SECONDS = 10
-- Challengers (Verify:Challenge) waiting from one sender at most: a whole fill's worth (Sync's MAX_FILL_PER_REQUEST),
-- so an honest filler's catch-up over held forgeries never loses one (a dropped record isn't asked for again)
local MAX_CHALLENGERS_PER_SENDER = 200



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Verify:OnEnable()
	local Store = Wanted.Store
	-- Records arriving about bounties that are this character's business are checked at once; the rest in the
	-- background
	Store:OnRecord("*", private.OnRecord)
	-- What's held already, for the background: a kind per piece of work
	for kind in pairs(Wanted.Signing.KINDS) do
		Wanted:QueueWork(function()
			for record in Store:Iterator(kind) do
				Verify:Want(record)
			end
		end)
	end
	C_Timer.NewTicker(1, function() Verify:BackgroundStep() end)
end

function private.OnRecord(record, isOwn)
	if isOwn and (record.kind == "bounty" or record.kind == "hunt" or record.kind == "claim") then
		private.mine = nil
	end
	if isOwn or not record.id or not Wanted.Signing.KINDS[record.kind] then
		return
	end
	Verify:Want(record, private.IsMine(record))
end

---A record relayed under an id already held by one that isn't its origin's word, signed as the origin's, which the
---store couldn't check at once (Store.private.Insert): checked in its turn, after what's being read; found good, it
---takes the held one's place (Store:MergeVerified), found bad, it's dropped. Senders are taken in turn, so one
---sender's junk can't keep another's waiting, and one sender has only so many waiting.
---@param record table not held
---@param sender string? who relayed it
function Verify:Challenge(record, sender)
	sender = type(sender) == "string" and sender or "?"
	local list = private.challengers[sender]
	if not list then
		list = {}
		private.challengers[sender] = list
		tinsert(private.challengerSenders, sender)
	end
	for _, waiting in ipairs(list) do
		if waiting.id == record.id and waiting.hash == record.hash then
			return
		end
	end
	if #list >= MAX_CHALLENGERS_PER_SENDER then
		Wanted:Log("!! Verify: %s has %d records waiting to be checked already; %s left out", sender, #list, tostring(record.id))
		return
	end
	tinsert(list, record)
	private.RunNext()
end

---The next challenger to check, the senders taken in turn, or nil.
function private.NextChallenger()
	local senders = private.challengerSenders
	for _ = 1, #senders do
		local sender = tremove(senders, 1)
		local list = private.challengers[sender]
		local record = list and tremove(list, 1)
		if list and #list > 0 then
			tinsert(senders, sender)
		else
			private.challengers[sender] = nil
		end
		if record then
			return record
		end
	end
	return nil
end

---Whether a record is about a bounty this character posted, hunts or claimed.
function private.IsMine(record)
	local data = record.data
	local id = data.bounty
	if not id and type(data.claim) == "string" then
		local claim = Wanted.Store:Get(data.claim)
		id = claim and claim.data.bounty
	end
	return type(id) == "string" and private.MyBounties()[id] == true
end

function private.MyBounties()
	local now = GetTime()
	if private.mine and now < private.mineUntil then
		return private.mine
	end
	local Store = Wanted.Store
	local me = Store:GetOrigin()
	local mine = {}
	for bounty in Store:Iterator("bounty") do
		if bounty.origin == me then
			mine[bounty.id] = true
		end
	end
	for _, kind in ipairs({ "hunt", "claim" }) do
		for record in Store:Iterator(kind) do
			if record.origin == me and type(record.data.bounty) == "string" then
				mine[record.data.bounty] = true
			end
		end
	end
	private.mine, private.mineUntil = mine, now + MINE_SECONDS
	return mine
end



-- ============================================================================
-- The queue
-- ============================================================================

---The key a record is signed with, if it's one this client can check: an authority record of another player's,
---signed, not checked yet, not tampered, by a key known for its origin.
---@param record table
---@return table? key the key book's entry
---@return string? sig the signature's base64
---@param challenger boolean? a record not held (Verify:Challenge): what's known of the held record's signature under
---its id says nothing about it
function private.Checkable(record, challenger)
	local sig = record.data and record.data.sig
	if (not challenger and Wanted.db.sigChecked[record.id] ~= nil) or record.tampered or type(sig) ~= "string" or #sig ~= Wanted.Signing.SIG_LENGTH
		or strsub(sig, 1, 1) ~= Wanted.Signing.SIG_VERSION or not Wanted.Signing.KINDS[record.kind]
		or record.origin == Wanted.Store:GetOrigin() or Wanted.Store:IsTest(record) then
		return nil
	end
	return Wanted.KeyBook:Find(record.origin, strsub(sig, 2, 9)), strsub(sig, 10)
end

---Asks for a record's signature to be checked: next when urgent (something reads or shows it), else in the
---background. Cheap when there's nothing to check, so readers can call it on every record they read.
---@param record table
---@param urgent boolean?
function Verify:Want(record, urgent)
	if type(record.data) ~= "table" or type(record.data.sig) ~= "string" or Wanted.db.sigChecked[record.id] ~= nil then
		return
	end
	local id = record.id
	if private.queued[id] then
		if urgent and private.queued[id] ~= "urgent" then
			private.queued[id] = "urgent"
			tinsert(private.urgent, id)
			private.RunNext()
		end
		return
	end
	if not private.Checkable(record) then
		return
	end
	private.queued[id] = urgent and "urgent" or "background"
	tinsert(urgent and private.urgent or private.background, id)
	if urgent then
		private.RunNext()
	end
end

---Asks for a bounty's records to be checked now: the bounty and everything about it (raises, withdrawals, hunts,
---claims and their confirms, payments). For the bounty's page.
---@param bounty table
function Verify:WantBounty(bounty)
	local Store = Wanted.Store
	Verify:Want(bounty, true)
	local claims = {}
	for _, kind in ipairs({ "raise", "withdraw", "hunt", "claim", "payment" }) do
		for record in Store:Iterator(kind) do
			if record.data.bounty == bounty.id then
				Verify:Want(record, true)
				if kind == "claim" then
					claims[record.id] = true
				end
			end
		end
	end
	for _, kind in ipairs({ "confirm", "payment" }) do
		for record in Store:Iterator(kind) do
			if claims[record.data.claim] then
				Verify:Want(record, true)
			end
		end
	end
end

---A new key for an origin: its signed records not checked yet may be checkable now.
---@param origin string
function Verify:OnKeyLearned(origin)
	if not Wanted.Store then
		return
	end
	for record in Wanted.Store:OriginIterator(origin) do
		if not record.tampered then
			Verify:Want(record)
		end
	end
end

---One a second, out of a fight, when nothing else is being checked: the next record from the background.
function Verify:BackgroundStep()
	if private.running or Wanted:InCombat() or not Wanted.db.settings.sigBackground or #private.urgent > 0 then
		return
	end
	private.RunNext(true)
end

---Starts checking the next record, unless one is being checked. Urgent ones first; background ones only when the
---one-a-second tick asks.
---@param fromTick boolean?
function private.RunNext(fromTick)
	if private.running or Crypto:IsOn() == false then
		return
	end
	if Crypto:IsOn() == nil then
		-- The self-test hasn't run yet (it's queued first at login)
		C_Timer.After(1, function() private.RunNext(fromTick) end)
		return
	end
	local Store = Wanted.Store
	while true do
		local list = #private.urgent > 0 and private.urgent or (fromTick and private.background) or nil
		local id = list and tremove(list, 1)
		if not id and #private.urgent == 0 then
			-- Challengers after what's being read, before the background
			local challenger = private.NextChallenger()
			if not challenger then
				return
			end
			local key, sig = private.Checkable(challenger, true)
			if key and private.Start(challenger, key, sig, true) then
				return
			end
		elseif not id then
			return
		end
		-- An urgent one may still be in the background list (it's skipped there once checked)
		local state = private.queued[id]
		if state and (list == private.urgent or state == "background") then
			private.queued[id] = nil
			local record = Store:Get(id)
			local key, sig = nil, nil
			if record then
				key, sig = private.Checkable(record)
			end
			if key and private.Start(record, key, sig) then
				return
			end
		end
	end
end

---Starts checking a record. Returns whether a check is running (not for a signature that can't be one).
---challenger: a record not held (Verify:Challenge), taken in or dropped by what's found rather than marked.
function private.Start(record, key, sig, challenger)
	local message = Wanted.Store:SigningMessage(record)
	if not message then
		-- A field no record can carry (a stored one never has one): nothing to check
		return false
	end
	local signature = Crypto:FromBase64(sig)
	if not signature or #signature ~= 64 then
		-- Its key id is a known key's, but what follows is no signature
		if not challenger then
			private.Finish(record, key, false)
		end
		return false
	end
	private.running = record
	local prepared = Wanted.KeyBook:GetPrepared(key.pk)
	local job = Crypto:NewCheck(prepared or Crypto:FromBase64(key.pk), message, signature)
	Crypto:Check(job, function(ok)
		private.running = nil
		if job.badKey then
			-- The key isn't one: the record isn't forged, it just can't be checked with it
			Wanted.KeyBook:Drop(record.origin, key.pk)
			C_Timer.After(0, function() private.RunNext() end)
			return
		end
		Wanted.KeyBook:KeepPrepared(key.pk, job.key)
		if challenger then
			private.FinishChallenger(record, key, ok)
		else
			private.Finish(record, key, ok)
		end
		C_Timer.After(0, function() private.RunNext() end)
	end)
	return true
end

---A challenger checked: good, it's merged (the store lets it take the held record's place, unless that one became
---its origin's word meanwhile); bad, it's dropped.
function private.FinishChallenger(record, key, ok)
	private.checked = private.checked + 1
	if ok == true then
		local isNew, why = Wanted.Store:MergeVerified(record)
		Wanted:Log("Verify: %s record %s checked out with %s's key %s: %s", tostring(record.kind), tostring(record.id), tostring(record.origin), tostring(key.kid), isNew and "taken in" or tostring(why))
		return
	end
	private.bad = private.bad + 1
	Wanted:Log("!! Verify: %s record %s offered for a held one has a bad signature for %s's key %s; dropped", tostring(record.kind), tostring(record.id), tostring(record.origin), tostring(key.kid))
end

---Keeps what a check found (sigChecked). A good signature: the record counts from now (Store:Authority), so what rests
---on it is worked out again. A bad signature from a known key: someone forged or changed it, so it's tampered, never
---read.
function private.Finish(record, key, ok)
	private.checked = private.checked + 1
	Wanted.db.sigChecked[record.id] = ok == true
	if ok == true then
		Wanted.Bounties:OnVerified(record)
		if Wanted.UI and Wanted.UI.Refresh then
			Wanted.UI:Refresh()
		end
		return
	end
	private.bad = private.bad + 1
	record.tampered = true
	Wanted:Log("!! Verify: %s record %s has a bad signature for %s's key %s; kept out of sight", tostring(record.kind), tostring(record.id), tostring(record.origin), tostring(key.kid))
	Wanted.Bounties:ForgetOpen()
	if Wanted.UI and Wanted.UI.Refresh then
		Wanted.UI:Refresh()
	end
end



-- ============================================================================
-- Reading the results
-- ============================================================================

---What's known of a record's signature, for its details: "Signed" (checked, or our own), "Bad signature", and for
---one in a keyed player's name that isn't their word yet (Store:Authority) "Not checked yet" or "Unsigned"; nil when
---nothing is known and nothing rests on it (unsigned from a player with no key, or not checked yet but theirs).
---@param record table?
---@return string?
function Verify:Label(record)
	if type(record) ~= "table" then
		return nil
	end
	local checked = Wanted.db.sigChecked[record.id]
	if checked == true then
		return "Signed"
	elseif checked == false then
		return "Bad signature"
	end
	local authority = Wanted.Store:Authority(record)
	if authority == "pending" then
		return "Not checked yet"
	elseif authority == "no" then
		return "Unsigned"
	end
	return nil
end

---Records about a bounty whose signature failed (they're tampered, so nothing else lists them): how many.
---@param bounty table
---@return number
function Verify:CountBad(bounty)
	local Store = Wanted.Store
	local claims, bad = {}, 0
	for _, id in ipairs(private.BadIds()) do
		local record = Store:Get(id)
		if record then
			local data = record.data
			if data.bounty == bounty.id then
				bad = bad + 1
			elseif type(data.claim) == "string" then
				local claim = Store:Get(data.claim)
				claims[data.claim] = claims[data.claim] or (claim and claim.data.bounty == bounty.id) or false
				if claims[data.claim] then
					bad = bad + 1
				end
			end
		end
	end
	return bad
end

---Every held record whose signature failed (few: each is a forgery), walked again at most once a minute.
function private.BadIds()
	local now = GetTime()
	if private.badIds and now < private.badUntil and private.badAt == private.bad then
		return private.badIds
	end
	local ids = {}
	for id, checked in pairs(Wanted.db.sigChecked) do
		if checked == false and Wanted.db.records[id] then
			tinsert(ids, id)
		end
	end
	private.badIds, private.badUntil, private.badAt = ids, now + 60, private.bad
	return ids
end

---Counts for /wanted bug: records held that checked out (our own signed ones too), that failed, and checks waiting.
---@return number good
---@return number bad
---@return number waiting
function Verify:Counts()
	local good, bad = 0, 0
	for id, checked in pairs(Wanted.db.sigChecked) do
		if Wanted.db.records[id] then
			good = good + (checked == true and 1 or 0)
			bad = bad + (checked == false and 1 or 0)
		end
	end
	local challengers = 0
	for _, list in pairs(private.challengers) do
		challengers = challengers + #list
	end
	return good, bad, #private.urgent + #private.background + challengers
end

function Verify:Status()
	local good, bad, waiting = Verify:Counts()
	return format("Verify: %d signatures checked out, %d bad, %d waiting; %d checked this session.", good, bad, waiting, private.checked)
end
