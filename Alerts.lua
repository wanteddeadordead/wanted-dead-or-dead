-- Wanted: alerts. A warning line at the top of the screen and a sound when an enemy shows up, louder for
-- Kill on Sight and bounty targets, and its own alarm for an enemy going into stealth nearby.

local ADDON_FOLDER, Wanted = ...
local Alerts = Wanted:NewModule("Alerts")
local Theme = Wanted.Theme
local C = Theme.C
local private = {
	frame = nil,
	lastSound = 0,
	muted = false, -- for the session, from the Nearby window
}
local SOUND_GAP = 1.5
local SHOW_SECONDS = 4
local FADE_SECONDS = 1

function Alerts:OnEnable()
	Wanted.Enemies:OnChange(private.OnEnemyEvent)
	Wanted.Enemies:OnChange(private.OnTargeting)
end

function private.Settings()
	return Wanted.db.settings.detect
end

function Alerts:IsMuted()
	return private.muted or not private.Settings().sound
end

function Alerts:SetMuted(muted)
	private.muted = muted
end



-- ============================================================================
-- Warning display
-- ============================================================================

function private.GetFrame()
	if private.frame then
		return private.frame
	end
	local frame = CreateFrame("Frame", nil, UIParent)
	frame:SetSize(800, 60)
	frame:SetPoint("TOP", 0, -140)
	frame:SetFrameStrata("HIGH")
	frame.title = frame:CreateFontString(nil, "OVERLAY")
	frame.title:SetFontObject(Theme:MakeFont("WantedFontAlertTitle", 22, nil, "OUTLINE"))
	frame.title:SetPoint("TOP")
	frame.sub = frame:CreateFontString(nil, "OVERLAY")
	frame.sub:SetFontObject(Theme:MakeFont("WantedFontAlertSub", 13, nil, "OUTLINE"))
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
	private.frame = frame
	return frame
end

---Shows a warning at the top of the screen.
---@param title string
---@param sub string?
---@param color table
function Alerts:Warn(title, sub, color)
	local frame = private.GetFrame()
	frame.title:SetText(title)
	frame.title:SetTextColor(color[1], color[2], color[3])
	frame.sub:SetText(sub or "")
	frame.sub:SetTextColor(0.9, 0.9, 0.9)
	frame.age = 0
	frame:SetAlpha(1)
	frame:Show()
end

---Plays an alert sound unless muted or one just played.
---@param kind string "enemy" | "important" | "stealth"
function Alerts:Sound(kind)
	if Alerts:IsMuted() or GetTime() - private.lastSound < SOUND_GAP then
		return
	end
	private.lastSound = GetTime()
	Alerts:PlayRaw(kind)
end

-- Wanted's own beeps (synthesised for the addon): one beep for an enemy, three quick higher ones for Kill
-- on Sight and bounty targets, a falling two-tone for stealth. The game's own sounds are the fallback.
-- Paths follow the folder the addon is installed in
local SOUND_DIR = "Interface\\AddOns\\"..ADDON_FOLDER.."\\Sounds\\"
local SOUND_FILES = {
	targeted = SOUND_DIR.."targeted.mp3",
	enemy = SOUND_DIR.."enemy.mp3",
	important = SOUND_DIR.."important.mp3",
	stealth = SOUND_DIR.."stealth.mp3",
}
local FALLBACK_KITS = { enemy = "MAP_PING", important = "RAID_WARNING", stealth = "UI_RAID_BOSS_WHISPER_WARNING", targeted = "ALARM_CLOCK_WARNING_3" }

---Plays an alert sound now, ignoring mute and spacing (for previews).
---@param kind string "enemy" | "important" | "stealth"
function Alerts:PlayRaw(kind)
	local file = SOUND_FILES[kind] or SOUND_FILES.enemy
	local willPlay = PlaySoundFile and PlaySoundFile(file, "Master")
	if not willPlay and SOUNDKIT then
		local kit = SOUNDKIT[FALLBACK_KITS[kind] or "MAP_PING"]
		if kit then
			PlaySound(kit, "Master")
		end
	end
end



-- ============================================================================
-- What deserves an alert
-- ============================================================================

local function Describe(d)
	local parts = {}
	if d.level then
		tinsert(parts, "level "..d.level)
	elseif d.skull then
		tinsert(parts, "level ??")
	end
	if d.class then
		tinsert(parts, Theme:ClassLabel(d.class))
	end
	if d.guild then
		tinsert(parts, "<"..d.guild..">")
	end
	return table.concat(parts, " ")
end

function private.OnEnemyEvent(event, entry)
	local settings = private.Settings()
	if not settings.enabled or settings.alerts == "none" or not entry or not entry.guid then
		return
	end
	local d = Wanted.Enemies:Describe(entry.guid)
	local name = Theme:ClassName(d.name, d.class)
	if event == "new" then
		if d.kos then
			Alerts:Warn("KILL ON SIGHT: "..d.name, Describe(d)..(d.reason and ("  -  "..d.reason) or ""), C.red)
			Alerts:Sound("important")
		elseif d.bounty > 0 then
			Alerts:Warn("WANTED: "..d.name, Describe(d).."  -  "..Wanted.Bounties:FormatMoney(d.bounty).." bounty", C.gold)
			Alerts:Sound("important")
		elseif settings.alerts == "all" then
			Alerts:Sound("enemy")
		end
	elseif event == "stealth" and settings.stealth then
		Alerts:Warn(format("%s: %s", strupper(entry.stealthKind or "Stealth"), d.name), Describe(d).." is nearby and hidden", C.amber)
		Alerts:Sound("stealth")
	elseif event == "shared" and settings.sharedAlerts then
		if d.kos or d.bounty > 0 then
			local where = entry.zone or "?"
			if entry.x then
				where = format("%s (%.0f, %.0f)", where, entry.x, entry.y)
			end
			Alerts:Warn(format("%s seen by %s", d.name, entry.by), where..(d.bounty > 0 and ("  -  "..Wanted.Bounties:FormatMoney(d.bounty).." bounty") or "  -  Kill on Sight"), d.kos and C.red or C.gold)
			Alerts:Sound("important")
		end
	elseif event == "killedby" then
		Alerts:Warn("Killed by "..(d.name or "?"), Describe(d)..format("  -  they've won %d, you've won %d", d.losses, d.wins), C.muted)
	end
end



-- ============================================================================
-- Targeted warning (a HUD message that stays while enemies target you)
-- ============================================================================

local HUD_FLASH_SECONDS = 3 -- how long it stays when "keep it up" is off
local HUD_LINES = 5

function private.GetHud()
	if private.hud then
		return private.hud
	end
	local hud = CreateFrame("Frame", "WantedTargetedHud", UIParent)
	hud:SetSize(520, 64)
	hud:SetFrameStrata("HIGH")
	hud:SetClampedToScreen(true)
	hud:SetMovable(true)
	local pos = private.Settings().hudPos
	if pos and pos.point then
		hud:SetPoint(pos.point, UIParent, pos.point, pos.x, pos.y)
	else
		hud:SetPoint("CENTER", UIParent, "CENTER", 0, 210)
	end
	hud.glow = hud:CreateTexture(nil, "BACKGROUND")
	hud.glow:SetPoint("TOPLEFT", -10, 6)
	hud.glow:SetPoint("BOTTOMRIGHT", 10, -6)
	-- Near black so the red title reads over any sky (a red wash vanished over the Barrens at dusk), with red
	-- edges to keep it looking like a warning
	hud.glow:SetColorTexture(0.07, 0.01, 0.01, 0.75)
	hud.edges = {}
	for _, side in ipairs({ "TOP", "BOTTOM" }) do
		local edge = hud:CreateTexture(nil, "BORDER")
		edge:SetHeight(2)
		edge:SetPoint(side.."LEFT", hud.glow, side.."LEFT")
		edge:SetPoint(side.."RIGHT", hud.glow, side.."RIGHT")
		edge:SetColorTexture(0.9, 0.15, 0.12, 0.9)
		tinsert(hud.edges, edge)
	end
	hud.title = hud:CreateFontString(nil, "OVERLAY")
	hud.title:SetFontObject(Theme:MakeFont("WantedFontHudTitle", 26, nil, "OUTLINE"))
	hud.title:SetPoint("TOP", 0, 0)
	hud.title:SetTextColor(1, 0.25, 0.2)
	-- One line per attacker: class icon and a description, most dangerous first
	local namesFont = Theme:MakeFont("WantedFontHudNames", 14, nil, "OUTLINE")
	hud.lines = {}
	for i = 1, HUD_LINES do
		local line = CreateFrame("Frame", nil, hud)
		line:SetSize(420, 20)
		line:SetPoint("TOP", hud.title, "BOTTOM", 0, -6 - (i - 1) * 20)
		line.icon = line:CreateTexture(nil, "ARTWORK")
		line.icon:SetSize(16, 16)
		line.text = line:CreateFontString(nil, "OVERLAY")
		line.text:SetFontObject(namesFont)
		line.text:SetPoint("CENTER", 10, 0)
		line.icon:SetPoint("RIGHT", line.text, "LEFT", -5, 0)
		line:Hide()
		hud.lines[i] = line
	end
	hud.names = hud.lines[1].text
	hud:Hide()
	-- A slow pulse so it reads as live, not as a leftover message
	hud:SetScript("OnUpdate", function(self, elapsed)
		self.t = (self.t or 0) + elapsed
		local pulse = 0.75 + 0.25 * math.sin(self.t * 5)
		self.title:SetAlpha(pulse)
		for _, edge in ipairs(self.edges) do
			edge:SetAlpha(pulse)
		end
		if self.hideAt and GetTime() >= self.hideAt and not self.moving then
			self:Hide()
		end
	end)
	-- Dragging only in "move" mode (Settings), so it never gets in the way of clicks in a fight
	hud:RegisterForDrag("LeftButton")
	hud:SetScript("OnDragStart", function(self)
		if self.moving then
			self:StartMoving()
		end
	end)
	hud:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, _, x, y = self:GetPoint(1)
		private.Settings().hudPos = { point = point, x = x, y = y }
	end)
	private.hud = hud
	return hud
end

function private.Describe(d)
	local parts = { Theme:ClassName(d.name, d.class) }
	local extra = {}
	if d.level then
		tinsert(extra, tostring(d.level))
	end
	if d.class then
		tinsert(extra, Theme:ClassLabel(d.class))
	end
	if #extra > 0 then
		tinsert(parts, Theme:Colorize("("..table.concat(extra, " ")..")", { 0.85, 0.85, 0.85 }))
	end
	if d.kos then
		tinsert(parts, Theme:Colorize("KoS", C.red))
	end
	if d.bounty > 0 then
		tinsert(parts, Theme:Colorize(Wanted.Bounties:FormatMoney(d.bounty), C.gold))
	end
	return table.concat(parts, " ")
end

---Redraws the targeted warning from who is targeting us now.
function Alerts:UpdateTargetedHud()
	local settings = private.Settings()
	local hud = private.GetHud()
	if hud.moving then
		return
	end
	local targeters = settings.enabled and settings.targetWarn and Wanted.Enemies:GetTargeters() or {}
	if #targeters == 0 then
		if settings.targetHold then
			hud:Hide()
		end
		return
	end
	hud.title:SetText(#targeters == 1 and "TARGETED" or format("TARGETED BY %d", #targeters))
	local shown = #targeters > HUD_LINES and HUD_LINES - 1 or #targeters
	if not settings.targetNames then
		shown = -1 -- title only
	end
	for i, line in ipairs(hud.lines) do
		if i <= shown then
			Theme:SetClassIcon(line.icon, targeters[i].class)
			line.text:SetText(private.Describe(targeters[i]))
			line:Show()
		elseif shown >= 0 and i == shown + 1 and #targeters > shown then
			line.icon:Hide()
			line.text:SetText(format("and %d more", #targeters - shown))
			line:Show()
		else
			line:Hide()
		end
	end
	hud.hideAt = not settings.targetHold and (GetTime() + HUD_FLASH_SECONDS) or nil
	hud:Show()
end

function private.OnTargeting(event, entry)
	local settings = private.Settings()
	if event == "newTargeter" and settings.enabled and settings.targetWarn and settings.targetSound and not Alerts:IsMuted() then
		-- Its own sound, not held back by the spacing of the other alerts
		Alerts:PlayRaw("targeted")
	end
	if event == "newTargeter" or event == "targeted" then
		Alerts:UpdateTargetedHud()
	end
end

---Shows the warning with a sample so it can be dragged into place, or puts it back.
---@param moving boolean
function Alerts:SetHudMoving(moving)
	local hud = private.GetHud()
	hud.moving = moving
	hud:EnableMouse(moving)
	if moving then
		hud.title:SetText("TARGETED BY 2")
		hud.lines[1].icon:Hide()
		hud.lines[1].text:SetText("Drag me where you want the warning")
		hud.lines[1]:Show()
		hud.lines[2].icon:Hide()
		hud.lines[2].text:SetText("then press Done in Settings")
		hud.lines[2]:Show()
		for i = 3, HUD_LINES do
			hud.lines[i]:Hide()
		end
		hud.hideAt = nil
		hud:Show()
	else
		hud:Hide()
		Alerts:UpdateTargetedHud()
	end
end

function Alerts:IsHudMoving()
	return private.hud and private.hud.moving or false
end
