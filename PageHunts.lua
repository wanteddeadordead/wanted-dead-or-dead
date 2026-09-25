-- Wanted: the player as a hunter. What they're owed and have earned at a glance, the bounties they're
-- hunting (each with how long the hunt has left: a hunt lasts 24 hours and Renew starts it again), the
-- claims their kills have made, the finished ones, and their trust as a hunter. Everything as a poster is
-- on Your bounties.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Model = Wanted.Model
local Rows = Wanted.Rows
local private = { view = "hunting" }
local LIST_TOP = 122

function private.Refresh()
	if not private.list then
		return
	end
	local summary = Model:GetMySummary()
	private.owedTile.value:SetText(Theme:Money(summary.owed))
	private.owedTile.note:SetText(summary.owedCount > 0 and format("%d claim%s", summary.owedCount, summary.owedCount == 1 and "" or "s") or "")
	private.huntingTile.value:SetText(Theme:Money(summary.hunting))
	private.huntingTile.note:SetText(format("%d hunt%s", summary.huntingCount, summary.huntingCount == 1 and "" or "s"))
	private.earnedTile.value:SetText(Theme:Money(summary.earned))
	private.earnedTile.note:SetText(summary.earnedCount > 0 and format("%d paid", summary.earnedCount) or "")
	local showRecord = private.view == "record"
	private.record:SetShown(showRecord)
	private.list:SetShown(not showRecord)
	if showRecord then
		private.record:Refresh()
	elseif private.view == "claims" then
		private.list:SetItems(Model:GetMyActiveClaims(), "No claims in play.", "Kill a player with a bounty on them and the claim files itself.")
	elseif private.view == "history" then
		private.list:SetItems(Model:GetMyHistory("hunter"), "Nothing finished yet.", "Your paid, beaten and disputed claims end up here.")
	else
		private.list:SetItems(Model:GetMyHunts(), "You're not hunting anyone.", "Press Hunt on a bounty on the Board. A hunt lasts 24 hours; Renew starts it again.")
	end
end

UI:RegisterPage("hunts", {
	title = "Your hunts",
	subtitle = "The bounties you're hunting, the claims your kills made, and your record as a hunter.",
	order = 2.5,
	badge = function()
		local hunts = #Model:GetMyHunts()
		return hunts > 0 and hunts or nil
	end,
	build = function(container, width, height)
		local tileWidth = floor((width - 24) / 3)
		private.owedTile = W:StatTile(container, "Owed to you", C.green)
		private.owedTile:SetPoint("TOPLEFT")
		private.owedTile:SetWidth(tileWidth)
		private.huntingTile = W:StatTile(container, "Hunting now", C.blue)
		private.huntingTile:SetPoint("LEFT", private.owedTile, "RIGHT", 12, 0)
		private.huntingTile:SetWidth(tileWidth)
		private.earnedTile = W:StatTile(container, "Earned", C.gold)
		private.earnedTile:SetPoint("LEFT", private.huntingTile, "RIGHT", 12, 0)
		private.earnedTile:SetWidth(tileWidth)

		local segment = W:Segmented(container, {
			{ key = "hunting", label = "Hunting now" },
			{ key = "claims", label = "Your claims" },
			{ key = "history", label = "History" },
			{ key = "record", label = "Your record" },
		}, function(key)
			private.view = key
			private.Refresh()
		end, 170)
		segment:SetPoint("TOPLEFT", 0, -84)
		segment:Select("hunting", true)
		private.segment = segment

		-- Hunts are bounty infos (they carry a state); claims are claim items
		local list = W:List(container, Rows.HEIGHT, floor((height - LIST_TOP) / Rows.HEIGHT), function(row) Rows:Create(row) end, function(row, item)
			if item.state then
				Rows:UpdateBounty(row, item)
			else
				Rows:UpdateClaim(row, item)
			end
		end)
		list:SetPoint("TOPLEFT", 0, -LIST_TOP)
		list:SetPoint("TOPRIGHT", 0, -LIST_TOP)
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
		private.record = Wanted.TrustPanel:Create(container, LIST_TOP, width, height, "hunter")
	end,
	refresh = private.Refresh,
})

Wanted.HuntsPage = {}
---Opens Your hunts on the Your claims tab.
function Wanted.HuntsPage:ShowClaims()
	UI:Show("hunts")
	if private.segment then
		private.segment:Select("claims")
	end
end

---Opens Your hunts on the Your record tab.
function Wanted.HuntsPage:ShowRecord()
	UI:Show("hunts")
	if private.segment then
		private.segment:Select("record")
	end
end
