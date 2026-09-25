-- Wanted: the bounties the player is hunting. Each shows how long the hunt has left (a hunt lasts 24 hours;
-- Renew starts it again), with Stop and Renew. Click one for the file on the target.

local _, Wanted = ...
local UI = Wanted.UI
local W = Wanted.Widgets
local Model = Wanted.Model
local Rows = Wanted.Rows
local private = {}

function private.Refresh()
	if not private.list then
		return
	end
	private.list:SetItems(Model:GetMyHunts(), "You're not hunting anyone.", "Press Hunt on a bounty on the Board. A hunt lasts 24 hours; Renew starts it again.")
end

UI:RegisterPage("hunts", {
	title = "Your hunts",
	subtitle = "The bounties you're hunting and how long each hunt has left. Click one for where to find the target.",
	order = 2.5,
	badge = function()
		local hunts = #Model:GetMyHunts()
		return hunts > 0 and hunts or nil
	end,
	build = function(container, width, height)
		local list = W:List(container, Rows.HEIGHT, floor(height / Rows.HEIGHT), function(row) Rows:Create(row) end, function(row, info)
			Rows:UpdateBounty(row, info)
		end)
		list:SetPoint("TOPLEFT")
		list:SetPoint("TOPRIGHT")
		list.onEnter = function(row, info) Rows:ShowBountyTooltip(row, info) end
		list.onClick = function(info) Wanted.TargetFile:ShowBounty(info) end
		private.list = list
	end,
	refresh = private.Refresh,
})
