# Security policy

## Reporting

Report a suspected vulnerability privately through a
[GitHub security advisory](https://github.com/adibis/icarium/security/advisories/new).
Please do not disclose it publicly until a fix is released. icarium follows
coordinated disclosure, and runs no bug bounty.

## What counts

icarium reads Yosys JSON netlists, SDC files, waiver files and RTL attributes
that may come from untrusted sources. A crash, hang, unbounded memory use or
code execution caused by such an input is a security issue. Wrong or missing
findings are correctness bugs; report those as ordinary issues.

`elaborate.sh` runs Yosys on your RTL; Yosys's own security is out of scope.

## Supported versions

Fixes land on `master` and in the next release. Only the latest release is
supported.
