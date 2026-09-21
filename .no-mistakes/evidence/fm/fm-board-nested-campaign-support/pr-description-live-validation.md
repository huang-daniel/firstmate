### Live validation on huang-daniel/oas-board-lab (project 3)

A scratch FM_HOME and fresh issues: programme #15, campaign #16 (sub-issue of #15, promoted, tasks #22 and #23 via `child-add`), flat programme #17 (children #18 closed, #19 open), and programme #20, whose only child #21 was marked `decomposed` (no derived state) and then closed. Columns were read from each issue node's `projectItems` Status.

| Step | Programme #15 | Campaign #16 (issue) | Flat #17 | #20 (underived closed child) |
|---|---|---|---|---|
| Before first poll | Umbrella Programme | Umbrella Programme (open) | Umbrella Programme | Umbrella Programme |
| Poll 1, nothing started | Umbrella Programme | Umbrella Programme (open) | Umbrella Programme In Progress | **Umbrella Programme Done** |
| `mark fm-live-one in-progress` + poll | **Umbrella Programme In Progress** (same cycle as campaign) | Umbrella Programme In Progress (open) | In Progress | Done |
| Both tasks `done` + poll | **Umbrella Programme Done** | Umbrella Programme Done (**still OPEN**) | In Progress | Done |
| Next poll | silent | silent | silent | silent |
| Close #19 + poll | Done | Done | **Umbrella Programme Done** | Done |

A second project stanza over the same board (`labalias`) reported #15, #16, #17 and #20 as `foreign … lab` with **0** sub-issue reads.

Before this change, per the issue report, the programme stayed in Umbrella Programme until the campaign issue was closed by hand. The nested-campaign unit test fails on base 32b24f5 for the same reason.
