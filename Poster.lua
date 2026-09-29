-- Wanted: your wanted poster. A painted poster over a dark screen with your own character in the portrait
-- (a live model of you, tinted like an old print), your name, and the price on your head: every bounty the
-- other side has posted on you, paid or not, as it reached this side (see Bridge).
-- Upload your wanted poster shows your model alone on a plain backdrop and has the game take a screenshot (an
-- addon can't save a picture any other way), noting where the model was on screen (WantedDB.posterShots). The
-- desktop app cuts the model out of that screenshot and uploads it to wanteddeadordead.com, which draws the
-- poster around it: the poster there can change without anyone uploading again.

local _, Wanted = ...
local Poster = Wanted:NewModule("Poster")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local private = {
	frame = nil,
	shooting = false,
	shot = nil, -- the poster shot being taken: { l, top, r, b } where the model is, as fractions of the screen
	format = nil, -- the screenshot format to put back afterwards
	customAmount = nil, -- copper; a made-up reward to show instead, just for fun (never saved or shared)
}
local TEXTURE = "Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\poster"
-- Rye (SIL Open Font License, see THIRD_PARTY_NOTICES.md): western wood type, like the painted WANTED
local POSTER_FONT = "Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\Rye.ttf"
-- The painting fills the top of a 512x1024 texture; its own shape, and where its empty spaces are, as
-- fractions of the painting (left, top, right, bottom)
local PAINTING_HEIGHT = 763 / 1024
local PAINTING_ASPECT = 512 / 763
local PORTRAIT = { 0.19, 0.245, 0.815, 0.605 }
local NAME_BAND = { 0.17, 0.645, 0.83, 0.705 }
local REWARD_BAND = { 0.17, 0.755, 0.83, 0.82 }
local INK = { 0.17, 0.1, 0.06 }
local SEPIA = { 1, 0.86, 0.66 } -- multiplied over the portrait so the live model looks printed
local MAX_CUSTOM_GOLD = 1000000
local STUDIO_BACKDROP = { 0.11, 0.09, 0.07 } -- plain and dark behind the model, like the poster's paper in shadow
local MAX_POSTER_SHOTS = 5 -- the newest kept for the app



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Poster:OnEnable()
	local events = CreateFrame("Frame")
	events:RegisterEvent("SCREENSHOT_SUCCEEDED")
	events:RegisterEvent("SCREENSHOT_FAILED")
	events:SetScript("OnEvent", function(_, event)
		private.OnScreenshot(event == "SCREENSHOT_SUCCEEDED")
	end)
end

---Shows the poster.
function Poster:Show()
	local frame = private.GetFrame()
	private.Fill(frame)
	frame:Show()
end

function Poster:IsShown()
	return private.frame and private.frame:IsShown() or false
end

function Poster:Hide()
	if private.frame then
		private.frame:Hide()
	end
end



-- ============================================================================
-- The poster
-- ============================================================================

local function PosterFont(name, size)
	local font = CreateFont(name)
	font:SetFont(POSTER_FONT, size, "")
	return font
end

local function Commas(number)
	local text, count = tostring(number), 1
	while count > 0 do
		text, count = gsub(text, "^(%d+)(%d%d%d)", "%1,%2")
	end
	return text
end

---A reward the way a poster prints it: "5,000 GOLD", "4 GOLD 50 SILVER", "75 SILVER".
function private.FormatReward(copper)
	local gold, silver = floor(copper / 10000), floor(copper % 10000 / 100)
	if gold == 0 then
		return (silver > 0 and silver or 1).." SILVER"
	end
	return Commas(gold).." GOLD"..(silver > 0 and (" "..silver.." SILVER") or "")
end

---Sets text in a band, stepping down to the smaller font and then shrinking it if it's still too wide (long
---names: Forever's two-part names run to about 25 letters; "No price on your head yet").
local function FitText(fontString, text, font, smallFont, width)
	fontString:SetFontObject(font)
	if fontString.SetTextScale then
		fontString:SetTextScale(1)
	end
	fontString:SetText(text)
	if fontString:GetStringWidth() <= width then
		return
	end
	fontString:SetFontObject(smallFont)
	local actual = fontString:GetStringWidth()
	if actual > width and fontString.SetTextScale then
		fontString:SetTextScale(width / actual)
	end
end

---Places a region inside the painting by fractions of it.
local function Place(region, painting, box)
	region:ClearAllPoints()
	local width, height = painting:GetWidth(), painting:GetHeight()
	region:SetPoint("TOPLEFT", painting, "TOPLEFT", box[1] * width, -box[2] * height)
	region:SetPoint("BOTTOMRIGHT", painting, "TOPLEFT", box[3] * width, -box[4] * height)
end

function private.GetFrame()
	if private.frame then
		return private.frame
	end
	-- Everything behind goes dark, so the screenshot is the poster
	local frame = CreateFrame("Frame", "WantedPosterFrame", UIParent)
	frame:SetFrameStrata("FULLSCREEN_DIALOG")
	frame:SetAllPoints(UIParent)
	frame:EnableMouse(true)
	frame:Hide()
	tinsert(UISpecialFrames, "WantedPosterFrame")
	local backdrop = frame:CreateTexture(nil, "BACKGROUND")
	backdrop:SetAllPoints()
	backdrop:SetColorTexture(0.03, 0.02, 0.02, 0.92)

	local height = min(UIParent:GetHeight() * 0.84, 900)
	local painting = CreateFrame("Frame", nil, frame)
	painting:SetSize(height * PAINTING_ASPECT, height)
	painting:SetPoint("CENTER", 0, 24)
	frame.painting = painting
	local art = painting:CreateTexture(nil, "BACKGROUND")
	art:SetAllPoints()
	art:SetTexture(TEXTURE)
	art:SetTexCoord(0, 1, 0, PAINTING_HEIGHT)

	-- The player, live, head and shoulders
	local model = CreateFrame("PlayerModel", nil, painting)
	Place(model, painting, PORTRAIT)
	frame.model = model
	local tint = CreateFrame("Frame", nil, painting)
	tint:SetFrameLevel(model:GetFrameLevel() + 1)
	Place(tint, painting, PORTRAIT)
	local sepia = tint:CreateTexture(nil, "OVERLAY")
	sepia:SetAllPoints()
	sepia:SetColorTexture(SEPIA[1], SEPIA[2], SEPIA[3], 1)
	sepia:SetBlendMode("MOD")

	-- Name and who they are
	local text = CreateFrame("Frame", nil, painting)
	text:SetFrameLevel(tint:GetFrameLevel() + 1)
	text:SetAllPoints()
	local nameBand = CreateFrame("Frame", nil, text)
	Place(nameBand, painting, NAME_BAND)
	frame.name = nameBand:CreateFontString(nil, "OVERLAY")
	frame.nameFont = PosterFont("WantedFontPosterName", floor(height * 0.034))
	frame.nameFontSmall = PosterFont("WantedFontPosterNameSmall", floor(height * 0.024))
	frame.nameWidth = (NAME_BAND[3] - NAME_BAND[1]) * painting:GetWidth() - 16
	frame.name:SetFontObject(frame.nameFont)
	frame.name:SetPoint("TOP", 0, -height * 0.006)
	frame.name:SetTextColor(INK[1], INK[2], INK[3])
	frame.who = nameBand:CreateFontString(nil, "OVERLAY")
	frame.who:SetFontObject(PosterFont("WantedFontPosterWho", floor(height * 0.017)))
	frame.who:SetPoint("BOTTOM", 0, height * 0.006)
	frame.who:SetTextColor(INK[1], INK[2], INK[3], 0.85)

	-- The price on their head
	local rewardBand = CreateFrame("Frame", nil, text)
	Place(rewardBand, painting, REWARD_BAND)
	frame.reward = rewardBand:CreateFontString(nil, "OVERLAY")
	frame.rewardFont = PosterFont("WantedFontPosterReward", floor(height * 0.036))
	frame.rewardFontSmall = PosterFont("WantedFontPosterRewardSmall", floor(height * 0.024))
	frame.rewardWidth = (REWARD_BAND[3] - REWARD_BAND[1]) * painting:GetWidth() - 16
	frame.reward:SetFontObject(frame.rewardFont)
	frame.reward:SetPoint("CENTER", 0, 0)
	frame.reward:SetTextColor(INK[1], INK[2], INK[3])
	frame.rewardNote = text:CreateFontString(nil, "OVERLAY")
	frame.rewardNote:SetFontObject(PosterFont("WantedFontPosterNote", floor(height * 0.016)))
	frame.rewardNote:SetPoint("TOP", rewardBand, "BOTTOM", 0, -height * 0.004)
	frame.rewardNote:SetTextColor(INK[1], INK[2], INK[3], 0.85)

	-- Under the poster: where it's from, then the buttons (hidden for the screenshot)
	frame.credit = Theme:Text(frame, "small", "Wanted: Dead or... Dead  -  a World PvP addon for WoW Forever", { 0.85, 0.78, 0.66 })
	frame.credit:SetPoint("TOP", painting, "BOTTOM", 0, -10)
	local buttons = CreateFrame("Frame", nil, frame)
	buttons:SetSize(470, 30)
	buttons:SetPoint("TOP", frame.credit, "BOTTOM", 0, -12)
	frame.buttons = buttons
	-- Once a picture is taken, the same button sends it: the app only sees it after the game saves (a /reload)
	local shoot = W:Button(buttons, "Upload your wanted poster", "primary", 200, 28, function()
		if frame.waitingToSend then
			ReloadUI()
		else
			private.TakeScreenshot()
		end
	end)
	frame.shoot = shoot
	shoot:SetPoint("LEFT")
	W:AttachTooltip(shoot, "Upload your wanted poster", "Photographs your character for your poster on wanteddeadordead.com. The Wanted app uploads it after your next /reload or logout.")
	frame.amountButton = W:Button(buttons, "Set amount", "secondary", 130, 28, function()
		private.ToggleCustomAmount()
	end)
	frame.amountButton:SetPoint("LEFT", shoot, "RIGHT", 10, 0)
	W:AttachTooltip(frame.amountButton, "Set amount", "Just for fun: show any reward you like on your poster. Nothing is saved or shared.")
	local close = W:Button(buttons, "Close", "secondary", 110, 28, function()
		frame:Hide()
	end)
	close:SetPoint("RIGHT")

	-- The studio: the model alone, 4:3 like the poster's window, on a plain backdrop, for the upload
	local studio = CreateFrame("Frame", nil, frame)
	local studioHeight = UIParent:GetHeight() * 0.6
	studio:SetSize(studioHeight * 4 / 3, studioHeight)
	studio:SetPoint("CENTER")
	studio:Hide()
	local studioBackdrop = studio:CreateTexture(nil, "BACKGROUND")
	studioBackdrop:SetAllPoints()
	studioBackdrop:SetColorTexture(STUDIO_BACKDROP[1], STUDIO_BACKDROP[2], STUDIO_BACKDROP[3], 1)
	frame.studio = studio
	frame.studioModel = CreateFrame("PlayerModel", nil, studio)
	frame.studioModel:SetAllPoints()
	private.frame = frame
	return frame
end

---Fills the poster with the player and the current price on their head.
function private.Fill(frame)
	frame.model:SetUnit("player")
	frame.model:SetPortraitZoom(0.65)
	frame.model:SetCamDistanceScale(1)
	frame.model:SetRotation(0)
	local first, last = UnitName("player")
	FitText(frame.name, strupper(last and last ~= "" and (first.." "..last) or first or "?"), frame.nameFont, frame.nameFontSmall, frame.nameWidth)
	local _, class = UnitClass("player")
	local who = { "Level "..(UnitLevel("player") or "?") }
	if class then
		tinsert(who, Theme:ClassLabel(class))
	end
	local guild = GetGuildInfo("player")
	if guild then
		tinsert(who, "<"..guild..">")
	end
	frame.who:SetText(table.concat(who, "  "))
	frame.amountButton:SetText(private.customAmount and "Real amount" or "Set amount")
	local total, count, posters = Wanted.Bridge:GetPriceOnMe()
	if private.customAmount then
		FitText(frame.reward, private.FormatReward(private.customAmount), frame.rewardFont, frame.rewardFontSmall, frame.rewardWidth)
		frame.rewardNote:SetText("(allegedly)")
	elseif total > 0 then
		FitText(frame.reward, private.FormatReward(total), frame.rewardFont, frame.rewardFontSmall, frame.rewardWidth)
		frame.rewardNote:SetText(format("%d bount%s from %d player%s", count, count == 1 and "y" or "ies", posters, posters == 1 and "" or "s"))
	else
		FitText(frame.reward, "No price on your head yet", frame.rewardFont, frame.rewardFontSmall, frame.rewardWidth)
		frame.rewardNote:SetText("")
	end
end



---Gold typed by the player ("5000", "1,250", "75g"), in copper, or nil.
function private.ParseGold(text)
	local gold = tonumber((gsub(gsub(text or "", "[,%s]", ""), "[gG]$", "")))
	if not gold or gold <= 0 or gold > MAX_CUSTOM_GOLD then
		return nil
	end
	return floor(gold * 10000 + 0.5)
end

---Asks for a made-up reward, or goes back to the real one.
function private.ToggleCustomAmount()
	if private.customAmount then
		private.customAmount = nil
		private.Fill(private.frame)
		return
	end
	W:Dialog({
		title = "Set the amount",
		text = "Just for fun: the reward to show on your poster, in gold. It isn't saved or shared, and Real amount puts the true one back.",
		input = { placeholder = "Gold, e.g. 5000" },
		confirmLabel = "Show it",
		validate = function(value)
			if not private.ParseGold(value) then
				return format("Enter an amount of gold from 1 to %s.", BreakUpLargeNumbers and BreakUpLargeNumbers(MAX_CUSTOM_GOLD) or MAX_CUSTOM_GOLD)
			end
		end,
		onConfirm = function(value)
			private.customAmount = private.ParseGold(value)
			private.Fill(private.frame)
		end,
	})
end



-- ============================================================================
-- Screenshot
-- ============================================================================

function private.TakeScreenshot()
	if private.shooting or not Screenshot then
		return
	end
	if not Wanted:AppVersion() then
		Wanted:Print("Uploading your poster needs the Wanted app on this computer: it puts the picture on wanteddeadordead.com. Get it at wanteddeadordead.com/app.")
		return
	end
	if InCombatLockdown and InCombatLockdown() then
		Wanted:Print("Not during a fight: try again when it's over.")
		return
	end
	private.shooting = true
	local frame = private.frame
	frame.buttons:Hide()
	frame.credit:Hide()
	frame.painting:Hide()
	frame.studioModel:SetUnit("player")
	frame.studioModel:SetPortraitZoom(0.65)
	frame.studioModel:SetCamDistanceScale(1)
	frame.studioModel:SetRotation(0)
	frame.studio:Show()
	-- PNG, whatever the player's setting: the app reads it, and it keeps the model sharp
	if GetCVar and SetCVar then
		private.format = GetCVar("screenshotFormat")
		if private.format ~= "png" then
			SetCVar("screenshotFormat", "png")
		end
	end
	-- Let the model load and the frame redraw first
	C_Timer.After(0.5, function()
		if not private.shooting then
			return
		end
		private.shot = private.ModelRect(frame.studioModel)
		Screenshot()
	end)
	-- Back to normal even if the game never answers
	C_Timer.After(4, function()
		if private.shooting then
			private.OnScreenshot(false)
		end
	end)
end

---Where a frame is on screen, as fractions of the screen from its top left, or nil if the game won't say.
function private.ModelRect(region)
	local scale, screenScale = region:GetEffectiveScale(), UIParent:GetEffectiveScale()
	local left, right, top, bottom = region:GetLeft(), region:GetRight(), region:GetTop(), region:GetBottom()
	local width, height = UIParent:GetWidth(), UIParent:GetHeight()
	for _, v in ipairs({ scale, screenScale, left, right, top, bottom, width, height }) do
		if type(v) ~= "number" then
			return nil
		end
	end
	local sw, sh = width * screenScale, height * screenScale
	if sw <= 0 or sh <= 0 then
		return nil
	end
	return { l = left * scale / sw, r = right * scale / sw, top = 1 - top * scale / sh, b = 1 - bottom * scale / sh }
end

function private.OnScreenshot(succeeded)
	if not private.shooting then
		return
	end
	private.shooting = false
	if private.format and private.format ~= "png" and SetCVar then
		SetCVar("screenshotFormat", private.format)
	end
	private.format = nil
	local frame = private.frame
	if frame then
		frame.studio:Hide()
		frame.painting:Show()
		frame.credit:Show()
		frame.buttons:Show()
	end
	local shot = private.shot
	private.shot = nil
	if not succeeded or not shot then
		Wanted:Print("The game couldn't take the picture. Try again in a moment.")
		return
	end
	local shots = Wanted.db.posterShots
	tinsert(shots, { t = GetServerTime(), who = Wanted.Store:GetOrigin(), l = shot.l, top = shot.top, r = shot.r, b = shot.b })
	while #shots > MAX_POSTER_SHOTS do
		tremove(shots, 1)
	end
	if frame then
		frame.waitingToSend = true
		frame.shoot:SetText("Send it now (/reload)")
	end
	Wanted:Print("Picture taken. Type /reload now to send it (or it goes when you log out). The Wanted app puts it on wanteddeadordead.com.")
end

Wanted:RegisterCommand("poster", "Your wanted poster, with the price on your head, to screenshot and share: /wanted poster", function()
	Poster:Show()
end)
