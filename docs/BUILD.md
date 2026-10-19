# Build runbook

Installing the result: see [`INSTALLING.md`](INSTALLING.md). Bumping any
version: see [`PORTING.md`](PORTING.md).

## Build host

Any Slackware AArch64-current system, real or emulated. A full install from
this medium is one; a Mac running it can rebuild its own installer with no
other machine. Built natively on a Mac mini M2; QEMU on x86 is also viable.

Run everything as root, from the top of the tree, in one shell. Allow ~70 GB
free: the kernel rebase needs ~25 GB, the kernel build ~15 GB, the base ISO and
the finished medium ~5 GB each.

## 1. Tree and sources

```sh
git clone https://github.com/ph0racious/slackware-aarch64-mac.git
cd slackware-aarch64-mac
tools/check-tree-hygiene.sh     # CRLF, BOMs, shell syntax
tools/setup-build-host.sh       # toolchain present? reports, installs nothing
tools/fetch-sources.sh          # upstream sources + the kernel parity spec, checksum-verified
. tools/build-paths.sh          # $W_DIR $ISO_DIR $PKGDIR; set BUILDROOT first to relocate
```

## 2. The Slackware base

Everything stock on the medium comes from one pinned snapshot of Slackware
ARM's all-in-one installer image:

| | |
|---|---|
| Snapshot | `Sat May 30 08:08:08 UTC 2026` |
| URL | `https://slackware.uk/slackwarearm/platform/aarch64/bootware/installer-aio/slackwareaarch64-current/efi_generic.iso` |
| sha256 | `8a58bece68e69ea4a4ca64ebcd01ef61c35849fcc8fcea669df9daa987fea188` |

Upstream replaces that file in place, at Stuart's discretion. Once it has
moved on, take the copy attached to this port's release (`efi_generic.7z.*`,
beside upstream's own `efi_generic.iso.asc` and `.md5`). A different snapshot
is a version bump, not a substitute: `build-installer-iso.sh` refuses any base
but the pinned one.

```sh
mkdir -p "$ISO_DIR" /mnt/iso
wget -P "$ISO_DIR" <URL above>
echo "8a58bece68e69ea4a4ca64ebcd01ef61c35849fcc8fcea669df9daa987fea188  $ISO_DIR/efi_generic.iso" | sha256sum -c
mount -o loop,ro "$ISO_DIR/efi_generic.iso" /mnt/iso
T=/mnt/iso/slackware/slackwareaarch64-current
```

Keep it mounted until the medium is built.

## 3. The kernel source

Produced, not downloaded. `tools/rebase-asahi-onto-slackware.sh` replays the
Asahi driver delta onto Slackware's own `k/kernel-source` and emits
`linux-6.18.33-mac.tar.gz` (~252 MB). Needs `git`, network and ~25 GB.
Everything is pinned; the one known conflict is carried as a recorded
resolution, and the script **stops** rather than resolving an unrecorded one —
a conflict resolved differently on two runs gives two kernels that both look
right.

```sh
mkdir -p /root/kernel-rebase
cp $T/slackware/k/kernel-source-6.18.33-aarch64-1.txz /root/kernel-rebase/
( cd $T && grep -a 'k/kernel-source-6.18.33-aarch64-1.txz$' CHECKSUMS.md5 )
md5sum /root/kernel-rebase/kernel-source-6.18.33-aarch64-1.txz      # must match the line above
tools/rebase-asahi-onto-slackware.sh
cp /root/kernel-rebase/linux-6.18.33-mac.tar.gz source/kernel_armv8-mac/sources/
```

The run also regenerates `REBASE-NOTES.md` beside the tarball. It should be
identical to the tree's copy, and the tarball's sha256 identical to the one
published with the release, since the tarball is written reproducibly; a
difference in either means an input changed. Commit SHAs differ on every run
(a commit hash includes its timestamp), so compare trees, not commits.

## Build order

**Boot chain and hardware enablement:** `lzfse`, `asahi-scripts`,
`asahi-fwextract`, `alsa-ucm-conf-asahi`, `speakersafetyd`, `tiny-dfr` and
`hwm-bw-mac`, then `kernel_armv8-mac` with its headers. None of these needs
another to build. At runtime `asahi-fwextract` loads `lzfse`; `asahi-scripts`'
`asahi-fwupdate` runs `asahi-fwextract`; and its `update-m1n1` builds
`boot.bin` from `hwm-bw-mac`'s m1n1 and U-Boot and the kernel's device trees.

**GPU userspace:** `mesa-asahi`, Slackware's own Mesa with the `asahi` driver
added. It replaces `x/mesa`.

**Audio DSP.** Each arrow is a build-time dependency; `pipewire` cannot gain
LV2 support until `lilv` exists:

```
zix, serd ──► sord ──┐
                     ├──► sratom ──► lilv ──► pipewire (rebuild, -Dlv2=enabled)
serd ────────────────┤
lv2 ─────────────────┘
```

`lsp-plugins-lv2` needs none of these (it bundles its own LV2 headers), and
`bankstown` and `triforce-lv2` need only cargo and their crates. `asahi-audio`
is configuration only, but its filter graphs need the LV2-enabled `pipewire`,
`lsp-plugins-lv2`, `bankstown` and `triforce-lv2` at runtime, or they fail to
load.

## 4. Building

Standard SlackBuilds; each writes its package to `/tmp`. Each package is
installed as soon as it is built, because later ones build against earlier
ones. `upgradepkg --install-new --reinstall` does the right thing whether or
not an older copy is installed, and is required for `pipewire` and `mesa`,
which replace Slackware packages of the same name. If `/tmp` holds packages
from an earlier build, remove them first — the ISO builder refuses two builds
of one package.

⚠ **Several builds need network access of their own:** mesa (meson fetches
rusticl's Rust crates and d3d12's DirectX-Headers wrap at configure time), and
`speakersafetyd`, `tiny-dfr`, `bankstown` and `triforce-lv2` (their crates,
from crates.io).

```sh
inst() { upgradepkg --install-new --reinstall "$@"; }

for p in lzfse asahi-scripts asahi-fwextract alsa-ucm-conf-asahi speakersafetyd tiny-dfr hwm-bw-mac; do
  ( cd source/$p && ./$p.SlackBuild ) && inst /tmp/$p-[0-9]*_mac.txz
done
```

The kernel. Its seed config is Slackware's own, from `a/kernel_armv8` on the
base ISO — a package this medium drops. Its parity spec (vanilla Asahi's kernel
config) was fetched in step 1.

```sh
tar xOf $T/slackware/a/kernel_armv8-6.18.33-aarch64-1.txz \
    boot/config-armv8-6.18.33 > /root/config-armv8-6.18.33
( cd source/kernel_armv8-mac && CONFIGSRC=/root/config-armv8-6.18.33 ./kernel_armv8-mac.SlackBuild )
inst /tmp/kernel_armv8-mac-6.18.33-aarch64-1_mac.txz /tmp/kernel_armv8-mac-headers-6.18.33-aarch64-1_mac.txz
```

About 25 minutes on 8 cores.

⚠ **`kernel_armv8-mac` must be *installed* on the build host, not merely
built.** `build-installer-initrd.sh` packages its module tree from
`/lib/modules/<version>`. The kernel is never booted on the build host, so
`installpkg` under a stock Slackware kernel is sufficient.

⚠ The kernel exports `RUST_LIB_SRC=/usr/lib64/rustlib/src/rust/library` —
Slackware uses `lib64` and the kernel expects `lib`. Without it the build
decides Rust is unavailable and **silently drops the GPU driver**.

Mesa, then the audio chain, in the order above. Keep the base mounted at
`/mnt/iso` from step 2: the mesa and pipewire SlackBuilds read Slackware's own
packages from it, to compare their builds with, and refuse to run without them.

```sh
( cd source/mesa-asahi && ./mesa-asahi.SlackBuild ) && inst /tmp/mesa-[0-9]*_mac.txz

for p in zix serd sord lv2 sratom lilv; do
  ( cd source/$p && ./$p.SlackBuild ) && inst /tmp/$p-[0-9]*_mac.txz
done
( cd source/pipewire-lv2 && ./pipewire-lv2.SlackBuild ) && inst /tmp/pipewire-[0-9]*_mac.txz
for p in lsp-plugins-lv2 bankstown triforce-lv2 asahi-audio; do
  ( cd source/$p && ./$p.SlackBuild ) && inst /tmp/$p-[0-9]*_mac.txz
done
```

Stage them all for the medium, and check that none carries systemd or
Arch/Fedora init glue:

```sh
mkdir -p "$PKGDIR" && cp /tmp/*_mac.txz "$PKGDIR/"
tools/check-init-deps.sh --package-dir "$PKGDIR"
```

## 5. The media

The initrd carries the kernel's module tree and the installer screens; the ISO
carries the initrd.

```sh
mkdir -p "$W_DIR"
cp /boot/Image-armv8-mac "$W_DIR/"
tools/build-installer-initrd.sh -s /mnt/iso/boot/initrd-armv8.img   # -> $W_DIR/initrd-mac.img
tools/build-installer-iso.sh                                         # -> $ISO_DIR/slackware-aarch64-mac.iso
tools/check-desc-drift.sh                                            # descriptions on the medium = slack-descs
umount /mnt/iso
```

The ISO builder verifies the base against its pin, gates the kernel with
`check-driver-parity.sh`, checksums every installer screen and the GRUB template
in the finished initrd against this tree, and checks that the medium's package
indexes and setup checklists describe the medium, refusing to write media that
has drifted. Do not hand-assemble an ISO instead: those checks are the only
thing standing between you and media carrying a stale screen or index.

### Publishing it

The ISO is larger than GitHub's 2 GB per-asset limit, so it ships as a
multi-volume 7-Zip. **Store mode** — the media is already-compressed `.txz`, so
compressing again gains nothing. 7-Zip is not part of Slackware; use `p7zip`
from SlackBuilds.org, or split on another machine.

```sh
cd "$ISO_DIR"
7z a -mx0 -v1600m slackware-aarch64-mac.7z slackware-aarch64-mac.iso
sha256sum slackware-aarch64-mac.iso        # publish this, not the parts
7z a -mx0 -v1600m efi_generic.7z efi_generic.iso   # the pinned base, with upstream's .asc and .md5
```

One release asset per part. Reassembly is opening the `.7z.001`; the other
parts must sit beside it. Verify the SHA256 of the reassembled ISO before
writing a stick.

Attach `linux-6.18.33-mac.tar.gz` from step 3 as well, with its SHA256. With
the patches in `source/kernel_armv8-mac/patches/` and this tree's build
scripts, it is the kernel's corresponding source, which GPL-2 obliges whoever
distributes the binary to provide, and nothing else publishes it: the rebase
builds it from Slackware's `kernel-source` and Asahi's tag. Anyone
redistributing media built from this tree has to provide it too, with the
tree.

## Gates

Each exits non-zero on failure, so each can gate a build.

| Check | What it catches |
|---|---|
| `check-driver-parity.sh <pkg>` | a kernel missing drivers vanilla Asahi enables. Derives the required set from the pinned vanilla Asahi config rather than a typed list, and checks that every module the build produced is in the package. `build-installer-iso.sh` runs it on the kernel it stages, so an ungated kernel cannot reach media |
| `check-init-deps.sh --package-dir` | systemd assumptions in a SysV distribution. **This mismatch fails silently** — the package installs and the daemon never runs |
| `migrate-kernel-config.sh` | boot-critical symbols lost in the config, and parity with vanilla Asahi's config |
| `check-desc-drift.sh` | a package on the media whose description no longer matches its `slack-desc`, or that it cannot check at all |
| `check-tree-hygiene.sh` | CRLF, a UTF-8 BOM before a shebang, shell syntax errors |
| `verify-install-mac` | run on the installed system: that the whole thing is coherent end to end |

Everything else is checked by installing the media and using it.

## A note on package signatures

**This port's packages are unsigned.** Stock Slackware packages on the media
carry a `.txz.asc` GPG signature; ours carry none, and a listing of `a/` or `l/`
will show that gap.

That is deliberate. These packages are **built from this tree**, not distributed
from an archive — you produce them yourself, from sources whose checksums are
pinned in `tools/fetch-sources.sh`, so a signature would attest to nothing you
did not already do. Integrity on the media is covered by its two
`CHECKSUMS.md5` files, the top-level one and the one in `slackware/`, which the
build rewrites to list every package on the medium. Their `CHECKSUMS.md5.asc`
signatures are Slackware's, made over the stock lists, so the build removes both
rather than ship signatures that fail; the medium's indexes are unsigned, like
this port's packages. The medium is an installer, not a slackpkg mirror:
slackpkg reads `CHECKSUMS.md5.asc` on every update and refuses a mirror
without one, whatever `CHECKGPG` says.

If you redistribute media built from this tree, sign the packages with your
own key. Do not present unsigned packages as though they came from an archive
that signs its own.
