-- Wanted: bug reports, feature ideas and the beta welcome. An addon can't open a web page or send anything outside
-- the game, so a report the player sends (a bug, a duel tip that looks wrong, or an idea for a feature) waits in
-- the saved data for the desktop app to pass on to the developers.

local _, Wanted = ...
local Report = Wanted:NewModule("Report")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local private = { frame = nil }
local LOG_LINES = 40
local MAX_PROBLEM_LINES = 5 -- this session's newest problems a bug's log carries ahead of the recent lines
local MIN_NAME = 2 -- shorter names aren't looked for
-- Reports waiting for the app (docs/DATA.md): the most kept, how long one waits, and the most each part may be (letters;
-- the log in bytes)
local MAX_QUEUED = 20
local REPORT_KEEP_SECONDS = 30 * 24 * 60 * 60
local MAX_TEXT = 500
local MAX_TIP = 1000
local MAX_LOG_BYTES = 8 * 1024
local MAX_RULE = 64

function Report:OnLoad()
	-- A report the app never sent within 30 days goes
	local cutoff = GetServerTime() - REPORT_KEEP_SECONDS
	for id, report in pairs(Wanted.db.reports) do
		if type(report) ~= "table" or type(report.at) ~= "number" or report.at < cutoff then
			Wanted.db.reports[id] = nil
		end
	end
end

---Whether a byte can be part of a name: a letter, an apostrophe, or part of an accented letter.
local function NameByte(byte)
	return byte ~= nil and (byte >= 128 or byte == 39 or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122))
end

---The names Wanted knows, as a set: players seen, the name book, every record's origin and key, realm links, the
---guild roster, the lists, this character's own. Each with its realm cut off as well, and its first name alone (the
---combat log often gives only that), marked "first".
---@return table name -> true or "first"
function private.KnownNames()
	local set = {}
	local function Keep(name, first)
		if #name >= MIN_NAME and set[name] ~= true then
			set[name] = first or true
		end
	end
	local function Add(name)
		if type(name) == "string" and not (issecretvalue and issecretvalue(name)) then
			Keep(name)
			local bare = strmatch(name, "^([^%-]+)%-")
			if bare then
				Keep(bare)
			end
			local first = strmatch(name, "^([^%s%-]+)[%s%-]")
			if first then
				Keep(first, "first")
			end
		end
	end
	local db = Wanted.db or {}
	for _, player in pairs(type(db.players) == "table" and db.players or {}) do
		Add(type(player) == "table" and player.name)
	end
	for _, entry in pairs(type(db.names) == "table" and db.names or {}) do
		Add(type(entry) == "table" and entry.n)
	end
	for _, book in ipairs({ db.chains, db.keys, db.farPeers }) do
		for origin in pairs(type(book) == "table" and book or {}) do
			Add(origin)
		end
	end
	for _, list in ipairs({ db.kos, db.ignore }) do
		for _, entry in pairs(type(list) == "table" and list or {}) do
			Add(type(entry) == "table" and entry.name)
		end
	end
	for _, entry in pairs(type(db.hkBook) == "table" and db.hkBook or {}) do
		Add(type(entry) == "table" and entry.n)
	end
	for _, book in pairs(type(db.guildKos) == "table" and db.guildKos or {}) do
		for _, e in pairs(type(book) == "table" and type(book.entries) == "table" and book.entries or {}) do
			if type(e) == "table" then
				Add(e.kind == "player" and e.name)
				Add(e.by)
				Add(e.dby)
				Add(e.eby)
			end
		end
	end
	local ok, members = pcall(function() return Wanted.GuildRank and Wanted.GuildRank:Members() end)
	for _, m in ipairs(ok and type(members) == "table" and members or {}) do
		Add(m.name)
	end
	if Wanted.Sync then
		for name in pairs(Wanted.Sync:GetLinks()) do
			Add(name)
		end
		for _, name in ipairs(Wanted.Sync:DirectoryNames()) do
			Add(name)
		end
	end
	Add(Wanted.Store and Wanted.Store:GetOrigin())
	return set
end

-- Where the log puts a name Wanted may never have stored, by the formats that put one there (any name), each as a
-- pattern whose captures are what comes before the name and, if anything, what comes after it
local SENDER_FORMATS = {
	"(received %d+ bytes from )[^<]-( %(self%))",
	"(received %d+ bytes from )[^<]-( on [^ ]+)$",
	"(received %d+ bytes from )[^<]-( by whisper)$",
	"(received %d+ bytes from )[^<]-( in the guild)$",
	"(handling %u+ from )[^<]-( %(realm link%))$",
	"(handling %u+ from )[^<]-$",
	"(message from )[^<(,:;]-$",
	"(part %d+/%d+ from )[^<]-( doesn't fit)",
	"(record %S+ from )[^<]-(: )",
	"( on guild ).+$",
}
-- The words a "First Surname" name follows in the log's formats ("killed by", "UNIT_DIED for", "Sync: ... says"); not
-- "in", which comes before a zone, or a duel's "against", which comes before a class
local NAME_MARKERS = { "from", "to", "by", "for", "with", "of", "as", "on", "one against", "killer", "origin", "greeting",
	"told", "notice [%u_]+", "realm link", "may not %l+", "sender name", "Sync:", "Posse:", "Enemies:", "Recorder:",
	"Bridge:", "GuildKoS:", "KeyBook:", "Version:", "Store:", "Verify:" }
-- Lines whose words after a marker are never a player: a blocked action's code places and trail, a vendor
local NO_NAME_LINES = { "ADDON_ACTION_%u+:", "GearCatalog: " }
local PAIR = "[%u\128-\255][%l\128-\255'][%a\128-\255]* [%u\128-\255][%l\128-\255'][%a\128-\255]*"
local NAME_PAIR = PAIR.."%f[^%w\128-\255]"

---Whether the text from first to last stands where the log puts a name: after a marker, and not in front of another
---capitalised word.
local function NameStands(line, first, last)
	if strfind(line, "^ [%u\128-\255]", last + 1) then
		return false
	end
	local before = strsub(line, 1, first - 1)
	for _, marker in ipairs(NAME_MARKERS) do
		if strfind(before, "%f[%w]"..marker.." $") then
			return true
		end
	end
	return false
end

---A line with the names in a set left out: each run of up to three words (letters, apostrophes, accented letters)
---that is one, or is one followed by "'s", becomes <name>. A first name alone only where a name stands (after a
---marker) and not in front of another capitalised word: "Night Elf" and "Posse:" stay though a "Night Hunter" and a
---"Posse Rider" are known. Word by word, so thousands of known names cost no more.
local function ScrubKnown(line, names)
	local words, i = {}, 1
	while i <= #line do
		if NameByte(line:byte(i)) then
			local j = i
			while NameByte(line:byte(j + 1)) do
				j = j + 1
			end
			tinsert(words, { i, j })
			i = j + 1
		else
			i = i + 1
		end
	end
	local out, at, k = {}, 1, 1
	while k <= #words do
		local found
		for span = 3, 1, -1 do
			local last = words[k + span - 1]
			local together = last ~= nil
			for w = k, k + span - 2 do
				together = together and words[w + 1][1] == words[w][2] + 2 and line:byte(words[w][2] + 1) == 32
			end
			if together then
				local text = strsub(line, words[k][1], last[2])
				local bare = strsub(text, -2) == "'s" and strsub(text, 1, -3)
				if names[text] == true or (names[text] and NameStands(line, words[k][1], last[2])) then
					found = { span, last[2] }
				elseif bare and (names[bare] == true or (names[bare] and NameStands(line, words[k][1], last[2] - 2))) then
					found = { span, last[2] - 2 }
				end
				if found then
					break
				end
			end
		end
		if found then
			tinsert(out, strsub(line, at, words[k][1] - 1))
			tinsert(out, "<name>")
			at = found[2] + 1
			k = k + found[1]
		else
			k = k + 1
		end
	end
	tinsert(out, strsub(line, at))
	return table.concat(out)
end

---A line with other players left out: GUIDs (any case), the names Wanted knows (with a realm or not), names in the
---formats that put one there and any "First Surname" after a word that comes before a name, record ids ("Name:12"),
---any other "Name-Realm", and this realm's name. The log names whoever a message came from or was about; the report
---shouldn't.
function private.Scrub(line, names)
	line = gsub(line, "[Pp][Ll][Aa][Yy][Ee][Rr]%-%d+%-%x+", "Player-?")
	-- Names never stored, found by where they stand in the line. An honor message the addon couldn't read is the
	-- game's text, names and all.
	line = gsub(line, "(honor message not understood: ).*$", "%1<text>")
	for _, pattern in ipairs(SENDER_FORMATS) do
		line = gsub(line, pattern, function(before, after) return before.."<name>"..(after or "") end)
	end
	local named = true
	for _, pattern in ipairs(NO_NAME_LINES) do
		named = named and not strfind(line, pattern)
	end
	for _, marker in ipairs(named and NAME_MARKERS or {}) do
		line = gsub(line, "(%f[%w]"..marker.." )"..NAME_PAIR, "%1<name>")
	end
	-- "First Surname-Realm" whole, and record ids ("First Surname:12"), anywhere
	line = gsub(line, "%f[%a\128-\255]"..PAIR.."%-[%u\128-\255][%w\128-\255]*", "<name>")
	line = gsub(line, "%f[%a\128-\255]"..PAIR.."(:%w)", "<name>%1")
	line = ScrubKnown(line, names)
	-- A name with a realm, known or not, and a realm after a name left out
	line = gsub(line, "<name>%-[%w\128-\255']+", "<name>")
	line = gsub(line, "[%w\128-\255']+%-[%u\128-\255][%w\128-\255']*", function(token)
		return strfind(token, "^Player%-") and token or "<name>"
	end)
	local realm = GetRealmName and GetRealmName()
	if type(realm) == "string" and realm ~= "" then
		line = gsub(line, "%f[%w]"..gsub(realm, "%p", "%%%0").."%f[%W]", "<realm>")
	end
	return line
end

---The top of a bug report's log, at most 4 lines: the game, the settings that matter, the app and network, signing.
---@return string[]
function private.Header()
	local lines = {}
	local version, build = GetBuildInfo()
	tinsert(lines, format("Game client %s (build %s), locale %s; %s, level %s", tostring(version), tostring(build),
		tostring(GetLocale and GetLocale() or "?"), tostring(UnitFactionGroup("player")), tostring(UnitLevel("player"))))
	local detect = Wanted.db and Wanted.db.settings.detect or {}
	tinsert(lines, format("Detection %s, alerts %s, sound %s, share %s, timeout %ss", tostring(detect.enabled), tostring(detect.alerts),
		tostring(detect.sound), tostring(detect.share), tostring(detect.timeout)))
	local app = Wanted:AppVersion()
	app = not app and "none" or Wanted:IsNewerVersion(Report.MIN_APP, app) and app.." (too old for reports)"
		or Wanted:AppNotRunningFor() and app.." (not running)" or app.." (running)"
	local info = Wanted.Sync and Wanted.Sync:GetInfo()
	tinsert(lines, format("Wanted app %s; network %s", app, info and format("channel %s, %d peers%s",
		info.channelId and ("#"..info.channelId) or "not joined", info.peers, info.paused and ", PAUSED" or "") or "off"))
	if Wanted.Signing and Wanted.db then
		local _, kid = Wanted.Signing:PublicKey()
		tinsert(lines, format("Signing: %s, self-test %s", kid and format("key %s (%s seed)", kid, tostring(Wanted.Signing:Source())) or "no key yet",
			Wanted.Crypto:SelfTestText()))
	end
	return lines
end

---The report text: versions, settings that matter, network state, problems this session, recent log. No longer
---shown (Report a bug only sends); kept for the tests, which read what it gathers.
---@return string
function Report:Build()
	local lines = {}
	local function Add(fmt, ...)
		tinsert(lines, select("#", ...) > 0 and format(fmt, ...) or fmt)
	end
	Add("Wanted: Dead or... Dead %s%s%s", tostring(Wanted.VERSION), Wanted.BETA and " (beta)" or "", Wanted.newerVersion and (", newer version seen: "..Wanted.newerVersion) or "")
	for _, line in ipairs(private.Header()) do
		Add(line)
	end
	local info = Wanted.Sync and Wanted.Sync:GetInfo()
	if info then
		local stats = info.stats
		Add("Network: channel %s, members %s, peers %d, sent %d, received %d, merged %d, invalid %d, dropped %d, throttled %d, repeats skipped %d%s", info.channelId and ("#"..info.channelId) or "not joined", tostring(info.members), info.peers, stats.sent, stats.received, stats.merged, stats.invalid, stats.dropped, stats.throttled, stats.skipped, info.paused and ", PAUSED" or "")
		local reasons = Wanted.Sync and Wanted.Sync.DropReasons and Wanted.Sync:DropReasons() or ""
		if reasons ~= "" then
			Add("Dropped: %s", reasons)
		end
	end
	if Wanted.Store and Wanted.db then
		Add("Records flagged: %d tampered (never used), %d broken chain (never a witness)", Wanted.Store:CountFlagged())
		-- Signing (1.19.0): the keys known and what checks found (this character's key and the self-test are in the header)
		local origins, keys = Wanted.KeyBook:Count()
		local good, bad, waiting = Wanted.Verify:Counts()
		Add("Signatures: %d keys known for %d players; %d records checked out, %d bad, %d waiting", keys, origins, good, bad, waiting)
	end
	Add("")
	local problems = Wanted:GetProblems()
	Add("Problems this session (%d):", #problems)
	if #problems == 0 then
		Add("  none recorded")
	end
	local names = private.KnownNames()
	for _, problem in ipairs(problems) do
		Add("  %s", private.Scrub(problem, names))
	end
	Add("")
	Add("Last %d log lines (other players' names left out):", LOG_LINES)
	for _, line in ipairs(Wanted:GetLogLines(LOG_LINES)) do
		Add("  %s", private.Scrub(line, names))
	end
	return table.concat(lines, "\n")
end



-- ============================================================================
-- Reports for the developers, sent on by the Wanted app
-- ============================================================================

---Text as it's sent: on one line, without control characters or the game's escape codes (a link pasted in keeps
---its "[Name]"; icons, atlases and the like go whole, and any other "|"), at most maxLetters letters (UTF-8, as the
---app and the server count them, never cut inside one).
---@return string
function private.Clip(text, maxLetters)
	if type(text) ~= "string" then
		return ""
	end
	text = gsub(gsub(text, "|c%x%x%x%x%x%x%x%x", ""), "|r", "")
	text = gsub(gsub(text, "|H.-|h(.-)|h", "%1"), "|T.-|t", "")
	text = gsub(gsub(text, "|A.-|a", ""), "|K.-|k", "")
	text = strtrim((gsub(gsub(gsub(text, "|", ""), "[\r\n]+", " "), "%c", "")))
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

---How many reports are waiting for the app.
function Report:CountQueued()
	local n = 0
	for _ in pairs(Wanted.db.reports) do
		n = n + 1
	end
	return n
end

---Whether the queue is full: nothing more is taken until the app sends what's there.
function Report:IsQueueFull()
	return Report:CountQueued() >= MAX_QUEUED
end

---Puts a report in the queue for the app, under an id no other report has.
---@param report table kind and its fields, and character when it isn't this one; text, at, character and
---addonVersion are filled in here
---@return string? id nil when the queue is full
function Report:Queue(report)
	local queue = Wanted.db.reports
	if Report:IsQueueFull() then
		return nil
	end
	local character = report.character or Wanted.Store:GetOrigin()
	local at = floor(GetServerTime())
	while queue[character..":report:"..at] do
		at = at + 1
	end
	local id = character..":report:"..at
	report.at, report.character, report.addonVersion = at, character, tostring(Wanted.VERSION)
	report.text = private.Clip(report.text, MAX_TEXT)
	queue[id] = report
	Wanted:Log("Report %s waiting for the Wanted app (%d waiting)", id, Report:CountQueued())
	return id
end

---Queues a duel tip the player says looks wrong, with the duel's classes, specs and level, in the name of the
---character who fought it (the account's duels are all listed on any of its characters).
---@param duel table
---@param finding table the report's finding the tip belongs to
---@param text string? what the player said
---@return string? id
function Report:QueueTip(duel, finding, text)
	local Duels = Wanted.Duels
	local me, them = Duels:Side(duel, "me"), Duels:Side(duel, "them")
	local function Name(value)
		return type(value) == "string" and Wanted.Store:CleanName(value) or nil
	end
	return Report:Queue({
		kind = "tip",
		character = type(duel.id) == "string" and strmatch(duel.id, "^(.+):duel:%d+$") or nil,
		text = text,
		duelId = duel.id,
		rule = type(finding.rule) == "string" and private.Clip(finding.rule, MAX_RULE) or nil,
		tip = private.Clip(type(finding.tip) == "string" and finding.tip or finding.text, MAX_TIP),
		finding = private.Clip(finding.text, MAX_TIP),
		myClass = Name(me.class),
		mySpec = Name(me.spec),
		theirClass = Name(them.class),
		theirSpec = Name(them.spec),
		myLevel = type(me.level) == "number" and me.level or nil,
	})
end

---Queues a bug report: what the player said and a log of at most 40 lines and 8 KB (each line and its break, as the
---app and the server count it), other players' names left out. A 4-line header comes first, then up to 5 of this
---session's newest problems the recent lines don't have, then the recent lines, oldest first. The recent lines are
---trimmed first, oldest first, leaving room for the problems; problems are dropped too, oldest first, if it's still
---over 8 KB.
---@param text string
---@return string? id
function Report:QueueBug(text)
	local names = private.KnownNames()
	local head, bytes = {}, 0
	for _, line in ipairs(private.Header()) do
		line = private.Scrub(line, names)
		tinsert(head, line)
		bytes = bytes + #line + 1
	end
	-- The newest problems, as logged ("<time> Problem: <text>"): room is kept for all of them before the recent lines
	-- are trimmed, then only those the recent lines left don't have are sent
	local candidates, all = {}, Wanted:GetProblems()
	for i = #all, max(1, #all - MAX_PROBLEM_LINES + 1), -1 do
		local at, what = strmatch(all[i], "^(%S+) (.*)$")
		local line = private.Scrub(format("%s Problem: %s", at or "", what or all[i]), names)
		tinsert(candidates, 1, line)
		bytes = bytes + #line + 1
	end
	local log = {}
	for _, line in ipairs(Wanted:GetLogLines(LOG_LINES)) do
		line = private.Scrub(line, names)
		tinsert(log, line)
		bytes = bytes + #line + 1
	end
	while #log > 0 and (#head + #candidates + #log > LOG_LINES or bytes > MAX_LOG_BYTES) do
		bytes = bytes - #tremove(log, 1) - 1
	end
	local logged, problems = {}, {}
	for _, line in ipairs(log) do
		logged[line] = true
	end
	for _, line in ipairs(candidates) do
		if logged[line] then
			bytes = bytes - #line - 1
		else
			tinsert(problems, line)
		end
	end
	while #problems > 0 and bytes > MAX_LOG_BYTES do
		bytes = bytes - #tremove(problems, 1) - 1
	end
	local out = head
	for _, list in ipairs({ problems, log }) do
		for _, line in ipairs(list) do
			tinsert(out, line)
		end
	end
	return Report:Queue({ kind = "bug", text = text, log = out })
end

---Queues a feature idea: the player's words alone, no log. The app sends it on to the developers.
---@param text string
---@return string? id
function Report:QueueIdea(text)
	return Report:Queue({ kind = "idea", text = text })
end

---Lets go the reports the app says it has sent on (the catch-up's reportsReceived, read at every login).
---@param ids table? a list of report ids
function Report:TakeReceived(ids)
	if type(ids) ~= "table" then
		return
	end
	local removed = 0
	for _, id in ipairs(ids) do
		if type(id) == "string" and Wanted.db.reports[id] then
			Wanted.db.reports[id] = nil
			removed = removed + 1
		end
	end
	if removed > 0 then
		Wanted:Log("Catch-up: the Wanted app sent on %d reports", removed)
	end
end

-- The first desktop app that sends reports on
Report.MIN_APP = "0.2.46"

---What happens to a report now, by whether the app is set up, new enough and running.
function private.SentText()
	local version = Wanted:AppVersion()
	if not version then
		return "Thanks. It waits until the Wanted app runs on this PC (wanteddeadordead.com/app), then goes to the developers after a /reload or logout."
	elseif Wanted:IsNewerVersion(Report.MIN_APP, version) then
		return format("Thanks. It waits until the Wanted app is updated to %s or newer (you have %s): update it from its tray menu, then it goes to the developers after a /reload or logout.",
			Report.MIN_APP, Theme:Plain(version))
	elseif Wanted:AppNotRunningFor() then
		return "Thanks. The Wanted app isn't running, so it waits until you start it, then goes to the developers after a /reload or logout."
	end
	return "Thanks. It goes to the developers next time the Wanted app syncs (after a /reload or logout)."
end

---Where a bug report goes from here, for the report window: whether the app sends it, or what it waits for.
---@return string text
---@return table color
function private.AppText()
	local version = Wanted:AppVersion()
	if not version then
		return "A report waits until the Wanted app is running on this PC. Get it at wanteddeadordead.com/app.", C.amber
	elseif Wanted:IsNewerVersion(Report.MIN_APP, version) then
		return format("A report waits until the Wanted app is updated to %s or newer (you have %s): update it from its tray menu or wanteddeadordead.com/app.",
			Report.MIN_APP, Theme:Plain(version)), C.amber
	elseif Wanted:AppNotRunningFor() then
		return "The Wanted app isn't running: a report waits until you start it. Get it at wanteddeadordead.com/app.", C.amber
	end
	return "The Wanted app is set up: a report goes the next time it syncs (after a /reload or logout).", C.muted
end

---Tells the player the queue is full, and what gets the app sending.
function private.ShowFull()
	local version = Wanted:AppVersion()
	local todo = "Start the app and /reload"
	if not version then
		todo = "Get the app (wanteddeadordead.com/app), start it and /reload"
	elseif Wanted:IsNewerVersion(Report.MIN_APP, version) then
		todo = format("Update the app to %s or newer from its tray menu (you have %s) and /reload", Report.MIN_APP, Theme:Plain(version))
	end
	W:Dialog({
		title = "Reports waiting",
		text = format("%d reports are already waiting for the Wanted app to send them. %s, then you can send more.", MAX_QUEUED, todo),
		confirmLabel = "OK",
	})
end

---Asks what's wrong, then queues the report and says where it goes.
---@param options table title, text, validate, over (as W:Dialog's), queue(text) -> id?, savedTitle (of the dialog
---that says where it goes, default "Report saved")
function private.Ask(options)
	-- A second click while it asks does nothing (it would wait its turn behind this one)
	if W:IsDialogShown() then
		return
	end
	if Report:IsQueueFull() then
		private.ShowFull()
		return
	end
	W:Dialog({
		title = options.title,
		text = options.text,
		width = 440,
		over = options.over,
		input = { multiline = true, maxLetters = MAX_TEXT },
		confirmLabel = "Send",
		validate = options.validate,
		onConfirm = function(text)
			if not options.queue(text) then
				private.ShowFull()
				return
			end
			W:Dialog({ title = options.savedTitle or "Report saved", text = private.SentText(), confirmLabel = "OK" })
		end,
	})
end

---Asks the player what looks wrong with a duel's tip, and queues it for the developers.
---@param duel table
---@param finding table
function Report:AskAboutTip(duel, finding)
	private.Ask({
		title = "Something not right?",
		text = "Tell the developers what looks wrong with this tip, if you like. The tip and both sides' classes and specs go with it.",
		queue = function(text) return Report:QueueTip(duel, finding, text) end,
	})
end

---Asks the player what happened, and queues a bug report for the developers.
function Report:AskAboutBug()
	private.Ask({
		title = "Send to the developers",
		over = private.frame,
		text = "What happened, and what did you expect? Wanted's recent log goes with it, with your game and settings, other players' names left out.",
		validate = function(text)
			return private.Clip(text, MAX_TEXT) == "" and "Say what happened first." or nil
		end,
		queue = function(text) return Report:QueueBug(text) end,
	})
end

---Asks the player what Wanted should do, and queues the idea for the developers.
function Report:AskAboutIdea()
	private.Ask({
		title = "Suggest a feature",
		text = "What should Wanted do? It goes to the developers through the Wanted app.",
		validate = function(text)
			return private.Clip(text, MAX_TEXT) == "" and "Say what Wanted should do first." or nil
		end,
		queue = function(text) return Report:QueueIdea(text) end,
		savedTitle = "Idea saved",
	})
end



-- ============================================================================
-- Report window
-- ============================================================================

function private.Create()
	local frame = CreateFrame("Frame", "WantedBugReport", UIParent)
	frame:SetSize(620, 156)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetClampedToScreen(true)
	Theme:Skin(frame, C.panelSolid, C.borderLight)
	tinsert(UISpecialFrames, "WantedBugReport")
	frame:Hide()
	local bar = frame:CreateTexture(nil, "ARTWORK")
	bar:SetPoint("TOPLEFT", 1, -1)
	bar:SetPoint("TOPRIGHT", -1, -1)
	bar:SetHeight(3)
	Theme:Paint(bar, C.accent, 1)
	local title = Theme:Text(frame, "heading", "Report a bug")
	title:SetPoint("TOPLEFT", 20, -20)
	local close = W:Button(frame, "X", "ghost", 28, 28, function() frame:Hide() end)
	close:SetPoint("TOPRIGHT", -8, -8)
	-- The app sends it on: the player only says what happened
	local send = W:Button(frame, "Send to the developers", "primary", 180, 28, function() Report:AskAboutBug() end)
	send:SetPoint("TOPRIGHT", -20, -44)
	local sendNote = Theme:Text(frame, "body", "Say what happened and the Wanted app sends it, with the recent log.", C.text)
	sendNote:SetPoint("TOPLEFT", 20, -51)
	sendNote:SetPoint("RIGHT", send, "LEFT", -12, 0)
	sendNote:SetWordWrap(true)
	-- Whether the app will send it, or what the report waits for (set at each Show)
	local appNote = Theme:Text(frame, "small", "")
	appNote:SetPoint("TOPLEFT", 20, -84)
	appNote:SetPoint("RIGHT", -20, 0)
	appNote:SetWordWrap(true)
	local note = Theme:Text(frame, "tiny", "Say what you were doing, and the exact red error text if the game showed one.")
	note:SetPoint("BOTTOMLEFT", 20, 18)
	frame.appNote = appNote
	private.frame = frame
end

---Opens the report window, saying where a report goes from here.
function Report:Show()
	if not private.frame then
		private.Create()
	end
	local text, color = private.AppText()
	private.frame.appNote:SetText(text)
	private.frame.appNote:SetTextColor(color[1], color[2], color[3])
	private.frame:Show()
end

Wanted:RegisterCommand("bug", "Opens a bug report to send to the developers.", function()
	Report:Show()
end)

Wanted:RegisterCommand("idea", "Suggests a feature to the developers.", function()
	Report:AskAboutIdea()
end)



-- ============================================================================
-- Beta welcome
-- ============================================================================

---Shown once per version the first time the main window opens with no other dialog up.
function Report:MaybeWelcome()
	local db = Wanted.db
	if not Wanted.BETA or db.welcomed == Wanted.VERSION or W:IsDialogShown() then
		return
	end
	db.welcomed = Wanted.VERSION
	C_Timer.After(0.2, function()
		if W:IsDialogShown() then
			db.welcomed = nil -- another came up meanwhile: next time
			return
		end
		W:Dialog({
			title = "Welcome, bounty hunter",
			text = "Thanks for trying the Wanted: Dead or... Dead beta. If anything looks off, Report a bug at the foot of the menu (or /wanted bug) sends the details to the developers through the Wanted app.",
			confirmLabel = "Let's hunt",
		})
	end)
end
