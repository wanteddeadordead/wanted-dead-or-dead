-- Wanted: the Raids page. Form a world PvP raid (now, or at a time), lead it (Announce in chat, Close), and join the
-- raids other Wanted players of your faction are forming: click one to join, or to sign up for a planned one.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Raids = Wanted.Raids
local private = { size = 40, later = false }
local ROW_HEIGHT = 42
local CARD_HEIGHT = 120

---A time typed as "20:00", "8:30" or "20" as the next such time (server seconds), or nil.
---@param text string
---@return number?
function private.ParseTime(text)
	local h, m = strmatch(text or "", "^%s*(%d%d?):(%d%d)%s*$")
	if not h then
		h, m = strmatch(text or "", "^%s*(%d%d?)%s*$"), "0"
	end
	h, m = tonumber(h), tonumber(m)
	if not h or h > 23 or m > 59 then
		return nil
	end
	local now = GetServerTime()
	local t = date("*t", now)
	t.hour, t.min, t.sec = h, m, 0
	local at = time(t)
	if at <= now then
		at = at + 24 * 3600
	end
	return at
end

function private.CreateRow(row)
	row.title = Theme:Text(row, "body", "")
	row.title:SetPoint("TOPLEFT", 14, -8)
	row.title:SetWidth(420)
	row.sub = Theme:Text(row, "tiny", "")
	row.sub:SetPoint("TOPLEFT", 14, -26)
	row.sub:SetWidth(420)
	row.action = Theme:Text(row, "small", "")
	row.action:SetPoint("RIGHT", -14, 0)
	row.action:SetJustifyH("RIGHT")
end

function private.UpdateRow(row, raid)
	local started = raid.startAt <= GetServerTime()
	row.title:SetText(raid.title..Theme:Colorize("  "..raid.where, C.muted))
	local when = started and "Forming now" or ("Starts "..date("%a %H:%M", raid.startAt))
	local count = format("%d/%d", raid.members, raid.size)..(raid.signups > 0 and format(", %d signed up", raid.signups) or "")
	row.sub:SetText(format("%s  -  %s  -  led by %s  -  level %d+", when, count, raid.leader, raid.minLevel))
	if Raids:Joined(raid.id) then
		row.action:SetText(Theme:Colorize(started and "Joined" or "Signed up", C.green))
	elseif raid.members >= raid.size then
		row.action:SetText(Theme:Colorize("Full", C.muted))
	else
		row.action:SetText(Theme:Colorize(started and "Click to join" or "Click to sign up", C.gold))
	end
end

---The form, or the raid we lead.
function private.RefreshCard()
	local mine = Raids:Mine()
	private.form:SetShown(not mine)
	private.lead:SetShown(mine ~= nil)
	if not mine then
		private.timeBox:SetShown(private.later)
		return
	end
	local started = mine.startAt <= GetServerTime()
	private.leadTitle:SetText(mine.title..Theme:Colorize("  "..mine.where, C.muted))
	local names = {}
	for name in pairs(mine.signups) do
		tinsert(names, name)
	end
	sort(names)
	local group = IsInGroup() and max(1, GetNumGroupMembers()) or 1
	private.leadSub:SetText(format("%s  -  %d/%d in your group%s", started and "Forming now" or ("Starts "..date("%a %H:%M", mine.startAt)),
		group, mine.size, #names > 0 and ("  -  signed up: "..table.concat(names, ", ")) or ""))
end

function private.Refresh()
	if not private.list then
		return
	end
	private.RefreshCard()
	private.list:SetItems(Raids:List(), "No raids forming right now.",
		"Raids other Wanted players of your faction form show here. Form one above, and everyone with Wanted sees it.")
end

function private.Form()
	local startAt
	if private.later then
		startAt = private.ParseTime(private.timeBox:GetText())
		if not startAt then
			UI:Toast("Type a start time like 20:00.", C.red)
			return
		end
	end
	local raid, why = Raids:Create({ title = private.titleBox:GetText(), where = private.whereBox:GetText(), startAt = startAt,
		size = private.size, minLevel = private.levelBox:GetText() })
	if not raid then
		UI:Toast(why, C.red)
		return
	end
	UI:Toast("Raid formed. Wanted players of your faction can see it now.", C.green)
	private.Refresh()
end

function private.BuildForm(parent, width)
	local form = W:Card(parent)
	form:SetPoint("TOPLEFT")
	form:SetPoint("TOPRIGHT")
	form:SetHeight(CARD_HEIGHT)
	W:SectionLabel(form, "Form a raid"):SetPoint("TOPLEFT", 14, -10)
	private.titleBox = W:Input(form, 200, "Name, e.g. Southshore raid")
	private.titleBox:SetPoint("TOPLEFT", 14, -36)
	private.whereBox = W:Input(form, 170, "Where (your zone)")
	private.whereBox:SetPoint("LEFT", private.titleBox, "RIGHT", 8, 0)
	private.levelBox = W:Input(form, 90, "Min. level")
	private.levelBox:SetPoint("LEFT", private.whereBox, "RIGHT", 8, 0)
	local when = W:Segmented(form, { { key = "now", label = "Now" }, { key = "later", label = "Later" } }, function(key)
		private.later = key == "later"
		private.RefreshCard()
	end, 70)
	when:SetPoint("TOPLEFT", 14, -74)
	when:Select("now", true)
	private.timeBox = W:Input(form, 90, "20:00")
	private.timeBox:SetPoint("LEFT", when, "RIGHT", 8, 0)
	local size = W:Choice(form, 90, { { key = 10, label = "10" }, { key = 20, label = "20" }, { key = 40, label = "40" } }, function(key)
		private.size = key
	end)
	size:SetChoice(40)
	size:SetPoint("LEFT", private.timeBox, "RIGHT", 8, 0)
	local go = W:Button(form, "Form raid", "primary", 110, 26, private.Form)
	go:SetPoint("TOPRIGHT", -14, -74)
	return form
end

---Announce: shows the line and where it goes first, editable; Post sends it, Cancel sends nothing.
function private.ConfirmAnnounce()
	local index, channel = Raids:AnnounceChannel()
	if not index then
		UI:Toast("You're not in a Looking for Group or General channel.", C.red)
		return
	end
	W:Dialog({
		title = "Announce your raid",
		text = format("This goes in %s (channel %d), where players without Wanted see it. Anyone who whispers you \"inv\" is invited. Change it if you like:",
			channel, index),
		input = { value = Raids:AnnounceText() or "", multiline = true },
		width = 520,
		confirmLabel = "Post",
		cancelLabel = "Cancel",
		onConfirm = function(text)
			local why = Raids:Announce(text)
			UI:Toast(why or "Posted in "..channel..".", why and C.red or C.green)
		end,
	})
end

function private.BuildLead(parent)
	local lead = W:Card(parent)
	lead:SetPoint("TOPLEFT")
	lead:SetPoint("TOPRIGHT")
	lead:SetHeight(CARD_HEIGHT)
	W:SectionLabel(lead, "Your raid"):SetPoint("TOPLEFT", 14, -10)
	private.leadTitle = Theme:Text(lead, "heading", "")
	private.leadTitle:SetPoint("TOPLEFT", 14, -36)
	private.leadTitle:SetWidth(560)
	private.leadSub = Theme:Text(lead, "small", "")
	private.leadSub:SetPoint("TOPLEFT", 14, -58)
	private.leadSub:SetWidth(560)
	local announce = W:Button(lead, "Announce", "secondary", 110, 26, private.ConfirmAnnounce)
	announce:SetPoint("BOTTOMLEFT", 14, 12)
	W:AttachTooltip(announce, "Announce in chat", "Posts the raid in Looking for Group (or the zone's General) for players without Wanted. Anyone who whispers you \"inv\" is invited.")
	local close = W:Button(lead, "Close raid", "danger", 110, 26, function()
		Raids:Close()
		private.Refresh()
	end)
	close:SetPoint("LEFT", announce, "RIGHT", 8, 0)
	return lead
end

UI:RegisterPage("raids", {
	group = "World PvP",
	title = "Raids",
	subtitle = "Form a world PvP raid, or join one: everyone with Wanted on your faction sees it, and the leader invites you.",
	order = 3,
	build = function(container, width, height)
		private.form = private.BuildForm(container, width)
		private.lead = private.BuildLead(container)
		local listTop = CARD_HEIGHT + 12
		local list = W:List(container, ROW_HEIGHT, floor((height - listTop) / ROW_HEIGHT), private.CreateRow, private.UpdateRow)
		list:SetPoint("TOPLEFT", 0, -listTop)
		list:SetPoint("TOPRIGHT", 0, -listTop)
		list.onClick = function(raid)
			if Raids:Joined(raid.id) then
				return
			end
			local why = Raids:Join(raid.id)
			UI:Toast(why or (raid.startAt <= GetServerTime() and "Asked to join: the leader invites you." or "Signed up: you'll be invited when it starts."),
				why and C.red or C.green)
			private.Refresh()
		end
		private.list = list
		private.Refresh()
	end,
	refresh = private.Refresh,
})
