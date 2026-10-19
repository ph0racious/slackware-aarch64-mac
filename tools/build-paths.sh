# build-paths.sh -- where build artifacts live. Sourced, not executed.
#
# One definition: every tool that needs one of these paths reads it here rather
# than computing its own, which is how a path goes stale when artifacts move.
#
# BUILDROOT is the one setting. It puts the whole lot somewhere else in one
# move:
#
#   BUILDROOT=/scratch/mac tools/build-installer-iso.sh
#
# ⚠ A media build writes several GB -- the ISO staging tree and a ~4.9 GB
# image. Point BUILDROOT at something with room.

BUILDROOT=${BUILDROOT:-$HOME/mac-build}

W_DIR=$BUILDROOT/work               # the kernel Image + initrd the ISO build consumes
ISO_DIR=$BUILDROOT/iso              # the base ISO in, the finished medium out
WORK=$BUILDROOT/installer-build     # ISO staging root
PKGDIR=$WORK/packages               # this port's built .txz, staged for the medium

# The medium's filename. ⚠ Its INTERNAL volume label is a different thing
# entirely and must stay `SLKins_aio-pkgs`: the medium's GRUB finds itself by
# that label, so renaming the file is safe but relabelling the volume is not.
ISO_MAC="$ISO_DIR/slackware-aarch64-mac.iso"
