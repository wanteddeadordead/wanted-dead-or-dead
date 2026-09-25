-- Wanted: the player as a poster. What they owe and have paid out at a glance, the bounties they posted
-- (with the decisions waiting on them first), the ones that are finished, and their trust as a poster.
-- Everything as a hunter is on Your hunts.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Model = Wanted.Model
local Rows = Wanted.Rows
local private = { view = "posted" }
local LIST_TOP = 122

function private.Refresh()
	if not private.list then
		return
	end
	local summary = Model:GetMySummary()
	private.oweTile.value:SetText(Theme:Money(summary.owe))
	private.oweTile.note:SetText(summary.oweCount > 0 and format("%d to pay", summary.oweCount) or "all settled")
	private.openTile.value:SetText(Theme:Money(summary.open))
	private.openTile.note:SetText(format("%d open%s", summary.openCount, summary.decide > 0 and format(", %d to decide", summary.decide) or ""))
	private.paidTile.value:SetText(Theme:Money(summary.paidOut))
	private.paidTile.note:SetText(summary.paidOutCount > 0 and format("%d claim%s", summary.paidOutCount, summary.paidOutCount == 1 and "" or "s") or "")
	local showRecord = private.view == "record"
	private.record:SetShown(showRecord)
	private.list:SetShown(not showRecord)
	if showRecord then
		private.record:Refresh()
	elseif private.view == "posted" then
		private.list:SetItems(Model:GetMyBounties(), "No live bounties.", "Post one from the Board. Finished ones are under History.")
	else
		private.list:SetItems(Model:GetMyHistory("poster"), "Nothing finished yet.", "Your paid, expired and withdrawn bounties end up here.")
	end
end

UI:RegisterPage("mine", {
	title = "Your bounties",
	subtitle = "The bounties you posted: what you owe, what's waiting on you, and your record as a poster.",
	order = 2,
	badge = function() return Model:GetActionCount() end,
	build = function(container, width, height)
		local tileWidth = floor((width - 24) / 3)
		private.oweTile = W:StatTile(container, "You owe", C.red)
		private.oweTile:SetPoint("TOPLEFT")
		private.oweTile:SetWidth(tileWidth)
		private.openTile = W:StatTile(container, "Your open bounties", C.blue)
		private.openTile:SetPoint("LEFT", private.oweTile, "RIGHT", 12, 0)
		private.openTile:SetWidth(tileWidth)
		private.paidTile = W:StatTile(container, "Paid out", C.green)
		private.paidTile:SetPoint("LEFT", private.openTile, "RIGHT", 12, 0)
		private.paidTile:SetWidth(tileWidth)

		local segment = W:Segmented(container, {
			{ key = "posted", label = "Your live bounties" },
			{ key = "history", label = "History" },
			{ key = "record", label = "Your record" },
		}, function(key)
			private.view = key
			private.Refresh()
		end, 170)
		segment:SetPoint("TOPLEFT", 0, -84)
		segment:Select("posted", true)
		private.segment = segment
		local poster = W:Button(container, "Your wanted poster", "secondary", 160, 26, function()
			Wanted.Poster:Show()
		end)
		poster:SetPoint("TOPRIGHT", 0, -84)
		W:AttachTooltip(poster, "Your wanted poster", "The price the other faction has put on your head, on a poster with your character, to screenshot and share.")

		local list = W:List(container, Rows.HEIGHT, floor((height - LIST_TOP) / Rows.HEIGHT), function(row) Rows:Create(row) end, function(row, info)
			Rows:UpdateBounty(row, info)
		end)
		list.onClick = function(info) Wanted.TargetFile:ShowBounty(info) end
		list.onEnter = function(row, info) Rows:ShowBountyTooltip(row, info) end
		list:SetPoint("TOPLEFT", 0, -LIST_TOP)
		list:SetPoint("TOPRIGHT", 0, -LIST_TOP)
		private.list = list
		private.record = Wanted.TrustPanel:Create(container, LIST_TOP, width, height, "poster", function()
			segment:Select("posted")
		end)
	end,
	refresh = private.Refresh,
})

---Opens Your bounties on the Your record tab.
Wanted.MinePage = {}
function Wanted.MinePage:ShowRecord()
	UI:Show("mine")
	if private.segment then
		private.segment:Select("record")
	end
end

Wanted:RegisterCommand("record", "Your record and how to improve it: /wanted record (as a poster) or /wanted record hunter.", function(args)
	if strlower(strtrim(args or "")) == "hunter" then
		Wanted.HuntsPage:ShowRecord()
	else
		Wanted.MinePage:ShowRecord()
	end
end)
