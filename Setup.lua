-- Wanted: the setup checklist. The four steps a player needs for Wanted to work in full, each with a green check or a
-- red X (amber for "nearly") and how to fix it: the addon up to date, the Wanted app running, the Wanted Battle.net
-- group joined, and enemy nameplates on (Wanted sees enemies through them). A feature toggle
-- is not setup and isn't listed (2026-10-17). The Dashboard shows one line of marks, each with its detail and fix as
-- its tooltip (click for the Website & app page); the Website & app page shows every step with its address to copy;
-- /wanted setup prints them.

local _, Wanted = ...
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Setup = Wanted:NewModule("Setup")
local private = {}
-- The cards built (Setup:BuildCard), by page: "home" (brief) and "web"
Setup.cards = {}

local SITE = "https://wanteddeadordead.com"
local PAD = 16
local ICON = 16
local ICONS = {
	ok = "Interface\\RaidFrame\\ReadyCheck-Ready",
	bad = "Interface\\RaidFrame\\ReadyCheck-NotReady",
	warn = "Interface\\RaidFrame\\ReadyCheck-Waiting",
	off = "Interface\\RaidFrame\\ReadyCheck-Waiting",
}
local COLORS = { ok = C.green, bad = C.red, warn = C.amber, off = C.faint }
-- The full card's step bar: each step's name, and what a dot's state reads under it
local BAR_STEPS = { "Addon up to date", "Wanted app running", "In the group", "Enemy nameplates" }
local BAR_NOTES = { bad = "Not yet", warn = "Nearly" }
local WORDS = { ok = "ok", bad = "NO", warn = "nearly", off = "off" }

---The steps, in order: { key, title, short (for the one-line card), state ("ok", "bad", "warn", "off"), detail, fix?, url?, cvar? }.
---@return table[]
function Setup:Steps()
	local steps = {}
	local newer = Wanted.newerVersion
	steps[1] = {
		key = "addon", title = "Addon up to date", short = "Addon current", state = newer and "bad" or "ok",
		detail = newer and format("Version %s is out, you have %s.", tostring(newer), tostring(Wanted.VERSION)) or format("Version %s.", tostring(Wanted.VERSION)),
		fix = newer and "Update from CurseForge or the Wanted app, then restart the game." or nil,
		url = newer and SITE.."/addon" or nil,
	}
	local app, notRunning = Wanted:AppVersion(), Wanted:AppNotRunningFor()
	if app and notRunning then
		steps[2] = { key = "app", title = "Wanted app running", short = "App running", state = "warn",
			detail = format("Set up here (version %s), but it last ran %s ago.", app, Theme:Ago(notRunning)),
			fix = "Start it: Wanted Dead or Dead in the Start menu, or Wanted in Applications on a Mac." }
	elseif app then
		steps[2] = { key = "app", title = "Wanted app running", short = "App running", state = "ok", detail = format("Version %s.", app) }
	else
		steps[2] = { key = "app", title = "Wanted app running", short = "App running", state = "bad",
			detail = "No Wanted app on this computer: your kills don't reach the website and the fight layer doesn't reach you.",
			fix = "Get it, start it, then /reload.", url = SITE.."/app" }
	end
	local inGroup = Wanted.Bridge ~= nil and Wanted.Bridge:InCommunity()
	steps[3] = { key = "group", title = "In the Wanted Battle.net group", short = "In the group", state = inGroup and "ok" or "bad",
		detail = inGroup and "Both sides, one layer: your addon trades the fight layer with the other side's through it, as data." or "Horde and Alliance can't talk in game; through the group your addon learns which layer the other side is fighting on, as data, not chat.",
		fix = (not inGroup) and "Join it (members can see each other's BattleTag):" or nil,
		url = (not inGroup) and Wanted.Bridge and Wanted.Bridge.INVITE_URL or nil }
	local plates = GetCVar and GetCVar("nameplateShowEnemies")
	local on = plates == "1" or plates == 1 or plates == true
	steps[4] = { key = "nameplates", title = "Enemy nameplates on", short = "Enemy plates", state = on and "ok" or "bad",
		detail = on and "Wanted sees enemies through them, out to 45 yards." or "Wanted sees enemies through their nameplates; with them off, only what you target or mouse over.",
		fix = (not on) and "Press V, or Interface > Names > Enemy Players." or nil,
		cvar = (not on) and "nameplateShowEnemies" or nil }
	return steps
end

---Whether nothing is red or amber.
---@param steps table[]?
---@return boolean
function Setup:AllSet(steps)
	for _, step in ipairs(steps or Setup:Steps()) do
		if step.state == "bad" or step.state == "warn" then
			return false
		end
	end
	return true
end

---A card of the steps. card.Refresh() lays it out for the current state and returns its height. brief: one line of
---the four marks, each explaining its step and fix on hover (the Dashboard); otherwise every step with its detail,
---and its address in a box to copy or a button to turn it on (the Website & app page).
---@param parent table
---@param width number
---@param brief boolean?
---@param onClick function? the card opens something when brief
---@return table card
function Setup:BuildCard(parent, width, brief, onClick)
	local card = brief and onClick and W:CardButton(parent, onClick) or W:Card(parent)
	card:SetWidth(width)
	card.label = W:SectionLabel(card, "Your setup")
	card.label:SetPoint("TOPLEFT", PAD, -14)
	card.rows = {}
	-- The Website & app page: the steps on the guild-war step bar, the first unset one's fix under it
	if not brief then
		card.bar = W:StepBar(card, width - 2 * PAD, BAR_STEPS)
		card.bar:SetPoint("TOPLEFT", PAD, -34)
		card.fix = Theme:Text(card, "small", "", C.text)
		card.fix:SetJustifyH("LEFT")
		card.fix:SetWordWrap(true)
		card.fix:SetWidth(width - 2 * PAD)
	end
	for i = 1, 4 do
		local row = {}
		row.icon = card:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(ICON, ICON)
		row.name = Theme:Text(card, "small", "")
		-- The brief card's mark and name, explained on hover; clicks go through to the card
		row.hit = CreateFrame("Button", nil, card)
		row.hit:SetMouseClickEnabled(false)
		row.hit:Hide()
		row.title = Theme:Text(card, "body", "", C.text)
		row.detail = Theme:Text(card, "small", "", C.muted)
		row.detail:SetJustifyH("LEFT")
		row.detail:SetWordWrap(true)
		row.box = W:CopyBox(card, width - 2 * PAD - ICON - 8, "")
		row.button = W:Button(card, "Turn on", "secondary", 90, 22, function()
			if row.cvar and SetCVar then
				SetCVar(row.cvar, "1")
				card.Refresh()
			end
		end)
		card.rows[i] = row
	end
	card.Refresh = function() return private.Layout(card, width, brief) end
	Setup.cards[brief and "home" or "web"] = card
	return card
end

---Lays the card out (Setup:BuildCard) and returns its height.
function private.Layout(card, width, brief)
	local steps = Setup:Steps()
	local allSet = Setup:AllSet(steps)
	card.label:SetText(allSet and "Your setup: all set" or "Your setup")
	local y = -34
	if brief then
		-- One line of marks, each step a fifth of the width
		local column = (width - 2 * PAD) / #steps
		for i, step in ipairs(steps) do
			local row = card.rows[i]
			local x = PAD + (i - 1) * column
			row.icon:ClearAllPoints()
			row.icon:SetPoint("TOPLEFT", x, y)
			row.icon:SetTexture(ICONS[step.state])
			row.icon:SetAlpha(step.state == "off" and 0.5 or 1)
			row.name:SetText(step.short) -- the title is too long for a fifth of the card (2026-10-17: "In the Wanted Batt...")
			row.name:SetTextColor(COLORS[step.state][1], COLORS[step.state][2], COLORS[step.state][3])
			row.name:ClearAllPoints()
			row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
			row.name:SetWidth(column - ICON - 8)
			row.name:Show()
			row.hit:ClearAllPoints()
			row.hit:SetPoint("TOPLEFT", row.icon, "TOPLEFT")
			row.hit:SetSize(ICON + 4 + row.name:GetStringWidth(), ICON)
			row.hit:Show()
			W:Explain(row.hit, step.title, step.fix and step.detail.."\n\n"
				..Theme:Colorize(step.fix..(step.url and " "..step.url:gsub("^https://", "") or ""), C.gold) or step.detail)
			row.title:Hide()
			row.box:Hide()
			row.button:Hide()
			row.detail:Hide()
		end
		y = y - ICON - 8
		card:SetHeight(-y + PAD - 8)
		return card:GetHeight()
	end
	-- The step bar: steps set ticked, red ones crossed, the first one not set ringed; each dot's tooltip its detail and fix
	local current, failed, done, notes = #steps + 1, {}, {}, {}
	for i, step in ipairs(steps) do
		if step.state ~= "ok" and current > #steps then
			current = i
		end
		failed[i] = step.state == "bad" or nil
		done[i] = step.state == "ok" or nil
		notes[i] = BAR_NOTES[step.state] or ""
	end
	card.bar:Set(current, notes, failed, done)
	for i, step in ipairs(steps) do
		W:Explain(card.bar.dots[i], step.title, step.fix and step.detail.."\n\n"..step.fix or step.detail)
		local row = card.rows[i]
		row.name:Hide()
		row.hit:Hide()
		row.icon:Hide()
		row.title:Hide()
		row.detail:Hide()
		row.box:Hide()
		row.button:Hide()
	end
	y = y - 64 - 6
	-- What to do about the first step not set, with its address to copy or the button that sets it
	local step = steps[current]
	card.fix:SetShown(step ~= nil)
	if step then
		local row = card.rows[current]
		card.fix:SetText(step.title..": "..(step.fix or step.detail))
		card.fix:ClearAllPoints()
		card.fix:SetPoint("TOPLEFT", PAD, y)
		y = y - card.fix:GetStringHeight() - 6
		row.cvar = step.cvar
		if step.url then
			row.box:SetText(step.url)
			row.box:ClearAllPoints()
			row.box:SetPoint("TOPLEFT", PAD, y)
			row.box:Show()
			y = y - 28 - 4
		end
		if step.cvar then
			row.button:ClearAllPoints()
			row.button:SetPoint("TOPLEFT", PAD, y)
			row.button:Show()
			y = y - 22 - 4
		end
	end
	card:SetHeight(-y + PAD - 8)
	return card:GetHeight()
end

Wanted:RegisterCommand("setup", "Your setup, step by step, with what to fix: /wanted setup", function()
	local steps = Setup:Steps()
	Wanted:Print(Setup:AllSet(steps) and "Your setup: all set." or "Your setup:")
	for _, step in ipairs(steps) do
		Wanted:Print("  [%s] %s. %s%s%s", WORDS[step.state], step.title, step.detail, step.fix and " "..step.fix or "", step.url and " "..step.url or "")
	end
end)
