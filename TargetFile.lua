-- Wanted: the file on a wanted player. Everything the records and sightings hold about where to find
-- them: who they are and what's on their head, where they were last seen, the zones they keep to and the
-- hours they're usually about, every sighting by you and other Wanted users, and their deaths. For a
-- bounty on a whole guild, the members and all their sightings. Hunts can take days; this is the file a
-- hunter works from.

local _, Wanted = ...
local TargetFile = {}
Wanted.TargetFile = TargetFile
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Store = Wanted.Store
local Bounties = Wanted.Bounties
local Tracks = Wanted.Tracks
local private = {}
local WIDTH, HEIGHT = 780, 540
local ROW_HEIGHT = 20
local LEFT_WIDTH = 340



-- ============================================================================
-- Window
-- ============================================================================

function private.Section(parent, text, anchor, gap)
	local label = W:SectionLabel(parent, text)
	label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(gap or 16))
	return label
end

function private.Body(parent, anchor, color)
	local text = Theme:Text(parent, "small", "", color or C.text)
	text:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -5)
	text:SetWidth(LEFT_WIDTH)
	text:SetJustifyH("LEFT")
	text:SetWordWrap(true)
	text:SetSpacing(3)
	return text
end

function private.Create()
	local frame = CreateFrame("Frame", "WantedTargetFile", UIParent)
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetClampedToScreen(true)
	Theme:Skin(frame, C.panel, C.borderLight)
	tinsert(UISpecialFrames, "WantedTargetFile")
	frame:Hide()
	local bar = frame:CreateTexture(nil, "ARTWORK")
	bar:SetPoint("TOPLEFT", 1, -1)
	bar:SetPoint("TOPRIGHT", -1, -1)
	bar:SetHeight(3)
	bar:SetColorTexture(C.red[1], C.red[2], C.red[3], 1)
	local close = W:Button(frame, "X", "ghost", 28, 28, function() frame:Hide() end)
	close:SetPoint("TOPRIGHT", -8, -8)

	frame.name = Theme:Text(frame, "heading", "")
	frame.name:SetPoint("TOPLEFT", 20, -20)
	frame.who = Theme:Text(frame, "small", "", C.muted)
	frame.who:SetPoint("TOPLEFT", frame.name, "BOTTOMLEFT", 0, -4)
	frame.money = Theme:Text(frame, "money", "")
	frame.money:SetPoint("TOPRIGHT", -48, -18)
	frame.bounty = Theme:Text(frame, "small", "", C.muted)
	frame.bounty:SetPoint("TOPRIGHT", frame.money, "BOTTOMRIGHT", 0, -4)
	frame.bounty:SetJustifyH("RIGHT")
	frame.bounty:SetWidth(420)

	frame.map = W:Button(frame, "Show on map", "secondary", 120, 26, function()
		if frame.mapId and OpenWorldMap and not InCombatLockdown() then
			frame:Hide()
			OpenWorldMap(frame.mapId)
		end
	end)
	frame.map:SetPoint("TOPLEFT", 20, -70)
	W:AttachTooltip(frame.map, "Show on map", "Opens the map on the zone they were last seen in. Markers show sightings from the last 30 minutes.")
	frame.post = W:Button(frame, "Add a bounty", "secondary", 120, 26, function()
		frame:Hide()
		Wanted.UI:Show("board")
		Wanted.BoardPage:PrefillTarget(frame.targetName)
	end)
	frame.post:SetPoint("LEFT", frame.map, "RIGHT", 6, 0)
	local divider = Theme:Line(frame)
	divider:SetPoint("TOPLEFT", 20, -106)
	divider:SetPoint("TOPRIGHT", -20, -106)

	-- Left: the summary
	local top = CreateFrame("Frame", nil, frame)
	top:SetSize(1, 1)
	top:SetPoint("TOPLEFT", 20, -104)
	frame.lastLabel = private.Section(frame, "Last seen", top, 12)
	frame.last = private.Body(frame, frame.lastLabel)
	frame.zonesLabel = private.Section(frame, "Usual zones", frame.last)
	frame.zones = private.Body(frame, frame.zonesLabel)
	frame.hoursLabel = private.Section(frame, "Usually about (your time)", frame.zones)
	frame.hours = private.Body(frame, frame.hoursLabel)
	frame.recordLabel = private.Section(frame, "Record", frame.hours)
	frame.record = private.Body(frame, frame.recordLabel)

	-- Right: every sighting
	frame.listLabel = W:SectionLabel(frame, "")
	frame.listLabel:SetPoint("TOPLEFT", 40 + LEFT_WIDTH, -118)
	local listTop = 136
	local list = W:List(frame, ROW_HEIGHT, floor((HEIGHT - listTop - 16) / ROW_HEIGHT), function(row)
		row.when = Theme:Text(row, "small", "", C.muted)
		row.when:SetPoint("LEFT", 6, 0)
		row.where = Theme:Text(row, "small", "", C.text)
		row.where:SetPoint("LEFT", 96, 0)
		row.where:SetWidth(200)
		row.where:SetWordWrap(false)
		row.by = Theme:Text(row, "tiny", "", C.faint)
		row.by:SetPoint("RIGHT", -8, 0)
	end, function(row, entry)
		row.when:SetText(date("%b %d %H:%M", entry.t))
		local where = entry.zone or "?"
		if entry.x then
			where = format("%s %.0f,%.0f", where, entry.x, entry.y)
		end
		if entry.name then
			where = Theme:ClassName(entry.name, entry.class).."  "..where
		end
		row.where:SetText(where)
		row.by:SetText(entry.by and ("by "..entry.by) or "by you")
	end)
	list:SetPoint("TOPLEFT", 40 + LEFT_WIDTH - 6, -listTop)
	list:SetPoint("TOPRIGHT", -14, -listTop)
	frame.list = list
	private.frame = frame
	return frame
end



-- ============================================================================
-- Filling it in
-- ============================================================================

function private.Ago(t)
	return Theme:Ago(GetServerTime() - t)
end

function private.Where(entry)
	local where = entry.zone or "?"
	if entry.x then
		where = format("%s (%.1f, %.1f)", where, entry.x, entry.y)
	end
	return where
end

---The bounties on a player (and on their guild), totalled.
function private.BountyText(bounties)
	local total, posters = 0, {}
	local expiry = 0
	local hunters = {}
	for _, bounty in ipairs(bounties) do
		total = total + Bounties:GetAmount(bounty)
		tinsert(posters, bounty.origin == Store:GetOrigin() and "you" or bounty.origin)
		expiry = max(expiry, Bounties:GetExpiry(bounty))
		for _, hunter in ipairs(Bounties:GetActiveHunters(bounty)) do
			hunters[hunter] = true
		end
	end
	local numHunters = 0
	for _ in pairs(hunters) do
		numHunters = numHunters + 1
	end
	if #bounties == 0 then
		return "", "No open bounty"
	end
	local text = format("From %s.  %s", table.concat(posters, ", "), Theme:Left(expiry - GetServerTime()))
	if numHunters > 0 then
		text = text..format(".  %d hunting", numHunters)
	end
	return Theme:Money(total), text
end

function private.FillSummary(frame, entries, deaths, stats)
	local summary = Tracks:Summarize(entries)
	local latest = entries[1]
	frame.mapId = latest and latest.mapId
	for _, entry in ipairs(entries) do
		if frame.mapId then
			break
		end
		frame.mapId = entry.mapId
	end
	frame.map:SetEnabled(frame.mapId ~= nil)
	if latest then
		frame.last:SetText(format("%s%s, %s, by %s", latest.name and (latest.name..", ") or "", private.Where(latest), private.Ago(latest.t), latest.by or "you"))
	else
		frame.last:SetText(Theme:Colorize("Not seen yet by you or another Wanted user.", C.faint))
	end
	local zones = {}
	for i = 1, min(#summary.zones, 5) do
		local z = summary.zones[i]
		tinsert(zones, format("%s  %s", z.zone, Theme:Colorize(format("%d sighting%s, last %s", z.count, z.count == 1 and "" or "s", private.Ago(z.last)), C.muted)))
	end
	frame.zones:SetText(#zones > 0 and table.concat(zones, "\n") or Theme:Colorize("Nothing yet.", C.faint))
	local hours = {}
	for _, window in ipairs(summary.hours) do
		tinsert(hours, format("%02d:00 to %02d:00  %s", window.from, window.to, Theme:Colorize(format("%d sighting%s", window.count, window.count == 1 and "" or "s"), C.muted)))
	end
	if summary.days > 0 then
		tinsert(hours, Theme:Colorize(format("Seen on %d day%s since %s.", summary.days, summary.days == 1 and "" or "s", date("%b %d", summary.first)), C.muted))
	end
	frame.hours:SetText(#hours > 0 and table.concat(hours, "\n") or Theme:Colorize("Nothing yet.", C.faint))
	local record = {}
	if stats then
		tinsert(record, format("You've won %d, they've won %d. You've seen them %d time%s.", stats.wins or 0, stats.losses or 0, stats.detections or 0, (stats.detections or 0) == 1 and "" or "s"))
	end
	if #deaths > 0 then
		local last = deaths[1]
		tinsert(record, format("Died %d time%s in the records, last %s in %s%s.", #deaths, #deaths == 1 and "" or "s", private.Ago(last.t), last.zone or "?", last.killer and (", killed by "..last.killer) or ""))
	else
		tinsert(record, "No deaths in the records yet.")
	end
	frame.record:SetText(table.concat(record, "\n"))
	frame.listLabel:SetText(strupper(format("Every sighting (%d)", #entries)))
	frame.list:SetItems(entries, "No sightings yet.", "They're added as you and other Wanted users see them.")
end

---Opens the file on one player.
---@param guid string
---@param name string?
function TargetFile:ShowPlayer(guid, name)
	local frame = private.frame or private.Create()
	local player = Store:GetPlayer(guid) or {}
	name = player.name or name or "?"
	frame.targetName = name
	frame.name:SetText(Theme:ClassName(name, player.class))
	local who = {}
	if player.level then
		tinsert(who, "Level "..(player.level == -1 and "??" or player.level))
	end
	tinsert(who, strtrim((player.race or "").." "..Theme:ClassLabel(player.class)))
	if type(player.guild) == "string" then
		tinsert(who, "<"..player.guild..">")
	end
	if player.faction then
		tinsert(who, player.faction)
	end
	frame.who:SetText(table.concat(who, "  "))
	local bounties = Bounties:GetOpenForTarget(guid)
	if type(player.guild) == "string" then
		for _, bounty in ipairs(Bounties:GetOpenForGuild(player.guild)) do
			tinsert(bounties, bounty)
		end
	end
	local money, text = private.BountyText(bounties)
	frame.money:SetText(money)
	frame.bounty:SetText(text)
	frame.post:SetText(#bounties > 0 and "Add a bounty" or "Post a bounty")
	frame.post:Show()
	local entries = Tracks:Get(guid)
	if #entries == 0 and player.lastSeen then
		-- No history kept yet: at least where the records last put them
		entries = { { t = player.lastSeen, zone = player.zone, mapId = player.mapId, x = player.x, y = player.y, by = player.seenBy } }
	end
	private.FillSummary(frame, entries, Tracks:GetDeaths(guid), Wanted.Enemies:GetStats(guid))
	frame:Show()
	frame:Raise()
end

---Opens the file on a guild with a bounty on it: its members' sightings together.
---@param guild string
function TargetFile:ShowGuild(guild)
	local frame = private.frame or private.Create()
	frame.targetName = nil
	frame.name:SetText(Theme:Colorize("<"..guild..">", C.amber))
	local members = Wanted.Model:GetGuildMembers(guild)
	frame.who:SetText(format("Bounty on any member. %d member%s seen.", #members, #members == 1 and "" or "s"))
	local money, text = private.BountyText(Bounties:GetOpenForGuild(guild))
	frame.money:SetText(money)
	frame.bounty:SetText(text)
	frame.post:Hide()
	local entries, deaths = {}, {}
	for _, member in ipairs(members) do
		for _, entry in ipairs(Tracks:Get(member.guid)) do
			-- A copy: the entries are the saved history itself
			tinsert(entries, { t = entry.t, zone = entry.zone, mapId = entry.mapId, x = entry.x, y = entry.y, by = entry.by, name = member.name, class = member.class })
		end
		for _, death in ipairs(Tracks:GetDeaths(member.guid)) do
			tinsert(deaths, death)
		end
	end
	sort(entries, function(a, b) return a.t > b.t end)
	sort(deaths, function(a, b) return a.t > b.t end)
	private.FillSummary(frame, entries, deaths, nil)
	frame:Show()
	frame:Raise()
end

---Opens the right file for a bounty (a Model bounty info).
---@param info table
function TargetFile:ShowBounty(info)
	if info.guild then
		TargetFile:ShowGuild(info.guild)
	elseif info.bounty and info.bounty.data.target then
		TargetFile:ShowPlayer(info.bounty.data.target, info.targetName)
	end
end

function TargetFile:IsShown()
	return private.frame and private.frame:IsShown() or false
end

Wanted:RegisterCommand("file", "The file on a player: where they've been, when they're about, their record. /wanted file <First Last>.", function(args)
	local name = strtrim(args or "")
	local guid, player
	if name == "" and UnitExists("target") and UnitIsPlayer("target") then
		guid, name = UnitGUID("target"), GetUnitName("target", true)
	else
		guid, player = Store:FindPlayerByName(name)
		name = player and player.name or name
	end
	if not guid then
		Wanted:Print("No player named %s has been seen. Target them, or check the spelling.", name ~= "" and name or "(none given)")
		return
	end
	TargetFile:ShowPlayer(guid, name)
end)
