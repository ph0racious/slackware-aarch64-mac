# Slackware install script for tiny-dfr.
#
# This package deviates from the usual Slackware convention that an admin opts
# a service in by hand, as speakersafetyd does: on the 13-inch M1 and M2
# MacBook Pro the function, media and brightness keys exist only on the Touch
# Bar, so a daemon that defaults to "off" leaves the machine without them.
# rc.tiny-dfr does nothing on a machine without a Touch Bar, so enabling it
# everywhere costs nothing.
#
# As speakersafetyd does it: rc.tiny-dfr.new is packaged executable and
# installed with stock's preserve_perms(), so a fresh install is enabled and an
# upgrade keeps the admin's `chmod -x`.
#
# It prints nothing, like every stock Slackware doinst.sh short of a fatal
# condition.

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
preserve_perms etc/rc.d/rc.tiny-dfr.new

# Its log's rotation, admin config as stock's logrotate entries are.
config etc/logrotate.d/tiny-dfr.new

# The boot hook is a file this package owns,
# /etc/rc.d/rc.platform.d/aarch64/tiny-dfr, which Slackware ARM's rc.platform
# sources from rc.M just before rc.local. /etc/rc.d/rc.local is the admin's and
# is left alone; see speakersafetyd's doinst.sh for why.
