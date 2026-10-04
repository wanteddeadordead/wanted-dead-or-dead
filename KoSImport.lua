-- Wanted: Kill on Sight from Spy and True Spy. When either is installed alongside Wanted, its Kill on Sight lists can
-- be brought over with their reasons: Spy's for this character and the others it keeps in the account data, True
-- Spy's for every realm. They keep names, Wanted keeps game IDs: a name Wanted has seen goes on Kill on Sight at once,
-- the others wait (WantedDB.kosPending) until the player is first seen, and Enemies puts them on Kill on Sight then,
-- before the first alert. True Spy keys players by first name on Forever: a first name goes over only when Wanted
-- knows exactly one player by it; the rest are skipped, never guessed.

local _, Wanted = ...
local KoSImport = Wanted:NewModule("KoSImport")
local private = {}
local PENDING_DAYS = 30 -- a name nobody sees in this long stops waiting
local HINT_DELAY = 20 -- seconds after login before the one-time hint, clear of the login chatter

---Spy's names are "First-Last" (it joins the two parts of a Forever name with a dash); Wanted's are "First Last".
function private.CleanName(name)
	return (gsub(strtrim(name), "%-", " "))
end

---Spy's reasons for a player: its reason table holds a key per reason, or the text for its "Other" reason.
function private.SpyReason(player)
	local parts = {}
	if type(player) == "table" and type(player.reason) == "table" then
		for key, value in pairs(player.reason) do
			if type(value) == "string" and value ~= "" then
				tinsert(parts, value)
			elseif value == true and type(key) == "string" then
				tinsert(parts, key)
			end
		end
	end
	sort(parts)
	return #parts > 0 and table.concat(parts, ", ") or "From Spy"
end

---Every name on Spy's and True Spy's Kill on Sight lists, once: name -> { reason, from, firstOnly }.
function private.Names()
	local out = {}
	local function Add(name, reason, from)
		if type(name) ~= "string" or name == "" then
			return
		end
		name = private.CleanName(name)
		if out[name] == nil then
			out[name] = { reason = reason, from = from, firstOnly = not strfind(name, " ") }
		end
	end
	-- Spy: this character's list, then the other characters' (kosData[realm][faction][character] = { name = time })
	local perChar = type(SpyPerCharDB) == "table" and SpyPerCharDB or nil
	local players = perChar and type(perChar.PlayerData) == "table" and perChar.PlayerData or {}
	if perChar and type(perChar.KOSData) == "table" then
		for name in pairs(perChar.KOSData) do
			Add(name, private.SpyReason(players[name]), "Spy")
		end
	end
	local account = type(SpyDB) == "table" and type(SpyDB.kosData) == "table" and SpyDB.kosData or {}
	for _, factions in pairs(account) do
		for _, characters in pairs(type(factions) == "table" and factions or {}) do
			for _, list in pairs(type(characters) == "table" and characters or {}) do
				for name in pairs(type(list) == "table" and list or {}) do
					Add(name, private.SpyReason(players[name]), "Spy")
				end
			end
		end
	end
	-- True Spy: realms[realm].kos[name] = { reason, added }
	local realms = type(TrueSpyDB) == "table" and type(TrueSpyDB.realms) == "table" and TrueSpyDB.realms or {}
	for _, realm in pairs(realms) do
		for name, entry in pairs(type(realm) == "table" and type(realm.kos) == "table" and realm.kos or {}) do
			local reason = type(entry) == "table" and type(entry.reason) == "string" and entry.reason ~= "" and entry.reason or "From True Spy"
			Add(name, reason, "True Spy")
		end
	end
	return out
end

---The players Wanted has seen, by lower-case full name and by lower-case first name (false when several share it):
---one pass over thousands, not one per imported name.
function private.Indexes()
	local byName, byFirst = {}, {}
	for guid, player in pairs(Wanted.db.players) do
		if type(player.name) == "string" then
			local lower = strlower(player.name)
			byName[lower] = guid
			local first = strmatch(lower, "^(%S+)")
			if first then
				byFirst[first] = byFirst[first] == nil and guid or false
			end
		end
	end
	return byName, byFirst
end

---Where an imported name leads: the player's game ID and full name when Wanted knows them, or nil and why ("wait"
---for a full name not seen yet, "skip" for a first name that isn't one known player's).
function private.Resolve(name, entry, byName, byFirst)
	if entry.firstOnly then
		local guid = byFirst[strlower(name)]
		if guid then
			return guid, Wanted.db.players[guid].name
		end
		return nil, "skip"
	end
	local guid = byName[strlower(name)]
	if guid then
		return guid, name
	end
	return nil, "wait"
end

---Whether Wanted has the player already: on Kill on Sight (by game ID), ignored, or waiting.
function private.AlreadyHave(guid, name)
	if guid then
		return Wanted.db.kos[guid] ~= nil or Wanted.db.ignore[guid] ~= nil
	end
	return Wanted.db.kosPending[strlower(name)] ~= nil
end

---How many players on Spy's and True Spy's lists can come over (0 without either).
---@return number
function KoSImport:SpyCount()
	local names = private.Names()
	if next(names) == nil then
		return 0
	end
	local byName, byFirst = private.Indexes()
	local count = 0
	for name, entry in pairs(names) do
		local guid, why = private.Resolve(name, entry, byName, byFirst)
		if why ~= "skip" and not private.AlreadyHave(guid, name) then
			count = count + 1
		end
	end
	return count
end

---SpyCount, worked out at most every half minute: for a page that redraws often.
function KoSImport:SpyCountCached()
	if not private.countAt or GetTime() - private.countAt > 30 then
		private.count, private.countAt = KoSImport:SpyCount(), GetTime()
	end
	return private.count
end

---Brings Spy's and True Spy's Kill on Sight over. Returns how many went on Kill on Sight now, how many wait to be
---seen, and how many first names were skipped (not one known player's).
---@return number added
---@return number waiting
---@return number skipped
function KoSImport:ImportSpy()
	local added, waiting, skipped = 0, 0, 0
	local byName, byFirst = private.Indexes()
	for name, entry in pairs(private.Names()) do
		local guid, why = private.Resolve(name, entry, byName, byFirst)
		if why == "skip" then
			skipped = skipped + 1
		elseif not private.AlreadyHave(guid, name) then
			if guid then
				Wanted.Enemies:SetKoS(guid, why, true)
				Wanted.Enemies:SetReason(guid, entry.reason)
				added = added + 1
			else
				Wanted.db.kosPending[strlower(name)] = { name = name, reason = entry.reason, t = GetServerTime(), from = entry.from }
				waiting = waiting + 1
			end
		end
	end
	private.countAt = nil
	Wanted:Log("KoSImport: %d on Kill on Sight, %d waiting to be seen, %d first names skipped", added, waiting, skipped)
	return added, waiting, skipped
end

---How many names wait to be seen.
function KoSImport:CountPending()
	local count = 0
	for _ in pairs(Wanted.db.kosPending) do
		count = count + 1
	end
	return count
end

---Drops names nobody has seen in PENDING_DAYS.
function KoSImport:PrunePending()
	local cutoff = GetServerTime() - PENDING_DAYS * 86400
	for key, entry in pairs(Wanted.db.kosPending) do
		if type(entry) ~= "table" or (entry.t or 0) < cutoff then
			Wanted.db.kosPending[key] = nil
		end
	end
end

---Says the import's result in chat.
function private.Report(added, waiting, skipped)
	if added + waiting == 0 then
		Wanted:Print("Spy's and True Spy's Kill on Sight have nobody new for Wanted's.%s", skipped > 0
			and format(" %d first name%s couldn't be matched to one player.", skipped, skipped == 1 and "" or "s") or "")
		return
	end
	Wanted:Print("Kill on Sight brought over: %d on it now%s%s.", added,
		waiting > 0 and format(", %d more go on it the first time Wanted sees them", waiting) or "",
		skipped > 0 and format("; %d first name%s from True Spy skipped (more than one player, or nobody Wanted knows, has it)", skipped, skipped == 1 and "" or "s") or "")
end

function KoSImport:Run()
	private.Report(KoSImport:ImportSpy())
end

function KoSImport:OnEnable()
	KoSImport:PrunePending()
	-- Once per account: Spy is installed with names Wanted doesn't have
	C_Timer.After(HINT_DELAY, function()
		if Wanted.db.spyImportHinted then
			return
		end
		local count = KoSImport:SpyCount()
		if count > 0 then
			Wanted.db.spyImportHinted = true
			Wanted:Print("Your Spy or True Spy Kill on Sight has %d player%s Wanted doesn't. Bring them over: /wanted importspy, or Enemies, Import Kill on Sight.",
				count, count == 1 and "" or "s")
		end
	end)
end

Wanted:RegisterCommand("importspy", "Brings Spy's and True Spy's Kill on Sight lists over, with their reasons: /wanted importspy", function()
	KoSImport:Run()
end)
