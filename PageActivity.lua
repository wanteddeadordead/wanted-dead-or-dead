-- Wanted: what the addon has witnessed: honor kills, enemy deaths and enemy sightings, newest first.
-- Clicking an enemy puts them into the board's post form.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Model = Wanted.Model
local private = { kind = nil }
local ROW_HEIGHT = 42
local KIND_STYLE = {
	kill = { color = C.red, label = "Kill" },
	death = { color = C.amber, label = "Death" },
	seen = { color = C.blue, label = "Seen" },
}

function private.CreateRow(row)
	row.kind = W:Pill(row)
	row.kind:SetPoint("LEFT", 16, 0)
	row.text = Theme:Text(row, "body", "")
	row.text:SetPoint("TOPLEFT", 84, -8)
	row.text:SetWidth(480)
	row.sub = Theme:Text(row, "tiny", "")
	row.sub:SetPoint("TOPLEFT", 84, -26)
	row.sub:SetWidth(460)
	row.time = Theme:Text(row, "small", "")
	row.time:SetPoint("RIGHT", -14, 0)
	row.time:SetJustifyH("RIGHT")
end

function private.UpdateRow(row, item)
	local style = KIND_STYLE[item.kind]
	row.kind:Set(style.label, style.color)
	local player = item.player or (item.guid and Wanted.Store:GetPlayer(item.guid))
	local name = Theme:ClassName(item.name or "?", player and player.class)
	if item.kind == "kill" then
		row.text:SetText(format("%s killed %s", item.who, name))
	elseif item.kind == "death" then
		row.text:SetText(format("%s died", name)..Theme:Colorize("  witnessed by "..item.who, C.muted))
	else
		row.text:SetText(name..Theme:Colorize(format("  level %s %s", player and player.level or "?", Theme:ClassLabel(player and player.class)), C.muted))
	end
	local where = item.zone or "?"
	if item.x then
		where = format("%s (%.1f, %.1f)", where, item.x, item.y)
	end
	local guild = item.guild and ("<"..item.guild..">  -  ") or ""
	row.sub:SetText((item.test and "Test data  -  " or "")..guild..where)
	row.time:SetText(Theme:Ago(GetServerTime() - item.t))
end

function private.Refresh()
	if not private.list then
		return
	end
	local hints = {
		kill = "Your honorable kills appear here, and other players' through sync.",
		death = "Enemy players who die near you (in nameplate range) appear here.",
		seen = "Mouse over, target or come near an enemy player to record a sighting.",
	}
	private.list:SetItems(Model:GetActivity(private.kind), "Nothing witnessed yet.", private.kind and hints[private.kind] or "Enemy players you see, and deaths and kills near you, appear here.")
end

UI:RegisterPage("activity", {
	title = "Activity",
	subtitle = "Kills, deaths and sightings the addon has witnessed. Click an enemy to put a bounty on them.",
	order = 5,
	build = function(container, width, height)
		local filter = W:Segmented(container, {
			{ key = "all", label = "Everything" },
			{ key = "kill", label = "Kills" },
			{ key = "death", label = "Deaths" },
			{ key = "seen", label = "Sightings" },
		}, function(key)
			private.kind = key ~= "all" and key or nil
			private.Refresh()
		end, 100)
		filter:SetPoint("TOPLEFT")
		filter:Select("all", true)
		local listTop = 40
		local list = W:List(container, ROW_HEIGHT, floor((height - listTop) / ROW_HEIGHT), private.CreateRow, private.UpdateRow)
		list:SetPoint("TOPLEFT", 0, -listTop)
		list:SetPoint("TOPRIGHT", 0, -listTop)
		list.onClick = function(item)
			if item.name and item.guid and strsub(item.guid, 1, 5) ~= "name:" then
				UI:Show("board")
				Wanted.BoardPage:PrefillTarget(item.name)
				UI:Toast("Type an amount and press Post bounty.", C.muted)
			end
		end
		list.onEnter = function(row, item)
			GameTooltip:SetOwner(row, "ANCHOR_CURSOR_RIGHT", 16, 0)
			GameTooltip:SetText("Put a bounty on "..(item.name or "?"), 1, 1, 1)
			GameTooltip:AddLine("Click to fill in the board's post form.", C.muted[1], C.muted[2], C.muted[3])
			GameTooltip:Show()
		end
		private.list = list
	end,
	refresh = private.Refresh,
})
