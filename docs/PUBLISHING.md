# Publishing

Releases are built by the [BigWigs packager](https://github.com/BigWigsMods/packager) when a `v*` tag is
pushed. It reads `## Interface: 16001` from the toc (interfaces starting `16` map to CurseForge's
**Forever** game type), replaces `@project-version@` with the tag, leaves out what `.pkgmeta` ignores,
posts that version's section of `CHANGELOG.md` as the release notes (`.github/release-notes.sh`), and uploads `WantedDeadOrDead-<tag>.zip` to CurseForge and a
GitHub release. Until a CurseForge project ID and token exist, it only makes the GitHub release.

## One-time CurseForge setup

1. Sign in at <https://authors.curseforge.com> and create a project:
   - Game: World of Warcraft. Game version / flavor: **Forever**.
   - Name: `Wanted: Dead or... Dead`. Slug suggestion: `wanted-dead-or-dead`.
   - Summary (short line): "[Beta] World PvP bounties, enemy awareness and reputation for WoW Forever,
     shared player to player."
   - Description: the short beta line, then the Features and How it works sections of `README.md`.
   - Issues URL: <https://github.com/wanteddeadordead/wanted-dead-or-dead/issues> (so CurseForge's "Issues" link
     goes to the bug report form).
   - Primary category: PvP. Secondary: Combat, Chat & Communication.
   - License: MIT.
   - Logo: `docs/media/logo.png` (400 x 400), the wax seal; `docs/media/seal-1024.png` is the transparent master.
   - Source: <https://github.com/wanteddeadordead/wanted-dead-or-dead>, issues on the same repository.
   CurseForge reviews new projects before they go public (usually within a few days).
2. Put the project ID into `WantedDeadOrDead.toc` as `## X-Curse-Project-ID: <id>` and commit it.
3. Create an API token at <https://authors.curseforge.com/account/api-tokens>, then add it to this
   repository as the Actions secret `CF_API_KEY` (Settings > Secrets and variables > Actions).

All addons must be free under Blizzard's UI Add-On Development Policy; this one has no paid tier.

## Versions

1.0.0 was the first stable release (the betas were `v0.1.0-beta.1` to `v0.1.0-beta.8`). `Wanted.BETA` in
`Core.lua` is now false: no BETA label or beta welcome. Stable releases use plain tags (`v1.0.1`, `v1.1.0`),
which CurseForge labels Release; a `-beta.N` suffix still makes a Beta file for a test build.
Bump the patch number for fixes, the minor for new features, and the major for a change that breaks saved
data or the network protocol for older versions.

## Releasing

1. `lua tests/smoke_test.lua` passes.
2. In `CHANGELOG.md`, move the `[Unreleased]` notes under a new `## [x.y.z] - YYYY-MM-DD` heading.
3. Commit, then `git tag vx.y.z && git push origin main vx.y.z` (a plain tag is not pushed by `--follow-tags`).
4. Use `-beta.1` or `-alpha.1` tag suffixes for test builds; the packager marks them on CurseForge.

## Installing from a local checkout

Copy (or link) the repository folder into `Interface\AddOns\` under the name `WantedDeadOrDead`.
Saved data is stored per folder name, so an earlier install under another folder name keeps its data in
that name's saved-variables file; copy `WTF\Account\<account>\SavedVariables\<old>.lua` to
`WantedDeadOrDead.lua` once, with the game closed, to bring it across.
