-- Wanted: catch-up from the desktop app. The app reads this account's saved data, asks the server for what it
-- lacks (this side's records past the chains held, and the other side's bounties on this side as notices) and
-- writes them into the !!WantedLink addon (WantedAppCatchup, keyed by account mark). At login they're taken in
-- in the background, as gap fills are, so the channel only has to carry what happens while playing.
-- The catch-up also carries bounties the player asked for on wanteddeadordead.com's Discord bot: each is asked
-- once, on the character it was asked for, and posted the normal way if they agree; the app reads the answers.

local _, Wanted = ...
local Catchup = Wanted:NewModule("Catchup")
local Store = Wanted.Store
local Sync = Wanted.Sync
local Bridge = Wanted.Bridge
local private = {}
-- Records taken in per piece of background work
local BATCH = 50
-- Bounty requests: the most kept, the most a request may be (the website's limit), how long answers are kept for
-- the app, and how soon after login the first is asked
local MAX_REQUESTS = 20
local MAX_REQUEST_AMOUNT = 100000 * 10000
local ANSWER_KEEP_SECONDS = 7 * 24 * 60 * 60
local ASK_DELAY = 10

function Catchup:OnEnable()
	-- The app sends the server this account's side, so it only gets this side's records back
	local faction = UnitFactionGroup("player")
	if faction == "Horde" or faction == "Alliance" then
		Wanted.db.faction = faction
	end
	Catchup:Import()
	-- Requests are asked out of a fight and out of instances: again when either ends
	Wanted:OnCombatEnd(function() private.AskSoon(1) end)
	private.frame = private.frame or CreateFrame("Frame")
	private.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	private.frame:SetScript("OnEvent", function() private.AskSoon(ASK_DELAY) end)
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

-- The most GUIDs looked up at once
local MAX_UNNAMED = 300

---The players the app's combat log named by first name only: the game's cache often knows them in full (and
---their class and sex) for a while after they were near, so each is asked and the answers go in the name book,
---which the app sends to wanteddeadordead.com.
---@param unnamed table? a list of GUIDs
function private.LookUpUnnamed(unnamed)
	if type(unnamed) ~= "table" then
		return
	end
	local asked, named = 0, 0
	for i = 1, min(#unnamed, MAX_UNNAMED) do
		local guid = unnamed[i]
		if type(guid) == "string" and strfind(guid, "^Player%-%d+%-%w+$") then
			asked = asked + 1
			local _, classFile, _, _, sexNumber, name = GetPlayerInfoByGUID(guid)
			if type(name) == "string" and not (issecretvalue and issecretvalue(name)) and strfind(name, "%S %S") then
				Store:NoteName(guid, name, classFile, sexNumber == 2 and "male" or sexNumber == 3 and "female" or nil)
				named = named + 1
			end
		end
	end
	if asked > 0 then
		Wanted:Log("Catch-up: %d of %d players the combat log named by first name only are known to the game", named, asked)
	end
end

---Takes in this account's catch-up, if the app has written one newer than the last taken in.
function Catchup:Import()
	local all = WantedAppCatchup
	-- It can be large, and it's read once: let it go (a /reload loads the file again)
	WantedAppCatchup = nil
	local entry = type(all) == "table" and all[Wanted.db.accountMark]
	if type(entry) ~= "table" or type(entry.t) ~= "number" then
		Wanted.Challenges:Take(nil, true)
		return
	end
	-- Asked at every login and /reload, even of a catch-up already taken in: the game may know them by now
	private.LookUpUnnamed(entry.unnamed)
	-- The sync channel wanteddeadordead.com says everyone moved to, after the old one was taken over
	if type(entry.channel) == "table" then
		Sync:AdoptFromApp(entry.channel)
	end
	-- Bounty requests are kept by id, so taking in the same ones again changes nothing
	private.TakeRequests(entry.requests)
	-- Challenges, hot zones and ranks are only shown, so they're read at every login, taken in or not
	Wanted.Challenges:Take(entry.challenges)
	-- Blizzard PvP ranks other Wanted players shared, from the site (app with addon 1.10.0)
	if Wanted.BlizzRank then
		Wanted.BlizzRank:Take(entry.blizzRanks)
	end
	-- World PvP achievements and what each is, from the site (app 0.2.33)
	Wanted.Achievements:Take(entry.achievementDefs, entry.achievements)
	-- Players on other realm names to greet as realm links, also at every login
	Sync:TakeDirectory(entry.links)
	-- The guilds' Kill on Sight lists as the server keeps them: newer changes only, so taking them again is harmless
	if Wanted.GuildKoS then
		Wanted.GuildKoS:TakeServer(entry.guildKos)
	end
	if entry.t <= (Wanted.db.catchupT or 0) then
		Wanted:Log("Catch-up: already taken in")
		return
	end
	local records = type(entry.records) == "table" and entry.records or {}
	local notices = type(entry.notices) == "table" and entry.notices or {}
	local counts = { new = 0, held = 0, skipped = 0, pruned = 0 }
	for first = 1, #records, BATCH do
		Wanted:QueueWork(function()
			Sync:WithoutForwarding(function()
				for i = first, min(first + BATCH - 1, #records) do
					local record = records[i]
					if not private.IsWellFormed(record) then
						counts.skipped = counts.skipped + 1
					else
						local isNew, why = Store:MergeRelayed(record, true)
						if isNew then
							counts.new = counts.new + 1
						elseif why == "pruned" then
							-- Too old to keep: its chain moved on, so the app doesn't send it again
							counts.pruned = counts.pruned + 1
						else
							counts.held = counts.held + 1
						end
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
		Wanted:Log("Catch-up: %d records new, %d already held, %d too old to keep, %d malformed; %d bounty notices", counts.new,
			counts.held, counts.pruned, counts.skipped, #notices)
	end)
end



-- ============================================================================
-- Bounty requests from Discord
-- ============================================================================

---A request as the app writes it, checked field by field; the cleaned copy to keep, or nil.
function private.CleanRequest(r, now)
	if type(r) ~= "table" or type(r.id) ~= "string" or #r.id > 64 or not strfind(r.id, "^[%w%-]+$")
		or type(r.character) ~= "string" or not strfind(r.character, "^Player%-%d+%-%w+$")
		or type(r.amount) ~= "number" or r.amount ~= floor(r.amount) or r.amount < Wanted.Bounties.MIN_BOUNTY or r.amount > MAX_REQUEST_AMOUNT
		or type(r.t) ~= "number" or type(r.expires) ~= "number" or r.expires <= now then
		return nil
	end
	local name = Store:CleanName(r.targetName)
	local out = { id = r.id, character = r.character, name = name, amount = r.amount, t = r.t, expires = r.expires }
	if r.guild ~= nil then
		out.guild = Store:CleanName(r.guild)
		if not out.guild or r.target ~= nil then
			return nil
		end
		out.name = "<"..out.guild..">"
	elseif type(r.target) ~= "string" or not strfind(r.target, "^Player%-%d+%-%w+$") or not name then
		return nil
	else
		out.target = r.target
	end
	return out
end

---Keeps the requests the app handed on, and lets old answers and expired requests go.
function private.TakeRequests(list)
	local db = Wanted.db
	local now = GetServerTime()
	for id, answer in pairs(db.requestAnswers) do
		if type(answer) ~= "table" or (answer.t or 0) < now - ANSWER_KEEP_SECONDS then
			db.requestAnswers[id] = nil
		end
	end
	for id, r in pairs(db.bountyRequests) do
		if type(r) ~= "table" or r.expires <= now or db.requestAnswers[id] then
			db.bountyRequests[id] = nil
		end
	end
	if type(list) ~= "table" then
		return
	end
	local kept, dropped = 0, 0
	for i = 1, min(#list, MAX_REQUESTS) do
		local r = private.CleanRequest(list[i], now)
		if not r then
			dropped = dropped + 1
		elseif not db.bountyRequests[r.id] and not db.requestAnswers[r.id] then
			db.bountyRequests[r.id] = r
			kept = kept + 1
		end
	end
	if kept + dropped > 0 then
		Wanted:Log("Catch-up: %d bounty requests from Discord kept, %d malformed or expired", kept, dropped)
	end
	private.AskSoon(ASK_DELAY)
end

---Asks about the next request after delay seconds, once.
function private.AskSoon(delay)
	if private.askPending then
		return
	end
	private.askPending = true
	C_Timer.After(delay, function()
		private.askPending = false
		private.AskNext()
	end)
end

---The oldest request waiting for this character, not yet answered or expired.
function private.NextRequest()
	local me, now = UnitGUID("player"), GetServerTime()
	local oldest = nil
	for id, r in pairs(Wanted.db.bountyRequests) do
		if r.character == me and r.expires > now and not Wanted.db.requestAnswers[id] and (not oldest or r.t < oldest.t or (r.t == oldest.t and id < oldest.id)) then
			oldest = r
		end
	end
	return oldest
end

---Asks about the next request for this character: never in a fight, an instance, over another dialog, or while
---an update is required (bounties are paused then; the request waits).
function private.AskNext()
	local W = Wanted.Widgets
	local r = private.NextRequest()
	if not r or Wanted:InCombat() or InCombatLockdown() or IsInInstance() or Wanted:GetRequiredUpdate() then
		return
	end
	if W:IsDialogShown() then
		private.AskSoon(ASK_DELAY)
		return
	end
	W:Dialog({
		title = "Wanted: bounty from Discord",
		text = format("You asked from Discord to post %s on %s.", Wanted.Bounties:FormatMoney(r.amount), r.name),
		confirmLabel = "Post it",
		cancelLabel = "Discard",
		onConfirm = function() private.Answer(r, true) end,
		onCancel = function() private.Answer(r, false) end,
	})
end

---Posts or discards a request, keeps the answer for the app, and asks about the next.
function private.Answer(r, post)
	local db = Wanted.db
	if db.requestAnswers[r.id] or not db.bountyRequests[r.id] then
		return
	end
	local answer = { state = "discarded", t = GetServerTime() }
	if post then
		local bounty, err
		if r.guild then
			bounty, err = Wanted.Bounties:PostGuild(r.guild, nil, r.amount)
		else
			bounty, err = Wanted.Bounties:Post(r.target, r.name, r.amount)
		end
		if bounty then
			answer.state = "posted"
			Wanted:Print("Bounty posted: %s on %s, expires in 7 days.", Wanted.Bounties:FormatMoney(r.amount), r.name)
		else
			answer.state, answer.reason = "refused", err
			Wanted:Print("Cannot post: %s.", tostring(err))
		end
	end
	db.requestAnswers[r.id] = answer
	db.bountyRequests[r.id] = nil
	Wanted:Log("Bounty request %s: %s", r.id, answer.state)
	private.AskSoon(1)
end
