# asahi-audio doinst.sh -- switch the desktop's sound server to PipeWire.
#
# WHY THIS IS NEEDED AT ALL
# -------------------------
# Everything else this package ships is inert under PulseAudio, and Slackware
# starts PulseAudio by default. Shipping a competing autostart entry is NOT
# enough: both fire in the same session, and PulseAudio takes the pulse socket
# before pipewire-pulse can.
#
# The gap is this package's own launcher waiting for PipeWire's socket before
# starting pipewire-pulse -- correct behaviour, and exactly the window
# PulseAudio needs. KDE does not wait for a phase-1 entry to finish, so no
# amount of ordering closes it.
#
# THE SWITCH IS SLACKWARE'S OWN
# -----------------------------
# /usr/bin/start-pulseaudio-x11 and /etc/xdg/Xwayland-session.d/00-pulseaudio-x11
# both open with, verbatim:
#
#     if ! grep -q "^Hidden=true$" /etc/xdg/autostart/pulseaudio.desktop ; then
#
# Slackware's pulseaudio package adds that test, and Pat's pipewire-enable.sh
# flips exactly this switch, so a literal `Hidden=true` line is Slackware's
# supported off switch; the XDG autostart spec independently requires a desktop
# to ignore an entry that carries it. One line closes both paths.
#
# AND IT IS AN ADMIN FILE, NOT A PACKAGE FILE
# -------------------------------------------
# Slackware ships it as `etc/xdg/autostart/pulseaudio.desktop.new` -- check
# /var/log/packages/pulseaudio-*. The `.new` convention means the live file
# belongs to the admin: the package never overwrites it, and an upgrade cannot
# revert this. Editing it modifies no package. There is already precedent on a
# stock install -- xfce4-clipman-plugin-autostart.desktop carries Hidden=true.
#
# ⚠ REMOVEPKG DOES NOT REVERSE THIS, on purpose. pkgtools does run a package's
# install/douninst.sh when it is removed, but upgradepkg runs the old copy's
# too, so an uninstall hook would turn PipeWire off and kmix back on at every
# upgrade. The PulseAudio and kmix switches are undone by hand instead: the
# original desktop file is kept beside it, and rc.asahi-audio's header says how.
# Nothing is printed: stock Slackware doinst.sh scripts speak only on a fatal
# condition, and this is not one.

PADESK=etc/xdg/autostart/pulseaudio.desktop
RCAA=etc/rc.d/rc.asahi-audio

# The switch follows rc.asahi-audio's executable bit, the documented way back
# to PulseAudio: after `rc.asahi-audio stop` and `chmod -x`, an upgrade leaves
# pulseaudio.desktop as the admin restored it. A fresh install has no
# rc.asahi-audio yet (only the .new that preserve_perms() installs below), so
# it is switched.
if [ -f "$PADESK" ] && { [ ! -e "$RCAA" ] || [ -x "$RCAA" ]; }; then
  if grep -q '^Hidden=true$' "$PADESK" ; then
    : # already switched -- reinstall or upgrade, nothing to do
  else
    # Keep the original exactly once, so a second install cannot overwrite a
    # good backup with an already-modified file.
    [ -f "$PADESK.asahi-orig" ] || cp -a "$PADESK" "$PADESK.asahi-orig"
    printf 'Hidden=true\n' >> "$PADESK"
  fi
fi

# --- the boot-time assertion -------------------------------------------------
#
# The append above is correct and insufficient. On a FULL-SERIES INSTALL this
# script runs before pulseaudio is installed -- asahi-audio sorts before
# pulseaudio in l/ -- so there is no pulseaudio.desktop to edit yet, and
# pulseaudio's own install then lays down the stock one, switch absent.
#
# rc.asahi-audio re-asserts the switch at every boot, which closes that. It is
# idempotent, so it costs nothing when the append above already worked.

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

# rc.asahi-audio.new is packaged executable and installed with stock's
# preserve_perms(): a fresh install is enabled, and an upgrade keeps the
# admin's `chmod -x`, which the switch above and start-session also honour;
# that is the documented way back to PulseAudio.
preserve_perms etc/rc.d/rc.asahi-audio.new
# kmix's autostart entry is ordered after pulseaudio's, which the switch
# above disables -- leaving kmix to start before any sound server and fall
# back to the raw ALSA controls. No package owns /etc/xdg/kmixrc, so
# nothing overwrites this mid-install; rc.asahi-audio re-asserts it anyway.
config etc/xdg/kmixrc.new

# The boot hook is a file this package owns,
# /etc/rc.d/rc.platform.d/aarch64/asahi-audio, which Slackware ARM's
# rc.platform sources from rc.M just before rc.local. /etc/rc.d/rc.local is the
# admin's and is left alone; see speakersafetyd's doinst.sh for why.
