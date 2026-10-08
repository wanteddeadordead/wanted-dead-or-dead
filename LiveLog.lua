-- Wanted: live battle reports. The desktop app reads the game's combat log (Logs\WoWCombatLog-*.txt) and uploads
-- the deaths in it, so the website's battle reports fill in during a fight rather than after a /reload. The
-- game writes the log out every five minutes whatever an addon does (switching logging off and on doesn't
-- make it write sooner), so Wanted only keeps logging on.
--
-- Logging is on in the open world and off in instances, which aren't world PvP (the app's log reader doesn't tell
-- them apart). Wanted only ever turns off logging it turned on itself: logging that was on already (the player's, for
-- Warcraft Logs, say), or that anything else switched since (a raid logger, /combatlog), is theirs and stays as it is.

local _, Wanted = ...
local LiveLog = Wanted:NewModule("LiveLog")
local private = { setting = false }

function LiveLog:OnEnable()
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	frame:SetScript("OnEvent", function() LiveLog:Update() end)
	-- Anything else switching logging (another addon, /combatlog) makes it theirs
	pcall(hooksecurefunc, "LoggingCombat", function(on)
		if on ~= nil and not private.setting and Wanted.db.liveLogOn then
			Wanted.db.liveLogOn = nil
			Wanted:Log("LiveLog: combat logging switched by something else; it's theirs now")
		end
	end)
	LiveLog:Update()
end

---Switches logging, as Wanted's own.
function private.Set(on)
	private.setting = true
	LoggingCombat(on)
	private.setting = false
end

---Turns logging on or off for the setting and where the player is.
function LiveLog:Update()
	local want = Wanted.db.settings.liveLog and not IsInInstance()
	local logging = LoggingCombat()
	if not logging and Wanted.db.liveLogOn then
		-- Turned off by something else since: whatever turns it on next is theirs, not Wanted's
		Wanted.db.liveLogOn = nil
	end
	if want and not logging then
		private.Set(true)
		Wanted.db.liveLogOn = true
		Wanted:Log("LiveLog: combat logging on")
	elseif not want and logging and Wanted.db.liveLogOn then
		private.Set(false)
		Wanted.db.liveLogOn = nil
		Wanted:Log("LiveLog: combat logging off")
	end
end
