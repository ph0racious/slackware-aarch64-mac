# Slackware install script for kernel_armv8-mac.

# Standard Slackware handling for a config file shipped as .new: install it as
# the live file on a fresh install, but on upgrade leave an existing, possibly
# user-edited, config in place and keep the .new alongside for manual merging.
config() {
  NEW="$1"
  OLD="$(dirname $NEW)/$(basename $NEW .new)"
  if [ ! -r "$OLD" ]; then
    mv "$NEW" "$OLD"
  elif [ "$(cat $OLD | md5sum)" = "$(cat $NEW | md5sum)" ]; then
    rm "$NEW"
  fi
}

config etc/xdg/powermanagementprofilesrc.new
config etc/elogind/sleep.conf.d/20-mac.conf.new
