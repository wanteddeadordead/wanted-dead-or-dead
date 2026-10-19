-- Wanted: guild wars, the addon's side. After an influence race (Races), the faction that doesn't hold the zone may
-- declare a war on it; a draw picks one declaring guild; the holders pick a half-hour on one of the next two evenings,
-- and the attackers accept or withdraw; each side brings a roster of up to 40, and the attackers take the defenders'
-- lanes (a tower, then an inhibitor) until one inhibitor down opens the keep. The winner holds the zone, with 3 days'
-- protection. War Marks, a guild treasury and a guild tax pay for the stakes and the cosmetics.
--
-- wanteddeadordead.com decides everything; this client only shows it and says what its player wants done. What the
-- site decided comes in the app's catch-up (`wars`, read at every login); what the player asks for (declare, the time,
-- accept or withdraw, the roster, the tax, the war officers) goes to the app through GuildWars:Act. The shapes here
-- are the approved design's (docs/conquest/guild-wars-ui.md), provisional until the war contract
-- (docs/conquest/war-contract.md) fixes them; the catch-up is cleaned generically (plain text, finite numbers, bounded
-- size), and the screens read it defensively, so a field the site leaves out shows as unknown, never as an error.
--
-- Who is a war officer is the guild master's setting (the Guild tab): by default the guild master and every rank with
-- the game's guild-invite right (rank flag 5), plus members added by name and less those left out.

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
GuildWars.MAX_ROSTER = 40
GuildWars.DAILY_CAP = 150



-- ============================================================================
-- Lifecycle and the catch-up
-- ============================================================================

function GuildWars:OnLoad()
	-- What the player asked for, until the site says it happened: { kind, war, data, t }, newest last
	Wanted.db.warActions = type(Wanted.db.warActions) == "table" and Wanted.db.warActions or {}
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

---Takes in the wars from a catch-up (or nil: none). Only shown, so read at every login.
---@param src table?
function GuildWars:Take(src)
	private.state = type(src) == "table" and private.Clean(src, 0) or nil
	-- Asks the site can no longer be waiting on drop out: for a war it no longer lists, or a day old (until the war
	-- contract says how the site acknowledges them)
	local listed, now = {}, GetServerTime()
	for _, war in ipairs(GuildWars:Wars()) do
		if war.id ~= nil then
			listed[war.id] = true
		end
	end
	local actions = Wanted.db.warActions or {}
	for i = #actions, 1, -1 do
		local action = actions[i]
		if (action.war ~= nil and not listed[action.war]) or now - (action.t or 0) > 86400 then
			tremove(actions, i)
		end
	end
	private.Changed()
end

---Whether the site runs guild wars on this client's campaign: the catch-up named them.
---@return boolean
function GuildWars:On()
	return private.state ~= nil
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

---The campaign's zones: { zone, holder = { guild, faction, crest }, since, protectedUntil, next = { kind, at, text } }.
---@return table[]
function GuildWars:Zones()
	return List(private.state and private.state.zones)
end

---This player's guild's war record: { name, treasury, staked, tax, taxBy, taxAt, week, officers }, or nil.
---@return table?
function GuildWars:Guild()
	local guild = private.state and private.state.guild
	return type(guild) == "table" and guild or nil
end

---This player's War Marks: { marks, today, cap, sources = { { label, n, max } }, recent = { { t, text, purse, treasury } } }.
---@return table?
function GuildWars:Purse()
	local purse = private.state and private.state.purse
	return type(purse) == "table" and purse or nil
end

---The wars this player's guild is in or may declare: each { id, zone, role ("declare", "attack" or "defend"), step,
---attacker, defender, declare, draw, time, roster, battle, result }, in the catch-up's order.
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

---The guild's members from the game: { name (without the realm), rank, rankIndex, class }.
---@return table[]
function GuildWars:Members()
	local members = {}
	local ok, n = pcall(GetNumGuildMembers)
	if not ok or type(n) ~= "number" then
		return members
	end
	for i = 1, min(n, 1000) do
		local fine, name, rank, rankIndex, _, _, _, _, _, _, _, class = pcall(GetGuildRosterInfo, i)
		if fine and type(name) == "string" and type(rankIndex) == "number" then
			tinsert(members, { name = (strmatch(name, "^([^%-]+)") or name), rank = rank, rankIndex = rankIndex, class = class })
		end
	end
	return members
end

---The war-officer setting in force: the saved one, or the default (the guild master and every rank that can invite).
---Second: whether it's the default.
---@return table { ranks = { [index] = true }, add = { [name] = true }, out = { [name] = true }, savedAt?, savedBy? }
---@return boolean default
function GuildWars:OfficerSetting()
	local guild = GuildWars:Guild()
	-- What the guild master just saved counts until the site's answer comes in
	local pending = GuildWars:Pending("officers")
	local saved = pending and pending.data or guild and type(guild.officers) == "table" and guild.officers
	local setting = { ranks = { [0] = true }, add = {}, out = {} }
	if saved and type(saved.ranks) == "table" then
		for _, index in ipairs(saved.ranks) do
			setting.ranks[index] = true
		end
		for _, name in ipairs(List(saved.add)) do
			setting.add[name] = true
		end
		for _, name in ipairs(List(saved.out)) do
			setting.out[name] = true
		end
		setting.savedAt, setting.savedBy = saved.savedAt, saved.savedBy
		return setting, false
	end
	for _, rank in ipairs(GuildWars:Ranks()) do
		if rank.invite then
			setting.ranks[rank.index] = true
		end
	end
	return setting, true
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

---Whether this player is a war officer of their guild.
---@return boolean
function GuildWars:AmOfficer()
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

---Asks the site, through the app, for something the player chose: "declare" { stake }, "time" { start }, "accept",
---"withdraw", "roster" { names, standby }, "in" { on }, "tax" { percent }, "officers" { ranks, add, out }. Kept in
---saved data until the site's catch-up shows it done (the app takes it from there); the screens say "Sent; waiting
---for the site" meanwhile. Returns whether it was taken.
---@param kind string
---@param war string? the war's id, nil for a guild-wide one (tax, officers)
---@param data table?
---@return boolean
function GuildWars:Act(kind, war, data)
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
	tinsert(actions, { kind = kind, war = war, data = data or {}, t = GetServerTime() })
	Wanted:Log("Guild wars: asked %s%s", kind, war and (" for "..war) or "")
	private.Changed()
	return true
end

---The player's last ask of a kind (for a war, or guild-wide), while the site hasn't answered it, or nil.
---@param kind string
---@param war string?
---@return table?
function GuildWars:Pending(kind, war)
	for i = #Wanted.db.warActions, 1, -1 do
		local action = Wanted.db.warActions[i]
		if action.kind == kind and action.war == war then
			return action
		end
	end
	return nil
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
