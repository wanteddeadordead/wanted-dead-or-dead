-- Wanted: the key book, other players' public signing keys by origin (WantedDB.keys). A key is learned only two
-- ways: from a hello its owner sent on the channel (the game stamps the sender, so nobody else can send it), or from
-- the desktop app's catch-up (the server took it only from the app of the account the character is confirmed to).
-- A key in a relayed message, a gap fill or a record never counts. Each origin keeps a few keys, so a second PC or
-- a reinstall adds one rather than replacing it; only the owner's own reset hello (kr = 1) removes them.

local _, Wanted = ...
local KeyBook = Wanted:NewModule("KeyBook")
local Crypto = Wanted.Crypto
local private = {
	prepared = {}, -- base64 key -> prepared key, at most PREPARED_MAX
	preparedOrder = {}, -- base64 keys, least recently used first
}
-- Keys kept per origin: the one heard least lately goes when another comes
KeyBook.MAX_KEYS = 4
-- An origin not heard for this long, with no authority record held, is dropped; then the least recently heard until
-- MAX_ORIGINS remain (about 0.5 MB at most)
local KEEP_SECONDS = 60 * 24 * 60 * 60
KeyBook.MAX_ORIGINS = 2000
-- While the app's list for an origin is this fresh, a key heard live that isn't on it isn't taken: the server's word
-- wins over a hello's
local APP_FRESH_SECONDS = 3 * 24 * 60 * 60
-- Prepared keys kept in memory this session (about 21 KB each)
local PREPARED_MAX = 16
local GUID_PATTERN = "^Player%-%d+%-%x+$"
local MAX_NAME_BYTES = 64



-- ============================================================================
-- Lifecycle
-- ============================================================================

function KeyBook:OnEnable()
	Wanted:QueueWork(function() KeyBook:Prune(GetServerTime()) end)
end

---A public key as sent (43 characters of base64), or nil if it isn't one.
function private.CleanKey(k)
	local pk = type(k) == "string" and #k == 43 and Crypto:FromBase64(k)
	return pk and #pk == 32 and k or nil
end



-- ============================================================================
-- Learning keys
-- ============================================================================

---A hello heard on the channel: the sender's key (k) and GUID (g), and kr = 1 when they reset their keys. The game
---stamped the sender, so the key binds to that name.
---@param tbl table the hello
---@param sender string
function KeyBook:FromHello(tbl, sender)
	local k = private.CleanKey(tbl.k)
	if not k or type(sender) ~= "string" or sender == Wanted.Store:GetOrigin() or type(tbl.g) ~= "string" or not strfind(tbl.g, GUID_PATTERN) then
		return
	end
	if tbl.kr == 1 then
		KeyBook:Reset(sender, k, tbl.g)
	else
		private.Bind(sender, k, tbl.g, "live", GetServerTime())
	end
end

---Keys from the desktop app's catch-up: { n = name, g = GUID, k = key, t = when the server took it } each. The server
---only takes a key from the app of the account its character is confirmed to, so these win over keys heard live.
---@param list any
---@param at number when the app wrote the catch-up
function KeyBook:FromApp(list, at)
	if type(list) ~= "table" or type(at) ~= "number" then
		return
	end
	local byOrigin = {}
	for i = 1, min(#list, KeyBook.MAX_ORIGINS) do
		local entry = list[i]
		local k = type(entry) == "table" and private.CleanKey(entry.k)
		if k and type(entry.n) == "string" and #entry.n <= MAX_NAME_BYTES and type(entry.g) == "string" and strfind(entry.g, GUID_PATTERN) then
			local book = Wanted.db.keys[entry.n]
			local t = type(entry.t) == "number" and entry.t or at
			-- A key the owner reset away before the server heard of the reset
			if not (book and book.resetAt and t < book.resetAt) then
				byOrigin[entry.n] = byOrigin[entry.n] or {}
				byOrigin[entry.n][k] = true
				private.Bind(entry.n, k, entry.g, "app", at)
			end
		end
	end
	-- The app's word wins: keys heard live that it doesn't list go
	for origin, listed in pairs(byOrigin) do
		local book = Wanted.db.keys[origin]
		if book then
			book.appAt = max(book.appAt or 0, at)
			for i = #book.list, 1, -1 do
				local key = book.list[i]
				if not listed[key.pk] and key.src ~= "app" then
					Wanted:Log("KeyBook: %s's key %s isn't the app's; dropped", origin, tostring(key.kid))
					tremove(book.list, i)
				end
			end
		end
	end
end

---Adds a key to an origin's set, or notes it was heard again.
function private.Bind(origin, k, guid, src, at)
	local keys = Wanted.db.keys
	local book = keys[origin]
	if type(book) ~= "table" or type(book.list) ~= "table" then
		book = { list = {} }
		keys[origin] = book
	end
	local now = GetServerTime()
	-- Never a key of small order (it checks out for any message). Checked by its bytes: the app can bring a couple of
	-- hundred keys at login, and decoding each takes about 2 ms in the game. The first check with a key decodes it, and
	-- drops it if it isn't a point of the curve after all (KeyBook:Drop).
	if Crypto:IsSmallOrderKey(Crypto:FromBase64(k)) then
		Wanted:Log("!! KeyBook: %s's key is one of small order; not taken", origin)
		return
	end
	-- Another character took the name: the keys of the one before go
	for i = #book.list, 1, -1 do
		if book.list[i].g ~= guid then
			Wanted:Log("KeyBook: %s is another character now; its earlier keys dropped", origin)
			tremove(book.list, i)
		end
	end
	for _, key in ipairs(book.list) do
		if key.pk == k then
			key.lastHeard = max(key.lastHeard or 0, at)
			if src == "app" then
				key.src = "app"
			end
			return
		end
	end
	if src == "live" and book.appAt and now - book.appAt < APP_FRESH_SECONDS then
		Wanted:Log("KeyBook: %s's key heard live isn't the one the app gave; not taken", origin)
		return
	end
	if #book.list >= KeyBook.MAX_KEYS then
		local oldest = 1
		for i, key in ipairs(book.list) do
			if (key.lastHeard or 0) < (book.list[oldest].lastHeard or 0) then
				oldest = i
			end
		end
		tremove(book.list, oldest)
	end
	tinsert(book.list, { pk = k, kid = Crypto:KeyId(Crypto:FromBase64(k)), src = src, g = guid, firstAt = now, lastHeard = at })
	Wanted:Log("KeyBook: learned a key for %s (%s)", origin, src)
	if not book.keyedAt then
		book.keyedAt = now
		private.Grandfather(origin)
	end
	if Wanted.Verify then
		Wanted.Verify:OnKeyLearned(origin)
	end
end

---The origin's first key: the authority records already held from it are marked pre (held before it had a key), so a
---later release that stops counting its unsigned ones keeps counting these.
function private.Grandfather(origin)
	local KINDS, checked, pre = Wanted.Signing.KINDS, Wanted.db.sigChecked, Wanted.db.sigPre
	for record in Wanted.Store:OriginIterator(origin) do
		if KINDS[record.kind] and checked[record.id] == nil then
			pre[record.id] = true
		end
	end
end

---Drops a key that turned out not to be a point of the curve when a check first decoded it.
---@param origin string
---@param k string base64
function KeyBook:Drop(origin, k)
	local book = Wanted.db.keys[origin]
	for i = #(type(book) == "table" and type(book.list) == "table" and book.list or {}), 1, -1 do
		if book.list[i].pk == k then
			tremove(book.list, i)
			Wanted:Log("!! KeyBook: %s's key isn't a usable public key; dropped", origin)
		end
	end
end

---An owner's reset (kr = 1, live only): their key set becomes the new key alone. Records already checked keep what was
---found (sv); the rest wait for a key that signs them.
---@param origin string
---@param k string
---@param guid string
function KeyBook:Reset(origin, k, guid)
	local book = Wanted.db.keys[origin]
	if type(book) == "table" and type(book.list) == "table" then
		for i = #book.list, 1, -1 do
			if book.list[i].pk ~= k then
				tremove(book.list, i)
			end
		end
		book.appAt = nil
		book.resetAt = GetServerTime()
	end
	Wanted:Log("KeyBook: %s reset their keys", origin)
	private.Bind(origin, k, guid, "live", GetServerTime())
end



-- ============================================================================
-- Reading keys
-- ============================================================================

---The key an origin signs with under a key id, if it's known.
---@param origin string
---@param kid string
---@return table? key { pk (base64), kid, src, g, firstAt, lastHeard }
function KeyBook:Find(origin, kid)
	local book = Wanted.db.keys[origin]
	if type(book) ~= "table" or type(book.list) ~= "table" then
		return nil
	end
	for _, key in ipairs(book.list) do
		if key.kid == kid then
			return key
		end
	end
	return nil
end

---Whether any key is known for an origin.
---@param origin string
---@return boolean
function KeyBook:HasKeys(origin)
	local book = Wanted.db.keys[origin]
	return type(book) == "table" and type(book.list) == "table" and #book.list > 0
end

---How many origins have keys, and how many keys in all.
---@return number origins
---@return number keys
function KeyBook:Count()
	local origins, keys = 0, 0
	for _, book in pairs(Wanted.db.keys) do
		if type(book) == "table" and type(book.list) == "table" and #book.list > 0 then
			origins, keys = origins + 1, keys + #book.list
		end
	end
	return origins, keys
end

---A key prepared earlier this session (Crypto:Prepare), or nil.
---@param k string base64
---@return table?
function KeyBook:GetPrepared(k)
	local prepared = private.prepared[k]
	if prepared then
		private.Touch(k)
	end
	return prepared
end

---Keeps a prepared key for the session, letting the least recently used go past PREPARED_MAX.
---@param k string base64
---@param prepared table
function KeyBook:KeepPrepared(k, prepared)
	if not prepared then
		return
	end
	if not private.prepared[k] and #private.preparedOrder >= PREPARED_MAX then
		private.prepared[tremove(private.preparedOrder, 1)] = nil
	end
	private.prepared[k] = prepared
	private.Touch(k)
end

function private.Touch(k)
	local order = private.preparedOrder
	for i = #order, 1, -1 do
		if order[i] == k then
			tremove(order, i)
		end
	end
	tinsert(order, k)
end



-- ============================================================================
-- Pruning
-- ============================================================================

---Drops origins not heard for KEEP_SECONDS that have no authority record held, then the least recently heard until
---MAX_ORIGINS remain.
---@param now number
function KeyBook:Prune(now)
	local keys = Wanted.db.keys
	local KINDS = Wanted.Signing.KINDS
	local function Heard(book)
		local last = 0
		for _, key in ipairs(type(book) == "table" and type(book.list) == "table" and book.list or {}) do
			last = max(last, key.lastHeard or 0)
		end
		return last
	end
	local function HoldsAuthority(origin)
		for record in Wanted.Store:OriginIterator(origin) do
			if KINDS[record.kind] then
				return true
			end
		end
		return false
	end
	local dropped, left = 0, {}
	for origin, book in pairs(keys) do
		if type(book) ~= "table" or type(book.list) ~= "table" or #book.list == 0
			or (Heard(book) < now - KEEP_SECONDS and not HoldsAuthority(origin)) then
			keys[origin] = nil
			dropped = dropped + 1
		else
			tinsert(left, origin)
		end
	end
	if #left > KeyBook.MAX_ORIGINS then
		local heard = {}
		for _, origin in ipairs(left) do
			heard[origin] = Heard(keys[origin])
		end
		sort(left, function(a, b) return heard[a] > heard[b] end)
		for i = KeyBook.MAX_ORIGINS + 1, #left do
			keys[left[i]] = nil
			dropped = dropped + 1
		end
	end
	if dropped > 0 then
		Wanted:Log("KeyBook: dropped %d origins' keys (not heard for %d days, or past the %d most recent)", dropped, KEEP_SECONDS / 86400, KeyBook.MAX_ORIGINS)
	end
end

function KeyBook:Status()
	local origins, keys = KeyBook:Count()
	return format("KeyBook: %d keys for %d players.", keys, origins)
end
