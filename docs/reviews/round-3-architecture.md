# v0.2.0 review — plan and documentation conformance

Commit reviewed: `337614d` (tag `v0.2.0`). Reviewer: independent subagent,
read-only against the shipped binary and source. This file digests the report;
the fix dispositions are in `docs/REVIEWS.md` (R3-01…R3-12).

**Verdict:** NOT READY — documentation contradicted the implementation in several places; corrected.

## Findings

1. **Blocker — arrayBuffers field was non-functional** (R3-03).
2. **Blocker — ROADMAP's historical status column was rewritten** so v0.2 work appeared to exist in v0.1; the column is now labelled "Before v0.2" and the deliverables are in a v0.2.0 section (R3-11).
3. **High — PLAN was stale** (Phase 1 "fixes in progress", deferred soak/diff, Buffer TODO, env read-only wording, round-1 counts). Updated, with Phase 5/6 added for permissions and sandboxing (R3-11).
4. **High — COMPAT/ROADMAP claimed mkdir mode was ignored** while the code applies it; `fs.promises` inventory was 7 vs 11 (R3-11).
5. **High — module containment described as the entry directory** while `projectRootFor` widens to the nearest package; ARCH corrected (R3-11).
6. **High — ARCH still v0.1** in status, layout, builtin table, native signatures and gate counts; refreshed (R3-11).
7. Medium — BENCH header said v0.1.0 in the v0.2.0 tarball; generated from `djs --version` now (R3-11).
8. Medium — REVIEWS had no v0.2 round and stale hashes; this section and the round-3 files added (R3-11).
9. Medium — claimed v0.2 coverage was partial (no fs.promises new ops, no arrayBuffers growth, no write encodings); tests added (R3-11).
10. Medium — Buffer encoding/fill divergences undocumented; COMPAT updated (R3-07/R3-11).
11. Medium — diff gate records success when it skips for missing Node; it prints a distinct skip and the gate line includes the case count (R3-11).

Gate arithmetic checked out: 8 gate steps, integration 67 at review time
(70 after the fixes), sanitizer 34 (37 after), diff 7, soak green, `--version`
v0.2.0. Permission-model review findings are recorded separately in
`docs/PERMISSIONS.md` and carried into Phase 5.
