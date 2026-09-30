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
Store.MAX_SIGHTINGS = MAX_SIGHTINGS
-- Other players' kills, deaths and assists are kept this long (3 days, decided 2026-09-29; 30 days before); the
-- website keeps the archive. Every other kind (bounties and what happens to them, links, notices) is kept, and so
-- are the kills, deaths and assists of this account's characters and what a claim rests on (Store:Prune).
local KEEP_SECONDS = 3 * 24 * 60 * 60
Store.KEEP_SECONDS = KEEP_SECONDS
local PRUNED_KINDS = { kill = true, death = true, assist = true }
-- While the desktop app hasn't read the latest save, records since its last catch-up may not be uploaded yet:
-- they're kept, unless it hasn't caught up for this long (it's no longer used)
local APP_WAIT_SECONDS = 30 * 24 * 60 * 60
-- The app stamps its catch-up with the PC's clock, not the server's
local APP_CLOCK_MARGIN = 60 * 60
-- Pruning runs again this often in a long session
local PRUNE_EVERY_SECONDS = 24 * 60 * 60
-- A chain whose earlier records were pruned everywhere continues from a record whose predecessor is unknown
local UNKNOWN_HASH = "?"
local MAX_NAME_BYTES = 64 -- "First Last-Realm" in UTF-8 fits with room to spare



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
	db.names = db.names or {} -- guid -> { n = "First Last", t } every player seen, either side (the name book)
	private.PruneNames(db.names)
	db.addonVersions = db.addonVersions or {} -- "Name" -> { v = "1.2.19", t } the Wanted version each player's messages carried
	Store:NoteAddonVersion(UnitName("player"), Wanted.VERSION)
	private.PruneVersions(db.addonVersions)
	db.characters = db.characters or {} -- guid -> { n = origin, t } this account's characters
end

---Drops other players' kills, deaths and assists older than KEEP_SECONDS. Returns how many. Kept whatever their
---age: records where one of this account's characters is the killer, victim or assister (not every death their
---client witnessed: those were most of the records), a kill a claim rests on and the deaths that witness it,
---and records the desktop app may not have uploaded yet. Saved data grew without bound (8 MB in four days for one
---player) and every record was walked on load and on every sync; the website holds everything ever uploaded.
---A chain says how far this client has taken an origin's records, pruned or not, so pruned records are never
---asked for again. It only moves forward, past a pruned record held beyond a gap.
---@param now number
---@return number pruned
function Store:Prune(now)
	local records, chains = Wanted.db.records, Wanted.db.chains
	local cutoff = private.PruneCutoff(now)
	-- What old records may still be needed for: claims (their kill, and deaths within the witness window), and
	-- which characters are this account's (every link record with the app's code for this account)
	local code = private.AppLinkCode()
	local claimed, claimTimes, targets = {}, {}, {}
	for _, record in pairs(records) do
		local data = record.data
		private.NoteFirst(chains[record.origin], record)
		if record.kind == "bounty" and type(data) == "table" and type(data.target) == "string" then
			targets[data.target] = true
		elseif record.kind == "claim" and type(data) == "table" then
			if type(data.kill) == "string" then
				claimed[data.kill] = true
			end
			if type(data.victim) == "string" and type(data.killT) == "number" then
				claimTimes[data.victim] = claimTimes[data.victim] or {}
				tinsert(claimTimes[data.victim], data.killT)
			end
		elseif record.kind == "link" and code and type(data) == "table" and data.code == code then
			Store:NoteCharacter(data.guid, record.origin, record.t)
		end
	end
	private.BuildOwn()
	local pruned, kept, left = 0, 0, 0
	local pastGap = {} -- origin -> the newest old record held past a gap in its chain
	for id, record in pairs(records) do
		if PRUNED_KINDS[record.kind] and type(record.t) == "number" and record.t < cutoff then
			local chain = chains[record.origin]
			if claimed[id] or private.IsOwnRelated(record) or private.Witnesses(record, claimTimes) then
				kept = kept + 1
				left = left + 1
			else
				if chain and type(record.seq) == "number" and record.seq > chain.seq
					and (not pastGap[record.origin] or record.seq > pastGap[record.origin].seq) then
					pastGap[record.origin] = record
				end
				records[id] = nil
				pruned = pruned + 1
			end
		else
			left = left + 1
		end
	end
	-- A gap still open behind a record this old won't be filled with anything worth keeping (what's in it is older
	-- still): the chain moves past the pruned record, so it isn't asked for again
	for origin, record in pairs(pastGap) do
		Store:SkipTo(origin, record.seq + 1, record.hash)
	end
	if pruned > 0 then
		private.indexFor = nil -- built again on the next walk
	end
	Wanted:Log("Store: pruned %d kills, deaths and assists older than %d days; kept %d older ones (your characters', claims', or not yet uploaded); %d records held",
		pruned, KEEP_SECONDS / 86400, kept, left)
	private.PrunePlayers(now, targets)
	return pruned
end

-- Players the addon knows (enemies seen, bounty targets) are kept while seen lately, then at most PLAYERS_MAX, the
-- most recently seen first. It grew by about 900 a day for one player.
Store.PLAYERS_MAX = 5000
local PLAYERS_DAYS = 30

---Drops players not seen for PLAYERS_DAYS, then the least recently seen past PLAYERS_MAX. Never one a page still
---needs: on Kill on Sight or Ignore, with a history (tracks), fought (wins or losses: nemesis and rivals), a bounty
---target, or one of this account's characters.
---@param now number
---@param targets table guid -> true for every bounty's target
function private.PrunePlayers(now, targets)
	local db = Wanted.db
	local players, kos, ignore, tracks, stats = db.players, db.kos or {}, db.ignore or {}, db.tracks or {}, db.enemyStats or {}
	local cutoff = now - PLAYERS_DAYS * 86400
	local function Needed(guid)
		local fought = stats[guid]
		return targets[guid] or kos[guid] or ignore[guid] or tracks[guid] or db.characters[guid]
			or (type(fought) == "table" and ((fought.wins or 0) > 0 or (fought.losses or 0) > 0))
	end
	local dropped, count = 0, 0
	for guid, player in pairs(players) do
		if Needed(guid) then
			-- kept, outside the cap
		elseif type(player) ~= "table" or (player.lastSeen or 0) < cutoff then
			players[guid] = nil
			dropped = dropped + 1
		else
			count = count + 1
		end
	end
	if count > Store.PLAYERS_MAX then
		local list = {}
		for guid, player in pairs(players) do
			if not Needed(guid) then
				tinsert(list, guid)
			end
		end
		sort(list, function(a, b) return (players[a].lastSeen or 0) > (players[b].lastSeen or 0) end)
		for i = Store.PLAYERS_MAX + 1, #list do
			players[list[i]] = nil
			dropped = dropped + 1
		end
	end
	if dropped > 0 then
		Wanted:Log("Store: dropped %d players not seen for %d days or past the %d most recent", dropped, PLAYERS_DAYS, Store.PLAYERS_MAX)
	end
end

---Records older than this may be pruned: KEEP_SECONDS ago, or earlier when the desktop app is set up but hasn't
---read the latest save (the time of its last catch-up is when it last uploaded).
function private.PruneCutoff(now)
	local db = Wanted.db
	local cutoff = now - KEEP_SECONDS
	local entry = type(WantedAppCatchup) == "table" and WantedAppCatchup[db.accountMark]
	local appT = max(db.catchupT or 0, type(entry) == "table" and type(entry.t) == "number" and entry.t or 0)
	if appT > 0 and appT < (db.savedAt or 0) and now - appT < APP_WAIT_SECONDS then
		cutoff = min(cutoff, appT - APP_CLOCK_MARGIN)
	end
	return cutoff
end

---The link code the desktop app gave this WoW account, if it's set up.
function private.AppLinkCode()
	local code = type(WantedAppLinks) == "table" and WantedAppLinks[Wanted.db.accountMark]
	return type(code) == "string" and strupper(code) or nil
end

---Notes one of this account's characters: its GUID and its name as an origin.
---@param guid string?
---@param origin string?
---@param t number? when it was last known to be ours
function Store:NoteCharacter(guid, origin, t)
	if type(guid) ~= "string" or type(origin) ~= "string" or (issecretvalue and issecretvalue(guid)) then
		return
	end
	local entry = Wanted.db.characters[guid]
	t = t or GetServerTime()
	if not entry or entry.n ~= origin or (entry.t or 0) < t then
		Wanted.db.characters[guid] = { n = origin, t = max(t, entry and entry.t or 0) }
		private.own = nil
	end
end

---This account's characters as sets of origins and GUIDs.
function private.BuildOwn()
	local own = { origins = {}, guids = {} }
	for guid, entry in pairs(Wanted.db.characters) do
		own.guids[guid] = true
		if type(entry) == "table" and type(entry.n) == "string" then
			own.origins[entry.n] = true
		end
	end
	private.own = own
	return own
end

---Whether one of this account's characters is a record's killer, victim or assister. A death one of them only
---witnessed isn't theirs; a kill or assist they recorded is (older ones may not name the killer).
function private.IsOwnRelated(record)
	local own = private.own or private.BuildOwn()
	local data = record.data
	return (type(data) == "table" and (own.guids[data.victim] or own.guids[data.killer]))
		or (record.kind ~= "death" and own.origins[record.origin]) or false
end

---Whether a record arriving now would be pruned at once: another player's kill, death or assist older than
---KEEP_SECONDS that no claim needs.
function private.IsPrunable(record)
	if not PRUNED_KINDS[record.kind] or type(record.t) ~= "number" or record.t >= GetServerTime() - KEEP_SECONDS
		or private.IsOwnRelated(record) then
		return false
	end
	local data = type(record.data) == "table" and record.data or {}
	for claim in Store:Iterator("claim") do
		local c = claim.data
		if c.kill == record.id or (record.kind == "death" and c.victim == data.victim and type(c.killT) == "number"
			and abs(record.t - c.killT) <= Wanted.Bounties.WITNESS_WINDOW) then
			return false
		end
	end
	return true
end

---Whether a death witnesses a claim's kill: the same victim within the witness window (Bounties:GetWitnesses).
function private.Witnesses(record, claimTimes)
	local times = record.kind == "death" and type(record.data) == "table" and claimTimes[record.data.victim]
	if not times then
		return false
	end
	for _, killT in ipairs(times) do
		if abs(record.t - killT) <= Wanted.Bounties.WITNESS_WINDOW then
			return true
		end
	end
	return false
end

---A peer's history for an origin starts at seq: everything before was pruned everywhere it asked. The chain
---moves on to there, so this client stops asking for records nobody has, and continues from prev (the first
---record's predecessor) or from an unknown one.
---@param origin string
---@param seq number
---@param prev string?
function Store:SkipTo(origin, seq, prev)
	local db = Wanted.db
	local chain = db.chains[origin]
	if not chain then
		chain = { seq = 0, lastHash = "0" }
		db.chains[origin] = chain
	end
	if origin == private.origin or type(seq) ~= "number" or seq - 1 <= chain.seq then
		return
	end
	Wanted:Log("Store: %s's records before %d are gone from the network; the chain continues from there", origin, seq)
	local held = Wanted.db.records[origin..":"..seq]
	if type(prev) ~= "string" and held then
		prev = held.prev
	end
	chain.seq = seq - 1
	chain.lastHash = type(prev) == "string" and prev or UNKNOWN_HASH
	private.CatchUpChain(origin, chain)
end



-- ============================================================================
-- The name book
-- ============================================================================

-- Every player the addon sees, on either side, by GUID with their full name, kept for the desktop app: the game's
-- combat log names players by first name only, and the app puts full names on the deaths it reads there.
Store.NAME_BOOK_MAX = 5000
local NAME_BOOK_DAYS = 30
-- A name already in the book is only stamped again this often
local NAME_RESTAMP_SECONDS = 3600

---Drops names not seen for a month, then the oldest until the book fits its cap.
function private.PruneNames(names)
	local now, cutoff = GetServerTime(), GetServerTime() - NAME_BOOK_DAYS * 86400
	local kept = {}
	for guid, entry in pairs(names) do
		if type(entry) ~= "table" or type(entry.t) ~= "number" or entry.t < cutoff or entry.t > now + 86400 then
			names[guid] = nil
		else
			tinsert(kept, guid)
		end
	end
	if #kept > Store.NAME_BOOK_MAX then
		sort(kept, function(a, b) return names[a].t > names[b].t end)
		for i = Store.NAME_BOOK_MAX + 1, #kept do
			names[kept[i]] = nil
		end
	end
end

---Notes a player's full name in the name book, with their class and sex when known (the app sends those to
---wanteddeadordead.com too).
---@param guid string
---@param name string?
---@param class string? the game's class file name, e.g. ROGUE
---@param sex string? "male" or "female"
-- The version book: which Wanted version each player's sync messages said they run, for the app to pass to the
-- website (how far an update has spread). Kept for VERSION_BOOK_DAYS, at most VERSION_BOOK_MAX players.
Store.VERSION_BOOK_MAX = 500
local VERSION_BOOK_DAYS = 14

---Notes the version a player's message carried. The name loses any realm, as the name book's names do.
---@param name string?
---@param version any
function Store:NoteAddonVersion(name, version)
	if type(name) ~= "string" or type(version) ~= "string" or #version > 24 or not strfind(version, "^%d+%.%d+%.%d+[%w%.%-]*$") then
		return
	end
	name = strmatch(name, "^([^%-]+)") or name
	if name == "" or #name > 48 then
		return
	end
	local book = Wanted.db.addonVersions
	local entry = book[name]
	if entry and entry.v == version and GetServerTime() - entry.t < 600 then
		return
	end
	book[name] = { v = version, t = GetServerTime() }
end

function private.PruneVersions(book)
	local now, cutoff = GetServerTime(), GetServerTime() - VERSION_BOOK_DAYS * 86400
	local kept = {}
	for name, entry in pairs(book) do
		if type(entry) ~= "table" or type(entry.v) ~= "string" or type(entry.t) ~= "number" or entry.t < cutoff or entry.t > now + 86400 then
			book[name] = nil
		else
			tinsert(kept, name)
		end
	end
	if #kept > Store.VERSION_BOOK_MAX then
		sort(kept, function(a, b) return book[a].t > book[b].t end)
		for i = Store.VERSION_BOOK_MAX + 1, #kept do
			book[kept[i]] = nil
		end
	end
end

function Store:NoteName(guid, name, class, sex)
	if type(name) ~= "string" or name == "" or (issecretvalue and issecretvalue(name)) then
		return
	end
	local entry = Wanted.db.names[guid]
	local now = GetServerTime()
	class = type(class) == "string" and class ~= "" and not (issecretvalue and issecretvalue(class)) and class or (entry and entry.class)
	sex = (sex == "male" or sex == "female") and sex or (entry and entry.sex)
	if entry and entry.n == name and entry.class == class and entry.sex == sex and now - entry.t < NAME_RESTAMP_SECONDS then
		return
	end
	-- Updated in place: the entry also holds the guild (NoteGuild)
	entry = entry or {}
	entry.n, entry.t, entry.class, entry.sex = name, now, class, sex
	Wanted.db.names[guid] = entry
end

-- Two "no guild" readings this far apart are needed before a known guild is dropped: the game gives no guild for
-- a player whose guild it hasn't loaded yet
local GUILD_LEFT_SECONDS = 30

---Notes a player's guild in the name book, with when it was seen (g, gt; g = "" when seen in none), so a change
---of guild is kept from the moment it's seen. The player's name must be in the book already (NoteName).
---@param guid string
---@param guild string? nil or "" when the game gives none
function Store:NoteGuild(guid, guild)
	local entry = Wanted.db.names[guid]
	if not entry or (issecretvalue and guild and issecretvalue(guild)) then
		return
	end
	guild = type(guild) == "string" and guild or ""
	local now = GetServerTime()
	if guild == "" and entry.g and entry.g ~= "" then
		-- In a guild before: only once "none" holds for a while
		if not entry.ng then
			entry.ng = now
			return
		elseif now - entry.ng < GUILD_LEFT_SECONDS then
			return
		end
	end
	entry.ng = nil
	if entry.g == guild and entry.gt and now - entry.gt < NAME_RESTAMP_SECONDS then
		return
	end
	entry.g, entry.gt = guild, now
end

function Store:OnEnable()
	private.origin = Store:GetOrigin()
	Wanted:Log("Store: origin %s", private.origin)
	Wanted.db.chains[private.origin] = Wanted.db.chains[private.origin] or { seq = 0, lastHash = "0" }
	private.ownChain = Wanted.db.chains[private.origin]
	Store:NoteCharacter(UnitGUID("player"), private.origin)
	Store:Prune(GetServerTime())
	Store:RepairChains()
	Store:AutoLink()
	-- When this client last saved: the desktop app has uploaded everything held if it caught up after that
	private.frame = CreateFrame("Frame")
	private.frame:RegisterEvent("PLAYER_LOGOUT")
	private.frame:SetScript("OnEvent", function()
		Wanted.db.savedAt = GetServerTime()
	end)
	C_Timer.NewTicker(PRUNE_EVERY_SECONDS, function()
		Wanted:QueueWork(function() Store:Prune(GetServerTime()) end)
	end)
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
	private.NoteFirst(chain, record)
	Wanted.db.records[record.id] = record
	private.AddToIndex(record)
	private.Notify(record, true)
	return record
end

---Merges a record received from a peer. Returns whether it was new. The chain check is advisory: a record
---whose prev does not match what we hold for that origin is stored but flagged, never dropped, since we
---may simply be missing the records between.
---@param record table
---@param sender string The server-stamped sender of the message carrying it
---@return boolean isNew
---@return string? why when not new: "already held", "malformed", "not sent by its origin", "test data" or "pruned"
function Store:Merge(record, sender)
	if type(record) ~= "table" or type(record.id) ~= "string" or type(record.kind) ~= "string" or type(record.data) ~= "table" then
		return false, "malformed"
	end
	if record.origin ~= sender then
		-- Only the origin may introduce its own records live; gap fills carry records from other origins and
		-- go through MergeRelayed instead
		return false, "not sent by its origin"
	end
	return private.Insert(record, true)
end

---Merges a record relayed by a peer answering a gap request (origin may differ from sender).
---@param record table
---@return boolean isNew
---@return string? why when not new, as for Merge
function Store:MergeRelayed(record)
	if type(record) ~= "table" or type(record.id) ~= "string" or type(record.kind) ~= "string" or type(record.data) ~= "table" then
		return false, "malformed"
	end
	return private.Insert(record, false)
end

---Stores a received record. live: it came straight from its origin (the game stamped the sender), which the
---desktop app reports so the network can accept this client as a witness to it. Local flags arriving with a
---record are the sender's, not ours, and are dropped: a relayed record can't claim to be live.
function private.Insert(record, live)
	local db = Wanted.db
	record.live, record.tampered, record.brokenChain = nil, nil, nil
	local existing = db.records[record.id]
	if existing then
		if live and existing.hash == record.hash and not existing.test then
			existing.live = true
		end
		return false, "already held"
	end
	if strsub(record.id, 1, 5) == "TEST:" or record.test then
		return false, "test data"
	end
	record.live = live or nil
	if record.hash ~= Store:Hash(Canonical(record)) then
		-- Doesn't hash to itself: altered in transit or by a modified addon
		record.tampered = true
		Wanted:Log("!! Store: %s record %s doesn't match its hash (altered)", tostring(record.kind), tostring(record.id))
	end
	local chain = db.chains[record.origin]
	if not chain then
		chain = { seq = 0, lastHash = "0" }
		db.chains[record.origin] = chain
	end
	private.NoteFirst(chain, record)
	if record.seq == chain.seq + 1 then
		if record.prev ~= chain.lastHash and chain.lastHash ~= UNKNOWN_HASH then
			record.brokenChain = true
			Wanted:Log("!! Store: record %s doesn't follow %s's previous record (broken chain)", tostring(record.id), tostring(record.origin))
		end
		chain.seq = record.seq
		chain.lastHash = record.hash
		private.CatchUpChain(record.origin, chain)
		if private.IsPrunable(record) then
			-- Already too old to keep (the app's catch-up, or a fill, of old records): the chain moves on over it, so
			-- it's neither asked for nor sent again, but it isn't stored only to be pruned at the next login
			return false, "pruned"
		end
	elseif record.seq <= chain.seq then
		-- Older than what we hold for this origin, and not held. One pruned here (or skipped as pruned everywhere)
		-- comes back whenever a peer fills someone else's gap on the channel: it isn't taken in again.
		local old = type(record.t) == "number" and record.t < GetServerTime() - KEEP_SECONDS
		if private.IsPrunable(record) then
			return false, "pruned"
		elseif old then
			Wanted:Log("Store: record %s is from before %s's chain was pruned or skipped; kept", tostring(record.id), tostring(record.origin))
		else
			-- A recent one: a rewritten history
			record.brokenChain = true
			Wanted:Log("!! Store: record %s is older than %s's chain (rewritten history)", tostring(record.id), tostring(record.origin))
		end
	end
	-- A gap (seq > chain.seq + 1) is stored as is; the sync layer asks for the missing records
	db.records[record.id] = record
	private.AddToIndex(record)
	private.Notify(record, false)
	return true
end

---Moves a chain on over records already held past its end (they arrived ahead of a gap). Without this the
---chain stays at the gap and the sync asks for those records again at every resync.
---@param origin string
---@param chain table
function private.CatchUpChain(origin, chain)
	local records = Wanted.db.records
	local nextRecord = records[origin..":"..(chain.seq + 1)]
	while nextRecord and nextRecord.origin == origin and nextRecord.seq == chain.seq + 1 do
		if nextRecord.prev ~= chain.lastHash then
			nextRecord.brokenChain = true
			Wanted:Log("!! Store: record %s doesn't follow %s's previous record (broken chain)", tostring(nextRecord.id), origin)
		end
		chain.seq = nextRecord.seq
		chain.lastHash = nextRecord.hash
		nextRecord = records[origin..":"..(chain.seq + 1)]
	end
end

---Moves every chain on over records it already holds: saved data from before 1.1.1 can have chains stuck at
---a gap that has since been filled.
function Store:RepairChains()
	for origin, chain in pairs(Wanted.db.chains) do
		local before = chain.seq
		private.CatchUpChain(origin, chain)
		if chain.seq ~= before then
			Wanted:Log("Store: %s's chain moved on from %d to %d over records already held", origin, before, chain.seq)
		end
	end
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
	private.AddToIndex(record)
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
	for guid in pairs(db.tracks or {}) do
		if strsub(guid, 1, 12) == "Player-TEST-" then
			db.tracks[guid] = nil
		end
	end
	return removed
end

--@debug@
---Clears every shared record (bounties, kills, deaths, claims, payments...) and starts this player's record
---chain again from the beginning. Settings, Kill on Sight, Ignore, enemy statistics and sightings stay. Only
---safe before any other player has received this client's records: theirs would no longer match.
---@return number removed
function Store:FreshStart()
	local db = Wanted.db
	local removed = 0
	for _ in pairs(db.records) do
		removed = removed + 1
	end
	db.records = {}
	db.chains = {}
	db.chains[private.origin] = { seq = 0, lastHash = "0" }
	private.ownChain = db.chains[private.origin]
	return removed
end
--@end-debug@

---Gets a record by id.
---@param id string
---@return table?
function Store:Get(id)
	return Wanted.db.records[id]
end

-- Record ids by kind, so walking the handful of raises or payments doesn't mean walking every record (the
-- bounty code does that many times over), and each origin's newest record time, so the sync can tell which
-- chains are active. Built on first use and kept as records arrive; built again whenever the records table is
-- replaced (a fresh start, the launch reset) or pruned. Each kind's ids are a list that only grows, so a walk
-- reads it in place (copying it for every walk made most of the addon's garbage); a record removed some other way
-- is skipped by walks until then.
function private.Index()
	local records = Wanted.db.records
	if private.indexFor ~= records then
		private.byKind, private.indexed, private.lastActive, private.indexFor = {}, {}, {}, records
		for _, record in pairs(records) do
			private.AddId(record)
			private.NoteActive(record)
		end
	end
	return private.byKind
end

function private.AddId(record)
	if private.indexed[record.id] then
		return
	end
	private.indexed[record.id] = true
	local ids = private.byKind[record.kind]
	if not ids then
		ids = {}
		private.byKind[record.kind] = ids
	end
	ids[#ids + 1] = record.id
end

function private.NoteActive(record)
	local origin, t = record.origin, record.t
	if type(origin) == "string" and type(t) == "number" and t > (private.lastActive[origin] or 0) then
		private.lastActive[origin] = t
	end
end

function private.AddToIndex(record)
	-- Not built yet: the first walk builds it with this record in
	if private.indexFor ~= Wanted.db.records then
		return
	end
	private.AddId(record)
	private.NoteActive(record)
end

---Iterates the records of one kind, unordered. It walks the ids as they were when it started, so records
---added meanwhile are left for the next walk.
---@param kind string
---@return fun(): table?
function Store:Iterator(kind)
	local records = Wanted.db.records
	local list = private.Index()[kind]
	local n = list and #list or 0
	local i = 0
	return function()
		while i < n do
			i = i + 1
			local record = records[list[i]]
			if record and record.kind == kind then
				return record
			end
		end
		return nil
	end
end

---Registers a function called with (record, isOwn) whenever a record of a kind is added ("*" for every kind).
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
	for _, func in ipairs(private.listeners["*"] or {}) do
		func(record, isOwn)
	end
end

---When the newest record held from an origin was made (0 if none).
---@param origin string
---@return number
function Store:GetLastActive(origin)
	private.Index()
	return private.lastActive[origin] or 0
end

---Keeps the time of an origin's first record (seq 1) with its chain (first): the record itself may be pruned, and
---how long someone has been around is still asked (Bounties, a claim's witnesses).
function private.NoteFirst(chain, record)
	if chain and record.seq == 1 and type(record.t) == "number" then
		chain.first = record.t
	end
end

---When an origin's first record (seq 1) was made, or nil if it was never seen.
---@param origin string
---@return number?
function Store:GetFirstSeen(origin)
	local chain = Wanted.db.chains[origin]
	return chain and chain.first
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

---Records what is known about a player, and that they were seen now unless seen is false (a bounty posted on
---them by name, say, isn't a sighting).
---@param guid string
---@param info table name, class, level, faction (any may be nil)
---@param seen boolean? false to leave "last seen" alone
function Store:UpdatePlayer(guid, info, seen)
	local players = Wanted.db.players
	local player = players[guid]
	if not player then
		player = {}
		players[guid] = player
	end
	for key, value in pairs(info) do
		if key == "name" then
			value = Store:CleanName(value) or player.name
		end
		player[key] = value
	end
	if seen ~= false then
		player.lastSeen = GetServerTime()
	end
end

---A player name safe to show or to put in a macro: no control characters (a newline would start a new macro
---line, which a click then runs) and no "|" (the client's escape sequences). Peers can send any string.
---@param name any
---@return string? name nil when nothing is left
function Store:CleanName(name)
	if type(name) ~= "string" then
		return nil
	end
	name = strsub((gsub(name, "[%c|]", "")), 1, MAX_NAME_BYTES)
	return name ~= "" and name or nil
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
		-- Skips gaps (a purge of test sightings leaves some) rather than stopping at them
		while i < MAX_SIGHTINGS do
			i = i + 1
			local sighting = db.sightings[(db.sightingsPos - i) % MAX_SIGHTINGS + 1]
			if sighting then
				return sighting
			end
		end
		return nil
	end
end



-- ============================================================================
-- Desktop app link
-- ============================================================================

-- Codes the desktop app shows: letters and digits
local LINK_CODE_MIN, LINK_CODE_MAX = 6, 12

Wanted:RegisterCommand("link", "Links this character to the Wanted desktop app: /wanted link <code the app shows>.", function(args)
	local code = strupper(strtrim(args or ""))
	if #code < LINK_CODE_MIN or #code > LINK_CODE_MAX or not strmatch(code, "^%w+$") then
		Wanted:Print("Type the code the desktop app shows: /wanted link <code>.")
		return
	end
	-- Shared like any record: another player's desktop app seeing it straight from us confirms the link
	Store:NewRecord("link", { code = code, guid = UnitGUID("player") })
	Wanted:Print("Link code %s sent. The desktop app shows this character as linked once another Wanted player's app has seen it.", code)
end)

---Links this character to the desktop app without /wanted link: the app leaves this WoW account's code in the
---!!WantedLink addon, under the account mark in our saved data. Once per character per code; a new code (the
---app renews it every few weeks) links again.
function Store:AutoLink()
	local code = type(WantedAppLinks) == "table" and WantedAppLinks[Wanted.db.accountMark]
	if type(code) ~= "string" or #code < LINK_CODE_MIN or #code > LINK_CODE_MAX or not strmatch(code, "^%w+$") then
		return
	end
	code = strupper(code)
	for record in Store:Iterator("link") do
		if record.origin == private.origin and record.data.code == code then
			return
		end
	end
	Store:NewRecord("link", { code = code, guid = UnitGUID("player") })
	Wanted:Log("Store: linked this character to the desktop app")
end
