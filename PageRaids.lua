-- Wanted: the Raids page. Form a world PvP raid (now, or at a time), lead it (Announce in chat, whisper the sign-ups,
-- Edit, Close), and join the raids other Wanted players of your faction are forming: click one to join, or mark a
-- planned one Interested or Going.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Raids = Wanted.Raids
local private = { size = 40, later = false, guild = false, exclusive = false, editing = false, serverTime = false, day = 0 }
local ROW_HEIGHT = 42
local CARD_HEIGHT = 140
local FORM_HEIGHT = 144 -- how it works is in the tooltips of the controls it explains

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
	-- A planned raid: Interested and Going, clicked again to take it back
	row.going = W:Button(row, "Going", "chip", 70, 22, function() private.SignUp(row.item, "going") end)
	row.going:SetPoint("RIGHT", -14, 0)
	row.interested = W:Button(row, "Interested", "chip", 90, 22, function() private.SignUp(row.item, "interested") end)
	row.interested:SetPoint("RIGHT", row.going, "LEFT", -6, 0)
end

function private.SignUp(raid, kind)
	if not raid then
		return
	end
	local why = Raids:SignUp(raid.id, Raids:Interest(raid.id) ~= kind and kind or nil)
	if why then
		UI:Toast(why, C.red)
	end
	private.Refresh()
end

function private.UpdateRow(row, raid)
	local started = raid.startAt <= GetServerTime()
	row.title:SetText(Raids:Title(raid)..Theme:Colorize("  "..raid.where, C.muted))
	local when = started and "Forming now" or ("Starts "..Raids:When(raid.startAt))
	local count = format("%d/%d", raid.members, raid.size)..(raid.signups > 0 and format(", %d going", raid.signups) or "")
		..((raid.interested or 0) > 0 and format(", %d interested", raid.interested) or "")
	row.sub:SetText(format("%s  -  %s  -  led by %s  -  level %d+", when, count, raid.leader, raid.minLevel))
	-- Hovering it: who's going, asking its leader the first time
	W:Explain(row, Raids:Title(raid), function() return private.RaidRoster(raid) end, "ANCHOR_RIGHT")
	local planned = not started and raid.members < raid.size
	row.going:SetShown(planned)
	row.interested:SetShown(planned)
	if planned then
		local kind = Raids:Interest(raid.id)
		row.going:SetStyle(kind == "going" and "selected" or "chip")
		row.interested:SetStyle(kind == "interested" and "selected" or "chip")
		row.action:SetText("")
	elseif Raids:Joined(raid.id) then
		row.action:SetText(Theme:Colorize("Joined", C.green))
	elseif raid.members >= raid.size then
		row.action:SetText(Theme:Colorize("Full", C.muted))
	else
		row.action:SetText(Theme:Colorize("Click to join", C.gold))
	end
end

---A tooltip's body listing who's going and who's interested.
function private.Roster(going, interested, more)
	local function Add(label, names, color)
		return Theme:Colorize(format("%s (%d)", label, #names), color).."\n"..(#names > 0 and table.concat(names, ", ") or "Nobody yet")
	end
	local body = Add("Going", going, C.green).."\n\n"..Add("Interested", interested, C.gold)
	if more and more > 0 then
		body = body.."\n"..Theme:Colorize(format("and %d more", more), C.muted)
	end
	return body
end

---Another player's raid: who's going, asking its leader the first time (until they answer, says so).
function private.RaidRoster(raid)
	local roster = Raids:Roster(raid.id)
	if not roster then
		return "Asking the leader who's going..."
	end
	return private.Roster(roster.going or {}, roster.interested or {}, roster.more)
end

---The form, or the raid we lead.
function private.RefreshCard()
	local mine = Raids:Mine()
	if not mine then
		private.editing = false
	end
	local formShown = not mine or private.editing
	private.form:SetShown(formShown)
	private.lead:SetShown(not formShown)
	-- The list sits under whichever card shows
	private.list:ClearAllPoints()
	private.list:SetPoint("TOPLEFT", formShown and private.form or private.lead, "BOTTOMLEFT", 0, -12)
	private.list:SetPoint("TOPRIGHT", formShown and private.form or private.lead, "BOTTOMRIGHT", 0, -12)
	if formShown then
		private.formLabel:SetText(private.editing and "EDIT YOUR RAID" or "FORM A RAID")
		private.go:SetText(private.editing and "Save changes" or "Form raid")
		if private.editing then
			W:Explain(private.go, "Save changes", "Everyone signed up is told what changed.")
		else
			W:Explain(private.go, "Form raid", "Every Wanted player of your faction sees it, on every realm, in their own time.")
		end
		private.cancelEdit:SetShown(private.editing)
		private.timeBox:SetShown(private.later)
		private.zoneChoice:SetShown(private.later)
		private.dayChoice:SetShown(private.later)
		-- Named by the clock the time is in, afresh (the window may stay open past midnight)
		private.dayChoice:SetChoices(private.Days())
		private.dayChoice:SetChoice(private.day)
		return
	end
	local started = mine.startAt <= GetServerTime()
	private.leadTitle:SetText(Raids:Title(mine)..Theme:Colorize("  "..mine.where, C.muted))
	local going, interested = Raids:SignUps(mine)
	local group = IsInGroup() and max(1, GetNumGroupMembers()) or 1
	private.leadSub:SetText(format("%s  -  %d/%d in your group  -  %d going, %d interested", started and "Forming now" or ("Starts "..Raids:When(mine.startAt)),
		group, mine.size, #going, #interested))
	local names = {}
	if #going > 0 then
		tinsert(names, "Going: "..table.concat(going, ", "))
	end
	if #interested > 0 then
		tinsert(names, "Interested: "..table.concat(interested, ", "))
	end
	private.leadNames:SetText(table.concat(names, "   "))
	W:Explain(private.signups, "Signed up for "..Raids:Title(mine), function()
		return private.Roster(Raids:SignUps(Raids:Mine() or mine))
	end, "ANCHOR_RIGHT")
	private.openButton:SetShown(mine.exclusive == true)
	-- In someone else's group without assist: invites wait until we can send them
	private.cantInvite:SetShown(not Raids:CanInvite())
	local formNow = Raids:CanFormNow()
	private.formNow:SetShown(formNow)
	private.sendInvites:SetShown(formNow)
end

---The day picker's days: today and the six after, on the calendar of the clock the time is typed in (as ParseTime
---counts them).
function private.Days()
	local offset = private.serverTime and Raids:ServerOffset() or 0
	local base = date("*t", GetServerTime() + offset)
	local days = {}
	for d = 0, 6 do
		local t = { year = base.year, month = base.month, day = base.day + d, hour = 12 }
		tinsert(days, { key = d, label = d == 0 and "Today" or d == 1 and "Tomorrow" or date("%a %d", time(t)) })
	end
	return days
end

---Edit: the form, filled in with the raid we lead.
function private.Edit()
	local mine = Raids:Mine()
	if not mine then
		return
	end
	private.editing = true
	private.titleBox:SetValue(mine.title)
	private.whereBox:SetValue(mine.where)
	private.levelBox:SetValue(tostring(mine.minLevel))
	private.later = mine.startAt > GetServerTime()
	private.when:Select(private.later and "later" or "now", true)
	local offset = private.serverTime and Raids:ServerOffset() or 0
	private.timeBox:SetValue(date("%H:%M", mine.startAt + offset))
	-- Its day, counted in the calendar from today
	local function DayNumber(t)
		local d = date("*t", t + offset)
		return floor(time({ year = d.year, month = d.month, day = d.day, hour = 12 }) / 86400)
	end
	private.day = max(0, min(6, DayNumber(mine.startAt) - DayNumber(GetServerTime())))
	private.dayChoice:SetChoice(private.day)
	private.size = mine.size
	private.sizeChoice:SetChoice(mine.size)
	private.guild = mine.guild ~= nil
	private.guildToggle:SetChecked(private.guild)
	private.exclusive = mine.exclusive == true
	private.exclusiveToggle:SetChecked(private.exclusive)
	private.Refresh()
end

function private.Refresh()
	if not private.list then
		return
	end
	-- Shown here (with the window open, not just the last page): no longer new, so the menu's count goes
	if UI:IsShown() and Raids:MarkSeen() then
		UI:Refresh(true)
		return
	end
	private.RefreshCard()
	private.list:SetItems(Raids:List(), "No raids forming right now.",
		"Raids other Wanted players of your faction form show here. Form one above, and everyone with Wanted sees it.")
end

function private.Form()
	local startAt
	if private.later then
		startAt = Raids:ParseTime(private.timeBox:GetText(), private.serverTime, private.day)
		if not startAt then
			UI:Toast("Type a start time like 20:00.", C.red)
			return
		end
	end
	local o = { title = private.titleBox:GetText(), where = private.whereBox:GetText(), startAt = startAt,
		size = private.size, minLevel = private.levelBox:GetText(), guild = private.guild, exclusive = private.exclusive }
	if private.editing then
		local why = Raids:Update(o)
		if why then
			UI:Toast(why, C.red)
			return
		end
		private.editing = false
		UI:Toast("Raid changed.", C.green)
		private.Refresh()
		return
	end
	local raid, why = Raids:Create(o)
	if not raid then
		UI:Toast(why, C.red)
		return
	end
	UI:Toast("Raid formed.", C.green)
	private.Refresh()
end

function private.BuildForm(parent)
	local form = W:Card(parent)
	form:SetPoint("TOPLEFT")
	form:SetPoint("TOPRIGHT")
	form:SetHeight(FORM_HEIGHT)
	private.formLabel = W:SectionLabel(form, "Form a raid")
	private.formLabel:SetPoint("TOPLEFT", 14, -10)
	private.titleBox = W:Input(form, 200, "Name, e.g. Southshore raid")
	private.titleBox:SetPoint("TOPLEFT", 14, -36)
	private.titleBox:SetMaxLetters(Raids.MAX_TEXT)
	private.whereBox = W:Input(form, 170, "Where (your zone)")
	private.whereBox:SetPoint("LEFT", private.titleBox, "RIGHT", 8, 0)
	private.whereBox:SetMaxLetters(Raids.MAX_TEXT)
	W:Suggest(private.whereBox, function() return Raids:Zones() end)
	private.levelBox = W:Input(form, 90, "Min. level")
	private.levelBox:SetPoint("LEFT", private.whereBox, "RIGHT", 8, 0)
	local when = W:Segmented(form, {
		{ key = "now", label = "Now", tip = { "Now", "Anyone who clicks Join is invited straight away." } },
		{ key = "later", label = "Later", tip = { "Later", "Players mark Interested or Going, and it's on their calendar and yours. "
			.."Invite or whisper them all from your raid's card." } },
	}, function(key)
		private.later = key == "later"
		private.RefreshCard()
	end, 70)
	when:SetPoint("TOPLEFT", 14, -74)
	when:Select("now", true)
	private.when = when
	-- Later: which day (today and the six after), then the time
	private.dayChoice = W:Choice(form, 100, private.Days(), function(key)
		private.day = key
	end)
	private.dayChoice:SetChoice(0)
	private.dayChoice:SetPoint("LEFT", when, "RIGHT", 8, 0)
	private.timeBox = W:Input(form, 70, "20:00")
	private.timeBox:SetPoint("LEFT", private.dayChoice, "RIGHT", 6, 0)
	-- The time typed: ours, or the realm's
	private.zoneChoice = W:Choice(form, 130, { { key = false, label = "Your time "..Raids:ZoneName() }, { key = true, label = "Server time" } }, function(key)
		private.serverTime = key
		private.RefreshCard()
	end)
	private.zoneChoice:SetChoice(false)
	private.zoneChoice:SetPoint("LEFT", private.timeBox, "RIGHT", 6, 0)
	W:Explain(private.zoneChoice, "Which clock the time is in", function()
		local now = GetServerTime()
		return format("Your time now: %s %s. Server time now: %s.\n\nEveryone sees the raid in their own time, with the server's beside it.",
			date("%H:%M", now), Raids:ZoneName(), date("%H:%M", now + Raids:ServerOffset()))
	end)
	local size = W:Choice(form, 90, { { key = 10, label = "10" }, { key = 20, label = "20" }, { key = 40, label = "40" } }, function(key)
		private.size = key
	end)
	size:SetChoice(40)
	private.sizeChoice = size
	size:SetPoint("LEFT", private.levelBox, "RIGHT", 8, 0)
	local guild = W:Toggle(form, "Guild raid", function(checked)
		private.guild = checked
	end)
	guild:SetPoint("TOPLEFT", 14, -114)
	private.guildToggle = guild
	local exclusive = W:Toggle(form, "Guild only", function(checked)
		private.exclusive = checked
	end)
	exclusive:SetPoint("LEFT", guild, "RIGHT", 12, 0)
	W:Explain(exclusive, "Guild only", "Only your guildmates with Wanted see it, Announce posts in guild chat, and only guildmates "
		.."are invited. Open it to everyone later from your raid's card.")
	private.exclusiveToggle = exclusive
	W:Explain(guild, "Guild raid", "Shows the raid with your guild's name: The Duskwood Takeover with <Your Guild>.")
	local go = W:Button(form, "Form raid", "primary", 120, 26, private.Form)
	go:SetPoint("TOPRIGHT", -14, -74)
	private.go = go
	private.cancelEdit = W:Button(form, "Cancel", "ghost", 80, 26, function()
		private.editing = false
		private.Refresh()
	end)
	private.cancelEdit:SetPoint("TOPRIGHT", -14, -10)
	return form
end

---Announce: shows the line and where it goes first, editable; Post sends it, Cancel sends nothing.
function private.ConfirmAnnounce()
	local targets = Raids:AnnounceTargets()
	if #targets == 0 then
		UI:Toast("You're not in a guild or any chat channel.", C.red)
		return
	end
	local guildOnly = Raids:Mine() and Raids:Mine().exclusive
	local labels = {}
	for _, t in ipairs(targets) do
		labels[t.key] = t.label
	end
	W:Dialog({
		title = "Announce your raid",
		text = guildOnly and "The raid is guild only: only guildmates who whisper you \"inv\" are invited until you open it to everyone."
			or "Anyone who whispers you \"inv\" is invited.",
		choice = { label = "Post in", items = targets, selected = labels[Raids:AnnounceTarget()] and Raids:AnnounceTarget() or targets[1].key },
		input = { value = Raids:AnnounceText() or "", multiline = true },
		width = 520,
		confirmLabel = "Post",
		cancelLabel = "Cancel",
		onConfirm = function(text, target)
			local why, ready = Raids:Announce(text, target)
			UI:Toast(why or (ready and "In your chat box: press Enter to post it in "..(labels[target] or "chat").."." or "Posted in "..(labels[target] or "chat").."."), why and C.red or C.green)
		end,
	})
end

---Whisper sign-ups: shows the whisper and who gets it first, editable; Send whispers each of them.
function private.ConfirmWhisper()
	local mine = Raids:Mine()
	local going, interested = Raids:SignUps(mine)
	if #going + #interested == 0 then
		UI:Toast("Nobody has signed up yet.", C.red)
		return
	end
	local names = {}
	for _, list in ipairs({ going, interested }) do
		for _, name in ipairs(list) do
			tinsert(names, name)
		end
	end
	W:Dialog({
		title = "Whisper your sign-ups",
		text = format("This goes to the %d who signed up (%s).", #names, table.concat(names, ", ")),
		input = { value = Raids:WhisperText() or "", multiline = true },
		width = 520,
		confirmLabel = "Send",
		cancelLabel = "Cancel",
		onConfirm = function(text)
			local why = Raids:WhisperSignUps(text)
			UI:Toast(why or format("Whispering %d players.", #names), why and C.red or C.green)
		end,
	})
end

---Invite sign-ups: who gets an invite, then Invite sends them.
function private.ConfirmInvite()
	local going, interested = Raids:SignUps(Raids:Mine())
	if #going + #interested == 0 then
		UI:Toast("Nobody has signed up yet.", C.red)
		return
	end
	local who = {}
	if #going > 0 then
		tinsert(who, "going: "..table.concat(going, ", "))
	end
	if #interested > 0 then
		tinsert(who, "interested: "..table.concat(interested, ", "))
	end
	W:Dialog({
		title = "Invite your sign-ups",
		text = format("Send a group invite to the %d who signed up (%s)?", #going + #interested, table.concat(who, "; ")),
		confirmLabel = "Invite",
		cancelLabel = "Cancel",
		onConfirm = function()
			local why = Raids:InviteSignUps()
			UI:Toast(why or "Inviting your sign-ups.", why and C.red or C.green)
		end,
	})
end

function private.BuildLead(parent, width)
	local lead = W:Card(parent)
	-- TODO(ui-pass PR 3): a compact W:StepBar here (Formed > Sign-ups > Starting > Started, sub-lines the time,
	-- "12 going", "invites sent") in place of the Forming / Starts part of leadSub, once the widget exists
	lead:SetPoint("TOPLEFT")
	lead:SetPoint("TOPRIGHT")
	lead:SetHeight(CARD_HEIGHT)
	W:SectionLabel(lead, "Your raid"):SetPoint("TOPLEFT", 14, -10)
	private.leadTitle = Theme:Text(lead, "heading", "")
	private.leadTitle:SetPoint("TOPLEFT", 14, -36)
	private.leadTitle:SetWidth(420)
	private.leadSub = Theme:Text(lead, "small", "")
	private.leadSub:SetPoint("TOPLEFT", 14, -58)
	private.leadSub:SetWidth(width - 28)
	private.leadNames = Theme:Text(lead, "tiny", "", C.muted)
	private.leadNames:SetPoint("TOPLEFT", 14, -76)
	private.leadNames:SetWidth(width - 28)
	private.leadNames:SetWordWrap(false)
	private.cantInvite = Theme:Text(lead, "small", "Can't invite: you're not the group's leader or an assistant", C.red)
	private.cantInvite:SetPoint("TOPLEFT", 14, -94)
	private.cantInvite:SetWidth(width - 28)
	private.cantInvite:SetWordWrap(false)
	private.cantInvite:Hide()
	W:Explain(private.cantInvite, "Can't invite", "You're in a group without being its leader or an assistant. Invites wait until you are.")
	-- Hovering the sign-ups: everyone, going and interested (the tooltip is set with the raid, in RefreshCard)
	local signups = CreateFrame("Frame", nil, lead)
	signups:SetPoint("TOPLEFT", private.leadSub, "TOPLEFT")
	signups:SetPoint("BOTTOMRIGHT", private.leadNames, "BOTTOMRIGHT")
	private.signups = signups
	local announce = W:Button(lead, "Announce", "secondary", 100, 26, private.ConfirmAnnounce)
	announce:SetPoint("BOTTOMLEFT", 14, 10)
	W:AttachTooltip(announce, "Announce in chat", "Posts the raid in Looking for Group (or the zone's General) for players without Wanted. Anyone who whispers you \"inv\" is invited.")
	local close = W:Button(lead, "Close raid", "danger", 100, 26, function()
		Raids:Close()
		private.Refresh()
	end)
	W:Explain(close, "Close raid", "Ends it for everyone signed up; they're told.")
	local invite = W:Button(lead, "Invite sign-ups", "secondary", 130, 26, private.ConfirmInvite)
	invite:SetPoint("LEFT", announce, "RIGHT", 8, 0)
	W:AttachTooltip(invite, "Invite sign-ups", "Sends a group invite to everyone going or interested. Your group becomes a raid as they join.")
	local whisper = W:Button(lead, "Whisper sign-ups", "secondary", 140, 26, private.ConfirmWhisper)
	whisper:SetPoint("LEFT", invite, "RIGHT", 8, 0)
	W:AttachTooltip(whisper, "Whisper sign-ups", "Whispers everyone going or interested, with a message you can change first.")
	local edit = W:Button(lead, "Edit", "secondary", 70, 26, private.Edit)
	edit:SetPoint("LEFT", whisper, "RIGHT", 8, 0)
	W:AttachTooltip(edit, "Edit the raid", "Change its name, place, time, size or level. Everyone signed up is told what changed.")
	close:SetPoint("LEFT", edit, "RIGHT", 8, 0)
	-- A guild-only raid: open it to everyone once the guild has filled what it will
	private.openButton = W:Button(lead, "Open to everyone", "primary", 140, 26, function()
		Raids:OpenToEveryone()
		UI:Toast("Your raid is open to everyone.", C.green)
		private.Refresh()
	end)
	private.openButton:SetPoint("TOPRIGHT", -14, -44)
	-- From 15 minutes before a planned raid: form it now, inviting the sign-ups if ticked
	private.formNow = W:Button(lead, "Form raid now", "primary", 130, 26, function()
		Raids:FormNow(private.sendInvites.checked)
		UI:Toast("Raid formed.", C.green)
		private.Refresh()
	end)
	private.formNow:SetPoint("TOPRIGHT", -14, -10)
	W:AttachTooltip(private.formNow, "Form raid now", "From 15 minutes before the start. Starts your raid now: everyone signed up gets a popup to join. "
		.."With Send invites ticked, they're invited too.")
	private.sendInvites = W:Toggle(lead, "Send invites")
	private.sendInvites:SetChecked(true)
	private.sendInvites:SetPoint("RIGHT", private.formNow, "LEFT", -10, 0)
	W:AttachTooltip(private.openButton, "Open to everyone", "Shows your guild-only raid to every Wanted player of your faction, so others can fill the spots left.")
	return lead
end

UI:RegisterPage("raids", {
	group = "World PvP",
	title = "Raids",
	order = 3,
	-- Raids not looked at yet
	badge = function()
		local unseen = Raids:Unseen()
		return unseen > 0 and unseen or nil, C.blue
	end,
	build = function(container, width, height)
		private.form = private.BuildForm(container)
		private.lead = private.BuildLead(container, width)
		local listTop = FORM_HEIGHT + 12
		local list = W:List(container, ROW_HEIGHT, floor((height - listTop) / ROW_HEIGHT), private.CreateRow, private.UpdateRow)
		list.onEnter = function(row, raid)
			private.hovered = { row = row, raid = raid }
		end
		-- The leader's answer came while the raid is hovered: show it (explaining it again redraws the tooltip)
		Raids:OnRosterUpdate(function(id)
			local h = private.hovered
			if h and h.raid.id == id and h.row.item == h.raid and h.row:IsMouseOver() then
				W:Explain(h.row, Raids:Title(h.raid), function() return private.RaidRoster(h.raid) end, "ANCHOR_RIGHT")
			end
		end)
		list.onClick = function(raid)
			-- A planned raid has its Interested and Going buttons
			if Raids:Joined(raid.id) or raid.startAt > GetServerTime() then
				return
			end
			local why = Raids:Join(raid.id)
			UI:Toast(why or "Asked to join.", why and C.red or C.green)
			private.Refresh()
		end
		private.list = list
		private.Refresh()
	end,
	refresh = private.Refresh,
})
