#!/usr/bin/env bash
# Body of the beta release notes (docs/updates.md section 13, "Заметки к релизу"), printed to stdout.
#   beta_notes.sh <previous beta manifest.json or ''>
# The previous beta's commit is read from the first line of its English notes ("... commit abc1234)").
# Notes = every version of release-notes/beta.txt committed since that commit, newest first (a beta
# run cancelled by a newer push loses nothing). Unknown previous commit (first beta, foreign history)
# -> the file as it is. Nothing (the file was not updated / is empty) -> exit 1.
# Needs the full history (actions/checkout fetch-depth: 0).
set -euo pipefail

file=release-notes/beta.txt
manifest="${1:-}"
prev=""
if [ -n "$manifest" ] && [ -s "$manifest" ]; then
  prev=$(jq -r '.notes.en // ""' "$manifest" | head -n 1 | sed -n 's/.*commit \([0-9a-f]\{7,40\}\).*/\1/p')
fi

trimmed() { sed -e 's/[[:space:]]*$//'; }
out=""
if [ -n "$prev" ] && git cat-file -e "$prev^{commit}" 2> /dev/null && git merge-base --is-ancestor "$prev" HEAD; then
  seen=()
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    body=$(git show "$h:$file" 2> /dev/null | trimmed) || continue
    [ -n "${body//[[:space:]]/}" ] || continue
    dup=false
    for s in "${seen[@]+"${seen[@]}"}"; do [ "$s" = "$body" ] && dup=true; done
    $dup && continue
    seen+=("$body")
    out+="${out:+$'\n\n'}$body"
  done < <(git log --format=%H "$prev..HEAD" -- "$file")
elif [ -f "$file" ]; then
  out=$(trimmed < "$file")
fi

[ -n "${out//[[:space:]]/}" ] || exit 1
printf '%s\n' "$out"
