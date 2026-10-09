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
	invites = {}, -- name -> { sent (GetTime, nil until invited), tries } players to invite to the raid we lead, until they're in
	inviteOrder = {}, -- the names in invites, first asked first
	replied = {}, -- name -> when we last whispered them back (GetTime)
	answered = {}, -- name -> when we last told them who's going (GetTime)
	viewed = {}, -- raid id -> true once the Raids page has shown it
	rosters = {}, -- raid id -> { going, interested, more, at, asked } who's going to others' raids, as their leaders said
	counter = 0,
	lastAnnounce = -math.huge,
	lastWhisper = -math.huge,
}

local SIZES = { [10] = true, [20] = true, [40] = true }
local MAX_TEXT = 40
Raids.MAX_TEXT = MAX_TEXT -- the longest a raid's name or place may be (the form's boxes take no more)
local AD_SECONDS = 60 -- an open raid's ad goes out this often
local GONE_SECONDS = 3 * 60 -- a raid whose ad hasn't come for this long has gone
local OPEN_HOURS = 2 -- a raid closes itself this long after it starts
local SOON_SECONDS = 15 * 60 -- the reminder before a planned raid
local ASK_MINUTES = 10 -- a planned raid's members ask for their invite for this long after it starts
local ANNOUNCE_SECONDS = 60
local WHISPER_GAP_SECONDS = 0.5 -- between Whisper sign-ups' whispers, so the game doesn't hold them back
local MAX_SEEN = 30
local MAX_SEEN_PER_LEADER = 3 -- a leader has one raid at a time; more ids than this under one name at once is noise
local PLAN_AHEAD_SECONDS = 7 * 24 * 3600 -- a raid can be planned this far ahead (Create), so no ad says further
local AD_PAST_SECONDS = 24 * 3600 -- an ad for a raid that started longer ago than this is nonsense (raids close after OPEN_HOURS)
local PARTY_SIZE = 5
local WHO_SECONDS = 10 -- a player is told who's going at most this often
local ROSTER_SECONDS = 30 -- a leader is asked who's going at most this often per raid
local ROSTER_ROOM = 180 -- letters of names an answer holds (one addon message)
local INVITE_ROUND_SECONDS = 2 -- the invite queue looks again this often while anyone waits
local INVITE_AGAIN_SECONDS = 60 -- an invite not taken up by then is sent once more
local INVITE_GIVE_UP_SECONDS = 180 -- and not taken up by then, dropped
local REPLY_SECONDS = 60 -- a player whispering "inv" is whispered back at most this often
local DIRECT_SECONDS = 2 * 60 -- a raid heard from its leader this recently isn't changed by copies others shared on
local MAX_EDITS = 10000 -- an ad's edit count past this is nonsense
local MAP_WORLD = Enum.UIMapType and Enum.UIMapType.World or 1
local MAP_ZONE = Enum.UIMapType and Enum.UIMapType.Zone or 3

-- ============================================================================
-- Forming and leading a raid
-- ============================================================================

function Raids:OnEnable()
	private.frame = private.frame or CreateFrame("Frame")
	private.frame:RegisterEvent("CHAT_MSG_WHISPER")
	private.frame:RegisterEvent("GROUP_ROSTER_UPDATE")
	private.frame:RegisterEvent("CHAT_MSG_SYSTEM")
	private.frame:SetScript("OnEvent", function(_, event, text, sender)
		if event == "CHAT_MSG_WHISPER" then
			Raids:OnWhisper(text, sender)
		elseif event == "CHAT_MSG_SYSTEM" then
			Raids:OnSystem(text)
		elseif private.mine then
			private.PumpInvites()
			private.Changed()
		end
	end)
	Wanted:OnCombatEnd(function() private.PumpInvites() end)
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
	mine.edits = (mine.edits or 0) + 1
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
	if startAt > now + PLAN_AHEAD_SECONDS then
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
	wipe(private.invites)
	wipe(private.inviteOrder)
	wipe(private.replied)
	wipe(private.answered)
	private.refused = nil
	private.Changed()
end

---The line Announce puts in a public chat channel, for players without Wanted.
---@return string?
function Raids:AnnounceText()
	local raid = private.mine
	if not raid then
		return nil
	end
	if private.Started(raid) then
		return format("Forming a world PvP raid: %s in %s now (%d/%d). Whisper me \"inv\" to join.", Raids:Title(raid), raid.where,
			private.GroupSize(), raid.size)
	end
	return format("World PvP raid: %s in %s, %s. Whisper me \"inv\" to sign up, and you'll be invited when it starts.",
		Raids:Title(raid), raid.where, Raids:ServerWhen(raid.startAt))
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
	-- Said once per player, however often they whisper
	private.refused = private.refused or {}
	if not quiet and not private.refused[name] then
		private.refused[name] = true
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
	private.QueueInvite(sender)
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
	return format("%s starts %s in %s. See you there!", Raids:Title(raid), Raids:ServerWhen(raid.startAt), raid.where)
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

---A whisper asking for an invite ("inv", "inv pls", "invite me") to the leader of an open raid: after the start a join;
---before it a sign-up as going, whispered back the start time, and invited when it starts. A full raid says so. A
---guild-only raid's outsiders get nothing.
---@param text string
---@param sender string
function Raids:OnWhisper(text, sender)
	local raid = private.mine
	if not raid or type(text) ~= "string" or type(sender) ~= "string" then
		return
	end
	local word = strmatch(strlower(text), "^%s*(%a+)")
	if (word ~= "inv" and word ~= "invite") or not private.MayJoin(sender) then
		return
	end
	if private.Full(sender) then
		private.Reply(sender, format("Sorry, %s is full (%d).", raid.title, raid.size))
		return
	end
	if not private.Started(raid) then
		if not raid.signups[sender] then
			raid.signups[sender] = "going"
			Wanted:Print("%s is going to %s (whispered).", sender, raid.title)
			private.Changed()
		end
		raid.whispered = raid.whispered or {}
		raid.whispered[sender] = true
		private.Reply(sender, format("You're signed up for %s: it starts %s in %s, and you'll be invited then.", Raids:Title(raid),
			Raids:ServerWhen(raid.startAt), raid.where))
		return
	end
	if not Raids:CanInvite() then
		private.Reply(sender, "Got it: I can't invite just yet, you're in line and will be invited as soon as I can.")
	end
	private.QueueInvite(sender)
end

---Puts those who signed up by whisper in line for an invite; one the raid has no room for is told so and let go.
function private.QueueWhispered(raid)
	for name in pairs(raid.whispered or {}) do
		if private.Full(name) then
			private.Reply(name, format("Sorry, %s filled up before you could be invited.", raid.title))
			private.Done(name)
		else
			private.QueueInvite(name)
		end
	end
end

---Whispers a player back, at most every REPLY_SECONDS each.
function private.Reply(name, text)
	local last = private.replied[name]
	if last and GetTime() - last < REPLY_SECONDS then
		return
	end
	private.replied[name] = GetTime()
	C_ChatInfo.SendChatMessage(strsub(text, 1, 255), "WHISPER", nil, name)
end

-- ============================================================================
-- Inviting
-- ============================================================================

---Whether a player is in our group, by their name as it reached us ("Name-Realm" or "Name").
function private.InGroup(name)
	if not (UnitInRaid or UnitInParty) then
		return false
	end
	local short = strmatch(name, "^([^%-]+)%-")
	for _, n in ipairs({ name, short }) do
		if n and ((UnitInRaid and UnitInRaid(n)) or (UnitInParty and UnitInParty(n))) then
			return true
		end
	end
	return false
end

---Whether we may invite: alone, or the group's leader or an assistant. A client without the game's checks may.
function Raids:CanInvite()
	if not IsInGroup() or not UnitIsGroupLeader then
		return true
	end
	return UnitIsGroupLeader("player") or (UnitIsGroupAssistant and UnitIsGroupAssistant("player")) or false
end

---How many invites are out and not yet taken up.
function private.Outstanding()
	local n, now = 0, GetTime()
	for _, entry in pairs(private.invites) do
		if entry.sent and now - entry.sent < INVITE_AGAIN_SECONDS then
			n = n + 1
		end
	end
	return n
end

---Whether the raid we lead has no room for someone not yet in it: its members and the invites out fill it.
function private.Full(name)
	local raid = private.mine
	if not raid or private.InGroup(name) or private.invites[name] then
		return false
	end
	return private.GroupSize() + private.Outstanding() >= raid.size
end

---Puts a player in line for an invite to the raid we lead (never ourselves, nor anyone already in the group), and
---sends what the group has room for.
function private.QueueInvite(name)
	local raid = private.mine
	if not raid or type(name) ~= "string" or name == Store:GetOrigin() then
		return
	end
	if private.InGroup(name) then
		-- Already in (invited some other way): nothing to do, now or at the next re-queue
		private.Done(name)
		return
	end
	if not private.invites[name] then
		if private.Full(name) then
			Wanted:Print("%s wants to join %s, but it's full (%d).", name, raid.title, raid.size)
			return
		end
		private.invites[name] = { tries = 0, queued = GetTime() }
		tinsert(private.inviteOrder, name)
	end
	private.PumpInvites()
end

---Sends the invites the group has room for: never in a fight, never without the right to invite; four while we're
---alone (a party holds five), and once a party would overflow it becomes a raid, the rest going out once it is one.
---Anyone in the group leaves the line ("joined"); an invite not taken up goes once more after INVITE_AGAIN_SECONDS,
---and is dropped after INVITE_GIVE_UP_SECONDS. Looks again every INVITE_ROUND_SECONDS while anyone waits.
function private.PumpInvites()
	local raid, now = private.mine, GetTime()
	local order = private.inviteOrder
	-- While invites can't go out (a fight, no right to invite), the wait doesn't count towards giving up
	local blocked = InCombatLockdown() or not Raids:CanInvite()
	for i = #order, 1, -1 do
		local name = order[i]
		local entry = private.invites[name]
		if not raid or private.InGroup(name) then
			if raid then
				Wanted:Print("%s joined %s.", name, raid.title)
			end
			private.Done(name)
			tremove(order, i)
		elseif entry.sent and now - entry.sent >= INVITE_GIVE_UP_SECONDS then
			Wanted:Print("%s didn't join %s.", name, raid.title)
			private.Done(name)
			tremove(order, i)
		elseif not entry.sent and blocked then
			entry.queued = now
		elseif not entry.sent and now - entry.queued >= INVITE_GIVE_UP_SECONDS then
			-- Never sent (in a fight, no right to invite, no room) for as long: given up on too
			Wanted:Print("%s couldn't be invited to %s in time.", name, raid.title)
			private.Done(name)
			tremove(order, i)
		end
	end
	if #order == 0 then
		return
	end
	if not blocked then
		local members, out = private.GroupSize(), private.Outstanding()
		local waiting = 0
		for _, name in ipairs(order) do
			local entry = private.invites[name]
			if not entry.sent or (now - entry.sent >= INVITE_AGAIN_SECONDS and entry.tries < 2) then
				waiting = waiting + 1
			end
		end
		local room = raid.size - members - out
		if not IsInGroup() then
			room = min(room, PARTY_SIZE - 1 - out)
		elseif not IsInRaid() then
			if members + out + waiting > PARTY_SIZE and C_PartyInfo and C_PartyInfo.ConvertToRaid then
				C_PartyInfo.ConvertToRaid()
			end
			room = min(room, PARTY_SIZE - members - out)
		end
		local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
		for _, name in ipairs(order) do
			if room <= 0 or not invite then
				break
			end
			local entry = private.invites[name]
			if not entry.sent or (now - entry.sent >= INVITE_AGAIN_SECONDS and entry.tries < 2) then
				invite(name)
				if entry.tries == 0 then
					Wanted:Print("Inviting %s to %s.", name, raid.title)
				end
				entry.sent, entry.tries = now, entry.tries + 1
				room = room - 1
			end
		end
	end
	if not private.pumpScheduled then
		private.pumpScheduled = true
		C_Timer.After(INVITE_ROUND_SECONDS, function()
			private.pumpScheduled = false
			private.PumpInvites()
		end)
	end
end

---The game's line for a declined invite, or one to a player already in a group, as a pattern catching the name: nil
---when this client hasn't the string.
function private.SystemPattern(global)
	local text = _G[global]
	if type(text) ~= "string" then
		return nil
	end
	local before, after = strmatch(text, "^(.-)%%s(.*)$")
	if not before then
		return nil
	end
	local function Plain(part)
		return (gsub(part, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
	end
	return "^"..Plain(before).."(.+)"..Plain(after).."$"
end

---A system message: a player declined our invite, or is in another group. They leave the invite line at once
---instead of holding a place for a minute and being invited again.
---@param text string
function Raids:OnSystem(text)
	if type(text) ~= "string" or not next(private.invites) then
		return
	end
	for _, global in ipairs({ "ERR_DECLINE_GROUP_S", "ERR_ALREADY_IN_GROUP_S" }) do
		local pattern = private.SystemPattern(global)
		local name = pattern and strmatch(text, pattern)
		if name then
			for i, queued in ipairs(private.inviteOrder) do
				if private.SameName(queued, name) then
					Wanted:Print("%s %s.", queued, global == "ERR_DECLINE_GROUP_S" and "declined the invite" or "is in another group")
					private.Done(queued)
					tremove(private.inviteOrder, i)
					private.PumpInvites()
					return
				end
			end
		end
	end
end

---A player's done with the invite line (in, or given up on): off it, and off the raid's whispered sign-ups.
function private.Done(name)
	private.invites[name] = nil
	local raid = private.mine
	if raid and raid.whispered then
		raid.whispered[name] = nil
	end
end

---The players waiting for an invite to the raid we lead, or already invited and not in yet: their names, in order.
---@return string[]
function Raids:Inviting()
	local out = {}
	for _, name in ipairs(private.inviteOrder) do
		tinsert(out, name)
	end
	return out
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
	private.QueueWhispered(raid)
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
	for _, list in ipairs({ going, interested }) do
		for _, name in ipairs(list) do
			private.QueueInvite(name)
		end
	end
	return nil
end

---The raid's ad, shared with every Wanted player of our faction.
function private.SendAd(closed)
	local raid = private.mine
	if not raid then
		return
	end
	-- The leader as the id names them (our name could be corrected after the raid was formed)
	Sync:SendRaidAd({ id = raid.id, l = strmatch(raid.id, "^(.*):%d+:%d+$") or Store:GetOrigin(), t = raid.title, g = raid.guild, x = raid.exclusive and 1 or nil, e = raid.edits, z = raid.where, s = raid.startAt, m = raid.size,
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
			-- At the start, those who signed up by whispering (no Wanted to ask for themselves) are invited
			-- (kept with the raid until they're in or given up on, so a /reload doesn't lose them)
			if private.Started(raid) and raid.whispered then
				private.QueueWhispered(raid)
			end
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
---Returns true when it was taken (a closed one too), for Sync to share it on.
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
	-- A raid's id starts with its leader's name, and a raid keeps its leader: nobody else's ad can stand for it
	if strsub(ad.id, 1, #ad.l + 1) ~= ad.l..":" then
		return
	end
	local known = private.seen[ad.id]
	if known and known.raid.leader ~= ad.l then
		return
	end
	-- Straight from a player, an ad must be their own raid's. One shared on by a realm link (fw) can list a raid, but
	-- for one heard straight from its leader it only says it's still about: it can't change or close it
	local direct = not ad.fw
	if direct and not private.SameName(sender, ad.l) then
		return
	end
	-- A shared-on copy lists a raid led on another realm name (the one who shared it heard its leader there). One
	-- naming a leader of this realm is taken only for a raid heard from that leader: anyone could otherwise list a
	-- raid under any name here, and joiners would whisper that player
	if not direct and not (known and known.direct) and not private.OtherRealm(ad.l) then
		return
	end
	local now = GetServerTime()
	local heardDirect = known and known.direct and now - known.direct < DIRECT_SECONDS
	if not direct and heardDirect then
		if not ad.c then
			known.heard = now
		end
		return
	end
	-- An ad from before the leader's latest edit (delayed, or shared on late) changes nothing; a close always counts.
	-- Only the leader's own ads count edits (a shared-on copy can't raise them), and only while we hear the leader
	-- (a leader whose client lost its count to a crash is taken up again a couple of minutes on)
	local edits = max(0, min(MAX_EDITS, floor(tonumber(ad.e) or 0)))
	if direct and heardDirect and not ad.c and edits < (known.raid.edits or 0) then
		return
	end
	if not direct then
		edits = known and known.raid.edits or 0
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
		return true
	end
	if ad.x and (channel ~= "GUILD" or ad.g ~= GetGuildInfo("player")) then
		return
	end
	local faction = UnitFactionGroup("player")
	local size, startAt = tonumber(ad.m), tonumber(ad.s)
	-- A start no raid can have (further ahead than one can be planned, or long past) is nonsense: a far-off one would
	-- be listed for good, and a huge number throws in date()
	if ad.f ~= faction or not SIZES[size] or not startAt or startAt ~= startAt or startAt > now + PLAN_AHEAD_SECONDS or startAt < now - AD_PAST_SECONDS then
		return
	end
	local entry = private.seen[ad.id]
	if not entry then
		if private.CountLed(ad.l) >= MAX_SEEN_PER_LEADER then
			return
		end
		-- Full: the raid furthest off (or, of those starting together, the one heard longest ago) makes room, so a
		-- list filled with far-off ads can't keep a raid forming now off it
		if private.Count(private.seen) >= MAX_SEEN then
			private.Evict()
		end
		entry = {}
		private.seen[ad.id] = entry
	end
	entry.heard = GetServerTime()
	-- When we last heard it straight from its leader (copies shared on can't change it for a while after)
	if direct then
		entry.direct = now
	end
	entry.raid = {
		id = ad.id, leader = ad.l, title = private.Clean(ad.t), guild = private.Clean(ad.g) ~= "" and private.Clean(ad.g) or nil, where = private.Clean(ad.z), startAt = startAt, size = size,
		minLevel = max(1, min(60, floor(tonumber(ad.ml) or 1))), members = max(0, min(size, floor(tonumber(ad.n) or 0))),
		signups = max(0, min(99, floor(tonumber(ad.u) or 0))), interested = max(0, min(99, floor(tonumber(ad.i) or 0))),
		edits = edits,
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
	return true
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
	if now.startAt ~= was.startAt then
		-- A new time: the reminder and the popup come again at it
		private.reminded[raid.id..":soon"], private.reminded[raid.id..":start"] = nil, nil
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
				-- Until we're in the leader's group
				if not private.InGroup(j.leader) then
					Sync:SendRaidJoin(j.leader, id)
				end
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
---seconds), or nil; with day (1 to 6), that many days from today at that time.
---@param text string
---@param server boolean?
---@return number?
function Raids:ParseTime(text, server, day)
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
	-- isdst left to the calendar: a day across a clock change still lands on the hour typed
	t.hour, t.min, t.sec, t.isdst = h, m, 0, nil
	if day and day > 0 then
		-- That many days on, at that time
		t.day = t.day + day
		return time(t) - offset
	end
	local at = time(t) - offset
	if at <= now then
		-- Tomorrow at that time, by the calendar rather than 24 hours on
		t.day = t.day + 1
		at = time(t) - offset
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

---A time formatted with date(), or "?" for one date() can't format: the game's Lua gives nil for a time out of its
---range, and newer ones throw, so a number from another client never gets that far unguarded.
local function Clock(fmt, t)
	local ok, text = pcall(date, fmt, t)
	return ok and type(text) == "string" and text or "?"
end

---A raid's start as shown here: our own time with our time zone ("Thu 20:00 EDT"), and the realm's beside it when it
---differs ("Thu 20:00 EDT (server 23:00)").
---@param t number
---@return string
function Raids:When(t)
	local offset = Raids:ServerOffset()
	local ours = Clock("%a %H:%M", t).." "..Raids:ZoneName()
	if offset == 0 then
		return ours
	end
	return format("%s (server %s)", ours, Clock("%H:%M", t + offset))
end

---A start in the realm's time for chat lines, which every reader shares, with its day unless it's today on the realm:
---"at 23:00 server time", "Thu at 23:00 server time".
---@param t number
---@return string
function Raids:ServerWhen(t)
	local offset = Raids:ServerOffset()
	local today = Clock("%Y%m%d", GetServerTime() + offset) == Clock("%Y%m%d", t + offset)
	return (today and "" or Clock("%a ", t + offset)).."at "..Raids:ServerClock(t)
end

---A start in the realm's time, for chat lines, which every reader shares: "23:00 server time".
---@param t number
---@return string
function Raids:ServerClock(t)
	return Clock("%H:%M", t + Raids:ServerOffset()).." server time"
end

-- ============================================================================
-- Helpers
-- ============================================================================

---Whether two names are the same player: the same, or the same first part when one has no realm.
function private.SameName(a, b)
	if type(a) ~= "string" or type(b) ~= "string" then
		return false
	end
	if a == b then
		return true
	end
	local aName, aRealm = strmatch(a, "^([^%-]+)%-?(.*)$")
	local bName, bRealm = strmatch(b, "^([^%-]+)%-?(.*)$")
	return aName == bName and (aRealm == "" or bRealm == "")
end

---Whether a name is a player's on another realm name: it carries a realm, and not ours. Players of this realm name
---are named without one, as the game stamps senders here.
function private.OtherRealm(name)
	local realm = type(name) == "string" and strmatch(name, "^[^%-]+%-(.+)$") or nil
	if not realm then
		return false
	end
	local ours = GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName and GetRealmName() or ""
	return gsub(realm, "[%s%-]", "") ~= gsub(ours, "[%s%-]", "")
end

---How many raids seen are under a leader's name.
function private.CountLed(leader)
	local n = 0
	for _, entry in pairs(private.seen) do
		if entry.raid and entry.raid.leader == leader then
			n = n + 1
		end
	end
	return n
end

---Drops the raid seen that's least worth a place: the one starting furthest off, or of those starting at the same
---time, the one heard longest ago.
function private.Evict()
	local worst, worstId
	for id, entry in pairs(private.seen) do
		if entry.raid and (not worst or entry.raid.startAt > worst.raid.startAt
			or (entry.raid.startAt == worst.raid.startAt and entry.heard < worst.heard)) then
			worst, worstId = entry, id
		end
	end
	if worstId then
		private.seen[worstId] = nil
		private.viewed[worstId] = nil
	end
end

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
