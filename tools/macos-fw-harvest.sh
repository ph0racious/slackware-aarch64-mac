#!/bin/sh
#
# Copyright 2026  Jim Phoenix, Earth, Milky Way.  Modified BSD terms:
# redistributions must retain this notice.  Full text in LICENSE at the
# slackware-aarch64-mac tree root.
#
# macos-fw-harvest.sh -- capture CURRENT Wi-Fi/Bluetooth firmware from a live
# macOS, for Slackware on Apple Silicon.
#
# RUN THIS IN macOS, NOT IN LINUX.
#
# WHY THIS EXISTS
# ---------------
# The Asahi installer builds its firmware archive from the IPSW of the macOS
# version it pins for its stub (13.5 on an M2 Mac mini) -- it never reads the
# macOS you actually run. So its Wi-Fi and Bluetooth firmware are that
# version's no matter how current macOS is, and updating macOS beforehand does
# not change that.
#
# This script copies the Wi-Fi and Bluetooth firmware from your running macOS
# so the Slackware installer can use it instead. Everything else -- webcam,
# multitouch -- still comes from the Asahi installer's copy. It is optional:
# skip it and the Asahi installer's Wi-Fi and Bluetooth firmware are used too.
#
# WHEN TO RUN IT
# --------------
# AFTER the Asahi installer has finished, while you are still in macOS and
# before you reboot.
#
# It cannot run earlier: Apple Silicon has no FAT EFI partition until the Asahi
# installer creates one, so before that there is nowhere to put the file that
# Linux will later be able to read. (Linux cannot read APFS, so leaving it on
# your macOS volume would not work either.)
#
# WHAT IT TOUCHES
# ---------------
# Reads  /usr/share/firmware        -- read-only; macOS is not modified.
# Writes <ESP>/asahi/all_firmware-live.tar.gz  -- ONE new file.
#
# It never touches m1n1/, never touches the archive the Asahi installer wrote,
# and never formats anything. Deleting that one file undoes it completely.
#
# Usage:
#   sudo sh macos-fw-harvest.sh          capture
#   sudo sh macos-fw-harvest.sh --remove delete the captured file
#
# (Run it straight off the Slackware install medium -- macOS can read it.)

set -u

FWSRC=/usr/share/firmware
OUTNAME=all_firmware-live.tar.gz
MODE=capture

for a in "$@"; do
  case "$a" in
    --remove)  MODE=remove ;;
    -h|--help) sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "macos-fw-harvest: unknown argument: $a (try --help)" >&2; exit 2 ;;
  esac
done

die()  { echo "macos-fw-harvest: $*" >&2; exit 1; }
info() { echo "  $*"; }

[ "$(id -u)" = 0 ] || die "must be run with sudo -- mounting the EFI partition needs root"
[ "$(uname -s)" = Darwin ] || die "this runs in macOS, not in Linux"

# FIND THE ESP BY WHAT IS ON IT, NOT BY DEVICE NODE.
#
# Disk numbering is not stable across machines and a Mac can have several EFI
# partitions (external disks, other installs). The one wanted is the one the
# Asahi installer built, and the honest test for that is that it carries both
# asahi/ and m1n1/. Mount candidates read-write only as far as needed and leave
# anything already mounted where it was.
find_esp() {
  for _id in $(diskutil list 2>/dev/null | grep -w EFI | awk '{print $NF}'); do
    _mp=$(diskutil info "$_id" 2>/dev/null \
          | awk -F: '/Mount Point/ {sub(/^[ \t]+/,"",$2); print $2; exit}')
    if [ -z "$_mp" ]; then
      diskutil mount "$_id" >/dev/null 2>&1 || continue
      _mp=$(diskutil info "$_id" 2>/dev/null \
            | awk -F: '/Mount Point/ {sub(/^[ \t]+/,"",$2); print $2; exit}')
    fi
    [ -n "$_mp" ] || continue
    if [ -d "$_mp/asahi" ] && [ -d "$_mp/m1n1" ]; then
      echo "$_mp"
      return 0
    fi
  done
  return 1
}

ESP=$(find_esp) || die "could not find an Asahi EFI partition.

  Looked for an EFI partition containing both asahi/ and m1n1/, and found none.
  The overwhelmingly likely reason is that THE ASAHI INSTALLER HAS NOT RUN YET.

  Run the Asahi installer first, then -- before rebooting -- run this again."

info "EFI partition: $ESP"

# ---- remove ---------------------------------------------------------------
if [ "$MODE" = remove ]; then
  [ -f "$ESP/asahi/$OUTNAME" ] || die "$ESP/asahi/$OUTNAME is not there -- nothing to remove"
  rm -f "$ESP/asahi/$OUTNAME"
  info "removed $ESP/asahi/$OUTNAME"
  exit 0
fi

# ---- capture --------------------------------------------------------------
[ -d "$FWSRC/wifi" ] || die "$FWSRC/wifi does not exist -- is this really macOS?"

# Space first. The ESP is small and shared with the bootloader; filling it is a
# far worse outcome than not running at all.
NEED_KB=120000
FREE_KB=$(df -k "$ESP" 2>/dev/null | awk 'NR==2 {print $4}')
case "$FREE_KB" in
  ''|*[!0-9]*) die "could not read free space on $ESP" ;;
esac
[ "$FREE_KB" -ge "$NEED_KB" ] \
  || die "only $((FREE_KB / 1024)) MB free on $ESP; want at least $((NEED_KB / 1024)) MB.
  Refusing rather than risk filling the partition that holds the bootloader."

info "free on ESP: $((FREE_KB / 1024)) MB"
info "macOS: $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"

# WRITE TO A TEMPORARY NAME AND RENAME.
#
# The Slackware installer picks this file up AUTOMATICALLY and without asking.
# A half-written archive left by an interrupted run would therefore be found and
# used on the next install. Renaming into place means the final name only ever
# exists once the archive is complete.
TMP="$ESP/asahi/.$OUTNAME.part"
OUT="$ESP/asahi/$OUTNAME"
rm -f "$TMP"

info "capturing wifi/ and bluetooth/ from $FWSRC ..."
if ! tar czf "$TMP" -C "$(dirname "$FWSRC")" \
       "$(basename "$FWSRC")/wifi" "$(basename "$FWSRC")/bluetooth" 2>/dev/null; then
  rm -f "$TMP"
  die "tar failed -- nothing was written"
fi

# Sanity-check before it is given the real name.
if ! tar tzf "$TMP" >/dev/null 2>&1; then
  rm -f "$TMP"
  die "the archive did not verify -- nothing was written"
fi
NFILES=$(tar tzf "$TMP" 2>/dev/null | wc -l | tr -d ' ')
if [ "$NFILES" -lt 100 ]; then
  rm -f "$TMP"
  die "only $NFILES entries captured, which cannot be right -- nothing was written"
fi

mv "$TMP" "$OUT" || { rm -f "$TMP"; die "could not put the archive in place"; }

info "wrote $OUT"
info "  entries : $NFILES"
info "  size    : $(du -h "$OUT" 2>/dev/null | awk '{print $1}')"

# DELIBERATELY NOT REPORTING A FIRMWARE BUILD DATE HERE.
#
# The temptation is to grep a version string out of one of the captured blobs.
# Doing that correctly means knowing which chip THIS Mac uses, because a vendor
# tree carries firmware for every Mac and an old model's blob can legitimately
# be years older than the tree shipping it. Sampling the wrong file would print
# a scary or falsely reassuring date.
#
# The Linux side already resolves the right chip from the driver's own
# "using brcm/... for chip ..." line, so let it be the thing that says a date.
echo
info "Done."
