#!/usr/bin/env bash
# Body of the beta release notes (docs/updates.md section 13, "Заметки к релизу"), printed to stdout.
#   beta_notes.sh <previous beta manifest.json or ''>
# The previous beta's commit is read from the first line of its English notes ("... commit abc1234)").
# release-notes/beta.txt always holds the whole summary since the previous published beta, so the notes
# are the file as it is now - provided it was committed since that commit (a cancelled run loses nothing,
# an edit of the text before the beta is out makes no duplicates). Unknown previous commit (first beta,
# foreign history) -> the file as it is. Not updated since the previous beta / empty -> exit 1.
# Needs the full history (actions/checkout fetch-depth: 0).
set -euo pipefail

file=release-notes/beta.txt
manifest="${1:-}"
prev=""
if [ -n "$manifest" ] && [ -s "$manifest" ]; then
  prev=$(jq -r '.notes.en // ""' "$manifest" | head -n 1 | sed -n 's/.*commit \([0-9a-f]\{7,40\}\).*/\1/p')
fi

[ -f "$file" ] || exit 1
if [ -n "$prev" ] && git cat-file -e "$prev^{commit}" 2> /dev/null && git merge-base --is-ancestor "$prev" HEAD; then
  [ -n "$(git log -n 1 --format=%H "$prev..HEAD" -- "$file")" ] || exit 1
fi
out=$(sed -e 's/[[:space:]]*$//' "$file")

[ -n "${out//[[:space:]]/}" ] || exit 1
printf '%s\n' "$out"