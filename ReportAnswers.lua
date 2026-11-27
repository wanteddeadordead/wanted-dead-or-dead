-- Wanted: the developers' answers to the player's reports (bug reports, feature ideas, tips), in game. The Wanted
-- app writes the account's answered tickets into the catch-up (tickets); Catchup hands them here at every login
-- and /reload. Each unread answer gives one chat line (never with its text), a line on the Dashboard and a count
-- on Website & app, where it opens in a dialog with the ticket's address to answer on the website. Opening it
-- records it in reportsRead, which the app sends to the website so it marks the ticket seen.
-- Everything in the list is the app's local file: for display only, never a record, never sent on the channel. The
-- developers' text is untrusted: every "|" is doubled before it reaches a font string, so no colour, link or
-- texture code in it can take effect.

local _, Wanted = ...
local ReportAnswers = Wanted:NewModule("ReportAnswers")
local private = {}

local SITE = "https://wanteddeadordead.com"
-- The most tickets read, and the longest texts (letters): the server's limits, held again here
local MAX_TICKETS = 10
local MAX_REPLY = 1000
local MAX_SAID = 80
-- A reply keeps at most this many line breaks, so a reply of nothing but line breaks can't fill the screen
local MAX_LINES = 20
-- The app version that writes tickets into the catch-up
local MIN_APP = "0.2.66"
-- Seconds after the loading screen before the chat line, as What's new waits
local SETTLE_SECONDS = 4
-- Whole numbers the app writes stay below this (a double holds them exactly)
local MAX_ID = 2 ^ 53
-- Ticket numbers stay within a 32-bit whole number (what format's %d prints exactly on every client); times stay
-- before the year 2100, where the game's date() works on every system
local MAX_N = 2 ^ 31 - 1
local MAX_TIME = 4102444800

ReportAnswers.KINDS = { bug = "Bug report", idea = "Feature idea", tip = "Tip" }
ReportAnswers.STATUSES = { open = "Open", awaiting = "Awaiting info", fixed = "Fixed", closed = "Closed" }
-- How each kind reads in the chat line: "your bug report #16"
local KIND_CHAT = { bug = "bug report", idea = "feature idea", tip = "tip" }

ReportAnswers.APP_UPDATE_TEXT = "Answers from the developers show here with Wanted app "..MIN_APP.." or newer. Until then, read them at wanteddeadordead.com/me/reports."
ReportAnswers.NO_APP_TEXT = "Answers reach the game through the Wanted app. Read them at wanteddeadordead.com/me/reports."
ReportAnswers.NONE_TEXT = "No answers yet."



-- ============================================================================
-- Text from the app
-- ============================================================================

---At most maxLetters letters of text (UTF-8, never cut inside one).
local function CutLetters(text, maxLetters)
	-- Each letter starts with a byte that isn't a UTF-8 continuation byte
	local letters = 0
	for at in gmatch(text, "()[^\128-\191]") do
		letters = letters + 1
		if letters > maxLetters then
			return strsub(text, 1, at - 1)
		end
	end
	return text
end

---Text from the app made safe to show: control characters gone (line breaks kept, or turned to spaces for oneLine),
---at most maxLetters letters, and every "|" doubled, which makes any |c, |H, |T, |K, |A or |n show as typed and
---leaves nothing that can start a code. The doubling is last, after the cut.
---@param text any
---@param maxLetters number
---@param oneLine boolean? line breaks become spaces
---@return string? text nil when it isn't a string
function private.Clean(text, maxLetters, oneLine)
	if type(text) ~= "string" then
		return nil
	end
	-- A letter is at most 4 bytes: bytes past that can't be kept, however they are counted (stray continuation bytes
	-- count as no letter), and the steps below needn't run over them
	text = strsub(text, 1, maxLetters * 4)
	text = gsub(text, "\r\n?", "\n")
	text = gsub(text, "%c", function(char)
		if char == "\n" then
			return char
		elseif char == "\t" then
			return " "
		end
		return ""
	end)
	if oneLine then
		text = gsub(text, "%s+", " ")
	else
		text = gsub(text, "\n\n\n+", "\n\n")
		local breaks = 0
		text = gsub(text, "\n", function()
			breaks = breaks + 1
			if breaks > MAX_LINES then
				return " "
			end
		end)
	end
	text = CutLetters(strtrim(text), maxLetters)
	return (gsub(text, "|", "||"))
end

---A whole number from 1 up, or nil.
local function WholeNumber(value, most)
	if type(value) == "number" and value == floor(value) and value >= 1 and value <= most then
		return value
	end
	return nil
end

---A ticket as the app writes it, checked field by field; the cleaned copy to keep, or nil.
function private.CleanTicket(t)
	if type(t) ~= "table" then
		return nil
	end
	local n, m = WholeNumber(t.n, MAX_N), WholeNumber(t.m, MAX_ID)
	if not n or not m or not ReportAnswers.KINDS[t.kind] or not ReportAnswers.STATUSES[t.status] then
		return nil
	end
	local reply, said = t.reply == nil and "" or private.Clean(t.reply, MAX_REPLY), t.said == nil and "" or private.Clean(t.said, MAX_SAID, true)
	if not reply or not said then
		return nil
	end
	local at, replyAt = type(t.at) == "number" and t.at >= 0 and t.at <= MAX_TIME and floor(t.at) or 0,
		type(t.replyAt) == "number" and t.replyAt >= 0 and t.replyAt <= MAX_TIME and floor(t.replyAt) or 0
	return { n = n, kind = t.kind, status = t.status, m = m, at = at, seen = t.seen == true, reply = reply,
		replyAt = reply ~= "" and replyAt or 0, said = said }
end

---Drops from a saved map (ticket number -> message id) every ticket that isn't in the list, and any bad entry.
function private.Prune(name, keep)
	local map = Wanted.db[name]
	if type(map) ~= "table" then
		Wanted.db[name] = {}
		return
	end
	for n, m in pairs(map) do
		if not keep[n] or type(m) ~= "number" then
			map[n] = nil
		end
	end
end

---Takes in the catch-up's tickets, at every login: the newest first, at most MAX_TICKETS, each checked. Anything
---that isn't a table leaves no list (and prunes nothing); a table, even an empty one, prunes the saved maps to the
---tickets in it.
---@param list any
function ReportAnswers:Take(list)
	private.list = nil
	if type(list) ~= "table" then
		return
	end
	local out, keep = {}, {}
	for i = 1, MAX_TICKETS do
		local t = private.CleanTicket(rawget(list, i))
		if t and not keep[t.n] then
			keep[t.n] = true
			tinsert(out, t)
		end
	end
	sort(out, function(a, b)
		if a.at ~= b.at then
			return a.at > b.at
		end
		return a.n > b.n
	end)
	private.list = out
	private.Prune("reportsRead", keep)
	private.Prune("reportsTold", keep)
end

---The tickets taken in, newest first, or nil when the app sent none (an old app or server, or no app).
---@return table[]?
function ReportAnswers:List()
	return private.list
end

---The ticket with this number, or nil.
function ReportAnswers:Get(n)
	for _, t in ipairs(private.list or {}) do
		if t.n == n then
			return t
		end
	end
	return nil
end

---Whether the player has not read this answer: the app says it isn't seen on the website and the game's record of
---opening it is older than the answer.
function ReportAnswers:IsUnread(t)
	return not t.seen and (Wanted.db.reportsRead[t.n] or 0) < t.m
end

---The unread answers, newest first.
---@return table[]
function ReportAnswers:Unread()
	local out = {}
	for _, t in ipairs(private.list or {}) do
		if ReportAnswers:IsUnread(t) then
			tinsert(out, t)
		end
	end
	return out
end

---What the "Your reports" card says when it has no list to show: "none" (the app is current but the list is empty or
---wasn't written), "update" (an app older than the one that carries answers) or "app" (no app).
---@return string state "list", "none", "update" or "app"
---@return string text
function ReportAnswers:State()
	if private.list and #private.list > 0 then
		return "list", ""
	end
	if private.list then
		return "none", ReportAnswers.NONE_TEXT
	end
	local version = Wanted:AppVersion()
	if not version then
		return "app", ReportAnswers.NO_APP_TEXT
	elseif Wanted:IsNewerVersion(MIN_APP, version) then
		return "update", ReportAnswers.APP_UPDATE_TEXT
	end
	return "none", ReportAnswers.NONE_TEXT
end

---The ticket's address on the website, built here from its number.
---@param n number
---@return string
function ReportAnswers:Address(n)
	return format("%s/me/reports/%d", SITE, n)
end



-- ============================================================================
-- The chat line
-- ============================================================================

---Says once per answer (ticket and message) that the developers answered, never with the text. Not in a fight; the
---end of the fight comes back to it.
function private.Announce()
	local db = Wanted.db
	if not private.list or not db or Wanted.idle or InCombatLockdown() or Wanted:InCombat() then
		return
	end
	local fresh = {}
	for _, t in ipairs(ReportAnswers:Unread()) do
		if (db.reportsTold[t.n] or 0) < t.m then
			tinsert(fresh, t)
		end
	end
	if #fresh == 0 then
		return
	end
	for _, t in ipairs(fresh) do
		db.reportsTold[t.n] = t.m
	end
	local what
	if #fresh == 1 then
		what = format("your %s #%d", KIND_CHAT[fresh[1].kind], fresh[1].n)
	else
		what = format("%d of your reports", #fresh)
	end
	Wanted:Print("The developers answered %s. Type /wanted reports, or open Settings > Website & app.", what)
end

function ReportAnswers:OnEnable()
	private.events = private.events or CreateFrame("Frame")
	private.events:RegisterEvent("LOADING_SCREEN_DISABLED")
	private.events:SetScript("OnEvent", function()
		C_Timer.After(SETTLE_SECONDS, private.Announce)
	end)
	Wanted:OnCombatEnd(private.Announce)
end



-- ============================================================================
-- The answer
-- ============================================================================

---The dialog's text for an answer: what the player said, the developers' reply and the status, then where to answer.
---@param t table a ticket taken in
---@return string
function ReportAnswers:DialogText(t)
	local status = ReportAnswers.STATUSES[t.status]
	local parts = {}
	if t.reply ~= "" then
		if t.said ~= "" then
			tinsert(parts, "You said: "..t.said)
		end
		tinsert(parts, format("The developers, %s:\n%s", date("%Y-%m-%d", t.replyAt > 0 and t.replyAt or t.at), t.reply))
		tinsert(parts, "Status: "..status)
	else
		tinsert(parts, "The developers set it to "..status..".")
	end
	tinsert(parts, "Answer on the website, signed in to the account the Wanted app is connected to. Copy the address (Ctrl+C):")
	return table.concat(parts, "\n\n")
end

---Opens an answer in a dialog, and records that the player has read it: the app sends that to the website, which marks
---the ticket seen. The notices clear at once.
---@param n number the ticket's number
function ReportAnswers:Open(n)
	local t = ReportAnswers:Get(n)
	if not t then
		return
	end
	local db = Wanted.db
	Wanted.Widgets:Dialog({
		title = format("Report #%d · %s", t.n, ReportAnswers.KINDS[t.kind]),
		text = ReportAnswers:DialogText(t),
		width = 480,
		input = { value = ReportAnswers:Address(t.n), copy = true },
		confirmLabel = "Got it",
		cancelLabel = "Close",
		onConfirm = function() end,
	})
	-- After the dialog is built: an error making it never marks the answer read
	db.reportsRead[t.n] = max(db.reportsRead[t.n] or 0, t.m)
	db.reportsTold[t.n] = max(db.reportsTold[t.n] or 0, t.m)
	if Wanted.UI then
		Wanted.UI:Refresh(true)
	end
end

Wanted:RegisterCommand("reports", "Opens Website & app, where the developers' answers to your reports are.", function()
	Wanted.UI:Show("web")
end)
