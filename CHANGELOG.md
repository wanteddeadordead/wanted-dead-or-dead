# Changelog

## [Unreleased]

- Hunts last 24 hours (was 2), renewable.
- The file on a target: click a bounty (or right-click an enemy > Where they've been, or /wanted file) for last
  seen, usual zones, usual hours, every sighting and their deaths. Sightings of wanted players are kept a month.
- Your hunts (Your bounties > Your hunts): every bounty you're hunting, with the time left and Renew or Stop.
- Kill proof: a stamped screenshot when your kill claims a bounty, shown on the claim, with the Forever PvP
  Discord (#pvp-salt) for disputes. On by default, in Settings > Sharing and display.
- Your record (Your bounties > Your record, /wanted record): your trust as a poster and as a hunter, what it
  means, and how to improve it, with a key to every trust level.
- Trust levels in bounty tooltips and /wanted rep: Trusted, Reliable, Unproven or New poster, Doubtful, Untrustworthy.
- Bounty rows show each poster's and hunter's record in a few coloured words: unpaid, paid, disputed, level.
- An entry in the game's Options > AddOns list with buttons to open Wanted and the Nearby window.
- Test data is gone from released versions: no test data card on the Tools page, no simulate or purge commands.
- Call for help: a button under the Nearby list sends where you are and who's around to your party or raid or
  your guild, or types it into your chat box for Local Defense (the game lets only you post there: press Enter). Enemies also get a Tell Local Defense option.
- Rising-zone alerts: RISING FAST: <zone> when a zone fills up with enemies (on by default, Settings or Hotspots).
- Sightings are shared in batches with their own budget, and an enemy someone just shared isn't sent again, so a
  big fight no longer pauses bounty and kill sync. Messages the game holds back are sent again.
- Hotspots page (/wanted hotspots): the zones where enemy players were seen in the last hour, busiest first,
  with levels, the biggest guild there, PvP deaths and whether it's getting busier. Top zones on the minimap tooltip.
- The Tools page is off by default; turn it on in Settings.
- A note when another player's client reports a newer release (chat, minimap tooltip, bug report).
- Enemy markers now show on the world map, drawn through the map's own pin system so they work alongside other
  map addons such as Leatrix Maps.
- Show or hide the enemy markers from the map's filter menu, the Hotspots page or Settings.
- Nearby window timing: an enemy out of view still shows as in sight for a minute, then shaded for 30 seconds,
  then leaves the list. Both times are in Settings.

## [0.1.0-beta.1] - 2026-09-24

First public beta, for WoW Forever (client 1.60.1).

- Report a bug (/wanted bug): a ready-made report to paste into the GitHub bug report form.

- Bounty board: post bounties on enemy players or whole guilds, raise, withdraw, pass, hunt.
- Claims from your own honorable kills; witnessed by other players' clients; first kill wins.
- Payments by mail, recorded from both sides; unpaid bounties go on the poster's record.
- Reputation from records only: hunter rank and reliability, poster record, leaderboards, guilds.
- Enemy detection: Nearby window, Last hour, Kill on Sight with reasons, Ignore,
  alerts and sounds, stealth alarm, TARGETED warning, wins and losses, enemy statistics.
- World map markers for recent sightings, shared between players running the addon.
- Peer-to-peer sync over a hidden channel with gap filling, limits and a hash-chained record per player.
