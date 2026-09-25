-- Wanted: the look. One palette, one set of fonts, and helpers that draw flat panels with 1px borders
-- from plain colour textures, so nothing depends on the client's older dialog art.

local _, Wanted = ...
local Theme = {}
Wanted.Theme = Theme

local C = {
	bg = { 0.047, 0.051, 0.063, 1 },
	titleBar = { 0.071, 0.075, 0.09, 1 },
	sidebar = { 0.059, 0.063, 0.078, 1 },
	panel = { 0.086, 0.09, 0.11, 1 },
	panelAlt = { 0.114, 0.118, 0.141, 1 },
	input = { 0.035, 0.039, 0.047, 1 },
	hover = { 1, 1, 1, 0.05 },
	rowAlt = { 1, 1, 1, 0.018 },
	border = { 0.176, 0.184, 0.216, 1 },
	borderLight = { 0.26, 0.27, 0.31, 1 },
	text = { 0.925, 0.925, 0.945 },
	muted = { 0.6, 0.62, 0.68 },
	faint = { 0.4, 0.42, 0.47 },
	white = { 1, 1, 1 },
	accent = { 0.8, 0.18, 0.16 },
	accentHover = { 0.92, 0.26, 0.22 },
	accentDim = { 0.8, 0.18, 0.16, 0.22 },
	gold = { 1, 0.8, 0.32 },
	green = { 0.36, 0.8, 0.46 },
	greenDim = { 0.36, 0.8, 0.46, 0.18 },
	amber = { 0.96, 0.68, 0.22 },
	blue = { 0.42, 0.66, 1 },
	red = { 0.93, 0.33, 0.31 },
	redDim = { 0.93, 0.33, 0.31, 0.16 },
	transparent = { 0, 0, 0, 0 },
}
Theme.C = C

-- One file per alphabet, as the client's own fonts do, so a Cyrillic, Korean or Chinese name renders
-- instead of turning into boxes
local FONT_FILES = {
	{ "roman", "Fonts\\FRIZQT__.TTF" },
	{ "russian", "Fonts\\FRIZQT___CYR.TTF" },
	{ "korean", "Fonts\\2002.TTF" },
	{ "simplifiedchinese", "Fonts\\ARKai_T.ttf" },
	{ "traditionalchinese", "Fonts\\blei00d.TTF" },
}

---A font covering every alphabet the client ships, at a size and with optional flags ("OUTLINE").
function Theme:MakeFont(name, size, color, flags)
	local font
	if CreateFontFamily then
		local members = {}
		for _, entry in ipairs(FONT_FILES) do
			tinsert(members, { alphabet = entry[1], file = entry[2], height = size, flags = flags or "" })
		end
		local ok, family = pcall(CreateFontFamily, name, members)
		font = ok and family or nil
	end
	if not font then
		font = CreateFont(name)
		font:SetFont(FONT_FILES[1][2], size, flags or "")
	end
	font:SetShadowOffset(1, -1)
	font:SetShadowColor(0, 0, 0, 0.85)
	if color then
		font:SetTextColor(color[1], color[2], color[3])
	end
	return font
end

local function MakeFont(name, size, color, flags)
	return Theme:MakeFont(name, size, color, flags)
end
Theme.Fonts = {
	brand = MakeFont("WantedFontBrand", 17, C.text),
	title = MakeFont("WantedFontTitle", 18, C.text),
	heading = MakeFont("WantedFontHeading", 13, C.text),
	body = MakeFont("WantedFontBody", 12, C.text),
	small = MakeFont("WantedFontSmall", 11, C.muted),
	tiny = MakeFont("WantedFontTiny", 10, C.faint),
	money = MakeFont("WantedFontMoney", 14, C.gold),
	stat = MakeFont("WantedFontStat", 20, C.text),
}

---A solid colour texture covering a frame.
function Theme:Fill(frame, color, layer)
	local texture = frame:CreateTexture(nil, layer or "BACKGROUND")
	texture:SetAllPoints()
	texture:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
	return texture
end

---A 1px border drawn as four textures.
function Theme:Border(frame, color)
	local edges = {}
	for i = 1, 4 do
		edges[i] = frame:CreateTexture(nil, "BORDER")
	end
	edges[1]:SetPoint("TOPLEFT")
	edges[1]:SetPoint("TOPRIGHT")
	edges[1]:SetHeight(1)
	edges[2]:SetPoint("BOTTOMLEFT")
	edges[2]:SetPoint("BOTTOMRIGHT")
	edges[2]:SetHeight(1)
	edges[3]:SetPoint("TOPLEFT")
	edges[3]:SetPoint("BOTTOMLEFT")
	edges[3]:SetWidth(1)
	edges[4]:SetPoint("TOPRIGHT")
	edges[4]:SetPoint("BOTTOMRIGHT")
	edges[4]:SetWidth(1)
	frame._edges = edges
	Theme:SetBorderColor(frame, color)
	return edges
end

function Theme:SetBorderColor(frame, color)
	for _, edge in ipairs(frame._edges or {}) do
		edge:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
	end
end

---Background plus border.
function Theme:Skin(frame, bg, border)
	frame._bg = Theme:Fill(frame, bg)
	if border then
		Theme:Border(frame, border)
	end
end

function Theme:SetBg(frame, color)
	if frame._bg then
		frame._bg:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
	end
end

---A font string in one of the theme fonts.
function Theme:Text(parent, font, text, color, layer)
	local fs = parent:CreateFontString(nil, layer or "OVERLAY")
	fs:SetFontObject(Theme.Fonts[font or "body"])
	if color then
		fs:SetTextColor(color[1], color[2], color[3])
	end
	fs:SetText(text or "")
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(false)
	return fs
end

---A horizontal 1px line.
function Theme:Line(parent, color)
	local line = parent:CreateTexture(nil, "BORDER")
	line:SetHeight(1)
	local c = color or C.border
	line:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
	return line
end

function Theme:Hex(color)
	return format("|cff%02x%02x%02x", floor(color[1] * 255 + 0.5), floor(color[2] * 255 + 0.5), floor(color[3] * 255 + 0.5))
end

function Theme:Colorize(text, color)
	return Theme:Hex(color)..text.."|r"
end

---Money with coin icons where the client offers them (display only, never for chat).
function Theme:Money(copper)
	copper = floor((copper or 0) + 0.5)
	if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
		return C_CurrencyInfo.GetCoinTextureString(copper)
	elseif GetCoinTextureString then
		return GetCoinTextureString(copper)
	end
	return Wanted.Bounties:FormatMoney(copper)
end

---A player name in their class colour.
function Theme:ClassName(name, class)
	local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if color and color.WrapTextInColorCode then
		return color:WrapTextInColorCode(name or "?")
	elseif color then
		return format("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, name or "?")
	end
	return name or "?"
end

function Theme:ClassLabel(class)
	if not class then
		return ""
	end
	local localized = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]
	return localized or (strsub(class, 1, 1)..strlower(strsub(class, 2)))
end

---"5m ago" style durations.
function Theme:Ago(seconds)
	seconds = max(floor(seconds or 0), 0)
	if seconds < 60 then
		return "just now"
	elseif seconds < 3600 then
		return floor(seconds / 60).."m ago"
	elseif seconds < 86400 then
		return floor(seconds / 3600).."h ago"
	end
	return floor(seconds / 86400).."d ago"
end

---"6d 4h" style remaining time.
function Theme:Left(seconds)
	seconds = max(floor(seconds or 0), 0)
	if seconds < 3600 then
		return max(floor(seconds / 60), 1).."m left"
	elseif seconds < 86400 then
		return floor(seconds / 3600).."h left"
	end
	local days = floor(seconds / 86400)
	local hours = floor(seconds % 86400 / 3600)
	return days.."d "..hours.."h left"
end

-- Class icon styles the client ships. Atlases are checked before use, so a style this client lacks falls
-- back to the next one instead of drawing nothing.
Theme.ICON_STYLES = {
	{ key = "crest", label = "Crest", atlas = function(class) return "classicon-"..strlower(class) end },
	{ key = "round", label = "Round", atlas = function(class) return "groupfinder-icon-class-"..strlower(class) end },
	{ key = "color", label = "Coloured", atlas = function(class) return "groupfinder-icon-class-color-"..strlower(class) end },
	{ key = "square", label = "Square", file = function(class)
		local name = class == "DEATHKNIGHT" and "DeathKnight" or (strsub(class, 1, 1)..strlower(strsub(class, 2)))
		return "Interface\\Icons\\ClassIcon_"..name
	end },
	{ key = "classic", label = "Classic", sheet = true },
}

local function AtlasExists(atlas)
	if C_Texture and C_Texture.GetAtlasInfo then
		return C_Texture.GetAtlasInfo(atlas) ~= nil
	end
	return true
end

local function ApplyStyle(texture, style, class)
	if style.atlas then
		local atlas = style.atlas(class)
		if not AtlasExists(atlas) or not texture.SetAtlas then
			return false
		end
		texture:SetAtlas(atlas)
		return true
	elseif style.file then
		texture:SetTexture(style.file(class))
		texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		return true
	elseif style.sheet and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class] then
		texture:SetTexture("Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes")
		texture:SetTexCoord(unpack(CLASS_ICON_TCOORDS[class]))
		return true
	end
	return false
end

---Puts a class icon on a texture in the chosen style (Settings), falling back through the others.
---@param texture Texture
---@param class string? e.g. "ROGUE"
---@param styleKey string? a style to force (for the Settings previews)
function Theme:SetClassIcon(texture, class, styleKey)
	if not class then
		texture:Hide()
		return
	end
	local chosen = styleKey or (Wanted.db and Wanted.db.settings.iconStyle) or "crest"
	local order = {}
	for _, style in ipairs(Theme.ICON_STYLES) do
		if style.key == chosen then
			tinsert(order, 1, style)
		elseif not styleKey then
			tinsert(order, style)
		end
	end
	for _, style in ipairs(order) do
		texture:SetTexCoord(0, 1, 0, 1)
		if ApplyStyle(texture, style, class) then
			texture:Show()
			return
		end
	end
	texture:Hide()
end
