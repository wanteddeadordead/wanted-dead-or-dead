-- Wanted: layers. WoW Forever runs each zone as several copies (layers, or shards), and players on different layers
-- of a zone can't see or fight each other. A creature's GUID names the copy it lives in:
-- Creature-0-<server>-<map>-<zone instance>-<creature>-<spawn>. Server, map and zone instance together change from
-- one layer to the next and stay the same within one (the maintainer's combat logs, 2026-10-09: one quest giver under
-- a new number on each layer, a zone's creatures all under one). Our layer is the one most of the creatures looked at
-- lately in this zone live in, so a creature seen over a zone border doesn't change it. It goes out with our hello,
-- our rally position and our capture-point presence (Sync, Rally, Captures), so every Wanted player's layer is known
-- with their zone, and the Nearby window says when the rally leader is on another one.
--
-- The only way onto another layer is to join a group whose leader is on it. A layer hop asks a Wanted player on the
-- rally's layer in our zone for an invite (by addon whisper); their addon invites us (never dead, in a fight, in a
-- full group, or with hosting off), ours accepts the invite from that host alone, holds the group twenty seconds so
-- the server doesn't bounce us back, then leaves it, unless we chose to stay or the host leads the rally. Fifteen
-- seconds in, the creatures around us say whether the move happened: still on the old layer, we say so and leave.

local _, Wanted = ...
local Shard = Wanted:NewModule("Shard")
local private = {
	frame = CreateFrame("Frame"),
	votes = {}, -- the last creatures looked at in this zone, oldest first: { guid, key }
	voted = {}, -- guid -> true for the creatures in votes
	seenAt = nil, -- GetTime() a creature of this zone was last looked at, counted before or not
	counts = {}, -- scratch for Current: key -> creatures
	peers = {}, -- name -> { key, mapId, at (GetTime) }: the layer each Wanted player last said they were on, and where
	site = {}, -- zone name -> { active, deaths, since }: each zone's fight layer as the site last said it (the catch-up)
	deaths = {}, -- the deaths heard lately with a layer, oldest first: { t, zone, key, id }
	tally = {}, -- scratch for the estimate: key -> count
	hop = nil, -- the hop under way: { id, host, target, from, state, asked, joined, stay, tried } (see Shard:HopTo)
	hosted = {}, -- name -> GetTime() we last invited them for a hop (one ask a while each)
	hops = 0, -- hops started, so a timer for an earlier one changes nothing
}
-- A host has this long to invite after we ask; an invite from them later than this is left to the player
local INVITE_SECONDS = 30
-- Once in the host's group, how long we stay so the server doesn't bounce us back, and when the creatures around us
-- are asked whether the move happened
local HOLD_SECONDS = 20
local WATCHDOG_SECONDS = 15
-- A host invites one player this often at most
local HOST_AGAIN_SECONDS = 30
-- Why a host couldn't invite, as their addon said it (r), in plain words
local REFUSALS = {
	combat = "in combat",
	dead = "dead",
	full = "their group is full",
	cant = "not their group's leader",
	off = "hosting layer hops is off in their settings",
	instance = "in an instance",
	busy = "they invited you a moment ago",
}
-- How many creatures the layer is taken from
local VOTES = 15
-- Not confirmed by a creature for this long, the layer is unknown again (a group invite can move a player)
local STALE_SECONDS = 10 * 60
-- Confirmed by a creature this recently, the reading is fresh (IsFresh)
local FRESH_SECONDS = 60
-- A layer a peer sends: three numbers, never longer than this
local MAX_KEY_BYTES = 32
-- A peer's word on their layer is kept this long (rally positions and point presence come every half minute)
local PEER_SECONDS = 10 * 60
local MAX_PEERS = 200
-- A zone's fight layer: the site's word holds this long; this client's own estimate counts the deaths heard in the
-- last FIGHT_SECONDS and the Wanted players of our side heard in the zone, and names a layer from this many
local SITE_SECONDS = 15 * 60
local FIGHT_SECONDS = 10 * 60
local FIGHT_FLOOR = 5
local MAX_DEATHS = 500
-- A record's time this far past our clock is a bad clock
local AHEAD_SECONDS = 120
-- Events that put a unit in reach, and the unit token each one is about
local UNIT_EVENTS = {
	PLAYER_TARGET_CHANGED = "target",
	UPDATE_MOUSEOVER_UNIT = "mouseover",
	PLAYER_SOFT_ENEMY_CHANGED = "softenemy",
	PLAYER_SOFT_FRIEND_CHANGED = "softfriend",
	PLAYER_SOFT_INTERACT_CHANGED = "softinteract",
}
-- GUID kinds that carry a layer. Players' don't (Player-<realm>-<id>); pets are left out, a player's own summons.
local GUID_KINDS = { Creature = true, Vehicle = true }



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Shard:OnLoad()
	-- host: invite Wanted players who ask for a hop onto our layer; accept: take the invite our hop asked for by itself
	local settings = Wanted.db.settings
	settings.shard = type(settings.shard) == "table" and settings.shard or {}
	for key, value in pairs({ host = true, accept = true }) do
		if type(settings.shard[key]) ~= "boolean" then
			settings.shard[key] = value
		end
	end
end

function Shard:OnEnable()
	for event in pairs(UNIT_EVENTS) do
		private.Register(event)
	end
	for _, event in ipairs({ "NAME_PLATE_UNIT_ADDED", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD", "PARTY_INVITE_REQUEST", "GROUP_ROSTER_UPDATE" }) do
		private.Register(event)
	end
	private.frame:SetScript("OnEvent", Wanted:Timed("Shard events", private.OnEvent))
	-- The deaths our side hears of (both sides' kills and deaths reach the channel) say where the fight is, by layer
	Wanted.Store:OnRecord("kill", private.OnDeath)
	Wanted.Store:OnRecord("death", private.OnDeath)
end

---The layer hop settings: { host, accept }.
function Shard:Settings()
	return Wanted.db.settings.shard
end

---Registers an event if this client has it.
function private.Register(event)
	if not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid(event) then
		private.frame:RegisterEvent(event)
	end
end

function private.OnEvent(_, event, unit)
	if event == "PARTY_INVITE_REQUEST" then
		private.OnInvite(unit)
		return
	elseif event == "GROUP_ROSTER_UPDATE" then
		private.OnRoster()
		return
	elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
		-- Each zone has its own layers
		private.Forget()
		return
	end
	-- In an instance there are no layers to meet anyone on, and unit identity is secret
	if Wanted:InInstance() then
		return
	end
	private.Look(UNIT_EVENTS[event] or unit)
end

---Drops what the creatures said: a new zone, or a group that may have moved us.
function private.Forget()
	wipe(private.votes)
	wipe(private.voted)
	private.seenAt = nil
end



-- ============================================================================
-- Reading our layer
-- ============================================================================

---The layer a GUID names ("server-map-zone instance"), or nil for a GUID that names none (a player's, a pet's).
---@param guid any
---@return string?
function Shard:ParseGUID(guid)
	if (issecretvalue and issecretvalue(guid)) or type(guid) ~= "string" then
		return nil
	end
	local kind, server, map, zone = strmatch(guid, "^(%a+)%-%d+%-(%d+)%-(%d+)%-(%d+)%-%d+%-%x+$")
	if not GUID_KINDS[kind] then
		return nil
	end
	return server.."-"..map.."-"..zone
end

---Counts the layer of the creature on a unit, once per creature. One counted before still confirms the layer is
---current: standing among the same guards for a long while keeps it known.
function private.Look(unit)
	if not unit then
		return
	end
	local guid = UnitGUID(unit)
	if (issecretvalue and issecretvalue(guid)) or type(guid) ~= "string" then
		return
	end
	if private.voted[guid] then
		private.seenAt = GetTime()
		return
	end
	local key = Shard:ParseGUID(guid)
	if not key then
		return
	end
	private.seenAt = GetTime()
	local votes = private.votes
	if #votes >= VOTES then
		private.voted[tremove(votes, 1).guid] = nil
	end
	tinsert(votes, { guid = guid, key = key })
	private.voted[guid] = true
end

---Our layer of the zone we're in ("server-map-zone instance"), or nil while it isn't known.
---@return string?
function Shard:Current()
	local votes = private.votes
	if not votes[1] or GetTime() - (private.seenAt or 0) > STALE_SECONDS then
		return nil
	end
	local counts, best = wipe(private.counts), nil
	-- Newest first: of two layers with as many creatures, the one seen last wins
	for i = #votes, 1, -1 do
		local key = votes[i].key
		counts[key] = (counts[key] or 0) + 1
		if not best or counts[key] > counts[best] then
			best = key
		end
	end
	return best
end

---Whether a creature confirmed our layer in the last minute.
---@return boolean
function Shard:IsFresh()
	return Shard:Current() ~= nil and GetTime() - (private.seenAt or 0) <= FRESH_SECONDS
end

---The zone map we're on (Rally's reading: a cave's or a town's map counts as its zone's), or nil where none reaches.
---@return number?
function Shard:ZoneMap()
	return Wanted.Rally and Wanted.Rally:ZoneMap() or nil
end

---A layer's short name for chat and the Nearby window: its zone instance number, "497", or "?" for none.
---@param key string?
---@return string
function Shard:Short(key)
	return key and strmatch(key, "(%d+)$") or "?"
end

---A layer as the site and the addon name it: "layer 497".
---@param key string?
---@return string
function Shard:LayerText(key)
	return "layer "..Shard:Short(key)
end

---The name of the zone we're in, as records carry it (the game's zone text).
---@return string
function Shard:Zone()
	return (Wanted.Recorder:GetPosition())
end



-- ============================================================================
-- Others' layers
-- ============================================================================

---Whether a value a peer sent is a layer.
function private.IsKey(key)
	return type(key) == "string" and #key <= MAX_KEY_BYTES and strfind(key, "^%d+%-%d+%-%d+$") ~= nil
end

---Whether a value (a peer's, or the catch-up's) is a layer.
---@param key any
---@return boolean
function Shard:IsKey(key)
	return private.IsKey(key)
end

---A Wanted player's layer, as their last message said (a hello, a rally position, their presence at a capture
---point), with the zone map it was on. No layer, or not one: they're forgotten.
---@param name any the sender, as the game names them
---@param key any their layer
---@param mapId any the zone map they were on
function Shard:Note(name, key, mapId)
	if type(name) ~= "string" then
		return
	end
	if not private.IsKey(key) or type(mapId) ~= "number" then
		private.peers[name] = nil
		return
	end
	local now = GetTime()
	if not private.peers[name] then
		local count = 0
		for other, entry in pairs(private.peers) do
			if now - entry.at > PEER_SECONDS then
				private.peers[other] = nil
			else
				count = count + 1
			end
		end
		if count >= MAX_PEERS then
			return
		end
	end
	private.peers[name] = { key = key, mapId = mapId, at = now }
end

---A Wanted player's layer as they last said it, { key, mapId, at }, or nil when they haven't said lately.
---@param name string
---@return table?
function Shard:Of(name)
	local entry = private.peers[name]
	if entry and GetTime() - entry.at <= PEER_SECONDS then
		return entry
	end
	return nil
end

---Whether a Wanted player is in our zone on another layer than ours: theirs and ours are known, on the same zone
---map, and differ.
---@param name string
---@return boolean
function Shard:IsOther(name)
	local entry = Shard:Of(name)
	local mine, mapId = Shard:Current(), Shard:ZoneMap()
	return entry ~= nil and mine ~= nil and mapId ~= nil and entry.mapId == mapId and entry.key ~= mine
end



-- ============================================================================
-- The target layer: where the fight is
-- ============================================================================

---Takes each zone's fight layer as the site worked it out, from the app's catch-up: { [zone name] = { active, deaths,
---since } }. Only shown, so it's read at every login; malformed zones are left out.
---@param list table?
function Shard:TakeLayers(list)
	wipe(private.site)
	if type(list) ~= "table" then
		return
	end
	for zone, entry in pairs(list) do
		if type(zone) == "string" and type(entry) == "table" and private.IsKey(entry.active) and type(entry.since) == "number" then
			private.site[zone] = { active = entry.active, deaths = type(entry.deaths) == "number" and entry.deaths or 0, since = entry.since }
		end
	end
end

---A kill or death record, ours or heard: one with a layer and a zone, from the last ten minutes, is counted toward
---that zone's fight layer, each death once (a kill and a death record can tell of the same one).
function private.OnDeath(record)
	local data = record.data
	local now = GetServerTime()
	if type(data) ~= "table" or not private.IsKey(data.l) or type(data.zone) ~= "string" or type(record.t) ~= "number"
		or now - record.t > FIGHT_SECONDS or record.t > now + AHEAD_SECONDS or Wanted.Store:IsTest(record) then
		return
	end
	local id = data.deathId or record.id
	local deaths = private.deaths
	for i = #deaths, 1, -1 do
		if now - deaths[i].t > FIGHT_SECONDS then
			tremove(deaths, i)
		elseif deaths[i].id == id then
			return
		end
	end
	if #deaths >= MAX_DEATHS then
		tremove(deaths, 1)
	end
	tinsert(deaths, { t = record.t, zone = data.zone, key = data.l, id = id })
end

---Whether layer a comes before b: the lower zone instance number (ties between layers as busy go to it).
function private.Lower(a, b)
	local na, nb = tonumber(Shard:Short(a)), tonumber(Shard:Short(b))
	if na and nb and na ~= nb then
		return na < nb
	end
	return a < b
end

---This client's own estimate of a zone's fight layer, from the channel: the deaths heard there in the last ten
---minutes by layer, plus the Wanted players of our side heard in the zone by layer (their hello, rally position or
---point presence; us too when it's our zone), the busiest layer once it reaches the floor. nil below it.
---@param zone string
---@param mapId number?
---@return string?
function private.Estimate(zone, mapId)
	local tally, now = wipe(private.tally), GetServerTime()
	for _, death in ipairs(private.deaths) do
		if death.zone == zone and now - death.t <= FIGHT_SECONDS then
			tally[death.key] = (tally[death.key] or 0) + 1
		end
	end
	if mapId then
		for _, entry in pairs(private.peers) do
			if entry.mapId == mapId and GetTime() - entry.at <= PEER_SECONDS then
				tally[entry.key] = (tally[entry.key] or 0) + 1
			end
		end
		local mine = Shard:Current()
		if mine and mapId == Shard:ZoneMap() then
			tally[mine] = (tally[mine] or 0) + 1
		end
	end
	local best
	for key, n in pairs(tally) do
		if n >= FIGHT_FLOOR and (not best or n > tally[best] or (n == tally[best] and private.Lower(key, best))) then
			best = key
		end
	end
	return best
end

---A zone's map: ours when it's the zone we're in, a front's by its name, else nil.
function private.MapOf(zone)
	if zone == Shard:Zone() then
		return Shard:ZoneMap()
	end
	for _, front in ipairs(Wanted.Captures.FRONTS) do
		if front.zone == zone then
			return front.mapId
		end
	end
	return nil
end

---A zone's target layer, the one to be on: during the siege at that front (from an hour before the window until it's
---over) the layer the site picked for it, once picked; else the zone's fight layer as the site last said it (the
---catch-up, for a quarter hour), else this client's own estimate from the channel. Returns the layer and which it
---is, "siege" or "fight", or nil when there's none.
---@param zone string the zone's name, as records carry it
---@param mapId number? its zone map (worked out when left out: ours, or a front's)
---@return string? key
---@return string? kind
function Shard:Target(zone, mapId)
	if type(zone) ~= "string" then
		return nil, nil
	end
	local Captures = Wanted.Captures
	local s = Captures:Siege()
	if s and s.front.zone == zone and s.layer and Captures:RespawnPaused(s.front) then
		return s.layer, "siege"
	end
	local site = private.site[zone]
	if site and GetServerTime() - site.since <= SITE_SECONDS then
		return site.active, "fight"
	end
	local key = private.Estimate(zone, mapId or private.MapOf(zone))
	return key, key and "fight" or nil
end

---One line on a zone's target layer: "The fight is on layer 3, you're on 5" (or "The siege is ..."), "You're on
---the fight's layer", and for a zone we're not in "The siege is on layer 3"; nil when there's no target.
---@param zone string
---@param mapId number?
---@return string?
function Shard:TargetText(zone, mapId)
	local key, kind = Shard:Target(zone, mapId)
	if not key then
		return nil
	end
	local what = kind == "siege" and "siege" or "fight"
	local map = mapId or private.MapOf(zone)
	if not map or map ~= Shard:ZoneMap() then
		return format("The %s is on %s", what, Shard:LayerText(key))
	end
	local mine = Shard:Current()
	if mine == key then
		return format("You're on the %s's layer", what)
	elseif not mine then
		return format("The %s is on %s, yours isn't read yet", what, Shard:LayerText(key))
	end
	return format("The %s is on %s, you're on %s", what, Shard:LayerText(key), Shard:Short(mine))
end



-- ============================================================================
-- Hopping: asking for an invite
-- ============================================================================

---Who can invite us onto the rally's layer in our zone: the rally leader when they're on another layer than ours,
---else the Wanted player of our side last heard on the rally's layer in our zone. Returns the host and the layer, or
---nil and why there's nobody to ask.
---@return string? host
---@return string? why
---@return string? layer
function Shard:HopTarget()
	local mapId = Shard:ZoneMap()
	if not mapId then
		return nil, "Your zone isn't known here."
	end
	local mine = Shard:Current()
	if not mine then
		return nil, "Your layer isn't known yet: look at a creature nearby."
	end
	local leader = Wanted.Rally:Here()
	if not leader or leader.mine then
		return nil, "There's no rally to hop to in your zone."
	end
	local theirs = Shard:Of(leader.name)
	if not theirs or theirs.mapId ~= mapId then
		return nil, format("%s's layer isn't known yet.", leader.name)
	end
	if theirs.key == mine then
		return nil, "You're on the rally's layer."
	end
	return leader.name, nil, theirs.key
end

---Another host on a layer in our zone, heard latest, leaving out the ones that couldn't invite this hop.
---@param layer string
---@param tried table name -> true
---@return string?
function private.NextHost(layer, tried)
	local mapId, best, bestAt = Shard:ZoneMap(), nil, 0
	for name, entry in pairs(private.peers) do
		if not tried[name] and entry.key == layer and entry.mapId == mapId and Shard:Of(name) and entry.at > bestAt then
			best, bestAt = name, entry.at
		end
	end
	return best
end

---Why we can't hop now, or nil.
---@return string?
function Shard:HopWhyNot()
	if private.hop then
		return format("You're already hopping to %s's layer.", private.hop.host)
	end
	if Wanted:InInstance() then
		return "Layer hops are for the open world, not instances."
	end
	if Wanted:InCombat() or InCombatLockdown() then
		return "You can't hop layers in a fight."
	end
	if UnitIsDeadOrGhost("player") then
		return "You can't hop layers while dead."
	end
	if IsInGroup() then
		return "You're in a group: leave it first, then hop."
	end
	if Wanted:GetRequiredUpdate() then
		return format("Update Wanted to %s first: nothing is shared until you do.", Wanted:GetRequiredUpdate())
	end
end

---Hops to the rally's layer: asks the rally leader, or whoever of our side is on it in our zone. Returns why not, or
---nil.
---@return string?
function Shard:Hop()
	local host, why, layer = Shard:HopTarget()
	if not host then
		return why
	end
	return Shard:HopTo(host, layer)
end

---Asks a Wanted player of our side for an invite onto their layer. Their addon invites us (or says why it can't);
---ours accepts their invite and holds their group a while (private.Joined). Returns why not, or nil.
---@param name string the host, as the game names them
---@param layer string? their layer, when known: the move is checked against it
---@return string?
function Shard:HopTo(name, layer)
	local why = Shard:HopWhyNot()
	if why then
		return why
	end
	if type(name) ~= "string" or name == "" or name == Wanted.Store:GetOrigin() then
		return "Name a Wanted player of your side in your zone to hop to."
	end
	if not Wanted.Sync:SendHop(name, { a = 1 }) then
		return format("%s couldn't be asked (not in the sync channel, or whispers are blocked here).", name)
	end
	private.hops = private.hops + 1
	private.hop = { id = private.hops, host = name, target = layer, from = Shard:Current(), state = "asked", asked = GetTime(), tried = { [name] = true } }
	Wanted:Print("Asking %s for an invite onto their layer.", name)
	private.GiveUpLater()
	private.Changed()
	return nil
end

---Gives the hop up once the host we asked last hasn't invited us in time (a refusal moves the ask to the next host,
---whose own time starts then).
function private.GiveUpLater()
	local askedAt = private.hop.asked
	private.Later(INVITE_SECONDS, function()
		local hop = private.hop
		if hop.asked == askedAt and (hop.state == "asked" or hop.state == "invited") then
			Wanted:Print("%s didn't invite you.", hop.host)
			private.End()
		end
	end)
end

---Runs func after seconds, for the hop under way now only.
function private.Later(seconds, func)
	local id = private.hops
	C_Timer.After(seconds, function()
		if private.hop and private.hop.id == id then
			func()
		end
	end)
end

---The hop is over, one way or the other.
function private.End()
	private.hop = nil
	private.Changed()
end

---A hop message by whisper: { a = 1 } asks us for an invite; { r } is our host's answer.
---@param tbl table
---@param sender string
function Shard:OnMessage(tbl, sender)
	if type(tbl) ~= "table" or type(sender) ~= "string" then
		return
	end
	if tbl.a == 1 then
		private.Host(sender)
	elseif type(tbl.r) == "string" and #tbl.r <= 16 then
		private.Answer(sender, tbl.r)
	end
end

---Our host's answer: the invite is coming, or why not (then the next host on that layer is asked, if there is one).
function private.Answer(sender, r)
	local hop = private.hop
	if not hop or hop.host ~= sender or hop.state ~= "asked" then
		return
	end
	if r == "ok" then
		hop.state = "invited"
		Wanted:Print("%s is inviting you.", sender)
		return
	end
	Wanted:Print("%s couldn't invite (%s).", sender, REFUSALS[r] or "no reason given")
	local other = hop.target and private.NextHost(hop.target, hop.tried)
	if other and Wanted.Sync:SendHop(other, { a = 1 }) then
		hop.host, hop.asked, hop.tried[other] = other, GetTime(), true
		Wanted:Print("Asking %s instead.", other)
		private.GiveUpLater()
		private.Changed()
		return
	end
	private.End()
end

---Whether a name the game gives ("Name" or "Name-Realm") is our host's.
function private.IsHost(name)
	local host = private.hop and private.hop.host
	if type(name) ~= "string" or not host then
		return false
	end
	if name == host then
		return true
	end
	local short, hostShort = strmatch(name, "^([^%-]+)"), strmatch(host, "^([^%-]+)")
	-- One of them came without a realm: the names alone must agree
	return short == hostShort and (not strfind(name, "-", 1, true) or not strfind(host, "-", 1, true))
end

---A group invite: the one our hop asked for, from that host, within the time, is accepted by itself (the game's
---popup is closed as accepted, so it doesn't decline on closing); any other is left to the player.
function private.OnInvite(name)
	local hop = private.hop
	if not hop or (hop.state ~= "asked" and hop.state ~= "invited") or not private.IsHost(name) or GetTime() - hop.asked > INVITE_SECONDS then
		return
	end
	if not Shard:Settings().accept then
		Wanted:Print("Accept %s's invite to hop onto their layer.", hop.host)
		return
	end
	local popup = StaticPopup_Visible and StaticPopup_Visible("PARTY_INVITE")
	local frame = type(popup) == "string" and _G[popup] or type(popup) == "table" and popup or nil
	if frame then
		frame.inviteAccepted = 1
	end
	AcceptGroup()
	StaticPopup_Hide("PARTY_INVITE")
	hop.state = "accepted"
end

---The group changed: our host's group taken up starts the hold.
function private.OnRoster()
	local hop = private.hop
	if not hop or hop.state == "joined" or not IsInGroup() or not Wanted.Raids:InGroup(hop.host) then
		return
	end
	private.Joined()
end

---In the host's group: the game moves us to their layer. We hold the group HOLD_SECONDS so the server doesn't bounce
---us back, then leave it, unless we chose to stay or the host leads the rally here. At WATCHDOG_SECONDS the creatures
---around us say whether we moved: still on the old layer, we say so and leave.
function private.Joined()
	local hop = private.hop
	hop.state, hop.joined = "joined", GetTime()
	-- The creatures here are the new layer's: what the old ones said is forgotten
	private.Forget()
	local leader = Wanted.Rally:Here()
	if leader and not leader.mine and leader.name == hop.host then
		hop.stay = true
		Wanted:Print("You joined %s's group, the rally leader's: it takes you to their layer. Staying in it.", hop.host)
	else
		Wanted:Print("You joined %s's group: it takes you to their layer. Leaving it in %d seconds (/wanted hop stay to stay).", hop.host, HOLD_SECONDS)
	end
	private.Countdown()
	private.Later(WATCHDOG_SECONDS, function()
		if hop.from and Shard:Current() == hop.from then
			Wanted:Print("You're still on your old layer: the move didn't happen. Leaving %s's group.", hop.host)
			private.Leave()
			private.End()
		end
	end)
	private.Later(HOLD_SECONDS, function()
		if not hop.stay then
			private.Leave()
			local now = Shard:Current()
			if now and now ~= hop.from then
				Wanted:Print("Moved to %s's layer.", hop.host)
			else
				Wanted:Print("Left %s's group. Look at a creature nearby to read your layer.", hop.host)
			end
		end
		private.End()
	end)
	private.Changed()
end

---The hold's countdown at the top of the screen, a second at a time.
function private.Countdown()
	local hop = private.hop
	if not hop or hop.state ~= "joined" or hop.stay then
		return
	end
	local left = HOLD_SECONDS - floor(GetTime() - hop.joined + 0.5)
	if left <= 0 then
		return
	end
	Wanted.Alerts:Warn("LAYER HOP", format("Leaving %s's group in %d s. Stay in Nearby, or /wanted hop stay", hop.host, left), Wanted.Theme.C.gold)
	private.Later(1, private.Countdown)
end

---Stays in the host's group after the hop (the rally's raid). Returns why not, or nil.
---@return string?
function Shard:Stay()
	local hop = private.hop
	if not hop or hop.state ~= "joined" then
		return "You're not in a layer hop's group."
	end
	if hop.stay then
		return nil
	end
	hop.stay = true
	Wanted:Print("Staying in %s's group.", hop.host)
	private.End()
	return nil
end

---Whether we're holding a hop's group and will leave it: the Stay buttons show.
---@return boolean
function Shard:Holding()
	local hop = private.hop
	return hop ~= nil and hop.state == "joined" and not hop.stay
end

---The hop under way, { host, state }, or nil.
---@return table?
function Shard:Hopping()
	return private.hop
end

function private.Leave()
	if C_PartyInfo and C_PartyInfo.LeaveParty then
		C_PartyInfo.LeaveParty()
	elseif LeaveParty then
		LeaveParty()
	end
end

---Redraws the Nearby window and the HUD for a hop's change.
function private.Changed()
	if Wanted.NearbyWindow and Wanted.NearbyWindow:IsShown() then
		Wanted.NearbyWindow:Refresh()
	end
	if Wanted.CapturesHUD then
		Wanted.CapturesHUD:Update()
	end
end



-- ============================================================================
-- Hosting: answering an ask
-- ============================================================================

---Why we can't invite a player onto our layer now, or nil.
function private.HostWhyNot(name)
	if not Shard:Settings().host then
		return "off"
	end
	if Wanted:InInstance() then
		return "instance"
	end
	if UnitIsDeadOrGhost("player") then
		return "dead"
	end
	local last = private.hosted[name]
	if last and GetTime() - last < HOST_AGAIN_SECONDS then
		return "busy"
	end
end

---Someone asks us for an invite: they get one (the Raids module's invite) and "ok", or why not. Where the game
---blocks whispers (an instance) no answer can go: they're left to their half-minute wait.
function private.Host(name)
	if Wanted.Sync:WhispersLocked() then
		return
	end
	local why = private.HostWhyNot(name) or Wanted.Raids:Invite(name)
	if why then
		Wanted.Sync:SendHop(name, { r = why })
		return
	end
	private.hosted[name] = GetTime()
	Wanted.Sync:SendHop(name, { r = "ok" })
	Wanted:Print("Inviting %s to your group: they asked for a hop onto your layer.", name)
end

Wanted:RegisterCommand("hop", "Hops to the rally's layer in your zone (/wanted hop), to a Wanted player's (/wanted hop Name), or stays in the group after one (/wanted hop stay).", function(args)
	args = strtrim(args or "")
	local why
	if strlower(args) == "stay" then
		why = Shard:Stay()
	elseif args ~= "" then
		why = Shard:HopTo(args)
	else
		why = Shard:Hop()
	end
	if why then
		Wanted:Print("%s", why)
	end
end)

Wanted:RegisterCommand("shard", "Says which layer of your zone you're on, and which the rally leader is on.", function()
	local mine = Shard:Current()
	Wanted:Print("Your layer: %s%s.", Shard:Short(mine), mine and (Shard:IsFresh() and " (confirmed in the last minute)" or "") or " (look at a creature nearby to read it)")
	local leader = Wanted.Rally and Wanted.Rally:Here()
	if not leader or leader.mine then
		return
	end
	local theirs = Shard:Of(leader.name)
	Wanted:Print("%s leads the rally here on layer %s%s.", leader.name, Shard:Short(theirs and theirs.key),
		Shard:IsOther(leader.name) and ": not yours" or theirs and theirs.key == mine and ": yours" or "")
end)
