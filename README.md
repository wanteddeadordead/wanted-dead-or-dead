# Wanted: Dead or... Dead

> **Under heavy development through the WoW Forever beta.** Expect frequent updates, and possible issues
> while we work through the game's changes.

> Found a problem or have an idea? Press **Report a bug** in the addon's title bar (or type `/wanted bug`)
> and [open a report](https://github.com/wanteddeadordead/wanted-dead-or-dead/issues/new/choose).

**The world PvP addon for WoW Forever.** See who's around and who's on you, find out who killed you, put a price
on a ganker's head, and rally your faction for a raid on Southshore. Every fight goes on the record at
[wanteddeadordead.com](https://wanteddeadordead.com).

The addon works on its own. The optional desktop app puts your fights on the website and brings back
challenges, achievements and calling cards.

## Know who's around

- **Nearby window:** every enemy player near you, with class, level, guild, health and any bounty on them.
  Click to target, right-click for options. **Last hour**, **Kill on Sight** (with reasons) and **Ignore** lists.
- **TARGETED warning** that stays up while enemies have you targeted, and names them.
- **Stealth alarm** when the enemy you had targeted vanishes into Stealth, Prowl, Invisibility or Shadowmeld.
- **Death card:** when a player kills you, a card says who it was, your record against them and the bounty on
  them. One click puts them on Kill on Sight, posts a bounty or opens their file.
- **Hotspots:** the zones where the enemy is right now, busiest first, with their levels, the biggest guild there
  and whether it's getting busier. Recent sightings, yours and other players', on the world map.
- **Guild Kill on Sight:** a list your guild keeps together, changed only by the ranks your officers allow.
- **Call for help** tells Local Defense, your party or raid, or your guild where you are in words ("Need help
  west of Razor Hill, Durotar 47,40") and who's on you.
- **Quiet mode** (optional): alerts and the Nearby window stay silent until you're PvP flagged.
- **Emote buttons** along the bottom of the Nearby window: taunts, after a kill, losing, mid-fight.

## Form world PvP raids

- **Form a raid** now or for later. Every Wanted player on your faction sees it, across realm names, and joins
  with one click; your addon invites them, making the group a raid before the sixth.
- **Interested or Going** sign-ups, with who's going on hover, a popup when the raid starts, and **Invite
  sign-ups** and **Whisper sign-ups** for the leader.
- **Guild only** raids for your guild first, opened to everyone when you need more.
- **Announce** it in guild chat or any channel you're in, and anyone who whispers you "inv" is invited.
- Times in your own time zone and server time, changes and cancellations sent to everyone signed up, and raids
  on your calendar.

## Put a price on their head

- **Bounties** on an enemy player, or on a whole guild (the first kill of any member claims it). Hunters mark the
  bounties they're chasing; while anyone is hunting one, the poster can't pull it.
- **The file on every target:** where they were last seen, the zones and hours they keep to, and every sighting.
- Kill the target and the claim files itself. Another player's addon that saw the death **witnesses** it. The
  poster confirms and pays by mail in one click, and both sides record the payment.
- **Kill proof:** a stamped screenshot when your kill claims a bounty.
- **Your wanted poster:** every bounty the other faction has put on you, on a poster to screenshot and share
  (`/wanted poster`).
- **Reputation from the record:** hunters are rated on confirmed kills, posters on what they paid. Unpaid
  bounties show.

## Earn your calling card

- **Achievements, weekly medals and badges** for what you do in world PvP, with a popup the moment you earn one.
- **Your calling card:** a banner built from the backgrounds, borders, plates and emblems you unlock, shown on
  your player page and on the death card of everyone you kill. Build it in game with `/wanted card`.
- **Kill streak callouts:** Killing spree, Unstoppable, Double kill and the rest.
- **Daily and weekly challenges** for both factions, with hot zones where kills count double.

## Every fight on the record

- **Battle reports** for every big fight on [wanteddeadordead.com](https://wanteddeadordead.com): who died, who
  killed, the top killers, healers and damage, the guilds, and a written report of how it went.
- **The war this week:** which side holds each zone, the front line in contested zones, and the week's major
  battle on the front page.
- **Leaderboards** for killing blows, streaks, healers, damage, guilds and zones.
- **Confirmed, not claimed:** a kill only counts once another player's records back it up, so nobody can pad
  their numbers from one computer.
- **Your nemesis:** who has killed you most, and who you've killed most, with wins and losses against every enemy.
- **Players' Blizzard PvP ranks** on nameplates, tooltips and your target, for anyone running Wanted.

Follow the war on X: [@WantedDoD](https://x.com/WantedDoD), with the biggest battles as they happen.

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
- **Chat only when you click.** The addon never posts in public chat on its own. It only sends chat when you
  press a button that says so: Call for help, "Tell ...", or a raid's Announce and Whisper sign-ups.

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
