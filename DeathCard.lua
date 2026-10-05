-- Wanted: the death card. When an enemy player kills you in the open world, a small card says who it was and what
-- you know of them (your record against them, their rank, the bounty on them, whether they're an outlaw), with
-- one click to put them on Kill on Sight, post a bounty on them or open their file. It goes when you're alive
-- again, after two minutes, or when closed; a second death by the same player brings it back up to date.

local _, Wanted = ...
local DeathCard = Wanted:NewModule("DeathCard")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local Store = Wanted.Store
local private = {}
local WIDTH = 410
-- Taller when the "probably" line shows (the recap didn't name the killer)
local HEIGHT, HEIGHT_UNSURE = 160, 178
local SHOW_SECONDS = 120
local KOS_REASON = "Killed me"

function private.Settings()
	return Wanted.db.settings.detect
end



-- ============================================================================
-- Frame
-- ============================================================================

function private.Create()
	local f = CreateFrame("Frame", "WantedDeathCard", UIParent)
	f:SetSize(WIDTH, HEIGHT_UNSURE)
	f:SetFrameStrata("HIGH")
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	Theme:Skin(f, C.panel, C.borderLight)
	local stripe = f:CreateTexture(nil, "ARTWORK")
	stripe:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)
	stripe:SetPoint("TOPLEFT", 1, -1)
	stripe:SetPoint("TOPRIGHT", -1, -1)
	stripe:SetHeight(3)
	-- Below the game's Release Spirit box, which sits at the top of the screen
	local pos = private.Settings().deathCardPos
	if pos and pos.point then
		f:SetPoint(pos.point, UIParent, pos.point, pos.x, pos.y)
	else
		f:SetPoint("TOP", UIParent, "TOP", 0, -250)
	end
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, _, x, y = self:GetPoint(1)
		private.Settings().deathCardPos = { point = point, x = x, y = y }
	end)
	-- Escape closes it, like the game's own windows
	if UISpecialFrames then
		tinsert(UISpecialFrames, "WantedDeathCard")
	end

	f.heading = Theme:Text(f, "small", "KILLED BY", C.accent)
	f.heading:SetPoint("TOPLEFT", 14, -14)
	f.close = W:Button(f, "x", "chip", 22, 20, function() DeathCard:Hide() end)
	f.close:SetPoint("TOPRIGHT", -8, -8)

	f.icon = f:CreateTexture(nil, "ARTWORK")
	f.icon:SetSize(28, 28)
	f.icon:SetPoint("TOPLEFT", 14, -34)
	f.name = Theme:Text(f, "title", "")
	f.name:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 8, 2)
	f.name:SetPoint("RIGHT", -14, 0)
	f.who = Theme:Text(f, "small", "")
	f.who:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -3)
	f.who:SetPoint("RIGHT", -14, 0)

	f.sure = Theme:Text(f, "small", "", C.amber)
	f.sure:SetPoint("TOPLEFT", 14, -74)
	f.sure:SetPoint("RIGHT", -14, 0)
	f.record = Theme:Text(f, "body", "")
	f.record:SetPoint("RIGHT", -14, 0)
	f.status = Theme:Text(f, "body", "")
	f.status:SetPoint("TOPLEFT", f.record, "BOTTOMLEFT", 0, -4)
	f.status:SetPoint("RIGHT", -14, 0)

	-- Each wide enough for its longest label ("On your Kill on Sight" once added)
	f.kos = W:Button(f, "Kill on Sight", "primary", 140, 26, function() private.AddKoS() end)
	f.kos:SetPoint("BOTTOMLEFT", 14, 12)
	f.post = W:Button(f, "Post a bounty", "secondary", 104, 26, function() private.PostBounty() end)
	f.post:SetPoint("LEFT", f.kos, "RIGHT", 6, 0)
	f.where = W:Button(f, "Where they've been", "secondary", 0, 26, function() private.ShowFile() end)
	f.where:SetPoint("LEFT", f.post, "RIGHT", 6, 0)
	f.where:SetPoint("RIGHT", -14, 0)
	f:Hide()
	private.frame = f
	return f
end

function private.Frame()
	return private.frame or private.Create()
end



-- ============================================================================
-- Filling it
-- ============================================================================

---Fills the card for the enemy who killed us. how is "recap" (the game's death recap named them) or "targeting"
---(the one enemy who had us targeted, a guess).
function private.Fill(guid, how)
	local f = private.Frame()
	local d = Wanted.Enemies:Describe(guid)
	private.guid, private.name = guid, d.name
	Theme:SetClassIcon(f.icon, d.class)
	f.name:SetText(Theme:ClassName(d.name, d.class))
	local who = {}
	if d.level then
		tinsert(who, "Level "..d.level)
	end
	if d.race then
		tinsert(who, d.race)
	end
	if d.guild then
		tinsert(who, "<"..d.guild..">")
	end
	local player = Store:GetPlayer(guid) or {}
	local ours = UnitFactionGroup("player")
	local faction = player.faction or (ours == "Horde" and "Alliance" or "Horde")
	local rank = Wanted.BlizzRank and Wanted.BlizzRank:RankOf(d.name, faction)
	if rank and Wanted.Ranks then
		tinsert(who, Wanted.Ranks:BadgeText(rank).." "..Wanted.Ranks:Label(rank))
	end
	f.who:SetText(table.concat(who, "   "))
	-- The record sits where the "probably" line would be when there's none
	f.record:ClearAllPoints()
	f.record:SetPoint("RIGHT", -14, 0)
	if how == "recap" then
		f.sure:Hide()
		f.record:SetPoint("TOPLEFT", 14, -76)
		f:SetHeight(HEIGHT)
	elseif how == "pet" then
		-- Certain, so not a warning: said in the card's quiet colour
		f.sure:SetText("Their pet landed the killing blow")
		f.sure:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
		f.sure:Show()
		f.record:SetPoint("TOPLEFT", 14, -94)
		f:SetHeight(HEIGHT_UNSURE)
	elseif how == "pet guess" then
		f.sure:SetText("Probably "..d.name..": a pet landed the killing blow, and they had you targeted")
		f.sure:SetTextColor(C.amber[1], C.amber[2], C.amber[3])
		f.sure:Show()
		f.record:SetPoint("TOPLEFT", 14, -94)
		f:SetHeight(HEIGHT_UNSURE)
	else
		f.sure:SetText("Probably "..d.name..": the death recap didn't say, but they had you targeted")
		f.sure:SetTextColor(C.amber[1], C.amber[2], C.amber[3])
		f.sure:Show()
		f.record:SetPoint("TOPLEFT", 14, -94)
		f:SetHeight(HEIGHT_UNSURE)
	end
	f.record:SetText(format("They've won %d, you've won %d", d.losses, d.wins))
	local status = {}
	if d.bounty > 0 then
		tinsert(status, Theme:Colorize(Wanted.Bounties:FormatMoney(d.bounty).." bounty on them", C.gold))
	end
	if d.outlaw then
		tinsert(status, Theme:Colorize("Outlaw: "..d.outlaw.rank, C.amber))
	end
	if d.kosGuild then
		tinsert(status, Theme:Colorize("<"..d.guild.."> is on your Kill on Sight", C.red))
	elseif d.guildKos then
		tinsert(status, Theme:Colorize("On your guild's Kill on Sight", C.red))
	end
	f.status:SetText(#status > 0 and table.concat(status, "   ") or "No bounty on them yet")
	private.UpdateKoSButton(d)
end

function private.UpdateKoSButton(d)
	local f = private.frame
	if d.kos and not d.guildKos and not d.kosGuild then
		f.kos:SetText("On your Kill on Sight")
		f.kos:SetStyle("secondary")
		f.kos:Disable()
	else
		f.kos:SetText("Kill on Sight")
		f.kos:SetStyle("primary")
		f.kos:Enable()
	end
end



-- ============================================================================
-- Buttons
-- ============================================================================

function private.AddKoS()
	local guid = private.guid
	if not guid then
		return
	end
	Wanted.Enemies:SetKoS(guid, private.name, true)
	Wanted.Enemies:SetReason(guid, KOS_REASON)
	private.UpdateKoSButton(Wanted.Enemies:Describe(guid))
end

function private.PostBounty()
	if not private.name then
		return
	end
	-- The board's own rules apply there: the other faction only, the minimum, one bounty per poster per target
	Wanted.UI:Show("board")
	Wanted.BoardPage:PrefillTarget(private.name)
end

function private.ShowFile()
	if private.guid then
		Wanted.TargetFile:ShowPlayer(private.guid, private.name)
	end
end



-- ============================================================================
-- Showing and hiding
-- ============================================================================

---Hides the card once it has been up SHOW_SECONDS; until then it checks again when that time is due. Each showing
---gets its own token, so the check of an earlier one doesn't touch a newer one.
function private.Expire(token)
	if private.token ~= token or not DeathCard:IsShown() then
		return
	end
	local left = SHOW_SECONDS - (GetTime() - private.shownAt)
	if left > 0 then
		C_Timer.After(left, function() private.Expire(token) end)
	else
		DeathCard:Hide()
	end
end

---Shows the card for the enemy the latest death names.
function DeathCard:ShowFor(guid, how)
	if private.Settings().deathCard == false or not guid then
		return
	end
	private.Fill(guid, how)
	private.token = (private.token or 0) + 1
	private.shownAt = GetTime()
	private.Frame():Show()
	local token = private.token
	C_Timer.After(SHOW_SECONDS, function() private.Expire(token) end)
end

function DeathCard:Hide()
	if private.frame then
		private.frame:Hide()
	end
end

function DeathCard:IsShown()
	return private.frame ~= nil and private.frame:IsShown()
end

---The GUID of the enemy the card is about, while it's shown.
function DeathCard:GetKiller()
	return DeathCard:IsShown() and private.guid or nil
end

---The card's frame, for tests.
function DeathCard:GetFrame()
	return private.Frame()
end

---Whether the card takes the place of the one-line "Killed by" warning (Alerts).
function DeathCard:IsOn()
	return private.Settings().deathCard ~= false
end

function DeathCard:OnEnable()
	Wanted.Enemies:OnChange(function(event, entry)
		if event == "killedby" and entry and entry.guid then
			local last = Wanted.Enemies:GetLastDeath()
			DeathCard:ShowFor(entry.guid, last and last.guid == entry.guid and last.how or "targeting")
		end
	end)
	local events = CreateFrame("Frame")
	events:RegisterEvent("PLAYER_ALIVE")
	events:RegisterEvent("PLAYER_UNGHOST")
	events:SetScript("OnEvent", function()
		-- PLAYER_ALIVE also comes on releasing to a ghost: the card stays for the run back
		if not UnitIsDeadOrGhost("player") then
			DeathCard:Hide()
		end
	end)
end
