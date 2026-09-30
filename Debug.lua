-- Wanted: test data. /wanted simulate builds a whole bounty story out of records marked as test data,
-- so claims, witness levels, confirming, owed, reputation and the scoreboard can be checked without an
-- enemy in sight. Test records never leave this client and /wanted purge removes them.

local _, Wanted = ...
local Debug = Wanted:NewModule("Debug")
local Store = Wanted.Store
local Bounties = Wanted.Bounties
local Recorder = Wanted.Recorder

local TARGET_GUID = "Player-TEST-00000001"
local TARGET_NAME = "Corvin Ashdale"
local HUNTER = "Rhea Stormtide"
local WITNESS = "Tobin Greaves"
local OTHER_POSTER = "Hallam Voss"

-- Development builds only: released versions have no test data at all
if not Wanted.DEV then
	return
end

-- ============================================================================
-- Timing (development builds only)
-- ============================================================================

-- Every wrapped handler and timer is timed. One call over SLOW_MS, or a second in which they add up to over
-- BUSY_MS, is logged with the worst offenders, so a slow moment in a big fight names its cause.
local SLOW_MS = 12
local BUSY_MS = 50
local second, secondTotal, secondByLabel = 0, 0, {}

local function FlushSecond()
	if secondTotal > BUSY_MS then
		local labels = {}
		for label, stat in pairs(secondByLabel) do
			tinsert(labels, { label = label, ms = stat.ms, calls = stat.calls })
		end
		sort(labels, function(a, b) return a.ms > b.ms end)
		local parts = {}
		for i = 1, min(#labels, 4) do
			tinsert(parts, format("%s %.0fms/%d", labels[i].label, labels[i].ms, labels[i].calls))
		end
		Wanted:Log("!! Busy second: %.0fms: %s", secondTotal, table.concat(parts, ", "))
	end
	secondTotal = 0
	wipe(secondByLabel)
end

function Wanted:Timed(label, func)
	local isEvents = strfind(label, "events$") ~= nil
	-- Notes the time a call took and passes its results through
	local function Done(start, event, ...)
		local ms = debugprofilestop() - start
		-- An event handler is timed per event, so the log names the one that was slow
		local label = type(event) == "string" and label.." "..event or label
		local now = floor(GetTime())
		if now ~= second then
			FlushSecond()
			second = now
		end
		secondTotal = secondTotal + ms
		local stat = secondByLabel[label]
		if not stat then
			stat = { ms = 0, calls = 0 }
			secondByLabel[label] = stat
		end
		stat.ms = stat.ms + ms
		stat.calls = stat.calls + 1
		if ms > SLOW_MS then
			Wanted:Log("!! Slow: %s took %.0fms", label, ms)
		end
		return ...
	end
	return function(...)
		return Done(debugprofilestop(), isEvents and select(2, ...), func(...))
	end
end

-- ============================================================================
-- Network log (development builds only)
-- ============================================================================

-- Every debug log line also goes into the saved data, so a session's network traffic can be read back after
-- a /reload or logout (WantedDB.devLog, the last DEV_LOG_LINES lines). Lines starting "!!" are the weird
-- ones: altered records, broken chains, bad messages, limits hit, version locks, rejected notices.
local DEV_LOG_LINES = 5000
local pendingLog = {} -- lines logged before the saved data is ready
local realLog = Wanted.Log

local function KeepLine(line)
	local db = Wanted.db
	if not db then
		tinsert(pendingLog, line)
		return
	end
	local log = db.devLog
	if type(log) ~= "table" or type(log.lines) ~= "table" then
		log = { lines = {}, pos = 0 }
		db.devLog = log
	end
	log.pos = log.pos % DEV_LOG_LINES + 1
	log.lines[log.pos] = line
end

-- /wanted netwatch: the network lines also print to chat as they happen (weird ones in red), leaving out
-- the low-level ones (message parts, byte counts)
local NETWATCH_SKIP = { "^Sync: SendAddonMessage part", "^Sync: received %d+ bytes" }

local function Watch(msg)
	if not (Wanted.db and Wanted.db.devNetwatch) then
		return
	end
	local weird = strfind(msg, "^!! ") ~= nil
	if not weird and not (strfind(msg, "^Sync: ") or strfind(msg, "^Bridge: ") or strfind(msg, "^Store: ")) then
		return
	end
	for _, pattern in ipairs(NETWATCH_SKIP) do
		if strfind(msg, pattern) then
			return
		end
	end
	DEFAULT_CHAT_FRAME:AddMessage((weird and "|cffff4040net|r " or "|cff7fa7ffnet|r ")..(weird and ("|cffff8080"..msg.."|r") or msg))
end

function Wanted:Log(fmt, ...)
	realLog(self, fmt, ...)
	local msg = select("#", ...) > 0 and format(fmt, ...) or fmt
	KeepLine(date("%m-%d %H:%M:%S").." "..msg)
	Watch(msg)
end

function Debug:OnLoad()
	for _, line in ipairs(pendingLog) do
		KeepLine(line)
	end
	wipe(pendingLog)
end

---The kept network log lines, oldest first.
function Debug:GetDevLog()
	local log = Wanted.db and Wanted.db.devLog
	local lines = {}
	if type(log) ~= "table" or type(log.lines) ~= "table" then
		return lines
	end
	for i = 1, DEV_LOG_LINES do
		local line = log.lines[(log.pos + i - 1) % DEV_LOG_LINES + 1]
		if line then
			tinsert(lines, line)
		end
	end
	return lines
end

Wanted:RegisterCommand("netwatch", "Development builds: print network activity to chat as it happens (again to stop): /wanted netwatch", function()
	Wanted.db.devNetwatch = not Wanted.db.devNetwatch or nil
	Wanted:Print(Wanted.db.devNetwatch and "Netwatch on: network activity prints to chat (weird events in red). /wanted netwatch again to stop."
		or "Netwatch off.")
end)

Wanted:RegisterCommand("netlog", "Development builds: network summary and the last weird events (!!) from the kept log: /wanted netlog", function()
	Wanted:Print(Wanted.Sync:Status())
	if Wanted.Bridge then
		Wanted:Print(Wanted.Bridge:Status())
	end
	local lines = Debug:GetDevLog()
	local weird = {}
	for _, line in ipairs(lines) do
		if strfind(line, " !! ", 1, true) then
			tinsert(weird, line)
		end
	end
	Wanted:Print("Kept log: %d lines, %d weird (!!). The last %d:", #lines, #weird, min(#weird, 20))
	for i = max(1, #weird - 19), #weird do
		Wanted:Print("  %s", weird[i])
	end
end)

-- The reputation cast for /wanted simulate rep: made-up players with records that differ on purpose
-- Realistic names so screenshots and tests read like the real thing: a reliable hunter, a doubtful one, a
-- poster who pays and one who doesn't
local ACE, SHADY, HONEST, DEADBEAT = "Kaelen Duskbrand", "Vorn Ashgrip", "Maribel Stonehollow", "Grix Tallowbane"

---Builds a record history where good and bad reputations sit side by side:
---  Kaelen Duskbrand: witnessed and confirmed kills, paid. High level, full reliability.
---  Vorn Ashgrip: kills nobody saw, two disputed by the poster. Level 0, no reliability.
---  Maribel Stonehollow: posts and pays. Grix Tallowbane: two confirmed claims never paid (UNPAID).
---Plus open bounties from both posters on the Board, and two of yours with claims to confirm or dispute.
function Debug:SimulateReputation()
	Store:PurgeTest()
	local me = Store:GetOrigin()
	local zone, x, y, mapId = Recorder:GetPosition()
	local now = GetServerTime()
	local day = 86400
	local targets = {}
	for i, def in ipairs({ { "Elyra Moonwhisper", "MAGE", 21 }, { "Dorran Ironvale", "WARRIOR", 23 }, { "Sella Brightwell", "PRIEST", 20 }, { "Thane Oakcrest", "HUNTER", 22 } }) do
		local guid = format("Player-TEST-%08d", 100 + i)
		Store:UpdatePlayer(guid, { name = def[1], class = def[2], level = def[3], faction = "Alliance", guild = "Crimson Vanguard", zone = zone, mapId = mapId, x = x, y = y })
		targets[i] = { guid = guid, name = def[1], level = def[3] }
	end
	-- Ten days of made-up whereabouts for each target, mostly evenings, across a few zones
	local zones = { { zone, mapId, x or 50, y or 50 }, { "Ashenvale", 1440, 70, 60 }, { "Stonetalon Mountains", 1442, 60, 55 } }
	local spotters = { nil, "Tobin Greaves", "Maribel Stonehollow" }
	for i, target in ipairs(targets) do
		local list = {}
		for d = 10, 0, -1 do
			for n = 1, 2 + (i + d) % 3 do
				local hour = 19 + (n + i + d) % 5
				local t = now - d * day - (now % day) + hour * 3600 + n * 900
				if t < now then
					local z = zones[(n + d + i) % #zones + 1]
					tinsert(list, { t = t, zone = z[1], mapId = z[2], x = z[3] + n, y = z[4] - n, by = spotters[(n + d) % #spotters + 1] })
				end
			end
		end
		sort(list, function(a, b) return a.t < b.t end)
		Wanted.db.tracks[target.guid] = list
	end
	local function Bounty(poster, target, amount, t)
		return Store:InsertTest("bounty", poster, { target = target.guid, targetName = target.name, amount = amount, level = target.level, zone = zone }, t)
	end
	-- A kill by the hunter, seen by a witness when witnessed is set; returns the claim on the bounty
	local function Claim(hunter, bounty, target, t, witnessed)
		local deathId = Store:Hash(strjoin("|", target.guid, hunter, tostring(t)))
		local kill = Store:InsertTest("kill", hunter, { killer = "Player-TEST-"..hunter, killerName = hunter, victim = target.guid, victimName = target.name, victimGuild = "Crimson Vanguard", deathId = deathId, zone = zone, x = x, y = y, honor = true }, t)
		if witnessed then
			Store:InsertTest("death", WITNESS, { deathId = deathId, victim = target.guid, victimName = target.name, victimGuild = "Crimson Vanguard", zone = zone, x = x, y = y }, t + 1)
		end
		return Store:InsertTest("claim", hunter, { bounty = bounty.id, kill = kill.id, deathId = deathId, victim = target.guid, victimName = target.name, zone = zone, killT = t }, t + 2)
	end
	local function Confirm(poster, claim, disputed)
		Store:InsertTest("confirm", poster, { claim = claim.id, disputed = disputed or nil }, claim.t + 1800)
	end
	local function Pay(poster, hunter, claim, bounty)
		Store:InsertTest("payment", poster, { claim = claim.id, bounty = bounty.id, to = hunter, amount = Bounties:GetAmount(bounty), side = "payer" }, claim.t + 3600)
	end
	-- Kaelen Duskbrand: six kills on Maribel Stonehollow's bounties over three weeks, witnessed, confirmed and paid
	for i = 1, 6 do
		local t = now - (3 + i * 3) * day
		local target = targets[(i - 1) % #targets + 1]
		local bounty = Bounty(HONEST, target, (40 + i * 10) * 100, t - day)
		local claim = Claim(ACE, bounty, target, t, true)
		Confirm(HONEST, claim)
		Pay(HONEST, ACE, claim, bounty)
	end
	-- Grix Tallowbane: two of Ace's kills confirmed days ago and never paid
	for i = 1, 2 do
		local t = now - (3 + i) * day
		local bounty = Bounty(DEADBEAT, targets[i], 60 * 100, t - day)
		Confirm(DEADBEAT, Claim(ACE, bounty, targets[i], t, true))
	end
	-- Vorn Ashgrip: three kills nobody saw, two of them disputed by the poster
	for i = 1, 3 do
		-- Half a day off Ace's kills: a witness is matched by victim, zone and time
		local t = now - (8 + i) * day + day / 2
		local bounty = Bounty(HONEST, targets[i + 1], 30 * 100, t - day)
		local claim = Claim(SHADY, bounty, targets[i + 1], t, false)
		if i <= 2 then
			Confirm(HONEST, claim, true)
		end
	end
	-- Open bounties on the Board, so each poster's record shows on a row
	Bounty(HONEST, targets[3], 75 * 100, now - 7200)
	Bounty(DEADBEAT, targets[4], 90 * 100, now - 3600)
	-- Two of yours: Ace's witnessed kill to confirm and pay, Shady's unseen one to dispute
	local mine1 = Bounty(me, targets[1], 50 * 100, now - day)
	local aceClaim = Claim(ACE, mine1, targets[1], now - 1200, true)
	-- Kaelen's client saved a proof screenshot of that kill
	Store:InsertTest("proof", ACE, { claim = aceClaim.id, deathId = aceClaim.data.deathId, at = date("%H:%M:%S") }, now - 1190)
	local mine2 = Bounty(me, targets[2], 50 * 100, now - day)
	Claim(SHADY, mine2, targets[2], now - 900, false)
	Wanted:Print("Simulated reputations: %s (reliable hunter), %s (disputed claims), %s (pays), %s (2 unpaid). See the Board, Your bounties > Your live bounties, Leaderboards, and /wanted rep <name>. /wanted purge removes it all.", ACE, SHADY, HONEST, DEADBEAT)
end

Wanted:RegisterCommand("simulate", "Creates test data: a bounty of yours, a witnessed claim on it, and another poster's bounty. /wanted simulate paid adds the payment; /wanted simulate rep builds players with good and bad records.", function(args)
	local me = Store:GetOrigin()
	local zone, x, y, mapId = Recorder:GetPosition()
	local now = GetServerTime()
	if strtrim(args or "") == "rep" then
		Debug:SimulateReputation()
		return
	end
	if strtrim(args or "") == "paid" then
		-- Collect first: adding records while walking the record table can skip some
		local unpaid = {}
		for claim in Store:Iterator("claim") do
			if Store:IsTest(claim) and claim.origin == HUNTER and not Wanted.Payments:GetForClaim(claim.id) then
				tinsert(unpaid, claim)
			end
		end
		for _, claim in ipairs(unpaid) do
			Store:InsertTest("payment", HUNTER, { claim = claim.id, bounty = claim.data.bounty, from = me, amount = Bounties:GetAmount(Store:Get(claim.data.bounty)), side = "payee" })
		end
		local paid = #unpaid
		Wanted:Print("Simulated %d payment(s) received by %s.", paid, HUNTER)
		return
	end
	Store:PurgeTest()
	-- An enemy, seen twice
	Store:UpdatePlayer(TARGET_GUID, { name = TARGET_NAME, class = "ROGUE", level = 22, faction = "Alliance", guild = "Crimson Vanguard", zone = zone, mapId = mapId, x = x, y = y })
	Store:AddSighting(TARGET_GUID, zone, x, y, mapId)
	-- Your bounty on them, posted yesterday, raised today
	local bounty = Store:InsertTest("bounty", me, { target = TARGET_GUID, targetName = TARGET_NAME, amount = 50 * 100, level = 22, zone = zone }, now - 86400)
	Store:InsertTest("raise", me, { bounty = bounty.id, amount = 30 * 100 }, now - 3600)
	-- Someone else's bounty on the same target, too low for most
	Store:InsertTest("bounty", OTHER_POSTER, { target = TARGET_GUID, targetName = TARGET_NAME, amount = 15 * 100, level = 22, zone = zone }, now - 7200)
	-- A hunter killed them ten minutes ago with honor credit, and a bystander saw the death
	local killT = now - 600
	local deathId = Store:Hash(strjoin("|", TARGET_GUID, zone, floor(killT / 10)))
	local kill = Store:InsertTest("kill", HUNTER, { killer = "Player-TEST-00000002", killerName = HUNTER, killerGuild = "Bloodfang Syndicate", victim = TARGET_GUID, victimName = TARGET_NAME, victimGuild = "Crimson Vanguard", deathId = deathId, zone = zone, x = x, y = y, honor = true }, killT)
	Store:InsertTest("death", WITNESS, { deathId = deathId, victim = TARGET_GUID, victimName = TARGET_NAME, victimGuild = "Crimson Vanguard", zone = zone, x = x, y = y }, killT + 1)
	-- Their claims on both bounties
	Store:InsertTest("claim", HUNTER, { bounty = bounty.id, kill = kill.id, deathId = deathId, victim = TARGET_GUID, victimName = TARGET_NAME, zone = zone, killT = killT }, killT + 2)
	local others = {}
	for other in Store:Iterator("bounty") do
		if other.origin == OTHER_POSTER and Store:IsTest(other) then
			tinsert(others, other)
		end
	end
	for _, other in ipairs(others) do
		Store:InsertTest("claim", HUNTER, { bounty = other.id, kill = kill.id, deathId = deathId, victim = TARGET_GUID, victimName = TARGET_NAME, zone = zone, killT = killT }, killT + 2)
	end
	-- A history for the hunter: two older confirmed claims by the other poster, one paid
	for i = 1, 2 do
		local old = Store:InsertTest("bounty", OTHER_POSTER, { target = TARGET_GUID, targetName = TARGET_NAME, amount = 40 * 100, level = 22, zone = zone }, now - (10 + i) * 86400)
		local oldClaim = Store:InsertTest("claim", HUNTER, { bounty = old.id, kill = kill.id, deathId = deathId.."x"..i, victim = TARGET_GUID, victimName = TARGET_NAME, zone = zone, killT = old.t + 3600 }, old.t + 3601)
		Store:InsertTest("confirm", OTHER_POSTER, { claim = oldClaim.id }, old.t + 7200)
		if i == 1 then
			Store:InsertTest("payment", OTHER_POSTER, { claim = oldClaim.id, bounty = old.id, to = HUNTER, amount = 40 * 100, side = "payer" }, old.t + 7300)
		end
	end
	Wanted:Print("Simulated: %s (%s) has an 80s bounty from you and a 15s one from %s; %s killed them 10 minutes ago, %s saw it. Look at Bounties, Claims, Owed, Top, and /wanted rep %s. /wanted purge removes it all.", TARGET_NAME, "level 22 rogue", OTHER_POSTER, HUNTER, WITNESS, HUNTER)
end)

Wanted:RegisterCommand("freshstart", "Deletes every bounty, kill, death, claim and payment and starts your record again. Before release only.", function()
	Wanted.Widgets:Dialog({
		title = "Start fresh",
		text = "Deletes every bounty, kill, death, claim and payment on this client and starts your record again. Settings, Kill on Sight, Ignore, enemy statistics and sightings stay.\n\nOnly do this before anyone else has synced with you: their copies of your records would no longer match.",
		confirmLabel = "Start fresh",
		confirmStyle = "danger",
		onConfirm = function()
			local removed = Store:FreshStart()
			Wanted:Print("Fresh start: removed %d records. Your record starts again from here.", removed)
			if Wanted.UI then
				Wanted.UI:Refresh()
			end
		end,
	})
end)

Wanted:RegisterCommand("purge", "Removes all test data.", function()
	local removed = Store:PurgeTest()
	Wanted:Print("Removed %d test records.", removed)
end)

Wanted:RegisterCommand("channels", "Development builds: probe how the game reports the sync channel's members: /wanted channels", function()
	local Sync = Wanted.Sync
	local info = Sync:GetInfo()
	local mine = strlower(info.channelName or "")
	Wanted:Print("Channels probe: %s (#%s); GetNumDisplayChannels=%s", tostring(info.channelName), tostring(info.channelId),
		GetNumDisplayChannels and tostring(GetNumDisplayChannels()) or "no function")
	local ours
	if GetNumDisplayChannels and GetChannelDisplayInfo then
		for i = 1, GetNumDisplayChannels() do
			local name, header, collapsed, number, count, active, category, channelType = GetChannelDisplayInfo(i)
			Wanted:Print("  %d: %s header=%s number=%s count=%s active=%s category=%s type=%s", i, tostring(name), tostring(header),
				tostring(number), tostring(count), tostring(active), tostring(category), tostring(channelType))
			if not header and type(name) == "string" and strlower(name) == mine then
				ours = i
			end
		end
	end
	local probe = CreateFrame("Frame")
	for _, ev in ipairs({ "CHANNEL_COUNT_UPDATE", "CHANNEL_ROSTER_UPDATE", "CHANNEL_UI_UPDATE", "CHAT_MSG_CHANNEL_LIST" }) do
		probe:RegisterEvent(ev)
	end
	probe:SetScript("OnEvent", function(_, event, ...)
		local args = { ... }
		local parts = {}
		for i = 1, select("#", ...) do
			local v = args[i]
			parts[i] = type(v) == "string" and ("'"..strsub(v, 1, 120).."'"..(#v > 120 and ("...("..#v..")") or "")) or tostring(v)
		end
		Wanted:Print("  event %s: %s", event, table.concat(parts, ", "))
		if event == "CHANNEL_ROSTER_UPDATE" and C_ChatInfo and C_ChatInfo.GetChannelRosterInfo then
			local n = 0
			local index = ...
			while n < 500 do
				local name = C_ChatInfo.GetChannelRosterInfo(index, n + 1)
				if not name then break end
				n = n + 1
			end
			Wanted:Print("  roster of display channel %s: %d names", tostring(index), n)
		end
	end)
	C_Timer.After(15, function() probe:UnregisterAllEvents() Wanted:Print("Channels probe: done listening.") end)
	if ours and SetSelectedDisplayChannel then
		Wanted:Print("  calling SetSelectedDisplayChannel(%d)", ours)
		SetSelectedDisplayChannel(ours)
	else
		Wanted:Print("  our channel is not in the display list (or no SetSelectedDisplayChannel)")
	end
	if ListChannelByName then
		Wanted:Print("  calling ListChannelByName(%s)", info.channelName)
		ListChannelByName(info.channelName)
	else
		Wanted:Print("  no ListChannelByName")
	end
end)

-- /wanted channelowner [unmod|unban <First Last>]: who owns and moderates the sync channel, which owner functions
-- this client has, and (with a name) whether an addon may undo a moderator or a ban without a click.
Wanted:RegisterCommand("channelowner", "Development builds: who owns and moderates the sync channel, and whether Wanted may undo a moderator or ban: /wanted channelowner [unmod|unban First Last]", function(args)
	local info = Wanted.Sync:GetInfo()
	local channel = info.channelName
	local funcs = {}
	for _, name in ipairs({ "ChannelModerate", "ChannelModerator", "ChannelUnmoderator", "ChannelBan", "ChannelUnban", "ChannelKick",
		"SetChannelOwner", "SetChannelPassword", "ChannelToggleAnnouncements", "DisplayChannelOwner", "IsDisplayChannelOwner" }) do
		tinsert(funcs, name..(type(_G[name]) == "function" and "" or " (missing)"))
	end
	Wanted:Print("Owner probe: %s (#%s). Functions: %s", tostring(channel), tostring(info.channelId), table.concat(funcs, ", "))
	-- The member list: asking for it makes the game send the roster (see Sync.RequestMembers)
	local index
	for i = 1, (GetNumDisplayChannels and GetNumDisplayChannels() or 0) do
		local name, header = GetChannelDisplayInfo(i)
		if not header and type(name) == "string" and channel and strlower(name) == strlower(channel) then
			index = i
		end
	end
	if not index then
		Wanted:Print("  the sync channel isn't in the game's channel list yet; try again in a moment")
		return
	end
	local action, target = strmatch(args or "", "^(%a+)%s+(.+)$")
	local watcher = CreateFrame("Frame")
	watcher:RegisterEvent("ADDON_ACTION_BLOCKED")
	watcher:RegisterEvent("ADDON_ACTION_FORBIDDEN")
	watcher:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE_USER")
	watcher:SetScript("OnEvent", function(_, event, a1, a2, _, a4, a5)
		Wanted:Print("  event %s: %s %s %s %s", event, tostring(a1), tostring(a2), tostring(a4), tostring(a5))
	end)
	C_Timer.After(8, function() watcher:UnregisterAllEvents() Wanted:Print("Owner probe: done.") end)
	-- The member list the game sends back: names comma-separated, the owner marked * and moderators @
	local lists = CreateFrame("Frame")
	lists:RegisterEvent("CHAT_MSG_CHANNEL_LIST")
	local lastList
	lists:SetScript("OnEvent", function(_, _, text, _, _, _, _, _, _, _, baseName)
		if type(baseName) == "string" and channel and strlower(baseName) == strlower(channel) then
			lastList = text
		end
	end)
	C_Timer.After(8, function() lists:UnregisterAllEvents() end)
	local function Roster(label)
		if type(lastList) ~= "string" then
			Wanted:Print("  %s: the game sent no member list", label)
			return
		end
		local me = Wanted.Store:GetOrigin()
		local total, owner, mods, mine = 0, nil, {}, "not listed"
		for entry in string.gmatch(lastList, "[^,]+") do
			entry = strtrim(entry)
			local marks, name = strmatch(entry, "^([%*@]*)(.+)$")
			if name and name ~= "" then
				total = total + 1
				if strfind(marks, "%*") then owner = name end
				if strfind(marks, "@") then tinsert(mods, name) end
				if name == me or name == strmatch(me, "^(%S+)") then
					mine = strfind(marks, "%*") and "owner" or strfind(marks, "@") and "moderator" or "member"
				end
			end
		end
		Wanted:Print("  %s: %d listed; owner %s; moderators %s; you are %s. Raw: %s", label, total, tostring(owner),
			#mods > 0 and table.concat(mods, ", ") or "none", mine, strsub(lastList, 1, 200))
	end
	ListChannelByName(channel)
	C_Timer.After(2, function()
		Roster("before")
		if not action then
			return
		end
		local func = (action == "unmod" and ChannelUnmoderator) or (action == "unban" and ChannelUnban) or nil
		if not func then
			Wanted:Print("  unknown action %s: use unmod or unban", tostring(action))
			return
		end
		local ok, err = pcall(func, channel, target)
		Wanted:Print("  %s(%s, %s) called: %s", action == "unmod" and "ChannelUnmoderator" or "ChannelUnban", channel, target,
			ok and "no error" or tostring(err))
		C_Timer.After(1, function() lastList = nil ListChannelByName(channel) end)
		C_Timer.After(3, function() Roster("after") end)
	end)
end)

-- /wanted who <name>: whether an addon may run a /who search from a slash command and read the results (full names
-- and guilds). SendWho is restricted, so the game may block it; the blocked and forbidden events say so.
Wanted:RegisterCommand("who", "Development builds: tries a /who search for a name and prints what the game returns: /wanted who [ui|later] <name>", function(args)
	-- ui: results to the Who window (does the game then tell the addon?); later: sent a second after the command,
	-- with no key press behind it (can it run in the background?)
	local mode, rest = strmatch(strtrim(args or ""), "^(%a+)%s+(.+)$")
	local name = strtrim(args or "")
	if mode == "ui" or mode == "later" then
		name = strtrim(rest)
	else
		mode = nil
	end
	if name == "" then
		Wanted:Print("Usage: /wanted who [ui|later] <name>")
		return
	end
	local list = C_FriendList
	if type(list) ~= "table" then
		Wanted:Print("Who probe: C_FriendList missing")
		return
	end
	-- A secret value can't be printed or compared, so it's named instead
	local function Show(value)
		if issecretvalue and issecretvalue(value) then
			return "(secret)"
		end
		return tostring(value)
	end
	local function Results()
		if not list.GetNumWhoResults then
			Wanted:Print("  GetNumWhoResults missing")
			return
		end
		local ok, count = pcall(list.GetNumWhoResults)
		Wanted:Print("  results: %s", ok and Show(count) or ("error "..tostring(count)))
		if not ok or type(count) ~= "number" or (issecretvalue and issecretvalue(count)) then
			return
		end
		if not list.GetWhoInfo then
			Wanted:Print("  GetWhoInfo missing")
			return
		end
		for i = 1, min(count, 5) do
			local got, info = pcall(list.GetWhoInfo, i)
			if not got then
				Wanted:Print("  %d: error %s", i, tostring(info))
			elseif type(info) ~= "table" then
				Wanted:Print("  %d: %s", i, Show(info))
			else
				Wanted:Print("  %d: %s <%s> level %s %s in %s (%s, gender %s)", i, Show(info.fullName), Show(info.fullGuildName), Show(info.level),
					Show(info.classStr), Show(info.area), Show(info.filename), Show(info.gender))
			end
		end
	end
	local probe = CreateFrame("Frame")
	for _, event in ipairs({ "WHO_LIST_UPDATE", "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN", "CHAT_MSG_SYSTEM" }) do
		probe:RegisterEvent(event)
	end
	probe:SetScript("OnEvent", function(_, event, a1, a2, a3)
		if event == "CHAT_MSG_SYSTEM" then
			-- The answer as a chat line: shown raw (|| for the link codes), then read with the game's own format
			if type(a1) == "string" and not (issecretvalue and issecretvalue(a1)) and (strfind(a1, "Level", 1, true) or strfind(a1, "total", 1, true)) then
				Wanted:Print("  chat line: %s", (gsub(a1, "|", "||")))
				local plain = gsub(gsub(gsub(gsub(a1, "|c%x%x%x%x%x%x%x%x", ""), "|r", ""), "|Hplayer:[^|]*|h", ""), "|h", "")
				local who, level, race, class, guild, zone = strmatch(plain, "^%[(.-)%]: Level (%d+) (.-) (%a+) <(.-)> %- (.+)$")
				if not who then
					who, level, race, class, zone = strmatch(plain, "^%[(.-)%]: Level (%d+) (.-) (%a+) %- (.+)$")
				end
				if who then
					Wanted:Print("  read from chat: %s, level %s %s %s, guild %s, in %s", who, level, race, class, tostring(guild or "none"), zone)
				end
			end
			return
		end
		Wanted:Print("  event %s: %s %s %s", event, Show(a1), Show(a2), Show(a3))
		if event == "WHO_LIST_UPDATE" then
			Results()
		end
	end)
	C_Timer.After(10, function() probe:UnregisterAllEvents() Wanted:Print("Who probe: done.") end)
	if list.SetWhoToUi then
		local ok, err = pcall(list.SetWhoToUi, mode == "ui")
		Wanted:Print("  SetWhoToUi(%s): %s", tostring(mode == "ui"), ok and "no error" or tostring(err))
	else
		Wanted:Print("  SetWhoToUi missing")
	end
	if not list.SendWho then
		Wanted:Print("  SendWho missing")
		return
	end
	local query = 'n-"'..name..'"'
	local function Send()
		local ok, err = pcall(list.SendWho, query)
		Wanted:Print("  SendWho(%s)%s: %s", query, mode == "later" and " a second later, from a timer" or "", ok and "no error" or tostring(err))
	end
	if mode == "later" then
		C_Timer.After(1, Send)
	else
		Send()
	end
end)

Wanted:RegisterCommand("guildrank", "Development builds: prints what the game says about your guild rank and your guild's officers, and what Wanted kept: /wanted guildrank", function()
	local function Show(value)
		if issecretvalue and issecretvalue(value) then
			return "(secret)"
		end
		return tostring(value)
	end
	local function Ask(name, f, ...)
		if not f then
			Wanted:Print("  %s: missing", name)
			return
		end
		local results = { pcall(f, ...) }
		if not results[1] then
			Wanted:Print("  %s: error %s", name, tostring(results[2]))
			return
		end
		local shown = {}
		for i = 2, #results do
			shown[#shown + 1] = Show(results[i])
		end
		Wanted:Print("  %s: %s", name, table.concat(shown, ", "))
		return unpack(results, 2)
	end
	Wanted:Print("Guild rank probe:")
	Ask("IsInGuild", IsInGuild)
	Ask("GetGuildInfo(player)", GetGuildInfo, "player")
	Ask("IsGuildLeader", IsGuildLeader)
	Ask("C_GuildInfo.IsGuildOfficer", C_GuildInfo and C_GuildInfo.IsGuildOfficer)
	local club = Ask("C_Club.GetGuildClubId", C_Club and C_Club.GetGuildClubId)
	if club ~= nil and not (issecretvalue and issecretvalue(club)) and C_Club.GetClubMembers then
		local ok, ids = pcall(C_Club.GetClubMembers, club)
		Wanted:Print("  members: %s", ok and type(ids) == "table" and #ids or ("error "..tostring(ids)))
		for i = 1, ok and type(ids) == "table" and min(#ids, 8) or 0 do
			local got, info = pcall(C_Club.GetMemberInfo, club, ids[i])
			if got and type(info) == "table" then
				Wanted:Print("  %d: %s rank %s (%s) role %s %s", i, Show(info.name), Show(info.guildRankOrder), Show(info.guildRank), Show(info.role), Show(info.guid))
			else
				Wanted:Print("  %d: %s", i, tostring(info))
			end
		end
	end
	local own = Wanted.db.guildRanks[UnitGUID("player")]
	Wanted:Print("  kept: %s", own and format("<%s> %s (%d) officer %s", own.g, own.rn, own.ri, tostring(own.o)) or "nothing yet")
	for guild, entry in pairs(Wanted.db.guildOfficers) do
		local n = 0
		for _ in pairs(entry.m) do
			n = n + 1
		end
		Wanted:Print("  officers kept for <%s>: %d", guild, n)
	end
end)

-- Three pretend kills two seconds apart, from timers (as a real kill comes, not from a click or a typed command), so
-- the callouts, the sound and the party or guild line can be tried without a fight. Starts from a clean streak.
Wanted:RegisterCommand("streaktest", "Development builds: three pretend kills 2 s apart to try the streak callouts and the party or guild line: /wanted streaktest", function()
	Wanted.Streaks:OnDeath()
	for i = 1, 3 do
		C_Timer.After(2 * i, function()
			Wanted.Streaks:OnKill("Streak Test "..i)
		end)
	end
	Wanted:Print("Streak test: three pretend kills over the next 6 seconds. Nothing is recorded.")
end)
