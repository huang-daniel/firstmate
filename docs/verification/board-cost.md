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
`poll` still makes exactly one whole-board read per configured board per cycle, which is the one such read the design keeps.

### The whole-board read is GraphQL, and cheaper than the CLI's own

Verified 2026-09-19 against `gh version 2.96.0 (2026-07-02)`, reading a real organization-owned ProjectV2 carrying 77 items.

The CLI's `project item-list` answers a card's `content` with body, number, repository, title, type, and url, and never whether the issue is open or closed:

```
$ gh project item-list 1 --owner overheadautomationsolutions --format json --limit 2 \
    --jq '.items[0] | {keys: (keys), content_keys: (.content|keys)}'
{"content_keys":["body","number","repository","title","type","url"],"keys":["content","id","repository","status","title"]}
```

Closure is a withdrawal signal, so `BOARD_ITEMS_QUERY` asks GitHub directly instead, which returns the state beside the card - and costs less than the read it replaces.
The measurement below adds the free `rateLimit` field to that same document, which is how the cost is read back in one call rather than by differencing two probes:

```
$ gh api graphql -f query="$BOARD_ITEMS_QUERY" -f owner=overheadautomationsolutions \
    -F number=1 -F page=100 -F fields=100 -F labels=50 -F people=50 \
    --jq '{rate: .data.rateLimit, cards: (...items.nodes|length)}'
{"cards":77,"rate":{"cost":3,"limit":5000,"remaining":4577}}
```

So the one whole-board read a cycle makes went from 102 points to 3.
The rule the adapter obeys is still the shape rather than the price: a read per card stays refused however cheap one read becomes.

`items(first:)` is capped at 100 by GitHub, so a `--limit` above that is walked by `gh api graphql --paginate` inside the one invocation, exactly as `item-list --limit` paged internally.
Both page sizes return the same cards, in the same set, with no duplicate across a page boundary:

```
$ for p in 10 100; do gh api graphql --paginate -f query="$BOARD_ITEMS_QUERY" \
    -f owner=overheadautomationsolutions -F number=1 -F page=$p -F fields=100 \
    -F labels=50 -F people=50 --jq '...items.nodes[] | .id' | sort > /tmp/p$p.txt; done
$ wc -l < /tmp/p10.txt; wc -l < /tmp/p100.txt; sort /tmp/p10.txt | uniq -d; diff /tmp/p10.txt /tmp/p100.txt
77
77
```

A live read-only `poll` of that same board, through a `FM_BOARD_GH` wrapper that refused every mutation, read it once and classified all 77 cards: intake triggers fired from the `labels` column, container cards were recognized from the `status` column, the `Area` classification came through on the cards carrying one, and the state column read 43 `open` against 34 `closed`.

## The one per-card read, and why it is outside this budget

The COST section of [`bin/fm-board.sh`](../../bin/fm-board.sh) owns the container read budget, which uses REST rather than the GraphQL calls measured here.
`test_a_container_costs_one_flat_read_and_never_a_board_read` in [`tests/fm-board.test.sh`](../../tests/fm-board.test.sh) checks CLI invocation counts with a stub; it does not measure live HTTP pagination or rate-limit consumption.

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

**One id read already carries every single-select field, so a second synchronized field adds no request.**
The response quoted above is the whole of the evidence: the query asks for `fields(first: $fields)` and GitHub answers with every single-select field on the board, each with its options, for the same 1 point.
The adapter's `classify-field` support changed only which of those fields the client-side filter keeps; the query document and its variables are unchanged, so the 1-point measurement above still stands without re-measuring.
A board wanting a third synchronized field would widen the same filter, not add a read.

## What has live evidence, and what does not

Validation for this change drove a real user-owned project board, and it exercised the read path alone.
The four results, quoted from the transcript:

- a plain poll of a board whose one linked card was settled produced no output at all
- `poll --all` emitted that card's `linked` record, `linked live-verification https://github.com/huang-daniel/gamba-labs-main/issues/2 verification-card todo`
- `poll --limit 1` reported `truncated live-verification 1`
- with the local record seeded to show a write outstanding that the board already showed, a plain poll confirmed the record to in-progress/in-progress without writing

No live write was made at all.
The validation run issued zero `project item-edit` calls, zero `project item-add` calls, and zero `issue create` calls against the real board.
So every write path is stub-proven rather than live-proven, and there are four of them: reconciling many owed mutations from one snapshot, resolving a single-card event without a full-board read, per-card failure reporting with retry, and setting two single-select fields on one card in one aliased GraphQL mutation.

Each stays stub-proven for a reason, so a later reader can tell a deliberate limit from an oversight:

- driving many owed writes live would mean manufacturing a board carrying many pending writes and then spending the real request budget to watch it, and that budget is the exact resource this change exists to protect, while the configured board is a live operational surface rather than a test fixture
- per-card failure reporting and retry cannot be driven live at all without inducing write failures against GitHub on demand, which nothing here can do reliably
- the two-field write is a write by definition, so it cannot be exercised without writing to that same live operational surface; its shape is two aliased `updateProjectV2ItemFieldValue` mutations in one document, which is ordinary GraphQL rather than anything GitHub documents as special
- the complexity guard covers these against the stub, and that guard was itself proven by deliberately reintroducing eight distinct regressions and confirming each one turns the suite red, which is stronger evidence than a single unrepeatable live run

The two added on 2026-09-19, with the classification field, were each reintroduced and confirmed to fail `test_a_second_synchronized_field_costs_no_second_request`:

```
resolving the classification field's ids in their own request
  not ok - a cycle synchronizing two fields cost 8 calls where one field cost 5,
           for the same 3 changed cards

writing the classification in a second item-edit rather than the batched mutation
  not ok - a cycle synchronizing two fields cost 8 calls where one field cost 5,
           for the same 3 changed cards
```

Both regressions produce the same call count from different causes, which is why the test asserts the per-kind `graphql ids` and `graphql write` counts as well as the total: the first leaves the write count correct and the id count wrong, the second the reverse.
