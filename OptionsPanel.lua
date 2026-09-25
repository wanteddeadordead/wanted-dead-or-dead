-- Wanted: an entry in the game's Options > AddOns list. Everything lives in Wanted's own window, so the page
-- is the name, the version, how to open it, and buttons that do.

local _, Wanted = ...
local OptionsPanel = Wanted:NewModule("OptionsPanel")
local Theme = Wanted.Theme
local C = Theme.C

---Closes the game's Options window (so Wanted's window isn't hidden behind it), then runs the action.
local function CloseOptionsThen(action)
	-- The Options window can't be closed by an addon in combat; Wanted opens on top of it then
	if SettingsPanel and SettingsPanel:IsShown() and not InCombatLockdown() then
		SettingsPanel:ExitWithCommit(true)
	end
	action()
end

function OptionsPanel:OnLoad()
	if not Settings or not Settings.RegisterCanvasLayoutCategory then
		return
	end
	local panel = CreateFrame("Frame")
	panel:Hide()

	local icon = panel:CreateTexture(nil, "ARTWORK")
	icon:SetSize(72, 72)
	icon:SetPoint("CENTER", 0, 150)
	icon:SetTexture("Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\icon")

	local title = panel:CreateFontString(nil, "OVERLAY")
	title:SetFontObject(Theme:MakeFont("WantedFontOptionsTitle", 40, nil, ""))
	title:SetPoint("TOP", icon, "BOTTOM", 0, -16)
	title:SetText(Theme:Colorize("WANTED: ", C.text)..Theme:Colorize("DEAD OR... ", C.muted)..Theme:Colorize("DEAD", C.red))

	local version = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	version:SetPoint("TOP", title, "BOTTOM", 0, -14)
	version:SetText("Version: "..tostring(Wanted.VERSION)..(Wanted.BETA and " (beta)" or ""))

	local how = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	how:SetPoint("TOP", version, "BOTTOM", 0, -8)
	how:SetText("Open it with /wanted or the minimap button")

	local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	open:SetSize(420, 56)
	open:SetPoint("TOP", how, "BOTTOM", 0, -24)
	open:SetText("Open Wanted")
	open:SetNormalFontObject("GameFontNormalHuge")
	open:SetHighlightFontObject("GameFontHighlightHuge")
	open:SetScript("OnClick", function()
		CloseOptionsThen(function() Wanted.UI:Show() end)
	end)

	local nearby = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	nearby:SetSize(200, 30)
	nearby:SetPoint("TOP", open, "BOTTOM", 0, -12)
	nearby:SetText("Nearby window")
	nearby:SetScript("OnClick", function()
		CloseOptionsThen(function() Wanted.NearbyWindow:SetShown(true) end)
	end)

	local category = Settings.RegisterCanvasLayoutCategory(panel, "Wanted: Dead or... Dead")
	Settings.RegisterAddOnCategory(category)
	OptionsPanel.category = category
	OptionsPanel.openButton, OptionsPanel.nearbyButton = open, nearby
end
