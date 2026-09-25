# Security Policy

## Reporting a vulnerability

Please report security problems privately through GitHub: open the repository's **Security** tab and
choose **Report a vulnerability**. Please don't open a public issue for them.

Include what you found, how to reproduce it, and the addon version. You will get a reply within a week.

## Scope

The addon runs inside the World of Warcraft client with the permissions every addon has. It sends and
receives data only through the game's addon messages on a hidden custom chat channel, between players
running it on the same faction. It never posts in public chat channels, and it never reads or sends
anything outside the game. Incoming messages are size-limited, rate-limited per sender, validated
before they are stored, and can't impersonate another player (the game stamps each sender's name).
