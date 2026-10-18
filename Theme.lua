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
	-- A panel for a window of its own over the game world (dialogs, menus): never see-through, as the themes make panel
	panelSolid = { 0.086, 0.09, 0.11, 1 },
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

-- The window themes, one per poker felt: the felt (Poker\Media\felt-<key>) under the whole window, darkened, panels
-- tinted from its colour, and an accent from its art. Red stays for danger and for "DEAD" in the brand in every theme.
-- base: the felt's own colour; accent: buttons, tabs, section labels, the selected menu entry; shade: how much the
-- felt is darkened (a pale felt more).
local THEMES = {
	{ key = "stormwind", name = "Stormwind", base = { 0.149, 0.204, 0.255 }, accent = { 0.83, 0.69, 0.36 }, shade = 0.29 },
	{ key = "orgrimmar", name = "Orgrimmar", base = { 0.282, 0.118, 0.114 }, accent = { 0.86, 0.33, 0.25 }, shade = 0.32 },
	{ key = "elwynn", name = "Elwynn Forest", base = { 0.188, 0.341, 0.204 }, accent = { 0.82, 0.62, 0.27 }, shade = 0.27 },
	{ key = "durotar", name = "Durotar", base = { 0.565, 0.216, 0.122 }, accent = { 0.9, 0.5, 0.25 }, shade = 0.22 },
	{ key = "stranglethorn", name = "Stranglethorn Vale", base = { 0.227, 0.325, 0.204 }, accent = { 0.36, 0.74, 0.55 }, shade = 0.29 },
	{ key = "winterspring", name = "Winterspring", base = { 0.4, 0.5, 0.58 }, accent = { 0.58, 0.8, 0.94 }, shade = 0.15 },
	{ key = "tanaris", name = "Tanaris", base = { 0.5, 0.39, 0.22 }, accent = { 0.9, 0.72, 0.38 }, shade = 0.18 },
	{ key = "undercity", name = "Undercity", base = { 0.24, 0.2, 0.27 }, accent = { 0.58, 0.82, 0.32 }, shade = 0.3 },
	{ key = "ironforge", name = "Ironforge", base = { 0.243, 0.224, 0.231 }, accent = { 0.96, 0.5, 0.18 }, shade = 0.35 },
	{ key = "darnassus", name = "Darnassus", base = { 0.224, 0.169, 0.275 }, accent = { 0.78, 0.76, 0.92 }, shade = 0.32 },
}
Theme.THEMES = THEMES

---A colour of the theme's base, darkened to a share of black (0..1), with an alpha.
local function Tint(base, share, alpha)
	return { 0.035 + base[1] * share, 0.035 + base[2] * share, 0.04 + base[3] * share, alpha or 1 }
end

---Sets a palette entry's values in place, so everything holding the table (the button styles) sees the change.
local function Put(name, color)
	local entry = C[name]
	for i = 1, 4 do
		entry[i] = color[i] or (i == 4 and 1 or nil)
	end
end

---The theme for a key, or the default for the player's side (Orgrimmar for the Horde, Stormwind for the Alliance).
---@param key string?
---@return table
function Theme:Get(key)
	for _, theme in ipairs(THEMES) do
		if theme.key == key then
			return theme
		end
	end
	local side = UnitFactionGroup and UnitFactionGroup("player")
	return side == "Horde" and THEMES[2] or THEMES[1]
end

---Applies a theme to the palette: call before any window is drawn (a window drawn already keeps its colours until a
---/reload). Panels are see-through over the felt, as the theme's art is meant to show.
---@param key string?
function Theme:Apply(key)
	local theme = Theme:Get(key)
	Theme.current = theme
	local b, a = theme.base, theme.accent
	Put("bg", Tint(b, 0.12))
	Put("titleBar", Tint(b, 0.08, 0))
	Put("sidebar", Tint(b, 0.1, 0.78))
	Put("panel", Tint(b, 0.16, 0.74))
	Put("panelAlt", Tint(b, 0.26, 0.82))
	Put("panelSolid", Tint(b, 0.16, 0.97))
	Put("input", Tint(b, 0.06, 0.9))
	Put("border", { 0.16 + b[1] * 0.25, 0.16 + b[2] * 0.25, 0.17 + b[3] * 0.25, 0.9 })
	Put("borderLight", { 0.26 + b[1] * 0.3, 0.26 + b[2] * 0.3, 0.27 + b[3] * 0.3, 1 })
	Put("accent", { a[1], a[2], a[3], 1 })
	Put("accentHover", { min(1, a[1] * 1.12 + 0.04), min(1, a[2] * 1.12 + 0.04), min(1, a[3] * 1.12 + 0.04), 1 })
	Put("accentDim", { a[1], a[2], a[3], 0.2 })
	return theme
end

---The theme's felt as a file path (it ships with Dead Man's Hand Poker, Wanted's own second folder).
---@param theme table?
function Theme:FeltFile(theme)
	theme = theme or Theme.current or Theme:Get()
	return "Interface\\AddOns\\"..Wanted.FOLDER.."_Poker\\Media\\felt-"..theme.key
end

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
	title = MakeFont("WantedFontTitle", 22, C.text),
	heading = MakeFont("WantedFontHeading", 13, C.text),
	body = MakeFont("WantedFontBody", 12, C.text),
	small = MakeFont("WantedFontSmall", 11, C.muted),
	tiny = MakeFont("WantedFontTiny", 10, C.faint),
	money = MakeFont("WantedFontMoney", 14, C.gold),
	stat = MakeFont("WantedFontStat", 20, C.text),
}
-- The brand's own face, Rye (Media\Rye.ttf, SIL Open Font License): Latin only, so only for the fixed brand words
do
	local display = CreateFont("WantedFontDisplay")
	display:SetFont("Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\Rye.ttf", 19, "")
	display:SetShadowOffset(1, -1)
	display:SetShadowColor(0, 0, 0, 0.9)
	display:SetTextColor(C.text[1], C.text[2], C.text[3])
	Theme.Fonts.display = display
end

---A solid colour texture covering a frame.
function Theme:Fill(frame, color, layer)
	local texture = frame:CreateTexture(nil, layer or "BACKGROUND")
	texture:SetAllPoints()
	texture:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
	return texture
end

---A line's thickness: at least one screen pixel at any UI scale. A plain 1-unit line can round away to nothing where
---it falls between pixels (the seam between two tabs lost both its edges).
local function Thickness(edge, horizontal)
	if PixelUtil and PixelUtil.SetHeight then
		if horizontal then
			PixelUtil.SetHeight(edge, 1, 1)
		else
			PixelUtil.SetWidth(edge, 1, 1)
		end
	elseif horizontal then
		edge:SetHeight(1)
	else
		edge:SetWidth(1)
	end
end

---A 1px border drawn as four textures.
function Theme:Border(frame, color)
	local edges = {}
	for i = 1, 4 do
		edges[i] = frame:CreateTexture(nil, "BORDER")
	end
	edges[1]:SetPoint("TOPLEFT")
	edges[1]:SetPoint("TOPRIGHT")
	Thickness(edges[1], true)
	edges[2]:SetPoint("BOTTOMLEFT")
	edges[2]:SetPoint("BOTTOMRIGHT")
	Thickness(edges[2], true)
	edges[3]:SetPoint("TOPLEFT")
	edges[3]:SetPoint("BOTTOMLEFT")
	Thickness(edges[3], false)
	edges[4]:SetPoint("TOPRIGHT")
	edges[4]:SetPoint("BOTTOMRIGHT")
	Thickness(edges[4], false)
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

---Sets the first of several texts that fits a width on one line, in the font string's own font, then in a smaller
---one; the last text, cut off, when none fits. For cards whose names and numbers can run long.
---@param fs FontString
---@param width number
---@param texts string[] longest first
---@param smaller string? a theme font to try before giving up
---@param wrap boolean? when nothing fits, the last text on up to two lines instead of cut off
function Theme:FitText(fs, width, texts, smaller, wrap)
	fs.fitFont = fs.fitFont or fs:GetFontObject()
	fs.fitWidth = width -- what the line has to fit (the tests check every fitted line against it)
	-- A font object brings its own colour: keep the one the line had
	local r, g, b = fs:GetTextColor()
	if wrap then
		fs:SetWordWrap(false)
	end
	for _, font in ipairs({ fs.fitFont, smaller and Theme.Fonts[smaller] or nil }) do
		fs:SetFontObject(font)
		fs:SetTextColor(r, g, b)
		for _, text in ipairs(texts) do
			fs:SetText(text)
			if fs:GetUnboundedStringWidth() <= width then
				return
			end
		end
	end
	if wrap then
		fs:SetWordWrap(true)
		fs:SetMaxLines(2)
	end
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

-- Star ratings: one sprite with a full, a half and an empty star side by side
local STAR_FILE = "Interface\\AddOns\\"..Wanted.FOLDER.."\\Media\\stars"

---Five stars as inline text (works in any font string or tooltip), in half steps. nil gives five empty stars.
---@param rating number? 0 to 5
---@param size number? height in pixels
---@return string
function Theme:Stars(rating, size)
	size = size or 12
	local parts = {}
	for i = 1, 5 do
		local slot = (rating and rating >= i) and 0 or ((rating and rating >= i - 0.5) and 1 or 2)
		tinsert(parts, format("|T%s:%d:%d:0:0:256:64:%d:%d:0:64|t", STAR_FILE, size, size, slot * 64, slot * 64 + 64))
	end
	return table.concat(parts)
end

---A player name in their class colour. The name is cleaned first (Theme:Plain): a bounty's target name comes from
---the poster's record as any peer sent it on.
function Theme:ClassName(name, class)
	name = Theme:Plain(name)
	local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if color and color.WrapTextInColorCode then
		return color:WrapTextInColorCode(name)
	elseif color then
		return format("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, name)
	end
	return name
end

---Text from a record or a peer as it may be shown: no escape codes (a "|H" would make a link, a "|T" a picture) or
---control characters, cut to a name's length; "?" when nothing is left.
---@param text any
---@return string
function Theme:Plain(text)
	return Wanted.Store:CleanName(text) or "?"
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
	-- Square and Classic show the same crest artwork as Crest on this client, so they're not offered as choices;
	-- they stay as fallbacks for a client missing the atlases
	{ key = "square", label = "Square", hidden = true, file = function(class)
		local name = class == "DEATHKNIGHT" and "DeathKnight" or (strsub(class, 1, 1)..strlower(strsub(class, 2)))
		return "Interface\\Icons\\ClassIcon_"..name
	end },
	{ key = "classic", label = "Classic", hidden = true, sheet = true },
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
			-- Only when hidden: the Nearby rows' icons sit in secure buttons, where a Show in combat is blocked
			if not texture:IsShown() then
				texture:Show()
			end
			return
		end
	end
	texture:Hide()
end
