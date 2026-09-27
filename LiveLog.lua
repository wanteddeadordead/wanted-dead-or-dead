-- Wanted: live battle reports. The desktop app reads the game's combat log (Logs\WoWCombatLog-*.txt) and uploads
-- the deaths in it, so the website's battle reports fill in during a fight rather than after a /reload. The
-- game writes the log out every five minutes whatever an addon does (switching logging off and on doesn't
-- make it write sooner), so Wanted only keeps logging on.
--
-- Logging is on in the open world and off in instances, which aren't world PvP. Wanted only ever turns off
-- logging it turned on itself: logging the player started (for Warcraft Logs, say) stays on.

local _, Wanted = ...
local LiveLog = Wanted:NewModule("LiveLog")

function LiveLog:OnEnable()
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	frame:SetScript("OnEvent", function() LiveLog:Update() end)
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
