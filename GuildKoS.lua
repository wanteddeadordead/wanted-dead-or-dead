-- Wanted: Guild Kill on Sight. A Kill on Sight list a guild keeps together, beside each player's own. Its settings
-- (on or off, who may change the list, Discord sightings) and its entries (a player, or a whole guild) go to the
-- guildmates online over a hidden guild addon channel as soon as they change, and a member logging in asks for them.
-- Every member's addon checks each change against its sender's guild rank in the game's own roster before taking it,
-- so a modified addon can't approve its own entry or change the settings without an officer's rank.
--
-- Who may do what (the guild's mode):
--   review: any member adds a name as pending; officers approve or deny it, and remove names
--   rank:   members at the chosen rank or above add and remove
--   open:   any member adds and removes
-- Officers are the ranks the game lets listen to officer chat (GuildRank:OfficerRanks). Only officers change the
-- settings. The list is the guild's own: it never goes on the sync channel, to realm links or to the website.

local _, Wanted = ...
local GuildKoS = Wanted:NewModule("GuildKoS")
local Sync = Wanted.Sync
local private = {
	frame = nil,
	msgCounter = 0,
	partial = {}, -- sender..":"..msgId -> { parts = {}, total, t }
	queue = {}, -- messages waiting to go: texts
	sending = false,
	answerAt = nil, -- when we'll answer a member's request for the list, unless someone answers first
	answerSince = nil, -- the oldest "newest change" among the asks we'll answer: the list sends what's newer
	askedAt = nil, -- when we asked for the list: a list is only taken in answer to our own ask
	members = nil, -- name -> rank index, from the roster, read at most every MEMBERS_SECONDS
	membersAt = 0,
}

local PREFIX = "WNTDK"
local TAG_EDIT, TAG_SETTINGS, TAG_ASK, TAG_LIST = "E", "S", "Q", "L"
GuildKoS.MODES = { "review", "rank", "open" }
local MODE_OK = { review = true, rank = true, open = true }
local STATES = { pending = true, approved = true, denied = true, removed = true }
local MAX_ENTRIES = 300
local MAX_REASON = 120
local MAX_NAME = 48
local PART_LEN = 230 -- a guild addon message holds 255 bytes; the rest is the "id:part/total:" header
local MAX_PARTS = 60
local PART_TIMEOUT = 30
local MAX_PARTIAL = 4 -- unfinished messages held per sender; past it their oldest goes
local SEND_SPACING = 0.3
local MEMBERS_SECONDS = 30
local ASK_DELAY = 12 -- after login, once the guild roster has come
local ANSWER_DELAY_MAX = 4 -- the members asked wait a moment, so usually only one answers
local ASK_ANSWER_SECONDS = 60 -- how long after asking a list is taken
local KEEP_SECONDS = 30 * 24 * 60 * 60 -- denied and removed entries are forgotten after this, so a late copy can't return them
local MAX_AHEAD = 5 * 60 -- a change dated further ahead of the server's clock is refused: no real change after it could replace it

-- ============================================================================
-- Data
-- ============================================================================

function GuildKoS:OnLoad()
	-- faction..":"..lower(guild) -> { settings = { enabled, mode, rank, discord, t, by }, entries = { [id] = entry } }
	Wanted.db.guildKos = type(Wanted.db.guildKos) == "table" and Wanted.db.guildKos or {}
	local now = GetServerTime()
	for _, book in pairs(Wanted.db.guildKos) do
		if type(book) == "table" and type(book.entries) == "table" then
			for id, e in pairs(book.entries) do
				if type(e) ~= "table" or ((e.state == "denied" or e.state == "removed") and now - (e.t or 0) > KEEP_SECONDS) then
					book.entries[id] = nil
				end
			end
		end
	end
end

---The default settings: off, review mode, rank mode's line at the officers.
function GuildKoS:DefaultSettings()
	return { enabled = false, mode = "review", rank = 1, discord = false, t = 0, by = "" }
end

---This character's guild and faction, or nil out of a guild.
function private.OwnGuild()
	if not IsInGuild or not IsInGuild() then
		return nil
	end
	local ok, guild, _, rankIndex = pcall(GetGuildInfo, "player")
	if not ok or type(guild) ~= "string" or guild == "" then
		return nil
	end
	return guild, UnitFactionGroup("player") or "", rankIndex
end

---The book for a guild (made if missing): its settings and entries.
function private.Book(guild, faction)
	local key = faction..":"..strlower(guild)
	local book = Wanted.db.guildKos[key]
	if type(book) ~= "table" then
		book = { guild = guild, settings = GuildKoS:DefaultSettings(), entries = {} }
		Wanted.db.guildKos[key] = book
	end
	book.guild = guild
	return book
end

---This character's guild's book, or nil out of a guild.
function GuildKoS:Current()
	local guild, faction = private.OwnGuild()
	return guild and private.Book(guild, faction) or nil
end

---An entry's id: one per target.
function GuildKoS.EntryId(kind, target)
	return (kind == "guild" and "g:" or "p:")..strlower(target)
end

-- ============================================================================
-- Who may do what
-- ============================================================================

---Whether an action is allowed: "settings", "add", "approve", "deny" or "remove".
---@param action string
---@param settings table the guild's settings
---@param actorRank number? the actor's rank index (0 = the guild master)
---@param officers table rank index -> true
---@param entry table? the entry acted on (for removing one's own pending entry)
---@param actor string? the actor's name
---@return boolean
function GuildKoS.Allowed(action, settings, actorRank, officers, entry, actor)
	if type(actorRank) ~= "number" or type(settings) ~= "table" then
		return false
	end
	local officer = officers[actorRank] == true
	if action == "settings" or action == "approve" or action == "deny" then
		return officer
	end
	local mode = MODE_OK[settings.mode] and settings.mode or "review"
	local ranked = officer or actorRank <= (tonumber(settings.rank) or 0)
	if action == "add" then
		return mode ~= "rank" or ranked
	elseif action == "remove" then
		if mode == "open" then
			return true
		elseif mode == "rank" then
			return ranked
		end
		-- Review: officers remove; a member can take back their own entry while it's pending
		return officer or (entry ~= nil and entry.state == "pending" and entry.by == actor)
	end
	return false
end

---The state a new entry starts in: pending in review mode unless an officer adds it, approved otherwise.
function GuildKoS.NewState(settings, actorRank, officers)
	if settings.mode == "review" and not officers[actorRank] then
		return "pending"
	end
	return "approved"
end

---Rank indexes by member name, from the roster (read at most every MEMBERS_SECONDS).
function private.Members()
	if not private.members or GetTime() - private.membersAt >= MEMBERS_SECONDS then
		local list = Wanted.GuildRank and Wanted.GuildRank:Members()
		if list then
			local byName = {}
			for _, m in ipairs(list) do
				if m.name then
					byName[Ambiguate(m.name, "none")] = m.ri
				end
			end
			private.members, private.membersAt = byName, GetTime()
		end
	end
	return private.members or {}
end

---A guildmate's rank index by name, or nil if the roster doesn't have them.
function GuildKoS:RankOf(name)
	if type(name) ~= "string" then
		return nil
	end
	return private.Members()[Ambiguate(name, "none")]
end

---This character's rank index in its guild.
function private.OwnRank()
	local _, _, rankIndex = private.OwnGuild()
	return rankIndex
end

---Whether this character may do an action on its guild's list now.
function GuildKoS:Can(action, entry)
	local book = GuildKoS:Current()
	if not book then
		return false
	end
	return GuildKoS.Allowed(action, book.settings, private.OwnRank(), Wanted.GuildRank:OfficerRanks(), entry, private.Me())
end

---This character's name as guildmates see it on messages: on WoW Forever a name and a surname, which UnitName gives
---apart (the store joins them).
function private.Me()
	return Ambiguate(Wanted.Store:GetOrigin() or "", "none")
end

-- ============================================================================
-- Checking what arrives
-- ============================================================================

local function cleanText(value, maxLen)
	if type(value) ~= "string" then
		return nil
	end
	local text = strtrim((gsub(value, "|", "")))
	if text == "" then
		return nil
	end
	return strsub(text, 1, maxLen)
end

---Whether a change's time is a number no further ahead of the server's clock than MAX_AHEAD.
function private.Dated(t)
	return type(t) == "number" and t <= GetServerTime() + MAX_AHEAD
end

---An entry from a message, cleaned, or nil if it's malformed.
function GuildKoS.CleanEntry(e)
	if type(e) ~= "table" then
		return nil
	end
	local kind = e.kind == "guild" and "guild" or (e.kind == "player" and "player") or nil
	local name = cleanText(e.name, MAX_NAME)
	local by = cleanText(e.by, MAX_NAME)
	local eby = cleanText(e.eby, MAX_NAME)
	if not kind or not name or not by or not eby or not STATES[e.state] or not private.Dated(e.t) or not private.Dated(e.at) then
		return nil
	end
	local guid = kind == "player" and type(e.guid) == "string" and strfind(e.guid, "^Player%-%d+%-%x+$") and e.guid or nil
	if kind == "player" and not guid then
		return nil
	end
	return {
		kind = kind, guid = guid, name = name, reason = cleanText(e.reason, MAX_REASON), state = e.state,
		by = by, at = e.at, dby = cleanText(e.dby, MAX_NAME), eby = eby, t = e.t,
	}
end

---The id of a cleaned entry.
function private.IdOf(e)
	return GuildKoS.EntryId(e.kind, e.kind == "player" and e.guid or e.name)
end

---The action a change to an entry amounts to, from what we hold: "add", "approve", "deny" or "remove".
function private.ActionOf(book, held, e, rank, officers)
	if e.state == "denied" then
		return "deny"
	elseif e.state == "removed" then
		return "remove"
	elseif e.state == "approved" then
		if held and held.state == "pending" then
			return "approve"
		elseif held and held.state == "approved" then
			return "add" -- the reason changed
		end
		-- New (or back after a denial or removal) and approved at once: an officer adding it, or anyone in open or rank
		-- mode; a member in review mode can't
		return GuildKoS.NewState(book.settings, rank, officers) == "approved" and "add" or "approve"
	end
	-- Pending: an approved entry sent back as pending takes it off the list (officers only in review mode), or a
	-- member could resend it as their own and then take that back
	if held and held.state == "approved" then
		return "remove"
	end
	return "add"
end

---Takes an entry change, if it's newer than what we hold and the guildmate it's judged by may make it. Returns
---whether it was taken.
---@param book table
---@param raw table the entry as it came
---@param sender string who sent it: for a live change it must be the editor (eby, who made this change)
---@param officers table rank index -> true
---@param relayed boolean? an entry in a list: judged by its sender's own rank, not by the editor it names (a name the
---sender writes), so a member's list can't approve or remove in an officer's name
function GuildKoS:TakeEntry(book, raw, sender, officers, relayed)
	local e = GuildKoS.CleanEntry(raw)
	if not e or type(sender) ~= "string" or (not relayed and e.eby ~= sender) then
		return false
	end
	local id = private.IdOf(e)
	local held = book.entries[id]
	if held and held.t >= e.t then
		return false
	end
	local rank = GuildKoS:RankOf(sender)
	local action = private.ActionOf(book, held, e, rank, officers)
	if not GuildKoS.Allowed(action, book.settings, rank, officers, held, sender) then
		Wanted:Log("!! GuildKoS: %s may not %s %s; ignored", sender, action, e.name)
		return false
	end
	if not held and private.Count(book.entries) >= MAX_ENTRIES then
		return false
	end
	if held and (held.state == "approved" or held.state == "pending") then
		-- An edit of a name on the list: who added it and when stay as they were
		e.by, e.at = held.by, held.at
	end
	book.entries[id] = e
	return true
end

---Takes settings from a guildmate, if they're newer and the guildmate is an officer.
function GuildKoS:TakeSettings(book, raw, actor, officers)
	if type(raw) ~= "table" or not private.Dated(raw.t) or raw.t <= (book.settings.t or 0) then
		return false
	end
	if not GuildKoS.Allowed("settings", book.settings, GuildKoS:RankOf(actor), officers) then
		Wanted:Log("!! GuildKoS: %s may not change the settings; ignored", tostring(actor))
		return false
	end
	book.settings = {
		enabled = raw.enabled == true, mode = MODE_OK[raw.mode] and raw.mode or "review",
		rank = type(raw.rank) == "number" and max(0, min(floor(raw.rank), 20)) or 1, discord = raw.discord == true,
		t = raw.t, by = cleanText(raw.by, MAX_NAME) or actor,
	}
	return true
end

function private.Count(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

---Takes the guilds' lists the app brought from wanteddeadordead.com (the catch-up's guildKos: a list of
---{ guild, settings, entries }). The server only keeps changes members' own apps made at a rank that allows them, so
---whatever is newer than ours is taken as it is; that fills in what happened while nobody was online to tell us.
---@param list table?
function GuildKoS:TakeServer(list)
	if type(list) ~= "table" then
		return
	end
	local faction = UnitFactionGroup("player") or ""
	local changed = 0
	for _, raw in ipairs(list) do
		local guild = type(raw) == "table" and cleanText(raw.guild, MAX_NAME)
		if guild then
			local book = private.Book(guild, faction)
			local s = raw.settings
			if type(s) == "table" and private.Dated(s.t) and s.t > (book.settings.t or 0) then
				book.settings = {
					enabled = s.enabled == true, mode = MODE_OK[s.mode] and s.mode or "review",
					rank = type(s.rank) == "number" and max(0, min(floor(s.rank), 20)) or 1, discord = s.discord == true,
					t = s.t, by = cleanText(s.by, MAX_NAME) or "",
				}
				changed = changed + 1
			end
			for _, e in ipairs(type(raw.entries) == "table" and raw.entries or {}) do
				local clean = GuildKoS.CleanEntry(e)
				if clean then
					local id = private.IdOf(clean)
					local held = book.entries[id]
					if (not held or clean.t > held.t) and (held or private.Count(book.entries) < MAX_ENTRIES) then
						book.entries[id] = clean
						changed = changed + 1
					end
				end
			end
		end
	end
	if changed > 0 then
		Wanted:Log("GuildKoS: %d changes from the server", changed)
		private.Changed()
	end
end

-- ============================================================================
-- Changes made here
-- ============================================================================

---Adds a player or a whole guild to this guild's list (pending in review mode for a member). Returns the entry, or
---nil and why not.
---@param kind string "player" or "guild"
---@param name string the player's or guild's name
---@param guid string? the player's GUID
---@param reason string?
function GuildKoS:Add(kind, name, guid, reason)
	local book = GuildKoS:Current()
	if not book or not book.settings.enabled then
		return nil, "Guild Kill on Sight is off for your guild."
	end
	if not GuildKoS:Can("add") then
		return nil, "Your rank can't add to your guild's Kill on Sight."
	end
	local now = GetServerTime()
	local officers = Wanted.GuildRank:OfficerRanks()
	local state = GuildKoS.NewState(book.settings, private.OwnRank(), officers)
	local e = GuildKoS.CleanEntry({ kind = kind, guid = guid, name = name, reason = reason, state = state, by = private.Me(), at = now,
		dby = state == "approved" and private.Me() or nil, eby = private.Me(), t = now })
	if not e then
		return nil, "That isn't a player or guild Wanted can add."
	end
	book.entries[private.IdOf(e)] = e
	private.Broadcast(TAG_EDIT, { e = e })
	private.Changed()
	return e
end

---Approves, denies or removes an entry by id. Returns whether it was done, and why not.
---@param id string
---@param action string "approve", "deny" or "remove"
function GuildKoS:Decide(id, action)
	local book = GuildKoS:Current()
	local held = book and book.entries[id]
	if not held then
		return false, "That entry isn't on the list."
	end
	if not GuildKoS:Can(action, held) then
		return false, "Your rank can't do that."
	end
	local now = GetServerTime()
	local e = {}
	for k, v in pairs(held) do
		e[k] = v
	end
	e.state = action == "approve" and "approved" or (action == "deny" and "denied" or "removed")
	if action ~= "remove" then
		e.dby = private.Me()
	end
	e.eby = private.Me()
	e.id = nil
	e.t = max(now, held.t + 1)
	book.entries[id] = e
	private.Broadcast(TAG_EDIT, { e = e })
	private.Changed()
	return true
end

---Changes this guild's settings (officers only). Returns whether it was done.
---@param changes table any of enabled, mode, rank, discord
function GuildKoS:SetSettings(changes)
	local book = GuildKoS:Current()
	if not book or not GuildKoS:Can("settings") then
		return false
	end
	local s = book.settings
	local new = { enabled = s.enabled, mode = s.mode, rank = s.rank, discord = s.discord }
	for k, v in pairs(changes) do
		new[k] = v
	end
	new.t, new.by = max(GetServerTime(), (s.t or 0) + 1), private.Me()
	new.mode = MODE_OK[new.mode] and new.mode or "review"
	book.settings = new
	private.Broadcast(TAG_SETTINGS, { s = new })
	private.Changed()
	return true
end

-- ============================================================================
-- Who is on it
-- ============================================================================

---The approved entry that makes an enemy Kill on Sight for this guild (their own, or their guild's), or nil.
---@param guid string?
---@param guild string? the enemy's guild
function GuildKoS:Match(guid, guild)
	local book = GuildKoS:Current()
	if not book or not book.settings.enabled then
		return nil
	end
	local e = guid and book.entries[GuildKoS.EntryId("player", guid)]
	if e and e.state == "approved" then
		return e
	end
	e = type(guild) == "string" and guild ~= "" and book.entries[GuildKoS.EntryId("guild", guild)]
	if e and e.state == "approved" then
		return e
	end
	return nil
end

---This guild's entries in a state ("approved", "pending", ...), newest first; all live ones (approved and pending)
---when state is nil.
function GuildKoS:Entries(state)
	local book = GuildKoS:Current()
	local out = {}
	if not book then
		return out
	end
	for id, e in pairs(book.entries) do
		if (state and e.state == state) or (not state and (e.state == "approved" or e.state == "pending")) then
			local copy = { id = id }
			for k, v in pairs(e) do
				copy[k] = v
			end
			tinsert(out, copy)
		end
	end
	sort(out, function(a, b) return a.t > b.t end)
	return out
end

-- ============================================================================
-- The guild channel
-- ============================================================================

function GuildKoS:OnEnable()
	C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
	private.frame = CreateFrame("Frame")
	private.frame:RegisterEvent("CHAT_MSG_ADDON")
	private.frame:SetScript("OnEvent", function(_, _, prefix, text, channel, sender)
		if prefix == PREFIX and channel == "GUILD" then
			private.OnMessage(text, sender)
		end
	end)
	C_Timer.After(ASK_DELAY, function() GuildKoS:Ask() end)
end

---Asks the guildmates online for the list (at login): the newest change we hold, so only someone with newer answers.
function GuildKoS:Ask()
	local book = GuildKoS:Current()
	if book then
		private.askedAt = GetTime()
		private.Broadcast(TAG_ASK, { n = private.Newest(book) })
	end
end

---The time of the newest change in a book.
function private.Newest(book)
	local newest = book.settings.t or 0
	for _, e in pairs(book.entries) do
		newest = max(newest, e.t or 0)
	end
	return newest
end

function private.Broadcast(tag, tbl)
	if not IsInGuild() then
		return
	end
	local payload = Sync:Encode(tbl)
	private.msgCounter = private.msgCounter + 1
	local id = format("%x", private.msgCounter % 0xffff)
	local total = ceil(#payload / PART_LEN)
	if total > MAX_PARTS then
		Wanted:Log("!! GuildKoS: a %s message of %d bytes is too big to send", tag, #payload)
		return
	end
	for i = 1, total do
		tinsert(private.queue, format("%s:%s:%d/%d:%s", tag, id, i, total, strsub(payload, (i - 1) * PART_LEN + 1, i * PART_LEN)))
	end
	private.Pump()
end

function private.Pump()
	if private.sending or #private.queue == 0 then
		return
	end
	private.sending = true
	local text = tremove(private.queue, 1)
	C_ChatInfo.SendAddonMessage(PREFIX, text, "GUILD")
	C_Timer.After(SEND_SPACING, function()
		private.sending = false
		private.Pump()
	end)
end

function private.OnMessage(text, sender)
	if Ambiguate(sender, "none") == private.Me() then
		return
	end
	local tag, id, part, total, chunk = strmatch(text, "^(%u):(%x+):(%d+)/(%d+):(.*)$")
	part, total = tonumber(part), tonumber(total)
	if not tag or not part or not total or total < 1 or total > MAX_PARTS or part > total then
		return
	end
	local key = sender..":"..id
	local now = GetTime()
	for k, p in pairs(private.partial) do
		if now - p.t > PART_TIMEOUT then
			private.partial[k] = nil
		end
	end
	local p = private.partial[key]
	if not p then
		-- A new message: a sender's unfinished ones are held a few at a time, so a flood of first parts can't pile up
		local prefix, count, oldest = sender..":", 0, nil
		for k, held in pairs(private.partial) do
			if strsub(k, 1, #prefix) == prefix then
				count = count + 1
				if not oldest or held.t < private.partial[oldest].t then
					oldest = k
				end
			end
		end
		if count >= MAX_PARTIAL then
			private.partial[oldest] = nil
		end
		p = { parts = {}, total = total, t = now }
		private.partial[key] = p
	end
	p.parts[part] = chunk
	for i = 1, total do
		if not p.parts[i] then
			return
		end
	end
	private.partial[key] = nil
	local tbl = Sync:Decode(table.concat(p.parts))
	if type(tbl) == "table" then
		private.Handle(tag, tbl, Ambiguate(sender, "none"))
	end
end

function private.Handle(tag, tbl, sender)
	local book = GuildKoS:Current()
	if not book or GuildKoS:RankOf(sender) == nil then
		return -- not a guildmate the roster knows
	end
	local officers = Wanted.GuildRank:OfficerRanks()
	if tag == TAG_EDIT then
		if GuildKoS:TakeEntry(book, tbl.e, sender, officers) then
			private.Changed()
		end
	elseif tag == TAG_SETTINGS then
		if GuildKoS:TakeSettings(book, tbl.s, sender, officers) then
			private.Changed()
		end
	elseif tag == TAG_ASK then
		-- Someone logged in: if we hold something newer, answer after a moment unless another member does first
		if type(tbl.n) == "number" and private.Newest(book) > tbl.n then
			private.answerSince = min(private.answerSince or tbl.n, tbl.n)
		end
		if type(tbl.n) == "number" and private.Newest(book) > tbl.n and not private.answerAt then
			private.answerAt = GetTime() + random() * ANSWER_DELAY_MAX
			C_Timer.After(private.answerAt - GetTime(), function()
				if private.answerAt then
					private.answerAt = nil
					private.SendList(book, private.answerSince or 0)
					private.answerSince = nil
				end
			end)
		end
	elseif tag == TAG_LIST then
		private.answerAt, private.answerSince = nil, nil -- someone answered; we needn't
		if not private.askedAt or GetTime() - private.askedAt > ASK_ANSWER_SECONDS then
			return -- a list nobody here asked for
		end
		-- A long list comes in several messages: each one keeps the door open for the next
		private.askedAt = GetTime()
		-- A list is judged by who sent it, as the roster ranks them, never by the names it carries: an officer's
		-- settings and decisions are taken; from anyone else only what they may change themselves (in review mode,
		-- pending entries)
		local changed = GuildKoS:TakeSettings(book, tbl.s, sender, officers)
		for _, raw in ipairs(type(tbl.l) == "table" and tbl.l or {}) do
			if GuildKoS:TakeEntry(book, raw, sender, officers, true) then
				changed = true
			end
		end
		if changed then
			private.Changed()
		end
	end
end

---Answers an ask with the settings and the entries changed after since (the asker's newest), oldest first, in as many
---messages as it takes: one message holds at most MAX_PARTS parts.
function private.SendList(book, since)
	local list = {}
	for _, e in pairs(book.entries) do
		if e.t > since then
			tinsert(list, e)
		end
	end
	sort(list, function(a, b) return a.t < b.t end)
	private.SendListPart(book.settings, list, 1, #list)
end

function private.SendListPart(settings, list, first, last)
	local part = {}
	for i = first, last do
		tinsert(part, list[i])
	end
	local tbl = { s = settings, l = part }
	if last > first and ceil(#Sync:Encode(tbl) / PART_LEN) > MAX_PARTS then
		local middle = floor((first + last) / 2)
		private.SendListPart(settings, list, first, middle)
		private.SendListPart(settings, list, middle + 1, last)
		return
	end
	private.Broadcast(TAG_LIST, tbl)
end

function private.Changed()
	if Wanted.UI and Wanted.UI.Refresh then
		Wanted.UI:Refresh()
	end
end
