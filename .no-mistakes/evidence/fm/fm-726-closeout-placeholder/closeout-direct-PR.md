**Closeout (required at your done report).**
Fill these three fields into the report text you already write at your `done:` report - your terminal summary, and the PR description where you write one (fields 1 and 2 only; field 3 stays out of the PR description) - with no new file or record.
For pipeline-mode work that is the implementation-complete `done:` that requests validation; restate the fields at the final `done:` only if they changed.
Do not repeat the branch, SHA, file list, or timestamps; git and the PR already own them.
A docs-only change can fill each field in one line.
1. SEMANTIC SURFACES TOUCHED: the meaningful surfaces changed beyond the file list, such as notification semantics, consent behaviour, provider transport, production environment, public presentation, schema, or deployment assumptions; write `NONE` when no such surface changed.
2. PREFLIGHT DISPOSITION: one line per applicable truth surface, classified as `VERIFIED`, `NOT_APPLICABLE`, `UNVERIFIABLE` with the reason and who or what can establish it, or `FAILED`, which blocks the work.
   Use the word unverifiable exactly as the repository's own full check does; `UNVERIFIABLE` never implies success where proof was unavailable.
3. MERGE RELATIONSHIP: report the slot `MERGE RELATIONSHIP: <LANDS_BEFORE | LANDS_AFTER | INDEPENDENT>` unfilled in your completion report only, for the supervising home, which decides the relationship and fills it provisionally until the primary grants the cross-home slot; it is required at the done report for pipeline-mode work.
   Never write the literal placeholder or a relationship value into a PR description, and never decide the relationship yourself; the supervising side writes the decided value into the PR description when it confirms it.
