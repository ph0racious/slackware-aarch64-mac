# Testing a model

A model must pass all these gates to be listed as **Tested**.<br>
Partial passes are still worth sending to aid development.

A gate only applies where upstream's feature table (below) lists that feature
as working on your model, and where your machine has the hardware; otherwise
it is `N/A`.

## Core Criteria

| # | Requirements |
|---|---|
| 1 | **The install completes unaided**, following the [Installation runbook](INSTALLING.md) only |
| 2 | **It boots with the media removed** |
| 3 | **It survives a cold boot** - full power off, power on; all tested functionality returns |
| 4 | **It sleeps and wakes** - suspend from the menu, wake with the power button or lid; `/sys/power/suspend_stats/success` increments |
| 5a | **GPU acceleration works** |
| 5b | **Audio DSP is active** - the output is listed as your model's speakers (e.g. *Mac mini speaker*), not *Raw Speaker Device* or *Dummy Output*; no need to play anything |
| 5c | **Wi-Fi works** |
| 5d | **Bluetooth works** - a device pairs and is usable |
| 5e | **Ethernet works**, where the machine has it |
| 6 | **Wi-Fi associates to an enterprise access point**, not just a simple hotspot (see note #1) |
| 7 | **`/etc/rc.d/rc.speakersafetyd status` reports speakers protected** (see note #2) |

## MacBook & iMac Specific Criteria

| # | Requirements |
|---|---|
| 8 | **The internal panel runs at its native resolution**, and backlight control works |
| 9 | **The internal microphone captures** |

## MacBook-only Specific Criteria

| # | Requirements |
|---|---|
| 10 | **Internal keyboard and trackpad work** - pointer and click at minimum |
| 11 | **Closing the lid sleeps the machine and opening it wakes** |
| 12 | **Battery reports** charge level, AC-present and charging state |

## Upstream parity

Compare against Asahi's feature tables for your machine:
[M1 series](https://asahilinux.org/docs/platform/feature-support/m1/) (T8103),
[M2 series](https://asahilinux.org/docs/platform/feature-support/m2/) (T8112).
Anything upstream supports that fails here is worth reporting, but a feature
upstream lists at kernel 7.0 or later may not be in this release.

Please don't report a failure for any component upstream marks as non-functional,
but all unexpected successes are welcome.

## Notes

#1 (Criterion 6): This checks for a failure mode seemingly inherited from upstream that on some WiFi firmware versions
doesn't just fail association but *wedges the firmware entirely*; it's the primary reason this project
harvests *live* firmware from a target machine while upstream doesn't. Enterprise = Cisco/HPE etc.

#2 (Criterion 7): Asahi specifically warns about speaker damage on some machine classes, but as the installation runbook
states, speakersafetyd's actual ability to protect anything IS NOT VERIFIED HERE. The check is just
that we have shipped the package and started the daemon - neither a tester nor the project author
makes any claim that the hardware is definitely protected from physical damage.

## What to send

```sh
verify-install-mac --tester
```

Send the whole block it prints, filling in Release Tag, in a GitHub issue.<br>
Lines marked `(auto)` are answered already: the tool checks those itself.
The others show what the tool can see beside the question, to help you answer.<br>
Answer every line, write `N/A` for hardware your machine doesn't have,
and please detail every `no` fully: *"lid switch triggers when opened
but not closed"*, is far more useful than *"sleep is broken"*.
