-- Wanted: Guild Wars › one tab per war of the player's guild (war1, war2, war3), named by its zone. Each shows the
-- war's header (attack or defence, the zone and its holder, the headline, a countdown, both guilds' crests), the step
-- bar (Race > Declare > Draw > Time > Roster > Battle > Result) and the panel for the step the war is at; a done step's
-- dot opens its panel to look back. The panels are in the files after this one (GuildWars.PANELS). From the app's
-- catch-up (GuildWars); officers' choices are asked of the site through the app (GuildWars:Act).

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local GuildWars = Wanted.GuildWars
local Data = GuildWars.Page -- what the pages read: the tour's sample war while one is on (WarSample.lua)
local private = { tabs = {} }
local MAX_WARS = 3
local HEADER_HEIGHT, BAR_CARD = 88, 78
local GAP = 12
local STEPS = { "race", "declare", "draw", "time", "roster", "battle", "result" }
local STEP_INDEX = {}
for i, key in ipairs(STEPS) do
	STEP_INDEX[key] = i
end
local STEP_BAR = {
	{ "Race", "The influence race in the zone. The faction that doesn't hold it may declare when it ends." },
	{ "Declare", "Officers of a guild with 10% of its side's influence and 5 members with the app declare, with a stake, within 15 minutes of the race." },
	{ "Draw", "The site draws one declaring guild at 8:00 PM, weighted by influence and stake." },
	{ "Time", "The holders pick a half-hour start over the next two evenings; the attackers accept or withdraw." },
	{ "Roster", "Each guild picks up to 40. Only the roster takes and holds points." },
	{ "Battle", "15 minutes' prep, then 30 of battle: the lanes, then the keep." },
	{ "Result", "The site counts the result. The winner holds the zone, protected for 3 days." },
}
-- The panels, by step key: { build = fn(panel, width, height), refresh = fn(panel, war, ctx) }
GuildWars.PANELS = GuildWars.PANELS or {}
GuildWars.STEPS = STEPS

---The zone's short name for tabs and headlines: "Hillsbrad" for Hillsbrad Foothills.
function GuildWars:Short(zone)
	return type(zone) == "string" and (strmatch(zone, "^(%S+)") or zone) or "?"
end

---A war's side for this player: "attack" or "defend" (or "declare" before it's declared), and the two guilds as ours
---and theirs.
function private.Sides(war)
	local attacker = type(war.attacker) == "table" and war.attacker or {}
	local defender = type(war.defender) == "table" and war.defender or {}
	if war.role == "defend" then
		return defender, attacker
	end
	return attacker, defender
end

---"mm:ss" under an hour, "h:mm" under a day, else the day and time.
function private.Countdown(seconds, at)
	seconds = max(floor(seconds), 0)
	if seconds < 3600 then
		return format("%d:%02d", floor(seconds / 60), seconds % 60)
	elseif seconds < 86400 then
		return format("%d:%02d", floor(seconds / 3600), floor(seconds % 3600 / 60))
	end
	return date("%a ", at)..GuildWars:Clock(at)
end

---The header's headline, countdown and its caption for the war at its step.
function private.Headline(war, now)
	local ours, theirs = private.Sides(war)
	local attacker = type(war.attacker) == "table" and war.attacker.guild or "?"
	local short = GuildWars:Short(war.zone)
	local step = war.step
	local d, dr, t, b, r = war.declare or {}, war.draw or {}, war.time or {}, war.battle or {}, war.result or {}
	if step == "declare" then
		return "Declare war on "..short, d.closesAt, "left to declare"
	elseif step == "draw" then
		if dr.drawn == true then
			return format("Drawn: %s attacks %s", attacker, short), t.deadline, format("for %s to pick", theirs.guild or "the holders")
		elseif dr.drawn == false then
			return "Not drawn", nil, nil
		end
		return format("%s declared on %s", ours.guild or "?", short), dr.at, "to the draw"
	elseif step == "time" then
		if type(t.start) == "number" then
			-- More than a day off, the countdown shows the day and time; within a day, the time left
			return format("%s attacks %s", attacker, short), t.start, t.start - now >= 86400 and "the war's time" or "until the war"
		end
		return format("%s attacks %s", attacker, short), t.deadline, war.role == "defend" and "left to choose" or format("for %s to pick", theirs.guild or "the holders")
	elseif step == "roster" then
		return format("%s attacks %s", attacker, short), b.prep, "to prep"
	elseif step == "battle" then
		if type(b.start) == "number" and now < b.start then
			return "Prep: the war starts soon", b.start, "to the battle"
		end
		return "The war is on", b.stop, "battle left"
	elseif step == "result" then
		if r.void or r.cancelled then
			return r.void and "Void: no war" or "Cancelled", nil, nil
		elseif r.won == nil then
			return "The site is counting", nil, nil
		end
		local winner = r.won and ours.guild or theirs.guild
		local took = (war.role == "attack") == (r.won == true)
		return format("%s %s %s", winner or "?", took and "took" or "held", short), nil, nil
	end
	return war.zone or "?", nil, nil
end

---The header's top line: ATTACK · HILLSBRAD FOOTHILLS · HELD BY REVENANT (ALLIANCE).
function private.Kicker(war)
	local defender = type(war.defender) == "table" and war.defender or {}
	local role = war.role == "defend" and "Defence" or "Attack"
	local held = war.step == "result" and type(war.result) == "table" and war.result.won ~= nil
		and ("now "..(((war.role == "attack") == (war.result.won == true)) and (war.attacker and war.attacker.guild or "?") or (defender.guild or "?")).."'s")
		or war.role == "defend" and "your zone"
		or (defender.guild and format("held by %s (%s)", defender.guild, defender.faction or "?") or "unclaimed")
	return strupper(format("%s · %s · %s", role, war.zone or "?", held))
end

---The step bar's sub-lines: when each step happened or happens.
function private.Notes(war)
	local d, dr, t, ro, b, r = war.declare or {}, war.draw or {}, war.time or {}, war.roster or {}, war.battle or {}, war.result or {}
	local function At(v, prefix)
		return type(v) == "number" and ((prefix or "")..GuildWars:Clock(v)) or ""
	end
	return {
		type(war.race) == "table" and At(war.race.at) or "",
		type(d.mine) == "table" and At(d.mine.at) or At(d.closesAt, "by "),
		At(dr.at),
		type(t.start) == "number" and (date("%a ", t.start)..GuildWars:Clock(t.start)) or At(t.deadline, "by "),
		type(ro.count) == "number" and format("%d of %d", ro.count, GuildWars.MAX_ROSTER) or At(ro.lockAt, "locks at "),
		war.step == "battle" and "now" or (type(b.start) == "number" and type(b.stop) == "number" and (gsub(GuildWars:Clock(b.start), " [AP]M$", "").." to "..GuildWars:Clock(b.stop))) or "",
		r.won == true and "won" or r.won == false and "lost" or "",
	}
end



-- ============================================================================
-- A war's tab
-- ============================================================================

function private.BuildTab(container, width, height, index)
	local tab = { index = index, panels = {} }
	-- The header
	local header = W:Card(container)
	tab.header = header
	header:SetPoint("TOPLEFT")
	header:SetSize(width, HEADER_HEIGHT)
	tab.kicker = Theme:Text(header, "labelSmall", "")
	tab.kicker:SetPoint("TOPLEFT", 16, -14)
	tab.title = Theme:Text(header, "title", "")
	tab.title:SetPoint("TOPLEFT", 16, -34)
	tab.title:SetWidth(width - 360)
	tab.title:SetWordWrap(false)
	tab.crests = {}
	for i = 1, 2 do
		local crest = CreateFrame("Frame", nil, header)
		crest:SetSize(76, 72)
		crest:SetPoint("TOPRIGHT", -16 - (2 - i) * 84, -8)
		crest.icon = crest:CreateTexture(nil, "ARTWORK")
		crest.icon:SetSize(44, 44)
		crest.icon:SetPoint("TOP", 0, -4)
		crest.name = Theme:Text(crest, "small", "", C.text)
		crest.name:SetPoint("TOP", crest.icon, "BOTTOM", 0, -4)
		crest.name:SetWidth(80)
		crest.name:SetWordWrap(false)
		tab.crests[i] = crest
	end
	local divider = header:CreateTexture(nil, "BORDER")
	divider:SetColorTexture(1, 1, 1, 0.07)
	divider:SetSize(1, HEADER_HEIGHT - 24)
	divider:SetPoint("TOPRIGHT", -16 - 2 * 84 - 6, -12)
	tab.clock = Theme:Text(header, "stat", "", C.gold)
	tab.clock:SetPoint("TOPRIGHT", -16 - 2 * 84 - 22, -20)
	tab.clock:SetJustifyH("RIGHT")
	tab.caption = Theme:Text(header, "small", "")
	tab.caption:SetPoint("TOPRIGHT", -16 - 2 * 84 - 22, -54)
	tab.caption:SetJustifyH("RIGHT")
	tab.pill = W:Pill(header)
	tab.pill:SetPoint("TOPRIGHT", -16 - 2 * 84 - 22, -18)
	-- The step bar: a done step's dot opens its panel; the current one comes back to the war's own
	local barCard = W:Card(container)
	tab.barCard = barCard
	barCard:SetPoint("TOPLEFT", 0, -HEADER_HEIGHT - GAP)
	barCard:SetSize(width, BAR_CARD)
	tab.bar = W:StepBar(barCard, width - 32, STEP_BAR, function(step)
		tab.viewing = STEPS[step]
		private.RefreshTab(tab)
	end)
	tab.bar:SetPoint("TOPLEFT", 16, -8)
	-- The panels, one per step, in the room left
	local top = -HEADER_HEIGHT - GAP - BAR_CARD - GAP
	for key, def in pairs(GuildWars.PANELS) do
		local panel = CreateFrame("Frame", nil, container)
		panel:SetPoint("TOPLEFT", 0, top)
		panel:SetSize(width, height + top)
		panel.tab = tab
		def.build(panel, width, height + top)
		panel:Hide()
		tab.panels[key] = panel
	end
	tab.none = Theme:Text(container, "body", "", C.muted)
	tab.none:SetPoint("TOP", 0, top - 40)
	private.tabs[index] = tab
	return tab
end

function private.RefreshTab(tab)
	local war = Data:War(tab.index)
	if not war then
		return
	end
	local now = GetServerTime()
	local ours, theirs = private.Sides(war)
	tab.kicker:SetText(private.Kicker(war))
	local headline, at, caption = private.Headline(war, now)
	tab.title:SetText(headline)
	local result = war.step == "result" and type(war.result) == "table" and war.result.won ~= nil
	tab.pill:Set(result and (war.result.won and "WON" or "LOST") or nil, result and (war.result.won and C.green or C.red) or nil)
	tab.clock:SetShown(not result)
	tab.clock:SetText(type(at) == "number" and private.Countdown(at - now, at) or "")
	tab.caption:SetText(result and (type(war.result.at) == "number" and (GuildWars:Clock(war.result.at)..", the site's count") or "the site's count") or caption or "")
	for i, guild in ipairs({ ours, theirs }) do
		local crest = tab.crests[i]
		crest:SetShown(guild.guild ~= nil)
		crest.icon:SetTexture(GuildWars:CrestFile(guild))
		crest.name:SetText(guild.guild or "")
	end
	-- The step bar: where the war is, a failed step marked (not drawn, withdrawn)
	local current = STEP_INDEX[war.step] or 1
	local failed
	if type(war.draw) == "table" and war.draw.drawn == false then
		failed = { [STEP_INDEX.draw] = true }
	elseif type(war.time) == "table" and war.time.withdrawn then
		failed = { [STEP_INDEX.time] = true }
	end
	tab.bar:Set(result and #STEPS + 1 or current, private.Notes(war), failed)
	-- The panel: the step looked back at, else the war's own
	-- (Start the roster opens the Roster step early, while the time is still being set)
	local early = tab.early == "roster" and tab.viewing == "roster" and (war.step == "draw" or war.step == "time")
	local view = tab.viewing and STEP_INDEX[tab.viewing] and (STEP_INDEX[tab.viewing] < current or early) and tab.viewing or war.step
	local ctx = { now = now, ours = ours, theirs = theirs, officer = Data:AmOfficer(), app = Wanted:HasApp(), looking = view ~= war.step }
	local shown = false
	for key, panel in pairs(tab.panels) do
		panel:SetShown(key == view)
		if key == view then
			shown = true
			GuildWars.PANELS[key].refresh(panel, war, ctx)
		end
	end
	tab.none:SetShown(not shown)
	tab.none:SetText(shown and "" or "Nothing to show for this step yet.")
end

function private.Refresh()
	for _, tab in pairs(private.tabs) do
		if tab.container:IsVisible() then
			private.RefreshTab(tab)
		end
	end
end

---A war's badge: WON or LOST for a day after the result, LIVE from prep to the end, the minutes to prep in the hour
---before, and "!" while a war officer of ours must act (declare, pick the time, accept or withdraw).
---@return string? badge
---@return table? color
function private.Badge(war, now)
	local b, r, t = war.battle or {}, war.result or {}, war.time or {}
	if war.step == "result" and r.won ~= nil then
		return r.won and "WON" or "LOST", r.won and C.green or C.red
	elseif type(b.prep) == "number" and now >= b.prep and now < (b.stop or 0) then
		return "LIVE", C.green
	elseif type(b.prep) == "number" and now >= b.prep - 3600 and now < b.prep and war.step ~= "result" then
		return format("%dm", ceil((b.prep - now) / 60)), C.gold
	end
	if not Data:AmOfficer() then
		return nil
	end
	local d = war.declare or {}
	local must = war.step == "declare" and not d.mine and type(d.closesAt) == "number" and now < d.closesAt and not Data:Pending("declare", war.id)
		or war.state == "awaiting_time" and war.role == "defend" and not Data:Pending("time", war.id)
		or war.state == "awaiting_answer" and war.role == "attack" and not t.accepted and not t.withdrawn and not Data:Pending("answer", war.id)
	if must then
		return "!", C.amber
	end
	return nil
end
GuildWars.Badge = function(_, war, now) return private.Badge(war, now or GetServerTime()) end

for index = 1, MAX_WARS do
	UI:RegisterPage("war"..index, {
		title = "War",
		-- Named by its zone
		tabLabel = function()
			local war = Data:War(index)
			if not war then
				return "War"
			end
			-- Its badge on the tab too (tab buttons draw no badge of their own)
			local badge, color = private.Badge(war, GetServerTime())
			return GuildWars:Short(war.zone)..(badge and (" "..Theme:Colorize(badge, color)) or "")
		end,
		tabTip = { "A war of your guild's", "Members see this page without its buttons. It closes 24 hours after the result; the war stays in the guild's history on the site." },
		under = "guildwars",
		order = -2,
		hidden = function() return Data:War(index) == nil end,
		badge = function()
			local war = Data:War(index)
			if war then
				return private.Badge(war, GetServerTime())
			end
			return nil
		end,
		build = function(container, width, height)
			local tab = private.BuildTab(container, width, height, index)
			tab.container = container
			-- The clocks tick while the tab is up
			local elapsed = 0
			container:SetScript("OnUpdate", function(_, dt)
				elapsed = elapsed + dt
				if elapsed >= 1 then
					elapsed = 0
					private.RefreshTab(tab)
				end
			end)
			GuildWars:OnChange(function()
				if container:IsVisible() then
					private.RefreshTab(tab)
				end
			end)
			private.RefreshTab(tab)
		end,
		refresh = function()
			local tab = private.tabs[index]
			if tab then
				private.RefreshTab(tab)
			end
		end,
	})
end

-- The tour's war stops border these (Tour): the first war's header, step bar and lanes
UI:Mark("warheader", function() return private.tabs[1] and private.tabs[1].header end)
UI:Mark("warbar", function() return private.tabs[1] and private.tabs[1].barCard end)
UI:Mark("warlanes", function()
	local panel = private.tabs[1] and private.tabs[1].panels.battle
	return panel and panel.lanesCard
end)
UI:Mark("warturnout", function()
	local panel = private.tabs[1] and private.tabs[1].panels.battle
	return panel and panel.lanesCard
end)

-- For the panels: the shared bits
GuildWars.Sides = function(_, war) return private.Sides(war) end
