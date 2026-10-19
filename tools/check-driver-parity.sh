#!/bin/bash
#
# check-driver-parity.sh -- assert a built kernel package enables every driver
# vanilla Asahi's kernel config enables, and ships every module it built.
#
#   check-driver-parity.sh /path/to/kernel_armv8-mac-<ver>-aarch64-<n>_mac.txz
#
# Reads the package and the parity spec. Nothing else: no build host, no
# network, no running kernel.
#
# WHY THIS IS DERIVED AND NOT TYPED
# ---------------------------------
# A typed list of drivers asserts only what its author remembered, and a driver
# missing from it looks exactly like a driver nobody wanted: the gate reports
# green while, say, apple_wdt is absent and the SoC watchdog (left running by
# U-Boot, never claimed) resets the machine mid-boot with nothing on screen.
# So the required set is read from vanilla Asahi's config -- if Asahi gains a
# driver, this picks it up with no edit here.
#
# TWO CHECKS
# ----------
#   parity        every CONFIG_*=y|m in the spec is =y|m in the package's own
#                 /boot/config. Presence, not form: built-in versus modular
#                 follows the spec at build time, but whether a driver is in
#                 vmlinux is a packaging detail upstream is free to change.
#   completeness  every module the build produced (modules.order) is in the
#                 package. A config that enables a driver proves nothing if
#                 its .ko never made it into the .txz.
#
# Excepted from parity, and only these: the deliberate divergences in
# migrate-kernel-config.sh's PARITY_EXCEPT (read from there, so the two cannot
# drift) and SHORTFALL below.
#
# The spec is the file tools/fetch-sources.sh pins for the ASAHI_TAG the kernel
# SlackBuild names.

set -uo pipefail

PKG=${1:-}
TOOLS=$(cd "$(dirname "$0")" && pwd)
KSRC=$TOOLS/../source/kernel_armv8-mac

die()  { echo "check-driver-parity: $*" >&2; exit 1; }
info() { echo "  $*"; }

[ -n "$PKG" ] || {
  sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}
[ -f "$PKG" ] || die "no such package: $PKG"

tag=$(sed -nE 's/^ASAHI_TAG=\$\{ASAHI_TAG:-([^}]+)\}.*/\1/p' "$KSRC/kernel_armv8-mac.SlackBuild")
[ -n "$tag" ] || die "cannot read ASAHI_TAG from kernel_armv8-mac.SlackBuild"
ASAHI_CFG=$KSRC/sources/config-$tag
# FATAL WHEN THE SPEC IS ABSENT, never a warning. An empty expected set is the
# exact condition under which a missing driver is indistinguishable from one
# nobody wanted, and the gate would report success unconditionally.
[ -s "$ASAHI_CFG" ] || die "no parity spec at $ASAHI_CFG.
  Fetch it with: tools/fetch-sources.sh kernel_armv8-mac"

# SYMBOLS THE SPEC ENABLES THAT THIS SOURCE CANNOT PROVIDE: explicit, never
# implicit. Each entry needs a reason. migrate-kernel-config.sh prints the
# candidates as its parity SHORTFALL; nothing goes here without reading why.
#
# None today. The last was EXT4_USE_FOR_EXT2, which is `depends on
# EXT2_FS=n`; migrate-kernel-config.sh now switches EXT2_FS off, so ext4
# mounts ext2 here as it does in vanilla Asahi.
SHORTFALL=''

# The policy divergences, from the one place they are decided.
EXCEPT=$(sed -n '/^PARITY_EXCEPT=(/,/^)/p' "$TOOLS/migrate-kernel-config.sh" \
         | grep -oE '^ *CONFIG_[A-Z0-9_]+' | tr -d ' ' | tr '\n' ' ')
[ -n "$EXCEPT" ] || die "cannot read PARITY_EXCEPT from migrate-kernel-config.sh"

# List once to a file; never `tar tf | grep -q`. grep -q exits on the first
# match, tar takes SIGPIPE, and pipefail turns a SUCCESSFUL match into a
# failure -- a check that reports failure against output that satisfies it.
listing=$(mktemp); ours=$(mktemp)
trap 'rm -f "$listing" "$ours"' EXIT
tar tf "$PKG" > "$listing" || die "cannot list $PKG"

KREL=$(sed -nE 's|^lib/modules/([^/]+)/.*|\1|p' "$listing" | head -1)
[ -n "$KREL" ] || die "$PKG has no lib/modules/<release>/ -- is it a kernel package?"
info "package       : $(basename "$PKG")"
info "kernel release: $KREL"
info "parity spec   : $(basename "$ASAHI_CFG") ($(sed -n '3s/^# //p' "$ASAHI_CFG"))"

# Duties inherited from kernel_armv8, which this package replaces on its media.
# Without slk-hwm-discover, setup's board hooks show an error dialog; without
# the GRUB tool an installed machine has nothing to write its menuentry with.
for want in sbin/slk-hwm-discover usr/sbin/grub-entry-mac; do
  grep -qx "$want" "$listing" || die "package does not ship $want"
done

# --- parity ------------------------------------------------------------------
tar xOf "$PKG" "boot/config-armv8-mac-$KREL" > "$ours" 2>/dev/null
[ -s "$ours" ] || die "no boot/config-armv8-mac-$KREL in the package"

missing=""; n_spec=0; n_skip=0
while IFS='=' read -r k v; do
  n_spec=$((n_spec + 1))
  case " $EXCEPT $SHORTFALL " in *" $k "*) n_skip=$((n_skip + 1)); continue ;; esac
  grep -qE "^$k=[ym]$" "$ours" || missing="$missing ${k#CONFIG_}"
done < <(grep -E '^CONFIG_[A-Z0-9_]+=[ym]$' "$ASAHI_CFG")
info "parity        : spec enables $n_spec, excepted $n_skip, missing $(echo $missing | wc -w)"

# --- completeness ------------------------------------------------------------
order=$(tar xOf "$PKG" "lib/modules/$KREL/modules.order" 2>/dev/null || true)
[ -n "$order" ] || die "no lib/modules/$KREL/modules.order in the package.
  Without it there is no record of what the build produced to compare against."
lost=""
while read -r m; do
  grep -qE "^lib/modules/$KREL/${m%.ko}\.ko(\.[a-z]+)?$" "$listing" || lost="$lost ${m##*/}"
done <<<"$order"
info "completeness  : $(wc -l <<<"$order") modules built, $(echo $lost | wc -w) not packaged"

# THE MAC MINI M2's DEVICE TREE. Shipping every Apple DTB but the machine's
# own boots nothing. A tree is not a config symbol, so it gets its own stop.
grep -qE "^lib/modules/$KREL/dtbs/t8112-j473\.dtb$" "$listing" \
  || die "NO t8112-j473.dtb IN THE PACKAGE (lib/modules/$KREL/dtbs)
  The kernel SlackBuild builds the device trees (its dtbs target) and installs
  the Apple ones into the module directory; look there, not at the config."

[ -z "$lost" ] || die "MODULES BUILT BUT NOT PACKAGED:$lost"
[ -z "$missing" ] || die "ENABLED BY VANILLA ASAHI, ABSENT FROM THIS KERNEL:$missing
  Each is =y|m in $(basename "$ASAHI_CFG") and neither in this package's config.
  Fix the config (tools/migrate-kernel-config.sh); an exception needs a reason."

echo "  parity: complete"
