-- What's new: after an update, a window with a note from the author and a few short lines on what changed, once per
-- version, at the first login out of combat once the loading screen has gone. A fresh install gets a welcome instead.
-- /wanted new shows the newest notes again. Only major and minor releases (x.y.0) get an entry, never a patch (x.y.1),
-- and the newest must match CHANGELOG.md's newest x.y.0 (the smoke test checks both).
-- New entries: a note of at most two sentences (about 40 words), and lines of at most about 15 words, each with the
-- command or the place in it. The how-it-works goes in tooltips and the tour, not here. Older entries stay as they are.

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
		version = "1.28.0",
		note = "Thank you to everyone who helped test Wanted during the beta. Your bug reports, screenshots and ideas "
			.."made this release. The beta ends on Wednesday, October 21, and this is the last beta release.\n\n"
			.."Next comes guild wars. After launch, guilds will fight over the zones of Azeroth, and each zone's owner goes on "
			.."the war map at wanteddeadordead.com.\n\n"
			.."— Chris aka xmadness",
		lines = {
			"A new look: Inter text, themes that recolour at once, and a UI size in Settings > Theme.",
			"Influence races every night at 7:00, 7:50 and 8:40 PM ET, under Guild Wars in the menu (needs the Wanted app).",
			"Three points per zone, the middle one worth 20% more, with your side's numbers live as you fight.",
			"Coming after launch, guild wars: after a race, a guild on the side that doesn't hold the zone can declare war, and the defenders pick a half-hour slot over the next two evenings.",
			"Wars are up to 40 a side: three lanes with a tower and an inhibitor each, and a keep at each end. The winner gets 3 days of peace. War Marks buy cosmetics only.",
		},
	},
	{
		version = "1.27.0",
		note = "New to Wanted, or want a refresher? First steps walks you through it page by page: each stop opens the real "
			.."page and borders the part it talks about. Poker has its own tour, and you can now invite a friend to your table "
			.."by name, even one on another realm name or without the Wanted app.",
		lines = {
			"First steps: /wanted tour, any time. A new install gets it at the first login.",
			"The poker tour: the first time you open Poker, or /wanted poker tour.",
			"Invite a player by name from your table card, or /wanted poker invite <name>: your table reaches them by whisper.",
			"Safety, at the foot of the menu: Wanted takes online bullying seriously. Misuse, griefing or bullying gets you banned.",
			"The setup card on the Dashboard shows what Wanted still needs from you, with the fix under each red mark.",
		},
	},
	{
		version = "1.26.0",
		note = "The Battle.net group is now a data link between the two sides, not a chat. Horde and Alliance can't talk "
			.."in game, so through the group's members the addons on both sides trade one thing as hidden game data: how many "
			.."Wanted players are in a zone, by layer. Where you are never crosses, no names and no positions; the other side "
			.."sees you only when they see you in the game. The fight layer is picked automatically, always the zone's most "
			.."active Wanted PvP layer, and there is no choosing one.",
		lines = {
			"Join the group from Settings or the Siege page; the setup checklist on the Dashboard shows whether you're in.",
			"The fight layer now counts both sides' Wanted players, so Hop takes everyone to the same place.",
			"Siege features still wait behind Settings > Capture fronts until the first public night.",
		},
	},
	{
		version = "1.25.0",
		note = "Two things about layers. Forever runs each zone as several layers, and Horde and Alliance can't talk in game, "
			.."so the Wanted Battle.net group is now the link between both sides' addons: not a chat, a data line, "
			.."through which your addon learns which layer the other side is fighting on. And a setup checklist at the top of the Dashboard shows what Wanted still needs from you, with the fix "
			.."under each red mark.",
		lines = {
			"Your setup, on the Dashboard: addon up to date, the Wanted app running, in the Battle.net group, enemy nameplates on. Website & app has every address to copy and a Turn on button for the nameplates.",
			"Join the Wanted Battle.net group from Settings or the Siege page: both sides, one layer. Members can see each other's BattleTag.",
			"/wanted setup prints the checklist in chat.",
		},
	},
	{
		version = "1.24.0",
		note = "Siege nights are coming: a capture front across the zone, three lanes of towers and inhibitors between two "
			.."Nexus, fought on one layer, with a HUD, painted pieces on the maps and a way to hop layers. The first public "
			.."night isn't set yet, so all of it ships switched off and nothing else changes for you. Want a look before "
			.."then? /wanted siege on, then /reload.",
		lines = {
			"Settings > Capture fronts turns the siege features on or off (off until the first public siege night).",
			"With it on: the capture HUD under the main window, the pieces on the world map and minimap, rally leaders and layer hops.",
			"Layers: Wanted reads yours from the creatures around you; /wanted shard says yours and the fight's, and Hop gets you there by a group invite from a Wanted player already on it.",
		},
	},
	{
		version = "1.23.0",
		note = "A round of polish for the poker table from the first week of games: the table can be dressed up, the money "
			.."rounds to the table's coin, and the host has a few more controls.",
		lines = {
			"Ten painted felts from around Azeroth, chosen in the table settings, with a brightness slider per felt. Stranglethorn Vale is the default.",
			"Names at the table and in the hand log are in class colours, the computer players' too.",
			"A silver game has no copper: every bet, raise, buy-in and rebuy rounds to whole silver.",
			"Close table waits for the hand under way and tells the players; Keep open undoes it.",
			"The window is wider, bets stay off the pot, and the log names the hands that showed and lost.",
		},
	},
	{
		version = "1.22.0",
		note = "Nothing better after a day of hunting than playing some poker with that hard-earned gold. Wanted now deals "
			.."Texas hold'em: open the Poker page, host a table or sit at one, and play for chips, for gold, or against the "
			.."house's computer players while you wait on a pull. Every deal is shuffled by everyone at the table and checked "
			.."by every client, so nobody can rig it, the host included.",
		lines = {
			"Poker: cash games and tournaments on the Poker page, or /wanted poker. It comes with Wanted and is on by default.",
			"Gold tables are cash on the table: buy-ins go to the host first, stacks come back when you leave, and Settlement keeps the books.",
			"Practice tables fill the seats with computer players on play money that looks like gold.",
			"Tables run in dungeons and raids too, and pause themselves during a boss fight.",
		},
	},
	{
		version = "1.21.0",
		note = "Something not right? Tell us from inside the game. Every duel tip now has a \"Something not right?\" link, and "
			.."Report a bug sends your report straight to us through the Wanted app, with other players' names left out.\n\n"
			.."The calendar also shows events from wanteddeadordead.com, starting with the Forever Open on October 17 and 18.",
		lines = {
			"\"Something not right?\" under a duel tip sends that tip to us, with what you think is wrong.",
			"Report a bug (title bar or /wanted bug) now sends straight to us through the Wanted app: no more copying.",
			"The calendar shows the site's events, like the Forever Open, in your local time (Wanted app 0.2.47 or newer).",
			"Reinstalled the addon or lost your saved data? Your new kills and deaths no longer clash with your old ones.",
		},
	},
	{
		version = "1.20.0",
		note = "This one is about getting better at fighting. Duel someone and Wanted now keeps the fight: who you faced, "
			.."their spec, talents and gear, and how it went.\n\n"
			.."With the Wanted app running, you also get a fight card for each duel: what happened, second by second, "
			.."and a few tips on what to try next time.",
		lines = {
			"A Duels tab under Progress: your record against each class and spec, and as each of your own builds.",
			"Click a duel for its fight card: both sides' health, the control you took, what each of you used, and tips.",
			"Timeline replays the fight cast by cast; See talent tree and See gear show what your opponent ran.",
			"Fight cards come from the Wanted app reading your combat log (experimental: /wanted bug tells us about a wrong tip).",
			"Duels never count as kills, deaths or kill streaks.",
		},
	},
	{
		version = "1.19.0",
		note = "This one is about trust. Bounties run on your word: when a poster confirms a kill or pays a hunter, "
			.."everyone's addon has to believe it really came from them, and until now another player could fake that. "
			.."From this version, your addon signs what you post, claim, confirm and pay, so nobody can do it in your name.\n\n"
			.."You don't need to do anything. With the Wanted app, your key comes from it; without it, the addon makes one "
			.."after a few minutes of play.",
		lines = {
			"Your bounties, claims, confirms and payments are signed, so nobody can fake them in your name.",
			"A bounty's details show Signed when a poster's or hunter's word checks out, and leave out anything forged.",
			"Checking runs in the background, out of combat, without slowing your game.",
			"Using the Wanted app? Your key comes from it and is stronger. Get it at wanteddeadordead.com/app.",
			"Think someone has your key? Type /wanted key reset.",
		},
	},
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

local AUTHOR = "The maintainers of Wanted"
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
		-- The tour in place of the welcome note (Tour); the welcome stays for /wanted welcome and older clients
		if Wanted.Tour then
			Wanted.Tour:Start(1)
		else
			private.Open("Welcome to Wanted", nil, { { lines = Wanted.WELCOME } }, true)
		end
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
	Theme:Skin(f, C.panelSolid, C.borderLight)
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
