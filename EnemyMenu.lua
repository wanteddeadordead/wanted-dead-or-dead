-- Wanted: the menu for an enemy player, shared by the Nearby window and the Enemies page: Kill on Sight
-- with a reason, Ignore, a bounty, and telling your party, raid or guild (never public channels).

local _, Wanted = ...
local EnemyMenu = {}
Wanted.EnemyMenu = EnemyMenu
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Enemies = Wanted.Enemies

local function Announce(channel, d)
	-- Plain text only: a chat message with colour codes or links is dropped
	local parts = { "Enemy: "..d.name }
	if d.level then
		tinsert(parts, "level "..d.level)
	end
	if d.class then
		tinsert(parts, Theme:ClassLabel(d.class))
	end
	if d.guild then
		tinsert(parts, "<"..d.guild..">")
	end
	local where = d.zone or ""
	if d.x then
		where = format("%s %.0f,%.0f", where, d.x, d.y)
	end
	if where ~= "" then
		tinsert(parts, "at "..where)
	end
	if d.kos then
		tinsert(parts, "(Kill on Sight)")
	end
	if d.bounty > 0 then
		tinsert(parts, "- "..Wanted.Bounties:FormatMoney(d.bounty).." bounty")
	end
	C_ChatInfo.SendChatMessage(table.concat(parts, " "), channel)
end

function EnemyMenu:SetReason(d)
	W:Dialog({
		title = "Kill on Sight reason",
		text = format("Why is %s on your Kill on Sight list? You'll see it in alerts and tooltips.", Theme:ClassName(d.name, d.class)),
		input = { placeholder = "e.g. camps the Crossroads", value = d.reason or "" },
		confirmLabel = "Save",
		onConfirm = function(value)
			Enemies:SetReason(d.guid, strtrim(value or ""))
		end,
	})
end

---Shows the menu for an enemy (a Describe() result).
---@param d table
function EnemyMenu:Show(d)
	local items = {
		{ text = Theme:ClassName(d.name, d.class), header = true },
	}
	if d.kos then
		tinsert(items, { text = "Remove from Kill on Sight", onClick = function() Enemies:SetKoS(d.guid, d.name, false) end })
		tinsert(items, { text = d.reason and "Change reason..." or "Add a reason...", onClick = function() EnemyMenu:SetReason(d) end })
	else
		tinsert(items, { text = "Kill on Sight", color = C.red, onClick = function() Enemies:SetKoS(d.guid, d.name, true) end })
	end
	if d.ignored then
		tinsert(items, { text = "Stop ignoring", onClick = function() Enemies:SetIgnored(d.guid, d.name, false) end })
	else
		tinsert(items, { text = "Ignore (no alerts)", onClick = function() Enemies:SetIgnored(d.guid, d.name, true) end })
	end
	tinsert(items, "-")
	tinsert(items, { text = d.bounty > 0 and "Add to the bounty..." or "Put a bounty on them...", color = C.gold, onClick = function()
		Wanted.UI:Show("board")
		Wanted.BoardPage:PrefillTarget(d.name)
	end })
	if d.nearby then
		tinsert(items, { text = "Remove from Nearby", onClick = function() Enemies:RemoveNearby(d.guid) end })
	end
	local canParty = IsInGroup and IsInGroup()
	local canRaid = IsInRaid and IsInRaid()
	local canGuild = IsInGuild and IsInGuild()
	if canParty or canGuild then
		tinsert(items, "-")
		if canRaid then
			tinsert(items, { text = "Tell your raid", onClick = function() Announce("RAID", d) end })
		elseif canParty then
			tinsert(items, { text = "Tell your party", onClick = function() Announce("PARTY", d) end })
		end
		if canGuild then
			tinsert(items, { text = "Tell your guild", onClick = function() Announce("GUILD", d) end })
		end
	end
	W:Menu(items)
end

---Adds an enemy's details to the game tooltip (already owned and titled by the caller).
---@param d table
function EnemyMenu:AddTooltip(d)
	local muted = C.muted
	local parts = {}
	if d.level then tinsert(parts, "Level "..d.level) elseif d.skull then tinsert(parts, "Level ??") end
	if d.race then tinsert(parts, d.race) end
	if d.class then tinsert(parts, Theme:ClassLabel(d.class)) end
	GameTooltip:AddLine(table.concat(parts, " "), muted[1], muted[2], muted[3])
	if d.guild then
		GameTooltip:AddLine("<"..d.guild..">", C.amber[1], C.amber[2], C.amber[3])
	end
	if d.kos then
		GameTooltip:AddLine("Kill on Sight"..(d.reason and (": "..d.reason) or ""), C.red[1], C.red[2], C.red[3], true)
	end
	if d.bounty > 0 then
		GameTooltip:AddLine("Bounty: "..Wanted.Bounties:FormatMoney(d.bounty), C.gold[1], C.gold[2], C.gold[3])
	end
	if d.stealthed then
		GameTooltip:AddLine("Went into "..strlower(d.stealthKind or "stealth").." recently", C.amber[1], C.amber[2], C.amber[3])
	end
	GameTooltip:AddLine(" ")
	if d.lastSeen then
		local where = d.zone or "?"
		if d.x then
			where = format("%s (%.1f, %.1f)", where, d.x, d.y)
		end
		GameTooltip:AddDoubleLine("Last seen", where..", "..Theme:Ago(GetServerTime() - d.lastSeen), 1, 1, 1, muted[1], muted[2], muted[3])
	end
	GameTooltip:AddDoubleLine("Seen", d.detections.." time"..(d.detections == 1 and "" or "s"), 1, 1, 1, muted[1], muted[2], muted[3])
	GameTooltip:AddDoubleLine("You won / they won", d.wins.." / "..d.losses, 1, 1, 1, muted[1], muted[2], muted[3])
end
