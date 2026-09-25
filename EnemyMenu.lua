-- Wanted: the menu for an enemy player, shared by the Nearby window and the Enemies page: Kill on Sight
-- with a reason, Ignore, a bounty, and telling your party, raid, guild or Local Defense. Also the call for
-- help. Chat is only ever sent when the player clicks one of these; never General or Trade.

local _, Wanted = ...
local EnemyMenu = {}
Wanted.EnemyMenu = EnemyMenu
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Enemies = Wanted.Enemies

-- Local Defense is zone channel 22 in every language; its English name is the fallback
local LOCAL_DEFENSE_ZONE_CHANNEL = 22
local HELP_COOLDOWN = 15 -- seconds between calls for help to the same channel
local MAX_CHAT_LENGTH = 255
local lastHelp = {}

local function Readable(value)
	if issecretvalue and issecretvalue(value) then
		return nil
	end
	return value
end

---The number of the Local Defense channel you're in, or nil (not in one here, e.g. in a city or instance).
---@return number?
function EnemyMenu:GetLocalDefenseChannel()
	for i = 1, MAX_WOW_CHAT_CHANNELS or 20 do
		local info = C_ChatInfo.GetChannelInfoFromIdentifier and C_ChatInfo.GetChannelInfoFromIdentifier(tostring(i))
		if info and (Readable(info.zoneChannelID) == LOCAL_DEFENSE_ZONE_CHANNEL or strfind(Readable(info.name) or "", "^LocalDefense")) then
			return i
		end
		local _, name = GetChannelName(i)
		name = Readable(name)
		if type(name) == "string" and strfind(name, "^LocalDefense") then
			return i
		end
	end
	return nil
end

---Sends plain text to a chat type ("RAID", "PARTY", "GUILD" or "CHANNEL" with its number). The client
---blocks addons from posting in public channels like Local Defense, even from a click, so for a channel the
---message is typed into your chat box instead ("/4 Need help at ...") and you press Enter to send it.
local function Send(text, chatType, channelNumber)
	if chatType == "CHANNEL" then
		local line = "/"..channelNumber.." "..text
		local OpenChat = ChatFrameUtil and ChatFrameUtil.OpenChat or ChatFrame_OpenChat
		if OpenChat then
			OpenChat(strsub(line, 1, MAX_CHAT_LENGTH))
		end
		return
	end
	C_ChatInfo.SendChatMessage(strsub(text, 1, MAX_CHAT_LENGTH), chatType)
end

local function Announce(channel, d, channelNumber)
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
	Send(table.concat(parts, " "), channel, channelNumber)
end

---"Need help at The Barrens 62,38 - 3 enemies: Stabby 22 Rogue (on me), Sam 24 Mage, Bob 20 Warrior" in
---plain text (colour codes or links get a chat message dropped), those attacking you first.
---@return string
function EnemyMenu:BuildHelpText()
	local zone, x, y = Wanted.Recorder:GetPosition()
	local where = zone or "?"
	if x then
		where = format("%s %.0f,%.0f", where, x, y)
	end
	local nearby = {}
	for _, d in ipairs(Enemies:GetNearby()) do
		tinsert(nearby, d)
	end
	-- Whoever is on you first, then the list's own order (active, in sight, gone)
	for i, d in ipairs(nearby) do
		d.helpOrder = (d.targetingMe and 0 or 1000) + i
	end
	sort(nearby, function(a, b) return a.helpOrder < b.helpOrder end)
	if #nearby == 0 then
		return "Need help at "..where.."!"
	end
	local text = format("Need help at %s - %d enem%s:", where, #nearby, #nearby == 1 and "y" or "ies")
	for i, d in ipairs(nearby) do
		local part = " "..d.name
		if d.level then
			part = part.." "..d.level
		end
		if d.class then
			part = part.." "..Theme:ClassLabel(d.class)
		end
		if d.targetingMe then
			part = part.." (on me)"
		end
		part = part..(i < #nearby and "," or "")
		local more = format(" +%d more", #nearby - i)
		if #text + #part + #more > MAX_CHAT_LENGTH - 4 then
			return text..format(" +%d more", #nearby - i + 1)
		end
		text = text..part
	end
	return text
end

---Sends the call for help, at most once per channel every few seconds.
---@param chatType string "CHANNEL" (Local Defense), "RAID", "PARTY" or "GUILD"
---@return boolean sent
function EnemyMenu:CallForHelp(chatType)
	local channelNumber
	if chatType == "CHANNEL" then
		channelNumber = EnemyMenu:GetLocalDefenseChannel()
		if not channelNumber then
			Wanted:Print("You're not in a Local Defense channel here.")
			return false
		end
	end
	local key = chatType..(channelNumber or "")
	if lastHelp[key] and GetTime() - lastHelp[key] < HELP_COOLDOWN then
		Wanted:Print("Help was just sent there. Try again in a few seconds.")
		return false
	end
	lastHelp[key] = GetTime()
	Send(EnemyMenu:BuildHelpText(), chatType, channelNumber)
	return true
end

---The call-for-help menu: Local Defense, your raid or party, your guild.
function EnemyMenu:ShowHelpMenu()
	local items = {
		{ text = "Call for help", header = true },
	}
	local localDefense = EnemyMenu:GetLocalDefenseChannel()
	tinsert(items, { text = localDefense and format("Local Defense (/%d, press Enter)", localDefense) or "Local Defense (not here)", color = C.red, disabled = not localDefense, onClick = function() EnemyMenu:CallForHelp("CHANNEL") end })
	if IsInRaid and IsInRaid() then
		tinsert(items, { text = "Your raid", onClick = function() EnemyMenu:CallForHelp("RAID") end })
	elseif IsInGroup and IsInGroup() then
		tinsert(items, { text = "Your party", onClick = function() EnemyMenu:CallForHelp("PARTY") end })
	end
	if IsInGuild and IsInGuild() then
		tinsert(items, { text = "Your guild", onClick = function() EnemyMenu:CallForHelp("GUILD") end })
	end
	W:Menu(items)
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
	tinsert(items, { text = "Where they've been...", onClick = function() Wanted.TargetFile:ShowPlayer(d.guid, d.name) end })
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
	local localDefense = EnemyMenu:GetLocalDefenseChannel()
	if canParty or canGuild or localDefense then
		tinsert(items, "-")
		if localDefense then
			tinsert(items, { text = "Tell Local Defense (press Enter)", onClick = function() Announce("CHANNEL", d, localDefense) end })
		end
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
