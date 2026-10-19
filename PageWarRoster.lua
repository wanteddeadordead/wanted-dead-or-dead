-- Wanted: a war's Roster step. Up to 40 a side: the roster (officers pick; x takes someone off), who said they're in
-- and isn't picked (Add, or greyed with why they can't be), the standby order, and I'm in for the player's own sign-up.
-- Officers fill from the sign-ups, invite an allied guild, announce in guild chat, and save (asked of the site through
-- the app). No warnings about numbers: whoever is there at the start fights.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local GuildWars = Wanted.GuildWars
local private = {}
local GAP = 12
local ROW = 21
local ROSTER_HEIGHT, LOWER_HEIGHT = 222, 136
local MAX_SIGNUPS, MAX_STANDBY = 5, 5
local ROSTER_TIP = "One raid, 40 a side. Only the roster takes and holds points. Whoever is there at the start fights: no minimum, no forfeit."
local STANDBY_TIP = "First in, in order, if someone on the roster drops. Rosters lock when the battle starts."

---A name with its class colour.
function private.Name(entry)
	return Theme:ClassName(entry.name or "?", entry.class)
end

---The roster being edited (an officer's), else the site's: { names = list, standby = list }.
function private.Edit(panel, war)
	local ro = type(war.roster) == "table" and war.roster or {}
	if not panel.state.edit or panel.state.war ~= war.id then
		local edit = { names = {}, standby = {} }
		for _, p in ipairs(type(ro.players) == "table" and ro.players or {}) do
			if type(p) == "table" and p.name then
				tinsert(edit.names, p.name)
			end
		end
		for _, p in ipairs(type(ro.standby) == "table" and ro.standby or {}) do
			if type(p) == "table" and p.name then
				tinsert(edit.standby, p.name)
			end
		end
		panel.state.edit, panel.state.war, panel.state.dirty = edit, war.id, false
	end
	return panel.state.edit
end

---Everyone the roster can name: the site's players, sign-ups and standby, by name.
function private.People(war)
	local ro = type(war.roster) == "table" and war.roster or {}
	local people = {}
	for _, key in ipairs({ "players", "signups", "standby" }) do
		for _, p in ipairs(type(ro[key]) == "table" and ro[key] or {}) do
			if type(p) == "table" and p.name and not people[p.name] then
				people[p.name] = p
			end
		end
	end
	return people
end

function private.Contains(list, name)
	for i, n in ipairs(list) do
		if n == name then
			return i
		end
	end
	return nil
end

GuildWars.PANELS.roster = {
	build = function(panel, width, height)
		panel.state = {}
		local card = W:Card(panel)
		card:SetPoint("TOPLEFT")
		card:SetSize(width, ROSTER_HEIGHT)
		panel.label = W:SectionLabel(card, "")
		panel.label:SetPoint("TOPLEFT", 16, -14)
		panel.labelGlyph = W:InfoGlyph(card, "Roster", ROSTER_TIP)
		panel.mine = W:Switch(card, function(on)
			if panel.state.record then
				GuildWars:Act("in", panel.state.record.id, { on = on })
			end
		end)
		panel.mine:SetPoint("TOPRIGHT", -16, -10)
		local mineLabel = Theme:Text(card, "body", "I'm in", C.text)
		mineLabel:SetPoint("RIGHT", panel.mine, "LEFT", -10, 0)
		W:Explain(panel.mine, "I'm in", "Officers pick; anyone in the guild or an invited ally can say they're in.")
		-- The roster, two columns, scrolled
		panel.scroll = W:Scroll(card, width - 16, ROSTER_HEIGHT - 44)
		panel.scroll:SetPoint("TOPLEFT", 16, -38)
		panel.rows = {}
		local column = floor((width - 44) / 2)
		for i = 1, GuildWars.MAX_ROSTER do
			local row = CreateFrame("Frame", nil, panel.scroll.content)
			row:SetSize(column - 8, ROW)
			row:SetPoint("TOPLEFT", ((i - 1) % 2) * column, -floor((i - 1) / 2) * ROW)
			row.name = Theme:Text(row, "body", "")
			row.name:SetPoint("LEFT")
			row.name:SetWidth(150)
			row.name:SetWordWrap(false)
			row.rank = Theme:Text(row, "small", "")
			row.rank:SetPoint("LEFT", 158, 0)
			row.rank:SetWidth(110)
			row.rank:SetWordWrap(false)
			row.status = Theme:Text(row, "small", "")
			row.status:SetPoint("LEFT", 276, 0)
			row.remove = W:Button(row, "x", "ghost", 20, 20, function()
				local edit = panel.state.edit
				local at = private.Contains(edit.names, row.who)
				if at then
					tremove(edit.names, at)
					panel.state.dirty = true
					GuildWars.PANELS.roster.refresh(panel, panel.state.record, panel.ctx)
				end
			end)
			row.remove:SetPoint("RIGHT")
			W:Explain(row.remove, "Take off the roster", "Back to the sign-ups.")
			panel.rows[i] = row
		end
		-- Said I'm in, not picked
		local half = floor((width - GAP) * 0.62)
		local signups = W:Card(panel)
		signups:SetPoint("TOPLEFT", 0, -ROSTER_HEIGHT - GAP)
		signups:SetSize(half, LOWER_HEIGHT)
		panel.signupLabel = W:SectionLabel(signups, "")
		panel.signupLabel:SetPoint("TOPLEFT", 16, -14)
		panel.signups = {}
		for i = 1, MAX_SIGNUPS do
			local row = CreateFrame("Frame", nil, signups)
			row:SetSize(half - 32, 20)
			row:SetPoint("TOPLEFT", 16, -34 - (i - 1) * 20)
			row.name = Theme:Text(row, "body", "")
			row.name:SetPoint("LEFT")
			row.name:SetWidth(130)
			row.name:SetWordWrap(false)
			row.why = Theme:Text(row, "small", "")
			row.why:SetPoint("LEFT", 138, 0)
			row.why:SetPoint("RIGHT", -50, 0)
			row.why:SetWordWrap(false)
			row.add = W:Button(row, "Add", "chip", 40, 18, function()
				local edit = panel.state.edit
				if #edit.names < GuildWars.MAX_ROSTER and not private.Contains(edit.names, row.who) then
					tinsert(edit.names, row.who)
					panel.state.dirty = true
					GuildWars.PANELS.roster.refresh(panel, panel.state.record, panel.ctx)
				end
			end)
			row.add:SetPoint("RIGHT")
			panel.signups[i] = row
		end
		-- Standby, in order
		local standby = W:Card(panel)
		standby:SetPoint("TOPLEFT", half + GAP, -ROSTER_HEIGHT - GAP)
		standby:SetSize(width - half - GAP, LOWER_HEIGHT)
		panel.standbyLabel = W:SectionLabel(standby, "")
		panel.standbyLabel:SetPoint("TOPLEFT", 16, -14)
		panel.standbyGlyph = W:InfoGlyph(standby, "Standby", STANDBY_TIP)
		panel.standby = {}
		for i = 1, MAX_STANDBY do
			local line = Theme:Text(standby, "body", "")
			line:SetPoint("TOPLEFT", 16, -34 - (i - 1) * 20)
			panel.standby[i] = line
		end
		-- The officers' buttons
		local y = -ROSTER_HEIGHT - GAP - LOWER_HEIGHT - GAP
		panel.fill = W:Button(panel, "Fill from sign-ups", "secondary", 140, 30, function()
			local edit, war = panel.state.edit, panel.state.record
			if not war then
				return
			end
			local ro = type(war.roster) == "table" and war.roster or {}
			for _, p in ipairs(type(ro.signups) == "table" and ro.signups or {}) do
				if #edit.names >= GuildWars.MAX_ROSTER then
					break
				end
				if type(p) == "table" and p.name and not p.why and not private.Contains(edit.names, p.name) then
					tinsert(edit.names, p.name)
				end
			end
			panel.state.dirty = true
			GuildWars.PANELS.roster.refresh(panel, war, panel.ctx)
		end)
		panel.fill:SetPoint("TOPLEFT", 0, y)
		W:Explain(panel.fill, "Fill from sign-ups", "In sign-up order, up to 40. Those who can't be picked are skipped.")
		panel.allies = W:Button(panel, "Invite allies", "secondary", 120, 30, function()
			W:Dialog({ title = "Invite allies", text = "A guild of your side whose members can then sign up.", input = { placeholder = "Guild name" },
				confirmLabel = "Invite", cancelLabel = "Cancel",
				onConfirm = function(name)
					name = strtrim(name or "")
					if name ~= "" then
						GuildWars:Act("allies", panel.state.record.id, { guild = name })
					end
				end })
		end)
		panel.allies:SetPoint("LEFT", panel.fill, "RIGHT", 10, 0)
		W:Explain(panel.allies, "Invite allies", "Same-faction guilds; their members can then sign up.")
		panel.announce = W:Button(panel, "Announce", "secondary", 100, 30, function()
			local war = panel.state.record
			if not war then
				return
			end
			local start = type(war.time) == "table" and tonumber(war.time.start)
			SendChatMessage(format("Guild war: %s %s %s. Say you're in: /wanted, Guild Wars.", war.role == "defend" and "we defend" or "we attack",
				war.zone or "?", start and (date("%a ", start)..GuildWars:Clock(start)) or "soon"), "GUILD")
		end)
		panel.announce:SetPoint("LEFT", panel.allies, "RIGHT", 10, 0)
		W:Explain(panel.announce, "Announce", "A line in guild chat with the war and its time.")
		panel.open = Theme:Text(panel, "small", "")
		panel.open:SetPoint("LEFT", panel.announce, "RIGHT", 16, 0)
		panel.save = W:Button(panel, "Save roster", "primary", 120, 30, function()
			local edit, war = panel.state.edit, panel.state.record
			if not war then
				return
			end
			GuildWars:Act("roster", war.id, { names = edit.names, standby = edit.standby })
			panel.state.dirty = false
		end)
		panel.save:SetPoint("TOPRIGHT", 0, y)
		panel.status = Theme:Text(panel, "small", "")
		panel.status:SetPoint("TOPRIGHT", 0, y - 40)
	end,
	refresh = function(panel, war, ctx)
		panel.state.record, panel.ctx = war, ctx
		local ro = type(war.roster) == "table" and war.roster or {}
		local edit = private.Edit(panel, war)
		local people = private.People(war)
		local locked = type(ro.lockAt) == "number" and ctx.now >= ro.lockAt or war.step == "battle" or war.step == "result"
		local canEdit = ctx.officer and not ctx.looking and not locked
		local rival = tonumber(ro.rival)
		panel.label:SetText(strupper(format("Roster · %d of %d%s", #edit.names, GuildWars.MAX_ROSTER,
			rival and format(" · %s %d of %d", ctx.theirs.guild or "them", rival, GuildWars.MAX_ROSTER) or "")))
		panel.labelGlyph:ClearAllPoints()
		panel.labelGlyph:SetPoint("LEFT", panel.label, "LEFT", panel.label:GetStringWidth() + 6, 0)
		-- I'm in: the player's own sign-up (the latest ask counts until the site answers)
		local pendingIn = GuildWars:Pending("in", war.id)
		local me = type(ro.me) == "table" and ro.me or {}
		panel.mine:SetChecked(pendingIn and pendingIn.data.on or me["in"] == true)
		panel.mine:SetShown(not locked)
		-- The roster
		for i, row in ipairs(panel.rows) do
			local name = edit.names[i]
			row:SetShown(name ~= nil)
			if name then
				local p = people[name] or { name = name }
				row.who = name
				row.name:SetText(private.Name(p))
				row.rank:SetText(p.ally and ("<"..p.ally..">") or p.rank or "")
				row.status:SetText(p.app == false and Theme:Colorize("! app not seen", C.amber)
					or Theme:Colorize("✓", C.green)..(p.online == false and Theme:Colorize("  offline", C.faint) or "")..(p.ally and Theme:Colorize("  ally", C.blue) or ""))
				if p.app == false then
					W:Explain(row.status, "App not seen", "Their app hasn't been seen this week: their presence may not count.")
				end
				row.remove:SetShown(canEdit)
			end
		end
		panel.scroll:Fit(ceil(#edit.names / 2) * ROW)
		-- Sign-ups not picked: Add, or greyed with why
		local waiting = {}
		for _, p in ipairs(type(ro.signups) == "table" and ro.signups or {}) do
			if type(p) == "table" and p.name and not private.Contains(edit.names, p.name) then
				tinsert(waiting, p)
			end
		end
		panel.signupLabel:SetText(strupper(format("Said I'm in, not picked (%d)", #waiting)))
		for i, row in ipairs(panel.signups) do
			local p = waiting[i]
			row:SetShown(p ~= nil)
			if p then
				row.who = p.name
				row.name:SetText(private.Name(p))
				row:SetAlpha(p.why and 0.6 or 1)
				local who = p.ally and ("<"..p.ally..">") or p.rank or ""
				row.why:SetText(who..(p.why and ((who ~= "" and " · " or "")..Theme:Colorize(p.why, C.red)) or ""))
				if p.why then
					W:Explain(row.why, p.name, p.why)
				end
				row.add:SetShown(canEdit and not p.why and #edit.names < GuildWars.MAX_ROSTER)
			end
		end
		-- Standby
		panel.standbyLabel:SetText(strupper(format("Standby · %d", #edit.standby)))
		panel.standbyGlyph:ClearAllPoints()
		panel.standbyGlyph:SetPoint("LEFT", panel.standbyLabel, "LEFT", panel.standbyLabel:GetStringWidth() + 6, 0)
		for i, line in ipairs(panel.standby) do
			local name = edit.standby[i]
			line:SetText(name and (Theme:Colorize(i.."  ", C.muted)..private.Name(people[name] or { name = name })) or "")
		end
		-- The officers' buttons
		for _, button in ipairs({ panel.fill, panel.allies, panel.announce, panel.save }) do
			button:SetShown(canEdit)
		end
		panel.save:SetEnabled(ctx.app)
		W:Explain(panel.save, "Save roster", ctx.app and "Saved on the site; the roster locks when the battle starts." or "Start the Wanted app to save.")
		local open = GuildWars.MAX_ROSTER - #edit.names
		panel.open:SetText(canEdit and (open > 0 and format("%d place%s open", open, open == 1 and "" or "s") or "Full") or "")
		local pendingRoster = GuildWars:Pending("roster", war.id)
		panel.status:SetText(locked and "Locked: the battle has started."
			or pendingRoster and not panel.state.dirty and Theme:Colorize("Sent; waiting for the site", C.amber)
			or panel.state.dirty and Theme:Colorize("Not saved yet", C.amber)
			or not ctx.officer and "Officers pick the roster. Say you're in with I'm in." or "")
	end,
}
