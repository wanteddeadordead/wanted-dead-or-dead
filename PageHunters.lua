-- Wanted: the leaderboards. Hunters ranked by verified kills and reliability, posters by gold paid out
-- and whether they pay. Both come from the records, so nobody can talk their way up.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Model = Wanted.Model
local Reputation = Wanted.Reputation
local private = { view = "hunters", period = "all" }
local ROW_HEIGHT = 38
local PERIODS = { week = 7 * 86400, month = 30 * 86400, all = nil }
local HUNTER_COLUMNS = { { "#", 16 }, { "Hunter", 56 }, { "Rank", 280 }, { "Rating", 360 }, { "Kills", 470 }, { "Earned", 560 } }
local POSTER_COLUMNS = { { "#", 16 }, { "Poster", 56 }, { "Rating", 280 }, { "Paid", 390 }, { "Unpaid", 460 }, { "Paid out", 560 } }
local GUILD_COLUMNS = { { "#", 16 }, { "Guild", 56 }, { "Kills", 300 }, { "Deaths", 380 }, { "Seen", 460 }, { "Bounties on them", 540 } }

function private.SetColumns(columns)
	for i, header in ipairs(private.headers) do
		local col = columns[i]
		header:SetText(col and strupper(col[1]) or "")
		header:ClearAllPoints()
		header:SetPoint("LEFT", private.headerBar, "LEFT", col and col[2] or 0, 0)
	end
end

function private.CreateRow(row)
	row.rank = Theme:Text(row, "heading", "")
	row.rank:SetPoint("LEFT", 16, 0)
	row.name = Theme:Text(row, "body", "")
	row.name:SetPoint("LEFT", 56, 0)
	row.name:SetWidth(210)
	row.level = W:Pill(row)
	row.level:SetPoint("LEFT", 280, 0)
	-- Stars, or "new" before anyone has had to rely on them
	row.stars = Theme:Text(row, "body", "")
	row.col3 = Theme:Text(row, "body", "")
	row.col4 = Theme:Text(row, "body", "")
	row.col5 = Theme:Text(row, "body", "")
	row.col6 = Theme:Text(row, "money", "")
end

function private.UpdateRow(row, item, index)
	local rankColor = index == 1 and C.gold or (index <= 3 and C.text or C.muted)
	row.rank:SetText(index)
	row.rank:SetTextColor(unpack(rankColor))
	row.name:SetText(item.me and Theme:Colorize(item.origin.."  (you)", C.blue) or item.origin)
	row.col3:ClearAllPoints()
	row.col4:ClearAllPoints()
	row.col5:ClearAllPoints()
	row.col6:ClearAllPoints()
	if private.view == "guilds" then
		local color = item.mine and C.blue or C.red
		row.name:SetText(Theme:Colorize("<"..item.name..">", color)..Theme:Colorize(item.faction and ("  "..item.faction) or "", C.faint))
		row.level:Hide()
		row.stars:SetText("")
		row.col3:SetPoint("LEFT", 300, 0)
		row.col3:SetText(item.kills > 0 and tostring(item.kills) or Theme:Colorize("0", C.faint))
		row.col4:SetPoint("LEFT", 380, 0)
		row.col4:SetText(item.deaths > 0 and Theme:Colorize(tostring(item.deaths), C.red) or Theme:Colorize("0", C.faint))
		row.col5:SetPoint("LEFT", 460, 0)
		row.col5:SetText(item.seen)
		row.col6:SetPoint("LEFT", 540, 0)
		row.col6:SetText(item.bounties > 0 and (Theme:Money(item.gold)..Theme:Colorize(format("  (%d)", item.bounties), C.muted)) or Theme:Colorize("none", C.faint))
	elseif private.view == "hunters" then
		row.level:Set("Level "..item.level, item.level >= 5 and C.gold or C.blue)
		row.stars:ClearAllPoints()
		row.stars:SetPoint("LEFT", 360, 0)
		row.stars:SetText(item.rating and Theme:Stars(item.rating, 14) or Theme:Colorize("new", C.faint))
		row.col3:SetText("")
		row.col4:SetText("")
		row.col5:SetPoint("LEFT", 470, 0)
		row.col5:SetText(item.kills)
		row.col6:SetPoint("LEFT", 560, 0)
		row.col6:SetText(Theme:Money(item.earned))
	else
		row.level:Hide()
		row.stars:ClearAllPoints()
		row.stars:SetPoint("LEFT", 280, 0)
		row.stars:SetText(item.rating and Theme:Stars(item.rating, 14) or Theme:Colorize("new", C.faint))
		row.col3:SetText("")
		row.col4:SetPoint("LEFT", 390, 0)
		row.col4:SetText(Theme:Colorize(tostring(item.paid), C.green))
		row.col5:SetPoint("LEFT", 460, 0)
		row.col5:SetText(item.unpaid > 0 and Theme:Colorize(tostring(item.unpaid), C.red) or Theme:Colorize("0", C.faint))
		row.col6:SetPoint("LEFT", 560, 0)
		row.col6:SetText(Theme:Money(item.gold))
	end
end

function private.Refresh()
	if not private.list then
		return
	end
	local since = PERIODS[private.period] and (GetServerTime() - PERIODS[private.period]) or nil
	local hunters, posters = Model:GetLeaderboards(since)
	if private.view == "guilds" then
		private.SetColumns(GUILD_COLUMNS)
		private.list:SetItems(Model:GetGuildBoard(since), "No guilds seen yet.", "Guilds come from the players you see and the kills and deaths recorded.")
	elseif private.view == "hunters" then
		private.SetColumns(HUNTER_COLUMNS)
		private.list:SetItems(hunters, "No hunters yet.", "Claims on bounties put hunters here.")
	else
		private.SetColumns(POSTER_COLUMNS)
		private.list:SetItems(posters, "No posters yet.", "Anyone who posts a bounty appears here.")
	end
end

UI:RegisterPage("hunters", {
	title = "Leaderboards",
	subtitle = "Ranked from what actually happened: witnessed kills, confirmed claims, bounties paid, and guild kills and deaths.",
	order = 4,
	build = function(container, width, height)
		local view = W:Segmented(container, {
			{ key = "hunters", label = "Hunters" },
			{ key = "posters", label = "Posters" },
			{ key = "guilds", label = "Guilds" },
		}, function(key)
			private.view = key
			private.Refresh()
		end, 110)
		view:SetPoint("TOPLEFT")
		view:Select("hunters", true)
		local period = W:Segmented(container, {
			{ key = "week", label = "7 days" },
			{ key = "month", label = "30 days" },
			{ key = "all", label = "All time" },
		}, function(key)
			private.period = key
			private.Refresh()
		end, 84)
		period:SetPoint("TOPRIGHT")
		period:Select("all", true)

		local headerBar = CreateFrame("Frame", nil, container)
		headerBar:SetPoint("TOPLEFT", 0, -40)
		headerBar:SetPoint("TOPRIGHT", 0, -40)
		headerBar:SetHeight(24)
		local line = Theme:Line(headerBar)
		line:SetPoint("BOTTOMLEFT")
		line:SetPoint("BOTTOMRIGHT")
		private.headerBar = headerBar
		private.headers = {}
		for i = 1, 6 do
			private.headers[i] = W:SectionLabel(headerBar, "")
		end

		local listTop = 68
		local list = W:List(container, ROW_HEIGHT, floor((height - listTop) / ROW_HEIGHT), private.CreateRow, private.UpdateRow)
		list:SetPoint("TOPLEFT", 0, -listTop)
		list:SetPoint("TOPRIGHT", 0, -listTop)
		list.onEnter = function(row, item)
			GameTooltip:SetOwner(row, "ANCHOR_CURSOR_RIGHT", 16, 0)
			if private.view == "guilds" then
				GameTooltip:SetText("<"..item.name..">", 1, 1, 1)
				GameTooltip:AddLine("Kills count honorable kills credited to members running Wanted. Deaths count members seen dying, each death once.", C.muted[1], C.muted[2], C.muted[3], true)
				local members = Model:GetGuildMembers(item.name)
				for i = 1, min(#members, 8) do
					local member = members[i]
					GameTooltip:AddDoubleLine(Theme:ClassName(member.name or "?", member.class), "level "..(member.level or "?"), 1, 1, 1, C.muted[1], C.muted[2], C.muted[3])
				end
				GameTooltip:Show()
				return
			end
			GameTooltip:SetText(item.origin, 1, 1, 1)
			local t = item.tally
			-- Stars and the trust word first, as on bounty tooltips, then the numbers behind them
			if private.view == "hunters" then
				Reputation:AddTrustLines("Hunter trust", Reputation:GetHunterTrust(t))
				GameTooltip:AddLine(" ")
				GameTooltip:AddDoubleLine("Witnessed kills", t.witnessed, 1, 1, 1, 1, 1, 1)
				GameTooltip:AddDoubleLine("Confirmed by poster", t.confirmed, 1, 1, 1, 1, 1, 1)
				GameTooltip:AddDoubleLine("Unverified", t.lone, 1, 1, 1, 1, 1, 1)
				GameTooltip:AddDoubleLine("Disputed", t.disputed, 1, 1, 1, t.disputed > 0 and 1 or 1, t.disputed > 0 and 0.4 or 1, t.disputed > 0 and 0.4 or 1)
			else
				Reputation:AddTrustLines("Poster trust", Reputation:GetPosterTrust(t))
			end
			GameTooltip:Show()
		end
		private.list = list
	end,
	refresh = private.Refresh,
})
