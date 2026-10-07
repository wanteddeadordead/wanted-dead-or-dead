-- Wanted: the You entry's poster tab: a small wanted poster of you with the price on your head, and the full-size one
-- (to screenshot, or upload to wanteddeadordead.com) a click away.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local private = {}

function private.Refresh()
	if not private.preview then
		return
	end
	private.preview:Update()
	local total, count, posters = Wanted.Bridge:GetPriceOnMe()
	private.price:SetText(total > 0 and format("%d bount%s from %d player%s of the other faction.", count, count == 1 and "y" or "ies", posters, posters == 1 and "" or "s")
		or "Nobody on the other faction has put a price on your head yet.")
end

UI:RegisterPage("poster", {
	group = "You",
	title = "Wanted poster",
	subtitle = "The price the other faction has put on your head, on a poster with your character, to screenshot and share.",
	order = 6.1,
	under = "card",
	tabLabel = "Wanted poster",
	build = function(container, width, height)
		private.preview = Wanted.Poster:Preview(container, height - 8)
		private.preview:SetPoint("TOPLEFT", 0, -4)
		private.price = Theme:Text(container, "body", "")
		private.price:SetPoint("TOPLEFT", private.preview, "TOPRIGHT", 24, -8)
		private.price:SetWidth(width - private.preview:GetWidth() - 24)
		private.price:SetWordWrap(true)
		local open = W:Button(container, "Open full size", "primary", 150, 28, function()
			Wanted.Poster:Show()
		end)
		open:SetPoint("TOPLEFT", private.price, "BOTTOMLEFT", 0, -16)
		local hint = Theme:Text(container, "small", "Full size, you can screenshot it, set a made-up amount just for fun, or upload it to wanteddeadordead.com. Also /wanted poster.", C.muted)
		hint:SetPoint("TOPLEFT", open, "BOTTOMLEFT", 0, -10)
		hint:SetWidth(width - private.preview:GetWidth() - 24)
		hint:SetWordWrap(true)
		private.Refresh()
	end,
	refresh = private.Refresh,
})
