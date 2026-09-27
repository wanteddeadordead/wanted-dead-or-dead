-- Wanted: catch-up from the desktop app. The app reads this account's saved data, asks the server for what it
-- lacks (this side's records past the chains held, and the other side's bounties on this side as notices) and
-- writes them into the !!WantedLink addon (WantedAppCatchup, keyed by account mark). At login they're taken in
-- in the background, as gap fills are, so the channel only has to carry what happens while playing.

local _, Wanted = ...
local Catchup = Wanted:NewModule("Catchup")
local Store = Wanted.Store
local Sync = Wanted.Sync
local Bridge = Wanted.Bridge
local private = {}
-- Records taken in per piece of background work
local BATCH = 50

function Catchup:OnEnable()
	-- The app sends the server this account's side, so it only gets this side's records back
	local faction = UnitFactionGroup("player")
	if faction == "Horde" or faction == "Alliance" then
		Wanted.db.faction = faction
	end
	Catchup:Import()
end

---A record as the addon makes them: plain values only, its id its origin and seq.
function private.IsWellFormed(r)
	if type(r) ~= "table" or type(r.kind) ~= "string" or type(r.origin) ~= "string" or type(r.seq) ~= "number"
		or type(r.t) ~= "number" or type(r.prev) ~= "string" or type(r.hash) ~= "string" or type(r.data) ~= "table"
		or r.id ~= r.origin..":"..r.seq then
		return false
	end
	for key, value in pairs(r.data) do
		local kind = type(value)
		if type(key) ~= "string" or (kind ~= "string" and kind ~= "number" and kind ~= "boolean") then
			return false
		end
	end
	return true
end

---Takes in this account's catch-up, if the app has written one newer than the last taken in.
function Catchup:Import()
	local all = WantedAppCatchup
	-- It can be large, and it's read once: let it go (a /reload loads the file again)
	WantedAppCatchup = nil
	local entry = type(all) == "table" and all[Wanted.db.accountMark]
	if type(entry) ~= "table" or type(entry.t) ~= "number" then
		return
	end
	if entry.t <= (Wanted.db.catchupT or 0) then
		Wanted:Log("Catch-up: already taken in")
		return
	end
	local records = type(entry.records) == "table" and entry.records or {}
	local notices = type(entry.notices) == "table" and entry.notices or {}
	local counts = { new = 0, held = 0, skipped = 0 }
	for first = 1, #records, BATCH do
		Wanted:QueueWork(function()
			Sync:WithoutForwarding(function()
				for i = first, min(first + BATCH - 1, #records) do
					local record = records[i]
					if not private.IsWellFormed(record) then
						counts.skipped = counts.skipped + 1
					elseif Store:MergeRelayed(record) then
						counts.new = counts.new + 1
					else
						counts.held = counts.held + 1
					end
				end
			end)
		end)
	end
	Wanted:QueueWork(function()
		-- After the records, which may already hold a notice of the same bounty
		for _, notice in ipairs(notices) do
			Bridge:ReceiveNotice(notice)
		end
		Wanted.db.catchupT = entry.t
		Wanted:Log("Catch-up: %d records new, %d already held, %d malformed; %d bounty notices", counts.new, counts.held,
			counts.skipped, #notices)
	end)
end
