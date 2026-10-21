-- Wanted: war and race points on the minimap. In the zone you are in, the war's towers, inhibitors and keep and
-- tonight's race points show as small seals where they stand, in the colours the world map gives them (WarMap
-- supplies the points). They are plain textures on our own frames, children of the minimap: nothing is added to the
-- game's frames or pins, and none is protected, so they are safe in combat. Hidden in instances, and when the setting
-- is off. Updated on a zone change, when the wars or races change, and each second (you move, the minimap zooms).

local _, Wanted = ...
local MinimapPins = Wanted:NewModule("MinimapPins")
local GuildWars = Wanted.GuildWars
local Races = Wanted.Races
local private = { pins = {}, used = 0 }
-- The minimap's width in yards at each zoom level, outdoors and indoors (the figures minimap libraries use). The
-- game has no call for it.
local OUTDOOR = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 }
local INDOOR = { [0] = 300, 240, 180, 120, 80, 50 }
local SCALE = 0.5 -- a seal's size on the minimap, against the world map's

function MinimapPins:OnEnable()
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	frame:SetScript("OnEvent", function()
		-- The zone's map is known a moment after the event
		C_Timer.After(1, function() MinimapPins:Refresh() end)
	end)
	GuildWars:OnChange(function() MinimapPins:Refresh() end)
	Races:OnChange(function() MinimapPins:Refresh() end)
	C_Timer.NewTicker(1, Wanted:Timed("Minimap pins", function() MinimapPins:Refresh() end))
end

---Whether the points show (Settings, the world map button's menu).
function MinimapPins:Shown()
	return Wanted.db.settings.minimapWar ~= false
end

function MinimapPins:SetShown(shown)
	Wanted.db.settings.minimapWar = shown and true or false
	MinimapPins:Refresh()
end

---Whether the minimap is set to the indoor zoom range, found as minimap libraries do: nudge the zoom and see whether
---the game's zoom setting still agrees with it.
local function Indoors()
	local zoom = Minimap:GetZoom()
	if type(zoom) ~= "number" then
		return false
	end
	local outdoorSetting, indoorSetting = tonumber(GetCVar("minimapZoom")), tonumber(GetCVar("minimapInsideZoom"))
	if not (outdoorSetting and indoorSetting) then
		return false
	end
	if outdoorSetting == indoorSetting then
		Minimap:SetZoom(zoom < 2 and zoom + 1 or zoom - 1)
	end
	local indoors = outdoorSetting ~= Minimap:GetZoom()
	Minimap:SetZoom(zoom)
	return indoors
end

---The minimap's radius in yards.
local function Radius()
	local zoom = Minimap:GetZoom()
	zoom = type(zoom) == "number" and zoom or 0
	local table_ = Indoors() and INDOOR or OUTDOOR
	return (table_[zoom] or table_[0]) / 2
end

local function Pin(index)
	local pin = private.pins[index]
	if not pin then
		pin = CreateFrame("Frame", nil, Minimap)
		pin:SetFrameLevel(Minimap:GetFrameLevel() + 5)
		pin.icon = pin:CreateTexture(nil, "ARTWORK")
		pin.icon:SetAllPoints()
		private.pins[index] = pin
	end
	return pin
end

---Puts the points of the zone you are in on the minimap, or takes them off.
function MinimapPins:Refresh()
	local used = 0
	local mapId = MinimapPins:Shown() and not IsInInstance() and C_Map.GetBestMapForUnit("player") or nil
	local position = mapId and C_Map.GetPlayerMapPosition(mapId, "player") or nil
	local width, height = nil, nil
	if position and C_Map.GetMapWorldSize then
		width, height = C_Map.GetMapWorldSize(mapId)
	end
	if position and width and height and width > 0 then
		local points = Wanted.WarMap:MinimapPoints(mapId)
		if #points > 0 then
			local radius, half = Radius(), Minimap:GetWidth() / 2
			local facing = GetCVar("rotateMinimap") == "1" and GetPlayerFacing() or nil
			local sin, cos = facing and math.sin(facing) or 0, facing and math.cos(facing) or 1
			for _, point in ipairs(points) do
				-- Yards east and north of you, then pixels from the minimap's centre (turned with it when it rotates)
				local east, north = (point.x / 100 - position.x) * width, -(point.y / 100 - position.y) * height
				local x, y = (east * cos + north * sin) / radius * half, (-east * sin + north * cos) / radius * half
				if x * x + y * y <= half * half then
					used = used + 1
					local pin = Pin(used)
					local size = point.px * SCALE
					pin:SetSize(size, size)
					pin.icon:SetTexture(point.texture)
					pin:ClearAllPoints()
					pin:SetPoint("CENTER", Minimap, "CENTER", x, y)
					pin:Show()
				end
			end
		end
	end
	for index = used + 1, #private.pins do
		private.pins[index]:Hide()
	end
	private.used = used
end

---How many points show now.
function MinimapPins:Count()
	return private.used
end
