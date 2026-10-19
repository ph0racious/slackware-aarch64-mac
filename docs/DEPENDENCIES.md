# Dependency & toolchain survey

Each package's build and runtime dependencies, mapped to the Slackware
AArch64-current package that provides them. **Everything this port does not
build itself resolves to a stock Slackware package**; it adds no outside
dependency the distribution does not already carry.

Read each upstream's build files (Makefile / CMakeLists / Kbuild / setup.py) as
well as its declared dependency list: the declared lists can be incomplete.
`sord` needing `zix` is the case here (*Audio chain dependencies*, below).

Two Slackware-specific facts:

* **`rust-src` lands under `lib64`.** The kernel looks for the Rust stdlib
  source under `<sysroot>/lib/rustlib/...`; Slackware puts it in `lib64`. Without
  `RUST_LIB_SRC` pointing at the right place, Kconfig silently stops offering
  `CONFIG_RUST`, `DRM_ASAHI` vanishes, and the build succeeds with no GPU driver
  in it.
* **Slackware names the dwarves package `pahole`.** Only matters with
  `DEBUG_INFO_BTF`, but the package name search fails if you look for the wrong
  one.

Stock `rust` and `rust-bindgen` build the kernel's Rust GPU driver: the shipped
kernel has `CONFIG_RUST=y` and `CONFIG_DRM_ASAHI=y`. The kernel enforces a rustc
*minimum* and no maximum, so a newer Slackware rustc stays acceptable.

## Per-package matrix

Legend: ✓ present in Slackware · ⚠ present but needs an adaptation · RT runtime-only.

Versions are whatever the pinned base ships (`PORTING.md`, *The base is a
pin*); the minimums are the kernel's own.

### hwm-bw-mac  (boot chain: m1n1 stage 2 + U-Boot)

One package builds both halves of the boot chain, so their dependencies are
listed together.

| Dependency | Provides | Slackware pkg | Notes |
|---|---|---|---|
| gcc, binutils, make | native aarch64 C | gcc, binutils, make | for m1n1 and U-Boot. m1n1 is built with `ARCH=` empty, so plain `gcc` |
| bc, bison, flex | kconfig / parsers | bc, bison, flex | |
| dtc, swig, python3 | pylibfdt | dtc, swig, python3 | |
| openssl, gnutls | EFI bits | openssl, gnutls | |
| ImageMagick | boot logo | imagemagick | m1n1's one declared `makedepends` |
| the carried patch series | — | (in repo) | applied at `--fuzz=0` |

m1n1 1.5.2 needs no clang and no Rust. Its Makefile selects clang only on a
macOS host, and links its Rust code only with `CHAINLOADING=1`, which this
build does not set. Rust, and `build-std` for its bare-metal target, arrive
with m1n1 1.6.x.

### kernel_armv8-mac 6.18.33  (GPU on)

| Dependency | Provides | Slackware pkg | Notes |
|---|---|---|---|
| gcc | compiler | gcc | ✓ (≥ 8.1) |
| rust + rust-src | kernel Rust | rust (src bundled) | ✓ (≥ 1.78) |
| bindgen | C→Rust bindings | rust-bindgen | ✓ (≥ 0.65.1) |
| libclang | bindgen backend | llvm | ✓ (≥ 15.0) |
| pahole | BTF (`CONFIG_DEBUG_INFO_BTF`) | **pahole** | ✓ — Slackware names it `pahole`, not `dwarves`. The config wants v1.25 or later |
| flex, bison, bc | kbuild | ✓ | ✓ |
| elfutils (libelf) | module tooling | elfutils | ✓ |
| cpio, kmod, perl, python3, openssl | kbuild/initramfs | all present | ✓ |
| `RUST_LIB_SRC` | kernel Rust stdlib source | rust (bundled) | ⚠ Slackware puts it under `lib64`; the kernel expects `lib`. Set it explicitly or `DRM_ASAHI` silently disappears |

### lzfse 1.0  (fwextract dep)

| Dependency | Provides | Slackware pkg | Notes |
|---|---|---|---|
| cmake, gcc | build | cmake, gcc | ✓ |

### asahi-scripts 20260127.1  (update-m1n1)

| Dependency | Provides | Slackware pkg | Notes |
|---|---|---|---|
| make, POSIX sh | build/install | make, bash | ✓ — pure shell, `noarch`. |

### asahi-fwextract 0.7.9  (firmware extractor, runs on-device)

| Dependency | Provides | Slackware pkg | Notes |
|---|---|---|---|
| python3 | interpreter | python3 | ✓ |
| setuptools, build, installer, wheel | wheel build | python-setuptools, python-build, python-installer, python-wheel | ✓ |
| distutils | (removed) | — | **⚠ fixed** by patch 0001 → setuptools. |
| lzfse, python3 | runtime | this port's lzfse + python3 | RT runtime only |

### speakersafetyd 2.0.1  (speaker protection daemon)

| Dependency | Provides | Slackware pkg | Notes |
|---|---|---|---|
| rust + cargo | build | rust | ✓ — system rustc; the pin in the `rust-toolchain.toml` beside `AsahiLinux/PKGBUILDs`' PKGBUILD is a rustup mechanism and is not used. **Network** for crates.io |
| alsa-lib | ALSA control access | alsa-lib | ✓ |

### tiny-dfr 0.3.7  (Touch Bar daemon)

| Dependency | Provides | Slackware pkg | Notes |
|---|---|---|---|
| rust + cargo | build | rust | ✓ — system rustc; `AsahiLinux/PKGBUILDs`' rustc 1.93.1 pin is a rustup mechanism and is not used. **Network** for crates.io |
| cairo, pango, librsvg, gdk-pixbuf2 | drawing the keys | cairo, pango, librsvg, gdk-pixbuf2 | ✓ — librsvg must be 2.59 or later |
| libinput, eudev (libudev) | touch input, device discovery | libinput, eudev | ✓ |
| freetype, fontconfig | key labels | freetype, fontconfig | ✓ |
| uinput | key events | kernel (`CONFIG_INPUT_UINPUT=m`) | ✓ — `rc.tiny-dfr` loads it |

---

## Adaptations

Everything resolves to a Slackware package. `asahi-fwextract` carries real
source patches: upstream still imports `distutils`, removed from modern Python,
so `patches/0001` moves it to `setuptools`; and `patches/0002` fixes how
`wifi.py` computes firmware subpaths (see `PORTING.md`).

## Audio chain dependencies

**Slackware ships none of the LV2 ecosystem** — not the SDK, not lilv, not the
RDF libraries, which is why audio is the largest part of this port.

**`zix` is undeclared.** `sord` depends on it, but it appears in none of the
obvious dependency listings for the LV2 stack; the tell is `sord`'s build
failing.

| Package | Build-time needs | All from Slackware? |
|---|---|---|
| `zix`, `serd`, `sord`, `lv2`, `sratom`, `lilv` | meson, ninja, pkg-config, C compiler | yes |
| `pipewire` (rebuild) | everything Slackware's own build needs, **plus `lilv`** | yes, once lilv is installed |
| `lsp-plugins-lv2` | C++ toolchain, cairo and libsndfile (its LV2 headers are bundled) | yes |
| `bankstown`, `triforce-lv2` | system rustc + cargo; **network** for crates.io | yes (rustc), plus network |
| `asahi-audio` | `make`, `sed` — config generation only | yes |

Two adaptations, recorded in `docs/PORTING.md`:

1. **`-Dlv2=enabled` on PipeWire**, never the `auto` default — `auto` silently
   resolves to *disabled* without lilv, which is exactly how Slackware's stock
   package ended up unable to host LV2 plugins at all.
2. **`LIBDIR=/usr/lib64` passed explicitly** to every plugin package, so bundles
   land where an LV2 host will actually look.

### Graphics

| Package | Build-time needs | All from Slackware? |
|---|---|---|
| `mesa` (rebuild) | everything Slackware's own build needs: `meson`, `ninja`, **`rust` + `rust-bindgen`** (stock enables `-Dgallium-rusticl=true`), **`llvm`** and `libclc` (`-Dllvm=enabled -Dshared-llvm=enabled`). Network during `meson setup`, for rusticl's Rust crates and the DirectX-Headers wrap | yes, all stock; plus network |

**`mesa` is version-pinned to whatever Slackware ships — 26.1.1 here.** The
SlackBuild refuses to build against a version other than the pinned base's,
because Mesa is core enough that an accidental up- or downgrade takes X, GL and
everything linking `libGL`/`libEGL` with it.

⚠ **When Slackware updates Mesa, an upgrade replaces this build with the stock
one**, and hardware acceleration silently disappears — `glxinfo` goes back to
saying `llvmpipe` and nothing else announces it. A new Mesa is a version bump:
rebuild to match.

Two adaptations, both recorded in `docs/PORTING.md`:

1. **`asahi` appended to both `-Dgallium-drivers` and `-Dvulkan-drivers`.**
   Stock omits `asahi` from both.
2. **mesa-demos is built as part of the same package**, because Slackware ships
   those binaries inside `mesa` rather than separately — a rebuild that skips
   them deletes `glxinfo` and `glxgears` from the running system on upgrade.

---

## Tooling dependencies (not packages, but they gate the work)

These are needed to build the kernel and the media rather than any one
package.

Build host: any Slackware AArch64-current system, real or emulated; built
natively on a Mac mini M2; QEMU on x86 is also viable. `kernel_armv8-mac` must
be installed on it. A full Slackware install already provides almost all of the
below.

| Need | For | Note |
|---|---|---|
| `gcc` / `make` / `ld` / `bison` / `flex` / `bc` | the kernel | stock Slackware |
| `rustc`, `cargo`, `bindgen` | the kernel's Rust and the GPU driver | the kernel enforces a minimum and no maximum (`PORTING.md`, *Kernel Rust*) |
| `RUST_LIB_SRC` = `/usr/lib64/rustlib/src/rust/library` | same | Slackware uses `lib64`; the kernel's default expects `lib`, hence the explicit variable |
| `libelf.h`, `gelf.h`, `elfutils/libdw.h` | objtool | |
| `makepkg`, `depmod`, `cpio`, `xz` | packaging, and the initrd | the installer initrd is a newc cpio under **xz**, with a CRC32 check |
| GNU `parallel` | the kernel's module compression | stock Slackware; the kernel SlackBuild compresses its modules with it, as Slackware ARM's own does |
| `python3` | the initrd | the installer-script patches are applied in Python |
| `git` | the kernel rebase | stock Slackware |
| `curl` | `tools/fetch-sources.sh` | stock Slackware |
| `wget` | the base ISO (`BUILD.md`, step 2) | stock Slackware |
| `xorriso` | the media | ⚠ must be told `-boot_image any keep`, or it discards the El Torito record and produces a valid ISO that no firmware will boot |
| coreutils (`md5sum`, `sha256sum`) | the staleness and integrity guards | the media is refused if an installer screen or the GRUB template does not match the tree |
| **`/boot/config-armv8-6.18.33`** | the kernel | ⚠ **not present by default** — it is the seed config from Slackware's `a/kernel_armv8`, a package this media deliberately drops. Stage it from Slackware's stock ISO or the SlackBuild aborts before compiling: `tar xOf .../a/kernel_armv8-*.txz boot/config-armv8-6.18.33`. The one non-obvious prerequisite |

⚠ **`kernel_armv8-mac` must be *installed* on the build host, not merely built.**
`build-installer-initrd.sh` packages that kernel's module tree, and `depmod`
reads it from `/lib/modules/<version>` on disk. The kernel is never booted
there, so `installpkg` in a VM running a stock Slackware kernel is sufficient.

A full `-j8` kernel build peaks at about **1.9 GB RSS**.
