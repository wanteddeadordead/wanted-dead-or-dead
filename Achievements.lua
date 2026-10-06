-- Wanted: world PvP achievements, from wanteddeadordead.com through the desktop app's catch-up. Earned once and kept
-- for good, for fun: not a rank (Wanted's ranks are Blizzard's). The server works them out and names them, so a new
-- achievement needs no addon update. Kept in memory only: the catch-up brings them again at each login.

local _, Wanted = ...
local Achievements = Wanted:NewModule("Achievements")
local private = {
	defs = {}, -- id -> { id, name, text }, in the listed order through `order`
	order = {},
	held = {}, -- lower-case name -> { id, ... }
}
local MAX_DEFS = 50
local MAX_HOLDERS = 5000

---A short single-line string from the catch-up, or nil.
function private.Text(value, maxLength)
	if type(value) ~= "string" or value == "" then
		return nil
	end
	return (strsub(gsub(value, "[%c|]", ""), 1, maxLength))
end

---Takes in the catch-up's achievements: what each is (defs) and who holds which (held, by lower-case name). Missing
---or malformed parts leave none.
---@param defs table?
---@param held table?
function Achievements:Take(defs, held)
	private.defs, private.order, private.held = {}, {}, {}
	if type(defs) ~= "table" then
		return
	end
	for i = 1, min(#defs, MAX_DEFS) do
		local d = defs[i]
		local id = type(d) == "table" and private.Text(d.id, 40)
		local name = id and private.Text(d.name, 40)
		if name and not private.defs[id] then
			private.defs[id] = { id = id, name = name, text = private.Text(d.text, 200) or "" }
			tinsert(private.order, id)
		end
	end
	local holders = 0
	for name, ids in pairs(type(held) == "table" and held or {}) do
		if holders >= MAX_HOLDERS then
			break
		end
		if type(name) == "string" and type(ids) == "table" then
			local list = {}
			for _, id in ipairs(ids) do
				if private.defs[id] then
					tinsert(list, id)
				end
			end
			if #list > 0 then
				private.held[strlower(name)] = list
				holders = holders + 1
			end
		end
	end
	Wanted:Log("Achievements: %d kinds, %d players hold some", #private.order, holders)
end

---The achievements a player holds, by full name ("First Last", any case): their definitions, in the listed order.
---@param name string?
---@return table
function Achievements:Of(name)
	local out = {}
	for _, id in ipairs(type(name) == "string" and private.held[strlower(name)] or {}) do
		tinsert(out, private.defs[id])
	end
	return out
end

---This character's achievements.
---@return table
function Achievements:Mine()
	return Achievements:Of(Wanted.Store and Wanted.Store:GetOrigin() or UnitName("player"))
end

---Every achievement there is, in the listed order.
---@return table
function Achievements:All()
	local out = {}
	for _, id in ipairs(private.order) do
		tinsert(out, private.defs[id])
	end
	return out
end

---Achievements' names in a short line: "Headhunter, Witness", or the first few and "+2" past `most`.
---@param list table
---@param most number?
---@return string
function Achievements:Names(list, most)
	most = most or #list
	local names = {}
	for i = 1, min(#list, most) do
		tinsert(names, list[i].name)
	end
	if #list > most then
		tinsert(names, "+"..(#list - most))
	end
	return table.concat(names, ", ")
end
