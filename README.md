# Wanted: Dead or... Dead

World PvP bounties, enemy awareness and reputation for **WoW Forever**, shared player to player.

Put a price on a ganker's head. Hunt the people with gold on theirs. See who's around, who's targeting
you, and who pays their debts. There's no server, no bank and no middleman: every copy of the addon
shares what it sees with the others on your faction, and everything is judged from what actually
happened.

## Features

**Bounty board**
- Post a bounty on an enemy player, or on **every member of a guild**. One per target; posting again adds
  to it.
- Hunters mark a bounty they're chasing. While anyone is hunting it, the poster can't pull it.
- Kill the target and the claim files itself from your honorable kill. Another player's client that saw
  the death **witnesses** it. The earliest kill wins.
- The poster confirms or disputes, then pays by mail in one click. Both sides' clients record the
  payment, so paid and unpaid are facts, not claims.

**Reputation from the record**
- Hunters get a level and a reliability rating from witnessed and confirmed kills.
- Posters are known by what they posted and paid. Unpaid bounties show on their record.
- Leaderboards for hunters, posters and guilds (kills, deaths, bounty gold on them).

**Enemy awareness**
- A small **Nearby** window: who's around, who's acting, who's out of sight, with class icons, guilds,
  levels, health and bounty gold. Click to target, right-click for options.
- **Last hour**, **Kill on Sight** (with reasons) and **Ignore** lists.
- Alerts and beeps for new enemies, louder for Kill on Sight and bounty targets, a **stealth alarm**, and a
  **TARGETED** warning that stays up while enemies have you targeted.
- Wins and losses against every enemy, and a sortable, searchable enemies list.
- Recent sightings, yours and other players', on the world map.

## Install

Install from CurseForge, or download the latest release zip and extract the `WantedDeadOrDead` folder into
`World of Warcraft\_classic_beta_\Interface\AddOns\` (the WoW Forever client).

Open it with `/wanted` or the minimap button. Right-click the minimap button for the Nearby window.

## How it works

- **Seeing enemies.** WoW Forever doesn't let addons read the combat log, so the addon watches what the
  client does allow: nameplates, your target, focus and mouseover, enemy spell casts (for stealth), the
  client's kill and death events, and the death recap. Someone who never appears on your screen can't be
  seen by any addon.
- **Sharing.** Copies of the addon on the same faction talk through a hidden custom chat channel using
  addon messages, which only the addon sees. Each copy keeps the full record and fills in what it missed
  from whoever is online. Every record carries a hash of the sender's previous one, so a rewritten history
  shows.
- **Trust.** A claim needs the killer's own client; a second client that saw the death makes it witnessed.
  The game stamps who sent each message, so nobody can speak for someone else. Reports weigh by the
  reporter's own record.
- **No public chat.** The addon never posts in General, Trade or any public channel. The only chat it sends
  is when you press "Tell your party / raid / guild" yourself.

## Limits

- WoW Forever only (client 1.60.x).
- During combat the game won't let an addon re-point clickable rows, so new enemies in the Nearby window
  become clickable once combat ends.
- Enemy health is drawn by the game, not read by the addon, so the bar shows length but not a colour change.
- The network needs other players running the addon. Alone, it still detects, alerts and keeps your lists.

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
