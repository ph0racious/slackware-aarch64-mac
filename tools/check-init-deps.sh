#!/bin/bash
#
# check-init-deps.sh -- find init-system assumptions that DO NOT work on Slackware.
#
# WHY THIS EXISTS
# ---------------
# Slackware is SysV init. Every upstream Asahi package is packaged for
# systemd distributions (Arch, Fedora), so anything that starts a daemon,
# provisions a user, or hooks the initrd will be expressed in a form Slackware
# silently ignores. "Silently" is the problem: the package installs cleanly, the
# files land, and the daemon never runs. For speakersafetyd that failure mode
# leaves the speakers at the reduced volume Asahi's kernel driver holds them
# to, with nothing to say why.
#
# This is not a one-off. It is inherent to the port and recurs for every package.
# So it is automated rather than remembered.
#
# USAGE
#   check-init-deps.sh --source  <dir>        an unpacked upstream source tree
#   check-init-deps.sh --package <file.txz>   a Slackware package we built
#   check-init-deps.sh --package-dir <dir>    every *.txz in a directory
#
# --source  is ADVISORY: it tells you what you must adapt.
# --package is a GATE: our finished packages must contain none of this, because
#           it means Arch/Fedora init glue leaked into a Slackware package.
#           Exits non-zero on findings.

set -uo pipefail

MODE=""; TARGET=""
case "${1:-}" in
  --source)      MODE=source;   TARGET=${2:?need a directory} ;;
  --package)     MODE=package;  TARGET=${2:?need a .txz} ;;
  --package-dir) MODE=pkgdir;   TARGET=${2:?need a directory} ;;
  *) sed -n '2,/^set -uo pipefail$/p' "$0" | sed '$d'; exit 2 ;;
esac

findings=0
note() { printf "  [%s] %s\n" "$1" "$2"; findings=$((findings+1)); }

# ---------------------------------------------------------------- source mode
scan_source() {
  local d=$1
  echo "== scanning source tree: $d =="

  # 1. systemd units. Each needs an /etc/rc.d/rc.<name> equivalent.
  while IFS= read -r f; do
    note "UNIT" "$(basename "$f") -> needs an /etc/rc.d/rc.* script"
    # Units with User=/DynamicUser= assume systemd provisions the account.
    if grep -qE '^(DynamicUser|User)=' "$f" 2>/dev/null; then
      note "USER" "$(basename "$f") runs as a non-root user (systemd DynamicUser/User=) -> Slackware must create it or run as root, deliberately"
    fi
    grep -qE '^(AmbientCapabilities|CapabilityBoundingSet)=' "$f" 2>/dev/null && \
      note "CAPS" "$(basename "$f") relies on systemd capability handling -> replicate or run privileged"
    grep -qE '^Restart=' "$f" 2>/dev/null && \
      note "RESTART" "$(basename "$f") expects systemd auto-restart -> no equivalent in SysV; consider supervision"
  done < <(find "$d" -maxdepth 5 \( -name '*.service' -o -name '*.socket' \
            -o -name '*.timer' -o -name '*.path' \) 2>/dev/null)

  # 2. udev rules that launch things via systemd. These are INERT on Slackware:
  #    the rule loads, the match fires, and then nothing happens.
  while IFS= read -r f; do
    if grep -qE 'SYSTEMD_WANTS|TAG\+?="systemd"' "$f" 2>/dev/null; then
      note "UDEV" "$(basename "$f") starts a service via SYSTEMD_WANTS -> inert on Slackware, daemon will NOT start"
    fi
  done < <(find "$d" -maxdepth 5 -name '*.rules' 2>/dev/null)

  # 3. initrd integration for the wrong initrd generator.
  [ -d "$d/dracut" ]     && note "INITRD" "dracut/ present -> Slackware uses mkinitrd"
  [ -d "$d/initcpio" ]   && note "INITRD" "initcpio/ present -> Slackware uses mkinitrd"

  # 4. package-manager hooks for the wrong package manager.
  [ -d "$d/libalpm" ]    && note "PKGMGR" "libalpm/ hooks present -> pacman-only, use doinst.sh"

  # 5. systemd-only provisioning mechanisms.
  [ -n "$(find "$d" -maxdepth 5 \( -name 'sysusers.d' -o -name '*.sysusers' \) -print -quit 2>/dev/null)" ] && \
    note "USER" "sysusers.d present -> Slackware has no equivalent; create accounts in doinst.sh"
  [ -n "$(find "$d" -maxdepth 5 \( -name 'tmpfiles.d' -o -name '*.tmpfiles' \) -print -quit 2>/dev/null)" ] && \
    note "TMPFILES" "tmpfiles.d present -> create dirs in doinst.sh or the rc script"

  # 6. Makefile install targets that bake in systemd paths.
  if [ -f "$d/Makefile" ] && grep -qE '^(UNITDIR|SYSTEMD|SYSTEMD_UNIT)' "$d/Makefile" 2>/dev/null; then
    note "MAKE" "Makefile has UNITDIR/SYSTEMD vars -> point them at a throwaway dir and delete, or use a narrower install target"
  fi
}

# --------------------------------------------------------------- package mode
scan_package() {
  local p=$1 label=${2:-$(basename "$1")}
  local list
  # A package the gate cannot read is a finding, not a pass.
  list=$(tar tJf "$p" 2>/dev/null) || { note "READ" "cannot read $p"; return; }

  # NEVER `echo "$list" | grep -q`. A package listing runs far past the 64 KB
  # pipe buffer, so on an early match grep -q exits, echo takes SIGPIPE, and
  # pipefail turns the match into a failure: the gate then passes the very
  # package it exists to catch. Here-strings have no writer to kill. The same
  # rule is written at check-driver-parity.sh, for `tar tf | grep -q`.
  local bad=0
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if grep -qE "$pat" <<<"$list"; then
      note "LEAK" "$label contains $(grep -m1 -E "$pat" <<<"$list")"
      bad=1
    fi
  done <<'PATTERNS'
(^|/)lib/systemd/
(^|/)usr/lib/systemd/
\.service$
\.socket$
\.timer$
(^|/)usr/lib/dracut/
(^|/)lib/dracut/
(^|/)usr/lib/initcpio/
(^|/)usr/share/libalpm/
(^|/)usr/lib/sysusers\.d/
(^|/)usr/lib/tmpfiles\.d/
PATTERNS

  # A shipped udev rule that only acts via systemd is a silent no-op -- UNLESS
  # the package also ships an /etc/rc.d/rc.* script to start the daemon itself.
  # In that case the rule's systemd lines are merely inert, which is expected and
  # correct, so do not report it: a gate that cries wolf on correctly-handled
  # packages trains you to ignore it.
  local has_rc=0
  grep -qE '(^|/)etc/rc\.d/rc\.[A-Za-z0-9._-]+' <<<"$list" && has_rc=1
  if grep -qE '\.rules$' <<<"$list"; then
    local tmp; tmp=$(mktemp -d)
    tar xJf "$p" -C "$tmp" --wildcards '*.rules' 2>/dev/null || true
    while IFS= read -r r; do
      if grep -qE 'SYSTEMD_WANTS|TAG\+?="systemd"' "$r" 2>/dev/null; then
        if [ "$has_rc" -eq 1 ]; then
          printf "  note:  %s ships %s (systemd lines inert) -- covered by the rc.d script it also ships\n" \
            "$label" "$(basename "$r")"
        else
          note "UDEV" "$label ships $(basename "$r") which starts services via systemd, and ships NO rc.d script -> daemon will never start"
          bad=1
        fi
      fi
    done < <(find "$tmp" -name '*.rules' 2>/dev/null)
    rm -rf "$tmp"
  fi
  [ "$bad" -eq 0 ] && printf "  clean: %s\n" "$label"
}

case "$MODE" in
  source)  scan_source "$TARGET" ;;
  package) echo "== scanning package: $TARGET =="; scan_package "$TARGET" ;;
  pkgdir)
    echo "== scanning packages in: $TARGET =="
    n=0
    for p in "$TARGET"/*.txz; do [ -e "$p" ] || continue; scan_package "$p"; n=$((n+1)); done
    # A sweep of an empty or wrong directory checks nothing; that is not a pass.
    [ "$n" -gt 0 ] || note "EMPTY" "no .txz packages in $TARGET" ;;
esac

echo
if [ "$findings" -eq 0 ]; then
  echo "RESULT: no init-system problems found."
  exit 0
fi
echo "RESULT: $findings finding(s)."
if [ "$MODE" = source ]; then
  echo "Source mode is advisory -- each finding above must be handled deliberately"
  echo "in the SlackBuild (see docs/PORTING.md, 'Init system')."
  exit 0
fi
echo "Package mode is a GATE: our packages must not ship systemd/Arch init glue."
exit 1
