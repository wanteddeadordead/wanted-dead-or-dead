-- Wanted: world PvP achievements, from wanteddeadordead.com through the desktop app's catch-up. Earned once and kept
-- for good, for fun: not a rank (Wanted's ranks are Blizzard's). The server works them out and names them, so a new
-- achievement needs no addon update. Kept in memory only: the catch-up brings them again at each login.

local _, Wanted = ...
local Achievements = Wanted:NewModule("Achievements")
local private = {
	defs = {}, -- id -> { id, name, text }, in the listed order through `order`
	order = {},
	held = {}, -- lower-case name -> { id, ... }
}
local MAX_DEFS = 50
local MAX_HOLDERS = 5000

---A short single-line string from the catch-up, or nil.
function private.Text(value, maxLength)
	if type(value) ~= "string" or value == "" then
		return nil
	end
	return (strsub(gsub(value, "[%c|]", ""), 1, maxLength))
end

---Takes in the catch-up's achievements: what each is (defs) and who holds which (held, by lower-case name). Missing
---or malformed parts leave none.
---@param defs table?
---@param held table?
function Achievements:Take(defs, held)
	private.defs, private.order, private.held = {}, {}, {}
	if type(defs) ~= "table" then
		return
	end
	for i = 1, min(#defs, MAX_DEFS) do
		local d = defs[i]
		local id = type(d) == "table" and private.Text(d.id, 40)
		local name = id and private.Text(d.name, 40)
		if name and not private.defs[id] then
			private.defs[id] = { id = id, name = name, text = private.Text(d.text, 200) or "" }
			tinsert(private.order, id)
		end
	end
	local holders = 0
	for name, ids in pairs(type(held) == "table" and held or {}) do
		if holders >= MAX_HOLDERS then
			break
		end
		if type(name) == "string" and type(ids) == "table" then
			local list = {}
			for _, id in ipairs(ids) do
				if private.defs[id] then
					tinsert(list, id)
				end
			end
			if #list > 0 then
				private.held[strlower(name)] = list
				holders = holders + 1
			end
		end
	end
	Wanted:Log("Achievements: %d kinds, %d players hold some", #private.order, holders)
end

---The achievements a player holds, by full name ("First Last", any case): their definitions, in the listed order.
---@param name string?
---@return table
function Achievements:Of(name)
	local out = {}
	for _, id in ipairs(type(name) == "string" and private.held[strlower(name)] or {}) do
		tinsert(out, private.defs[id])
	end
	return out
end

---This character's achievements.
---@return table
function Achievements:Mine()
	return Achievements:Of(Wanted.Store and Wanted.Store:GetOrigin() or UnitName("player"))
end

---Every achievement there is, in the listed order.
---@return table
function Achievements:All()
	local out = {}
	for _, id in ipairs(private.order) do
		tinsert(out, private.defs[id])
	end
	return out
end

---Achievements' names in a short line: "Headhunter, Witness", or the first few and "+2" past `most`.
---@param list table
---@param most number?
---@return string
function Achievements:Names(list, most)
	most = most or #list
	local names = {}
	for i = 1, min(#list, most) do
		tinsert(names, list[i].name)
	end
	if #list > most then
		tinsert(names, "+"..(#list - most))
	end
	return table.concat(names, ", ")
end



-- ============================================================================
-- Badge art, weekly medals and this week's boards
-- ============================================================================

local TEXTURE = "Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\badges"
local SHEET, CELL = 512, 64
-- Each badge's cell in Media/badges.tga: 64 px cells, 8 to a row from the top left (made by the private export script)
local CELLS = {
	["headhunter"] = 0, ["patron"] = 1, ["untouchable"] = 2, ["outlaw-catcher"] = 3, ["witness"] = 4,
	["hot-zone-regular"] = 5, ["bodyguard"] = 6, ["founding-hunter"] = 7,
	["top-killer:gold"] = 8, ["top-killer:silver"] = 9, ["top-killer:bronze"] = 10,
	["defender:gold"] = 11, ["defender:silver"] = 12, ["defender:bronze"] = 13,
	["weekly-challenger:gold"] = 14, ["weekly-challenger:silver"] = 15, ["weekly-challenger:bronze"] = 16,
	["bounty-hunter:gold"] = 17, ["bounty-hunter:silver"] = 18, ["bounty-hunter:bronze"] = 19,
	-- Playstyle badges (the site's; not sent to the addon yet) and the weekly all-three challenge badge
	["bully"] = 20, ["underdog"] = 21, ["lone-wolf"] = 22, ["duo"] = 23, ["gang"] = 24, ["serial"] = 25, ["camper"] = 26,
	["field-medic"] = 27, ["all-three"] = 28,
}
-- The weekly boards, in the order they're shown, and the medals' metals by place
Achievements.BOARDS = {
	{ id = "top-killer", name = "Top Killer", unit = "kills" },
	{ id = "defender", name = "Defender", unit = "kills" },
	{ id = "weekly-challenger", name = "Weekly Challenger", unit = "points" },
	{ id = "bounty-hunter", name = "Bounty Hunter", unit = "bounties" },
}
local BOARD_NAMES = {}
for _, b in ipairs(Achievements.BOARDS) do
	BOARD_NAMES[b.id] = b.name
end
local METAL_ORDER = { gold = 1, silver = 2, bronze = 3 }
-- The playstyle badges the site gives (how a player kills this season; they can come and go), by name, as their art
local PLAYSTYLES = {
	["Bully"] = "bully", ["Underdog"] = "underdog", ["Lone Wolf"] = "lone-wolf", ["Duo"] = "duo", ["Gang"] = "gang",
	["Serial"] = "serial", ["Camper"] = "camper", ["Field Medic"] = "field-medic",
}
local MAX_BOARD_LINES = 25

---A badge's art: the texture and its coordinates (left, right, top, bottom), or nil for a badge with none. key is an
---achievement's id, or a medal's "board:metal".
---@param key string
---@return string? texture
---@return number? left
---@return number? right
---@return number? top
---@return number? bottom
function Achievements:Icon(key)
	local cell = CELLS[key]
	if not cell then
		return nil
	end
	local col, row = cell % 8, floor(cell / 8)
	return TEXTURE, col * CELL / SHEET, (col + 1) * CELL / SHEET, row * CELL / SHEET, (row + 1) * CELL / SHEET
end

---A badge's art as inline text for tooltips and lines: "|T...|t", or "" for a badge with none.
---@param key string
---@param size number? pixels, default 20
---@return string
function Achievements:IconText(key, size)
	local cell = CELLS[key]
	if not cell then
		return ""
	end
	size = size or 20
	local col, row = cell % 8, floor(cell / 8)
	return format("|T%s:%d:%d:0:0:%d:%d:%d:%d:%d:%d|t", TEXTURE, size, size, SHEET, SHEET, col * CELL, (col + 1) * CELL, row * CELL, (row + 1) * CELL)
end

---Takes in the catch-up's weekly medals (by lower-case name: { b, m, n }) and this week's boards. Unknown boards and
---metals are left out.
---@param medals table?
---@param week table?
function Achievements:TakeWeekly(medals, week)
	private.medals, private.week = {}, nil
	local holders = 0
	for name, list in pairs(type(medals) == "table" and medals or {}) do
		if holders >= MAX_HOLDERS then
			break
		end
		if type(name) == "string" and type(list) == "table" then
			local kept = {}
			for _, m in ipairs(list) do
				local n = type(m) == "table" and tonumber(m.n)
				if n and n >= 1 and BOARD_NAMES[m.b] and METAL_ORDER[m.m] then
					tinsert(kept, { board = m.b, metal = m.m, count = min(floor(n), 999) })
				end
			end
			if #kept > 0 then
				private.medals[strlower(name)] = kept
				holders = holders + 1
			end
		end
	end
	if type(week) == "table" and tonumber(week.start) and tonumber(week.ends) and type(week.boards) == "table" then
		local boards = {}
		for id in pairs(BOARD_NAMES) do
			local lines, kept = week.boards[id], {}
			if type(lines) == "table" then
				for i = 1, min(#lines, MAX_BOARD_LINES) do
					local l = lines[i]
					local name = type(l) == "table" and private.Text(l.n, 60)
					if name and tonumber(l.v) then
						tinsert(kept, { name = name, faction = l.f == "H" and "Horde" or l.f == "A" and "Alliance" or nil, value = tonumber(l.v) })
					end
				end
			end
			boards[id] = kept
		end
		private.week = { start = tonumber(week.start), ends = tonumber(week.ends), boards = boards }
	end
end

---Takes in the catch-up's playstyle badges: by lower-case name, a list of badge names. Unknown names are left out.
---@param styles table?
function Achievements:TakePlaystyle(styles)
	private.playstyle = {}
	local holders = 0
	for name, list in pairs(type(styles) == "table" and styles or {}) do
		if holders >= MAX_HOLDERS then
			break
		end
		if type(name) == "string" and type(list) == "table" then
			local kept = {}
			for _, b in ipairs(list) do
				if PLAYSTYLES[b] then
					tinsert(kept, b)
				end
			end
			if #kept > 0 then
				private.playstyle[strlower(name)] = kept
				holders = holders + 1
			end
		end
	end
end

---The weekly medals a player won, by full name (any case): { key, board, metal, count, name }, by board then metal.
---@param name string?
---@return table
function Achievements:MedalsOf(name)
	local out = {}
	for _, m in ipairs(type(name) == "string" and private.medals and private.medals[strlower(name)] or {}) do
		tinsert(out, { key = m.board..":"..m.metal, board = m.board, metal = m.metal, count = m.count,
			name = BOARD_NAMES[m.board].." "..m.metal })
	end
	sort(out, function(a, b)
		if a.metal ~= b.metal then
			return METAL_ORDER[a.metal] < METAL_ORDER[b.metal]
		end
		return a.board < b.board
	end)
	return out
end

---Every badge a player holds, for a row of icons: their weekly medals (gold first), their achievements, then their
---playstyle badges. Each is { key, name, count?, playstyle? }.
---@param name string?
---@return table
function Achievements:BadgesOf(name)
	local out = {}
	for _, m in ipairs(Achievements:MedalsOf(name)) do
		tinsert(out, { key = m.key, name = m.name, count = m.count })
	end
	for _, a in ipairs(Achievements:Of(name)) do
		tinsert(out, { key = a.id, name = a.name })
	end
	for _, b in ipairs(type(name) == "string" and private.playstyle and private.playstyle[strlower(name)] or {}) do
		tinsert(out, { key = PLAYSTYLES[b], name = b, playstyle = true })
	end
	-- Their signature badge (a cosmetic they picked) leads
	local signature = Achievements:CosmeticsOf(name).signature
	for i, b in ipairs(out) do
		if b.key == signature and i > 1 then
			tinsert(out, 1, tremove(out, i))
			break
		end
	end
	return out
end

---A row of badge icons as inline text: the first `most`, then "+N". A badge this addon has no art for (one the site
---added since) shows its name.
---@param badges table from BadgesOf
---@param most number
---@param size number? pixels
---@return string
function Achievements:IconRow(badges, most, size)
	local parts = {}
	for i = 1, min(#badges, most) do
		local icon = Achievements:IconText(badges[i].key, size)
		tinsert(parts, icon ~= "" and icon or badges[i].name)
	end
	if #badges > most then
		tinsert(parts, "+"..(#badges - most))
	end
	return table.concat(parts, " ")
end

---This character's place on each of this week's boards: { name, place?, value?, unit }, in board order; nil when the
---catch-up brought no boards for this week (or the week has ended).
---@return table?
function Achievements:MyPlaces()
	local week = private.week
	if not week or week.ends <= GetServerTime() then
		return nil
	end
	local me = strlower(Wanted.Store and Wanted.Store:GetOrigin() or UnitName("player") or "")
	local out = {}
	for _, b in ipairs(Achievements.BOARDS) do
		local line = { name = b.name, unit = b.unit }
		for i, l in ipairs(week.boards[b.id] or {}) do
			if strlower(l.name) == me then
				line.place, line.value = i, l.value
				break
			end
		end
		tinsert(out, line)
	end
	return out
end

---"1st", "2nd", "3rd", "11th", "22nd".
function Achievements:Ordinal(n)
	local last2, last = n % 100, n % 10
	local suffix = "th"
	if last2 < 11 or last2 > 13 then
		suffix = last == 1 and "st" or last == 2 and "nd" or last == 3 and "rd" or "th"
	end
	return n..suffix
end

---Announces this character's badges that are new since the last catch-up: a banner with the art. The first catch-up
---a character sees only notes what they hold (WantedDB.badgesSeen).
function Achievements:CheckNew()
	local me = Wanted.Store and Wanted.Store:GetOrigin() or UnitName("player")
	if type(me) ~= "string" then
		return
	end
	Wanted.db.badgesSeen = type(Wanted.db.badgesSeen) == "table" and Wanted.db.badgesSeen or {}
	local seen = Wanted.db.badgesSeen[me]
	local first = type(seen) ~= "table"
	seen = first and {} or seen
	local new = {}
	for _, b in ipairs(Achievements:BadgesOf(me)) do
		-- A medal won again counts as new: its count is part of what was seen. Playstyle badges describe the season's
		-- play and come and go, so they're never announced
		local mark = b.count and (b.key..":"..b.count) or b.key
		if not b.playstyle and not seen[mark] then
			seen[mark] = true
			tinsert(new, b)
		end
	end
	Wanted.db.badgesSeen[me] = seen
	if first or #new == 0 then
		return
	end
	local names = {}
	for _, b in ipairs(new) do
		tinsert(names, Achievements:IconText(b.key, 24).." "..b.name..(b.count and b.count > 1 and (" x"..b.count) or ""))
	end
	Wanted:Print("New badge%s: %s.", #new == 1 and "" or "s", table.concat(names, ", "))
	Wanted.Alerts:Warn(#new == 1 and "BADGE EARNED" or format("%d BADGES EARNED", #new), table.concat(names, "   "), Wanted.Theme.C.gold)
	Wanted.Alerts:Sound("important")
end



-- ============================================================================
-- Cosmetics (picked on wanteddeadordead.com, checked there against what each player has unlocked)
-- ============================================================================

-- The poster frames' colours, for the death card's border
Achievements.FRAME_COLORS = {
	gold = { 0.87, 0.70, 0.28 }, silver = { 0.78, 0.80, 0.83 }, bronze = { 0.69, 0.43, 0.25 }, founding = { 0.62, 0.14, 0.16 },
}

---Takes in the catch-up's cosmetics: by lower-case name, { s = signature badge, f = frame, t = stamp }. Unknown
---frames and signatures without art are left out.
---@param looks table?
function Achievements:TakeCosmetics(looks)
	private.cosmetics = {}
	local holders = 0
	for name, c in pairs(type(looks) == "table" and looks or {}) do
		if holders >= MAX_HOLDERS then
			break
		end
		if type(name) == "string" and type(c) == "table" then
			local kept = {
				signature = type(c.s) == "string" and CELLS[c.s] and c.s or nil,
				frame = type(c.f) == "string" and Achievements.FRAME_COLORS[c.f] and c.f or nil,
				stamp = private.Text(c.t, 40),
			}
			if kept.signature or kept.frame or kept.stamp then
				private.cosmetics[strlower(name)] = kept
				holders = holders + 1
			end
		end
	end
end

---A player's cosmetics by full name (any case): { signature?, frame?, stamp? }; an empty table for none.
---@param name string?
---@return table
function Achievements:CosmeticsOf(name)
	return type(name) == "string" and private.cosmetics and private.cosmetics[strlower(name)] or {}
end

---A stamp's words, as inked on a poster: "FOUNDING HUNTER", "DEFENDER"; nil for one unknown.
---@param id string?
---@return string?
function Achievements:StampText(id)
	if type(id) ~= "string" then
		return nil
	end
	local board = strmatch(id, "^board%-(.+)$")
	if board then
		return BOARD_NAMES[board] and strupper(BOARD_NAMES[board]) or nil
	end
	local def = private.defs[id]
	return def and strupper(def.name) or nil
end

---Puts a player's signature badge before what they said, in your own chat windows (the name is the game's link, so
---it stays as it is). On by default (settings.signatureChat).
function private.ChatFilter(_, _, message, author, ...)
	if not Wanted.db.settings.signatureChat or type(message) ~= "string" or type(author) ~= "string"
		or (issecretvalue and (issecretvalue(message) or issecretvalue(author))) then
		return false
	end
	local signature = Achievements:CosmeticsOf(strmatch(author, "^([^%-]+)") or author).signature
	if not signature then
		return false
	end
	return false, Achievements:IconText(signature, 14).." "..message, author, ...
end

-- Chat where a player says something; the badge goes at the start of what they said
local CHAT_EVENTS = {
	"CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_CHANNEL", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_PARTY",
	"CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_INSTANCE_CHAT",
	"CHAT_MSG_INSTANCE_CHAT_LEADER", "CHAT_MSG_WHISPER", "CHAT_MSG_EMOTE",
}

function Achievements:OnEnable()
	local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
	if addFilter then
		for _, event in ipairs(CHAT_EVENTS) do
			addFilter(event, private.ChatFilter)
		end
	end
end
