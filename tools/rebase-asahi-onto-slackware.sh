#!/bin/bash
#
# rebase-asahi-onto-slackware.sh -- produce the kernel source this port builds:
# Slackware's own kernel-source with the Asahi Apple Silicon delta replayed onto
# it. Emits linux-<ver>-mac.tar.gz and regenerates REBASE-NOTES.md.
#
# Run on an aarch64 Slackware host. Needs git, tar, xz and about 25 GB. It
# does not compile anything; the SlackBuild does that.
#
# WHY A REBASE AND NOT A PATCH SERIES
# -----------------------------------
# The claim of this port is "Slackware's own kernel, running Apple hardware".
# That requires Slackware's kernel-source as the BASE, with Asahi's work applied
# to it -- not Asahi's tree with Slackware bits added. A rebase makes the
# direction of that dependency explicit, and git then reports commit by commit
# what upstream has already absorbed.
#
# WHAT MAKES IT TRACTABLE
# -----------------------
# Asahi's delta touches ~482 files. Going from the delta's base to Slackware's
# point release touches ~11,000. The INTERSECTION is what actually has to be
# resolved by hand, and it is small -- measure it (this script prints it)
# before assuming a bump is a big job. Changes in different regions of one file
# still merge cleanly.
#
# DETERMINISM IS THE WHOLE POINT
# ------------------------------
# Everything is pinned and every deviation is recorded. A conflict resolved
# differently on two runs produces two different kernels that both look right,
# so the single known conflict is carried as a recorded resolution (git
# rerere's cache, source/kernel_armv8-mac/rebase/rerere-cache) and the script
# STOPS if it no longer applies. It never opens an editor and never guesses.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

# ---- pins. A rebase against a moving tag is not reproducible. ----
KVER=${KVER:-6.18.33}                       # Slackware's kernel-source version
ASAHI_TAG=${ASAHI_TAG:-asahi-6.18.15-1}     # the 6.18-based Asahi release pinned
ASAHI_BASE=${ASAHI_BASE:-v6.18.15}          # what that tag branched from
ASAHI_URL=https://github.com/AsahiLinux/linux.git

WORK=/root/kernel-rebase
OUT=$WORK
SRCNAM=linux-$KVER-mac
BRANCH=mac

die()  { echo "rebase: $*" >&2; exit 1; }
info() { echo "  $*"; }
say()  { echo; echo "### $* ###"; }

for t in git tar xz; do command -v "$t" >/dev/null 2>&1 || die "need $t"; done
[ "$(uname -m)" = aarch64 ] || info "WARNING: not aarch64 -- fine for the rebase, but build on the target"

mkdir -p "$WORK" || die "cannot create $WORK"
cd "$WORK" || die "cannot enter $WORK"

# ---------------------------------------------------------------- 1. the base
say "1. Slackware's kernel-source $KVER"
#
# THE BASE IS A PIN, AND THE MEDIUM IS WHERE THE PIN LIVES.
#
# NOT the mirror. `-current` moves on, and the version we build against stops
# being published there. Fetching "the current kernel-source" would silently
# rebase onto a different kernel and still succeed.
#
# NOT kernel.org either. The claim is about SLACKWARE's tree specifically, and
# Slackware carries its own patches on top of upstream.
#
# So: k/kernel-source-<ver>-aarch64-1.txz, off the install medium, which is
# itself a pinned build input.
BASE_PKG=$WORK/kernel-source-$KVER-aarch64-1.txz
[ -s "$BASE_PKG" ] || die "no Slackware kernel-source package at $BASE_PKG.

  Take it off the install medium -- that is the pin -- and verify it against the
  medium's own CHECKSUMS.md5 rather than a value typed anywhere:

      T=slackware/slackwareaarch64-current
      xorriso -osirrox on -indev <medium>.iso \\
        -extract \$T/slackware/k/kernel-source-$KVER-aarch64-1.txz \\
        kernel-source-$KVER-aarch64-1.txz
      xorriso -osirrox on -indev <medium>.iso -extract \$T/CHECKSUMS.md5 CHECKSUMS.md5
      grep -a \"k/kernel-source-$KVER-aarch64-1.txz\$\" CHECKSUMS.md5

  then stage it here as $BASE_PKG."
info "base package  : $(basename "$BASE_PKG") ($(du -h "$BASE_PKG" | cut -f1))"

SRC=$WORK/$SRCNAM
rm -rf "$SRC" "$WORK/_base"
mkdir -p "$SRC" "$WORK/_base"
tar xf "$BASE_PKG" -C "$WORK/_base" || die "cannot unpack the base package"
[ -d "$WORK/_base/usr/src/linux-$KVER" ] \
  || die "the package has no usr/src/linux-$KVER -- wrong package or wrong KVER"
# Move rather than copy: it is ~1.3 GB of small files.
mv "$WORK/_base/usr/src/linux-$KVER"/* "$WORK/_base/usr/src/linux-$KVER"/.[!.]* "$SRC/" 2>/dev/null
rm -rf "$WORK/_base"
[ -f "$SRC/Makefile" ] || die "no Makefile in the unpacked base"
mkver=$(sed -ne 's/^VERSION *= *//p' "$SRC/Makefile").$(sed -ne 's/^PATCHLEVEL *= *//p' "$SRC/Makefile").$(sed -ne 's/^SUBLEVEL *= *//p' "$SRC/Makefile")
[ "$mkver" = "$KVER" ] || die "the package unpacks to $mkver, not $KVER"
info "base version  : $mkver (asserted from its own Makefile)"

say "2. Asahi tree, pinned at $ASAHI_TAG"
GIT=$WORK/asahi-linux
#
# A FULL CLONE, NOT A PARTIAL ONE.
#
# `--filter=blob:none` is the obvious way to save several GB, and it does not
# work here. The rebase happens in a SECOND repository, and a partial clone
# cannot serve blobs it never downloaded:
#
#   remote: fatal: could not fetch <sha> from promisor remote
#   fatal: protocol error: bad pack header
#
# The failure comes at the fetch, long after the clone "succeeded", and reads
# like repository corruption rather than a missing-blob policy. Pay the disk.
# A clone made partial by an earlier run is DISCARDED, not repaired.
#
# `git fetch --refetch` after unsetting the filter looks like the obvious fix and
# does not work: it grows the clone substantially and still leaves blobs
# missing. Re-cloning costs bandwidth; a half-repaired clone costs a rebase
# that dies partway with what reads as remote repository corruption.
if [ -d "$GIT/.git" ] && git -C "$GIT" config --get remote.origin.partialclonefilter >/dev/null 2>&1; then
  info "existing clone is partial and cannot be repaired -- discarding it"
  rm -rf "$GIT"
fi

if [ ! -d "$GIT/.git" ]; then
  info "cloning $ASAHI_URL (several GB; once)"
  git clone "$ASAHI_URL" "$GIT" || die "clone failed"
fi

git -C "$GIT" fetch --tags origin || die "fetch failed"
git -C "$GIT" rev-parse -q --verify "$ASAHI_TAG^{commit}" >/dev/null \
  || die "tag $ASAHI_TAG not found in $ASAHI_URL"
git -C "$GIT" rev-parse -q --verify "$ASAHI_BASE^{commit}" >/dev/null \
  || die "base $ASAHI_BASE not found"
TAG_SHA=$(git -C "$GIT" rev-parse "$ASAHI_TAG^{commit}")
BASE_SHA=$(git -C "$GIT" rev-parse "$ASAHI_BASE^{commit}")
info "$ASAHI_TAG  = $TAG_SHA"
info "$ASAHI_BASE = $BASE_SHA"

# PROVE THE OBJECTS ARE ACTUALLY HERE, BEFORE COMMITTING TO THE LONG PART.
#
# A clone can be missing blobs and look completely healthy: `git log` works,
# `rev-parse` works, the tags resolve. The absence surfaces only when something
# asks for the content -- and then it surfaces as
#
#   fatal: git upload-pack: aborting due to possible repository corruption
#
# blamed on the REMOTE, long after the fetch began. Walk the delta's objects
# now: it covers exactly what the rebase will need and nothing more, so it is
# quick.
info "verifying the delta's objects are all present"
if ! git -C "$GIT" rev-list --objects --no-object-names "$ASAHI_BASE..$ASAHI_TAG" \
     >/dev/null 2>"$WORK/objwalk.err"; then
  head -3 "$WORK/objwalk.err" >&2
  die "the clone at $GIT is incomplete.
  Delete it and let this script clone again -- do not try to repair it:
      rm -rf $GIT"
fi

# RESTORE EVERY SYMLINK, NOT JUST THE OBVIOUS ONES.
#
# Slackware's kernel-source package carries ALL of them only as doinst.sh
# lines, the way makepkg stores every symlink, so the tree unpacked above with
# tar has none -- 85 in this kernel. Restoring only
# `scripts/dtc/include-prefixes` (12 of the 85) leaves 73 paths simply absent
# from the tree, including
# `arch/arm64/tools/syscall_64.tbl -> ../../../scripts/syscall.tbl`, which is
# arm64's own build input.
#
# The set is derived from upstream at the delta's base rather than typed: git
# records a symlink as mode 120000 whose blob content is the target, so this
# reproduces them exactly and picks up any upstream adds or removals on a bump.
info "restoring the symlinks the Slackware package keeps in its doinst.sh"
nlink=0
while IFS= read -r -d '' entry; do
  mode=${entry%% *}
  [ "$mode" = 120000 ] || continue
  path=${entry#*$'\t'}
  target=$(git -C "$GIT" cat-file blob "$ASAHI_BASE:$path" 2>/dev/null) || continue
  [ -n "$target" ] || continue
  mkdir -p "$SRC/$(dirname "$path")"
  ln -sfn "$target" "$SRC/$path" && nlink=$((nlink + 1))
done < <(git -C "$GIT" ls-tree -r -z "$ASAHI_BASE")
info "symlinks      : $nlink restored"

# The dtc farm is the one whose absence is most expensive: every .dtso that
# includes another arch's dtsi fails late in the build, inside a Raspberry Pi
# driver with nothing to do with this port, reading like a corrupt tree rather
# than a missing symlink.
[ -e "$SRC/scripts/dtc/include-prefixes/arm64/broadcom" ] \
  || die "the dtc include symlinks did not resolve after restoring them"
# arm64's syscall table is generated through this one.
[ -e "$SRC/arch/arm64/tools/syscall_64.tbl" ] \
  || die "arch/arm64/tools/syscall_64.tbl did not resolve after restoring symlinks"
[ "$nlink" -ge 80 ] || die "only $nlink symlinks restored, expected ~85 --
  the Slackware package carries them only as doinst.sh lines, so a low count
  here means the tree is missing build inputs that will fail much later and
  much less clearly."

# ------------------------------------------------------- 3. commit the base
say "3. commit the base verbatim"
#
# Verbatim, in its own commit, before anything is replayed. That commit is the
# thing every later diff is against; if the base is entangled with the port's
# own changes there is no way to say what the port actually altered.
cd "$SRC" || die
rm -rf .git
git init -q -b slackbase . || die "git init failed"
git config user.name  "slackware-aarch64-mac"
git config user.email "noreply@localhost"
git add -A && git commit -q -m "Slackware k/kernel-source-$KVER, verbatim" \
  || die "could not commit the base"
SLACKBASE=$(git rev-parse HEAD)
info "slackbase     = $SLACKBASE"

# --------------------------------------------------------- 4. the delta
say "4. replay the Asahi delta"
git remote add asahi "$GIT" 2>/dev/null || true

# FETCH THE TAGS AS TAGS, THEN PEEL THEM.
#
# Both refs are ANNOTATED tags, so they name `tag` objects rather than commits.
# A refspec of `<tag>:refs/heads/<branch>` therefore tries to write a non-commit
# to a branch and git refuses:
#
#   error: cannot update ref 'refs/heads/_asahi_tag': trying to write
#   non-commit object <sha> to branch 'refs/heads/_asahi_tag'
#
# The objects transfer fine; only the ref update fails, so the error arrives
# after the expensive part and looks like a fetch problem rather than a refspec
# one. `^{commit}` cannot go in a refspec, so peel it afterwards with git branch.
git fetch -q asahi "refs/tags/$ASAHI_TAG:refs/tags/$ASAHI_TAG" \
                   "refs/tags/$ASAHI_BASE:refs/tags/$ASAHI_BASE" \
  || die "could not fetch the delta into the work tree"
git branch -f _asahi_tag  "$ASAHI_TAG^{commit}"  || die "cannot resolve $ASAHI_TAG to a commit"
git branch -f _asahi_base "$ASAHI_BASE^{commit}" || die "cannot resolve $ASAHI_BASE to a commit"

NONMERGE=$(git rev-list --no-merges --count _asahi_base.._asahi_tag)
ALL=$(git rev-list --count _asahi_base.._asahi_tag)
info "delta         : $ALL commits, $NONMERGE non-merge"

# HOW BIG IS THE ACTUAL JOB?
#
# Print the intersection before starting. This is what turns "rebase 880
# patches" from a gamble into a bounded piece of work, and it is the number to
# look at first on the next kernel bump.
adelta=$(git diff --name-only _asahi_base.._asahi_tag | sort -u)
sdelta=$(git diff --name-only "$BASE_SHA..$SLACKBASE" 2>/dev/null | sort -u || true)
if [ -n "$sdelta" ]; then
  inter=$(comm -12 <(echo "$adelta") <(echo "$sdelta") | wc -l)
  info "files touched : asahi $(echo "$adelta" | wc -l), intersection with the base $inter"
fi

git checkout -q -b "$BRANCH" _asahi_tag || die "cannot branch from the tag"

# Load the recorded conflict resolution into rerere's cache, so the rebase
# resolves it without a human and without an editor.
# rerere replays the recorded resolution, and autoUpdate stages it. Both are
# needed: without autoUpdate the file is fixed on disk but left unstaged, and
# `rebase --continue` refuses.
git config rerere.enabled true
git config rerere.autoUpdate true
RR=$HERE/../source/kernel_armv8-mac/rebase/rerere-cache
[ -d "$RR" ] && { mkdir -p .git/rr-cache && cp -a "$RR/." .git/rr-cache/ && \
                  info "loaded the recorded conflict resolution"; }

info "rebasing onto the Slackware base -- this is the long part"
git rebase --onto "$SLACKBASE" _asahi_base "$BRANCH" >"$WORK/rebase.log" 2>&1 || true

# RERERE RESOLVES; IT DOES NOT CONTINUE.
#
# Even when the recorded resolution applies cleanly -- the log says
# "Resolved '<file>' using previous resolution" -- git still HALTS so a human
# can look. So a rebase that is fully covered by the recording stops anyway, and
# reads exactly like one that is not.
#
# Drive it forward only while there is nothing left unmerged. An unmerged path
# means rerere did not cover it, and that is where a human is genuinely needed:
# a conflict resolved differently on two runs produces two kernels that both
# look correct.
rounds=0
while [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; do
  unmerged=$(git diff --name-only --diff-filter=U)
  if [ -n "$unmerged" ]; then
    echo >&2
    echo "  unresolved:" >&2
    echo "$unmerged" | sed 's/^/    /' >&2
    tail -20 "$WORK/rebase.log" >&2
    die "the rebase stopped on a conflict the recorded resolution does not cover.
  Resolve it by hand ONCE, then capture it so the next run needs no human:
      git -C $SRC rebase --continue
      cp -a $SRC/.git/rr-cache/. <tree>/source/kernel_armv8-mac/rebase/rerere-cache/
  and regenerate REBASE-NOTES.md. Do not re-run this script until that is done:
  an unrecorded resolution is the one failure mode this script exists to prevent."
  fi
  rounds=$((rounds + 1))
  [ "$rounds" -gt 60 ] && die "still resolving after $rounds rounds -- refusing to loop"
  info "  recorded resolution applied; continuing (round $rounds)"
  GIT_EDITOR=true git rebase --continue >>"$WORK/rebase.log" 2>&1 || true
done

APPLIED=$(git rev-list --no-merges --count "$SLACKBASE..$BRANCH")
DROPPED=$((NONMERGE - APPLIED))
RESULT=$(git rev-parse HEAD)
info "applied       : $APPLIED of $NONMERGE  (dropped as already upstream: $DROPPED)"
info "result        = $RESULT"

# Which ones did git discard? That list is the upstreaming trajectory as a
# measurable fact rather than a claim, so it goes into the notes.
dropped_list=$(comm -23 \
  <(git log --no-merges --format='%s' _asahi_base.._asahi_tag | sort) \
  <(git log --no-merges --format='%s' "$SLACKBASE..$BRANCH" | sort))

# ------------------------------------------------------------ 5. the gate
say "5. parity of the RESULT"
#
# Refuse to emit a tarball whose delta silently lost the drivers that are the
# entire reason for it. This is a source-tree check -- the built-package gate is
# tools/check-driver-parity.sh, and they answer different questions.
missing=""
for d in drivers/gpu/drm/apple drivers/gpu/drm/asahi drivers/phy/apple \
         sound/soc/apple drivers/hid/spi-hid drivers/soc/apple \
         arch/arm64/boot/dts/apple; do
  [ -d "$SRC/$d" ] || missing="$missing $d"
done
[ -z "$missing" ] && info "parity dirs   : all present" || die "the rebase result is missing:$missing
  A tarball built from this would compile and boot and drive no Apple hardware."
ndts=$(ls "$SRC"/arch/arm64/boot/dts/apple/*.dts 2>/dev/null | wc -l)
[ "$ndts" -gt 0 ] || die "no Apple device tree sources in the result"
info "device trees  : $ndts .dts"
[ -f "$SRC/arch/arm64/boot/dts/apple/t8112-j473.dts" ] \
  || die "t8112-j473.dts (Mac mini M2) is absent from the result"

# ------------------------------------------------------------ 6. the tarball
say "6. tarball"
cd "$WORK" || die
rm -rf "$SRCNAM/.git"
# Written reproducibly, so a rerun reproduces the tarball's sha256 and not just
# its content, and anyone rebuilding can check theirs against the published
# one. Each flag removes one thing that varies between runs: --sort=name the
# order the filesystem lists entries in; --mtime the checkout's file times,
# replaced by the Asahi tag's commit time; --owner/--group/--numeric-owner the
# account names; --mode the checkout's umask; --format=gnu any extended
# headers; gzip -n the name and timestamp gzip records.
SRC_EPOCH=$(git -C "$GIT" log -1 --format=%ct "$TAG_SHA") || die "cannot read the Asahi tag's commit time"
case "$SRC_EPOCH" in ''|*[!0-9]*) die "the Asahi tag's commit time is not a number: '$SRC_EPOCH'" ;; esac
tar --sort=name --format=gnu --mtime="@$SRC_EPOCH" --owner=0 --group=0 --numeric-owner \
    --mode='u+rwX,go=rX' -cf - "$SRCNAM" | gzip -9n > "$OUT/$SRCNAM.tar.gz.part" || die "tar failed"
mv "$OUT/$SRCNAM.tar.gz.part" "$OUT/$SRCNAM.tar.gz"
SUM=$(sha256sum "$OUT/$SRCNAM.tar.gz" | cut -d' ' -f1)
info "$OUT/$SRCNAM.tar.gz  ($(du -h "$OUT/$SRCNAM.tar.gz" | cut -f1))"
info "sha256        = $SUM"

# --------------------------------------------------------------- 7. notes
say "7. REBASE-NOTES.md"
#
# Regenerated, never hand-edited: a record that drifts from what was actually
# done is worse than none, because it is trusted.
NOTES=$OUT/REBASE-NOTES.md
# The series each pin belongs to, for the wording below: a kernel bump must
# not leave a stale one in a file that is regenerated, never hand-edited. The
# first two fields, not ${KVER%.*}: a series' first release is named x.y.
KSERIES=$(echo "$KVER" | cut -d. -f1-2)
ASAHI_SERIES=$(echo "${ASAHI_BASE#v}" | cut -d. -f1-2)
{
  echo "# kernel_armv8-mac — how the source tree is produced"
  echo
  echo "Generated by \`tools/rebase-asahi-onto-slackware.sh\`. Do not hand-edit:"
  echo "these are the reviewable record of what was traded to carry Apple Silicon"
  echo "support on Slackware's kernel, and a stale record is worse than none."
  echo
  echo "## Inputs"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Base | Slackware \`k/kernel-source-$KVER\`, committed verbatim |"
  echo "| Delta | \`$ASAHI_BASE..$ASAHI_TAG\` — ${ASAHI_SERIES}-based Asahi release |"
  echo "| Asahi tag | \`$TAG_SHA\` |"
  echo "| Asahi base | \`$BASE_SHA\` |"
  echo
  echo "## Result"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Commits in the Asahi delta | $ALL ($NONMERGE non-merge) |"
  echo "| Applied | **$APPLIED** |"
  echo "| Dropped by git as already upstream | $DROPPED |"
  echo
  echo "### Dropped as already upstream"
  echo
  echo "git recognised the content had reached the $KSERIES stable series between"
  echo "$ASAHI_BASE and $KVER and discarded these. This is the upstreaming"
  echo "trajectory as a measurable fact rather than a claim:"
  echo
  echo "$dropped_list" | sed 's/^/- `/;s/$/`/'
  echo
  echo "## Reproducing"
  echo
  echo '```sh'
  echo "tools/rebase-asahi-onto-slackware.sh    # -> $SRCNAM.tar.gz"
  echo '```'
  echo
  echo "Commit SHAs differ on every run (a commit hash includes its timestamp), so"
  echo "none is recorded here. The tarball is written reproducibly (names sorted,"
  echo "every mtime the Asahi tag's commit time, owner and group 0, gzip without a"
  echo "timestamp), so a rerun reproduces its sha256 as well as its content, and"
  echo "this file byte for byte."
  echo
  echo "The script refuses to emit a tarball if the Apple driver directories or"
  echo "the Mac mini device tree are absent from the result, so a rebase that"
  echo "silently dropped \`drm/apple\` or \`drm/asahi\` cannot be packaged as if it"
  echo "had not. It also stops rather than resolving an unrecorded conflict."
} > "$NOTES"
info "$NOTES"

echo
echo "  Next:"
echo "    copy $SRCNAM.tar.gz to source/kernel_armv8-mac/sources/"
echo "    then build, and gate the package with tools/check-driver-parity.sh"
echo
echo "  $NOTES should be identical to the tree's"
echo "  source/kernel_armv8-mac/REBASE-NOTES.md. A difference means an input"
echo "  changed: the base package, the Asahi pins, or the recorded resolution."
