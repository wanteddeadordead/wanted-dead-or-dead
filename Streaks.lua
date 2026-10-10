-- Wanted: kill streaks. The player's own kills (the kill records Recorder makes) count up: kills within 30 seconds
-- of each other are a multi-kill (Double kill, Triple kill ...), and kills since the player's last death are a
-- streak (Killing spree at 3, Unstoppable at 5 ...). Each one gets a callout in the middle of the screen and a
-- sound, and, only when the player turns it on, a line to their party or guild. Never to a public channel.

local _, Wanted = ...
local Streaks = Wanted:NewModule("Streaks")
local Theme = Wanted.Theme
local C = Theme.C
local private = {
	frame = CreateFrame("Frame"),
	callout = nil,
	chain = 0, -- kills in the current multi-kill
	streak = 0, -- kills since our last death
	lastKill = nil, -- GetTime() of the last kill counted
	recentVictims = {}, -- victim name -> GetTime() it was counted (the kill event and honor message can both record it)
	lastAnnounce = nil, -- GetTime() of the last line sent to party or guild
}
-- A kill this soon after the previous one continues the multi-kill
Streaks.CHAIN_SECONDS = 30
-- At most one line to party or guild this often
Streaks.ANNOUNCE_GAP = 10
-- The same victim counts once within this long
local SAME_VICTIM_SECONDS = 10
local SHOW_SECONDS = 2
local FADE_SECONDS = 0.6
local MULTI_LABELS = { [2] = "Double kill", [3] = "Triple kill", [4] = "Quad kill" }
-- The callout, and how the party or guild line puts it
local STREAK_LABELS = {
	[3] = { "Killing spree", "is on a killing spree" },
	[5] = { "Unstoppable", "is unstoppable" },
	[8] = { "Legendary", "is legendary" },
}
-- Only these; the setting's other value is "none"
local ANNOUNCE_CHAT = { party = "PARTY", guild = "GUILD" }

function Streaks:OnEnable()
	Wanted.Store:OnRecord("kill", function(record, isOwn)
		if isOwn then
			Streaks:OnKill(record.data.victimName or record.data.victim)
		end
	end)
	private.frame:RegisterEvent("PLAYER_DEAD")
	private.frame:SetScript("OnEvent", function()
		-- Losing a duel to the death doesn't end a world PvP streak
		if not (Wanted.Duels and Wanted.Duels:Involves(UnitGUID("player"))) then
			Streaks:OnDeath()
		end
	end)
end

function private.Settings()
	return Wanted.db.settings.streaks
end



-- ============================================================================
-- Counting
-- ============================================================================

---The multi-kill name for this many kills in a row, or nil below two.
---@param chain number
---@return string?
function Streaks:MultiLabel(chain)
	if chain >= 5 then
		return "Rampage"
	end
	return MULTI_LABELS[chain]
end

---The streak name when a streak reaches this many kills, and how an announcement says it, or nil when this count
---isn't a milestone.
---@param streak number
---@return string? label, string? phrase
function Streaks:StreakLabel(streak)
	if streak >= 10 then
		if streak % 5 == 0 then
			return format("Legendary (%d)", streak), "is legendary"
		end
		return nil
	end
	local entry = STREAK_LABELS[streak]
	if entry then
		return entry[1], entry[2]
	end
end

---Counts one of the player's own kills and calls it out.
---@param victim string? the victim's name, so a kill recorded twice counts once
function Streaks:OnKill(victim)
	local now = GetTime()
	if victim then
		if private.recentVictims[victim] and now - private.recentVictims[victim] < SAME_VICTIM_SECONDS then
			return
		end
		-- Only the last few seconds' victims are needed
		for name, t in pairs(private.recentVictims) do
			if now - t >= SAME_VICTIM_SECONDS then
				private.recentVictims[name] = nil
			end
		end
		private.recentVictims[victim] = now
	end
	if private.lastKill and now - private.lastKill <= Streaks.CHAIN_SECONDS then
		private.chain = private.chain + 1
	else
		private.chain = 1
	end
	private.lastKill = now
	private.streak = private.streak + 1
	local multi = Streaks:MultiLabel(private.chain)
	local streak, phrase = Streaks:StreakLabel(private.streak)
	if not multi and not streak then
		return
	end
	local settings = private.Settings()
	if settings.callout then
		if multi then
			private.Show(multi, streak and format("%s: %d kills", streak, private.streak) or format("%d kills in a row", private.chain), C.gold)
		else
			private.Show(streak, format("%d kills without dying", private.streak), C.red)
		end
	end
	if settings.sound and not Wanted.Alerts:IsMuted() then
		Wanted.Alerts:PlayRaw("important")
	end
	local name = UnitName("player")
	if streak then
		Streaks:Announce(format("Wanted: %s %s (%d kills)", name, phrase, private.streak))
	else
		Streaks:Announce(format("Wanted: %s got a %s", name, strlower(multi)))
	end
end

---The player died: the streak starts again.
function Streaks:OnDeath()
	private.streak = 0
	private.chain = 0
	private.lastKill = nil
end

---The current multi-kill and streak counts.
---@return number chain, number streak
function Streaks:GetCounts()
	return private.chain, private.streak
end



-- ============================================================================
-- Callout and announcement
-- ============================================================================

function private.GetCallout()
	if private.callout then
		return private.callout
	end
	local frame = CreateFrame("Frame", nil, UIParent)
	frame:SetSize(600, 70)
	frame:SetPoint("CENTER", 0, 100)
	frame:SetFrameStrata("HIGH")
	frame.title = frame:CreateFontString(nil, "OVERLAY")
	frame.title:SetFontObject(Theme:MakeFont("WantedFontStreakTitle", 34, nil, "OUTLINE"))
	frame.title:SetPoint("TOP")
	frame.sub = frame:CreateFontString(nil, "OVERLAY")
	frame.sub:SetFontObject(Theme:MakeFont("WantedFontStreakSub", 15, nil, "OUTLINE"))
	frame.sub:SetPoint("TOP", frame.title, "BOTTOM", 0, -4)
	frame:Hide()
	frame:SetScript("OnUpdate", function(self, elapsed)
		self.age = self.age + elapsed
		if self.age > SHOW_SECONDS + FADE_SECONDS then
			self:Hide()
		elseif self.age > SHOW_SECONDS then
			self:SetAlpha(1 - (self.age - SHOW_SECONDS) / FADE_SECONDS)
		end
	end)
	private.callout = frame
	return frame
end

---Shows a callout in the middle of the screen for a couple of seconds.
function private.Show(title, sub, color)
	local frame = private.GetCallout()
	frame.title:SetText(strupper(title))
	frame.title:SetTextColor(color[1], color[2], color[3])
	frame.sub:SetText(sub or "")
	frame.sub:SetTextColor(0.9, 0.9, 0.9)
	frame.age = 0
	frame:SetAlpha(1)
	frame:Show()
end

---Sends a line to party or guild when the player chose one and is in it, at most once every ANNOUNCE_GAP seconds.
---@param text string plain text
---@return boolean sent
function Streaks:Announce(text)
	local chatType = ANNOUNCE_CHAT[private.Settings().announce]
	if not chatType then
		return false
	end
	if (chatType == "PARTY" and not IsInGroup()) or (chatType == "GUILD" and not IsInGuild()) then
		return false
	end
	local now = GetTime()
	if private.lastAnnounce and now - private.lastAnnounce < Streaks.ANNOUNCE_GAP then
		return false
	end
	private.lastAnnounce = now
	C_ChatInfo.SendChatMessage(text, chatType)
	return true
end

---Shows a sample callout and plays its sound (the Settings preview).
function Streaks:Preview()
	private.Show("Triple kill", "Killing spree: 3 kills", C.gold)
	Wanted.Alerts:PlayRaw("important")
end
