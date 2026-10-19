# Porting notes

Packages are ports of Arch PKGBUILDs from
[`AsahiLinux/PKGBUILDs`](https://github.com/AsahiLinux/PKGBUILDs), and for
`asahi-scripts` / `asahi-fwextract` the `asahi-alarm` org. Asahi moves faster
than Slackware-current, so drift is the main ongoing cost.

A full install from the medium is a complete build host ([`BUILD.md`](BUILD.md)),
so the port can be rebuilt and changed on the Mac it runs on.

## Traps — symptom first

Traps that bite while building, packaging or maintaining the port. The last
column names where the fix lives.

### Packaging and media

| Symptom | Cause | Handled in |
|---|---|---|
| setup's board hooks show *"'slk-hwm-discover' is missing … critical component of the Kernel package"* | Replacing `kernel_armv8` inherits its non-kernel duties | `kernel_armv8-mac.SlackBuild` installs it to `/sbin` from `source/slackware-k/`, and the parity gate asserts it reached the package |
| Tagfile `REC`/`ADD` seems to have no effect | `terse`/`full` prompting **never reads tagfiles**, and `menu`/`expert` build their own from each series' `maketag` checklist; only `newbie` (and `custom`/`tagpath`) follow the medium's tagfiles | use `newbie` prompting when tagfile selections have to be honoured |
| In `menu`/`expert` prompting, the A checklist offers `kernel_armv8` and none of this port's packages, which then arrive as one-by-one prompts | each series' `maketag` and `maketag.ez` is a checklist with one hand-kept line per package plus two loops naming every package; they describe the stock series until rewritten | `build-installer-iso.sh` rewrites them to name exactly the series, and its metadata gate refuses a medium whose checklists do not (`installer-text/SCREENS.md`, screen 3) |
| ISO rebuild fails after the `-rm` steps report success | xorriso refuses a non-empty `-outdev`; the error arrives late and reads like the removals broke it | `build-installer-iso.sh` clears the output first |
| Media boots GRUB, then cannot find itself | Volume label must stay `SLKins_aio-pkgs` | `build-installer-iso.sh` |
| Rebuilt ISO boots nothing | El Torito is discarded unless `-boot_image any keep` | `build-installer-iso.sh` |
| Installer initrd unreadable by the kernel | The kernel's initramfs decoder accepts xz only with a CRC32 check or none, and xz defaults to CRC64 | `build-installer-initrd.sh` repacks with `xz --check=crc32`, as stock's initrd is |
| Installer boots but sees no hardware | Module tree version ≠ running kernel; modprobe just finds nothing | `build-installer-initrd.sh` refuses to build |
| Rebuilt media boots and then sees no storage and no network, having been built from a tree where nothing changed | A **versioned** kernel path in a builder goes stale: the initrd is built around one kernel build while the medium carries another, so `modprobe` looks in `/lib/modules/<running>` and finds nothing. The failure looks like broken hardware support. **Checking the artefact does not check the recipe** | keep every kernel and initrd path in the builders **unversioned**; `build-installer-iso.sh` reads the version string out of the kernel, the `lib/modules/<ver>` path out of the initrd, and **refuses if they differ** |
| Installer cannot find its own packages from a USB stick, falls back to asking for the source partition and directory by hand | The media is located by volume label `SLKins_aio-pkgs`, but **FAT32 labels are 11 characters**. A stick written the way users actually write one (Rufus, default ISO mode) presents as `SLKINS_AIO-`, so the match misses. Fine from an optical image, broken from the media everyone will actually use | carried patch in `build-installer-initrd.sh` extends the label match to the truncated form — and only touches `grep -E` lines, because adding an alternation to a basic-regex grep would match nothing at all |
| **GRUB's own `search --label` misses on the same stick, one stage earlier** | Same 11-character truncation, different consumer. The initrd patch above fixes the *installer's* source detection, not GRUB's. Rufus does rewrite the ISO label to the FAT32 one in `grub.cfg`, but not on every line: on this port's stick it rewrote the fallback `search` line, while a full-label search on an `if !` line was left as it was and missed at boot (GRUB: `no such device: SLKins_aio-pkgs`). | see the row below |
| **GRUB prints `can't find command '['` and `no such device`, pauses, then boots anyway** | Two faults in one line. `[` is GRUB's **`test`** module, which is not built into Slackware's `BOOTAA64.EFI` and was never `insmod`ed -- the entry's other `insmod`s are silent no-ops because those modules *are* built in, so the omission only shows at boot. The failed test then made `if !` true, so the searches ran regardless, and the full label misses on a Rufus stick. GRUB prints a command's own error even inside `if !`, so both land on screen and the boot pauses | `build-installer-iso.sh` searches the **truncated label first** -- Rufus is what the instructions tell people to use, so that is the common case -- and drops the `[ -e ]` guard entirely. A dd-written or optical image takes one miss and then matches. ⚠ Do not reintroduce a `test`-based guard |
| A network install, or slackpkg pointed at a copy of the medium, sees stock's package list: none of this port's packages, and records for the stock ones it replaces, which are not on it | The medium has **two** `PACKAGES.TXT`, `slackwareaarch64-current/PACKAGES.TXT` and `…/slackware/PACKAGES.TXT`, byte-identical (on the mirror the second is a symlink to the first). Setup's FTP/HTTP source builds its package tree from the **top-level** one, so editing only the inner copy leaves a network install reading the stock tree. The USB path never notices: it walks the series directories | `build-installer-iso.sh` rewrites one copy and writes it to both paths, along with both `CHECKSUMS.md5`, `FILELIST.TXT`, `slackware/FILE_LIST` and `slackware/MANIFEST.bz2`. A gate replays setup's network-source lookup and refuses the medium if any record does not resolve |
| Media rebuilt as a "hybrid" ISO stops booting and drops to GRUB's command line (`grub>`) | Promoting the El Torito image to a real GPT partition moves GRUB's `$root` and **`$prefix`** onto that small ESP. The GRUB image's embedded config (the medium's `grub-stub.cfg`) searches for `EFIBOOTISO`, which is `efiboot.img`'s own FAT label: on this port's Rufus stick no filesystem carries it, so `$root` stays the partition holding `grub.cfg`, but on the hybrid it matches, and the image holds only `EFI/BOOT/BOOTAA64.EFI`, so `configfile /grub.cfg` finds nothing | do not add a partition table to the ISO; write it unmodified, as [`INSTALLING.md`](INSTALLING.md) describes |

### Boot and kernel

| Symptom | Cause | Handled in |
|---|---|---|
| `unknown-block(0,0)` — disk found, root not | `root=UUID=`/`LABEL=` need an initrd; the kernel resolves `PARTUUID=`, `PARTLABEL=` or a device name, never a filesystem's `UUID=` or `LABEL=` | `grub-entry-mac` |
| A keypress will not wake a suspended machine | **No device tree node declares `wakeup-source`**, so there is no wake path to arm. Only the SMC ends a sleep: power button, or lid on a laptop | idle suspend is off in the Plasma profile `kernel_armv8-mac` ships |
| Freshly installed machine boots the wrong kernel | `grub-mkconfig` refuses to run on ARM, so nothing generates an entry; `/etc/grub.d/` is inert | the installer's `000-grub-configure` patch; `grub-entry-mac --install` where the entry is missing |
| Adding an `initrd` or `devicetree` line breaks a working boot | Everything for `/` is built in; U-Boot supplies the DTB via EFI | `grub-entry-mac --verify` |
| `make kernelrelease` ignores the `CONFIG_LOCALVERSION` you just set | `setlocalversion` reads `include/config/auto.conf`, written by the *first* resolve and never refreshed. Modules would install into another kernel's directory | `migrate-kernel-config.sh` runs `syncconfig` and asserts the release |
| Config says 16K pages, built kernel is 4K | Page size is a Kconfig *choice*: clearing 4K and re-resolving re-defaults it back before 16K is ever set | `migrate-kernel-config.sh` — the disable/set block runs no `olddefconfig` of its own |
| **Machine resets itself mid-boot, ~30 s in, no error on screen** — identical with `nomodeset`, so not the display | **U-Boot leaves the Apple SoC watchdog running when Linux starts.** Without `CONFIG_APPLE_WATCHDOG` nothing claims or feeds it, so it fires on a timer regardless of kernel health. The driver adopts an already-running watchdog: it reads `WD1_CTRL` and on `RESET_EN` sets `WDOG_HW_RUNNING` so the core pets it | `CONFIG_APPLE_WATCHDOG=y` |
| **Every interactive prompt in the installer is invisible; anything using `read` hangs** — any Apple machine | Apple device trees set `chosen/stdout-path = serial0`. With no `console=` on the command line, `/dev/console` becomes the SoC UART, which has nothing attached. busybox init hands that to `rc.S` as stdin/stdout, so output vanishes and `read` waits on serial while the USB keyboard types into tty1 | `console=tty0` on the medium's install entry |
| Keystrokes are eaten — the console responds to roughly every third one — and a *"press Enter to activate this console"* line appears under the installer banner | Two shells on the same terminal. The shipped inittab has `::respawn:-/bin/bash` on `/dev/console`, and `rc.installerconfig:63` adds `tty1::askfirst:-/bin/bash`. Before `console=tty0` those landed on different devices; once `/dev/console` **is** tty1 they collide and split the input stream | **`tty1noaskfirst`**, which Slackware provides for exactly this — its own comment says *"Opt out by supplying tty1noaskfirst"*. Goes on the cmdline **together with** `console=tty0`; neither is right alone |
| **The *installed* system boots silently, and an fsck prompt after an unclean shutdown never appears** | Same `stdout-path = serial0`, same dead UART — the installed system inherits it, because an entry with no `console=` at all leaves it there. Easy to miss, because `agetty` runs on tty1 regardless, so you still get a login prompt and the machine looks fine | `console=tty0` is on the entry the installer and `grub-entry-mac` write. `--verify` warns when an entry has no `console=` |
| A root on ext2 installs, then panics at the first boot: `VFS: Unable to mount root fs` | Setup offers every filesystem in the installer's `MOD_FS` and loads each as a module first, so a filesystem this kernel has only as a module is offered, installs cleanly, and cannot be mounted without an initrd | `migrate-kernel-config.sh` builds every one in (ext2 through ext4's `EXT4_USE_FOR_EXT2`, which needs `EXT2_FS` off), and `build-installer-initrd.sh` refuses an initrd whose kernel lacks any filesystem `MOD_FS` names |
| Setup offering JFS or F2FS, though neither can hold a root here | **F2FS:** on 16K pages the kernel mounts only F2FS made with 16K blocks, GRUB's F2FS driver reads only 4K blocks (`F2FS_BLK_BITS 12`), and this base's `mkfs.f2fs` makes only 4K, so no F2FS root can boot. **JFS:** memory compaction migrating JFS metadata pages crashes this kernel (a NULL dereference in `remove_metapage`), and GRUB 2.14 could not read a kernel written to JFS | as Slackware stopped offering reiserfs and bcachefs: `build-installer-initrd.sh` comments out both detection blocks in `SeTpartitions`, with the reason (Pat's way), and drops both from `MOD_FS`, keeping the old line (Stuart's way). F2FS goes back to stock's module; JFS is off (`migrate-kernel-config.sh`, `DISABLE`), so no JFS disk can be mounted here |
| After re-pinning the base, GRUB on the installed Mac fails its memory allocations and boots nothing | GRUB 2.16 confines arm64 EFI allocations below 4 GB (upstream `1cae8613`, after 2.14), and Apple Silicon has no RAM there. This base ships grub 2.14 | before re-pinning, check the new base's grub. From 2.16, carry Asahi's revert (`0005-arm64-revert-4gb-memory-limit.patch`, `AsahiLinux/PKGBUILDs` `52775e86`), or wait until Slackware ARM carries it. An installed system meets it only when `update-grub` writes an upgraded grub to the ESP |
| **Reinstalling is impossible: setup reports "NO EFI SYSTEM PARTITION DETECTED" on a machine that has one** | **Upstream Slackware bug.** `SeTEFI:114` relabels the ESP to `SLKefi` during install. On any later run `sbin/probe` filters reserved labels (`grep -Eq "^SLK(…\|efi\|…)$"`) and **removes the device from its output**; `setup:72` greps that output for "EFI System Partition", finds nothing, and declares there is none. The first install makes the ESP invisible to the installer permanently | patched in `build-installer-initrd.sh`. ⚠ Never reformat the ESP to work around it — it holds `m1n1/boot.bin` |


### Graphics and display drivers

| Symptom | Cause | Handled in |
|---|---|---|
| A rebuilt Mesa silently **deletes `glxinfo` and `glxgears`** | Slackware's `mesa` package *contains* the mesa-demos binaries; they are not a separate package. `upgradepkg` removes paths the old package had and the new one does not, so a rebuild that only builds Mesa takes the demo tools out with it — including the very tools used to check whether the rebuild worked | `mesa-asahi.SlackBuild` builds mesa-demos too and applies Slackware's own `MESA_DEMO_BINS` list. It also asserts that this port's package is a **superset** of stock's, with an explicit exception list, so the general form of this mistake fails the build rather than the system. That covers every path and every symlink: makepkg moves symlinks into `install/doinst.sh`, so a file list never shows them, which is how glvnd's fallback `libGLX_system.so.0` was once lost |
| A rebuilt Mesa lacks the DirectX-Headers development files stock's carries, on some build hosts and not others | Meson prefers a `DirectX-Headers.pc` already installed on the build host over its wrap, and a host running stock's mesa has one. Stock's scripts delete it before configuring | `mesa-asahi.SlackBuild` runs stock's line verbatim, and its superset check requires the files |
| Stock ARM's Mesa flags look applied and are not | Its script writes `CFLAGS=… \ mkdir meson-build`, which binds the flags to `mkdir` alone, so its libraries import no `_chk` symbols. Pat's x86 script exports them before `meson setup` | `mesa-asahi.SlackBuild` exports them, as x86 does, and its comment says so; do not copy the ARM line's shape |
| An external display stays dark after a hot-plug — on **every other** plug, not at random | On a freshly established DPTX session the DCP firmware can publish an **empty** `TimingElements` array: the driver logs `TimingElements without valid modes!` and `nr_modes:0`, and emits no `iomfb_parse_mode_*` events, because the parser is handed nothing. A plug that succeeds tears the session down on unplug, so the next one is fresh and fails; a plug that fails tears nothing down, so the next reuses the retained table and works. A cold boot inherits m1n1's session and is unaffected. It is not a link fault: the link comes up well inside its 2 s timeout | `patches/0002-drm-apple-republish-timings-…`: on a connect yielding `nr_modes == 0`, release the DPTX session and reconnect, forcing the firmware to republish — what a physical replug does. The sequence existed in the driver as dead code behind the never-defined `DCP_DPTX_DISCONNECT_ON_INIT`. Bounded to 3 attempts, re-reading the HPD GPIO between each |
| Suspend aborts with `-22`, then succeeds on a later attempt | `dcp_crtc_atomic_check()` rejects a commit needing no modeset while the connector reads disconnected, which is what suspend submits once DCP holds `valid_mode=1` with the port already torn down. Upstream code, untouched by this port's patches | nothing. It retries and sleeps |
| A link-config timeout in `dcp_dptx_connect()` would be logged as success | `int ret = …; ret = wait_for_completion_timeout(…); if (ret < 0)`. `wait_for_completion_timeout()` returns **`unsigned long`** and returns **0 on timeout**, so `ret < 0` can never be true | not the cause of anything above. Worth an upstream report; the correct test is `ret == 0` |

### Firmware and radio

| Symptom | Cause | Handled in |
|---|---|---|
| Wi-Fi scans return **nothing at all**, silently | Firmware reports bss_info struct **v116**; `brcmfmac` hard-rejects anything outside **109–112** → `brcmf_inform_bss: BSS info version 116 unsupported`. Affects **any** Asahi user whose macOS is recent enough | `patches/0001-wifi-brcmfmac-…-bss_info-versions-above-112.patch`. Safe because the struct is append-only — *"the offsets of the subsequent fields … haven't changed"*, [LKML](https://lkml.iu.edu/hypermail/linux/kernel/2311.0/05603.html). An upstream gap, not this port's rebase |
| `asahi-fwextract` dies with `ValueError: not enough values to unpack` | Apple added `*_gen.clmb` files (`java_gen`, `sakhalin_gen`, `sumatra_gen`); the `_gen` token contains no `-`, so `wifi.py:61`'s `k, v = i.split("-", 1)` raises. **0.7.9 cannot extract current macOS firmware at all** | this port's tool skips `*_gen*` before extracting. Fixed upstream in v0.9.0; 0.7.9 needs ours |
| ★ **A machine that harvested live firmware still runs the Asahi installer's Wi-Fi firmware** | `wifi.py` builds each file's identity from `dirpath.lstrip(source_path)`. **`str.lstrip` strips a character SET, not a prefix**, so it eats into the first directory name whenever the source path contains that letter: `C-4388__s-C0` becomes `-4388__s-C0`, the parser reads an empty key and dies on `assert not props`. Extraction runs under `mktemp -d`, so whether it happens is decided by the random temp name, and the installer then falls back to the Asahi installer's factory copy | `asahi-fwextract` `patches/0002` uses `os.path.relpath`; the SlackBuild asserts the fix reached the *packaged* `wifi.py`, not just the build tree. Fixed upstream in v0.8.0; 0.7.9 needs ours. ⚠ Never date a machine's firmware from a blob picked by glob: a vendor tree holds every Mac's firmware, and some chips' blobs carry no build date at all, so a sampler that falls through reports another chip's vintage, not this machine's |
| `python3 -m asahi_firmware.bluetooth` fails as soon as it is asked to package what it reads | its `__main__` does `from . import FWPackage`, but `FWPackage` lives in `core.py` | this port's tool drives the library directly rather than either module's `__main__`. Worth reporting upstream |
| BT firmware descriptors silently skipped | 0.7.9 cannot parse newer forms, and warns `Unable to determine vendor` (Broadcom descriptors naming `AMKOR`) or `Unexpected firmware file` (MediaTek `MT7932` parts) | not handled. The vendor warnings are descriptors naming the module vendor `AMKOR`, which 0.7.9's vendor table lacks; upstream added it in v0.9.1. `MT7932B0` is not a Broadcom part, and upstream's parser still warns on it at v0.9.2 |

### Audio

| Symptom | Cause | Handled in |
|---|---|---|
| PulseAudio wins even though this port's autostart entry is phase 1 and starts first | **Ordering cannot fix this.** KDE does not wait for a phase-1 entry, so both run concurrently; this port's launcher correctly waits for PipeWire's socket before starting `pipewire-pulse`, and that wait is the window | `Hidden=true` in `pulseaudio.desktop`, from `doinst.sh`. Not a race to be won |
| `autospawn = no` in `/etc/pulse/client.conf.d/` does not stop `pulseaudio.desktop` | **The drop-in is honoured, but the wrong thing was expected of it.** `/usr/bin/start-pulseaudio-x11` greps `/etc/pulse/client.conf` **literally** and never reads `client.conf.d`, so it still sees `autospawn = yes` and proceeds | two separate paths, two separate fixes. The drop-in closes the **client-library** path; `Hidden=true` closes the **autostart** path |
| **A full-series install leaves the `Hidden=true` switch missing**, so both sound servers start | `doinst.sh` runs at *package* install time and **`asahi-audio` sorts before `pulseaudio` in `l/`**, so there is no `pulseaudio.desktop` to edit yet, and pulseaudio's own install then lays down the stock one. Invisible when packages are installed by hand onto a complete system. (A later `pulseaudio` upgrade is not a risk: its `config()` keeps an edited file and leaves the new one as `.new`.) | `rc.asahi-audio`, started at boot from `/etc/rc.d/rc.platform.d/aarch64/asahi-audio`, re-asserts the switch **every boot**. Idempotent |

### Reproducing the kernel source

`tools/rebase-asahi-onto-slackware.sh` replays the Asahi delta onto Slackware's
kernel-source. Each blames the wrong thing.

| Symptom | Cause | Handled in |
|---|---|---|
| A fetch dies with `fatal: git upload-pack: aborting due to possible repository corruption on the remote side` | The clone was made with `--filter=blob:none`. A **partial clone cannot serve blobs it never downloaded**, and the rebase runs in a second repository that asks it for them. The message blames the remote; the remote is a directory on the same disk | never `--filter` a clone that will be fetched from. The script refuses a partial clone rather than using one |
| `git fetch --refetch` after unsetting the filter still leaves objects missing | It is **not a repair**: the clone grows substantially and `rev-list --objects` still reports `missing blob object`. Meanwhile `git log`, `rev-parse` and the tags all work, so the clone looks healthy | discard a partial clone and take a fresh one. The script does this rather than attempting repair |
| `error: cannot update ref 'refs/heads/X': trying to write non-commit object` | The refspec `<tag>:refs/heads/X` where the tag is **annotated** — it names a `tag` object, not a commit. The objects transfer correctly first, so the error arrives *after* the expensive part and reads as a fetch failure | fetch tags as tags (`refs/tags/X:refs/tags/X`), then peel with `git branch <name> "<tag>^{commit}"`. `^{commit}` is not valid inside a refspec |
| A clone passes every quick check and fails much later | Missing objects surface only when something asks for content | walk the object graph of the range you need *before* the long part: `git rev-list --objects <base>..<tag> >/dev/null`. It covers exactly what the rebase will touch |

⚠ **Commit SHAs will not match a previous run**, and that is not a defect: a
commit hash includes its timestamp and committer, so an identical replay yields
different SHAs. **Compare trees, not commits** — file lists and content hashes.


## Version pins

> `slackware-k` holds one file vendored from Slackware ARM and builds nothing.
> `kernel_armv8-mac` emits two `.txz`, the kernel and its headers.

### The base is a pin

Everything below pins *this port's* packages. The **Slackware base underneath
them** is pinned too, and `build-installer-iso.sh` refuses any other:

| | |
|---|---|
| Base | `slackwareaarch64-current`, the **curated all-in-one installer snapshot** |
| Snapshot | **`Sat May 30 08:08:08 UTC 2026`** (its `ChangeLog.txt` head) |
| Ships | Plasma 5.27.12, glibc 2.42, rust 1.95.0, kernel-source 6.18.33 |
| Source | `https://slackware.uk/slackwarearm/platform/aarch64/bootware/installer-aio/slackwareaarch64-current/efi_generic.iso` |
| sha256 | `8a58bece68e69ea4a4ca64ebcd01ef61c35849fcc8fcea669df9daa987fea188` |

Upstream replaces that file in place, at Stuart's discretion, and keeps no
archive. A copy of the pinned snapshot is attached to this port's release,
alongside upstream's own `efi_generic.iso.asc` so it can be verified against
Slackware's key, for when upstream has moved on.

⚠ **There is no stable AArch64 Slackware.** `slackwarearm-15.0` is **32-bit ARM
only** — its own announcement says so, and its packages are `-arm-` with glibc
2.33. AArch64 exists *solely* as `-current`, so this curated snapshot is the
most stable foundation available, not a casual choice.

**It is a snapshot, not a subscription.** The all-in-one image is rebuilt far
less often than the package tree, and that is a feature here: it is a blessed,
internally consistent point. Only the packages this hardware needs are
slipstreamed. Pivot the base when AArch64 stable exists — or when a newer
curated image appears *and there is an actual reason*, not on a hypothetical.

**Boot chain and hardware enablement**

| Package | This port's version | Upstream tag / ref |
|---|---|---|
| `hwm-bw-mac` | 2026.08.06 | **two upstreams in one package** — `AsahiLinux/m1n1` `v1.5.2` (+ artwork `80d14f8b`) and `AsahiLinux/u-boot` `asahi-v2026.04-2`. The version is a date, since one package carries two upstreams, so it shows neither component's version: keep both pins here, in the SlackBuild header and in `slack-desc`, or provenance is lost. |
| `lzfse` | 1.0 | `lzfse/lzfse` `lzfse-1.0` |
| `asahi-scripts` | 20260127.1 | `asahi-alarm/asahi-scripts` `20260127.1` |
| `asahi-fwextract` | 0.7.9 | `asahi-alarm/asahi-alarm-installer` `v0.7.9` |
| `speakersafetyd` | 2.0.1 | `AsahiLinux/speakersafetyd` `2.0.1` |
| `tiny-dfr` | 0.3.7 | crates.io `tiny-dfr` `0.3.7`, ported from `AsahiLinux/PKGBUILDs` `cfe631b8` with its `81.patch` |
| `alsa-ucm-conf-asahi` | 8 | `AsahiLinux/alsa-ucm-conf-asahi` `v8` |

**LV2 foundation** — drobilla's RDF/LV2 stack. None of this is shipped by
Slackware; all of it is ours.

| Package | This port's version | Upstream |
|---|---|---|
| `zix` | 0.8.2 | drobilla — needed by `sord`; easy to miss, it is not an obvious dependency |
| `serd` | 0.32.4 | drobilla |
| `sord` | 0.16.18 | drobilla |
| `lv2` | 1.18.10 | the LV2 SDK (headers + Turtle) |
| `sratom` | 0.6.18 | drobilla |
| `lilv` | 0.24.26 | the host library; provides `lv2ls` / `lv2info` |

**Audio DSP**

| Package | This port's version | Upstream | Note |
|---|---|---|---|
| `pipewire-lv2` | 1.6.6 | freedesktop | **`PRGNAM=pipewire`** — deliberately replaces Slackware's package. See the warning below. |
| `lsp-plugins-lv2` | 1.2.24 | `lsp-plugins/lsp-plugins` | built `FEATURES=lv2` only |
| `bankstown` | 1.1.0 | `chadmed/bankstown` | |
| `triforce-lv2` | 0.3.2 | `chadmed/triforce` | tarball is `triforce`, crate is `triforce-lv2` |
| `asahi-audio` | 4.0 | `AsahiLinux/asahi-audio` | `noarch`; config + FIR data only |

> **`pipewire` must track Slackware's version exactly.** It is not an Asahi
> package, and the version is Slackware's to set — it is Slackware's own
> PipeWire plus one meson option (`-Dlv2=enabled`), with only `BUILD` bumped.
> If Slackware ships a new PipeWire and this port does not rebuild to match, an
> upgrade replaces this port's LV2-enabled build with the stock one and audio
> DSP silently stops working. "Slackware's own" means the pinned base's
> package: the SlackBuild reads it off the base mounted in BUILD.md step 2,
> refuses a version mismatch, and compares the two packages file by file, both
> ways. The one deliberate difference is that Pat's `pipewire-enable.sh` and
> `pipewire-disable.sh`, and the autostart samples they rename, are left out:
> asahi-audio turns PipeWire on itself, and on this system those scripts would
> start a second WirePlumber or be undone at the next boot.

All pins live in one place per artifact: the `VERSION`/`*_VER` variables at the
top of each SlackBuild, and the checksummed manifest in
[`tools/fetch-sources.sh`](../tools/fetch-sources.sh). Update both together: a
mismatch means `fetch-sources.sh` fetches a tarball the SlackBuild then fails to
find.

The kernel's two Asahi pins move together too: `ASAHI_TAG` in
`rebase-asahi-onto-slackware.sh` and in `kernel_armv8-mac.SlackBuild`, and the
parity-spec row in `fetch-sources.sh` (the `AsahiLinux/PKGBUILDs` commit that
packaged that same tag). The SlackBuild refuses a spec and a source that name
different releases.

## Resync procedure

1. Pull the upstream PKGBUILD for the package and read its `pkgver`, source
   URL/tag, and `sha256sums`.
2. Bump the version variable in the SlackBuild and the matching manifest row in
   `fetch-sources.sh`, pasting upstream's sha256. If upstream publishes only
   b2/sha512, compute the sha256 yourself, as for `tiny-dfr`; `lzfse` instead
   keeps upstream's sha512, which `fetch-sources.sh` checks separately.
3. `tools/fetch-sources.sh <pkg>` — this both downloads and verifies.
4. Re-diff upstream's `build()`/`package()` against the SlackBuild and carry any
   real changes. Ignore Arch-isms (see below).
5. Rebuild on the build host and run the package's verification (see
   [`BUILD.md`](BUILD.md) → Gates).

## Init system

**Slackware is SysV init; every upstream Asahi package targets systemd.** The
mismatch recurs in every port, so it is automated rather than
remembered.

The dangerous property is that it fails **silently**. A systemd unit installed on
Slackware is an inert text file: the package installs cleanly, every file lands
where it should, `installpkg` reports success — and the daemon never runs. There
is no error to notice. For `speakersafetyd` that failure leaves the speakers at
the reduced volume Asahi's kernel driver holds them to, and nothing says why.

### Mandatory step

Run this before writing any SlackBuild, and again on the finished package:

```sh
tools/check-init-deps.sh --source  /tmp/mac/<unpacked-source>   # advisory: what to adapt
tools/check-init-deps.sh --package /tmp/<pkg>.txz               # gate: must exit 0
tools/check-init-deps.sh --package-dir /tmp                     # sweep everything built
```

Source mode lists what needs adapting. Package mode is a **gate** — it exits
non-zero if Arch/Fedora init glue leaked into one of this port's packages.

### The translation table

| Upstream (systemd distro) | Slackware equivalent |
|---|---|
| `foo.service` unit | `/etc/rc.d/rc.foo` with `start\|stop\|restart\|status`, executable bit = enabled |
| udev rule with `TAG+="systemd"`, `SYSTEMD_WANTS` | **Inert.** The rule matches and then nothing happens. Needs an rc script; keep any non-systemd lines (e.g. `ENV{...}` tagging) since those still work under eudev |
| `DynamicUser=` / `User=` / `sysusers.d` | No equivalent. Create the account in `doinst.sh`, or run as root **as a deliberate, documented choice** |
| `AmbientCapabilities=` | No equivalent. Run privileged or set file capabilities explicitly |
| `Restart=on-failure` | No equivalent in plain SysV. Either accept it, or supervise |
| `tmpfiles.d` | Create directories in `doinst.sh` or at the top of the rc script |
| `dracut/`, `initcpio/` | Slackware uses `mkinitrd` |
| `libalpm/` hooks | pacman-only; use `doinst.sh` |
| `make install` with `UNITDIR=` | Point it at a throwaway directory and delete, or use a narrower install target |

### Enabling a service the Slackware way

Slackware does not auto-enable services. `rc.M` runs a fixed set, then Slackware
ARM's hardware-model hook `/etc/rc.d/rc.platform`, which sources every file in
`/etc/rc.d/rc.platform.d/aarch64/`, then `/etc/rc.d/rc.local`; the **executable
bit is the enable switch**. So shipping `rc.foo` is not enough — it must be
*enabled*.

This port departs from "the admin opts in" only where the hardware does not work
without the service. `speakersafetyd` is that case: the package ships
`rc.speakersafetyd.new` already executable, and its `doinst.sh` installs it with
stock Slackware's `preserve_perms()`, as `openssh` does `rc.sshd`, printing
nothing, as stock `doinst.sh` scripts do. A fresh install is therefore enabled,
and an upgrade keeps whatever mode the admin left, so a `chmod -x` survives it.
The package also ships `/etc/rc.d/rc.platform.d/aarch64/speakersafetyd` to start
it at boot. `rc.speakersafetyd` starts the daemon only where upstream's own udev
rule asks for it. eudev records the rule's `SYSTEMD_WANTS` on the speaker-sense
PCM, though nothing acts on it, and the script reads that record. So a Mac whose
kernel drives no speakers, or a model upstream has not validated, is left alone;
its `status` exits 3, which `verify-install-mac` reports as N/A.
[`INSTALLING.md`](INSTALLING.md) tells the user to confirm protection with
`rc.speakersafetyd status` before playing audio. `asahi-audio` and `tiny-dfr`
ship and start their rc scripts the same way; `rc.tiny-dfr` does nothing on a
machine without a Touch Bar.

Where an rc script appends a daemon's output to its own file under
`/var/log`, as `rc.speakersafetyd` and `rc.tiny-dfr` do, the package also
ships a `/etc/logrotate.d` entry for it, `.new` and installed by `config()`,
as stock's `wpa_supplicant` does. It uses `copytruncate`, because the daemon
never reopens the file.

**Never touch `rc.local`.** It belongs to the admin, and `sysvinit-scripts` ships
it as `.new`: a package that creates it first leaves the stock copy behind as
`rc.local.new`, and accepting that in `slackpkg new-config` drops every hook.
Precedent: Slackware's own `sc8280xp` helper starts `pd-mapper` from
`rc.platform.d`, and stock `qemu-guest-agent` keeps its `rc.local` lines
commented out.

Precedent in this repo: `asahi-scripts` deliberately uses upstream's base `make
install` target and **not** `install-arch`, because the latter drops systemd
units, dracut modules, mkinitcpio hooks and pacman hooks onto the system.

## Deliberate divergences from upstream

These are intentional and should be re-applied on every resync, not "fixed":

- **Vendor firmware: Wi-Fi and Bluetooth live, everything else pinned.** The
  Asahi installer builds the whole vendor set (Wi-Fi, Bluetooth, multitouch,
  webcam ISP, kernelcache firmware) from the IPSW of the macOS version it pins
  for its stub -- 13.5 on the M2 Mac mini -- never from the macOS the machine
  runs. `vendorfw-install-mac` keeps that set and replaces only `brcm/` (Wi-Fi
  and Bluetooth) with a live capture from `macos-fw-harvest.sh`, when one
  extracts and verifies cleanly: that is where a newer macOS was shown to matter
  (the enterprise-AP wedge), and where this tree carries the matching driver fix
  (`bss_info` v116). Multitouch, webcam and kernelcache firmware stay at
  upstream's pinned version; revisit one only with the hardware and a reason.
  `verify-install-mac` fails if any non-`brcm/` file the ESP manifest lists is
  missing from `/lib/firmware/updates`.

- **Suspend is allowed; idle suspend is not.** Slackware ARM's installer
  disables suspend on every ARM machine (`helper.scr/010-pwrmgmt`), and its own
  comment planned to restrict that to specific hardware models. This hardware
  suspends to idle, so `kernel_armv8-mac` ships
  `/etc/elogind/sleep.conf.d/20-mac.conf` with `AllowSuspend=yes`, which elogind
  reads after `sleep.conf`. Hibernation stays off. The hardware exposes no wake
  source but the SMC, so an idle machine would look powered off: the Plasma
  profile the same package ships at `/etc/xdg/powermanagementprofilesrc` drops
  idle suspend. Screen blanking, lid action and sleep on demand are left alone.

- **hwm-bw-mac (m1n1 + U-Boot) / kernel:** no distro `CFLAGS` are injected.
  These are freestanding firmware / kernel with their own flag sets; distro
  CFLAGS break them. (Ordinary C packages like `lzfse` do take `SLKCFLAGS`.)

- **U-Boot patch series** (`source/hwm-bw-mac/patches/series`): applied
  verbatim, in order, at `--fuzz=0`, including the patches for
  Rockchip/RPi/Jetson/Allwinner. Those are inert on `apple_m1_defconfig` but
  for one hunk: `ARM-RPi5-Enable-PCIe.patch` passes every DMA address in
  `drivers/nvme/nvme.c` through `dev_phys_to_bus()`, which is the identity on
  Apple's NVMe node (it has no `dma-ranges`); Asahi's own U-Boot carries the
  same series. They are kept because applying the exact upstream set is what
  upstream tests, and dropping entries risks context conflicts in the patches
  that follow. Do not prune without rebuilding and diffing `u-boot-nodtb.bin`.
  The SlackBuild refuses to continue unless every entry in the series applied.

- **U-Boot DTB filter:** this port ships only Apple Silicon Mac device trees
  (exclude t7000/t7001/t8010/t8011/t8012/t8015 = iPhones/iPads/T2 Intel Macs),
  matching upstream's `package()`.

- **asahi-scripts:** this port uses only the base `make install` target, NOT
  `install-arch`. Upstream's `install-arch`/`install-fedora` drop systemd units,
  dracut modules, mkinitcpio hooks and pacman (libalpm) hooks — none of which
  Slackware uses. This port adds `/etc/default/update-m1n1` (shipped `.new`)
  pointing `DTBS` at the newest installed kernel's device trees, as upstream's
  Arch package does. **Not** at the trees `hwm-bw-mac` ships: those are U-Boot's
  mainline set, which lacks the display controller, the sound card and the M2
  laptops' keyboard, so a stage 2 built from them boots without all three.

  The package exists for **`update-m1n1`**; `asahi-diagnose` and
  `asahi-fwupdate` come along as passengers of that base target rather than as
  separate choices.

- **asahi-scripts `patches/0001`:** teaches `asahi-diagnose` about Slackware.
  Its `package_versions()` tests only `/etc/arch-release` and
  `/etc/fedora-release`, and otherwise prints *"Distribution not supported"* and
  returns — so the section a support request usually wants comes back empty,
  while every other section (device, firmware versions, boot config) is
  distribution-agnostic and already correct.

  **This is an upstream gap, not a porting workaround**; the patch should be
  dropped when upstream takes it.

  Two details if it is ever rewritten. Slackware has no query
  command that accepts package *names*, so the function's `cmd`/`pkgs` shape has
  nothing to bind to — a small `slackware_pkgs()` helper stands in for one, and
  the existing `$($cmd $pkgs …)` call is left untouched, since an unquoted
  expansion invokes a function just as it would a binary. And the match must
  anchor the three trailing hyphen-separated fields of
  `name-version-arch-build`: only the *name* may contain hyphens, so a bare
  `^name-` prefix reports **`kernel_armv8-mac-headers` as a match for
  `kernel_armv8-mac`**. `asahi-diagnose` is `#!/bin/sh`, so the helper carries no
  bashisms. The SlackBuild asserts both the branch and the helper survive into
  the *installed* file.

- **asahi-fwextract:** `patches/0001` switches `setup.py` from the removed
  `distutils.core` to `setuptools`. Python 3.12 dropped `distutils` from the
  stdlib, so upstream's import works here only through the copy setuptools
  bundles; at this pin the unpatched build does work that way, and generates
  the same console script. The patch moves the build to the supported call,
  so it does not depend on that copy. Re-check on every version bump: if
  upstream modernises their packaging (pyproject.toml), this patch may become
  unnecessary or need to change.

  `patches/0002` replaces `wifi.py`'s `dirpath.lstrip(source_path)` with
  `os.path.relpath` — see the trap table above for what that character-set
  strip does to a chip directory name. Both patches are upstream bugs, not
  porting workarounds. Upstream took `0002`'s fix in v0.8.0, so drop it when
  moving past 0.7.9; `0001` stays while upstream imports `distutils`, as
  v0.9.2 still does. The SlackBuild asserts the second one survived into the package,
  because without it the harvested firmware is intermittently, and silently,
  not used.

- **Slackware ARM's own upstream `source/k/` (on the mirror, not in this tree)
  is worth reading before writing anything initrd-related.** It carries
  Stuart Winter's initrd tooling: `sources/os-initrd-mgr` (with a `.pod`
  manpage), `scripts/repack_initrd`, `slim-kmods-initrd`, `hack-initrd`.

  ⚠ **`repack_initrd` is for the OS initrd, not the installer's.** It unpacks
  with `zcat` and repacks with `gzip -9`, as the OS initrd is gzip; the
  installer initrd is xz, which its `zcat` cannot read. Repacking that with xz
  has a trap of its own: the kernel's initramfs decoder accepts only a CRC32
  check or none, and xz defaults to CRC64. `build-installer-initrd.sh` repacks
  with `xz --check=crc32`, as stock's initrd is.

  Exactly one file is vendored from that tree — `slk-hwm-discover`, in
  `source/slackware-k/`, with Stuart Winter's notice intact. Refresh it from
  upstream rather than editing it, and re-check that it still reports the right
  Hardware Model on real hardware afterwards.

- **The kernel ships no initrd, and needs none.** Everything on the path to `/`
  is built in, including `NVME_APPLE=y`, `APPLE_RTKIT=y`, `APPLE_MAILBOX=y`,
  `EFI_PARTITION=y`, and every root filesystem setup offers (`EXT4_FS=y`,
  which also serves ext3 and, through `EXT4_USE_FOR_EXT2=y`, ext2; `XFS_FS`
  and `BTRFS_FS` `=y`; setup does not offer JFS or F2FS, see Traps).
  `build-installer-initrd.sh` checks the installer's own list against the
  config. (`BLK_DEV_NVME` is the *generic* PCIe NVMe driver, irrelevant on
  Apple SoCs whatever its setting.) The console is likewise built in
  (`DRM_SIMPLEDRM`, `FRAMEBUFFER_CONSOLE`), so the first boot is visible
  without any userspace, and so are the laptops' internal keyboards
  (`APPLE_DOCKCHANNEL`, `HID_DOCKCHANNEL`, `SPI_HID_APPLE_*`). A USB keyboard
  needs its host controller's modules, which udev loads; `rc.S` starts udev
  before the root fsck, so it can answer that prompt. If a future config change
  makes anything on the path to `/` a module, an initrd becomes mandatory and
  the GRUB entry must gain an `initrd` line.

## Kernel Rust

**There is no rustc pin.** The kernel tree carries no `rust-toolchain.toml`; it
enforces a **minimum** rustc (1.78.0 for 6.18, via
`scripts/min-tool-version.sh`) with **no maximum**, which Slackware's system
rustc satisfies comfortably. Any 1.93.1 figure you find elsewhere is a
downstream packaging choice, not a kernel requirement.

Proven by compiling rather than reading: `drivers/gpu/drm/asahi/asahi.o` builds
clean with Slackware's rustc and `make rustavailable` reports "Rust is
available!". **The shipped kernel has `CONFIG_RUST=y` and the GPU driver,
`CONFIG_DRM_ASAHI`, enabled.**

### The one Slackware-specific adaptation

The kernel resolves the Rust standard-library source from the rustc sysroot as
`<sysroot>/lib/rustlib/src/rust/library`. Slackware's sysroot is `/usr` but it
installs rust-src under **`lib64`**, so the stock check fails with *"Source code
for the 'core' standard library could not be found"*. This is a **path mismatch,
not a missing component**. `kernel_armv8-mac.SlackBuild` exports the kernel's
own override:

```sh
make ARCH=arm64 RUST_LIB_SRC=/usr/lib64/rustlib/src/rust/library ...
```

No symlink, no repackaging, no rustup.

### What to actually check on a kernel bump

1. `scripts/min-tool-version.sh rustc` (and `bindgen`, `llvm`) against what
   Slackware ships. Only a *minimum* can bite.
2. Whether upstream has since introduced a `rust-toolchain.toml` — if they do,
   this section needs revisiting rather than assuming.
3. That `RUST_LIB_SRC` still points at a real directory; Slackware could move it.
4. That both carried patches still apply — the SlackBuild uses
   `patch -p1 --fuzz=0`, so a moved context line is a hard stop rather than a
   hunk landing somewhere unintended. That strictness is deliberate.

### Carried kernel patches

In `source/kernel_armv8-mac/patches/`, applied in order by the SlackBuild
at `--fuzz=0`. Each is documented in the trap tables above; this is the index.

| patch | what it does | why it is needed |
|---|---|---|
| `0001-wifi-brcmfmac-accept-bss_info-versions-above-112` | Raises `BRCMF_BSS_INFO_MAX_VERSION` 112 → 116 | **Wi-Fi does not work at all without it** on any machine whose macOS is recent enough to ship v116 firmware. The struct is append-only, so the offsets of existing fields are unchanged |
| `0002-drm-apple-republish-timings-when-dcp-returns-an-empty-table` | Re-requests the timing table when a fresh DPTX session returns an empty one | **An external display can stay dark after a hot-plug without it.** Wires up a release/connect sequence the driver already contained as dead code behind the never-defined `DCP_DPTX_DISCONNECT_ON_INIT` |

⚠ **Both are functional and upstreamable.** If either is dropped, say which and
why — each is the difference between working hardware and hardware that
appears broken.

## LV2 and audio conventions

- **LV2 bundles must land in `/usr/lib64/lv2`** on Slackware AArch64. A plugin
  installed elsewhere is simply never found, with no error anywhere — the host
  just reports fewer plugins. **Always pass `LIBDIR` explicitly** rather than
  relying on an upstream default, even when that default is currently correct
  (`bankstown` defaults to `/usr/lib64` and `triforce` to `$(PREFIX)/lib64`
  today; neither is a promise).

- **Verify discovery, not installation.** That files landed on disk proves
  nothing. The real test is that an LV2 *host* can see and load them:

  ```sh
  lv2ls | grep <uri>                 # discoverable?
  lv2info <uri>                      # does it actually instantiate?
  ```

  "Installed but undiscoverable" is the likely failure mode and it is silent.

- **PipeWire 1.6.x does not link LV2 into `filter-chain`.** It builds a separate,
  dynamically loaded SPA backend:

  ```
  /usr/lib64/spa-0.2/filter-graph/libspa-filter-graph-plugin-lv2.so
  ```

  ⚠ Checking `libpipewire-module-filter-chain.so` for a lilv link gives a
  **false negative**. Check the real artifact above.

- **`-Dlv2=enabled`, never `auto`.** PipeWire's meson default is `auto`, which
  resolves to *disabled* when lilv is absent and says so only in a summary line
  nobody reads. That is precisely how Slackware ended up with an LV2-less
  PipeWire. `enabled` fails the build loudly instead.

- **Rust plugins have no toolchain pin**, so they build against the system rustc
  — the same situation as the kernel. Do not assume a crate builds offline:
  `bankstown` looks dependency-free but needs the `lv2` crate from crates.io, and
  `cargo --offline` fails on it.

### This port is PipeWire-only, and says so in files it owns

Slackware's default sound server is PulseAudio. PipeWire is opt-in, through
Pat's **`pipewire-enable.sh`**, which renames PipeWire's and WirePlumber's
autostart samples into place and switches PulseAudio off. This port cannot be
opt-in about it; the DSP that makes the speakers usable *is* WirePlumber
configuration, and `pipewire` is rebuilt with `-Dlv2=enabled` for no other
reason than to host the plugins those graphs name. Under PulseAudio none of it
loads and the desktop shows a dummy output, which looks exactly like broken
hardware.

`asahi-audio` therefore turns PipeWire on: files it owns, plus **two edits to
admin files**, because the owned files alone are not sufficient:

| File | Why |
|---|---|
| `/usr/share/asahi-audio/start-session` | Starts `pipewire`, then `pipewire-pulse` and `wireplumber`. **Order is not cosmetic** — the latter two are clients and exit if nothing is listening, so the script waits for the socket rather than sleeping a guessed interval. Idempotent **per daemon**, so re-running it also repairs a session where only one has died |
| `/etc/xdg/autostart/asahi-audio.desktop` | `X-KDE-autostart-phase=1`, matching Slackware's own sample. Sequencing only — see below |
| `/etc/pulse/client.conf.d/99-asahi-no-autospawn.conf` | `autospawn = no`, closing the **client-library** path: any libpulse client that cannot connect would otherwise start a real PulseAudio |
| `/etc/rc.d/rc.asahi-audio` (shipped `.new`) | Re-asserts the PulseAudio and kmix switches at every boot, because on a full-series install `doinst.sh` runs before `pulseaudio` is installed (see the Audio traps) |
| `/etc/xdg/kmixrc` (shipped `.new`) | `AutoStart=false`: kmix would otherwise start before any sound server and fall back to the raw ALSA controls |
| `Hidden=true` appended to `/etc/xdg/autostart/pulseaudio.desktop`, by `doinst.sh` | Closes the **autostart** path. The original is kept as `.asahi-orig` |
| `/etc/rc.d/rc.platform.d/aarch64/asahi-audio` | Runs `rc.asahi-audio` at boot, from `rc.platform` |

`removepkg` reverses neither admin edit; `rc.asahi-audio stop` reverts the
switches, and `chmod -x` on it keeps them reverted: the boot hook, the
package's upgrades and `start-session` all honour that bit.

### Two paths, and only one of them is obvious

PulseAudio can arrive two ways, and closing one does nothing about the other.

**The autostart path cannot be won by starting first.** KDE does not wait for a
phase-1 entry to finish, so this port's entry and `pulseaudio.desktop` run
concurrently — and this port's launcher correctly waits for PipeWire's socket
before starting `pipewire-pulse`, which is precisely the window PulseAudio
needs. Phase 1 buys sequencing, not exclusion.

What closes it is Slackware's own switch, the one `pipewire-enable.sh` flips.
Both `/usr/bin/start-pulseaudio-x11` and
`/etc/xdg/Xwayland-session.d/00-pulseaudio-x11` open with, verbatim:

```sh
if ! grep -q "^Hidden=true$" /etc/xdg/autostart/pulseaudio.desktop ; then
```

and the XDG autostart spec independently requires a desktop to ignore an entry
carrying it. One line, both paths.

**⚠ That file is admin config, not a package file.** Slackware ships it as
`etc/xdg/autostart/pulseaudio.desktop.new` — check
`/var/log/packages/pulseaudio-*`. The `.new` convention means the live file
belongs to the admin: the package never overwrites it, and an upgrade cannot
revert the change. The pulseaudio *package* stays stock. There is precedent on a
plain install — `xfce4-clipman-plugin-autostart.desktop` already carries
`Hidden=true`.

**The client-library path is what the drop-in closes**, and it is genuinely a
different mechanism. `start-pulseaudio-x11` greps `/etc/pulse/client.conf`
**literally** and never reads `client.conf.d`, so the drop-in is invisible to
it. The drop-in works — it just answers a different question.

### Other launcher details

- **`daemon -frB` is wrong for this**, though the Slackware sample uses it. `-f`
  is `--foreground` and never returns; harmless in a `.desktop` `Exec=` because
  the desktop forks each entry, fatal in a script that starts three things in
  order. Use **`-rB`**.
- **Idempotency must be per daemon.** A blanket "is pipewire running?" early
  exit is wrong in exactly the case that matters: PulseAudio can take the socket
  while `pipewire` itself is healthy, `pipewire-pulse` then dies on every
  attempt, however often `daemon -r` retries it, and re-running the launcher
  fixes nothing.
- **PipeWire and `speakersafetyd` coexist.** Starting and stopping the stack
  leaves speaker protection running.

Leave `wireplumber.desktop.sample` alone — enabling it as well starts a second
WirePlumber.

**A session that does not run XDG autostart starts no sound server.** Of the
sessions `xwmconfig` offers, blackbox, fluxbox, fvwm2, mwm and twm never read
`/etc/xdg/autostart`, so `asahi-audio.desktop` never runs and nothing starts
PipeWire. Start `/usr/share/asahi-audio/start-session` from the session's own
startup instead, for example in `~/.xinitrc` before its `exec` line. This is
not a regression from stock: under PulseAudio this hardware has only a dummy
output, and Slackware's own PipeWire opt-in relies on XDG autostart the same
way.

## Slackware ARM packaging conventions

Read off the installer media. Following them is why this port needs no bespoke
package series.

- **There is no per-platform series, and there should not be one.** Slackware ARM
  puts packages in the series where they *functionally* belong, and ships
  hardware-specific packages for every supported platform side by side. There is
  no `arm`, `rpi` or `applesilicon` series. A series named after a distribution
  or a platform would sit in the tree like a `debian/` would.

- **`hwm-bw-<platform>` is the established name for per-platform boot firmware.**
  The tree already carries `hwm-bw-raspberrypi` ("Boot Loader firmware and tools
  for the Raspberry Pi"), `hwm-bw-lx2160acex7` and `hwm-bw-rk3399`, all in
  `a/`. Ours is
  `hwm-bw-mac`: m1n1 and U-Boot in one package.

- **One kernel rule.** The **media** ships exactly one kernel and it is the one
  that works on the target — never a useless one. Slackware ARM ships boot
  firmware for hardware you do not own, but not kernels you cannot run. That is
  why `kernel_armv8` (a 4K-page build) is **removed** from Apple Silicon media.

  The rule bans shipping a kernel nobody can boot. A second *bootable* kernel is
  a different question, and adding one needs arguing here first — note it would
  need a tagfile entry of `OPT`, which `terse`/`full` prompting ignores, so it
  would land on every install regardless of the operator's intent.

- **Replacing the kernel package inherits its non-kernel duties.** This is the
  trap in the rule above, and it is not visible from the outside: `kernel_armv8`
  ships two tools that the rest of the OS expects *the kernel package* to
  provide. Take the package off the media and they vanish with it.

  Without them, setup's board hooks show

  > `'slk-hwm-discover' is missing from your system. This is a critical
  > component of the Kernel package.`

  The full gap, from diffing the two packages' file lists (everything outside
  `lib/modules/` and `boot/`) — four files, two tools:

  | File | This port | Why |
  |---|---|---|
  | `sbin/slk-hwm-discover` | **ships** | Reads `/proc/device-tree/model`. Called by `/etc/rc.d/rc.platform` at **every boot** and by `/usr/sbin/update-grub`. Works unmodified on Apple Silicon — U-Boot passes a device tree via EFI. |
  | `usr/sbin/os-initrd-mgr` | omitted | Manages Slackware ARM's "OS InitRD", which this port does not use: the GRUB entry carries no `initrd` line because everything on the path to `/` is built into the kernel image. |
  | `etc/os-initrd-mgr.conf.sample` | omitted | as above |
  | `usr/man/man8/os-initrd-mgr.8.gz` | omitted | as above |

  Omitting `os-initrd-mgr` is the same reasoning that keeps a 4K kernel off the
  media — do not ship what cannot work here. **Caveat:** `/sbin/mkinitrd` and
  `/usr/sbin/geninitrd` both reference it, so anyone who genuinely needs an
  initrd on this platform (LUKS root, for instance) will have to revisit the
  decision. It is a judgement, not a certainty.

  The general lesson: when you replace a distribution's package with your own,
  diff the file lists. What breaks is never the part you were thinking about.

- **Kernel modules ship `.ko.xz`, as stock's do.** Neither config sets
  `MODULE_COMPRESS`: Slackware ARM's `kernel.SlackBuild` compresses at
  packaging time, and `kernel_armv8-mac.SlackBuild` runs the same lines, so
  GNU `parallel` is a build dependency. kmod is built `+XZ`, and the
  installer's initrd, which copies this module tree, loads them as stock's
  installer loads its own.

- **Reference points for placement**, taken from the tree:

  | Series | Contains |
  |---|---|
  | `a/` | `kernel_armv8`, `kernel-firmware`, `grub`, `efibootmgr`, `mkinitrd`, `xz`, the `hwm-bw-*` family |
  | `d/` | `kernel-headers`, `u-boot-tools` |
  | `k/` | `kernel-source` only |
  | `l/` | `pipewire`, `wireplumber`, `alsa-lib` |

- **Replace, do not parallel-install.** This port's `pipewire` *is* `l/pipewire` — same
  name, same version, ours adds `-Dlv2=enabled`. Shipping both would mean
  whichever installed last won, silently. Anything that is architecturally
  required rather than additional should replace its counterpart.

- **Tagging: `ADD` / `REC` / `OPT`.** The kernel and the boot firmware are
  **`ADD`**, as stock tags `kernel_armv8` and every `hwm-bw-*`: newbie
  prompting installs `ADD` without asking, so it cannot offer to leave a
  machine with no kernel. The rest of ours are **`REC`**: default yes,
  deselectable. A user who overrides a default is assumed to know what they are
  doing; that is the Slackware bargain. What carries the weight there is the
  **description**: each of this port's `slack-desc` files says what the package
  is for, and the ones the hardware cannot do without say so plainly
  ("REQUIRED: the stock kernel is 4K-page and cannot boot a Mac"), so the
  information is in front of anyone deselecting it one package at a time. The `menu`/`expert` checklists show each package's title only, as
  they do for every stock package; there, each of ours is listed and ticked.

- **Signatures.** Series packages normally ship a `.txz.asc`. This port is not
  Slackware and cannot sign as them, so ours have none — expected, and not to be
  faked. When removing a stock package from the media, remove its `.asc` too, or
  an orphaned signature is left behind for a package that is no longer there.
  The same holds one level up: both `CHECKSUMS.md5` files are rewritten to list
  this medium's packages, so both `CHECKSUMS.md5.asc` are removed; Slackware's
  signatures over the stock lists would fail against the new ones. One
  consequence: slackpkg cannot use the medium as a mirror. It reads
  `CHECKSUMS.md5.asc` on every update and stops unless that file holds a
  signature, whatever `CHECKGPG` says. Setup's own network install reads only
  `PACKAGES.TXT` and is unaffected.

## One media, one kernel

The claim is "Slackware's own kernel runs **this installer**", so it is tested
by running *this installer* — not a bespoke path built around the new kernel.
The media carries exactly one kernel, `kernel_armv8-mac`. The builders take no
kernel-selection argument: there is nothing to select, and an option with one
value is an invitation to add a second.

**The driver-parity spec** decides which drivers this kernel must ship: vanilla
Asahi's own kernel config — `AsahiLinux/PKGBUILDs` `linux-asahi/config`, at the
commit that packaged the same Asahi release the rebase replays — fetched and
checksum-pinned by `tools/fetch-sources.sh`. Two tools read it:

| where | answers |
|---|---|
| `tools/migrate-kernel-config.sh` | **builds** the config: everything vanilla enables that this tree can provide, less the reasoned `PARITY_EXCEPT` divergences |
| `tools/check-driver-parity.sh` | **gates** the package: every symbol vanilla enables, less `PARITY_EXCEPT`, is enabled in the shipped kernel's own `/boot/config`, and every module the build produced (`modules.order`) is in the package. `build-installer-iso.sh` runs it on the kernel it stages |

⚠ **Never replace the spec with a hand-maintained list, or with another
distribution's config.** A list cannot fail loudly — a driver missing from it
looks exactly like a driver nobody wanted — and a distribution's config carries
that distribution's choices, not Asahi's.

> **Replacing `kernel_armv8` inherits its duties.** `kernel_armv8-mac` ships
> `slk-hwm-discover` *and* `grub-entry-mac`, and its SlackBuild asserts
> both are in the package before it will build one; without `slk-hwm-discover`,
> setup's board hooks show an error dialog. There is no file clash with another
> kernel package to avoid: Slackware's `removepkg` skips files that appear in
> another installed package's file list.

## Kernel config

`tools/migrate-kernel-config.sh` starts from Slackware's own config (the seed,
from `a/kernel_armv8`), resolves it against the rebased source, then applies:

| List | Meaning |
|---|---|
| derived parity | every `CONFIG_*=y\|m` in the spec. `asahi=y` over `ours=m` is corrected to `=y`; `asahi=m` over `ours=y` is left alone. Run **to a fixed point**: Kconfig writes no line for a symbol whose dependency is off, so a symbol gated by one the same pass enables only appears on the next. What never appears is printed as the parity SHORTFALL |
| `PARITY_EXCEPT` | deliberate divergences from vanilla, each with its reason in the script |
| `ADDED_ENABLE` | built in (`=y`) whatever the spec says, because no initrd is shipped: the path to `/`, every root filesystem setup offers (the initrd builder checks the installer's list), and the installer's needs (`PACKET`) |
| `ADDED_MODULE` | modules (`=m`). An entry the spec has `=y` is dropped, and the script says so |
| `DISABLE` / `SET_STR` | symbols switched off, and string symbols set (`CONFIG_LOCALVERSION`) |
| `MUST_Y` / `MUST_VAL` | boot-critical symbols asserted **after** migration. If any is dropped or flipped, the migration needs a human |

Every added symbol is asserted once everything has resolved, so a later
`--module` that demotes an earlier `=y` child is caught.

**Policy that parity brings in.** Vanilla Asahi's config makes some policy
choices stock Slackware makes the other way, and parity takes them unless
`PARITY_EXCEPT` names them; the bar for naming one is whether it changes what
the machine lets a user do. `SECURITY_YAMA` is excepted: Slackware's own
`CONFIG_LSM` lists yama, so building it in would set `ptrace_scope=1` and stop
a user attaching `strace` or `gdb` to their own processes, which stock allows.
`JFS_FS` is excepted, with its options, because it cannot run on this
hardware: it crashes this 16K-page kernel, so it is switched off (see Traps).
Accepted as Asahi has them: AppArmor and Landlock built but not in
`CONFIG_LSM`, so inactive (Landlock logs that it is disabled when a tool asks
for it); `HZ_1000`, `NO_HZ_FULL`, `PREEMPT_DYNAMIC` and `DEBUG_PREEMPT`;
`INIT_ON_ALLOC_DEFAULT_ON`; `PROC_KCORE`; `CHECKPOINT_RESTORE`.

> **A Kconfig choice must not be resolved halfway.** Page size is a *choice*.
> Clearing `ARM64_4K_PAGES`, running `olddefconfig`, then setting
> `ARM64_16K_PAGES` does not work: a choice with no member selected is not left
> empty, it is immediately re-defaulted — back to 4K. The clear and the select
> have to reach the same resolve, which is why the `DISABLE`/`SET_STR` block
> deliberately runs **no** `olddefconfig` of its own. The only symptom of
> getting this wrong is `CONFIG_PAGE_SHIFT=12` in a kernel that everything else
> says is correct.

**When something "just does not work" in the installer, suspect a missing
kernel symbol before suspecting the software.** A missing `PACKET` presents as
broken DHCP, not as a kernel gap.

## The boot chain

```
Apple iBoot → m1n1 stage 1 → m1n1 stage 2 (+ device trees) → U-Boot → GRUB → Linux
```

m1n1 stage 1 is installed once by the official Asahi installer, signed with a
machine-specific key, and is effectively immutable. Stage 2 comes from the same
installer: its **UEFI environment only** package puts m1n1, the device trees and
U-Boot on the ESP, and setup never replaces them. A fresh install therefore
boots the Asahi installer's stage 2; this port's `hwm-bw-mac` replaces it only
when someone runs `update-m1n1`, which is why that tool takes the kernel's
device trees (see asahi-scripts above). GRUB onwards is this port's.

Stage 2 lives at `<ESP>/m1n1/boot.bin` and is a plain concatenation of **four**
parts:

1. `m1n1.bin`
2. every Apple device tree blob (`*.dtb`)
3. `u-boot-nodtb.bin`, gzip-compressed
4. an m1n1 configuration text blob

This is the exact layout upstream's `update-m1n1` produces; the fourth part
comes only from an optional `/etc/m1n1.conf`, so it is usually empty. ⚠ U-Boot
is the part whose absence fails silently: a payload with no U-Boot appended
loads, and then simply stops, with nothing on screen to say why.

U-Boot then provides UEFI services and loads `<ESP>/EFI/BOOT/BOOTAA64.EFI`. From
that point this is an ordinary UEFI ARM64 machine and GRUB is stock.

**U-Boot supplies the device tree to the kernel via EFI**, which is why this
port's GRUB entry carries no `devicetree` line. It needs no `initrd` line either: everything
on the path to `/` (`NVME_APPLE` and `APPLE_RTKIT` among it, and every root
filesystem setup offers) is built into the kernel image.

The Asahi installer is not forked. It is run in **UEFI environment only** mode to
do the job only it can do: lay down signed stage 1, the macOS firmware stub, the
partitioning and a working stage 2. This port takes over at GRUB.

## The GRUB entry

`tools/grub-entry-mac` exists because `grub-mkconfig` is patched on Slackware
ARM to refuse to run there, so nothing generates an entry. Everything under
`/etc/grub.d/` is likewise inert here — only `grub-mkconfig` ever reads it, so
dropping an entry into `41_custom` would look tidy and do nothing.

1. **`root=PARTUUID=`, never `root=UUID=`.** This port ships no initrd, so the *kernel*
   resolves `root=` itself. `early_lookup_bdev()` understands `PARTUUID=` (a GPT
   partition UUID), `PARTLABEL=`, `/dev/xxx` and `major:minor`. It does **not**
   understand a filesystem `UUID=` or `LABEL=` — those need userspace in an
   initramfs. Slackware's own entry survives `root=LABEL=SLKroot` only because it
   ships an initrd.

   This is worth recognising by sight, because it does not look like a bad `root=`:

   ```
   Kernel panic … VFS: Unable to mount root fs on unknown-block(0,0)
   ```

   The disk is present and its driver bound; the kernel just cannot turn the
   string into a device number. `--verify` fails on the `UUID=`/`LABEL=` form.

   Note GRUB's own `search --fs-uuid` correctly uses the *filesystem* UUID — GRUB
   has filesystem drivers. Two different identifiers, both needed.

2. **No `initrd` line.** Everything on the path to `/` is built in.
3. **No `devicetree` line.** U-Boot supplies the DTB via EFI from `boot.bin`;
   confirmed empirically by `Found DTB: Prior firmware` in the boot log. Supplying
   one here overrides that with a guess.
4. **`/boot` lives on the root filesystem**, as stock Slackware ARM's entry
   assumes: the entry searches the root filesystem for `/boot/Image-armv8-mac`.
   With a separate `/boot` it cannot boot, so `--install` refuses and `--verify`
   warns rather than write or pass such an entry.

The entry references the `/boot/Image-armv8-mac` **symlink**, not the versioned
filename it points at, so a kernel upgrade cannot leave GRUB pointing at a file
that no longer exists — `upgradepkg` removes the old package's versioned image,
and an entry naming it would survive the upgrade while the kernel did not.
GRUB's ext2 module follows symlinks; Slackware's own entry relies on the same.

## Installer media conventions

Slackware's installer cannot run on Apple Silicon: its kernel has no Apple
watchdog driver and is a 4K-page build. This port runs the **stock installer on
this port's kernel**, adapting only what is genuinely kernel-tied, plus the
carried patches below; see `tools/build-installer-initrd.sh`.

- **The installer initrd is `xz`, with a CRC32 check.** The kernel's initramfs
  decoder rejects xz's default CRC64. It logs *"Initramfs unpacking failed:
  Input was encoded with settings that are not supported by this XZ decoder"*
  early in boot, and the boot then stops at a root-mount panic that does not
  name the initrd. Check the magic (`fd377a58`) and repack with
  `xz --check=crc32`.
  (Upstream's `source/k/scripts/repack_initrd` is for the gzip OS initrd.)
- **Swap the whole module tree, never merge.** A tree whose version does not match
  the running kernel is not an error — `modprobe` finds nothing, so the installer
  boots and is then blind to storage and network for no visible reason. The
  builder refuses unless exactly one tree is present and it is the intended one.
- **`root=/dev/ram` in Slackware's grub.cfg is vestigial.** The initrd is a cpio
  archive, so the kernel unpacks it into rootfs and runs `/init`, ignoring `root=`.
  Slackware's own kernel sets `BLK_DEV_RAM_SIZE=4096` — a 4 MB ramdisk, far too
  small for the installer's initrd, which confirms it is not used that way. No
  `CONFIG_BLK_DEV_RAM` is needed on this port's side.
- **Leave `setup` and the `SeT*` scripts alone, beyond the patches below.** The manual, per-package
  character of the installer is the thing being preserved: `usr/lib/setup/setup`
  itself is untouched, and the builder proves it against the stock initrd. The
  edits to installer internals are the ones below, all applied by
  `build-installer-initrd.sh` and all of which **fail loudly** if the anchor text
  moves — so a Slackware update produces an error rather than a silently
  unpatched installer.

### Carried patches to the installer

| What | Why | Drop it when |
|---|---|---|
| `usr/share/hwm-configure/…/template-grub.cfg` — **replaced with ours** | Upstream's loads `/boot/Image-armv8` with an initrd, neither of which this media installs. Ours carries one entry, `root=PARTUUID=`, `console=tty0`, no initrd, no devicetree | Slackware ships an Apple Silicon kernel |
| `usr/share/hwm-configure/…/000-grub-configure` — fill this port's placeholders, and one added screen | `%KERNELPATH%`/`%ROOTPARTUUID%`/`%ROOTFSTYPE%` from the just-installed target; upstream's `%ROOTDEV%` is `LABEL=SLKroot`, which this kernel cannot resolve without an initrd. The screen is the boot-loader INSTALL/SKIP choice on untested Apple Silicon, in our own words, since upstream's screen calls the machine unsupported. **Failures here exit silently**, as every failure path in upstream's own copy of this script does | as above |
| `var/log/setup/setup.vendorfw-mac` — **not a patch**: our own file, shipped by the kernel package | Slackware's extension point. `SeTconfig` runs `$T_PX/var/log/setup/setup.*` in sorted order and never inspects their exit status; Stuart ships board-specific install work the same way (`setup.11.bootloader-flash-lx2160acex7`). Runs `vendorfw-install-mac` so the first boot has `wlan0` and `hci0`. Its `#BLURB` line names it in `pkgtool`'s Setup menu, as every stock `setup.*` does; pkgtool greps for that token, so it appears on exactly one line. **The name sorts after `setup.timeconfig` on purpose**, so `--regdom=auto` has a timezone to read; the kernel SlackBuild asserts that ordering | Slackware ships Apple vendor firmware |
| **`sbin/probe` — stop filtering the `SLKefi` label** | **upstream bug.** See "Reinstalling is impossible" above | **Slackware fixes it** |
| **`usr/lib/setup/*` — teach the label match about FAT32 truncation** | **upstream gap.** The media is found by volume label, but a Rufus-written stick presents `SLKINS_AIO-` | Slackware handles the truncated form |
| **`usr/lib/setup/SeTpartitions` and `load_kernel_modules` — stop offering JFS and F2FS** | Neither can hold a root on this 16K-page kernel; see "Setup offering JFS or F2FS" above. Slackware's own way of retiring a filesystem, as for reiserfs and bcachefs: the detection block in `SeTpartitions` commented out with its reason (Pat's), and the name dropped from `MOD_FS` with the old line kept (Stuart's) | a 16K-page kernel and GRUB can both use them |

**The installer text this port writes by hand lives in `installer-text/`**,
not in the patch scripts. Two files — `grub-dialog.txt` and the GRUB template
`template-grub-mac.cfg` — each edited by hand, staged into the initrd by
`build-installer-initrd.sh` and checksummed onto the media by
`build-installer-iso.sh`. A screen left as Slackware ships it has no file
here. The medium's boot menu and the package checklists are generated by
`build-installer-iso.sh` instead (`SCREENS.md`, screens 1 and 3), and setup's
filesystem menu (screen 2) is stock's less JFS and F2FS. Keeping text
out of the builder's Python heredocs means a typo in a sentence is a typo, not
a syntax error in the patch.

`tools/installer-text.sh` holds the **one** definition of what a screen becomes:
the destination map, the `%GRUBCONF%` substitution, a guaranteed final newline,
and two guards. Both the writer and the verifier source it: with a copy of the
map each, a transformation added to only one would leave the media check
silently comparing the wrong bytes.

**`installer-text/SCREENS.md` is the placement record**: every screen in the
order it appears, its trigger site, and how it differs from vanilla. It exists
because placement is not knowable from the files, and a screen can contradict
the ones either side of it without anyone reading the three together. Read it
before moving text between screens; the aim is Slackware's own pacing, right
information at the right moment, not maximum warning.

| placeholder / markup | valid in | resolved by |
|---|---|---|
| `%GRUBCONF%` | any screen | build time, from `setup`'s own `T_PX="/mnt"`, asserted |
| `%HWM%` | `grub-dialog.txt` only | run time, `000-grub-configure`, which alone knows the model |
| `\Zb` `\Z1` `\Zn` … | `grub-dialog.txt` only | `dialog --colors` |
| `%KERNELPATH%` `%ROOTPARTUUID%` `%ROOTFSTYPE%` | `template-grub-mac.cfg` only | install time, from the target just installed |

> **Only `grub-dialog.txt` can show colour**: it alone is drawn with `dialog
> --colors`. Markup anywhere else prints literally — `\Zb\Z7%GRUBCONF% \Zn` at
> the user — so the build **fails** on it rather than letting it reach the
> console.

### The hardware classes decide words, not templates

Upstream's `case $HWM` exists to pick per-model boot settings. Ours cannot be
used for that, and deliberately is not: **this media ships exactly one kernel**
— `kernel_armv8` is removed from it entirely — so whatever machine boots it, the
only kernel it can install is ours, and only this port's template can boot that. The
template is replaced globally and every model gets the right one.

⚠ **Do not classify in order to pick the template.** A model-name allowlist such
as `"Apple Mac"*|"Apple MacBook"*|"Apple iMac"*` is both unnecessary and unsafe:
it makes a name match load-bearing for correctness, so a future Mac that failed
to match would install something that could not boot.

**What classification IS for is telling the operator the truth.** Three tiers:

| Tier | Match on `slk-hwm-discover`'s model string | Behaviour |
|---|---|---|
| tested | the README's Tested models, by exact string (`build-installer-initrd.sh`) | `hwm_grub_supported=1` — installed with **no prompt**, exactly as Slackware treats any model it supports |
| M1 / M2 | `"Apple"*"M1"*` \| `"Apple"*"M2"*` | this port's INSTALL/SKIP screen: Apple Silicon, model untested, expected to work |
| anything else | — | upstream's own unsupported-hardware dialog, **untouched** |

The allowlist objection does not apply to this shape, and the difference is
worth being precise about: **a model that fails to match now costs only
wording.** It still gets the correct template and a working entry; it is merely
asked a question it did not need to be asked, or asked it in upstream's words
rather than ours. Only the tested tier changes behaviour, and only by removing a
prompt.

The tested tier is the README's Tested models, by exact model string. Adding a
model there means adding its string to `build-installer-initrd.sh` too.

Upstream's dialog block is left byte-identical and this port's screen is a wrapper in
front of it, which sets `hwm_grub_supported=1` after a yes so upstream's does not
also fire. That way tier 3 inherits any change Slackware makes to its own
wording, and the patch needs one anchor instead of rewriting a multi-line shell
string in place.

⚠ **Known and accepted:** a tier-3 machine that chooses INSTALL still gets *this port's*
template, because the template replacement is global. Upstream's wording offers
"a generic GRUB configuration", which is then not quite true. It is accepted
because such a machine cannot boot anything this media installs anyway — the
boot loader is not that operator's first problem — and carrying a second
template would be real maintenance for an already-lost case.

The template carries the same `###MAC-BEGIN`/`###MAC-END` markers `grub-entry-mac`
manages, so `grub-entry-mac --install` replaces the installer's entry in place
rather than leaving two.
