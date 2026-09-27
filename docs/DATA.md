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

A received record's `live` flag (from 1.1.0) is local, like `tampered` and `brokenChain`: set when the record
came straight from its origin (the game stamped the sender), never taken from what a sender says. Clients drop
all three flags from incoming records and work them out themselves.

## Fresh start (development builds)

`/wanted freshstart` deletes every shared record on the client and starts its record chain again. Only
safe before anyone has synced with that client: their copies of its records would no longer match. It
exists only in development builds.
