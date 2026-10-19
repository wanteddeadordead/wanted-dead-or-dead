-- Wanted: guild war notifications. From the catch-up, as this client sees each war's news the first time: the declare
-- window open (the guild's war officers), drawn or declared on, the time set (the attackers' officers), accepted or
-- withdrawn (the defenders' officers) and the result, each a toast (out of combat; Toast queues them) and a chat
-- line; a war's tab opens on a click. By the clock: an hour before, a toast and a sound for the roster and standby;
-- in the war's zone, prep, the battle's start, the keep opening and the end on the announcement frame (it works in a
-- fight) with a sound. Off in Settings (Guild wars, Guild war notifications). What was told is kept per war
-- (db.warSeen) while the site lists it.

local _, Wanted = ...
local WarAlerts = Wanted:NewModule("WarAlerts")
local GuildWars = Wanted.GuildWars
local private = {}
local GOLD = { r = 1, g = 0.82, b = 0 }
local HOUR, PREP = 3600, 15 * 60

function WarAlerts:OnLoad()
	-- What was told of each war (and race to declare on), by its id
	Wanted.db.warSeen = type(Wanted.db.warSeen) == "table" and Wanted.db.warSeen or {}
end

function WarAlerts:OnEnable()
	GuildWars:OnChange(function() WarAlerts:Check() end)
	C_Timer.NewTicker(5, Wanted:Timed("War alerts", function() WarAlerts:Tick() end))
	WarAlerts:Check()
end

function private.On()
	return Wanted.db.settings.warToasts ~= false
end

---A toast and a chat line, the war's tab on a click.
function private.Tell(index, kind, name, detail)
	if not private.On() then
		return
	end
	Wanted.Toast:Add({ kind = kind, name = name, detail = detail, art = GuildWars.MEDIA.."nexus-keep-sealed-"..(UnitFactionGroup("player") == "Alliance" and "alliance" or "horde"),
		aspect = 1, onClick = function() Wanted.UI:Show("war"..index) end })
	Wanted:Print("Guild war: %s%s", name, detail and (". "..detail) or "")
end

---A line on the announcement frame (the capture fronts', which shows in a fight), else the warning line, and a sound.
function private.Announce(text)
	if not private.On() then
		return
	end
	local frame = WantedCaptureAnnounceFrame
	local shown = frame and frame.AddMessage and RaidWarningUtil and RaidWarningUtil.MessageType
		and pcall(frame.AddMessage, frame, text, GOLD, nil, RaidWarningUtil.MessageType.BGSystem)
	if not shown and Wanted.Alerts then
		Wanted.Alerts:Warn(text, nil, Wanted.Theme.C.gold)
	end
	if Wanted.Alerts and not Wanted.Alerts:IsMuted() and SOUNDKIT and SOUNDKIT.RAID_WARNING then
		PlaySound(SOUNDKIT.RAID_WARNING, "Master")
	end
end

---"Tue 7:00 PM" or "tonight 7:00 PM".
function private.When(t)
	return type(t) == "number" and GuildWars:When(t) or "soon"
end

---The news in the catch-up not told yet.
function WarAlerts:Check()
	local seenBook = Wanted.db.warSeen
	local listed, now = {}, GetServerTime()
	local officer = GuildWars:AmOfficer()
	for index, war in ipairs(GuildWars:Wars()) do
		local key = war.id
		if key then
			listed[key] = true
			local seen = seenBook[key]
			local short = GuildWars:Short(war.zone)
			local ours, theirs = GuildWars:Sides(war)
			if war.step == "declare" then
				local d = war.declare or {}
				if not seen and officer and not d.mine and type(d.closesAt) == "number" and d.closesAt > now then
					private.Tell(index, "DECLARE WAR?", short, format("Your guild may declare on %s until %s.", short, GuildWars:Clock(d.closesAt)))
				end
				seenBook[key] = seen or { told = true }
			else
				local result = type(war.result) == "table" and war.result or {}
				local time = type(war.time) == "table" and war.time or {}
				if not seen and (war.state == "awaiting_time" or war.state == "awaiting_answer") then
					if war.role == "attack" then
						private.Tell(index, "DRAWN", short, format("%s attacks %s; %s picks the time by %s.", ours.guild or "Your guild", short, theirs.guild or "the holders", private.When(time.deadline)))
					else
						private.Tell(index, "WAR DECLARED", short, format("%s attacks %s. %s", theirs.guild or "?", short, officer and format("Pick the time by %s.", private.When(time.deadline)) or "Your officers pick the time."))
					end
				end
				seen = seen or {}
				if type(time.start) == "number" and seen.start ~= time.start and war.role == "attack" and officer and war.state == "awaiting_answer" then
					private.Tell(index, "TIME SET", short, format("%s, set by %s. Accept or withdraw before prep.", private.When(time.start), theirs.guild or "the holders"))
				end
				local answer = time.withdrawn and "withdraw" or time.accepted and "accept" or nil
				if answer and seen.answer ~= answer and war.role == "defend" and officer then
					private.Tell(index, answer == "accept" and "ACCEPTED" or "WITHDRAWN", short, answer == "accept" and format("%s accepted: %s.", theirs.guild or "?", private.When(time.start))
						or format("%s withdrew: no war, you keep %s.", theirs.guild or "?", short))
				end
				if result.won ~= nil and seen.won == nil then
					local took = (war.role == "attack") == (result.won == true)
					private.Tell(index, result.won and "WAR WON" or "WAR LOST", short, format("%s %s %s.%s", (result.won and ours.guild or theirs.guild) or "?", took and "took" or "held", short,
						type(result.protectedUntil) == "number" and (" Protected until "..private.When(result.protectedUntil)..".") or ""))
				end
				seen.state, seen.start, seen.answer, seen.won = war.state, time.start, answer, result.won
				seenBook[key] = seen
			end
		end
	end
	for key in pairs(seenBook) do
		if not listed[key] and GuildWars:On() then
			seenBook[key] = nil
		end
	end
end

---By the clock: the hour's reminder, and in the war's zone prep, the start, the keep opening and the end.
function WarAlerts:Tick()
	local now = GetServerTime()
	for index, war in ipairs(GuildWars:Wars()) do
		local seen = war.id and Wanted.db.warSeen[war.id]
		local b = war.battle or {}
		if seen and type(b.start) == "number" and now >= b.start - HOUR and now < b.start - PREP and not seen.reminded
			and war.step ~= "result" and GuildWars:OnRoster(war) then
			seen.reminded = true
			private.Tell(index, "WAR IN 1 HOUR", GuildWars:Short(war.zone), format("Battle at %s, prep from %s. Go to the rally.", GuildWars:Clock(b.start), GuildWars:Clock(b.start - PREP)))
			if private.On() and SOUNDKIT and SOUNDKIT.READY_CHECK then
				PlaySound(SOUNDKIT.READY_CHECK, "Master")
			end
		end
	end
	-- In the war's zone
	local war = GuildWars:Here(now)
	if war then
		private.inWar = war
		local seen = Wanted.db.warSeen[war.id] or {}
		Wanted.db.warSeen[war.id] = seen
		local b = war.battle
		if now < b.start and not seen.prepTold then
			seen.prepTold = true
			private.Announce(format("Prep: the war on %s starts at %s", GuildWars:Short(war.zone), GuildWars:Clock(b.start)))
		elseif now >= b.start and not seen.startTold then
			seen.prepTold, seen.startTold = true, true
			private.Announce(format("The battle for %s has begun", GuildWars:Short(war.zone)))
		end
		if type(b.keep) == "table" and b.keep.state == "open" and not seen.keepTold then
			seen.keepTold = true
			private.Announce("The keep is open: take it to win")
		end
	elseif private.inWar then
		local last = private.inWar
		private.inWar = nil
		local b = last.battle or {}
		local seen = Wanted.db.warSeen[last.id]
		local _, _, _, mapId = Wanted.Recorder:GetPosition()
		local zone = Wanted.WarZones:Get(last.zone)
		if seen and not seen.overTold and type(b.stop) == "number" and now >= b.stop and zone and zone.mapId == mapId then
			seen.overTold = true
			private.Announce(format("The war for %s is over: the site counts the result", GuildWars:Short(last.zone)))
		end
	end
end
