-- Wanted: a sample war for the tour. While the site runs no guild wars, the tour's war stops need something to show:
-- GuildWars:StartSample builds one in the shape of the app's catch-up (the war contract's section 7) and turns it into
-- the screens' view with GuildWars.View, as for a real war. Display only:
--   * The sample is held here and nowhere else: never in saved data, never passed to the log, the addon messages, the
--     census, the HUD or the map. GuildWars:On(), Zones(), Wars() and the rest still answer from the real catch-up.
--   * Only the war pages read it, through GuildWars.Page, which answers from the sample while one is on and from the
--     real thing otherwise (a real catch-up with wars ends the sample at once).
--   * Asks (GuildWars:Act) do nothing while it is on, and the pages' own buttons that act outside the game's log
--     (the waypoint, the map, the HUD) check GuildWars:Sampling().
-- Every name in it is "Sample".

local _, Wanted = ...
local GuildWars = Wanted.GuildWars
local private = { view = nil }
local OTHER = { Horde = "Alliance", Alliance = "Horde" }
local LETTER = { Horde = "h", Alliance = "a" }
local SAMPLE = "Sample"
local WAR_ID = 7

-- The guild's ranks and members for the Guild tab (index 0 is the guild master)
local RANKS = {
	{ index = 0, name = "Guild Master", invite = true }, { index = 1, name = "Officer", invite = true }, { index = 2, name = "Member", invite = false },
}
local MEMBERS = {
	{ name = "Sample Warlord", rank = "Guild Master", rankIndex = 0, class = "WARRIOR" },
	{ name = "Sample Priest", rank = "Officer", rankIndex = 1, class = "PRIEST" },
	{ name = "Sample Rogue", rank = "Officer", rankIndex = 1, class = "ROGUE" },
	{ name = "Sample Hunter", rank = "Member", rankIndex = 2, class = "HUNTER" },
	{ name = "Sample Mage", rank = "Member", rankIndex = 2, class = "MAGE" },
	{ name = "Sample Druid", rank = "Member", rankIndex = 2, class = "DRUID" },
}

---The sample as the catch-up would give it: this account's guild, its purse, a few zones and one war in the middle of
---its battle (the attackers have taken one lane's tower and inhibitor, the keep is open).
---@param now number
---@param mine string "Horde" or "Alliance", this player's side
function private.Raw(now, mine)
	local guid = UnitGUID("player") or "Player-0-SAMPLE"
	local theirs = OTHER[mine]
	local d = LETTER[theirs]
	local roster = {}
	for i, member in ipairs(MEMBERS) do
		roster[i] = { name = member.name, guid = "Player-0-SAMPLE"..i }
	end
	return {
		guild = { [guid] = { id = 1, name = SAMPLE, faction = mine, rank = 0, member = true, joinedAt = now - 30 * 86400,
			countsAt = now - 27 * 86400, officer = true, leader = true } },
		guilds = { ["1"] = { name = SAMPLE, faction = mine, membersWithApp = 23, treasury = 2140, tax = 10,
			officers = { ranks = { 0, 1 }, default = true, now = {} } } },
		owners = {
			["Hillsbrad Foothills"] = { guild = SAMPLE, faction = theirs, since = now - 3 * 86400 },
			["Arathi Highlands"] = { guild = SAMPLE, faction = mine, since = now - 4 * 86400, next = { kind = "race", at = now + 86400 } },
			["Ashenvale"] = { guild = SAMPLE, faction = mine, since = now - 86400, protectedUntil = now + 2 * 86400 },
			["Tanaris"] = { guild = SAMPLE, faction = theirs, since = now - 5 * 86400 },
		},
		wars = { { id = WAR_ID, zone = "Hillsbrad Foothills", side = "attack", state = "battle", attacker = SAMPLE, defender = SAMPLE,
			stake = 300, drawAt = now - 86400, start = now - 700, answer = "accept", timeDeadline = now - 80000,
			declarations = { { guild = SAMPLE, stake = 300, influence = 500, weight = 1, drawn = true } },
			roster = roster, standby = {}, signups = {}, rivalCount = 24 } },
		warLive = { [tostring(WAR_ID)] = { zone = "Hillsbrad Foothills", phase = "battle", endsAt = now + 1100, at = now - 30, keepOpen = true,
			points = {
				{ id = "hb-top-"..d.."-tower", holder = "att", progress = 22, cost = 22 },
				{ id = "hb-top-"..d.."-inhibitor", holder = "att", progress = 49, cost = 49 },
				{ id = "hb-mid-"..d.."-tower", holder = "def", progress = 11, cost = 22 },
				{ id = "hb-bot-"..d.."-tower", holder = "def", progress = 0, cost = 22 },
			}, turnout = { att = 31, def = 24 }, friends = { h = 9, a = 4 }, mult = { att = 1, def = 1.21 } } },
		marks = { purse = 420, today = { earned = 47, cap = GuildWars.DAILY_CAP, races = 18, wars = 0, bounties = 29, boards = 0 },
			history = { { at = now - 7200, amount = 29, kind = "earn_bounty" }, { at = now - 3600, amount = 18, kind = "earn_race" },
				{ at = now - 1800, amount = 10, kind = "earn_board" } } },
	}
end

---Whether a sample is on.
---@return boolean
function GuildWars:Sampling()
	return private.view ~= nil
end

---Turns the sample on, unless the site runs wars: then the pages show the real ones and this does nothing.
---@return boolean on
function GuildWars:StartSample()
	if GuildWars:On() then
		return false
	end
	if not private.view then
		local now = GetServerTime()
		local mine = UnitFactionGroup("player") == "Alliance" and "Alliance" or "Horde"
		private.view = GuildWars.View(private.Raw(now, mine), now)
		GuildWars:Touch()
	end
	return true
end

---Turns the sample off (the tour ended, or the site's catch-up now has wars).
function GuildWars:StopSample()
	if private.view then
		private.view = nil
		GuildWars:Touch()
	end
end



-- ============================================================================
-- What the war pages read
-- ============================================================================

---The war pages' reader: the sample while one is on, else the real thing (every other member is GuildWars').
local Page = setmetatable({}, { __index = GuildWars })
GuildWars.Page = Page

local function List(t)
	return type(t) == "table" and t or {}
end

---A member is a war officer under a setting: the guild master, or added, or of a ticked rank and not left out.
local function IsOfficer(member, setting)
	return member.rankIndex == 0 or setting.add[member.name] == true or (setting.ranks[member.rankIndex] == true and not setting.out[member.name])
end

-- name = what to answer from the sample; the real answer otherwise
local FROM_SAMPLE = {
	On = function() return true end,
	Zones = function() return List(private.view.zones) end,
	Guild = function() return private.view.guild end,
	Purse = function() return private.view.purse end,
	Wars = function() return List(private.view.wars) end,
	War = function(_, index) return List(private.view.wars)[index] end,
	At = function() return private.view.at end,
	Ranks = function()
		local ranks = {}
		for i, rank in ipairs(RANKS) do
			ranks[i] = { index = rank.index, name = rank.name, invite = rank.invite, members = 0 }
		end
		for _, member in ipairs(MEMBERS) do
			ranks[member.rankIndex + 1].members = ranks[member.rankIndex + 1].members + 1
		end
		return ranks
	end,
	Members = function() return MEMBERS end,
	OfficerSetting = function() return { ranks = { [0] = true, [1] = true }, add = {}, out = {} }, true end,
	Officers = function(_, setting)
		setting = setting or { ranks = { [0] = true, [1] = true }, add = {}, out = {} }
		local list = {}
		for _, member in ipairs(MEMBERS) do
			if IsOfficer(member, setting) then
				tinsert(list, member)
			end
		end
		return list
	end,
	AmOfficer = function() return true end,
	AmGuildMaster = function() return true end,
	-- Nothing is asked of the site, and no ask is waiting
	Act = function() return false end,
	Pending = function() return nil end,
	Refused = function() return nil, nil end,
}
for name, sampled in pairs(FROM_SAMPLE) do
	Page[name] = function(self, ...)
		if private.view and not GuildWars:On() then
			return sampled(self, ...)
		end
		return GuildWars[name](GuildWars, ...)
	end
end
