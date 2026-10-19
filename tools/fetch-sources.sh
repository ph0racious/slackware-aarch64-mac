#!/bin/bash
#
# fetch-sources.sh -- download and checksum-verify upstream sources for the
# slackware-aarch64-mac SlackBuilds.
#
# Every source is pinned to an exact tag/commit and verified against a sha256
# recorded here (lzfse against upstream's sha512, below); see docs/PORTING.md
# for how to refresh them.
#
# The kernel source is not fetched: tools/rebase-asahi-onto-slackware.sh
# produces it. Its parity spec is: vanilla Asahi's own kernel config, from
# AsahiLinux/PKGBUILDs at the commit that packaged the SAME Asahi release the
# rebase replays (ASAHI_TAG in that script). Bump the two together.
#
# Usage:
#   tools/fetch-sources.sh              # fetch sources for all packages
#   tools/fetch-sources.sh hwm-bw-mac lzfse   # only the named packages
#
# Sources are written into source/<pkg>/sources/ (git-ignored).  Re-running is
# cheap: a file whose checksum already matches is not re-downloaded.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

# manifest rows: <pkg> <dest-filename> <sha256> <url>
# Keep dest-filename in sync with what each SlackBuild expects in sources/.
MANIFEST=$(cat <<'EOF'
hwm-bw-mac|m1n1-1.5.2.tar.gz|01d4c8a75999ab388f9e3d87245f041c195f05e068237b6918435368afd3db99|https://github.com/AsahiLinux/m1n1/archive/v1.5.2.tar.gz
hwm-bw-mac|artwork-80d14f8b6f485b310e305a84b4b806361518ddd1.tar.gz|f2b18744a38d1369a8e9e59acddd12551c5500435fbd9e709fe7a6b212a070ac|https://github.com/AsahiLinux/artwork/archive/80d14f8b6f485b310e305a84b4b806361518ddd1.tar.gz
hwm-bw-mac|u-boot-asahi-v2026.04-2.tar.gz|b3cdcc467afbf6737ad7c87d174daa8eb0dcc212feb275ee56c406c1e084768c|https://github.com/AsahiLinux/u-boot/archive/asahi-v2026.04-2.tar.gz
lzfse|lzfse-1.0.tar.gz|SKIP|https://github.com/lzfse/lzfse/archive/refs/tags/lzfse-1.0.tar.gz
asahi-scripts|asahi-scripts-20260127.1.tar.gz|4df3d1e9946fca9b9e37177e9b832d05549096c94e17cf3bd8c192a3b8d1c0bc|https://github.com/asahi-alarm/asahi-scripts/archive/refs/tags/20260127.1.tar.gz
asahi-fwextract|asahi-fwextract-0.7.9.tar.gz|1f8728dd5d206855cc5ecac045dc4de03c9e22583663c907061d275d2da3b05d|https://github.com/asahi-alarm/asahi-alarm-installer/archive/refs/tags/v0.7.9.tar.gz
tiny-dfr|tiny-dfr-0.3.7.crate|5ca2d7d41e627c2f66908a0cdb5f817b8457a2c24014ad5841f3090aa7bb67db|https://static.crates.io/crates/tiny-dfr/tiny-dfr-0.3.7.crate
speakersafetyd|speakersafetyd-2.0.1.tar.gz|0e1cb05a2f5521d80f9a502daa0b75ef5c7f2b9e8913b0f88c2d19a97d4439e5|https://github.com/AsahiLinux/speakersafetyd/archive/2.0.1.tar.gz
alsa-ucm-conf-asahi|alsa-ucm-conf-asahi-8.tar.gz|e0a028ab4d6d5cf5033e293a4205071245911827be052e21a723ed6bd694efb1|https://github.com/AsahiLinux/alsa-ucm-conf-asahi/archive/v8.tar.gz
zix|zix-0.8.2.tar.xz|4c73aab0f8cbbfe56b00c8c6d648316021e699c5ae6cbf254391ef309047e67b|https://download.drobilla.net/zix-0.8.2.tar.xz
serd|serd-0.32.4.tar.xz|cbefb569e8db686be8c69cb3866a9538c7cb055e8f24217dd6a4471effa7d349|https://download.drobilla.net/serd-0.32.4.tar.xz
sord|sord-0.16.18.tar.xz|4f398b635894491a4774b1498959805a08e11734c324f13d572dea695b13d3b3|https://download.drobilla.net/sord-0.16.18.tar.xz
lv2|lv2-1.18.10.tar.xz|78c51bcf21b54e58bb6329accbb4dae03b2ed79b520f9a01e734bd9de530953f|https://lv2plug.in/spec/lv2-1.18.10.tar.xz
sratom|sratom-0.6.18.tar.xz|4c6a6d9e0b4d6c01cc06a8849910feceb92e666cb38779c614dd2404a9931e92|https://download.drobilla.net/sratom-0.6.18.tar.xz
lilv|lilv-0.24.26.tar.xz|22feed30bc0f952384a25c2f6f4b04e6d43836408798ed65a8a934c055d5d8ac|https://download.drobilla.net/lilv-0.24.26.tar.xz
pipewire-lv2|pipewire-1.6.6.tar.gz|b2a0a8de6946b8145a453639c936555beb0cbf2f2486e0b1c676cffdaaf029d9|https://gitlab.freedesktop.org/pipewire/pipewire/-/archive/1.6.6/pipewire-1.6.6.tar.gz
lsp-plugins-lv2|lsp-plugins-src-1.2.24.tar.gz|ac329fdcfa916be94b65c1c640d45704691c9e190c35d13d2689389f7fdbb463|https://github.com/lsp-plugins/lsp-plugins/releases/download/1.2.24/lsp-plugins-src-1.2.24.tar.gz
bankstown|bankstown-1.1.0.tar.gz|e877508b73fe90774d74526d838f75e8ea278bdbcee0a1f92e3eca67ed734675|https://github.com/chadmed/bankstown/archive/refs/tags/1.1.0.tar.gz
triforce-lv2|triforce-0.3.2.tar.gz|1d081222d0bfe2c961ac44b368c9f1d2dd9ec0833a35bab87863bac07e9df019|https://github.com/chadmed/triforce/archive/refs/tags/0.3.2.tar.gz
asahi-audio|asahi-audio-4.0.tar.gz|fedd185df798370961a9a918571bc35d347032dc2ab04d22d1233be06ec5ee3a|https://github.com/AsahiLinux/asahi-audio/archive/refs/tags/v4.0.tar.gz
mesa-asahi|mesa-26.1.1.tar.xz|8bd36c031cc6d0edfec04617527609454ee3a09ad53bdf983b45fc2c1e129b2e|https://archive.mesa3d.org/mesa-26.1.1.tar.xz
mesa-asahi|mesa-demos-9.0.0.tar.xz|3046a3d26a7b051af7ebdd257a5f23bfeb160cad6ed952329cdff1e9f1ed496b|https://archive.mesa3d.org/demos/mesa-demos-9.0.0.tar.xz
kernel_armv8-mac|config-asahi-6.18.15-1|3f54f64359265f68854b165fe1344f1695bcb661f286276b7143ac6098972d84|https://raw.githubusercontent.com/AsahiLinux/PKGBUILDs/d8c7aacd138a34eee4db219b5b16c60c0bd7b539/linux-asahi/config
EOF
)

# lzfse upstream publishes only a sha512 in its PKGBUILD; verified separately.
LZFSE_SHA512='9d7ca44e6d3d2bdf4b82b0eb66c14922369b8b6fe2cf891187a77c6708b8d26c2c1b2ccddec6059e85dbbbb37c497419549f02812b5f34d06238ac246a8cf912'

want_pkg() {
  # Called as: want_pkg <target-pkg> "$@"  (the script's own argv).
  # Shift the target off FIRST, then decide: an empty remaining list means no
  # filter was given, so we want everything.  Testing $# before the shift is a
  # bug -- it is never 0 (the target is always there), so every package gets
  # skipped and the script silently fetches nothing while reporting success.
  local target=$1; shift
  [ "$#" -eq 0 ] && return 0
  for p in "$@"; do [ "$p" = "$target" ] && return 0; done
  return 1
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# main() calls this as `fetch_one ... || rc=1`, and bash ignores set -e inside a
# function called from an || list. Every failure here must therefore return
# explicitly: an unchecked one carries on and reports "ok".
fetch_one() {
  local pkg=$1 fname=$2 want=$3 url=$4
  local destdir="$REPO_ROOT/source/$pkg/sources"
  local dest="$destdir/$fname"
  mkdir -p "$destdir" || return 1

  if [ -f "$dest" ]; then
    local have; have=$(sha256_of "$dest")
    if [ "$want" = "SKIP" ] || [ "$have" = "$want" ]; then
      echo "  have   $pkg/$fname"
      verify_extra "$pkg" "$dest" || return 1
      return 0
    fi
    echo "  stale  $pkg/$fname (checksum mismatch, refetching)"
    rm -f "$dest"
  fi

  echo "  get    $pkg/$fname"
  curl -fSL --no-progress-meter --retry 3 --connect-timeout 30 -o "$dest.part" "$url" \
    || { echo "  ERROR  $pkg/$fname download failed" >&2; return 1; }
  mv -f "$dest.part" "$dest" || return 1

  local have; have=$(sha256_of "$dest")
  if [ "$want" != "SKIP" ] && [ "$have" != "$want" ]; then
    echo "  ERROR  $pkg/$fname sha256 mismatch" >&2
    echo "         want $want" >&2
    echo "         got  $have" >&2
    rm -f "$dest"
    return 1
  fi
  verify_extra "$pkg" "$dest" || return 1
  echo "  ok     $pkg/$fname"
}

verify_extra() {
  # lzfse has no pinned sha256 in the manifest; check its sha512 instead.
  local pkg=$1 dest=$2
  if [ "$pkg" = "lzfse" ]; then
    local have; have=$(sha512sum "$dest" | cut -d' ' -f1)
    if [ "$have" != "$LZFSE_SHA512" ]; then
      echo "  ERROR  lzfse sha512 mismatch" >&2
      echo "         want $LZFSE_SHA512" >&2
      echo "         got  $have" >&2
      rm -f "$dest"
      return 1
    fi
  fi
}

main() {
  # A name that matches no row would fetch nothing and still report success,
  # so a mistyped name would read as a verified fetch.
  local p
  for p in "$@"; do
    awk -F'|' -v p="$p" '$1 == p { found = 1 } END { exit !found }' <<< "$MANIFEST" \
      || { echo "fetch-sources: nothing is pinned for '$p' -- check the name against this script's MANIFEST" >&2; exit 1; }
  done
  echo "Fetching sources into source/<pkg>/sources/ ..."
  local rc=0
  while IFS='|' read -r pkg fname sha url; do
    [ -z "$pkg" ] && continue
    if want_pkg "$pkg" "$@"; then
      fetch_one "$pkg" "$fname" "$sha" "$url" || rc=1
    fi
  done <<< "$MANIFEST"
  if [ "$rc" -ne 0 ]; then
    echo "One or more sources failed to fetch or verify." >&2
    exit 1
  fi
  echo "All requested sources present and verified."
}

main "$@"
