-- Wanted: layers. WoW Forever runs each zone as several copies (layers, or shards), and players on different layers
-- of a zone can't see or fight each other. A creature's GUID names the copy it lives in:
-- Creature-0-<server>-<map>-<zone instance>-<creature>-<spawn>. Server, map and zone instance together change from
-- one layer to the next and stay the same within one (the maintainer's combat logs, 2026-10-09: one quest giver under
-- a new number on each layer, a zone's creatures all under one). Our layer is the one most of the creatures looked at
-- lately in this zone live in, so a creature seen over a zone border doesn't change it. It goes out with our hello,
-- our rally position and our capture-point presence (Sync, Rally, Captures), so every Wanted player's layer is known
-- with their zone, and the Nearby window says when the rally leader is on another one.
--
-- Each zone has one target layer (Shard:Target): the layer the site picked for tonight's siege while the siege is on
-- at that front, else the zone's fight layer, as the site last said it or as this client reckons it from the deaths
-- and the Wanted players heard on the channel. Nobody picks a layer: the hop goes to the target or nowhere.
--
-- The only way onto another layer is to join a group whose leader is on it. A layer hop asks the Wanted player of
-- our side heard latest on the target layer in our zone for an invite (by addon whisper); their addon invites us
-- (never dead, in a fight, in an instance, in a full group, in a raid they can't invite to, or with hosting off, and
-- a refusal moves the ask to the next host), ours accepts the invite from that host alone, holds the group twenty
-- seconds so the server doesn't bounce us back, then leaves it, unless we chose to stay or the host leads the rally.
-- The game says whether the move happens: SHARD_TRANSFER_IMMINENT (its "refresh world" countdown; the group is held
-- until it runs out), then SHARD_TRANSFER (moved) or SHARD_TRANSFER_CANCELLED (not moved: we say so and leave). When
-- no such event comes, the creatures around us say at fifteen seconds whether we moved. One hop every ten minutes.

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
	-- The other side's Wanted players by zone map and layer, as their bridges summarise them (Bridge: hidden game data
	-- through the Wanted Battle.net group, never chat), and as a bridge of our side passes them on to the channel
	-- ("X"): sender -> { at (GetTime), list = { [mapId] = { [layer] = n } } }. Counted in the estimate, the most any
	-- one sender says of a layer, so two bridges telling of the same players don't double them
	far = {},
	hop = nil, -- the hop under way: { id, host, target, from, state, asked, joined, leaveAt, stay, tried, imminent, moved } (Shard:Hop)
	hosted = {}, -- name -> GetTime() we last invited them for a hop (one ask a while each)
	hops = 0, -- hops started, so a timer for an earlier one changes nothing
	lastHopAt = nil, -- GetTime() we last joined a host's group for a hop (the cooldown runs from it)
	siegeTold = nil, -- the siege layer last announced
	fight = nil, -- the fight layer last seen in our zone, { zone, key }, so a new one is news
	fightToldAt = nil, -- GetTime() a fight layer was last announced
}
-- A host has this long to invite after we ask; an invite from them later than this is left to the player
local INVITE_SECONDS = 30
-- Once in the host's group, how long we stay so the server doesn't bounce us back (longer while the game's own
-- transfer countdown runs, up to MAX_HOLD_SECONDS, plus a moment for the move itself), and when the creatures around
-- us are asked whether the move happened, failing any word from the game
local HOLD_SECONDS = 20
local MAX_HOLD_SECONDS = 120
local MOVE_GRACE_SECONDS = 3
local WATCHDOG_SECONDS = 15
-- A host invites one player this often at most
local HOST_AGAIN_SECONDS = 30
-- One hop this often: layers aren't for picking
local COOLDOWN_SECONDS = 10 * 60
-- Why a host couldn't invite, as their addon said it (r), in plain words
local REFUSALS = {
	combat = "in combat",
	dead = "dead",
	full = "their group is full",
	cant = "not their group's leader or an assistant",
	off = "they aren't leading a group or the rally, and hosting hops is off in their settings",
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
-- A zone's fight layer is announced at most this often
local FIGHT_TOLD_SECONDS = 10 * 60
-- The other side's summaries (Shard:NoteFar) count this long, from this many senders, this many entries each
local FAR_SECONDS = 10 * 60
local MAX_FAR_SENDERS = 20
local MAX_FAR_ENTRIES = 12
local MAX_FAR_COUNT = 200
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
	-- host: invite Wanted players who ask for a hop onto our layer even when we lead nothing (Shard:Hosting); accept:
	-- take the invite our hop asked for by itself
	local settings = Wanted.db.settings
	settings.shard = type(settings.shard) == "table" and settings.shard or {}
	for key, value in pairs({ host = false, accept = true }) do
		if type(settings.shard[key]) ~= "boolean" then
			settings.shard[key] = value
		end
	end
end

function Shard:OnEnable()
	for event in pairs(UNIT_EVENTS) do
		private.Register(event)
	end
	for _, event in ipairs({ "NAME_PLATE_UNIT_ADDED", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD", "PARTY_INVITE_REQUEST", "GROUP_ROSTER_UPDATE",
		"SHARD_TRANSFER_IMMINENT", "SHARD_TRANSFER", "SHARD_TRANSFER_CANCELLED" }) do
		private.Register(event)
	end
	private.frame:SetScript("OnEvent", Wanted:Timed("Shard events", private.OnEvent))
	-- The deaths our side hears of (both sides' kills and deaths reach the channel) say where the fight is, by layer
	Wanted.Store:OnRecord("kill", private.OnDeath)
	Wanted.Store:OnRecord("death", private.OnDeath)
	-- The siege's layer, picked or switched (a peer's word, or the catch-up); the catch-up read at login came before
	-- this module was enabled, so its pick is told now
	Wanted.Captures:OnSiege(function(kind)
		if kind == "layer" then
			private.TellSiegeLayer()
		end
	end)
	private.TellSiegeLayer()
end

---The layer hop settings: { host, accept }.
function Shard:Settings()
	return Wanted.db.settings.shard
end

---Whether we lead our group (the game keeps it secret in instances, where there's no hosting anyway).
function private.LeadsGroup()
	if not IsInGroup() or type(UnitIsGroupLeader) ~= "function" then
		return false
	end
	local ok, yes = pcall(UnitIsGroupLeader, "player")
	return ok and not (issecretvalue and issecretvalue(yes)) and yes == true
end

---Whether we host layer hops now: while we lead a group or the rally here, hosting is on (whoever gathers people
---takes them onto their layer); otherwise only with the setting switched on.
---@return boolean
function Shard:Hosting()
	return Shard:Settings().host == true or private.LeadsGroup() or (Wanted.Rally and Wanted.Rally:Mine() ~= nil) or false
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
		-- Each zone has its own layers: read afresh, and the lines say the new zone's target at once
		private.Forget()
		private.CheckFight()
		private.Changed()
		return
	elseif event == "SHARD_TRANSFER_IMMINENT" then
		private.OnImminent()
		return
	elseif event == "SHARD_TRANSFER" then
		private.OnTransfer()
		return
	elseif event == "SHARD_TRANSFER_CANCELLED" then
		private.OnCancelled()
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

---The game is about to move us to another layer (its "refresh world" countdown, after joining a group whose leader
---is elsewhere): a hop holds the group until the countdown runs out, so the move isn't called off by leaving.
function private.OnImminent()
	local hop = private.hop
	if not hop or hop.state ~= "joined" or hop.moved then
		return
	end
	hop.imminent = true
	local left = type(GetEvictionTimeRemaining) == "function" and select(2, pcall(GetEvictionTimeRemaining))
	left = type(left) == "number" and not (issecretvalue and issecretvalue(left)) and left > 0 and left or nil
	if left then
		hop.leaveAt = max(hop.leaveAt, min(GetTime() + left + MOVE_GRACE_SECONDS, hop.joined + MAX_HOLD_SECONDS))
	end
	Wanted:Print("The game is moving you to %s%s.", Shard:LayerText(hop.target), left and format(" in %d s", ceil(left)) or "")
	private.Changed()
end

---The game moved us to another layer: the creatures seen so far were the old one's, and a hop's move is confirmed.
function private.OnTransfer()
	private.Forget()
	local hop = private.hop
	if hop and hop.state == "joined" and not hop.moved then
		hop.moved = true
		Wanted:Print("Moved to %s: the game confirmed it.", Shard:LayerText(hop.target))
	end
	private.Changed()
end

---The game called the move off: a hop's group is left, we're still where we were.
function private.OnCancelled()
	local hop = private.hop
	if not hop or hop.state ~= "joined" or hop.moved then
		return
	end
	Wanted:Print("The game called the move off: you're still on your layer. Leaving %s's group.", hop.host)
	private.Leave()
	private.End()
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

---Whether two layer ids name the same layer: the same id, or the same layer number (the part after the last dash).
---The server and map parts can differ between what the site stored (an operator's typed pin, another client's
---reading) and what this client reads off creature GUIDs; the number is the layer (2026-10-16: "4615-0-6" against a
---reading ending in 6 said "you're on 6" with a Hop button).
---@param a string?
---@param b string?
---@return boolean
function Shard:Same(a, b)
	return a ~= nil and b ~= nil and (a == b or Shard:Short(a) == Shard:Short(b))
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
	private.CheckFight()
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
	private.CheckFight()
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
	private.CheckFight()
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
		private.FarCounts(mapId, tally)
	end
	local best
	for key, n in pairs(tally) do
		if n >= FIGHT_FLOOR and (not best or n > tally[best] or (n == tally[best] and private.Lower(key, best))) then
			best = key
		end
	end
	return best
end

---Adds the other side's players on a zone map to the tally, by layer: the most any one sender says lately.
function private.FarCounts(mapId, tally)
	local now, best = GetTime(), {}
	for _, entry in pairs(private.far) do
		local layers = now - entry.at <= FAR_SECONDS and entry.list[mapId]
		if layers then
			for key, n in pairs(layers) do
				if n > (best[key] or 0) then
					best[key] = n
				end
			end
		end
	end
	for key, n in pairs(best) do
		tally[key] = (tally[key] or 0) + n
	end
end

---Our side's Wanted players by zone map and layer, from the channel in the last PEER_SECONDS (us too), for the other
---side's reckoning: { { m = mapId, l = layer, n = count }, ... }, the busiest first, at most MAX_FAR_ENTRIES.
---@return table[]
function Shard:FarSummary()
	local list = {}
	local now, counts = GetTime(), {}
	local function Add(mapId, key)
		counts[mapId] = counts[mapId] or {}
		counts[mapId][key] = (counts[mapId][key] or 0) + 1
	end
	for _, entry in pairs(private.peers) do
		if now - entry.at <= PEER_SECONDS then
			Add(entry.mapId, entry.key)
		end
	end
	local mine, mapId = Shard:Current(), Shard:ZoneMap()
	if mine and mapId then
		Add(mapId, mine)
	end
	for m, layers in pairs(counts) do
		for l, n in pairs(layers) do
			tinsert(list, { m = m, l = l, n = n })
		end
	end
	sort(list, function(a, b)
		if a.n ~= b.n then
			return a.n > b.n
		elseif a.m ~= b.m then
			return a.m < b.m
		end
		return a.l < b.l
	end)
	for i = MAX_FAR_ENTRIES + 1, #list do
		list[i] = nil
	end
	return list
end

---Takes the other side's summary (Shard:FarSummary as their bridge sent it, or as a bridge of our side passed it on
---the channel), by sender; malformed entries are left out.
---@param sender string who it came from (a Battle.net game account, or the channel peer passing it on)
---@param list any
function Shard:NoteFar(sender, list)
	if type(sender) ~= "string" or type(list) ~= "table" then
		return
	end
	local kept, count = {}, 0
	for _, entry in ipairs(list) do
		if type(entry) == "table" and type(entry.m) == "number" and private.IsKey(entry.l) and type(entry.n) == "number" and entry.n >= 1 then
			kept[entry.m] = kept[entry.m] or {}
			kept[entry.m][entry.l] = min(floor(entry.n), MAX_FAR_COUNT)
			count = count + 1
			if count >= MAX_FAR_ENTRIES then
				break
			end
		end
	end
	local now = GetTime()
	if count == 0 then
		private.far[sender] = nil
		return
	end
	local senders = 0
	for other, entry in pairs(private.far) do
		if now - entry.at > FAR_SECONDS then
			private.far[other] = nil
		else
			senders = senders + 1
		end
	end
	if not private.far[sender] and senders >= MAX_FAR_SENDERS then
		return
	end
	private.far[sender] = { at = now, list = kept }
	private.CheckFight()
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

---The Hop hint under an announcement: the command only (a warning has no tooltip); chat says it in full.
local HOP_HINT = "/wanted hop"

---Says which layer tonight's siege is on, when it's picked or switches (the Siege call setting, wherever we are),
---once per pick.
function private.TellSiegeLayer()
	local Captures = Wanted.Captures
	local s, key = Captures:Siege(), Captures:SiegeLayer()
	if not s or not key or s.over or key == private.siegeTold then
		return
	end
	private.siegeTold = key
	if Captures:Settings().siegeCall then
		Wanted.Alerts:Warn(format("The siege of %s is on %s", s.front.zone, Shard:LayerText(key)), HOP_HINT, Wanted.Theme.C.gold)
		Wanted:Print("The siege of %s is on %s. Hop to it: /wanted hop, or Hop in Nearby.", s.front.zone, Shard:LayerText(key))
	end
	private.Changed()
end

---A fight layer newly known in our zone (the site's word or this client's estimate) is announced, at most once in
---ten minutes (the capture alerts setting); the siege's layer is told by private.TellSiegeLayer instead.
function private.CheckFight()
	if Wanted:InInstance() then
		return
	end
	local zone, mapId = Shard:Zone(), Shard:ZoneMap()
	if not mapId then
		return
	end
	local key, kind = Shard:Target(zone, mapId)
	if kind ~= "fight" then
		private.fight = nil
		return
	end
	local last = private.fight
	if last and last.zone == zone and last.key == key then
		return
	end
	private.fight = { zone = zone, key = key }
	local now = GetTime()
	if (private.fightToldAt and now - private.fightToldAt < FIGHT_TOLD_SECONDS) or not Wanted.Captures:Settings().alerts then
		return
	end
	private.fightToldAt = now
	local sub = Shard:Same(Shard:Current(), key) and zone..": you're on it" or zone..". "..HOP_HINT
	Wanted.Alerts:Warn(format("Big fight on %s", Shard:LayerText(key)), sub, Wanted.Theme.C.amber)
	Wanted:Print("Big fight on %s in %s.", Shard:LayerText(key), sub)
	private.Changed()
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
	if Shard:Same(mine, key) then
		return format("You're on the %s's layer", what)
	elseif not mine then
		return format("The %s is on %s, yours isn't read yet", what, Shard:LayerText(key))
	end
	return format("The %s is on %s, you're on %s", what, Shard:LayerText(key), Shard:Short(mine))
end



-- ============================================================================
-- Hopping: asking for an invite
-- ============================================================================

---The Wanted player of our side to ask for an invite onto a layer in our zone: the one heard there latest (their
---hello, rally position or point presence), leaving out the ones that couldn't invite this hop. nil when there's
---nobody.
---@param layer string
---@param tried table name -> true
---@return string?
function private.NextHost(layer, tried)
	local mapId, best, bestAt = Shard:ZoneMap(), nil, 0
	for name, entry in pairs(private.peers) do
		if not tried[name] and Shard:Same(entry.key, layer) and entry.mapId == mapId and Shard:Of(name) and entry.at > bestAt then
			best, bestAt = name, entry.at
		end
	end
	return best
end

---Why we can't hop now, or nil.
---@return string?
function Shard:HopWhyNot()
	if private.hop then
		return format("You're already hopping to %s.", Shard:LayerText(private.hop.target))
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
		return "You're in a group: leave your group first, then hop."
	end
	if Wanted:GetRequiredUpdate() then
		return format("Update Wanted to %s first: nothing is shared until you do.", Wanted:GetRequiredUpdate())
	end
	local since = private.lastHopAt and GetTime() - private.lastHopAt
	if since and since < COOLDOWN_SECONDS then
		local left = COOLDOWN_SECONDS - since
		return format("One hop every %d minutes: your next is allowed in %s.", COOLDOWN_SECONDS / 60, left >= 60 and format("%d min", ceil(left / 60)) or format("%d s", ceil(left)))
	end
end

---Hops to our zone's target layer, the fight's or the siege's (Shard:Target): asks the Wanted player of our side
---heard latest on it in our zone for an invite. Their addon invites us (or says why it can't, and the next host is
---asked); ours accepts their invite and holds their group a while (private.Joined). Returns why not, or nil.
---@return string?
function Shard:Hop()
	local why = Shard:HopWhyNot()
	if why then
		return why
	end
	local zone = Shard:Zone()
	if not Shard:ZoneMap() then
		return "Your zone isn't known here."
	end
	local target, kind = Shard:Target(zone)
	if not target then
		return format("No fight layer is known in %s yet.", zone)
	end
	local mine = Shard:Current()
	if not mine then
		return "Your layer isn't known yet: look at a creature nearby."
	end
	if Shard:Same(mine, target) then
		return format("You're on the %s's layer.", kind)
	end
	local host = private.NextHost(target, {})
	if not host then
		return format("No one on %s can invite you yet.", Shard:LayerText(target))
	end
	if not Wanted.Sync:SendHop(host, { a = 1 }) then
		return format("%s couldn't be asked (not in the sync channel, or whispers are blocked here).", host)
	end
	private.hops = private.hops + 1
	private.hop = { id = private.hops, host = host, target = target, from = mine, state = "asked", asked = GetTime(), tried = { [host] = true } }
	Wanted:Print("Asking %s for an invite onto %s.", host, Shard:LayerText(target))
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
	-- Their word on their layer is stale too: the next ask, if any, goes elsewhere
	local other = private.NextHost(hop.target, hop.tried)
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
---us back (longer while the game's transfer countdown runs: private.OnImminent), then leave it, unless we chose to
---stay or the host leads the rally here. The game's events say whether we moved; failing them, at WATCHDOG_SECONDS the
---creatures around us do: still on the old layer, we say so and leave.
function private.Joined()
	local hop = private.hop
	hop.state, hop.joined = "joined", GetTime()
	hop.leaveAt = hop.joined + HOLD_SECONDS
	private.lastHopAt = hop.joined
	-- The creatures here are the new layer's: what the old ones said is forgotten
	private.Forget()
	local where = Shard:LayerText(hop.target)
	local leader = Wanted.Rally:Here()
	if leader and not leader.mine and leader.name == hop.host then
		hop.stay = true
		Wanted:Print("You joined %s's group, the rally leader's: it takes you to %s. Staying in it.", hop.host, where)
	else
		Wanted:Print("You joined %s's group: it takes you to %s. Leaving it in %d seconds (/wanted hop stay to stay).", hop.host, where, HOLD_SECONDS)
	end
	private.Countdown()
	private.Later(WATCHDOG_SECONDS, private.Watchdog)
	private.Later(HOLD_SECONDS, private.Settle)
	private.Changed()
end

---No word from the game by now: the creatures around us say whether we moved. Still on the old layer, we say so and
---leave the group.
function private.Watchdog()
	local hop = private.hop
	if hop.moved or hop.imminent or not hop.from or Shard:Current() ~= hop.from then
		return
	end
	Wanted:Print("You're still on your old layer: the move didn't happen. Leaving %s's group.", hop.host)
	private.Leave()
	private.End()
end

---The hold is over (or goes on while the game's countdown runs): the group is left unless we stay, and the move is
---told from the game's word or, failing it, from the creatures around us.
function private.Settle()
	local hop = private.hop
	local left = hop.leaveAt - GetTime()
	if left > 0.5 then
		private.Later(left, private.Settle)
		return
	end
	if not hop.stay then
		private.Leave()
		local now = Shard:Current()
		if hop.moved or (now and now ~= hop.from) then
			Wanted:Print("Moved to %s.", Shard:LayerText(hop.target))
		else
			Wanted:Print("Left %s's group. Look at a creature nearby to read your layer.", hop.host)
		end
	end
	private.End()
end

---The hold's countdown at the top of the screen, a second at a time.
function private.Countdown()
	local hop = private.hop
	if not hop or hop.state ~= "joined" or hop.stay then
		return
	end
	local left = floor(hop.leaveAt - GetTime() + 0.5)
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

---The hop under way, { host, state, target }, or nil.
---@return table?
function Shard:Hopping()
	return private.hop
end

---The hop under way as one line: who's asked, who's inviting, or whose group is held and for how long. nil without one.
---@return string?
function Shard:HopText()
	local hop = private.hop
	if not hop then
		return nil
	end
	local where = Shard:LayerText(hop.target)
	if hop.state == "joined" then
		if hop.stay then
			return format("In %s's group: it takes you to %s", hop.host, where)
		end
		return format("In %s's group for %s: leaving it in %d s", hop.host, where, max(0, floor(hop.leaveAt - GetTime() + 0.5)))
	elseif hop.state == "invited" or hop.state == "accepted" then
		return format("%s is inviting you onto %s", hop.host, where)
	end
	return format("Asking %s for an invite onto %s", hop.host, where)
end

---One line on a zone's layer and the button to go with it: the hop under way (Stay while its group is held), else
---the zone's target layer as Shard:TargetText says it, with Hop while it's our zone and we're not on it. Nothing
---without either.
---@param zone string
---@param mapId number?
---@return string? text
---@return string? button "Hop" or "Stay"
function Shard:Line(zone, mapId)
	if private.hop then
		return Shard:HopText(), Shard:Holding() and "Stay" or nil
	end
	local text = Shard:TargetText(zone, mapId)
	if not text then
		return nil, nil
	end
	local map = mapId or private.MapOf(zone)
	local here = map ~= nil and map == Shard:ZoneMap()
	return text, here and not Shard:Same(Shard:Target(zone, mapId), Shard:Current()) and "Hop" or nil
end

function private.Leave()
	if C_PartyInfo and C_PartyInfo.LeaveParty then
		C_PartyInfo.LeaveParty()
	elseif LeaveParty then
		LeaveParty()
	end
end

---Redraws the layer lines (Nearby, the HUD, the Hotspots page when open) for a hop's or a zone's change.
function private.Changed()
	if Wanted.NearbyWindow and Wanted.NearbyWindow:IsShown() then
		Wanted.NearbyWindow:Refresh()
	end
	if Wanted.CapturesHUD then
		Wanted.CapturesHUD:Update()
	end
	if Wanted.UI and Wanted.UI:IsShown("hotspots") then
		Wanted.UI:Refresh()
	end
end



-- ============================================================================
-- Hosting: answering an ask
-- ============================================================================

---Why we can't invite a player onto our layer now, or nil.
function private.HostWhyNot(name)
	if not Shard:Hosting() then
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

Wanted:RegisterCommand("hop", "Hops to the fight's (or the siege's) layer in your zone (/wanted hop), or stays in the group after one (/wanted hop stay).", function(args)
	args = strlower(strtrim(args or ""))
	local why
	if args == "stay" then
		why = Shard:Stay()
	elseif args ~= "" then
		why = "Hops go to the fight's layer only: /wanted hop, or /wanted hop stay to keep the group after one."
	else
		why = Shard:Hop()
	end
	if why then
		Wanted:Print("%s", why)
	end
end)

Wanted:RegisterCommand("shard", "Says which layer of your zone you're on, which the fight is on, and which the rally leader is on.", function()
	local mine = Shard:Current()
	Wanted:Print("Your layer: %s%s.", Shard:Short(mine), mine and (Shard:IsFresh() and " (confirmed in the last minute)" or "") or " (look at a creature nearby to read it)")
	local text = Shard:TargetText(Shard:Zone())
	Wanted:Print("%s.", text or format("No fight layer is known in %s yet", Shard:Zone()))
	local leader = Wanted.Rally and Wanted.Rally:Here()
	if not leader or leader.mine then
		return
	end
	local theirs = Shard:Of(leader.name)
	Wanted:Print("%s leads the rally here on layer %s%s.", leader.name, Shard:Short(theirs and theirs.key),
		Shard:IsOther(leader.name) and ": not yours" or theirs and theirs.key == mine and ": yours" or "")
end)

-- The other side's summary passed on the channel by a bridge of our side (Bridge), so every Wanted player of the
-- faction reckons with it, not only those with a bridge of their own
Wanted.Sync:RegisterPlugin("X", function(tbl, sender)
	if type(tbl) == "table" then
		Shard:NoteFar(sender, tbl.z)
	end
end, { priority = 3 })
