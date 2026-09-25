-- Wanted: settings, in three tabs: Alerts (detection and sounds), Nearby window (what each row shows),
-- and Sharing and display (network, map, minimap, class icons).

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local private = { toggles = {}, panels = {}, view = "alerts", iconButtons = {} }

local function Detect()
	return Wanted.db.settings.detect
end

local function NearbyShow()
	return Wanted.db.settings.nearby
end

local function RefreshNearby()
	if Wanted.NearbyWindow then
		Wanted.NearbyWindow:ForceLayout()
	end
end

---A toggle bound to a settings table key.
function private.Toggle(parent, getTable, key, label, tip, x, y, onChange)
	local toggle = W:Toggle(parent, label, function(checked)
		getTable()[key] = checked
		if onChange then
			onChange(checked)
		end
		UI:Refresh()
	end)
	toggle:SetPoint("TOPLEFT", x, y)
	W:AttachTooltip(toggle, label, tip)
	tinsert(private.toggles, { toggle = toggle, getTable = getTable, key = key })
	return toggle
end

function private.Card(parent, y, height, title, width)
	local card = W:Card(parent)
	card:SetPoint("TOPLEFT", 0, y)
	card:SetSize(width, height)
	local label = W:SectionLabel(card, title)
	label:SetPoint("TOPLEFT", 16, -14)
	return card
end



-- ============================================================================
-- Tabs
-- ============================================================================

function private.BuildAlerts(panel, width)
	local card = private.Card(panel, 0, 250, "Enemy detection and alerts", width)
	private.Toggle(card, Detect, "enabled", "Detect enemy players", "Watch nameplates, your target, focus and mouseover for enemy players.", 16, -38)
	private.Toggle(card, Detect, "sound", "Alert sounds", "Play a beep when an enemy appears (three for Kill on Sight and bounty targets).", 16, -62)
	private.Toggle(card, Detect, "stealth", "Stealth alarm", "Warn when a nearby enemy uses Stealth, Vanish, Prowl, Shadowmeld or Invisibility.", 16, -86)
	private.Toggle(card, Detect, "autoShow", "Open the Nearby window when an enemy appears", "Otherwise open it with right-click on the minimap button, the Enemies page or /wanted nearby.", 16, -110)
	private.Toggle(card, Detect, "risingAlerts", "Warn when a zone fills up with enemies fast", "A warning like RISING FAST: The Barrens when many more enemies show up there than 5 minutes before. From your sightings and other Wanted users'.", 16, -134)
	local alertsLabel = Theme:Text(card, "small", "Alert for")
	alertsLabel:SetPoint("TOPLEFT", 16, -170)
	private.alerts = W:Segmented(card, {
		{ key = "all", label = "Every enemy" },
		{ key = "important", label = "KoS and bounties" },
		{ key = "none", label = "Nothing" },
	}, function(key)
		Detect().alerts = key
	end, 130)
	private.alerts:SetPoint("TOPLEFT", 16, -188)
	-- Lost contact: still shown as in sight for a while (they're likely still around), then shaded, then gone
	local inSightLabel = Theme:Text(card, "small", "Out of view, still show as in sight for")
	inSightLabel:SetPoint("TOPLEFT", 440, -150)
	private.inSight = W:Segmented(card, {
		{ key = "30", label = "30s" },
		{ key = "60", label = "1m" },
		{ key = "120", label = "2m" },
	}, function(key)
		Detect().inSight = tonumber(key)
		RefreshNearby()
	end, 56)
	private.inSight:SetPoint("TOPLEFT", 440, -168)
	local timeoutLabel = Theme:Text(card, "small", "Then shade them for, before they leave the list")
	timeoutLabel:SetPoint("TOPLEFT", 440, -198)
	private.timeout = W:Segmented(card, {
		{ key = "20", label = "20s" },
		{ key = "30", label = "30s" },
		{ key = "60", label = "1m" },
		{ key = "120", label = "2m" },
	}, function(key)
		Detect().timeout = tonumber(key)
	end, 56)
	private.timeout:SetPoint("TOPLEFT", 440, -216)
	local previewLabel = Theme:Text(card, "small", "Hear them")
	previewLabel:SetPoint("TOPLEFT", 440, -38)
	local previous = nil
	for _, preview in ipairs({ { "enemy", "Enemy" }, { "important", "Kill on Sight" }, { "stealth", "Stealth" } }) do
		local button = W:Button(card, preview[2], "chip", preview[1] == "important" and 100 or 70, 22, function()
			Wanted.Alerts:PlayRaw(preview[1])
		end)
		if previous then
			button:SetPoint("LEFT", previous, "RIGHT", 6, 0)
		else
			button:SetPoint("TOPLEFT", 440, -58)
		end
		previous = button
	end
end

function private.BuildTargeted(panel, width)
	local card = private.Card(panel, -262, 172, "When an enemy targets you", width)
	private.Toggle(card, Detect, "targetWarn", "Show a TARGETED warning", "A warning in the middle of the screen naming whoever has you targeted.", 16, -38, function() Wanted.Alerts:UpdateTargetedHud() end)
	private.Toggle(card, Detect, "targetSound", "Play the targeted sound", "A rising double tone each time another enemy starts targeting you.", 16, -62)
	private.Toggle(card, Detect, "targetHold", "Keep the warning up while I'm targeted", "Otherwise it shows for a few seconds each time someone new targets you.", 16, -86)
	private.Toggle(card, Detect, "targetNames", "List who in the warning", "Off: the warning just says TARGETED, and the Nearby window shows who (their rows turn red).", 16, -110, function() Wanted.Alerts:UpdateTargetedHud() end)
	local hear = W:Button(card, "Targeted", "chip", 80, 22, function()
		Wanted.Alerts:PlayRaw("targeted")
	end)
	hear:SetPoint("TOPLEFT", 440, -38)
	W:AttachTooltip(hear, "Hear it", "The sound you get when an enemy targets you.")
	private.moveHud = W:Button(card, "Move the warning", "secondary", 140, 26, function()
		local moving = not Wanted.Alerts:IsHudMoving()
		Wanted.Alerts:SetHudMoving(moving)
		private.moveHud:SetText(moving and "Done" or "Move the warning")
		private.moveHud:SetStyle(moving and "primary" or "secondary")
	end)
	private.moveHud:SetPoint("TOPLEFT", 440, -70)
	local hint = Theme:Text(card, "tiny", "Needs enemy detection on. Works from nameplates, your target and focus: someone off screen can't be seen targeting you.")
	hint:SetPoint("TOPLEFT", 16, -142)
end

function private.BuildNearby(panel, width)
	local card = private.Card(panel, 0, 120, "Row layout", width)
	private.layout = W:Segmented(card, {
		{ key = "auto", label = "Automatic" },
		{ key = "normal", label = "Always normal" },
		{ key = "compact", label = "Always compact" },
	}, function(key)
		NearbyShow().layout = key
		RefreshNearby()
	end, 130)
	private.layout:SetPoint("TOPLEFT", 16, -38)
	local hint = Theme:Text(card, "tiny", "Automatic uses two-line rows, and one-line rows once more than 8 enemies are around.")
	hint:SetPoint("TOPLEFT", 16, -72)
	local opacityLabel = Theme:Text(card, "small", "Window background")
	opacityLabel:SetPoint("TOPLEFT", 440, -20)
	private.opacity = W:Segmented(card, {
		{ key = "1", label = "Solid" },
		{ key = "0.75", label = "75%" },
		{ key = "0.5", label = "50%" },
		{ key = "0.25", label = "25%" },
	}, function(key)
		NearbyShow().opacity = tonumber(key)
		RefreshNearby()
	end, 60)
	private.opacity:SetPoint("TOPLEFT", 440, -38)

	local shown = private.Card(panel, -132, 152, "Show on each row", width)
	local items = {
		{ "icon", "Class icon", "The class icon at the start of the row (style under Sharing and display)." },
		{ "className", "Class name", "The class spelled out next to the level (two-line rows)." },
		{ "level", "Level", "The player's level (?? for a skull)." },
		{ "guild", "Guild", "<Guild name> on the second line." },
		{ "bounty", "Bounty", "The bounty gold on them, and a gold marker." },
		{ "kos", "Kill on Sight", "The Kill on Sight tag with your reason, and a red marker." },
		{ "state", "Active / in sight / not seen", "Whether they're acting, in view, or out of sight and for how long." },
		{ "record", "Wins and losses", "Your record against them, e.g. 2-1." },
		{ "health", "Health bar", "A thin health bar along the bottom while they're in view." },
		{ "tint", "Class colour wash", "A faint wash of their class colour behind the row." },
		{ "targeting", "Targeting you", "A red > before the name when they target you." },
		{ "fade", "Shade out of sight", "Dim a row once the player has been out of view longer than the in-sight time (Alerts tab)." },
	}
	for i, item in ipairs(items) do
		local column = (i - 1) % 3
		local line = floor((i - 1) / 3)
		private.Toggle(shown, NearbyShow, item[1], item[2], item[3], 16 + column * 230, -38 - line * 26, RefreshNearby)
	end
end

function private.BuildSharing(panel, width)
	local card = private.Card(panel, 0, 130, "Sharing", width)
	private.Toggle(card, Detect, "share", "Share the enemies I see", "Other players running Wanted on your faction see where you spotted enemies (on their map and in their alerts).", 16, -38)
	private.Toggle(card, Detect, "sharedAlerts", "Alert me when others see a KoS or bounty target", "Shows where another Wanted user spotted someone on your Kill on Sight list or with a bounty.", 16, -62)
	local note = Theme:Text(card, "tiny", "Wanted never posts in General or Trade. Chat is only sent when you click Call for help or Tell (Local Defense, party, raid, guild).")
	note:SetPoint("TOPLEFT", 16, -94)

	local display = private.Card(panel, -142, 150, "Display", width)
	private.Toggle(display, Detect, "mapPins", "Show enemies on the world map", "Recent sightings, yours and shared, drawn on the world map for the last 30 minutes. Also in the map's own filter menu.", 16, -38, function() Wanted.MapPins:Refresh() end)
	private.minimap = W:Toggle(display, "Minimap button", function(checked)
		Wanted.db.settings.minimap.hide = not checked
		Wanted.Minimap:Update()
	end)
	private.minimap:SetPoint("TOPLEFT", 16, -62)
	private.Toggle(display, function() return Wanted.db.settings end, "showTools", "Show the Tools page", "Network details, test data and the debug log. Handy when reporting a problem; off by default.", 16, -86)
	local iconLabel = Theme:Text(display, "small", "Class icons")
	iconLabel:SetPoint("TOPLEFT", 360, -20)
	local previous = nil
	for _, style in ipairs(Theme.ICON_STYLES) do
		local button = W:Button(display, "", "secondary", 58, 58, function()
			Wanted.db.settings.iconStyle = style.key
			private.Refresh()
			UI:Refresh()
			RefreshNearby()
		end)
		if previous then
			button:SetPoint("LEFT", previous, "RIGHT", 6, 0)
		else
			button:SetPoint("TOPLEFT", 360, -40)
		end
		button.icons = {}
		for i, class in ipairs({ "WARRIOR", "MAGE", "ROGUE", "PRIEST" }) do
			local icon = button:CreateTexture(nil, "ARTWORK")
			icon:SetSize(18, 18)
			icon:SetPoint("TOPLEFT", 8 + ((i - 1) % 2) * 22, -6 - floor((i - 1) / 2) * 22)
			button.icons[i] = { texture = icon, class = class }
		end
		button.label:ClearAllPoints()
		button.label:SetPoint("BOTTOM", 0, -16)
		button.label:SetFontObject(Theme.Fonts.tiny)
		button:SetText(style.label)
		button.styleKey = style.key
		tinsert(private.iconButtons, button)
		previous = button
	end
end



-- ============================================================================
-- Page
-- ============================================================================

function private.Refresh()
	if not private.alerts then
		return
	end
	for _, entry in ipairs(private.toggles) do
		entry.toggle:SetChecked(entry.getTable()[entry.key])
	end
	local detect = Detect()
	private.alerts:Select(detect.alerts or "all", true)
	private.inSight:Select(tostring(detect.inSight or 60), true)
	private.timeout:Select(tostring(detect.timeout or 30), true)
	private.layout:Select(NearbyShow().layout or "auto", true)
	private.opacity:Select(tostring(NearbyShow().opacity or 1), true)
	private.minimap:SetChecked(not Wanted.db.settings.minimap.hide)
	for _, button in ipairs(private.iconButtons) do
		for _, entry in ipairs(button.icons) do
			Theme:SetClassIcon(entry.texture, entry.class, button.styleKey)
		end
		button:SetStyle(button.styleKey == (Wanted.db.settings.iconStyle or "crest") and "selected" or "secondary")
	end
	for key, panel in pairs(private.panels) do
		panel:SetShown(key == private.view)
	end
end

UI:RegisterPage("settings", {
	title = "Settings",
	subtitle = "Alerts, what the Nearby window shows, and what Wanted shares with other players.",
	order = 6,
	build = function(container, width, height)
		local tabs = W:Segmented(container, {
			{ key = "alerts", label = "Alerts" },
			{ key = "nearby", label = "Nearby window" },
			{ key = "sharing", label = "Sharing and display" },
		}, function(key)
			private.view = key
			private.Refresh()
		end, 150)
		tabs:SetPoint("TOPLEFT")
		tabs:Select("alerts", true)
		for _, key in ipairs({ "alerts", "nearby", "sharing" }) do
			local panel = CreateFrame("Frame", nil, container)
			panel:SetPoint("TOPLEFT", 0, -40)
			panel:SetSize(width, height - 40)
			panel:Hide()
			private.panels[key] = panel
		end
		private.BuildAlerts(private.panels.alerts, width)
		private.BuildTargeted(private.panels.alerts, width)
		private.BuildNearby(private.panels.nearby, width)
		private.BuildSharing(private.panels.sharing, width)
	end,
	refresh = private.Refresh,
})
