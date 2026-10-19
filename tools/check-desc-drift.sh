#!/bin/bash
#
# check-desc-drift.sh -- does the package description ON THE MEDIA still match
# the slack-desc in the source tree?
#
# WHY THIS EXISTS
# ---------------
# A package embeds its slack-desc at build time. Edit the slack-desc afterwards
# and the built .txz keeps the old text -- silently, because a description-only
# change triggers no rebuild and breaks no test.
#
# It matters more here than usual. Every package but the kernel and the boot
# firmware is tagged REC rather than ADD, and the justification for that is
# that each description says what the package is for, and the ones the
# hardware cannot do without say so plainly, in front of anyone deselecting
# them. A stale description drops exactly those "REQUIRED ..." lines: the
# tagging ships, the reasoning behind it does not.
#
# Nothing else catches this. The packages install, the tagfiles are right, the
# install completes, and the system boots. The only symptom is a user reading
# the wrong text at the one moment it matters.
#
# Usage:
#   tools/check-desc-drift.sh                    # against the built ISO
#
# Exit 1 if anything has drifted or could not be checked, so it can gate media
# builds.

set -u
. "$(dirname "$0")/build-paths.sh"
ISO=$ISO_MAC
SRC=$(cd "$(dirname "$0")/../source" && pwd)
T=/slackware/slackwareaarch64-current/slackware
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

[ -r "$ISO" ] || { echo "no ISO at $ISO" >&2; exit 1; }

# The source directory is usually the package name, but not always: our
# pipewire rebuild lives in source/pipewire-lv2/ and builds a package called
# "pipewire", and kernel_armv8-mac-headers comes out of the kernel build.
# Resolve by finding the slack-desc that actually declares this package.
#
# Note the glob covers slack-desc AND slack-desc-*: one SlackBuild can emit
# several packages with different descriptions (the kernel SlackBuild writes
# slack-desc for the kernel and slack-desc-headers for the headers package).
# Matching only "slack-desc" leaves the headers package permanently "unchecked"
# -- a package silently exempt from the gate, which is worse than no gate.
find_desc() {
  local name=$1 d
  for d in "$SRC"/*/slack-desc "$SRC"/*/slack-desc-*; do
    [ -r "$d" ] && grep -qE "^${name}:" "$d" && { echo "$d"; return 0; }
  done
  return 1
}

drift=0; match=0; skip=0
for p in $(xorriso -indev "$ISO" -find "$T" -name '*_mac.txz' 2>/dev/null \
           | grep -a "^'/" | tr -d "'"); do
  base=$(basename "$p" .txz)
  name=$(echo "$base" | sed 's/-[^-]*-[^-]*-[^-]*$//')

  desc=$(find_desc "$name") || {
    printf "  %-26s no source slack-desc found\n" "$name"; skip=$((skip+1)); continue; }

  xorriso -osirrox on -indev "$ISO" -extract "${p%.txz}.txt" "$W/media.txt" >/dev/null 2>&1
  [ -s "$W/media.txt" ] || {
    printf "  %-26s no .txt on media\n" "$name"; skip=$((skip+1)); continue; }

  # Compare only the payload lines; the handy-ruler comment is not shipped.
  grep -E "^${name}:" "$desc"        | sed 's/[[:space:]]*$//' > "$W/src.lines"
  grep -E "^${name}:" "$W/media.txt" | sed 's/[[:space:]]*$//' > "$W/med.lines"

  if diff -q "$W/src.lines" "$W/med.lines" >/dev/null 2>&1; then
    match=$((match+1))
  else
    drift=$((drift+1))
    printf "  %-26s STALE on media\n" "$name"
    diff "$W/src.lines" "$W/med.lines" | grep '^[<>]' | head -4 | sed 's/^/       /'
  fi
  rm -f "$W/media.txt" "$W/src.lines" "$W/med.lines"
done

echo
echo "  $match current, $drift stale, $skip unchecked"
if [ "$drift" -gt 0 ]; then
  echo
  echo "  Rebuild the stale packages and rebuild the media. A slack-desc edit"
  echo "  does not reach users until the package itself is rebuilt."
  exit 1
fi
# An unchecked package is exempt from the gate, which is worse than no gate;
# so is a run that found nothing to check.
if [ "$skip" -gt 0 ]; then
  echo
  echo "  Every package must be checked: give each one a slack-desc in source/,"
  echo "  and find out why any .txt is missing from the media."
  exit 1
fi
if [ "$match" -eq 0 ]; then
  echo
  echo "  No package of this port was found on $ISO, so nothing was checked."
  exit 1
fi
