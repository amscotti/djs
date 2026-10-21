# v0.2.0 review — general correctness

Commit reviewed: `337614d` (tag `v0.2.0`). Reviewer: independent subagent,
read-only against the shipped binary and source. This file digests the report;
the fix dispositions are in `docs/REVIEWS.md` (R3-01…R3-12).

**Verdict:** NOT READY — 3 blockers, 12 findings; fixed in the v0.2.0 fix round.

## Findings

1. **Blocker — copyFile self-copy truncates the source.** `fs.copyFileSync(a, a)` returned success with a 0-byte file; also reproduced through a hardlink and a symlink to the source. Fixed with an `fstat` dev/ino identity check and no `O_TRUNC` before identity is known (R3-01).
2. **Blocker — readFile encodings ignored.** `hex`, `base64`, `latin1` and `ascii` were accepted but always UTF-8-decoded, returning silently corrupted strings. Fixed by decoding the returned bytes in the prelude with `Buffer.toString` (R3-02).
3. **Blocker — arrayBuffers/external constant 0.** QuickJS `binary_object_size` only counts deserialized bytecode. Fixed with the pinned-engine accounting patch and `JS_GetArrayBufferBytes` (R3-03).
4. Recursive mkdir accepted an existing file as success (R3-04).
5. `rm -r` failed above 64 levels and left a partial tree (R3-05).
6. `Buffer.alloc` string fills and `Buffer.write`/`byteLength` argument forms diverged (R3-07).
7. ESM named exports missed documented path/os/fs members (R3-09).
8. `path` trailing separators and `extname("a.")` diverged; `os.endianness` was a value (R3-10).
9. Stale COMPAT/ROADMAP/ARCH/PLAN/BENCH text (R3-11).
10. Golden/diff suites skipped exactly the divergent cases (R3-11).

Positive: no crash, leak, or memory-safety defect was found in the new native
code; view offsets, NUL checks, ownership and frees were sound.
