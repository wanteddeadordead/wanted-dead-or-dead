-- Wanted: battleground probe, for development builds only. It notes what the game shows an addon about battlegrounds:
-- the instance type of each PvP zone entered (and of new zones, in case a battleground is part of the open world),
-- the match's state changes, battleground system messages, the scoreboard widgets at the top of the screen, and the
-- scoreboard itself, once mid-match (to see which fields are hidden then) and again at the end. All of it stays in
-- the saved data for Chris to read; nothing is sent and nothing counts as world PvP. Outside a PvP zone it only
-- looks at zone changes.

local _, Wanted = ...
local BGProbe = Wanted:NewModule("BGProbe")
local private = {
	frame = CreateFrame("Frame"),
	match = nil, -- the match record being written, while in a PvP zone
	ticker = nil, -- the widget snapshot every minute, while in a match
	listening = false, -- whether the in-match events are registered
}
-- Matches kept; a new one drops the oldest
BGProbe.MAX_MATCHES = 5
-- Zones remembered, so a new one is noted even in the open world
BGProbe.MAX_ZONES = 20
-- Zone entries noted (PvP zones and new zones)
BGProbe.MAX_ENTRIES = 40
-- Per match: state changes and other events, system messages, widget snapshots, and end-of-match score reads
BGProbe.MAX_EVENTS = 100
BGProbe.MAX_CHAT = 200
BGProbe.MAX_WIDGET_SNAPSHOTS = 60
BGProbe.MAX_SCORE_READS = 3
-- Rows kept from the one mid-match read: enough to see which fields are hidden
BGProbe.MID_ROWS = 10
BGProbe.SECRET = "<secret>"
local WIDGET_SECONDS = 60
local MAX_DEPTH = 4
-- Enum.PvPMatchState.Complete
local STATE_COMPLETE = 5
-- Events listened to only inside a match
local MATCH_EVENTS = { "CHAT_MSG_BG_SYSTEM_ALLIANCE", "CHAT_MSG_BG_SYSTEM_HORDE", "CHAT_MSG_BG_SYSTEM_NEUTRAL", "UPDATE_BATTLEFIELD_SCORE" }

---Whether the probe runs: development builds only, so a release never collects any of this.
---@return boolean
function BGProbe:IsOn()
	return Wanted:IsDevVersion(Wanted.VERSION)
end

function BGProbe:OnLoad()
	if not BGProbe:IsOn() then
		return
	end
	local probe = Wanted.db.bgProbe or {}
	probe.matches = probe.matches or {}
	probe.zones = probe.zones or {}
	probe.entries = probe.entries or {}
	Wanted.db.bgProbe = probe
end

function BGProbe:OnEnable()
	if not BGProbe:IsOn() then
		return
	end
	for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "PVP_MATCH_ACTIVE", "PVP_MATCH_STATE_CHANGED", "PVP_MATCH_COMPLETE" }) do
		private.frame:RegisterEvent(event)
	end
	private.frame:SetScript("OnEvent", function(_, event, ...)
		if BGProbe:IsOn() and Wanted.db.bgProbe then
			BGProbe:OnEvent(event, ...)
		end
	end)
end

function private.Data()
	return Wanted.db.bgProbe
end



-- ============================================================================
-- Plain values
-- ============================================================================

---A copy that is safe to save: hidden values become "<secret>", tables are copied (a few levels deep), and
---functions or frames become their type name.
---@param value any
---@param depth? number
---@return any
function BGProbe:Plain(value, depth)
	if issecretvalue and issecretvalue(value) then
		return BGProbe.SECRET
	end
	local kind = type(value)
	if kind == "table" then
		depth = (depth or 0) + 1
		if depth > MAX_DEPTH then
			return "<table>"
		end
		local copy = {}
		for key, inner in pairs(value) do
			if issecretvalue and issecretvalue(key) then
				key = BGProbe.SECRET
			end
			if type(key) == "string" or type(key) == "number" then
				copy[key] = BGProbe:Plain(inner, depth)
			end
		end
		return copy
	elseif kind == "string" or kind == "number" or kind == "boolean" or kind == "nil" then
		return value
	end
	return "<"..kind..">"
end

---Calls a game function that may be missing or fail, and returns its results as a saved-safe list.
---@param func function?
---@return table
function private.Call(func, ...)
	if type(func) ~= "function" then
		return { missing = true }
	end
	local results = { pcall(func, ...) }
	if not results[1] then
		return { err = tostring(results[2]) }
	end
	tremove(results, 1)
	return BGProbe:Plain(results)
end

---The first result of a C_PvP function, saved-safe, or nil.
function private.PvP(name, ...)
	local result = private.Call(C_PvP and C_PvP[name], ...)
	if result.missing or result.err then
		return nil
	end
	return result[1]
end

function private.Append(list, cap, entry)
	if #list < cap then
		tinsert(list, entry)
		return true
	end
	return false
end



-- ============================================================================
-- Zones
-- ============================================================================

---What the game says about where the player is.
---@return table
function private.Snapshot()
	local where = private.Call(IsInInstance)
	local instance = private.Call(GetInstanceInfo)
	return {
		t = GetServerTime(),
		inInstance = where[1],
		instanceType = where[2],
		isBattleground = private.PvP("IsBattleground"),
		isActiveBattlefield = private.PvP("IsActiveBattlefield"),
		isMatchActive = private.PvP("IsMatchActive"),
		matchState = private.PvP("GetActiveMatchState"),
		zone = private.Call(GetZoneText)[1],
		mapId = private.Call(C_Map and C_Map.GetBestMapForUnit, "player")[1],
		-- name, instanceType, difficultyID, difficultyName, maxPlayers, dynamicDifficulty, isDynamic, instanceID,
		-- instanceGroupSize, LfgDungeonID
		instance = instance,
	}
end

---Whether a snapshot looks like a PvP match: a pvp or arena instance, or C_PvP saying so (an open-world one).
---@param snap table
---@return boolean
function private.IsPvP(snap)
	return snap.instanceType == "pvp" or snap.instanceType == "arena" or snap.isBattleground == true
		or snap.isActiveBattlefield == true or snap.isMatchActive == true
end

---Remembers a zone; true when it wasn't among the remembered ones.
function private.NoteZone(snap)
	local zones = private.Data().zones
	local name = tostring(snap.zone)
	for i, zone in ipairs(zones) do
		if zone.name == name then
			tremove(zones, i)
			tinsert(zones, { name = name, instanceType = snap.instanceType, t = snap.t })
			return false
		end
	end
	tinsert(zones, { name = name, instanceType = snap.instanceType, t = snap.t })
	while #zones > BGProbe.MAX_ZONES do
		tremove(zones, 1)
	end
	return true
end

---On entering the world or a new zone: notes PvP zones and new zones, and starts or ends the match record.
function BGProbe:OnZone(event)
	local snap = private.Snapshot()
	snap.event = event
	local isNew = private.NoteZone(snap)
	local pvp = private.IsPvP(snap)
	if pvp or isNew then
		local entries = private.Data().entries
		tinsert(entries, snap)
		while #entries > BGProbe.MAX_ENTRIES do
			tremove(entries, 1)
		end
	end
	if pvp then
		private.StartMatch(snap)
	elseif private.match then
		private.EndMatch()
	end
end



-- ============================================================================
-- The match
-- ============================================================================

function private.StartMatch(snap)
	if not private.match then
		local matches = private.Data().matches
		private.match = { started = snap.t, zone = snap.zone, entry = snap, events = {}, chat = {}, widgets = {}, scoreReads = {} }
		private.match.teamsAtStart = { private.PvP("GetTeamInfo", 0) or false, private.PvP("GetTeamInfo", 1) or false }
		tinsert(matches, private.match)
		while #matches > BGProbe.MAX_MATCHES do
			tremove(matches, 1)
		end
		private.NoteEvent("start")
	end
	if not private.listening then
		private.listening = true
		for _, event in ipairs(MATCH_EVENTS) do
			private.frame:RegisterEvent(event)
		end
		private.ticker = C_Timer.NewTicker(WIDGET_SECONDS, function()
			BGProbe:SnapWidgets()
		end)
		BGProbe:SnapWidgets()
	end
end

function private.EndMatch()
	private.NoteEvent("left")
	private.match.left = GetServerTime()
	private.match = nil
	if private.listening then
		private.listening = false
		for _, event in ipairs(MATCH_EVENTS) do
			private.frame:UnregisterEvent(event)
		end
	end
	if private.ticker then
		private.ticker:Cancel()
		private.ticker = nil
	end
end

function private.NoteEvent(name, extra)
	local match = private.match
	if match then
		private.Append(match.events, BGProbe.MAX_EVENTS, { t = GetServerTime(), event = name, state = private.PvP("GetActiveMatchState"), extra = extra })
	end
end

function BGProbe:OnEvent(event, ...)
	if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
		BGProbe:OnZone(event)
		return
	end
	-- A match event in a zone not yet seen as PvP (an open-world battleground) starts the record
	if not private.match and (event == "PVP_MATCH_ACTIVE" or event == "PVP_MATCH_STATE_CHANGED" or event == "PVP_MATCH_COMPLETE") then
		local snap = private.Snapshot()
		snap.event = event
		private.StartMatch(snap)
	end
	if not private.match then
		return
	end
	if event == "PVP_MATCH_COMPLETE" then
		local winner, duration = ...
		private.NoteEvent(event, BGProbe:Plain({ winner = winner, duration = duration }))
		private.Complete()
	elseif event == "PVP_MATCH_ACTIVE" or event == "PVP_MATCH_STATE_CHANGED" then
		private.NoteEvent(event)
		if private.PvP("GetActiveMatchState") == STATE_COMPLETE then
			private.Complete()
		end
	elseif event == "UPDATE_BATTLEFIELD_SCORE" then
		BGProbe:OnScore()
	else
		local text = ...
		private.Append(private.match.chat, BGProbe.MAX_CHAT, { t = GetServerTime(), event = event, text = BGProbe:Plain(text) })
	end
end

---The match is over: notes the result and asks for the final scoreboard.
function private.Complete()
	local match = private.match
	if match.complete then
		return
	end
	match.complete = GetServerTime()
	match.winner = private.PvP("GetActiveMatchWinner")
	match.duration = private.PvP("GetActiveMatchDuration")
	match.teams = { private.PvP("GetTeamInfo", 0) or false, private.PvP("GetTeamInfo", 1) or false }
	BGProbe:SnapWidgets()
	private.Call(RequestBattlefieldScoreData)
end

---Each widget in the top-center set: its type and what it shows.
function BGProbe:SnapWidgets()
	local match = private.match
	if not match or not C_UIWidgetManager then
		return
	end
	local setId = private.Call(C_UIWidgetManager.GetTopCenterWidgetSetID)[1]
	local snap = { t = GetServerTime(), setId = setId, widgets = {} }
	if type(setId) == "number" then
		local widgets = private.Call(C_UIWidgetManager.GetAllWidgetsBySetID, setId)[1]
		for _, widget in ipairs(type(widgets) == "table" and widgets or {}) do
			local entry = { id = widget.widgetID, type = widget.widgetType }
			-- The game's own widget code knows which function reads each widget type
			local typeInfo = UIWidgetManager and UIWidgetManager.GetWidgetTypeInfo and UIWidgetManager:GetWidgetTypeInfo(widget.widgetType)
			if typeInfo and typeInfo.visInfoDataFunction and type(widget.widgetID) == "number" then
				entry.info = private.Call(typeInfo.visInfoDataFunction, widget.widgetID)[1]
			end
			tinsert(snap.widgets, entry)
		end
	end
	private.Append(match.widgets, BGProbe.MAX_WIDGET_SNAPSHOTS, snap)
	-- One scoreboard read during the match, to see which fields are hidden then
	if not match.complete and not match.midAsked then
		match.midAsked = true
		private.Call(RequestBattlefieldScoreData)
	end
end

---The scoreboard rows and the map's own columns.
---@param limit? number
---@return table
function private.ReadScores(limit)
	local count = private.Call(GetNumBattlefieldScores)[1]
	local read = { t = GetServerTime(), count = count, rows = {} }
	if type(count) == "number" then
		for i = 1, min(count, limit or count) do
			tinsert(read.rows, private.Call(C_PvP and C_PvP.GetScoreInfo, i)[1] or false)
		end
	end
	read.columns = private.PvP("GetMatchPVPStatColumns")
	return read
end

function BGProbe:OnScore()
	local match = private.match
	if not match.complete then
		if not match.mid then
			match.mid = private.ReadScores(BGProbe.MID_ROWS)
		end
		return
	end
	if #match.scoreReads >= BGProbe.MAX_SCORE_READS then
		return
	end
	local read = private.ReadScores()
	tinsert(match.scoreReads, read)
	match.scores = read
	if #match.scoreReads == 1 then
		Wanted:Print("battleground probe saved (%d players). /reload when convenient and tell Chris.", #read.rows)
	end
end



-- ============================================================================
-- Command
-- ============================================================================

---A short summary of what's saved.
---@return string[]
function BGProbe:Summary()
	local probe = private.Data()
	if not BGProbe:IsOn() or not probe then
		return { "battleground probe: off (development builds only)." }
	end
	local lines = { format("battleground probe: %d matches, %d zone entries, %d zones known.", #probe.matches, #probe.entries, #probe.zones) }
	for _, match in ipairs(probe.matches) do
		tinsert(lines, format("  %s: %s, %d events, %d messages, %d widget snapshots, mid read %s, final %s players, winner %s.",
			date("%m-%d %H:%M", match.started), tostring(match.zone), #match.events, #match.chat, #match.widgets,
			match.mid and "yes" or "no", match.scores and tostring(#match.scores.rows) or "no", tostring(match.winner)))
	end
	local last = probe.entries[#probe.entries]
	if last then
		tinsert(lines, format("  last entry: %s, instance type %s, battleground %s, battlefield %s.", tostring(last.zone),
			tostring(last.instanceType), tostring(last.isBattleground), tostring(last.isActiveBattlefield)))
	end
	return lines
end

if BGProbe:IsOn() then
	Wanted:RegisterCommand("bgprobe", "Summarises what the battleground probe saved (development builds).", function()
		for _, line in ipairs(BGProbe:Summary()) do
			Wanted:Print(line)
		end
	end)
end
