#!/usr/bin/env bash
# Writes RELEASE_NOTES.md, the release notes the packager posts to CurseForge and GitHub: the CHANGELOG.md
# section for the version being released (the tag without its "v"), or with no tag the newest released one.
# The empty "Unreleased" placeholder and older versions are left out.
set -euo pipefail
version="${1:-}"
version="${version#v}"
awk -v want="$version" '
	/^## \[/ {
		name = $0
		sub(/^## \[/, "", name)
		sub(/\].*/, "", name)
		if (printing) exit
		if (name != "Unreleased" && (want == "" || name == want)) printing = 1
	}
	printing { print }
' CHANGELOG.md > RELEASE_NOTES.md
test -s RELEASE_NOTES.md || { echo "CHANGELOG.md has no section for ${version:-a release}" >&2; exit 1; }
cat RELEASE_NOTES.md
