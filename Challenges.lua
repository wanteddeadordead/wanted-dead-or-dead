-- Wanted: daily and weekly challenges, hot zones and challenge ranks. wanteddeadordead.com works everything out;
-- the desktop app puts it in the catch-up (WantedAppCatchup[mark].challenges) and the addon only shows it. Nothing
-- here is computed from the addon's own records or sent to other players. Missing data (no app, an older app, the
-- server off) leaves the pages on their empty state.

local _, Wanted = ...
local Challenges = Wanted:NewModule("Challenges")
local private = {
	data = nil, -- the cleaned challenges from this login's catch-up
	demo = nil, -- development builds: made-up challenges to look at (/wanted demo)
}

-- Challenge ranks, copied from the server's stats.ChallengeRanks: the points each rank starts at, and its title
-- on each side. The badges are the game's own PvP rank badges.
Challenges.MAX_RANK = 14
Challenges.THRESHOLDS = { 5, 40, 120, 260, 480, 800, 1250, 1850, 2650, 3700, 5100, 7000, 9600, 13000 }
Challenges.TITLES = {
	Alliance = { "Private", "Corporal", "Sergeant", "Master Sergeant", "Sergeant Major", "Knight", "Knight-Lieutenant",
		"Knight-Captain", "Knight-Champion", "Lieutenant Commander", "Commander", "Marshal", "Field Marshal", "Grand Marshal" },
	Horde = { "Scout", "Grunt", "Sergeant", "Senior Sergeant", "First Sergeant", "Stone Guard", "Blood Guard", "Legionnaire",
		"Centurion", "Champion", "Lieutenant General", "General", "Warlord", "High Warlord" },
}

-- What the catch-up may hold at most: more is cut off rather than refused
local MAX_HOT = 4
local MAX_WEEKLY = 3
local MAX_ME = 60
local MAX_RECENT = 10
local MAX_RANKS = 5000
local MAX_TEXT = 80
-- Completions noted for the banner are forgotten after this long
local NOTE_KEEP_SECONDS = 21 * 24 * 60 * 60
-- After login, so the banner isn't lost behind the loading screen
local BANNER_DELAY = 8

function Challenges:OnLoad()
	-- character GUID -> { rank, done = { [challenge id] = when noted } }: what the banner already said (docs/DATA.md)
	Wanted.db.challengeNotes = type(Wanted.db.challengeNotes) == "table" and Wanted.db.challengeNotes or {}
end



-- ============================================================================
-- Reading the catch-up
-- ============================================================================

function private.CountKeys(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

---Text from the server, safe to show: a string, no escape codes, trimmed and cut to a length. nil otherwise.
function private.Text(value, maxLength)
	if type(value) ~= "string" then
		return nil
	end
	local text = strtrim((gsub(value, "|", "")))
	if text == "" then
		return nil
	end
	return strsub(text, 1, maxLength or MAX_TEXT)
end

---A whole number at least low (and at most high), or nil.
function private.Count(value, low, high)
	if type(value) ~= "number" or value ~= value or value ~= floor(value) or value < (low or 0) or (high and value > high) then
		return nil
	end
	return value
end

---A challenge's description: { id, name, text, target, points, hot }, or nil.
function private.CleanChallenge(c)
	if type(c) ~= "table" then
		return nil
	end
	local out = {
		id = private.Text(c.id, 64), name = private.Text(c.name), text = private.Text(c.text, 120),
		target = private.Count(c.target, 1), points = private.Count(c.points, 0) or 0, hot = c.hot == true,
	}
	if not out.id or not out.name or not out.target then
		return nil
	end
	return out
end

---Progress on one challenge: { n, done }.
function private.CleanProgress(p)
	if type(p) ~= "table" then
		return { n = 0, done = false }
	end
	return { n = private.Count(p.n, 0) or 0, done = p.done == true }
end

---One of the app's characters: progress, streak, rank and points. nil when malformed.
function private.CleanMine(m)
	if type(m) ~= "table" then
		return nil
	end
	local out = {
		daily = private.CleanProgress(m.daily),
		weekly = {},
		streak = private.Count(m.streak, 0) or 0,
		rank = private.Count(m.rank, 0, Challenges.MAX_RANK) or 0,
		points = private.Count(m.points, 0) or 0,
		nextAt = private.Count(m.nextAt, 1),
		recent = {},
	}
	for i = 1, MAX_WEEKLY do
		out.weekly[i] = private.CleanProgress(type(m.weekly) == "table" and m.weekly[i] or nil)
	end
	if type(m.recent) == "table" then
		for i = 1, min(#m.recent, MAX_RECENT) do
			local r = m.recent[i]
			local name = type(r) == "table" and private.Text(r.name)
			local at = type(r) == "table" and private.Count(r.at, 1)
			if name and at then
				tinsert(out.recent, { name = name, points = private.Count(r.points, 0) or 0, at = at })
			end
		end
	end
	return out
end

---The challenges part of a catch-up, checked field by field: the copy to show, or nil when it isn't there or
---can't be read. Parts that are missing or malformed are left out; the rest still shows.
---@param raw any
---@return table?
function Challenges:Clean(raw)
	if type(raw) ~= "table" or not private.Count(raw.t, 1) then
		return nil
	end
	local out = {
		t = raw.t,
		day = private.Text(raw.day, 16),
		dayEnds = private.Count(raw.dayEnds, 1),
		weekEnds = private.Count(raw.weekEnds, 1),
		hot = {},
		daily = private.CleanChallenge(raw.daily),
		weekly = {},
		allThreeBonus = private.Count(raw.allThreeBonus, 0),
		me = {},
		ranks = {},
	}
	if type(raw.hot) == "table" then
		for i = 1, min(#raw.hot, MAX_HOT) do
			local h = raw.hot[i]
			local zone = type(h) == "table" and private.Text(h.zone, 64)
			if zone then
				tinsert(out.hot, { zone = zone, band = private.Text(h.band, 16) })
			end
		end
	end
	if type(raw.weekly) == "table" then
		for i = 1, min(#raw.weekly, MAX_WEEKLY) do
			local c = private.CleanChallenge(raw.weekly[i])
			if not c then
				break
			end
			out.weekly[i] = c
		end
	end
	if type(raw.me) == "table" then
		local count = 0
		for guid, m in pairs(raw.me) do
			if count >= MAX_ME then
				break
			end
			if type(guid) == "string" and strfind(guid, "^Player%-%d+%-%w+$") then
				local mine = private.CleanMine(m)
				if mine then
					out.me[guid] = mine
					count = count + 1
				end
			end
		end
	end
	if type(raw.ranks) == "table" then
		local count = 0
		for name, r in pairs(raw.ranks) do
			if count >= MAX_RANKS then
				break
			end
			local rank = type(r) == "table" and private.Count(r.r, 1, Challenges.MAX_RANK)
			if type(name) == "string" and #name <= 64 and not strfind(name, "|", 1, true) and rank and (r.f == "H" or r.f == "A") then
				out.ranks[strlower(name)] = { r = rank, f = r.f }
				count = count + 1
			end
		end
	end
	return out
end

---Takes the challenges from this login's catch-up (Catchup:Import), and a little later shows a banner for what
---this character newly finished or a rank it newly reached.
---@param raw any entry.challenges as the app wrote it
---@param noCatchup boolean? the app wrote no catch-up for this account at all
function Challenges:Take(raw, noCatchup)
	-- A catch-up for this account means the app is there: without challenges in it, it's an older app
	private.appSeen = not noCatchup
	private.data = Challenges:Clean(raw)
	if raw ~= nil and not private.data then
		Wanted:Log("Challenges: the catch-up's challenges could not be read")
	elseif private.data then
		Wanted:Log("Challenges: from %s, %d hot zones, %d of your characters, %d ranks", Wanted.Theme:Ago(GetServerTime() - private.data.t),
			#private.data.hot, private.CountKeys(private.data.me), private.CountKeys(private.data.ranks))
		C_Timer.After(BANNER_DELAY, function() Challenges:CheckNews() end)
	end
end



-- ============================================================================
-- Reading what's there
-- ============================================================================

---The challenges to show: the demo's while it's on, otherwise this login's from the app; nil without either.
---@return table?
function Challenges:Get()
	return private.demo or private.data
end

-- The app version that first brings challenges, for the empty state's update line
Challenges.APP_VERSION = "0.2.27"

---Whether the Wanted app is on this computer: it wrote this account a catch-up, or says its version.
---@return boolean
function Challenges:HasApp()
	return private.appSeen == true or Wanted:AppVersion() ~= nil
end

---The empty state's heading, line and button when there are no challenges: get the app, or update it when it's
---there but too old to bring them.
---@return string title
---@return string line
---@return string button
function Challenges:EmptyText()
	if Challenges:HasApp() then
		return "Update the Wanted app to track challenges and ranks",
			"Already updated it? Type /reload to load your challenges. Otherwise open the app and it updates itself, or download "..Challenges.APP_VERSION.." from wanteddeadordead.com/app.", "Update the app"
	end
	return "Get the Wanted app to track challenges and ranks", "Download it for Windows or Mac from wanteddeadordead.com/app.", "Get the app"
end

---This character's progress, streak and rank (or another of the app's characters'), or nil.
---@param guid string?
---@return table?
function Challenges:GetMine(guid)
	local data = Challenges:Get()
	return data and data.me[guid or UnitGUID("player")] or nil
end

---Today's hot zone with this name ({ zone, band }), or nil. Zones are named as wanteddeadordead.com names them.
---@param zone string?
---@return table?
function Challenges:GetHot(zone)
	local data = Challenges:Get()
	if not data or type(zone) ~= "string" or (data.dayEnds and GetServerTime() >= data.dayEnds) then
		return nil
	end
	local wanted = strlower(zone)
	for _, hot in ipairs(data.hot) do
		if strlower(hot.zone) == wanted then
			return hot
		end
	end
	return nil
end

---Whether the day the challenges were made for is over (the app hasn't brought the next one yet).
---@return boolean
function Challenges:IsDayOver()
	local data = Challenges:Get()
	return data ~= nil and data.dayEnds ~= nil and GetServerTime() >= data.dayEnds
end

---Whether the week the weekly challenges were made for is over.
---@return boolean
function Challenges:IsWeekOver()
	local data = Challenges:Get()
	return data ~= nil and data.weekEnds ~= nil and GetServerTime() >= data.weekEnds
end

---A rank's title on a side ("Horde" or "Alliance", or "H" / "A"); this character's side by default.
---@param rank number
---@param faction string?
---@return string?
function Challenges:Title(rank, faction)
	faction = faction == "A" and "Alliance" or faction == "H" and "Horde" or faction or UnitFactionGroup("player")
	local titles = Challenges.TITLES[faction] or Challenges.TITLES.Horde
	return titles[rank]
end

---The points a rank starts at (0 for no rank).
---@param rank number
---@return number
function Challenges:Threshold(rank)
	return Challenges.THRESHOLDS[rank] or 0
end

---The game's PvP rank badge for a rank (1 to 14).
---@param rank number
---@return string?
function Challenges:Badge(rank)
	if not private.Count(rank, 1, Challenges.MAX_RANK) then
		return nil
	end
	return format("Interface\\PvPRankBadges\\PvPRank%02d", rank)
end

---Daily and weekly challenges done out of those there are, for this character: done, total. nil without them.
---@return number? done
---@return number? total
function Challenges:CountDone()
	local data, mine = Challenges:Get(), Challenges:GetMine()
	if not data or not mine then
		return nil
	end
	local done, total = 0, 0
	if data.daily and not Challenges:IsDayOver() then
		total = total + 1
		done = done + (mine.daily.done and 1 or 0)
	end
	if not Challenges:IsWeekOver() then
		for i in ipairs(data.weekly) do
			total = total + 1
			done = done + (mine.weekly[i].done and 1 or 0)
		end
	end
	if total == 0 then
		return nil
	end
	return done, total
end

---A player's challenge rank from wanteddeadordead.com: { r, f }, or nil. Never what a player says of themselves.
---@param name string? "Name" or "Name-Realm"
---@return table?
---@param faction string? "Horde" or "Alliance", when known: the demo's made-up ranks use it
function Challenges:GetRank(name, faction)
	local data = Challenges:Get()
	if not data or type(name) ~= "string" then
		return nil
	end
	local key = strlower((strsplit("-", name)))
	if data.ranks[key] or not private.demo or key == "" then
		return data.ranks[key] or nil
	end
	-- The demo ranks every player, the same rank for the same name, so each place a rank shows can be seen on
	-- real players
	local sum = 0
	for i = 1, #key do
		sum = (sum * 31 + key:byte(i)) % 1000003
	end
	faction = faction or UnitFactionGroup("player")
	return { r = sum % Challenges.MAX_RANK + 1, f = faction == "Alliance" and "A" or "H" }
end



-- ============================================================================
-- Banner for what's newly done
-- ============================================================================

---What this character finished or reached since the banner last spoke: a list of { name, points } and the new
---rank or nil. Notes it, so each completion is announced once. The first time a character is seen, what's
---already done is only noted.
---@return table[] done
---@return number? rank
function Challenges:TakeNews()
	local data, guid = private.data, UnitGUID("player")
	local mine = data and guid and data.me[guid]
	if not mine then
		return {}, nil
	end
	local notes = Wanted.db.challengeNotes
	local now = GetServerTime()
	for _, note in pairs(notes) do
		for id, t in pairs(type(note.done) == "table" and note.done or {}) do
			if type(t) ~= "number" or now - t > NOTE_KEEP_SECONDS then
				note.done[id] = nil
			end
		end
	end
	local first = type(notes[guid]) ~= "table"
	local note = not first and notes[guid] or { rank = mine.rank, done = {} }
	notes[guid] = note
	note.done = type(note.done) == "table" and note.done or {}
	local done = {}
	local function Check(challenge, progress)
		if challenge and progress.done and not note.done[challenge.id] then
			note.done[challenge.id] = now
			if not first then
				tinsert(done, { name = challenge.name, points = challenge.points })
			end
		end
	end
	Check(data.daily, mine.daily)
	for i, challenge in ipairs(data.weekly) do
		Check(challenge, mine.weekly[i])
	end
	local rank = nil
	if not first and mine.rank > (tonumber(note.rank) or 0) then
		rank = mine.rank
	end
	note.rank = mine.rank
	return done, rank
end

---Shows a banner (and a chat line) for what this character newly finished or reached.
function Challenges:CheckNews()
	local done, rank = Challenges:TakeNews()
	Challenges:Announce(done, rank)
end

---The banner and chat line for completions and a rank-up.
---@param done table[] { name, points }
---@param rank number?
function Challenges:Announce(done, rank)
	local C = Wanted.Theme.C
	local names = {}
	for _, d in ipairs(done) do
		tinsert(names, format("%s (+%d)", d.name, d.points))
	end
	local doneText = #names > 0 and table.concat(names, ", ") or nil
	if rank then
		local title = Challenges:Title(rank) or ("Rank "..rank)
		Wanted:Print("Challenge rank %d: %s.%s", rank, title, doneText and (" Done: "..doneText..".") or "")
		Wanted.Alerts:Warn("RANK UP: "..strupper(title), doneText and ("Challenge rank "..rank..". Done: "..doneText) or ("Challenge rank "..rank), C.gold)
	elseif doneText then
		Wanted:Print("Challenge done: %s.", doneText)
		Wanted.Alerts:Warn(#done == 1 and "CHALLENGE DONE" or format("%d CHALLENGES DONE", #done), doneText, C.gold)
	else
		return
	end
	Wanted.Alerts:Sound("important")
	if Wanted.UI and Wanted.UI.Refresh then
		Wanted.UI:Refresh()
	end
end



-- ============================================================================
-- Demo (development builds)
-- ============================================================================

---Development builds: shows made-up challenges (or the real ones again with nil), so the pages can be seen
---before the app brings any. Nothing of it is saved.
---@param demo table?
function Challenges:SetDemo(demo)
	private.demo = demo and Challenges:Clean(demo) or nil
	if Wanted.UI and Wanted.UI.Refresh then
		Wanted.UI:Refresh(true)
	end
end

function Challenges:IsDemo()
	return private.demo ~= nil
end

function Challenges:Status()
	local data = Challenges:Get()
	if not data then
		return "Challenges: none from the app"
	end
	return format("Challenges: %sfrom %s, %d hot zones, %d ranks", private.demo and "demo, " or "", Wanted.Theme:Ago(GetServerTime() - data.t),
		#data.hot, private.CountKeys(data.ranks))
end
