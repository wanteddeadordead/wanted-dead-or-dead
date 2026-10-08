-- Wanted: world PvP raids. A leader forms one, now or for later; its ad goes to every Wanted player of their faction
-- (the sync channel, and realm links, which share it on theirs), who see it on the Raids page and in a toast. Join
-- whispers the leader's client, which invites them (turning the group into a raid before the sixth); a raid that
-- hasn't started they mark Interested or Going (the leader sees who, and can whisper them all), and when it starts
-- their client asks them to join. Edits reach those signed up as a toast saying what changed, or that it was cancelled. Announce puts a line in a public
-- chat channel for players without Wanted, and the leader's client invites anyone who whispers "inv". Each character's
-- raid, sign-ups and the planned raids it has heard of are saved (WantedDB.raids), so a reload or logout loses
-- nothing; a raid that has started is gone once its ad stops coming, a planned one stays until it should have started.

local _, Wanted = ...
local Raids = Wanted:NewModule("Raids")
local Sync = Wanted.Sync
local Store = Wanted.Store
local private = {
	mine = nil, -- the raid we lead: { id, title, guild?, where, startAt, size, minLevel, created, signups = { name = true } }
	seen = {}, -- id -> { raid, heard (server time) } other players' raids
	toasted = {}, -- id -> true once its toast has shown
	joined = {}, -- id -> { leader, startAt, title, kind ("going" or "interested"), asked, details } raids we joined or signed up for
	reminded = {}, -- id..":"..kind -> true
	pending = {}, -- names waiting for an invite until combat ends
	inviteQueue = {}, -- names Invite sign-ups still has to invite
	answered = {}, -- name -> when we last told them who's going (GetTime)
	viewed = {}, -- raid id -> true once the Raids page has shown it
	rosters = {}, -- raid id -> { going, interested, more, at, asked } who's going to others' raids, as their leaders said
	inviteTries = 0,
	soloInvites = 0, -- invites out while we're still alone (a party holds four)
	counter = 0,
	lastAnnounce = -math.huge,
	lastWhisper = -math.huge,
}

local SIZES = { [10] = true, [20] = true, [40] = true }
local MAX_TEXT = 40
local AD_SECONDS = 60 -- an open raid's ad goes out this often
local GONE_SECONDS = 3 * 60 -- a raid whose ad hasn't come for this long has gone
local OPEN_HOURS = 2 -- a raid closes itself this long after it starts
local SOON_SECONDS = 15 * 60 -- the reminder before a planned raid
local ASK_MINUTES = 10 -- a planned raid's members ask for their invite for this long after it starts
local ANNOUNCE_SECONDS = 60
local WHISPER_GAP_SECONDS = 0.5 -- between Whisper sign-ups' whispers, so the game doesn't hold them back
local MAX_SEEN = 30
local PARTY_SIZE = 5
local WHO_SECONDS = 10 -- a player is told who's going at most this often
local ROSTER_SECONDS = 30 -- a leader is asked who's going at most this often per raid
local ROSTER_ROOM = 180 -- letters of names an answer holds (one addon message)
local INVITE_RETRY_SECONDS = 2 -- Invite sign-ups waits this long between rounds (for someone to join, or a fight to end)
local INVITE_TRIES = 60 -- rounds before it gives up on the rest
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
	Raids:Load()
end

---Takes up this character's saved raids (WantedDB.raids[character]), dropping what's past, and sends our raid's ad
---again. The saved tables are the ones used from then on, so every change is saved as it happens.
function Raids:Load()
	local db = Wanted.db
	db.raids = type(db.raids) == "table" and db.raids or {}
	local origin = Store:GetOrigin()
	local saved = type(db.raids[origin]) == "table" and db.raids[origin] or {}
	db.raids[origin] = saved
	saved.joined = type(saved.joined) == "table" and saved.joined or {}
	saved.seen = type(saved.seen) == "table" and saved.seen or {}
	saved.viewed = type(saved.viewed) == "table" and saved.viewed or {}
	private.saved, private.joined, private.seen, private.viewed = saved, saved.joined, saved.seen, saved.viewed
	local now = GetServerTime()
	local mine = saved.mine
	if type(mine) ~= "table" or type(mine.startAt) ~= "number" or type(mine.signups) ~= "table" or now > mine.startAt + OPEN_HOURS * 3600 then
		mine = nil
	end
	private.SetMine(mine)
	for id, j in pairs(private.joined) do
		if type(j) ~= "table" or type(j.startAt) ~= "number" or now > j.startAt + ASK_MINUTES * 60 then
			private.joined[id] = nil
		end
	end
	for id, entry in pairs(private.seen) do
		if type(entry) ~= "table" or type(entry.raid) ~= "table" or type(entry.heard) ~= "number" or private.Gone(entry, now) then
			private.seen[id] = nil
		else
			private.toasted[id] = true
		end
	end
	for id in pairs(private.viewed) do
		if not private.seen[id] then
			private.viewed[id] = nil
		end
	end
	if mine then
		private.SendAd()
	end
	private.Changed()
end

---The raid we lead, saved with it.
function private.SetMine(raid)
	private.mine = raid
	if private.saved then
		private.saved.mine = raid
	end
end

---Whether another player's raid has gone: no ad for a while since it started (a planned raid stays until then, as its
---leader may be offline).
function private.Gone(entry, now)
	return now - max(entry.heard, entry.raid.startAt) > GONE_SECONDS
end

---The raids for the calendar: ours, and those we're going to or interested in: { at, text, short }.
---@return table[]
function Raids:Calendar()
	local out = {}
	local mine = private.mine
	if mine then
		tinsert(out, { at = mine.startAt, text = format("%s %s (your raid)", date("%H:%M", mine.startAt), Raids:Title(mine)), short = mine.title })
	end
	for _, j in pairs(private.joined) do
		tinsert(out, { at = j.startAt, text = format("%s %s (%s)", date("%H:%M", j.startAt), j.title, j.kind or "going"), short = j.title })
	end
	return out
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
	local raid, why = private.Details(o)
	if not raid then
		return nil, why
	end
	local now = GetServerTime()
	private.counter = private.counter + 1
	raid.id = Store:GetOrigin()..":"..now..":"..private.counter
	raid.created = now
	raid.signups = {} -- name -> "going" or "interested"
	private.SetMine(raid)
	private.SendAd()
	private.Changed()
	return private.mine
end

---Changes the raid we lead (the same fields as Create; a started raid without a new time keeps its start). Its ad
---goes out at once, so those signed up are told what changed. Returns why not, or nil.
---@param o table
---@return string?
function Raids:Update(o)
	local mine = private.mine
	if not mine then
		return "You're not leading a raid."
	end
	if not o.startAt and private.Started(mine) then
		o.startAt = mine.startAt
	end
	local raid, why = private.Details(o, mine.startAt)
	if not raid then
		return why
	end
	for key, value in pairs(raid) do
		mine[key] = value
	end
	mine.guild, mine.exclusive = raid.guild, raid.exclusive
	private.SendAd()
	private.Changed()
	return nil
end

---A raid's details from the form, checked: { title, guild, where, startAt, size, minLevel }, or nil and why not. A
---start before now is now, except keep (the start a raid already had).
function private.Details(o, keep)
	local title = private.Clean(o.title)
	if title == "" then
		return nil, "Give the raid a name."
	end
	local size = tonumber(o.size)
	if not SIZES[size] then
		return nil, "Pick a size: 10, 20 or 40."
	end
	-- Guild only is a guild raid too
	local guild = (o.guild or o.exclusive) and GetGuildInfo("player") or nil
	if (o.guild or o.exclusive) and not guild then
		return nil, "You're not in a guild."
	end
	local now = GetServerTime()
	local startAt = tonumber(o.startAt)
	if not startAt or (startAt < now and startAt ~= keep) then
		startAt = now
	end
	if startAt > now + 7 * 24 * 3600 then
		return nil, "A raid can be planned up to a week ahead."
	end
	return {
		title = title,
		guild = guild,
		exclusive = o.exclusive and true or nil,
		where = private.Clean(o.where) ~= "" and private.Clean(o.where) or (GetZoneText() or ""),
		startAt = startAt,
		size = size,
		minLevel = max(1, min(60, floor(tonumber(o.minLevel) or 1))),
	}
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
	private.SetMine(nil)
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
	local when = private.Started(raid) and "now" or ("at "..Raids:ServerClock(raid.startAt))
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

---Where Announce can post: guild chat (in a guild), then each chat channel we're in but Wanted's own: { key, label },
---key "guild" or the channel's number.
---@return table[]
function Raids:AnnounceTargets()
	local out = {}
	if IsInGuild() then
		tinsert(out, { key = "guild", label = "Guild chat" })
	end
	local own = Sync:GetInfo().channelName
	local list = GetChannelList and { GetChannelList() } or {}
	for i = 1, #list, 3 do
		local id, name, disabled = list[i], list[i + 1], list[i + 2]
		if type(id) == "number" and type(name) == "string" and not disabled and not (own and strlower(name) == strlower(own)) then
			tinsert(out, { key = id, label = format("%d. %s", id, name) })
		end
	end
	return out
end

---Where Announce posts unless told otherwise: guild chat for a guild-only raid, else Looking for Group or General.
---@return string|number|nil
function Raids:AnnounceTarget()
	if private.mine and private.mine.exclusive and IsInGuild() then
		return "guild"
	end
	return (Raids:AnnounceChannel())
end

---Puts a line in guild chat or a chat channel (target: "guild" or a channel number from AnnounceTargets; nil for
---AnnounceTarget), the raid's own line when text is nil. Needs a click: the game only lets a key press or click post
---in public channels, so it's called from the confirm dialog's button. Returns why not, or nil.
---@param text string?
---@param target string|number|nil
---@return string?
function Raids:Announce(text, target)
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
	target = target or Raids:AnnounceTarget()
	local known = false
	for _, t in ipairs(Raids:AnnounceTargets()) do
		known = known or t.key == target
	end
	if not target or not known then
		return "Pick where to post it."
	end
	private.lastAnnounce = GetTime()
	if target == "guild" then
		C_ChatInfo.SendChatMessage(strsub(text, 1, 255), "GUILD")
	else
		C_ChatInfo.SendChatMessage(strsub(text, 1, 255), "CHANNEL", nil, target)
	end
	return nil
end

---Opens the guild-only raid we lead to everyone: its ad goes out to every Wanted player of our faction from now on.
function Raids:OpenToEveryone()
	local mine = private.mine
	if not mine or not mine.exclusive then
		return
	end
	mine.exclusive = nil
	private.SendAd()
	private.Changed()
end

---Whether a player may join the raid we lead: anyone, or for a guild-only raid, our guildmates. A client without the
---game's guild check lets them in.
function private.MayJoin(name, quiet)
	local mine = private.mine
	if not mine or not mine.exclusive or not (C_GuildInfo and C_GuildInfo.MemberExistsByName) then
		return true
	end
	local ok, exists = pcall(C_GuildInfo.MemberExistsByName, name)
	if ok and exists then
		return true
	end
	-- The guild may know them without their realm
	local short = strmatch(name, "^([^%-]+)%-")
	if short then
		ok, exists = pcall(C_GuildInfo.MemberExistsByName, short)
		if ok and exists then
			return true
		end
	end
	if not quiet then
		Wanted:Print("%s isn't in your guild: not invited to %s, which is guild only.", name, mine.title)
	end
	return false
end

---Someone asks to join the raid we lead, or, before it starts, signs up for it: k = "g" going (and an older client's
---join, which has no k), "i" interested, "x" taken back.
---@param sender string
---@param tbl table { r = raid id, k = kind? }
function Raids:OnJoin(sender, tbl)
	local raid = private.mine
	if not raid or type(tbl) ~= "table" or tbl.r ~= raid.id or type(sender) ~= "string" then
		return
	end
	if tbl.k ~= "x" and not private.MayJoin(sender) then
		return
	end
	if tbl.k == "x" then
		if raid.signups[sender] then
			raid.signups[sender] = nil
			private.Changed()
		end
		return
	end
	if not private.Started(raid) then
		local kind = tbl.k == "i" and "interested" or "going"
		if raid.signups[sender] ~= kind then
			raid.signups[sender] = kind
			Wanted:Print("%s is %s for %s.", sender, kind, raid.title)
			private.Changed()
		end
		return
	end
	private.Invite(sender)
end

---Who signed up for a raid we lead: those going and those interested, each sorted.
---@param raid table
---@return string[] going
---@return string[] interested
function Raids:SignUps(raid)
	local going, interested = {}, {}
	for name, kind in pairs(raid.signups) do
		tinsert(kind == "interested" and interested or going, name)
	end
	sort(going)
	sort(interested)
	return going, interested
end

---The whisper Whisper sign-ups starts with.
---@return string?
function Raids:WhisperText()
	local raid = private.mine
	if not raid then
		return nil
	end
	if private.Started(raid) then
		return format("%s has started in %s. Whisper me \"inv\" for an invite.", Raids:Title(raid), raid.where)
	end
	return format("%s starts at %s in %s. See you there!", Raids:Title(raid), Raids:ServerClock(raid.startAt), raid.where)
end

---Whispers everyone signed up for the raid we lead, one at a time a moment apart, at most once a minute. Returns why
---not, or nil.
---@param text string
---@return string?
function Raids:WhisperSignUps(text)
	local raid = private.mine
	if not raid then
		return "You're not leading a raid."
	end
	text = strsub(strtrim((gsub(gsub(text or "", "|", ""), "[\r\n]+", " "))), 1, 255)
	if text == "" then
		return "There's nothing to send."
	end
	if not next(raid.signups) then
		return "Nobody has signed up yet."
	end
	if GetTime() - private.lastWhisper < ANNOUNCE_SECONDS then
		return "You whispered them less than a minute ago."
	end
	private.lastWhisper = GetTime()
	local going, interested = Raids:SignUps(raid)
	local i = 0
	for _, list in ipairs({ going, interested }) do
		for _, name in ipairs(list) do
			C_Timer.After(i * WHISPER_GAP_SECONDS, function()
				C_ChatInfo.SendChatMessage(text, "WHISPER", nil, name)
			end)
			i = i + 1
		end
	end
	return nil
end

---A whisper: "inv" to the leader of an open raid that has started is a join.
---@param text string
---@param sender string
function Raids:OnWhisper(text, sender)
	local raid = private.mine
	if raid and private.Started(raid) and type(text) == "string" and strmatch(strlower(text), "^%s*inv[ite]*%s*$") and private.MayJoin(sender) then
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

---Someone asks who's going to the raid we lead: the names, going and interested, as many as fit one message. Not for a
---guild-only raid's outsiders; at most every WHO_SECONDS per player.
---@param sender string
---@param tbl table { r = raid id }
function Raids:OnWho(sender, tbl)
	local raid = private.mine
	if not raid or type(tbl) ~= "table" or tbl.r ~= raid.id or type(sender) ~= "string" then
		return
	end
	if raid.exclusive and not private.MayJoin(sender, true) then
		return
	end
	local last = private.answered[sender]
	if last and GetTime() - last < WHO_SECONDS then
		return
	end
	private.answered[sender] = GetTime()
	local going, interested = Raids:SignUps(raid)
	local room, more = ROSTER_ROOM, 0
	local function Fit(names)
		local out = {}
		for _, name in ipairs(names) do
			if #name + 1 <= room then
				tinsert(out, name)
				room = room - #name - 1
			else
				more = more + 1
			end
		end
		return table.concat(out, ",")
	end
	Sync:SendRaidRoster(sender, { r = raid.id, g = Fit(going), i = Fit(interested), m = more > 0 and more or nil })
end

---A leader's answer to who's going: kept for their raid, from them only.
---@param sender string
---@param tbl table { r, g, i, m }
function Raids:OnRoster(sender, tbl)
	local entry = type(tbl) == "table" and type(tbl.r) == "string" and private.seen[tbl.r]
	if not entry or entry.raid.leader ~= sender then
		return
	end
	local function Names(text)
		local out = {}
		for name in gmatch(type(text) == "string" and text or "", "[^,|]+") do
			if #out < 40 then
				tinsert(out, strsub(name, 1, 60))
			end
		end
		return out
	end
	local roster = private.rosters[tbl.r] or {}
	roster.going, roster.interested = Names(tbl.g), Names(tbl.i)
	roster.more = max(0, min(99, floor(tonumber(tbl.m) or 0)))
	roster.at = GetTime()
	private.rosters[tbl.r] = roster
	private.Changed()
	if private.onRoster then
		private.onRoster(tbl.r)
	end
end

---Who's going to another player's raid, as its leader last said ({ going, interested, more }), or nil before they
---have; looking asks them again, at most every ROSTER_SECONDS.
---@param id string
---@return table?
function Raids:Roster(id)
	local entry = private.seen[id]
	if not entry then
		return nil
	end
	local roster = private.rosters[id] or {}
	private.rosters[id] = roster
	if not roster.asked or GetTime() - roster.asked >= ROSTER_SECONDS then
		roster.asked = GetTime()
		Sync:SendRaidWho(entry.raid.leader, id)
	end
	return roster.at and roster or nil
end

---Calls func(raid id) when a leader's answer comes in (the Raids page, to redraw a tooltip).
---@param func function
function Raids:OnRosterUpdate(func)
	private.onRoster = func
end

---Whether the planned raid we lead can be formed now: from SOON_SECONDS before it starts.
---@return boolean
function Raids:CanFormNow()
	local raid = private.mine
	return raid ~= nil and not private.Started(raid) and raid.startAt - GetServerTime() <= SOON_SECONDS
end

---Forms the planned raid we lead now: it starts (its ad says so, and those signed up get the popup asking them to
---join), and with invite, everyone signed up is invited too.
---@param invite boolean
function Raids:FormNow(invite)
	local raid = private.mine
	if not raid or private.Started(raid) then
		return
	end
	raid.startAt = GetServerTime()
	private.SendAd()
	if invite then
		Raids:InviteSignUps()
	end
	private.Changed()
end

---Invites everyone signed up for the raid we lead, going and interested, whether or not it has started. Solo, a party
---holds four invites: the rest wait until someone joins and the group becomes a raid. Never in a fight. Returns why
---not, or nil.
---@return string?
function Raids:InviteSignUps()
	local raid = private.mine
	if not raid then
		return "You're not leading a raid."
	end
	local going, interested = Raids:SignUps(raid)
	if #going + #interested == 0 then
		return "Nobody has signed up yet."
	end
	wipe(private.inviteQueue)
	for _, list in ipairs({ going, interested }) do
		for _, name in ipairs(list) do
			tinsert(private.inviteQueue, name)
		end
	end
	private.inviteTries, private.soloInvites = 0, 0
	private.PumpInvites()
	return nil
end

---A round of Invite sign-ups: what the group has room for now, then another round in a moment while any are left.
function private.PumpInvites()
	local queue = private.inviteQueue
	if #queue == 0 or not private.mine then
		wipe(queue)
		return
	end
	private.inviteTries = private.inviteTries + 1
	if not InCombatLockdown() then
		if not IsInGroup() then
			-- A party holds four besides us: no more until someone joins
			for _ = 1, min(PARTY_SIZE - 1 - private.soloInvites, #queue) do
				private.Invite(tremove(queue, 1))
				private.soloInvites = private.soloInvites + 1
			end
		elseif not IsInRaid() then
			if C_PartyInfo and C_PartyInfo.ConvertToRaid then
				C_PartyInfo.ConvertToRaid()
			end
		else
			while #queue > 0 do
				private.Invite(tremove(queue, 1))
			end
		end
	end
	if #queue > 0 then
		if private.inviteTries >= INVITE_TRIES then
			Wanted:Print("Invite sign-ups stopped: nobody joined, so %d weren't invited. Try again once someone is in your group.", #queue)
			wipe(queue)
			return
		end
		C_Timer.After(INVITE_RETRY_SECONDS, private.PumpInvites)
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
	Sync:SendRaidAd({ id = raid.id, l = Store:GetOrigin(), t = raid.title, g = raid.guild, x = raid.exclusive and 1 or nil, z = raid.where, s = raid.startAt, m = raid.size,
		ml = raid.minLevel, n = private.GroupSize(), u = private.CountKind(raid.signups, "going"), i = private.CountKind(raid.signups, "interested"), f = UnitFactionGroup("player"), c = closed and 1 or nil })
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
			private.SendAd()
			-- 15 minutes ahead: the leader can form it now
			if Raids:CanFormNow() and not private.reminded[raid.id..":lead"] then
				private.reminded[raid.id..":lead"] = true
				Wanted.Toast:Add({ kind = "FORM YOUR RAID", name = Raids:Title(raid),
					detail = "Starts "..Raids:When(raid.startAt)..". Form it now from the Raids page.", onClick = function() Wanted.UI:Show("raids") end })
				private.Changed()
			end
		end
	end
	local changed = false
	for id, entry in pairs(private.seen) do
		if private.Gone(entry, now) then
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
---A guild-only raid's ad counts only from our guild's own chat, and only when it's our guild.
---@param ad table
---@param sender string
---@param channel string? "GUILD", "CHANNEL" or "WHISPER"
function Raids:OnAd(ad, sender, channel)
	if type(ad) ~= "table" or type(ad.id) ~= "string" or #ad.id > 80 or type(ad.l) ~= "string" or #ad.l > 60 then
		return
	end
	if ad.l == Store:GetOrigin() or strfind(ad.l, "|", 1, true) then
		return
	end
	if ad.c then
		local j = private.joined[ad.id]
		if j then
			-- Closed before it started: cancelled
			private.joined[ad.id] = nil
			if j.startAt > GetServerTime() then
				Wanted.Toast:Add({ kind = "RAID CANCELLED", name = j.title, detail = j.leader.." cancelled it",
					onClick = function() Wanted.UI:Show("raids") end })
			end
		end
		if private.seen[ad.id] then
			private.seen[ad.id] = nil
			private.Changed()
		end
		return
	end
	if ad.x and (channel ~= "GUILD" or ad.g ~= GetGuildInfo("player")) then
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
	entry.heard = GetServerTime()
	entry.raid = {
		id = ad.id, leader = ad.l, title = private.Clean(ad.t), guild = private.Clean(ad.g) ~= "" and private.Clean(ad.g) or nil, where = private.Clean(ad.z), startAt = startAt, size = size,
		minLevel = max(1, min(60, floor(tonumber(ad.ml) or 1))), members = max(0, min(size, floor(tonumber(ad.n) or 0))),
		signups = max(0, min(99, floor(tonumber(ad.u) or 0))), interested = max(0, min(99, floor(tonumber(ad.i) or 0))),
	}
	private.TellChanges(entry.raid)
	private.Changed()
	if not private.toasted[ad.id] and Wanted.db.settings.raidToasts and Wanted.Toast then
		private.toasted[ad.id] = true
		local raid = entry.raid
		local started = raid.startAt <= GetServerTime()
		Wanted.Toast:Add({ kind = started and "RAID FORMING" or "RAID PLANNED", name = Raids:Title(raid),
			detail = format("%s, %s  %d/%d  led by %s", raid.where, started and "now" or Raids:When(raid.startAt), raid.members, raid.size, raid.leader),
			onClick = function() Wanted.UI:Show("raids") end })
	end
end

---How many of the raids we can see haven't been shown on the Raids page yet (the menu's count).
---@return number
function Raids:Unseen()
	local n = 0
	for id in pairs(private.seen) do
		if not private.viewed[id] then
			n = n + 1
		end
	end
	return n
end

---The Raids page is showing them all: none are new now. Returns whether any were.
---@return boolean
function Raids:MarkSeen()
	local any = false
	for id in pairs(private.seen) do
		if not private.viewed[id] then
			private.viewed[id] = true
			any = true
		end
	end
	return any
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

---Joins a raid we can see: the leader invites us. Before it starts, signs up as going. Returns why not, or nil.
---@param id string
---@return string?
function Raids:Join(id)
	local entry = private.seen[id]
	if entry and entry.raid.startAt > GetServerTime() then
		return Raids:SignUp(id, "going")
	end
	local why = private.CanJoin(entry)
	if why then
		return why
	end
	local raid = entry.raid
	private.joined[id] = { leader = raid.leader, startAt = raid.startAt, title = Raids:Title(raid), kind = "going", asked = true,
		details = private.Snapshot(raid) }
	Sync:SendRaidJoin(raid.leader, id)
	Wanted:Print("Joining %s: %s will invite you.", raid.title, raid.leader)
	private.Changed()
	return nil
end

---Signs up for a raid that hasn't started, as "going" or "interested", or takes it back (nil). The leader sees the
---count; when it starts we're asked to join. Returns why not, or nil.
---@param id string
---@param kind string?
---@return string?
function Raids:SignUp(id, kind)
	local entry = private.seen[id]
	if not kind then
		local j = private.joined[id]
		if j then
			private.joined[id] = nil
			Sync:SendRaidJoin(j.leader, id, "x")
			private.Changed()
		end
		return nil
	end
	local why = private.CanJoin(entry)
	if why then
		return why
	end
	local raid = entry.raid
	private.joined[id] = { leader = raid.leader, startAt = raid.startAt, title = Raids:Title(raid), kind = kind,
		details = private.Snapshot(raid) }
	Sync:SendRaidJoin(raid.leader, id, kind == "interested" and "i" or "g")
	Wanted:Print("%s for %s at %s. You'll be asked to join when it starts.", kind == "interested" and "Interested" or "Going",
		raid.title, Raids:When(raid.startAt))
	private.Changed()
	return nil
end

---Why we can't join or sign up for a raid we can see, or nil.
function private.CanJoin(entry)
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
end

---Whether we joined or signed up for a raid.
---@param id string
---@return boolean
function Raids:Joined(id)
	return private.joined[id] ~= nil
end

---How we signed up for a raid: "going", "interested", or nil.
---@param id string
---@return string?
function Raids:Interest(id)
	return private.joined[id] and private.joined[id].kind
end

---The details a change alert compares: { title, where, startAt, size, minLevel }.
function private.Snapshot(raid)
	return { title = Raids:Title(raid), where = raid.where, startAt = raid.startAt, size = raid.size, minLevel = raid.minLevel }
end

---A raid we signed up for, from a new ad: a toast with what changed (what it is now, and was), if anything did.
function private.TellChanges(raid)
	local j = private.joined[raid.id]
	if not j then
		return
	end
	local was, now = j.details, private.Snapshot(raid)
	local changes = {}
	if now.title ~= was.title then
		tinsert(changes, format("%s (was %s)", now.title, was.title))
	end
	if now.startAt ~= was.startAt and now.startAt > GetServerTime() then
		tinsert(changes, format("%s (was %s)", Raids:When(now.startAt), Raids:When(was.startAt)))
	end
	if now.where ~= was.where then
		tinsert(changes, format("%s (was %s)", now.where, was.where))
	end
	if now.size ~= was.size then
		tinsert(changes, format("%d players (was %d)", now.size, was.size))
	end
	if now.minLevel ~= was.minLevel then
		tinsert(changes, format("level %d+ (was %d+)", now.minLevel, was.minLevel))
	end
	j.details, j.title, j.startAt = now, now.title, now.startAt
	if #changes > 0 then
		Wanted.Toast:Add({ kind = "RAID CHANGED", name = now.title, detail = table.concat(changes, ", "),
			onClick = function() Wanted.UI:Show("raids") end })
	end
end

---For the raids we signed up for: a reminder before they start; when they do, a popup asking to join (out of a fight,
---once), and once we say Join, asking the leader for the invite every minute for a while (in case one was missed).
function private.Remind(now)
	for id, j in pairs(private.joined) do
		if now > j.startAt + ASK_MINUTES * 60 then
			private.joined[id] = nil
		elseif now >= j.startAt then
			if j.asked then
				Sync:SendRaidJoin(j.leader, id)
			elseif not private.reminded[id..":start"] and not InCombatLockdown() and not Wanted.Widgets:IsDialogShown() then
				private.reminded[id..":start"] = true
				private.AskToJoin(id, j)
			end
		elseif now >= j.startAt - SOON_SECONDS and not private.reminded[id..":soon"] then
			private.reminded[id..":soon"] = true
			Wanted.Toast:Add({ kind = "RAID SOON", name = j.title, detail = "Starts "..Raids:When(j.startAt).." with "..j.leader,
				onClick = function() Wanted.UI:Show("raids") end })
		end
	end
end

---The popup when a raid we signed up for starts: Join asks the leader for the invite.
function private.AskToJoin(id, j)
	Wanted.Alerts:Sound("important")
	Wanted.Widgets:Dialog({
		title = "Raid starting",
		text = format("%s has started %s. Join now?", j.leader, j.title),
		confirmLabel = "Join",
		cancelLabel = "Not now",
		onConfirm = function()
			if private.joined[id] then
				j.asked = true
				Sync:SendRaidJoin(j.leader, id)
				Wanted:Print("Joining %s: %s will invite you.", j.title, j.leader)
			end
		end,
	})
end

-- ============================================================================
-- Times
-- ============================================================================

---How far the realm's clock is ahead of ours, in seconds, to the quarter hour: 0 when they agree or the game doesn't
---say.
---@return number
function Raids:ServerOffset()
	local h, m
	if GetGameTime then
		h, m = GetGameTime()
	end
	if type(h) ~= "number" or type(m) ~= "number" then
		return 0
	end
	local here = date("*t", GetServerTime())
	local diff = (h * 60 + m) - (here.hour * 60 + here.min)
	if diff > 720 then
		diff = diff - 1440
	elseif diff < -720 then
		diff = diff + 1440
	end
	return floor(diff / 15 + 0.5) * 15 * 60
end

---A time typed as "20:00", "8:30" or "20", in our own time or (server) the realm's, as the next such moment (server
---seconds), or nil.
---@param text string
---@param server boolean?
---@return number?
function Raids:ParseTime(text, server)
	local h, m = strmatch(text or "", "^%s*(%d%d?):(%d%d)%s*$")
	if not h then
		h, m = strmatch(text or "", "^%s*(%d%d?)%s*$"), "0"
	end
	h, m = tonumber(h), tonumber(m)
	if not h or h > 23 or m > 59 then
		return nil
	end
	local offset = server and Raids:ServerOffset() or 0
	local now = GetServerTime()
	local t = date("*t", now + offset)
	t.hour, t.min, t.sec = h, m, 0
	local at = time(t) - offset
	if at <= now then
		at = at + 24 * 3600
	end
	return at
end

---A time zone's short name: as given when it's short ("EDT"), its initials when it's spelled out ("Eastern Daylight
---Time", as Windows gives it), else its offset from UTC ("UTC-4", "UTC+5:30").
---@param name string?
---@param utcOffset number seconds ahead of UTC
---@return string
function Raids:ShortZone(name, utcOffset)
	name = type(name) == "string" and strtrim(name) or ""
	if name ~= "" and not strfind(name, " ") and #name <= 5 then
		return name
	end
	if strfind(name, " ") then
		local initials = gsub(name, "(%a)%a*%.?%s*", "%1")
		if #initials >= 2 and #initials <= 5 then
			return strupper(initials)
		end
	end
	local minutes = floor(math.abs(utcOffset) / 60 + 0.5)
	local h, m = floor(minutes / 60), minutes % 60
	return format("UTC%s%d%s", utcOffset < 0 and "-" or "+", h, m > 0 and format(":%02d", m) or "")
end

---Our time zone's short name: "EDT".
---@return string
function Raids:ZoneName()
	local now = GetServerTime()
	local here, utc = date("*t", now), date("!*t", now)
	utc.isdst = here.isdst
	local ok, name = pcall(date, "%Z", now)
	return Raids:ShortZone(ok and name or nil, time(here) - time(utc))
end

---A raid's start as shown here: our own time with our time zone ("Thu 20:00 EDT"), and the realm's beside it when it
---differs ("Thu 20:00 EDT (server 23:00)").
---@param t number
---@return string
function Raids:When(t)
	local offset = Raids:ServerOffset()
	local ours = date("%a %H:%M", t).." "..Raids:ZoneName()
	if offset == 0 then
		return ours
	end
	return format("%s (server %s)", ours, date("%H:%M", t + offset))
end

---A start in the realm's time, for chat lines, which every reader shares: "23:00 server time".
---@param t number
---@return string
function Raids:ServerClock(t)
	return date("%H:%M", t + Raids:ServerOffset()).." server time"
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

function private.CountKind(signups, kind)
	local n = 0
	for _, k in pairs(signups) do
		if k == kind then
			n = n + 1
		end
	end
	return n
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
