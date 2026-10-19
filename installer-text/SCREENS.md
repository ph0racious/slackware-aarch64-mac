# Every screen this port changes, in the order the installer shows them

There are four: the medium's boot menu, and three during `setup`, one of which
appears only in the "menu" and "expert" prompting modes. There is also one config
file that is not a screen at all. Everything else the installer says is
Slackware's own.

**`usr/lib/setup/setup` is unpatched** — byte-identical to what Slackware
ships, asserted at build time. That is the strongest available statement that
the installer behaves the way it was built to.

**Vanilla delta** is the column that matters when judging whether this still
feels like Slackware. Its bold lead names the kind of change; the rest says
exactly what differs.

---

## Before `setup`

### 1. The medium's boot menu — `grub.cfg`

| | |
|---|---|
| Shown | when the medium boots, before the installer starts |
| Written by | `build-installer-iso.sh`, into the medium's `grub.cfg` |
| Vanilla delta | **entries replaced.** Stock's generic entry becomes this port's; stock's HoneyComb LX2 and ThinkPad X13s entries are dropped; the UEFI Firmware Settings and Reboot entries are stock's, unchanged |

```
Install Slackware Linux (AArch64-mac)
[ UEFI Firmware Settings ]
[ Reboot ]
```

The install entry boots this port's kernel with the parameters of stock's
generic entry, plus `console=tty0` and without `RCFONT`.

---

## During `setup`

### 2. Filesystem menu, "SELECT FILESYSTEM FOR <partition>": `SeTpartitions`

| | |
|---|---|
| Shown | when a Linux partition is to be formatted, `/` included |
| Changed by | `build-installer-initrd.sh`, in stock's `SeTpartitions` and `load_kernel_modules` |
| Vanilla delta | **entries removed.** JFS and F2FS are not offered, and their sentences leave the description. Nothing is added or reworded, and the default is still ext4 |

```
  ext2   Standard Linux Ext2 Filesystem
  ext3   Ext3 Journaling Filesystem
  ext4   Ext4 Journaling Filesystem
- jfs    IBM's Journaled Filesystem
  btrfs  Btrfs Copy-on-Write B-tree Filesystem
- f2fs   Flash-Friendly File System
  xfs    SGI's Journaling Filesystem
```

The description above the menu loses "F2FS is a Flash-Friendly File System."
and "JFS is IBM's Journaled Filesystem, currently used in IBM enterprise
servers."

Neither can hold a root on this 16K-page kernel: GRUB reads only 4K-block
F2FS, which this kernel cannot mount, and JFS crashes it. Both go the way
Slackware retired reiserfs and bcachefs: each detection block in
`SeTpartitions` is commented out with its reason, and each name leaves the
installer's `MOD_FS`, the old line kept.

### 3. Package checklists in "menu" and "expert" modes: each series' `maketag`

| | |
|---|---|
| Shown | at the start of each package series, when setup's prompting mode is "menu" or "expert". The default, "terse", shows none |
| Written by | `build-installer-iso.sh`, from stock's own `maketag` and `maketag.ez` |
| Vanilla delta | **lines added and removed.** Each package this port adds gets a line, ticked, whose text is the title its `slack-desc` already gives setup. The A checklist loses `kernel_armv8`, which the medium does not carry. Every other line, and every word around the lists, is stock's |

```
A    - kernel_armv8              Generic Linux Kernel for AArch64 systems
     + asahi-fwextract           Apple Silicon firmware extractor
     + asahi-scripts             Apple Silicon maintenance scripts
     + hwm-bw-mac                Boot Loader firmware for Apple Silicon Macs
     + kernel_armv8-mac          Slackware's kernel for Apple Silicon Macs
     + lzfse                     LZFSE compression library and tool
     + speakersafetyd            Apple Silicon speaker protection daemon
     + tiny-dfr                  Touch Bar daemon for Apple Silicon MacBook Pro
D    + kernel_armv8-mac-headers  kernel build tree
L    + alsa-ucm-conf-asahi       ALSA UCM profiles for Apple Silicon
     + asahi-audio               PipeWire DSP configuration for Apple Silicon
     + bankstown                 LV2 psychoacoustic bass enhancement
     + lilv                      LV2 plugin host library
     + lsp-plugins-lv2           LSP audio plugin suite, LV2 build
     + lv2                       LV2 audio plugin specification
     + serd                      lightweight RDF syntax library
     + sord                      in-memory RDF store
     + sratom                    LV2 atom RDF serialisation library
     + triforce-lv2              LV2 microphone beamformer for Apple Silicon
     + zix                       lightweight C utility library
```

`mesa` and `pipewire` replace stock's packages under the same names, so the X
and L checklists keep stock's lines for them. Left stock, these checklists
offered `kernel_armv8` and none of this port's packages, which then arrived as
one-by-one prompts afterwards. The build refuses a medium whose checklists do
not name exactly the packages in their series.

"Newbie" prompting shows no checklist: it reads each series' tagfile,
installs `ADD` packages without asking and asks about each `REC` one. This
port's kernel and `hwm-bw-mac` are `ADD`, as stock's `kernel_armv8` and every
`hwm-bw-*` are, so they are never offered for skipping; the rest of this
port's packages are `REC`, and are asked about one at a time, as stock's are.

### 4. Boot loader INSTALL / SKIP — `grub-dialog.txt`

| | |
|---|---|
| Shown | after every package series is installed, when the boot loader is configured — **on untested Apple Silicon only** |
| Drawn by | `000-grub-configure`, `dialog --yesno --colors --no-collapse` |
| Vanilla delta | **an added screen.** Upstream's own "INSTALL BOOT LOADER ON UNKNOWN HARDWARE MODEL" is left untouched and still shown, on hardware outside the Apple M1/M2 family |

**Outside the filesystem menu and the menu-mode checklists, this is the only
screen in the flow where a decision is made**, and choosing INSTALL is what leaves a machine that boots.
It is also the only screen that renders `\Z` colour codes, and the only place
`%HWM%` works — substituted at run time with the detected model.

### Which machines see it

`000-grub-configure` classifies into three tiers, and this screen belongs to
the middle one:

| Tier | Machine | What happens |
|---|---|---|
| tested | the README's Tested models | boot loader installed with **no prompt**, as on any Slackware-supported model |
| M1 / M2 | any other M1 or M2 Mac | **this screen** |
| anything else | M3, M4, non-Apple | upstream's own unsupported-hardware screen, verbatim |

⚠ **The tiers choose words, not templates.** This media ships one kernel, so
there is one GRUB template and every machine gets it — classification cannot
change that and does not try to. A model string that fails to match therefore
costs wording, never a broken boot. That is what makes matching on model names
acceptable here.

---

## Not a screen: `template-grub-mac.cfg`

The GRUB configuration written onto the **installed system**. It replaces
Slackware's `template-grub.cfg`, which loads `/boot/Image-armv8` with an initrd
— neither of which this media installs.

`%KERNELPATH%`, `%ROOTPARTUUID%` and `%ROOTFSTYPE%` are filled at install time
from the target that was just installed.

It carries the same `###MAC-BEGIN`/`-END` markers `grub-entry-mac`
manages, so `grub-entry-mac --install` replaces that entry in place
instead of adding a second copy. It rebuilds the entry from scratch, so a
parameter added to the `linux` line by hand goes in again through its
`--cmdline=`, and the template's own comment tells whoever edits the
installed file so.

---

## Screens left unchanged

* **NO EFI SYSTEM PARTITION DETECTED** (`setup:72`) — vanilla, untouched, and
  unreachable on a reinstall: the `sbin/probe` carried patch stops Slackware
  hiding an ESP it labelled `SLKefi` itself.
* Every other partition, series-selection and configuration screen —
  vanilla, untouched. That is the point: the installer should behave normally.

## Authoring rules

See `README.md` here. In short: `%GRUBCONF%` works in any screen, `%HWM%` only
in `grub-dialog.txt`, `\Z` colour codes only in `grub-dialog.txt`, and the build
fails rather than printing any of them at the user.
