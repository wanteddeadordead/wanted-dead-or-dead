-- Wanted: rally leaders. A group's leader can mark themselves the rally leader for their zone: their client shares
-- where they stand on the sync channel every half minute, and Wanted players of their faction in that zone see them
-- on the world map and at the top of the Nearby window. One per faction per zone: the earlier claim holds, and in
-- the same second the name that sorts first. A rally ends when its leader dies, leaves the zone, ends it, or stands
-- still for half an hour; others drop one they haven't heard from for five minutes (logged off, or out of reach).
-- A rally is only ever taken from its leader's own client: the game names who sent each message, and nobody passes
-- one on. Nothing is saved: a /reload ends the rally, and the others drop it as they stop hearing it.

local _, Wanted = ...
local Rally = Wanted:NewModule("Rally")
local Store = Wanted.Store
local Sync = Wanted.Sync
local private = {
	mine = nil, -- the rally we lead: { claimed (server time), zone, mapId, x, y, moved (GetTime), sends, sentAt (GetTime) }
	leaders = {}, -- sender -> { name, claimed, firstHeard, heard (server time), zone, mapId, x, y, class } others' rallies
	told = {}, -- sender..":"..claimed -> true once we've said they lead the rally in our zone
	frame = CreateFrame("Frame"),
}
local SEND_SECONDS = 30 -- the leader's position goes out this often
local LINK_EVERY = 4 -- and every fourth time (two minutes) to the realm links too, whose budget is smaller
local GONE_SECONDS = 5 * 60 -- a rally not heard for this long has gone
local IDLE_SECONDS = 30 * 60 -- a leader who hasn't moved for this long ends their rally
local EARLY_SECONDS = GONE_SECONDS -- a claim counts at most this much earlier than we first heard it
local AHEAD_SECONDS = 60 -- a claim this far past our clock is nonsense
local ANSWER_SECONDS = 5 -- a rival's later claim is answered at once, at most this often
local MAX_LEADERS = 40
local MAX_ZONE = 60

function Rally:OnEnable()
	for _, event in ipairs({ "PLAYER_DEAD", "ZONE_CHANGED_NEW_AREA", "PLAYER_LOGOUT" }) do
		private.frame:RegisterEvent(event)
	end
	private.frame:SetScript("OnEvent", function(_, event)
		if not private.mine then
			return
		end
		if event == "PLAYER_DEAD" then
			Rally:End("You died: your rally has ended.")
		elseif event == "PLAYER_LOGOUT" then
			Rally:End()
		elseif Wanted:InInstance() or private.Left(GetZoneText()) then
			Rally:End(format("You left %s: your rally has ended.", private.mine.zone))
		end
	end)
	C_Timer.NewTicker(SEND_SECONDS, function() Rally:Tick() end)
end

-- ============================================================================
-- Leading a rally
-- ============================================================================

---Why we can't lead the rally where we are, or nil.
---@return string?
function Rally:WhyNot()
	if private.mine then
		return format("You already lead the rally in %s.", private.mine.zone)
	end
	if Wanted:InInstance() then
		return "Rallies are for the open world, not instances."
	end
	if Wanted:InCombat() or InCombatLockdown() then
		return "You can't start a rally in a fight."
	end
	if UnitIsDeadOrGhost("player") then
		return "You can't lead a rally while dead."
	end
	if not private.IsGroupLeader() then
		return "Only a group's leader can lead a rally: form a posse or a group first."
	end
	local zone, x, y, mapId = Wanted.Recorder:GetPosition()
	if not x or not mapId or not zone or zone == "" or zone == "?" then
		return "Your position isn't known here."
	end
	local holder = Rally:Holder(zone)
	if holder then
		return format("%s already leads the rally in %s.", holder.name, zone)
	end
end

---Marks us the rally leader for our zone. Returns why not, or nil.
---@return string?
function Rally:Claim()
	local why = Rally:WhyNot()
	if why then
		return why
	end
	local zone, x, y, mapId = Wanted.Recorder:GetPosition()
	private.mine = { claimed = GetServerTime(), zone = zone, mapId = mapId, x = x, y = y, moved = GetTime(), sends = 0 }
	private.Send()
	Wanted:Print("You lead the rally in %s. Wanted players of your faction there see you on their map and in Nearby until you die, leave the zone or end it (/wanted rally end).", zone)
	private.Changed()
	return nil
end

---Ends the rally we lead, telling the others; why is said in chat (nil says nothing).
---@param why string?
function Rally:End(why)
	if not private.mine then
		return
	end
	private.Send(true)
	private.mine = nil
	if why then
		Wanted:Print("%s", why)
	end
	private.Changed()
end

---The rally we lead: { claimed, zone, mapId, x, y }, or nil.
---@return table?
function Rally:Mine()
	return private.mine
end

---Every half minute: our position (and the end of a rally whose leader stood still too long), and others' rallies
---gone quiet dropped.
function Rally:Tick()
	local mine = private.mine
	if mine then
		local zone, x, y, mapId = Wanted.Recorder:GetPosition()
		if private.Left(zone) then
			Rally:End(format("You left %s: your rally has ended.", mine.zone))
		else
			if x and (x ~= mine.x or y ~= mine.y or mapId ~= mine.mapId) then
				mine.x, mine.y, mine.mapId, mine.moved = x, y, mapId, GetTime()
			end
			if GetTime() - mine.moved >= IDLE_SECONDS then
				Rally:End(format("You haven't moved for %d minutes: your rally has ended.", IDLE_SECONDS / 60))
			else
				private.Send()
			end
		end
	end
	local now, changed = GetServerTime(), false
	for sender, entry in pairs(private.leaders) do
		if now - entry.heard > GONE_SECONDS then
			private.leaders[sender] = nil
			changed = true
		end
	end
	if changed then
		private.Changed()
	end
end

---Our rally's position on the channel (and, every few times or at its end, to the realm links).
function private.Send(ended)
	local mine = private.mine
	mine.sends = mine.sends + 1
	mine.sentAt = GetTime()
	local _, class = UnitClass("player")
	Sync:SendRally({ c = mine.claimed, z = mine.zone, m = mine.mapId, x = mine.x, y = mine.y, k = class, f = UnitFactionGroup("player"),
		e = ended and 1 or nil }, ended or mine.sends % LINK_EVERY == 1)
end

---Whether a zone name says we've left our rally's zone. None (a loading screen) says nothing.
function private.Left(zone)
	return type(zone) == "string" and zone ~= "" and zone ~= "?" and zone ~= private.mine.zone
end

---Whether we lead our group. The game keeps it secret in instances, where rallies aren't allowed anyway.
function private.IsGroupLeader()
	if not IsInGroup() or not UnitIsGroupLeader then
		return false
	end
	local ok, leader = pcall(UnitIsGroupLeader, "player")
	return ok and not (issecretvalue and issecretvalue(leader)) and leader == true
end

-- ============================================================================
-- Others' rallies
-- ============================================================================

---A rally message, from the leader's own client (sender is who the game says sent it). Anything that doesn't make
---sense, or from the other faction, is dropped. A claim earlier than ours in our zone ends ours; a later one is
---answered at once, so its leader hears ours and stands down.
---@param tbl table { c = claimed, z = zone, m = map id, x, y, k = class, f = faction, e = 1 when it ended }
---@param sender string
function Rally:OnMessage(tbl, sender)
	if type(tbl) ~= "table" or type(sender) ~= "string" or sender == Store:GetOrigin() or tbl.f ~= UnitFactionGroup("player") then
		return
	end
	if tbl.e then
		if private.leaders[sender] then
			private.leaders[sender] = nil
			private.Changed()
		end
		return
	end
	local now = GetServerTime()
	local claimed, x, y, mapId = tonumber(tbl.c), tonumber(tbl.x), tonumber(tbl.y), tonumber(tbl.m)
	local zone = type(tbl.z) == "string" and strsub((gsub(tbl.z, "[%c|]", "")), 1, MAX_ZONE) or ""
	-- (n ~= n is a NaN, which no comparison catches)
	if not claimed or claimed ~= claimed or claimed > now + AHEAD_SECONDS or claimed < 0 or zone == ""
		or not x or not y or x ~= x or y ~= y or x < 0 or x > 100 or y < 0 or y > 100 or not mapId or mapId ~= floor(mapId) then
		return
	end
	local entry = private.leaders[sender]
	if not entry then
		if private.Count() >= MAX_LEADERS then
			return
		end
		entry = {}
		private.leaders[sender] = entry
	end
	-- A new claim, or the same leader somewhere else, is heard afresh
	if entry.claimed ~= claimed or entry.zone ~= zone then
		entry.firstHeard = now
	end
	entry.name, entry.claimed, entry.heard, entry.zone, entry.mapId, entry.x, entry.y = sender, claimed, now, zone, mapId, x, y
	entry.class = type(tbl.k) == "string" and strmatch(tbl.k, "^%u+$") and #tbl.k <= 12 and tbl.k or nil
	local mine = private.mine
	if mine and mine.zone == zone then
		if Rally:Holder(zone) == entry then
			Rally:End(format("%s claimed the rally in %s before you: yours has ended.", sender, zone))
		elseif GetTime() - (mine.sentAt or 0) >= ANSWER_SECONDS then
			private.Send()
		end
	end
	private.Tell(entry)
	private.Changed()
end

---When a claim counts from: the leader's own word, but never more than EARLY_SECONDS before we first heard it, so a
---made-up early claim can't take over a rally that's been going for a while.
function private.Since(entry)
	return max(entry.claimed, entry.firstHeard - EARLY_SECONDS)
end

---Whether rally a holds over rally b: the earlier claim, and in the same second the name that sorts first.
function private.Before(a, b)
	if a.since ~= b.since then
		return a.since < b.since
	end
	return a.name < b.name
end

---Who leads the rally in a zone: { name, zone, mapId, x, y, class, heard, mine = true when it's us }, or nil.
---@param zone string
---@return table?
function Rally:Holder(zone)
	local best
	local mine = private.mine
	if mine and mine.zone == zone then
		best = { name = Store:GetOrigin(), since = mine.claimed, mine = true, zone = zone, mapId = mine.mapId, x = mine.x, y = mine.y, heard = GetServerTime() }
	end
	local now = GetServerTime()
	for _, entry in pairs(private.leaders) do
		if entry.zone == zone and now - entry.heard <= GONE_SECONDS then
			entry.since = private.Since(entry)
			if not best or private.Before(entry, best) then
				best = entry
			end
		end
	end
	return best
end

---The rally leaders others have, one per zone, that the world map shows on a map: { name, x, y, class, heard }.
---@param mapId number
---@return table[]
function Rally:OnMap(mapId)
	local out, zones = {}, {}
	for _, entry in pairs(private.leaders) do
		if entry.mapId == mapId and not zones[entry.zone] then
			zones[entry.zone] = true
			local holder = Rally:Holder(entry.zone)
			if holder and not holder.mine and holder.mapId == mapId then
				tinsert(out, holder)
			end
		end
	end
	return out
end

---The rally in our zone for the Nearby window: its leader (nil when there's none), and whether it's us.
---@return table?
function Rally:Here()
	return Rally:Holder(GetZoneText() or "")
end

---A rally leader new to us in our zone: said once in chat, as the Nearby window can be closed.
function private.Tell(entry)
	local key = entry.name..":"..entry.claimed
	if private.told[key] or entry.zone ~= GetZoneText() or Rally:Holder(entry.zone) ~= entry then
		return
	end
	private.told[key] = true
	Wanted:Print("%s leads the rally in %s (%.0f, %.0f): they're marked on your map.", entry.name, entry.zone, entry.x, entry.y)
end

function private.Count()
	local n = 0
	for _ in pairs(private.leaders) do
		n = n + 1
	end
	return n
end

---Redraws the map's markers and the Nearby window.
function private.Changed()
	if Wanted.MapPins then
		Wanted.MapPins:Refresh()
	end
	if Wanted.NearbyWindow and Wanted.NearbyWindow:IsShown() then
		Wanted.NearbyWindow:Refresh()
	end
end

Wanted:RegisterCommand("rally", "Leads the rally in your zone, as your group's leader (your faction sees you on the map): /wanted rally, or /wanted rally end.", function(args)
	if strlower(strtrim(args or "")) == "end" then
		if not private.mine then
			Wanted:Print("You're not leading a rally.")
			return
		end
		Rally:End("Your rally has ended.")
		return
	end
	local why = Rally:Claim()
	if why then
		Wanted:Print("%s", why)
	end
end)
