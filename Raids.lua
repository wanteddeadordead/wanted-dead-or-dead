-- Wanted: world PvP raids. A leader forms one, now or for later; its ad goes to every Wanted player of their faction
-- (the sync channel, and realm links, which share it on theirs), who see it on the Raids page and in a toast. Join
-- whispers the leader's client, which invites them (turning the group into a raid before the sixth); for a raid that
-- hasn't started, Join signs them up, and their client asks again when it starts. Announce puts a line in a public
-- chat channel for players without Wanted, and the leader's client invites anyone who whispers "inv". Ads are passing
-- news, never stored: a raid whose ad stops coming has gone.

local _, Wanted = ...
local Raids = Wanted:NewModule("Raids")
local Sync = Wanted.Sync
local Store = Wanted.Store
local private = {
	mine = nil, -- the raid we lead: { id, title, guild?, where, startAt, size, minLevel, created, signups = { name = true } }
	seen = {}, -- id -> { ad, sender, heard } other players' raids
	toasted = {}, -- id -> true once its toast has shown
	joined = {}, -- id -> { leader, startAt, asked } raids we joined or signed up for
	reminded = {}, -- id..":"..kind -> true
	pending = {}, -- names waiting for an invite until combat ends
	counter = 0,
	lastAnnounce = -math.huge,
}

local SIZES = { [10] = true, [20] = true, [40] = true }
local MAX_TEXT = 40
local AD_SECONDS = 60 -- an open raid's ad goes out this often
local GONE_SECONDS = 3 * 60 -- a raid whose ad hasn't come for this long has gone
local OPEN_HOURS = 2 -- a raid closes itself this long after it starts
local SOON_SECONDS = 15 * 60 -- the reminder before a planned raid
local ASK_MINUTES = 10 -- a planned raid's members ask for their invite for this long after it starts
local ANNOUNCE_SECONDS = 60
local MAX_SEEN = 30
local PARTY_SIZE = 5
local MAP_WORLD = Enum.UIMapType and Enum.UIMapType.World or 1
local MAP_ZONE = Enum.UIMapType and Enum.UIMapType.Zone or 3

-- ============================================================================
-- Forming and leading a raid
-- ============================================================================

function Raids:OnEnable()
	private.frame = private.frame or CreateFrame("Frame")
	private.frame:RegisterEvent("CHAT_MSG_WHISPER")
	private.frame:SetScript("OnEvent", function(_, _, text, sender)
		Raids:OnWhisper(text, sender)
	end)
	Wanted:OnCombatEnd(private.InvitePending)
	private.ticker = private.ticker or C_Timer.NewTicker(AD_SECONDS, function() Raids:Tick() end)
end

---Forms a raid: { title, where, startAt (server seconds; nil or past for now), size (10, 20 or 40), minLevel, guild
---(true: under our own guild's name) }.
---Returns the raid, or nil and why not.
---@param o table
---@return table? raid
---@return string? why
function Raids:Create(o)
	if private.mine then
		return nil, "You're already leading a raid. Close it first."
	end
	local title = private.Clean(o.title)
	if title == "" then
		return nil, "Give the raid a name."
	end
	local size = tonumber(o.size)
	if not SIZES[size] then
		return nil, "Pick a size: 10, 20 or 40."
	end
	local guild = o.guild and GetGuildInfo("player") or nil
	if o.guild and not guild then
		return nil, "You're not in a guild."
	end
	local now = GetServerTime()
	local startAt = tonumber(o.startAt)
	if not startAt or startAt < now then
		startAt = now
	end
	if startAt > now + 7 * 24 * 3600 then
		return nil, "A raid can be planned up to a week ahead."
	end
	private.counter = private.counter + 1
	private.mine = {
		id = Store:GetOrigin()..":"..now..":"..private.counter,
		title = title,
		guild = guild,
		where = private.Clean(o.where) ~= "" and private.Clean(o.where) or (GetZoneText() or ""),
		startAt = startAt,
		size = size,
		minLevel = max(1, min(60, floor(tonumber(o.minLevel) or 1))),
		created = now,
		signups = {},
	}
	private.SendAd()
	private.Changed()
	return private.mine
end

---A raid's name as shown: with its guild, if it's a guild raid.
---@param raid table
---@return string
function Raids:Title(raid)
	return raid.guild and format("%s with <%s>", raid.title, raid.guild) or raid.title
end

---The game's outdoor zone names, in this client's language, sorted, for the Where box: every zone under the world
---map we're on. Empty while the map isn't known yet (asked again next time).
---@return string[]
function Raids:Zones()
	if private.zones then
		return private.zones
	end
	local mapId = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	local info = mapId and C_Map.GetMapInfo(mapId)
	-- Up to the world map (Azeroth), whose zones are every continent's
	while info and info.mapType > MAP_WORLD and info.parentMapID and info.parentMapID > 0 do
		mapId, info = info.parentMapID, C_Map.GetMapInfo(info.parentMapID)
	end
	local names, seen = {}, {}
	for _, zone in ipairs(info and C_Map.GetMapChildrenInfo and C_Map.GetMapChildrenInfo(mapId, MAP_ZONE, true) or {}) do
		if zone.name and zone.name ~= "" and not seen[zone.name] then
			seen[zone.name] = true
			tinsert(names, zone.name)
		end
	end
	sort(names)
	if #names > 0 then
		private.zones = names
	end
	return names
end

---The raid we lead, or nil.
---@return table?
function Raids:Mine()
	return private.mine
end

---Closes the raid we lead: its ad goes out once more, marked closed.
function Raids:Close()
	if not private.mine then
		return
	end
	private.SendAd(true)
	private.mine = nil
	wipe(private.pending)
	private.Changed()
end

---The line Announce puts in a public chat channel, for players without Wanted.
---@return string?
function Raids:AnnounceText()
	local raid = private.mine
	if not raid then
		return nil
	end
	local when = private.Started(raid) and "now" or ("at "..date("%H:%M", raid.startAt))
	return format("Forming a world PvP raid: %s in %s %s (%d/%d). Whisper me \"inv\" to join.", Raids:Title(raid), raid.where, when,
		private.GroupSize(), raid.size)
end

---The public chat channel Announce posts in: Looking for Group when we're in it, else the zone's General. Its number
---and name, or nil when we're in neither.
---@return number? index
---@return string? name
function Raids:AnnounceChannel()
	for _, name in ipairs({ "LookingForGroup", "General - "..(GetZoneText() or ""), "General" }) do
		local index = GetChannelName(name)
		if index and index > 0 then
			return index, name
		end
	end
end

---Puts a line in the Announce channel (the raid's own line when text is nil). Needs a click: the game only lets a key
---press or click post in public channels, so it's called from the confirm dialog's button. Returns why not, or nil.
---@param text string?
---@return string?
function Raids:Announce(text)
	if not private.mine then
		return "You're not leading a raid."
	end
	text = text and strtrim((gsub(gsub(text, "|", ""), "[\r\n]+", " "))) or Raids:AnnounceText()
	if text == "" then
		return "There's nothing to post."
	end
	if GetTime() - private.lastAnnounce < ANNOUNCE_SECONDS then
		return "You announced it less than a minute ago."
	end
	local index = Raids:AnnounceChannel()
	if not index then
		return "You're not in a Looking for Group or General channel."
	end
	private.lastAnnounce = GetTime()
	C_ChatInfo.SendChatMessage(strsub(text, 1, 255), "CHANNEL", nil, index)
	return nil
end

---Someone asks to join (or sign up for) the raid we lead.
---@param sender string
---@param tbl table { r = raid id }
function Raids:OnJoin(sender, tbl)
	local raid = private.mine
	if not raid or type(tbl) ~= "table" or tbl.r ~= raid.id or type(sender) ~= "string" then
		return
	end
	if not private.Started(raid) then
		if not raid.signups[sender] then
			raid.signups[sender] = true
			Wanted:Print("%s signed up for %s.", sender, raid.title)
			private.Changed()
		end
		return
	end
	private.Invite(sender)
end

---A whisper: "inv" to the leader of an open raid that has started is a join.
---@param text string
---@param sender string
function Raids:OnWhisper(text, sender)
	local raid = private.mine
	if raid and private.Started(raid) and type(text) == "string" and strmatch(strlower(text), "^%s*inv[ite]*%s*$") then
		private.Invite(sender)
	end
end

---Invites a player to the raid we lead: never past its size, never in combat (they wait for it to end), turning the
---group into a raid before it would pass a party.
function private.Invite(name)
	local raid = private.mine
	if not raid or type(name) ~= "string" or name == Store:GetOrigin() then
		return
	end
	if private.GroupSize() >= raid.size then
		Wanted:Print("%s wants to join %s, but it's full (%d).", name, raid.title, raid.size)
		return
	end
	if InCombatLockdown() then
		private.pending[name] = true
		return
	end
	if IsInGroup() and not IsInRaid() and GetNumGroupMembers() >= PARTY_SIZE and C_PartyInfo and C_PartyInfo.ConvertToRaid then
		C_PartyInfo.ConvertToRaid()
	end
	local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
	if invite then
		invite(name)
		Wanted:Print("%s joins %s: invited.", name, raid.title)
	end
end

---After a fight: the invites that waited for it.
function private.InvitePending()
	for name in pairs(private.pending) do
		private.pending[name] = nil
		private.Invite(name)
	end
end

---The raid's ad, shared with every Wanted player of our faction.
function private.SendAd(closed)
	local raid = private.mine
	if not raid then
		return
	end
	Sync:SendRaidAd({ id = raid.id, l = Store:GetOrigin(), t = raid.title, g = raid.guild, z = raid.where, s = raid.startAt, m = raid.size,
		ml = raid.minLevel, n = private.GroupSize(), u = private.Count(raid.signups), f = UnitFactionGroup("player"), c = closed and 1 or nil })
end

---Every minute: the ad again, a raid past its time closed, others' raids gone quiet dropped, reminders and asks for
---the raids we joined.
function Raids:Tick()
	local now = GetServerTime()
	local raid = private.mine
	if raid then
		if now > raid.startAt + OPEN_HOURS * 3600 then
			Wanted:Print("%s has been open %d hours: closed.", raid.title, OPEN_HOURS)
			Raids:Close()
		else
			-- Members who signed up are invited when it starts
			if private.Started(raid) and next(raid.signups) then
				for name in pairs(raid.signups) do
					raid.signups[name] = nil
					private.Invite(name)
				end
			end
			private.SendAd()
		end
	end
	local changed = false
	for id, entry in pairs(private.seen) do
		if GetTime() - entry.heard > GONE_SECONDS then
			private.seen[id] = nil
			changed = true
		end
	end
	private.Remind(now)
	if changed then
		private.Changed()
	end
end

-- ============================================================================
-- Other players' raids
-- ============================================================================

---Another player's raid ad (from the channel or a realm link): kept while it keeps coming, shown on the Raids page,
---and a toast the first time. Ads that don't make sense, from the other faction or already closed are dropped.
---@param ad table
---@param sender string
function Raids:OnAd(ad, sender)
	if type(ad) ~= "table" or type(ad.id) ~= "string" or #ad.id > 80 or type(ad.l) ~= "string" or #ad.l > 60 then
		return
	end
	if ad.l == Store:GetOrigin() or strfind(ad.l, "|", 1, true) then
		return
	end
	if ad.c then
		if private.seen[ad.id] then
			private.seen[ad.id] = nil
			private.Changed()
		end
		return
	end
	local faction = UnitFactionGroup("player")
	local size, startAt = tonumber(ad.m), tonumber(ad.s)
	if ad.f ~= faction or not SIZES[size] or not startAt then
		return
	end
	local entry = private.seen[ad.id]
	if not entry then
		if private.Count(private.seen) >= MAX_SEEN then
			return
		end
		entry = {}
		private.seen[ad.id] = entry
	end
	entry.heard = GetTime()
	entry.raid = {
		id = ad.id, leader = ad.l, title = private.Clean(ad.t), guild = private.Clean(ad.g) ~= "" and private.Clean(ad.g) or nil, where = private.Clean(ad.z), startAt = startAt, size = size,
		minLevel = max(1, min(60, floor(tonumber(ad.ml) or 1))), members = max(0, min(size, floor(tonumber(ad.n) or 0))),
		signups = max(0, min(99, floor(tonumber(ad.u) or 0))),
	}
	private.Changed()
	if not private.toasted[ad.id] and Wanted.db.settings.raidToasts and Wanted.Toast then
		private.toasted[ad.id] = true
		local raid = entry.raid
		local started = raid.startAt <= GetServerTime()
		Wanted.Toast:Add({ kind = started and "RAID FORMING" or "RAID PLANNED", name = Raids:Title(raid),
			detail = format("%s, %s  %d/%d  led by %s", raid.where, started and "now" or date("%a %H:%M", raid.startAt), raid.members, raid.size, raid.leader),
			onClick = function() Wanted.UI:Show("raids") end })
	end
end

---Other players' raids we can see: started ones first, then by start time.
---@return table[]
function Raids:List()
	local out = {}
	for _, entry in pairs(private.seen) do
		tinsert(out, entry.raid)
	end
	local now = GetServerTime()
	sort(out, function(a, b)
		local aNow, bNow = a.startAt <= now, b.startAt <= now
		if aNow ~= bNow then
			return aNow
		end
		return a.startAt < b.startAt
	end)
	return out
end

---Joins a raid we can see (or signs up for it, before it starts). Returns why not, or nil.
---@param id string
---@return string?
function Raids:Join(id)
	local entry = private.seen[id]
	if not entry then
		return "That raid has gone."
	end
	local raid = entry.raid
	if (UnitLevel("player") or 0) < raid.minLevel then
		return format("That raid is for level %d and up.", raid.minLevel)
	end
	if raid.members >= raid.size then
		return "That raid is full."
	end
	private.joined[id] = { leader = raid.leader, startAt = raid.startAt, title = Raids:Title(raid) }
	Sync:SendRaidJoin(raid.leader, id)
	if raid.startAt <= GetServerTime() then
		Wanted:Print("Joining %s: %s will invite you.", raid.title, raid.leader)
	else
		Wanted:Print("Signed up for %s at %s. You'll be invited when it starts.", raid.title, date("%a %H:%M", raid.startAt))
	end
	private.Changed()
	return nil
end

---Whether we joined or signed up for a raid.
---@param id string
---@return boolean
function Raids:Joined(id)
	return private.joined[id] ~= nil
end

---For the raids we signed up for: a reminder before they start, then asking for the invite when they do (in case the
---leader's client missed the sign-up), every minute for a while.
function private.Remind(now)
	for id, j in pairs(private.joined) do
		if now > j.startAt + ASK_MINUTES * 60 then
			private.joined[id] = nil
		elseif now >= j.startAt then
			if not private.reminded[id..":start"] then
				private.reminded[id..":start"] = true
				Wanted.Toast:Add({ kind = "RAID STARTING", name = j.title, detail = j.leader.." is inviting", onClick = function() Wanted.UI:Show("raids") end })
			end
			Sync:SendRaidJoin(j.leader, id)
		elseif now >= j.startAt - SOON_SECONDS and not private.reminded[id..":soon"] then
			private.reminded[id..":soon"] = true
			Wanted.Toast:Add({ kind = "RAID SOON", name = j.title, detail = "Starts at "..date("%H:%M", j.startAt).." with "..j.leader,
				onClick = function() Wanted.UI:Show("raids") end })
		end
	end
end

-- ============================================================================
-- Helpers
-- ============================================================================

---Text from a form or another client: a string, no escape codes, at most MAX_TEXT letters.
function private.Clean(text)
	text = type(text) == "string" and gsub(text, "|", "") or ""
	text = strtrim and strtrim(text) or text
	return strsub(text, 1, MAX_TEXT)
end

function private.Started(raid)
	return raid.startAt <= GetServerTime()
end

---How many are in our group, ourselves included.
function private.GroupSize()
	return IsInGroup() and max(1, GetNumGroupMembers()) or 1
end

function private.Count(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

---Tells the Raids page to redraw.
function private.Changed()
	if Wanted.UI and Wanted.UI.Refresh then
		Wanted.UI:Refresh()
	end
end
