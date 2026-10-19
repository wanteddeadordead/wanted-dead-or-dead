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



---A tab's page: a scrolling column of sections and EllesmereUI rows, each stacked under the last.
function private.Column(panel, width, height)
	local scroll = W:Scroll(panel, width, height)
	scroll:SetPoint("TOPLEFT")
	local column = { content = scroll.content, width = width - 12, y = 0, scroll = scroll }
	---Puts a frame next, height h (its own by default), x in from the left.
	function column:Add(frame, h, x)
		frame:SetPoint("TOPLEFT", x or 0, self.y)
		self.y = self.y - (h or frame:GetHeight())
		scroll:Fit(-self.y)
		return frame
	end
	function column:Section(title)
		if self.y ~= 0 then
			self.y = self.y - 18
		end
		self:Add(W:SectionLabel(self.content, title, self.width), 22)
	end
	---A row: the option's label, its control on the right, its help on the label.
	function column:Row(label, control, tip)
		return self:Add(W:Row(self.content, self.width, label, control, tip))
	end
	---A note under the rows, in small print.
	function column:Note(text)
		local note = Theme:Text(self.content, "tiny", text)
		note:SetWidth(self.width - 40)
		note:SetJustifyH("LEFT")
		note:SetWordWrap(true)
		self.y = self.y - 8
		self:Add(note, note:GetStringHeight() + 4, 20)
		return note
	end
	return column
end

---A row with a switch bound to a settings table key.
function private.Switch(column, getTable, key, label, tip, onChange)
	local switch = W:Switch(column.content, function(checked)
		getTable()[key] = checked
		if onChange then
			onChange(checked)
		end
		UI:Refresh()
	end)
	tinsert(private.toggles, { toggle = switch, getTable = getTable, key = key })
	return column:Row(label, switch, tip), switch
end

---A frame holding buttons side by side, for a row's control.
local function ButtonGroup(parent, buttons)
	local group = CreateFrame("Frame", nil, parent)
	local x = 0
	for _, button in ipairs(buttons) do
		button:SetParent(group)
		button:ClearAllPoints()
		button:SetPoint("LEFT", x, 0)
		x = x + button:GetWidth() + 6
	end
	group:SetSize(max(x - 6, 1), 28)
	return group
end



-- ============================================================================
-- Tabs
-- ============================================================================

function private.BuildAlerts(column)
	local content = column.content
	column:Section("Enemy detection and alerts")
	private.Switch(column, Detect, "enabled", "Detect enemy players", "Watch nameplates, your target, focus and mouseover for enemy players.")
	private.Switch(column, Detect, "sound", "Alert sounds", "Play a beep when an enemy appears (three for Kill on Sight and bounty targets).")
	private.Switch(column, Detect, "stealth", "Stealth alarm", "Warn when a nearby enemy uses Stealth, Vanish, Prowl, Shadowmeld or Invisibility.")
	private.Switch(column, Detect, "autoShow", "Open the Nearby window when an enemy appears", "Otherwise open it with right-click on the minimap button, the Enemies page or /wanted nearby.")
	private.Switch(column, Detect, "risingAlerts", "Warn when a zone fills up with enemies fast", "A warning like RISING FAST: The Barrens when many more enemies show up there than 5 minutes before. From your sightings and other Wanted users'.")
	private.Switch(column, Detect, "onlyWhenExposed", "Only when I can be attacked", "Alerts, the TARGETED warning and the Nearby window stay quiet while you're not PvP flagged or are in a sanctuary. Enemies are still seen and shared.", function()
		Wanted.NearbyWindow:UpdateExposure()
	end)
	private.Switch(column, Detect, "deathCard", "Show a card when a player kills you", "Who killed you, your record against them and what's on their head, with Kill on Sight, Post a bounty and Where they've been.")
	private.alerts = W:Segmented(content, {
		{ key = "all", label = "Every enemy" },
		{ key = "important", label = "KoS and bounties" },
		{ key = "none", label = "Nothing" },
	}, function(key)
		Detect().alerts = key
	end, 130)
	column:Row("Alert for", private.alerts)
	-- Lost contact: still shown as in sight for a while (they're likely still around), then shaded, then gone
	private.inSight = W:Segmented(content, {
		{ key = "30", label = "30s" },
		{ key = "60", label = "1m" },
		{ key = "120", label = "2m" },
	}, function(key)
		Detect().inSight = tonumber(key)
		RefreshNearby()
	end, 56)
	column:Row("Out of view, still show as nearby for", private.inSight)
	private.timeout = W:Segmented(content, {
		{ key = "20", label = "20s" },
		{ key = "30", label = "30s" },
		{ key = "60", label = "1m" },
		{ key = "120", label = "2m" },
	}, function(key)
		Detect().timeout = tonumber(key)
	end, 56)
	column:Row("Then shade them for, before they leave the list", private.timeout)
	local previews = {}
	for _, preview in ipairs({ { "enemy", "Enemy" }, { "important", "Kill on Sight" }, { "stealth", "Stealth" } }) do
		tinsert(previews, W:Button(content, preview[2], "chip", preview[1] == "important" and 100 or 70, 22, function()
			Wanted.Alerts:PlayRaw(preview[1])
		end))
	end
	column:Row("Hear them", ButtonGroup(content, previews))

	column:Section("When an enemy targets you")
	local targeted = private.Switch(column, Detect, "targetWarn", "Show a TARGETED warning", "A warning in the middle of the screen naming whoever has you targeted.", function() Wanted.Alerts:UpdateTargetedHud() end)
	W:Cog(targeted, "The TARGETED warning", function(popup)
		private.Toggle(popup, Detect, "targetSound", "Play the targeted sound", "A rising double tone each time another enemy starts targeting you.", 14, -40)
		private.Toggle(popup, Detect, "targetHold", "Keep the warning up while I'm targeted", "Otherwise it shows for a few seconds each time someone new targets you.", 14, -66)
		private.Toggle(popup, Detect, "targetNames", "List who in the warning", "Off: the warning just says TARGETED, and the Nearby window shows who (their rows turn red).", 14, -92, function() Wanted.Alerts:UpdateTargetedHud() end)
		private.Refresh()
		return 126
	end)
	private.moveHud = W:Button(content, "Move the warning", "secondary", 140, 24, function()
		local moving = not Wanted.Alerts:IsHudMoving()
		Wanted.Alerts:SetHudMoving(moving)
		private.moveHud:SetText(moving and "Done" or "Move the warning")
		private.moveHud:SetStyle(moving and "primary" or "secondary")
	end)
	column:Row("Where it shows", private.moveHud)
	column:Note("Needs enemy detection on. Works from nameplates, your target and focus: someone off screen can't be seen targeting you.")

	-- Each alert's sound, with a button to hear it
	column:Section("Sounds")
	for _, kind in ipairs(SOUND_KINDS) do
		local pick = W:Button(content, "", "secondary", 132, 22)
		pick:SetScript("OnClick", function(self)
			private.SoundMenu(kind[1], self)
		end)
		-- A long SharedMedia name is cut short instead of running over the next button
		pick.label:SetWidth(122)
		pick.label:SetWordWrap(false)
		W:AttachTooltip(pick, kind[2], kind[3])
		private.soundPicks[kind[1]] = pick
		local hear = W:Button(content, "Hear it", "chip", 58, 22, function()
			Wanted.Alerts:PlayRaw(kind[1])
		end)
		column:Row(kind[2], ButtonGroup(content, { pick, hear }))
	end
	column:Note("Add your own sounds with a SharedMedia addon.")
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

-- What each Nearby row can show: { key, label, tooltip }
local NEARBY_ITEMS = {
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

---Options for a W:MultiSelect from { key, label, tooltip } entries.
local function Options(items)
	local options = {}
	for _, item in ipairs(items) do
		tinsert(options, { key = item[1], label = item[2], tip = { item[2], item[3] } })
	end
	return options
end

---The keys of a settings table that are on, for a W:MultiSelect.
local function Selected(settings, items)
	local selected = {}
	for _, item in ipairs(items) do
		selected[item[1]] = settings[item[1]] and true or nil
	end
	return selected
end

function private.BuildNearby(column)
	local content = column.content
	column:Section("Row layout")
	private.layout = W:Segmented(content, {
		{ key = "auto", label = "Automatic" },
		{ key = "normal", label = "Always normal" },
		{ key = "compact", label = "Always compact" },
	}, function(key)
		NearbyShow().layout = key
		RefreshNearby()
	end, 130)
	column:Row("Row layout", private.layout)
	column:Note("Automatic uses two-line rows, and one-line rows once more than 8 enemies are around.")
	private.opacity = W:Segmented(content, {
		{ key = "1", label = "Solid" },
		{ key = "0.75", label = "75%" },
		{ key = "0.5", label = "50%" },
		{ key = "0.25", label = "25%" },
	}, function(key)
		NearbyShow().opacity = tonumber(key)
		RefreshNearby()
	end, 60)
	column:Row("Window background", private.opacity)
	private.autoHide = W:Segmented(content, {
		{ key = "0", label = "Never" },
		{ key = "120", label = "2m" },
		{ key = "300", label = "5m" },
		{ key = "600", label = "10m" },
	}, function(key)
		Detect().autoHide = tonumber(key)
	end, 60)
	column:Row("Hide it after no enemies for", private.autoHide)

	column:Section("Show in the Nearby window")
	private.nearbyShow = W:MultiSelect(content, 320, Options(NEARBY_ITEMS), function(key, checked)
		NearbyShow()[key] = checked
		RefreshNearby()
		UI:Refresh()
	end)
	column:Row("Show in each row", private.nearbyShow)
end

-- Where capture fronts show: { key, label, tooltip, refresh }
local FRONT_PLACES = {
	{ "map", "World map", "Each point at its real size, coloured by who holds it, and the lanes between them. Click a point for a waypoint.", function() Wanted.CapturesMap:Refresh() end },
	{ "minimap", "Minimap", "Capture points on the minimap. Also in the minimap's tracking menu.", function() Wanted.CapturesMap:UpdateMinimap() end },
	{ "bar", "Capture bar", "Points each side holds by lane at the top of the screen in a front's zone, and your side's progress while you stand in a point.", function() Wanted.CapturesHUD:Update() end },
}

function private.BuildSharing(column)
	local content = column.content
	local function Root() return Wanted.db.settings end
	column:Section("Sharing")
	private.Switch(column, Detect, "share", "Share the enemies I see", "Other players running Wanted on your faction see where you spotted enemies (on their map and in their alerts).")
	private.Switch(column, Detect, "sharedAlerts", "Alert me when others see a KoS or bounty target", "Shows where another Wanted user spotted someone on your Kill on Sight list or with a bounty.")
	private.Switch(column, Root, "bridge", "Carry bounty notices across factions", "Battle.net friends on the other faction who also run Wanted pass on the bounties each side posts on the other, as hidden game data, never chat. It's how you learn the price on your head.")
	-- The Wanted community: its members carry bounty notices across too (Bridge)
	local invite = W:CopyBox(content, 320, Wanted.Bridge.INVITE_URL)
	column:Row("Wanted community", invite)
	column:Note("Join to link your addon to the other faction's: bounty notices and the fight layer cross as data, never chat. Members can see each other's BattleTag.")
	private.invite = invite
	-- The invite sits on Sharing and display: the tour opens that tab before bordering it (2026-10-17: it bordered an
	-- empty spot of the Alerts tab)
	UI:Mark("invite", function() return private.invite end, function()
		if private.tabs and private.view ~= "sharing" then
			private.tabs:Select("sharing")
		end
	end)
	column:Note("Wanted never posts in General or Trade. Chat is only sent when you click Call for help or Tell (Local Defense, party, raid, guild).")

	column:Section("Display")
	private.Switch(column, Detect, "mapPins", "Show enemies on the world map", "Recent sightings, yours and shared, drawn on the world map for the last 30 minutes. Also in the map's own filter menu.", function() Wanted.MapPins:Refresh() end)
	private.minimap = W:Switch(content, function(checked)
		Wanted.db.settings.minimap.hide = not checked
		Wanted.Minimap:Update()
	end)
	column:Row("Minimap button", private.minimap)
	private.Switch(column, Root, "showTools", "Show the Tools page", "Network details, test data and the debug log. Handy when reporting a problem; off by default.")
	private.Switch(column, Root, "sigBackground", "Check signatures in the background", "Bounties, claims and payments are signed by the players who make them. Wanted checks the ones you hold, one a second, never in a fight. Off: only the ones a page shows or reads.")

	column:Section("Kill proof")
	private.Switch(column, Root, "proofShots", "Take a proof screenshot when I kill a bounty target", "A stamp with who, where, when and the kill id goes on screen for a moment and the game saves a screenshot. Posters see that you have proof.")
	column:Note(format("If a kill is disputed, post the screenshot in %s on the Forever PvP Discord (click the link, Ctrl+C):", Wanted.Proof.DISCORD_CHANNEL))
	column.y = column.y - 4
	column:Add(W:CopyBox(content, 320, Wanted.Proof.DISCORD_URL), 32, 20)

	column:Section("Capture fronts")
	local Settings = function() return Wanted.Captures:Settings() end
	private.frontsShow = W:MultiSelect(content, 260, Options(FRONT_PLACES), function(key, checked)
		Settings()[key] = checked
		for _, place in ipairs(FRONT_PLACES) do
			if place[1] == key then
				place[4]()
			end
		end
		UI:Refresh()
	end)
	column:Row("Show capture fronts on", private.frontsShow)
	private.Switch(column, Settings, "alerts", "Warn about capture points near me", "When your side gathers at a point in your zone, or enemies are close while you stand in one; and the siege's rounds and Nexus falls while you're in its zone or have its map open.")
	private.Switch(column, Settings, "autoTrack", "Keep a waypoint on the nearest point to attack", "In a front's zone. Only ever replaces a waypoint Wanted set, never your own.", function() Wanted.Captures:AutoTrack() end)
	private.Switch(column, Settings, "siegeCall", "Siege call", "Half an hour before each night's siege and when it opens, wherever you are.")
	local Shard = function() return Wanted.Shard:Settings() end
	private.Switch(column, Shard, "host", "Host layer hops", "Invite Wanted players of your side who ask to hop onto your copy of the zone, whether or not you lead anything. While you lead a group or the rally you host anyway: the group follows your layer. Never while dead, in a fight, in an instance, in a full group, or in a raid you can't invite to. Hoppers leave your group twenty seconds later unless you lead the rally.")
	private.Switch(column, Shard, "accept", "Auto-accept my hops", "When you hop to the fight's layer, accept the invite from the player you asked by yourself. Off: the game's invite popup shows and you accept it.")
	private.Switch(column, Root, "siege", "Siege nights on this client (then /reload)", "Capture fronts, the HUD and map pieces, rally leaders and layer hops. Off until their first public siege night; a /reload applies the change.", function(checked)
		Wanted:Print("Siege nights %s. Type /reload to apply it.", checked and "on" or "off")
	end)
end




-- The window's look: the theme, one per poker felt (EllesmereUI's style over the felt), and the class icons
local SWATCH_COLUMNS, SWATCH_GAP = 5, 12
function private.BuildLook(panel, width)
	local card = private.Card(panel, 0, 262, "Window theme", width)
	local swatchWidth = floor((width - 32 - (SWATCH_COLUMNS - 1) * SWATCH_GAP) / SWATCH_COLUMNS)
	local swatchHeight = floor(swatchWidth * 0.58)
	private.swatches = {}
	for i, theme in ipairs(Theme.THEMES) do
		local swatch = CreateFrame("Button", nil, card)
		swatch:SetSize(swatchWidth, swatchHeight)
		local column, row = (i - 1) % SWATCH_COLUMNS, floor((i - 1) / SWATCH_COLUMNS)
		swatch:SetPoint("TOPLEFT", 16 + column * (swatchWidth + SWATCH_GAP), -38 - row * (swatchHeight + 30))
		swatch.art = swatch:CreateTexture(nil, "BACKGROUND")
		swatch.art:SetPoint("TOPLEFT", 1, -1)
		swatch.art:SetPoint("BOTTOMRIGHT", -1, 1)
		swatch.art:SetTexture(Theme:FeltFile(theme))
		local light = min(1, theme.shade * 1.6)
		swatch.art:SetVertexColor(light, light, light, 1)
		swatch.stripe = swatch:CreateTexture(nil, "ARTWORK")
		swatch.stripe:SetPoint("BOTTOMLEFT", 1, 1)
		swatch.stripe:SetPoint("BOTTOMRIGHT", -1, 1)
		swatch.stripe:SetHeight(4)
		swatch.stripe:SetColorTexture(theme.accent[1], theme.accent[2], theme.accent[3], 1)
		Theme:Border(swatch, C.border)
		swatch.name = Theme:Text(card, "small", theme.name, C.muted)
		swatch.name:SetPoint("TOP", swatch, "BOTTOM", 0, -5)
		swatch.key = theme.key
		swatch:SetScript("OnClick", function()
			Theme:Choose(theme.key)
			UI:PreviewTheme(theme.key)
			private.RefreshLook()
		end)
		swatch:SetScript("OnEnter", function(self) Theme:SetBorderColor(self, C.borderLight) end)
		swatch:SetScript("OnLeave", function() private.RefreshLook() end)
		tinsert(private.swatches, swatch)
	end
	private.lookNote = Theme:Text(card, "tiny", "", C.muted)
	private.lookNote:SetPoint("BOTTOMLEFT", 16, 16)
	local reload = W:Button(card, "Reload to apply", "secondary", 130, 24, function() ReloadUI() end)
	reload:SetPoint("BOTTOMRIGHT", -16, 10)
	private.lookReload = reload

	card = private.Card(panel, -274, 130, "Class icons", width)
	local previous = nil
	for _, style in ipairs(Theme.ICON_STYLES) do
		-- Styles marked hidden aren't offered: they look the same as Crest here
		if not style.hidden then
		local button = W:Button(card, "", "secondary", 58, 58, function()
			Wanted.db.settings.iconStyle = style.key
			private.Refresh()
			UI:Refresh()
			RefreshNearby()
		end)
		if previous then
			button:SetPoint("LEFT", previous, "RIGHT", 6, 0)
		else
			button:SetPoint("TOPLEFT", 16, -40)
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

---Borders the chosen theme and says whether a /reload is needed for its colours.
function private.RefreshLook()
	if not private.swatches then
		return
	end
	local chosen = Theme:Get(Wanted.db.settings.theme).key
	for _, swatch in ipairs(private.swatches) do
		Theme:SetBorderColor(swatch, swatch.key == chosen and C.accent or C.border)
		swatch.name:SetTextColor(unpack(swatch.key == chosen and C.white or C.muted))
	end
	local applied = Theme.current and Theme.current.key
	local pending = applied ~= chosen
	private.lookNote:SetText(pending and format("%s shows behind the window now. Reload to apply its colours.", Theme:Get(chosen).name)
		or "Your side's capital is the default until you pick one. The poker table's felt follows the theme.")
	private.lookReload:SetShown(pending)
end


function private.BuildStreaks(column)
	local content = column.content
	column:Section("Kill streaks")
	local callout = private.Switch(column, StreakSettings, "callout", "Show a callout for streaks and multi-kills", "Big text in the middle of the screen: Double kill and up for kills within 30 seconds of each other, Killing spree at 3 kills without dying, Unstoppable at 5, Legendary at 8.")
	W:Cog(callout, "Streak callout", function(popup)
		private.Toggle(popup, StreakSettings, "sound", "Play a sound with it", "The Kill on Sight alert sound. Quiet when alert sounds are off (Alerts tab) or muted from the Nearby window.", 14, -40)
		private.Refresh()
		return 74
	end)
	local hear = W:Button(content, "Show me", "chip", 80, 22, function()
		Wanted.Streaks:Preview()
	end)
	W:AttachTooltip(hear, "Show me", "A sample callout and its sound.")
	column:Row("Sample callout", hear)
	private.streakAnnounce = W:Segmented(content, {
		{ key = "none", label = "Nobody" },
		{ key = "party", label = "My party" },
		{ key = "guild", label = "My guild" },
	}, function(key)
		StreakSettings().announce = key
	end, 110)
	column:Row("Announce streaks to", private.streakAnnounce)
	column:Note("A line like \"Wanted: <you> is on a killing spree (3 kills)\", at most one every 10 seconds, only while you're in a party or guild. Never in public chat.")
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

-- Where else ranks show: { key, label, tooltip }
local RANK_PLACES = {
	{ "tooltip", "Tooltip", "A line like \"PvP rank: Rank 7, Blood Guard\" with the badge, when you mouse over a player." },
	{ "chat", "Chat", "[R7] at the start of what ranked players say, in your own chat windows. Off by default." },
	{ "nearby", "Nearby window", "R7 beside the level of ranked enemies." },
	{ "who", "Who list", "R7 beside ranked players' names." },
}

---A rank layout's cog popup: where, X and Y offsets and size, from the top; returns how far down it went.
local function LayoutControls(popup, width, getTable, choices, onAnchor)
	local Ranks = Wanted.Ranks
	local function Offset(value) return format("%+d", value) end
	local function Scale(value) return format("%.1fx", value) end
	local inner = width - 28
	local where = Theme:Text(popup, "small", "Where", C.muted)
	where:SetPoint("TOPLEFT", 14, -46)
	local anchor = W:Choice(popup, inner - 70, choices, function(key)
		getTable().anchor = key
		Ranks:Update()
		if onAnchor then
			onAnchor(key)
		end
	end)
	anchor:SetPoint("TOPLEFT", 84, -38)
	private.LayoutSlider(popup, getTable, "x", "X offset", -50, 50, 1, Offset, 14, -78, inner)
	private.LayoutSlider(popup, getTable, "y", "Y offset", -50, 50, 1, Offset, 14, -122, inner)
	private.LayoutSlider(popup, getTable, "scale", "Size", 0.6, 1.6, 0.1, Scale, 14, -166, inner)
	return anchor, -210
end

---A note at the foot of a cog popup; returns the popup's height.
local function PopupNote(popup, width, y, text)
	local note = Theme:Text(popup, "tiny", text)
	note:SetPoint("TOPLEFT", 14, y)
	note:SetWidth(width - 28)
	note:SetJustifyH("LEFT")
	note:SetWordWrap(true)
	return -y + note:GetStringHeight() + 14
end

function private.BuildRanks(column)
	local content = column.content
	-- Players' Blizzard PvP ranks (Ranks), as Wanted players' addons read them from the game, and the honor scout
	local function RankSettings() return Wanted.db.settings.ranks end
	local function Update() Wanted.Ranks:Update() end
	local function Plate() return Wanted.db.settings.ranks.plate end
	local function Target() return Wanted.db.settings.ranks.targetLabel end
	local Ranks = Wanted.Ranks
	local plateChoices, targetChoices = {}, {}
	for _, a in ipairs(Ranks.PLATE_ANCHORS) do tinsert(plateChoices, { key = a.key, label = a.label }) end
	for _, a in ipairs(Ranks.TARGET_ANCHORS) do tinsert(targetChoices, { key = a.key, label = a.label }) end

	column:Section("Blizzard PvP ranks of other players")
	local plates = private.Switch(column, RankSettings, "nameplates", "Rank on nameplates", "The rank's badge and number left of ranked players' names on nameplates. New plates follow the switch as they come up.", Update)
	W:Cog(plates, "Rank on nameplates", function(popup, width)
		local y
		private.plateAnchor, y = LayoutControls(popup, width, Plate, plateChoices)
		W:AttachTooltip(private.plateAnchor, "Where", "Centred over the plate, around the player's name, or on the top corners of the health bar.")
		private.Toggle(popup, Plate, "badge", "Show badge", "The rank's badge, the game's PvP rank insignia.", 14, y, Update)
		private.Toggle(popup, Plate, "number", "Show number", "The rank's number, after the badge.", 140, y, Update)
		private.Refresh()
		return PopupNote(popup, width, y - 32, "Changes show at once on the nameplates already up. Works with the game's nameplates, ElvUI and Plater.")
	end)
	local target = private.Switch(column, RankSettings, "target", "Rank over the target frame", "The rank and its title over your target's frame.", Update)
	W:Cog(target, "Rank at the target frame", function(popup, width)
		local y
		private.targetAnchor, y = LayoutControls(popup, width, Target, targetChoices)
		private.Refresh()
		return PopupNote(popup, width, y, "Your target's frame, or ElvUI's when it's loaded.")
	end)
	private.rankShow = W:MultiSelect(content, 260, Options(RANK_PLACES), function(key, checked)
		RankSettings()[key] = checked
		if key == "nearby" then
			RefreshNearby()
		end
		UI:Refresh()
	end)
	column:Row("Also show ranks in", private.rankShow)
	local function Root() return Wanted.db.settings end
	if Wanted.FEATURES.chatEmblems then
		private.Switch(column, Root, "signatureChat", "Emblems in chat", "The emblem a Wanted player picked on wanteddeadordead.com, before what they say in your chat windows.")
	end
	private.Switch(column, Root, "honorScout", "Read players' honorable kills", "When you target or mouse over a player, Wanted reads their lifetime honorable kills from the game (out of combat, a few seconds apart) for wanteddeadordead.com's Honorable Kills board.")
	column:Note("Blizzard's PvP ranks, as each Wanted player's addon reads their own from the game. Players without Wanted show none.")
end




-- ============================================================================
-- Page
-- ============================================================================

function private.BuildEmotes(column)
	local Emotes = Wanted.Emotes
	column:Section("Emote buttons")
	private.Switch(column, function() return Wanted.db.settings.emotes end, "enabled", "Show emote buttons in the Nearby window",
		"Favourites along the bottom of the Nearby window and a ... button with the rest. Each emotes at your target, even mid-fight.", RefreshNearby)
	-- The chips, under the row
	local card = CreateFrame("Frame", nil, column.content)
	card:SetWidth(column.width)
	private.emoteCount = Theme:Text(card, "small", "")
	private.emoteCount:SetPoint("TOPRIGHT", -16, -12)
	private.emoteCount:SetJustifyH("RIGHT")
	local legend = Theme:Text(card, "tiny", "Click an emote to change it:  "..Theme:Colorize("gold", C.accent).." = favourite (in the Nearby window, up to "
		..Emotes.MAX_FAVOURITES..")   outlined = in the ... list   faint = hidden")
	legend:SetPoint("TOPLEFT", 16, -14)
	local y = -38
	for _, group in ipairs(Emotes.GROUPS) do
		local heading = W:SectionLabel(card, group.label)
		heading:SetPoint("TOPLEFT", 16, y)
		y = y - 18
		local col = 0
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
				chip:SetPoint("TOPLEFT", 16 + col * (EMOTE_CHIP_WIDTH + 4), y)
				tinsert(private.emoteChips, chip)
				col = col + 1
				if col == EMOTE_COLUMNS then
					col = 0
					y = y - 26
				end
			end
		end
		y = y - (col > 0 and 26 or 0) - 6
	end
	local hint = Theme:Text(card, "tiny", "Changes show in the Nearby window straight away, or after combat if you're in one.")
	hint:SetPoint("TOPLEFT", 16, y - 2)
	card:SetHeight(-y + 20)
	column:Add(card)
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
	-- The rank layouts are in cog popups, built on first opening
	if private.plateAnchor then
		private.plateAnchor:SetChoice(Wanted.db.settings.ranks.plate.anchor)
	end
	if private.targetAnchor then
		private.targetAnchor:SetChoice(Wanted.db.settings.ranks.targetLabel.anchor)
	end
	private.nearbyShow:SetSelected(Selected(NearbyShow(), NEARBY_ITEMS))
	private.rankShow:SetSelected(Selected(Wanted.db.settings.ranks, RANK_PLACES))
	private.frontsShow:SetSelected(Selected(Wanted.Captures:Settings(), FRONT_PLACES))
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
	private.RefreshLook()
	for key, panel in pairs(private.panels) do
		panel:SetShown(key == private.view)
	end
end

UI:RegisterPage("settings", {
	group = "You",
	title = "Settings",
	subtitle = "Alerts, what the Nearby window shows, and what Wanted shares with other players.",
	order = 6,
	under = "card",
	tabLabel = "Settings",
	build = function(container, width, height)
		local tabs = W:Tabs(container, {
			{ key = "alerts", label = "Alerts" },
			{ key = "nearby", label = "Nearby window" },
			{ key = "sharing", label = "Sharing and display" },
			{ key = "streaks", label = "Kill streaks" },
			{ key = "ranks", label = "Ranks" },
			{ key = "emotes", label = "Emotes" },
			{ key = "look", label = "Theme" },
		}, function(key)
			private.view = key
			private.Refresh()
		end, 121)
		tabs:SetPoint("TOPLEFT")
		tabs:Select("alerts", true)
		private.tabs = tabs
		for _, key in ipairs({ "alerts", "nearby", "sharing", "streaks", "ranks", "emotes", "look" }) do
			local panel = CreateFrame("Frame", nil, container)
			panel:SetPoint("TOPLEFT", 0, -40)
			panel:SetSize(width, height - 40)
			panel:Hide()
			private.panels[key] = panel
		end
		-- One option per row, in a column that scrolls (the Alerts tab alone has 14)
		local function Column(key) return private.Column(private.panels[key], width, height - 40) end
		private.BuildAlerts(Column("alerts"))
		private.BuildNearby(Column("nearby"))
		private.BuildSharing(Column("sharing"))
		private.BuildStreaks(Column("streaks"))
		private.BuildRanks(Column("ranks"))
		private.BuildEmotes(Column("emotes"))
		private.BuildLook(private.panels.look, width)
	end,
	refresh = private.Refresh,
})

---Opens Settings on its Theme tab (the poker table's Felt button).
function UI:ShowThemeSettings()
	UI:Show("settings")
	if private.tabs then
		private.tabs:Select("look")
	end
end
