-- Wanted: every enemy player the addon knows, with how often you've met, who won, their guild and where
-- they were last seen. Sort by any column, search by name or guild, and filter to Kill on Sight or
-- Ignored. Click a row for the enemy menu. Across the top: your nemesis (who killed you most), who you
-- killed most, and who you've fought most.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Enemies = Wanted.Enemies
local EnemyMenu = Wanted.EnemyMenu
local private = { filter = nil, sort = "lastSeen", descending = true }
local ROW_HEIGHT = 36
-- The nemesis tiles take the top of the page; everything else sits below them
local TOP = 78
local NEMESES = {
	{ key = "killedYou", label = "Killed you most", color = C.red, note = function(d) return d.losses == 1 and "once" or format("%d times", d.losses) end },
	{ key = "youKilled", label = "You killed most", color = C.green, note = function(d) return d.wins == 1 and "once" or format("%d times", d.wins) end },
	{ key = "fought", label = "Fought most", color = C.gold, note = function(d) return format("%d won, %d lost", d.wins, d.losses) end },
}
local COLUMNS = {
	{ key = "name", label = "Name", x = 42 },
	{ key = "level", label = "Lvl", x = 250 },
	{ key = "guild", label = "Guild", x = 290 },
	{ key = "wins", label = "Won", x = 440 },
	{ key = "losses", label = "Lost", x = 488 },
	{ key = "detections", label = "Seen", x = 536 },
	{ key = "lastSeen", label = "Last seen", x = 584 },
}

function private.CreateRow(row)
	row.bar = row:CreateTexture(nil, "ARTWORK")
	row.bar:SetPoint("TOPLEFT")
	row.bar:SetPoint("BOTTOMLEFT")
	row.bar:SetWidth(3)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(22, 22)
	row.icon:SetPoint("LEFT", 12, 0)
	row.name = Theme:Text(row, "body", "")
	row.name:SetPoint("TOPLEFT", 42, -5)
	row.name:SetWidth(200)
	row.sub = Theme:Text(row, "tiny", "")
	row.sub:SetPoint("TOPLEFT", 42, -21)
	row.sub:SetWidth(200)
	row.level = Theme:Text(row, "body", "")
	row.level:SetPoint("LEFT", 250, 0)
	row.guild = Theme:Text(row, "small", "")
	row.guild:SetPoint("LEFT", 290, 0)
	row.guild:SetWidth(142)
	row.wins = Theme:Text(row, "body", "")
	row.wins:SetPoint("LEFT", 440, 0)
	row.losses = Theme:Text(row, "body", "")
	row.losses:SetPoint("LEFT", 488, 0)
	row.seen = Theme:Text(row, "body", "")
	row.seen:SetPoint("LEFT", 536, 0)
	row.last = Theme:Text(row, "small", "")
	row.last:SetPoint("LEFT", 584, 0)
	row.last:SetPoint("RIGHT", -4, 0)
	row.last:SetWordWrap(false)
end

function private.UpdateRow(row, d)
	local barColor = d.kos and C.red or (d.bounty > 0 and C.gold) or (d.nearby and C.green) or C.transparent
	row.bar:SetColorTexture(barColor[1], barColor[2], barColor[3], barColor[4] or 1)
	Theme:SetClassIcon(row.icon, d.class)
	row.name:SetText(Theme:ClassName(d.name, d.class)..(d.nearby and Theme:Colorize("  nearby", C.green) or ""))
	local sub = {}
	if d.kos then
		tinsert(sub, Theme:Colorize(d.reason and ("KoS: "..d.reason) or "Kill on Sight", C.red))
	end
	if d.ignored then
		tinsert(sub, "ignored")
	end
	if d.bounty > 0 then
		tinsert(sub, Theme:Colorize(Wanted.Bounties:FormatMoney(d.bounty).." bounty", C.gold))
	end
	-- Race and class always lead the second line
	tinsert(sub, 1, strtrim((d.race or "").." "..Theme:ClassLabel(d.class)))
	row.sub:SetText(table.concat(sub, "  "))
	row.level:SetText(d.level and tostring(d.level) or (d.skull and "??" or "?"))
	row.guild:SetText(d.guild and ("<"..d.guild..">") or Theme:Colorize("none", C.faint))
	row.wins:SetText(d.wins > 0 and Theme:Colorize(tostring(d.wins), C.green) or Theme:Colorize("0", C.faint))
	row.losses:SetText(d.losses > 0 and Theme:Colorize(tostring(d.losses), C.red) or Theme:Colorize("0", C.faint))
	row.seen:SetText(d.detections)
	row.last:SetText(d.lastSeen and ((d.zone or "?")..", "..Theme:Ago(GetServerTime() - d.lastSeen)) or "")
end

function private.RefreshNemeses()
	local found = Enemies:GetNemeses()
	for _, n in ipairs(NEMESES) do
		local tile, d = private.nemesis[n.key], found[n.key]
		tile.enemy = d
		tile.value:SetText(d and Theme:ClassName(d.name, d.class) or Theme:Colorize("Nobody yet", C.faint))
		tile.note:SetText(d and n.note(d) or "")
	end
end

function private.Refresh()
	if not private.list then
		return
	end
	private.RefreshNemeses()
	local items = Enemies:GetAll(private.filter)
	local search = strlower(strtrim(private.search:GetText() or ""))
	if search ~= "" then
		local filtered = {}
		for _, d in ipairs(items) do
			if strfind(strlower(d.name), search, 1, true) or (d.guild and strfind(strlower(d.guild), search, 1, true)) then
				tinsert(filtered, d)
			end
		end
		items = filtered
	end
	local key, descending = private.sort, private.descending
	sort(items, function(a, b)
		local av, bv = a[key], b[key]
		if type(av) == "string" or type(bv) == "string" then
			av, bv = strlower(tostring(av or "")), strlower(tostring(bv or ""))
		else
			av, bv = av or 0, bv or 0
		end
		if av == bv then
			return a.name < b.name
		end
		if descending then
			return av > bv
		end
		return av < bv
	end)
	for _, header in ipairs(private.headers) do
		local arrow = header.key == key and (descending and "  v" or "  ^") or ""
		header:SetText(strupper(header.labelText)..arrow)
		header.fs:SetTextColor(unpack(header.key == key and C.text or C.faint))
	end
	private.count:SetText(format("%d enem%s", #items, #items == 1 and "y" or "ies"))
	local importable = Wanted.KoSImport and Wanted.KoSImport:SpyCountCached() or 0
	private.import:SetText(format("Import Kill on Sight (%d)", importable))
	private.import:SetShown(importable > 0)
	private.count:ClearAllPoints()
	private.count:SetPoint("RIGHT", importable > 0 and private.import or private.nearby, "LEFT", -12, 0)
	local hints = {
		kos = "Right-click an enemy in the Nearby window or click one here, then Kill on Sight.",
		ignored = "Ignored enemies never trigger alerts.",
	}
	private.list:SetItems(items, "No enemies yet.", private.filter and hints[private.filter] or "Enemy players you see appear here, with wins and losses.")
end

UI:RegisterPage("enemies", {
	group = "World PvP",
	title = "Enemies",
	subtitle = "Every enemy you've met: how often, who won, their guild, and where they were last. Click one for options.",
	order = 2,
	badge = function()
		local nearby = Enemies:CountNearby()
		return nearby > 0 and nearby or nil
	end,
	menuLabel = "Enemies",
	tabLabel = "Enemies",
	tabs = { "hotspots", "enemies", "guildkos", "activity" },
	build = function(container, width, height)
		private.nemesis = {}
		local tileWidth = floor((width - 24) / 3)
		local previous
		for _, n in ipairs(NEMESES) do
			local tile = W:StatTile(container, n.label, n.color)
			tile:SetWidth(tileWidth)
			if previous then
				tile:SetPoint("LEFT", previous, "RIGHT", 12, 0)
			else
				tile:SetPoint("TOPLEFT")
			end
			tile.value:SetWidth(tileWidth - 32)
			tile.value:SetJustifyH("LEFT")
			tile.value:SetWordWrap(false)
			tile.note:ClearAllPoints()
			tile.note:SetPoint("TOPRIGHT", -12, -12)
			tile:EnableMouse(true)
			tile:SetScript("OnMouseUp", function(self)
				if self.enemy then
					EnemyMenu:Show(self.enemy)
				end
			end)
			tile:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
				if self.enemy then
					GameTooltip:SetText(Theme:ClassName(self.enemy.name, self.enemy.class))
					EnemyMenu:AddTooltip(self.enemy)
				else
					GameTooltip:SetText(n.label)
					GameTooltip:AddLine("From your own wins and losses against enemy players.", 1, 1, 1, true)
				end
				GameTooltip:Show()
			end)
			tile:SetScript("OnLeave", function() GameTooltip:Hide() end)
			private.nemesis[n.key] = tile
			previous = tile
		end

		local filter = W:Segmented(container, {
			{ key = "all", label = "All enemies" },
			{ key = "kos", label = "Kill on Sight" },
			{ key = "ignored", label = "Ignored" },
		}, function(key)
			private.filter = key ~= "all" and key or nil
			private.Refresh()
		end, 108)
		filter:SetPoint("TOPLEFT", 0, -TOP)
		filter:Select("all", true)
		private.search = W:Input(container, 170, "Search name or guild", function() private.Refresh() end)
		private.search:SetPoint("LEFT", filter, "RIGHT", 12, 0)
		local nearby = W:Button(container, "Nearby window", "secondary", 130, 26, function() Wanted.NearbyWindow:Toggle() end)
		private.nearby = nearby
		nearby:SetPoint("TOPRIGHT", 0, -TOP)
		W:AttachTooltip(nearby, "Nearby window", "The small list of enemies around you. Also right-click the minimap button, or /wanted nearby.")
		-- Only when Spy or True Spy is installed with players Wanted doesn't have (KoSImport)
		private.import = W:Button(container, "Import Kill on Sight", "secondary", 170, 26, function()
			Wanted.KoSImport:Run()
			private.Refresh()
		end)
		private.import:SetPoint("RIGHT", nearby, "LEFT", -8, 0)
		W:AttachTooltip(private.import, "Import Kill on Sight", "Brings Spy's and True Spy's Kill on Sight lists over, with their reasons. Players Wanted hasn't seen yet go on Kill on Sight the first time it sees them.")
		private.count = Theme:Text(container, "small", "")

		local headerBar = CreateFrame("Frame", nil, container)
		headerBar:SetPoint("TOPLEFT", 0, -TOP - 40)
		headerBar:SetPoint("TOPRIGHT", 0, -TOP - 40)
		headerBar:SetHeight(24)
		local line = Theme:Line(headerBar)
		line:SetPoint("BOTTOMLEFT")
		line:SetPoint("BOTTOMRIGHT")
		private.headers = {}
		for _, col in ipairs(COLUMNS) do
			local header = CreateFrame("Button", nil, headerBar)
			header:SetHeight(24)
			header:SetPoint("LEFT", col.x, 0)
			header.fs = W:SectionLabel(header, col.label)
			header.fs:SetPoint("LEFT")
			header:SetFontString(header.fs)
			header:SetWidth(60)
			header.key = col.key
			header.labelText = col.label
			header:SetScript("OnClick", function()
				if private.sort == col.key then
					private.descending = not private.descending
				else
					private.sort = col.key
					private.descending = col.key ~= "name" and col.key ~= "guild"
				end
				private.Refresh()
			end)
			tinsert(private.headers, header)
		end

		local listTop = TOP + 68
		local list = W:List(container, ROW_HEIGHT, floor((height - listTop) / ROW_HEIGHT), private.CreateRow, private.UpdateRow)
		list:SetPoint("TOPLEFT", 0, -listTop)
		list:SetPoint("TOPRIGHT", 0, -listTop)
		list.onClick = function(d) EnemyMenu:Show(d) end
		list.onEnter = function(row, d)
			GameTooltip:SetOwner(row, "ANCHOR_CURSOR_RIGHT", 16, 0)
			GameTooltip:SetText(Theme:ClassName(d.name, d.class))
			EnemyMenu:AddTooltip(d)
			GameTooltip:Show()
		end
		private.list = list
	end,
	refresh = private.Refresh,
})
