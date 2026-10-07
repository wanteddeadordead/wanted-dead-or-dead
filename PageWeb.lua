-- Wanted: the website and the desktop app. The game can't open a browser, so each address is in a box: click it
-- (it selects itself), Ctrl+C, and paste it into a browser.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local private = {}

local SITE = "https://wanteddeadordead.com"

---An address with a label over it, in a card.
local function AddLink(card, y, label, url, width)
	local text = Theme:Text(card, "small", label, C.muted)
	text:SetPoint("TOPLEFT", 16, y)
	local box = W:CopyBox(card, width - 32, url)
	box:SetPoint("TOPLEFT", 16, y - 18)
	return box
end

---Letters and digits as they are, everything else percent-encoded, for a character's name in an address.
function private.Escape(text)
	return (gsub(text, "[^%w]", function(ch) return format("%%%02X", ch:byte()) end))
end

function private.BuildSite(container, width)
	local card = W:Card(container)
	card:SetPoint("TOPLEFT")
	card:SetSize(width, 196)
	local label = W:SectionLabel(card, "The website")
	label:SetPoint("TOPLEFT", 16, -14)
	local about = Theme:Text(card, "body", "Leaderboards for every kill the network records: most kills, most killed, streaks, the Wall of Shame, guilds, zones and bounties, for both factions or one.")
	about:SetPoint("TOPLEFT", 16, -34)
	about:SetPoint("RIGHT", -16, 0)
	about:SetJustifyH("LEFT")
	about:SetWordWrap(true)
	AddLink(card, -80, "The site", SITE, width)
	private.playerBox = AddLink(card, -132, "Your page", SITE.."/player/", width)
end

function private.BuildApp(container, width)
	local card = W:Card(container)
	card:SetPoint("TOPLEFT", 0, -208)
	card:SetSize(width, 226)
	local label = W:SectionLabel(card, "The desktop app")
	label:SetPoint("TOPLEFT", 16, -14)
	local about = Theme:Text(card, "body", "Puts your records on the website's leaderboards, lets your records confirm other players' kills, links your characters by itself, and keeps Wanted's saved data safe between sessions. Windows and Mac. The addon works the same without it.")
	about:SetPoint("TOPLEFT", 16, -34)
	about:SetPoint("RIGHT", -16, 0)
	about:SetJustifyH("LEFT")
	about:SetWordWrap(true)
	private.appStatus = Theme:Text(card, "small", "")
	private.appStatus:SetPoint("TOPLEFT", 16, -96)
	AddLink(card, -124, "Download it", SITE.."/app", width)
	private.liveLog = W:Toggle(card, "Live battle reports", function(checked)
		Wanted.db.settings.liveLog = checked
		Wanted.LiveLog:Update()
	end)
	private.liveLog:SetPoint("TOPLEFT", 16, -184)
	private.appPrompt = W:Toggle(card, "Remind me at login when the app isn't set up", function(checked)
		Wanted.db.settings.appPrompt = checked
	end)
	private.appPrompt:SetPoint("LEFT", private.liveLog, "RIGHT", 40, 0)
	W:AttachTooltip(private.liveLog, "Live battle reports", "Keeps the game's combat log on in the open world, so the app can post deaths to the website within about five minutes, without a /reload. Turn it off here rather than with /combatlog. The log files stay in your Logs folder; the app can clean them up.")
end

---What the app last told the addon (through !!WantedLink): set up and current, behind, or not set up.
---@return string text
---@return table color
function private.AppState()
	local info = WantedAppInfo
	local running = type(info) == "table" and Wanted:ParseVersion(info.running) and info.running
	if not running then
		return "Not set up on this computer.", C.muted
	end
	if type(info.latest) == "string" and Wanted:IsNewerVersion(info.latest, running) then
		return format("Set up here (version %s). Version %s is out: download it below.", running, info.latest), C.amber
	end
	return format("Set up here (version %s), up to date.", running), C.green
end

function private.Refresh()
	if not private.appStatus then
		return
	end
	local text, color = private.AppState()
	private.appStatus:SetText(text)
	private.appStatus:SetTextColor(color[1], color[2], color[3])
	private.liveLog:SetChecked(Wanted.db.settings.liveLog)
	private.appPrompt:SetChecked(Wanted.db.settings.appPrompt)
	-- The name the network knows us by (first and last name on WoW Forever), as the site's pages use
	local url = SITE.."/player/"..private.Escape(Wanted.Store:GetOrigin() or "")
	private.playerBox:SetText(url)
	private.playerBox:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			self:SetText(url)
			self:HighlightText()
		end
	end)
end

---At login or /reload, when the desktop app isn't set up on this computer: a popup offering it, with the address
---to copy (as TSM does for its app). "Don't remind me" turns it off; the Website & app page turns it back on.
function Wanted:PromptForApp()
	if not Wanted.db.settings.appPrompt or Wanted:InCombat() or W:IsDialogShown() or (Wanted.WhatsNew and Wanted.WhatsNew:IsShown()) then
		return
	end
	local stopReminding = function()
		Wanted.db.settings.appPrompt = false
		Wanted:Print("No more app reminders. The Website & app page (/wanted web) has the link, and can turn them back on.")
		UI:Refresh()
	end
	if Wanted:AppVersion() then
		-- Set up: remind only when it hasn't run for a while
		local ago = Wanted:AppNotRunningFor()
		if ago then
			W:Dialog({
				title = "Is the Wanted app running?",
				text = format("The Wanted app last ran on this computer %s ago, so your kills aren't reaching the website. Start it from the Start menu: Wanted Dead or Dead.", Theme:Ago(ago)),
				confirmLabel = "Close",
				cancelLabel = "Don't remind me",
				onConfirm = function() end,
				onCancel = stopReminding,
			})
		end
		return
	end
	W:Dialog({
		title = "Get the Wanted app",
		text = "The Wanted desktop app isn't set up on this computer. It puts your kills on the website's leaderboards, lets your records confirm other players' kills, and keeps Wanted's saved data safe. For Windows and Mac.\n\nClick the address, press Ctrl+C, and paste it into your browser:",
		input = { value = SITE.."/app" },
		confirmLabel = "Close",
		cancelLabel = "Don't remind me",
		onConfirm = function() end,
		onCancel = stopReminding,
	})
end

UI:RegisterPage("web", {
	group = "You",
	title = "Website & app",
	subtitle = "Where the leaderboards are, and the app that puts you on them.",
	order = 5.5,
	build = function(container, width)
		private.BuildSite(container, width)
		private.BuildApp(container, width)
	end,
	refresh = private.Refresh,
})
