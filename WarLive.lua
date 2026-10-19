-- Wanted: a war's live state in game, between catch-ups. The catch-up is read at login only, so during a war each
-- roster member's client says every 30-second tick, to the others of its side (Sync plugin G), which war point it
-- stands on and how many enemy players are near it; each client then runs the capture rule (the war contract's 4.2)
-- over the ticks itself: at each open point, net = min(6, attackers − defenders), progress kept, a point taken once its
-- progress reaches its cost; a lane's inhibitor opens when its tower falls, the keep when any inhibitor does. Our
-- side's count is the members who said they're there; the other side's (whose clients can't reach ours) is the most
-- enemies one of them saw near it, friends included. Provisional: the site counts the result from everyone's records.
-- It starts from the catch-up's warLive when there is one, and writes into the war's battle (lanes, keep, our turnout).

local _, Wanted = ...
local WarLive = Wanted:NewModule("WarLive")
local GuildWars = Wanted.GuildWars
local private = { samples = {}, state = {} }
local TAG = "G"
local TICK = 30
local NET_CAP = 6
local MAX_PEERS, MAX_ENEMIES = 80, 40
-- The capture costs when the site hasn't given them (4.2): round(3.8 × N^0.47), the keep 2.2 × that; N the larger
-- roster, at least 5
local function Cost(n, keep)
	local base = floor(3.8 * max(n, 5) ^ 0.47 + 0.5)
	return keep and floor(2.2 * base + 0.5) or base
end

function WarLive:OnEnable()
	Wanted.Sync:RegisterPlugin(TAG, function(tbl, sender) WarLive:OnPeer(tbl, sender) end, { priority = 3 })
	C_Timer.NewTicker(5, Wanted:Timed("War live", function() WarLive:Step() end))
end

---Each few seconds in a war's zone: our sample once a tick (on the roster), and the ticks gone by applied.
function WarLive:Step()
	local now = GetServerTime()
	local war, zone, x, y, mapId = GuildWars:Here(now)
	if not war or type(war.warId) ~= "number" then
		return
	end
	local slot = floor(now / TICK)
	if GuildWars:OnRoster(war) and private.sent ~= slot then
		private.sent = slot
		local point = GuildWars:PointAt(war, zone, x, y, mapId)
		local sample = { w = war.warId, t = slot, p = point and point.id or "", e = min(Wanted.Enemies:CountNearby(), MAX_ENEMIES) }
		Wanted.Sync:BroadcastPlugin(TAG, sample)
		private.Take(war, UnitName("player") or "?", sample)
	end
	local b = war.battle
	if now >= b.start and now < b.stop then
		private.Advance(war, zone, floor(b.start / TICK), slot)
	end
end

---Another of our side's samples: kept when it's for this client's war, now, and makes sense.
function WarLive:OnPeer(tbl, sender)
	if type(tbl) ~= "table" or type(sender) ~= "string" or sender == "" then
		return
	end
	local war = GuildWars:Here()
	if not war or tbl.w ~= war.warId or type(tbl.t) ~= "number" or type(tbl.e) ~= "number" or type(tbl.p) ~= "string" then
		return
	end
	if abs(tbl.t - floor(GetServerTime() / TICK)) > 2 or tbl.e < 0 or tbl.e > MAX_ENEMIES then
		return
	end
	private.Take(war, sender, tbl)
end

function private.Take(war, sender, sample)
	local book = private.samples[sample.t]
	if not book then
		book = {}
		private.samples[sample.t] = book
		-- Only the last few ticks are needed
		for t in pairs(private.samples) do
			if t < sample.t - 4 then
				private.samples[t] = nil
			end
		end
	end
	local count = 0
	for _ in pairs(book) do
		count = count + 1
	end
	if book[sender] or count < MAX_PEERS then
		book[sender] = { p = sample.p, e = floor(sample.e) }
	end
end

---The war's provisional points, from the catch-up's when it has them: id -> { progress, cost, taken }.
function private.Start(war, zone)
	local roster = war.roster or {}
	local n = max(roster.count or 0, tonumber(roster.rival) or 0)
	local lanes = {}
	for _, lane in ipairs(type(war.battle.lanes) == "table" and war.battle.lanes or {}) do
		lanes[lane.id] = lane
	end
	local points = {}
	for _, p in ipairs(GuildWars:Points(war, zone)) do
		if p.role ~= "rally" then
			local known = p.lane and lanes[p.lane] and lanes[p.lane][p.role] or {}
			points[p.id] = { point = p, progress = tonumber(known.progress) or 0, cost = tonumber(known.cost) or Cost(n, p.role == "keep"),
				taken = known.state == "taken" or (p.role == "keep" and type(war.battle.keep) == "table" and war.battle.keep.state == "fallen") }
		end
	end
	return points
end

---Applies the ticks from the last one applied to the one before now, then writes the state into the war's battle.
function private.Advance(war, zone, first, now)
	local state = private.state[war.warId]
	if not state then
		state = { points = private.Start(war, zone), tick = first - 1 }
		private.state[war.warId] = state
	end
	local attack = war.role == "attack"
	local changed = false
	for t = max(state.tick + 1, now - 4), now - 1 do
		state.tick = t
		local here = {}
		for _, s in pairs(private.samples[t] or {}) do
			if s.p ~= "" then
				local at = here[s.p] or { ours = 0, theirs = 0 }
				at.ours, at.theirs = at.ours + 1, max(at.theirs, s.e)
				here[s.p] = at
			end
		end
		for id, at in pairs(here) do
			local p = state.points[id]
			if p and not p.taken and private.Open(state.points, p.point) then
				local attackers, defenders = attack and at.ours or at.theirs, attack and at.theirs or at.ours
				local net = min(NET_CAP, attackers - defenders)
				if net > 0 then
					p.progress = min(p.progress + net, p.cost)
					p.taken = p.progress >= p.cost
					changed = true
				end
			end
		end
	end
	state.tick = max(state.tick, now - 1)
	private.Write(war, state, now)
	if changed then
		GuildWars:Touch()
	end
end

---Whether a point can be attacked now: a tower always; an inhibitor once its lane's tower fell; the keep once any
---inhibitor did.
function private.Open(points, point)
	if point.role == "tower" then
		return true
	end
	for _, p in pairs(points) do
		if p.taken and p.point.lane and ((point.role == "inhibitor" and p.point.role == "tower" and p.point.lane == point.lane)
			or (point.role == "keep" and p.point.role == "inhibitor")) then
			return true
		end
	end
	return false
end

---The provisional state into the war's battle as the screens read it: lanes, keep, our side's turnout.
function private.Write(war, state, now)
	local b = war.battle
	local lanes, keep, anyInhib = {}, "sealed", false
	for _, p in pairs(state.points) do
		local point = p.point
		local entry = p.taken and { state = "taken", progress = p.cost, cost = p.cost }
			or p.progress > 0 and { state = "taking", pct = floor(p.progress / p.cost * 100), progress = p.progress, cost = p.cost }
			or { progress = 0, cost = p.cost }
		if point.lane then
			lanes[point.lane] = lanes[point.lane] or { id = point.lane }
			lanes[point.lane][point.role] = entry
			anyInhib = anyInhib or (point.role == "inhibitor" and p.taken)
		elseif p.taken then
			keep = "fallen"
		end
	end
	if keep ~= "fallen" and anyInhib then
		keep = "open"
	end
	b.lanes = {}
	for _, id in ipairs({ "top", "mid", "bot" }) do
		tinsert(b.lanes, lanes[id] or { id = id })
	end
	b.keep = { state = keep }
	b.live = true
	-- Our side's roster members heard this tick or the last
	local seen = {}
	for t = now - 1, now do
		for sender in pairs(private.samples[t] or {}) do
			seen[sender] = true
		end
	end
	local ours = 0
	for _ in pairs(seen) do
		ours = ours + 1
	end
	b.turnout = b.turnout or {}
	if ours > 0 then
		b.turnout[war.role == "attack" and "attacker" or "defender"] = ours
	end
end
