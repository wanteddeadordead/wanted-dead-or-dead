-- Wanted: what the HUDs share (the zone, race, war and capture HUDs). Each HUD registers once with its Settings switch;
-- the kit then gives it a place the player can drag it to (kept per HUD for the account, Reset puts them back), a
-- chevron that folds it to a one-line bar (kept per HUD), a close X, and the /wanted hud commands. A hidden HUD is the
-- HUD's switch in Settings turned off, so the switch and the commands always agree.

local _, Wanted = ...
local HudKit = Wanted:NewModule("HudKit")
local Theme = Wanted.Theme
local W = Wanted.Widgets
local C = Theme.C
local COLLAPSED_HEIGHT = 28
local CHEVRON = "Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\chevron"
-- The order /wanted hud lists and toggles them in
local ORDER = { "zone", "race", "war", "capture" }
local specs, frames = {}, {}

---Registers a HUD.
---@param key string "zone", "race", "war" or "capture"
---@param spec table { name, setting = fun(): table, field (its switch in that table: false is hidden), refresh = fun(),
---  place = fun(frame) (where it goes without a saved place), collapsedWidth? }
function HudKit:Register(key, spec)
	spec.posKey, spec.collapsedKey = key.."HudPos", key.."HudCollapsed"
	specs[key] = spec
end

---The container to build a HUD's content in, so folding hides it all at once.
---@return Frame
function HudKit:Body(f)
	local body = CreateFrame("Frame", nil, f)
	body:SetAllPoints()
	f.body = body
	return body
end

function HudKit:IsCollapsed(key)
	return Wanted.db.settings[specs[key].collapsedKey] == true
end

function HudKit:IsHidden(key)
	local spec = specs[key]
	return spec.setting()[spec.field] == false
end

---Puts the HUD where the player dragged it, else where it goes by default.
function HudKit:Place(key, f)
	local pos = Wanted.db.settings[specs[key].posKey]
	f:ClearAllPoints()
	if type(pos) == "table" and type(pos.point) == "string" and type(pos.x) == "number" and type(pos.y) == "number" then
		f:SetPoint(pos.point, UIParent, type(pos.relative) == "string" and pos.relative or pos.point, pos.x, pos.y)
	else
		specs[key].place(f)
	end
end

---Sizes the HUD, keeping where it is on screen and its saved place right for the new size.
function HudKit:Rescale(key, f, scale)
	local pos = Wanted.db.settings[specs[key].posKey]
	if type(pos) == "table" then
		local x, y = Theme:RescaleInPlace(f, scale)
		if x then
			pos.x, pos.y = x, y
		end
	else
		f:SetScale(Theme:ClampScale(scale))
	end
end

---Dresses a HUD built in HudKit:Body: its drag, its fold bar and its two buttons. Call once, after Build has set it up.
function HudKit:Attach(key, f)
	local spec = specs[key]
	frames[key] = f
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetClampedToScreen(true)
	f:SetScript("OnDragStart", function(self)
		-- Ours are plain frames; a protected one can't be moved in a fight
		if InCombatLockdown() and self:IsProtected() == true then
			return
		end
		self:StartMoving()
	end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relative, x, y = self:GetPoint(1)
		Wanted.db.settings[spec.posKey] = { point = point, relative = relative, x = x, y = y }
	end)
	-- What the HUD says folded: the module sets its text
	f.summary = Theme:Text(f, "small", "", C.text)
	f.summary:SetPoint("LEFT", 10, 0)
	f.summary:SetPoint("RIGHT", -10, 0)
	f.summary:SetJustifyH("LEFT")
	f.summary:SetWordWrap(false)
	-- Beside the HUD, not on it: its own corners are full
	local buttons = CreateFrame("Frame", nil, f)
	buttons:SetSize(40, 18)
	buttons:SetPoint("TOPLEFT", f, "TOPRIGHT", 2, 0)
	f.fold = W:Button(buttons, "", "ghost", 18, 18, function() HudKit:SetCollapsed(key, not HudKit:IsCollapsed(key)) end)
	f.fold:SetPoint("LEFT")
	f.fold.icon = f.fold:CreateTexture(nil, "ARTWORK")
	f.fold.icon:SetSize(12, 12)
	f.fold.icon:SetPoint("CENTER")
	f.fold.icon:SetTexture(CHEVRON)
	f.fold.icon:SetVertexColor(1, 1, 1, 0.6)
	local close = W:Button(buttons, "X", "ghost", 18, 18, function() HudKit:SetHidden(key, true) end)
	close:SetPoint("LEFT", f.fold, "RIGHT", 4, 0)
	W:Explain(close, "Hide", "Brings it back with /wanted hud "..key.." or its switch in Settings.", "ANCHOR_BOTTOM")
	HudKit:Place(key, f)
end

---Folds the HUD to its bar, or opens it again; kept for the account.
function HudKit:SetCollapsed(key, collapsed)
	Wanted.db.settings[specs[key].collapsedKey] = collapsed or nil
	specs[key].refresh()
end

---Shows the HUD's body or its bar, at the size the module worked out for the open HUD. Call from the module's Update,
---after it drew, before it shows the frame.
function HudKit:Apply(key, f, width, height)
	local spec = specs[key]
	local collapsed = HudKit:IsCollapsed(key)
	f.body:SetShown(not collapsed)
	f.summary:SetShown(collapsed)
	f:SetSize(collapsed and (spec.collapsedWidth or width) or width, collapsed and COLLAPSED_HEIGHT or height)
	f.fold.icon:SetRotation(collapsed and 0 or math.pi)
	W:Explain(f.fold, collapsed and "Open" or "Fold", collapsed and "Shows all of it again." or "Folds it to one line.", "ANCHOR_BOTTOM")
end

---Hides or shows a HUD (its switch in Settings), saved. The first hide says how to bring it back.
function HudKit:SetHidden(key, hidden)
	local spec = specs[key]
	spec.setting()[spec.field] = not hidden
	if hidden and not Wanted.db.settings.hudHint then
		Wanted.db.settings.hudHint = true
		Wanted:Print("A HUD is hidden. Bring it back with /wanted hud (all) or /wanted hud zone, race, war or capture, or in Settings.")
	end
	spec.refresh()
	if Wanted.UI then
		Wanted.UI:Refresh()
	end
end

---Hides every HUD that shows, or shows them all when none does.
function HudKit:ToggleAll()
	local anyShown = false
	for _, key in ipairs(ORDER) do
		anyShown = anyShown or (specs[key] ~= nil and not HudKit:IsHidden(key))
	end
	for _, key in ipairs(ORDER) do
		if specs[key] then
			HudKit:SetHidden(key, anyShown)
		end
	end
end

---Puts every HUD back where it goes by default.
function HudKit:ResetPositions()
	for key, spec in pairs(specs) do
		Wanted.db.settings[spec.posKey] = nil
		if frames[key] then
			HudKit:Place(key, frames[key])
		end
	end
end

Wanted:RegisterCommand("hud", "Shows or hides the HUDs: /wanted hud for all, /wanted hud zone, race, war or capture for one.", function(args)
	local key = strlower(strtrim(args or ""))
	if key == "" then
		HudKit:ToggleAll()
	elseif specs[key] then
		HudKit:SetHidden(key, not HudKit:IsHidden(key))
	else
		Wanted:Print("Which HUD? /wanted hud, or /wanted hud zone, race, war or capture.")
	end
end)
