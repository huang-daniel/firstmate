### Live validation on huang-daniel/oas-board-lab (project 3), re-run 2026-09-21

Scratch FM_HOME (pre-existing lab containers recorded under a third project so none of them moved), fresh issues:
programme #33 → campaign #34 (sub-issue, promoted) → tasks #40, #41 (`child-add`); flat programme #35 (children #36 closed, #37 open);
programme #38 whose only child #39 was marked `decomposed` (record `done - - -`, no derived state) and then closed.
Every column below was read from the issue node's `projectItems` Status on project 3. At each stage the base script (32b24f5) polled first, then this branch (f88a81b).

| Stage | Programme #33, **before** (base 32b24f5) | Programme #33, **after** (f88a81b) | Campaign #34 (issue state) |
|---|---|---|---|
| Tasks carded, nothing started | Umbrella Programme | Umbrella Programme | Umbrella Programme (open) |
| Task #40 `in-progress` | **Umbrella Programme** (lags) | **Umbrella Programme In Progress** | Umbrella Programme In Progress (open) |
| #40 and #41 `done`, campaign left open | **Umbrella Programme** (base moved it back to todo) | **Umbrella Programme Done** | Umbrella Programme Done (**still OPEN**) |
| Next poll | – | silent | silent |

Guards on the same run (this branch): flat programme #35 went to Umbrella Programme In Progress with one of its two children closed, and to Umbrella Programme Done once #37 was closed. Programme #38 reached **Umbrella Programme Done** even though its closed child #39 has an underived record. A second stanza over the same board (`labalias`) reported #33, #34, #35 and #38 as `foreign … lab` and made **0** sub-issue reads.
