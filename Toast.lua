-- Unlock toasts: a framed popup with the art for each achievement, weekly medal, badge tier, rank or calling-card
-- piece you unlock, near the top of the screen. Only ever out of combat and in the world: what comes in during a fight
-- or a loading screen waits (the catch-up's come at login, behind the loading screen), and toasts showing when one
-- starts go back in line. Click one to open your calling card.

local _, Wanted = ...
local Theme = Wanted.Theme
local Toast = Wanted:NewModule("Toast")
local private = { queue = {}, frames = {}, ready = false, loading = false }

local MAX_SHOWN = 3
local SHOW_SECONDS, FADE_IN_SECONDS, FADE_OUT_SECONDS = 6, 0.3, 1
local WIDTH, HEIGHT, GAP, TOP = 360, 76, 6, -190
local ART_HEIGHT, ART_MAX_WIDTH = 60, 120
local MORE_NAMES = 3 -- names listed on the "more" toast
local SETTLE_SECONDS = 3 -- after a loading screen, before the first toast
local FALLBACK_SECONDS = 15 -- after login, in case no loading screen ever says it's done
local MAX_FRAME_SECONDS = 0.1 -- a longer frame (a hitch, a loading screen) counts as this long



-- ============================================================================
-- Public
-- ============================================================================

function Toast:OnEnable()
	Wanted:OnCombatEnd(function() private.Pump() end)
	private.events = private.events or CreateFrame("Frame")
	private.events:RegisterEvent("PLAYER_REGEN_DISABLED")
	private.events:RegisterEvent("LOADING_SCREEN_ENABLED")
	private.events:RegisterEvent("LOADING_SCREEN_DISABLED")
	private.events:SetScript("OnEvent", function(_, event)
		if event == "LOADING_SCREEN_DISABLED" then
			private.loading = false
			private.ReadySoon(SETTLE_SECONDS)
			return
		end
		if event == "LOADING_SCREEN_ENABLED" then
			private.loading, private.ready = true, false
		end
		private.Pause()
	end)
	private.ReadySoon(FALLBACK_SECONDS)
end

---Queues a toast: { kind = "ACHIEVEMENT EARNED", name = "Witness", detail = "...", art = texture path,
---coords = { left, right, top, bottom }?, aspect = width / height of the art (1 for square), onClick = function? (else a
---click opens your calling card) }.
---@param toast table
function Toast:Add(toast)
	tinsert(private.queue, toast)
	private.Pump()
end

---How many toasts are waiting to show.
---@return number
function Toast:Pending()
	return #private.queue
end

---The toasts on screen, top first.
---@return table[]
function Toast:Shown()
	local out = {}
	for _, frame in ipairs(private.frames) do
		if frame:IsShown() then
			tinsert(out, frame.toast)
		end
	end
	return out
end



-- ============================================================================
-- Showing
-- ============================================================================

---Shows what's waiting in the free places, out of combat only. When more wait than there's room for, the last place
---sums up the rest.
function private.Pump()
	if not private.ready or InCombatLockdown() or #private.queue == 0 then
		return
	end
	local free = MAX_SHOWN - #Toast:Shown()
	if free <= 0 then
		return
	end
	if #private.queue > free then
		for _ = 1, free - 1 do
			private.Show(tremove(private.queue, 1))
		end
		local names = {}
		for i = 1, min(#private.queue, MORE_NAMES) do
			tinsert(names, private.queue[i].name)
		end
		local more = #private.queue - #names
		private.Show({ kind = format("%d MORE UNLOCKS", #private.queue), name = table.concat(names, ", ")..(more > 0 and format(" and %d more", more) or ""),
			detail = "Click to see them on your calling card" })
		private.queue = {}
	else
		while #private.queue > 0 do
			private.Show(tremove(private.queue, 1))
		end
	end
	Wanted.Alerts:Sound("important")
end

---Lets toasts show after seconds, unless a loading screen has started by then.
function private.ReadySoon(seconds)
	C_Timer.After(seconds, function()
		if not private.loading then
			private.ready = true
			private.Pump()
		end
	end)
end

---Puts the toasts on screen back at the front of the line, in order, for when the fight is over.
function private.Pause()
	local back = {}
	for _, frame in ipairs(private.frames) do
		if frame:IsShown() then
			tinsert(back, frame.toast)
			frame:Hide()
		end
	end
	for i = #back, 1, -1 do
		tinsert(private.queue, 1, back[i])
	end
end

---Shows a toast in the first free place.
function private.Show(toast)
	local frame
	for i = 1, MAX_SHOWN do
		local f = private.frames[i] or private.NewFrame(i)
		if not f:IsShown() then
			frame = f
			break
		end
	end
	frame.toast = toast
	frame.kind:SetText(toast.kind)
	frame.name:SetText(toast.name)
	frame.detail:SetText(toast.detail or "Click to open your calling card")
	local aspect = toast.aspect or 1
	local width = toast.art and min(ART_MAX_WIDTH, ART_HEIGHT * aspect) or 0
	frame.art:SetSize(max(width, 1), max(width, 1) / aspect)
	-- The text starts just right of the art, whatever its shape
	local left = 8 + width + (width > 0 and 10 or 4)
	frame.kind:ClearAllPoints()
	frame.kind:SetPoint("TOPLEFT", left, -10)
	for _, fs in ipairs({ frame.kind, frame.name, frame.detail }) do
		fs:SetWidth(WIDTH - left - 10)
	end
	if toast.art then
		frame.art:SetTexture(toast.art)
		local c = toast.coords
		frame.art:SetTexCoord(c and c[1] or 0, c and c[2] or 1, c and c[3] or 0, c and c[4] or 1)
		frame.art:Show()
	else
		frame.art:Hide()
	end
	frame.age = 0
	frame:SetAlpha(0)
	frame:Show()
end

---A toast's frame, in place index (1 at the top).
function private.NewFrame(index)
	local frame = CreateFrame("Button", nil, UIParent)
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("TOP", 0, TOP - (index - 1) * (HEIGHT + GAP))
	frame:SetFrameStrata("DIALOG")
	Theme:Fill(frame, { 0.04, 0.06, 0.07, 0.94 })
	Theme:Border(frame, Theme.C.gold)
	frame.art = frame:CreateTexture(nil, "ARTWORK")
	frame.art:SetPoint("LEFT", 8, 0)
	frame.kind = Theme:Text(frame, "small", "", Theme.C.gold)
	frame.name = Theme:Text(frame, "title", "")
	frame.name:SetPoint("TOPLEFT", frame.kind, "BOTTOMLEFT", 0, -3)
	frame.detail = Theme:Text(frame, "small", "")
	frame.detail:SetPoint("TOPLEFT", frame.name, "BOTTOMLEFT", 0, -4)
	frame:SetScript("OnClick", function(self)
		self:Hide()
		if self.toast.onClick then
			self.toast.onClick()
		else
			Wanted.CallingCard:Show()
		end
		private.Pump()
	end)
	frame:SetScript("OnUpdate", function(self, elapsed)
		self.age = self.age + min(elapsed, MAX_FRAME_SECONDS)
		if self.age < FADE_IN_SECONDS then
			self:SetAlpha(self.age / FADE_IN_SECONDS)
		elseif self.age < SHOW_SECONDS then
			self:SetAlpha(1)
		elseif self.age < SHOW_SECONDS + FADE_OUT_SECONDS then
			self:SetAlpha(1 - (self.age - SHOW_SECONDS) / FADE_OUT_SECONDS)
		else
			self:Hide()
			private.Pump()
		end
	end)
	frame:Hide()
	private.frames[index] = frame
	return frame
end
