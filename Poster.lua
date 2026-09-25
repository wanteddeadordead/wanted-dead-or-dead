-- Wanted: your wanted poster. A painted poster over a dark screen with your own character in the portrait
-- (a live model of you, tinted like an old print), your name, and the price on your head: every bounty the
-- other side has posted on you, paid or not, as it reached this side (see Bridge). Take screenshot hides the
-- buttons and has the game save the picture in its Screenshots folder, ready to share. An addon can't save
-- a picture any other way.

local _, Wanted = ...
local Poster = Wanted:NewModule("Poster")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local private = {
	frame = nil,
	shooting = false,
}
local TEXTURE = "Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\poster"
-- The painting fills the top of a 512x1024 texture; its own shape, and where its empty spaces are, as
-- fractions of the painting (left, top, right, bottom)
local PAINTING_HEIGHT = 763 / 1024
local PAINTING_ASPECT = 512 / 763
local PORTRAIT = { 0.19, 0.245, 0.815, 0.605 }
local NAME_BAND = { 0.17, 0.645, 0.83, 0.705 }
local REWARD_BAND = { 0.17, 0.755, 0.83, 0.82 }
local INK = { 0.17, 0.1, 0.06 }
local SEPIA = { 1, 0.86, 0.66 } -- multiplied over the portrait so the live model looks printed



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
	frame.name:SetFontObject(Theme:MakeFont("WantedFontPosterName", floor(height * 0.036), nil, nil))
	frame.name:SetPoint("TOP", 0, -height * 0.006)
	frame.name:SetTextColor(INK[1], INK[2], INK[3])
	frame.who = nameBand:CreateFontString(nil, "OVERLAY")
	frame.who:SetFontObject(Theme:MakeFont("WantedFontPosterWho", floor(height * 0.017), nil, nil))
	frame.who:SetPoint("BOTTOM", 0, height * 0.006)
	frame.who:SetTextColor(INK[1], INK[2], INK[3], 0.85)

	-- The price on their head
	local rewardBand = CreateFrame("Frame", nil, text)
	Place(rewardBand, painting, REWARD_BAND)
	frame.reward = rewardBand:CreateFontString(nil, "OVERLAY")
	frame.reward:SetFontObject(Theme:MakeFont("WantedFontPosterReward", floor(height * 0.036), nil, nil))
	frame.reward:SetPoint("CENTER", 0, 0)
	frame.reward:SetTextColor(INK[1], INK[2], INK[3])
	frame.rewardNote = text:CreateFontString(nil, "OVERLAY")
	frame.rewardNote:SetFontObject(Theme:MakeFont("WantedFontPosterNote", floor(height * 0.015), nil, nil))
	frame.rewardNote:SetPoint("TOP", rewardBand, "BOTTOM", 0, -height * 0.004)
	frame.rewardNote:SetTextColor(INK[1], INK[2], INK[3], 0.85)

	-- Under the poster: where it's from, then the buttons (hidden for the screenshot)
	frame.credit = Theme:Text(frame, "small", "Wanted: Dead or... Dead  -  a World PvP addon for WoW Forever", { 0.85, 0.78, 0.66 })
	frame.credit:SetPoint("TOP", painting, "BOTTOM", 0, -10)
	local buttons = CreateFrame("Frame", nil, frame)
	buttons:SetSize(300, 30)
	buttons:SetPoint("TOP", frame.credit, "BOTTOM", 0, -12)
	frame.buttons = buttons
	local shoot = W:Button(buttons, "Take screenshot", "primary", 150, 28, function()
		private.TakeScreenshot()
	end)
	shoot:SetPoint("LEFT")
	local close = W:Button(buttons, "Close", "secondary", 130, 28, function()
		frame:Hide()
	end)
	close:SetPoint("RIGHT")
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
	frame.name:SetText(strupper(last and last ~= "" and (first.." "..last) or first or "?"))
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
	local total, count, posters = Wanted.Bridge:GetPriceOnMe()
	if total > 0 then
		frame.reward:SetText(Wanted.Bounties:FormatMoney(total))
		frame.rewardNote:SetText(format("%d bount%s from %d player%s", count, count == 1 and "y" or "ies", posters, posters == 1 and "" or "s"))
	else
		frame.reward:SetText("No price on your head yet")
		frame.rewardNote:SetText("")
	end
end



-- ============================================================================
-- Screenshot
-- ============================================================================

function private.TakeScreenshot()
	if private.shooting or not Screenshot then
		return
	end
	private.shooting = true
	private.frame.buttons:Hide()
	-- Let the frame redraw without the buttons first
	C_Timer.After(0.1, function()
		Screenshot()
	end)
	-- Back to normal even if the game never answers
	C_Timer.After(3, function()
		if private.shooting then
			private.OnScreenshot(false)
		end
	end)
end

function private.OnScreenshot(succeeded)
	if not private.shooting then
		return
	end
	private.shooting = false
	if private.frame then
		private.frame.buttons:Show()
	end
	if succeeded then
		Wanted:Print("Your wanted poster is saved in your Screenshots folder (World of Warcraft\\_classic_beta_\\Screenshots). Share it anywhere.")
	else
		Wanted:Print("The game couldn't save the screenshot. Try again, or use your own screenshot key.")
	end
end

Wanted:RegisterCommand("poster", "Your wanted poster, with the price on your head, to screenshot and share: /wanted poster", function()
	Poster:Show()
end)
