---
name: board-orchestration
description: >-
  Agent-only policy for bridging a configured project board and firstmate's existing backlog.
  Load on a session-start or heartbeat cycle when a project board is configured, before judging whether a filed card is one task, a programme, or a persistent lane, before importing, promoting, decomposing, declaring or reversing a lane, or placing a board item, before reflecting a dispatch, PR, blocker, or merge onto a board, and whenever a card's status or classification disagrees with firstmate's own records or a cycle reports a card unclassified.
user-invocable: false
metadata:
  internal: true
---

# Project board orchestration

Firstmate is the orchestrator, `data/backlog.md` remains the one execution queue and the source of truth, and the board is how that queue is shown to the captain.
Chat, not the board, is where the captain steers the work.
This skill owns the policy; [`bin/fm-board.sh`](../../../bin/fm-board.sh)'s header owns every command, flag, record, and failure mode, and [`docs/configuration.md`](../../../docs/configuration.md) owns the local `config/boards` file.

## The bridge is inert until a board is configured

A home with no `config/boards` file, or an empty one, does none of this.
It performs zero board reads and zero board writes, invokes no GitHub CLI for a board, and behaves exactly as it did before the bridge existed, the same way Relay stays inert until its own opt-in.
Do not run a board command, mention a board to the captain, or offer board behavior in such a home.

Deleting or emptying that file is the whole off switch and leaves no residue, because the bridge creates no poll, watcher check, cadence file, daemon, or background process to unwind.
Say plainly what disabling does not undo: backlog items already imported stay, issues already created stay, comments already posted stay posted, and cards already moved stay where they were moved.
Never offer to reverse those as part of turning the bridge off; that is separate work and needs the captain's word.

The bridge is also strictly per project.
Only a project with its own stanza in `config/boards` is ever mapped to a board, so work on any other project never reaches any board, and a home holding several boards resolves an event against that project's stanza alone.
Never place, comment on, or move work for a project the captain did not configure a board for.

## Scope

The bridge may read the board's issues and cards, import new actionable items into the existing backlog, promote a filed card firstmate judges to be a programme into the container lane, break a container into linked child cards, declare a filed card firstmate judges to be a standing charter a persistent lane and reverse that declaration, place work firstmate already holds onto the board, move a card as firstmate's own execution events happen, attach the working PR to the originating issue, record blockers on that issue, and report a card whose status firstmate did not write.

It may not become a second execution system.
Do not build or ask for webhook infrastructure, another daemon, another database, a second queue, continuous real-time synchronization, a separate board service, or a new orchestration layer.
Reading on the cycles firstmate already has is the whole mechanism, and it is what the captain chose knowing the latency cost.

## When the read happens

The poll runs on cycles firstmate already has, and it runs on its own rather than because this skill was remembered.

- **Session start** reconciles the board as part of the digest's own network checks and prints each actionable line as `BOARD_POLL: <line>`.
  Act on those lines; do not run `poll` again for that board in the same turn, because the read has already happened and repeating it spends the board's request budget twice.
  A board already reconciled prints nothing at all, and a home with no board configured never reads one.
  Silence is the ordinary result on a settled board, not a sign the read failed: every line is something to act on, and a card already showing what firstmate recorded produces none.
  Read an empty poll as a board that agrees, and never as nothing having happened.
- **Heartbeat wakes** are where firstmate runs `bin/fm-board.sh poll` itself, as part of the fleet review AGENTS.md section 8 already requires.

Add no wake source, no watcher check, no timer, no daemon, and no background process for it.
Never poll from a lock-refused read-only session, because that session is not authorized to mutate anything; the session start's own board reconciliation is skipped there for the same reason.

Be honest about the resulting freshness when the captain asks.
The board is as current as the last cycle, never live.
An idle fleet produces no heartbeats, so an item filed while everything is idle is picked up at the next session start rather than within minutes.
A poll that could not read the board reports an `error` line and reconciles nothing; never present that to the captain as the board being in sync.

## Intake

`poll` prints a `new` line only for a card that is a real issue, sits in the configured Todo column, and carries the configured trigger.
The label is the authoritative trigger; the optional mention and assignee triggers are additional and off unless the captain configured them.
Everything else on the board is deliberately invisible to intake, including draft cards, pull requests, and untagged issues.

### Judge the card before anything binds

A filed card is one of three things, and which one it is has to be settled before the card binds to anything.
It is one shippable task; or a programme: work too large to ship as a single task, whose children are the real work; or a persistent lane: a standing charter that produces work continuously and is never itself finished.

Settle it first because the judgement cannot be revisited afterwards.
An issue binds to exactly one task permanently and a conflicting relink is refused rather than overwritten, so a programme internalized as one task has spent its issue's one binding on work no worker can ship, recoverable only by abandoning that issue and filing a fresh one.
The adapter refuses a promotion after a binding for exactly that reason, so a refusal is the ordering being enforced rather than an obstacle to route around.
It refuses a lane declaration on the same terms, and refuses each of the three classifications over the top of either other one.

Read the issue in full, and any linked context it names, then take exactly one of three routes: "One shippable task" immediately below, "Promoting a filed card firstmate judges to be a programme" under "Programmes and their children", or "Declaring a persistent lane" under "Persistent lanes".
Never take two of them, and never start down one route and switch.
When it is genuinely unclear which one it is, ask the captain rather than binding it to find out.

### One shippable task

Import each such `new` line exactly once, in this order:

1. Confirm no backlog item already names that issue URL.
2. Create the ordinary backlog item, recording the issue URL in its note, and resolve delivery mode and yolo at intake exactly as AGENTS.md section 7 requires.
3. Immediately run `bin/fm-board.sh import <project> <issue-url> <task-id>` so the linkage is durable before the turn ends, adding the classification flag "Classifying work" requires when that board configures one.

Step 3 is also what moves the card out of the captain's inbox on a board that configures the Processed column, so it is what makes the board's own reading of "picked up" true.
It is what makes import idempotent, so it is never deferred to a later turn.
The record lives with the durable fleet records rather than the task's runtime state, so it outlives cleanup: an issue whose task shipped and was torn down months ago is still linked and can never be imported a second time.
Step 1 exists only for the narrow window where a turn died between steps 2 and 3.
Re-running `import` for an already-linked issue is a successful no-op, and an attempt to point a linked issue at a different task is refused rather than silently rebound; investigate a refusal instead of working around it.

### Board-sourced work is captain-gated

Work that arrives from a board is not authorized to run merely because it arrived.
Create the backlog item **held**, with `tasks-axi hold <id> --reason "imported from the <project> board, awaiting the captain's go" --kind captain`, report the new item to the captain, and dispatch it only on their explicit word.
Use that existing hold mechanism; do not invent a second gating concept.

The reason is worth keeping in mind so this is not later simplified away: the backlog is firstmate's own record, but a board is an outside surface, so anything with write access to that board could otherwise place work straight into an autonomous execution queue.
This gate is not weakened by `yolo`, which is authority over routine gates inside work already authorized, while this is about whether the work is authorized at all.

Be precise about what the gate covers.
It gates **dispatch** of board-sourced work.
It does not gate board reads, card creation, card movement, or any of the reflection commands, and it applies to every route by which board content becomes work, including the children of a decomposition: creating child cards unattended is exactly what the captain asked for, running them is not.
This skill says nothing about work that did not come from a board; that is each home's own business and is recorded in its own captain preferences.

## Status mapping

Ownership of a card alternates between the captain and firstmate, and that alternation is what makes every hand-off unambiguous.

| Column | Means | Who moves it next |
| --- | --- | --- |
| Todo | The captain's inbox: a card they filed that firstmate has not internalized yet. | firstmate |
| `processed` | Firstmate has internalized it into the backlog and resolved how it ships. | the captain |
| `queued` | The captain's go is given and the only thing left is for the work to become runnable, including while it waits on another task to land. | firstmate |
| In Progress | Started and not yet landed: a worker running, or a PR open awaiting merge. | firstmate |
| Done | Merged and verified. | - |

`processed` and `queued` are optional and unset by default, and each is inert until its home configures it.
A home that configured neither has only the three original columns and nothing here changes for it.

A card still sitting in Todo means firstmate has not picked it up yet, and that is deliberate rather than a gap to close.
It is honest signal about how fresh the last cycle was, and an idle fleet produces no heartbeats, so a card filed while everything is idle genuinely waits for the next session start.
Never move a card to `processed` to make the board look current.
That column is written only by internalizing the work the card names, so writing it any other way reports a state firstmate's own records do not support.

An item the captain has approved whose only remaining obstacle is a dependency is `queued`, not `processed`: the go has been given, and waiting for another task to land is exactly what that column is for.

Work that becomes blocked after it has started stays visible in the column it is already in, with the blocker recorded on its issue through `bin/fm-board.sh note <task-id> "Blocked: ..."`.
That rule is about work already under way, and it never holds an approved item out of `queued`.
A column outside these is reported by its real name and never driven; leave the card there rather than forcing it into one of the others.

### `processed` to `queued` is a chat instruction

The captain gives their go in conversation, and firstmate then moves the card with `bin/fm-board.sh mark <task-id> queued`.
When the go came before the card existed, the placement carries it instead - see `--cleared` under "Putting work firstmate already holds on the board" - so it is never a second command to remember.
The board reports that go; it never issues it.
A card that appears in `queued` on its own is a divergence to report exactly as any other is, and is never authorization to launch anything - see "Filing is intent; status is firstmate's report" below, which this does not weaken.

## Classifying work

A board may configure a second synchronized field that sorts its work into areas of its own - `classify-field` in its `config/boards` stanza.
Where it does, that field is firstmate's report exactly as the columns are, and firstmate keeps it current for the same reason: a roadmap nobody has to maintain by hand is the only kind that stays true.
Where it does not, none of this section applies and no command here takes a classification at all.

**The area is firstmate's judgement, and the adapter will not make it.**
`import`, `place`, and `child-add` refuse on a classifying board unless the call states `--area <name>` or `--unclassified`, so read the work and decide before the card exists.
Run `bin/fm-board.sh classifications <project>` to see the areas that board offers, in its own words, and pass one of them.
Never pick an area from a title substring, a label, a repository, or a file path: those are the proxies the adapter deliberately refuses to use, and firstmate adopting them by hand would be the same mistake one level up.
Read what the work actually changes, and match it against what each area means on that board.

**Classify in the pass that files the card.**
The area goes on the `import` or `place` call itself, never as a second command afterwards.
This is the same rule `--parent` and `--cleared` already follow, and for the same reason: a fact left to a follow-up command is a fact that eventually does not get sent.

**Blank is for genuine ambiguity only.**
`--unclassified` is a real answer when the work could honestly sit in more than one area, or when it is not yet clear enough to place, and it is the right answer then.
It is never the answer for "this would take a moment's thought", and never for work whose area is obvious once the issue is read.
Handle `unclassified` lines like any other actionable record, either by classifying the card or, when the ambiguity is the captain's to settle, by asking them.
The adapter header owns which active linked cards produce these records; completed and withdrawn work stays quiet.

**Update it when the work's scope moves.**
`bin/fm-board.sh classify <task-id> <area>` when an issue grows or narrows into a different area.
It is `mark` for this field in every respect, including that it degrades to a stale board the next cycle retries.

A programme is not classified; its children are the work and each carries its own area.
For automatic card placement during dispatch, pass the classification to `fm-spawn.sh` using its caller-supplied classification flags (see its header).
Without that choice on a classifying board, dispatch succeeds but reports skipped placement; place the card deliberately with its area stated in the same call.

## Programmes and their children

A `decompose <project> <parent-issue-url>` line is a container: an issue whose children are the real work, and which no worker can ship as it stands.
Deciding what it breaks down into is judgement, which is why the script never invents children and this skill owns the procedure.
Nothing here happens in a home whose board configures no big-picture columns, because no card is ever classified as a container there.

A container arrives two ways, and both end in the same procedure.
The captain files one directly in the big-picture lane, or firstmate judges a card the captain filed as ordinary work to be a programme and promotes it.

### Promoting a filed card firstmate judges to be a programme

This is firstmate's own call and it is made at intake, on the `new` line, before that card binds to anything - "Judge the card before anything binds" above owns why the ordering is not negotiable.
The script provides the mechanism and never decides what is or is not a programme.

Promote when the card cannot be implemented and validated as one piece of work: it names several independently shippable outcomes, spans surfaces that would each need their own review, or reads as a direction rather than a change.
Do not promote merely because a card is hard, long, or touches many files; a single difficult change is still one task.
Prefer importing it as one task when a competent worker could plausibly carry the whole thing on one branch.

1. Run `bin/fm-board.sh promote <project> <issue-url>`. The card moves into the big-picture lane and its container record opens; the card is never bound to a task, and the adapter refuses to bind it afterwards.
2. Break it down with the procedure below, starting at step 2 - the container issue is the one just promoted.

Tell the captain plainly that their card turned out to be a programme, what it broke into, and that the pieces are waiting on their go.
That is a judgement they may disagree with, so it is reported rather than filed silently.

### Breaking a container down

1. Read the container issue in full, and any linked context it names.
2. Break it into concrete work items that can each be independently implemented and validated - not a restatement of the container in three parts. If it genuinely cannot be broken down, or the split needs a product decision, say so to the captain rather than inventing pieces.
3. Resolve delivery mode and yolo for each piece exactly as AGENTS.md section 7 requires, at intake, on that project's standing posture.
4. For each piece, run `bin/fm-board.sh child-add <project> <parent-issue-url> <title> <body> <task-id>`, carrying the classification required by "Classifying work" above.
   One command per piece creates the issue as a native GitHub sub-issue of the container, cards it as work firstmate itself filed, and records its link.
   A `child-partial` line names the step that did not land: re-run the same command, which converges on the issue it already filed rather than creating a second one.
5. Create each backlog item, **held**, exactly as the captain gate above requires. Creating the child cards is unattended; running them is not.
6. Run `bin/fm-board.sh decomposed <project> <parent-issue-url>`. Until that lands the container keeps being offered, which is what finishes an interrupted breakdown; once it lands the container is never offered again.
7. Post the breakdown as a comment on the parent issue, so the captain has the reasoning where the work lives, then report it to them.

Use GitHub's own sub-issue relationship and nothing else: the board already surfaces `Parent issue` and `Sub-issues progress`, so invent no parallel taxonomy, label scheme, or naming convention to express it.

Container reconciliation follows the PARENT STATUS contract in [`bin/fm-board.sh`](../../../bin/fm-board.sh); a failed child read must be surfaced rather than treated as a settled card.

## Persistent lanes

Some work the captain files is neither one task nor a programme.
A persistent lane is a standing charter: it has no fixed child set, it produces temporary work as evidence appears for as long as the product exists, and it is never itself completed.
Its issue stays open indefinitely as the charter, and that is the settled end state rather than a gap.

Programme semantics are wrong for one in every direction, which is why this is a classification rather than a way of handling a container.
There is no breakdown to perform, so `decomposed` would assert one that never happened - the dishonest escape, and it is not available.
No terminal state ever arrives, so a container's derived `done` could never be reached honestly.
Left as a container, such an issue is offered for decomposition on every cycle forever with no legitimate way to settle the offer.

Nothing here happens in a home whose board configures no lane column.

### Declaring a persistent lane

This is firstmate's own call and it is made at intake, on the `new` line, before that card binds to anything - "Judge the card before anything binds" above owns why the ordering is not negotiable.
The script provides the mechanism and never decides what is or is not a lane; it reads no title, label, age, or other proxy, so a card only becomes a lane because firstmate said so once, deliberately.

Declare a lane when the card names an ongoing responsibility rather than an outcome: work that recurs for as long as the product exists, whose pieces are discovered rather than enumerated, and which no breakdown could ever exhaust.
Do not declare one merely because a programme is large, long-running, or hard to break down; a programme whose children are simply not all known yet is still a programme, and the answer there is to file the pieces that are known.
Prefer a programme whenever a competent reader could write down the full set of children, however many there are.

Run `bin/fm-board.sh lane <project> <issue-url>`.
The card moves into the lane column, the durable record opens, and the card is never bound to a task, never offered for import, and never offered for decomposition again.
The record outlives cleanup and restarts, exactly as the link and decomposition records do.

Tell the captain plainly that their card is being treated as a standing lane rather than a programme, and why.
That is a judgement they may disagree with, so it is reported rather than filed silently.

### What a lane changes, and what it does not

Nothing about a lane touches the work it generates.
Each piece is filed, dispatched, carded, classified, and completed exactly as any other task is, including the captain gate on board-sourced work.
A lane is not itself classified, for the same reason a container is not: it holds no task and ships nothing.

A lane is never a parent in the board's own sense, so `--parent` and `child-add` refuse one.
Attaching a piece of work to a lane as a GitHub sub-issue would make that work a member of a set the lane derives its status from, and a lane has no status to derive.
File its work as ordinary tasks instead.

A lane sitting open, cycle after cycle, produces no record at all - that is a settled charter, not something to reconcile.
The only thing reported about one is a card someone moved out of the lane column, which is an ordinary divergence and gets the ordinary answer: report it, change nothing, and re-run `lane` to restore the card once the captain has decided.
The adapter header's PERSISTENT LANES contract owns the repair write and retry mechanics.

### Reversing one

The captain may later decide a lane really was a programme, or one shippable task after all.
Run `bin/fm-board.sh unlane <project> <issue-url>`, which retires the record and touches nothing else, after which the ordinary routes are open again and the issue can be promoted or imported.
Reversal is always this deliberate act; no cycle ever undoes a lane on its own, and none ever declares one.

## Putting work firstmate already holds on the board

`bin/fm-board.sh place <project> <task-id> <title> [<body>]` is the inverse of `import`: it files the issue, cards it, and records the link, after which every event below works on it with no special casing.
Use it for a task that started in the backlog and belongs on that roadmap.
Work firstmate files itself never sat in the captain's inbox and is already internalized when its card appears, so `place` and `child-add` card it as internalized rather than as something the captain still has to be told about.

State everything the card should say on that one call.
A fact firstmate holds at placement and leaves to a second command is a fact it will eventually not send, which is why these are flags on `place` rather than steps in this procedure:

- **The programme it belongs to.**
  When the task exists as follow-on from a container already on the board, pass `--parent <parent-issue-url>`.
  The issue is created as a native GitHub sub-issue of that container and recorded as its child in the same operation, and the container's card then follows it exactly as it follows the children a decomposition created.
  That is GitHub's own sub-issue relationship and nothing else, as "Programmes and their children" already requires; never attach it afterwards by hand.
- **The area it belongs to.**
  On a board that configures a classification field, pass `--area <name>` or, for genuinely ambiguous work, `--unclassified`, exactly as "Classifying work" sets out.
  The call is refused without one, so this is not a flag to forget.
- **That the captain has already cleared it.**
  When their go was given before the card existed, pass `--cleared` and the card is filed in `queued` rather than `processed`.
  State it only when they actually gave it: never infer it from the absence of a hold, from the task existing, or from any other proxy, because an inferred go turns a filed card into a launch authorization the moment the inference is wrong.
  Work firstmate has not been cleared to run is placed internalized, which is what the absent flag means.

`--parent` attaches work to a programme that already exists and never creates one, so an issue not already recorded as a container is refused; judge and `promote` it first, exactly as "Judge the card before anything binds" requires.
A board with no `queued` column has nowhere to show a go, so `--cleared` files the card internalized instead; the `placed` line names the state it filed, so read it rather than assuming.

Whether a task belongs on a board is an editorial call the script never makes, and project alone does not settle it.
Firstmate's own work belongs on a captain's product roadmap when it serves that product's delivery and stays off it when it does not.
When the change lands somewhere other than the repository the card's issue is filed in, pass `--lands-in <owner/name>` so the roadmap never implies a diff is somewhere it is not.

There is deliberately no bulk placement, and never build one: existing work goes onto a board one item at a time, chosen deliberately.

## The events that move a card

`mark`, `pr`, `note`, and `ack` apply only to a task that holds a link record - one imported from a board or placed on one.
A task with no board link is never passed to any of them; they refuse it outright rather than degrading, and that refusal is a sign the wrong task id was used.

Firstmate's own execution events are what move a card, and the ones that matter most happen on their own:

- **Dispatch and merge need no command.** `bin/fm-spawn.sh` places the card if the project has a board and the task has none, then marks it in progress; `bin/fm-pr-check.sh` attaches the PR to its originating issue; `bin/fm-pr-merge.sh` closes the card after a merge that actually landed. A task with no board, and every task in a home with no board configured, is untouched by all three.
- **Cleared to launch:** `bin/fm-board.sh mark <task-id> queued` when the captain's go, given in chat, releases a held item already on the board and the board configures that column.
  Work being placed after the go is already given carries it on the placement itself instead.
- **Blocked:** `bin/fm-board.sh note <task-id> "Blocked: <what is needed>"`, alongside the ordinary captain escalation when the blocker needs the captain.
- **Its area changed or remains unclassified:** follow "Classifying work" above.
- Run `mark` by hand only to correct a card, for instance after a divergence or when work leaves the cleared set.

Prefer a better card to a better command: when a task deserves a human title on the roadmap, `place` it yourself before dispatching, and the dispatch will then only move the card it finds.

Every one of these degrades to a stale board instead of blocking delivery, and each reports plainly whether the board took the change.
A board that did not take a change is never a reason to delay a dispatch, a PR report, a merge, or cleanup, and it is not a captain escalation on its own.
`poll` retries an outstanding card move and an outstanding PR attachment on the next cycle, reporting each as `synced` or `stale`; a blocker note is deliberately not retried, so re-run it if it matters and the captain escalation still stands either way.

## Filing is intent; status is firstmate's report

This is the single most important rule here, and it has two halves that must not be collapsed into one.

**Filing work on the board is the captain's intent.**
A new labelled card is them adding work, and intake above is unchanged - including that it stays captain-gated before anything runs.

**The status columns, and the classification field where one is configured, are firstmate's own report of its records.**
Firstmate writes them outward from the backlog; a card's column never tells firstmate what to do, and neither does its area.
That covers every one of them, including the optional `processed` and `queued` columns: each is written because firstmate's own records already moved, never to make the board read better than the records support.
So a `divergence` line - a card showing a status firstmate did not write - means change nothing, dispatch nothing, stop nothing, and tell the captain in chat.
The adapter has already declined to reconcile it in either direction, and firstmate must not do by hand what the adapter deliberately refused.
Raise a given divergence once and do not repeat it every cycle while it stands unresolved; when the captain decides, `bin/fm-board.sh mark <task-id> <state>` is how the card is put right.
A `classification-divergence` line is the same situation in the classification field and gets the same answer: report it, change nothing, and put the card right with `classify` once the captain has decided which area is correct.

Treat an unexplained appearance in a configured `queued` column as security-relevant, because under this model it can only mean something outside firstmate wrote to that board.
It never launches a crew.

Two consequences follow, and both are reports rather than actions:

- A card moved backwards out of In Progress, or moved to Done while work is unfinished, is something to tell the captain plainly - what firstmate has running, and what has not landed - not a reason to stop a worker on its own. Stop work only on the captain's word, then through `bin/fm-control.sh <task-id> interrupt` and `exit` exactly as any other stop.
- A `cancelled` line, a card that left the board entirely while firstmate was still executing it, is reported the same way; once the captain decides, update the backlog and run `bin/fm-board.sh ack <task-id>` so it is not reported again.
- A `closed` line is the same withdrawal said the other way: the issue is closed and its card is still sitting on the board.
  Handle it exactly as `cancelled`, including the `ack` that stops it repeating, and tell the captain which of the two happened rather than collapsing them - under `cancelled` the card is gone, under `closed` it is still there to look at.
  It is reported only while the work is still open; a closed issue whose task already landed is the ordinary end of that task and is never reported.

Neither ever authorizes discarding unlanded work: hard rule 3 stands unchanged, so preserve the branch, report what is on it, and get an explicit captain instruction before anything is discarded.

This is a real security property of the design and the captain accepted it knowingly: write access to a configured board is enough to file work into intake, and never enough to start it.

- A `foreign` line means a card on the board being polled carries an issue that another configured board already owns.
  That is a configuration mistake, not an instruction, so the adapter names the owning project and touches neither the card nor the link.
  Tell the captain which board owns the issue and let them decide which board should carry it; never re-home it by hand.
- An `error` line means the board could not be read, or answered so implausibly that the adapter refused to act on it.
  Treat it as a board that is temporarily unavailable, let the next cycle reconcile, and never read it as work being withdrawn.
  A cycle that reported an error reconciled nothing, so never tell the captain the board is in sync on the strength of it.
- A `truncated` line means the board filled the read's card ceiling, so a card past it was never seen.
  Everything that read did report still stands, including `closed` records for visible cards, but no `cancelled` record is emitted for an unseen card, because absence cannot be told apart from the ceiling.
  Re-run `poll` for that board with a higher `--limit`, and if it stays truncated tell the captain the board has outgrown the default read.
  The ceiling belongs to that read alone: `mark`, `import`, and `promote` find a card through the issue that holds it, so a card sitting past the ceiling is still moved normally.
- A scope edit to a card's own text mid-flight follows the lifecycle rule AGENTS.md section 7 already owns: route it to follow-up work unless it completely invalidates the work being validated.
  A board edit does not create a second, competing rule for that.

## Reporting to the captain

The board, the card, and the issue are the captain's own nouns and need no translation; everything else still follows AGENTS.md section 9.
Report what the board now shows and what it changed about the work, not that a poll ran or that a record was updated.
An unchanged board is not progress and is not worth a message.

## Ownership

The home whose linkage record holds an issue is the home that updates that issue and its card.
Board configuration is local to that home and is not inherited by secondmates, so never ask a secondmate or a crewmate to update a board on firstmate's behalf.
