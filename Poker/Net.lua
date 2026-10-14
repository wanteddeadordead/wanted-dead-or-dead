-- Wanted: Dead Man's Hand Poker. Ties this character's table to the game: the host and player objects (Host,
-- Client) send through the base's sync transport as plugin messages (hidden addon whispers, with the open-table
-- ad on the base's channel), the clock is the game's, and a message to oneself (the host's own seat) or to one of
-- the host's computer players (Bots) goes straight to that object. Also the list of open tables heard on the
-- channel, and whether the game is refusing table messages right now (its addon message lockdown in a boss fight
-- or a PvP match), which stops the table's clocks until it lifts.
local _, Poker = ...
local Net = Poker:NewModule("PokerNet")
local Wanted = Poker.Wanted
local Host, Client, Bots, Protocol = Poker.PokerHost, Poker.PokerClient, Poker.PokerBots, Poker.PokerProtocol
local private = {
	host = nil, -- the table this character hosts
	player = nil, -- this character's seat at a table (its own or another's)
	bots = {}, -- name -> computer player at the table this character hosts
	tables = {}, -- id -> ad heard on the channel, with .heard
	listeners = {},
	refusedAt = nil, -- GetTime() when the game last refused a table message
	probeAt = nil, -- GetTime() a probe whisper to ourselves went out
}

local function Now()
	return GetTime()
end

function Net:OnEnable()
	local Sync = Wanted.Sync
	Sync:RegisterPlugin(Protocol.TAG, function(tbl, sender)
		private.OnMessage(tbl, sender)
	end)
	Sync:RegisterPlugin(Protocol.AD_TAG, function(tbl, sender)
		private.OnAd(tbl, sender)
	end)
	private.ticker = C_Timer.NewTicker(1, function()
		if private.host then private.host:Tick() end
		if private.player then private.player:Tick() end
		for _, bot in pairs(private.bots) do bot:Tick() end
		private.ForgetStaleAds()
		private.CheckBlocked()
	end)
end

---This character's name as the game gives it to others.
function Net:Me()
	return Wanted.Store:GetOrigin()
end

---Whether the game is refusing table messages right now: one was refused within the last while, and nothing has
---gone through since. The table's clocks stop while it is.
---@return boolean
function Net:Blocked()
	return private.refusedAt ~= nil and Now() - private.refusedAt < Protocol.BLOCKED_SECONDS
end

-- Says when the game starts or stops refusing our messages
function private.CheckBlocked()
	local blocked = Net:Blocked()
	if blocked ~= (private.saidBlocked or false) then
		private.saidBlocked = blocked
		private.Notify("blocked", blocked)
	end
end

-- Sends a table message: to oneself or to a bot without the network. Returns false when the game refused it.
local function Send(target, tbl)
	if target == Net:Me() then
		if private.player and Protocol.TO_PLAYER[tbl.k] then
			private.player:Receive(target, tbl)
		elseif private.host and Protocol.TO_HOST[tbl.k] then
			private.host:Receive(target, tbl)
		end
		return true
	end
	if private.bots[target] then
		private.bots[target]:Receive(Net:Me(), tbl)
		return true
	end
	local ok, why = Wanted.Sync:SendPlugin(Protocol.TAG, tbl, target)
	if ok then
		private.refusedAt = nil
	elseif why == "lockdown" then
		private.refusedAt = Now()
	end
	private.CheckBlocked()
	return ok
end

local function Advertise(ad)
	Wanted.Sync:BroadcastPlugin(Protocol.AD_TAG, ad)
end

function private.OnMessage(tbl, sender)
	if type(tbl) ~= "table" then
		return
	end
	if tbl.k == "probe" then
		if sender == Net:Me() and private.probeAt then
			Wanted:Print("Poker: the table whisper came back in %.1fs. Tables work here.", Now() - private.probeAt)
			private.probeAt = nil
		end
		return
	end
	if private.host and Protocol.TO_HOST[tbl.k] then
		private.host:Receive(sender, tbl)
	end
	if private.player and Protocol.TO_PLAYER[tbl.k] then
		private.player:Receive(sender, tbl)
	end
end

function private.OnAd(ad, sender)
	if type(ad) ~= "table" or type(ad.id) ~= "string" or #ad.id > 100 or Protocol:HostOf(ad.id) ~= sender or not Protocol:IsName(ad.h) or ad.h ~= sender then
		return
	end
	if ad.c then
		private.tables[ad.id] = nil
	else
		ad.heard = Now()
		private.tables[ad.id] = ad
	end
	private.Notify("tables")
end

function private.ForgetStaleAds()
	local now = Now()
	local changed = false
	for id, ad in pairs(private.tables) do
		if now - ad.heard > Protocol.AD_STALE_SECONDS then
			private.tables[id] = nil
			changed = true
		end
	end
	if changed then
		private.Notify("tables")
	end
end

function private.Notify(event, ...)
	for _, f in ipairs(private.listeners) do
		f(event, ...)
	end
end

---Calls func(event, ...) on "tables" (the list of open tables changed), "state" (our table's state), "audit",
---"refused", "hostGone", "newHost", "left", "blocked" (true: the game is refusing table messages; false: no longer).
---@param func function
function Net:On(func)
	tinsert(private.listeners, func)
end

-- What the table this character hosts reports: its settlement lines go to the ledger like a player's
function private.OnHostEvent(event, ...)
	if event == "settle" then
		private.Notify("settle", ...)
	end
	private.Notify("host", event, ...)
end

local function Blocked()
	return Net:Blocked()
end

local function NewPlayer()
	return Client:New({ name = Net:Me(), send = Send, now = Now, blocked = Blocked, on = function(event, ...)
		if event == "takeover" then
			private.TakeOver(...)
		end
		private.Notify(event, ...)
	end })
end

-- Seats the computer players at a practice table: each a client of its own, sending straight to the host
local function SeatBots(host, n)
	local names = {}
	for i, name in ipairs(Bots.NAMES) do names[i] = name end
	local first = math.random(#names)
	local buyin = host.cfg.kind == "tournament" and host.cfg.entry or host.cfg.buyMax
	for i = 1, n do
		local name = names[(first + i - 2) % #names + 1]
		local bot = Bots:New({ name = name, style = Bots.STYLES[(i - 1) % #Bots.STYLES + 1], now = Now, send = function(_, tbl)
			if private.host then private.host:Receive(name, tbl) end
			return true
		end })
		private.bots[name] = bot
		bot:Join(host.name, host.id, buyin)
	end
end

---Opens a table and sits at it. A table with bots (cfg.bots) is a practice table: the other seats are filled by
---computer players and nothing is advertised.
---@param cfg table see Protocol:Settings
---@param buyin number
---@return boolean ok
---@return string? reason
---@param password string? asked of anyone sitting down
function Net:HostTable(cfg, buyin, password)
	if private.player and not private.player.left then
		return false, "you're at a table already"
	end
	local practice = type(cfg) == "table" and (cfg.bots or 0) > 0
	local host, reason = Host:New({ name = Net:Me(), cfg = cfg, send = Send, ad = not practice and Advertise or nil, now = Now, on = private.OnHostEvent,
		blocked = Blocked, password = not practice and password or nil })
	if not host then
		return false, reason
	end
	private.host = host
	private.player = NewPlayer()
	private.player:Join(host.name, host.id, buyin, not practice and password or nil)
	if practice then
		SeatBots(host, host.cfg.bots)
	end
	host:Advertise()
	return true
end

---Sits at a table heard on the channel.
---@param id string
---@param buyin number
---@return boolean ok
---@return string? reason
---@param password string? for a locked table
function Net:JoinTable(id, buyin, password)
	if private.player and not private.player.left then
		return false, "you're at a table already"
	end
	local host = Protocol:HostOf(id)
	if not host then
		return false, "no such table"
	end
	private.player = NewPlayer()
	private.player:Join(host, id, buyin, password)
	return true
end

---Starts the tournament this character hosts.
---@return boolean ok
---@return string? reason
function Net:StartTournament()
	if not private.host then
		return false, "you aren't hosting"
	end
	return private.host:Start()
end

---Leaves the table; a host closes it.
function Net:Leave()
	if private.host then
		private.host:Close()
		private.host:Advertise()
		private.host = nil
		private.bots = {}
	end
	if private.player then
		private.player:Leave()
	end
end

-- The host vanished and this seat is next: the table carries on from the backup, under this character
function private.TakeOver(backup)
	local host = Host:Restore(backup, { name = Net:Me(), send = Send, ad = Advertise, now = Now, on = private.OnHostEvent, blocked = Blocked })
	if not host then
		return
	end
	private.host = host
	host:AnnounceTakeover()
end

---Whispers a table message to ourselves and says when it comes back: whether tables work where we stand (the game
---refuses addon whispers in a boss fight and a PvP match, and may elsewhere).
function Net:Probe()
	private.probeAt = Now()
	local ok, why = Wanted.Sync:SendPlugin(Protocol.TAG, { k = "probe" }, Net:Me())
	if not ok then
		private.probeAt = nil
		Wanted:Print("Poker: the game refused the whisper (%s). Tables can't run here right now.", why or "not sent")
		return
	end
	C_Timer.After(5, function()
		if private.probeAt then
			private.probeAt = nil
			Wanted:Print("Poker: the whisper was accepted but nothing came back in 5s. Tables may not work here.")
		end
	end)
end

---This character's view of their table, or nil.
function Net:State()
	return private.player and private.player.state
end

function Net:Player()
	return private.player
end

function Net:HostedTable()
	return private.host
end

---The computer players at the table this character hosts, by name.
function Net:Bots()
	return private.bots
end

---The open tables heard, newest first.
---@return table[]
function Net:Tables()
	local list = {}
	for _, ad in pairs(private.tables) do
		list[#list + 1] = ad
	end
	sort(list, function(a, b) return a.heard > b.heard end)
	return list
end
