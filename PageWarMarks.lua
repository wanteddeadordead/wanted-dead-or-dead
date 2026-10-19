-- Wanted: Guild Wars › War Marks. Your purse and what you earned today against the daily cap, by source; your guild's
-- treasury, the stakes it holds, its tax (the guild master sets it) and its week; and the recent movements of both.
-- From the app's catch-up (GuildWars), as of its time; the tax is asked of the site through the app (GuildWars:Act).

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local GuildWars = Wanted.GuildWars
local private = { sources = {}, week = {}, recent = {} }
local GAP = 12
local SOURCE_ROWS, WEEK_ROWS = 7, 5
local RECENT_ROW = 22
-- Your War Marks on the site: the purse, today by source and the history from the ledger (the war contract's 8)
local MARKS_PAGE = "https://wanteddeadordead.com/marks"
local TODAY_TIP = "Earned only from play the site verifies, up to 150 a day. The guild tax comes out of each."
local TAX_TIP = "The share of each member's War Marks that goes to the guild's treasury, for its stakes. Leaders only: the guild master sets it."

function private.Count(n)
	n = floor(tonumber(n) or 0)
	return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
end

---"+14" in green, "-400" in red, "" for nothing.
function private.Signed(n)
	n = tonumber(n)
	if not n or n == 0 then
		return ""
	end
	return Theme:Colorize((n > 0 and "+" or "-")..private.Count(math.abs(n)), n > 0 and C.green or C.red)
end

---A thin bar: a track and a fill to a share.
function private.Bar(parent, width)
	local track = parent:CreateTexture(nil, "BACKGROUND")
	track:SetSize(width, 4)
	track:SetColorTexture(1, 1, 1, 0.06)
	local fill = parent:CreateTexture(nil, "ARTWORK")
	fill:SetPoint("LEFT", track, "LEFT")
	fill:SetHeight(4)
	fill:SetColorTexture(C.green[1], C.green[2], C.green[3], 1)
	return track, fill
end

function private.BuildToday(card, width)
	card.label = W:SectionLabel(card, "")
	card.label:SetPoint("TOPLEFT", 16, -14)
	card.glyph = W:InfoGlyph(card, "Today", TODAY_TIP)
	card.bar = W:ProgressBar(card, 8)
	card.bar:SetPoint("TOPLEFT", 16, -38)
	card.bar:SetWidth(width - 32)
	for i = 1, SOURCE_ROWS do
		local y = -60 - (i - 1) * 26
		local row = { label = Theme:Text(card, "body", "", C.text) }
		row.label:SetPoint("TOPLEFT", 16, y)
		row.track, row.fill = private.Bar(card, width - 32 - 150 - 70)
		row.track:SetPoint("TOPLEFT", 160, y - 6)
		row.value = Theme:Text(card, "small", "")
		row.value:SetPoint("TOPRIGHT", -16, y)
		row.value:SetJustifyH("RIGHT")
		private.sources[i] = row
	end
end

function private.BuildTreasury(card, width)
	card.label = W:SectionLabel(card, "")
	card.label:SetPoint("TOPLEFT", 16, -14)
	card.coin = card:CreateTexture(nil, "ARTWORK")
	card.coin:SetSize(20, 20)
	card.coin:SetPoint("TOPLEFT", 16, -34)
	card.coin:SetTexture(GuildWars.MEDIA.."coin")
	card.value = Theme:Text(card, "stat", "", C.gold)
	card.value:SetPoint("LEFT", card.coin, "RIGHT", 6, 0)
	card.staked = Theme:Text(card, "small", "")
	card.staked:SetPoint("LEFT", card.value, "RIGHT", 6, -2)
	card.taxLabel = Theme:Text(card, "body", "Guild tax", C.text)
	card.taxLabel:SetPoint("TOPLEFT", 16, -76)
	card.taxGlyph = W:InfoGlyph(card, "Guild tax", TAX_TIP)
	card.taxGlyph:SetPoint("LEFT", card.taxLabel, "RIGHT", 6, 0)
	card.tax = W:Slider(card, "", 240, 0, 25, 1, function(v) return v.."%" end, function(v)
		GuildWars:Act("tax", nil, { percent = v })
		private.Refresh()
	end)
	card.tax:SetPoint("TOPRIGHT", -16, -66)
	card.taxBy = Theme:Text(card, "tiny", "")
	card.taxBy:SetPoint("TOPLEFT", 16, -106)
	card.weekLabel = W:SectionLabel(card, "This week")
	card.weekLabel:SetPoint("TOPLEFT", 16, -130)
	for i = 1, WEEK_ROWS do
		local y = -150 - (i - 1) * 18
		local row = { text = Theme:Text(card, "small", "", C.text), value = Theme:Text(card, "small", "") }
		row.text:SetPoint("TOPLEFT", 16, y)
		row.value:SetPoint("TOPRIGHT", -16, y)
		row.value:SetJustifyH("RIGHT")
		private.week[i] = row
	end
end

function private.BuildRecent(card, width, height)
	W:SectionLabel(card, "Recent"):SetPoint("TOPLEFT", 16, -14)
	local treasury = W:SectionLabel(card, "Treasury")
	treasury:SetPoint("TOPRIGHT", -16, -14)
	local purse = W:SectionLabel(card, "Purse")
	purse:SetPoint("TOPRIGHT", -130, -14)
	card.treasuryHead = treasury
	for i = 1, max(floor((height - 40) / RECENT_ROW), 1) do
		local y = -36 - (i - 1) * RECENT_ROW
		local row = { time = Theme:Text(card, "small", ""), text = Theme:Text(card, "body", "", C.text),
			purse = Theme:Text(card, "small", ""), treasury = Theme:Text(card, "small", "") }
		row.time:SetPoint("TOPLEFT", 16, y)
		row.text:SetPoint("TOPLEFT", 110, y)
		row.text:SetWidth(width - 110 - 260)
		row.text:SetWordWrap(false)
		row.purse:SetPoint("TOPRIGHT", -130, y)
		row.purse:SetJustifyH("RIGHT")
		row.treasury:SetPoint("TOPRIGHT", -16, y)
		row.treasury:SetJustifyH("RIGHT")
		private.recent[i] = row
	end
	card.empty = Theme:Text(card, "body", "", C.muted)
	card.empty:SetPoint("CENTER")
end

function private.Refresh()
	if not private.tiles then
		return
	end
	local purse, guild = GuildWars:Purse(), GuildWars:Guild()
	local inGuild = guild ~= nil and type(guild.name) == "string"
	local tiles = private.tiles
	-- The tiles: purse, today, treasury, tax
	tiles.purse.value:SetText(purse and private.Count(purse.marks) or "0")
	local cap = purse and tonumber(purse.cap) or GuildWars.DAILY_CAP
	tiles.today.value:SetText((purse and private.Count(purse.today) or "0").." / "..private.Count(cap))
	tiles.today.note:SetText(purse and type(purse.resets) == "number" and ("resets "..GuildWars:Clock(purse.resets)) or "")
	for _, key in ipairs({ "treasury", "tax" }) do
		tiles[key]:SetShown(inGuild)
	end
	if inGuild then
		tiles.treasury.label:SetText(strupper(guild.name.." treasury"))
		tiles.treasury.value:SetText(private.Count(guild.treasury))
		tiles.treasury.note:SetText(tonumber(guild.staked) and guild.staked > 0 and (private.Count(guild.staked).." held as a stake") or "")
		local pending = GuildWars:Pending("tax")
		tiles.tax.value:SetText((pending and pending.data.percent or tonumber(guild.tax) or 0).."%")
		tiles.tax.note:SetText(pending and "sent; waiting for the site" or "set by the guild master")
	end
	-- Today, by source
	local today = private.today
	today.label:SetText(strupper(format("Today · %s of %s", purse and private.Count(purse.today) or "0", private.Count(cap))))
	today.glyph:ClearAllPoints()
	today.glyph:SetPoint("LEFT", today.label, "LEFT", today.label:GetStringWidth() + 6, 0)
	today.bar:SetValue(purse and min((tonumber(purse.today) or 0) / max(cap, 1), 1) or 0, C.gold)
	local sources = purse and type(purse.sources) == "table" and purse.sources or {}
	for i, row in ipairs(private.sources) do
		local source = type(sources[i]) == "table" and sources[i] or nil
		local n, most = source and tonumber(source.n) or 0, source and tonumber(source.max)
		for _, part in pairs(row) do
			part:SetShown(source ~= nil)
		end
		if source then
			row.label:SetText(source.label or "?")
			-- Against its own most when it has one, else the day's cap
			local of = most or cap
			row.fill:SetWidth(max(row.track:GetWidth() * (of > 0 and min(n / of, 1) or 0), 1))
			row.fill:SetShown(n > 0)
			row.value:SetText(Theme:Colorize(private.Count(n), n > 0 and C.gold or C.muted)..(most and Theme:Colorize(" / "..private.Count(most), C.muted) or ""))
		end
	end
	-- The treasury and its tax, with this guild only
	local treasury = private.treasury
	treasury:SetShown(inGuild)
	if inGuild then
		treasury.label:SetText(strupper(guild.name.." treasury"))
		treasury.value:SetText(private.Count(guild.treasury))
		treasury.staked:SetText(tonumber(guild.staked) and guild.staked > 0 and (private.Count(guild.staked).." staked") or "")
		local pending = GuildWars:Pending("tax")
		treasury.tax:SetValue(pending and pending.data.percent or tonumber(guild.tax) or 0)
		-- Leaders only: the guild master moves it, everyone sees it
		local leader = GuildWars:AmGuildMaster()
		treasury.tax.slider:EnableMouse(leader)
		treasury.tax.box:EnableMouse(leader)
		treasury.tax:SetAlpha(leader and 1 or 0.6)
		local refused = GuildWars:Refused("tax")
		treasury.taxBy:SetText(pending and "Sent; waiting for the site" or refused and Theme:Colorize(refused, C.red)
			or (type(guild.taxBy) == "string" and (guild.taxBy..(type(guild.taxAt) == "number" and (", "..GuildWars:Day(guild.taxAt)) or "")) or ""))
		local week = type(guild.week) == "table" and guild.week or {}
		treasury.weekLabel:SetShown(#week > 0)
		for i, row in ipairs(private.week) do
			local entry = type(week[i]) == "table" and week[i] or nil
			row.text:SetText(entry and entry.text or "")
			row.value:SetText(entry and private.Signed(entry.n) or "")
		end
	end
	-- Recent
	local recent = purse and type(purse.recent) == "table" and purse.recent or {}
	private.recentCard.treasuryHead:SetShown(inGuild)
	for i, row in ipairs(private.recent) do
		local entry = type(recent[i]) == "table" and recent[i] or nil
		row.time:SetText(entry and type(entry.t) == "number" and ((date("%Y-%m-%d", entry.t) == date("%Y-%m-%d", GetServerTime()) and "" or date("%a ", entry.t))
			..GuildWars:Clock(entry.t)) or "")
		row.text:SetText(entry and entry.text or "")
		row.purse:SetText(entry and private.Signed(entry.purse) or "")
		row.treasury:SetText(entry and inGuild and private.Signed(entry.treasury) or "")
	end
	-- Nothing yet: when the next race is
	local next_ = Wanted.Races:Next()
	private.recentCard.empty:SetShown(#recent == 0)
	private.recentCard.empty:SetText("No War Marks yet"..(next_ and (": race "..GuildWars:When(next_.start)..".") or "."))
end

UI:RegisterPage("warmarks", {
	title = "War Marks",
	tabLabel = "War Marks",
	tabTip = { "War Marks", "Earned from races, wars and bounties the site verifies, up to 150 a day. They buy cosmetics on the site." },
	under = "guildwars",
	order = -2,
	hidden = function() return not GuildWars:On() end,
	build = function(container, width, height)
		local tileWidth = floor((width - 3 * GAP) / 4)
		private.tiles = {
			purse = W:StatTile(container, "Your purse", C.gold),
			today = W:StatTile(container, "Earned today", C.green),
			treasury = W:StatTile(container, "Treasury", C.accent),
			tax = W:StatTile(container, "Guild tax", C.amber),
		}
		for i, key in ipairs({ "purse", "today", "treasury", "tax" }) do
			local tile = private.tiles[key]
			tile:SetPoint("TOPLEFT", (i - 1) * (tileWidth + GAP), 0)
			tile:SetWidth(tileWidth)
		end
		private.tiles.purse.note:SetText("War Marks")
		W:Explain(private.tiles.today, "Earned today", TODAY_TIP)
		W:Explain(private.tiles.tax, "Guild tax", TAX_TIP)
		local cardTop, cardHeight = -78, 236
		local half = floor((width - GAP) / 2)
		local today = W:Card(container)
		today:SetPoint("TOPLEFT", 0, cardTop)
		today:SetSize(half, cardHeight)
		private.BuildToday(today, half)
		private.today = today
		local treasury = W:Card(container)
		treasury:SetPoint("TOPLEFT", half + GAP, cardTop)
		treasury:SetSize(width - half - GAP, cardHeight)
		private.BuildTreasury(treasury, width - half - GAP)
		private.treasury = treasury
		local recentTop = cardTop - cardHeight - GAP
		local recentHeight = height + recentTop - 48
		local recent = W:Card(container)
		recent:SetPoint("TOPLEFT", 0, recentTop)
		recent:SetSize(width, recentHeight)
		private.BuildRecent(recent, width, recentHeight)
		private.recentCard = recent
		local shop = W:Button(container, "Open on the site", "secondary", 140, 28, function()
			W:Dialog({ title = "Your War Marks on the site", input = { value = MARKS_PAGE }, confirmLabel = "Close" })
		end)
		shop:SetPoint("BOTTOMRIGHT", 0, 4)
		W:Explain(shop, "Open on the site", "Your purse, today by source and every movement, on wanteddeadordead.com. Copy the address. War Marks are never sold.")
		GuildWars:OnChange(function()
			if container:IsVisible() then
				private.Refresh()
			end
		end)
		private.Refresh()
	end,
	refresh = private.Refresh,
})
