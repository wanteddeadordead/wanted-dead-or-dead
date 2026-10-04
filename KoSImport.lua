-- Wanted: Kill on Sight from Spy. When Spy is installed alongside Wanted, its Kill on Sight lists (this character's
-- and the other characters' Spy keeps in the account data) can be brought over with their reasons. Spy keeps names,
-- Wanted keeps game IDs: a name Wanted has seen goes on Kill on Sight at once, the others wait (WantedDB.kosPending)
-- until the player is first seen, and Enemies puts them on Kill on Sight then, before the first alert.

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
function private.Reason(player)
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

---Every name on Spy's Kill on Sight lists, once, as Wanted writes names: name -> Spy's player entry or false.
function private.SpyNames()
	local out = {}
	local perChar = type(SpyPerCharDB) == "table" and SpyPerCharDB or nil
	local players = perChar and type(perChar.PlayerData) == "table" and perChar.PlayerData or {}
	if perChar and type(perChar.KOSData) == "table" then
		for name in pairs(perChar.KOSData) do
			if type(name) == "string" then
				out[private.CleanName(name)] = players[name] or false
			end
		end
	end
	-- The other characters' lists: kosData[realm][faction][character] = { name = time }
	local account = type(SpyDB) == "table" and type(SpyDB.kosData) == "table" and SpyDB.kosData or {}
	for _, factions in pairs(account) do
		for _, characters in pairs(type(factions) == "table" and factions or {}) do
			for _, list in pairs(type(characters) == "table" and characters or {}) do
				for name in pairs(type(list) == "table" and list or {}) do
					if type(name) == "string" and out[private.CleanName(name)] == nil then
						out[private.CleanName(name)] = players[name] or false
					end
				end
			end
		end
	end
	return out
end

---The players Wanted has seen, by lower-case name: one pass over thousands, not one per imported name.
function private.NameIndex()
	local index = {}
	for guid, player in pairs(Wanted.db.players) do
		if type(player.name) == "string" then
			index[strlower(player.name)] = guid
		end
	end
	return index
end

---Whether a name is already on Wanted's Kill on Sight (by its game ID), ignored, or waiting.
function private.AlreadyHave(name, index)
	if Wanted.db.kosPending[strlower(name)] then
		return true
	end
	local guid = index[strlower(name)]
	return guid ~= nil and (Wanted.db.kos[guid] ~= nil or Wanted.db.ignore[guid] ~= nil)
end

---How many players on Spy's lists aren't on Wanted's yet (0 without Spy).
---@return number
function KoSImport:SpyCount()
	local names = private.SpyNames()
	if next(names) == nil then
		return 0
	end
	local index, count = private.NameIndex(), 0
	for name in pairs(names) do
		if not private.AlreadyHave(name, index) then
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

---Brings Spy's Kill on Sight over. Returns how many went on Kill on Sight now and how many wait to be seen.
---@return number added
---@return number waiting
function KoSImport:ImportSpy()
	local added, waiting = 0, 0
	local index = private.NameIndex()
	for name, player in pairs(private.SpyNames()) do
		if not private.AlreadyHave(name, index) then
			local reason = private.Reason(player)
			local guid = index[strlower(name)]
			if guid then
				Wanted.Enemies:SetKoS(guid, name, true)
				Wanted.Enemies:SetReason(guid, reason)
				added = added + 1
			else
				Wanted.db.kosPending[strlower(name)] = { name = name, reason = reason, t = GetServerTime(), from = "Spy" }
				waiting = waiting + 1
			end
		end
	end
	private.countAt = nil
	Wanted:Log("KoSImport: from Spy, %d on Kill on Sight, %d waiting to be seen", added, waiting)
	return added, waiting
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
function private.Report(added, waiting)
	if added + waiting == 0 then
		Wanted:Print("Spy's Kill on Sight has nobody who isn't on Wanted's already.")
		return
	end
	Wanted:Print("From Spy: %d on Kill on Sight now%s.", added,
		waiting > 0 and format(", %d more go on it the first time Wanted sees them", waiting) or "")
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
			Wanted:Print("Spy's Kill on Sight has %d player%s Wanted doesn't. Bring them over: /wanted importspy, or Enemies, Kill on Sight, Import from Spy.",
				count, count == 1 and "" or "s")
		end
	end)
end

Wanted:RegisterCommand("importspy", "Brings Spy's Kill on Sight lists over, with their reasons: /wanted importspy", function()
	KoSImport:Run()
end)
