# Project board request cost verification

Audience: maintainer verification.

This record supports the COST and BATCHING sections of [`bin/fm-board.sh`](../../bin/fm-board.sh)'s header and the cost guard in [`tests/fm-board.test.sh`](../../tests/fm-board.test.sh).
It records the measured GraphQL point cost of each call shape the adapter can make, and the two API facts that decide which shape it uses.
Re-establish these when the GitHub CLI's project commands change or GitHub changes how it charges Projects reads.

Verified 2026-09-11 against `gh version 2.96.0 (2026-07-02)`, reading a real user-owned ProjectV2 with 9 items and 20 fields.
Every measurement below is read-only.

## Why the point cost is the whole design constraint

The GraphQL budget is 5,000 points an hour, and a whole-board read spends about a fiftieth of it.
Making one such read per card is what exhausted the budget and rate-limited the account at 45 cards, which is the defect the adapter is now shaped to make structurally impossible.

## Measuring method

A `rateLimit` query is itself free, so the difference between two of them is exactly what the call between them cost.
That the probe is free is verified rather than assumed:

```
$ rr(){ gh api graphql -f query='{rateLimit{remaining}}' --jq '.data.rateLimit.remaining'; }
$ x=$(rr); y=$(rr); echo $((x-y))
0
```

## Cost of each call shape

```
rateLimit probe itself        : 0 points
project item-list --limit 200 : 102 points
project view + field-list     : 104 points
targeted card lookup          : 1 points
batched project+field ids     : 1 points
```

The first two are the shapes the adapter used to reach for on every single-card event, so one `mark`, `import`, or `promote` spent those 206 points before the write itself.
The last two are what it uses now, so the same event spends 2 before the same write.
The write's own cost is not measured here, because no write was made against the real board at all.
`poll` still makes one `project item-list` per configured board per cycle, which is the one whole-board read the design keeps.

## The one per-card read, and why it is outside this budget

A container card's own state is derived from the sub-issues GitHub records under its parent issue, read with `gh api repos/OWNER/REPO/issues/NUMBER/sub_issues`.
That is REST rather than GraphQL, so it is charged against the 5,000-requests-an-hour core limit and spends none of the 5,000 GraphQL points this record's figures protect.
Its point cost is therefore not measured here; what bounds it instead is that only a card in the container lane makes it, one read per container per cycle, and that the read contains no board read.
`tests/fm-board.test.sh` pins both properties against the stub, and that guard was proven by making the adapter read one container's children twice and confirming it turns the suite red.

## The targeted lookup returns the same card the board read does

The board read and the flat lookup were run against the same issue and agree:

```
$ gh project item-list 2 --owner huang-daniel --limit 200 --format json \
    --jq '.items[] | select(.content.url == ".../gamba-labs-main/issues/5") | .id'
PVTI_lAHOBrTgPc4A_6rlzgdaq0U

$ gh api graphql -F owner=huang-daniel -F name=gamba-labs-main -F number=5 \
    -f query="$CARD_QUERY" \
    --jq '.data.repository.issue.projectItems.nodes[]
          | select(.project.number == 2 and .project.owner.login == "huang-daniel") | .id'
PVTI_lAHOBrTgPc4A_6rlzgdaq0U
```

## Two API facts the query shapes depend on

**`repositoryOwner` reaches a project through the `ProjectV2Owner` interface.**
There is no top-level `projectV2(owner:, number:)`, and `ProjectV2Owner` is not what `repositoryOwner` returns, so the id query spreads one interface fragment inside another.
That composition is valid and resolves for a user-owned project:

```
$ gh api graphql -F owner=huang-daniel -F number=2 -F fields=100 -f query="$BOARD_IDS_QUERY"
{"data":{"repositoryOwner":{"projectV2":{"id":"PVT_kwHOBrTgPc4A_6rl","fields":{"nodes":[...,
  {"id":"PVTSSF_lAHOBrTgPc4A_6rlzgy4Mc8","name":"Status","options":[
    {"id":"f75ad846","name":"Todo"},{"id":"47fc9ee4","name":"In progress"},
    {"id":"98236657","name":"Done"}]}, ...]}}}}
```

**`field(name:)` is an exact, case-sensitive match, which is why the adapter reads the field list and filters it instead.**
A `status-field` key spelled `status` has always resolved a board field named `Status`, and asking GitHub for it by name loses that:

```
$ gh api graphql -F owner=huang-daniel -F number=2 -F field=status -f query='... field(name: $field) ...'
gh: Could not resolve to a Unions::ProjectV2FieldConfiguration with the name status
```

Filtering `fields(first: 100)` in the response costs the same 1 point as naming the field, so the tolerant match is free.

## What has live evidence, and what does not

Validation for this change drove a real user-owned project board, and it exercised the read path alone.
The four results, quoted from the transcript:

- a plain poll of a board whose one linked card was settled produced no output at all
- `poll --all` emitted that card's `linked` record, `linked live-verification https://github.com/huang-daniel/gamba-labs-main/issues/2 verification-card todo`
- `poll --limit 1` reported `truncated live-verification 1`
- with the local record seeded to show a write outstanding that the board already showed, a plain poll confirmed the record to in-progress/in-progress without writing

No live write was made at all.
The validation run issued zero `project item-edit` calls, zero `project item-add` calls, and zero `issue create` calls against the real board.
So every write path is stub-proven rather than live-proven, and there are three of them: reconciling many owed mutations from one snapshot, resolving a single-card event without a full-board read, and per-card failure reporting with retry.

Each stays stub-proven for a reason, so a later reader can tell a deliberate limit from an oversight:

- driving many owed writes live would mean manufacturing a board carrying many pending writes and then spending the real request budget to watch it, and that budget is the exact resource this change exists to protect, while the configured board is a live operational surface rather than a test fixture
- per-card failure reporting and retry cannot be driven live at all without inducing write failures against GitHub on demand, which nothing here can do reliably
- the complexity guard covers these against the stub, and that guard was itself proven by deliberately reintroducing six distinct regressions and confirming each one turns the suite red, which is stronger evidence than a single unrepeatable live run
