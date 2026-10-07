-- Wanted: the You entry's first tab, your calling card: as other players see it, how much of the catalogue you've
-- unlocked, and the editor a click away. Before the app has brought your card, the sample card shows instead.

local _, Wanted = ...
local UI = Wanted.UI
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local CallingCard = Wanted.CallingCard
local private = {}
local BANNER_WIDTH = 600

function private.Refresh()
	if not private.banner then
		return
	end
	local mine = CallingCard:MyCard()
	if mine then
		CallingCard:Draw(private.banner, mine.card, mine.name, mine.stats)
		private.note:SetText(format("%d of %d pieces unlocked. Change your card any time; the Wanted app sends it to wanteddeadordead.com.", mine.unlocked, mine.total))
	else
		local sample, stats = CallingCard:Sample()
		CallingCard:Draw(private.banner, sample, UnitName("player") or "Your Name", stats)
		private.note:SetText("A sample card. Yours shows here once the Wanted app has brought it from wanteddeadordead.com.")
	end
end

UI:RegisterPage("card", {
	group = "You",
	title = "Calling card",
	subtitle = "Your banner on wanteddeadordead.com and on the death card of anyone you kill: the art your badges unlock.",
	order = 6,
	menuLabel = "You",
	tabLabel = "Calling card",
	tabs = { "card", "poster", "web", "settings", "tools" },
	build = function(container, width)
		private.banner = CallingCard:Banner(container, min(width, BANNER_WIDTH))
		private.banner:SetPoint("TOPLEFT", 0, -4)
		private.note = Theme:Text(container, "small", "", C.muted)
		private.note:SetPoint("TOPLEFT", private.banner, "BOTTOMLEFT", 0, -56)
		private.note:SetWidth(min(width, BANNER_WIDTH))
		private.note:SetWordWrap(true)
		local change = W:Button(container, "Change your card", "primary", 160, 28, function()
			CallingCard:Show()
		end)
		change:SetPoint("TOPLEFT", private.note, "BOTTOMLEFT", 0, -12)
		W:AttachTooltip(change, "Change your card", "Step through the pieces you've unlocked, or try any combination. Also /wanted card.")
		private.Refresh()
	end,
	refresh = private.Refresh,
})
