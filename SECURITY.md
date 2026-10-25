# Security policy

## Status

DJS is a hobby project without a security response process. There is no
embargo channel, no SLA, and no backported releases. Do not run untrusted
code with it and do not expose it to users who matter — see the "Status and
scope" section of [`README.md`](README.md).

## Reporting

Found something that looks like a memory-safety bug or a permission-model
bypass? Open a regular GitHub issue with a reproducer. If the report
includes an exploit for a real target, mark the issue as a draft until a
maintainer responds.

Please do not test exploits against systems you do not own.

## What counts as a security issue here

- Crashes or memory corruption reachable from JavaScript (QuickJS and the
  D host layer; upstream QuickJS CVEs are tracked upstream).
- Bypasses of the permission model described in
  [`docs/PERMISSIONS.md`](docs/PERMISSIONS.md) that do not require an
  existing `--allow-*` grant or `-A`.
- HTTP/TLS parser bugs reachable from the network side.

## What does not

- Anything requiring `-A`/`--allow-all` or an equivalent grant: those flags
  are the documented "no sandbox" switch.
- The permission model being a seat belt rather than a kernel sandbox —
  that is a documented limitation; OS-level isolation is the answer for
  hostile code.
- Missing `Intl`, WASM, N-API, and other unimplemented surfaces.
