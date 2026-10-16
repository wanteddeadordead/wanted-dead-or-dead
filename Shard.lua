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

function Shard:OnEnable()
	for event in pairs(UNIT_EVENTS) do
		private.Register(event)
	end
	for _, event in ipairs({ "NAME_PLATE_UNIT_ADDED", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" }) do
		private.Register(event)
	end
	private.frame:SetScript("OnEvent", Wanted:Timed("Shard events", private.OnEvent))
end

---Registers an event if this client has it.
function private.Register(event)
	if not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid(event) then
		private.frame:RegisterEvent(event)
	end
end

function private.OnEvent(_, event, unit)
	if event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
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



-- ============================================================================
-- Others' layers
-- ============================================================================

---Whether a value a peer sent is a layer.
function private.IsKey(key)
	return type(key) == "string" and #key <= MAX_KEY_BYTES and strfind(key, "^%d+%-%d+%-%d+$") ~= nil
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
