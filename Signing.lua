-- Wanted: this account's signing keys. Each character signs its authority records (bounties, confirms, payments
-- and the rest: Signing.KINDS) with its own Ed25519 key, so a record relayed by someone else can't be forged in its
-- name. The keys come from one account seed: the desktop app's when it's installed (WantedAppSeed in !!WantedLink),
-- else one made here from the timing of game events, which is weak (below). With no seed yet nothing is signed, and
-- records follow the rules for unsigned ones. Only public keys ever leave this client.

local _, Wanted = ...
local Signing = Wanted:NewModule("Signing")
local Crypto = Wanted.Crypto
local private = {
	key = nil, -- this character's key: { seed, pk, kid, k (base64 pk), from (the account seed it was made from) }
	pool = nil, -- the local seed being gathered: { state, samples, count }
	resetHello = false, -- the next hello carries kr = 1 (keys reset)
}

-- The kinds of record an authority decision reads (who posted, raised, withdrew, confirmed, paid...). They're made
-- on a click or a mail, almost never in a fight. Kills, deaths, assists, sightings and proofs are not signed.
Signing.KINDS = { bounty = true, raise = true, withdraw = true, pass = true, hunt = true, claim = true, confirm = true,
	mark = true, payment = true, link = true, notice = true }
-- data.sig: this version, the key id (8) and the signature in base64 (86)
Signing.SIG_VERSION = "1"
Signing.SIG_LENGTH = 95
-- What a signature covers comes after this line (Store:SigningMessage)
Signing.MESSAGE_PREFIX = "wanted-sig-v1\n"
local CHAR_KEY_PREFIX = "wanted-char-key-v1\n"

-- The local seed: event times sampled until this many, hashed a few at a time in the background work
local POOL_EVENTS = 256
local POOL_FOLD = 8
-- Events that come often while playing, at times nobody else sees to the microsecond. Not the combat log: registering
-- COMBAT_LOG_EVENT_UNFILTERED is forbidden on this client (the game blocks it).
local POOL_TRIGGERS = { "CHAT_MSG_CHANNEL", "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_GUILD", "CHAT_MSG_WHISPER",
	"CHAT_MSG_ADDON", "CHAT_MSG_SYSTEM", "PLAYER_STARTED_MOVING", "PLAYER_STOPPED_MOVING", "PLAYER_TARGET_CHANGED",
	"UPDATE_MOUSEOVER_UNIT", "CURSOR_CHANGED", "MODIFIER_STATE_CHANGED", "NAME_PLATE_UNIT_ADDED", "BAG_UPDATE" }
-- And the player's own health, auras and power, which change many times a minute in play
local POOL_UNIT_TRIGGERS = { "UNIT_HEALTH", "UNIT_AURA", "UNIT_POWER_FREQUENT" }



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Signing:OnLoad()
	local signing = Wanted.db.signing
	local seed = signing.seed
	if seed ~= nil and (type(seed) ~= "string" or #seed ~= 64 or strfind(seed, "[^%x]")) then
		Wanted:Log("!! Signing: the saved seed isn't 64 hex digits; dropped")
		signing.seed, signing.source = nil, nil
	end
end

function Signing:OnEnable()
	private.TakeAppSeed()
	if not Wanted.db.signing.seed then
		private.StartPool()
	end
	-- Made now, at login, so the first click doesn't wait for it (about 20 ms in the game)
	Wanted:QueueWork(function() private.Key() end)
end

---Takes the desktop app's seed for this WoW account, unless it's the one /wanted key reset dropped. A new seed is a
---new key for every character: peers add it to the ones they know.
function private.TakeAppSeed()
	local signing = Wanted.db.signing
	local seed = type(WantedAppSeed) == "table" and WantedAppSeed[Wanted.db.accountMark]
	if type(seed) ~= "string" or #seed ~= 64 or strfind(seed, "[^%x]") then
		return
	end
	seed = strlower(seed)
	if (signing.source == "app" and signing.seed == seed) or signing.appDropped == private.SeedMark(seed) then
		return
	end
	signing.seed, signing.source = seed, "app"
	private.StopPool()
	Wanted:Log("Signing: the seed is the desktop app's")
end

---A short mark of a seed (not the seed): which app seed /wanted key reset dropped.
function private.SeedMark(seedHex)
	return Crypto:Hex(strsub(Crypto:SHA512("wanted-seed-mark\n"..seedHex), 1, 8))
end



-- ============================================================================
-- Keys
-- ============================================================================

---This character's key from the account seed and its GUID, made once a session. nil while there's no seed.
---@return table?
function private.Key()
	local seedHex = Wanted.db.signing.seed
	local guid = UnitGUID("player")
	if not seedHex or type(guid) ~= "string" then
		return nil
	end
	local key = private.key
	if not key or key.from ~= seedHex or key.guid ~= guid then
		local seed = strsub(Crypto:SHA512(CHAR_KEY_PREFIX..Crypto:FromHex(seedHex).."\n"..guid), 1, 32)
		local pk = Crypto:PublicKey(seed)
		key = { seed = seed, pk = pk, kid = Crypto:KeyId(pk), k = Crypto:Base64(pk), from = seedHex, guid = guid }
		private.key = key
		Wanted:Log("Signing: this character's key is %s (%s seed)", key.kid, tostring(Wanted.db.signing.source))
	end
	-- The desktop app reads the public keys and gives them to the server for this account's characters
	local origin = Wanted.Store:GetOrigin()
	local pub = Wanted.db.signing.pub[origin]
	if type(pub) ~= "table" or pub.k ~= key.k or pub.g ~= guid then
		Wanted.db.signing.pub[origin] = { k = key.k, g = guid }
	end
	return key
end

---Whether records made now would be signed: there's a seed and the self-test hasn't failed. Cheap: a fight asks it.
---@return boolean
function Signing:CanSign()
	return Wanted.db.signing.seed ~= nil and Crypto:IsOn() ~= false
end

---data.sig for a message (Store:SigningMessage), or nil when nothing is signed: no seed yet, a failed self-test, or
---a fight (a signature takes about 20 ms in the game).
---@param message string
---@return string?
function Signing:Sign(message)
	if Wanted:InCombat() or not Signing:CanSign() or not Crypto:EnsureSelfTest() then
		return nil
	end
	local key = private.Key()
	if not key then
		return nil
	end
	return Signing.SIG_VERSION..key.kid..Crypto:Base64(Crypto:Sign(key.seed, key.pk, message))
end

---This character's public key in base64 (43 characters) and its key id, or nil while there's no seed.
---@return string? k
---@return string? kid
function Signing:PublicKey()
	local key = Signing:CanSign() and private.Key()
	if not key then
		return nil, nil
	end
	return key.k, key.kid
end

---Adds this character's key to a hello: k (the public key) and g (the GUID it's bound to), and kr = 1 on the one
---hello after /wanted key reset.
---@param fields table
function Signing:AddToHello(fields)
	local k = Signing:PublicKey()
	if not k then
		return
	end
	fields.k, fields.g = k, UnitGUID("player")
	if private.OwesResetHello() then
		fields.kr = 1
	end
end

---Whether this character hasn't yet said kr = 1 since the account's keys were last reset: every character of the
---account says it once, on its first hello with its new key.
function private.OwesResetHello()
	local signing = Wanted.db.signing
	return type(signing.resetAt) == "number" and (type(signing.krSent) ~= "table" or signing.krSent[Wanted.Store:GetOrigin()] ~= signing.resetAt)
end

---A hello with kr = 1 went out from this character: its later ones go without it.
function Signing:ResetSent()
	local signing = Wanted.db.signing
	signing.krSent = type(signing.krSent) == "table" and signing.krSent or {}
	signing.krSent[Wanted.Store:GetOrigin()] = signing.resetAt
end

---Where the seed came from: "app", "local" or nil (none yet).
---@return string?
function Signing:Source()
	return Wanted.db.signing.seed and Wanted.db.signing.source or nil
end



-- ============================================================================
-- The local seed (no desktop app)
-- ============================================================================

-- Weak: it rests on the times game events reach this client, to the microsecond (debugprofilestop and
-- GetTimePreciseSec), plus a few readings of the machine and session. No API promises those are hard to guess, and it
-- hasn't been measured. It beats signing nothing, and the desktop app's seed (Go crypto/rand) replaces it when the app
-- is installed.

---Starts gathering a seed: event times until POOL_EVENTS, then the seed.
function private.StartPool()
	if private.pool then
		return
	end
	private.pool = { state = private.Readings(), samples = {}, count = 0 }
	private.poolFrame = private.poolFrame or CreateFrame("Frame")
	for _, event in ipairs(POOL_TRIGGERS) do
		private.poolFrame:RegisterEvent(event)
	end
	for _, event in ipairs(POOL_UNIT_TRIGGERS) do
		private.poolFrame:RegisterUnitEvent(event, "player")
	end
	private.poolFrame:SetScript("OnEvent", private.OnPoolEvent)
	Wanted:Log("Signing: no seed yet; gathering one from event times")
end

function private.StopPool()
	private.pool = nil
	if private.poolFrame then
		private.poolFrame:UnregisterAllEvents()
	end
end

function private.OnPoolEvent()
	local pool = private.pool
	if not pool then
		return
	end
	local precise = type(GetTimePreciseSec) == "function" and GetTimePreciseSec() or 0
	pool.samples[#pool.samples + 1] = format("%.17g %.17g", debugprofilestop(), precise)
	pool.count = pool.count + 1
	if #pool.samples >= POOL_FOLD and not pool.foldDue then
		pool.foldDue = true
		C_Timer.After(0, private.FoldPool)
	end
end

---Hashes the samples taken so far into the pool, POOL_FOLD at a time (a few SHA-512 blocks, under 3 ms in the game),
---on a timer rather than in the background work: Sync holds incoming messages while work is waiting. Not in a fight.
function private.FoldPool()
	local pool = private.pool
	if not pool then
		return
	end
	if Wanted:InCombat() then
		C_Timer.After(1, private.FoldPool)
		return
	end
	local samples = table.concat(pool.samples, "\n", 1, POOL_FOLD)
	for _ = 1, POOL_FOLD do
		tremove(pool.samples, 1)
	end
	pool.state = Crypto:SHA512(pool.state..samples)
	pool.folded = (pool.folded or 0) + POOL_FOLD
	if pool.folded >= POOL_EVENTS then
		private.FinishPool(pool)
	elseif #pool.samples >= POOL_FOLD then
		C_Timer.After(0, private.FoldPool)
	else
		pool.foldDue = nil
	end
end

---Readings of the machine and session mixed in at the start and the end.
function private.Readings()
	local parts = { tostring(time()), tostring(GetTime()), tostring(GetServerTime()), format("%.17g", debugprofilestop()),
		tostring(UnitGUID("player")), tostring(math.random()), format("%.17g", collectgarbage("count")) }
	if type(fastrandom) == "function" then
		tinsert(parts, tostring(fastrandom()))
	end
	if type(GetTimePreciseSec) == "function" then
		tinsert(parts, format("%.17g", GetTimePreciseSec()))
	end
	if type(GetCursorPosition) == "function" then
		local x, y = GetCursorPosition()
		tinsert(parts, format("%.17g,%.17g", x or 0, y or 0))
	end
	if type(GetNetStats) == "function" then
		local down, up, home, world = GetNetStats()
		tinsert(parts, format("%s,%s,%s,%s", tostring(down), tostring(up), tostring(home), tostring(world)))
	end
	if type(GetFramerate) == "function" then
		tinsert(parts, format("%.17g", GetFramerate() or 0))
	end
	return table.concat(parts, "\n")
end

function private.FinishPool(pool)
	local signing = Wanted.db.signing
	private.StopPool()
	if signing.seed then
		return
	end
	signing.seed = Crypto:Hex(strsub(Crypto:SHA512("wanted-local-seed\n"..pool.state..private.Readings()), 1, 32))
	signing.source = "local"
	Wanted:Log("Signing: a seed was made from %d event times (weak: the desktop app's replaces it)", pool.folded)
	Wanted:QueueWork(function()
		private.Key()
		-- After /wanted key reset: tell the channel at once, with kr = 1
		if private.OwesResetHello() and Wanted.Sync and Wanted.Sync.SayHello then
			Wanted.Sync:SayHello()
		end
	end)
end



-- ============================================================================
-- Reset
-- ============================================================================

---Drops this account's seed and makes a new one (from event times: an app seed that was stolen can't be used
---again), and every character's public key, so the app uploads none from before (it tells the server the time, and
---the server retires the keys bound before it). Every character of the account gets a new key and says kr = 1 on its
---first hello with it: peers who hear that keep only the new key for that character (and what they already checked).
function Signing:Reset()
	local signing = Wanted.db.signing
	if signing.source == "app" and signing.seed then
		signing.appDropped = private.SeedMark(signing.seed)
	end
	signing.seed, signing.source = nil, nil
	signing.resetAt = GetServerTime()
	signing.pub = {}
	private.key = nil
	private.StopPool()
	private.StartPool()
	Wanted:Log("Signing: keys reset")
end

Wanted:RegisterCommand("key", "Your signing key: /wanted key shows it, /wanted key reset makes a new one (if your saved data was copied).", function(args)
	if strlower(strtrim(args or "")) == "reset" then
		Signing:Reset()
		Wanted:Print("Your signing keys are being remade. In a few minutes of play the new one is ready and other Wanted players are told to drop the old one.")
		return
	end
	local k, kid = Signing:PublicKey()
	if not k then
		Wanted:Print("No signing key yet: one is made in a few minutes of play (or from the desktop app). Until then your bounties, claims and payments go unsigned.")
	else
		Wanted:Print("Your signing key: %s (%s). Records you post are signed with it.", kid,
			Signing:Source() == "app" and "from the desktop app" or "made by the addon; the desktop app gives a stronger one")
	end
end)

function Signing:Status()
	local k, kid = Signing:PublicKey()
	return format("Signing: %s.", k and (kid.." ("..tostring(Signing:Source()).." seed)") or "no key yet")
end
