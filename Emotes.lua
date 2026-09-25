-- Wanted: emote buttons. A row of favourites in the Nearby window and a pop-out with every emote, grouped,
-- each one clicking an emote at your target the way typing /lol would. They're macro buttons with a fixed
-- macro, so they keep working in combat, and the pop-out opens and closes through a secure handler (the way
-- the game's own action bar flyouts do), so it opens mid-fight too. Which emotes are favourites, in the
-- list, or hidden is set in Settings > Emotes.

local _, Wanted = ...
local Emotes = Wanted:NewModule("Emotes")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local private = {
	flyout = nil,
	flyoutButtons = {},
}
Emotes.MAX_FAVOURITES = 7
local BUTTON_HEIGHT = 20
local FLYOUT_COLUMNS = 5
local FLYOUT_BUTTON_WIDTH = 74
local FLYOUT_PAD = 10

Emotes.GROUPS = {
	{ key = "taunt", label = "Taunts" },
	{ key = "kill", label = "After a kill" },
	{ key = "lose", label = "Losing" },
	{ key = "voice", label = "Mid-fight" },
}

-- Every emote, in the order they show: key, label, slash command, group
Emotes.LIST = {
	{ "lol", "LOL", "/lol", "taunt" },
	{ "rofl", "ROFL", "/rofl", "taunt" },
	{ "cackle", "Cackle", "/cackle", "taunt" },
	{ "guffaw", "Guffaw", "/guffaw", "taunt" },
	{ "snicker", "Snicker", "/snicker", "taunt" },
	{ "flex", "Flex", "/flex", "taunt" },
	{ "gloat", "Gloat", "/gloat", "taunt" },
	{ "mock", "Mock", "/mock", "taunt" },
	{ "rude", "Rude", "/rude", "taunt" },
	{ "spit", "Spit", "/spit", "taunt" },
	{ "chicken", "Chicken", "/chicken", "taunt" },
	{ "train", "Train", "/train", "taunt" },
	{ "moon", "Moon", "/moon", "taunt" },
	{ "fart", "Fart", "/fart", "taunt" },
	{ "burp", "Burp", "/burp", "taunt" },
	{ "violin", "Violin", "/violin", "taunt" },
	{ "golfclap", "Golf clap", "/golfclap", "taunt" },
	{ "pity", "Pity", "/pity", "taunt" },
	{ "bored", "Bored", "/bored", "taunt" },
	{ "yawn", "Yawn", "/yawn", "taunt" },
	{ "doom", "Doom", "/doom", "taunt" },
	{ "threaten", "Threaten", "/threaten", "taunt" },
	{ "taunt", "Taunt", "/taunt", "taunt" },
	{ "roar", "Roar", "/roar", "taunt" },
	{ "charge", "Charge", "/charge", "taunt" },
	{ "victory", "Victory", "/victory", "kill" },
	{ "cheer", "Cheer", "/cheer", "kill" },
	{ "bow", "Bow", "/bow", "kill" },
	{ "salute", "Salute", "/salute", "kill" },
	{ "dance", "Dance", "/dance", "kill" },
	{ "bye", "Bye", "/bye", "kill" },
	{ "wave", "Wave", "/wave", "kill" },
	{ "shoo", "Shoo", "/shoo", "kill" },
	{ "cower", "Cower", "/cower", "lose" },
	{ "flee", "Flee", "/flee", "lose" },
	{ "sorry", "Sorry", "/sorry", "lose" },
	{ "oops", "Oops", "/oops", "lose" },
	{ "facepalm", "Facepalm", "/facepalm", "lose" },
	{ "cry", "Cry", "/cry", "lose" },
	{ "surrender", "Surrender", "/surrender", "lose" },
	{ "helpme", "Help me", "/helpme", "voice" },
	{ "incoming", "Incoming", "/incoming", "voice" },
	{ "attack", "Attack", "/attacktarget", "voice" },
	{ "openfire", "Open fire", "/openfire", "voice" },
	{ "oom", "OOM", "/oom", "voice" },
	{ "retreat", "Retreat", "/retreat", "voice" },
}



-- ============================================================================
-- Settings
-- ============================================================================

function private.Settings()
	return Wanted.db.settings.emotes
end

---"fav" (in the Nearby window's row), "list" (only in the pop-out) or "hidden". Anything not set is in the list.
---@param key string
---@return string
function Emotes:GetState(key)
	return private.Settings().state[key] or "list"
end

---Moves an emote along: favourite, in the list, hidden, favourite again. A favourite past the limit is
---skipped to the list. Returns the new state.
---@param key string
---@return string
function Emotes:CycleState(key)
	local state = Emotes:GetState(key)
	local nextState = state == "fav" and "list" or state == "list" and "hidden" or "fav"
	if nextState == "fav" and #Emotes:GetFavourites() >= Emotes.MAX_FAVOURITES then
		nextState = "list"
	end
	private.Settings().state[key] = nextState
	return nextState
end

function Emotes:IsEnabled()
	return private.Settings().enabled
end

---The favourite emotes, in list order, at most MAX_FAVOURITES.
---@return table[] { key, label, command, group }
function Emotes:GetFavourites()
	local favourites = {}
	for _, def in ipairs(Emotes.LIST) do
		if Emotes:GetState(def[1]) == "fav" and #favourites < Emotes.MAX_FAVOURITES then
			tinsert(favourites, def)
		end
	end
	return favourites
end

---How many emotes are favourites and in the list (not hidden).
function Emotes:CountShown()
	local favourites, listed = 0, 0
	for _, def in ipairs(Emotes.LIST) do
		local state = Emotes:GetState(def[1])
		if state == "fav" then
			favourites = favourites + 1
		elseif state == "list" then
			listed = listed + 1
		end
	end
	return favourites, listed
end



-- ============================================================================
-- Buttons
-- ============================================================================

---A button that runs one emote's macro at your target; works in combat. Its emote can only be changed out of
---combat (Emotes:SetButtonEmote).
---@param parent table
---@param width number
function Emotes:CreateButton(parent, width)
	local button = W:Button(parent, "", "chip", width, BUTTON_HEIGHT, nil, "SecureActionButtonTemplate")
	button.label:SetFontObject(Theme.Fonts.small)
	-- Act on release whatever "cast on key down" says, as the Nearby rows do
	button:RegisterForClicks("AnyUp")
	button:SetAttribute("useOnKeyDown", false)
	button:SetAttribute("type1", "macro")
	button:SetAttribute("macrotext1", "")
	return button
end

---Points a button at an emote (out of combat only).
---@param button table
---@param def table? { key, label, command, group }
function Emotes:SetButtonEmote(button, def)
	button.def = def
	button:SetText(def and def[2] or "")
	button:SetAttribute("macrotext1", def and def[3] or "")
	W:AttachTooltip(button, def and def[2] or "", def and (def[3].." at your target, or on its own with nothing targeted.") or "")
end

Emotes.BUTTON_HEIGHT = BUTTON_HEIGHT



-- ============================================================================
-- The pop-out
-- ============================================================================

---The "..." button that opens the pop-out of every emote, and the pop-out itself, anchored beside the given
---window. Both open and close through a secure handler, so it works in combat.
---@param parent table the Nearby window
---@param width number
---@return table button
function Emotes:CreateMoreButton(parent, width)
	local flyout = private.GetFlyout(parent)
	local button = W:Button(parent, "...", "chip", width, BUTTON_HEIGHT, nil, "SecureHandlerClickTemplate")
	W:AttachTooltip(button, "All emotes", "Every emote you haven't hidden, grouped. Opens mid-fight too. Choose favourites in Settings > Emotes.")
	button:SetFrameRef("flyout", flyout)
	button:SetAttribute("_onclick", [=[
		local flyout = self:GetFrameRef("flyout")
		if flyout:IsShown() then
			flyout:Hide()
		else
			flyout:Show()
		end
	]=])
	return button
end

function private.GetFlyout(parent)
	if private.flyout then
		return private.flyout
	end
	local flyout = CreateFrame("Frame", "WantedEmoteFlyout", parent, "SecureFrameTemplate")
	flyout:SetFrameStrata("DIALOG")
	flyout:SetPoint("BOTTOMLEFT", parent, "BOTTOMRIGHT", 4, 0)
	Theme:Skin(flyout, C.bg, C.border)
	flyout:EnableMouse(true)
	flyout:Hide()
	-- Out of combat, an emote from the list closes it; in combat it stays open until "..." is clicked again
	flyout.headings = {}
	private.flyout = flyout
	return flyout
end

---Lays the pop-out out again for the emotes not hidden (out of combat only).
function Emotes:LayoutFlyout()
	local flyout = private.flyout
	if not flyout or InCombatLockdown() then
		return
	end
	for _, button in ipairs(private.flyoutButtons) do
		button:Hide()
	end
	for _, heading in ipairs(flyout.headings) do
		heading:Hide()
	end
	local y = -FLYOUT_PAD
	local used, headingsUsed = 0, 0
	for _, group in ipairs(Emotes.GROUPS) do
		local column, inGroup = 0, 0
		for _, def in ipairs(Emotes.LIST) do
			if def[4] == group.key and Emotes:GetState(def[1]) ~= "hidden" then
				inGroup = inGroup + 1
				if inGroup == 1 then
					headingsUsed = headingsUsed + 1
					local heading = flyout.headings[headingsUsed]
					if not heading then
						heading = W:SectionLabel(flyout, "")
						flyout.headings[headingsUsed] = heading
					end
					heading:SetText(group.label)
					heading:ClearAllPoints()
					heading:SetPoint("TOPLEFT", FLYOUT_PAD, y)
					heading:Show()
					y = y - 16
				end
				used = used + 1
				local button = private.flyoutButtons[used]
				if not button then
					button = Emotes:CreateButton(flyout, FLYOUT_BUTTON_WIDTH)
					button:HookScript("OnClick", function()
						if not InCombatLockdown() then
							flyout:Hide()
						end
					end)
					private.flyoutButtons[used] = button
				end
				Emotes:SetButtonEmote(button, def)
				button:ClearAllPoints()
				button:SetPoint("TOPLEFT", FLYOUT_PAD + column * (FLYOUT_BUTTON_WIDTH + 4), y)
				button:Show()
				column = column + 1
				if column == FLYOUT_COLUMNS then
					column = 0
					y = y - (BUTTON_HEIGHT + 4)
				end
			end
		end
		if column > 0 then
			y = y - (BUTTON_HEIGHT + 4)
		end
		if inGroup > 0 then
			y = y - 4 -- a little space before the next group's heading
		end
	end
	flyout:SetSize(FLYOUT_PAD * 2 + FLYOUT_COLUMNS * (FLYOUT_BUTTON_WIDTH + 4) - 4, -y + FLYOUT_PAD - 4)
end

function Emotes:HideFlyout()
	if private.flyout and not InCombatLockdown() then
		private.flyout:Hide()
	end
end

function Emotes:IsFlyoutShown()
	return private.flyout ~= nil and private.flyout:IsShown()
end



-- ============================================================================
-- The one-time tip
-- ============================================================================

---The first time the emote row shows, out of combat and with no other dialog up: what it is and how to turn
---it off.
function Emotes:MaybeTip()
	local settings = private.Settings()
	if settings.tipShown or not settings.enabled or InCombatLockdown() or W:IsDialogShown() then
		return
	end
	settings.tipShown = true
	W:Dialog({
		title = "Emote buttons",
		text = "The buttons at the bottom of the Nearby window /lol, /flex, /doom and more at your target, even mid-fight. The ... button opens every emote.\n\nChoose your favourites, or turn them all off, in Settings > Emotes.",
		cancelLabel = "Turn off",
		confirmLabel = "Keep them",
		onCancel = function()
			settings.enabled = false
			if Wanted.NearbyWindow then
				Wanted.NearbyWindow:ForceLayout()
			end
		end,
	})
end
