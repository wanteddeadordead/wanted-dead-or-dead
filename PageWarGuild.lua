-- Wanted: Guild Wars › Guild. Who the guild's war officers are: they declare, pick the time, accept or withdraw, and
-- set the roster. The guild master picks the ranks (by default every rank with the game's guild-invite right) and
-- adds or leaves out people by name; everyone else in the guild sees it read-only. Saving asks the site through the
-- app (GuildWars:Act); the site checks it comes from the guild's leader.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local GuildWars = Wanted.GuildWars
local private = { edit = nil, exceptionRows = {}, officerCells = {} }
local ROW = 44
local MAX_EXCEPTIONS, MAX_OFFICERS = 6, 24
local RANKS_TIP = "Who may declare, pick the time, accept or withdraw, and set the roster. Default: the guild master and every rank that can invite."
local EXCEPTIONS_TIP = "Add someone of any rank, or leave out someone of a ticked rank. Exceptions follow the person, not the character's rank, and lapse if they leave the guild."

---A copy of the setting in force to edit: { ranks = set, add = set, out = set }.
function private.Copy(setting)
	local copy = { ranks = {}, add = {}, out = {} }
	for _, key in ipairs({ "ranks", "add", "out" }) do
		for k in pairs(setting[key]) do
			copy[key][k] = true
		end
	end
	return copy
end

---A set's keys, sorted, as a list.
function private.Keys(set)
	local list = {}
	for k in pairs(set) do
		tinsert(list, k)
	end
	sort(list, function(a, b) return tostring(a) < tostring(b) end)
	return list
end

---The rank options for the multiselect: each rank with "can invite · N" or its member count; the guild master's
---always on and locked.
function private.RankOptions(ranks, guildName)
	local options = {}
	for _, rank in ipairs(ranks) do
		local note = (rank.invite and "can invite · " or "")..rank.members
		local tip
		if rank.index == 0 then
			tip = { rank.name, "The guild master's rank is always in." }
		elseif rank.invite then
			tip = { format("%s · %d member%s", rank.name, rank.members, rank.members == 1 and "" or "s"),
				format("From the game: %s has the guild-invite right in %s's rank settings, so it's ticked by default.\n\nUntick it to leave the rank out. The guild master's rank is always in.", rank.name, guildName) }
		else
			tip = { format("%s · %d member%s", rank.name, rank.members, rank.members == 1 and "" or "s"), "Tick it to make the whole rank war officers." }
		end
		tinsert(options, { key = rank.index, label = rank.name, note = note, locked = rank.index == 0, tip = tip })
	end
	return options
end

function private.Refresh()
	if not private.ranks then
		return
	end
	local guildName = GetGuildInfo and GetGuildInfo("player") or (GuildWars:Guild() and GuildWars:Guild().name) or "your guild"
	local setting, default = GuildWars:OfficerSetting()
	private.edit = private.edit or private.Copy(setting)
	local edit = private.edit
	edit.ranks[0] = true
	local master = GuildWars:AmGuildMaster()
	local ranks = GuildWars:Ranks()
	private.ranks:SetOptions(private.RankOptions(ranks, guildName))
	private.ranks:SetSelected(edit.ranks)
	private.ranks:SetEnabled(master)
	-- The exceptions: added in green with +, left out in red with -
	local rankOf = {}
	for _, member in ipairs(GuildWars:Members()) do
		rankOf[member.name] = member.rank
	end
	local list = {}
	for _, name in ipairs(private.Keys(edit.add)) do
		tinsert(list, { name = name, add = true })
	end
	for _, name in ipairs(private.Keys(edit.out)) do
		tinsert(list, { name = name, add = false })
	end
	for i, row in ipairs(private.exceptionRows) do
		local entry = list[i]
		row:SetShown(entry ~= nil)
		if entry then
			row.name:SetText(Theme:Colorize((entry.add and "+ " or "- ")..entry.name, entry.add and C.green or C.red))
			row.rank:SetText(rankOf[entry.name] or "not in the guild")
			row.remove:SetShown(master)
			row.entry = entry
		end
	end
	local y = -2 * ROW - min(#list, MAX_EXCEPTIONS) * 30 - 16
	private.box:SetShown(master)
	private.add:SetShown(master)
	private.out:SetShown(master)
	-- The war officers this would make
	local officers = GuildWars:Officers(edit)
	private.officersCard:ClearAllPoints()
	private.officersCard:SetPoint("TOPLEFT", 0, y)
	private.officersCard:SetPoint("TOPRIGHT", 0, y)
	private.officersLabel:SetText(strupper(format("War officers now · %d", #officers)))
	for i, cell in ipairs(private.officerCells) do
		local member = officers[i]
		cell:SetShown(member ~= nil)
		if member then
			cell.name:SetText(Theme:ClassName(member.name, member.class))
			cell.rank:SetText(member.rank..(edit.add[member.name] and " +" or ""))
		end
	end
	local rows = ceil(min(#officers, MAX_OFFICERS) / 2)
	private.officersCard:SetHeight(42 + max(rows, 1) * 22)
	-- Saved by, Reset and Save
	local pending = GuildWars:Pending("officers")
	local refused = GuildWars:Refused("officers")
	private.saved:SetText(pending and "Sent; waiting for the site" or refused and Theme:Colorize(refused, C.red) or default and "Default"
		or setting.held and Theme:Colorize("Saved; waiting for the guild's roster to agree", C.amber)
		or (setting.savedAt and format("Saved %s%s", GuildWars:Day(setting.savedAt), setting.savedBy and (" by "..setting.savedBy) or "")) or "")
	private.reset:SetShown(master)
	private.save:SetShown(master)
	local app = Wanted:HasApp()
	private.save:SetEnabled(app)
	W:Explain(private.save, "Save", app and "Applies on the site and in every member's addon at their next sync." or "Start the Wanted app to save.")
	W:Explain(private.reset, "Reset to default", "The guild master and every rank that can invite, no exceptions.")
	private.readOnly:SetShown(not master)
end

---Adds an exception: "add" makes them a war officer whatever their rank, "out" leaves them out.
function private.Except(kind)
	local name = strtrim(private.box:GetText() or "")
	if name == "" then
		return
	end
	name = strmatch(name, "^([^%-]+)") or name
	private.edit.add[name], private.edit.out[name] = nil, nil
	private.edit[kind][name] = true
	private.box:SetText("")
	private.Refresh()
end

UI:RegisterPage("warguild", {
	title = "Guild",
	tabLabel = "Guild",
	tabTip = { "Guild", "Who your guild's war officers are. The guild master sets them; everyone in the guild can see them." },
	under = "guildwars",
	order = -2,
	hidden = function() return not GuildWars:On() or not (IsInGuild and IsInGuild()) end,
	build = function(container, width)
		local inner = width
		-- War officer ranks
		private.ranks = W:MultiSelect(container, 300, {}, function(_, _, selected)
			private.edit.ranks = selected
			private.Refresh()
		end, "Guild Master")
		local ranksRow = W:Row(container, inner, "War officer ranks", private.ranks)
		ranksRow:SetPoint("TOPLEFT")
		W:InfoGlyph(ranksRow, "War officers by rank", RANKS_TIP):SetPoint("LEFT", ranksRow.label, "LEFT", ranksRow.label:GetStringWidth() + 6, 0)
		-- Exceptions: a name, then Add or Leave out
		local controls = CreateFrame("Frame", nil, container)
		controls:SetSize(160 + 6 + 60 + 6 + 90, 28)
		private.box = W:Input(controls, 160, "Member name")
		private.box:SetPoint("LEFT")
		W:Suggest(private.box, function()
			local names = {}
			for _, member in ipairs(GuildWars:Members()) do
				tinsert(names, member.name)
			end
			return names
		end)
		private.add = W:Button(controls, "Add", "secondary", 60, 28, function() private.Except("add") end)
		private.add:SetPoint("LEFT", private.box, "RIGHT", 6, 0)
		W:Explain(private.add, "Add", "Makes them a war officer, whatever their rank.")
		private.out = W:Button(controls, "Leave out", "secondary", 90, 28, function() private.Except("out") end)
		private.out:SetPoint("LEFT", private.add, "RIGHT", 6, 0)
		W:Explain(private.out, "Leave out", "Leaves them out, whatever their rank.")
		local exceptionsRow = W:Row(container, inner, "Exceptions", controls)
		exceptionsRow:SetPoint("TOPLEFT", 0, -ROW)
		W:InfoGlyph(exceptionsRow, "Exceptions", EXCEPTIONS_TIP):SetPoint("LEFT", exceptionsRow.label, "LEFT", exceptionsRow.label:GetStringWidth() + 6, 0)
		for i = 1, MAX_EXCEPTIONS do
			local row = CreateFrame("Frame", nil, container)
			row:SetSize(inner, 30)
			row:SetPoint("TOPLEFT", 0, -2 * ROW - (i - 1) * 30 - 4)
			row.name = Theme:Text(row, "body", "")
			row.name:SetPoint("LEFT", 20, 0)
			row.rank = Theme:Text(row, "small", "")
			row.rank:SetPoint("LEFT", 190, 0)
			row.remove = W:Button(row, "x", "ghost", 24, 24, function()
				local entry = row.entry
				if entry then
					private.edit[entry.add and "add" or "out"][entry.name] = nil
					private.Refresh()
				end
			end)
			row.remove:SetPoint("RIGHT", -20, 0)
			W:Explain(row.remove, "Clear", "Drops this exception.")
			private.exceptionRows[i] = row
		end
		-- War officers now, two columns
		local card = W:Card(container)
		private.officersCard = card
		private.officersLabel = W:SectionLabel(card, "")
		private.officersLabel:SetPoint("TOPLEFT", 16, -14)
		local column = floor((inner - 32) / 2)
		for i = 1, MAX_OFFICERS do
			local cell = CreateFrame("Frame", nil, card)
			cell:SetSize(column, 20)
			cell:SetPoint("TOPLEFT", 16 + ((i - 1) % 2) * column, -36 - floor((i - 1) / 2) * 22)
			cell.name = Theme:Text(cell, "body", "")
			cell.name:SetPoint("LEFT")
			cell.name:SetWidth(170)
			cell.name:SetWordWrap(false)
			cell.rank = Theme:Text(cell, "small", "")
			cell.rank:SetPoint("LEFT", 180, 0)
			private.officerCells[i] = cell
		end
		-- Saved by, and the guild master's buttons
		private.saved = Theme:Text(container, "small", "")
		private.saved:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -20)
		private.save = W:Button(container, "Save", "primary", 110, 28, function()
			local edit = private.edit
			local ranks = private.Keys(edit.ranks)
			GuildWars:Act("officers", nil, { ranks = ranks, add = private.Keys(edit.add), out = private.Keys(edit.out) })
			private.Refresh()
		end)
		private.save:SetPoint("TOPRIGHT", card, "BOTTOMRIGHT", 0, -12)
		private.reset = W:Button(container, "Reset to default", "secondary", 140, 28, function()
			private.edit = { ranks = { [0] = true }, add = {}, out = {} }
			for _, rank in ipairs(GuildWars:Ranks()) do
				if rank.invite then
					private.edit.ranks[rank.index] = true
				end
			end
			private.Refresh()
		end)
		private.reset:SetPoint("RIGHT", private.save, "LEFT", -10, 0)
		private.readOnly = Theme:Text(container, "small", "Set by the guild master", C.faint)
		private.readOnly:SetPoint("TOPRIGHT", card, "BOTTOMRIGHT", 0, -20)
		GuildWars:OnChange(function()
			-- The site's setting came in: start the edit from it again
			private.edit = nil
			if container:IsVisible() then
				private.Refresh()
			end
		end)
		private.Refresh()
	end,
	refresh = private.Refresh,
})
