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

The first two are the shapes the adapter used to reach for on every single-card event, so one `mark`, `import`, or `promote` cost roughly 207 points before the write itself.
The last two are what it uses now, so the same event costs 3.
`poll` still makes one `project item-list` per cycle, which is the one whole-board read the design keeps.

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
