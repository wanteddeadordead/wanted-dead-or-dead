-- Wanted: the player's own business. What they owe and are owed at a glance, the bounties they posted
-- (with the decisions waiting on them first), and the claims they made as a hunter.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Model = Wanted.Model
local Rows = Wanted.Rows
local private = { view = "posted" }

function private.Refresh()
	if not private.list then
		return
	end
	local summary = Model:GetMySummary()
	private.oweTile.value:SetText(Theme:Money(summary.owe))
	private.oweTile.note:SetText(summary.oweCount > 0 and format("%d to pay", summary.oweCount) or "all settled")
	private.owedTile.value:SetText(Theme:Money(summary.owed))
	private.owedTile.note:SetText(summary.owedCount > 0 and format("%d claim%s", summary.owedCount, summary.owedCount == 1 and "" or "s") or "")
	private.openTile.value:SetText(Theme:Money(summary.open))
	private.openTile.note:SetText(format("%d open%s", summary.openCount, summary.decide > 0 and format(", %d to decide", summary.decide) or ""))
	if private.view == "posted" then
		private.list:SetItems(Model:GetMyBounties(), "No live bounties.", "Post one from the Board. Finished ones are under History.")
	elseif private.view == "claims" then
		private.list:SetItems(Model:GetMyActiveClaims(), "No claims in play.", "Kill a player with a bounty on them and the claim files itself.")
	else
		private.list:SetItems(Model:GetMyHistory(), "Nothing finished yet.", "Paid, expired and withdrawn bounties, and finished claims, end up here.")
	end
end

UI:RegisterPage("mine", {
	title = "Your bounties",
	subtitle = "Your live bounties and claims, what you owe and are owed. Finished ones move to History.",
	order = 2,
	badge = function() return Model:GetActionCount() end,
	build = function(container, width, height)
		local tileWidth = floor((width - 24) / 3)
		private.oweTile = W:StatTile(container, "You owe", C.red)
		private.oweTile:SetPoint("TOPLEFT")
		private.oweTile:SetWidth(tileWidth)
		private.owedTile = W:StatTile(container, "Owed to you", C.green)
		private.owedTile:SetPoint("LEFT", private.oweTile, "RIGHT", 12, 0)
		private.owedTile:SetWidth(tileWidth)
		private.openTile = W:StatTile(container, "Your open bounties", C.blue)
		private.openTile:SetPoint("LEFT", private.owedTile, "RIGHT", 12, 0)
		private.openTile:SetWidth(tileWidth)

		local segment = W:Segmented(container, {
			{ key = "posted", label = "Your live bounties" },
			{ key = "claims", label = "Your claims" },
			{ key = "history", label = "History" },
		}, function(key)
			private.view = key
			private.Refresh()
		end, 170)
		segment:SetPoint("TOPLEFT", 0, -84)
		segment:Select("posted", true)

		local listTop = 122
		local numRows = floor((height - listTop) / Rows.HEIGHT)
		-- Bounty infos carry a state; claim items carry a label (history mixes both)
		local list = W:List(container, Rows.HEIGHT, numRows, function(row) Rows:Create(row) end, function(row, item)
			if item.state then
				Rows:UpdateBounty(row, item)
			else
				Rows:UpdateClaim(row, item)
			end
		end)
		list.onEnter = function(row, item)
			if item.state then
				Rows:ShowBountyTooltip(row, item)
			end
		end
		list:SetPoint("TOPLEFT", 0, -listTop)
		list:SetPoint("TOPRIGHT", 0, -listTop)
		private.list = list
	end,
	refresh = private.Refresh,
})
