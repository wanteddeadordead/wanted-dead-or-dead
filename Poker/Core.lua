-- Wanted: Dead Man's Hand Poker. Texas hold'em at the Wanted table, as a second addon: it needs Wanted: Dead or...
-- Dead (the .toc's Dependencies, so the game loads it after the base and not without it) and runs on the base's
-- comms, keys, widgets, window and payments through the base's namespace, which the base makes global (Wanted).
-- Core: this addon's modules and their load order, the way the base's Core does it.
local ADDON_NAME, Poker = ...
Poker.Wanted = _G.Wanted
Poker.VERSION = C_AddOns and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "?"
Poker.FOLDER = ADDON_NAME
local modules = {}

---Registers a module; its OnLoad runs once this addon has loaded, its OnEnable at PLAYER_LOGIN.
---@param name string
---@return table
function Poker:NewModule(name)
	assert(not Poker[name], "duplicate module "..name)
	local module = {}
	Poker[name] = module
	tinsert(modules, module)
	return module
end

local function CallModules(funcName)
	for _, module in ipairs(modules) do
		if module[funcName] then
			module[funcName](module)
		end
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, name)
	if event == "ADDON_LOADED" and name == ADDON_NAME then
		-- This addon's saved data: the table window's place and the last settings hosted with (WantedPokerDB)
		WantedPokerDB = type(WantedPokerDB) == "table" and WantedPokerDB or {}
		Poker.db = WantedPokerDB
		CallModules("OnLoad")
	elseif event == "PLAYER_LOGIN" then
		CallModules("OnEnable")
	end
end)
