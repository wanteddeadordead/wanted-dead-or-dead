-- Wanted: posses. An outlaw or a bountied player nearby is worth more than one hunter: "Form a posse" sends
-- where they are to the faction's Wanted players as an urgent sighting with a call attached, everyone in the
-- same zone is asked to join, and whoever joins whispers the caller and is invited to their group. The call is
-- refreshed with the target's position every half minute while the caller can see them, for ten minutes.
-- Older clients see the call as a plain sighting of the enemy, which is the right thing for them to see.

local _, Wanted = ...
local Posse = Wanted:NewModule("Posse")
local Store = Wanted.Store
local Enemies = Wanted.Enemies
local Sync = Wanted.Sync
local W = Wanted.Widgets
local private = {
	active = {}, -- guid -> { name, since } posses this client called
	prompted = {}, -- guid -> when this client was last asked to join a posse against them
	promptedBy = {}, -- caller -> when this client was last asked to join one of their posses
	ticker = nil,
}
local POSSE_SECONDS = 10 * 60
local REFRESH_SECONDS = 30
local CALLER_SECONDS = 2 * 60 -- one ask per caller this often, whoever their posse is against
local MAX_WHY = 24

function Posse:OnEnable()
	Enemies:OnChange(function(event, entry)
		if event == "shared" and type(entry.posse) == "table" then
			private.OnCall(entry)
		end
	end)
end

---Whether a posse can be called against a player: an outlaw, or one with a price on their head.
---@param d table an Enemies:Describe result
---@return boolean
function Posse:CanCall(d)
	return d ~= nil and (d.outlaw ~= nil or (d.bounty or 0) > 0)
end

---Calls a posse against a player nearby. Returns whether the call went out.
---@param guid string
---@return boolean
function Posse:Call(guid)
	local d = Enemies:Describe(guid)
	if not Posse:CanCall(d) then
		Wanted:Print("A posse is for outlaws and players with a price on their head; %s is neither.", d.name or "that player")
		return false
	end
	local now = GetTime()
	local active = private.active[guid]
	if active and now - active.since < POSSE_SECONDS then
		Wanted:Print("A posse against %s is already out (%d minutes ago).", d.name, floor((now - active.since) / 60))
		return false
	end
	private.active[guid] = { name = d.name, since = now }
	private.Send(d)
	Wanted:Print("Posse called against %s. Wanted players in %s get the call; whoever joins is invited to your group.", d.name, d.zone or "the zone")
	if not private.ticker then
		private.ticker = C_Timer.NewTicker(REFRESH_SECONDS, private.Refresh)
	end
	return true
end

function private.Send(d)
	Sync:QueueSighting({
		g = d.guid, n = d.name, c = d.class, l = d.level, r = d.race, u = d.guild,
		z = d.zone, m = d.mapId, x = d.x, y = d.y, s = d.stealthed or nil,
		p = { c = Store:GetOrigin(), k = d.outlaw and d.outlaw.rank or "bounty" },
	}, true)
end

---Sends the target's latest position while the caller can see them; ends the posse after its time.
function private.Refresh()
	local now = GetTime()
	local any = false
	for guid, active in pairs(private.active) do
		if now - active.since >= POSSE_SECONDS then
			private.active[guid] = nil
		else
			any = true
			local d = Enemies:Describe(guid)
			if d.nearby and d.inSight then
				private.Send(d)
			end
		end
	end
	if not any and private.ticker then
		private.ticker:Cancel()
		private.ticker = nil
	end
end

---A posse call from another player: ask to join, in the caller's zone with a position, once per target and once per
---caller in a while.
function private.OnCall(entry)
	local caller = entry.by
	if type(caller) ~= "string" or caller == Store:GetOrigin() or type(entry.guid) ~= "string" then
		return
	end
	if type(entry.zone) ~= "string" or entry.zone ~= GetZoneText() or type(entry.x) ~= "number" or type(entry.y) ~= "number" then
		return
	end
	local now = GetTime()
	if (private.prompted[entry.guid] and now - private.prompted[entry.guid] < POSSE_SECONDS)
		or (private.promptedBy[caller] and now - private.promptedBy[caller] < CALLER_SECONDS) then
		return
	end
	for _, times in ipairs({ private.prompted, private.promptedBy }) do
		for key, t in pairs(times) do
			if now - t >= POSSE_SECONDS then
				times[key] = nil
			end
		end
	end
	private.prompted[entry.guid], private.promptedBy[caller] = now, now
	local where = format("%s (%.0f, %.0f)", entry.zone, entry.x, entry.y)
	local why = type(entry.posse.why) == "string" and strsub((gsub(entry.posse.why, "[%c|]", "")), 1, MAX_WHY) or "wanted"
	why = why == "bounty" and "a price on their head" or why
	Wanted:Log("Posse: %s calls one against %s in %s", caller, entry.name, where)
	if W:IsDialogShown() or Wanted:InCombat() or InCombatLockdown() then
		-- Never a dialog in a fight (or over another): a line in chat instead
		Wanted:Print("%s is calling a posse against %s (%s) in %s.", caller, entry.name, why, where)
		return
	end
	W:Dialog({
		title = "Posse: "..tostring(entry.name),
		text = format("%s is calling a posse against %s (%s) in %s.\n\nJoin, and you'll be invited to their group.", caller, entry.name, why, where),
		confirmLabel = "Join",
		cancelLabel = "Ignore",
		onConfirm = function()
			Posse:Join(caller, entry.guid, entry.name)
		end,
	})
end

---Joins a posse: a whisper the caller reads, and an addon whisper their client acts on.
---@param caller string
---@param guid string
---@param name string
function Posse:Join(caller, guid, name)
	C_ChatInfo.SendChatMessage(format("Wanted: joining your posse against %s.", tostring(name)), "WHISPER", nil, caller)
	Sync:SendPosseJoin(caller, guid)
	Wanted:Print("Joining %s's posse against %s: they'll invite you.", caller, tostring(name))
end

---Someone joins a posse this client called: invite them.
---@param sender string
---@param guid any
function Posse:OnJoin(sender, guid)
	local active = type(guid) == "string" and private.active[guid]
	if not active or GetTime() - active.since >= POSSE_SECONDS then
		Wanted:Log("Posse: %s wants to join a posse we don't have out", tostring(sender))
		return
	end
	local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
	if invite then
		invite(sender)
	end
	Wanted:Print("%s joins the posse against %s: invited.", sender, active.name)
end
