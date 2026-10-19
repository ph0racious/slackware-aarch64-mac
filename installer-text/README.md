# installer-text/: the installer text this port writes by hand

These files hold the screen this port adds to the installer, plus the GRUB
configuration it writes onto the installed system.
`tools/build-installer-initrd.sh` reads them and writes them into the initrd,
so **editing a file here is the whole change** -- there is no string to find in
a shell script or a Python heredoc.

Two other changes are generated rather than written here:
`tools/build-installer-iso.sh` writes the medium's boot menu and rewrites the
package checklists (screens 1 and 3 in `SCREENS.md`). Screen 2, setup's
filesystem menu, is stock's less JFS and F2FS, patched by
`tools/build-installer-initrd.sh`.

Each file here is installed into the initrd at the path named below and used
by an existing piece of the installer; the template, filled in, becomes the
installed system's `/boot/grub/grub.cfg`.

| file | shown when | printed by | lands in the initrd as |
|---|---|---|---|
| `grub-dialog.txt` | after the package install, when setup offers to configure GRUB | `dialog --colors` | `/usr/lib/setup/apple-grub-dialog.txt` |
| `template-grub-mac.cfg` | **not a screen** — the GRUB config written onto the installed system | — | replaces Slackware's `template-grub.cfg` |

## Only edits live here

Screens left alone have no file here. Slackware's `setup` is
**unpatched** — byte-identical to what it ships, and the build asserts that —
so the two files above are the only hand-written differences. **To retire a
screen, delete its file and its patch** — that is the whole mechanism.

**`SCREENS.md` beside this file is the one to read before moving text between
them.** It gives the trigger site for each screen and — more usefully — how each
one differs from vanilla Slackware, which is not knowable from the files.

That map lives in `tools/installer-text.sh`, and both the script that writes
these into the initrd and the script that verifies the finished media read it
from there. Add a screen by adding a row.

## Writing rules

**Line endings and width.** Keep lines under about 64 characters. The build
strips CR and guarantees a final newline, so neither a Windows editor's `^M`
nor a missing newline at the end of the file can reach the console — but it
cannot re-wrap a paragraph for you.

**Blank lines separate paragraphs.** `grub-dialog.txt` is passed
`--no-collapse`, so the line breaks you write are the line breaks that appear.
Without it dialog flattens them into one paragraph, which is why upstream
Slackware's own dialogs are full of literal `\n` sequences -- not needed here.
It auto-sizes, so a longer edit cannot overflow a hardcoded box.

### `%GRUBCONF%` -- any screen

Replaced at build time with `/mnt/boot/grub/grub.cfg`, the target's GRUB config
as the operator can reach it from the installer. `/mnt` is not a guess: the
build reads `T_PX="/mnt"` out of Slackware's own `setup` and fails if it ever
changes.

### `%HWM%` -- `grub-dialog.txt` only

The detected machine, e.g. `Apple MacBook Air (13-inch, M2, 2022)`. Substituted at *run*
time by `000-grub-configure`, which is the only thing that knows the model.
Nothing substitutes it anywhere else, so the build **fails** if it appears in
another file rather than printing it at the user.

### `%KERNELPATH%` `%ROOTPARTUUID%` `%ROOTFSTYPE%` -- `template-grub-mac.cfg` only

Filled at install time from the target that was just installed. This is the file
to edit to change the **installed system's** kernel command line.

The fill replaces every occurrence, comments included, so the build **fails** if
a comment names one of these; describe them in words there.

### Colour codes -- `grub-dialog.txt` only

`\Zb` bold, `\Zr` reverse, `\Z1` red, `\Z7` white, `\Zn` reset. dialog renders
these **only when passed `--colors`**, and `grub-dialog.txt` is the only screen
that is.

> **Being a dialog is not enough.** A screen only renders `\Z` if its dialog is
> passed `--colors`; otherwise the escape codes print at the user verbatim.
> "Is it a dialog?" is the wrong question; the right one is the *printed by*
> column above. The build fails on a `\Z` in any other file rather than letting
> it reach the screen.

There is no escape for a literal backslash-Z you do not want interpreted;
avoid it.

## After editing

Rebuild the initrd, then the ISO — the initrd carries the screens and the ISO
carries the initrd, so an ISO rebuild alone ships the old text. The exact
commands are in [`docs/BUILD.md`](../docs/BUILD.md) → *The media*.

Both fail loudly if a file here is missing, empty, or uses markup its screen
cannot render, and the ISO builder additionally greps the finished initrd for
the rendered text — so a stale initrd is caught rather than shipped. Without
that you get an installer that prints `%GRUBCONF%` at the user.
