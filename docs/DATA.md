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

`WantedDB.faction` (from 1.2.7) is the account's side ("Horde" or "Alliance"), saved at login for the desktop app.
`WantedDB.catchupT` (from 1.2.7) is the server time of the last catch-up taken in. The app sends the server the
account's chains and side, and writes the answer into `!!WantedLink/Catchup.lua` as
`WantedAppCatchup[mark] = { t, records = { ... }, notices = { ... } }`: this side's records past the chains held,
and the other side's bounties on this side in the Bridge's notice form. At login `Catchup:Import` takes in an
entry newer than `catchupT` in the background (as gap fills, never live, not forwarded to realm links), then the
notices through the Bridge. No layout change: both fields are new and optional.

Pruning (from 1.2.9): at load, `Store:Prune` drops `kill`, `death` and `assist` records older than 30 days
(`Store.KEEP_SECONDS`), except a kill some `claim` names in `data.kill`. Every other kind is kept. The website
keeps the full archive (the app uploads records as they appear; one pruned before the app ever ran is lost to
it). A fill (`F`) answering a request for records the sender pruned carries `p = { [origin] = firstSeqHeld }`;
the receiver's chain for that origin moves on to `firstSeqHeld - 1` (`Store:SkipTo`), continuing from that
record's `prev`, or from an unknown predecessor (`lastHash = "?"`, which the chain check accepts once), so it
stops asking for records nobody holds. Older clients ignore `p` and keep asking, as before.

`WantedDB.recentPeers` (from 1.2.10) is `name -> seen` for the last 20 players heard on the sync channel. A client
locked out of the channel (banned, password changed, or no answer after 12 join attempts) whispers them a hello
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

`WantedDB.syncChannel` (from 1.2.18) is `{ e, n, p, t }`: the channel everyone moved to after the first was taken
over (epoch, name, password, when). Absent until then; the addon uses WantedNet<Side> with the built-in password.

`WantedDB.channel` (from 1.2.15) is `{ name, realm, members, t }`, the sync channel's size as the game last said.

`WantedDB.settings.liveLog` (from 1.2.0, default on) turns combat logging on in the open world for the app's live
battle reports (`LiveLog.lua`). `WantedDB.liveLogOn` is `true` while logging is on because Wanted turned it on,
so a `/reload` still knows the logging is Wanted's to turn off; logging the player started is never turned off.
Both are new keys with defaults, so no migration.

`WantedDB.world` (from 1.1.0) says which game world the data belongs to: `"beta"` (also assumed when it's
missing) or `"live"`. `Wanted.WORLD` in `Core.lua` is the world a release is for. The first time a release for
the live game loads beta data, it keeps `settings` (and `welcomed`) and drops everything else: records,
bounties, players, Kill on Sight, Ignore, chains, sightings and the rest belong to beta characters that no
longer exist. The website and network are reset at the same time. Live data is never dropped this way.

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

## Shared records and the channel

- Every message carries the sender's addon version (`v`). **The newest version wins**: when a client hears a
  newer release (one that looks real: at most one major version ahead), the shared side of Wanted pauses
  until it's updated. Bounties, claims, payments and sync stop; the Nearby window, alerts, hotspots and the
  map keep working. The lock lifts on update, or when nobody on that version has been seen for three days
  (so a made-up version number can't lock people out for good).
- A newer client ignores what older clients send and tells each of them, by a private addon whisper
  (`U`), at most every 10 minutes, to update.
- Records are immutable. A new record field must be optional: older code ignores fields it doesn't know,
  and newer code must cope with it missing. A new record kind is stored by older clients and ignored.
- Because newer versions lock older ones, a release that changes what records mean doesn't have to be
  read by old versions; it only has to read the old records it will still find.
- `notice` records (from 0.1.0-beta.3) carry a bounty from the other faction's network across, by a
  Battle.net friend's client (`Bridge.lua`): `bounty` (the other side's bounty id), `target` (a GUID on this
  faction), `targetName`, `amount` (copper, the highest seen), `poster` (a hash of the poster, for counting,
  never their name) and `postedAt`. The same bounty can arrive as several notices (raises, several bridges);
  readers take the highest amount per `bounty`. `WantedDB.seenNotices` (bounty id -> amount) remembers which
  bounties on this player have been announced.

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

## Fresh start (development builds)

`/wanted freshstart` deletes every shared record on the client and starts its record chain again. Only
safe before anyone has synced with that client: their copies of its records would no longer match. It
exists only in development builds.
