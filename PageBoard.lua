-- Wanted: the board page. Post a bounty at the top, filter below it, and the bounties that matter to
-- the player listed with the one or two things they can do about each.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Store = Wanted.Store
local Bounties = Wanted.Bounties
local Model = Wanted.Model
local Rows = Wanted.Rows
local Board = {}
Wanted.BoardPage = Board
local private = {}
local QUICK_AMOUNTS = { { "25s", 2500 }, { "50s", 5000 }, { "1g", 10000 }, { "5g", 50000 } }
local MIN_BOUNTY = 1000



-- ============================================================================
-- Post form
-- ============================================================================

function private.BuildPostCard(parent, width)
	local card = W:Card(parent)
	card:SetPoint("TOPLEFT")
	card:SetSize(width, 124)
	local label = W:SectionLabel(card, "Post a bounty")
	label:SetPoint("TOPLEFT", 16, -14)
	private.preview = Theme:Text(card, "small", "")
	private.preview:SetPoint("TOPRIGHT", -16, -13)
	private.preview:SetJustifyH("RIGHT")

	private.targetBox = W:Input(card, 210, "Player name", private.OnFormChanged)
	private.targetBox:SetPoint("TOPLEFT", 16, -34)
	local useTarget = W:Button(card, "Use my target", "secondary", 116, 26, function()
		if UnitExists("target") and UnitIsPlayer("target") then
			private.targetBox:SetValue(GetUnitName("target", true))
			private.OnFormChanged()
		else
			UI:Toast("Target an enemy player first.", C.amber)
		end
	end)
	useTarget:SetPoint("LEFT", private.targetBox, "RIGHT", 6, 0)
	W:AttachTooltip(useTarget, "Use my target", "Fills in the player you have targeted.")

	private.amountBox = W:Input(card, 120, "Amount, e.g. 1g", private.OnFormChanged)
	private.amountBox:SetPoint("LEFT", useTarget, "RIGHT", 16, 0)
	private.amountBox.onEnter = private.Post
	local post = W:Button(card, "Post bounty", "primary", 124, 26, private.Post)
	post:SetPoint("LEFT", private.amountBox, "RIGHT", 8, 0)
	private.postButton = post

	local quickLabel = Theme:Text(card, "tiny", "Quick")
	quickLabel:SetPoint("TOPLEFT", 16, -76)
	local previous = quickLabel
	for _, quick in ipairs(QUICK_AMOUNTS) do
		local chip = W:Button(card, quick[1], "chip", 44, 20, function()
			private.amountBox:SetValue(Bounties:FormatMoney(quick[2]))
			private.OnFormChanged()
		end)
		chip:SetPoint("LEFT", previous, "RIGHT", previous == quickLabel and 10 or 5, 0)
		previous = chip
	end
	private.guildToggle = W:Toggle(card, "Their whole guild", private.OnFormChanged)
	private.guildToggle:SetPoint("LEFT", previous, "RIGHT", 24, 0)
	W:AttachTooltip(private.guildToggle, "Their whole guild", "Put the bounty on every member of the player's guild. The first kill of any member claims it.")
	private.rate = Theme:Text(card, "tiny", "")
	private.rate:SetPoint("TOPLEFT", 16, -100)
	private.rate:SetPoint("RIGHT", card, "RIGHT", -16, 0)
	return card
end

---What the form's name means, if anything.
function private.ResolveForm()
	local name = strtrim(private.targetBox:GetText() or "")
	if name == "" then
		return nil
	end
	local guid, resolvedName = Bounties:ResolveName(name)
	return guid, resolvedName or name
end

---The guild the form targets when "Their whole guild" is ticked, or nil.
function private.GetFormGuild(player)
	return private.guildToggle and private.guildToggle.checked and player and player.guild or nil
end

function private.OnFormChanged()
	local guid, name = private.ResolveForm()
	local amount = Bounties:ParseMoney(private.amountBox:GetText())
	local player = guid and Store:GetPlayer(guid)
	local guild = private.GetFormGuild(player)
	local text = strtrim(private.targetBox:GetText() or "")
	if text == "" then
		private.preview:SetText("Target an enemy, or type the name of one you've seen.")
		private.preview:SetTextColor(unpack(C.faint))
	elseif not guid then
		private.preview:SetText("Not seen yet. Target them or mouse over them once.")
		private.preview:SetTextColor(unpack(C.amber))
	elseif player and player.faction and player.faction == UnitFactionGroup("player") then
		private.preview:SetText(name.." is on your side. Bounties are for the other faction.")
		private.preview:SetTextColor(unpack(C.amber))
	elseif private.guildToggle.checked and not guild then
		private.preview:SetText(name.." isn't in a guild, as far as Wanted has seen.")
		private.preview:SetTextColor(unpack(C.amber))
	elseif guild then
		private.preview:SetText(Theme:Colorize("<"..guild..">", C.amber)..Theme:Colorize(format("  any member, %d seen so far", #Model:GetGuildMembers(guild)), C.muted))
	else
		local seen = player and player.lastSeen and (", seen "..Theme:Ago(GetServerTime() - player.lastSeen).." in "..(player.zone or "?")) or ""
		local guildText = player and player.guild and ("  <"..player.guild..">") or ""
		private.preview:SetText(Theme:ClassName(name, player and player.class)..Theme:Colorize(format("  level %s %s%s%s", player and player.level or "?", Theme:ClassLabel(player and player.class), guildText, seen), C.muted))
	end
	private.rate:SetText(player and Model:GetGoingRate(player.level, amount) or "")
	-- A target you already have a bounty on gets a raise instead of a second bounty
	local existing = nil
	if guild then
		existing = Bounties:GetMyOpenGuild(guild)
	elseif guid then
		existing = Bounties:GetMyOpen(guid)
	end
	private.postButton:SetText(existing and "Add to bounty" or "Post bounty")
	if existing then
		private.rate:SetText(format("You already have %s on them; this adds to it.", Theme:Money(Bounties:GetAmount(existing))))
	end
	local minimum = existing and 1 or MIN_BOUNTY
	local canPost = guid and amount and amount >= minimum and not (player and player.faction == UnitFactionGroup("player")) and not (private.guildToggle.checked and not guild)
	private.postButton:SetEnabled(canPost and true or false)
end

function private.Post()
	local guid, name = private.ResolveForm()
	local amount = Bounties:ParseMoney(private.amountBox:GetText())
	if not guid then
		UI:Toast("Pick a player you've seen: target them, or mouse over them once.", C.amber)
		return
	elseif not amount or (amount < MIN_BOUNTY and not Bounties:GetMyOpen(guid)) then
		UI:Toast("A bounty is at least "..Bounties:FormatMoney(MIN_BOUNTY)..".", C.amber)
		return
	end
	local player = Store:GetPlayer(guid)
	local guild = private.GetFormGuild(player)
	local existing = guild and Bounties:GetMyOpenGuild(guild) or (not guild and Bounties:GetMyOpen(guid)) or nil
	local shownName = guild and Theme:Colorize("<"..guild..">", C.amber) or Theme:ClassName(name, player and player.class)
	if existing then
		local total = Bounties:GetAmount(existing) + amount
		W:Dialog({
			title = "Add to your bounty?",
			text = format("You already have a bounty on %s. Adding %s brings it to %s and gives it a fresh 7 days.", shownName, Theme:Money(amount), Theme:Money(total)),
			confirmLabel = "Add to bounty",
			onConfirm = function()
				Bounties:Raise(existing, amount)
				private.targetBox:SetValue("")
				private.amountBox:SetValue("")
				private.OnFormChanged()
				UI:Toast(format("Your bounty on %s is now %s.", guild and ("<"..guild..">") or name, Bounties:FormatMoney(total)), C.green)
				UI:Refresh()
			end,
		})
		return
	end
	W:Dialog({
		title = guild and "Post a guild bounty?" or "Post this bounty?",
		text = guild
			and format("%s on any member of %s. The first kill of any member claims it. It stays up for 7 days, and you confirm the kill and pay by mail.", Theme:Money(amount), shownName)
			or format("%s on %s. It stays up for 7 days. When someone claims it, you confirm the kill and pay them by mail.", Theme:Money(amount), shownName),
		confirmLabel = "Post bounty",
		onConfirm = function()
			local bounty, err
			if guild then
				bounty, err = Bounties:PostGuild(guild, player and player.faction, amount)
			else
				bounty, err = Bounties:Post(guid, name, amount)
			end
			if not bounty then
				UI:Toast("Couldn't post: "..err..".", C.red)
				return
			end
			private.targetBox:SetValue("")
			private.amountBox:SetValue("")
			private.OnFormChanged()
			UI:Toast(format("Posted %s on %s. Hunters running Wanted will see it.", Bounties:FormatMoney(amount), guild and ("<"..guild..">") or name), C.green)
			UI:Refresh()
		end,
	})
end

---Puts a player into the form (e.g. from the activity page).
---@param name string
function Board:PrefillTarget(name)
	if private.targetBox then
		private.targetBox:SetValue(name)
		private.OnFormChanged()
		private.amountBox:SetFocus()
	end
end



-- ============================================================================
-- Filters and list
-- ============================================================================

function private.BuildFilters(parent, width)
	local bar = CreateFrame("Frame", nil, parent)
	bar:SetPoint("TOPLEFT", 0, -138)
	bar:SetSize(width, 26)
	private.search = W:Input(bar, 180, "Search by name", function() private.RefreshList() end)
	private.search:SetPoint("LEFT")
	private.minBox = W:Input(bar, 110, "Min. amount", function(text)
		Wanted.db.settings.minBounty = Bounties:ParseMoney(text) or 0
		private.RefreshList()
	end)
	private.minBox:SetPoint("LEFT", private.search, "RIGHT", 8, 0)
	private.zoneToggle = W:Toggle(bar, "This zone only", function(checked)
		Wanted.db.settings.zoneFilter = checked and GetZoneText() or nil
		private.RefreshList()
	end)
	private.zoneToggle:SetPoint("LEFT", private.minBox, "RIGHT", 16, 0)
	W:AttachTooltip(private.zoneToggle, "This zone only", "Only bounties on players last seen where you are now.")
	private.passedToggle = W:Toggle(bar, "Show passed", function(checked)
		Wanted.db.settings.showPassed = checked
		private.RefreshList()
	end)
	private.passedToggle:SetPoint("LEFT", private.zoneToggle, "RIGHT", 16, 0)
	private.count = Theme:Text(bar, "small", "")
	private.count:SetPoint("RIGHT", 0, 0)
	private.count:SetJustifyH("RIGHT")
end

function private.RefreshList()
	if not private.list then
		return
	end
	local settings = Wanted.db.settings
	local items = Model:GetBoard({
		search = private.search:GetText(),
		minAmount = settings.minBounty or 0,
		zone = settings.zoneFilter,
		showPassed = settings.showPassed,
	})
	local total = 0
	for _, info in ipairs(items) do
		if info.state == Model.STATE.OPEN then
			total = total + info.amount
		end
	end
	private.count:SetText(#items == 0 and "" or format("%d bount%s  -  %s open", #items, #items == 1 and "y" or "ies", Theme:Money(total)))
	private.list:SetItems(items, "No bounties on the board.", "Post one above, or clear the filters.")
end



-- ============================================================================
-- Page
-- ============================================================================

UI:RegisterPage("board", {
	title = "Board",
	subtitle = "Bounties on enemy players. Kill the target and the claim files itself; the poster pays by mail.",
	order = 1,
	build = function(container, width, height)
		private.BuildPostCard(container, width)
		private.BuildFilters(container, width)
		local listTop = 176
		local numRows = floor((height - listTop) / Rows.HEIGHT)
		local list = W:List(container, Rows.HEIGHT, numRows, function(row) Rows:Create(row) end, function(row, info) Rows:UpdateBounty(row, info) end)
		list:SetPoint("TOPLEFT", 0, -listTop)
		list:SetPoint("TOPRIGHT", 0, -listTop)
		list.onEnter = function(row, info) Rows:ShowBountyTooltip(row, info) end
		list.onClick = function(info) Wanted.TargetFile:ShowBounty(info) end
		private.list = list
		private.OnFormChanged()
	end,
	refresh = function()
		local settings = Wanted.db.settings
		if not private.minBox:HasFocus() then
			private.minBox:SetValue(settings.minBounty and settings.minBounty > 0 and Bounties:FormatMoney(settings.minBounty) or "")
		end
		private.zoneToggle:SetChecked(settings.zoneFilter ~= nil)
		private.passedToggle:SetChecked(settings.showPassed)
		private.OnFormChanged()
		private.RefreshList()
	end,
})
