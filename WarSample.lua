-- Wanted: a sample war for the tour. While the site runs no guild wars, the tour's war stops need something to show:
-- GuildWars:StartSample builds one in the shape of the app's catch-up (the war contract's section 7) and turns it into
-- the screens' view with GuildWars.View, as for a real war. Display only:
--   * The sample is held here and nowhere else: never in saved data, never passed to the log, the addon messages, the
--     census, the HUD or the map. GuildWars:On(), Zones(), Wars() and the rest still answer from the real catch-up.
--   * Only the war pages read it, through GuildWars.Page, which answers from the sample while one is on, except where the
--     player's guild has real data for that screen (a guild, a purse, zones, a war at the stage shown): real data wins.
--   * Asks (GuildWars:Act) do nothing while it is on, and the pages' own buttons that act outside the game's log
--     (the waypoint, the map, the HUD) check GuildWars:Sampling().
-- Every name in it is "Sample".

local _, Wanted = ...
local GuildWars = Wanted.GuildWars
local private = { view = nil }
local OTHER = { Horde = "Alliance", Alliance = "Horde" }
local LETTER = { Horde = "h", Alliance = "a" }
local SAMPLE = "Sample"
local WAR_ID = 2147483000 -- no real war has this id, so no page keeps its state across the sample and a real war

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

---The sample as the catch-up would give it at a stage of its life: this account's guild, its purse, a few zones and
---one war, "Sample" against "Sample": declared on, drawn, the holders picking the time, the rosters, the battle (the
---attackers have taken one lane's tower and inhibitor, the keep is open), and the result.
---@param now number
---@param mine string "Horde" or "Alliance", this player's side
---@param stage string one of GuildWars.SAMPLE_STAGES
function private.Raw(now, mine, stage)
	local guid = UnitGUID("player") or "Player-0-SAMPLE"
	local theirs = OTHER[mine]
	local d = LETTER[theirs]
	local roster = {}
	for i, member in ipairs(MEMBERS) do
		roster[i] = { name = member.name, guid = "Player-0-SAMPLE"..i }
	end
	local raw = {
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
		marks = { purse = 420, today = { earned = 47, cap = GuildWars.DAILY_CAP, races = 18, wars = 0, bounties = 29, boards = 0 },
			history = { { at = now - 7200, amount = 29, kind = "earn_bounty" }, { at = now - 3600, amount = 18, kind = "earn_race" },
				{ at = now - 1800, amount = 10, kind = "earn_board" } } },
	}
	local declarations = { { guild = SAMPLE, stake = 300, influence = 500, weight = 1, drawn = true },
		{ guild = SAMPLE, stake = 150, influence = 300, weight = 0.5 } }
	local war = { id = WAR_ID, zone = "Hillsbrad Foothills", side = "attack", attacker = SAMPLE, defender = SAMPLE, stake = 300,
		declarations = declarations, drawAt = now - 600, roster = {}, standby = {}, signups = {} }
	if stage == "declare" then
		raw.declare = { { battlegroup = "na", ruleset = "pvp", raceStart = now - 3600, zone = "Hillsbrad Foothills", closesAt = now + 522,
			minStake = 300, maxStake = 600, guild = 1, share = 0.41, influence = 527, sideInfluence = 1285,
			checks = { share = true, members = true, officer = true, community = false, zoneOpen = true, treasury = true },
			declared = { { guild = SAMPLE, stake = 300, influence = 270 } } } }
	elseif stage == "draw" then
		war.state, war.timeDeadline = "awaiting_time", now + 40000
		raw.wars = { war }
	elseif stage == "time" then
		war.side, war.state, war.timeDeadline = "defend", "awaiting_time", now + 43000
		raw.wars = { war }
	elseif stage == "roster" then
		war.state, war.start, war.answer, war.timeDeadline = "scheduled", now + 3600, "accept", now - 3600
		war.roster, war.standby = roster, { { name = "Sample Druid", guid = "Player-0-SAMPLE9" } }
		war.signups = { { name = "Sample Mage", guid = "Player-0-SAMPLE5" }, { name = "Sample Scout", guid = "Player-0-SAMPLE10" } }
		war.rivalCount = 18
		raw.wars = { war }
	elseif stage == "battle" then
		war.state, war.start, war.answer, war.timeDeadline, war.roster, war.rivalCount = "battle", now - 700, "accept", now - 3600, roster, 24
		raw.wars = { war }
		raw.warLive = { [tostring(WAR_ID)] = { zone = "Hillsbrad Foothills", phase = "battle", endsAt = now + 1100, at = now - 30, keepOpen = true,
			points = {
				{ id = "hb-top-"..d.."-tower", holder = "att", progress = 22, cost = 22 },
				{ id = "hb-top-"..d.."-inhibitor", holder = "att", progress = 49, cost = 49 },
				{ id = "hb-mid-"..d.."-tower", holder = "def", progress = 11, cost = 22 },
				{ id = "hb-bot-"..d.."-tower", holder = "def", progress = 0, cost = 22 },
			}, turnout = { att = 31, def = 24 }, friends = { h = 9, a = 4 }, mult = { att = 1, def = 1.21 } } }
	elseif stage == "result" then
		war.state, war.start, war.answer, war.timeDeadline, war.roster = "over", now - 3000, "accept", now - 3600, roster
		war.result = { winner = "att", towers = 3, inhibitors = 1, keepAt = now - 1500, turnoutAtt = 31, turnoutDef = 24,
			protectedUntil = now + 3 * 86400, marks = 25, kills = { att = 48, def = 37 }, keep = { at = now - 1500, by = "Sample Warlord" },
			lanes = { { lane = "top", tower = { at = now - 2400, by = "Sample Rogue" }, inhibitor = { at = now - 2000, by = "Sample Warlord" } },
				{ lane = "mid" }, { lane = "bot" } } }
		raw.wars = { war }
	end
	return raw
end

---The stages the sample goes through, in the order of a war's life.
GuildWars.SAMPLE_STAGES = { "declare", "draw", "time", "roster", "battle", "result" }

---Whether a sample is on.
---@return boolean
function GuildWars:Sampling()
	return private.view ~= nil
end

---The sample's stage, or nil.
---@return string?
function GuildWars:SampleStage()
	return private.stage
end

---Turns the sample on at a stage of the war's life ("battle" when left out), or moves it to that stage.
---@param stage string?
function GuildWars:StartSample(stage)
	stage = stage or "battle"
	if private.view and private.stage == stage then
		return
	end
	local now = GetServerTime()
	local mine = UnitFactionGroup("player") == "Alliance" and "Alliance" or "Horde"
	private.view = GuildWars.View(private.Raw(now, mine, stage), now)
	private.stage = stage
	for _, war in ipairs(private.view.wars) do
		war.sample = true
	end
	GuildWars:Touch()
end

---Turns the sample off (the tour ended).
function GuildWars:StopSample()
	if private.view then
		private.view, private.stage = nil, nil
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

---The real wars at the stage the sample shows (a war's step is the stage's name), else the sample's.
local function Wars()
	local real = {}
	for _, war in ipairs(GuildWars:Wars()) do
		if war.step == private.stage then
			tinsert(real, war)
		end
	end
	return #real > 0 and real or List(private.view.wars)
end

-- name = { sampled, real = whether the real answer wins now }; the real answer otherwise
local RULES = {
	On = { function() return true end },
	Zones = { function() return List(private.view.zones) end, function() return #GuildWars:Zones() > 0 end },
	Guild = { function() return private.view.guild end, function() return GuildWars:Guild() ~= nil end },
	Purse = { function() return private.view.purse end, function() return GuildWars:Purse() ~= nil end },
	Wars = { Wars },
	War = { function(_, index) return Wars()[index] end },
	At = { function() return private.view.at end, function() return GuildWars:At() ~= nil end },
	Ranks = { function()
		local ranks = {}
		for i, rank in ipairs(RANKS) do
			ranks[i] = { index = rank.index, name = rank.name, invite = rank.invite, members = 0 }
		end
		for _, member in ipairs(MEMBERS) do
			ranks[member.rankIndex + 1].members = ranks[member.rankIndex + 1].members + 1
		end
		return ranks
	end, function() return GuildWars:Guild() ~= nil end },
	Members = { function() return MEMBERS end, function() return GuildWars:Guild() ~= nil end },
	OfficerSetting = { function() return { ranks = { [0] = true, [1] = true }, add = {}, out = {} }, true end, function() return GuildWars:Guild() ~= nil end },
	Officers = { function(_, setting)
		setting = setting or { ranks = { [0] = true, [1] = true }, add = {}, out = {} }
		local list = {}
		for _, member in ipairs(MEMBERS) do
			if IsOfficer(member, setting) then
				tinsert(list, member)
			end
		end
		return list
	end, function() return GuildWars:Guild() ~= nil end },
	AmOfficer = { function() return true end, function() return GuildWars:Guild() ~= nil end },
	AmGuildMaster = { function() return true end, function() return GuildWars:Guild() ~= nil end },
	-- Nothing is asked of the site, and no ask is waiting
	Act = { function() return false end },
	Pending = { function() return nil end },
	Refused = { function() return nil, nil end },
}
for name, rule in pairs(RULES) do
	Page[name] = function(self, ...)
		if private.view and not (rule[2] and rule[2]()) then
			return rule[1](self, ...)
		end
		return GuildWars[name](GuildWars, ...)
	end
end
