#!/bin/bash
#
# migrate-kernel-config.sh -- build this port's kernel config: Slackware's own
# config, plus every driver vanilla Asahi's config enables less the reasoned
# exceptions in PARITY_EXCEPT, and verify that the settings this port depends
# on survived.
#
# `make olddefconfig` resolves a config against a source tree, defaulting any
# newly-introduced symbols -- but it can silently DROP symbols whose
# dependencies changed. Losing CONFIG_ARM64_16K_PAGES or an Apple platform
# driver produces a kernel that builds perfectly and then fails on hardware.
#
# So this runs the migration and then ASSERTS a manifest of must-keep symbols,
# failing loudly if any regressed.
#
# Requires the kernel's own build dependencies, not only make and gcc: Kconfig
# offers CONFIG_RUST only when rustc, bindgen and the Rust source are present,
# and the parity spec's BTF settings need pahole. The kernel SlackBuild's
# "Build deps" line lists them.
#
# Usage:
#   ASAHI_CFG=<vanilla Asahi config> \
#   migrate-kernel-config.sh <kernel-src-dir> <slackware-config>
#
# Rust and the Apple GPU driver are required: the run fails unless
# CONFIG_DRM_ASAHI survives the migration.
#
# Writes the migrated config to <kernel-src-dir>/.config and a human diff to
# ./config-migration.diff.

set -euo pipefail

[ $# -eq 2 ] || { echo "usage: migrate-kernel-config.sh <kernel-src-dir> <slackware-config>" >&2; exit 2; }
SRC=$1
OLDCONF=$2

[ -f "$SRC/Makefile" ] || { echo "not a kernel source dir: $SRC" >&2; exit 1; }
[ -f "$OLDCONF" ] || { echo "no such config: $OLDCONF" >&2; exit 1; }

# ---------------------------------------------------------------------------
# THE LISTS
#   ADDED_ENABLE  built in (=y), each asserted =y
#   ADDED_MODULE  modules, each asserted =m specifically
#   DISABLE       switched off           SET_STR   string symbols set
#   MUST_Y        =y or =m afterwards    MUST_VAL  exact lines afterwards
# ---------------------------------------------------------------------------
# Built-in, whatever form the spec gives them: the path to /, the installer
# gaps, and what must work before userspace can load a module. THIS PORT
# SHIPS NO INITRAMFS, which is the reason for every entry that is not simply
# parity: a module cannot mount the root filesystem it lives on.
ADDED_ENABLE=(
  CONFIG_ARM64_16K_PAGES
  CONFIG_NVME_APPLE
  CONFIG_PCIE_APPLE
  CONFIG_APPLE_RTKIT
  CONFIG_APPLE_MAILBOX
  CONFIG_APPLE_SART
  CONFIG_EXT4_FS

  # PACKET: dhcpcd opens an AF_PACKET socket to do DHCP. As a module nothing
  # loads it before the installer's network setup runs, so DHCP fails and
  # retries in a loop, flooding the console with "bpf_open: Address family not
  # supported by protocol" -- no networking in the installer. When something
  # in the installer "just does not work", suspect a missing kernel symbol
  # before suspecting the software.
  CONFIG_PACKET

  # ROOT FILESYSTEMS setup offers: every one in the installer's MOD_FS, which
  # build-installer-initrd.sh checks against this kernel's config. Vanilla
  # builds most as modules, which is right where an initramfs loads them; here
  # a root on one would install cleanly and then fail to mount at boot. ext4
  # serves ext3 always, and ext2 through EXT4_USE_FOR_EXT2, as in vanilla's
  # config and Slackware's x86 one; that needs EXT2_FS off (see DISABLE).
  # Setup offers neither JFS nor F2FS on 16K pages (build-installer-initrd.sh
  # says why): F2FS keeps stock's module, and JFS is disabled below.
  CONFIG_EXT4_USE_FOR_EXT2
  CONFIG_XFS_FS
  CONFIG_BTRFS_FS

  # USB HID. Vanilla has these modular, and so could this config: the USB host
  # controllers (xHCI, DWC3, the ATC PHY) are modules that udev loads, and
  # rc.S starts udev before the root fsck, so a USB keyboard can answer that
  # prompt either way. Built in costs nothing, so they stay. The laptops'
  # internal keyboard is dockchannel/spi-hid below, built in.
  CONFIG_USB_HID
  CONFIG_HID_APPLE
  CONFIG_HID_MAGICMOUSE

  # Parity too, but listed so that it is ASSERTED: drm.edid_firmware= is the
  # cure for a sink that misbehaves on its own EDID, and a runtime debugfs
  # override cannot do the same job -- `status=on` applies it without a
  # modeset, `status=detect` re-reads the real EDID and discards it. The
  # override has to be in place before the first probe, i.e. on the kernel
  # command line.
  CONFIG_DRM_LOAD_EDID_FIRMWARE
  CONFIG_APPLE_DOCKCHANNEL  # M2 keyboard/trackpad transport
  CONFIG_HID_DOCKCHANNEL
  CONFIG_SPI_HID_APPLE_OF   # M1 keyboard/trackpad
  CONFIG_SPI_HID_APPLE_CORE
  CONFIG_RUST               # required by DRM_ASAHI
)
#
# NOT HERE, DELIBERATELY: the display path. DRM_APPLE, PHY_APPLE_DPTX,
# PHY_APPLE_ATC and TYPEC take whatever form the spec gives them, which is
# modular. Building DCP in also drags what it links against into vmlinux
# (`typec_mux_put`, `snd_card_new` -- otherwise the build fails at the final
# link, not at config time), and it changes the moment DCP takes the display
# over from m1n1. The console before the module loads is m1n1's framebuffer
# through DRM_SIMPLEDRM, which is built in.
#
# If a symbol is added back here because Kconfig is happy and the LINK is
# not, the ALSA core is the other half: SND depends on SOUND, and enabling
# SND while SOUND is =m silently demotes it back, taking SND_TIMER, SND_PCM,
# SND_SOC and SND_DMAENGINE_PCM with it. When an --enable does not take,
# look UP the dependency tree first.

# Modules. Where the parity spec has one of these =y, the parity pass below
# drops the entry and says so. DRM_ASAHI and the MACSMC input, charger and RTC
# drivers are not listed: the spec builds them in, so the parity pass enables
# them, and check-driver-parity.sh gates every symbol the spec enables.
ADDED_MODULE=(
  CONFIG_SND_SOC_APPLE_MACAUDIO
  CONFIG_SND_SOC_TAS2764
  CONFIG_SND_SOC_CS42L84
)

# CONFIG_IOMMU_DEFAULT_DMA_LAZY is here because it is the OTHER member of the
# choice that CONFIG_IOMMU_DEFAULT_DMA_STRICT belongs to, and asahi picks
# STRICT. Unlike the policy choices in PARITY_EXCEPT, this one is worth
# matching: it governs when the IOMMU invalidates TLB entries, and on this
# hardware the IOMMU is Apple's DART, sitting in front of the display
# controller, USB, audio DMA and the PCIe devices, among others. Lazy
# invalidation is a real behavioural difference there, not a latency
# preference. Same shape as ARM64_4K_PAGES: a choice member cannot be set
# while its sibling holds the slot, so the sibling is cleared here and the
# ADDED_ENABLE block below sets ours.
# The squashfs decompressor choice is the same shape again. Slackware's seed
# holds its slot with SQUASHFS_COMPILE_DECOMP_MULTI_PERCPU=y, so the member the
# spec picks (COMPILE_DECOMP_SINGLE) cannot be set while it stands; it is
# cleared with its other sibling, COMPILE_DECOMP_MULTI.
# SQUASHFS_CHOICE_DECOMP_BY_MOUNT is cleared as well: the whole compile-time
# choice is `depends on !` it, so a seed that set it would hide the spec's
# member entirely, and scripts/config --enable is a no-op on an invisible
# symbol.
# EXT2_FS goes for the same reason: EXT4_USE_FOR_EXT2 is `depends on
# EXT2_FS=n`, so while Slackware's ext2 module stands the ADDED_ENABLE entry
# cannot be set, and an ext2 root, which setup offers, cannot mount at boot.
# JFS_FS goes because it cannot run on this hardware: on 16K pages, memory
# compaction migrating JFS metadata pages crashes the kernel (a NULL
# dereference in remove_metapage), so mounting any JFS disk here is unsafe.
# Setup does not offer it, and PARITY_EXCEPT keeps parity from restoring it.
DISABLE=( CONFIG_ARM64_4K_PAGES CONFIG_LOCALVERSION_AUTO CONFIG_IOMMU_DEFAULT_DMA_LAZY
          CONFIG_SQUASHFS_CHOICE_DECOMP_BY_MOUNT
          CONFIG_SQUASHFS_COMPILE_DECOMP_MULTI
          CONFIG_SQUASHFS_COMPILE_DECOMP_MULTI_PERCPU
          CONFIG_EXT2_FS
          CONFIG_JFS_FS )
SET_STR=( "CONFIG_LOCALVERSION=-armv8-mac" )

# check_y accepts =y or =m, so the parity set can be listed regardless of how
# each one is built. A driver silently dropping out of the config is the
# failure this list exists to prevent.
MUST_Y=(
  CONFIG_ARCH_APPLE
  CONFIG_ARM64_16K_PAGES
  CONFIG_NVME_APPLE
  CONFIG_PCIE_APPLE
  CONFIG_I2C_APPLE
  CONFIG_SPI_APPLE
  CONFIG_PINCTRL_APPLE_GPIO
  CONFIG_APPLE_DART
  CONFIG_APPLE_AIC
  CONFIG_APPLE_SART
  CONFIG_MFD_MACSMC
  CONFIG_POWER_RESET_MACSMC
  CONFIG_APPLE_MAILBOX
  CONFIG_APPLE_RTKIT
  CONFIG_SPMI_APPLE
  CONFIG_DRM_APPLE
  CONFIG_PHY_APPLE_DPTX
  # Asserted, not merely requested: olddefconfig drops symbols whose
  # dependencies shift, and losing this one costs nothing visible at build
  # time -- the kernel boots fine and `drm.edid_firmware` simply does not
  # exist.
  CONFIG_DRM_LOAD_EDID_FIRMWARE
  CONFIG_DRM_ASAHI
  CONFIG_SND_SOC_APPLE_MACAUDIO
  CONFIG_SND_SOC_APPLE_MCA
  CONFIG_SND_SOC_TAS2764
  CONFIG_SND_SOC_CS42L84
  CONFIG_APPLE_DOCKCHANNEL
  CONFIG_HID_DOCKCHANNEL
  CONFIG_SPI_HID_APPLE_CORE
  CONFIG_INPUT_MACSMC_INPUT
  CONFIG_RTC_DRV_MACSMC
  CONFIG_RUST
)
MUST_VAL=(
  "CONFIG_PAGE_SHIFT=14"
  "CONFIG_LOCALVERSION=\"-armv8-mac\""
)

# ------------------------------------------------------------------------
# DERIVED PARITY WITH VANILLA ASAHI.
#
# Everything above this point is a HAND-WRITTEN list, and a hand-written list
# asserts only what its author remembered: a driver missing from it looks
# exactly like a driver nobody wanted. CONFIG_APPLE_WATCHDOG is the example
# that matters -- U-Boot leaves the Apple SoC watchdog running when Linux
# starts, so with no driver to claim it nothing feeds it and it resets the
# machine mid-boot, with no error message, on a timer.
#
# So the set is not typed. Read vanilla Asahi's own kernel config ($ASAHI_CFG:
# AsahiLinux/PKGBUILDs, for the same Asahi release as the source's delta) and
# take everything it enables that this tree can provide. Anything Asahi turns
# on for this hardware is in scope by definition, and a driver we do not ship
# is a driver the machine loses.
#
# Three outcomes per symbol, all reported rather than silently skipped, in the
# words the run prints:
#   +N builtin, +N module -- not yet on in this tree; we turn it on
#   already match         -- nothing to do
#   parity SHORTFALL      -- the symbol never appears in this tree, even after
#                            re-resolving to a fixed point. Near empty when
#                            spec and delta are the same Asahi release;
#                            anything listed is worth reading.
[ -n "${ASAHI_CFG:-}" ] && [ -r "$ASAHI_CFG" ] || {
  echo "migrate-kernel-config: no parity spec -- set ASAHI_CFG to vanilla Asahi's config." >&2
  echo "  Without it only the hand-written lists apply, which is how drivers go missing." >&2
  exit 1
}

# Deliberate divergences from vanilla. Each needs a reason, or it is not
# deliberate. Kconfig *choice* members, where selecting asahi's member means
# deselecting Slackware's; policy rather than hardware enablement, so the bar
# for overriding Slackware is "does it change what the machine can do"; and
# what cannot run on this hardware at all.
PARITY_EXCEPT=(
  CONFIG_LOCALVERSION_AUTO   # we set LOCALVERSION explicitly; see DISABLE above

  # asahi=INIT_STACK_NONE, Slackware=INIT_STACK_ALL_ZERO. Asahi turns stack
  # initialisation OFF for speed. Slackware's choice is strictly MORE
  # hardening at no cost in capability, so matching asahi here would be
  # copying a tradeoff we have no reason to want.
  CONFIG_INIT_STACK_NONE

  # asahi=SECURITY_YAMA on, Slackware=off. Slackware's own CONFIG_LSM already
  # lists yama, so building it in activates it, with ptrace_scope=1: a user
  # could no longer `strace -p` or `gdb -p` their own processes, which stock
  # Slackware allows. That is policy, and it takes something away from what
  # the machine lets a user do, so Slackware's choice stands.
  CONFIG_SECURITY_YAMA

  # asahi=JFS_FS module, with POSIX ACLs and security labels; Slackware=module.
  # Off here, with the options that exist only with it, because it cannot run
  # on this hardware: it crashes this 16K-page kernel (see DISABLE).
  CONFIG_JFS_FS
  CONFIG_JFS_POSIX_ACL
  CONFIG_JFS_SECURITY
)

echo "== migrating $(basename "$OLDCONF") -> $SRC =="
cp "$OLDCONF" "$SRC/.config"

( cd "$SRC" && make ARCH=arm64 olddefconfig )

# ---- derived parity classification -------------------------------------
#
# Runs HERE, after the first olddefconfig, and compares against $SRC/.config --
# the migrated config, which knows every symbol this source tree defines,
# including the ones the Asahi delta introduces. The seed config cannot be
# used: it is stock Slackware, which has mainline's Apple symbols but none the
# delta adds, so classifying against it declares every delta-provided driver
# "unavailable" and skips exactly the ones that need enabling.
#
# Value matters as well as presence. asahi=y with ours=m is a real difference
# -- a built-in driver can be depended on during kernel init, a module cannot
# -- so it is corrected, not accepted. asahi=m with ours=y is left alone:
# built-in is a superset of modular for anything that needs the driver present.

# THE PARITY SPEC WINS OVER THE HAND-WRITTEN LISTS.
#
# ADDED_MODULE is applied AFTER ADDED_ENABLE, so a symbol the derived pass set
# =y would be forced back to =m by a hand-written entry -- and then every child
# of it is demoted by olddefconfig, because a symbol cannot exceed its parent
# (MFD_MACSMC=m takes GPIO_MACSMC, POWER_RESET_MACSMC, CHARGER_MACSMC and
# RTC_DRV_MACSMC down with it). So a clash drops the =m entry, and says so.
drop_clashes() {
  [ ${#ADDED_MODULE[@]} -gt 0 ] && [ ${#ADDED_ENABLE[@]} -gt 0 ] || return 0
  local _keep=() _drop="" _m _e _clash
  for _m in "${ADDED_MODULE[@]}"; do
    _clash=0
    for _e in "${ADDED_ENABLE[@]}"; do [ "$_m" = "$_e" ] && { _clash=1; break; }; done
    if [ "$_clash" -eq 1 ]; then _drop="$_drop ${_m#CONFIG_}"; else _keep+=("$_m"); fi
  done
  ADDED_MODULE=(${_keep[@]+"${_keep[@]}"})
  [ -z "$_drop" ] || echo "  parity override -- =y per the parity spec, dropped from the =m list:$_drop"
}

p_add=0; p_mod=0; p_have=0; p_gone=""
while IFS='=' read -r k v; do
  case " ${PARITY_EXCEPT[*]:-} " in *" $k "*) continue ;; esac
  cur=$(sed -nE "s/^($k)=(.*)$/\2/p" "$SRC/.config")
  if ! grep -qE "^($k=|# $k is not set$)" "$SRC/.config"; then
    p_gone="$p_gone $k"                                  # not in this tree
  elif [ "$v" = y ] && [ "$cur" != y ]; then
    ADDED_ENABLE+=("$k"); p_add=$((p_add + 1))
  elif [ "$v" = m ] && [ -z "$cur" ]; then
    ADDED_MODULE+=("$k"); p_mod=$((p_mod + 1))
  else
    p_have=$((p_have + 1))
  fi
done < <(grep -E '^CONFIG_[A-Z0-9_]+=[ym]$' "$ASAHI_CFG")

drop_clashes

# Symbols to switch off, and string symbols to set.
#
# DELIBERATELY NO olddefconfig HERE. Page size is a Kconfig *choice*, and a
# choice with no member selected is not left empty -- olddefconfig immediately
# re-picks the default, which is 4K. Resolving between the disable and the
# enable would therefore hand back exactly the kernel we are trying not to
# build, and the only visible symptom would be CONFIG_PAGE_SHIFT=12 much later.
# So the clear and the select must reach the same resolve: this block only
# writes, and the ADDED_ENABLE block below runs the single olddefconfig that
# settles all of it.
if [ ${#DISABLE[@]} -gt 0 ] || [ ${#SET_STR[@]} -gt 0 ]; then
  echo "-- disabling / setting symbols (resolved with the enables below) --"
  for s in ${DISABLE[@]+"${DISABLE[@]}"}; do
    ( cd "$SRC" && ./scripts/config --disable "$s" ) >/dev/null 2>&1 || true
    echo "  off  $s"
  done
  for kv in ${SET_STR[@]+"${SET_STR[@]}"}; do
    # The value can begin with '-' (a localversion). scripts/config consumes it
    # as a positional value rather than re-parsing it as an option, but if that
    # ever changes the MUST_VAL manifest catches it -- it asserts the exact
    # resulting line, so a silently dropped setting cannot pass.
    ( cd "$SRC" && ./scripts/config --set-str "${kv%%=*}" "${kv#*=}" ) >/dev/null 2>&1 || true
    echo "  set  $kv"
  done
fi

# Built-in additions (=y), then modules (=m): the hand-written lists plus
# whatever the parity pass added.
echo "-- enabling our added symbols and modules --"
for s in ${ADDED_ENABLE[@]+"${ADDED_ENABLE[@]}"}; do
  ( cd "$SRC" && ./scripts/config --enable "$s" ) >/dev/null 2>&1 || true
done
( cd "$SRC" && make ARCH=arm64 olddefconfig >/dev/null )
for s in ${ADDED_MODULE[@]+"${ADDED_MODULE[@]}"}; do
  ( cd "$SRC" && ./scripts/config --module "$s" ) >/dev/null 2>&1 || true
done
( cd "$SRC" && make ARCH=arm64 olddefconfig >/dev/null )

# PARITY, TO A FIXED POINT.
#
# Kconfig writes no line at all for a symbol whose dependencies are unmet, so a
# spec symbol whose parent was off in Slackware's config looks absent on the
# first pass -- until that same pass turns the parent on. Re-classify what was
# absent, enable what has now appeared, resolve, and repeat until a pass adds
# nothing. Whatever is still absent afterwards is the real shortfall.
pass=1
while [ -n "$p_gone" ]; do
  pass=$((pass + 1)); still=""; grew=0
  for k in $p_gone; do
    if ! grep -qE "^($k=|# $k is not set$)" "$SRC/.config"; then
      still="$still $k"; continue
    fi
    v=$(sed -nE "s/^$k=([ym])$/\1/p" "$ASAHI_CFG")
    cur=$(sed -nE "s/^$k=(.*)$/\1/p" "$SRC/.config")
    if [ "$v" = y ] && [ "$cur" != y ]; then
      ( cd "$SRC" && ./scripts/config --enable "$k" ) >/dev/null 2>&1 || true
      ADDED_ENABLE+=("$k"); p_add=$((p_add + 1)); grew=1
    elif [ "$v" = m ] && [ -z "$cur" ]; then
      ( cd "$SRC" && ./scripts/config --module "$k" ) >/dev/null 2>&1 || true
      ADDED_MODULE+=("$k"); p_mod=$((p_mod + 1)); grew=1
    else
      p_have=$((p_have + 1))
    fi
  done
  p_gone=$still
  [ "$grew" -eq 1 ] || break
  ( cd "$SRC" && make ARCH=arm64 olddefconfig >/dev/null )
done
drop_clashes
echo "  parity vs vanilla Asahi: $p_have already match, +$p_add builtin, +$p_mod module ($pass passes)"
if [ -n "$p_gone" ]; then
  echo "  parity SHORTFALL -- $(echo $p_gone | wc -w) symbol(s) the spec enables never appeared:"
  for g in $p_gone; do echo "      ${g#CONFIG_}"; done
  echo "  Undefined in this source, or gated by a dependency the spec leaves off."
  echo "  Recorded, not ignored."
fi

# Asserted only once everything has resolved, so a later --module that demotes
# an earlier =y child is caught. Modules are asserted =m specifically: a driver
# that quietly became built-in, or quietly vanished, both read as "fine" to a
# check that only looks for enabled.
added_fail=0; n_ok=0
for s in ${ADDED_ENABLE[@]+"${ADDED_ENABLE[@]}"}; do
  if grep -qE "^${s}=y" "$SRC/.config"; then n_ok=$((n_ok + 1)); else
    echo "  FAIL $s is not =y -- $(grep -E "^(# )?${s}[= ]" "$SRC/.config" || echo 'absent')"
    added_fail=1
  fi
done
for s in ${ADDED_MODULE[@]+"${ADDED_MODULE[@]}"}; do
  if grep -qE "^${s}=m" "$SRC/.config"; then n_ok=$((n_ok + 1)); else
    echo "  FAIL $s is not =m -- $(grep -E "^(# )?${s}[= ]" "$SRC/.config" || echo 'absent')"
    added_fail=1
  fi
done
echo "  added symbols: $n_ok took as requested"
if [ "$added_fail" -ne 0 ]; then
  echo "  NOTE: a symbol that did not take is usually held down by its parent --" >&2
  echo "        a symbol cannot exceed its parent, so look UP the dependency tree." >&2
fi

# Bring include/config/auto.conf into line with the .config we just produced.
#
# NOT COSMETIC. scripts/setlocalversion reads CONFIG_LOCALVERSION from
# auto.conf, not from .config, and auto.conf is generated once by the first
# resolve and then left alone -- so `make kernelrelease` keeps reporting the
# SEED's localversion no matter what we set afterwards: .config says
# "-armv8-mac" while kernelrelease still says "6.18.33-armv8", which installs
# this kernel's modules over Slackware's own.
( cd "$SRC" && make ARCH=arm64 syncconfig >/dev/null 2>&1 ) || true

migrated="$SRC/.config"

# Sweep for Apple symbols the seed enabled that are NOT enabled after
# migration. Most are harmless (drivers genuinely dropped upstream), but an
# upstream rename shows up here first. Advisory, not fatal: review on every
# kernel bump. CR is stripped first so a seed with CRLF line endings cannot make
# every '$'-anchored pattern silently match nothing.
echo "-- symbols enabled in seed but not in migrated config (review on version bumps) --"
lostcount=0
while IFS= read -r line; do
  sym=${line%%=*}
  case "$sym" in
    *APPLE*|*ASAHI*|*MACSMC*|*NVME*|*RTKIT*|*SART*|*DART*|*AIC*|*MBOX*|*MAILBOX*|*SPMI*|*ADMAC*|*DOCKCHANNEL*) ;;
    *) continue ;;
  esac
  grep -qE "^${sym}=(y|m)" "$migrated" || { echo "  lost: $sym"; lostcount=$((lostcount+1)); }
done < <(tr -d '\r' < "$OLDCONF" | grep -E '^CONFIG_[A-Z0-9_]+=(y|m)$')
[ "$lostcount" -eq 0 ] && echo "  none"
diff -u "$OLDCONF" "$migrated" > config-migration.diff || true
echo "  wrote config-migration.diff ($(grep -c '^[+-]' config-migration.diff) changed lines)"

# Carry forward any ADDED_ENABLE / ADDED_MODULE failure. MUST_Y does not cover
# every added symbol, so starting from 0 here would let a symbol that failed to
# take print FAIL and still exit 0.
fail=${added_fail:-0}
check_y() {
  local sym=$1
  if grep -q "^${sym}=y" "$migrated"; then
    echo "  ok   $sym=y"
  elif grep -q "^${sym}=m" "$migrated"; then
    echo "  ok   $sym=m"
  else
    echo "  LOST $sym  (was expected =y/=m; now: $(grep -E "^(# )?${sym}\b" "$migrated" || echo absent))"
    fail=1
  fi
}
echo "-- must-keep symbols --"
for s in "${MUST_Y[@]}"; do check_y "$s"; done
for kv in "${MUST_VAL[@]}"; do
  if grep -q "^${kv}$" "$migrated"; then echo "  ok   $kv"; else
    echo "  LOST $kv  (now: $(grep -E "^${kv%%=*}=" "$migrated" || echo absent))"; fail=1
  fi
done

echo "-- Rust / GPU driver --"
# GPU is a committed feature: assert, do not merely report.  A migration that
# silently drops DRM_ASAHI would produce a kernel that builds fine and then
# has no GPU on real hardware -- exactly the kind of failure we cannot detect
# until it runs on real hardware, so fail loudly here instead.
if grep -q '^CONFIG_RUST=y' "$migrated"; then
  echo "  ok   CONFIG_RUST=y"
else
  echo "  LOST CONFIG_RUST (now: $(grep -E '^(# )?CONFIG_RUST\b' "$migrated" || echo absent))"
  echo "       hint: the kernel finds rust-src via <sysroot>/lib/rustlib; Slackware"
  echo "       uses lib64.  Export RUST_LIB_SRC=/usr/lib64/rustlib/src/rust/library"
  fail=1
fi
if grep -qE '^CONFIG_DRM_ASAHI=[my]' "$migrated"; then
  echo "  ok   $(grep -E '^CONFIG_DRM_ASAHI=' "$migrated")"
else
  echo "  LOST CONFIG_DRM_ASAHI (now: $(grep -E '^(# )?CONFIG_DRM_ASAHI\b' "$migrated" || echo absent))"
  fail=1
fi

# What the build will actually call this kernel. Reported here, and asserted
# when we asked for a specific localversion, because the value in .config and
# the value the build uses come from different files (see syncconfig above) and
# a mismatch means modules installed into another kernel's directory.
krel=$( cd "$SRC" && make ARCH=arm64 -s kernelrelease 2>/dev/null )
echo "-- kernel release --"
echo "  $krel"
for kv in ${SET_STR[@]+"${SET_STR[@]}"}; do
  [ "${kv%%=*}" = CONFIG_LOCALVERSION ] || continue
  want=${kv#*=}
  case "$krel" in
    *"$want") echo "  ok   release carries the requested localversion '$want'" ;;
    *) echo "  LOST release '$krel' does not end in '$want' -- auto.conf is stale"; fail=1 ;;
  esac
done

if [ "$fail" -ne 0 ]; then
  echo "MIGRATION CHECK FAILED: one or more must-keep symbols regressed." >&2
  exit 1
fi
echo "migration check passed."
