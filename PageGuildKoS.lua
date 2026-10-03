-- Wanted: the guild's Kill on Sight page. The guild's list (players and whole guilds) with who added each and why,
-- the names waiting for an officer, a box to add a guild by name, and the guild's settings, which officers change:
-- on or off, who may change the list (review, rank or open), and the rank for rank mode.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local GuildKoS = Wanted.GuildKoS
local private = { view = "approved" }
local ROW_HEIGHT = 40
local SETTINGS_TOP = 0
local LIST_TOP = 150

local MODE_LABELS = {
	review = "Review: anyone adds, officers approve",
	rank = "Rank: the chosen rank and above",
	open = "Open: any member",
}

---The guild's rank names, by rank index (0 = the guild master).
function private.Ranks()
	local out = {}
	local ok, n = pcall(GuildControlGetNumRanks)
	if ok and type(n) == "number" then
		for order = 1, min(n, 20) do
			local fine, name = pcall(GuildControlGetRankName, order)
			tinsert(out, { key = order - 1, label = fine and type(name) == "string" and name or ("Rank "..order) })
		end
	end
	return out
end

function private.Refresh()
	if not private.list then
		return
	end
	local book = GuildKoS:Current()
	local officer = book and GuildKoS:Can("settings")
	private.settings:SetShown(book ~= nil)
	if not book then
		private.status:SetText("Join a guild to use its Kill on Sight list.")
		private.list:SetItems({}, "Not in a guild.", "")
		return
	end
	local s = book.settings
	if s.enabled then
		private.status:SetText(format("<%s>: %s.%s", book.guild, MODE_LABELS[s.mode] or s.mode, officer and " You can change these as an officer." or ""))
	else
		private.status:SetText(format("<%s> hasn't switched on Guild Kill on Sight.%s", book.guild, officer and " Switch it on below." or " An officer can switch it on here."))
	end
	private.enabled:SetChecked(s.enabled)
	private.discord:SetChecked(s.discord)
	private.mode:SetChoice(s.mode)
	private.rank:SetChoice(s.rank)
	for _, control in ipairs({ private.enabled, private.discord, private.mode, private.rank }) do
		control:SetEnabled(officer)
	end
	private.rank:SetShown(s.mode == "rank")
	local canAdd = s.enabled and GuildKoS:Can("add")
	private.guildInput:SetShown(canAdd)
	private.addGuild:SetShown(canAdd)
	local items = GuildKoS:Entries(private.view)
	local pending = #GuildKoS:Entries("pending")
	for _, button in ipairs(private.segment.buttons) do
		if button.key == "pending" then
			button:SetText(pending > 0 and format("Waiting (%d)", pending) or "Waiting")
		end
	end
	if private.view == "pending" then
		private.list:SetItems(items, "Nothing waiting.", "In review mode, names members add wait here for an officer.")
	else
		private.list:SetItems(items, "Nobody on your guild's list yet.", "Right-click an enemy and choose Add to Guild Kill on Sight, or add a guild by name above.")
	end
end

function private.CreateRow(row)
	row.name = Theme:Text(row, "body", "")
	row.name:SetPoint("TOPLEFT", 10, -5)
	row.detail = Theme:Text(row, "small", "", C.muted)
	row.detail:SetPoint("TOPLEFT", 10, -22)
	row.detail:SetPoint("RIGHT", -120, 0)
	row.state = Theme:Text(row, "small", "")
	row.state:SetPoint("RIGHT", -12, 0)
end

function private.UpdateRow(row, e)
	row.name:SetText(e.kind == "guild" and ("Everyone in <"..e.name..">") or e.name)
	row.detail:SetText(format("%sadded by %s %s ago%s", e.reason and (e.reason.." - ") or "", e.by, Theme:Ago(GetServerTime() - e.at),
		e.dby and e.state == "approved" and e.dby ~= e.by and (", approved by "..e.dby) or ""))
	if e.state == "pending" then
		row.state:SetText("Waiting")
		row.state:SetTextColor(C.amber[1], C.amber[2], C.amber[3])
	else
		row.state:SetText("Kill on Sight")
		row.state:SetTextColor(C.red[1], C.red[2], C.red[3])
	end
end

---The menu for an entry: approve, deny and remove, as this character's rank allows.
function private.EntryMenu(e, row)
	local items = { { text = e.kind == "guild" and ("<"..e.name..">") or e.name, header = true } }
	local function act(action)
		local ok, why = GuildKoS:Decide(e.id, action)
		if not ok then
			Wanted:Print("%s", why)
		end
	end
	if e.state == "pending" and GuildKoS:Can("approve", e) then
		tinsert(items, { text = "Approve", color = C.green, onClick = function() act("approve") end })
		tinsert(items, { text = "Deny", onClick = function() act("deny") end })
	end
	if GuildKoS:Can("remove", e) then
		tinsert(items, { text = e.state == "pending" and "Take back" or "Remove from the list", onClick = function() act("remove") end })
	end
	if #items == 1 then
		tinsert(items, { text = "Your rank can't change this one", disabled = true })
	end
	W:Menu(items, row)
end

UI:RegisterPage("guildkos", {
	group = "War",
	title = "Guild Kill on Sight",
	subtitle = "Your guild's own Kill on Sight list, shared with your guildmates and kept apart from yours.",
	order = 3.5,
	badge = function()
		if not GuildKoS:Can("approve") then
			return nil
		end
		local pending = #GuildKoS:Entries("pending")
		return pending > 0 and pending or nil
	end,
	build = function(container, width, height)
		private.status = Theme:Text(container, "body", "", C.muted)
		private.status:SetPoint("TOPLEFT", 0, SETTINGS_TOP)
		private.status:SetPoint("RIGHT")
		private.status:SetWordWrap(true)

		-- The guild's settings: shown to everyone, changed by officers
		local settings = CreateFrame("Frame", nil, container)
		settings:SetPoint("TOPLEFT", 0, -28)
		settings:SetSize(width, 70)
		private.settings = settings
		private.enabled = W:Toggle(settings, "Guild Kill on Sight on", function(checked) GuildKoS:SetSettings({ enabled = checked }) end)
		private.enabled:SetPoint("TOPLEFT", 0, 0)
		private.discord = W:Toggle(settings, "Post sightings to the guild's Discord", function(checked) GuildKoS:SetSettings({ discord = checked }) end)
		private.discord:SetPoint("TOPLEFT", 0, -26)
		-- Discord sightings aren't posted yet: the switch shows once they are
		private.discord:Hide()
		local choices = {}
		for _, key in ipairs(GuildKoS.MODES) do
			tinsert(choices, { key = key, label = MODE_LABELS[key] })
		end
		private.mode = W:Choice(settings, 290, choices, function(key) GuildKoS:SetSettings({ mode = key }) end)
		private.mode:SetPoint("TOPLEFT", floor(width / 2), 0)
		private.rank = W:Choice(settings, 200, private.Ranks(), function(key) GuildKoS:SetSettings({ rank = key }) end)
		private.rank:SetPoint("TOPLEFT", floor(width / 2), -30)

		-- Adding a whole guild by name
		private.guildInput = W:Input(container, 260, "Add a whole guild by name")
		private.guildInput:SetPoint("TOPLEFT", 0, -104)
		private.addGuild = W:Button(container, "Add guild", "secondary", 96, 26, function()
			local name = strtrim(private.guildInput:GetText() or "")
			if name == "" then
				return
			end
			local e, why = GuildKoS:Add("guild", name)
			if e then
				private.guildInput:SetText("")
				Wanted:Print("<%s> %s.", name, e.state == "pending" and "is waiting for an officer to approve it" or "is on your guild's Kill on Sight list")
			else
				Wanted:Print("%s", why)
			end
		end)
		private.addGuild:SetPoint("LEFT", private.guildInput, "RIGHT", 8, 0)

		local segment = W:Segmented(container, {
			{ key = "approved", label = "On the list" },
			{ key = "pending", label = "Waiting" },
		}, function(key)
			private.view = key
			private.Refresh()
		end, 150)
		segment:SetPoint("TOPRIGHT", 0, -104)
		segment:Select("approved", true)
		private.segment = segment

		local list = W:List(container, ROW_HEIGHT, floor((height - LIST_TOP) / ROW_HEIGHT), private.CreateRow, private.UpdateRow)
		list:SetPoint("TOPLEFT", 0, -LIST_TOP)
		list:SetPoint("TOPRIGHT", 0, -LIST_TOP)
		list.onClick = function(e, row) private.EntryMenu(e, row) end
		private.list = list
	end,
	refresh = private.Refresh,
})
