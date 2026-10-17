-- Wanted: the first-run tour, "First steps". A fresh install gets it in place of a welcome note, at the first login out
-- of combat; /wanted tour brings it back any time, and remembers the page it was closed on. A card beside the main
-- window, one stop a page: a heading, a short paragraph, Back / Next / Skip. The real page opens in the window behind
-- the card, and the part the page talks about gets a pulsing amber border (UI:Mark). Never in combat: it closes itself
-- when a fight starts and comes back after. After the last page, or Skip, the app prompt as the welcome gave it.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Tour = Wanted:NewModule("Tour")
local private = { frame = nil, glows = {}, ticker = nil, resume = false, events = CreateFrame("Frame") }

local WIDTH, HEIGHT = 520, 330
local PAD = 20
local PULSE_SECONDS = 0.6
local GLOW_PAD = 6

-- The stops: title, text; page = the window page to open; nearby = show the Nearby window too; mark = the UI:Mark
-- name(s) to border (nil: the whole page)
Tour.STOPS = {
	{ title = "Welcome to Wanted", page = "home", mark = "setup",
		text = "Wanted is world PvP between players who chose it: enemies near you, kills counted, bounties posted and hunted, siege nights. Everything you see comes from other players' addons and the website.\n\n"
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
		text = "Daily and weekly goals for both factions, for fun and a weekly score. Kills in today's hot zones count double. The calendar has the siege nights and the site's events." },
	{ title = "You", page = "card",
		text = "Your calling card: the banner on your website page and on the death card of anyone you kill, with the art your badges unlock. The Wanted poster next to it shows the price the other faction has put on your head." },
	{ title = "Website & app", page = "web", mark = "yourpage",
		text = "The game can't open a browser, so every address is a box to copy: click it, Ctrl+C, paste. The box bordered here is your own page on wanteddeadordead.com.\n\nThe desktop app puts your kills on the website and keeps your saved data safe. Without it you still see enemies and bounties, but your records don't count." },
	{ title = "Settings", page = "settings", mark = "invite",
		text = "Alerts, what the Nearby window shows, and what Wanted shares with other players.\n\nThe Wanted Battle.net group is a data link, not a chat: through its members your addon learns which layer the other side is fighting on. Its invite is the box bordered here." },
	{ title = "Siege nights", page = "siege",
		text = "Every evening one front is the siege front: three lanes of towers and inhibitors between two Nexus, fought on one layer, 7 to 10 PM US Eastern. The siege features ship switched off until the first public night (Settings > Capture fronts).\n\nThat's the tour. /wanted tour brings it back. The menu has more: Poker, your guild's Kill on Sight list, your PvP rank and gear. Safety is at the foot of the menu." },
}

---Whether the tour is open.
---@return boolean
function Tour:IsShown()
	return private.frame ~= nil and private.frame:IsShown()
end

---The saved state: { seen, page, done }.
function private.State()
	local db = Wanted.db
	if not db then
		return {}
	end
	db.tour = type(db.tour) == "table" and db.tour or {}
	return db.tour
end

---Opens the tour at a page (default: the page it was closed on, else the first).
---@param page number?
function Tour:Start(page)
	local state = private.State()
	page = tonumber(page) or state.page or 1
	page = max(1, min(#Tour.STOPS, page))
	local f = private.frame or private.Create()
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
		local state = private.State()
		state.done, state.page = true, nil
		Wanted:PromptForApp()
	end
end

---Shows a page: the window's page behind, the marks bordered, the text and the buttons.
function private.Go(page)
	local f, stop = private.frame, Tour.STOPS[page]
	private.page = page
	private.State().page = page
	f.counter:SetText(format("First steps · %d of %d", page, #Tour.STOPS))
	f.title:SetText(stop.title)
	f.body:SetText(stop.text)
	f.back:SetEnabled(page > 1)
	f.next:SetText(page == #Tour.STOPS and "Finish" or "Next")
	if stop.page then
		UI:Show(stop.page)
	end
	if stop.nearby and Wanted.NearbyWindow and not Wanted.NearbyWindow:IsShown() then
		Wanted.NearbyWindow:Toggle()
	end
	private.Mark(stop.mark)
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
		if target then
			local glow = private.glows[i]
			if not glow then
				glow = CreateFrame("Frame", nil, UIParent)
				glow:SetFrameStrata("DIALOG")
				glow:SetFrameLevel(50)
				Theme:Border(glow, C.amber)
				private.glows[i] = glow
			end
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
	Theme:Skin(f, C.panel, C.borderLight)
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
	f.next = W:Button(f, "Next", "primary", 110, 26, function()
		if private.page >= #Tour.STOPS then
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
	f:SetScript("OnHide", function() private.Unmark() end)
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
		private.resume = true
		Tour:Close()
	end
end)
Wanted:OnCombatEnd(function()
	if private.resume then
		private.resume = false
		Tour:Start()
	end
end)

Wanted:RegisterCommand("tour", "First steps: a tour of Wanted, page by page: /wanted tour", function()
	Tour:Start()
end)
