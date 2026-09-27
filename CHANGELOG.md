# Changelog

## [Unreleased]

- When you die, your death record names who killed you (from the game's death recap), so their kill counts on
  the website even if they don't run Wanted. The game doesn't let addons see who killed anyone else.

- A Website & app page: what the site and the desktop app are for, whether the app is set up on this computer
  and up to date, and the addresses to copy (the site, the app download, and your own player page).
- When a new version of the Wanted desktop app is out, the addon says so in chat at login (the app tells it).
- Catch-ups for other players go out a batch at a time instead of all at once, which caused a brief hitch every
  minute or so with a player on another realm.
- Reading a zone's map for named areas on a zone change happens in a quiet moment.
- Enemy players who die near you are recorded even if the addon never had them on a nameplate or target: the
  game's death event and their race say which side they're on.

## [1.1.2] - 2026-09-26

No more lag in big fights, and both sides' deaths count.

- Fixed heavy lag in big fights (a raid on Undercity froze the game). The Nearby window redrew itself and the
  alerts looked up every enemy each time any enemy changed target, hundreds of times a second in a raid. The
  window now redraws at most four times a second, and alerts only look at the events that can raise one.
- In a fight the addon only records. Your kills, deaths and sightings are still noted, and sightings are still
  shared, but everything else (sending your records, catch-ups, taking in other players' records) waits until
  a few seconds after combat ends, then catches up a few milliseconds a frame.
- Looking up who has a bounty on them no longer reads through every saved record each time.
- Deaths on your own side are recorded too, yours included, when an enemy player was in view: dying to a mob
  isn't world PvP. Your record of a death confirms the enemy's kill, the same way theirs confirms yours, so
  both sides' kills can be confirmed.

## [1.1.1] - 2026-09-26

Sharing keeps up in big fights now, and links confirm in play.

- Your new records now go out together up to 8 seconds after they're made, instead of one message each. A busy
  fight used to hit the send limit and hold records back until the next resync.
- Links and assists are now shared as they happen, like kills. Before, they waited for a resync, and
  a link only confirms when another player receives it straight from you.
- A catch-up copy sent by the record's own author now counts as received straight from them.
- Sync messages wait in a queue and go out at the game's own pace (a burst, then one part every few seconds),
  so the game no longer refuses them in busy moments. Your new records go first and catch-ups go last. A part
  the game does refuse is sent again by itself, not the whole message from the start.
- Records that arrived ahead of a missing one now join their chain once it turns up. Before, the addon kept
  asking other players for records it already had, every minute. Saved chains stuck this way are fixed at login.
- More enemy sightings are shared in big fights (the limit was hit over and over during a raid on Undercity).
- Only a released version tells other players to update. A development build no longer tells anyone to update,
  pauses anyone's sharing, or ignores records from older versions.
- The Hotspots menu item shows how many zones have enemies right now, like the Enemies count.

## [1.1.0] - 2026-09-26

The Wanted desktop app is out: <https://wanteddeadordead.com/app>. It keeps every addon's saved data safe
between sessions and puts your records on the website's world PvP leaderboards. The addon works exactly the
same without it.

- With the app, every character links itself at login. `/wanted link <code>` is still there if one doesn't.
- Kill and death records now note each side's class, race, level and faction, and your kills note how many
  were in your group, for the website's breakdowns by class, race and level and its solo boards.
- Honorable kills you helped with but didn't land are recorded as assists. WoW Forever doesn't name the
  victim, so the addon matches the HK to the enemy death it just saw.
- `/wanted status` says whether the game or the desktop app loaded your saved data.
- Records passed on by another player no longer keep that player's flags (altered, broken chain); each client
  checks every record itself.

## [1.0.1] - 2026-09-25

- A realm link ends as soon as the other player logs off, instead of whispering to them for a while (and
  their "No player named ... is currently playing" is hidden). A quiet link now times out after 3 minutes.

## [1.0.0] - 2026-09-25

The first stable release, for WoW Forever (client 1.60.x). Everything from the betas, plus:

- The BETA label and beta welcome are gone. Report a bug stays in the title bar (or /wanted bug).

What Wanted: Dead or... Dead does, in short:

- A bounty board for enemy players and whole guilds: post, raise, hunt, claim by killing, witnessed by other
  players' clients, confirmed by the poster and paid by mail, with kill-proof screenshots.
- Reputation from the record: hunter levels and ratings, posters' payment records, leaderboards.
- Your wanted poster, with the price the other faction has put on your head.
- Enemy awareness: the Nearby window, Kill on Sight and Ignore lists, alerts, a stealth alarm, the TARGETED
  warning, hotspots, map markers, Call for help that says where you are, quiet mode, and emote buttons.
- Shared player to player with no server: on each realm's channel, across realms by hidden whispers, and
  bounty notices across factions through Battle.net friends.

## [0.1.0-beta.8] - 2026-09-25

- Shared sightings of wanted players. Seeing someone with an open bounty shares where and when (at most every
  5 minutes per target), and it syncs like everything else: to players who were offline and across realms. So
  every hunter's file on a target has everyone's sightings, from before they took the bounty too. Kill on
  Sight sightings stay private.
- A bounty carries what its poster knew about the target (class, race, level, guild, where and when last seen),
  so hunters who never saw them, on another realm or offline at the time, still know who and where to look.
- A realm link no longer loses the other side's first request when it arrives ahead of their hello.
## [0.1.0-beta.7] - 2026-09-25

- Sync across realms. WoW Forever's one world has several realm names (e.g. Classic Beta PvP and Classic Beta
  PvP 2), and a chat channel belongs to one, so players on different realm names never heard each other.
  Wanted now links them by hidden addon whispers, found through Battle.net friends, anyone who greets you, and
  links remembered from before. Bounties, hunts, kills, claims and payments cross; enemy sightings stay local.
  /wanted bridge lists the links.
- Players catching up now also get bounty notices and kill proofs, which the catch-up used to leave out.
## [0.1.0-beta.6] - 2026-09-25

- No more "Please enter a password for 'WantedNetHorde'" box at login: Wanted answers it for its own channel.
- Posting a bounty no longer counts as seeing the target, so "last seen" stays when they were really last seen.
## [0.1.0-beta.5] - 2026-09-25

- Emote buttons in the Nearby window: your favourites along the bottom (LOL, Flex, Doom, Rude, Train, Violin,
  Bye to start) and a ... button with all 46, grouped (taunts, after a kill, losing, mid-fight). They emote at
  your target and work mid-fight. Pick favourites, or turn them off, in Settings > Emotes.
- The Nearby window says "in sight" only for enemies on your screen (the ones you can click), and "nearby"
  for those out of view but seen within the last minute.
- Sort the bounty board: highest amount, newest, name, the zone they were last seen in, or who was seen most
  recently. Bounties waiting on you stay on top.
- The wanted poster's name and reward are lettered in a western wood-type font (Rye), and the reward reads
  like a poster ("5,000 GOLD"). Long names shrink to fit.

## [0.1.0-beta.4] - 2026-09-25

- The stealth alarm works again for the enemy you have targeted. The game no longer tells addons about Stealth
  or Vanish at all, so Wanted spots the moment instead: your target disappears and is dropped while within 28
  yards and alive. (Turning the camera keeps your target; walking out of view happens much further away.)
  Rogues show STEALTH, druids PROWL, mages INVISIBILITY, night elves SHADOWMELD; a Hearthstone or teleport
  finishing, or a loading screen, doesn't count.

## [0.1.0-beta.3] - 2026-09-25

- Your wanted poster (in the main menu, or /wanted poster): your character on a painted
  poster with the price on your head, every bounty the other faction has posted on you, paid or not. Take
  screenshot saves it for sharing; Set amount shows any reward you like, allegedly.
- Bounty notices across factions: Battle.net friends on the other faction who also run Wanted pass on the
  bounties each side posts on the other, as hidden game data, never chat. You get an alert when a price is
  put on your head. /wanted bridge shows who is carrying them; Settings > Sharing turns it off.
- New logo and icon: a bounty notice pinned by a jewelled dagger (addon list, minimap button, options).

## [0.1.0-beta.2] - 2026-09-25

- Quiet mode (Settings > Alerts > Only when I can be attacked): alerts, the TARGETED warning and the Nearby
  window stay silent until you can be attacked (PvP flagged, not in a sanctuary); getting flagged with enemies
  around opens the window. Off by default; after your first run-in with enemies a one-time tip offers it.
- The Nearby window hides itself after 5 minutes with no enemies (Settings > Nearby window: never, 2, 5 or 10 min).
- The TARGETED warning grows to fit everyone targeting you and fades out below the last name, instead of the
  names spilling out of its box.
- Call for help says where you are in words: the area you're in ("Need help in Brill, Tirisfal Glades 61,52") or,
  between areas, the nearest one and which way ("Need help west of Razor Hill, Durotar 47,40").

## [0.1.0-beta.1] - 2026-09-25

First public beta, for WoW Forever (client 1.60.1).

- Bounty board: bounties on enemy players or whole guilds; raise, withdraw, pass; 24-hour hunts with Renew.
- Claims file themselves from your kills, witnessed by other players' clients; the earliest kill wins.
- Kill proof: a stamped screenshot of each bounty kill, taken after combat, for disputes.
- Payments by mail, recorded by both sides; unpaid claims go on the poster's record.
- Five-star ratings for hunters and posters, trust levels, and Your record with how to improve it.
- Leaderboards for hunters, posters and guilds.
- Your bounties for everything as a poster, Your hunts for everything as a hunter.
- The file on a target: last seen, usual zones, usual hours, every sighting and their deaths.
- Enemy detection: the Nearby window (in sight, shaded, gone), Last hour, Kill on Sight, Ignore, alerts and
  sounds, stealth alarm, TARGETED warning, your own PvP status, Call for help.
- Hotspots, with an alert when a zone fills up fast; enemy markers on the world map, merged when seen together.
- Peer-to-peer sync over a hidden channel: batched sightings, send limits, hash-chained records, and the newest
  version wins.
- Report a bug (/wanted bug), an Options > AddOns entry, the addon menu and a minimap button.
