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
	private.saved, private.joined, private.seen = saved, saved.joined, saved.seen
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
	mine.guild = raid.guild
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
	local guild = o.guild and GetGuildInfo("player") or nil
	if o.guild and not guild then
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

---Someone asks to join the raid we lead, or, before it starts, signs up for it: k = "g" going (and an older client's
---join, which has no k), "i" interested, "x" taken back.
---@param sender string
---@param tbl table { r = raid id, k = kind? }
function Raids:OnJoin(sender, tbl)
	local raid = private.mine
	if not raid or type(tbl) ~= "table" or tbl.r ~= raid.id or type(sender) ~= "string" then
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
	return format("%s starts %s in %s. See you there!", Raids:Title(raid), date("%a %H:%M", raid.startAt), raid.where)
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
		raid.title, date("%a %H:%M", raid.startAt))
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
	if now.startAt ~= was.startAt then
		tinsert(changes, format("%s (was %s)", date("%a %H:%M", now.startAt), date("%a %H:%M", was.startAt)))
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
			Wanted.Toast:Add({ kind = "RAID SOON", name = j.title, detail = "Starts at "..date("%H:%M", j.startAt).." with "..j.leader,
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
