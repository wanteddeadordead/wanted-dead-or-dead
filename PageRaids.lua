-- Wanted: the Raids page. Form a world PvP raid (now, or at a time), lead it (Announce in chat, whisper the sign-ups,
-- Edit, Close), and join the raids other Wanted players of your faction are forming: click one to join, or mark a
-- planned one Interested or Going.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Raids = Wanted.Raids
local private = { size = 40, later = false, guild = false, editing = false }
local ROW_HEIGHT = 42
local CARD_HEIGHT = 120
local FORM_HEIGHT = 172 -- the form, with how it works under it
local HOW_IT_WORKS = "How it works: every Wanted player of your faction sees your raid, on every realm. Form it Now and "
	.."anyone who clicks Join is invited straight away. Form it for Later and players mark Interested or Going: you see "
	.."who, you can whisper them all, and when it starts they get a popup asking them to join. If you edit or close it, "
	.."they're told what changed. Announce posts it in chat for players without Wanted, who whisper you \"inv\" to be invited."

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
	local when = started and "Forming now" or ("Starts "..date("%a %H:%M", raid.startAt))
	local count = format("%d/%d", raid.members, raid.size)..(raid.signups > 0 and format(", %d going", raid.signups) or "")
		..((raid.interested or 0) > 0 and format(", %d interested", raid.interested) or "")
	row.sub:SetText(format("%s  -  %s  -  led by %s  -  level %d+", when, count, raid.leader, raid.minLevel))
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
		private.cancelEdit:SetShown(private.editing)
		private.timeBox:SetShown(private.later)
		return
	end
	local started = mine.startAt <= GetServerTime()
	private.leadTitle:SetText(Raids:Title(mine)..Theme:Colorize("  "..mine.where, C.muted))
	local going, interested = Raids:SignUps(mine)
	local group = IsInGroup() and max(1, GetNumGroupMembers()) or 1
	private.leadSub:SetText(format("%s  -  %d/%d in your group  -  %d going, %d interested", started and "Forming now" or ("Starts "..date("%a %H:%M", mine.startAt)),
		group, mine.size, #going, #interested))
	local names = {}
	if #going > 0 then
		tinsert(names, "Going: "..table.concat(going, ", "))
	end
	if #interested > 0 then
		tinsert(names, "Interested: "..table.concat(interested, ", "))
	end
	private.leadNames:SetText(table.concat(names, "   "))
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
	private.timeBox:SetValue(date("%H:%M", mine.startAt))
	private.size = mine.size
	private.sizeChoice:SetChoice(mine.size)
	private.guild = mine.guild ~= nil
	private.guildToggle:SetChecked(private.guild)
	private.Refresh()
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
	local o = { title = private.titleBox:GetText(), where = private.whereBox:GetText(), startAt = startAt,
		size = private.size, minLevel = private.levelBox:GetText(), guild = private.guild }
	if private.editing then
		local why = Raids:Update(o)
		if why then
			UI:Toast(why, C.red)
			return
		end
		private.editing = false
		UI:Toast("Raid changed. Everyone signed up sees what changed.", C.green)
		private.Refresh()
		return
	end
	local raid, why = Raids:Create(o)
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
	form:SetHeight(FORM_HEIGHT)
	private.formLabel = W:SectionLabel(form, "Form a raid")
	private.formLabel:SetPoint("TOPLEFT", 14, -10)
	private.titleBox = W:Input(form, 200, "Name, e.g. Southshore raid")
	private.titleBox:SetPoint("TOPLEFT", 14, -36)
	private.whereBox = W:Input(form, 170, "Where (your zone)")
	private.whereBox:SetPoint("LEFT", private.titleBox, "RIGHT", 8, 0)
	W:Suggest(private.whereBox, function() return Raids:Zones() end)
	private.levelBox = W:Input(form, 90, "Min. level")
	private.levelBox:SetPoint("LEFT", private.whereBox, "RIGHT", 8, 0)
	local when = W:Segmented(form, { { key = "now", label = "Now" }, { key = "later", label = "Later" } }, function(key)
		private.later = key == "later"
		private.RefreshCard()
	end, 70)
	when:SetPoint("TOPLEFT", 14, -74)
	when:Select("now", true)
	private.when = when
	private.timeBox = W:Input(form, 90, "20:00")
	private.timeBox:SetPoint("LEFT", when, "RIGHT", 8, 0)
	local size = W:Choice(form, 90, { { key = 10, label = "10" }, { key = 20, label = "20" }, { key = 40, label = "40" } }, function(key)
		private.size = key
	end)
	size:SetChoice(40)
	private.sizeChoice = size
	size:SetPoint("LEFT", private.timeBox, "RIGHT", 8, 0)
	local guild = W:Toggle(form, "Guild raid", function(checked)
		private.guild = checked
	end)
	guild:SetPoint("LEFT", size, "RIGHT", 12, 0)
	private.guildToggle = guild
	guild.tooltipTitle, guild.tooltipText = "Guild raid", "Shows the raid with your guild's name: The Duskwood Takeover with <Your Guild>."
	local go = W:Button(form, "Form raid", "primary", 120, 26, private.Form)
	go:SetPoint("TOPRIGHT", -14, -74)
	private.go = go
	private.cancelEdit = W:Button(form, "Cancel", "ghost", 80, 26, function()
		private.editing = false
		private.Refresh()
	end)
	private.cancelEdit:SetPoint("TOPRIGHT", -14, -10)
	local how = Theme:Text(form, "tiny", HOW_IT_WORKS, C.muted)
	how:SetPoint("TOPLEFT", 14, -112)
	how:SetWidth(width - 28)
	how:SetWordWrap(true)
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
		text = format("This goes to the %d who signed up (%s). Change it if you like:", #names, table.concat(names, ", ")),
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
	private.leadNames = Theme:Text(lead, "tiny", "", C.muted)
	private.leadNames:SetPoint("TOPLEFT", 14, -76)
	private.leadNames:SetWidth(560)
	private.leadNames:SetWordWrap(false)
	local announce = W:Button(lead, "Announce", "secondary", 110, 26, private.ConfirmAnnounce)
	announce:SetPoint("BOTTOMLEFT", 14, 10)
	W:AttachTooltip(announce, "Announce in chat", "Posts the raid in Looking for Group (or the zone's General) for players without Wanted. Anyone who whispers you \"inv\" is invited.")
	local close = W:Button(lead, "Close raid", "danger", 110, 26, function()
		Raids:Close()
		private.Refresh()
	end)
	local whisper = W:Button(lead, "Whisper sign-ups", "secondary", 140, 26, private.ConfirmWhisper)
	whisper:SetPoint("LEFT", announce, "RIGHT", 8, 0)
	W:AttachTooltip(whisper, "Whisper sign-ups", "Whispers everyone going or interested, with a message you can change first.")
	local edit = W:Button(lead, "Edit", "secondary", 80, 26, private.Edit)
	edit:SetPoint("LEFT", whisper, "RIGHT", 8, 0)
	W:AttachTooltip(edit, "Edit the raid", "Change its name, place, time, size or level. Everyone signed up is told what changed.")
	close:SetPoint("LEFT", edit, "RIGHT", 8, 0)
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
		local listTop = FORM_HEIGHT + 12
		local list = W:List(container, ROW_HEIGHT, floor((height - listTop) / ROW_HEIGHT), private.CreateRow, private.UpdateRow)
		list.onClick = function(raid)
			-- A planned raid has its Interested and Going buttons
			if Raids:Joined(raid.id) or raid.startAt > GetServerTime() then
				return
			end
			local why = Raids:Join(raid.id)
			UI:Toast(why or "Asked to join: the leader invites you.", why and C.red or C.green)
			private.Refresh()
		end
		private.list = list
		private.Refresh()
	end,
	refresh = private.Refresh,
})
