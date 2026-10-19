#!/bin/bash
#
# setup-build-host.sh -- check a Slackware AArch64 system for the main tools
# the slackware-aarch64-mac build uses; a full install (every series, D
# included) has all of them.
#
# Run this ON the build machine: any aarch64 Slackware -current system, bare
# metal or a VM. Apple hardware is not required.
#
# Builds are native only: the kernel needs a matching Rust toolchain and
# libclang for bindgen, Mesa builds against LLVM, and maintaining a second,
# cross toolchain buys nothing.
#
# Read-only: reports what is missing, installs nothing.

REQUIRED_FAIL=0
warn() { printf "  MISSING  %-22s %s\n" "$1" "$2"; REQUIRED_FAIL=$((REQUIRED_FAIL+1)); }
ok()   { printf "  ok       %-22s %s\n" "$1" "$2"; }

echo "== host =="
printf "  %-24s %s\n" "arch" "$(uname -m)"
printf "  %-24s %s\n" "kernel" "$(uname -r)"
printf "  %-24s %s\n" "slackware" "$(cat /etc/slackware-version 2>/dev/null || echo 'not Slackware')"
if [ "$(uname -m)" != "aarch64" ]; then
  echo
  echo "  This is not aarch64. These packages are built natively, so you need an"
  echo "  aarch64 Slackware -current system -- bare metal or a VM (QEMU is fine)."
  echo "  See docs/BUILD.md."
  exit 1
fi

echo
echo "== toolchain =="
for t in gcc make cmake python3 perl; do
  command -v "$t" >/dev/null 2>&1 && ok "$t" "$($t --version 2>/dev/null | head -1 | cut -c1-46)" \
                                  || warn "$t" "core build tool"
done

echo
echo "== clang / LLVM  (kernel bindgen needs libclang; mesa builds against LLVM) =="
command -v clang  >/dev/null 2>&1 && ok "clang"  "$(clang --version | head -1 | cut -c1-46)" \
                                  || warn "clang"  "from the llvm package"
ls /usr/lib64/libclang.so* >/dev/null 2>&1 && ok "libclang" "$(ls /usr/lib64/libclang.so* | head -1)" \
                                  || warn "libclang" "from llvm -- kernel bindgen will fail"

echo
echo "== Rust  (kernel GPU driver DRM_ASAHI; speakersafetyd; tiny-dfr) =="
command -v rustc >/dev/null 2>&1 && ok "rustc" "$(rustc --version | cut -c1-46)" \
                                 || warn "rustc" "kernel Rust + speakersafetyd need it"
command -v cargo >/dev/null 2>&1 && ok "cargo" "$(cargo --version | cut -c1-46)" || warn "cargo" ""
command -v bindgen >/dev/null 2>&1 && ok "bindgen" "$(bindgen --version 2>/dev/null | cut -c1-46)" \
                                 || warn "bindgen" "rust-bindgen; kernel Rust needs >= 0.65.1"
# THE Slackware-specific gotcha: the kernel looks for the Rust stdlib source at
# <rustc-sysroot>/lib/rustlib/..., but Slackware installs it under lib64. Without
# RUST_LIB_SRC the kernel's check reports that the source for the 'core'
# standard library could not be found, Kconfig quietly turns Rust off, and the
# GPU driver goes with it.
if [ -f /usr/lib64/rustlib/src/rust/library/core/src/lib.rs ]; then
  ok "rust-src" "/usr/lib64/rustlib/... (build with RUST_LIB_SRC=/usr/lib64/rustlib/src/rust/library)"
elif [ -f /usr/lib/rustlib/src/rust/library/core/src/lib.rs ]; then
  ok "rust-src" "/usr/lib/rustlib/... (kernel default path)"
else
  warn "rust-src" "kernel Rust cannot build without the stdlib source"
fi

echo
echo "== kernel build =="
for t in flex bison bc dtc; do
  command -v "$t" >/dev/null 2>&1 && ok "$t" "" || warn "$t" "kernel/U-Boot build"
done
# Slackware calls this 'pahole', not 'dwarves' as most distros do.
command -v pahole >/dev/null 2>&1 && ok "pahole" "$(pahole --version 2>/dev/null)" \
                                  || warn "pahole" "needed for CONFIG_DEBUG_INFO_BTF"
ls /usr/include/libelf.h >/dev/null 2>&1 && ok "libelf" "elfutils" || warn "libelf" "elfutils"
# GNU parallel: the kernel SlackBuild compresses its modules with it, as
# Slackware ARM's own kernel.SlackBuild does.
command -v parallel >/dev/null 2>&1 && ok "parallel" "kernel module compression" \
                                    || warn "parallel" "kernel module compression"

echo
echo "== package-specific =="
command -v convert >/dev/null 2>&1 && ok "imagemagick" "m1n1 boot logo" \
                                   || warn "imagemagick" "m1n1 boot logo"
command -v swig >/dev/null 2>&1 && ok "swig" "U-Boot pylibfdt" || warn "swig" "U-Boot"
[ -d /usr/include/alsa ] && ok "alsa-lib headers" "speakersafetyd" || warn "alsa-lib headers" "speakersafetyd"
pkg-config --exists 'librsvg-2.0 >= 2.59' libinput cairo pango 2>/dev/null \
  && ok "librsvg/libinput/cairo" "tiny-dfr" \
  || warn "librsvg/libinput/cairo" "tiny-dfr (librsvg 2.59 or later)"
for m in build installer wheel setuptools; do
  python3 -c "import $m" 2>/dev/null && ok "python-$m" "asahi-fwextract" \
                                     || warn "python-$m" "asahi-fwextract wheel build"
done

echo
echo "== sources, patches and the medium =="
for t in meson ninja; do
  command -v "$t" >/dev/null 2>&1 && ok "$t" "the LV2 stack, pipewire, mesa" \
                                  || warn "$t" "the LV2 stack, pipewire, mesa"
done
command -v patch   >/dev/null 2>&1 && ok "patch" "carried patches" || warn "patch" "carried patches"
command -v git     >/dev/null 2>&1 && ok "git" "the kernel rebase" || warn "git" "the kernel rebase"
command -v curl    >/dev/null 2>&1 && ok "curl" "fetch-sources.sh" || warn "curl" "fetch-sources.sh"
command -v wget    >/dev/null 2>&1 && ok "wget" "the base ISO (docs/BUILD.md)" \
                                   || warn "wget" "the base ISO (docs/BUILD.md)"
command -v xorriso >/dev/null 2>&1 && ok "xorriso" "the medium and its checks" \
                                   || warn "xorriso" "the medium and its checks"

echo
echo "== clock =="
# A wrong clock does not fail a build, it makes it never finish. A machine
# whose clock is not set starts at the epoch, source tarballs then carry future
# timestamps, make sees every target as perpetually out of date, and it
# rebuilds in a loop. There is no error message; the build simply grinds
# forever.
NOW_EPOCH=$(date +%s)
if [ "$NOW_EPOCH" -lt 1700000000 ]; then
  warn "system clock" "reads $(date) -- builds will loop forever, fix before building"
  echo "           set it by hand before building, in UTC:"
  echo "               date -u -s 'YYYY-MM-DD HH:MM'"
else
  ok "system clock" "$(date '+%Y-%m-%d %H:%M') (sane)"
fi

echo
echo "== installer media (build-installer-initrd.sh) =="
# The installer initrd is unpacked and repacked on this machine, because it needs
# depmod and the *-armv8-mac module tree -- which is why kernel_armv8-mac has to
# be installed here, not merely built.
command -v cpio >/dev/null 2>&1 && ok "cpio" "unpack/repack installer initrd" \
                                || warn "cpio" "build-installer-initrd.sh needs it"
# xz specifically: the stock installer initrd is xz-compressed, and it is
# repacked with a CRC32 check, because the kernel's decoder rejects xz's default
# CRC64 and the failure shows only at boot (build-installer-initrd.sh, trap 1).
command -v xz >/dev/null 2>&1 && ok "xz" "installer initrd is xz, not gzip" \
                              || warn "xz" "build-installer-initrd.sh needs it"
command -v depmod >/dev/null 2>&1 && ok "depmod" "swapped module tree must be depmod'd" \
                                  || warn "depmod" "kmod; modprobe finds nothing without it"

echo
echo "== Slackware packaging =="
[ -x /sbin/makepkg ]   && ok "makepkg" ""   || warn "makepkg" "pkgtools"
[ -x /sbin/installpkg ] && ok "installpkg" "" || warn "installpkg" "pkgtools"

echo
echo "== disk =="
avail=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
printf "  %-24s %sG free on /\n" "space" "${avail:-?}"
[ "${avail:-0}" -lt 70 ] && echo "  NOTE: docs/BUILD.md asks for ~70G free for a full build; consider freeing space."

echo
if [ "$REQUIRED_FAIL" -eq 0 ]; then
  echo "RESULT: build host looks complete."
  exit 0
fi
echo "RESULT: $REQUIRED_FAIL item(s) missing."
echo "A full Slackware install (all series, incl. D) provides everything above."
exit 1
