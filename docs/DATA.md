# Saved data and versions

Wanted keeps two kinds of data: what each player's client saves (`WantedDB`), and the records clients share
over the channel. Both have to keep working across versions.

## Saved data (`WantedDB`)

- `WantedDB.version` is the layout number. `Wanted.DB_VERSION` in `Core.lua` is the layout this release writes.
- Saved data is never wiped for being old. `Wanted:LoadSavedData()` runs each upgrade step in `MIGRATIONS`
  (in `Core.lua`) from the saved layout up to the current one, in place.
- Data saved by a newer version (someone went back to an older release) is left exactly as it is: that
  session runs on a scratch table and saves nothing, and the player is told to update.
- A table from before layouts were numbered counts as layout 1.

Rules for a change:

1. **Adding** a setting or field: give it a default in `DEFAULTS` (or an `x = x or {}` in the module's
   `OnLoad`). No layout change needed.
2. **Renaming, moving, removing or changing the meaning** of saved data: bump `DB_VERSION`, add
   `MIGRATIONS[n] = function(db) ... end` that turns layout n-1 into n without losing anything it can keep,
   and add a smoke test that loads a table in the old layout and checks the result.
3. Never delete the player's records, Kill on Sight, Ignore or settings in a migration. The one exception is
   the move from the beta to the live game, below.

`assist` records (from 1.1.0): honorable-kill credit without the killing blow. WoW Forever raises the HK count
("You have been awarded N Honor.") without naming the victim, so the addon ties each new HK that isn't its own
kill to the newest enemy death it recorded in the last few seconds that has no assist yet. Same fields as a
`kill` record: `killer*` is the assisting player (with `killerGroup`), `victim*` and `deathId` come from that
death record. No death seen, no record.

`WantedDB.accountMark` (from 1.1.0) is a random id made once per WoW account's saved data and kept forever
(the launch reset keeps it too). The desktop app reads it from the saved file and writes the account's link
code under it in the `!!WantedLink` addon (`WantedAppLinks[mark] = code`). At login `Store:AutoLink` makes a
`link` record with that code for the character if it hasn't already, so characters link themselves.
The same file also holds `WantedAppInfo = { running, latest }` (from 1.1.3): the app's version and the newest
one out. When the app is behind, the addon says so in chat once a login.

`WantedDB.realm` (from 1.6.0) is `{ id, name }`: the realm the account last logged in on, `GetRealmID()` and
`GetRealmName()`, written at every login. The Wanted app sends it to wanteddeadordead.com, which learns realm names
from it. Nothing reads it back; a missing or malformed one changes nothing.

`WantedDB.raids` (from 1.18.1) is `{ [character] = { mine, joined, seen } }`, by `Name-Realm`: the world PvP raid the
character leads (`{ id, title, guild, exclusive, where, startAt, size, minLevel, created, signups = { [name] = "going" or
"interested" } }`), the raids it marked (`joined[id] = { leader, startAt, title, kind, asked, details }`) and other
players' raids it has heard of (`seen[id] = { raid, heard }`, server times). `Raids:Load()` drops anything past at
login: a led raid two hours after its start, a marked one ten minutes after, a heard one three minutes after its start
or its last ad, whichever is later. A malformed entry is dropped.

`WantedDB.viewed` (from 1.18.2) is `{ [character] = { [kind] = { [id] = true } } }`: what each page last showed the
character, for the menu's counts of new things (`UI:NewCount`, `UI:MarkViewed`). Kinds: `board` (bounty ids),
`hotspots` (zone keys), `badges` (achievement keys, medal keys with their count) and `card` (calling-card piece ids).
A kind's first count takes in everything there, so nothing old shows as new. Raids keep their own in
`WantedDB.raids[character].viewed`.

`WantedDB.pvpSeason` (from 1.9.0) is `{ season, week, endsAt, weekMax, seasonMax, at }`: Blizzard's PvP season as the
game tells it (`GetCurrentArenaSeason()`, the PvP rank track's `weekNumber`, `currentWeekProgressiveMaxLevel` and
`maxLevel`), `endsAt` the game-server time it ends (0 when the game doesn't know yet) and `at` when it was read.
Read 15 seconds after login and each hour. Season 0 or week -1 means no season is running. The Wanted app sends it
to wanteddeadordead.com, whose seasons follow the game's. Nothing reads it back.

`WantedDB.pvpGear` (from 1.10.0) is the rank vendors' PvP gear, per faction: `pvpGear[faction][itemID] = { name,
quality, icon, slot, class, subclass, level, rank, classes, honor, marks = { [markItemID] = count }, price, vendor,
seen }`. Kept when a rank vendor opens (every item that costs Honor Points or needs a rank; all classes, read with the
vendor's filter on All, then put back). `rank` is from the tooltip's "(Rank N)", `classes` from its "Classes:" line
(the game's names), `class`/`subclass` the game's item class numbers. An item no vendor has shown in 60 days is
dropped. Nothing is shared.

`WantedDB.gearGoals` (from 1.10.0) is each character's chased items: `gearGoals[characterGUID][itemID] = true`.

`WantedDB.blizzRanks` (from 1.10.0) is Blizzard PvP ranks as Wanted players' hellos told them, and this character's
own: `blizzRanks["Name"] = { r, s, t }` (rank 1-14, the season, when heard). The hello carries `b` (rank) and `bs`
(season) once a player has a rank in a running season. Shown only for the season the game says is running; an entry
not heard in 30 days is dropped, and at most 5,000 are kept. The Wanted app sends them to wanteddeadordead.com.

`WantedDB.hkBook` (from 1.10.0) is players' lifetime honorable kills, read from the game (the achievement comparison's
"Total Honorable Kills" statistic) when a Wanted player targets or mouses over them: `hkBook[guid] = { n, f, hk, t }`
(name, "H"/"A", the count, when read). Each player again only after six hours; out of combat and instances; never
while the achievement window is open; settings.honorScout turns it off. Readings older than 30 days are dropped, and
at most 5,000 kept. The Wanted app sends them to wanteddeadordead.com.

`WantedDB.myPvp` (from 1.10.0) is each of the account's characters' own PvP numbers: `myPvp[guid] = { n, f, rank,
points, honor, hk, season, t }` (Blizzard rank, the season's rank points, Honor Points, lifetime honorable kills, the
season). Written at login and when the rank, honor or bags change. The Wanted app sends them for the Blizzard PvP
boards; the site takes them only for the account's own characters.

`WantedDB.guildKos` (from 1.7.0) is the guilds' own Kill on Sight lists, keyed `faction..":"..lower(guild)`:
`{ guild, settings = { enabled, mode = "review"|"rank"|"open", rank, discord, t, by }, entries = { [id] = entry } }`.
An entry's id is `"p:"..lower(guid)` for a player or `"g:"..lower(guild name)` for a whole guild; an entry is
`{ kind = "player"|"guild", guid?, name, reason?, state = "pending"|"approved"|"denied"|"removed", by, at, dby?,
eby, t }` (by: who added it; dby: who approved or denied it; eby: who made its last change; t: when). Denied and
removed entries are dropped 30 days after their last change. A missing or malformed table starts empty. A book's
optional `heard` (added after 1.18.2) is the time of the newest change taken from an officer (or the server, or made here as
an officer): logging in asks guildmates for what's newer than it. No migration: a book without it asks for everything
once.

`WantedDB.faction` (from 1.2.7) is the account's side ("Horde" or "Alliance"), saved at login for the desktop app.
`WantedDB.catchupT` (from 1.2.7) is the server time of the last catch-up taken in. The app sends the server the
account's chains and side, and writes the answer into `!!WantedLink/Catchup.lua` as
`WantedAppCatchup[mark] = { t, records = { ... }, notices = { ... } }`: this side's records past the chains held,
and the other side's bounties on this side in the Bridge's notice form. At login `Catchup:Import` takes in an
entry newer than `catchupT` in the background (as gap fills, never live, not forwarded to realm links), then the
notices through the Bridge. No layout change: both fields are new and optional.

Pruning (from 1.2.9): at login, `Store:Prune` drops `kill`, `death` and `assist` records older than
`Store.KEEP_SECONDS`: 30 days until 1.2.20, 3 days from 1.2.21. Every other kind is kept. So are, whatever their age
(from 1.2.21): records naming one of the account's characters as `victim` or `killer` (the assister, for an
`assist`), and kills and assists one of them recorded; a death they only witnessed is pruned like anyone's; a kill some
`claim` names in `data.kill`; a death of a claim's victim within the witness window of its `killT`; and, while the
desktop app hasn't read the latest save (`catchupT` older than `savedAt`), everything since its last catch-up, for
up to 30 days. It runs again every 24 hours of a session. A chain says how far this client has taken an origin's
records, pruned or not, so a pruned record is never asked for again, and one a peer sends again (answering someone
else's gap on the channel) is not taken back in. A pruned record held past a gap in its chain moves the chain past
it (from 1.2.21): what the gap holds is older still. A record arriving already too old to keep (the app's catch-up or
a fill of old records) that is next in its chain moves the chain on and isn't stored (from 1.2.21), so it isn't
imported only to be pruned at the next login, and the app doesn't send it again. Chains also keep `first` (from
1.2.21), the time of the origin's first record (seq 1), since that record may be pruned: a claim's witness counts as
new to the network when their first record came less than a day before the kill. An optional new field: no migration. The website keeps the full archive (the app
uploads records as they appear; one pruned before the app ever ran is lost to it). A fill (`F`) answering a request
for records the sender pruned carries `p = { [origin] = firstSeqHeld }`; the receiver's chain for that origin moves
on to `firstSeqHeld - 1` (`Store:SkipTo`), continuing from that record's `prev`, or from an unknown predecessor
(`lastHash = "?"`, which the chain check accepts once), so it stops asking for records nobody holds. From 1.2.21 a
fill also carries `g = { [origin] = { held1, next1, held2, next2, ... } }`, one pair per hole pruning left in the
chain past the first record (the seq held before it and the one after it, or the sender's chain end + 1 for a pruned
end); a receiver whose chain has reached `held` moves on to `next - 1` the same way. Older clients ignore `g` and keep
asking for interior holes, as before. After 1.18.2 a skip from `p` or `g` goes no further than one past the highest seq
any player's hello or have said the origin reaches, this client holds, or the fill carries (the origin may skip its own
chain as it likes), and odd numbers are ignored. A chain moved by a skip keeps `skip = { from, hash }`, where it stood
before: a recent record (younger than the 3 days records are kept) arriving inside the skipped range, heard from its
origin or brought by the app, shows the skip was false, and the chain goes back there and on from that record. The
origin's own record carrying the chain on past the skip clears `skip`. An optional new field: no migration.

`WantedDB.characters` (from 1.2.21) is `guid -> { n = origin, t }`: this WoW account's characters, noted at each
login and from every `link` record carrying the account's app link code (`WantedAppLinks[mark]`). Pruning keeps the
kills, deaths and assists that name them. `WantedDB.savedAt` (from 1.2.21) is the server time of the last logout or `/reload`,
when the game wrote the saved file. Both are new keys with defaults: no migration. The launch reset drops them.

At the same pass, `players` entries not seen for 30 days are dropped, then the least recently seen past 5000,
except bounty targets, Kill on Sight, Ignore, players with a history in `tracks`, enemies fought (wins or losses in
`enemyStats`) and the account's characters. At load, `enemyStats` entries with no wins or losses (only seen), not on
Kill on Sight and not seen for 30 days are dropped, then the least recently seen past 5000 (from 1.2.21).

`WantedDB.recentPeers` (from 1.2.10) is `name -> seen` for the last 20 players heard on the sync channel. A client
locked out of the channel (banned, a password set, or no answer after 12 join attempts) whispers them a hello
with `x = 1`, and a peer accepts a same-realm whispered hello only when it carries `x`; sync then runs over
whisper links until the channel can be joined again (tried every 5 minutes). Older clients ignore `x` and refuse
same-realm whispers as before.

Sex (from 1.2.14): kill, death and assist records carry `victimSex` and `killerSex` ("male" or "female", from
`GetPlayerInfoByGUID` and `UnitSex`), and enemy entries in `players` carry `sex`. Optional fields; the site uses
them for the posters' art.

`WantedDB.names` (from 1.2.4) is the name book: `guid -> { n = "First Last", t }` for every player the addon sees,
either side, stamped at most once an hour. The desktop app reads it (with `players`, which holds enemies) to put
full names on the deaths it reads from the combat log, which names players by first name only. At load, names
not seen for 30 days are dropped, then the oldest until it holds 5000. A new key with a default: no migration.
The launch reset drops it with the other beta data.

`WantedDB.names` entries also carry `class` and `sex` (from the GUID lookup, 1.2.17) and the guild the player was
last seen in with its time, `g` and `gt` (`g = ""` when seen in none). A known guild is only replaced by "none"
after two such readings 30 seconds apart.

`WantedDB.addonVersions` (from 1.2.20) is the version book: `"Name" -> { v = "1.2.19", t }`, the Wanted version the
player's last sync message carried and when, with any realm removed from the name. It includes this player's own
version. The desktop app passes it to the website, which counts how many players run each version. At load,
entries older than 14 days are dropped, then the oldest until it holds 500. A new key with a default: no migration.

`WantedDB.posterShots` (from 1.2.17) lists the newest five poster pictures for the desktop app to upload:
`{ t, who, l, top, r, b }`, when the game took the screenshot (server time), whose model it is, and where the model
was on screen as fractions of the screen from its top left. The app finds the PNG in the game's Screenshots folder,
cuts the model out and uploads it to wanteddeadordead.com. No migration: the field is filled in at load.

`WantedDB.syncChannel` is `{ e, n, t }` from 1.4.0 (layout 2): the channel wanteddeadordead.com last pointed
everyone to (epoch, name, when we took it), from the Wanted app's catch-up (`channel = { e, n }`) or whispered by a
player whose app brought it. No password: every sync channel is joined without one. It can name WantedNet<Side>
itself, when the server points everyone back. The app's pointer is followed when its epoch is newer, or the same with
another name; a whispered one only when newer. The app's default, the main channel at epoch 0, and any pointer with a
`p` (an app before 0.2.26) are ignored. Absent until a pointer comes; the addon then uses WantedNet<Side>.
From 1.2.18 to 1.3.x it was `{ e, n, p, t }`, a channel the addons picked themselves after a takeover, with a
password; the layout 2 migration drops it and keeps its name in `WantedDB.oldSyncChannel` (when it isn't
WantedNet<Side>), which the addon leaves once at the next login and clears.

`WantedDB.syncChannelState` (from 1.4.0) is `{ mainRefused, mainOpen, at, epoch }`. `mainRefused`: the channel this
client follows (WantedNet<Side>, or the server's) turned it away: a password, a ban, moderation, or two kicks within
10 minutes (the name is from when only the main channel was reported). `mainOpen`: WantedNet<Side> let us in, on it
or on a quiet try while following the server's channel. `at`: the last server time the state was seen (refreshed at
every join and try; the server counts only recent reports). `epoch`: the epoch of the server pointer followed (0 for
none, so the main channel), which tells the server which channel the report is about. The Wanted app passes it to
wanteddeadordead.com, which picks a new channel for a side once two accounts report the followed channel refused,
and points everyone back once the main one is open. A new key with defaults; the migration starts it afresh.

`WantedDB.homeCheck` is `{ wait, tried }` from 1.4.0: how long to wait between quiet tries of WantedNet<Side> while it
turns us away or we're on the server's channel (5 minutes, doubled after each refusal up to 25 minutes, under the server's 30-minute window for reports, back to 5
minutes once let in), and when it was last tried (server time). Up to 1.3.x it timed tries of the first channel
after an addon-made move, with a `home` field; the layout 2 migration resets it. `settings.channelMoves` (the old
moves' switch) is removed by the same migration.

`WantedDB.channel` (from 1.2.15) is `{ name, realm, members, t }`, the sync channel's size as the game last said.

`WantedDB.settings.streaks` (from 1.2.21) is `{ callout, sound, announce }`: the kill streak and multi-kill callout
in the middle of the screen (default on), its sound (default on), and where a line about the streak goes:
`"none"` (the default), `"party"` or `"guild"`, never a public channel (`Streaks.lua`). The counts themselves are
not saved. A new key with defaults: no migration.

`WantedDB.settings.detect.sounds` (from 1.2.26) is `{ enemy, important, stealth, targeted }`: each alert's sound,
`"wanted"` (the addon's own beep, the default), `"none"`, `"kit:NAME"` (a game SOUNDKIT) or `"lsm:Name"` (a sound
another addon registered with LibSharedMedia; Wanted's beep when it's gone). A new key with defaults: no migration.

`WantedDB.settings.minimap` is the table LibDBIcon keeps for the minimap button (from 1.2.24): `hide`, and
`minimapPos`, the button's angle in degrees, filled in at load from the older `angle` (which stays, for older
versions). LibDBIcon may add `lock`. A new key filled in at load: no migration.

`WantedDB.settings.liveLog` (from 1.2.0, default on) turns combat logging on in the open world for the app's live
battle reports (`LiveLog.lua`). `WantedDB.liveLogOn` is `true` while logging is on because Wanted turned it on,
so a `/reload` still knows the logging is Wanted's to turn off; logging the player started is never turned off.
Both are new keys with defaults, so no migration.

`WantedDB.world` (from 1.1.0) says which game world the data belongs to: `"beta"` (also assumed when it's
missing) or `"live"`. `Wanted.WORLD` in `Core.lua` is the world a release is for. The first time a release for
the live game loads beta data, it keeps `settings` (and `welcomed`) and drops everything else: records,
bounties, players, Kill on Sight, Ignore, chains, sightings and the rest belong to beta characters that no
longer exist. Live data is never dropped this way. The network keeps the beta's records (the beta season stays
browsable on the website), so in the live world every record chain counts from 1,000,000 (`Store:SeqBase()`):
a character's first live record is `Name:1000001`, never the id of one of its beta records, which the server
would refuse as a conflict when a player keeps their beta name. Other players' chains start at the same base, so
their first live record follows on with nothing to ask for.

`bounty` records (from 0.1.0-beta.8) can also carry the poster's notes on the target: `class`, `race`,
`faction`, `seenAt` (when the poster last saw them), `x`, `y`, `mapId`. A client that doesn't know the target
fills its player notes from them (never overwriting its own), marked as seen by the poster.

`spotted` records (from 0.1.0-beta.8) share a sighting of someone with an open bounty: `target` (GUID), `zone`,
`x`, `y`, `mapId`; the record's origin is who saw them and its `t` when. At most one per target every 5
minutes per client. Clients put them into the target's history (`WantedDB.tracks`) and drop spotted records
older than 30 days at login (the history's length). Kill on Sight sightings are never shared.

`WantedDB.farPeers` (name -> `{ realm, seen }`, the last 20, a week) remembers realm links: players on another
realm name of the same world, synced by hidden whisper (Sync). They're greeted again at login.

Development builds only: `WantedDB.devLog` keeps the last 5000 debug log lines (`{ lines, pos }`, a ring) so
network traffic can be read back after a session; `/wanted netlog` summarises it. Lines starting `!!` mark
anomalies (altered records, broken chains, bad messages, limits hit, version locks, rejected notices).
Released builds never write it (it lives in `Debug.lua`, which packages leave out).

`WantedDB.guildRanks` and `WantedDB.guildOfficers` (from 1.2.21) are for guild mode on Discord, which wanteddeadordead.com
turns on only for a guild's officer, proven from the game. `guildRanks[guid] = { g, rn, ri, o, t }` is each of this
account's characters' own guild (`""` out of one), rank name, rank index (0 is the guild master, -1 out of a guild),
whether the game counts it an officer (`IsGuildLeader()` or `C_GuildInfo.IsGuildOfficer()`) and when that was read; it's
written at login and on the guild events when it changed, never from a value the game keeps secret, and never while the
game hasn't loaded the guild yet. `guildOfficers[guild] = { t, m = { [guid] = rank index } }` is what that guild's roster
(the game's guild club) said at most every 10 minutes: only the members at officer ranks, which are the guild master's
and the character's own when it's an officer's. A plain member's rank is never kept. A book not read for 30 days goes.
The desktop app sends both to the website, which uses them for the officer check only and never shows them. No layout
change: both are new keys.

`WantedDB.bountyRequests` and `WantedDB.requestAnswers` (from 1.2.25) carry bounties asked for from wanteddeadordead.com's
Discord bot. The desktop app's catch-up hands them on; each is checked field by field before it's kept:
`bountyRequests[id] = { id, character, target, guild, name, amount, t, expires }`, where `character` is the GUID of the
character that asked for it, `target` the target's GUID (or `guild` for a guild bounty, with `name` `"<Guild>"`), `amount`
copper from 10s to 100,000g, and `expires` the time it's dropped without asking. At most 20 are taken from one catch-up.
Each is asked once, on its own character, out of a fight and out of instances, and never while an update is required.
`requestAnswers[id] = { state, reason, t }` is what the player did: `"posted"` (the normal `Bounties:Post` or `PostGuild`
made the record), `"discarded"`, or `"refused"` with the addon's reason. The app sends the answers to the website; they're
kept a week, and a request that expired without an answer is dropped silently. No layout change: both are new keys.

Challenges (from 1.5.0): the app's catch-up can carry `challenges = { t, day, dayEnds, weekEnds, hot, daily, weekly,
allThreeBonus, me, ranks }`, worked out by wanteddeadordead.com: today's hot zones, the daily and weekly challenges, the
app's own characters' progress, streak, rank and points (`me`, by GUID), and the challenge ranks of other players
(`ranks`, by lower-case name, `{ r, f }`). `Challenges:Clean` checks it field by field and keeps it in memory only: it is
read again at every login and `/reload`, taken in or not, and never saved or sent to other players. Missing or unreadable,
Home and Challenges show what the app adds. `WantedDB.challengeNotes` is `guid -> { done = { [challenge id] = t } }`:
what the banner already announced for each character, so a completion is announced once. The first catch-up seen for a
character only notes what's already done. Notes older than 21 days are dropped. A new key: no migration. (Before 1.10.0
a note also kept the character's challenge rank; challenges have no ranks now, and the field is cleared when next written.)

`WantedDB.badgesSeen` (from 1.12.0) is `name -> { [badge] = true }`: the badges the "badge earned" banner already
knew each character held, so each is announced once. A badge is an achievement id, or a weekly medal as
`"board:metal:count"` (a medal won again is new). The first catch-up a character sees only notes what they hold.
Achievements, medals, this week's boards and playstyle badges come from the app's catch-up (`achievementDefs`,
`achievements`, `medals`, `weekBoards`, `playstyle`) and are kept in memory only. Playstyle badges are never announced. A new key: no migration.

`WantedDB.settings.signatureChat` (from 1.14.0, default on): players' signature badges before what they say in chat.
Cosmetics (each player's signature badge, poster frame and stamp, picked on wanteddeadordead.com and checked there
against what they've unlocked) come in the catch-up's `cosmetics` and are kept in memory only.

`WantedDB.settings.ranks` (from 1.5.0) is `{ tooltip, target, nameplates, chat, nearby, who }`: where other players'
challenge ranks (from the catch-up's `ranks`) show. All on but `chat`. `ranks.plate` is `{ anchor, x, y, scale, badge,
number }`, where the rank goes on nameplates: `anchor` one of `centre` (the default, centred over the plate), `above`,
`left`, `right`, `below` (around the name text, or the plate without one), `barTopLeft` or `barTopRight` (the health bar's corners), `x` and `y` offsets in
pixels (-50 to 50), `scale` 0.6 to 1.6, and whether the badge and the number show. `ranks.targetLabel` is
`{ anchor, x, y, scale }` for the label at the target frame (`above`, `below`, `left` or `right`). Values out of range
are held to their limits when read. A new key with defaults: no migration.

`WantedDB.settings.lastPage` (from 1.5.0) is the window's page when it was last open; the window opens on Home when it's
unset or that page is switched off. A new setting: no migration.

## Shared records and the channel

- Every message carries the sender's addon version (`v`). **The newest version wins**: when a client hears a
  newer release (one that looks real: at most one major version ahead), the shared side of Wanted pauses
  until it's updated. Bounties, claims, payments and sync stop; the Nearby window, alerts, hotspots and the
  map keep working. The lock lifts on update, or when nobody on that version has been seen for three days
  (so a made-up version number can't lock people out for good). After 1.18.2 a version locks only once three
  different players have said they run it (hellos, haves or `U` whispers), and only up to two minor versions ahead
  (or the next major's x.0 to x.2); `WantedDB.requiredVersion` gains `votes`, and a lock without it (one player's
  word, from before) or no longer plausible from the running version lifts at load. No migration needed.
- A newer client ignores what older clients send and tells each of them, by a private addon whisper
  (`U`), at most every 10 minutes, to update. From 1.4.0 it also tells, at login, the players it knows whose last
  message came from an older release: 1.3.x clients pick channels themselves, so 1.4.0 needs them updated.
- Channel moves (`M`, whispers only) carry `{ e, n, a = 1, h }` from 1.4.0: the server's pointer, marked as the
  server's (`a`), with how many whispers it has taken since an app delivered it (`h`); `{ e, q = 1 }` asks for the
  current one. A client follows only a marked pointer with a higher epoch than its own, from a player it has heard on
  the channel or linked with, and passes it on only while `h` is under 2 (each client spreads a pointer once). The
  1.3.x form, `{ e, n, p }` with a channel an addon picked, is ignored. After 1.18.2 a whispered pointer is followed
  only up to one epoch past the newest one this client has had (its own, or its app's), and the app's pointer replaces
  whatever a whisper brought, unless it's older than the last one the app gave: `WantedDB.appChannelEpoch` keeps that
  epoch. A new field: no migration.
- Records are immutable. A new record field must be optional: older code ignores fields it doesn't know,
  and newer code must cope with it missing. A new record kind is stored by older clients and ignored.
- Because newer versions lock older ones, a release that changes what records mean doesn't have to be
  read by old versions; it only has to read the old records it will still find.
- `notice` records (from 0.1.0-beta.3) carry a bounty from the other faction's network across, by a
  Battle.net friend's client (`Bridge.lua`): `bounty` (the other side's bounty id), `target` (a GUID on this
  faction), `targetName`, `amount` (copper, the highest seen), `poster` (a hash of the poster, for counting,
  never their name) and `postedAt`. The same bounty can arrive as several notices (raises, several bridges);
  readers take the highest amount per `bounty`. `WantedDB.seenNotices` (bounty id -> amount) remembers which
  bounties on this player have been announced. After 1.18.2 a bridge sends `b` as `"w"` plus the bounty record's
  hash (the same on every client of that side, and no name in it) and no `p`, so new notices carry no `poster`;
  readers tell bounties apart by `target` and `postedAt`, so one carried under both ids counts once. A bridge's new
  notices are capped at 100 an hour, 10 an hour about one player, and amounts at 2^31 - 1 copper.

`link` records (from 1.1.0) tie a character to a Wanted desktop app key: `code` (the code the app showed) and
`guid` (the character's own). The network confirms the link when another player's app uploads the record
marked `live`.

`kill` and `death` records (from 1.1.0) can also carry what the recording client knew of each side:
`victimClass`, `victimRace`, `victimLevel`, `victimFaction`, and the same four for `killer`. Class and race are
the client's file names (`ROGUE`, `Scourge`), level is the last one seen, faction is `Horde` or `Alliance`. Any
of them can be missing, and records from before 1.1.0 have none. The recording player's own `kill` records
also carry `killerGroup`: how many were in their group, 1 when alone (a raid counts everyone in it).

`death` records name an enemy player, or (from 1.1.2) a player of the recording client's own faction,
themselves included, who died with an enemy player in view in the last 20 seconds. `victimFaction` tells them
apart. Either way another player's app recording the death confirms the killer's `kill` record, so both sides
confirm each other's kills.

A `death` record of the recording player's own death (from 1.1.3) also names who killed them when the game's
death recap says: `killer` (GUID), `killerName`, `killerGuild` and the killer's traits. The network counts it as
a witnessed kill for that player, who may not run Wanted at all.

A received record's `live` flag (from 1.1.0) is local, like `tampered` and `brokenChain`: set when the record
came straight from its origin (the game stamped the sender), never taken from what a sender says. Clients drop
all three flags from incoming records and work them out themselves.

A received record's `app` flag (from 1.3.3) is local too: set when the desktop app's catch-up brought it (the
server checked who sent it), or later brought a record already held with the same hash. Incoming copies drop it.
`Store:IsTrusted` believes a record that is this client's own, `live`, `app` or test data, and never one flagged
`tampered` or `brokenChain`; only trusted `death` records witness a claim (`Bounties:GetWitnesses`). Flagged records
are kept and synced. `Store:Iterator` leaves `tampered` ones out, so nothing in game reads them; `brokenChain` ones
can be innocent (a reinstall, lost saved data) and are still listed, but never witness a claim. An optional new field: no
migration. Records held from before 1.3.3 that came by catch-up have no `app` flag and witness nothing until the
app or their origin sends them again.

Records made after 1.18.2 carry `prev2`: the strong hash (`Store:Strong`, the first 16 hex digits of a SHA-256 of the
record before's canonical content and its own `prev2`) of the origin's previous record. It sits beside `prev`, outside
the canonical string, so older clients check the same Adler-32 and pass the field on untouched. The own chain keeps
`lastStrong`, the strong hash of its last record. A chain may keep `stubs = { [seq] = strong..prev2 }` (32 hex
digits) for records pruned after one of its origin's confirms, raises, withdrawals or payments that nothing has vouched
for yet, so a chain walk can still cross the hole; they go once no such record comes before them. Both are optional new fields: no migration. The desktop app and the
server should keep `prev2` on the records they carry, or a chain walk can't cross a record that came that way.

A received record's `vouched` flag (after 1.18.2) is local too: set once `Store:IsVouched` has found a trusted record
of the same origin later in its chain, every record between held and each naming the one before by its strong hash
(`prev2`; an Adler-32 `prev` can be forged to fit in a fraction of a second). A record already held is only taken as the
same as an incoming copy when its whole canonical content and `prev2` match, not only its hash. Incoming
copies drop it. A `confirm`, `raise`, `withdraw` or `payment` counts only when vouched (its maker's own word), and a
raise or withdrawal only from the bounty's poster. A record in this client's own name is only taken from the app's
catch-up, and a relayed record (not trusted) is replaced when its origin sends a different one for the same id. An
optional new field: no migration. The record hash is Adler32, which can be forged; a stronger hash is a planned
follow-up that needs the server and the desktop app to change with the addon.

## Fresh start (development builds)

`/wanted freshstart` deletes every shared record on the client and starts its record chain again. Only
safe before anyone has synced with that client: their copies of its records would no longer match. It
exists only in development builds.

`WantedDB.kosPending` (from 1.8.0) holds Kill on Sight brought over from Spy or True Spy for players Wanted hasn't
seen yet: `lower-case name -> { name = "First Last", reason, t, from = "Spy" | "True Spy" }`. The first time a player of that name is seen,
they go on Kill on Sight (`kos`, by game ID) and leave this table; names nobody sees in 30 days are dropped at
login. `WantedDB.spyImportHinted` is true once the one-time "bring Spy's Kill on Sight over" hint was shown. Both are
new keys with defaults: no migration.

`WantedDB.kosGuilds` (from 1.8.0) is your own Kill on Sight for whole guilds: `guild name -> { reason, t }`. Every
member counts as Kill on Sight (alerts, the Nearby window, the Enemies page) without being listed one by one. A new
key with a default: no migration.
