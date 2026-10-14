-- Wanted: Dead Man's Hand Poker. The vault: what must survive a crash. The game writes an addon's saved variables
-- only at logout or reload, so a crash loses everything since; a macro's body, on the other hand, goes to the server
-- the moment it's edited and comes back at the next login. The open debts and the gold table under way are small,
-- so they're kept in a few character macros named WantedPoker1, 2, ... (Gold writes them after every change and
-- reads them back at login). Nothing here is ever run as a macro: the bodies are data, not commands.
local _, Poker = ...
local Vault = Poker:NewModule("PokerVault")
local Wanted = Poker.Wanted
local private = { frame = CreateFrame("Frame"), pending = nil, waiting = false }
local NAME = "WantedPoker"
local BODY = 255 -- a macro body's limit
local MAX_CHUNKS = 6
local ICON = 134400 -- the question mark

local function Available()
	return type(EditMacro) == "function" and type(CreateMacro) == "function" and type(GetMacroIndexByName) == "function" and type(GetMacroBody) == "function"
end

---Whether this client can keep anything (the macro functions exist).
function Vault:Available()
	return Available()
end

function Vault:OnEnable()
	private.frame:RegisterEvent("PLAYER_REGEN_ENABLED")
	private.frame:SetScript("OnEvent", function()
		if private.pending then private.Write() end
	end)
end

---Keeps data for a crash: written a moment later (changes close together are written once), or once out of
---combat, since macros can't change in a fight. Nil clears what's kept.
---@param data table?
function Vault:Save(data)
	private.pending = { data = data }
	if private.waiting then
		return
	end
	private.waiting = true
	C_Timer.After(1, function()
		private.waiting = false
		private.Write()
	end)
end

function private.Write()
	local job = private.pending
	if not job or not Available() then
		return
	end
	if InCombatLockdown() then
		return -- PLAYER_REGEN_ENABLED comes back here
	end
	private.pending = nil
	local text = job.data and Wanted.Crypto:Base64(Wanted.Sync:Encode(job.data)) or ""
	local chunks = {}
	for i = 1, #text, BODY do
		chunks[#chunks + 1] = strsub(text, i, i + BODY - 1)
	end
	if #chunks > MAX_CHUNKS then
		Wanted:Log("!! Poker vault: too much to keep (%d characters); nothing kept", #text)
		chunks = {}
	end
	for i = 1, MAX_CHUNKS do
		local index = GetMacroIndexByName(NAME..i)
		if index == 0 then index = nil end
		local body = chunks[i]
		if body then
			if index then
				EditMacro(index, nil, nil, body)
			elseif not CreateMacro(NAME..i, ICON, body, true) then
				Wanted:Log("!! Poker vault: the game made no room for %s%d", NAME, i)
			end
		elseif index then
			-- No longer needed: emptied, so a stale chunk is never read back
			EditMacro(index, nil, nil, "")
		end
	end
end

---What was kept, or nil.
---@return table?
function Vault:Load()
	if not Available() then
		return nil
	end
	local parts = {}
	for i = 1, MAX_CHUNKS do
		local index = GetMacroIndexByName(NAME..i)
		if not index or index == 0 then break end
		local body = GetMacroBody(index)
		if not body or body == "" then break end
		parts[#parts + 1] = body
	end
	if #parts == 0 then
		return nil
	end
	local raw = Wanted.Crypto:FromBase64(table.concat(parts))
	local data = raw and Wanted.Sync:Decode(raw)
	return type(data) == "table" and data or nil
end
