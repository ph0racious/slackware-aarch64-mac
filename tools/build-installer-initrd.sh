#!/bin/bash
#
# build-installer-initrd.sh -- take Slackware's stock installer initrd and make
# it run on this port's kernel, with the few carried patches docs/PORTING.md
# lists ("Carried patches to the installer").
#
# WHY
# ---
# Slackware's installer cannot run on Apple Silicon: its kernel cannot run this
# hardware (it has no Apple watchdog driver, and it is a 4K-page build). The
# installer itself is fine -- it is only the kernel underneath that cannot run.
#
# So the kernel is swapped and the one thing tied to it is adjusted: the module
# tree under lib/modules. Beyond that, the only changes are the carried patches
# below -- the filesystems SeTpartitions offers and load_kernel_modules loads,
# sbin/probe, the medium-label greps under usr/lib/setup, and the boot-loader
# step in 000-grub-configure -- each failing loudly if its anchor moves, and
# two files rendered from installer-text/: the GRUB template, which replaces
# stock's template-grub.cfg, and the boot-loader screen's text.
# usr/lib/setup/setup itself, pkgtools and dialog are left exactly as
# Slackware ships them: the installer should behave normally, per-package
# selection and all.
#
# TWO TRAPS
# ---------
# 1. The installer initrd is **xz**-compressed (magic fd377a58), and the
#    kernel's initramfs decoder accepts xz only with a CRC32 check or none.
#    xz's default is CRC64, so a plain `xz -9` repack is an initrd the kernel
#    cannot read. It logs "Initramfs unpacking failed: Input was encoded with
#    settings that are not supported by this XZ decoder" early in boot, and
#    the boot then stops at a root-mount panic that does not name the initrd.
#    This script repacks with `xz --check=crc32`, as stock's initrd is.
#    (Slackware ARM's scripts/repack_initrd is no shortcut: it is for the OS
#    initrd, which is gzip, and its zcat cannot unpack this one.)
#
# 2. A module tree whose version does not match the running kernel is not an
#    error -- modprobe simply finds nothing. The installer boots, then cannot
#    see storage or network, and looks broken for unrelated reasons. This
#    script refuses to produce output unless the two match.
#
# Note 'root=/dev/ram' in Slackware's grub.cfg is vestigial: the initrd is a
# cpio archive, so the kernel unpacks it into rootfs and runs /init, ignoring
# root=. (Slackware's own kernel sets BLK_DEV_RAM_SIZE=4096 -- a 4 MB ramdisk,
# far too small for this initrd, which confirms it is not used that way.)
# So no CONFIG_BLK_DEV_RAM is required here.
#
# WHERE THIS RUNS: on the aarch64 Slackware host you are building on, with
# kernel_armv8-mac already installed. It needs cpio, xz and depmod, and it needs
# the *-armv8-mac module tree to package -- which is why the kernel package must
# be installed here first, not merely built.

set -euo pipefail

SRC=""
# The output is where build-installer-iso.sh reads it. W_DIR comes from
# build-paths.sh, read in a subshell: that file also defines WORK, which this
# script uses as scratch and removes.
OUT=$( . "$(dirname "$0")/build-paths.sh"; echo "$W_DIR" )/initrd-mac.img
# Scratch, removed on exit. Not a fixed name: this runs as root, and a fixed
# path under /tmp is one another user can create first.
WORK=$(mktemp -d /tmp/initrd-work.XXXXXX) \
  || { echo "build-installer-initrd: cannot create a scratch directory" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

usage() {
  cat <<EOF
usage: build-installer-initrd.sh -s ORIGINAL_INITRD

  -s   Slackware's stock installer initrd (boot/initrd-armv8.img from the ISO)

It packages the newest *-armv8-mac module tree under /lib/modules, and writes
$OUT.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -s) SRC=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

die() { echo "build-installer-initrd: $*" >&2; exit 1; }
info() { echo "  $*"; }

[ -n "$SRC" ] || { usage; exit 2; }
[ -f "$SRC" ] || die "no such initrd: $SRC"
# Absolute, because this script cd's into its work directory before
# unpacking; a relative -s would then fail with "xz: <name>: No such file or
# directory", which reads as a corrupt source rather than a path that moved.
SRC=$(readlink -f "$SRC")
mkdir -p "$(dirname "$OUT")"
for t in cpio xz depmod; do
  command -v $t >/dev/null 2>&1 || die "need $t.
  This must run on the aarch64 Slackware host where kernel_armv8-mac is
  installed -- it packages that kernel's module tree, so depmod must see it."
done

# Pick the kernel version: it must be this port's, never the
# build host's own.
#
# MATCH BY THE PLATFORM TOKEN, NEVER BY A VERSION HEURISTIC. A filter phrased as
# "not Slackware's version" is a guess about what else happens to be installed,
# and when it guesses wrong it does not fail -- it falls through to `uname -r`
# and builds the installer around the build host's own running kernel. That
# produces a plausible-looking image that finds no hardware at all, which is the
# exact failure this script exists to refuse.
#
# `-armv8-mac` is the name this port's kernel package installs under, so it is the thing
# to match. If it is absent, stop: there is nothing here to build an installer
# from, and any fallback is a wrong answer delivered confidently.
avail=$(ls -1d /lib/modules/*/ 2>/dev/null | xargs -r -n1 basename)
KVER=$(echo "$avail" | grep -E -- '-armv8-mac$' | sort -V | tail -1)
[ -n "$KVER" ] || die "no -armv8-mac module tree under /lib/modules.
Available:
$(echo "$avail" | sed 's/^/    /')
  Install kernel_armv8-mac here. Guessing builds an installer that finds no
  hardware."
info "target kernel : $KVER"

# The source must actually be xz. If Slackware ever changes it, notice here
# rather than producing something subtly wrong.
magic=$(head -c4 "$SRC" | od -An -tx1 | tr -d ' \n')
case "$magic" in
  fd377a58) info "source format : xz (as expected)" ;;
  1f8b*)    die "source is gzip, not xz -- Slackware changed format; update this script" ;;
  *)        die "unrecognised initrd magic '$magic'" ;;
esac

mkdir -p "$WORK/root"
info "unpacking     : $SRC ($(stat -c%s "$SRC") bytes)"
( cd "$WORK/root" && xz -dc "$SRC" | cpio -idm --quiet )

# Sanity: this must actually be the Slackware installer, not some other initrd.
[ -x "$WORK/root/usr/lib/setup/setup" ] || [ -f "$WORK/root/usr/lib/setup/setup" ] \
  || die "no usr/lib/setup/setup in this initrd -- is it really the installer?"
info "installer     : usr/lib/setup/setup present ($(ls "$WORK/root/usr/lib/setup" | wc -l) setup files)"

OLDVERS=$(ls -1 "$WORK/root/lib/modules" 2>/dev/null || true)
info "stock modules : ${OLDVERS:-<none>}"

# Swap the module tree. Remove ALL stock versions: leaving one behind means a
# tree that does not match the running kernel, which is the silent-failure case
# this script exists to prevent.
rm -rf "$WORK/root/lib/modules"
mkdir -p "$WORK/root/lib/modules"
cp -a "/lib/modules/$KVER" "$WORK/root/lib/modules/$KVER"
# Build artefacts are large and useless in an initrd.
rm -rf "$WORK/root/lib/modules/$KVER/build" "$WORK/root/lib/modules/$KVER/source"
depmod -b "$WORK/root" "$KVER" 2>/dev/null || die "depmod failed for $KVER"
info "new modules   : $KVER ($(find "$WORK/root/lib/modules/$KVER" -name '*.ko*' | wc -l) modules)"

# GATE: exactly one module tree, and it is the intended one.
n=$(ls -1 "$WORK/root/lib/modules" | wc -l)
[ "$n" -eq 1 ] || die "expected exactly 1 module tree, found $n"
[ -d "$WORK/root/lib/modules/$KVER" ] || die "module tree is not $KVER"
[ -s "$WORK/root/lib/modules/$KVER/modules.dep" ] || die "depmod produced no modules.dep"

# ---- jfs and f2fs (begin) --------------------------------------------------
# CARRIED PATCH: setup stops offering JFS and F2FS, as Slackware stopped
# offering reiserfs and bcachefs. Neither can hold a root on this 16K-page
# kernel:
#
#   F2FS  the kernel mounts only F2FS made with 16K blocks, and GRUB's F2FS
#         driver reads only 4K ones (F2FS_BLK_BITS 12). This base's mkfs.f2fs
#         makes only 4K, so no F2FS root can boot. The kernel keeps stock's
#         module.
#   JFS   memory compaction migrating JFS metadata pages crashes this kernel
#         (a NULL dereference in remove_metapage), and GRUB could not read a
#         kernel written to JFS. The kernel leaves JFS out entirely
#         (migrate-kernel-config.sh, DISABLE).
#
# Both halves of how stock did it:
#   - Pat's, in SeTpartitions: the block that offers each one is commented
#     out, with its reason, as he did for reiserfs and bcachefs.
#   - Stuart's, in load_kernel_modules: each is dropped from MOD_FS, the old
#     line kept commented, as he did for reiserfs and bcachefs.
# The screen "SELECT FILESYSTEM FOR <partition>" then offers ext2 ext3 ext4
# btrfs xfs (installer-text/SCREENS.md, screen 2). Each replacement is exact,
# and refuses if Slackware's text has moved. This runs before the gate below,
# so the gate checks the MOD_FS that ships.
#
# Drop it when a 16K-page kernel and GRUB can both use them.
# ---------------------------------------------------------------------------
info "filesystems   : setup stops offering jfs and f2fs (no root on 16K pages)"
python3 - "$WORK/root" <<'PYEOF' || die "jfs/f2fs patch failed"
import io, os, sys
root = sys.argv[1]
TAG = "# CARRIED PATCH (Slackware on Apple Silicon): "

EDITS = [
  ("usr/lib/setup/SeTpartitions",
   "  if grep -wq f2fs /proc/filesystems 1> $NDIR 2> $NDIR ; then\n"
   "    F2FS=\"F2FS is a Flash-Friendly File System. \"\n"
   "  fi\n",
   "  " + TAG + "not offered. On 16K pages the\n"
   "  # kernel mounts only 16K-block F2FS, which GRUB cannot read:\n"
   "  #if grep -wq f2fs /proc/filesystems 1> $NDIR 2> $NDIR ; then\n"
   "  #  F2FS=\"F2FS is a Flash-Friendly File System. \"\n"
   "  #fi\n"),
  ("usr/lib/setup/SeTpartitions",
   "  if grep -wq jfs /proc/filesystems 1> $NDIR 2> $NDIR ; then\n"
   "    JFS=\"JFS is IBM's Journaled Filesystem, currently used in IBM enterprise servers. \"\n"
   "  fi\n",
   "  " + TAG + "not offered. JFS crashes this\n"
   "  # 16K-page kernel, and GRUB could not read a kernel written to it:\n"
   "  #if grep -wq jfs /proc/filesystems 1> $NDIR 2> $NDIR ; then\n"
   "  #  JFS=\"JFS is IBM's Journaled Filesystem, currently used in IBM enterprise servers. \"\n"
   "  #fi\n"),
  ("load_kernel_modules",
   "\nexport MOD_FS=\"vfat ext2 ext3 ext4 btrfs jfs xfs f2fs\"\n",
   "\n" + TAG + "jfs and f2fs dropped. Neither can\n"
   "# hold a root on this 16K-page kernel (see SeTpartitions), and setup offers\n"
   "# what this list loads.\n"
   "#export MOD_FS=\"vfat ext2 ext3 ext4 btrfs jfs xfs f2fs\"\n"
   "export MOD_FS=\"vfat ext2 ext3 ext4 btrfs xfs\"\n"),
]

for rel, old, new in EDITS:
    p = os.path.join(root, rel)
    s = io.open(p, encoding="utf-8", errors="surrogateescape").read()
    n = s.count(old)
    if n == 1:
        s = s.replace(old, new, 1)
        io.open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
        print("  patched %s" % rel)
    elif n == 0 and new in s:
        print("  %s: already patched" % rel)
    else:
        sys.exit("%s: expected exactly one copy of\n\n%s\n\n  and found %d. Slackware changed its filesystem list. Re-read\n"
                 "  it before shipping: setup may otherwise offer a root this kernel\n"
                 "  cannot boot." % (rel, old.strip("\n"), n))
PYEOF
if grep -qE '^[[:space:]]*if grep -wq (jfs|f2fs) /proc/filesystems' "$WORK/root/usr/lib/setup/SeTpartitions"; then
  die "SeTpartitions still offers jfs or f2fs after the patch"
fi
[ "$(sed -nE 's/^[[:space:]]*export MOD_FS="([^"]*)".*/\1/p' "$WORK/root/load_kernel_modules")" = "vfat ext2 ext3 ext4 btrfs xfs" ] \
  || die "load_kernel_modules does not export MOD_FS=\"vfat ext2 ext3 ext4 btrfs xfs\" after the patch"
# ---- jfs and f2fs (end) ----------------------------------------------------

# ---- root filesystems (begin) ----------------------------------------------
# GATE: EVERY FILESYSTEM SETUP OFFERS FOR / IS BUILT INTO THIS KERNEL.
#
# The installer's load_kernel_modules loads each module in its MOD_FS, and
# setup then offers every filesystem /proc/filesystems lists. This kernel boots
# with no initrd, so a root filesystem it has only as a module installs
# cleanly and then cannot be mounted at the first boot. Read the list from the
# installer as it ships (stock's, less jfs and f2fs, which the patch above
# drops) rather than typing it, and check each against the config of the
# kernel this initrd is built for.
LKM=$WORK/root/load_kernel_modules
[ -r "$LKM" ] || die "no load_kernel_modules in this initrd, so the filesystems
  setup offers cannot be read"
MOD_FS=$(sed -nE 's/^[[:space:]]*export MOD_FS="([^"]*)".*/\1/p' "$LKM" | head -1)
[ -n "$MOD_FS" ] || die "cannot read MOD_FS from load_kernel_modules; Slackware
  changed how the installer lists its filesystems. Re-check before shipping."
KCFG=/boot/config-armv8-mac-$KVER
[ -r "$KCFG" ] || die "no $KCFG; install kernel_armv8-mac here first"
fs_builtin() {
  case "$1" in
    vfat)      return 0 ;;   # the ESP's, not offered for /
    ext2)      grep -qxE 'CONFIG_EXT2_FS=y|CONFIG_EXT4_USE_FOR_EXT2=y' "$KCFG" ;;
    ext3|ext4) grep -qx 'CONFIG_EXT4_FS=y' "$KCFG" ;;
    *)         grep -qx "CONFIG_$(echo "$1" | tr 'a-z' 'A-Z')_FS=y" "$KCFG" ;;
  esac
}
fs_missing=""
for fs in $MOD_FS; do
  fs_builtin "$fs" || fs_missing="$fs_missing $fs"
done
[ -z "$fs_missing" ] || die "setup offers these root filesystems, and $KVER has
  them only as modules or not at all:$fs_missing
  With no initrd, a root on one of them installs and then cannot mount at boot.
  Build them in (tools/migrate-kernel-config.sh, ADDED_ENABLE), or stop setup
  offering them, as the jfs and f2fs patch above does."
info "root fs       : $MOD_FS (all built in)"
# ---- root filesystems (end) ------------------------------------------------

# ---------------------------------------------------------------------------
# USER-FACING TEXT LIVES IN installer-text/, NOT IN THIS SCRIPT.
#
# Every screen this port writes words for is a file in installer-text/, and
# this script decides only WHERE each one lands and WHICH piece of the
# installer displays it. The screens this port changes without new words are
# not files: build-installer-iso.sh writes the medium's boot menu and the
# package checklists, and the jfs/f2fs patch above trims setup's filesystem
# menu.
#
# EDITS ONLY. There is no file for a screen left alone.
#
# usr/lib/setup/setup is UNPATCHED. The boot-loader work happens in
# 000-grub-configure, patched below.
# ---------------------------------------------------------------------------
. "$(dirname "$0")/installer-text.sh"
TEXTDIR=$(cd "$(dirname "$0")/../installer-text" 2>/dev/null && pwd)
{ [ -n "$TEXTDIR" ] && [ -d "$TEXTDIR" ]; } \
  || die "no installer-text/ directory beside tools/.
  Every screen the installer shows on this platform comes from there, so a
  medium built without it would show blank space where warnings belong."

# %GRUBCONF% RESOLVES TO $T_PX/boot/grub/grub.cfg, AND $T_PX IS A LITERAL.
#
# installer-text.sh hardcodes /mnt because usr/lib/setup/setup hardcodes
# T_PX="/mnt". Check that here rather than in the constant's comment: this is
# the one place in the build that has the real `setup` open in front of it, and
# a wrong path in this message sends the operator to edit a file that does not
# exist on a machine that will not boot until they edit the one that does.
_tpx=$(sed -n 's/^T_PX="\(.*\)"$/\1/p' "$WORK/root/usr/lib/setup/setup" | head -1)
[ "${_tpx:-}" = "${IT_GRUBCONF%/boot/grub/grub.cfg}" ] \
  || die "setup sets T_PX=\"${_tpx:-<not found>}\" but IT_GRUBCONF is $IT_GRUBCONF.
  Slackware changed where the target is mounted. Update IT_GRUBCONF in
  tools/installer-text.sh -- every screen naming the GRUB config is wrong
  until you do."

# EVERY SCREEN THIS SCRIPT ADDS MUST BE IN SCREENS.md.
#
# A `dialog` added here changes what a Slackware user sees during setup, and
# SCREENS.md is what that text is vetted from. So derive the count rather than
# trusting anyone to remember: the dialogs injected below must match the
# screens SCREENS.md documents as being drawn by one (its "Drawn by" rows).
# Anchored to the injected form -- an indented `dialog` command inside one of
# the heredocs below. A looser pattern matches this very line and counts itself.
# `|| true`, never `|| echo 0`: grep -c already prints 0 on no match -- it just
# exits 1 -- so `|| echo 0` yields "0" twice and the comparison fails. And under
# set -e a bare zero count would kill the build here, silently.
_dlg=$(grep -cE '^[[:space:]]+dialog[[:space:]]' "$0" || true)
_doc=$(grep -c '^| Drawn by |' "$TEXTDIR/SCREENS.md" 2>/dev/null || true)
_doc=${_doc:-0}
if [ "$_dlg" != "$_doc" ]; then
  die "this script injects $_dlg dialog(s) but SCREENS.md documents $_doc.
  Every screen the installer draws has to be in installer-text/SCREENS.md --
  that file is what the wording is reviewed from, and a screen missing from it
  reaches a user unreviewed. Add it there (with a 'Drawn by' row), or drop the
  dialog."
fi
info "installer text: $TEXTDIR  ($_dlg dialog(s), all in SCREENS.md; %GRUBCONF% -> $IT_GRUBCONF)"
while IFS=$'\t' read -r dest src kind; do
  [ -s "$TEXTDIR/$src" ] || die "installer-text/$src is missing or empty.
  Every file in installer-text/ is a screen we deliberately change; if a screen
  should keep Slackware's own text, delete the file and its patch rather than
  shipping an empty one, which would blank the screen."
  it_check "$TEXTDIR/$src" "$kind" || die "installer-text/$src cannot ship as written (see above)"
  mkdir -p "$WORK/root/$(dirname "$dest")"
  it_render "$TEXTDIR/$src" > "$WORK/root/$dest"
  chmod 644 "$WORK/root/$dest"
  printf '    %-38s <- %-22s %-6s %s lines\n' \
    "$dest" "$src" "$kind" "$(wc -l < "$WORK/root/$dest")"
done < <(it_map)

# usr/lib/setup/setup MUST BE UNTOUCHED, AND THIS PROVES IT.
#
# The correct number of changes to Slackware's `setup` is zero, and an
# assertion is the only way that stays true.
_stock_setup=$(mktemp)
xz -dc "$SRC" | cpio -i --to-stdout --quiet '*usr/lib/setup/setup' > "$_stock_setup" 2>/dev/null
if ! cmp -s "$_stock_setup" "$WORK/root/usr/lib/setup/setup"; then
  rm -f "$_stock_setup"
  die "usr/lib/setup/setup differs from the stock one.
  This port does not patch setup. If you have added an edit there, say why
  here -- and check first that the bootloader step does not already cover it."
fi
rm -f "$_stock_setup"
info "setup         : byte-identical to Slackware's (we patch it nowhere)"

# ---------------------------------------------------------------------------
# CARRIED PATCH: make SOURCE auto-detection survive a FAT32 volume label.
#
# The installer finds its own medium by volume label, matching the ISO9660
# volid "SLKins_aio-pkgs". That works from an optical image. It does NOT work
# from a USB stick written the way a user actually writes one: Rufus in its
# default ISO mode lays down FAT32, and **FAT32 labels are 11 characters**, so
# the stick presents as "SLKINS_AIO-". The grep misses, auto-detection falls
# through, and the installer asks for the source partition and package
# directory by hand. Not fatal -- there is a manual fallback -- but it hits
# every user who writes the medium normally.
#
# Only "grep -E" lines are touched, because the fix adds an alternation and a
# basic-regex grep would take the "|" literally and match nothing at all --
# turning a fallback into a silent failure. Any label-bearing grep that is NOT
# -E is reported rather than mangled.
#
# The alternation is GROUPED. Stock anchors the label ('SLKins_aio-pkgs$'), and
# '|' binds more loosely than '$', so a bare 'SLKins_aio-pkgs|SLKINS_AIO-$'
# would leave the full label unanchored; '(SLKins_aio-pkgs|SLKINS_AIO-)$' keeps
# stock's anchor on both forms.
info "SOURCE detect : teaching the label match about FAT32 truncation"
python3 - "$WORK/root" <<'PYEOF' || die "SOURCE label patch failed"
import io, os, sys

root  = sys.argv[1]
LABEL = "SLKins_aio-pkgs"
TRUNC = "SLKINS_AIO-"          # what FAT32 leaves of it: 11 chars, upper-cased
d     = os.path.join(root, "usr/lib/setup")

patched, skipped, already = [], [], []
for name in sorted(os.listdir(d)):
    p = os.path.join(d, name)
    if not os.path.isfile(p):
        continue
    try:
        s = io.open(p, encoding="utf-8", errors="surrogateescape").read()
    except (OSError, ValueError):
        continue
    if LABEL not in s:
        continue

    out, n = [], 0
    for line in s.split("\n"):
        if LABEL in line and "grep" in line:
            if TRUNC in line:
                already.append(name)
            elif "grep -E" in line or "grep -qE" in line or "egrep" in line:
                line = line.replace(LABEL, "(" + LABEL + "|" + TRUNC + ")")
                n += 1
            else:
                skipped.append((name, line.strip()[:70]))
        out.append(line)
    if n:
        io.open(p, "w", encoding="utf-8", errors="surrogateescape").write("\n".join(out))
        patched.append((name, n))

for name, line in skipped:
    print("  WARNING %s: label grep is not -E, left alone: %s" % (name, line))
if already:
    print("  already patched: %s" % ", ".join(sorted(set(already))))
if patched:
    for name, n in patched:
        print("  patched %s (%d line%s)" % (name, n, "" if n == 1 else "s"))
elif already:
    pass
else:
    sys.exit("no '%s' grep found under usr/lib/setup -- Slackware changed how the\n"
             "  installer locates its medium. Re-check before shipping, or the stick\n"
             "  will silently fall back to manual SOURCE selection." % LABEL)
PYEOF

# ---------------------------------------------------------------------------
# CARRIED PATCH: probe filters the OS's own EFI label, so you can install once
# and never again.
#
# sbin/probe drops any partition whose label is one of Slackware's reserved
# ones, to keep the installer's own media out of the candidate list. 'SLKefi'
# is in that list -- but SeTEFI:114 puts exactly that label on the USER'S EFI
# System Partition during every AArch64 install. So on a second install probe
# deletes the machine's own ESP from its output, setup:72 greps for
# "EFI System Partition", finds nothing, and reports
#
#     NO EFI SYSTEM PARTITION DETECTED
#
# on a machine whose ESP Slackware labelled itself. The only difference from a
# first, successful install is that label.
#
# Upstream already states the principle eight lines above, and applies it to a
# different label: 'SLKroot' is deliberately NOT filtered, because "the user
# might be reinstalling, thus would never be presented with the partition."
# SLKefi is the same kind of label -- used within the OS, at /boot/efi -- so it
# gets the same treatment. The INSTALLER's own ESP is 'SLKins_efi' and stays
# filtered.
#
# Blast radius is one line of behaviour: probe's EFI lines are read only by
# setup:72 (a presence check) and INShd:50 (a display). SeTDOS matches DOS/FAT
# type names; setup:57 filters 'Linux$' for the partition list; SeTEFI does not
# use probe at all -- it finds the ESP by partition-type GUID and mount-tests
# it before offering to format. Nothing new becomes formattable.
#
# Drop this when Slackware fixes it.
# ---------------------------------------------------------------------------
info "probe         : un-filtering SLKefi so a reinstall can see its own ESP"
python3 - "$WORK/root" <<'PYEOF' || die "probe SLKefi patch failed"
import io, sys, os
p = os.path.join(sys.argv[1], "sbin/probe")
s = io.open(p, encoding="utf-8", errors="surrogateescape").read()

OLD = "ins_boot|efi|hwm_bw)$"
NEW = "ins_boot|hwm_bw)$"

if OLD not in s:
    if NEW in s:
        print("  probe: already patched")
        sys.exit(0)
    sys.exit("probe: the reserved-label alternation is not the shape we know.\n"
             "  Expected to find %r. Slackware changed it -- re-read the filter\n"
             "  before shipping, because getting this wrong either hides the\n"
             "  user's ESP or offers them the installer's own." % OLD)

s = s.replace(OLD, NEW, 1)

NOTE = (
"# CARRIED PATCH (Slackware on Apple Silicon): 'efi' removed from the reserved\n"
"# labels the grep below filters, for exactly the reason given for 'SLKroot'\n"
"# above: it is a label used WITHIN THE OS (/boot/efi), not on the installer\n"
"# medium, and SeTEFI applies it during install.  Filtering it means a user\n"
"# reinstalling is told they have no EFI System Partition on a machine whose\n"
"# ESP Slackware labelled itself.  The installer's own ESP is 'SLKins_efi' and\n"
"# is still filtered.\n")
anchor = "awk '/^\\/dev\\// {print $1}'"
i = s.find(anchor)
if i < 0:
    sys.exit("probe: cannot find the device loop -- refusing to place the note blindly")
s = s[:i] + NOTE + s[i:]

io.open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
print("  probe: SLKefi no longer filtered")
PYEOF
grep -q 'ins_boot|hwm_bw' "$WORK/root/sbin/probe" \
  || die "probe patch reported success but the alternation still filters efi"

# ---------------------------------------------------------------------------
# CARRIED PATCH: make the installer leave a BOOTABLE machine.
#
# WHAT STOCK DOES HERE
# --------------------
# Slackware ARM configures the target's boot loader from
# usr/share/hwm-configure/.../helper.scr/000-grub-configure. It installs GRUB,
# then drops in template-grub.cfg -- which loads /boot/Image-armv8 with
# initrd /boot/initrd-armv8, i.e. Slackware's own 4K-page kernel. This medium
# does not carry that kernel, and it could not boot Apple hardware if it did.
#
# Leaving the target without a working boot entry is not how Slackware behaves
# anywhere else: on every other platform the installer finishes and the machine
# boots. There is no liloconfig or eliloconfig on AArch64 -- this script IS the
# bootloader step.
#
# WHAT THE HARDWARE CLASSES DO, AND WHAT THEY DELIBERATELY DO NOT
# ---------------------------------------------------------------
# THE TEMPLATE IS NOT CHOSEN BY CLASSIFICATION, and cannot be. This medium
# ships exactly one kernel -- kernel_armv8 is removed from it entirely -- so
# whatever machine boots it, the only kernel it can install is this port's, and
# only this port's template can boot that. The template is replaced globally and every model
# gets the right one: M1, M2, M3, M4, and whatever Apple names next.
#
# Classifying in order to PICK the template -- an "Apple Mac"*|"Apple
# MacBook"*|"Apple iMac"* branch -- would be unnecessary, and would make a name
# allowlist load-bearing for correctness: a future Mac that failed to match
# would install something that cannot boot.
#
# What the classes are for is telling the operator the truth. Three tiers:
#
#   tested      the README's Tested models,  installed with NO prompt, exactly
#               by exact model string        as Slackware treats a model it
#               (TIERS below)                supports
#   M1 / M2     "Apple"*"M1"*|"Apple"*"M2"*  our own INSTALL/SKIP screen
#   anything    -                            upstream's own dialog, untouched
#
# A model that fails to match costs only WORDING -- it still gets the correct
# template and a working entry. That is why matching on names is acceptable
# here.
#
# The same reasoning is in docs/PORTING.md ("The hardware classes decide words,
# not templates"). Both must move together or they will disagree.
# ---------------------------------------------------------------------------
info "bootloader    : target gets a working GRUB entry from setup itself"
python3 - "$WORK/root" <<'PYEOF' || die "000-grub-configure patch failed"
import io, sys, os
root = sys.argv[1]
p = os.path.join(root,
                 "usr/share/hwm-configure/platform/aarch64/installer/"
                 "helper.scr/000-grub-configure")
if not os.path.exists(p):
    sys.exit("000-grub-configure not found -- Slackware moved the GRUB post-install\n"
             "  script. Without it the target gets no boot loader at all.")
s = io.open(p, encoding="utf-8", errors="surrogateescape").read()

def edit(text, old, new, label):
    if new in text:
        print("  %s: already patched" % label)
        return text
    if old not in text:
        sys.exit("000-grub-configure: %s -- anchor not found, Slackware changed it" % label)
    print("  %s: patched" % label)
    return text.replace(old, new, 1)

# 1. Fill OUR placeholders, immediately before the template is installed.
#
#    Deliberately not upstream's %ROOTDEV%: that comes from
#    $TMP/SeTrootdev_labeled and is "LABEL=SLKroot", which this kernel cannot
#    resolve without an initrd. Using our own names leaves upstream's seds for
#    %ROOTDEV%, %CONSOLE%, %DEVICETREE% and %POST_INST_OS_CMDLINE_APPEND% as
#    harmless no-ops instead of something to fight.
#
#    Everything needed is already on disk at this point in setup:
#    $TMP/SeTrootdev is the TARGET's root device (SeTpartitions writes it),
#    $TMP/root_sys_type is its filesystem, and the target is mounted at $T_PX
#    with our kernel already installed into it.
FILL = '''
# CARRIED PATCH (Slackware on Apple Silicon): fill the Mac template.
# An empty root= is a kernel panic at a boot nobody is watching, so the kernel
# path and the root PARTUUID are checked rather than assumed; the filesystem
# type is stock's, as SeTpartitions recorded it.
# Both checks exit silently, as every failure path in this script already does:
# a missing template, a missing grub-install, and grub-install itself failing
# are all a bare `exit 1` upstream, with no screen -- and that last one leaves
# an unbootable machine. Dialogs here are for decisions and progress, not for
# failures, and this port does not diverge from that.
as_kernel=""
[ -e "${T_PX}/boot/Image-armv8-mac" ] && as_kernel="/boot/Image-armv8-mac"
[ -z "${as_kernel}" ] && exit 1
as_rootdev="$( cat ${TMP}/SeTrootdev 2>/dev/null )"
as_partuuid="$( blkid -s PARTUUID -o value "${as_rootdev}" 2>/dev/null )"
[ -z "${as_partuuid}" ] && exit 1
sed -i -e "s?%KERNELPATH%?${as_kernel}?g" \\
       -e "s?%ROOTPARTUUID%?${as_partuuid}?g" \\
       -e "s?%ROOTFSTYPE%?${conf_root_fstype}?g" ${ARMEDSLACK_GRUBCONF}

'''
s = edit(s,
    "#\n# Configure the template with this Hardware Model's settings:\n#\n",
    "#\n# Configure the template with this Hardware Model's settings:\n#\n" + FILL,
    "Mac template placeholders")

# 2. HARDWARE CLASSES -- three tiers.
#
#    Upstream's `case $HWM` sets hwm_grub_supported=1 for models Slackware
#    supports, and that flag gates EXACTLY ONE THING: the INSTALL/SKIP dialog
#    below it. grub-install, the template install and the template's
#    configuration all run regardless. So "install without asking" is one
#    variable, and nothing else changes.
#
#    tested     -> hwm_grub_supported=1, no prompt, as on any supported model
#    M1 / M2    -> our own screen, INSTALL/SKIP
#    everything -> upstream's unsupported-hardware dialog, untouched
#
#    ⚠ WHAT THESE BRANCHES DO NOT DO: choose a template. They cannot. This
#    medium ships one kernel, so there is one template and every machine gets
#    it. Classification here decides WORDS, and whether the operator is asked.
#    A model string that fails to match therefore costs wording, never
#    correctness -- which is why matching on names is acceptable here when it
#    is not acceptable for selecting behaviour that matters.
#
#    Set nothing else in these branches. conf_console, conf_dt,
#    conf_kernel_cmdline and no_append_platwalk all feed seds for placeholders
#    our template does not carry, so they are no-ops on it. And do NOT set
#    strip_uefifw: it deletes the ##SLKuefi_settings block, which our template
#    DOES have.
TIERS = '''   # CARRIED PATCH (Slackware on Apple Silicon): hardware classes.
   #
   # The README's Tested models behave as any Slackware-supported model
   # does -- the boot loader is installed without asking. Add a model here
   # when it is added there.
   "Apple Mac mini (M2, 2023)"*)
      hwm_grub_supported=1 ;;

   # M1/M2 Apple Silicon: the intended support target. Not individually
   # tested, so the operator is asked rather than told. Matches the chip in
   # the model string, which is what slk-hwm-discover reports.
   "Apple"*"M1"*|"Apple"*"M2"*)
      hwm_apple_untested=1 ;;

'''
s = edit(s,
    "      # Unsupported/Unknown Hardware Models.\n",
    TIERS + "      # Unsupported/Unknown Hardware Models.\n",
    "hardware class branches")

# 3. Our screen for untested Apple Silicon, as a WRAPPER.
#
#    Deliberately placed BEFORE upstream's `if [ -z "${hwm_grub_supported}" ]`
#    block and leaving that block byte-identical, rather than rewriting its
#    title and body in place. Two consequences:
#
#      * tier 3 gets upstream's own dialog verbatim, and we inherit any change
#        Slackware makes to it;
#      * two fragile anchors -- one of them a multi-line shell string bounded by
#        a search for `" 0 0` -- become one.
#
#    Setting hwm_grub_supported=1 after our prompt is what stops upstream's
#    dialog also firing.
APPLE_DIALOG = '''# CARRIED PATCH (Slackware on Apple Silicon): untested Apple Silicon gets our
# own screen, then continues as if supported so the dialog below does not also
# fire.
if [ -n "${hwm_apple_untested}" ]; then
   dialog \\
      --backtitle "Bootware" \\
      --colors \\
      --no-collapse \\
      --title "INSTALL BOOT LOADER" \\
      --yes-label "INSTALL" \\
      --no-label "SKIP" \\
      --yesno "$( sed -e "s?%HWM%?${HWM}?g" /usr/lib/setup/apple-grub-dialog.txt )" 0 0
   [ $? -eq 1 ] && exit 0 # quit if the user picked 'SKIP'
   hwm_grub_supported=1
fi

'''
s = edit(s,
    'if [ -z "${hwm_grub_supported}" ]; then\n',
    APPLE_DIALOG + 'if [ -z "${hwm_grub_supported}" ]; then\n',
    "untested-Apple boot loader screen")

# 4. The Wi-Fi/Bluetooth firmware step is NOT here, on purpose.
#
#    Slackware's own mechanism for install-time work is a script in
#    $T_PX/var/log/setup/setup.*, which SeTconfig runs in sorted order and
#    whose exit status it never inspects -- and Stuart ships board-specific
#    install-time work exactly that way (setup.11.bootloader-flash-lx2160acex7).
#    The step draws no screen when it fails, as stock's 000-grub-configure
#    draws none for its own failures (each is a bare `exit 1`); a failed
#    firmware step shows in verify-install-mac's report instead.
#
#    The step ships from the kernel package as
#    /var/log/setup/setup.vendorfw-mac. Sorting after setup.timeconfig gives
#    --regdom=auto a timezone to read.
#
#    Consequence for this file: it carries no firmware edit at all, and
#    000-grub-configure keeps only the placeholder and boot-loader changes.

io.open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
PYEOF
bash -n "$WORK/root/usr/share/hwm-configure/platform/aarch64/installer/helper.scr/000-grub-configure" \
  || die "000-grub-configure does not parse after patching -- the target would get no boot loader"
info "bootloader    : 000-grub-configure parses cleanly"

# ---------------------------------------------------------------------------
# The case pattern above claims to cover every Mac this kernel can boot. Check
# that against the DEVICE TREES THE KERNEL ACTUALLY SHIPS rather than trusting
# it, in the same spirit as the driver-parity gate: derive, do not type.
#
# A model string is what slk-hwm-discover reads out of /proc/device-tree/model,
# so matching the DTBs is matching what the installer will see at runtime.
# ---------------------------------------------------------------------------
DTBDIR=/lib/modules/$KVER/dtbs
if [ -d "$DTBDIR" ]; then
  MACS=$(grep -ahoE 'Apple (Mac|iMac|MacBook)[A-Za-z0-9 ,()/-]{0,50}' "$DTBDIR"/*.dtb 2>/dev/null \
         | sed 's/[[:space:]]*$//' | sort -u)
  nmac=$(printf '%s\n' "$MACS" | grep -c . || true)
  info "hardware      : $nmac Mac models in the shipped device trees"
  printf '%s\n' "$MACS" | sed 's/^/      /'
  # Every M1 and M2, plus three M3 machines, at this pin. The floor is
  # deliberately well below that -- this is checking the device trees did not
  # vanish, not pinning a count that upstream is free to change. A kernel that
  # shipped none of them would still build a medium that installs and then
  # classifies every Mac as unknown hardware.
  [ "${nmac:-0}" -ge 20 ] || die "only ${nmac:-0} Apple Mac device trees in $DTBDIR.
  The installer recognises Macs by that model string, so a kernel missing them
  sends every Mac down the UNKNOWN HARDWARE path."
  # The README's Tested model must be a string the shipped device trees carry,
  # or the tested tier above can never match.
  printf '%s\n' "$MACS" | grep -qx 'Apple Mac mini (M2, 2023)' \
    || die "'Apple Mac mini (M2, 2023)' is not a model string in $DTBDIR --
  the installer's tested tier could never match it."
else
  info "hardware      : no dtbs/ in the module tree, skipping the model check"
fi

info "repacking     : xz, newc"
# --check=crc32: the kernel's xz decoder rejects xz's default CRC64 (trap 1).
( cd "$WORK/root" && find . | cpio -o -H newc --quiet | xz -9 --check=crc32 -T0 ) > "$OUT"

[ -s "$OUT" ] || die "produced an empty initrd"
outmagic=$(head -c4 "$OUT" | od -An -tx1 | tr -d ' \n')
[ "$outmagic" = "fd377a58" ] || die "output is not xz (magic $outmagic)"

echo
echo "== done =="
echo "   $OUT  ($(stat -c%s "$OUT") bytes)"
echo "   kernel it pairs with: $KVER"
echo
echo "Boot it with the matching kernel; a mismatch leaves the installer running"
echo "but blind to storage and network."
