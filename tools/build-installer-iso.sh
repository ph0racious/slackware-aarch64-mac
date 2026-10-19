#!/bin/bash
#
# build-installer-iso.sh -- rebuild the Slackware AArch64 installer ISO so it
# boots and installs on Apple Silicon.
#
# WHAT CHANGES, AND WHAT DELIBERATELY DOES NOT
# --------------------------------------------
# Slackware's installer is fine; only the kernel underneath it cannot run (it
# has no Apple watchdog driver, and it is a 4K-page build). So this swaps the
# kernel and the initrd (its module tree, plus the few carried patches
# docs/PORTING.md lists). setup itself and pkgtools are untouched. What changes
# on the medium besides is what it carries: the packages below; the package
# indexes; each series' tagfile and setup checklists, rewritten to name exactly
# the packages in that series (see TRAPS, 3); the boot menu (grub.cfg); and the
# macOS firmware gatherer at the ISO root.
#
# Package placement follows Slackware ARM's own conventions rather than
# inventing a series:
#
#   * this port's packages go in the series they functionally belong to (a/,
#     d/, l/, x/), exactly as Slackware ARM does with its own platform-specific
#     packages (hwm-bw-raspberrypi, hwm-bw-rk3399, ... all live in a/);
#   * its pipewire REPLACES l/pipewire, and its mesa x/mesa, rather than sitting
#     beside them: same names, same versions, with -Dlv2=enabled and the asahi
#     drivers added respectively. Shipping both would mean whichever installed
#     last won, silently;
#   * kernel_armv8 is REMOVED. The tree ships one kernel and it is the one that
#     works; stock's kernel cannot run this hardware, so on Apple Silicon
#     media it is dead weight and a boot entry that traps the unwary.
#
# TRAPS THIS SCRIPT EXISTS TO AVOID
# ---------------------------------
#   1. xorriso DISCARDS the El Torito boot record by default. Its own note says
#      so: "Detected El-Torito boot information which currently is set to be
#      discarded". Without -boot_image any keep the output is a perfectly valid
#      ISO that no firmware will boot.
#   2. The volume label must stay SLKins_aio-pkgs -- grub.cfg finds the media
#      with `search --label`. Change it and GRUB starts, then cannot find itself.
#   3. The package indexes (PACKAGES.TXT, both CHECKSUMS.md5, FILELIST.TXT,
#      FILE_LIST, MANIFEST.bz2) and each series' setup checklists (maketag,
#      maketag.ez) are rewritten for exactly the files this build changes.
#      Regenerating them from scratch means md5summing ~4.6 GB for no benefit;
#      editing only some of them leaves a medium whose network install and
#      slackpkg see the stock tree. See "THE MEDIUM'S INDEXES" below.
#   4. Two or more builds of the same package staged at once. Selecting with
#      `find | head -1` can pair a kernel in a/ with a DIFFERENT build of its
#      headers in d/, so the headers land under the wrong kernel version. It
#      installs cleanly and boots; only an out-of-tree module build would ever
#      find it. This script refuses.
#   5. Rebuilding over an existing output. xorriso will not write into a
#      non-empty -outdev, and it says so only AFTER reporting the -rm steps as
#      successful, which reads as though the removals broke it.
#
# Needs: xorriso, and the stock Slackware AArch64 ISO to build from.

set -euo pipefail

# Build paths. Sourced before the assignments below, which are built from
# $ISO_DIR and $W_DIR: the kernel and initrd are read from the work directory
# where the earlier build steps left them, and the finished ISO is written to
# $ISO_DIR.
. "$(dirname "$0")/build-paths.sh"

# What the medium carries. KIMAGE is the name the kernel takes in /boot on the
# ISO, and grub.cfg loads it by that name, so it must match what KPKG
# installs. All three are UNVERSIONED on purpose: a version baked in here goes
# stale silently and ships a mismatched kernel, and see the module-tree check
# below for what that costs.
KIMAGE=Image-armv8-mac
KPKG=kernel_armv8-mac
KHDRPKG=kernel_armv8-mac-headers
# The menu title names the BUILD, not the hardware. Every entry a Mac can
# boot is Apple Silicon, so saying so carries no information.
KTITLE="Install Slackware Linux (AArch64-mac)"

ISO_IN=$ISO_DIR/efi_generic.iso
ISO_OUT=$ISO_MAC
KERNEL=$W_DIR/Image-armv8-mac
INITRD=$W_DIR/initrd-mac.img
MNT=/mnt/iso
VOLID="SLKins_aio-pkgs"
# What FAT32 leaves of that label: 11 characters, upper-cased. A stick written
# with Rufus in its default ISO mode presents THIS, not the ISO9660 volid, so
# both GRUB (below) and the installer's own source detection (patched in
# build-installer-initrd.sh) have to know about it. Derived, not typed, so the
# two can never disagree about what the truncation is.
VOLID_FAT=$(echo "$VOLID" | cut -c1-11 | tr 'a-z' 'A-Z')
TREE="slackware/slackwareaarch64-current/slackware"

die()  { echo "build-installer-iso: $*" >&2; exit 1; }
info() { echo "  $*"; }

command -v xorriso >/dev/null 2>&1 || die "xorriso not installed"
for f in "$ISO_IN" "$KERNEL" "$INITRD"; do [ -f "$f" ] || die "missing: $f"; done

# THE BASE IS A PIN. Slackware ARM rebuilds efi_generic.iso at Stuart's
# discretion, at the same URL, so its name does not say which snapshot it is.
# A different snapshot means different stock packages underneath this port's;
# a version bump, made deliberately (re-pin here and in docs/BUILD.md), never
# by accident.
BASE_SHA256=8a58bece68e69ea4a4ca64ebcd01ef61c35849fcc8fcea669df9daa987fea188
info "base ISO      : verifying $(basename "$ISO_IN") against the pin"
have=$(sha256sum "$ISO_IN" | cut -d' ' -f1)
[ "$have" = "$BASE_SHA256" ] || die "$(basename "$ISO_IN") is not the pinned base snapshot.
  want $BASE_SHA256
  got  $have
  See docs/BUILD.md for where the pinned snapshot lives. Building on a newer
  one is a version bump: re-pin BASE_SHA256 in this script deliberately."

TOOLSDIR=$(cd "$(dirname "$0")" && pwd)

# ---------------------------------------------------------------------------
# THE INITRD MUST CARRY *THIS* TREE'S INSTALLER TEXT.
#
# Every screen this port writes words for is a file in installer-text/,
# staged into the initrd by the initrd builder, so a medium built from a
# different copy of the tree carries that copy's text. (The boot menu and the
# package checklists are written by this script instead.) The GRUB
# template is staged the same way, and it is what makes the installed machine
# boot: a stale copy installs cleanly and fails only at the first reboot.
#
# Compared against the tree's copy with CR stripped, because that is what the
# initrd builder writes.
#
# The destination map and the rendering both come from installer-text.sh, which
# is also what build-installer-initrd.sh writes them with. Two copies of that
# knowledge is how a check ends up comparing the wrong thing and reporting
# green: a transformation (%GRUBCONF% substitution) added to the writer only.
. "$TOOLSDIR/installer-text.sh"
TEXTSRC=$TOOLSDIR/../installer-text
[ -d "$TEXTSRC" ] || die "no installer-text/ beside tools/ -- cannot verify the medium's screens"
while IFS=$'\t' read -r dst src kind; do
  [ -s "$TEXTSRC/$src" ] || die "installer-text/$src is missing or empty -- cannot verify $dst"
  it_check "$TEXTSRC/$src" "$kind" || die "installer-text/$src cannot ship as written (see above)"

  # EXTRACT TO A FILE, NEVER THROUGH $(...). Command substitution strips
  # trailing newlines, so hashing captured text compares the file against a copy
  # of itself missing its final newline -- a check that can never pass.
  _x=$(mktemp)
  xz -dc "$INITRD" 2>/dev/null \
    | cpio -i --to-stdout --quiet "*$dst" > "$_x" 2>/dev/null || true
  want=$(it_render "$TEXTSRC/$src" | md5sum | cut -d' ' -f1)
  [ -s "$_x" ] || { rm -f "$_x"; die "the initrd contains no $dst.
  $INITRD was built without installer-text/$src, or from a tree that predates it."; }
  have=$(md5sum < "$_x" | cut -d' ' -f1)
  rm -f "$_x"
  [ "$have" = "$want" ] || die "STALE INSTALLER TEXT ON THE MEDIUM: $dst
  initrd : $have
  tree   : $want  (installer-text/$src, rendered)
  The initrd was built from a different copy of this tree. Rebuild it with
  tools/build-installer-initrd.sh from THIS tree, then rebuild the medium."
  info "initrd text   : $src matches the tree ($want)"
done < <(it_map)

# THE KERNEL AND THE INITRD'S MODULE TREE MUST BE THE SAME BUILD.
#
# build-installer-initrd.sh already refuses to build an initrd whose module tree
# does not match the kernel it was given. But KERNEL and INITRD are two
# independent variables HERE, so nothing stops a stale kernel being paired with
# a freshly built initrd. That medium boots. It just cannot see storage or
# network, because modprobe looks in /lib/modules/<running-version> and finds
# nothing, and the failure looks like broken hardware support rather than a
# build error.
kver=$(grep -a -o -m1 'Linux version [0-9][^[:space:]]*' "$KERNEL" | awk '{print $3}')
# cpio stores these WITHOUT a leading "./" here, but other producers add one, so
# accept both. Matching `lib/modules/<ver>` with anything (or nothing) after it
# also catches the bare directory entry, which is the only entry present if a
# module tree is somehow empty.
mver=$(xz -dc "$INITRD" 2>/dev/null | cpio -t --quiet 2>/dev/null \
       | sed -n 's|^\(\./\)\{0,1\}lib/modules/\([^/][^/]*\).*|\2|p' | sort -u | head -1)
[ -n "$kver" ] || die "cannot read a version string out of $KERNEL"
[ -n "$mver" ] || die "cannot find lib/modules/<version> inside $INITRD"
[ "$kver" = "$mver" ] || die "KERNEL AND INITRD ARE DIFFERENT BUILDS
  kernel : $kver  ($KERNEL)
  initrd : $mver  ($INITRD)
  A medium built from these boots and then finds no storage and no network,
  because modprobe searches /lib/modules/$kver and the initrd only carries
  /lib/modules/$mver."
info "kernel/initrd : both $kver"
# ---------------------------------------------------------------------------
mountpoint -q "$MNT" || die "stock ISO not mounted at $MNT (mount -o loop,ro $ISO_IN $MNT)"
[ -d "$PKGDIR" ] || die "no package directory at $PKGDIR"

# Refuse to write over anything that is not this build's output.
#
# Files in $ISO_DIR that this build must never write over:
#
#   efi_generic.iso        THE BASE. It is the -indev of this very build.
#                          Writing to it destroys the input every future medium
#                          is made from.
#
# Match EXACT basenames. A substring glob here is a trap: the protected name
# and the output name share stems, so one reaches far enough to refuse the
# build it is supposed to permit -- and it fails closed, so the medium simply
# never gets built and the message blames the wrong file.
out_base=$(basename "$ISO_OUT")
case "$out_base" in
  efi_generic.iso|efi_generic-*.iso)
    die "ISO_OUT is $out_base -- that is the BASE image this build reads from.
  Writing to it would destroy the input every medium is built from." ;;
esac
info "medium: $(basename "$ISO_OUT")  (kernel package: $KPKG)"

# Which series each of this port's packages belongs to. Placement is by
# function, not origin.
declare -A SERIES=(
  [hwm-bw-mac]=a  [asahi-scripts]=a
  [asahi-fwextract]=a      [lzfse]=a              [speakersafetyd]=a
  [tiny-dfr]=a
  [pipewire]=l             [alsa-ucm-conf-asahi]=l [zix]=l    [serd]=l
  [sord]=l                 [lv2]=l                [sratom]=l  [lilv]=l
  [lsp-plugins-lv2]=l      [bankstown]=l          [triforce-lv2]=l
  [asahi-audio]=l
  # mesa REPLACES x/mesa, the same arrangement as pipewire in l/. Stock
  # Slackware builds it without `asahi` in -Dgallium-drivers, so without this
  # a fresh install has no hardware GL at all -- the kernel driver loads, the
  # render node appears, and every client still falls back to llvmpipe.
  [mesa]=x
)
# The kernel and its headers are named by the variables at the top of this
# file; everything above is a literal package name.
SERIES[$KPKG]=a
SERIES[$KHDRPKG]=d

OV="$WORK/overlay"
# Series we stage into. Adding a letter here is not enough on its own -- it has
# to be added to the tagfile loop, the metadata loop and the xorriso -map list
# further down, all of which name the series explicitly.
OUR_SERIES="a d l x"
rm -rf "$OV"; mkdir -p "$OV/boot" "$OV/$TREE"/{a,d,l,x}

echo "== staging kernel + initrd =="
install -m644 "$KERNEL" "$OV/boot/$KIMAGE"
install -m644 "$INITRD" "$OV/boot/initrd-mac.img"
info "kernel $KIMAGE $(stat -c%s "$KERNEL") bytes, initrd $(stat -c%s "$INITRD") bytes"

echo "== staging packages into their series =="
declare -A ADDED
n=0
for pkg in "${!SERIES[@]}"; do
  s=${SERIES[$pkg]}
  # NEVER `| head -1` here. That silently ships whichever build the filesystem
  # happened to return first, and with several versions staged it can answer
  # differently for different packages. kernel_armv8-mac and its headers
  # come from ONE SlackBuild but stage as two files, so a stale pair puts
  # headers in /lib/modules/<other-build>/build while the running kernel is
  # something else. It installs cleanly and the machine boots; only
  # building an out-of-tree module would have found it.
  #
  # Choosing between builds is not this script's decision to make. Refuse.
  mapfile -t cands < <(find "$PKGDIR" -maxdepth 1 -name "${pkg}-[0-9]*.txz" | sort)
  [ "${#cands[@]}" -gt 0 ] || die "package not found: $pkg (looked in $PKGDIR)"
  if [ "${#cands[@]}" -gt 1 ]; then
    echo "  $pkg has ${#cands[@]} builds staged:" >&2
    printf '    %s\n' "${cands[@]##*/}" >&2
    die "$pkg: more than one build staged -- remove the ones you do not want to ship"
  fi
  f=${cands[0]}
  base=$(basename "$f")

  # NO MEDIUM SHIPS AN UNGATED KERNEL.
  #
  # This is the enforcement point for driver parity: however the kernel was
  # built, nothing reaches a medium without passing it. The SlackBuild's own
  # check is a typed list and is labelled a smoke test; it catches a build that
  # fell over, not a driver nobody remembered.
  if [ "$pkg" = "$KPKG" ]; then
    info "driver parity : gating $base before it is staged"
    bash "$TOOLSDIR/check-driver-parity.sh" "$f" \
      || die "the kernel package failed the driver-parity gate -- refusing to
  build a medium around it. Fix the kernel, do not bypass this."
  fi

  cp "$f" "$OV/$TREE/$s/$base"
  # Slackware ships a .txt description alongside each package; it is the
  # slack-desc with the leading 'pkgname:' prefix retained. Extract from the
  # package itself so the two can never drift apart.
  tar xOf "$f" install/slack-desc 2>/dev/null \
    | grep -vE '^#|handy-ruler' | sed '/^[[:space:]]*$/d' > "$OV/$TREE/$s/${base%.txz}.txt" || true
  # Exactly the 11 description lines, or setup and PACKAGES.TXT get a blank or
  # broken description and nothing else would notice.
  [ "$(grep -c "^$pkg:" "$OV/$TREE/$s/${base%.txz}.txt")" = 11 ] \
    || die "$base: its install/slack-desc does not yield 11 '$pkg:' lines"
  ADDED[$s]="${ADDED[$s]:-} $pkg"
  n=$((n+1))
done
info "$n packages staged"

# ---- package policy (begin) ------------------------------------------------
# GATE: WHAT EACH OF THIS PORT'S PACKAGES SHIPS, CHECKED ON THE PACKAGE ITSELF.
#
# Slackware ARM's packaging makes every package's files unwritable by group and
# others and its docs 0644 (slackslack), and every stock package carries its
# licence. A SlackBuild's `cp -a` keeps whatever mode a source had, and a
# licence copy behind `|| true` vanishes quietly when a version bump renames
# the file, so check the result rather than trust the recipes:
#
#   * nothing writable by group or others (symlinks aside);
#   * every regular file under usr/doc is 0644;
#   * a licence under usr/doc, in every package but the headers one, which
#     carries none, as stock's kernel_armv8 and kernel-headers carry none;
#   * m1n1's third-party licences in hwm-bw-mac, whose m1n1.bin embeds that
#     code.
#
# Listings go through here-strings, never `| grep -q`: a kernel package's
# listing outruns the pipe buffer, grep -q exits on the first match, the writer
# takes SIGPIPE, and pipefail turns the match into a failure.
pp_fail=0
pp_bad() { echo "  POLICY: $*" >&2; pp_fail=1; }
for f in "$OV/$TREE"/{a,d,l,x}/*.txz; do
  [ -e "$f" ] || continue
  b=$(basename "$f" .txz)
  name=$(echo "$b" | sed 's/-[^-]*-[^-]*-[^-]*$//')
  lst=$(tar tvJf "$f") || { pp_bad "$b cannot be listed"; continue; }
  # The path is everything after the first five fields (mode, owner, size,
  # date, time), so names with spaces survive, less any leading ./ (makepkg
  # writes none but the root's; other tars write it on every entry).
  modes=$(awk '{ p = $0; for (i = 1; i <= 5; i++) sub(/^[^ ]+ +/, "", p); sub(/^\.\//, "", p); m = $1 }
    m !~ /^l/ && (substr(m, 6, 1) == "w" || substr(m, 9, 1) == "w") { print "writable by group or others: " m "  " p }
    m ~ /^-/ && p ~ /^usr\/doc\// && m != "-rw-r--r--" { print "doc file not 0644: " m "  " p }' <<<"$lst")
  [ -z "$modes" ] || pp_bad "$b:
$(printf '%s\n' "$modes" | head -8 | sed 's/^/      /')"
  paths=$(awk '{ p = $0; for (i = 1; i <= 5; i++) sub(/^[^ ]+ +/, "", p); sub(/^\.\//, "", p); print p }' <<<"$lst")
  if [ "$name" != "$KHDRPKG" ]; then
    grep -qiE '^usr/doc/[^/]+/(.+/)?(licen[cs]e[^/]*|copying[^/]*|licenses/[^/]+)$' <<<"$paths" \
      || pp_bad "$b ships no licence under usr/doc"
  fi
  if [ "$name" = hwm-bw-mac ]; then
    grep -qE '^usr/doc/[^/]+/m1n1-[^/]+/3rdparty_licenses/LICENSE\.' <<<"$paths" \
      || pp_bad "$b lacks m1n1's third-party licences (3rdparty_licenses/)"
  fi
done
[ "$pp_fail" -eq 0 ] || die "a package of this port breaks Slackware's packaging policy (above)"
info "package policy: modes, doc modes and licences clean in all $n packages"
# ---- package policy (end) --------------------------------------------------

echo "== tagfiles =="
# The kernel and the boot firmware are ADD, as stock tags the packages they
# stand in for (kernel_armv8:ADD, and every hwm-bw-* ADD). Newbie prompting,
# the one mode that reads these files, installs ADD without asking, so it
# never offers to leave the machine without a kernel. Everything else from
# this port is REC: default yes, deselectable. A user overriding defaults is
# assumed to know what they are doing; that is the Slackware bargain. What
# carries the weight there is each package's description, which says what the
# package is for; the ones the hardware cannot do without say so plainly.
ADD_PKGS=" $KPKG hwm-bw-mac "
for s in $OUR_SERIES; do
  cp "$MNT/$TREE/$s/tagfile" "$OV/$TREE/$s/tagfile"
  for pkg in ${ADDED[$s]:-}; do
    case "$ADD_PKGS" in *" $pkg "*) tag=ADD ;; *) tag=REC ;; esac
    grep -qE "^${pkg}:" "$OV/$TREE/$s/tagfile" \
      || echo "${pkg}:${tag}" >> "$OV/$TREE/$s/tagfile"
  done
done
# kernel_armv8 cannot run on this hardware, so it comes off the media entirely;
# its tagfile line has to go with it or setup asks for a package that is absent.
sed -i '/^kernel_armv8:/d' "$OV/$TREE/a/tagfile"
for pkg in $ADD_PKGS; do
  grep -qx "${pkg}:ADD" "$OV/$TREE/a/tagfile" \
    || die "the a/ tagfile does not tag $pkg ADD; newbie prompting would offer to skip it"
done
info "a/: +$(echo ${ADDED[a]} | wc -w) entries ($(echo $ADD_PKGS) ADD, the rest REC), kernel_armv8 removed"
info "d/: +$(echo ${ADDED[d]} | wc -w)   l/: +$(echo ${ADDED[l]} | wc -w)"

echo "== package checklists =="
# Setup's "menu" and "expert" prompting modes never read the tagfiles above.
# Each runs its series' maketag.ez or maketag, a dialog checklist with one line
# per package plus two loops naming every package, and installs from what was
# ticked. Left stock, the A checklist offers kernel_armv8, which this medium
# does not carry, and none of this port's packages, which then arrive as
# one-by-one prompts after it: tick kernel_armv8, answer No to the prompt for
# kernel_armv8-mac, and the machine has no kernel.
#
# So each checklist is rewritten to list exactly its series, as Slackware's own
# are: kernel_armv8 goes, and each package this port adds gets a line, ticked,
# whose text is the title its slack-desc already gives setup. A package this
# port replaces under the same name (mesa, pipewire) keeps stock's line. Only
# names change: stock's lines and loops are sorted in C order, and every
# insertion keeps them so. The metadata gate below checks the result.
for s in $OUR_SERIES; do
  : > "$OV/checklist.add"
  for pkg in ${ADDED[$s]:-}; do
    _t=$(ls "$OV/$TREE/$s/$pkg"-[0-9]*.txt)
    title=$(awk -v p="$pkg" 'NR == 1 && index($0, p ": " p " (") == 1 {
                               t = substr($0, length(p) * 2 + 5); sub(/\)[[:space:]]*$/, "", t); print t }' "$_t")
    [ -n "$title" ] || die "$pkg: its description's first line is not '$pkg: $pkg (title)'"
    case "$title" in *[\"\$\`\\]*) die "$pkg: its title has a character the checklist script cannot quote: $title" ;; esac
    printf '%s\t%s\n' "$pkg" "$title" >> "$OV/checklist.add"
  done
  for f in maketag maketag.ez; do
    [ -r "$MNT/$TREE/$s/$f" ] || die "the base has no $s/$f; re-check this before building on that base"
    LC_ALL=C awk -v rm=" kernel_armv8 " -v addf="$OV/checklist.add" '
      function item(n) { return "\"" n "\" \"" A[n] "\" \"on\" \\" }
      # Print every added name sorting before n, once.
      function flush(n,   k) { for (k = 1; k <= na; k++) if (!done[k] && (n == "" || N[k] < n)) { out(N[k]); done[k] = 1 } }
      # The names in a loop line, merged the same way, its tail kept as it is.
      function mergeloop(line,   tail, w, nw, i, k, s) {
        tail = line; sub(/^[^\\]*/, "", tail); sub(/[[:space:]]+\\.*$/, "", line)
        nw = split(line, w, " "); s = ""; k = 1
        for (i = 1; i <= nw; i++) {
          if (index(rm, " " w[i] " ")) continue
          while (k <= na && N[k] < w[i]) { if (!(N[k] in have)) s = s (s == "" ? "" : " ") N[k]; k++ }
          s = s (s == "" ? "" : " ") w[i]
        }
        for (; k <= na; k++) if (!(N[k] in have)) s = s " " N[k]
        return s "  " tail
      }
      function out(n) { if (!(n in have)) print item(n) }
      NR == FNR { if ($0 ~ /^"[^"]+" "[^"]*" "(on|off)" \\$/) { n = $0; sub(/^"/, "", n); sub(/".*/, "", n); have[n] = 1 }; next }
      FNR == 1 {
        while ((getline l < addf) > 0) { i = index(l, "\t"); n = substr(l, 1, i - 1); A[n] = substr(l, i + 1); N[++na] = n }
        for (i = 2; i <= na; i++) for (j = i; j > 1 && N[j] < N[j - 1]; j--) { t = N[j]; N[j] = N[j - 1]; N[j - 1] = t }
      }
      /^"[^"]+" "[^"]*" "(on|off)" \\$/ {
        n = $0; sub(/^"/, "", n); sub(/".*/, "", n); initems = 1
        flush(n)
        if (!index(rm, " " n " ")) print
        next
      }
      initems { flush(""); initems = 0 }
      inloop { print mergeloop($0); inloop = 0; next }
      /^[[:space:]]*for (PKG|PACKAGE) in \\$/ { inloop = 1 }
      { print }' "$MNT/$TREE/$s/$f" "$MNT/$TREE/$s/$f" > "$OV/$TREE/$s/$f"
    chmod 644 "$OV/$TREE/$s/$f"
    sh -n "$OV/$TREE/$s/$f" || die "$s/$f does not parse after rewriting"
  done
  cmp -s "$OV/$TREE/$s/maketag" "$OV/$TREE/$s/maketag.ez" \
    || die "$s/maketag and $s/maketag.ez differ after rewriting; stock keeps them identical"
done
rm -f "$OV/checklist.add"
info "checklists rewritten for: $OUR_SERIES (checked with the metadata below)"

echo "== grub.cfg =="
# One install entry, pointing at this port's kernel: stock's generic entry, with
# the parameters below changed. Stock's HoneyComb LX2 and ThinkPad X13s
# entries, serial console included, are meaningless here. Its UEFI Firmware
# Settings and Reboot entries are stock's, verbatim. Note the installer
# takes root=/dev/ram, which is vestigial (the cpio initrd becomes rootfs and
# /init runs) but kept for fidelity.
#
# console=tty0 -- THE SINGLE MOST IMPORTANT PARAMETER HERE.
#
#   Apple device trees set `chosen/stdout-path = serial0`. With no console= on
#   the cmdline Linux honours that, so /dev/console becomes a UART with nothing
#   attached to it: every installer prompt goes into the void and every `read`
#   blocks forever. The machine looks hung with a live kernel behind it.
#
#   It is not machine-specific -- every Apple machine has stdout-path in its DT.
#
#   The stock generic entry does not need it because ordinary EFI/UEFI firmware
#   leaves stdout-path pointing somewhere real.
#
# tty1noaskfirst -- VANILLA: Slackware's own generic entry carries it
#   (efi_generic.iso /grub.cfg). It stops rc.installerconfig appending
#   'tty1::askfirst:-/bin/bash' to inittab. With console=tty0 in place
#   /dev/console IS tty1, so the shipped '::respawn:-/bin/bash' already
#   provides the shell, and an askfirst entry would be a SECOND process reading
#   the same keyboard: a "press enter to activate this console" prompt under
#   the installer banner, and lost keystrokes. Both are needed, together.
#
# RCFONT -- left off, though stock's entry carries it.
#   rc.S runs rc.font only when RCFONT is on the command line, so Slackware's
#   own default is not to run it. Leaving it off gives the classic console
#   (kernel_armv8-mac has FONT_8x16=y).
#
# WHY THE SEARCH IS SHAPED LIKE THAT.
#
#   The medium finds itself by volume label. From an ISO9660 image that is
#   "SLKins_aio-pkgs". From a USB stick written the way a user actually writes
#   one -- Rufus in its default ISO mode, which lays down FAT32 -- it is
#   "SLKINS_AIO-", because FAT32 labels are 11 characters and upper-cased.
#
#   The initrd already carries a patch teaching the INSTALLER's own source
#   auto-detection about that truncation. GRUB needs the same thing one stage
#   earlier.
#
#   THE TRUNCATED LABEL IS TRIED FIRST, deliberately. GRUB prints a command's
#   own error message even inside `if !`, so whichever search runs first and
#   misses puts an error on screen and pauses the boot. Rufus is what the
#   instructions tell people to use, so the FAT32 form is the common case and
#   goes first; a dd-written or optical image takes one miss and then matches.
#
#   ⚠ DO NOT GUARD THIS WITH `[ -e /boot/<kernel> ]` to skip searching when
#   $root is already right. It makes things worse: `[` is
#   supplied by GRUB's `test` module, which is NOT built into Slackware's
#   BOOTAA64.EFI and is never insmod'ed here. The other insmods in the entry
#   are no-ops because those modules ARE built in, so the omission is silent
#   until boot, where it reads:
#
#       error: ... grub_script_function_find:119:can't find command `['.
#       error: ... grub_search_label:371:no such device: SLKins_aio-pkgs.
#
#   The failed test then made `if !` true, so every search ran anyway and the
#   guard bought nothing but an extra error line.
#
#   Deliberately NOT `search --file`: after the first install the target's
#   /boot holds a kernel of the same name, so a file search can select the
#   internal disk and boot the installed kernel with the medium's initrd.
cat > "$OV/grub.cfg" <<EOF
set timeout=30
set default=0

menuentry "$KTITLE" {
   echo "Loading Slackware Installer..."
   insmod part_gpt
   insmod part_msdos
   insmod linux
   insmod iso9660
   insmod udf
   if ! search --no-floppy --label $VOLID_FAT --set=root ; then
      search --no-floppy --label $VOLID --set=root
   fi
   linux /boot/$KIMAGE console=tty0 root=/dev/ram rw nic=auto:eth0:dhcp mitigations=off platwalk tty1noaskfirst bl_grub
   initrd /boot/initrd-mac.img
}

##SLKuefi_settings
menuentry --hotkey=f "[ UEFI Firmware Settings ]" {
   echo "Loading UEFI Firmware Menu..."
   fwsetup
}
##SLKuefi_settings

##SLKreboot
menuentry --hotkey=r "[ Reboot ]" {
   echo "Rebooting..."
   reboot
}
##SLKreboot
EOF
info "1 install entry, stock HoneyComb LX2 and ThinkPad X13s entries dropped"
# Assert the parameters above are actually present. Each is a one-token edit
# in a heredoc, and each fails at a boot rather than here if it goes missing --
# console=tty0 as a machine that looks hung, the label fallback as an installer
# that cannot find its own packages.
for want in "console=tty0" "tty1noaskfirst" "$VOLID_FAT" "menuentry \"$KTITLE\""; do
  grep -qF "$want" "$OV/grub.cfg" \
    || die "grub.cfg is missing '$want' -- a medium without it fails at boot
  (see the comments above). Refusing to build it."
done

# The TRUNCATED label must be searched FIRST. Rufus is what the instructions
# tell people to use, so FAT32 is the common case; searching the ISO9660 label
# first puts "no such device" on screen and pauses every USB boot.
_fat_at=$(grep -n -- "--label $VOLID_FAT" "$OV/grub.cfg" | head -1 | cut -d: -f1)
_iso_at=$(grep -n -- "--label $VOLID " "$OV/grub.cfg" | head -1 | cut -d: -f1)
[ -n "$_fat_at" ] && [ -n "$_iso_at" ] && [ "$_fat_at" -lt "$_iso_at" ] \
  || die "grub.cfg searches the ISO9660 label before the truncated FAT32 one.
  On a Rufus-written stick that prints an error and pauses before booting."

# And it must NOT be guarded by '['. That comes from GRUB's test module, which
# is not built into Slackware's BOOTAA64.EFI and is never insmod'ed here, so
# the guard cannot run: it errors, 'if !' takes the branch anyway, and the boot
# gains two error lines and a pause.
grep -qF "[ -e /boot/$KIMAGE ]" "$OV/grub.cfg" \
  && die "grub.cfg guards the search with '[', which needs GRUB's test module.
  That module is absent from this BOOTAA64.EFI -- the guard errors at boot."
info "grub.cfg      : console=tty0, tty1noaskfirst, FAT32 label first, no test-module guard"

echo "== macOS firmware gatherer =="
# Shipped at the ISO ROOT, because the only place it is useful is macOS -- and
# macOS reads ISO9660 as well as the FAT32 that Rufus writes in its default ISO
# mode, so it can be run straight off the install stick with nothing downloaded.
#
# Optional by design: skip it and the installed system falls back to the
# firmware the Asahi installer bundled. Documented in docs/INSTALLING.md only.
#
# CR-stripped for the same reason the kernel SlackBuild strips slk-hwm-discover:
# a shebang with a trailing CR is a script that will not run, and a tree edited
# on a Windows filesystem acquires them silently.
[ -r "$TOOLSDIR/macos-fw-harvest.sh" ] \
  || die "macos-fw-harvest.sh missing from $TOOLSDIR -- cannot ship the gatherer"
sed 's/\r$//' "$TOOLSDIR/macos-fw-harvest.sh" > "$OV/macos-fw-harvest.sh"
chmod 755 "$OV/macos-fw-harvest.sh"
head -1 "$OV/macos-fw-harvest.sh" | grep -q $'\r' \
  && die "macos-fw-harvest.sh shebang still carries CR after stripping"
sh -n "$OV/macos-fw-harvest.sh" \
  || die "macos-fw-harvest.sh does not parse -- refusing to ship it"
info "gatherer      : macos-fw-harvest.sh staged for the ISO root, parses cleanly"

echo "== metadata =="
# Removing kernel_armv8 and Slackware's pipewire and mesa, adding this port's.
# Match .txz exactly: a bare 'kernel_armv8*' glob also catches the .txz.asc
# signature, which must be removed too -- leaving it behind orphans a signature
# for a package that is no longer on the media.
# Anchor on a DIGIT after the hyphen. A bare 'kernel_armv8-' prefix also matches
# this port's own kernel package, so a directory holding both would have the
# "remove the stock kernel" step take this port's off the medium too. This reads
# the pristine ISO, but the regex should not be the only thing preventing it.
STOCK_KERNEL=$(ls "$MNT/$TREE/a" | grep -E '^kernel_armv8-[0-9].*\.txz$' | head -1 || true)
STOCK_PW=$(ls "$MNT/$TREE/l" | grep -E '^pipewire-[0-9].*\.txz$' | head -1 || true)
STOCK_MESA=$(ls "$MNT/$TREE/x" | grep -E '^mesa-[0-9].*\.txz$' | head -1 || true)
info "removing: ${STOCK_KERNEL:-<none>} ${STOCK_PW:-<none>} ${STOCK_MESA:-<none>}"

# ---- medium metadata (begin) ------------------------------------------------
#
# THE MEDIUM'S INDEXES MUST DESCRIBE THE MEDIUM.
#
# Stock carries five, and each has a reader:
#
#   PACKAGES.TXT    at the top of the tree, with an identical copy in
#                   slackware/ (a symlink on the mirror). Setup's FTP/HTTP
#                   source (INSURL) builds its whole package tree from the
#                   TOP-LEVEL one, and slackpkg reads it: a package missing
#                   there is a package a network install never installs.
#   CHECKSUMS.md5   one per level: ./slackware/<series>/... at the top,
#                   ./<series>/... inside slackware/.
#   FILELIST.TXT    at the top, an ls -l of the tree.
#   FILE_LIST       in slackware/, the same for the series directories, kept
#                   for checking a mirror against.
#   MANIFEST.bz2    in slackware/, every package's contents (slackpkg
#                   file-search).
#
# Each is rebuilt for exactly what this medium changes: the stock packages it
# removes, the packages it adds, the series files rewritten above (tagfile,
# maketag, maketag.ez) and the indexes themselves. Stock's order is kept, so
# each index lists the others as they finally are (in the base they agree
# exactly): PACKAGES.TXT and MANIFEST.bz2, then FILE_LIST, then the inner
# CHECKSUMS.md5, then FILELIST.TXT, then the top-level CHECKSUMS.md5, which
# nothing lists.
#
# Both CHECKSUMS.md5.asc are removed, the same way each removed package's .asc
# is: they are Slackware's signatures over files this build rewrites, and a
# signature that fails verification is worse than none. The medium's metadata
# is unsigned, like this port's packages (docs/BUILD.md).
#
# Paths below are relative to ROOT, the top of the Slackware tree, as the
# top-level indexes write them.
ROOT=${TREE%/*}               # slackware/slackwareaarch64-current
SLK=${TREE##*/}               # slackware
mkdir -p "$OV/$ROOT"

mm_removed=""
for _p in "a:$STOCK_KERNEL" "l:$STOCK_PW" "x:$STOCK_MESA"; do
  _s=${_p%%:*}; _b=${_p#*:}
  [ -n "$_b" ] || continue
  mm_removed="$mm_removed $SLK/$_s/${_b%.txz}.txt $SLK/$_s/$_b $SLK/$_s/$_b.asc"
done
mm_removed="$mm_removed CHECKSUMS.md5.asc $SLK/CHECKSUMS.md5.asc"
mm_is_removed() { case " $mm_removed " in *" $1 "*) return 0 ;; esac; return 1; }

# This port's files, and the series files this build rewrites.
mm_ours=""; mm_tags=""
for _s in $OUR_SERIES; do
  mm_tags="$mm_tags $SLK/$_s/tagfile $SLK/$_s/maketag $SLK/$_s/maketag.ez"
  for _f in "$OV/$TREE/$_s"/*.txz; do
    [ -e "$_f" ] || continue
    _b=$(basename "$_f" .txz)
    mm_ours="$mm_ours $SLK/$_s/$_b.txz $SLK/$_s/$_b.txt"
  done
done

# mm_sums <stock CHECKSUMS.md5> <prefix its paths omit> <out> <paths...>
# Stock's header, then its lines minus every removed or re-listed path, plus a
# fresh line for each path given, sorted by path as stock's are.
mm_sums() {
  local src=$1 strip=$2 out=$3 p; shift 3
  {
    awk '/^[0-9a-f]{32}  \.\//{exit} {print}' "$src"
    {
      awk -v drop=" $mm_removed $* " -v strip="$strip" '
        /^[0-9a-f]{32}  \.\// {
          if (index(drop, " " strip substr($0, 37) " ")) next
          print
        }' "$src"
      for p in "$@"; do
        echo "$(md5sum < "$OV/$ROOT/$p" | cut -d' ' -f1)  ./${p#"$strip"}"
      done
    } | LC_ALL=C sort -k2,2
  } > "$out"
}

# mm_filelist <stock FILELIST.TXT or FILE_LIST> <prefix its paths omit> <out> <paths...>
# Stock's list minus every removed or re-listed path, plus an ls -l line for
# each path given. A symlink line ends "./path -> target"; the path is the
# field before the arrow.
mm_filelist() {
  local src=$1 strip=$2 out=$3 p line; shift 3
  {
    awk -v drop=" $mm_removed $* " -v strip="$strip" '
      / \.\// {
        q = $0; sub(/ -> .*$/, "", q); n = split(q, F, " ")
        p = F[n]; sub(/^\.\//, "", p)
        if (index(drop, " " strip p " ")) next
      }
      { print }' "$src"
    for p in "$@"; do
      line=$(cd "$OV/$ROOT" && ls -l --time-style=long-iso "$p")
      echo "${line% "$p"} ./${p#"$strip"}"
    done
  } > "$out"
}

# 1. PACKAGES.TXT: one file, written to both places.
cmp -s "$MNT/$ROOT/PACKAGES.TXT" "$MNT/$TREE/PACKAGES.TXT" \
  || die "the base's two PACKAGES.TXT differ. Stock keeps them identical (one is
  a symlink on the mirror); re-check this before building on that base."
awk -v rm=" $STOCK_KERNEL $STOCK_PW $STOCK_MESA " '
  BEGIN { RS = ""; ORS = "\n\n" }
  {
    split($0, L, "\n")
    if (L[1] ~ /^PACKAGE NAME:  /) {
      n = L[1]; sub(/^PACKAGE NAME:  /, "", n)
      if (index(rm, " " n " ")) next
    }
    print
  }' "$MNT/$ROOT/PACKAGES.TXT" > "$OV/$ROOT/PACKAGES.TXT"
for _s in $OUR_SERIES; do
  for _f in "$OV/$TREE/$_s"/*.txz; do
    [ -e "$_f" ] || continue
    _b=$(basename "$_f")
    # Uncompressed size from xz's own index: field 5 of its `totals` line.
    # `|| _u=""` so a failing xz reaches the die below instead of set -e.
    _u=$(xz --robot --list "$_f" 2>/dev/null | awk -F'\t' '$1 == "totals" {print $5}') || _u=""
    case "$_u" in
      ''|*[!0-9]*) die "cannot read the uncompressed size of $_b" ;;
    esac
    {
      echo "PACKAGE NAME:  $_b"
      echo "PACKAGE LOCATION:  ./$SLK/$_s"
      echo "PACKAGE SIZE (compressed):  $(( $(stat -c%s "$_f") / 1024 )) K"
      echo "PACKAGE SIZE (uncompressed):  $(( _u / 1024 )) K"
      echo "PACKAGE DESCRIPTION:"
      cat "${_f%.txz}.txt"
      echo
    } >> "$OV/$ROOT/PACKAGES.TXT"
  done
done
# The header's totals, computed as stock's are: every record's size, summed,
# in whole MB (this reproduces the base's own figures exactly).
mm_totals() {
  awk '/^PACKAGE SIZE \(compressed\):/ {c += $4} /^PACKAGE SIZE \(uncompressed\):/ {u += $4}
       END {printf "%d %d\n", c / 1024, u / 1024}' "$1"
}
read -r _c _u < <(mm_totals "$OV/$ROOT/PACKAGES.TXT")
sed -i -e "s/^\(Total size of all packages (compressed):  \)[0-9]* MB$/\1$_c MB/" \
       -e "s/^\(Total size of all packages (uncompressed):  \)[0-9]* MB$/\1$_u MB/" \
  "$OV/$ROOT/PACKAGES.TXT"
cp "$OV/$ROOT/PACKAGES.TXT" "$OV/$TREE/PACKAGES.TXT"

# 2. MANIFEST.bz2. A section opens at the "++====" line that starts its
#    three-line "Package:" header and runs to the next one.
bzip2 -dc "$MNT/$TREE/MANIFEST.bz2" > "$OV/MANIFEST.work" \
  || die "cannot read the base's MANIFEST.bz2"
{
  awk -v rm=" ${STOCK_KERNEL:+./a/$STOCK_KERNEL} ${STOCK_PW:+./l/$STOCK_PW} ${STOCK_MESA:+./x/$STOCK_MESA} " '
    { L[NR] = $0 }
    END {
      n = 0
      for (i = 1; i <= NR; i++)
        if (L[i] ~ /^\+\+=+$/ && L[i+1] == "||" && L[i+2] ~ /^\|\|   Package:  /)
          start[++n] = i
      start[n + 1] = NR + 1
      for (i = 1; i < start[1]; i++) print L[i]
      for (k = 1; k <= n; k++) {
        pkg = L[start[k] + 2]; sub(/^\|\|   Package:  /, "", pkg)
        if (index(rm, " " pkg " ")) continue
        for (i = start[k]; i < start[k + 1]; i++) print L[i]
      }
    }' "$OV/MANIFEST.work"
  for _s in $OUR_SERIES; do
    for _f in "$OV/$TREE/$_s"/*.txz; do
      [ -e "$_f" ] || continue
      printf '++========================================\n||\n||   Package:  ./%s/%s\n||\n++========================================\n' \
        "$_s" "$(basename "$_f")"
      tar tvvf "$_f"
      printf '\n\n'
    done
  done
} | bzip2 -9 > "$OV/$TREE/MANIFEST.bz2"
rm -f "$OV/MANIFEST.work"

# 3. FILE_LIST, which lists the series directories and nothing else.
mm_filelist "$MNT/$TREE/FILE_LIST" "$SLK/" "$OV/$TREE/FILE_LIST" $mm_ours $mm_tags

# 4-6. The checksums and the top-level file list, in stock's order.
mm_sums "$MNT/$TREE/CHECKSUMS.md5" "$SLK/" "$OV/$TREE/CHECKSUMS.md5" \
  $mm_ours $mm_tags "$SLK/MANIFEST.bz2" "$SLK/FILE_LIST"
mm_filelist "$MNT/$ROOT/FILELIST.TXT" "" "$OV/$ROOT/FILELIST.TXT" \
  $mm_ours $mm_tags PACKAGES.TXT "$SLK/CHECKSUMS.md5" "$SLK/MANIFEST.bz2" "$SLK/FILE_LIST"
mm_sums "$MNT/$ROOT/CHECKSUMS.md5" "" "$OV/$ROOT/CHECKSUMS.md5" \
  $mm_ours $mm_tags PACKAGES.TXT FILELIST.TXT "$SLK/MANIFEST.bz2" "$SLK/FILE_LIST"

# THE GATE. Every index is checked against what the medium will carry, the way
# its consumers read it, before anything is written.
mm_fail=0
mm_bad() { echo "  METADATA: $*" >&2; mm_fail=1; }
# a. Replay INSURL: every PACKAGES.TXT record resolves to a file on the medium.
while IFS=$'\t' read -r _n _loc; do
  case "$_loc" in
    "./$SLK/"*) ;;
    *) mm_bad "$_n has location $_loc, not ./$SLK/<series>"; continue ;;
  esac
  _rel=${_loc#./}/$_n
  if [ -e "$OV/$ROOT/$_rel" ]; then :
  elif [ -e "$MNT/$ROOT/$_rel" ] && ! mm_is_removed "$_rel"; then :
  else mm_bad "$_n points at $_rel, which the medium does not carry"; fi
done < <(awk '/^PACKAGE NAME:  /{n = $3} /^PACKAGE LOCATION:  /{print n "\t" $3}' "$OV/$ROOT/PACKAGES.TXT")
# b. Every package in the series this build stages has exactly one record.
for _s in $OUR_SERIES; do
  for _f in "$MNT/$TREE/$_s"/*.txz "$OV/$TREE/$_s"/*.txz; do
    [ -e "$_f" ] || continue
    _b=$(basename "$_f")
    case "$_f" in "$MNT"/*) mm_is_removed "$SLK/$_s/$_b" && continue ;; esac
    _c=$(grep -cxF "PACKAGE NAME:  $_b" "$OV/$ROOT/PACKAGES.TXT" || true)
    [ "$_c" = 1 ] || mm_bad "$SLK/$_s/$_b has $_c PACKAGES.TXT records"
  done
done
cmp -s "$OV/$ROOT/PACKAGES.TXT" "$OV/$TREE/PACKAGES.TXT" \
  || mm_bad "the two PACKAGES.TXT copies differ"
read -r _c _u < <(mm_totals "$OV/$ROOT/PACKAGES.TXT")
grep -qx "Total size of all packages (compressed):  $_c MB" "$OV/$ROOT/PACKAGES.TXT" \
  && grep -qx "Total size of all packages (uncompressed):  $_u MB" "$OV/$ROOT/PACKAGES.TXT" \
  || mm_bad "the PACKAGES.TXT header totals do not match its records"
# c. Nothing still names a removed file.
bzip2 -dc "$OV/$TREE/MANIFEST.bz2" > "$OV/MANIFEST.check"
for _r in $mm_removed; do
  grep -qxF "PACKAGE NAME:  ${_r##*/}" "$OV/$ROOT/PACKAGES.TXT" && mm_bad "PACKAGES.TXT still lists ${_r##*/}"
  grep -qF "  ./$_r" "$OV/$ROOT/CHECKSUMS.md5" && mm_bad "CHECKSUMS.md5 still lists $_r"
  grep -qF "  ./${_r#"$SLK/"}" "$OV/$TREE/CHECKSUMS.md5" && mm_bad "$SLK/CHECKSUMS.md5 still lists $_r"
  grep -qE " \./${_r//./\\.}( |\$)" "$OV/$ROOT/FILELIST.TXT" && mm_bad "FILELIST.TXT still lists $_r"
  _rr=${_r#"$SLK/"}
  grep -qE " \./${_rr//./\\.}( |\$)" "$OV/$TREE/FILE_LIST" && mm_bad "$SLK/FILE_LIST still lists $_r"
  grep -qxF "||   Package:  ./${_r#"$SLK/"}" "$OV/MANIFEST.check" && mm_bad "MANIFEST.bz2 still lists $_r"
done
# d. Every re-listed path appears exactly once, with its real checksum and size.
for _p in $mm_ours $mm_tags PACKAGES.TXT FILELIST.TXT "$SLK/MANIFEST.bz2" "$SLK/FILE_LIST"; do
  _m=$(md5sum < "$OV/$ROOT/$_p" | cut -d' ' -f1)
  [ "$(grep -cxF "$_m  ./$_p" "$OV/$ROOT/CHECKSUMS.md5")" = 1 ] \
    || mm_bad "CHECKSUMS.md5 does not list $_p with its checksum, once"
done
for _p in $mm_ours $mm_tags "$SLK/MANIFEST.bz2" "$SLK/FILE_LIST"; do
  _m=$(md5sum < "$OV/$ROOT/$_p" | cut -d' ' -f1)
  [ "$(grep -cxF "$_m  ./${_p#"$SLK/"}" "$OV/$TREE/CHECKSUMS.md5")" = 1 ] \
    || mm_bad "$SLK/CHECKSUMS.md5 does not list $_p with its checksum, once"
done
for _p in $mm_ours $mm_tags PACKAGES.TXT "$SLK/CHECKSUMS.md5" "$SLK/MANIFEST.bz2" "$SLK/FILE_LIST"; do
  _z=$(stat -c%s "$OV/$ROOT/$_p")
  [ "$(awk -v p="./$_p" -v z="$_z" '$NF == p && $5 == z' "$OV/$ROOT/FILELIST.TXT" | wc -l)" = 1 ] \
    || mm_bad "FILELIST.TXT does not list $_p at its size, once"
done
for _p in $mm_ours $mm_tags; do
  _z=$(stat -c%s "$OV/$ROOT/$_p")
  [ "$(awk -v p="./${_p#"$SLK/"}" -v z="$_z" '$NF == p && $5 == z' "$OV/$TREE/FILE_LIST" | wc -l)" = 1 ] \
    || mm_bad "$SLK/FILE_LIST does not list $_p at its size, once"
done
for _p in $mm_ours; do
  case "$_p" in *.txz) ;; *) continue ;; esac
  [ "$(grep -cxF "||   Package:  ./${_p#"$SLK/"}" "$OV/MANIFEST.check")" = 1 ] \
    || mm_bad "MANIFEST.bz2 does not hold one section for $_p"
done
rm -f "$OV/MANIFEST.check"
# e. Each series' checklists name exactly the packages the medium carries there,
#    in C order, as stock's do: one line each, and each of the two loops once.
for _s in $OUR_SERIES; do
  for _f in "$MNT/$TREE/$_s"/*.txz "$OV/$TREE/$_s"/*.txz; do
    [ -e "$_f" ] || continue
    case "$_f" in "$MNT"/*) mm_is_removed "$SLK/$_s/${_f##*/}" && continue ;; esac
    basename "$_f" .txz | sed -E 's/-[^-]+-[^-]+-[^-]+$//'
  done | LC_ALL=C sort > "$OV/series.want"
  for _m in maketag maketag.ez; do
    _f=$OV/$TREE/$_s/$_m
    sed -nE 's/^"([^"]+)" "[^"]*" "(on|off)" [\]$/\1/p' "$_f" > "$OV/series.have"
    LC_ALL=C sort -c "$OV/series.have" 2>/dev/null \
      || mm_bad "$SLK/$_s/$_m: its checklist is not in C order"
    LC_ALL=C sort "$OV/series.have" | cmp -s - "$OV/series.want" \
      || mm_bad "$SLK/$_s/$_m: its checklist does not list exactly the packages in $SLK/$_s"
    _n=0
    while read -r _l; do
      _n=$((_n + 1))
      printf '%s\n' "$_l" | sed -E 's/[[:space:]]+[\].*$//' | tr ' ' '\n' | sed '/^$/d' \
        | LC_ALL=C sort | cmp -s - "$OV/series.want" \
        || mm_bad "$SLK/$_s/$_m: package loop $_n does not name exactly the packages in $SLK/$_s"
    done < <(grep -A1 -E '^[[:space:]]*for (PKG|PACKAGE) in [\]$' "$_f" | grep -vE '^[[:space:]]*for |^--$')
    [ "$_n" = 2 ] || mm_bad "$SLK/$_s/$_m has $_n package loops, not stock's 2"
  done
done
rm -f "$OV/series.want" "$OV/series.have"
[ "$mm_fail" -eq 0 ] || die "the medium's package indexes do not describe the medium (above)"
info "metadata      : PACKAGES.TXT x2, CHECKSUMS.md5 x2, FILELIST.TXT, FILE_LIST, MANIFEST.bz2 rebuilt; checklists match; gate passed"
# ---- medium metadata (end) --------------------------------------------------

echo "== building ISO =="
# Clear any previous output first. xorriso refuses to write when -indev and
# -outdev differ and the outdev already holds data:
#
#   FAILURE : -indev differs from -outdev and -outdev media holds non-zero data
#
# The failure arrives *after* the -rm steps have reported success, which reads
# like the removals broke it. They did not. Delete the stale image up front.
if [ -e "$ISO_OUT" ]; then
  info "removing previous $ISO_OUT ($(stat -c%s "$ISO_OUT") bytes)"
  rm -f "$ISO_OUT"
fi

# -boot_image any keep is NOT optional: without it xorriso discards the El
# Torito record and the result will not boot on any firmware.
xorriso -indev "$ISO_IN" -outdev "$ISO_OUT" \
  -volid "$VOLID" \
  -boot_image any keep \
  -rm "/boot/Image-armv8" -- \
  -rm "/boot/initrd-armv8.img" -- \
  ${STOCK_KERNEL:+-rm "/$TREE/a/$STOCK_KERNEL" --} \
  ${STOCK_KERNEL:+-rm_r "/$TREE/a/${STOCK_KERNEL%.txz}.txt" --} \
  ${STOCK_KERNEL:+-rm_r "/$TREE/a/${STOCK_KERNEL}.asc" --} \
  ${STOCK_PW:+-rm "/$TREE/l/$STOCK_PW" --} \
  ${STOCK_PW:+-rm_r "/$TREE/l/${STOCK_PW%.txz}.txt" --} \
  ${STOCK_PW:+-rm_r "/$TREE/l/${STOCK_PW}.asc" --} \
  ${STOCK_MESA:+-rm "/$TREE/x/$STOCK_MESA" --} \
  ${STOCK_MESA:+-rm_r "/$TREE/x/${STOCK_MESA%.txz}.txt" --} \
  ${STOCK_MESA:+-rm_r "/$TREE/x/${STOCK_MESA}.asc" --} \
  -rm "/$ROOT/CHECKSUMS.md5.asc" -- \
  -rm "/$TREE/CHECKSUMS.md5.asc" -- \
  -map "$OV/boot/$KIMAGE"            "/boot/$KIMAGE" \
  -map "$OV/boot/initrd-mac.img"   /boot/initrd-mac.img \
  -map "$OV/grub.cfg"                /grub.cfg \
  -map "$OV/macos-fw-harvest.sh"     /macos-fw-harvest.sh \
  -map "$OV/$TREE/a"                 "/$TREE/a" \
  -map "$OV/$TREE/d"                 "/$TREE/d" \
  -map "$OV/$TREE/l"                 "/$TREE/l" \
  -map "$OV/$TREE/x"                 "/$TREE/x" \
  -map "$OV/$TREE/CHECKSUMS.md5"     "/$TREE/CHECKSUMS.md5" \
  -map "$OV/$TREE/PACKAGES.TXT"      "/$TREE/PACKAGES.TXT" \
  -map "$OV/$TREE/MANIFEST.bz2"      "/$TREE/MANIFEST.bz2" \
  -map "$OV/$TREE/FILE_LIST"         "/$TREE/FILE_LIST" \
  -map "$OV/$ROOT/CHECKSUMS.md5"     "/$ROOT/CHECKSUMS.md5" \
  -map "$OV/$ROOT/PACKAGES.TXT"      "/$ROOT/PACKAGES.TXT" \
  -map "$OV/$ROOT/FILELIST.TXT"      "/$ROOT/FILELIST.TXT" \
  -commit 2>&1 | grep -viE '^xorriso : UPDATE|^Added to ISO' | tail -20

[ -s "$ISO_OUT" ] || die "no ISO produced"

# The signatures over the rewritten checksums must be gone from the medium,
# not merely absent from the overlay.
xorriso -indev "$ISO_OUT" -ls "/$ROOT" "/$TREE" 2>/dev/null | grep -q 'CHECKSUMS\.md5\.asc' \
  && die "a CHECKSUMS.md5.asc is still on the medium; it no longer matches its file"
info "signatures    : neither CHECKSUMS.md5.asc is on the medium"

echo
echo "== verifying the result =="
xorriso -indev "$ISO_OUT" -report_el_torito plain 2>/dev/null \
  | grep -iE "Volume id|El Torito (catalog|boot img|img path)" | sed 's/^/  /'
echo "  size: $(stat -c%s "$ISO_OUT") bytes"
echo
echo "  $ISO_OUT"
# These images carry El Torito but no hybrid MBR, so a dd'd stick presents raw
# ISO9660 and depends on U-Boot reading it; a Rufus write in its default ISO
# mode lays down FAT32 instead. docs/INSTALLING.md says which to use.
echo
echo "  Write it to a USB stick as docs/INSTALLING.md describes."
