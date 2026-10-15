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
	private.ticker = C_Timer.NewTicker(1, function() Net:Tick() end)
	-- Back after a reload (or a crash) with a seat remembered: take it again
	C_Timer.After(Protocol.REJOIN_DELAY_SECONDS, function() Net:Rejoin() end)
end

---Runs the table's clocks: called every second.
function Net:Tick()
	if private.host then private.host:Tick() end
	if private.player then private.player:Tick() end
	for _, bot in pairs(private.bots) do bot:Tick() end
	private.ForgetStaleAds()
	private.CheckBlocked()
	-- A rejoin the host never answered
	if private.rejoinAt and private.player and not private.player.left and not private.player.state and Now() - private.rejoinAt >= Protocol.REJOIN_GIVE_UP_SECONDS then
		private.rejoinAt = nil
		private.player.left = true
		private.Forget()
		Wanted:Print("Poker: your table didn't answer; it's gone.")
		private.Notify("left")
	end
end

-- ============================================================================
-- The seat remembered across a reload
-- ============================================================================

-- The host keeps a seat whose client went quiet, so a reload (or a crash) needn't cost it: the table is remembered in
-- the saved data and joined again at login. A table this character hosted lives on under the next seat (chips
-- tables), and is followed there by its ad
function private.Remember(id, host, buyin, password)
	Poker.db.seat = { id = id, host = host, buyin = buyin, password = password, at = time() }
end

function private.Forget()
	Poker.db.seat = nil
	private.rejoinAt = nil
end

---The seat remembered, or nil.
function Net:RememberedSeat()
	return Poker.db.seat
end

---Takes the remembered seat again: a join to its host, or, for a table this character hosted, a wait for the ad of
---whoever carries it on.
function Net:Rejoin()
	local seat = Poker.db.seat
	if type(seat) ~= "table" or type(seat.id) ~= "string" or (private.player and not private.player.left) then
		return false
	end
	if time() - (seat.at or 0) > Protocol.REJOIN_WINDOW_SECONDS then
		private.Forget()
		return false
	end
	if seat.host == Net:Me() then
		Wanted:Print("Poker: you were hosting %s; if the next seat carried it on, you'll be sat back down when it's heard.", seat.id)
		return false
	end
	Wanted:Print("Poker: taking your seat at %s's table again...", seat.host)
	private.rejoinAt = Now()
	return Net:JoinTable(seat.id, seat.buyin, seat.password, seat.host)
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
	if tbl.k == Protocol.LINES then
		return private.OnLines(tbl, sender)
	end
	if private.host and Protocol.TO_HOST[tbl.k] then
		private.host:Receive(sender, tbl)
	end
	if private.player and Protocol.TO_PLAYER[tbl.k] then
		private.player:Receive(sender, tbl)
	end
end

-- Settlement lines between two players, about no table in particular: a question (no lines) is answered with the
-- open lines this character owes the asker; an answer is taken only for lines the sender owes this character
function private.OnLines(tbl, sender)
	local Gold = Poker.PokerGold
	if type(tbl.l) ~= "table" then
		local owed = Gold and Gold:DebtsTo(sender) or {}
		if #owed > 0 then
			local lines = {}
			for i, l in ipairs(owed) do
				lines[i] = { id = l.id, table = l.table, title = l.title, at = l.at, from = l.from, to = l.to, amount = l.amount, kind = l.kind }
			end
			Wanted.Sync:SendPlugin(Protocol.TAG, { k = Protocol.LINES, l = lines }, sender)
		end
		return
	end
	local me = Net:Me()
	for _, l in ipairs(tbl.l) do
		if type(l) == "table" and type(l.id) == "string" and #l.id <= 120 and l.from == sender and l.to == me and Protocol:IsCount(l.amount, 1) and type(l.table) == "string" then
			private.Notify("settle", { id = l.id, table = l.table, title = type(l.title) == "string" and l.title or nil, host = sender, at = tonumber(l.at) or time(),
				from = l.from, to = l.to, amount = l.amount, kind = type(l.kind) == "string" and l.kind or nil })
		end
	end
end

---Asks a player for the open lines they owe this character.
---@param name string
function Net:AskLines(name)
	Wanted.Sync:SendPlugin(Protocol.TAG, { k = Protocol.LINES }, name)
end

function private.OnAd(ad, sender)
	-- The ad is its sender's: the id names the host who opened the table, not always the one carrying it on
	if type(ad) ~= "table" or type(ad.id) ~= "string" or #ad.id > 100 or not Protocol:HostOf(ad.id) or not Protocol:IsName(ad.h) or ad.h ~= sender then
		return
	end
	if ad.c then
		private.tables[ad.id] = nil
	else
		ad.heard = Now()
		private.tables[ad.id] = ad
		-- Our remembered table, advertised by whoever hosts it now: sit back down
		local seat = Poker.db.seat
		if type(seat) == "table" and seat.id == ad.id and sender ~= Net:Me() and (not private.player or private.player.left or (not private.player.state and private.player.host ~= sender)) then
			Wanted:Print("Poker: %s carries your table on; taking your seat again.", sender)
			if private.player then private.player.left = true end
			private.rejoinAt = Now()
			Net:JoinTable(ad.id, seat.buyin, seat.password, sender)
		end
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
	elseif event == "closed" and private.host then
		-- Closed, now or after the hand the host waited for: the last ad says so, and this seat leaves with the rest
		private.host:Advertise()
		private.host = nil
		private.bots = {}
		if private.player then private.player:Leave() end
	end
	private.Notify("host", event, ...)
end

local function Blocked()
	return Net:Blocked()
end

local function NewPlayer()
	return Client:New({ name = Net:Me(), class = UnitClass and select(2, UnitClass("player")) or nil, send = Send, now = Now, blocked = Blocked, on = function(event, ...)
		if event == "left" or event == "refused" or event == "hostLost" then
			private.Forget()
		elseif event == "state" then
			private.rejoinAt = nil
			local st = ...
			if st and st.phase == "closed" then private.Forget() end
		end
		if event == "takeover" then
			private.TakeOver(...)
		elseif event == "handoff" then
			private.OnHandoff(...)
		elseif event == "newHost" then
			-- Our own table, handed on: the successor has it now
			local name = ...
			if private.host and private.host.handingTo == name and private.host:Handed() then
				private.host = nil
				private.bots = {}
			end
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
		private.Forget()
	else
		private.Remember(host.id, host.name, buyin, password)
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
---@param hostName string? who hosts it now, when not the host its id names (a table carried on by the next seat)
function Net:JoinTable(id, buyin, password, hostName)
	if private.player and not private.player.left then
		return false, "you're at a table already"
	end
	local host = hostName or Protocol:HostOf(id)
	if not host then
		return false, "no such table"
	end
	private.player = NewPlayer()
	private.player:Join(host, id, buyin, password)
	private.Remember(id, host, buyin, password)
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
---Leaves the table; a host closes it. A hand under way at the host's table plays out first ("closing" comes back),
---and the table closes itself after it (OnHostEvent "closed").
function Net:Leave()
	if private.host then
		private.host:CloseAfterHand()
		return private.host and "closing" or nil
	end
	if private.player then
		private.player:Leave()
	end
end

---The host thinks again: the table stays open after the hand.
function Net:KeepOpen()
	if private.host then private.host:KeepOpen() end
end

-- The host vanished and this seat is next: the table carries on from the backup, under this character. Not a gold
-- table: the host holds the money, so nobody else can carry it on (the client claims its stack instead)
function private.TakeOver(backup, handed)
	if type(backup) == "table" and type(backup.cfg) == "table" and backup.cfg.stakes == "gold" and not handed then
		return false
	end
	if private.host then
		return false
	end
	local host = Host:Restore(backup, { name = Net:Me(), send = Send, ad = Advertise, now = Now, on = private.OnHostEvent, blocked = Blocked })
	if not host then
		return false
	end
	private.host = host
	host:AnnounceTakeover()
	return true
end

-- The host hands this character the table (chips tables only: a gold table's host holds the money and keeps it)
function private.OnHandoff(backup)
	if type(backup) == "table" and type(backup.cfg) == "table" and backup.cfg.stakes == "gold" then
		return
	end
	if private.TakeOver(backup, true) then
		Wanted:Print("Poker: you host the table now.")
		private.Notify("hosting")
	end
end

---Hands the table this character hosts to the next seat (chips tables only).
---@return boolean ok
---@return string? reason
function Net:Handoff()
	if not private.host then
		return false, "you aren't hosting"
	end
	if private.host.cfg.bots > 0 then
		return false, "a practice table is yours alone"
	end
	return private.host:Handoff()
end

---The host lets a seat in by hand, with the money they say they received.
---@param name string
---@param amount number
---@return boolean ok
---@return string? reason
function Net:Admit(name, amount)
	if not private.host then
		return false, "you aren't hosting"
	end
	return private.host:Admit(name, amount)
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
