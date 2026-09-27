-- Wanted: live battle reports. The desktop app reads the game's combat log (Logs\WoWCombatLog-*.txt) and uploads
-- the deaths in it, so the website's battle reports fill in during a fight rather than after a /reload. The
-- game keeps the combat log in memory until logging is switched off, so while there's fighting around, Wanted
-- switches logging off and straight back on every few seconds, which makes the game write out what it holds.
--
-- Logging is on in the open world and off in instances, which aren't world PvP. Wanted only ever turns off
-- logging it turned on itself: logging the player started (for Warcraft Logs, say) stays on.

local _, Wanted = ...
local LiveLog = Wanted:NewModule("LiveLog")
local Store = Wanted.Store
local private = {}

-- How often the log is written out while there's fighting
local WRITE_SECONDS = 5
-- How long after the last sign of fighting (a record, or being in combat) it keeps being written out
local ACTIVE_SECONDS = 30

private.lastActive = 0

function LiveLog:OnEnable()
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	frame:SetScript("OnEvent", function() LiveLog:Update() end)
	-- Any record, ours or shared, means someone is fighting nearby
	Store:OnRecord("*", function() private.lastActive = GetServerTime() end)
	C_Timer.NewTicker(WRITE_SECONDS, function() LiveLog:Tick() end)
	LiveLog:Update()
end

---Turns logging on or off for the setting and where the player is.
function LiveLog:Update()
	local want = Wanted.db.settings.liveLog and not IsInInstance()
	local logging = LoggingCombat()
	if want and not logging then
		LoggingCombat(true)
		Wanted.db.liveLogOn = true
		Wanted:Log("LiveLog: combat logging on")
	elseif not want and logging and Wanted.db.liveLogOn then
		LoggingCombat(false)
		Wanted.db.liveLogOn = nil
		Wanted:Log("LiveLog: combat logging off")
	end
end

---Every few seconds: while there's fighting, has the game write out the combat log it's holding.
function LiveLog:Tick()
	local active = Wanted:InCombat() or GetServerTime() - private.lastActive <= ACTIVE_SECONDS
	if active and LoggingCombat() then
		LoggingCombat(false)
		LoggingCombat(true)
	end
end
