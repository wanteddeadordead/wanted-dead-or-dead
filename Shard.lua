-- Wanted: which shard of its zone this client is on. WoW Forever runs each zone as several copies (shards), and
-- players on different shards of a zone can't see or fight each other. A creature's GUID names the copy it lives in:
-- Creature-0-<server>-<map>-<zone instance>-<creature>-<spawn>. Server, map and zone instance together change from
-- one shard to the next and stay the same within one (Chris's combat logs, 2026-10-09: one quest giver under a new
-- number on each shard, a zone's creatures all under one). The shard is the one most of the creatures looked at
-- lately in this zone live in, so a creature seen over a zone border doesn't change it. Peers send theirs with their
-- shared sightings (Sync), and a sighting from another shard of our zone is marked (Enemies, the Nearby window): that
-- enemy isn't where we can meet them.

local _, Wanted = ...
local Shard = Wanted:NewModule("Shard")
local private = {
	frame = CreateFrame("Frame"),
	votes = {}, -- the last creatures looked at in this zone, oldest first: { guid, key }
	voted = {}, -- guid -> true for the creatures in votes
	seenAt = nil, -- GetTime() a creature of this zone was last looked at, counted before or not
	counts = {}, -- scratch for Get: key -> creatures
}
-- How many creatures the shard is taken from
local VOTES = 15
-- Not confirmed by a creature for this long, the shard is unknown again (a group invite can move a player)
local STALE_SECONDS = 10 * 60
-- A shard a peer sends: three numbers, never longer than this
local MAX_KEY_BYTES = 32
-- Events that put a unit in reach, and the unit token each one is about
local UNIT_EVENTS = {
	PLAYER_TARGET_CHANGED = "target",
	UPDATE_MOUSEOVER_UNIT = "mouseover",
	PLAYER_SOFT_ENEMY_CHANGED = "softenemy",
	PLAYER_SOFT_FRIEND_CHANGED = "softfriend",
	PLAYER_SOFT_INTERACT_CHANGED = "softinteract",
}
-- GUID kinds that carry a shard. Players' don't (Player-<realm>-<id>); pets are left out, a player's own summons.
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
		-- Each zone has its own shards
		wipe(private.votes)
		wipe(private.voted)
		private.seenAt = nil
		return
	end
	-- In an instance there are no shards to meet anyone on, and unit identity is secret
	if Wanted:InInstance() then
		return
	end
	private.Look(UNIT_EVENTS[event] or unit)
end



-- ============================================================================
-- Reading the shard
-- ============================================================================

---The shard a GUID names ("server-map-zone instance"), or nil for a GUID that names none (a player's, a pet's).
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

---Counts the shard of the creature on a unit, once per creature. One counted before still confirms the shard is
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

---This client's shard of its zone ("server-map-zone instance"), or nil while it isn't known.
---@return string?
function Shard:Get()
	local votes = private.votes
	if not votes[1] or GetTime() - (private.seenAt or 0) > STALE_SECONDS then
		return nil
	end
	local counts, best = wipe(private.counts), nil
	-- Newest first: of two shards with as many creatures, the one seen last wins
	for i = #votes, 1, -1 do
		local key = votes[i].key
		counts[key] = (counts[key] or 0) + 1
		if not best or counts[key] > counts[best] then
			best = key
		end
	end
	return best
end

---Whether a shard a peer sent is another shard of the zone we're in: ours is known, theirs came with a sighting on
---the map we're on, and they differ. Unknown, another zone, or not a shard at all: not another shard.
---@param key any the peer's shard
---@param mapId any the map their sighting was on
---@return boolean
function Shard:IsOther(key, mapId)
	if type(key) ~= "string" or #key > MAX_KEY_BYTES or not strfind(key, "^%d+%-%d+%-%d+$") then
		return false
	end
	local mine = Shard:Get()
	if not mine or mapId == nil or mapId ~= C_Map.GetBestMapForUnit("player") then
		return false
	end
	return key ~= mine
end

---What the Nearby window shows: "Shard 497" (the zone instance), or "Shard ?" while it isn't known.
---@return string
function Shard:Label()
	local key = Shard:Get()
	return "Shard "..(key and strmatch(key, "(%d+)$") or "?")
end
