-- Wanted: rally leaders. A group's leader can mark themselves the rally leader for their zone: their client shares
-- where they stand on the sync channel every half minute, and Wanted players of their faction in that zone see them
-- on the world map and at the top of the Nearby window. One per faction per zone (the zone's map, so every language
-- agrees): the earlier claim holds, and in the same second the name that sorts first. A rally ends when its leader
-- dies, leaves the zone, ends it, or stands still for half an hour; others drop one they haven't heard from for five
-- minutes (logged off, or out of reach). A rally is only ever taken as its sender's own: the game names who sent each
-- message, and nobody passes one on. Nothing is saved: a /reload ends the rally, and the others drop it as they stop
-- hearing it.
--
-- The rally leader's line in Nearby has two buttons: Skull puts the skull on your target when it's a bounty or Kill on
-- Sight enemy, and Flare starts placing a world marker. The game lets only a click do either, so they're secure
-- buttons the game runs itself (no addon code in between), set up out of combat: in a fight they stay as they were
-- when it began. Both are for a group's leader or assistants, and have names for a macro: /click WantedRallySkullButton
-- or /click WantedRallyFlareButton.

local _, Wanted = ...
local Rally = Wanted:NewModule("Rally")
local Store = Wanted.Store
local Sync = Wanted.Sync
local W = Wanted.Widgets
local private = {
	mine = nil, -- the rally we lead: { claimed (server time), zone, mapId, x, y, moved (GetTime), sends }
	leaders = {}, -- sender -> { name, claimed, firstHeard, heard (server time), zone, mapId, x, y, class } others' rallies
	told = {}, -- sender..":"..claimed -> true once we've said they lead the rally in our zone
	answered = {}, -- sender..":"..claimed -> true once we've answered that later claim with ours
	answers = {}, -- sender -> how many of their claims we've answered while leading this rally
	changePending = false,
	frame = CreateFrame("Frame"),
	markFrame = CreateFrame("Frame"),
	skull = nil, -- the Skull and Flare buttons, once the Nearby window has made them
	flare = nil,
}
local SEND_SECONDS = 30 -- the leader's position goes out this often
local LINK_EVERY = 4 -- and every fourth time (two minutes) to the realm links too, whose budget is smaller
local GONE_SECONDS = 5 * 60 -- a rally not heard for this long has gone
local IDLE_SECONDS = 30 * 60 -- a leader who hasn't moved for this long ends their rally
local EARLY_SECONDS = GONE_SECONDS -- a claim counts at most this much earlier than we first heard it
local AHEAD_SECONDS = 60 -- a claim this far past our clock is nonsense
local MAX_ANSWERS = 3 -- a rival who keeps claiming after this many answers is left to hear our regular sends
local MAX_LEADERS = 40
local MAX_ZONE = 60
local MAX_MAP_ID = 2 ^ 31
local CHANGE_SECONDS = 0.5 -- redraws for rally news are put together this long
local MAP_ZONE = Enum.UIMapType and Enum.UIMapType.Zone or 3
local SKULL = 8 -- the skull raid target icon
local FLARE_MARKER = 1 -- the world marker Flare places

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
		elseif Wanted:InInstance() or private.Left(private.ZoneMap()) then
			Rally:End(format("You left %s: your rally has ended.", private.mine.zone))
		end
	end)
	C_Timer.NewTicker(SEND_SECONDS, function() Rally:Tick() end)
	for _, event in ipairs({ "PLAYER_TARGET_CHANGED", "GROUP_ROSTER_UPDATE", "PARTY_LEADER_CHANGED", "PLAYER_REGEN_ENABLED" }) do
		private.markFrame:RegisterEvent(event)
	end
	private.markFrame:SetScript("OnEvent", function() private.Arm() end)
end

-- ============================================================================
-- Where we are
-- ============================================================================

---The zone map we're on (a cave's or a town's map counts as its zone's), or nil where no zone map reaches: underground
---the game puts us on the continent's map, and that says nothing about which zone we're in.
---@return number?
function private.ZoneMap()
	local mapId = C_Map.GetBestMapForUnit("player")
	local info = mapId and C_Map.GetMapInfo(mapId)
	while info and info.mapType and info.mapType > MAP_ZONE and info.parentMapID and info.parentMapID > 0 do
		mapId, info = info.parentMapID, C_Map.GetMapInfo(info.parentMapID)
	end
	return info and info.mapType == MAP_ZONE and mapId or nil
end

---Where we are on a zone's map, in map percent to a tenth, or nil when the game doesn't say.
function private.Position(mapId)
	local pos = C_Map.GetPlayerMapPosition(mapId, "player")
	if not pos or not pos.x or not pos.y then
		return nil
	end
	return floor(pos.x * 1000 + 0.5) / 10, floor(pos.y * 1000 + 0.5) / 10
end

---Whether a zone map says we've left our rally's zone. None (underground, a loading screen) says nothing.
function private.Left(mapId)
	return mapId ~= nil and mapId ~= private.mine.mapId
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
	if Wanted:GetRequiredUpdate() then
		return format("Update Wanted to %s first: nothing is shared until you do.", Wanted:GetRequiredUpdate())
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
	local mapId = private.ZoneMap()
	if not mapId or not private.Position(mapId) then
		return "Your position isn't known here."
	end
	local holder = Rally:Holder(mapId)
	if holder then
		return format("%s already leads the rally in %s.", holder.name, holder.zone)
	end
end

---Marks us the rally leader for our zone. Returns why not, or nil.
---@return string?
function Rally:Claim()
	local why = Rally:WhyNot()
	if why then
		return why
	end
	local mapId = private.ZoneMap()
	local x, y = private.Position(mapId)
	local info = C_Map.GetMapInfo(mapId)
	local zone = info and info.name or GetZoneText() or "?"
	private.mine = { claimed = GetServerTime(), zone = zone, mapId = mapId, x = x, y = y, moved = GetTime(), sends = 0 }
	wipe(private.answered)
	wipe(private.answers)
	private.Arm()
	if private.Send() then
		Wanted:Print("You lead the rally in %s. Wanted players of your faction there see you on their map and in Nearby until you die, leave the zone or end it (/wanted rally end).", zone)
	else
		Wanted:Print("You lead the rally in %s, but it couldn't be shared yet (not in the sync channel): it goes out with the next update, every half minute.", zone)
	end
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
	private.Arm()
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
		local mapId = private.ZoneMap()
		if private.Left(mapId) then
			Rally:End(format("You left %s: your rally has ended.", mine.zone))
		else
			-- Off the zone's map (underground) the last place on it stands
			local x, y
			if mapId then
				x, y = private.Position(mapId)
			end
			if x and (x ~= mine.x or y ~= mine.y) then
				mine.x, mine.y, mine.moved = x, y, GetTime()
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

---Our rally's position on the channel (and, every few times or at its end, to the realm links). Returns whether it
---went out on the channel.
---@return boolean
function private.Send(ended)
	local mine = private.mine
	mine.sends = mine.sends + 1
	local _, class = UnitClass("player")
	return Sync:SendRally({ c = mine.claimed, z = mine.zone, m = mine.mapId, x = mine.x, y = mine.y, k = class, f = UnitFactionGroup("player"),
		e = ended and 1 or nil }, ended or mine.sends % LINK_EVERY == 1) and true or false
end

---Whether we lead our group (with assistant, or are one of its assistants). The game keeps both secret in
---instances, where rallies aren't allowed anyway.
function private.IsGroupLeader(assistant)
	if not IsInGroup() then
		return false
	end
	for _, check in ipairs({ UnitIsGroupLeader or false, assistant and UnitIsGroupAssistant or false }) do
		if check then
			local ok, yes = pcall(check, "player")
			if ok and not (issecretvalue and issecretvalue(yes)) and yes == true then
				return true
			end
		end
	end
	return false
end

-- ============================================================================
-- Skull and Flare
-- ============================================================================

---A value the game may keep secret, or nil when it does.
local function Readable(value)
	if issecretvalue and issecretvalue(value) then
		return nil
	end
	return value
end

---Why Skull can't mark our target now, or nil.
---@return string?
function Rally:SkullWhyNot()
	if not private.IsGroupLeader(true) then
		return "Only a group's leader or assistants can mark targets."
	end
	if not Readable(UnitExists("target")) then
		return "Target a bounty or Kill on Sight enemy first."
	end
	local guid = Readable(UnitGUID("target"))
	if not guid or not Readable(UnitIsPlayer("target")) or not Readable(UnitIsEnemy("player", "target")) then
		return "Skull is for enemy players with a bounty or on Kill on Sight."
	end
	local d = Wanted.Enemies:Describe(guid)
	if not d.kos and d.bounty <= 0 then
		return format("%s has no bounty and isn't on Kill on Sight.", d.name ~= "?" and d.name or "Your target")
	end
end

---Why Flare can't place a world marker now, or nil.
---@return string?
function Rally:FlareWhyNot()
	if not private.mine then
		return "Flare is for the rally leader: lead the rally here first."
	end
	if not private.IsGroupLeader(true) then
		return "Only a group's leader or assistants can place world markers."
	end
end

---Makes the Skull and Flare buttons, for the Nearby window's rally line (out of combat, once).
---@param parent table
---@return table skull
---@return table flare
function Rally:CreateMarkButtons(parent)
	if not private.skull then
		private.skull = private.MarkButton(parent, "Skull", "WantedRallySkullButton", "Skull your target",
			"Puts the skull on your target when it's an enemy with a bounty or on Kill on Sight. For a group's leader or assistants. Bind it with a macro: /click WantedRallySkullButton")
		private.skull:SetAttribute("unit", "target")
		private.skull:SetAttribute("marker", SKULL)
		private.skull:SetAttribute("action", "set")
		private.flare = private.MarkButton(parent, "Flare", "WantedRallyFlareButton", "Flare",
			"Click, then click the ground: a world marker there for your group to rally on. For the rally leader. Bind it with a macro: /click WantedRallyFlareButton")
		private.flare:SetAttribute("marker", FLARE_MARKER)
		private.flare:SetAttribute("action", "set")
		private.Arm()
	end
	return private.skull, private.flare
end

function private.MarkButton(parent, text, name, title, tip)
	local button = W:Button(parent, text, "chip", 44, 16, nil, "SecureActionButtonTemplate", name)
	button.label:SetFontObject(Wanted.Theme.Fonts.small)
	-- Act on release whatever "cast on key down" says, as the Nearby rows do
	button:RegisterForClicks("AnyUp")
	button:SetAttribute("useOnKeyDown", false)
	W:AttachTooltip(button, title, tip)
	-- Not set up to act (why was said when it was set): say why rather than nothing happening
	button:HookScript("PostClick", function(self)
		if not self:GetAttribute("type") and self.why then
			Wanted:Print("%s", self.why)
		end
	end)
	return button
end

---Sets Skull and Flare up for what they may do now: the game's action, or none and why not. Out of combat only (the
---game forbids it in a fight); a change then waits for the fight to end.
function private.Arm()
	if not private.skull or InCombatLockdown() then
		return
	end
	for button, why in pairs({ [private.skull] = Rally:SkullWhyNot() or false, [private.flare] = Rally:FlareWhyNot() or false }) do
		button.why = why or nil
		button:SetAttribute("type", not why and (button == private.skull and "raidtarget" or "worldmarker") or nil)
	end
end

-- ============================================================================
-- Others' rallies
-- ============================================================================

---A rally message, as the sender's own rally (sender is who the game says sent it). Anything that doesn't make
---sense, or from the other faction, is dropped. A claim earlier than ours in our zone ends ours; each later one is
---answered once, so its leader hears ours and stands down (a few times per player at most: past that they hear our
---regular sends like everyone else).
---@param tbl table { c = claimed, z = zone, m = map id, x, y, k = class, f = faction, e = 1 when it ended }
---@param sender string
function Rally:OnMessage(tbl, sender)
	if type(tbl) ~= "table" or type(sender) ~= "string" or sender == Store:GetOrigin() or tbl.f ~= UnitFactionGroup("player") then
		return
	end
	local now = GetServerTime()
	local claimed = tonumber(tbl.c)
	if tbl.e then
		-- An end late in the queue says nothing about a newer claim of theirs
		local entry = private.leaders[sender]
		if entry and claimed and claimed >= entry.claimed then
			private.leaders[sender] = nil
			private.Changed()
		end
		return
	end
	local x, y, mapId = tonumber(tbl.x), tonumber(tbl.y), tonumber(tbl.m)
	local zone = type(tbl.z) == "string" and strsub((gsub(tbl.z, "[%c|]", "")), 1, MAX_ZONE) or ""
	-- (n ~= n is a NaN, which no comparison catches)
	if not claimed or claimed ~= claimed or claimed > now + AHEAD_SECONDS or claimed < 0 or zone == ""
		or not x or not y or x ~= x or y ~= y or x < 0 or x > 100 or y < 0 or y > 100
		or not mapId or mapId <= 0 or mapId >= MAX_MAP_ID or mapId ~= floor(mapId) then
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
	if entry.claimed ~= claimed or entry.mapId ~= mapId then
		entry.firstHeard = now
	end
	entry.name, entry.claimed, entry.heard, entry.zone, entry.mapId, entry.x, entry.y = sender, claimed, now, zone, mapId, x, y
	entry.class = type(tbl.k) == "string" and strmatch(tbl.k, "^%u+$") and #tbl.k <= 12 and tbl.k or nil
	local mine = private.mine
	if mine and mine.mapId == mapId then
		local key = sender..":"..claimed
		if Rally:Holder(mapId) == entry then
			Rally:End(format("%s claimed the rally in %s before you: yours has ended.", sender, mine.zone))
		elseif not private.answered[key] and (private.answers[sender] or 0) < MAX_ANSWERS then
			private.answered[key] = true
			private.answers[sender] = (private.answers[sender] or 0) + 1
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

---Who leads the rally in a zone (by its map): { name, zone, mapId, x, y, class, heard, mine = true when it's us }, or
---nil.
---@param mapId number?
---@return table?
function Rally:Holder(mapId)
	if not mapId then
		return nil
	end
	local best
	local now = GetServerTime()
	local mine = private.mine
	if mine and mine.mapId == mapId then
		best = { name = Store:GetOrigin(), since = mine.claimed, mine = true, zone = mine.zone, mapId = mapId, x = mine.x, y = mine.y, heard = now }
	end
	for _, entry in pairs(private.leaders) do
		if entry.mapId == mapId and now - entry.heard <= GONE_SECONDS then
			entry.since = private.Since(entry)
			if not best or private.Before(entry, best) then
				best = entry
			end
		end
	end
	return best
end

---The rally leader others have on a map, for the world map: a list of none or one { name, zone, x, y, class, heard }.
---@param mapId number
---@return table[]
function Rally:OnMap(mapId)
	local holder = Rally:Holder(mapId)
	return holder and not holder.mine and { holder } or {}
end

---The rally in our zone for the Nearby window: its leader (nil when there's none), and whether it's us.
---@return table?
function Rally:Here()
	return Rally:Holder(private.ZoneMap() or (private.mine and private.mine.mapId))
end

---A rally leader new to us in our zone: said once in chat, as the Nearby window can be closed.
function private.Tell(entry)
	local key = entry.name..":"..entry.claimed
	if private.told[key] or entry.mapId ~= private.ZoneMap() or Rally:Holder(entry.mapId) ~= entry then
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

---Redraws the map's markers and the Nearby window, once for all the rally news of the next moment.
function private.Changed()
	if private.changePending then
		return
	end
	private.changePending = true
	C_Timer.After(CHANGE_SECONDS, function()
		private.changePending = false
		if Wanted.MapPins then
			Wanted.MapPins:Refresh()
		end
		if Wanted.NearbyWindow and Wanted.NearbyWindow:IsShown() then
			Wanted.NearbyWindow:Refresh()
		end
	end)
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
