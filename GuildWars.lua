-- Wanted: guild wars, the addon's side. After an influence race (Races), the faction that doesn't hold the zone may
-- declare a war on it; a draw picks one declaring guild; the holders pick a half-hour on one of the next two evenings,
-- and the attackers accept or withdraw; each side brings a roster of up to 40, and the attackers take the defenders'
-- lanes (a tower, then an inhibitor) until one inhibitor down opens the keep. The winner holds the zone, with 3 days'
-- protection. War Marks, a guild treasury and a guild tax pay for the stakes and the cosmetics.
--
-- wanteddeadordead.com decides everything; this client only shows it and says what its player wants done. What the
-- site decided comes in the app's catch-up (the war contract's section 7: guild, guilds, declare, wars, warLive,
-- marks, owners and ladders at the top of the account's entry, read at every login), cleaned generically (plain text,
-- finite numbers, bounded size) and turned into what the screens show by GuildWars.View (WarView.lua). What the
-- player asks for (declare, the time, accept or withdraw, sign up, the roster, allies, the war officers, the tax) is a
-- WANTEDA1 line on the game's log through GuildWars:Act: the app sends it to the site once, signed, and writes the
-- answer into the catch-up's `actions`, by the line's id; a refusal comes back with its code (section 6.3).
--
-- Who is a war officer is the guild master's setting (the Guild tab): by default the guild master and every rank with
-- the game's guild-invite right (rank flag 5), plus members added and less those left out. The site judges it.

local _, Wanted = ...
local GuildWars = Wanted:NewModule("GuildWars")
local private = {
	state = nil, -- the catch-up's wars, cleaned, or nil when it named none
	listeners = {},
}
local MAX_DEPTH, MAX_ITEMS, MAX_TEXT = 8, 200, 120
-- The game's rank permission that lets a rank invite to the guild (Blizzard_GuildControlUI.xml, InviteCheckbox id 5)
local INVITE_FLAG = 5
local MAX_ACTIONS = 50
-- The census and witness lines, every this many seconds in a war's zone (the war contract's 4.1, 4.3); a player counts
-- in the census only when seen moving or fighting this recently (AFK alts parked in the zone don't make a crowd: the
-- engine's WarCensusActive), and who's active is looked at this often
local SIGHT_SECONDS = 30
local ACTIVE_SECONDS, ACTIVE_LOOK = 5 * 60, 5
GuildWars.MAX_ROSTER = 40
GuildWars.DAILY_CAP = 150



-- ============================================================================
-- Lifecycle and the catch-up
-- ============================================================================

function GuildWars:OnLoad()
	-- What the player asked for, until the site says it happened: { id, kind, war, data, t, refused? }, newest last
	Wanted.db.warActions = type(Wanted.db.warActions) == "table" and Wanted.db.warActions or {}
end

function GuildWars:OnEnable()
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("GUILD_ROSTER_UPDATE")
	frame:SetScript("OnEvent", function() GuildWars:ReportRoster() end)
	C_Timer.NewTicker(SIGHT_SECONDS, Wanted:Timed("War census", function() GuildWars:Sight() end))
	C_Timer.NewTicker(ACTIVE_LOOK, Wanted:Timed("War census activity", function() GuildWars:LookActive() end))
end

---A value from the catch-up as this client may show it: strings as plain text (no escape sequences or control
---characters, at most MAX_TEXT letters), finite numbers, booleans, and tables at most MAX_DEPTH deep and MAX_ITEMS
---long; anything else is left out.
function private.Clean(value, depth)
	local kind = type(value)
	if kind == "string" then
		value = strtrim((gsub(value, "[|%c]", "")))
		return strsub(value, 1, MAX_TEXT)
	elseif kind == "number" then
		return value == value and value ~= math.huge and value ~= -math.huge and value or nil
	elseif kind == "boolean" then
		return value
	elseif kind == "table" and depth < MAX_DEPTH then
		local out, count = {}, 0
		for k, v in pairs(value) do
			if (type(k) == "string" or type(k) == "number") and count < MAX_ITEMS then
				local cleaned = private.Clean(v, depth + 1)
				if cleaned ~= nil then
					out[type(k) == "string" and private.Clean(k, depth) or k] = cleaned
					count = count + 1
				end
			end
		end
		return out
	end
	return nil
end

-- The catch-up's guild war fields (the war contract's section 7), and the app's answers to this account's asks
local FIELDS = { "guild", "guilds", "declare", "wars", "warLive", "marks", "owners", "ladders" }

---Takes in the guild wars from a catch-up entry (or the data addon's snapshot, which has only `owners`), or nil:
---none. Only shown, so read at every login.
---@param src table?
function GuildWars:Take(src)
	local raw
	for _, field in ipairs(FIELDS) do
		local value = type(src) == "table" and src[field] or nil
		if type(value) == "table" then
			raw = raw or {}
			raw[field] = private.Clean(value, 0)
		end
	end
	local db = Wanted.db
	private.state = raw and GuildWars.View(raw, type(src.t) == "number" and src.t or nil) or nil
	local listed, now = {}, GetServerTime()
	for _, war in ipairs(GuildWars:Wars()) do
		if war.id ~= nil then
			listed[war.id] = true
		end
	end
	-- The asks: answered ones done (the war or guild as it stands now is in this catch-up), refused ones kept to say
	-- why; for a war the site no longer lists, or a day old, they drop
	local answers = type(src) == "table" and type(src.actions) == "table" and private.Clean(src.actions, 0) or {}
	local actions = db.warActions or {}
	for i = #actions, 1, -1 do
		local action = actions[i]
		local answer = action.id and answers[action.id]
		if type(answer) == "table" and answer.ok == true then
			tremove(actions, i)
		elseif (action.war ~= nil and not listed[action.war]) or now - (action.t or 0) > 86400 then
			tremove(actions, i)
		elseif type(answer) == "table" then
			action.refused = { code = answer.code, detail = answer.detail }
		end
	end
	private.Changed()
	GuildWars:ReportRoster()
end

---Whether the site runs guild wars on this client's campaign: the catch-up named them.
---@return boolean
function GuildWars:On()
	return private.state ~= nil
end

---Says the wars changed (WarLive's provisional state moved on): the screens, the HUD and the map redraw.
function GuildWars:Touch()
	private.Changed()
end

---Calls func() when the wars change.
function GuildWars:OnChange(func)
	tinsert(private.listeners, func)
end

function private.Changed()
	for _, func in ipairs(private.listeners) do
		func()
	end
end



-- ============================================================================
-- Reading
-- ============================================================================

local function List(t)
	return type(t) == "table" and t or {}
end

---The campaign's zones: { zone, continent, holder = { guild, faction }, since, protectedUntil, next = { kind, at, text } },
---the held ones first.
---@return table[]
function GuildWars:Zones()
	return List(private.state and private.state.zones)
end

---This character's guild: { id, name, faction, treasury, staked, tax, membersWithApp, officers, rankNames, rankInvite,
---me = { rank, member, joinedAt, countsAt, officer, leader } }, or nil.
---@return table?
function GuildWars:Guild()
	local guild = private.state and private.state.guild
	return type(guild) == "table" and guild or nil
end

---This player's War Marks: { marks, today, cap, resets, sources = { { label, n } }, recent = { { t, text, purse } } }.
---@return table?
function GuildWars:Purse()
	local purse = private.state and private.state.purse
	return type(purse) == "table" and purse or nil
end

---The races this player's guild may declare on, then its wars: each { id, warId, zone, role ("attack" or "defend"),
---step, state, stake, attacker, defender, race, declare, draw, time, roster, battle, result } (WarView.lua).
---@return table[]
function GuildWars:Wars()
	return List(private.state and private.state.wars)
end

---A war by its place in the list (the war tabs are war1, war2, war3), or nil.
---@param index number
---@return table?
function GuildWars:War(index)
	return GuildWars:Wars()[index]
end

---When the catch-up was written, for "as of <time>".
---@return number?
function GuildWars:At()
	return private.state and type(private.state.at) == "number" and private.state.at or nil
end



-- ============================================================================
-- War officers
-- ============================================================================

---The guild's ranks from the game: { index (0 = the guild master), name, invite (the guild-invite right), members }.
---@return table[]
function GuildWars:Ranks()
	local ranks = {}
	local ok, n = pcall(GuildControlGetNumRanks)
	if not ok or type(n) ~= "number" then
		return ranks
	end
	for order = 1, min(n, 20) do
		local fine, name = pcall(GuildControlGetRankName, order)
		local flags
		if C_GuildInfo and C_GuildInfo.GuildControlGetRankFlags then
			local got, result = pcall(C_GuildInfo.GuildControlGetRankFlags, order)
			flags = got and type(result) == "table" and result or nil
		end
		tinsert(ranks, { index = order - 1, name = fine and type(name) == "string" and name or ("Rank "..order),
			invite = order == 1 or (flags and flags[INVITE_FLAG] == true) or false, members = 0 })
	end
	for _, member in ipairs(GuildWars:Members()) do
		local rank = ranks[member.rankIndex + 1]
		if rank then
			rank.members = rank.members + 1
		end
	end
	return ranks
end

---The guild's members from the game: { name (without the realm), rank, rankIndex, class, guid }.
---@return table[]
function GuildWars:Members()
	local members = {}
	local ok, n = pcall(GetNumGuildMembers)
	if not ok or type(n) ~= "number" then
		return members
	end
	for i = 1, min(n, 1000) do
		local fine, name, rank, rankIndex, _, _, _, _, _, _, _, class, _, _, _, _, _, guid = pcall(GetGuildRosterInfo, i)
		if fine and type(name) == "string" and type(rankIndex) == "number" then
			tinsert(members, { name = (strmatch(name, "^([^%-]+)") or name), rank = rank, rankIndex = rankIndex, class = class,
				guid = type(guid) == "string" and guid or nil })
		end
	end
	return members
end

---The war-officer setting in force: the one just asked for, else the site's saved one, else the default (the guild
---master and every rank that can invite). The site names people by GUID; the setting by name, from the guild's
---roster (or the site's list of officers now). Second: whether it's the default.
---@return table { ranks = { [index] = true }, add = { [name] = true }, out = { [name] = true }, savedAt?, savedBy?, held? }
---@return boolean default
function GuildWars:OfficerSetting()
	local guild = GuildWars:Guild()
	local setting = { ranks = { [0] = true }, add = {}, out = {} }
	local pending = GuildWars:Pending("officers")
	local saved = guild and type(guild.officers) == "table" and guild.officers or nil
	if pending then
		for _, index in ipairs(List(pending.data.ranks)) do
			setting.ranks[index] = true
		end
		for _, name in ipairs(List(pending.data.add)) do
			setting.add[name] = true
		end
		for _, name in ipairs(List(pending.data.out)) do
			setting.out[name] = true
		end
		return setting, false
	end
	if saved and type(saved.ranks) == "table" and not saved.default then
		local names = private.NamesByGuid(saved)
		for _, index in ipairs(saved.ranks) do
			setting.ranks[index] = true
		end
		for _, guid in ipairs(List(saved.add)) do
			if names[guid] then
				setting.add[names[guid]] = true
			end
		end
		for _, guid in ipairs(List(saved.leaveOut)) do
			if names[guid] then
				setting.out[names[guid]] = true
			end
		end
		setting.savedAt, setting.savedBy, setting.held = saved.savedAt, saved.savedBy, saved.held == true
		return setting, false
	end
	for _, rank in ipairs(GuildWars:Ranks()) do
		if rank.invite then
			setting.ranks[rank.index] = true
		end
	end
	return setting, true
end

---Guild members' names by GUID: the game's roster, and the site's list of officers now for anyone it doesn't show.
function private.NamesByGuid(officers)
	local names = {}
	for _, entry in ipairs(type(officers) == "table" and List(officers.now) or {}) do
		if type(entry) == "table" and type(entry.guid) == "string" and type(entry.name) == "string" then
			names[entry.guid] = entry.name
		end
	end
	for _, member in ipairs(GuildWars:Members()) do
		if member.guid then
			names[member.guid] = member.name
		end
	end
	return names
end

---Whether a guild member is a war officer under a setting (the one in force by default): the guild master always;
---else added by name, or of a ticked rank and not left out.
---@param member table { name, rankIndex }
---@param setting table?
---@return boolean
function GuildWars:IsOfficer(member, setting)
	setting = setting or GuildWars:OfficerSetting()
	if member.rankIndex == 0 then
		return true
	end
	if setting.add[member.name] then
		return true
	end
	return setting.ranks[member.rankIndex] == true and not setting.out[member.name]
end

---The war officers now, under a setting: each member who is one, guild master first, then by rank and name.
---@param setting table?
---@return table[]
function GuildWars:Officers(setting)
	setting = setting or GuildWars:OfficerSetting()
	local list = {}
	for _, member in ipairs(GuildWars:Members()) do
		if GuildWars:IsOfficer(member, setting) then
			tinsert(list, member)
		end
	end
	sort(list, function(a, b)
		if a.rankIndex ~= b.rankIndex then
			return a.rankIndex < b.rankIndex
		end
		return a.name < b.name
	end)
	return list
end

---Whether this player is a war officer of their guild: the site's word when the catch-up has it, else the setting.
---@return boolean
function GuildWars:AmOfficer()
	local guild = GuildWars:Guild()
	if guild and type(guild.me.officer) == "boolean" then
		return guild.me.officer
	end
	local me = UnitName("player")
	for _, member in ipairs(GuildWars:Members()) do
		if member.name == me then
			return GuildWars:IsOfficer(member)
		end
	end
	return false
end

---Whether this player leads their guild (the only one who sets the war officers).
---@return boolean
function GuildWars:AmGuildMaster()
	local ok, leader = pcall(IsGuildLeader)
	return ok and leader == true
end



-- ============================================================================
-- Actions
-- ============================================================================

---Asks the site, through the app, for something the player chose (the war contract's actions): "declare" { stake },
---"time" { start }, "answer" { accept }, "signup" { in }, "roster" { names, standby }, "allies" { guild, invite },
---"officers" { ranks, add, out } (by name) and "tax" { percent }. Written at once as a WANTEDA1 line for the app, and
---kept in saved data until the app's answer comes back in the catch-up; the screens say "Sent; waiting for the site"
---meanwhile, and why when the site refused. Returns whether it was taken.
---@param kind string
---@param war string? the war's id (GuildWars:Wars), nil for a guild-wide one (tax, officers)
---@param data table?
---@return boolean
function GuildWars:Act(kind, war, data)
	-- Nothing is asked while the tour's sample is up
	if GuildWars:Sampling() then
		return false
	end
	local actions = Wanted.db.warActions
	-- The same ask again replaces the last one
	for i = #actions, 1, -1 do
		if actions[i].kind == kind and actions[i].war == war then
			tremove(actions, i)
		end
	end
	if #actions >= MAX_ACTIONS then
		tremove(actions, 1)
	end
	local guid = UnitGUID("player")
	Wanted.db.warActionSeq = (tonumber(Wanted.db.warActionSeq) or 0) + 1
	local action = { id = guid and (guid..":"..Wanted.db.warActionSeq) or nil, kind = kind, war = war, data = data or {}, t = GetServerTime() }
	tinsert(actions, action)
	private.WriteAction(action)
	Wanted:Log("Guild wars: asked %s%s", kind, war and (" for "..war) or "")
	private.Changed()
	return true
end

---A value on a WANTEDA1 line: anything but letters, digits and -._~: as %XX; a list is its items so escaped, joined by
---commas; a boolean 1 or 0.
function private.Value(value)
	if type(value) == "table" then
		local items = {}
		for _, item in ipairs(value) do
			tinsert(items, private.Value(item))
		end
		return table.concat(items, ",")
	elseif type(value) == "boolean" then
		return value and "1" or "0"
	end
	return (gsub(tostring(value), "[^%w%-%._~:]", function(c) return format("%%%02X", c:byte()) end))
end

---The GUIDs of names: a war's people (its roster, standby and sign-ups) or the guild's members.
function private.Guids(names, war)
	local byName = {}
	for _, member in ipairs(GuildWars:Members()) do
		byName[member.name] = member.guid
	end
	local roster = war and war.roster or {}
	for _, key in ipairs({ "players", "standby", "signups" }) do
		for _, p in ipairs(List(roster[key])) do
			if p.guid then
				byName[p.name] = p.guid
			end
		end
	end
	local guids = {}
	for _, name in ipairs(List(names)) do
		if byName[name] then
			tinsert(guids, byName[name])
		end
	end
	return guids
end

---An ask's fields, in order, as the app reads them (desktop/warlog.go), or nil when it can't be sent.
function private.Fields(action)
	local war
	for _, w in ipairs(GuildWars:Wars()) do
		if w.id == action.war then
			war = w
		end
	end
	local data, kind = action.data, action.kind
	if kind == "tax" then
		return { { "percent", floor(tonumber(data.percent) or 0) } }
	elseif kind == "officers" then
		local ranks = {}
		for _, index in ipairs(List(data.ranks)) do
			tinsert(ranks, format("%d", index))
		end
		return { { "ranks", ranks }, { "add", private.Guids(data.add) }, { "leaveOut", private.Guids(data.out) } }
	elseif not war then
		return nil
	elseif kind == "declare" then
		local race = war.race or {}
		if not (race.battlegroup and race.ruleset and race.start) then
			return nil
		end
		return { { "battlegroup", race.battlegroup }, { "ruleset", race.ruleset }, { "start", format("%d", race.start) },
			{ "stake", floor(tonumber(data.stake) or 0) } }
	elseif not war.warId then
		return nil
	end
	local fields = { { "war", format("%d", war.warId) } }
	if kind == "time" then
		tinsert(fields, { "start", format("%d", tonumber(data.start) or 0) })
	elseif kind == "answer" then
		tinsert(fields, { "accept", data.accept == true })
	elseif kind == "signup" then
		tinsert(fields, { "in", data["in"] == true })
	elseif kind == "roster" then
		tinsert(fields, { "roster", private.Guids(data.names, war) })
		tinsert(fields, { "standby", private.Guids(data.standby, war) })
	elseif kind == "allies" then
		tinsert(fields, { "guild", tostring(data.guild or "") })
		tinsert(fields, { "invite", data.invite ~= false })
	else
		return nil
	end
	return fields
end

---An ask on the game's log (Logs\General.log), for the app: "WANTEDA1 <account mark> <action> id=<id>&t=<time>&
---guid=<GUID>&<fields>".
function private.WriteAction(action)
	local mark = Wanted.db.accountMark
	local fields = action.id and private.Fields(action)
	if not fields or not (C_Log and C_Log.LogMessage) or type(mark) ~= "string" or not strmatch(mark, "^%w+$") then
		return
	end
	local header = { { "id", action.id }, { "t", format("%d", action.t) }, { "guid", UnitGUID("player") } }
	for _, line in ipairs(private.Lines(format("WANTEDA1 %s %s ", mark, action.kind), header, fields)) do
		C_Log.LogMessage(line)
	end
end

-- The longest line written for the app (the game's log takes lines under 255 bytes)
local MAX_LINE = 250

---A line's fields as log lines for the app, each under MAX_LINE: "<prefix><header>&<fields>[&part=i/n]". The header
---(what names the line) goes in every part, the other fields in whichever part they fit, a list's items (a table)
---spread over the parts in order; "&part=i/n" on each when there's more than one.
---@param prefix string
---@param header table { { key, value } }
---@param fields table { { key, value or list } }
---@return string[]
function private.Lines(prefix, header, fields)
	local head = {}
	for _, field in ipairs(header) do
		tinsert(head, field[1].."="..private.Value(field[2]))
	end
	head = prefix..table.concat(head, "&")
	local room = MAX_LINE - #head - 14
	local parts, current, used = {}, {}, 0
	local function Flush()
		tinsert(parts, current)
		current, used = {}, 0
	end
	local function Put(text)
		if used + #text > room and #current > 0 then
			Flush()
		end
		tinsert(current, text)
		used = used + #text
	end
	for _, field in ipairs(fields) do
		local key, value = field[1], field[2]
		if type(value) == "table" then
			local chunk, count = "&"..key.."=", 0
			for _, item in ipairs(value) do
				local text = (count > 0 and "," or "")..private.Value(item)
				if used + #chunk + #text > room and (count > 0 or #current > 0) then
					if count > 0 then
						tinsert(current, chunk)
					end
					Flush()
					chunk, count, text = "&"..key.."=", 0, private.Value(item)
				end
				chunk, count = chunk..text, count + 1
			end
			Put(chunk)
		else
			Put("&"..key.."="..private.Value(value))
		end
	end
	if #current > 0 or #parts == 0 then
		Flush()
	end
	local lines = {}
	for i, part in ipairs(parts) do
		tinsert(lines, head..table.concat(part)..(#parts > 1 and format("&part=%d/%d", i, #parts) or ""))
	end
	return lines
end

---The player's last ask of a kind (for a war, or guild-wide), while the site hasn't answered it, or nil.
---@param kind string
---@param war string?
---@return table?
function GuildWars:Pending(kind, war)
	for i = #Wanted.db.warActions, 1, -1 do
		local action = Wanted.db.warActions[i]
		if action.kind == kind and action.war == war then
			return not action.refused and action or nil
		end
	end
	return nil
end

---Why the site refused the player's last ask of a kind, as a sentence, and its code; nil when it didn't.
---@param kind string
---@param war string?
---@return string? text
---@return string? code
function GuildWars:Refused(kind, war)
	for i = #Wanted.db.warActions, 1, -1 do
		local action = Wanted.db.warActions[i]
		if action.kind == kind and action.war == war then
			local refused = action.refused
			if not refused then
				return nil
			end
			return type(refused.detail) == "string" and refused.detail ~= "" and refused.detail or GuildWars:RefusalText(refused.code), refused.code
		end
	end
	return nil
end

-- The site's refusal codes (the war contract's 6.3) and the app's own, as the player reads them
local REFUSALS = {
	not_linked = "This character isn't linked to your Wanted account.",
	banned = "This account can't take part.",
	wrong_side = "This character isn't on your app's side.",
	not_member = "Not a member of the guild yet, as the site counts it.",
	not_officer = "Only war officers can do that.",
	not_leader = "Only the guild master can do that.",
	window_closed = "Declarations have closed.",
	not_your_faction = "Your faction holds this zone.",
	under_share = "Under 10% of the side's influence.",
	under_members = "Under 5 members with Wanted and the app.",
	protected = "The zone is protected.",
	war_on_zone = "There's already a war on this zone.",
	stake_range = "The stake is out of range.",
	treasury_low = "The treasury can't cover the stake.",
	already_declared = "Your guild has already declared.",
	state = "The war has moved on.",
	cell_closed = "That time is closed.",
	cell_past = "That time has passed.",
	deadline_passed = "Too late for that now.",
	locked = "The roster is locked.",
	roster_full = "The roster is full.",
	ineligible_72h = "Under 72 hours in the guild",
	ineligible_daily = "Already in a war that day",
	ineligible_app = "App not seen this week",
	ally_not_invited = "Their guild isn't invited",
	not_same_faction = "Not of your faction.",
	tax_range = "The tax is 0 to 25%.",
	contested = "Two groups claim this guild. Wanted's admins will settle it, or it clears once one group has been quiet for a week.",
	held = "Waiting for the guild's roster to agree.",
	bad_request = "The site couldn't read the request.",
	unavailable = "The site doesn't run guild wars yet.",
	unsent = "The app couldn't reach the site in time. Try again.",
}

---A refusal code as a sentence.
---@param code string?
---@return string
function GuildWars:RefusalText(code)
	return REFUSALS[code] or "Refused by the site."
end



-- ============================================================================
-- The guild roster report (the war contract's 2.1)
-- ============================================================================

-- The roster is read for a report at most this often; a report names at most this many ranks and members (the app's
-- limits)
local REPORT_SECONDS, REPORT_RANKS, REPORT_MEMBERS = 600, 10, 1000

local function secret(value)
	return issecretvalue and issecretvalue(value) or false
end

---An integer in a range, or nil.
function private.Int(value, low, high)
	if type(value) == "number" and not secret(value) and value == floor(value) and value >= low and value <= high then
		return value
	end
	return nil
end

---The game's colour as three integers 0 to 255, or nil.
function private.Rgb(color)
	if type(color) ~= "table" or type(color.GetRGB) ~= "function" then
		return nil
	end
	local ok, r, g, b = pcall(color.GetRGB, color)
	if not ok or type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" or secret(r) or secret(g) or secret(b) then
		return nil
	end
	return { max(0, min(255, floor(r * 255 + 0.5))), max(0, min(255, floor(g * 255 + 0.5))), max(0, min(255, floor(b * 255 + 0.5))) }
end

---This character's own guild tabard from the game, as the catch-up has tabards: { background = { r, g, b }, border,
---emblem (0 to 255), style (0 to 255), file }, or nil: none, a guild without a design, or the game wouldn't say.
---Only ever "player": another guild's tabard is the server's majority, never one client's word.
---@return table?
function GuildWars:LiveTabard()
	if not (C_GuildInfo and C_GuildInfo.GetGuildTabardInfo) then
		return nil
	end
	local ok, info = pcall(C_GuildInfo.GetGuildTabardInfo, "player")
	if not ok or type(info) ~= "table" or info.emblemFileID == nil then
		return nil
	end
	local background, border, emblem = private.Rgb(info.backgroundColor), private.Rgb(info.borderColor), private.Rgb(info.emblemColor)
	local style, file = private.Int(info.emblemStyle, 0, 255), private.Int(info.emblemFileID, 1, 2147483647)
	if not (background and border and emblem and style and file) then
		return nil
	end
	return { background = background, border = border, emblem = emblem, style = style, file = file }
end

---The roster line's tabard field: "<background>.<border>.<emblem>.<style>.<file>" ("1f3a5c.000000.ffd100.12.132456"), or nil.
function private.Tabard()
	local t = GuildWars:LiveTabard()
	if not t then
		return nil
	end
	local function Hex(c) return format("%02x%02x%02x", c[1], c[2], c[3]) end
	return format("%s.%s.%s.%d.%d", Hex(t.background), Hex(t.border), Hex(t.emblem), t.style, t.file)
end

---The guild's members with their GUIDs: the game's guild window's (GuildRank), else the roster's.
function private.RosterGuids()
	local members = Wanted.GuildRank and Wanted.GuildRank:Members()
	if type(members) == "table" and #members > 0 then
		return members
	end
	local out = {}
	for _, member in ipairs(GuildWars:Members()) do
		if member.guid and not secret(member.guid) and strfind(member.guid, "^Player%-") then
			tinsert(out, { guid = member.guid, ri = member.rankIndex })
		end
	end
	return out
end

---This character's view of its guild for the app, as WANTEDG1 lines, at each read of the roster (at most every
---REPORT_SECONDS): the guild master, the ranks with the guild-invite right, every member's GUID and rank; out of a
---guild, just that. The app sends a read when it differs from the last it sent, or a day on; the site works out
---membership, the leader and the ranks from many members' reports, never one. Written whether or not the catch-up has
---guild wars yet: the site reads rosters under a switch of its own, before wars are on.
---"WANTEDG1 <mark> reporter=<GUID>&at=<time>&realm=<id>&guild=<name>&leader=<GUID>&ranks=<1|0><name>,..[&tabard=<bg>.<border>.<emblem>.<style>.<file>]&members=<GUID>.<rank>,..[&part=i/n]"
function GuildWars:ReportRoster()
	local now = GetServerTime()
	local mark, me = Wanted.db.accountMark, UnitGUID("player")
	if now - (private.reportRead or 0) < REPORT_SECONDS or not (C_Log and C_Log.LogMessage)
		or type(mark) ~= "string" or not strmatch(mark, "^%w+$") or type(me) ~= "string" or secret(me) or not (IsInGuild and GetGuildInfo) then
		return
	end
	-- The realm is the GUID's, as the app checks it
	local realm = tonumber(strmatch(me, "^Player%-(%d+)%-"))
	local inGuild = IsInGuild()
	if not realm or secret(inGuild) then
		return
	end
	local header, prefix = { { "reporter", me }, { "at", format("%d", now) } }, format("WANTEDG1 %s ", mark)
	if not inGuild then
		private.reportRead = now
		for _, line in ipairs(private.Lines(prefix, header, { { "realm", format("%d", realm) }, { "guild", "" } })) do
			C_Log.LogMessage(line)
		end
		return
	end
	local ok, guild = pcall(GetGuildInfo, "player")
	if not ok or type(guild) ~= "string" or guild == "" or secret(guild) then
		return
	end
	local leader, list, rankList, mine = nil, {}, {}, false
	for _, member in ipairs(private.RosterGuids()) do
		if #list < REPORT_MEMBERS then
			leader = member.ri == 0 and member.guid or leader
			mine = mine or member.guid == me
			tinsert(list, member.guid.."."..format("%d", member.ri))
		end
	end
	for _, rank in ipairs(GuildWars:Ranks()) do
		if #rankList < REPORT_RANKS then
			tinsert(rankList, (rank.invite and "1" or "0")..strsub(rank.name, 1, 32))
		end
	end
	-- The roster isn't loaded yet (it comes with GUILD_ROSTER_UPDATE)
	if not leader or not mine or #rankList == 0 then
		return
	end
	private.reportRead = now
	sort(list)
	local fields = { { "realm", format("%d", realm) }, { "guild", guild }, { "leader", leader }, { "ranks", rankList } }
	local tabard = private.Tabard()
	if tabard then
		tinsert(fields, { "tabard", tabard })
	end
	tinsert(fields, { "members", list })
	for _, line in ipairs(private.Lines(prefix, header, fields)) do
		C_Log.LogMessage(line)
	end
	Wanted:Log("Guild wars: read <%s>'s roster for the app, %d members", guild, #list)
end



-- ============================================================================
-- For the screens
-- ============================================================================

local MEDIA = "Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\wars\\"
GuildWars.MEDIA = MEDIA
GuildWars.SIDE_COLORS = { Horde = { 0.82, 0.24, 0.2 }, Alliance = { 0.24, 0.48, 0.92 } }
-- The crests the site has art for so far ("wolf-gold": a charge and its tincture)
local CRESTS = { ["axe-ash"] = true, ["crown-violet"] = true, ["dagger-forest"] = true, ["flame-teal"] = true, ["raven-black"] = true,
	["skull-crimson"] = true, ["tower-ochre"] = true, ["wolf-bronze"] = true, ["wolf-gold"] = true, ["wolf-iron"] = true, ["wolf-royal"] = true }

---A guild's crest as a texture: its own when the site gave one we have art for, else its side's emblem.
---@param guild table? { crest, faction }
---@return string texture
function GuildWars:CrestFile(guild)
	local crest = type(guild) == "table" and guild.crest
	if type(crest) == "string" and CRESTS[crest] then
		return MEDIA.."crest-"..crest
	end
	return type(guild) == "table" and guild.faction == "Alliance" and "Interface\\Timer\\Alliance-Logo" or "Interface\\Timer\\Horde-Logo"
end

---A tabard as the catch-up has it, checked: { background, border, emblem = { r, g, b } (0 to 255), style (0 to 255), file },
---or nil for anything else.
---@param tabard any
---@return table?
function GuildWars:CleanTabard(tabard)
	if type(tabard) ~= "table" then
		return nil
	end
	local out = {}
	for _, key in ipairs({ "background", "border", "emblem" }) do
		local c = tabard[key]
		if type(c) ~= "table" or #c ~= 3 then
			return nil
		end
		local r, g, b = private.Int(c[1], 0, 255), private.Int(c[2], 0, 255), private.Int(c[3], 0, 255)
		if not (r and g and b) then
			return nil
		end
		out[key] = { r, g, b }
	end
	out.style, out.file = private.Int(tabard.style, 0, 255), private.Int(tabard.file, 1, 2147483647)
	return out.style and out.file and out or nil
end

---A guild's tabard to draw, or nil (then the faction art stands in): the player's own guild's from the game, so it shows
---before the site's vote settles, else the catch-up's, which is the server's majority of that guild's own members.
---Never another unit's.
---@param guild table? { guild or name, faction, tabard }
---@return table?
function GuildWars:Tabard(guild)
	if type(guild) ~= "table" then
		return nil
	end
	local name = guild.guild or guild.name
	if type(name) == "string" and IsInGuild and GetGuildInfo then
		local ok, mine = pcall(GetGuildInfo, "player")
		if ok and type(mine) == "string" and mine == name and (guild.faction == nil or guild.faction == UnitFactionGroup("player")) then
			local live = GuildWars:LiveTabard()
			if live then
				return live
			end
		end
	end
	return GuildWars:CleanTabard(guild.tabard)
end

-- GuildInviteFrame.xml's tabard art: one background and one border, tinted, and the emblem sheet (16 columns of 64 px in 1024)
local GUILD_FRAME = "Interface\\GuildFrame\\GuildFrame"
local EMBLEMS = "Interface\\GuildFrame\\GuildEmblemsLG_01"
local CREST = {
	background = { 0.63183594, 0.69238281, 0.61914063, 0.74023438 },
	border = { 0.63183594, 0.69238281, 0.74414063, 0.86523438 },
}

---A guild crest on a frame, from the game's own textures: the tabard tinted as the game's guild window does, else the
---faction art (CrestFile). A mouse-disabled frame; set it with crest:SetGuild(guild), anchor and size it as a frame.
---@param parent Frame
---@param layer string? the textures' draw layer, "ARTWORK"
---@param sublevel number?
---@return Frame crest with SetGuild(guild) and SetDesaturated(on)
function GuildWars:NewCrest(parent, layer, sublevel)
	layer = layer or "ARTWORK"
	local crest = CreateFrame("Frame", nil, parent)
	crest:EnableMouse(false)
	crest.background = crest:CreateTexture(nil, layer, nil, sublevel or 0)
	crest.background:SetAllPoints()
	crest.background:SetTexture(GUILD_FRAME)
	crest.background:SetTexCoord(unpack(CREST.background))
	crest.border = crest:CreateTexture(nil, layer, nil, (sublevel or 0) + 1)
	crest.border:SetAllPoints()
	crest.border:SetTexture(GUILD_FRAME)
	crest.border:SetTexCoord(unpack(CREST.border))
	crest.emblem = crest:CreateTexture(nil, layer, nil, (sublevel or 0) + 2)
	crest.emblem:SetPoint("TOP")
	crest.emblem:SetPoint("BOTTOM")
	crest.emblem:SetPoint("CENTER")
	crest.emblem:SetTexture(EMBLEMS)
	crest.fallback = crest:CreateTexture(nil, layer, nil, sublevel or 0)
	crest.fallback:SetAllPoints()
	crest:SetScript("OnSizeChanged", function(self, width) self.emblem:SetWidth(width * 7 / 8) end)
	crest.emblem:SetWidth(crest:GetWidth() * 7 / 8)
	crest.SetGuild = GuildWars.CrestSetGuild
	crest.SetDesaturated = GuildWars.CrestSetDesaturated
	crest:SetGuild(nil)
	return crest
end

function GuildWars.CrestSetGuild(crest, guild)
	local tabard = GuildWars:Tabard(guild)
	crest.background:SetShown(tabard ~= nil)
	crest.border:SetShown(tabard ~= nil)
	crest.emblem:SetShown(tabard ~= nil)
	crest.fallback:SetShown(tabard == nil)
	if tabard then
		local b, o, e = tabard.background, tabard.border, tabard.emblem
		crest.background:SetVertexColor(b[1] / 255, b[2] / 255, b[3] / 255)
		crest.border:SetVertexColor(o[1] / 255, o[2] / 255, o[3] / 255)
		-- The same sums as the game's SetLargeGuildTabardTextures
		local cell = 64 / 1024
		local x, y = (tabard.style % 16) * cell, floor(tabard.style / 16) * cell
		crest.emblem:SetTexCoord(x, x + cell, y, y + cell)
		crest.emblem:SetVertexColor(e[1] / 255, e[2] / 255, e[3] / 255)
	else
		crest.fallback:SetTexture(GuildWars:CrestFile(guild))
	end
end

function GuildWars.CrestSetDesaturated(crest, on)
	for _, texture in ipairs({ crest.background, crest.border, crest.emblem, crest.fallback }) do
		texture:SetDesaturated(on == true)
	end
end

---"7:50 PM" in this computer's clock.
function GuildWars:Clock(t)
	return (gsub(date("%I:%M %p", t), "^0", ""))
end

---"Fri 16 Oct".
function GuildWars:Day(t)
	return date("%a %d %b", t)
end

---"tonight 8:40 PM", "Tue 7:50 PM": a time to come, by the day it falls on.
function GuildWars:When(t, now)
	now = now or GetServerTime()
	if date("%Y-%m-%d", t) == date("%Y-%m-%d", now) then
		return "tonight "..GuildWars:Clock(t)
	end
	return date("%a ", t)..GuildWars:Clock(t)
end

---A zone map's size in yards: the game's, else the capture fronts' table.
function private.Yards(mapId)
	if C_Map and C_Map.GetMapWorldSize then
		local ok, w, h = pcall(C_Map.GetMapWorldSize, mapId)
		if ok and type(w) == "number" and type(h) == "number" and w > 0 and h > 0 and not (issecretvalue and (issecretvalue(w) or issecretvalue(h))) then
			return w, h
		end
	end
	local yards = Wanted.Captures.MAP_YARDS[mapId]
	if yards then
		return yards[1], yards[2]
	end
	return nil
end

---The guild's wars, then every other live war of the campaign (role "watch": a bystander's).
---@return table[]
function GuildWars:LiveWars()
	local out = {}
	for _, war in ipairs(GuildWars:Wars()) do
		tinsert(out, war)
	end
	for _, war in ipairs(List(private.state and private.state.others)) do
		tinsert(out, war)
	end
	return out
end

---A war in the player's zone (the guild's, else anyone's), from prep to its end by the clock, or nil. Also its zone
---(WarZones) and the player's place: x, y (0 to 100) and the map.
---@param now number?
function GuildWars:Here(now)
	now = now or GetServerTime()
	local _, x, y, mapId = Wanted.Recorder:GetPosition()
	for _, war in ipairs(GuildWars:LiveWars()) do
		local b, zone = war.battle, Wanted.WarZones:Get(war.zone)
		if zone and zone.mapId == mapId and type(b) == "table" and b.prep and b.stop and now >= b.prep and now < b.stop
			and war.step ~= "result" and war.state ~= "withdrawn" then
			return war, zone, x, y, mapId
		end
	end
	return nil
end

---A war's points as the map and the HUD show them: the defenders' half (each lane's tower and inhibitor), the keep
---and the attackers' rally, each { id, name, x, y, r, role ("tower", "inhibitor", "keep", "rally"), lane }.
---@param war table
---@param zone table WarZones'
---@return table[]
function GuildWars:Points(war, zone)
	local defender = type(war.defender) == "table" and war.defender.faction or nil
	local attacker = type(war.attacker) == "table" and war.attacker.faction or nil
	local d = defender == "Alliance" and "alliance" or "horde"
	local points = {}
	for _, lane in ipairs(zone.lanes) do
		for _, p in ipairs(lane.points) do
			if p.side == d then
				tinsert(points, { id = p.id, name = p.name, x = p.x, y = p.y, r = p.r, role = p.role, lane = lane.id })
			end
		end
	end
	local keep, rally = zone[d], zone[attacker == "Alliance" and "alliance" or "horde"]
	tinsert(points, { id = keep.id, name = keep.name, x = keep.x, y = keep.y, r = keep.r, role = "keep" })
	if rally ~= keep then
		tinsert(points, { id = rally.id, name = rally.name, x = rally.x, y = rally.y, r = rally.r, role = "rally" })
	end
	return points
end

---The war point the player at (x, y) on a map stands on (within its radius), or nil.
---@param war table
---@param zone table
---@param x number?
---@param y number?
---@param mapId number?
---@return table?
function GuildWars:PointAt(war, zone, x, y, mapId)
	if mapId ~= zone.mapId or type(x) ~= "number" or type(y) ~= "number" then
		return nil
	end
	local w, h = private.Yards(mapId)
	if not w then
		return nil
	end
	for _, point in ipairs(GuildWars:Points(war, zone)) do
		local dx, dy = (x - point.x) / 100 * w, (y - point.y) / 100 * h
		if dx * dx + dy * dy <= point.r * point.r then
			return point
		end
	end
	return nil
end

---Whether this player is on the war's roster (or its standby), as the site last said.
---@param war table
---@return boolean
function GuildWars:OnRoster(war)
	local me = UnitGUID("player")
	local roster = type(war.roster) == "table" and war.roster or {}
	for _, key in ipairs({ "players", "standby" }) do
		for _, p in ipairs(List(roster[key])) do
			if me and p.guid == me then
				return true
			end
		end
	end
	return false
end

---A lane point's seal: taken (the attackers' tower, the inhibitor broken by them), being taken (a tower contested), or
---standing (the defenders'). d and a: the defenders' and attackers' sides, "horde" or "alliance".
---@param point table? { state ("taken", "taking" or nil), pct }
---@param role string "tower" or "inhibitor"
---@return string texture
function GuildWars:SealFile(point, role, d, a)
	local state = type(point) == "table" and point.state or nil
	if state == "taken" then
		return MEDIA..(role == "tower" and ("tower-"..a) or ("inhib-broken-by-"..a))
	elseif state == "taking" and role == "tower" then
		return MEDIA.."tower-contested"
	end
	return MEDIA..(role == "tower" and ("tower-"..d) or ("inhib-"..d))
end

---The keep's seal: "sealed", "open" (the defenders', ringed) or "fallen" (to the attackers).
---@return string texture
function GuildWars:KeepFile(state, d, a)
	return MEDIA..(state == "fallen" and ("nexus-keep-fallen-to-"..a) or state == "open" and ("nexus-keep-open-"..d) or ("nexus-keep-sealed-"..d))
end



-- ============================================================================
-- The war census and witnesses (the war contract's 4.3 and 4.1)
-- ============================================================================

---The players on nameplates now: { unit, guid, faction }, each once, never this player.
function private.Plates()
	local out, seen, me = {}, {}, UnitGUID("player")
	local ok, plates = false, nil
	if C_NamePlate and C_NamePlate.GetNamePlates then
		ok, plates = pcall(C_NamePlate.GetNamePlates)
	end
	for _, plate in ipairs(ok and type(plates) == "table" and plates or {}) do
		local unit = plate.namePlateUnitToken
		local guid = type(unit) == "string" and UnitIsPlayer(unit) and UnitGUID(unit)
		local faction = guid and UnitFactionGroup(unit)
		if type(guid) == "string" and not secret(guid) and not secret(faction) and (faction == "Horde" or faction == "Alliance")
			and strfind(guid, "^Player%-") and guid ~= me and not seen[guid] then
			seen[guid] = true
			tinsert(out, { unit = unit, guid = guid, faction = faction })
		end
	end
	return out
end

---Notes who on the nameplates is moving or fighting, and not AFK, every ACTIVE_LOOK seconds in a war's zone.
function GuildWars:LookActive()
	local now = GetServerTime()
	if not GuildWars:Here(now) then
		return
	end
	private.active = private.active or {}
	for _, p in ipairs(private.Plates()) do
		local afk = UnitIsAFK and UnitIsAFK(p.unit)
		local speed = GetUnitSpeed and GetUnitSpeed(p.unit)
		local fighting = UnitAffectingCombat and UnitAffectingCombat(p.unit)
		if afk == true and not secret(afk) then
			private.active[p.guid] = nil
		elseif (type(speed) == "number" and not secret(speed) and speed > 0) or (fighting == true and not secret(fighting)) then
			private.active[p.guid] = now
		end
	end
	for guid, at in pairs(private.active) do
		if now - at > ACTIVE_SECONDS then
			private.active[guid] = nil
		end
	end
end

---Every SIGHT_SECONDS in the zone of a war of the guild's (prep or battle), roster or not, what this player's nameplates
---see, for the app, on the war's layer: a census line, the players of each faction in view seen moving or fighting in
---the last 5 minutes, rosters included (the site takes the rosters off, and works the outnumbered bonus out from the
---counts of apps on neither roster); and standing at a war
---point, witness lines: every player seen there, either side, roster or not (the site keeps who it needs).
---"WANTEDC1 <mark> census <war> <GUID> <time> <horde> <alliance> <layer or ->",
---"WANTEDC1 <mark> witness <war> <GUID> <time> <point> <layer or -> <GUIDs seen, or ->", as many lines as it takes.
function GuildWars:Sight()
	local now = GetServerTime()
	local war, zone, x, y, mapId = GuildWars:Here(now)
	local mark, me = Wanted.db.accountMark, UnitGUID("player")
	if not war or type(war.warId) ~= "number" or not (C_Log and C_Log.LogMessage)
		or type(mark) ~= "string" or not strmatch(mark, "^%w+$") or type(me) ~= "string" or secret(me) then
		return
	end
	local layer = Wanted.Shard and Wanted.Shard:Current()
	layer = type(layer) == "string" and strmatch(layer, "^[%w%-]+$") and layer or "-"
	-- Only on the war's layer, once the site has fixed it
	local warLayer = type(war.battle) == "table" and war.battle.layer or nil
	if type(warLayer) == "string" and layer ~= "-" and layer ~= warLayer then
		return
	end
	GuildWars:LookActive()
	-- Both rosters counted too: the site takes off the roster members it counted at the points
	local counts, seen, active = { Horde = 0, Alliance = 0 }, {}, private.active or {}
	for _, p in ipairs(private.Plates()) do
		if active[p.guid] then
			counts[p.faction] = counts[p.faction] + 1
		end
		if #seen < 2 * GuildWars.MAX_ROSTER then
			tinsert(seen, p.guid)
		end
	end
	local id = format("%d", war.warId)
	C_Log.LogMessage(format("WANTEDC1 %s census %s %s %d %d %d %s", mark, id, me, now, counts.Horde, counts.Alliance, layer))
	local point = GuildWars:PointAt(war, zone, x, y, mapId)
	if point and point.role ~= "rally" then
		-- As many lines as the sightings take, each under MAX_LINE (the app adds them up)
		local head = format("WANTEDC1 %s witness %s %s %d %s %s ", mark, id, me, now, point.id, layer)
		local chunk = {}
		for i, guid in ipairs(seen) do
			tinsert(chunk, guid)
			local nextGuid = seen[i + 1]
			if not nextGuid or #head + #table.concat(chunk, ",") + 1 + #nextGuid > MAX_LINE then
				C_Log.LogMessage(head..table.concat(chunk, ","))
				chunk = {}
			end
		end
		if #seen == 0 then
			C_Log.LogMessage(head.."-")
		end
	end
end
