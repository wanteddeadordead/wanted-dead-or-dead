-- Wanted: the player as a hunter. The bounties they're hunting, each with how long the hunt has left (a
-- hunt lasts 24 hours; Renew starts it again) and Stop and Renew, and the claims their kills have made.
-- Click a hunt for the file on the target.

local _, Wanted = ...
local UI = Wanted.UI
local W = Wanted.Widgets
local Model = Wanted.Model
local Rows = Wanted.Rows
local private = { view = "hunting" }

function private.Refresh()
	if not private.list then
		return
	end
	if private.view == "claims" then
		private.list:SetItems(Model:GetMyActiveClaims(), "No claims in play.", "Kill a player with a bounty on them and the claim files itself.")
	else
		private.list:SetItems(Model:GetMyHunts(), "You're not hunting anyone.", "Press Hunt on a bounty on the Board. A hunt lasts 24 hours; Renew starts it again.")
	end
end

UI:RegisterPage("hunts", {
	title = "Your hunts",
	subtitle = "The bounties you're hunting and the claims your kills have made. Click a hunt for where to find the target.",
	order = 2.5,
	badge = function()
		local hunts = #Model:GetMyHunts()
		return hunts > 0 and hunts or nil
	end,
	build = function(container, width, height)
		local segment = W:Segmented(container, {
			{ key = "hunting", label = "Hunting now" },
			{ key = "claims", label = "Your claims" },
		}, function(key)
			private.view = key
			private.Refresh()
		end, 170)
		segment:SetPoint("TOPLEFT")
		segment:Select("hunting", true)
		private.segment = segment

		local listTop = 40
		-- Hunts are bounty infos (they carry a state); claims are claim items
		local list = W:List(container, Rows.HEIGHT, floor((height - listTop) / Rows.HEIGHT), function(row) Rows:Create(row) end, function(row, item)
			if item.state then
				Rows:UpdateBounty(row, item)
			else
				Rows:UpdateClaim(row, item)
			end
		end)
		list:SetPoint("TOPLEFT", 0, -listTop)
		list:SetPoint("TOPRIGHT", 0, -listTop)
		list.onEnter = function(row, item)
			if item.state then
				Rows:ShowBountyTooltip(row, item)
			end
		end
		list.onClick = function(item)
			if item.state then
				Wanted.TargetFile:ShowBounty(item)
			elseif item.bounty then
				Wanted.TargetFile:ShowBounty(Model:GetBountyInfo(item.bounty))
			end
		end
		private.list = list
	end,
	refresh = private.Refresh,
})

---Opens Your hunts on the Your claims tab.
Wanted.HuntsPage = {}
function Wanted.HuntsPage:ShowClaims()
	UI:Show("hunts")
	if private.segment then
		private.segment:Select("claims")
	end
end
