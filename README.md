# slackware-aarch64-mac

## What is this?

[A Slackware installer ISO](https://github.com/ph0racious/slackware-aarch64-mac/releases) with hardware support for M1/M2 Macs, using Slackware AArch64's own kernel.

The media is produced by the build tree from two upstream sources:<br>
- **Slackware AArch64-current:** The base (date-pinned efi_generic.iso)
- **The Asahi Linux Project:** The boot chain and SoC enablement

This tree just packages all relevant requirements the Slackware way,
and adapts slack's native installer to make use of them.

## OK but what *exactly* is this?

The tree vs upstream aarch64:
- Slackware's 6.18.33 kernel with Asahi's Apple SoC delta rebased onto it & config extended to Asahi's driver set
- 18 added packages plus rebuilds of stock mesa and pipewire to configure options
- 7 carried patches alongside Asahi's verbatim 21-patch U-Boot series
- 4 installer patches including one boot-loader dialog screen and a GRUB template, plus the package checklists regenerated to match
- 3 port-specific tools: firmware installer, grub installer, installation checker
- 1 pre-install firmware harvest script to be run in macOS

## Will it run on my Mac?

Three model-dependent categories exist, setup respects each when installing the boot loader.

Tested: A fully supported machine, setup writes grub silently.<br>
Untested: Should work, unproven. Setup throws "untested" and confirms before writing grub.<br>
Unsupported: Probably broken. Setup throws "unknown" and offers to skip grub.<br>

| Status | Model | Variant |
|---|---|---|
| TESTED | **Mac mini M2** | (A2686, `t8112`/`j473`) |
| UNTESTED | **ANY other M1/M2 MacBook, iMac, mini, Studio or Mac Pro** | A2337, etc |
| UNSUPPORTED | **Later Silicon models, M3 onwards(*)** | |

On tested machines a full-series install completes with the system
immediately bootable, all hardware supported (GPU acceleration,
audio DSP, Wi-Fi, Bluetooth, any machine-specific additions),
and functional X (KDE).

**Only component types that exist on Mac mini have currently been tested.**<br>
Internal panel/backlight, keyboard/trackpad, lid switch, webcam, microphone 
and battery support are all unconfirmed.
The tree carries all the drivers and prerequisites; they are *expected* to work but not known to.

(*) M3 support wasn't initially scoped but became available upstream during development, 
it might be mostly functional or totally broken.

## Installing

The [Installation runbook](docs/INSTALLING.md) walks through the steps of
preparing the Asahi UEFI-only environment and booting the Slackware installer
built for this hardware. The process is straightforward but it's recommended to
read all steps fully before commencing the first.

## Building

Ideal build host is any Slackware AArch64-current system, real or emulated.<br>
QEMU on x86 is viable.

The [Build runbook](docs/BUILD.md) contains all information to build the tree: prerequisites, the pinned
upstream sources, build order, steps to reproduce kernel source, and the gates each
artifact must pass. [`docs/PORTING.md`](docs/PORTING.md) is the engineering
reference for maintaining and updating the port, and holds the historical trap info.

## Known limitations

- **Updating any of the packages this tree touches, or their dependencies, is
  likely to break things.**
- **2.4 GHz scanning is intermittently blind** on A2686 for many seconds at a time;
  5 GHz is unaffected. This bug is unattributed, but it reproduces
  on Asahi's own kernel, on both available firmware versions. If NetworkManager
  complains about a missing access point when first associating, cycling Wi-Fi off/on fixes the list.
- **HDMI to TV may crop every edge.** Can be worked around with the
  set's own picture mode settings (*PC*, *Just Scan*, *1:1*).
- **USB-A does not work in U-Boot.** Its controller needs firmware Asahi
  [cannot redistribute](https://asahilinux.org/docs/sw/u-boot/), so install media
  must use USB-C. Linux drives USB-A normally once booted.
- **U-Boot/grub might not see the USB keyboard.** Unattributed. See
  [warning B](docs/INSTALLING.md#before-installing-usb-under-u-boot).
- **PipeWire serves audio, not PulseAudio.** The speaker DSP runs as PipeWire
  filter graphs, so PulseAudio's autostart is disabled.
- **Kmix doesn't autostart.** It races the sound server at login and upstream
  intent is that it be disabled and replaced with the plasma applet.
- **Sleep is enabled, with caveats.** Upstream Slackware ARM disables it, but this port
  turns it back on, since it mostly works and a MacBook without sleep is undesirable.
  By upstream Asahi limitation only the power button or lid switch can wake the whole machine;
  USB devices wake the internal hub only, causing USB power output to resume but not
  anything else. Sleep-on-idle is shipped _disabled_; accessing the power button
  constantly on a mini/studio is also undesirable.

## Reporting problems or successful hardware tests

This is a personal project done on a whim, so please moderate/bury expectations.<br>
I will maintain until it's no longer interesting to me, upstream makes it irrelevant,
or someone does it better; whichever comes first.

Please see `docs/TESTING.md` for information on requirements for models to
transition from 'Untested' to 'Tested' status. A tester submitting a report
just runs `verify-install-mac --tester` and answers the questions it prints.

## License

This tree's own work in its entirety is written under the same terms that
upstream Slackware uses for build scripts. See [`LICENSE`](LICENSE).<br>
Everything it builds or carries keeps its own license:
kernel patches are GPL-2.0.<br>
Most of the patch series under `source/*/patches/` are other people's work
carried verbatim.<br> Any that this port wrote are offered under the license of
the project they patch. Attribution is in [`NOTICE`](NOTICE).

This is unofficial work, not endorsed by or affiliated with Slackware, the Asahi
Linux project, Apple, or any other parties explicitly stated or otherwise implied.

## Credits

- **Patrick Volkerding**

  [Slackware Linux](http://www.slackware.com/)

- **Stuart Winter**

  [The Slackware ARM/AArch64 port](https://arm.slackware.com/)

- **The Asahi Linux project**

  [All of the hard work to make this possible on Apple hardware is theirs.](https://asahilinux.org/)

- **Jay Lanagan** (`mac-a-r0ni`)

  For showing some [working examples](https://github.com/mac-a-r0ni/asahi-slackware)
  of Asahi PKGBUILDs as SlackBuilds, inspiring an attempt at this.
