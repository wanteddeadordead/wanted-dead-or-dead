-- What's new: after an update, a window with a note from the author and a few short lines on what changed, once per
-- version, at the first login out of combat once the loading screen has gone. A fresh install gets a welcome instead.
-- /wanted new shows the newest notes again. Only major and minor releases (x.y.0) get an entry, never a patch (x.y.1),
-- and the newest must match CHANGELOG.md's newest x.y.0 (the smoke test checks both).

local _, Wanted = ...
local Theme, W = Wanted.Theme, Wanted.Widgets
local C = Theme.C
local WhatsNew = Wanted:NewModule("WhatsNew")
local private = {}

-- Each version's note from the author (optional), a picture above it (optional: a calling-card piece's id) and short
-- lines for players, newest first. A pinned version reaches everyone who hasn't seen it, under the newest notes, even
-- when they skipped it.
Wanted.WHATS_NEW = {
	{
		version = "1.18.0",
		note = "This one is about getting together and finding things faster. You asked for an easy way to set up world PvP "
			.."raids, so now there is one, and the menu was getting crowded, so I cut it down.\n\n"
			.."Form a raid, tell your friends, and go take a town.",
		lines = {
			"Raids: form a world PvP raid now or for later, and every Wanted player of your faction sees it, across realms. Click Join and the leader invites you.",
			"Announce your raid in chat for players without Wanted. Anyone who whispers you \"inv\" gets invited.",
			"A shorter menu: Home, Bounties, Enemies, Raids, Progress and You, with the rest as tabs.",
			"You opens on your calling card, with your wanted poster in the next tab.",
			"Home shows the raids forming now, ready to join.",
		},
	},
	{
		version = "1.17.1",
		pinned = true, -- the launch: everyone who hasn't seen it gets it, whatever version they come from
		art = "ach-founding-hunter-emblem", -- a calling-card piece's art, shown above the note
		note = "First, I want to thank all of you for the support you've shown during the beta testing of this addon and system. "
			.."Every bug report, screenshot and idea you sent made Wanted better, and seeing your kills, bounties and grudges show "
			.."up on the site has made the long nights worth it.\n\n"
			.."I'm also sorry for the flood of updates. There were a lot of them, sometimes several in a day, and I know restarting "
			.."the game again and again got old. Things will settle down from here.\n\n"
			.."We're not going anywhere, and we'll be here in force for the launch.\n\n"
			.."When WoW Forever launches on November 4, the beta season is archived and everyone starts fresh in Season 1. "
			.."You'll still be able to look back at the beta on the website under past seasons, but none of it carries over to "
			.."the live game. Your website account and your settings do, and everyone who played Wanted in the beta keeps the "
			.."Founding Hunter badge.\n\n"
			.."If you're enjoying Wanted, please tell your friends and guildmates about it. The more of us running it, the more "
			.."every kill counts.\n\n"
			.."See you out there.",
		lines = {
			"Your calling card in game: open Your calling card from the menu, or type /wanted card, and build it from the pieces you've unlocked.",
			"New emblems for every achievement, weekly medal and playstyle badge.",
			"Your name sits in the middle of every nameplate, and the light plates are easier to read.",
			"A popup shows when you earn an achievement or medal, or reach a new badge tier or rank.",
			"This window, after each update. Type /wanted new to see it again.",
		},
	},
	{
		version = "1.16.0",
		lines = {
			"Unlock toasts: earn an achievement or medal, reach a new badge tier or rank, and a toast shows what you unlocked.",
		},
	},
	{
		version = "1.15.0",
		lines = {
			"Your calling card in game: Your calling card in the menu, or /wanted card.",
			"An emblem for every achievement, weekly medal and playstyle badge.",
		},
	},
}

-- What a fresh install sees instead
Wanted.WELCOME = {
	"Wanted shows enemy players near you, tracks world PvP kills, and lets players put bounties on each other.",
	"Get the Wanted app (wanteddeadordead.com/app) so your kills reach the website's boards and your records count.",
	"Open Wanted from the minimap button, or type /wanted.",
}

local AUTHOR = "Chris (xmadness), who makes Wanted"
local SETTLE_SECONDS = 4 -- after the loading screen, before the window
local MOST_VERSIONS = 3 -- versions listed after a long break
local WIDTH = 460
local ART_SIZE = 96
local ART_TOP = 52
local BODY_RIGHT = 36 -- the text's right margin, with room for the scroll bar
local SCREEN_MARGIN = 100 -- the window is at most the screen's height less this
local MIN_HEIGHT = 300



-- ============================================================================
-- Public
-- ============================================================================

function WhatsNew:OnEnable()
	private.events = private.events or CreateFrame("Frame")
	private.events:RegisterEvent("LOADING_SCREEN_DISABLED")
	private.events:SetScript("OnEvent", function()
		C_Timer.After(SETTLE_SECONDS, private.Check)
	end)
	Wanted:OnCombatEnd(private.Check)
end

---Whether the window is up.
---@return boolean
function WhatsNew:IsShown()
	return private.frame ~= nil and private.frame:IsShown()
end

---The versions newer than seen (a version string; nil for none), up to this one, newest first, at most MOST_VERSIONS.
---@param seen string?
---@param current string
---@return table[]
function WhatsNew:Since(seen, current)
	local now, last = private.Number(current), private.Number(seen)
	local out = {}
	for _, entry in ipairs(Wanted.WHATS_NEW) do
		local n = private.Number(entry.version)
		if n and now and n <= now and (not last or n > last) and #out < MOST_VERSIONS then
			tinsert(out, entry)
		end
	end
	return out
end

---Shows the newest notes (or the welcome with welcome = true), whatever was seen.
---@param welcome boolean?
function WhatsNew:Show(welcome)
	if welcome then
		private.Open("Welcome to Wanted", nil, { { lines = Wanted.WELCOME } })
		return
	end
	local newest = Wanted.WHATS_NEW[1]
	private.Open("What's new in Wanted "..newest.version, newest.note, { newest }, nil, newest.art)
end



-- ============================================================================
-- When to show
-- ============================================================================

---Shows the welcome or what's new once, when there's something unseen, out of combat and with nothing else up.
function private.Check()
	local db = Wanted.db
	if not db or Wanted.idle or WhatsNew:IsShown() or InCombatLockdown() or Wanted:InCombat() or W:IsDialogShown() then
		return
	end
	local current = private.Number(Wanted.VERSION) and strmatch(Wanted.VERSION, "^v?(%d+%.%d+%.%d+)")
	if not current or db.whatsNewSeen == current then
		return
	end
	if Wanted.freshInstall and not db.whatsNewSeen then
		db.whatsNewSeen = current
		private.Open("Welcome to Wanted", nil, { { lines = Wanted.WELCOME } }, true)
		return
	end
	-- Never seen it (the update that brought it): the newest version only, whose lines sum up what came before; then
	-- any pinned version not seen yet
	local entries = WhatsNew:Since(db.whatsNewSeen, current)
	if not db.whatsNewSeen then
		entries = { entries[1] }
	end
	local last = private.Number(db.whatsNewSeen)
	for _, entry in ipairs(Wanted.WHATS_NEW) do
		local n = private.Number(entry.version)
		local listed = false
		for _, e in ipairs(entries) do
			listed = listed or e == entry
		end
		if entry.pinned and n and n <= private.Number(current) and (not last or n > last) and not listed then
			tinsert(entries, entry)
		end
	end
	db.whatsNewSeen = current
	if #entries > 0 then
		private.Open("What's new in Wanted "..entries[1].version, entries[1].note, entries, nil, entries[1].art)
	end
end

---A version as one comparable number (1.16.2 -> 1016002), nil for anything else.
function private.Number(version)
	local major, minor, patch = strmatch(tostring(version or ""), "^v?(%d+)%.(%d+)%.(%d+)")
	return major and tonumber(major) * 1000000 + tonumber(minor) * 1000 + tonumber(patch) or nil
end



-- ============================================================================
-- The window
-- ============================================================================

---Opens the window: a title, a picture if any (a calling-card piece's id), the author's note if any, then each
---entry's lines (with its version when there are several). After the welcome, OK goes on to the app prompt.
function private.Open(title, note, entries, welcome, art)
	local f = private.frame or private.Create()
	f.title:SetText(title)
	local path = art and Wanted.CallingCard:Art(art)
	f.scroll:ClearAllPoints()
	if path then
		f.art:SetTexture(path)
		f.art:Show()
		f.scroll:SetPoint("TOPLEFT", 20, -(ART_TOP + ART_SIZE + 10)) -- under the picture
	else
		f.art:Hide()
		f.scroll:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -14)
	end
	f.scroll:SetPoint("BOTTOMRIGHT", -BODY_RIGHT, 52)
	local parts = {}
	if note then
		tinsert(parts, note)
		tinsert(parts, "|cff8f9aa3"..AUTHOR.."|r")
		tinsert(parts, "")
	end
	for i, entry in ipairs(entries) do
		if #entries > 1 then
			tinsert(parts, "|cffffcc52"..entry.version.."|r")
		end
		-- The first version's note leads the window; a later one's (a pinned launch note) sits under its version
		if i > 1 and entry.note then
			tinsert(parts, entry.note)
			tinsert(parts, "|cff8f9aa3"..AUTHOR.."|r")
		end
		for _, line in ipairs(entry.lines) do
			tinsert(parts, "- "..line)
		end
		if #entries > 1 then
			tinsert(parts, "")
		end
	end
	f.body:SetText(table.concat(parts, "\n"))
	f.welcome = welcome
	-- As tall as the text needs, but never taller than the screen: past that the text scrolls
	local bodyHeight = ceil(f.body:GetStringHeight() or 0)
	local room = max(MIN_HEIGHT, (UIParent:GetHeight() or 0) - SCREEN_MARGIN)
	local height = 64 + (path and ART_SIZE + 10 or 0) + bodyHeight + 56
	f.bodyHolder:SetHeight(max(bodyHeight, 1))
	f:SetHeight(min(height, room))
	f.scroll:SetVerticalScroll(0)
	f.scroll.ScrollBar:SetShown(height > room)
	f:Show()
	f:Raise()
end

function private.Create()
	local f = CreateFrame("Frame", "WantedWhatsNewFrame", UIParent)
	f:SetSize(WIDTH, 240)
	f:SetPoint("CENTER", 0, 80)
	f:SetFrameStrata("DIALOG")
	f:EnableMouse(true)
	Theme:Skin(f, C.panel, C.borderLight)
	f.title = Theme:Text(f, "title", "", C.gold)
	f.title:SetPoint("TOPLEFT", 20, -18)
	f.title:SetWidth(WIDTH - 40)
	f.art = f:CreateTexture(nil, "ARTWORK")
	f.art:SetSize(ART_SIZE, ART_SIZE)
	f.art:SetPoint("TOP", f, "TOP", 0, -ART_TOP) -- centred, under the title
	-- The text, in a scroll frame: a long note scrolls rather than running off the screen
	f.scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
	f.scroll.scrollBarHideable = true
	f.bodyHolder = CreateFrame("Frame", nil, f.scroll)
	f.bodyHolder:SetSize(WIDTH - 20 - BODY_RIGHT, 1)
	f.scroll:SetScrollChild(f.bodyHolder)
	f.body = Theme:Text(f.bodyHolder, "body", "")
	f.body:SetPoint("TOPLEFT")
	f.body:SetWidth(WIDTH - 20 - BODY_RIGHT)
	f.body:SetWordWrap(true)
	f.body:SetSpacing(3)
	f.ok = W:Button(f, "OK", "primary", 120, 26, function()
		f:Hide()
		if f.welcome then
			Wanted:PromptForApp()
		end
	end)
	f.ok:SetPoint("BOTTOM", 0, 16)
	f:Hide()
	-- Escape closes it
	if UISpecialFrames then
		tinsert(UISpecialFrames, "WantedWhatsNewFrame")
	end
	private.frame = f
	return f
end

Wanted:RegisterCommand("new", "What's new in this version of Wanted.", function()
	WhatsNew:Show()
end)
