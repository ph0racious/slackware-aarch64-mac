# Installation runbook

## Before installing: USB under U-Boot

**A. Only USB-C ports can be used to boot the install media.**

If the machine has USB-A ports, they are non-functional during U-Boot and thus
cannot boot the USB ISO. On USB-C ports, mixed combinations of C/A adaptors
& hubs should all work.

**B. Keyboard may not work during U-Boot/grub, even on USB-C.**

Neither of the two (PC) keyboards available for testing would work in U-Boot.
Once the Linux kernel loads, they function. Asahi's own documentation does
not mention this at all, suggesting something particular to the test lab arrangement,
but it's mentioned here in case anyone else encounters it.

Booting to a first install can be hands-off anyway, as the USB stick is the
only bootable device during U-Boot.

If attempting to perform a re-install without keyboard support
and U-Boot keeps defaulting to booting from NVME,
rename `EFI/BOOT/BOOTAA64.EFI` on the ESP (mounted at `/boot/efi` on the installed system) and it will
fall through to USB.

## Installing

Install steps are specific to this port. Anything considered a
normal part of installing Slackware is generally omitted.

### 1. Assemble & verify the media

The image ships as a three-part 7-Zip because of the github asset size cap.<br>
Download all three parts from Releases into one folder and open
`slackware-aarch64-mac.7z.001` to extract the contents.

Verify the checksum published with the release before writing:

```sh
sha256sum slackware-aarch64-mac.iso
```

Write ISO to a USB stick - Rufus is tested, similar methods should work.

### 2. Boot into fully-updated macOS and run the [official Asahi installer](https://asahilinux.org/), choosing *UEFI environment only* mode

```sh
curl https://alx.sh | sh
```

This creates machine-signed m1n1 stage 1 loader, the EFI partition,
and the pinned macOS firmware stub.

Optionally shrink macOS partition if desired.

***TAKE NOTE*** of the Asahi Installer's warnings and the given procedure
required on first reboot!

*DO NOT REBOOT* just yet.

### 3. Insert the slackware-aarch64-mac media and capture the *current* Wi-Fi/BT firmware while still in macOS

```sh
sudo sh /Volumes/SLKINS_AIO-/macos-fw-harvest.sh
```

`SLKINS_AIO-` is the volume name Rufus gives the stick. If it was written
another way, `ls /Volumes` shows the name to use.

The Asahi installer builds its own firmware package at step 2, but it does
so from a pinned macOS version, not the fully-updated live install.
Wi-Fi on the test A2686 was significantly broken with the older firmware
so it's suggested this step is not skipped without good reason.

If setup detects harvested Wi-Fi/BT firmware it will use it, otherwise
that and everything else comes from the Asahi installer's package. The
harvest file sits at `<ESP>/asahi/all_firmware-live.tar.gz`.

Note: If wanting to re-install from a 100% clean slate, the file must be
removed lest it be automatically re-used. The same script does that if
necessary, with its `--remove` switch.

### 4. Reboot the machine EXACTLY as the Asahi installer instructed

Ensure the USB stick remains attached.<br>
Following this step, the machine will finish the U-Boot installation
process and eventually boot the USB stick.

### 5. Once the media boots, proceed with installation as normal

The internal SSD is **`/dev/nvme0n1`**.
After step 2 a clean machine looks like this:

| Partition | Size | Description |
|---|---|---|
| `nvme0n1p1` | ~500M | Apple iBoot container |
| `nvme0n1p2` | varies | macOS |
| `nvme0n1p3` | ~2.3G | Asahi UEFI stub |
| `nvme0n1p4` | ~477M | EFI System Partition |
| *(gap)* | remainder | **free space** |
| `nvme0n1p5` | ~5G | recoveryOS |

- **NEVER disturb m1n1 on the EFI partition** - see Asahi's warnings
- Setup should detect & use the EFI System Partition with no prompt
- Setup will harmlessly relabel the EFI partition to `SLKefi`
- Create your Linux filesystem & swap partitions in the free space and run setup
- Answer YES to the UTC hardware clock question

### 6. At first boot, check speakersafetyd before playing any audio

Confirm speaker protection is running:

```sh
/etc/rc.d/rc.speakersafetyd status     # must say "speakers protected"
```

For machines on which Asahi does not run speakersafetyd, the command reports as such.

⚠ **Speakers can apparently incur *physical damage* if fully driven
on some Apple devices.**<br> This is according to the Asahi project's
documentation; Asahi ship speakersafetyd as a precaution.<br>
**The stated protection of speakersafetyd has NOT been and will NOT be validated by this project!**<br>
Speakersafetyd is included for completeness but ultimately: **YOUR hardware, YOUR risk.**

### 7. Installation complete

Adduser and startx at your leisure.<br>
KDE is the only currently tested environment so other choices will be pioneering.
