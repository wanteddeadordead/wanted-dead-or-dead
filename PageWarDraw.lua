-- Wanted: a war's Draw step. Every declaring guild with its influence, stake and chance, and who the site drew; the
-- seed to check the draw on the site. Drawn: Start the roster (opens the Roster step early). Not drawn: the stake is
-- back in the treasury, and the guild may still fight as the drawn guild's allies.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local GuildWars = Wanted.GuildWars
local Data = GuildWars.Page -- what the pages read: the tour's sample war while one is on (WarSample.lua)
local ROWS = 4
local COLUMNS = { guild = 16, influence = 330, stake = 430, chance = 530, result = 640 }
local SITE = "https://wanteddeadordead.com/war/wars/"

---Open on the site: the war's page, an address to copy (the game can't open a browser).
function GuildWars:OpenOnSite(war)
	if GuildWars:Sampling() then
		return
	end
	W:Dialog({ title = "The war on the site", input = { value = SITE..tostring(war and war.id or "") }, confirmLabel = "Close" })
end

GuildWars.PANELS.draw = {
	build = function(panel, width)
		local card = W:Card(panel)
		card:SetPoint("TOPLEFT")
		card:SetSize(width, 60 + ROWS * 40 + 40)
		panel.card = card
		panel.label = W:SectionLabel(card, "")
		panel.label:SetPoint("TOPLEFT", COLUMNS.guild, -14)
		for key, text in pairs({ influence = "Influence", stake = "Stake", chance = "Chance", result = "Result" }) do
			W:SectionLabel(card, text):SetPoint("TOPLEFT", COLUMNS[key], -14)
		end
		panel.rows = {}
		for i = 1, ROWS do
			local row = CreateFrame("Frame", nil, card)
			row:SetSize(width - 32, 38)
			row:SetPoint("TOPLEFT", 0, -34 - (i - 1) * 40)
			row.crest = row:CreateTexture(nil, "ARTWORK")
			row.crest:SetSize(22, 22)
			row.crest:SetPoint("LEFT", COLUMNS.guild, 0)
			row.guild = Theme:Text(row, "body", "", C.text)
			row.guild:SetPoint("LEFT", COLUMNS.guild + 30, 0)
			row.influence = Theme:Text(row, "body", "", C.text)
			row.influence:SetPoint("LEFT", COLUMNS.influence, 0)
			row.coin = row:CreateTexture(nil, "ARTWORK")
			row.coin:SetSize(14, 14)
			row.coin:SetPoint("LEFT", COLUMNS.stake, 0)
			row.coin:SetTexture(GuildWars.MEDIA.."coin")
			row.stake = Theme:Text(row, "body", "", C.text)
			row.stake:SetPoint("LEFT", COLUMNS.stake + 18, 0)
			row.chance = Theme:Text(row, "body", "", C.text)
			row.chance:SetPoint("LEFT", COLUMNS.chance, 0)
			row.result = W:Pill(row)
			row.result:SetPoint("LEFT", COLUMNS.result, 6)
			row.sub = Theme:Text(row, "tiny", "")
			row.sub:SetPoint("TOPLEFT", row.result, "BOTTOMLEFT", 0, -1)
			panel.rows[i] = row
		end
		panel.seed = Theme:Text(card, "small", "")
		panel.seed:SetPoint("BOTTOMLEFT", COLUMNS.guild, 14)
		panel.seedGlyph = W:InfoGlyph(card, "Seed", "Published with the result: anyone can check the draw on the site.")
		panel.message = Theme:Text(panel, "body", "", C.text)
		panel.message:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -16)
		panel.allies = W:InfoGlyph(panel, "Fight as allies", "")
		panel.roster = W:Button(panel, "Start the roster", "primary", 150, 30, function()
			panel.tab.viewing, panel.tab.early = "roster", "roster"
			UI:Refresh()
		end)
		panel.roster:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -48)
		W:Explain(panel.roster, "Start the roster", "Opens the Roster step now, before the time is set.")
		panel.back = W:Button(panel, "Back to Tonight", "secondary", 150, 30, function() UI:Show("guildwars") end)
		panel.back:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -48)
		panel.site = W:Button(panel, "Open on the site", "secondary", 140, 30, function() GuildWars:OpenOnSite(panel.war) end)
		panel.site:SetPoint("LEFT", panel.roster, "RIGHT", 10, 0)
		W:Explain(panel.site, "Open on the site", "The war's page on wanteddeadordead.com, with the draw to check.")
	end,
	refresh = function(panel, war, ctx)
		panel.war = war
		local dr = type(war.draw) == "table" and war.draw or {}
		local declarers = type(dr.declarers) == "table" and dr.declarers or {}
		-- As tall as the declarations shown (a draw usually has two)
		panel.card:SetHeight(60 + min(max(#declarers, 1), ROWS) * 40 + 40)
		panel.label:SetText(strupper("The draw"..(type(dr.at) == "number" and (" · "..GuildWars:Clock(dr.at)) or "")))
		local decided = dr.drawn ~= nil
		local holder = ctx.theirs.guild or "the holders"
		local deadline = type(war.time) == "table" and type(war.time.deadline) == "number" and war.time.deadline or nil
		for i, row in ipairs(panel.rows) do
			local entry = type(declarers[i]) == "table" and declarers[i] or nil
			row:SetShown(entry ~= nil)
			if entry then
				row.crest:SetTexture(GuildWars:CrestFile(entry))
				row.guild:SetText(entry.guild or "?")
				row.influence:SetText(format("%d%%", floor((tonumber(entry.share) or 0) * 100 + 0.5)))
				row.stake:SetText(tostring(tonumber(entry.stake) or 0))
				row.chance:SetText(format("%d%%", floor((tonumber(entry.chance) or 0) * 100 + 0.5)))
				local drawn = entry.drawn == true
				row.result:Set(decided and (drawn and "DRAWN" or "not drawn") or "waiting", drawn and C.green or C.muted)
				row.sub:SetText(decided and (drawn and "held" or "back") or "")
				W:Explain(row.result, drawn and "Drawn" or "Not drawn", drawn and format("The site drew at %s, weighted by influence and stake. Your stake is held until the war ends.\n\nNext: %s picks the time%s; then you accept or withdraw.",
					type(dr.at) == "number" and GuildWars:Clock(dr.at) or "8:00 PM", holder, deadline and (" by "..date("%a ", deadline)..GuildWars:Clock(deadline)) or "")
					or format("%s is back in the treasury.", tostring(tonumber(entry.stake) or 0)), "ANCHOR_BOTTOM")
			end
		end
		panel.seed:SetText(type(dr.seed) == "string" and ("Seed  "..Theme:Colorize(dr.seed, C.text)) or "")
		panel.seedGlyph:SetShown(type(dr.seed) == "string")
		panel.seedGlyph:ClearAllPoints()
		panel.seedGlyph:SetPoint("LEFT", panel.seed, "LEFT", panel.seed:GetStringWidth() + 6, 0)
		-- What it means for us
		local mine = nil
		for _, entry in ipairs(declarers) do
			if type(entry) == "table" and entry.guild == ctx.ours.guild then
				mine = entry
			end
		end
		local winner = nil
		for _, entry in ipairs(declarers) do
			if type(entry) == "table" and entry.drawn then
				winner = entry.guild
			end
		end
		if not decided then
			panel.message:SetText(#declarers == 1 and format("Only %s declared: no draw needed.", declarers[1].guild or "?")
				or type(dr.at) == "number" and ctx.now > dr.at + 300 and "The site hasn't drawn yet." or "Waiting for the draw.")
		elseif dr.drawn then
			panel.message:SetText(format("%s attacks %s. %s picks the time.", ctx.ours.guild or "?", GuildWars:Short(war.zone), holder))
		else
			local stake = tonumber(dr.refunded) or mine and tonumber(mine.stake)
			panel.message:SetText(format(dr.dropped and "Dropped at the draw (a check no longer passed): %s is back in your treasury." or "Not drawn: %s is back in your treasury.",
				stake and ("the stake of "..stake) or "your stake"))
		end
		local notDrawn = decided and not dr.drawn
		panel.allies:SetShown(notDrawn and winner ~= nil)
		if notDrawn and winner then
			W:Explain(panel.allies, "Fight as allies", format("%s's officers can invite you as allies; invited members tick I'm in on their roster. Anyone can fight in the zone as a friend; only rosters take points.", winner))
			panel.allies:ClearAllPoints()
			panel.allies:SetPoint("LEFT", panel.message, "LEFT", panel.message:GetStringWidth() + 8, 0)
		end
		panel.roster:SetShown(dr.drawn == true and not ctx.looking)
		panel.back:SetShown(notDrawn)
		panel.site:ClearAllPoints()
		panel.site:SetPoint("LEFT", notDrawn and panel.back or panel.roster, "RIGHT", 10, 0)
		if not panel.roster:IsShown() and not notDrawn then
			panel.site:ClearAllPoints()
			panel.site:SetPoint("TOPLEFT", panel.roster, "TOPLEFT")
		end
	end,
}
