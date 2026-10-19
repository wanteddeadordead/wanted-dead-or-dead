-- Wanted: guild wars as the screens show them, from the catch-up's fields as the war contract has them (section 7 of
-- docs/conquest/war-contract.md; protocol.WarsState): guild (this account's characters' standing, by GUID), guilds
-- (by id), declare (the races the guild may declare on now), wars, warLive (by war id), marks, owners (by zone) and
-- ladders. GuildWars:Take cleans them and calls GuildWars.View, which builds the one view the screens read: the
-- zones, this character's guild, its purse, and each war (or race to declare on) at its step, with the race, declare,
-- draw, time, roster, battle and result parts. What the contract leaves to rules (the time grid's evenings, the
-- default start, the closed cells, the war's lanes) is worked out here from the same rules (sections 3.3 and 4.2).

local _, Wanted = ...
local GuildWars = Wanted.GuildWars
local private = {}
local PREP, BATTLE, HOUR, DAY = 15 * 60, 30 * 60, 3600, 86400
local OTHER = { Horde = "Alliance", Alliance = "Horde" }
local LETTER = { Horde = "h", Alliance = "a" }
-- A war's state, as the contract names it, and the step it shows
local STEP = { awaiting_time = "time", awaiting_answer = "time", scheduled = "roster", prep = "battle", battle = "battle",
	over = "result", void = "result", cancelled = "result", withdrawn = "time" }
-- What a ledger line's kind means (section 5.2)
local KINDS = { earn_race = "A race", earn_war = "A war", earn_bounty = "A bounty", earn_board = "A weekly board",
	earn_guild = "The guild's earnings", tax = "Guild tax", stake_hold = "Stake held", stake_refund = "Stake back",
	stake_lost = "Stake lost", stake_return = "Stake returned", purchase = "The shop", admin_adjust = "An adjustment" }
-- The treasury's war earnings (section 5.1): an attack won, a defence held
local ATTACK_WON, DEFENCE_HELD = 200, 100

---A whole number from the catch-up as text: its ids are numbers ("42", never "42.0").
function private.Id(n)
	return type(n) == "number" and format("%d", n) or nil
end

local function List(t)
	return type(t) == "table" and t or {}
end



-- ============================================================================
-- US Eastern time (the wars' evenings and the War Marks day)
-- ============================================================================

---Days from 1970-01-01 to a date of the proleptic Gregorian calendar.
function private.Days(y, m, d)
	y = m <= 2 and y - 1 or y
	local era = floor(y / 400)
	local yoe = y - era * 400
	local doy = floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1
	return era * 146097 + yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy - 719468
end

---The first Sunday on or after a date, in days from 1970.
function private.Sunday(y, m, d)
	local day = private.Days(y, m, d)
	return day + (7 - (day + 4) % 7) % 7
end

---US Eastern's offset from UTC at a moment, in seconds: summer time from 2 AM on March's second Sunday to 2 AM on
---November's first.
---@param t number
---@return number
function GuildWars:EasternOffset(t)
	local y = tonumber(date("!%Y", t))
	local from = private.Sunday(y, 3, 8) * DAY + 7 * HOUR
	local to = private.Sunday(y, 11, 1) * DAY + 6 * HOUR
	return (t >= from and t < to) and -4 * HOUR or -5 * HOUR
end

---The moment `seconds` into the Eastern day `days` after the one t falls on: (t, 1, 18 * 3600) is 6 PM ET tomorrow.
---@param t number
---@param days number
---@param seconds number
---@return number
function GuildWars:EasternAt(t, days, seconds)
	local local_ = t + GuildWars:EasternOffset(t)
	local target = local_ - local_ % DAY + days * DAY + seconds
	return target - GuildWars:EasternOffset(target + 5 * HOUR)
end



-- ============================================================================
-- The guild, the purse, the zones
-- ============================================================================

---This character's guild: its standing (`me`, the contract's guild[GUID]) and the guild's record, or nil.
function private.Guild(raw, myGuid)
	local me = myGuid and type(raw.guild) == "table" and raw.guild[myGuid]
	if type(me) ~= "table" then
		return nil
	end
	local info = type(raw.guilds) == "table" and raw.guilds[private.Id(me.id) or ""]
	info = type(info) == "table" and info or {}
	local guild = { id = me.id, name = info.name or me.name, faction = info.faction or me.faction, treasury = info.treasury,
		tax = info.tax, membersWithApp = info.membersWithApp, officers = info.officers, rankNames = info.rankNames,
		rankInvite = info.rankInvite, me = me, staked = 0, taxBy = info.taxSetBy, taxAt = info.taxSetAt }
	-- The treasury's last 7 days, from the ledger
	local week = type(info.week) == "table" and info.week or nil
	if week then
		guild.week = { { text = "In", n = tonumber(week["in"]) or 0 }, { text = "Out", n = -(tonumber(week.out) or 0) }, { text = "Guild tax", n = tonumber(week.tax) or 0 } }
	end
	-- The stakes the treasury holds: the guild's declarations and its attacks not yet over
	for _, war in ipairs(List(raw.wars)) do
		if type(war) == "table" and war.attacker == guild.name and (war.state == "awaiting_time" or war.state == "awaiting_answer"
			or war.state == "scheduled" or war.state == "prep" or war.state == "battle") then
			guild.staked = guild.staked + (tonumber(war.stake) or 0)
		end
	end
	for _, open in ipairs(List(raw.declare)) do
		for _, d in ipairs(type(open) == "table" and List(open.declared) or {}) do
			if type(d) == "table" and d.guild == guild.name then
				guild.staked = guild.staked + (tonumber(d.stake) or 0)
			end
		end
	end
	return guild
end

---The purse: { marks, today, cap, resets, sources = { { label, n } }, recent = { { t, text, purse } } }, or nil.
function private.Purse(marks, now)
	if type(marks) ~= "table" then
		return nil
	end
	local today = type(marks.today) == "table" and marks.today or {}
	local purse = { marks = marks.purse, today = tonumber(today.earned) or 0, cap = tonumber(today.cap) or GuildWars.DAILY_CAP,
		resets = GuildWars:EasternAt(now, 1, 0), recent = {},
		sources = { { label = "Races", n = today.races }, { label = "Wars", n = today.wars }, { label = "Bounties", n = today.bounties },
			{ label = "Weekly boards", n = today.boards } } }
	for _, line in ipairs(List(marks.history)) do
		if type(line) == "table" and type(line.at) == "number" then
			tinsert(purse.recent, { t = line.at, text = KINDS[line.kind] or line.kind or "?", purse = line.amount })
		end
	end
	sort(purse.recent, function(a, b) return a.t > b.t end)
	return purse
end

---The zones: every war zone of the campaign (WarZones), the ones someone holds first, then any the site names that the
---map data doesn't know. A zone's next is the site's, else one of the guild's wars there, else its next race.
function private.Zones(raw, wars, now)
	local owners = type(raw.owners) == "table" and raw.owners or {}
	local warOn = {}
	for _, war in ipairs(wars) do
		if war.step ~= "declare" and war.step ~= "result" then
			warOn[war.zone] = war
		end
	end
	local zones, seen = {}, {}
	local function Add(name, continent)
		local owner = type(owners[name]) == "table" and owners[name] or nil
		local zone = { zone = name, continent = continent }
		if owner then
			zone.holder = { guild = owner.guild, faction = owner.faction }
			zone.since, zone.protectedUntil = owner.since, owner.protectedUntil
			zone.next = type(owner.next) == "table" and { kind = owner.next.kind, at = owner.next.at } or nil
		end
		local war = warOn[name]
		if war and (not zone.next or zone.next.kind ~= "race") then
			local start = type(war.time) == "table" and war.time.start or nil
			zone.next = { kind = "war", at = start, text = format("%s attacks%s", war.attacker.guild or "?", start and "" or ", time not set") }
		end
		if not zone.next then
			local race = private.NextRace(name, now)
			zone.next = race and { kind = "race", at = race.start } or nil
		end
		seen[name] = true
		tinsert(zones, zone)
	end
	for _, known in ipairs(Wanted.WarZones.LIST) do
		Add(known.name, known.continent)
	end
	for name in pairs(owners) do
		if type(name) == "string" and not seen[name] then
			Add(name, nil)
		end
	end
	for i, zone in ipairs(zones) do
		zone.order = i
	end
	sort(zones, function(a, b)
		if (a.holder ~= nil) ~= (b.holder ~= nil) then
			return a.holder ~= nil
		end
		return a.order < b.order
	end)
	return zones
end

---A zone's next race (tonight's or tomorrow's), still to come or on now, or nil.
function private.NextRace(zone, now)
	for _, list in ipairs({ Wanted.Races:Tonight(), Wanted.Races:Tomorrow() }) do
		for _, race in ipairs(list) do
			if race.zone == zone and race.stop > now then
				return race
			end
		end
	end
	return nil
end

---A race of tonight's by its zone and start, or nil.
function private.Race(zone, start)
	for _, race in ipairs(Wanted.Races:Tonight()) do
		if race.zone == zone and race.start == start then
			return race
		end
	end
	return nil
end



-- ============================================================================
-- A war
-- ============================================================================

---A race the guild may declare on, as a war at its Declare step.
function private.Declare(open, guild, owners)
	local owner = type(owners[open.zone]) == "table" and owners[open.zone] or nil
	local ours = { guild = guild.name, faction = guild.faction }
	local race = private.Race(open.zone, open.raceStart)
	local share = tonumber(open.share)
	-- The others' influence as a share of the side's, as ours is: the site's total, else tonight's race's, else ours
	-- worked back
	local total = tonumber(open.sideInfluence) or race and tonumber(race[guild.faction == "Alliance" and "alliance" or "horde"]) or nil
	local declared = {}
	for _, d in ipairs(List(open.declared)) do
		if type(d) == "table" and d.guild == guild.name and not total then
			total = share and share > 0 and tonumber(d.influence) and d.influence / share or nil
		end
	end
	local weights = 0
	for _, d in ipairs(List(open.declared)) do
		if type(d) == "table" then
			local entry = { guild = d.guild, faction = guild.faction, stake = d.stake,
				share = (d.guild == guild.name and share) or (total and total > 0 and (tonumber(d.influence) or 0) / total) or 0 }
			weights = weights + entry.share * (tonumber(d.stake) or 0)
			tinsert(declared, entry)
		end
	end
	for _, entry in ipairs(declared) do
		entry.chance = weights > 0 and entry.share * (tonumber(entry.stake) or 0) / weights or 0
	end
	-- Ours, for 24 hours after the window: declared (waiting for the draw), drawn (the war has its own entry), not
	-- drawn or dropped (a check failed at the draw), with the stake refunded
	local mine = type(open.mine) == "table" and open.mine or nil
	local view = {
		id = format("race:%s:%s:%s", tostring(open.battlegroup), tostring(open.ruleset), private.Id(open.raceStart) or "?"),
		zone = open.zone, role = "attack", step = "declare",
		race = { battlegroup = open.battlegroup, ruleset = open.ruleset, start = open.raceStart, at = race and race.stop or open.raceStart },
		attacker = ours, defender = owner and { guild = owner.guild, faction = owner.faction } or {},
		declare = { closesAt = open.closesAt, share = share, minStake = open.minStake, maxStake = open.maxStake,
			treasury = guild.treasury, members = guild.membersWithApp, checks = type(open.checks) == "table" and open.checks or nil,
			protectedUntil = owner and owner.protectedUntil, seedCommit = open.seedCommit, declared = declared,
			mine = mine and tonumber(mine.stake) and { stake = mine.stake } or nil,
			influence = tonumber(open.influence) or total and share and floor(total * share + 0.5) or nil, sideInfluence = total and floor(total + 0.5) or nil },
		-- The site draws when declaring closes
		draw = { at = open.closesAt, declarers = declared },
	}
	if mine and mine.state and mine.state ~= "declared" or (mine and type(open.closesAt) == "number" and GetServerTime() >= open.closesAt) then
		view.step = "draw"
		if mine.state == "not_drawn" or mine.state == "dropped" then
			view.draw.drawn, view.draw.dropped, view.draw.refunded = false, mine.state == "dropped", mine.refunded
		end
	end
	return view, mine
end

---The draw: each declaration's share of the influence, stake and chance (its weight of the whole).
function private.Draw(w, faction)
	local declarers, weight, influence = {}, 0, 0
	for _, d in ipairs(List(w.declarations)) do
		if type(d) == "table" then
			weight = weight + (tonumber(d.weight) or 0)
			influence = influence + (tonumber(d.influence) or 0)
		end
	end
	for _, d in ipairs(List(w.declarations)) do
		if type(d) == "table" then
			tinsert(declarers, { guild = d.guild, faction = faction, stake = d.stake, drawn = d.drawn == true,
				share = influence > 0 and (tonumber(d.influence) or 0) / influence or 0,
				chance = weight > 0 and (tonumber(d.weight) or 0) / weight or 0 })
		end
	end
	-- A war is a drawn declaration: drawn, whether or not the site listed the others
	return { at = w.drawAt, drawn = true, seed = w.seed, secret = w.secret, declarers = declarers }
end

---The Time step: the two evenings to pick from (6 PM ET, the two days after the draw's), the default start, and the
---starts closed by the guild's other war that day (two wars at least an hour apart).
function private.Time(w, others)
	local t = { deadline = w.timeDeadline, start = w.start, accepted = w.answer == "accept",
		withdrawn = w.answer == "withdraw" or w.state == "withdrawn", races = {}, closed = {} }
	if type(w.drawAt) == "number" then
		t.evenings = { GuildWars:EasternAt(w.drawAt, 1, 18 * HOUR), GuildWars:EasternAt(w.drawAt, 2, 18 * HOUR) }
	end
	if type(w.timeDeadline) == "number" then
		local at = GuildWars:EasternAt(w.timeDeadline, 0, 20 * HOUR)
		t.defaultStart = at > w.timeDeadline and at or GuildWars:EasternAt(w.timeDeadline, 1, 20 * HOUR)
	end
	for _, other in ipairs(others) do
		if other ~= w and type(other.start) == "number" and STEP[other.state] ~= "result" and other.state ~= "withdrawn" then
			if type(w.start) == "number" and GuildWars:EasternAt(other.start, 0, 0) == GuildWars:EasternAt(w.start, 0, 0) then
				t.otherWar = other.zone
			end
			for _, base in ipairs(t.evenings or {}) do
				for slot = 0, 11 do
					local start = base + slot * 1800
					if abs(start - other.start) < HOUR then
						tinsert(t.closed, { start = start, reason = format("Your war in %s starts %s.", other.zone or "?", GuildWars:Clock(other.start)) })
					end
				end
			end
		end
	end
	for _, list in ipairs({ Wanted.Races:Tonight(), Wanted.Races:Tomorrow() }) do
		for _, race in ipairs(list) do
			tinsert(t.races, { start = race.start, stop = race.stop, zone = race.zone })
		end
	end
	return t
end

---The Roster step: the site's roster, standby and sign-ups by name, with their guild rank (or ally guild) and why a
---sign-up can't be picked.
function private.Roster(w, guild, myGuid)
	local rankOf, classOf = {}, {}
	for _, member in ipairs(GuildWars:Members()) do
		if member.guid then
			rankOf[member.guid], classOf[member.guid] = member.rank, member.class
		end
	end
	local signedUp = false
	local function People(list)
		local out = {}
		for _, e in ipairs(List(list)) do
			if type(e) == "table" and type(e.name) == "string" then
				signedUp = signedUp or (myGuid ~= nil and e.guid == myGuid)
				local person = { guid = e.guid, name = e.name, place = e.place, rank = rankOf[e.guid], class = classOf[e.guid],
					ally = e.guild ~= nil and e.guild ~= guild.guild and e.guild or nil, why = e.why and GuildWars:RefusalText(e.why) or nil }
				if e.why == "ineligible_app" then
					person.app = false
				end
				tinsert(out, person)
			end
		end
		return out
	end
	local roster = { players = People(w.roster), standby = People(w.standby), signups = People(w.signups),
		rival = w.rivalCount, lockAt = w.start, allies = w.allies }
	roster.count = #roster.players
	roster.me = { ["in"] = signedUp }
	return roster
end

---A point's state in a war: taken (the attackers hold it), being taken (progress toward its cost), or standing.
function private.Point(p)
	if type(p) ~= "table" then
		return {}
	elseif p.holder == "att" then
		return { state = "taken", progress = p.cost, cost = p.cost }
	elseif (tonumber(p.progress) or 0) > 0 and (tonumber(p.cost) or 0) > 0 then
		return { state = "taking", pct = floor(p.progress / p.cost * 100), progress = p.progress, cost = p.cost }
	end
	return { progress = 0, cost = tonumber(p.cost) }
end

---The lanes and the keep from the war's points: the defenders' half (OPEN-3), each lane's tower then inhibitor
---("<zone>-<lane>-<h|a>-tower"), then the keep ("<zone>-base-<h|a>").
function private.Lanes(zone, defender, points, keepOpen)
	local known = Wanted.WarZones:Get(zone)
	local d = LETTER[defender] or "h"
	local byId = {}
	for _, p in ipairs(List(points)) do
		if type(p) == "table" and p.id then
			byId[p.id] = p
		end
	end
	local lanes = {}
	for _, lane in ipairs(known and known.lanes or {}) do
		local prefix = format("%s-%s-%s-", known.key, lane.id, d)
		tinsert(lanes, { id = lane.id, tower = private.Point(byId[prefix.."tower"]), inhibitor = private.Point(byId[prefix.."inhibitor"]) })
	end
	local keep = known and byId[known.key.."-base-"..d]
	return lanes, { state = type(keep) == "table" and keep.holder == "att" and "fallen" or keepOpen and "open" or "sealed" }
end

---The Battle step from the live state (prep or battle), the times from the war's start.
function private.Battle(w, live, defender)
	local start = tonumber(w.start)
	local b = { start = start, prep = start and start - PREP, stop = start and start + BATTLE }
	if type(live) ~= "table" then
		return b
	end
	b.live, b.phase, b.layer, b.at = true, live.phase, live.layer, live.at
	if live.phase == "battle" and type(live.endsAt) == "number" then
		b.stop = live.endsAt
	end
	b.lanes, b.keep = private.Lanes(w.zone, defender, live.points, live.keepOpen)
	local turnout, friends, mult = List(live.turnout), List(live.friends), List(live.mult)
	b.turnout = { attacker = turnout.att, defender = turnout.def }
	b.friends = { horde = friends.h, alliance = friends.a }
	b.mult = { attacker = mult.att, defender = mult.def }
	return b
end

---The Result step: who won, the keep, the lanes as last seen live, the turnout, the stake and the War Marks.
function private.Result(w, attacker, defender, last)
	if w.state == "void" or w.state == "cancelled" then
		return { [w.state] = true }
	end
	local r = type(w.result) == "table" and w.result or nil
	if not r or (r.winner ~= "att" and r.winner ~= "def") then
		return {}
	end
	local attackWon = r.winner == "att"
	local won = attackWon == (w.side == "attack")
	local stake = tonumber(w.stake) or 0
	local result = { won = won, at = r.keepAt or (tonumber(w.start) and w.start + BATTLE), towers = r.towers, inhibitors = r.inhibitors,
		keep = { state = attackWon and "fallen" or "held", at = r.keepAt }, turnout = { attacker = r.turnoutAtt, defender = r.turnoutDef },
		protectedUntil = r.protectedUntil, final = r.final,
		holder = attackWon and attacker or defender.guild and defender or nil,
		marks = { stake = stake, stakeBack = w.side == "attack" and attackWon, stakeWon = w.side == "defend" and not attackWon, purse = r.marks } }
	if type(r.kills) == "table" then
		result.kills = { attacker = r.kills.att, defender = r.kills.def }
	end
	result.log = type(r.log) == "table" and r.log or nil
	-- The treasury's movement from the war: the ledger's lines to and from our treasury, else section 5.1's rules (an
	-- attack won earns, a failed one loses its stake; a defence held earns and takes the attackers' stake)
	local ours = (w.side == "attack" and w.attacker or w.defender) or "?"
	local ledger, moved = type(r.ledger) == "table" and r.ledger or nil, 0
	for _, line in ipairs(ledger or {}) do
		if type(line) == "table" then
			local amount = tonumber(line.amount) or 0
			moved = moved + (line.to == ours.." treasury" and amount or 0) - (line.from == ours.." treasury" and amount or 0)
		end
	end
	if ledger then
		result.marks.treasury = moved
	elseif w.side == "attack" then
		result.marks.treasury = attackWon and ATTACK_WON or -stake
	else
		result.marks.treasury = attackWon and 0 or DEFENCE_HELD + stake
	end
	-- Each lane as the site counted it, else as this client last saw it live
	if type(r.lanes) == "table" then
		result.lanes = {}
		for _, lane in ipairs(r.lanes) do
			if type(lane) == "table" and type(lane.lane) == "string" then
				local function Taken(p)
					return type(p) == "table" and { state = "taken", at = p.at, by = p.by } or {}
				end
				tinsert(result.lanes, { id = lane.lane, tower = Taken(lane.tower), inhibitor = Taken(lane.inhibitor) })
			end
		end
	elseif type(last) == "table" then
		result.lanes = private.Lanes(w.zone, defender.faction, last.points, false)
	end
	if type(r.keep) == "table" then
		result.keep.at = r.keep.at or result.keep.at
		result.keep.by = r.keep.by
	end
	return result
end

---A war of the guild's, at its step.
function private.War(w, raw, guild, myGuid, last)
	local key = private.Id(w.id)
	local side = w.side == "defend" and "defend" or "attack"
	local mine = guild.faction
	local attackFaction = side == "attack" and mine or OTHER[mine]
	local attacker = { guild = w.attacker, faction = attackFaction }
	local defender = w.defender and { guild = w.defender, faction = OTHER[attackFaction] } or {}
	local step = STEP[w.state] or "time"
	-- The attackers wait on the holders' pick looking at the draw
	if w.state == "awaiting_time" and side == "attack" then
		step = "draw"
	end
	local live = type(raw.warLive) == "table" and raw.warLive[key or ""] or nil
	local war = { id = key, warId = w.id, zone = w.zone, role = side, step = step, state = w.state, stake = w.stake,
		attacker = attacker, defender = defender }
	war.draw = private.Draw(w, attackFaction)
	war.time = private.Time(w, List(raw.wars))
	war.roster = private.Roster(w, side == "attack" and attacker or defender, myGuid)
	war.battle = private.Battle(w, live, OTHER[attackFaction])
	war.result = private.Result(w, attacker, defender, last)
	return war, live
end



-- ============================================================================
-- The view
-- ============================================================================

---The view the screens read, from the cleaned catch-up fields: { at, zones, guild, purse, wars, ladders }. Second: the
---live points of each war in prep or battle, by its id, for the result to show later.
---@param raw table
---@param at number? when the catch-up was written
---@param last table? each war's last live points, by its id
---@return table view
---@return table live
function GuildWars.View(raw, at, last)
	local now = GetServerTime()
	local myGuid = UnitGUID("player")
	local view = { at = at, wars = {}, ladders = raw.ladders }
	local guild = private.Guild(raw, myGuid)
	view.guild = guild
	view.purse = private.Purse(raw.marks, now)
	local seen = {}
	if guild then
		local owners = type(raw.owners) == "table" and raw.owners or {}
		for _, open in ipairs(List(raw.declare)) do
			if type(open) == "table" and open.guild == guild.id and type(open.zone) == "string" then
				local war, mine = private.Declare(open, guild, owners)
				-- Drawn: the war's own entry takes over
				if not (mine and (mine.drawn == true or mine.state == "drawn")) then
					tinsert(view.wars, war)
				end
			end
		end
		for _, w in ipairs(List(raw.wars)) do
			if type(w) == "table" and type(w.id) == "number" and type(w.zone) == "string" then
				local war, live = private.War(w, raw, guild, myGuid, last and last[private.Id(w.id)])
				tinsert(view.wars, war)
				if live then
					seen[war.id] = { points = live.points, at = live.at }
				end
			end
		end
	end
	view.zones = private.Zones(raw, view.wars, now)
	return view, seen
end
