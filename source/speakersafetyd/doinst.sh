# Slackware install script for speakersafetyd.
#
# This package deviates from the usual Slackware convention that an admin opts
# a service in by hand. It is done deliberately:
#
#   Upstream starts this daemon from a udev rule via ENV{SYSTEMD_WANTS}. On
#   Slackware that rule is inert, so without intervention the daemon NEVER runs
#   and nothing reports an error: Asahi's kernel driver keeps the speakers at a
#   reduced volume, and nothing says why. A service the hardware does not work
#   without should not silently default to "off", so it ships switched on.
#
# How, the Slackware way, as openssh does rc.sshd: rc.speakersafetyd.new is
# packaged executable, and preserve_perms() below is stock's own
# (qemu-guest-agent's, verbatim). A fresh install gets the executable script,
# so the service is enabled; an upgrade keeps the mode the admin left, so a
# deliberate `chmod -x /etc/rc.d/rc.speakersafetyd` survives it.
#
# It prints nothing, like every stock Slackware doinst.sh short of a fatal
# condition. The user confirms protection with `rc.speakersafetyd status`, which
# docs/INSTALLING.md step 6 tells them to do before playing audio.

config() {
  NEW="$1"
  OLD="$(dirname $NEW)/$(basename $NEW .new)"
  if [ ! -r "$OLD" ]; then
    mv "$NEW" "$OLD"
  elif [ "$(cat $OLD | md5sum)" = "$(cat $NEW | md5sum)" ]; then
    rm "$NEW"
  fi
}

preserve_perms() {
  NEW="$1"
  OLD="$(dirname $NEW)/$(basename $NEW .new)"
  if [ -e $OLD ]; then
    cp -a $OLD ${NEW}.incoming
    cat $NEW > ${NEW}.incoming
    mv ${NEW}.incoming $NEW
  fi
  config $NEW
}

# The executable bit on /etc/rc.d/rc.* is Slackware's enable switch.
preserve_perms etc/rc.d/rc.speakersafetyd.new

# Its log's rotation, admin config as stock's logrotate entries are.
config etc/logrotate.d/speakersafetyd.new

# The boot hook is NOT written here. It is a file this package owns,
# /etc/rc.d/rc.platform.d/aarch64/speakersafetyd, which Slackware ARM's
# rc.platform sources from rc.M just before rc.local.
#
# Nothing here touches /etc/rc.d/rc.local. That file belongs to the admin, and
# sysvinit-scripts ships it as .new: this package installs before
# sysvinit-scripts on a full-series install, so creating rc.local here left
# Slackware's own copy behind as rc.local.new, and accepting that in
# `slackpkg new-config` dropped the hook without a word.
