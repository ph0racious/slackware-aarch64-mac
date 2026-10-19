#!/bin/bash
#
# check-tree-hygiene.sh -- refuse to build from a source tree that will produce
# broken packages. Three checks, each for a defect that passes every other form
# of review.
#
# Run it before a build, or after editing on an unfamiliar platform:
#
#   tools/check-tree-hygiene.sh
#
# Exit 0 if clean, non-zero with the offending files named.

set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
fail=0
say() { echo "  hygiene: $*"; }
bad() { echo "HYGIENE FAILED: $*" >&2; fail=1; }

# ---------------------------------------------------------------- CRLF
# A CR in an executable script is a shipped-package failure waiting to happen.
# A script packaged with a "/bin/bash\r" shebang installs cleanly, is present
# and executable, passes every static check -- and at boot the machine prints
#
#   /etc/rc.d/rc.platform: /sbin/slk-hwm-discover: /bin/bash^M: bad interpreter
#
# Markdown is checked too. It cannot break a boot, but .gitattributes says
# `* -text`, so line endings are committed exactly as they sit on disk, and a
# document edited from a Windows shell arrives wholly CRLF -- noticed only when
# a `$`-anchored grep stops matching.
#
# The patch series under source/*/patches/ are checked too. Upstream ships them
# with LF endings, and a CRLF copy is no longer the verbatim file it claims to
# be -- GNU patch strips the CRs itself and says so only in a line of the build
# log, so the build would not fail.
#
# So are installer-text/, LICENSE and NOTICE. The screens are CR-stripped when
# they are rendered into the initrd, so a CR there never reaches a console,
# but the committed files should be as clean as everything else.
#
# ⚠ Build the CR with printf, never as a literal in the pattern. A bare CR
# written inline can be stripped in transit (by an editor, a here-doc, a shell
# that normalises the command line), which leaves the pattern as a lone `$`
# anchor -- and that matches EVERY line of EVERY file, reporting the entire tree
# as CRLF. A check that always fails is worse than no check: it teaches people
# to ignore it.
#
# -I skips binary files. Without it, compiled artefacts (a stray __pycache__,
# say) match on their own bytes and are reported as CRLF source, which is the
# same "always fails" trap from the other direction.
CR=$(printf '\r')
crlf=$(grep -rlUI "$CR" "$REPO/tools" "$REPO/source" "$REPO/docs" "$REPO/README.md" \
         "$REPO/installer-text" "$REPO/LICENSE" "$REPO/NOTICE" \
         --exclude-dir=sources --exclude-dir=__pycache__ \
         2>/dev/null || true)
if [ -n "$crlf" ]; then
  bad "CRLF line endings in:
$(echo "$crlf" | sed "s|$REPO/|    |")
  Fix with: sed -i 's/\r\$//' <file>"
else
  say "no CRLF"
fi

# ---------------------------------------------------------------- which files
# Every shell script in the tree, found by WHAT IT IS as well as what it is
# called: any file whose first line is a sh or bash shebang, plus anything named
# *.sh, *.SlackBuild or doinst.sh. Both halves are needed. Extension alone lets
# every extensionless script -- rc.*, setup.*, slk-hwm-discover, the tools
# installed to /usr/sbin -- skip the checks below, and those are exactly the
# ones that run on a target at boot or during setup. Shebang alone drops the
# sourced libraries (build-paths.sh, installer-text.sh), which declare no
# interpreter because they are never executed.
#
# A leading BOM is stripped before the shebang is read. Otherwise a file with a
# BOM would not look like a script, and the BOM check would never see the very
# files it exists to catch.
BOM=$(printf '\xef\xbb\xbf')
SCRIPTS=$(mktemp)
trap 'rm -f "$SCRIPTS"' EXIT
find "$REPO/tools" "$REPO/source" -type f \
     -not -path '*/sources/*' -not -path '*/patches/*' \
     -not -path '*/rerere-cache/*' -not -path '*/__pycache__/*' 2>/dev/null |
while IFS= read -r f; do
  case "$f" in
    *.sh|*.SlackBuild|*/doinst.sh) echo "$f"; continue ;;
  esac
  line=$(head -1 "$f" 2>/dev/null)
  line=${line#"$BOM"}
  printf '%s\n' "$line" | grep -qE '^#!.*[/ ](ba)?sh([[:space:]]|$)' && echo "$f"
done | sort > "$SCRIPTS"

# ---------------------------------------------------------------- BOM
# A UTF-8 BOM before the shebang is the same class of failure and is NOT caught
# by the CRLF check. The kernel then finds no "#!" at the start of the file, so
# executing it directly fails with "Exec format error".
#
# Worse, most callers hide that. A shell runs the file itself when the kernel
# refuses it, and execvp() runs it with /bin/sh, so a cron entry (`sh -c`) and
# a `find -exec` both complain about line 1 and carry on. The defect stays
# hidden until something executes the file without that fallback, and only
# then fails.
#
# Some Windows shells write one on every save.
bom=""
while IFS= read -r f; do
  [ "$(head -c 3 "$f" 2>/dev/null)" = "$BOM" ] && bom="$bom
$f"
done < "$SCRIPTS"
if [ -n "$bom" ]; then
  bad "UTF-8 BOM before the shebang in:$(echo "$bom" | sed "s|$REPO/|    |")"
else
  say "no BOMs"
fi

# ---------------------------------------------------------------- syntax
# Cheap, and catches the edit that was never run. Validates each file with the
# interpreter it declares.
#
# ⚠ What this does NOT catch: bashisms in a #!/bin/sh script. Slackware's
# /bin/sh IS bash, so `sh -n` accepts them here and they would only fail on a
# system with a stricter shell. Verified: `foo=(a b c)` in a #!/bin/sh file
# passes this check. Do not read "syntax clean" as "POSIX clean".
badsyn=""
while IFS= read -r f; do
  if head -1 "$f" | grep -q 'bin/sh'; then chk=sh; else chk=bash; fi
  $chk -n "$f" 2>/dev/null || badsyn="$badsyn $f"
done < "$SCRIPTS"
if [ -n "$badsyn" ]; then
  bad "shell syntax errors in:$(echo "$badsyn" | sed "s|$REPO/||g")"
else
  say "shell syntax clean ($(wc -l < "$SCRIPTS") scripts)"
fi

[ "$fail" -eq 0 ] && say "tree is clean"
exit $fail
