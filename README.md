# Wanted: Dead or... Dead

> **Under heavy development through the WoW Forever beta.** Expect frequent updates, and possible issues
> while we work through the game's changes.

> Found a problem or have an idea? Press **Report a bug** in the addon's title bar (or type `/wanted bug`)
> and [open a report](https://github.com/wanteddeadordead/wanted-dead-or-dead/issues/new/choose).

World PvP bounties, enemy awareness and reputation for **WoW Forever**, shared player to player.

Put a price on a ganker's head. Hunt the people with gold on theirs. See who's around, who's targeting
you, and who pays their debts. There's no server, no bank and no middleman: every copy of the addon
shares what it sees with the others on your faction, and everything is judged from what actually
happened.

## Features

**Bounty board**
- Post a bounty on an enemy player, or on **every member of a guild**. One per target; posting again adds
  to it.
- Bounty hunters mark a bounty they're chasing, for a day at a time (renew to keep going). While anyone is
  hunting it, the poster can't pull it.
- Sort the board by amount, newest, name, the zone a target was last seen in, or who was seen most recently.
- **The file on every target:** click a bounty for where they were last seen, the zones they keep to, the
  hours they're usually about, every sighting by you and other Wanted users, and their deaths. Sightings of
  wanted players are kept for a month.
- Kill the target and the claim files itself from your honorable kill. Another player's client that saw
  the death **witnesses** it. The earliest kill wins.
- The poster confirms or disputes, then pays by mail in one click. Both sides' clients record the
  payment, so paid and unpaid are facts, not claims.
- **Kill proof:** when your kill claims a bounty, a stamp with who, where, when and the kill id goes on
  screen and the game saves a screenshot. Posters see you have proof; if a kill is disputed, post it in
  [#pvp-salt on the Forever PvP Discord](https://discord.com/invite/wow-forever-pvp).

**Your wanted poster**
- **The price on your head:** every bounty the other faction has ever posted on you, paid or not, adds up.
  You get an alert when someone puts a price on you.
- Open **Your wanted poster** from the menu (or `/wanted poster`): your own character on a painted poster
  with your name and that total. **Take screenshot** saves it to share anywhere.
- **Set amount** shows any reward you like, just for fun. The poster marks it "(allegedly)".

**Reputation from the record**
- Bounty hunters get a level and a reliability rating from witnessed and confirmed kills.
- Posters are known by what they posted and paid. Unpaid bounties show on their record.
- Leaderboards for bounty hunters, posters and guilds (kills, deaths, bounty gold on them).

**Enemy awareness**
- A small **Nearby** window: who's around, who's acting, who's out of sight, with class icons, guilds,
  levels, health and bounty gold. Click to target, right-click for options.
- **Last hour**, **Kill on Sight** (with reasons) and **Ignore** lists.
- Alerts and beeps for new enemies, louder for Kill on Sight and bounty targets, a **stealth alarm** when
  the enemy you have targeted vanishes into Stealth, Prowl, Invisibility or Shadowmeld, and a
  **TARGETED** warning that stays up while enemies have you targeted and grows to list everyone on you.
- **Quiet mode** (optional): alerts and the Nearby window stay silent until you're PvP flagged. The Nearby
  window also hides itself after a few minutes with nobody around.
- **Call for help** tells Local Defense, your party or raid, or your guild where you are in words ("Need help
  west of Razor Hill, Durotar 47,40") and who's on you.
- **Emote buttons**: your favourite emotes along the bottom of the Nearby window and a **...** button with all
  46 (taunts, after a kill, losing, mid-fight). They emote at your target and work mid-fight. Pick favourites
  or turn them off in Settings > Emotes.
- Wins and losses against every enemy, and a sortable, searchable enemies list.
- Recent sightings, yours and other players', on the world map.
- **Hotspots**: the zones where enemy players are right now, busiest first, with their levels, the biggest
  guild there, PvP deaths and whether it's getting busier. Click a zone to open its map.

## Install

Install from CurseForge, or download the latest release zip and extract the `WantedDeadOrDead` folder into
`World of Warcraft\_classic_beta_\Interface\AddOns\` (the WoW Forever client).

Open it with `/wanted` or the minimap button. Right-click the minimap button for the Nearby window.

## How it works

- **Seeing enemies.** WoW Forever doesn't let addons read the combat log, so the addon watches what the
  client does allow: nameplates, your target, focus and mouseover, the moment your target vanishes close by
  (for stealth), the client's kill and death events, and the death recap. Someone who never appears on your screen can't be
  seen by any addon.
- **Live battle reports.** The addon keeps the game's combat log on in the open world. The optional desktop
  app reads it (an addon can't), picks out the player-versus-player deaths and their killers, and posts them to
  wanteddeadordead.com within a few minutes, without a /reload. The combat log names players by first name only,
  so the addon keeps a name book of the full names it sees, and the app uses it.
- **Sharing.** Copies of the addon on the same faction talk through a hidden custom chat channel using
  addon messages, which only the addon sees. Each copy keeps the full record and fills in what it missed
  from whoever is online. Every record carries a hash of the sender's previous one, so a rewritten history
  shows.
- **Across realms.** WoW Forever's one world has several realm names, and a chat channel belongs to one. So
  copies on different realm names link up by hidden addon whispers instead: through Battle.net friends,
  anyone who greets them, and the links remembered from before. A link catches both sides up and passes new
  records both ways; each side shares what it gets on its own channel.
- **Across factions.** Each faction's copies only hear each other, so the price on your head comes from
  Battle.net friends: when a player on the other side who runs the addon has a Battle.net friend on yours
  who does too, their clients pass bounty notices across as hidden game data (never chat). Only the target,
  the amount and when it was posted cross, never the poster's name. Turn it off in Settings > Sharing;
  `/wanted bridge` shows who is carrying notices for you.
- **Trust.** A claim needs the killer's own client; a second client that saw the death makes it witnessed.
  The game stamps who sent each message, so nobody can speak for someone else. Reports weigh by the
  reporter's own record.
- **Chat only when you click.** The addon never posts in General or Trade. The only chat it sends is when
  you press "Call for help" or "Tell ..." yourself: to Local Defense, your party or raid, or your guild.

## Good to know

- WoW Forever only (client 1.60.x).
- During combat the game won't let an addon re-point clickable rows, so new enemies in the Nearby window
  become clickable once combat ends.
- Enemy health is drawn by the game, not read by the addon, so the bar shows length but not a colour change.
- WoW Forever doesn't tell addons about Stealth or Vanish, so the stealth alarm spots the moment your target
  vanishes close by. It can't cover enemies you haven't targeted.
- It gets better the more bounty hunters run it: bounties, sightings and witnesses all come from other players.
  On your own it still detects, alerts and keeps your lists.

## Development

```
lua tests/smoke_test.lua
```

loads the whole addon under a stand-in for the game and drives every page, button and dialog.
Releases are built by the [BigWigs packager](https://github.com/BigWigsMods/packager) from a git tag; see
[docs/PUBLISHING.md](docs/PUBLISHING.md).

## License

MIT. Bundled libraries are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Not affiliated
with Blizzard Entertainment.
