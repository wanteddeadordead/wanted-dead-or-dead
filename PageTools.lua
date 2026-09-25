-- Wanted: the network, test data and the debug log, with the settings that don't belong elsewhere.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local private = {}

function private.RunAndToast(command, args)
	UI:Run(command, args)
end

function private.BuildNetwork(container, width)
	local card = W:Card(container)
	card:SetPoint("TOPLEFT")
	card:SetSize(width, 112)
	local label = W:SectionLabel(card, "Network")
	label:SetPoint("TOPLEFT", 16, -14)
	private.dot = card:CreateTexture(nil, "ARTWORK")
	private.dot:SetSize(10, 10)
	private.dot:SetPoint("TOPLEFT", 16, -39)
	private.netTitle = Theme:Text(card, "heading", "")
	private.netTitle:SetPoint("LEFT", private.dot, "RIGHT", 10, 0)
	private.netStats = Theme:Text(card, "small", "")
	private.netStats:SetPoint("TOPLEFT", 16, -62)
	private.netStats:SetPoint("RIGHT", -16, 0)
	private.netStats:SetWordWrap(true)
	local test = W:Button(card, "Test connection", "secondary", 130, 26, function() private.RunAndToast("synctest") end)
	test:SetPoint("BOTTOMLEFT", 16, 12)
	W:AttachTooltip(test, "Test connection", "Sends a message through the channel and reports when it comes back.")
	local reconnect = W:Button(card, "Reconnect", "ghost", 100, 26, function() private.RunAndToast("reconnect") end)
	reconnect:SetPoint("LEFT", test, "RIGHT", 6, 0)
	local bug = W:Button(card, "Report a bug", "primary", 120, 26, function() Wanted.Report:Show() end)
	bug:SetPoint("BOTTOMRIGHT", -16, 12)
	W:AttachTooltip(bug, "Report a bug", "Builds a report to copy and shows where to send it. Also /wanted bug.")

end

function private.BuildTestData(container, width)
	local card = W:Card(container)
	card:SetPoint("TOPLEFT", 0, -124)
	card:SetSize(width, 96)
	local label = W:SectionLabel(card, "Test data")
	label:SetPoint("TOPLEFT", 16, -14)
	local text = Theme:Text(card, "small", "Fill the board with a made-up bounty, claim, witness and history to try every button. It never leaves your client.")
	text:SetPoint("TOPLEFT", 16, -32)
	text:SetPoint("RIGHT", -16, 0)
	text:SetWordWrap(true)
	local simulate = W:Button(card, "Add test data", "secondary", 120, 26, function() private.RunAndToast("simulate") end)
	simulate:SetPoint("BOTTOMLEFT", 16, 12)
	local paid = W:Button(card, "Simulate payment", "secondary", 136, 26, function() private.RunAndToast("simulate", "paid") end)
	paid:SetPoint("LEFT", simulate, "RIGHT", 6, 0)
	W:AttachTooltip(paid, "Simulate payment", "Pretends the test hunter received the gold for every unpaid test claim.")
	local purge = W:Button(card, "Remove test data", "danger", 136, 26, function() private.RunAndToast("purge") end)
	purge:SetPoint("LEFT", paid, "RIGHT", 6, 0)
end

function private.BuildLog(container, width, height)
	local card = W:Card(container)
	card:SetPoint("TOPLEFT", 0, -232)
	card:SetSize(width, height - 232)
	local label = W:SectionLabel(card, "Debug log")
	label:SetPoint("TOPLEFT", 16, -14)
	local hint = Theme:Text(card, "tiny", "Click the text, Ctrl+A, Ctrl+C to copy it.")
	hint:SetPoint("LEFT", label, "RIGHT", 12, 0)
	local refresh = W:Button(card, "Refresh", "ghost", 80, 22, function() private.Refresh() end)
	refresh:SetPoint("TOPRIGHT", -10, -8)
	local scroll = CreateFrame("ScrollFrame", nil, card, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 16, -38)
	scroll:SetPoint("BOTTOMRIGHT", -30, 12)
	local box = CreateFrame("EditBox", nil, scroll)
	box:SetMultiLine(true)
	box:SetAutoFocus(false)
	box:SetFontObject(Theme.Fonts.small)
	box:SetWidth(width - 60)
	box:SetScript("OnEscapePressed", box.ClearFocus)
	box:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			self:SetText(private.logText or "")
		end
	end)
	scroll:SetScrollChild(box)
	private.logBox = box
end

function private.Refresh()
	if not private.logBox then
		return
	end
	local info = Wanted.Sync:GetInfo()
	local color, title
	if not info.channelId then
		color, title = C.red, "Offline: not in "..(info.channelName or "the channel").." yet"
	elseif info.paused then
		color, title = C.amber, "Paused: too much traffic, resuming shortly"
	elseif info.peers == 0 then
		color, title = C.amber, format("Online in %s, no other players seen yet", info.channelName)
	else
		color, title = C.green, format("Online in %s with %d other player%s", info.channelName, info.peers, info.peers == 1 and "" or "s")
	end
	private.dot:SetColorTexture(color[1], color[2], color[3], 1)
	private.netTitle:SetText(title)
	local stats = info.stats
	private.netStats:SetText(format("Messages sent %d, received %d. Records merged from others %d. Rejected %d, dropped by limits %d, held back by the game %d, repeat sightings skipped %d.", stats.sent, stats.received - stats.echoed, stats.merged, stats.invalid, stats.dropped, stats.throttled, stats.skipped))
	private.logText = table.concat(Wanted:GetLogLines(), "\n")
	private.logBox:SetText(private.logText)
end

UI:RegisterPage("tools", {
	title = "Tools",
	subtitle = "The player-to-player network, test data, and the log to send when something looks wrong.",
	hidden = function() return not Wanted.db.settings.showTools end,
	order = 7,
	build = function(container, width, height)
		private.BuildNetwork(container, width)
		private.BuildTestData(container, width)
		private.BuildLog(container, width, height)
	end,
	refresh = private.Refresh,
})
