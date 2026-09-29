-- Wanted: guild ranks, for guild mode on Discord. wanteddeadordead.com lets a guild's Discord server show its members'
-- fights and defence calls only when one of the guild's officers connects it, proven from the game: each of this
-- account's characters notes its own guild and rank (guildRanks), and what its guild's roster says about who holds an
-- officer rank (guildOfficers: officers only, a plain member's rank is never kept). The desktop app sends both to the
-- website, which uses them for that check alone and never shows them.

local _, Wanted = ...
local GuildRank = Wanted:NewModule("GuildRank")
local private = {}

-- The roster is read at most this often
GuildRank.ROSTER_SECONDS = 600
-- A guild's officers book not read again for this long goes (a guild this account's characters left)
GuildRank.KEEP_SECONDS = 30 * 86400

function GuildRank:OnLoad()
	local db = Wanted.db
	db.guildRanks = db.guildRanks or {} -- guid -> { g = guild or "", rn = rank name, ri = rank index (0 = guild master), o = officer, t } this account's characters
	db.guildOfficers = db.guildOfficers or {} -- guild -> { t, m = { [guid] = rank index } } the members at officer ranks
	private.Prune(db.guildOfficers, GetServerTime())
end

function GuildRank:OnEnable()
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("PLAYER_GUILD_UPDATE")
	frame:RegisterEvent("GUILD_ROSTER_UPDATE")
	frame:SetScript("OnEvent", function(_, event)
		GuildRank:NoteOwn()
		if event == "GUILD_ROSTER_UPDATE" then
			GuildRank:ReadRoster()
		end
	end)
	GuildRank:NoteOwn()
	-- Asks the server for the roster; its GUILD_ROSTER_UPDATE reads it
	if C_GuildInfo and C_GuildInfo.GuildRoster then
		pcall(C_GuildInfo.GuildRoster)
	end
end

local function secret(value)
	return issecretvalue and issecretvalue(value) or false
end

---Notes the logged-in character's guild and rank, when they changed and the game let us read them.
function GuildRank:NoteOwn()
	local guid = UnitGUID("player")
	if type(guid) ~= "string" or secret(guid) then
		return
	end
	local rank = private.OwnRank()
	if not rank then
		return
	end
	local old = Wanted.db.guildRanks[guid]
	if old and old.g == rank.g and old.rn == rank.rn and old.ri == rank.ri and old.o == rank.o then
		return
	end
	rank.t = GetServerTime()
	Wanted.db.guildRanks[guid] = rank
	Wanted:Log("GuildRank: <%s> %s (%d)%s", rank.g, rank.rn, rank.ri, rank.o and ", officer" or "")
end

---The character's guild and rank; nil while the game hasn't loaded its guild yet, or for a value it keeps secret.
---Out of a guild, the guild is "".
function private.OwnRank()
	if not IsInGuild or not GetGuildInfo then
		return nil
	end
	local inGuild = IsInGuild()
	if secret(inGuild) then
		return nil
	end
	if not inGuild then
		return { g = "", rn = "", ri = -1, o = false }
	end
	local ok, guild, rankName, rankIndex = pcall(GetGuildInfo, "player")
	if not ok or secret(guild) or secret(rankName) or secret(rankIndex) or type(guild) ~= "string" or guild == ""
		or type(rankName) ~= "string" or type(rankIndex) ~= "number" then
		return nil
	end
	local officer = private.IsOfficer()
	if officer == nil then
		return nil
	end
	return { g = guild, rn = rankName, ri = rankIndex, o = officer }
end

---Whether the character is its guild's leader or an officer, as the game's own guild window counts them; nil when
---the game won't say.
function private.IsOfficer()
	local officer = false
	for _, ask in ipairs({ IsGuildLeader or false, C_GuildInfo and C_GuildInfo.IsGuildOfficer or false }) do
		if ask then
			local ok, yes = pcall(ask)
			if not ok or secret(yes) then
				return nil
			end
			officer = officer or yes == true
		end
	end
	return officer
end

---Reads the guild roster, at most once every ROSTER_SECONDS, and keeps the members at officer ranks: the guild
---master's, and this character's own when the game says it's an officer's.
function GuildRank:ReadRoster()
	local now = GetServerTime()
	if now - (private.rosterRead or 0) < GuildRank.ROSTER_SECONDS then
		return
	end
	local own = Wanted.db.guildRanks[UnitGUID("player")]
	if not own or own.g == "" then
		return
	end
	local members = private.Roster()
	if not members then
		return
	end
	private.rosterRead = now
	local officerRanks = { [0] = true }
	if own.o then
		officerRanks[own.ri] = true
	end
	local book, count = {}, 0
	for _, member in ipairs(members) do
		if officerRanks[member.ri] then
			book[member.guid] = member.ri
			count = count + 1
		end
	end
	Wanted.db.guildOfficers[own.g] = { t = now, m = book }
	Wanted:Log("GuildRank: %d of %d members of <%s> at officer ranks", count, #members, own.g)
end

---The guild's members as the game's guild window reads them (its club): each one's GUID and rank index (0 = the
---guild master); nil when the game won't say. Members whose values are secret are left out.
function private.Roster()
	if not (C_Club and C_Club.GetGuildClubId and C_Club.GetClubMembers and C_Club.GetMemberInfo) then
		return nil
	end
	local ok, club = pcall(C_Club.GetGuildClubId)
	if not ok or club == nil or secret(club) then
		return nil
	end
	local got, ids = pcall(C_Club.GetClubMembers, club)
	if not got or type(ids) ~= "table" or (issecrettable and issecrettable(ids)) then
		return nil
	end
	local out = {}
	for _, id in ipairs(ids) do
		local fine, info = pcall(C_Club.GetMemberInfo, club, id)
		if fine and type(info) == "table" and not (issecrettable and issecrettable(info)) then
			local guid, order = info.guid, info.guildRankOrder
			if type(guid) == "string" and not secret(guid) and strfind(guid, "^Player%-") and type(order) == "number" and not secret(order) then
				out[#out + 1] = { guid = guid, ri = order - 1 }
			end
		end
	end
	return out
end

---Drops officers books not read for KEEP_SECONDS.
function private.Prune(book, now)
	for guild, entry in pairs(book) do
		if type(entry) ~= "table" or type(entry.t) ~= "number" or now - entry.t > GuildRank.KEEP_SECONDS then
			book[guild] = nil
		end
	end
end
