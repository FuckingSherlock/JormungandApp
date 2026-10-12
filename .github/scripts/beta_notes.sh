#!/usr/bin/env bash
# Body of the beta release notes (docs/updates.md section 13, "Заметки к релизу"), printed to stdout.
#   beta_notes.sh <previous beta manifest.json or ''>
# The previous beta's commit is read from the first line of its English notes ("... commit abc1234)").
# Notes = every version of release-notes/beta.txt committed since that commit, newest first (a beta
# run cancelled by a newer push loses nothing). None -> the subjects of the commits since then.
# Unknown previous commit (first beta, foreign history) -> only HEAD is considered.
# Needs the full history (actions/checkout fetch-depth: 0).
set -euo pipefail

file=release-notes/beta.txt
manifest="${1:-}"
prev=""
if [ -n "$manifest" ] && [ -s "$manifest" ]; then
  prev=$(jq -r '.notes.en // ""' "$manifest" | head -n 1 | sed -n 's/.*commit \([0-9a-f]\{7,40\}\).*/\1/p')
fi
if [ -n "$prev" ] && git cat-file -e "$prev^{commit}" 2> /dev/null && git merge-base --is-ancestor "$prev" HEAD; then
  range="$prev..HEAD"
else
  range="HEAD~1..HEAD"
  git rev-parse -q --verify HEAD~1 > /dev/null || range="HEAD"
fi

out=""
seen=()
while IFS= read -r h; do
  [ -n "$h" ] || continue
  body=$(git show "$h:$file" 2> /dev/null | sed -e 's/[[:space:]]*$//') || continue
  [ -n "${body//[[:space:]]/}" ] || continue
  dup=false
  for s in "${seen[@]+"${seen[@]}"}"; do [ "$s" = "$body" ] && dup=true; done
  $dup && continue
  seen+=("$body")
  out+="${out:+$'\n\n'}$body"
done < <(git log --format=%H "$range" -- "$file")

if [ -z "$out" ]; then
  max=15
  mapfile -t subj < <(git log --no-merges --format=%s "$range" | cut -c1-200)
  if [ "${#subj[@]}" -eq 0 ]; then
    mapfile -t subj < <(git log -1 --format=%s | cut -c1-200)
  fi
  for ((i = 0; i < ${#subj[@]} && i < max; i++)); do out+="${out:+$'\n'}• ${subj[$i]}"; done
  if [ "${#subj[@]}" -gt "$max" ]; then out+=$'\n'"… and $((${#subj[@]} - max)) more"; fi
fi
printf '%s\n' "$out"
