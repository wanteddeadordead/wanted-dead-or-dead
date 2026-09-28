# Changelog

## [Unreleased]

- The channel's member count is asked for as /chatlist does, the only request the game answers from an addon,
  with the list's chat line hidden; asked again when the game's channel list isn't built yet, as right after a
  login or /reload, and once the list arrives.

## [1.2.15] - 2026-09-28

How many are on the net.

- The Tools page and /wanted sync say how many players are in the sync channel, from the game's channel list:
  every one of them runs Wanted. The app passes the count to wanteddeadordead.com.
- /wanted channels (development builds) shows how the game reports the channel's members.

- Logging in no longer says Wanted can't get into its sync channel: the game rejoins the channel without its
  password and asks for one, and that failed attempt was taken for a changed password.
- A player who answers a whispered greeting from this realm is heard, and a player on this realm is no longer
  remembered as a far one and greeted by whisper at every login.

## [1.2.14] - 2026-09-28

The right poster.

- Records now say whether a player is male or female, so wanteddeadordead.com can paint the right poster.

## [1.2.13] - 2026-09-28

A fix.

- Fixed an error ("bad argument #3 to '?'") when the game announced a sync channel change without naming who
  made it.

## [1.2.12] - 2026-09-28

Form a posse.

- Posses: "Form a posse" on an outlaw or a bountied player (their menu in the Nearby window) sends where they
  are to your faction's Wanted players. Everyone in that zone is asked to join; whoever joins whispers you and
  is invited to your group. The call carries the target's position every half minute while you can see them,
  for ten minutes.
- Kill and death records now carry the zone's map id, so wanteddeadordead.com names the zone the same whatever
  language your client runs in.

## [1.2.11] - 2026-09-28

Outlaws.

- Outlaws: a player who makes four kills within twenty minutes, each backed by someone else's record, is Wanted
  with no gold behind it, and stays so until a week passes without a kill. Ranks by the week's kills: Wanted,
  Notorious, Menace, Public Enemy, Dead or... Dead. The Nearby window shows the rank, an OUTLAW alert warns
  when one turns up, and Call for help names them. The same rule runs on wanteddeadordead.com.

## [1.2.10] - 2026-09-27

The sync channel looks after itself.

- Whoever has been in the sync channel longest becomes its owner, and an owner can kick, ban or lock it. Wanted
  now says in chat who did what, rejoins after a kick, and when it's locked out keeps syncing by whisper with
  the players it last heard there while it tries the channel again every five minutes.

## [1.2.9] - 2026-09-27

Saved data stays a month deep.

- Saved data stays a sensible size: kills, deaths and assists older than 30 days are dropped when Wanted loads
  (bounties and everything about them are kept, and so is any kill a claim rests on). wanteddeadordead.com keeps
  the full history. Catch-ups over the channel know where a pruned history starts, so nobody keeps asking for
  records that are gone.

## [1.2.8] - 2026-09-27

A quieter chat window.

- The sync channel no longer shows up in a chat window: joining it by hand (the /join tip) listed it there, and
  the game then showed its every join, leave and owner change in your chat. Wanted takes it back out and hides
  those notices.

## [1.2.7] - 2026-09-27

Log in already caught up.

- With the Wanted desktop app, you log in already caught up: the app fetches everything your side recorded while
  you were away from wanteddeadordead.com, and Wanted takes it in in the background after the loading screen
  (never during a fight). The other side's bounties on your side's players come with it. Needs app 0.2.3 or
  newer and one full game restart.

## [1.2.6] - 2026-09-27

Sync ready for a much bigger network, and no more repeated names in the Nearby window.

- Sync keeps working as the network grows: the hello a client sends when it logs in now lists only the players
  active in the last week (at most 150), not everyone it has ever heard from. Past about 1,000 players the old
  hello no longer fit the game's send limit, and new logins would have stopped syncing.
- Fixed the Nearby window listing an enemy several times when they turned up during a fight: each refresh in
  combat wrote them into another empty row.
- A copy of Wanted downloaded straight from GitHub no longer acts as a development build (debug log and test
  commands). Only builds marked "-dev" do.

## [1.2.5] - 2026-09-27

No more blocked actions in fights.

- Fixed "Interface action failed because of an AddOn" in fights with the Nearby window open: showing an
  enemy's health bar is blocked in combat on this client, so the bars now fade in and out instead.

## [1.2.4] - 2026-09-27

Full names on live battle reports, and a lot faster with a lot of saved data.

- Much faster with a lot of saved data: walking one kind of record (raises, claims, payments) no longer walks
  every record, and the open-bounty list and the minimap count are only worked out again when a bounty record
  arrives. With 2,300 records, the Board page's refresh went from about 4 ms to under 0.1 ms in testing.
- Released builds no longer write the addon's debug log to the game's Logs\General.log file.
- A name book: Wanted remembers the full names of the players it sees, on both sides, so the desktop app can
  put "First Last" on the deaths it reads from the combat log (which only has first names).

## [1.2.3] - 2026-09-27

Dungeons and speed.

- The Nearby window closes in dungeons and raids, where there's no world PvP, and opens again when you leave if
  it was open. Battlegrounds and arenas keep it.
- The main window refreshes several times faster with a lot of saved data. The menu's badges (actions waiting,
  hunts, busy hotspots) scanned every record on every refresh; now at most one is worked out again per refresh,
  and each at most every 5 seconds. Opening the window also refreshed it twice.
- The minimap button's count of actions waiting on you is only worked out again when a bounty record arrives,
  not on every death and sighting in a busy fight.
- Fixed a Lua error in dungeons ("attempt to compare a secret string value") from the Nearby window's health
  bars: the game keeps unit ids secret there.

## [1.2.2] - 2026-09-27

Harder to fake a bounty claim.

- Before you confirm a bounty claim, Wanted warns you when nobody else recorded the death, or when its only
  witnesses are new to the network or only ever back up that hunter. The confirm dialog also gives the address
  of the death's page on the website, with every record of it from both factions, including who the victim's
  own record says killed them.

## [1.2.1] - 2026-09-27

Reminders when the desktop app isn't set up, or isn't running.

- Without the Wanted desktop app set up on this computer, a popup at login or /reload offers it, with the address
  to copy. "Don't remind me" stops it; the Website & app page can turn it back on.
- When the app is set up but hasn't run for a few hours, the popup asks whether it's running, and the app light
  turns amber: "App not running". (Needs app 0.2.1, which says when it last ran.)

## [1.2.0] - 2026-09-27

Battle reports fill in during the fight, your nemesis on the Enemies page, and clearer signs of what's running.

- A note across the top of the window: Wanted is under heavy development through the WoW Forever beta, so
  expect frequent updates, and possible issues while we work through the game's changes.
- The top of the window shows two lights: the Wanted app (or "Get the app", which opens the Website & app page)
  and WantedNet, the in-game channel. It no longer counts other players.
- When a newer Wanted is out, the addon says your version is outdated and gives the CurseForge link, at each
  login until you update, not only the first time it notices.
- Live battle reports: Wanted keeps the game's combat log on in the open world, so the desktop app can post
  deaths to the website within about five minutes (the game writes the log that often) instead of after a
  /reload. On by default; the switch is on the Website & app page. Logging you turned on yourself
  is never turned off, and it's off in instances.
- Your nemesis, across the top of the Enemies page: who has killed you most, who you've killed most, and who
  you've fought most, from your own wins and losses. Click one for the enemy's menu.

## [1.1.3] - 2026-09-27

Who killed you now counts, and the addon tells you about the website and the app.

- When you die, your death record names who killed you (from the game's death recap), so their kill counts on
  the website even if they don't run Wanted. Kills by players in your group, which the addon already recorded,
  count for them on the website too. The game doesn't let addons see who killed anyone else.
- A Website & app page: what the site and the desktop app are for, whether the app is set up on this computer
  and up to date, and the addresses to copy (the site, the app download, and your own player page).
- When a new version of the Wanted desktop app is out, the addon says so in chat at login (the app tells it).
- A crowd of enemies coming into view no longer redraws the Nearby window once for each of them, and the
  minimap button no longer recounts your bounties every 10 seconds.
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
