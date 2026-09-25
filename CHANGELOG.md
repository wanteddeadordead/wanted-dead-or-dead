# Changelog

## [Unreleased]

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
