# installer-text.sh -- how a file in installer-text/ becomes a screen in the
# initrd. Sourced, not executed.
#
# WHY THIS IS ONE FILE AND NOT TWO COPIES
# ---------------------------------------
# Two scripts have to agree about these files:
#
#   build-installer-initrd.sh   WRITES them into the initrd
#   build-installer-iso.sh      VERIFIES the medium's copies against this tree
#
# The verification works by md5, so the moment those two disagree about what
# rendering means, one of two things happens: either every medium is reported
# stale, or -- worse -- the check is quietly comparing the wrong thing. So the
# destination map and every transformation (%GRUBCONF% substitution) live here,
# once, and both builders call it.
#
# PLACEHOLDERS
# ------------
#   %GRUBCONF%   substituted HERE, at build time, in every file.
#   %HWM%        left alone. It is the machine model, which is only knowable at
#                runtime, and 000-grub-configure sed's it in when it draws the
#                dialog. Valid in grub-dialog.txt and nowhere else, because
#                nothing substitutes it anywhere else -- it_check enforces that.
#
# COLOUR CODES
# ------------
# dialog's \Zb, \Z1, \Zn and friends are rendered ONLY when dialog is passed
# --colors, and only one of these files is drawn that way:
#
#   grub-dialog.txt   dialog --yesno --colors   ->  renders them
#
# Anywhere else they would print literally. That is not obvious from looking at
# the files, which is why it_check refuses rather than leaving it to be
# discovered on screen.

# The target's grub.cfg, as the operator will be told to edit it.
#
# /mnt is not a guess: usr/lib/setup/setup sets T_PX="/mnt" as a literal, and
# 000-grub-configure builds ARMEDSLACK_GRUBCONF=${T_PX}/boot/grub/grub.cfg from
# it. build-installer-initrd.sh asserts that literal is still there, so this
# constant cannot quietly go stale.
IT_GRUBCONF=/mnt/boot/grub/grub.cfg

# dest-inside-initrd <TAB> source-in-installer-text <TAB> kind
#
#   plain    printed as-is; no markup is interpreted
#   colour   drawn by `dialog --colors`, so \Z sequences render
#   config   not a screen at all -- the GRUB template installed onto the target
#
# In flow order. SCREENS.md documents where each one appears and how it differs
# from vanilla Slackware -- read that before moving text between them.
# EDITS ONLY, NOT DECLARATIONS THAT A SCREEN WAS LEFT ALONE.
#
# Every row below is a screen whose text genuinely differs from Slackware's, or
# the GRUB template, which replaces stock's. Screens we leave alone are not
# listed and have no file. A sentinel meaning "a file that says do not patch
# this" would be the same thing said twice.
#
# usr/lib/setup/setup is consequently UNPATCHED, which is the strongest
# available statement that the installer behaves the way Slackware built it.
it_map() {
  cat <<'EOF'
usr/lib/setup/apple-grub-dialog.txt	grub-dialog.txt	colour
usr/share/hwm-configure/platform/aarch64/installer/assets/bootloader/grub/template-grub.cfg	template-grub-mac.cfg	config
EOF
}

# it_render <srcfile>  -- what lands in the initrd, on stdout.
#
# Strips CR because a stray ^M lands on a console that has no way to hide it,
# and a tree edited on Windows acquires them silently. See .gitattributes.
#
# The awk pass GUARANTEES A FINAL NEWLINE. A file whose last line has no
# newline -- the normal result of an editor that does not add one -- runs
# straight into whatever its consumer prints next, and that is not something an
# author should have to think about. awk rebuilds every record with a
# terminator and leaves deliberate trailing blank lines alone.
it_render() {
  tr -d '\015' < "$1" | sed "s|%GRUBCONF%|$IT_GRUBCONF|g" | awk '{ print }'
}

# it_check <srcfile> <kind>  -- refuse to ship a screen that would print its own
# markup at the user. Prints the reason and returns 1.
#
# Both are build failures rather than warnings: a warning scrolls past in a
# 200-line build log, and the thing it warns about only becomes visible on a
# machine you are standing in front of, partway through an install.
it_check() {
  local src=$1 kind=$2 base rendered rc=0
  base=$(basename "$src")

  rendered=$(it_render "$src")

  # BOTH exceptions below key on KIND, not on the filename.
  #
  # They are the same exception wearing two hats: `colour` means "drawn by
  # 000-grub-configure", and that one consumer is what supplies BOTH the
  # --colors flag and the %HWM% substitution. Keying on the basename instead
  # looks equivalent and is not: a file carrying %HWM% at a `plain` destination
  # would pass with the placeholder unsubstituted, which is precisely the
  # "prints its own markup at the user" case this exists to stop. it_map is the
  # single place that decides which file is which.
  local left
  left=$(printf '%s\n' "$rendered" | grep -oE '%[A-Z_][A-Z0-9_]*%' | sort -u)
  if [ -n "$left" ]; then
    local unexpected=""
    local p
    for p in $left; do
      # %HWM% is filled at run time by 000-grub-configure, which is the only
      # thing that knows the machine model.
      if [ "$p" = "%HWM%" ] && [ "$kind" = colour ]; then continue; fi
      # The GRUB template's three are filled at install time by the same
      # script, from the target it has just finished installing.
      if [ "$kind" = config ]; then
        case "$p" in %KERNELPATH%|%ROOTPARTUUID%|%ROOTFSTYPE%) continue ;; esac
      fi
      unexpected="$unexpected $p"
    done
    if [ -n "$unexpected" ]; then
      echo "installer-text: $base still contains:$unexpected" >&2
      echo "  Nothing substitutes those, so they would be printed at the user" >&2
      echo "  exactly as written. Known placeholders:" >&2
      echo "    %GRUBCONF%      any screen -- substituted at build time" >&2
      echo "    %HWM%           grub-dialog.txt ONLY -- run time, from" >&2
      echo "                    000-grub-configure" >&2
      echo "    %KERNELPATH%    template-grub-mac.cfg ONLY -- install time" >&2
      echo "    %ROOTPARTUUID%  template-grub-mac.cfg ONLY -- install time" >&2
      echo "    %ROOTFSTYPE%    template-grub-mac.cfg ONLY -- install time" >&2
      rc=1
    fi
  fi

  # A placeholder named inside a COMMENT of the GRUB template is filled too:
  # the install-time fill is a global sed, so the comment arrives in every
  # installed grub.cfg reading "/boot/Image-armv8-mac, <uuid> and ext4 are
  # filled in...". Describe placeholders in words there.
  if [ "$kind" = config ] \
     && printf '%s\n' "$rendered" | grep -qE '^[[:space:]]*#.*%[A-Z_][A-Z0-9_]*%'; then
    echo "installer-text: $base names a placeholder inside a comment; the" >&2
    echo "  install-time fill would rewrite it there as well. Use words." >&2
    rc=1
  fi

  # dialog colour codes in a screen that cannot render them.
  if [ "$kind" != colour ] && printf '%s\n' "$rendered" | grep -q '\\Z'; then
    echo "installer-text: $base uses dialog colour codes (\\Z...) but nothing" >&2
    echo "  renders them there -- they would print literally." >&2
    echo "  grub-dialog.txt is the ONLY screen with colour: it is drawn by" >&2
    echo "  dialog --colors. Use plain text." >&2
    rc=1
  fi
  return $rc
}
