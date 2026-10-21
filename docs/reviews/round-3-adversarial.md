# v0.2.0 review — adversarial

Commit reviewed: `337614d` (tag `v0.2.0`). Reviewer: independent subagent,
read-only against the shipped binary and source. This file digests the report;
the fix dispositions are in `docs/REVIEWS.md` (R3-01…R3-12).

**Verdict:** Request changes — 2 high-severity permission bugs and 1 critical data-loss bug; fixed.

## Findings

1. **Critical — self/hardlink/symlink copyFile destroys the source** (R3-01).
2. **High — write/copy modes dropped.** `writeFile(..., {mode:0o600})` produced 0664; `copyFile` widened a 0600 source to 0664 (R3-06).
3. **High — readFile encodings ignored** (R3-02).
4. Medium — `rm -r` depth cap left partial trees (R3-05).
5. Medium — mkdir over a file succeeded (R3-04).
6. Medium — lone surrogates emitted CESU-8 (R3-08).
7. Medium — `Buffer.alloc`/`fill` string zero-fill (R3-07).
8. Medium — base64url `-`/`_` dropped (R3-08).
9. Low — `path.extname("a.")` and `os.endianness` shape (R3-10).
10. Gate coverage did not exercise any of the above (R3-11).

Positives: fuzzing ~88k codec operations produced no crash, hang or RSS growth;
`rm` does not follow symlinks; 2,000 concurrent copies fired every callback with
no fd leak.
