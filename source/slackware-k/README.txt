slackware-k
-----------

Files taken verbatim from Slackware ARM's own kernel source tree:

  https://slackware.uk/slackwarearm/slackwareaarch64-current/source/k/
    SlkOS-initrd-overlay/sbin/slk-hwm-discover

Fetched 2026-09-04. Stuart Winter's copyright notices are intact and must stay
that way -- the licence's one condition is that redistributions retain them.

  sbin/slk-hwm-discover
      Hardware Model discovery. Answers e.g. "Apple Mac mini (M2, 2023)" by
      reading /proc/device-tree/model. Installed to /sbin by
      kernel_armv8-mac; the SlackBuild asserts it reaches the package, and
      the parity gate checks again.

WHY THIS DIRECTORY EXISTS

Slackware's setup expects slk-hwm-discover: without it, setup's board hooks
show an error dialog. The file is not carried by anything else this port
builds. It is Slackware ARM's, vendored here unmodified and fetched from
upstream rather than copied from any intermediary, so that refreshing it is a
one-line operation with an auditable source.

Refresh by re-fetching from the URL above and re-running the hardware check:
the file must still report the correct Hardware Model on a real machine.
