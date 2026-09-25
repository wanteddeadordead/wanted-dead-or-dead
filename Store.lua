-- Wanted: the record store. Every fact the addon knows is an immutable record keyed by an id of
-- "origin:seq" (origin = this character as the server names it, seq = this client's counter), hash
-- chained per origin so a rewritten history is visible to any peer holding a copy. Players are keyed
-- by GUID so renames do not matter.

local _, Wanted = ...
local Store = Wanted:NewModule("Store")
local LibDeflate = LibStub("LibDeflate")
local private = {
	origin = nil,
	ownChain = nil, -- { seq, lastHash } for this client
	listeners = {}, -- kind -> { func, ... }
}
local MAX_SIGHTINGS = 500



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Store:OnLoad()
	local db = Wanted.db
	db.records = db.records or {} -- id -> record
	db.chains = db.chains or {} -- origin -> { seq, lastHash }
	db.players = db.players or {} -- guid -> { name, class, level, faction, lastSeen, zone, x, y }
	db.sightings = db.sightings or {} -- ring of { guid, zone, x, y, t }
	db.sightingsPos = db.sightingsPos or 0
end

function Store:OnEnable()
	private.origin = Store:GetOrigin()
	Wanted:Log("Store: origin %s", private.origin)
	Wanted.db.chains[private.origin] = Wanted.db.chains[private.origin] or { seq = 0, lastHash = "0" }
	private.ownChain = Wanted.db.chains[private.origin]
end

function Store:Status()
	local counts = {}
	for _, record in pairs(Wanted.db.records) do
		counts[record.kind] = (counts[record.kind] or 0) + 1
	end
	local parts = {}
	for kind, count in pairs(counts) do
		tinsert(parts, count.." "..kind)
	end
	sort(parts)
	local numPlayers = 0
	for _ in pairs(Wanted.db.players) do
		numPlayers = numPlayers + 1
	end
	return format("Store: %s; %d players seen; chain seq %d.", #parts > 0 and table.concat(parts, ", ") or "no records", numPlayers, private.ownChain and private.ownChain.seq or 0)
end



-- ============================================================================
-- Identity and hashing
-- ============================================================================

---This character as the server names it as the sender of an addon message. On this client characters have
---a first name and a surname, UnitName returns them as two values, and the sender is "First Last" with no
---realm; elsewhere it is "Name-Realm".
---@return string
function Store:GetOrigin()
	if private.origin then
		return private.origin
	end
	local name, surname = UnitName("player")
	if RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled() and surname and surname ~= "" then
		return name.." "..surname
	end
	local realm = GetNormalizedRealmName() or GetRealmName() or ""
	return name.."-"..gsub(realm, "[%s%-]", "")
end

---Corrects the origin once the client has shown how it names us as a sender (our own message echoed back).
---Only allowed before any record of our own exists, since ids embed it.
---@param sender string
function Store:LearnOrigin(sender)
	if sender == private.origin then
		return
	end
	if private.ownChain and private.ownChain.seq > 0 then
		Wanted:Log("Store: sender name %s differs from origin %s but records exist; keeping origin", sender, private.origin)
		return
	end
	Wanted:Log("Store: origin corrected from %s to %s", tostring(private.origin), sender)
	Wanted.db.chains[private.origin] = nil
	private.origin = sender
	Wanted.db.chains[sender] = Wanted.db.chains[sender] or { seq = 0, lastHash = "0" }
	private.ownChain = Wanted.db.chains[sender]
end

---A short hash of a string. Not cryptographic: the unforgeable identity is the server-stamped sender of a
---message; the hash only makes a changed record visible.
---@param str string
---@return string
function Store:Hash(str)
	return format("%08x", LibDeflate:Adler32(str))
end

-- The canonical string of a record covers everything but its own hash, with fields in a fixed order
local function Canonical(record)
	local keys = {}
	for key in pairs(record.data) do
		tinsert(keys, key)
	end
	sort(keys)
	local parts = { record.kind, record.id, record.prev, tostring(record.t) }
	for _, key in ipairs(keys) do
		tinsert(parts, key.."="..tostring(record.data[key]))
	end
	return table.concat(parts, "\n")
end



-- ============================================================================
-- Records
-- ============================================================================

---Creates and stores a new record of this client's own.
---@param kind string kill | bounty | claim | payment | mark | raise | pass
---@param data table Plain values only (strings, numbers, booleans)
---@return table record
function Store:NewRecord(kind, data)
	local chain = private.ownChain
	chain.seq = chain.seq + 1
	local record = {
		kind = kind,
		id = private.origin..":"..chain.seq,
		origin = private.origin,
		seq = chain.seq,
		prev = chain.lastHash,
		t = GetServerTime(),
		data = data,
	}
	record.hash = Store:Hash(Canonical(record))
	chain.lastHash = record.hash
	Wanted.db.records[record.id] = record
	private.Notify(record, true)
	return record
end

---Merges a record received from a peer. Returns whether it was new. The chain check is advisory: a record
---whose prev does not match what we hold for that origin is stored but flagged, never dropped, since we
---may simply be missing the records between.
---@param record table
---@param sender string The server-stamped sender of the message carrying it
---@return boolean isNew
function Store:Merge(record, sender)
	if type(record) ~= "table" or type(record.id) ~= "string" or type(record.kind) ~= "string" or type(record.data) ~= "table" then
		return false
	end
	if record.origin ~= sender then
		-- Only the origin may introduce its own records live; gap fills carry records from other origins and
		-- go through MergeRelayed instead
		return false
	end
	return private.Insert(record)
end

---Merges a record relayed by a peer answering a gap request (origin may differ from sender).
---@param record table
---@return boolean isNew
function Store:MergeRelayed(record)
	if type(record) ~= "table" or type(record.id) ~= "string" or type(record.kind) ~= "string" or type(record.data) ~= "table" then
		return false
	end
	return private.Insert(record)
end

function private.Insert(record)
	local db = Wanted.db
	if db.records[record.id] or strsub(record.id, 1, 5) == "TEST:" or record.test then
		return false
	end
	if record.hash ~= Store:Hash(Canonical(record)) then
		-- Doesn't hash to itself: altered in transit or by a modified addon
		record.tampered = true
	end
	local chain = db.chains[record.origin]
	if not chain then
		chain = { seq = 0, lastHash = "0" }
		db.chains[record.origin] = chain
	end
	if record.seq == chain.seq + 1 then
		if record.prev ~= chain.lastHash then
			record.brokenChain = true
		end
		chain.seq = record.seq
		chain.lastHash = record.hash
	elseif record.seq <= chain.seq then
		-- Older than what we hold for this origin, and not stored: a rewritten history
		record.brokenChain = true
	end
	-- A gap (seq > chain.seq + 1) is stored as is; the sync layer asks for the missing records
	db.records[record.id] = record
	private.Notify(record, false)
	return true
end

---Inserts a test record: it looks like any other but its id starts with "TEST:", it belongs to no chain, the
---sync never sends it, and /wanted purge removes it.
---@param kind string
---@param origin string
---@param data table
---@param t number?
---@return table
function Store:InsertTest(kind, origin, data, t)
	private.testCounter = (private.testCounter or 0) + 1
	local record = {
		kind = kind,
		id = "TEST:"..private.testCounter,
		origin = origin,
		seq = 0,
		prev = "0",
		t = t or GetServerTime(),
		data = data,
		test = true,
	}
	record.hash = Store:Hash(Canonical(record))
	Wanted.db.records[record.id] = record
	private.Notify(record, false)
	return record
end

---Whether a record is test data.
---@param record table
---@return boolean
function Store:IsTest(record)
	return record.test == true or strsub(record.id, 1, 5) == "TEST:"
end

---Removes every test record, player and sighting.
---@return number removed
function Store:PurgeTest()
	local db = Wanted.db
	local removed = 0
	for id, record in pairs(db.records) do
		if Store:IsTest(record) then
			db.records[id] = nil
			removed = removed + 1
		end
	end
	for guid in pairs(db.players) do
		if strsub(guid, 1, 12) == "Player-TEST-" then
			db.players[guid] = nil
		end
	end
	for i, sighting in pairs(db.sightings) do
		if strsub(sighting.guid, 1, 12) == "Player-TEST-" then
			db.sightings[i] = nil
		end
	end
	return removed
end

---Gets a record by id.
---@param id string
---@return table?
function Store:Get(id)
	return Wanted.db.records[id]
end

---Iterates the records of one kind, unordered.
---@param kind string
---@return fun(): table?
function Store:Iterator(kind)
	local records = Wanted.db.records
	local id = nil
	return function()
		local record
		repeat
			id, record = next(records, id)
		until not id or record.kind == kind
		return record
	end
end

---Registers a function called with (record, isOwn) whenever a record of a kind is added.
---@param kind string
---@param func fun(record: table, isOwn: boolean)
function Store:OnRecord(kind, func)
	private.listeners[kind] = private.listeners[kind] or {}
	tinsert(private.listeners[kind], func)
end

function private.Notify(record, isOwn)
	for _, func in ipairs(private.listeners[record.kind] or {}) do
		func(record, isOwn)
	end
end

---The highest seq held for an origin (for gap requests).
---@param origin string
---@return number
function Store:GetChainSeq(origin)
	local chain = Wanted.db.chains[origin]
	return chain and chain.seq or 0
end



-- ============================================================================
-- Players and sightings
-- ============================================================================

---Records what is known about a player.
---@param guid string
---@param info table name, class, level, faction (any may be nil)
function Store:UpdatePlayer(guid, info)
	local players = Wanted.db.players
	local player = players[guid]
	if not player then
		player = {}
		players[guid] = player
	end
	for key, value in pairs(info) do
		player[key] = value
	end
	player.lastSeen = GetServerTime()
end

---Gets what is known about a player.
---@param guid string
---@return table?
function Store:GetPlayer(guid)
	return Wanted.db.players[guid]
end

---Finds a player by name (case-insensitive, realm optional).
---@param name string
---@return string? guid
---@return table? player
function Store:FindPlayerByName(name)
	name = strlower(strmatch(name, "^([^%-]+)") or name)
	for guid, player in pairs(Wanted.db.players) do
		if player.name and strlower(strmatch(player.name, "^([^%-]+)")) == name then
			return guid, player
		end
	end
	return nil, nil
end

---Adds a sighting to the bounded ring.
---@param guid string
---@param zone string
---@param x number?
---@param y number?
function Store:AddSighting(guid, zone, x, y, mapId, by)
	local db = Wanted.db
	db.sightingsPos = db.sightingsPos % MAX_SIGHTINGS + 1
	-- by = the player who shared it, nil for our own
	local sighting = { guid = guid, zone = zone, x = x, y = y, mapId = mapId, by = by, t = GetServerTime() }
	db.sightings[db.sightingsPos] = sighting
	-- Not a record (never synced), but the interface wants to know about it
	private.Notify({ kind = "sighting", sighting = sighting }, true)
end

---Iterates sightings newest first.
---@return fun(): table?
function Store:SightingIterator()
	local db = Wanted.db
	local i = 0
	return function()
		i = i + 1
		if i > MAX_SIGHTINGS then
			return nil
		end
		local index = (db.sightingsPos - i) % MAX_SIGHTINGS + 1
		return db.sightings[index]
	end
end
