-- Wanted: settings, in six tabs: Alerts (detection and sounds), Nearby window (what each row shows),
-- Sharing and display (network, map, minimap, class icons), Kill streaks, Ranks (other players' ranks and where they
-- show), and Emotes (the emote buttons).

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local private = { toggles = {}, layoutSliders = {}, panels = {}, view = "alerts", iconButtons = {}, emoteChips = {}, soundPicks = {} }
local EMOTE_STYLES = { fav = "selected", list = "chip", hidden = "ghost" }
local EMOTE_CHIP_WIDTH, EMOTE_COLUMNS = 82, 8
local SOUNDS_X = 412 -- the Sounds card sits right of the targeted card
local SOUND_MENU_PAGE = 25 -- SharedMedia sounds per menu page, so a long list stays on screen
-- { kind, label, tooltip }
local SOUND_KINDS = {
	{ "enemy", "Enemy", "An enemy shows up (and a zone filling up fast)." },
	{ "important", "KoS and bounty", "A Kill on Sight, bounty or outlaw target shows up, or someone else sees one. Also the kill streak sound." },
	{ "stealth", "Stealth", "A nearby enemy goes into stealth." },
	{ "targeted", "Targeted", "An enemy starts targeting you." },
}

local function Detect()
	return Wanted.db.settings.detect
end

local function NearbyShow()
	return Wanted.db.settings.nearby
end

local function StreakSettings()
	return Wanted.db.settings.streaks
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
	local inSightLabel = Theme:Text(card, "small", "Out of view, still show as nearby for")
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
	private.Toggle(card, Detect, "onlyWhenExposed", "Only when I can be attacked", "Alerts, the TARGETED warning and the Nearby window stay quiet while you're not PvP flagged or are in a sanctuary. Enemies are still seen and shared.", 440, -100, function()
		Wanted.NearbyWindow:UpdateExposure()
	end)
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
	local card = private.Card(panel, -262, 172, "When an enemy targets you", SOUNDS_X - 12)
	private.Toggle(card, Detect, "targetWarn", "Show a TARGETED warning", "A warning in the middle of the screen naming whoever has you targeted.", 16, -38, function() Wanted.Alerts:UpdateTargetedHud() end)
	private.Toggle(card, Detect, "targetSound", "Play the targeted sound", "A rising double tone each time another enemy starts targeting you.", 16, -62)
	private.Toggle(card, Detect, "targetHold", "Keep the warning up while I'm targeted", "Otherwise it shows for a few seconds each time someone new targets you.", 16, -86)
	private.Toggle(card, Detect, "targetNames", "List who in the warning", "Off: the warning just says TARGETED, and the Nearby window shows who (their rows turn red).", 16, -110, function() Wanted.Alerts:UpdateTargetedHud() end)
	private.moveHud = W:Button(card, "Move the warning", "secondary", 140, 24, function()
		local moving = not Wanted.Alerts:IsHudMoving()
		Wanted.Alerts:SetHudMoving(moving)
		private.moveHud:SetText(moving and "Done" or "Move the warning")
		private.moveHud:SetStyle(moving and "primary" or "secondary")
	end)
	private.moveHud:SetPoint("TOPRIGHT", -12, -10)
	local hint = Theme:Text(card, "tiny", "Needs enemy detection on. Works from nameplates, your target and focus: someone off screen can't be seen targeting you.")
	hint:SetPoint("TOPLEFT", 16, -136)
	hint:SetWidth(SOUNDS_X - 44)
	hint:SetJustifyH("LEFT")
end

-- Beside the targeted card: each alert's sound, with a button to hear it
function private.BuildSounds(panel, width)
	local card = private.Card(panel, -262, 172, "Sounds", width - SOUNDS_X)
	card:SetPoint("TOPLEFT", SOUNDS_X, -262)
	for i, kind in ipairs(SOUND_KINDS) do
		local y = -38 - (i - 1) * 26
		local label = Theme:Text(card, "small", kind[2])
		label:SetPoint("TOPLEFT", 16, y - 4)
		local pick = W:Button(card, "", "secondary", 132, 22)
		pick:SetScript("OnClick", function(self)
			private.SoundMenu(kind[1], self)
		end)
		pick:SetPoint("TOPLEFT", 116, y)
		-- A long SharedMedia name is cut short instead of running over the next button
		pick.label:SetWidth(122)
		pick.label:SetWordWrap(false)
		W:AttachTooltip(pick, kind[2], kind[3])
		private.soundPicks[kind[1]] = pick
		local hear = W:Button(card, "Hear it", "chip", 52, 22, function()
			Wanted.Alerts:PlayRaw(kind[1])
		end)
		hear:SetPoint("LEFT", pick, "RIGHT", 6, 0)
	end
	local hint = Theme:Text(card, "tiny", "Add your own sounds with a SharedMedia addon.")
	hint:SetPoint("TOPLEFT", 16, -146)
end

---The sound choices for one alert kind, under its button. SharedMedia sounds get their own menu, a page at a time.
function private.SoundMenu(kind, anchor, page)
	local Alerts = Wanted.Alerts
	local current = Alerts:GetSoundChoice(kind)
	local function Item(choice, text)
		return { text = text, color = choice == current and C.accent or nil, onClick = function()
			Alerts:SetSoundChoice(kind, choice)
			Alerts:PlayRaw(kind)
			private.Refresh()
		end }
	end
	local items = {}
	local shared = Alerts:GetSharedMediaSounds()
	if page then
		tinsert(items, { text = "SharedMedia sounds", header = true })
		local first = (page - 1) * SOUND_MENU_PAGE + 1
		for i = first, min(#shared, first + SOUND_MENU_PAGE - 1) do
			tinsert(items, Item("lsm:"..shared[i], shared[i]))
		end
		tinsert(items, "-")
		if #shared > page * SOUND_MENU_PAGE then
			tinsert(items, { text = "More...", onClick = function() private.SoundMenu(kind, anchor, page + 1) end })
		end
		tinsert(items, { text = "Back", onClick = function() private.SoundMenu(kind, anchor) end })
	else
		tinsert(items, Item("wanted", Wanted.Alerts:SoundLabel("wanted", kind).." (Wanted)"))
		tinsert(items, Item("none", "None"))
		tinsert(items, "-")
		tinsert(items, { text = "Game sounds", header = true })
		for _, entry in ipairs(Alerts:GetGameSounds()) do
			tinsert(items, Item(entry[1], entry[2]))
		end
		if #shared > 0 then
			tinsert(items, "-")
			tinsert(items, { text = "SharedMedia sounds...", color = current:find("^lsm:") and C.accent or nil, onClick = function()
				private.SoundMenu(kind, anchor, 1)
			end })
		end
	end
	W:Menu(items, anchor)
end

function private.BuildNearby(panel, width)
	local card = private.Card(panel, 0, 130, "Row layout", width)
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
	local hideLabel = Theme:Text(card, "small", "Hide it after no enemies for")
	hideLabel:SetPoint("TOPLEFT", 440, -74)
	private.autoHide = W:Segmented(card, {
		{ key = "0", label = "Never" },
		{ key = "120", label = "2m" },
		{ key = "300", label = "5m" },
		{ key = "600", label = "10m" },
	}, function(key)
		Detect().autoHide = tonumber(key)
	end, 60)
	private.autoHide:SetPoint("TOPLEFT", 440, -92)

	local shown = private.Card(panel, -142, 178, "Show in the Nearby window", width)
	local items = {
		{ "icon", "Class icon", "The class icon at the start of the row (style under Sharing and display)." },
		{ "className", "Class name", "The class spelled out next to the level (two-line rows)." },
		{ "level", "Level", "The player's level (?? for a skull)." },
		{ "guild", "Guild", "<Guild name> on the second line." },
		{ "bounty", "Bounty", "The bounty gold on them, and a gold marker." },
		{ "kos", "Kill on Sight", "The Kill on Sight tag with your reason, and a red marker." },
		{ "state", "Active / in sight / nearby / not seen", "Whether they're acting, on your screen (in sight, clickable), out of view but likely still around (nearby), or gone and for how long." },
		{ "record", "Wins and losses", "Your record against them, e.g. 2-1." },
		{ "health", "Health bar", "A thin health bar along the bottom while they're in view." },
		{ "tint", "Class colour wash", "A faint wash of their class colour behind the row." },
		{ "targeting", "Targeting you", "A red > before the name when they target you." },
		{ "pvp", "Your PvP status", "A strip under the tabs: PvP on or off, and how long until the flag wears off." },
		{ "fade", "Shade the long gone", "Dim a row once the player has been out of view longer than the nearby time (Alerts tab)." },
	}
	for i, item in ipairs(items) do
		local column = (i - 1) % 3
		local line = floor((i - 1) / 3)
		private.Toggle(shown, NearbyShow, item[1], item[2], item[3], 16 + column * 230, -38 - line * 26, RefreshNearby)
	end
end

function private.BuildSharing(panel, width)
	local card = private.Card(panel, 0, 154, "Sharing", width)
	private.Toggle(card, Detect, "share", "Share the enemies I see", "Other players running Wanted on your faction see where you spotted enemies (on their map and in their alerts).", 16, -38)
	private.Toggle(card, Detect, "sharedAlerts", "Alert me when others see a KoS or bounty target", "Shows where another Wanted user spotted someone on your Kill on Sight list or with a bounty.", 16, -62)
	private.Toggle(card, function() return Wanted.db.settings end, "bridge", "Carry bounty notices across factions", "Battle.net friends on the other faction who also run Wanted pass on the bounties each side posts on the other, as hidden game data, never chat. It's how you learn the price on your head.", 16, -86)
	-- The Wanted community, beside the toggles: its members carry bounty notices across too (Bridge)
	local community = Theme:Text(card, "small", "Wanted community", C.muted)
	community:SetPoint("TOPLEFT", 400, -38)
	local join = Theme:Text(card, "tiny", "Join to link your addon to the other faction. Members can see each other's BattleTag.")
	join:SetPoint("TOPLEFT", 400, -56)
	join:SetPoint("RIGHT", -16, 0)
	join:SetJustifyH("LEFT")
	join:SetWordWrap(true)
	local invite = W:CopyBox(card, width - 416, Wanted.Bridge.INVITE_URL)
	invite:SetPoint("TOPLEFT", 400, -86)
	local note = Theme:Text(card, "tiny", "Wanted never posts in General or Trade. Chat is only sent when you click Call for help or Tell (Local Defense, party, raid, guild).")
	note:SetPoint("TOPLEFT", 16, -118)

	local display = private.Card(panel, -166, 150, "Display", width)
	private.Toggle(display, Detect, "mapPins", "Show enemies on the world map", "Recent sightings, yours and shared, drawn on the world map for the last 30 minutes. Also in the map's own filter menu.", 16, -38, function() Wanted.MapPins:Refresh() end)
	private.minimap = W:Toggle(display, "Minimap button", function(checked)
		Wanted.db.settings.minimap.hide = not checked
		Wanted.Minimap:Update()
	end)
	private.minimap:SetPoint("TOPLEFT", 16, -62)
	private.Toggle(display, function() return Wanted.db.settings end, "showTools", "Show the Tools page", "Network details, test data and the debug log. Handy when reporting a problem; off by default.", 16, -86)
	local proof = private.Card(panel, -328, 120, "Kill proof", width)
	private.Toggle(proof, function() return Wanted.db.settings end, "proofShots", "Take a proof screenshot when I kill a bounty target", "A stamp with who, where, when and the kill id goes on screen for a moment and the game saves a screenshot. Posters see that you have proof.", 16, -38)
	local proofText = Theme:Text(proof, "small", format("If a kill is disputed, post the screenshot in %s on the Forever PvP Discord (click the link, Ctrl+C):", Wanted.Proof.DISCORD_CHANNEL), C.muted)
	proofText:SetPoint("TOPLEFT", 16, -66)
	local link = W:CopyBox(proof, 360, Wanted.Proof.DISCORD_URL)
	link:SetPoint("TOPLEFT", 16, -84)

	local iconLabel = Theme:Text(display, "small", "Class icons")
	iconLabel:SetPoint("TOPLEFT", 360, -20)
	local previous = nil
	for _, style in ipairs(Theme.ICON_STYLES) do
		-- Styles marked hidden aren't offered: they look the same as Crest here
		if not style.hidden then
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
end



function private.BuildStreaks(panel, width)
	local card = private.Card(panel, 0, 196, "Kill streaks", width)
	private.Toggle(card, StreakSettings, "callout", "Show a callout for streaks and multi-kills", "Big text in the middle of the screen: Double kill and up for kills within 30 seconds of each other, Killing spree at 3 kills without dying, Unstoppable at 5, Legendary at 8.", 16, -38)
	private.Toggle(card, StreakSettings, "sound", "Play a sound with it", "The Kill on Sight alert sound. Quiet when alert sounds are off (Alerts tab) or muted from the Nearby window.", 16, -62)
	local hear = W:Button(card, "Show me", "chip", 80, 22, function()
		Wanted.Streaks:Preview()
	end)
	hear:SetPoint("TOPLEFT", 440, -38)
	W:AttachTooltip(hear, "Show me", "A sample callout and its sound.")
	local announceLabel = Theme:Text(card, "small", "Announce streaks to")
	announceLabel:SetPoint("TOPLEFT", 16, -98)
	private.streakAnnounce = W:Segmented(card, {
		{ key = "none", label = "Nobody" },
		{ key = "party", label = "My party" },
		{ key = "guild", label = "My guild" },
	}, function(key)
		StreakSettings().announce = key
	end, 110)
	private.streakAnnounce:SetPoint("TOPLEFT", 16, -116)
	local hint = Theme:Text(card, "tiny", "A line like \"Wanted: <you> is on a killing spree (3 kills)\", at most one every 10 seconds, only while you're in a party or guild. Never in public chat.")
	hint:SetPoint("TOPLEFT", 16, -154)
end

---A slider bound to a layout table key (settings.ranks.plate or targetLabel); kept in step by Refresh.
function private.LayoutSlider(parent, getTable, key, label, low, high, step, format, x, y, width)
	local slider = W:Slider(parent, label, width, low, high, step, format, function(value)
		getTable()[key] = value
		Wanted.Ranks:Update()
	end)
	slider:SetPoint("TOPLEFT", x, y)
	tinsert(private.layoutSliders, { slider = slider, getTable = getTable, key = key })
	return slider
end

function private.BuildRanks(panel, width)
	-- Other players' challenge ranks (Ranks), from the Wanted app only
	local ranks = private.Card(panel, 0, 128, "Challenge ranks of other players", width)
	local function RankSettings() return Wanted.db.settings.ranks end
	local function Update() Wanted.Ranks:Update() end
	private.Toggle(ranks, RankSettings, "tooltip", "In the tooltip", "A line like \"Wanted: Rank 7, Blood Guard\" with the badge, when you mouse over a player.", 16, -38)
	private.Toggle(ranks, RankSettings, "target", "Over the target frame", "The rank and its title over your target's frame.", 16, -62, Update)
	private.Toggle(ranks, RankSettings, "nameplates", "On nameplates", "The rank's badge and number left of ranked players' names on nameplates. New plates follow the switch as they come up.", 16, -86, Update)
	private.Toggle(ranks, RankSettings, "chat", "In chat", "[R7] at the start of what ranked players say, in your own chat windows. Off by default.", 360, -38)
	private.Toggle(ranks, RankSettings, "nearby", "In the Nearby window", "R7 beside the level of ranked enemies.", 360, -62, RefreshNearby)
	private.Toggle(ranks, RankSettings, "who", "In the Who list", "R7 beside ranked players' names.", 360, -86)
	local rankHint = Theme:Text(ranks, "tiny", "Ranks come from wanteddeadordead.com through the Wanted app. A player can never set their own.")
	rankHint:SetPoint("TOPLEFT", 16, -110)

	local function Plate() return Wanted.db.settings.ranks.plate end
	local function Target() return Wanted.db.settings.ranks.targetLabel end
	local Ranks = Wanted.Ranks
	local function Offset(value) return format("%+d", value) end
	local function Scale(value) return format("%.1fx", value) end
	local sliderWidth = floor((width - 32 - 2 * 24 - 170) / 3)

	local plate = private.Card(panel, -138, 140, "Rank on nameplates", width)
	local plateChoices, targetChoices = {}, {}
	for _, a in ipairs(Ranks.PLATE_ANCHORS) do tinsert(plateChoices, { key = a.key, label = a.label }) end
	for _, a in ipairs(Ranks.TARGET_ANCHORS) do tinsert(targetChoices, { key = a.key, label = a.label }) end
	private.plateAnchor = W:Choice(plate, 160, plateChoices, function(key)
		Plate().anchor = key
		Ranks:Update()
	end)
	private.plateAnchor:SetPoint("TOPLEFT", 16, -44)
	W:AttachTooltip(private.plateAnchor, "Where", "Centred over the plate, around the player's name, or on the top corners of the health bar.")
	local x0 = 16 + 170
	private.LayoutSlider(plate, Plate, "x", "X offset", -50, 50, 1, Offset, x0, -38, sliderWidth)
	private.LayoutSlider(plate, Plate, "y", "Y offset", -50, 50, 1, Offset, x0 + sliderWidth + 24, -38, sliderWidth)
	private.LayoutSlider(plate, Plate, "scale", "Size", 0.6, 1.6, 0.1, Scale, x0 + 2 * (sliderWidth + 24), -38, sliderWidth)
	private.Toggle(plate, Plate, "badge", "Show badge", "The rank's badge, the game's PvP rank insignia.", 16, -86, function() Ranks:Update() end)
	private.Toggle(plate, Plate, "number", "Show number", "The rank's number, after the badge.", 140, -86, function() Ranks:Update() end)
	local plateHint = Theme:Text(plate, "tiny", "Changes show at once on the nameplates already up. Works with the game's nameplates, ElvUI and Plater.")
	plateHint:SetPoint("TOPLEFT", 16, -114)

	local target = private.Card(panel, -288, 100, "Rank at the target frame", width)
	private.targetAnchor = W:Choice(target, 160, targetChoices, function(key)
		Target().anchor = key
		Ranks:Update()
	end)
	private.targetAnchor:SetPoint("TOPLEFT", 16, -44)
	private.LayoutSlider(target, Target, "x", "X offset", -50, 50, 1, Offset, x0, -38, sliderWidth)
	private.LayoutSlider(target, Target, "y", "Y offset", -50, 50, 1, Offset, x0 + sliderWidth + 24, -38, sliderWidth)
	private.LayoutSlider(target, Target, "scale", "Size", 0.6, 1.6, 0.1, Scale, x0 + 2 * (sliderWidth + 24), -38, sliderWidth)
	local targetHint = Theme:Text(target, "tiny", "Your target's frame, or ElvUI's when it's loaded.")
	targetHint:SetPoint("TOPLEFT", 16, -78)
end



-- ============================================================================
-- Page
-- ============================================================================

function private.BuildEmotes(panel, width)
	local Emotes = Wanted.Emotes
	local card = private.Card(panel, 0, 392, "Emote buttons", width)
	private.Toggle(card, function() return Wanted.db.settings.emotes end, "enabled", "Show emote buttons in the Nearby window",
		"Favourites along the bottom of the Nearby window and a ... button with the rest. Each emotes at your target, even mid-fight.", 16, -38, RefreshNearby)
	private.emoteCount = Theme:Text(card, "small", "")
	private.emoteCount:SetPoint("TOPRIGHT", -16, -40)
	private.emoteCount:SetJustifyH("RIGHT")
	local legend = Theme:Text(card, "tiny", "Click an emote to change it:  "..Theme:Colorize("gold", C.accent).." = favourite (in the Nearby window, up to "
		..Emotes.MAX_FAVOURITES..")   outlined = in the ... list   faint = hidden")
	legend:SetPoint("TOPLEFT", 16, -64)
	local y = -86
	for _, group in ipairs(Emotes.GROUPS) do
		local heading = W:SectionLabel(card, group.label)
		heading:SetPoint("TOPLEFT", 16, y)
		y = y - 18
		local column = 0
		for _, def in ipairs(Emotes.LIST) do
			if def[4] == group.key then
				local chip = W:Button(card, def[2], "chip", EMOTE_CHIP_WIDTH, 22, function(self)
					local before = Emotes:GetState(self.key)
					local state = Emotes:CycleState(self.key)
					if before == "hidden" and state == "list" then
						UI:Toast(format("Up to %d favourites; %s is in the ... list.", Emotes.MAX_FAVOURITES, self.label:GetText()), C.amber)
					end
					private.RefreshEmotes()
					RefreshNearby()
				end)
				chip.key = def[1]
				chip:SetPoint("TOPLEFT", 16 + column * (EMOTE_CHIP_WIDTH + 4), y)
				W:AttachTooltip(chip, def[2], def[3].." at your target.")
				tinsert(private.emoteChips, chip)
				column = column + 1
				if column == EMOTE_COLUMNS then
					column = 0
					y = y - 26
				end
			end
		end
		y = y - (column > 0 and 26 or 0) - 6
	end
	local hint = Theme:Text(card, "tiny", "Changes show in the Nearby window straight away, or after combat if you're in one.")
	hint:SetPoint("TOPLEFT", 16, y - 2)
end

---The emote chips' look and the count, from the saved states.
function private.RefreshEmotes()
	local Emotes = Wanted.Emotes
	for _, chip in ipairs(private.emoteChips) do
		chip:SetStyle(EMOTE_STYLES[Emotes:GetState(chip.key)])
	end
	local favourites, listed = Emotes:CountShown()
	private.emoteCount:SetText(format("%d favourite%s, %d in the list", favourites, favourites == 1 and "" or "s", listed))
end

function private.Refresh()
	if not private.alerts then
		return
	end
	private.RefreshEmotes()
	for _, entry in ipairs(private.layoutSliders) do
		entry.slider:SetValue(entry.getTable()[entry.key] or 0)
	end
	private.plateAnchor:SetChoice(Wanted.db.settings.ranks.plate.anchor)
	private.targetAnchor:SetChoice(Wanted.db.settings.ranks.targetLabel.anchor)
	for _, entry in ipairs(private.toggles) do
		entry.toggle:SetChecked(entry.getTable()[entry.key])
	end
	local detect = Detect()
	private.alerts:Select(detect.alerts or "all", true)
	private.inSight:Select(tostring(detect.inSight or 60), true)
	private.autoHide:Select(tostring(detect.autoHide or 300), true)
	private.timeout:Select(tostring(detect.timeout or 30), true)
	private.layout:Select(NearbyShow().layout or "auto", true)
	private.opacity:Select(tostring(NearbyShow().opacity or 1), true)
	private.streakAnnounce:Select(StreakSettings().announce or "none", true)
	private.minimap:SetChecked(not Wanted.db.settings.minimap.hide)
	for kind, pick in pairs(private.soundPicks) do
		pick:SetText(Wanted.Alerts:SoundLabel(Wanted.Alerts:GetSoundChoice(kind), kind))
	end
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
	group = "You",
	title = "Settings",
	subtitle = "Alerts, what the Nearby window shows, and what Wanted shares with other players.",
	order = 6,
	build = function(container, width, height)
		local tabs = W:Segmented(container, {
			{ key = "alerts", label = "Alerts" },
			{ key = "nearby", label = "Nearby window" },
			{ key = "sharing", label = "Sharing and display" },
			{ key = "streaks", label = "Kill streaks" },
			{ key = "ranks", label = "Ranks" },
			{ key = "emotes", label = "Emotes" },
		}, function(key)
			private.view = key
			private.Refresh()
		end, 121)
		tabs:SetPoint("TOPLEFT")
		tabs:Select("alerts", true)
		for _, key in ipairs({ "alerts", "nearby", "sharing", "streaks", "ranks", "emotes" }) do
			local panel = CreateFrame("Frame", nil, container)
			panel:SetPoint("TOPLEFT", 0, -40)
			panel:SetSize(width, height - 40)
			panel:Hide()
			private.panels[key] = panel
		end
		private.BuildAlerts(private.panels.alerts, width)
		private.BuildTargeted(private.panels.alerts, width)
		private.BuildSounds(private.panels.alerts, width)
		private.BuildNearby(private.panels.nearby, width)
		private.BuildSharing(private.panels.sharing, width)
		private.BuildStreaks(private.panels.streaks, width)
		private.BuildRanks(private.panels.ranks, width)
		private.BuildEmotes(private.panels.emotes, width)
	end,
	refresh = private.Refresh,
})
