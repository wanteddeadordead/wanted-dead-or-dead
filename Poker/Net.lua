-- Wanted: Dead Man's Hand Poker. Ties this character's table to the game: the host and player objects (Host,
-- Client) send through the base's sync transport as plugin messages (hidden addon whispers, with the open-table
-- ad on the base's channel), the clock is the game's, and a message to oneself (the host's own seat) goes
-- straight to the local player object. Also the list of open tables heard on the channel.
local _, Poker = ...
local Net = Poker:NewModule("PokerNet")
local Wanted = Poker.Wanted
local Host, Client, Protocol = Poker.PokerHost, Poker.PokerClient, Poker.PokerProtocol
local private = {
	host = nil, -- the table this character hosts
	player = nil, -- this character's seat at a table (its own or another's)
	tables = {}, -- id -> ad heard on the channel, with .heard
	listeners = {},
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
		private.ForgetStaleAds()
	end)
end

---This character's name as the game gives it to others.
function Net:Me()
	return Wanted.Store:GetOrigin()
end

-- Sends a table message: to oneself without the network
local function Send(target, tbl)
	if target == Net:Me() then
		if private.player and Protocol.TO_PLAYER[tbl.k] then
			private.player:Receive(target, tbl)
		elseif private.host and Protocol.TO_HOST[tbl.k] then
			private.host:Receive(target, tbl)
		end
		return
	end
	Wanted.Sync:SendPlugin(Protocol.TAG, tbl, target)
end

local function Advertise(ad)
	Wanted.Sync:BroadcastPlugin(Protocol.AD_TAG, ad)
end

function private.OnMessage(tbl, sender)
	if type(tbl) ~= "table" then
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
---"refused", "hostGone", "newHost", "left".
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

local function NewPlayer()
	return Client:New({ name = Net:Me(), send = Send, now = Now, on = function(event, ...)
		if event == "takeover" then
			private.TakeOver(...)
		end
		private.Notify(event, ...)
	end })
end

---Opens a table and sits at it.
---@param cfg table see Protocol:Settings
---@param buyin number
---@return boolean ok
---@return string? reason
function Net:HostTable(cfg, buyin)
	if private.player and not private.player.left then
		return false, "you're at a table already"
	end
	local host, reason = Host:New({ name = Net:Me(), cfg = cfg, send = Send, ad = Advertise, now = Now, on = private.OnHostEvent })
	if not host then
		return false, reason
	end
	private.host = host
	private.player = NewPlayer()
	private.player:Join(host.name, host.id, buyin)
	host:Advertise()
	return true
end

---Sits at a table heard on the channel.
---@param id string
---@param buyin number
---@return boolean ok
---@return string? reason
function Net:JoinTable(id, buyin)
	if private.player and not private.player.left then
		return false, "you're at a table already"
	end
	local host = Protocol:HostOf(id)
	if not host then
		return false, "no such table"
	end
	private.player = NewPlayer()
	private.player:Join(host, id, buyin)
	return true
end

---Leaves the table; a host closes it.
function Net:Leave()
	if private.host then
		private.host:Close()
		private.host:Advertise()
		private.host = nil
	end
	if private.player then
		private.player:Leave()
	end
end

-- The host vanished and this seat is next: the table carries on from the backup, under this character
function private.TakeOver(backup)
	local host = Host:Restore(backup, { name = Net:Me(), send = Send, ad = Advertise, now = Now, on = private.OnHostEvent })
	if not host then
		return
	end
	private.host = host
	host:AnnounceTakeover()
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
