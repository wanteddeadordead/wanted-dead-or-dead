-- Wanted: the tours. "First steps" for a fresh install, in place of a welcome note, at the first login out of combat;
-- /wanted tour brings it back any time. Other addons register their own set (the poker addon's, the first time the
-- Poker page opens: /wanted poker tour). Each remembers the page it was closed on. A card beside the main
-- window, one stop a page: a heading, a short paragraph, Back / Next / Skip. The real page opens in the window behind
-- the card, and the part the page talks about gets a pulsing amber border (UI:Mark). Never in combat: it closes itself
-- when a fight starts and comes back after. After the last page, or Skip, the app prompt as the welcome gave it.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Tour = Wanted:NewModule("Tour")
local private = { frame = nil, glows = {}, ticker = nil, waitTicker = nil, resume = nil, set = "first", events = CreateFrame("Frame") }

local WIDTH, HEIGHT = 520, 330
local PAD = 20
local PULSE_SECONDS = 0.6
local GLOW_PAD = 6
local WAIT_SECONDS = 1

-- The sets of stops by name (Tour:Register): "first" is below. A stop may carry wait = function() -> boolean and
-- waitText: Next waits for it ("Host a table first")
Tour.SETS = {}

-- The stops: title, text; page = the window page to open; nearby = show the Nearby window too; mark = the UI:Mark
-- name(s) to border (nil: the whole page)
Tour.SETS.first = {
	label = "First steps",
	{ title = "Welcome to Wanted", page = "home", mark = "setup",
		text = "Wanted is world PvP between players who chose it: enemies near you, kills counted, bounties posted and hunted, daily races. Everything you see comes from other players' addons and the website.\n\n"
			.."Three things make it work in full, and the card bordered here says which you still need: the Wanted app on this computer, the Wanted Battle.net group, and enemy nameplates on." },
	{ title = "The lights", mark = { "app", "net" },
		text = "Two lights at the top of every page. App: green when the Wanted app runs on this computer, red when there is none. WantedNet: green when you're on your faction's hidden channel with the other Wanted players.\n\nA red light opens the page with the fix." },
	{ title = "Enemies", page = "enemies", nearby = true,
		text = "Wanted sees enemy players through their nameplates, out to 45 yards, and remembers everyone you've met: how often, who won, their guild, where they were last.\n\nThe Nearby window (open now) shows who's around you right now. Click an enemy anywhere for options: a bounty, a note, kill on sight." },
	{ title = "The Board", page = "board", mark = "post",
		text = "Bounties on enemy players. Post one on an enemy you've met, or hunt one someone else posted. Kill the target and the claim files itself; a witness confirms it; the poster pays by mail.\n\nYour bounties and your hunts have their own tabs here." },
	{ title = "Find the fight", page = "hotspots",
		text = "Hotspots: where enemy players are right now, from what you and other Wanted players have seen, busiest first. Each zone says which layer the fight is on when it's known." },
	{ title = "Raids", page = "raids",
		text = "Form a world PvP raid, or join one. Everyone with Wanted on your faction sees it, and the leader invites you. A raid can be announced to a chat channel from here." },
	{ title = "Progress", page = "challenges",
		text = "Daily and weekly goals for both factions, for fun and a weekly score. Kills in today's hot zones count double. The calendar has the site's events." },
	{ title = "You", page = "card",
		text = "Your calling card: the banner on your website page and on the death card of anyone you kill, with the art your badges unlock. The Wanted poster next to it shows the price the other faction has put on your head." },
	{ title = "Website & app", page = "web", mark = "yourpage",
		text = "The game can't open a browser, so every address is a box to copy: click it, Ctrl+C, paste. The box bordered here is your own page on wanteddeadordead.com.\n\nThe desktop app puts your kills on the website and keeps your saved data safe. Without it you still see enemies and bounties, but your records don't count." },
	{ title = "Settings", page = "settings", mark = "invite",
		text = "Alerts, what the Nearby window shows, and what Wanted shares with other players.\n\nThe Wanted Battle.net group is a data link, not a chat: through its members your addon learns which layer the other side is fighting on. Its invite is the box bordered here." },
	-- Guild Wars: where the site runs races its page tops the menu; before then these stops show the main page
	{ title = "Tonight's races", page = "guildwars", mark = "racetonight",
		text = "Every night there are three races, 45 minutes each, in zones picked the evening before. Each is open to everyone in its zone, Horde against Alliance. When the site runs races, Guild Wars sits at the top of the menu.\n\n"
			.."Tonight lists each race's start, its zone and both sides' influence. Tomorrow's zones are under them." },
	{ title = "Influence", page = "guildwars", mark = "racecard",
		text = "A race is won on influence. Kills on the other faction in the zone earn it, once a witness backs them, and so do minutes standing on the zone's three points. The middle point counts 20% more.\n\n"
			.."Influence is all a race gives: nothing is captured or owned. The site counts the result. Hover a number to see where it comes from." },
	{ title = "The race HUD", page = "guildwars",
		text = "In a race's zone while it runs, a small frame at the top of the screen shows the time left, both sides' influence, the three points in their holders' colours, and your own kills and minutes.\n\n"
			.."Your minutes count while you stand on a point and aren't mounted, stealthed or away. A line under the frame says when they don't." },
	{ title = "Live numbers", page = "guildwars", mark = "racecard",
		text = "During a race, the Wanted players of your side tell each other what they've counted, once a minute. Your side's influence then shows as live: a provisional count until the site's result.\n\n"
			.."The other side's number is the site's, as of your last /reload." },
	{ title = "Guild wars come after launch",
		text = "After a race, a guild on the side that doesn't hold the zone can declare war and siege the zone. That arrives after launch; until then the races are the whole of it.\n\n"
			.."That's the tour. /wanted tour brings it back. The menu has more: Poker, your guild's Kill on Sight list, your PvP rank and gear. Safety is at the foot of the menu." },
}
Tour.STOPS = Tour.SETS.first

---Registers a set of stops under a name (/wanted tour <name>; Tour:Start(name)).
---@param name string
---@param stops table its label, and the stops
function Tour:Register(name, stops)
	Tour.SETS[name] = stops
end

---Whether the tour is open.
---@return boolean
function Tour:IsShown()
	return private.frame ~= nil and private.frame:IsShown()
end

---A set's saved state: { seen, page, done }. The first steps' lives at db.tour itself (as it shipped), the others
---under db.tour[name].
---@param name string
function private.State(name)
	local db = Wanted.db
	if not db then
		return {}
	end
	db.tour = type(db.tour) == "table" and db.tour or {}
	if name == "first" then
		return db.tour
	end
	db.tour[name] = type(db.tour[name]) == "table" and db.tour[name] or {}
	return db.tour[name]
end

---Whether a set has been opened before.
---@param name string
---@return boolean
function Tour:Seen(name)
	return private.State(name).seen == true
end

---Opens a set at a page (default: the page it was closed on, else the first). Not in a fight.
---@param name string|number? the set ("first" when left out), or the first steps' page
---@param page number?
function Tour:Start(name, page)
	if type(name) == "number" then
		name, page = "first", name
	end
	name = (name and Tour.SETS[name]) and name or "first"
	if Wanted:InCombat() then
		return
	end
	local stops, state = Tour.SETS[name], private.State(name)
	page = tonumber(page) or state.page or 1
	page = max(1, min(#stops, page))
	local f = private.frame or private.Create()
	private.set = name
	state.seen = true
	private.Go(page)
	f:Show()
end

---Closes the tour, remembering the page.
---@param done boolean? the last page was finished, or the tour skipped: the app prompt follows, as after the welcome
function Tour:Close(done)
	local f = private.frame
	if not f then
		return
	end
	f:Hide()
	private.Unmark()
	if done then
		local state = private.State(private.set)
		state.done, state.page = true, nil
		if private.set == "first" then
			Wanted:PromptForApp()
		end
	end
end

---Shows a page: the window's page behind, the marks bordered, the text and the buttons.
function private.Go(page)
	local f, stops = private.frame, Tour.SETS[private.set]
	local stop = stops[page]
	private.page = page
	private.State(private.set).page = page
	f.counter:SetText(format("%s · %d of %d", stops.label, page, #stops))
	f.title:SetText(stop.title)
	f.body:SetText(stop.text)
	f.back:SetEnabled(page > 1)
	if stop.page then
		UI:Show(stop.page)
	end
	if stop.nearby and Wanted.NearbyWindow and not Wanted.NearbyWindow:IsShown() then
		Wanted.NearbyWindow:Toggle()
	end
	private.Mark(stop.mark)
	private.Wait(stop)
end

---Next waits for a stop's condition (stop.wait), saying so on the button, and looks again every WAIT_SECONDS.
function private.Wait(stop)
	local f, stops = private.frame, Tour.SETS[private.set]
	if private.waitTicker then
		private.waitTicker:Cancel()
		private.waitTicker = nil
	end
	local last = private.page == #stops
	local function Check()
		local ready = not stop.wait or stop.wait() == true
		f.next:SetEnabled(ready)
		f.next:SetText(ready and (last and "Finish" or "Next") or (stop.waitText or "Not yet"))
		return ready
	end
	if not Check() and C_Timer and C_Timer.NewTicker then
		private.waitTicker = C_Timer.NewTicker(WAIT_SECONDS, function()
			if Check() and private.waitTicker then
				private.waitTicker:Cancel()
				private.waitTicker = nil
				-- What was waited for appeared (the table window): border afresh, so nothing gone stays marked
				private.Mark(stop.mark)
			end
		end)
	end
end

---Borders the named marks (UI:Mark) with a pulsing amber frame each; none: nothing bordered.
function private.Unmark()
	for _, glow in ipairs(private.glows) do
		glow:Hide()
	end
	if private.ticker then
		private.ticker:Cancel()
		private.ticker = nil
	end
end

function private.Mark(names)
	private.Unmark()
	if not names then
		return
	end
	if type(names) == "string" then
		names = { names }
	end
	local shown = 0
	for i, name in ipairs(names) do
		local target = UI:MarkFrame(name)
		-- Only what's on screen: a frame on a hidden tab or page has a place but nothing to see there
		if target and (not target.IsVisible or target:IsVisible()) then
			local glow = private.glows[i]
			if not glow then
				glow = CreateFrame("Frame", nil, UIParent)
				Theme:Border(glow, C.amber)
				private.glows[i] = glow
			end
			-- A child of what it borders (a text's frame for a text), so it hides with it and sits on its layer: a
			-- free border stayed where the host form had been, over the table window (2026-10-17)
			local holder = target.GetStringWidth and target:GetParent() or target
			glow:SetParent(holder)
			glow:SetFrameLevel(holder:GetFrameLevel() + 20)
			glow:ClearAllPoints()
			glow:SetPoint("TOPLEFT", target, "TOPLEFT", -GLOW_PAD, GLOW_PAD)
			glow:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", GLOW_PAD, -GLOW_PAD)
			glow:SetAlpha(1)
			glow:Show()
			shown = shown + 1
		end
	end
	if shown > 0 and C_Timer and C_Timer.NewTicker then
		local bright = true
		private.ticker = C_Timer.NewTicker(PULSE_SECONDS, function()
			bright = not bright
			for _, glow in ipairs(private.glows) do
				glow:SetAlpha(bright and 1 or 0.35)
			end
		end)
	end
end

---The card, beside the main window.
function private.Create()
	local f = CreateFrame("Frame", "WantedTourFrame", UIParent)
	f:SetSize(WIDTH, HEIGHT)
	f:SetFrameStrata("FULLSCREEN_DIALOG")
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	if f.RegisterForDrag then
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", function(self) self:StartMoving() end)
		f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
	end
	Theme:Skin(f, C.panelSolid, C.borderLight)
	f.counter = Theme:Text(f, "small", "", C.muted)
	f.counter:SetPoint("TOPLEFT", PAD, -16)
	f.title = Theme:Text(f, "title", "", C.gold)
	f.title:SetPoint("TOPLEFT", PAD, -36)
	f.title:SetWidth(WIDTH - 2 * PAD)
	f.body = Theme:Text(f, "body", "")
	f.body:SetPoint("TOPLEFT", PAD, -70)
	f.body:SetWidth(WIDTH - 2 * PAD)
	f.body:SetJustifyH("LEFT")
	f.body:SetWordWrap(true)
	f.body:SetSpacing(3)
	f.skip = W:Button(f, "Skip the tour", "chip", 110, 24, function() Tour:Close(true) end)
	f.skip:SetPoint("BOTTOMLEFT", PAD, 16)
	f.next = W:Button(f, "Next", "primary", 150, 26, function()
		if private.page >= #Tour.SETS[private.set] then
			Tour:Close(true)
		else
			private.Go(private.page + 1)
		end
	end)
	f.next:SetPoint("BOTTOMRIGHT", -PAD, 16)
	f.back = W:Button(f, "Back", "secondary", 90, 26, function()
		if private.page > 1 then
			private.Go(private.page - 1)
		end
	end)
	f.back:SetPoint("RIGHT", f.next, "LEFT", -8, 0)
	f.close = W:Button(f, "X", "chip", 24, 22, function() Tour:Close() end)
	f.close:SetPoint("TOPRIGHT", -10, -10)
	f:SetScript("OnShow", function() private.Place() end)
	f:SetScript("OnHide", function()
		private.Unmark()
		if private.waitTicker then
			private.waitTicker:Cancel()
			private.waitTicker = nil
		end
	end)
	f:Hide()
	private.frame = f
	return f
end

---Beside the main window, to its right; the screen's clamp keeps it on when there's no room.
function private.Place()
	local f, main = private.frame, UI:GetFrame()
	f:ClearAllPoints()
	if main then
		f:SetPoint("TOPLEFT", main, "TOPRIGHT", 12, 0)
	else
		f:SetPoint("CENTER")
	end
end

-- A fight closes it; the end of the fight brings it back where it was
private.events:RegisterEvent("PLAYER_REGEN_DISABLED")
private.events:SetScript("OnEvent", function()
	if Tour:IsShown() then
		private.resume = private.set
		Tour:Close()
	end
end)
Wanted:OnCombatEnd(function()
	if private.resume then
		local set = private.resume
		private.resume = nil
		Tour:Start(set)
	end
end)

Wanted:RegisterCommand("tour", "First steps, a tour of Wanted page by page: /wanted tour; the poker table's: /wanted poker tour", function(args)
	local name = strtrim(args or "")
	Tour:Start(name ~= "" and name or "first")
end)
