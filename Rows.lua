-- Wanted: the bounty row used on the board and the "your bounties" page, the tooltip that explains a
-- row, and what each row button does (with a confirmation where the action matters).

local _, Wanted = ...
local Rows = {}
Wanted.Rows = Rows
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Store = Wanted.Store
local Bounties = Wanted.Bounties
local Payments = Wanted.Payments
local Reputation = Wanted.Reputation
local Model = Wanted.Model

local ACTION_BUTTONS = {
	raise = { label = "Raise", style = "secondary", tip = "Add gold to your bounty." },
	withdraw = { label = "Withdraw", style = "ghost", tip = "Take your bounty down. Only possible while nobody is hunting or has claimed it." },
	hunt = { label = "Hunt", style = "primary", tip = "Tell everyone you're going after this target. For the next 2 hours the poster can't withdraw the bounty." },
	stophunt = { label = "Stop", style = "ghost", tip = "Stop hunting. The poster can withdraw the bounty again once nobody is hunting it." },
	renew = { label = "Renew", style = "secondary", tip = "Start your 2 hours again, keeping the bounty locked while you hunt." },
	pass = { label = "Pass", style = "ghost", tip = "Hide this bounty from your board, e.g. because it pays too little." },
	confirm = { label = "Confirm", style = "success", tip = "Agree the kill happened. You then owe the hunter the bounty." },
	dispute = { label = "Dispute", style = "danger", tip = "Say the claim is false. It goes on the hunter's record and the bounty opens again." },
	pay = { label = "Pay", style = "primary", tip = "Fill in a mail to the hunter at a mailbox. You check it and press Send." },
}
local ROW_HEIGHT = 50
Rows.HEIGHT = ROW_HEIGHT



-- ============================================================================
-- Row
-- ============================================================================

function Rows:Create(row)
	row.money = Theme:Text(row, "money", "")
	row.money:SetPoint("LEFT", 14, 0)
	row.money:SetWidth(118)
	row.name = Theme:Text(row, "body", "")
	row.name:SetPoint("TOPLEFT", 140, -9)
	row.name:SetWidth(250)
	row.detail = Theme:Text(row, "tiny", "")
	row.detail:SetPoint("TOPLEFT", 140, -29)
	row.detail:SetWidth(252)
	row.pill = W:Pill(row)
	row.pill:SetPoint("TOPLEFT", 404, -8)
	row.seen = Theme:Text(row, "tiny", "")
	row.seen:SetPoint("TOPLEFT", 404, -30)
	row.seen:SetWidth(150)
	row.buttons = {}
	for slot = 1, 2 do
		local button = W:Button(row, "", "secondary", 76, 26)
		if slot == 1 then
			button:SetPoint("RIGHT", -8, 0)
		else
			button:SetPoint("RIGHT", row.buttons[1], "LEFT", -6, 0)
		end
		button:SetScript("OnClick", function(self)
			if self.action and row.info then
				Rows:DoAction(self.action, row.info)
			end
		end)
		button:HookScript("OnEnter", function(self)
			row.highlight:Show()
		end)
		row.buttons[slot] = button
	end
end

---Fills a row for a bounty.
function Rows:UpdateBounty(row, info)
	row.info = info
	local player = info.player
	row.money:SetText(Theme:Money(info.amount))
	if info.guild then
		local members = #Model:GetGuildMembers(info.guild)
		row.name:SetText(Theme:Colorize("<"..info.guild..">", C.amber).."  "..Theme:Colorize(format("any member, %d seen", members), C.muted))
	else
		local who = Theme:ClassName(info.targetName, player and player.class)
		local level = player and player.level and ("Level "..player.level) or "Level ?"
		local class = player and Theme:ClassLabel(player.class) or ""
		local guild = player and player.guild and ("  <"..player.guild..">") or ""
		row.name:SetText(who.."  "..Theme:Colorize(strtrim(level.." "..class)..guild, C.muted))
	end
	row.detail:SetText(Model:GetDetail(info))
	local label, color = Model:GetStateLabel(info)
	row.pill:Set(label, color)
	local seen = Model:GetLastSeen(info)
	row.seen:SetText(seen and ("Seen "..seen) or "Not seen yet")
	-- Buttons fill from the right: the main action is always right-most
	local actions = info.actions or {}
	for slot = 1, 2 do
		local button = row.buttons[slot]
		local action = actions[#actions - slot + 1]
		if action then
			local def = ACTION_BUTTONS[action]
			button.action = action
			button:SetText(def.label)
			button:SetStyle(def.style)
			W:AttachTooltip(button, def.label, def.tip)
			button:Show()
		else
			button.action = nil
			button:Hide()
		end
	end
end

---Fills a row for one of the player's claims as a hunter.
function Rows:UpdateClaim(row, item)
	row.info = nil
	local player = item.player
	row.money:SetText(Theme:Money(item.amount))
	local who = Theme:ClassName(item.targetName, player and player.class)
	local guildBounty = item.bounty.data.guild and ("  for the <"..item.bounty.data.guild.."> bounty") or ""
	row.name:SetText(who.."  "..Theme:Colorize((player and player.level and ("Level "..player.level) or "")..guildBounty, C.muted))
	local parts = {}
	if item.test then
		tinsert(parts, "Test data")
	end
	tinsert(parts, "Bounty from "..item.poster)
	tinsert(parts, "killed "..Theme:Ago(GetServerTime() - item.t))
	row.detail:SetText(table.concat(parts, "  -  "))
	row.pill:Set(item.label, item.color)
	local hints = {
		Paid = "The gold arrived.",
		Confirmed = "The poster agreed. Payment is on its way.",
		Witnessed = "Another player saw it. Waiting for the poster.",
		Unverified = "Nobody else saw it. Waiting for the poster.",
		Disputed = "The poster says it didn't happen.",
		Overdue = "Confirmed over 2 days ago and still unpaid.",
		Beaten = "Another hunter got the kill first.",
	}
	row.seen:SetText(hints[item.label] or "")
	for _, button in ipairs(row.buttons) do
		button:Hide()
	end
end



-- ============================================================================
-- Tooltip
-- ============================================================================

function Rows:ShowBountyTooltip(row, info)
	local player = info.player
	GameTooltip:SetOwner(row, "ANCHOR_CURSOR_RIGHT", 16, 0)
	if info.guild then
		GameTooltip:SetText("<"..info.guild..">", C.amber[1], C.amber[2], C.amber[3])
		GameTooltip:AddLine("A bounty on the whole guild: the first kill of any member claims it.", C.muted[1], C.muted[2], C.muted[3], true)
		local members = Model:GetGuildMembers(info.guild)
		for i = 1, min(#members, 6) do
			local member = members[i]
			GameTooltip:AddDoubleLine(Theme:ClassName(member.name or "?", member.class).."  "..(member.level or "?"), member.lastSeen and ((member.zone or "?")..", "..Theme:Ago(GetServerTime() - member.lastSeen)) or "", 1, 1, 1, C.muted[1], C.muted[2], C.muted[3])
		end
		if #members > 6 then
			GameTooltip:AddLine(format("and %d more seen", #members - 6), C.faint[1], C.faint[2], C.faint[3])
		end
	else
		GameTooltip:SetText(Theme:ClassName(info.targetName, player and player.class))
	end
	if player then
		if player.guild then
			GameTooltip:AddLine("<"..player.guild..">", C.amber[1], C.amber[2], C.amber[3])
		end
		GameTooltip:AddLine(format("Level %s %s, %s", player.level or "?", Theme:ClassLabel(player.class), player.faction or "?"), C.muted[1], C.muted[2], C.muted[3])
		if player.lastSeen then
			local where = player.zone or "?"
			if player.x then
				where = format("%s (%.1f, %.1f)", where, player.x, player.y)
			end
			GameTooltip:AddLine("Last seen "..where..", "..Theme:Ago(GetServerTime() - player.lastSeen), C.muted[1], C.muted[2], C.muted[3])
		end
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddDoubleLine("Bounty", Theme:Money(info.amount), 1, 1, 1, 1, 1, 1)
	GameTooltip:AddDoubleLine("Posted by", info.mine and "you" or info.poster, 1, 1, 1, C.text[1], C.text[2], C.text[3])
	if not info.mine then
		Reputation:AddTrustLines("Poster trust", Reputation:GetPosterTrust(Reputation:GetTally(info.poster)))
	end
	if info.hunters and #info.hunters > 0 then
		GameTooltip:AddDoubleLine("Hunting now", table.concat(info.hunters, ", "), 1, 1, 1, C.blue[1], C.blue[2], C.blue[3])
	end
	if info.claim then
		GameTooltip:AddLine(" ")
		GameTooltip:AddDoubleLine("Claimed by", info.hunter, 1, 1, 1, C.text[1], C.text[2], C.text[3])
		local witnesses = Bounties:GetWitnesses(info.claim)
		GameTooltip:AddLine(#witnesses > 0 and ("Seen by "..table.concat(witnesses, ", ")) or "Nobody else saw the kill", C.muted[1], C.muted[2], C.muted[3], true)
		Reputation:AddTrustLines("Hunter trust", Reputation:GetHunterTrust(Reputation:GetTally(info.hunter)))
		if Wanted.Proof:Get(info.claim.id) then
			GameTooltip:AddLine(format("%s's client saved a screenshot of the kill. Ask for it in %s on the Forever PvP Discord.", info.hunter, Wanted.Proof.DISCORD_CHANNEL), C.green[1], C.green[2], C.green[3], true)
		end
	end
	GameTooltip:Show()
end



-- ============================================================================
-- Actions
-- ============================================================================

local UI -- set lazily (loaded after this file)

local function Done(text, color)
	UI = UI or Wanted.UI
	UI:Toast(text, color or C.green)
	UI:Refresh()
end

function Rows:DoAction(action, info)
	local W = Wanted.Widgets
	local name = Theme:ClassName(info.targetName, info.player and info.player.class)
	if action == "raise" then
		W:Dialog({
			title = "Raise the bounty",
			text = format("Your bounty on %s stands at %s. How much do you want to add?", name, Theme:Money(info.amount)),
			input = { placeholder = "e.g. 50s or 1g" },
			confirmLabel = "Raise",
			validate = function(value)
				local amount = Bounties:ParseMoney(value)
				if not amount or amount <= 0 then
					return "Type an amount like 50s, 1g or 1g 50s."
				end
			end,
			onConfirm = function(value)
				local amount = Bounties:ParseMoney(value)
				Bounties:Raise(info.bounty, amount)
				Done(format("Raised the bounty on %s to %s.", info.targetName, Bounties:FormatMoney(info.amount + amount)))
			end,
		})
	elseif action == "withdraw" then
		W:Dialog({
			title = "Withdraw this bounty?",
			text = format("Your %s bounty on %s comes off the board for everyone. Nobody has claimed it, so nothing is owed.", Theme:Money(info.amount), name),
			confirmLabel = "Withdraw",
			confirmStyle = "danger",
			onConfirm = function()
				local ok, err = Bounties:Withdraw(info.bounty)
				if ok then
					Done(format("Withdrew your bounty on %s.", info.targetName), C.muted)
				else
					Done("Couldn't withdraw: "..tostring(err)..".", C.red)
				end
			end,
		})
	elseif action == "hunt" then
		local ok, err = Bounties:Hunt(info.bounty)
		if ok then
			Done(format("You're hunting %s. The bounty is locked for 2 hours; renew it under Your bounties > Your hunts.", info.targetName))
		else
			Done("Couldn't start the hunt: "..tostring(err)..".", C.red)
		end
	elseif action == "renew" then
		local ok, err = Bounties:Hunt(info.bounty)
		if ok then
			Done(format("Renewed your hunt on %s for another 2 hours.", info.targetName))
		else
			Done("Couldn't renew the hunt: "..tostring(err)..".", C.red)
		end
	elseif action == "stophunt" then
		Bounties:Hunt(info.bounty, true)
		Done(format("Stopped hunting %s.", info.targetName), C.muted)
	elseif action == "pass" then
		Bounties:Pass(info.bounty)
		Done(format("Passed on the bounty on %s. Tick Show passed to see it again.", info.targetName), C.muted)
	elseif action == "confirm" then
		local witnesses = #Bounties:GetWitnesses(info.claim)
		W:Dialog({
			title = "Confirm the kill",
			text = format("You agree %s killed %s, and you owe them %s.%s", info.hunter, name, Theme:Money(info.amount), witnesses == 0 and "\n\nNobody else saw this kill." or ""),
			confirmLabel = "Confirm",
			confirmStyle = "success",
			onConfirm = function()
				Bounties:Decide(info.claim, false)
				Done(format("Confirmed. You owe %s %s: press Pay at a mailbox.", info.hunter, Bounties:FormatMoney(info.amount)))
			end,
		})
	elseif action == "dispute" then
		W:Dialog({
			title = "Dispute the claim",
			text = format("%s's claim on %s goes on their record as disputed, and your bounty opens again. Only dispute a claim you believe is false.", info.hunter, name)
				..(Wanted.Proof:Get(info.claim.id) and format("\n\n%s saved a screenshot of this kill. Check %s on the Forever PvP Discord first.", info.hunter, Wanted.Proof.DISCORD_CHANNEL) or ""),
			confirmLabel = "Dispute",
			confirmStyle = "danger",
			onConfirm = function()
				Bounties:Decide(info.claim, true)
				Done(format("Disputed %s's claim.", info.hunter), C.amber)
			end,
		})
	elseif action == "pay" then
		if MailFrame and MailFrame:IsShown() then
			local ok, err = Payments:Prefill(info.claim)
			if ok then
				Wanted.UI:GetFrame():Hide()
				print(format("|cffffd100Wanted:|r Mail to %s filled in with %s. Check it and press Send.", info.hunter, Bounties:FormatMoney(info.amount)))
			else
				Done("Could not fill in the mail: "..tostring(err), C.red)
			end
		else
			W:Dialog({
				title = "Pay "..info.hunter,
				text = format("Open any mailbox, then press Pay again. Wanted fills in a mail with %s for %s; you check it and press Send.", Theme:Money(info.amount), info.hunter),
				confirmLabel = "OK",
			})
		end
	end
end
