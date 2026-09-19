#!/usr/bin/env bash
# fm-board.sh - the one thin adapter between a configured project board and
# firstmate's existing backlog.
#
# The semantic policy is owned once by
# .agents/skills/board-orchestration/SKILL.md. This script is deterministic
# mechanics only: it reads a board, owns the durable issue-to-task linkage that
# makes import idempotent, and reflects firstmate's own execution events back
# onto the board. It never creates work, never decides what to import, and never
# pushes firstmate's recorded state over a status the captain changed on the
# board. The board owns intent; this script reconciles toward it.
#
# Usage:
#   fm-board.sh boards [<project>]
#   fm-board.sh poll [<project>] [--limit <n>] [--all]
#   fm-board.sh import <project> <issue-url> <task-id>
#     [--area <name> | --unclassified]
#   fm-board.sh place <project> <task-id> <title> [<body>]
#     [--lands-in <owner/name>] [--parent <issue-url>] [--cleared]
#     [--area <name> | --unclassified]
#   fm-board.sh promote <project> <issue-url>
#   fm-board.sh child-add <project> <parent-issue-url> <title> <body> <task-id>
#     [--area <name> | --unclassified]
#   fm-board.sh decomposed <project> <parent-issue-url>
#   fm-board.sh decompositions [<project>]
#   fm-board.sh links [<project>]
#   fm-board.sh lookup <issue-url|task-id>
#   fm-board.sh mark <task-id> todo|processed|queued|in-progress|done
#   fm-board.sh classify <task-id> <area-name>
#   fm-board.sh classifications [<project>]
#   fm-board.sh pr <task-id> <pr-url>
#   fm-board.sh note <task-id> <text>
#   fm-board.sh ack <task-id>
#   fm-board.sh -h | --help
#
# `--limit` caps how many cards one board read returns and defaults to 200. It
# belongs to `poll` alone, because `poll` is the only verb that reads the board;
# a board carrying more cards than the limit needs it raised, and `poll` says so
# with a `truncated` line. `mark`, `import`, and `promote` find a card through
# the issue that holds it rather than by paging the board, so no card is out of
# their reach however large the board grows and they take no limit at all.
#
# `--all` turns off `poll`'s default silence about settled cards. See RECORDS.
#
# CONFIGURATION - config/boards, local and gitignored (docs/configuration.md
# owns the operator-facing description). Plain text, one stanza per board, each
# opened by its `project` key:
#
#   project = harbourlight
#   owner = harbour-collective
#   number = 7
#   repo = harbour-collective/app  # optional; default: every repo on the board
#   label = firstmate            # default: firstmate
#   mention = @firstmate         # optional; default: mention trigger off
#   assignee = some-login        # optional; default: assignee trigger off
#   status-field = Status        # default: Status
#   classify-field = Area        # optional; default: classification off
#   todo = Todo                  # default: Todo
#   in-progress = In Progress    # default: In Progress
#   done = Done                  # default: Done
#   queued = Queued              # optional; default: off
#   processed = Processed        # optional; default: off
#   big-picture-todo = Big Picture Processed         # optional; default: off
#   big-picture-in-progress = Big Picture In Progress  # optional; default: off
#   big-picture-done = Big Picture Done              # optional; default: off
#
# `queued` is optional and off by default. Configured, it names the column a card
# sits in once firstmate has been cleared to launch the work. Unconfigured, no
# card is ever read or written as queued and the adapter behaves exactly as it
# did before the key existed.
#
# `processed` is optional and off by default in exactly the same shape, and it
# names the column a card sits in once firstmate has internalized it. Ownership
# of a card alternates between the two parties, which is what makes each
# hand-off unambiguous: Todo is the captain's inbox and firstmate moves it,
# Processed is firstmate's answer and the captain moves it, `queued` is the
# captain's go and firstmate moves it, and In Progress and Done are firstmate's
# alone. `import` is what moves a card Todo -> Processed, so a card still
# sitting in Todo means firstmate has not picked it up yet. That is honest
# signal about how fresh the last cycle was, and it is deliberate: no command
# here ever writes a status the durable records do not already support.
# Unconfigured, `import` writes no column at all and every path below behaves
# exactly as it did before the key existed, so an existing home never grows a
# column it did not ask for.
#
# CLASSIFICATION, THE SECOND SYNCHRONIZED FIELD. `classify-field` is optional
# and off by default in the same shape as the two keys above. Configured, it
# names a second single-select field on the board - an area, a component, a
# workstream, whatever that board calls it - and this adapter then treats it
# exactly as it treats the column: it reads it on every cycle, records it, keeps
# it, writes it, and reports a value it did not write as a divergence rather
# than acting on it. Unconfigured, no card's value is ever read or written, the
# `classify` refuses, `classifications` reports `off`, and every path below makes the calls it
# made before the key existed.
#
# The field's options are the board's own vocabulary and appear nowhere in this
# repository. `classifications` prints them, read from the board, so one
# project's areas can never be another's and no code change adds a board.
#
# WHICH AREA A PIECE OF WORK BELONGS TO IS A JUDGEMENT, so this adapter never
# forms one. It sets the value a caller states and refuses to infer one from a
# title, a label, a repository, a column, or any other proxy - the same shape as
# `--cleared` below, and for the same reason: a guess would be wrong quietly and
# at scale. `import`, `place`, and `child-add` therefore require the classifying
# caller to state `--area <name>` or `--unclassified` when the board configures
# the field, so a card is classified in the call that creates it rather than by
# a second command someone has to remember.
#
# Blank stays reachable because genuine ambiguity is a real answer, but only by
# saying `--unclassified`; omitting both is refused. That is the whole
# difference between a card left blank because its classification is genuinely
# open and one left blank for convenience. And a blank card is not silent: every
# cycle names it in an `unclassified` record until one is recorded, exactly as a
# card awaiting import repeats as `new`. Work already finished or withdrawn is
# settled and is not named, so a reconciled board still polls to nothing.
#
# The two flags are not symmetric on a board that configures no such field.
# `--area` names a field that board does not have, so it is refused.
# `--unclassified` states that no classification is being given, which is simply
# true there, so it is accepted and does nothing.
# Dispatch passes the caller's classification through; if none is stated for a
# classifying board, it reports skipped placement and still launches the task.
#
# `classify` changes the value afterwards, which is what an issue whose scope has
# moved into another area needs, and is also how a divergence on this field is
# resolved - firstmate acting, exactly as an explicit `mark` resolves one on the
# column.
#
# A container is not classified. It holds no task and ships nothing; its children
# are the work, and each of them carries its own classification.
#
# The three `big-picture-*` keys name the container lane and are the whole on
# switch for decomposition, defaulting to unset. Their values are ordinary
# column names like every other key here, so a board whose ordinary lane runs
# Todo -> Processed typically names the first of them `Big Picture Processed`;
# the key spelling is the lane position, never the column's own title. They
# default to unset. With none of them set this adapter behaves exactly as it did
# before they existed: no card is ever classified as a container and `decompose`
# is never printed. Setting some but not all three is a configuration error
# rather than a half-enabled feature, and so is naming a column that a
# `todo`, `in-progress`, or `done` key already names.
#
# INERT UNTIL CONFIGURED. This is a contract, not a side effect. With no
# `config/boards` file, or an empty one, this adapter performs zero board reads
# and zero board writes, invokes no GitHub CLI at all, creates no state, and
# behaves exactly as the home did before it existed - the same shape as Relay's
# opt-in. Every board identity comes from that one local file, so nothing here
# is org-specific or repo-specific.
#
# OFF SWITCH. Deleting or emptying `config/boards` fully disables the bridge and
# leaves no residue: there is no generated poll, watcher check, cadence file,
# daemon, or background process to unwind, because none was ever created. The
# only files this adapter ever writes are data/board-links.tsv and
# data/board-decompositions.tsv, and an unconfigured home never reads either of
# them into any behavior.
#
# WHAT DISABLING DOES NOT UNDO, by design. Work already done stays done: issues
# and backlog items already imported remain, comments already posted on an issue
# remain posted, and cards already moved stay where they were moved. Disabling
# stops future board reads and writes; it is not an undo.
#
# STRICTLY PER PROJECT. Only a project with its own stanza in `config/boards` is
# ever mapped to a board. Work on any other project has no board coordinates to
# resolve, so `import` refuses to name it and no card, issue, or comment for it
# is ever touched. A home with several boards keeps them separate: an event on
# one project resolves only that project's stanza.
#
# INTAKE. `poll` reports an item as importable only when it is a real issue (not
# a draft card and not a pull request), sits in the configured Todo column, and
# carries the configured trigger. The label is the authoritative trigger; the
# optional mention and assignee triggers are additional and off unless set.
# These are intake filters alone: a card they decline is still a card on the
# board, recorded as present before any of them runs, so declining to import it
# is never mistaken for it having left.
#
# IDEMPOTENCY. data/board-links.tsv is the durable linkage record and the single
# thing consulted before an import. It lives in data/, not state/, so it
# survives task cleanup: an issue whose task was long since torn down is still
# linked and is never imported a second time. The issue URL is the identity, so
# one issue can hold at most one task, and `import` for an issue that already
# links to the same task is a successful no-op. A conflicting relink is refused
# rather than overwritten.
#
# Record columns, tab separated:
#   project  issue  task  desired  synced  pr  pr_synced  area  area_synced
# `desired` is the column state firstmate's execution events call for and
# `synced` is the last state this adapter confirmed on the board, both drawn
# from todo|processed|queued|in-progress|done|other. They differ exactly while a board write is
# outstanding, which is what makes a failed write retryable on the next cycle.
# `other` is a column the captain added that firstmate does not drive; it is
# recorded so their intent is preserved, not so a fourth execution state exists.
# `area` is the requested classification; `area_synced` is its last confirmed
# board value, or the value observed by the existing card lookup immediately
# before an explicit classification write. Saving that observed baseline lets
# poll retry a failed correction while still detecting subsequent external edits.
# Older seven-column rows read both area fields as `-`.
# No column is ever empty: `-` is the placeholder, because bash collapses empty
# tab-separated fields when it reads them back.
#
# DECOMPOSITION. A big-picture card is a container: an issue whose children are
# the real work. No worker can ship a container, so a container must never spend
# the one issue-to-task binding above, and this adapter makes that structural
# rather than conventional: every verb that would write one of the two records
# refuses first when the issue already holds the other.
#
# On the binding side, `import` refuses an issue that holds a decomposition
# record, and so does `card_ensure`, the one boundary `place` and `child-add`
# both bind through - for `child-add` that is the child it is carding, since a
# parent holding a container record is the ordinary case. `poll` never prints
# `new` for a card sitting in a big-picture column or holding a decomposition
# record, so a container is never offered for binding either.
#
# On the container side, `promote` takes no task id at all and refuses an issue
# that holds a link, `child-add` refuses a parent that holds a link, and
# `decomposed` refuses a parent that holds a link. No record can therefore be
# reached from the other's side, whichever order a caller attempts, and every
# such refusal exits 3. `poll` writes a container's record the first time it
# sees the card rather than when it is decomposed, so the refusal covers every
# container the board has ever shown, not only the ones already broken down.
#
# PROMOTION, and why its ordering is a one-way door. A container arrives two
# ways: the captain files one in the container lane, or firstmate judges a card
# the captain filed as ordinary work to be a programme rather than one shippable
# task. `promote` is that second route. Because an issue binds to exactly one
# task permanently and a conflicting relink is refused rather than overwritten,
# the container-or-task judgement has to be made before anything binds: a
# container that has already spent its issue's one binding is recoverable only
# by abandoning that issue and filing a fresh one.
#
# So the ordering is enforced by the mechanism rather than left to the caller.
# `promote` takes no task id, so there is no parameter with which it could bind
# one however it is called, and it refuses outright an issue that already holds
# a link. An already-bound issue can therefore never become a container by any
# route, present or future. Read the filed card, judge it, and only then either
# `import` it as one task or `promote` it as a programme.
#
# `promote` writes the container's durable record before it touches the board,
# so the refusals above hold from that instant even when the card move does not
# land; the move is then an ordinary outstanding write that `poll` retries. The
# card lands in the container lane's first column, exactly where a captain-filed
# container sits, and `child-add` then generates the children as it always has.
#
# `poll` prints `decompose <project> <parent-issue-url>` for a container not yet
# recorded as decomposed: a real issue in the big-picture Todo column that
# carries the configured label, or one `promote` recorded, which the record
# below keeps offering wherever its card has reached. Deciding what a container
# breaks down into is judgement, so this script never invents children:
# firstmate reads that line, runs `child-add` once per piece of work, and closes
# the container with `decomposed`. Like `new`, a `decompose` line repeats every
# cycle until that closing command runs, so an interrupted decomposition is
# finished rather than lost; once closed it is never printed again, however long
# ago it was closed.
#
# data/board-decompositions.tsv is that durable record, alongside the linkage
# record and for the same reason: it must outlive task cleanup, so a parent
# decomposed months ago is never decomposed a second time. One row per parent,
# tab separated, `-` for an empty column:
#   project  parent  state  desired  synced  children
# `state` is open for a container the board showed in the container lane,
# promoted for one firstmate judged to be a programme, and done once
# `decomposed` closed it. The first two differ only in what they are enough to
# justify offering: an `open` container is offered while it sits labelled in the
# lane's first column, because the board is what called it a container, whereas
# a `promoted` one is offered until it is closed, because firstmate's own
# recorded judgement is. `children` is `-`, or a comma-separated list of `task=child-url`
# pairs; neither half can contain a comma or an `=`, so the pair parses back
# unambiguously. It records the one thing only firstmate knows - which task it
# made for which child issue - and is a subset of the container's real children
# rather than the list of them; PARENT STATUS owns that distinction.
# `desired` and `synced` carry the parent card's status exactly as
# the linkage record's own two columns do.
#
# PLACEMENT, the inverse of import. `place` puts a task firstmate already holds
# onto the board: it creates the issue, cards it, sets it to the column that work
# belongs in, and records the link, after which dispatch, PR attachment, and
# merge all reflect through the ordinary events with no further special casing.
# `child-add` is the same operation with a parent - it additionally creates the
# issue as a native GitHub sub-issue of the container and records the child
# against it - so both verbs run one shared implementation rather than two that
# can drift.
#
# Two facts firstmate holds at the moment it places a card are stated on that
# same call rather than left to a second command someone has to remember, which
# is the only shape that has ever reflected onto a board reliably:
#
#   --parent <issue-url>  the programme this work belongs to. The issue is
#     created as a native GitHub sub-issue of that container and recorded as its
#     child in the same call, so work attached this way feeds exactly the books
#     PARENT STATUS below derives from. GitHub's own sub-issue relationship is
#     the whole of it: no label scheme, no naming convention, no second record.
#   --cleared             the captain has already given their go, so the card
#     enters the configured `queued` column instead of Processed.
#
# Neither is inferred. `--cleared` is stated per call because filing a card is
# not by itself the captain's go: an unstated call enters internalized exactly as
# it did before the flag existed, and a go derived from a proxy would turn a
# filed card into a launch authorization the moment the proxy was wrong. A board
# with no `queued` key has no such column, so the cleared state falls back
# through internalized to the inbox, and the `placed` line names the state
# actually filed so a fact the board cannot show is visible rather than silent.
#
# `--parent` attaches work to a container that already exists and never creates
# one: an issue this board has not already recorded as a container is refused, so
# `poll` first-sighting a card in the container lane and `promote` stay the only
# two routes by which the container-or-task judgement is made. It refuses a
# parent that already holds a task exactly as `child-add` does, and refuses a
# task already bound to an issue that container does not record as its child
# rather than reporting `already-placed` over the top of it.
#
# Both create the issue in the board's configured repo, carrying the trigger
# label; a board with no `repo` key uses the parent's repo when there is a parent
# and otherwise refuses `place`, because it has no repository to choose. `place`
# also takes an optional `--lands-in <owner/name>` that states on the card which
# repository the change actually lands in; pass it whenever that is not the
# repository the issue itself is filed in, so a roadmap never implies a diff is
# somewhere it is not.
#
# Work firstmate creates itself never sat in the captain's inbox and is already
# internalized by the time its card exists, so `place` and `child-add` file it
# straight into the configured Processed column rather than into Todo. A board
# with no `processed` key has no such column and both file into Todo, exactly as
# they did before the key existed.
#
# Which tasks belong on a board is an editorial call this script never makes.
# There is deliberately no command that sweeps unlinked tasks onto a board:
# placement is one task at a time, by a caller that decided that task belongs
# there.
#
# Because the created issue carries the label and holds a link before the next
# cycle reads the board, `poll` treats it as an ordinary linked card and can
# never offer it as `new`.
#
# The failure contract has two halves, split at the one irreversible step.
# Creating the issue is the command's whole purpose, so a creation that does not
# land writes nothing, reports the failure, and exits 1 - there is nothing to
# converge toward and firstmate must not build a backlog item on it. Every step
# after creation degrades fail-soft: the command prints `placed-partial` or
# `child-partial` naming the first step that did not land, and exits 0. `placed`
# and `placed-partial` both carry the entry state as their fourth field, exactly
# as `import` reports the state it internalized a card into.
#
# Repeating either command converges instead of filing a second issue for the
# same work, through three guards in falling order of cost. A task that already
# holds a link is finished, and answers `already-placed` with no network call at
# all - the link is written last precisely so that holding one proves the rest
# landed. A child already recorded against its parent is reused rather than
# created. Otherwise, before creating anything, the repo's most recent issues are
# read and one already carrying this task's `firstmate-task:` marker is adopted;
# that scan is deliberately shallow because the only gap it closes is an issue
# created moments before an interruption.
#
# The link is written as soon as the card exists rather than at the very end, so
# a card on the board is never briefly importable as new work; its `synced` stays
# unconfirmed until the column write lands, which leaves the ordinary outstanding
# -write retry to finish the job on the next cycle.
#
# PARENT STATUS. `poll` derives a container's state from every sub-issue GitHub
# currently records under its parent issue, including children absent from the
# board or the durable decomposition record. That record binds tasks to children;
# using it as membership would allow unrecorded open work to disappear.
#
# A child with an issue-to-task link contributes LINK_DESIRED, regardless of who
# created it. Linked states outside todo/processed/queued, in-progress, and done
# are excluded, so withdrawn work does not prevent completion. An unlinked child
# contributes done when GitHub says closed, otherwise todo.
#
# Among contributing children, any in-progress child or a mixture of open and
# done children derives in-progress; all done derives done; otherwise derive todo.
# No contributing children derives no new state, leaving any saved desired state
# unchanged. A failed sub-issue read reports an `error` and returns before any
# reconciliation, including retries of saved desired states: stale evidence must
# never finish a container. There is no fallback to the recorded subset.
#
# Derived states move the card through the big-picture columns using the same
# outstanding-write and divergence rules as ordinary cards. Failed writes report
# `stale` and retry after a successful read on a later cycle; successful writes
# report `synced`. A matching card is silent; a card showing a state firstmate
# did not write reports divergence. Regression coverage: tests/fm-board.test.sh.
#
# FAIL SOFT. Every board write degrades to a stale board instead of blocking
# delivery: `mark`, `pr`, and `note` exit 0 whether or not the write landed,
# reporting the failure on stderr and leaving `mark` and `pr` retryable. `poll`
# retries both outstanding writes - the card move and the PR attachment - and
# reports each with the same `synced` or `stale` line, and it also exits 0 on a
# board read failure, reporting it as an `error` line. A read that cannot tell
# absence from its own limits - a full page, or a board answering with no cards
# at all while links are open - says so and reconciles nothing rather than
# guessing. Exiting non-zero is reserved for the three things a caller must not
# proceed past: a usage or configuration error exits 2, a refused conflicting
# relink or container-versus-task conflict exits 3, and an issue this adapter was
# asked to create but could not exits 1, as PLACEMENT above sets out.
#
# DIRECTION OF AUTHORITY. Firstmate's own durable records are the truth and the
# board is how that truth is shown; chat, not the board, is where the captain
# controls the work. So status flows one way, outward: this adapter writes
# todo, processed, queued, in-progress, and done onto a card from what firstmate
# already recorded, and a card's column never tells firstmate what to do.
#
# That makes a status this adapter did not write a divergence rather than an
# instruction. `poll` prints a `divergence` line, writes nothing to the record,
# writes nothing to the board, and leaves it for firstmate to raise with the
# captain; the deliberate exception is a write still outstanding, which is
# retried because the board is showing the value this adapter last confirmed
# rather than a change to it. A card that appears in the queued column without
# firstmate having put it there can only mean something outside firstmate wrote
# to this board, which is why nothing here reconciles it in either direction and
# nothing about it starts work.
#
# Intake is the one thing the board still states rather than reports: a new
# labelled card is the captain adding work, and `new` continues to mean exactly
# that.
#
# An explicit `mark` is how a divergence is resolved, because it is firstmate
# acting rather than the adapter reconciling behind the captain's back: it writes
# the card and records what it confirmed, and the divergence stops being reported.
#
# An issue that a different configured board already owns is a misconfiguration
# rather than an instruction, so `poll` names it in a `foreign` line carrying the
# owning project and touches neither the card nor the record. Ownership is never
# silently re-homed, because every later event would then resolve the wrong
# board. `import` stays fleet-wide: an issue linked under any project can never
# be imported a second time under another one.
#
# WITHDRAWAL. A card that left the board while firstmate was still executing it
# is reported as `cancelled` until `ack` records that it was reconciled.
# Repeating survives a missed cycle; a card that left after reaching Done is
# ordinary archiving and is never reported.
#
# Closing the issue while its card stays on the board is the other way the same
# thing is said, and it is reported as `closed` on the same terms: only while the
# work is still open, repeating until `ack`, and never for a task that already
# landed, whose closed issue is just the ordinary end of it. It is a separate
# record rather than a second cause of `cancelled` because the captain's two
# actions are different and firstmate has to be able to say which one happened:
# under `cancelled` the card is gone, under `closed` it is still sitting there.
#
# Withdrawal is about work firstmate holds, so intake is untouched by it: a card
# nothing has been imported from binds no task, and there is nothing to withdraw
# from. Whether such a card is offered is the same captain-gated question it
# always was.
#
# Both are something to raise, not something this adapter acts on, exactly like a
# divergence, and neither reporting nor acknowledging one ever authorizes
# discarding unlanded work: hard rule 3 stands, and this adapter touches no
# branch, worktree, or repository.
#
# RECORDS. Every line `poll` prints is something firstmate has to act on, which
# is the whole of the rule about what it says. The kinds are `new`, `decompose`,
# `divergence`, `foreign`, `cancelled`, `closed`, `synced`, `stale`, `truncated`,
# `error`, and - on a board that configures a classification field -
# `unclassified`, `classified`, `classification-stale`, and
# `classification-divergence`; each is owned by the section above that describes
# the situation it reports. A card already showing what firstmate recorded is not one of them: it
# prints nothing, exactly as a reconciled container has always printed nothing.
# So a fully reconciled board polls to no output at all, and a board that grows
# to hundreds of settled cards stays as quiet as one holding none. `--all` adds
# back the `linked` record for every settled card, which is the one record that
# default silence removes, and nothing further: a reconciled container stays
# silent under it exactly as it always has, and every durable record the cycle
# writes is unchanged. The flag is a specified part of this change rather than
# incidental to it, kept as an explicit opt-in for debugging.
#
# COST. Board and Projects work is GraphQL with its own hourly budget, and a
# full board read inside a per-item loop is what exhausts it: the CLI's own
# whole-board read is around a hundred points of an hourly five thousand, so a
# loop that made one per card rate-limited the account at forty-five cards. The
# read this file makes is the direct GraphQL one instead, measured at three
# points for the same board (docs/verification/board-cost.md), but the rule it
# obeys is the shape rather than the price: a read per card is refused however
# cheap one read gets.
#
# Nothing here reads the board to resolve a single card. One reconciliation
# cycle reads it exactly once, and every write that cycle then makes reuses a
# card id from that one read.
#
# The one per-card read a cycle makes is a container's sub-issues, and it is
# affordable for the reason this whole section turns on: it contains no board
# read. It is a flat REST read of one issue, made only for a card in the
# container lane rather than for every card, and a board's containers are its
# programmes - a small set beside its work items by construction. It is also a
# different budget: REST requests rather than GraphQL points.
#
# Outside a cycle, `mark`, `import`, and `promote`
# resolve their card from the issue that holds it - GitHub answers a card's id
# from the issue's own node, so the request is the same size whether the board
# carries ten cards or a thousand - and `place` and `child-add` read nothing at
# all, taking their card id from what the add itself returned, because a freshly
# added card is not immediately visible in a board listing anyway. The project,
# field, and option node IDs come back in one request and are cached per board
# for the rest of the invocation.
#
# Three properties follow, and tests/fm-board.test.sh pins all three. Per-card
# cost is a small constant rather than a function of how many cards the board
# carries, so a board that grows does not make every write on it dearer. No
# board read ever reappears inside a per-item loop: growing a board by ordinary
# work items changes what one invocation costs not at all, and growing it by a
# container adds one paginated REST invocation, which the same test counts.
# Pagination may make multiple HTTP requests; no page reads the board. And that
# constant does not follow how many fields are synchronized: a cycle that
# reconciles both the column and the classification of every card it changes
# costs exactly what the same cycle costs on a board that classifies nothing.
#
# BATCHING. One GraphQL document carries the project id and every single-select
# field on the board with its options, which the CLI's `project view` plus
# `project field-list` answer in two requests, the second of them paging every
# field on the board to reach the one that is wanted. Both reads were measured;
# docs/verification/board-cost.md carries the figures.
#
# That one document is why a second synchronized field is free to read. The
# status field and the classification field are two lookups into one cached
# snapshot, resolved by name in the shell rather than by the query, so the read
# count is set by how many boards a run touches and never by how many fields it
# writes. A third field would be the same.
#
# Writing them is batched for the same reason. Setting two single-select fields
# on one card is one request, not two: the CLI has no verb for it, so a
# two-field write goes through GraphQL, where one document carries both
# mutations under aliases. A card owing one field keeps the `project item-edit`
# it always used, so a board that classifies nothing makes exactly the calls it
# made before. What both halves preserve is the property the cost guard pins:
# per-card requests follow how many cards a cycle changes, never how many fields
# each change touches.
#
# The per-card write is still individual across cards by choice. The normal case
# here is a single-card event, where one write is the whole of the work, and
# writing each card on its own keeps failure attribution exact: `synced` and
# `stale` name the individual cards the board took and the ones still owed,
# which is what the next cycle retries.
#
# Revisit that choice when either of two things changes: this path starts
# routinely writing several cards per event, or GitHub request cost becomes
# material again. Batch it then.
#
# GITHUB CLI. This adapter calls `gh` rather than `gh-axi`, and adds no new
# dependency because `gh` is already part of firstmate's universal toolchain
# (docs/configuration.md, "Toolchain"). gh-axi can perform every read and write
# needed here, but it renders project reads as truncated agent-readable output
# with no machine-stable shape, while the status write needs the exact project,
# field, and option node IDs that only the JSON surface returns - the same
# `gh ... --format json` surface gh-axi itself calls. Every read here goes through
# `gh api graphql`, as does a write that sets two fields on one card: no CLI verb
# asks GitHub for one issue's card, for a project's id and its fields' options
# together, for two field values in one request, or for a board's cards with each
# card's issue state beside it.
# `gh` also carries an embedded jq, so shaping that JSON needs no external jq
# either. Firstmate's own conversational GitHub work stays on gh-axi. Board
# commands need gh's `project` OAuth scope (`gh auth refresh -s project`).
#
# Overrides for tests and specialized setups: FM_HOME, FM_CONFIG_OVERRIDE,
# FM_DATA_OVERRIDE, and FM_BOARD_GH (the GitHub CLI to invoke).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BOARDS_FILE="$CONFIG/boards"
LINKS="$DATA/board-links.tsv"
DECOMPS="$DATA/board-decompositions.tsv"
GH="${FM_BOARD_GH:-gh}"
TAB=$'\t'
# One board read's ceiling, which belongs to `poll` alone.
DEFAULT_LIMIT=200
MARK_USAGE='usage: fm-board.sh mark <task-id> todo|processed|queued|in-progress|done'

limit_valid() {
  case "${1:-}" in
    '' | *[!0-9]* | 0) return 1 ;;
  esac
  return 0
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-2}"
}

warn() {
  printf 'board: %s\n' "$1" >&2
}

print_help() {
  sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "$0"
}

# --- configuration ----------------------------------------------------------
#
# boards_emit prints one tab-separated stanza per configured board:
#   project owner number repo label mention assignee status_field todo
#   in_progress done bp_todo bp_in_progress bp_done queued processed
#   classify_field
# Optional values that are unset print as `-`. Malformed configuration is an
# actionable error rather than something to guess around.

CONFIG_VALUE_RE='^[A-Za-z0-9 ._-]+$'
CONFIG_SLUG_RE='^[A-Za-z0-9._-]+$'

# Emits the stanza being accumulated by boards_emit. Called only from there, and
# deliberately reads that caller's locals rather than taking a dozen arguments.
boards_flush() {
  local set_count=0 name norm seen_cols=
  [ -n "$project" ] || return 0
  [ "$owner" != - ] || die "config/boards: board \"$project\" has no owner"
  [ "$number" != - ] || die "config/boards: board \"$project\" has no number"
  # The three big-picture columns are one switch, not three independent keys: a
  # partial set would classify some containers and not others, so it is refused
  # here rather than half-enabled.
  for name in "$bp_todo" "$bp_in_progress" "$bp_done"; do
    [ "$name" = - ] || set_count=$((set_count + 1))
  done
  if [ "$set_count" != 0 ] && [ "$set_count" != 3 ]; then
    die "config/boards: board \"$project\" sets some big-picture columns but not all three (big-picture-todo, big-picture-in-progress, big-picture-done)"
  fi
  # Two keys naming one column would make a single card mean two different
  # things, so every configured column name has to be distinct.
  for name in "$todo" "$in_progress" "$done_col" "$queued" "$processed" \
    "$bp_todo" "$bp_in_progress" "$bp_done"; do
    [ "$name" != - ] || continue
    norm=$(norm_name "$name")
    case "$TAB$seen_cols" in
      *"$TAB$norm$TAB"*)
        die "config/boards: board \"$project\" gives \"$name\" as more than one column"
        ;;
    esac
    seen_cols="$seen_cols$norm$TAB"
  done
  # Two keys naming one field would make a single card's value mean two things,
  # exactly as two keys naming one column would, so the classification field has
  # to be a different field from the one holding the columns.
  if [ "$classify_field" != - ] \
    && [ "$(norm_name "$classify_field")" = "$(norm_name "$status_field")" ]; then
    die "config/boards: board \"$project\" gives \"$classify_field\" as both its status field and its classification field"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$project" "$owner" "$number" "$repo" "$label" "$mention" "$assignee" \
    "$status_field" "$todo" "$in_progress" "$done_col" \
    "$bp_todo" "$bp_in_progress" "$bp_done" "$queued" "$processed" \
    "$classify_field"
}
boards_emit() {
  local line key value project owner number repo label mention assignee
  local status_field todo in_progress done_col lineno=0 seen=
  local bp_todo bp_in_progress bp_done queued processed classify_field
  [ -f "$BOARDS_FILE" ] || return 0

  project=''
  owner=- number=- repo=- label=firstmate mention=- assignee=-
  status_field=Status todo=Todo in_progress='In Progress' done_col=Done
  bp_todo=- bp_in_progress=- bp_done=- queued=- processed=- classify_field=-
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    case "$line" in
      '' | '#'*) continue ;;
      *=*) ;;
      *) die "config/boards line $lineno: expected \"key = value\"" ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    # Trim surrounding whitespace from both halves.
    key=${key#"${key%%[![:space:]]*}"}
    key=${key%"${key##*[![:space:]]}"}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    [ -n "$value" ] || die "config/boards line $lineno: \"$key\" has no value"
    case "$value" in
      *"$TAB"*) die "config/boards line $lineno: \"$key\" must not contain a tab" ;;
    esac

    if [ "$key" = project ]; then
      boards_flush
      case "$value" in
        *' '*) die "config/boards line $lineno: project name must not contain a space" ;;
      esac
      case " $seen " in
        *" $value "*) die "config/boards: project \"$value\" is configured twice" ;;
      esac
      seen="$seen $value"
      project=$value
      owner=- number=- repo=- label=firstmate mention=- assignee=-
      status_field=Status todo=Todo in_progress='In Progress' done_col=Done
      bp_todo=- bp_in_progress=- bp_done=- queued=- processed=- classify_field=-
      continue
    fi
    [ -n "$project" ] || die "config/boards line $lineno: \"$key\" appears before any project"

    case "$key" in
      owner)
        [[ $value =~ $CONFIG_SLUG_RE ]] || die "config/boards line $lineno: owner \"$value\" is not a login"
        owner=$value
        ;;
      number)
        case "$value" in
          *[!0-9]*) die "config/boards line $lineno: number \"$value\" is not a project number" ;;
        esac
        number=$value
        ;;
      repo)
        case "$value" in
          */*/* | */ | /* | *' '*) die "config/boards line $lineno: repo \"$value\" is not owner/name" ;;
          */*) repo=$value ;;
          *) die "config/boards line $lineno: repo \"$value\" is not owner/name" ;;
        esac
        ;;
      label | todo | in-progress | done | queued | processed | status-field \
        | classify-field \
        | big-picture-todo | big-picture-in-progress | big-picture-done)
        [[ $value =~ $CONFIG_VALUE_RE ]] \
          || die "config/boards line $lineno: \"$key\" may use only letters, digits, spaces, dot, underscore, and dash"
        case "$key" in
          label) label=$value ;;
          todo) todo=$value ;;
          in-progress) in_progress=$value ;;
          done) done_col=$value ;;
          status-field) status_field=$value ;;
          classify-field) classify_field=$value ;;
          queued) queued=$value ;;
          processed) processed=$value ;;
          big-picture-todo) bp_todo=$value ;;
          big-picture-in-progress) bp_in_progress=$value ;;
          big-picture-done) bp_done=$value ;;
        esac
        ;;
      mention)
        case "$value" in
          @*) [[ ${value#@} =~ $CONFIG_SLUG_RE ]] || die "config/boards line $lineno: mention \"$value\" is not @login" ;;
          *) die "config/boards line $lineno: mention \"$value\" must start with @" ;;
        esac
        mention=$value
        ;;
      assignee)
        [[ $value =~ $CONFIG_SLUG_RE ]] || die "config/boards line $lineno: assignee \"$value\" is not a login"
        assignee=$value
        ;;
      *) die "config/boards line $lineno: unknown key \"$key\"" ;;
    esac
  done < "$BOARDS_FILE"
  boards_flush
}

# boards_load caches the validated stanzas once. boards_emit refuses malformed
# configuration by exiting, but it runs in a substitution subshell, so its status
# has to be turned back into a real exit here.
BOARDS_CACHE=
BOARDS_LOADED=0
boards_load() {
  local rc=0
  if [ "$BOARDS_LOADED" = 1 ]; then
    return 0
  fi
  BOARDS_CACHE=$(boards_emit) || rc=$?
  if [ "$rc" != 0 ]; then
    exit "$rc"
  fi
  BOARDS_LOADED=1
}

boards_rows() {
  [ -n "$BOARDS_CACHE" ] || return 0
  printf '%s\n' "$BOARDS_CACHE"
}

# board_for <project>: print that one board stanza, or fail with a usable error.
board_for() {
  local want=$1 row found=
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    case "$row" in
      "$want$TAB"*)
        found=$row
        break
        ;;
    esac
  done < <(boards_rows)
  [ -n "$found" ] || die "no board configured for project \"$want\" in config/boards"
  printf '%s\n' "$found"
}

# --- durable linkage record -------------------------------------------------

LINKS_HEADER="# fm-board.sh durable issue-to-task links: project${TAB}issue${TAB}task${TAB}desired${TAB}synced${TAB}pr${TAB}pr_synced${TAB}area${TAB}area_synced"

links_rows() {
  local row
  [ -f "$LINKS" ] || return 0
  while IFS= read -r row || [ -n "$row" ]; do
    case "$row" in
      '' | '#'*) continue ;;
    esac
    printf '%s\n' "$row"
  done < "$LINKS"
}

# A row is nine tab-separated columns and no column is ever empty, so one
# `read` splits it into named variables without a subprocess per field. The
# record is kept forever by design, so a scan that forked per field would cost
# more on every cycle than the one before it.
#
# The header owns the classification columns and legacy-row compatibility.
LINK_PROJECT=- LINK_ISSUE=- LINK_TASK=- LINK_DESIRED=- LINK_SYNCED=-
LINK_PR=- LINK_PR_SYNCED=- LINK_AREA=- LINK_AREA_SYNCED=-

link_clear() {
  LINK_PROJECT=- LINK_ISSUE=- LINK_TASK=- LINK_DESIRED=- LINK_SYNCED=-
  LINK_PR=- LINK_PR_SYNCED=- LINK_AREA=- LINK_AREA_SYNCED=-
}

# links_find issue|task <value>: leave the matching record in the LINK_
# variables and print it, or clear them and return 1. Callers read the
# variables, so this is never run inside a command substitution.
links_find() {
  local by=$1 want=$2 found=
  while IFS=$TAB read -r LINK_PROJECT LINK_ISSUE LINK_TASK LINK_DESIRED \
    LINK_SYNCED LINK_PR LINK_PR_SYNCED LINK_AREA LINK_AREA_SYNCED; do
    case "$by" in
      issue) [ "$LINK_ISSUE" = "$want" ] || continue ;;
      *) [ "$LINK_TASK" = "$want" ] || continue ;;
    esac
    found=1
    break
  done < <(links_rows)
  if [ -z "$found" ]; then
    link_clear
    return 1
  fi
  LINK_AREA=${LINK_AREA:--}
  LINK_AREA_SYNCED=${LINK_AREA_SYNCED:--}
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$LINK_PROJECT" "$LINK_ISSUE" "$LINK_TASK" "$LINK_DESIRED" "$LINK_SYNCED" \
    "$LINK_PR" "$LINK_PR_SYNCED" "$LINK_AREA" "$LINK_AREA_SYNCED"
}

# links_put <project> <issue> <task> <desired> <synced> <pr> <pr_synced>
#           <area> <area_synced>
# Atomically rewrites the record file, replacing any row for the same issue.
links_put() {
  [ "$#" -eq 9 ] || die "links_put requires both classification arguments"
  local project=$1 issue=$2 task=$3 desired=$4 synced=$5 pr=$6 pr_synced=$7
  local area=$8 area_synced=$9
  local tmp r_project r_issue r_task r_desired r_synced r_pr r_pr_synced
  local r_area r_area_synced
  mkdir -p "$DATA" || die "cannot create $DATA" 1
  tmp=$(umask 077; mktemp "$DATA/.board-links.XXXXXX") || die "cannot write the linkage record" 1
  printf '%s\n' "$LINKS_HEADER" > "$tmp"
  while IFS=$TAB read -r r_project r_issue r_task r_desired r_synced r_pr \
    r_pr_synced r_area r_area_synced; do
    [ "$r_issue" != "$issue" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$r_project" "$r_issue" "$r_task" "$r_desired" "$r_synced" "$r_pr" \
      "$r_pr_synced" "${r_area:--}" "${r_area_synced:--}" >> "$tmp"
  done < <(links_rows)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$project" "$issue" "$task" "$desired" "$synced" "${pr:--}" "${pr_synced:--}" \
    "${area:--}" "${area_synced:--}" >> "$tmp"
  mv -f "$tmp" "$LINKS" || { rm -f "$tmp"; die "cannot replace the linkage record" 1; }
}

# --- durable decomposition record -------------------------------------------
#
# One row per container, kept for the same reason the linkage record is: a
# parent decomposed long ago must never be offered for decomposition again.

DECOMPS_HEADER="# fm-board.sh durable decompositions: project${TAB}parent${TAB}state${TAB}desired${TAB}synced${TAB}children"

decomps_rows() {
  local row
  [ -f "$DECOMPS" ] || return 0
  while IFS= read -r row || [ -n "$row" ]; do
    case "$row" in
      '' | '#'*) continue ;;
    esac
    printf '%s\n' "$row"
  done < "$DECOMPS"
}

DECOMP_PROJECT=- DECOMP_PARENT=- DECOMP_STATE=-
DECOMP_DESIRED=- DECOMP_SYNCED=- DECOMP_CHILDREN=-

decomp_clear() {
  DECOMP_PROJECT=- DECOMP_PARENT=- DECOMP_STATE=-
  DECOMP_DESIRED=- DECOMP_SYNCED=- DECOMP_CHILDREN=-
}

# decomps_find <parent-issue-url>: leave the matching row in the DECOMP_
# variables and print it, or clear them and return 1. Like links_find, callers
# read the variables, so this never runs inside a command substitution.
decomps_find() {
  local want=$1 found=
  while IFS=$TAB read -r DECOMP_PROJECT DECOMP_PARENT DECOMP_STATE \
    DECOMP_DESIRED DECOMP_SYNCED DECOMP_CHILDREN; do
    [ "$DECOMP_PARENT" = "$want" ] || continue
    found=1
    break
  done < <(decomps_rows)
  if [ -z "$found" ]; then
    decomp_clear
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$DECOMP_PROJECT" "$DECOMP_PARENT" "$DECOMP_STATE" \
    "$DECOMP_DESIRED" "$DECOMP_SYNCED" "$DECOMP_CHILDREN"
}

# decomps_put <project> <parent> <state> <desired> <synced> <children>
decomps_put() {
  local project=$1 parent=$2 state=$3 desired=$4 synced=$5 children=$6
  local tmp r_project r_parent r_state r_desired r_synced r_children
  mkdir -p "$DATA" || die "cannot create $DATA" 1
  tmp=$(umask 077; mktemp "$DATA/.board-decompositions.XXXXXX") \
    || die "cannot write the decomposition record" 1
  printf '%s\n' "$DECOMPS_HEADER" > "$tmp"
  while IFS=$TAB read -r r_project r_parent r_state r_desired \
    r_synced r_children; do
    [ "$r_parent" != "$parent" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$r_project" "$r_parent" "$r_state" "$r_desired" \
      "$r_synced" "$r_children" >> "$tmp"
  done < <(decomps_rows)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$project" "$parent" "$state" "$desired" "$synced" "$children" >> "$tmp"
  mv -f "$tmp" "$DECOMPS" || { rm -f "$tmp"; die "cannot replace the decomposition record" 1; }
}

# The children column packs one `task=child-url` pair per child, comma
# separated. Neither half can hold a comma or an `=`, so splitting on those two
# characters recovers the pairs exactly.

# children_pairs <children>: print one `task=url` pair per line.
children_pairs() {
  local children=${1:--} pair rest
  [ "$children" != - ] || return 0
  rest=$children
  while [ -n "$rest" ]; do
    pair=${rest%%,*}
    if [ "$pair" = "$rest" ]; then
      rest=
    else
      rest=${rest#*,}
    fi
    [ -z "$pair" ] || printf '%s\n' "$pair"
  done
}

# children_child_for <children> <task-id>: print that task's recorded child URL.
children_child_for() {
  local children=$1 task=$2 pair
  while IFS= read -r pair; do
    [ "${pair%%=*}" = "$task" ] || continue
    printf '%s\n' "${pair#*=}"
    return 0
  done < <(children_pairs "$children")
  return 1
}

# children_add <children> <task-id> <child-url>: print the list with that pair
# added, replacing any pair the same task already holds.
children_add() {
  local children=$1 task=$2 url=$3 pair out=
  while IFS= read -r pair; do
    [ "${pair%%=*}" != "$task" ] || continue
    out="${out:+$out,}$pair"
  done < <(children_pairs "$children")
  printf '%s\n' "${out:+$out,}$task=$url"
}

# --- identifiers ------------------------------------------------------------

# issue_canonical <url>: print the canonical issue URL, or fail.
issue_canonical() {
  local url=${1:-} rest number
  url=${url%%\#*}
  url=${url%%\?*}
  url=${url%/}
  case "$url" in
    https://*/*/*/issues/*) ;;
    *) return 1 ;;
  esac
  rest=${url#https://}
  number=${rest##*/}
  case "$number" in
    '' | *[!0-9]*) return 1 ;;
  esac
  case "$url" in
    *"$TAB"* | *' '*) return 1 ;;
  esac
  printf '%s\n' "$url"
}

# issue_repo <canonical-url>: print owner/name.
issue_repo() {
  local rest=${1#https://}
  rest=${rest#*/}
  printf '%s/%s\n' "${rest%%/*}" "$(printf '%s' "${rest#*/}" | cut -d/ -f1)"
}

task_id_valid() {
  case "${1:-}" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

pr_url_valid() {
  case "${1:-}" in
    https://*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *"$TAB"* | *' '*) return 1 ;;
  esac
  return 0
}

# --- board reads ------------------------------------------------------------

# Normalize a field, option, label, or login the way any JSON export may spell
# it, so a "Status"/"status" or "In Progress"/"inProgress" difference is not a
# behavioral difference.
norm_name() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d ' '
}

# json_string <text>: emit a JSON string literal for safe jq interpolation.
# Configuration already restricts these names to letters, digits, spaces, dot,
# underscore, and dash, so this is defence in depth rather than the only guard.
json_string() {
  printf '"%s"' "$(printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

# The board read's columns, in order:
#   item_id  type  issue_url  status  labels  assignees  title  body  class
#   state
# Every column falls back to `-` so the reader never sees an empty field.
#
# `class` is the configured classification field's value on that card, read from
# this same response rather than from a second one: the card already carries
# every field the board sets on it, so a second synchronized field is another
# column here and never another request. A board with no classification field
# configured passes an empty key, which matches no field on any card, so the
# column is `-` for every card and no path below ever reads it.
#
# `state` is the card's own issue state, `open` or `closed`, and `-` for a draft
# card that has no issue behind it. It is the same kind of column as `class`:
# one more value out of the one board read, never a lookup per card.
#
# A card whose field values did not fit one page is refused rather than read
# short, because a status this read could not see would look exactly like a card
# firstmate never wrote to.
items_jq() {
  local status_key class_key class_name=${2:--}
  [ "$class_name" != - ] || class_name=''
  status_key=$(json_string "$(norm_name "$1")")
  class_key=$(json_string "$(norm_name "$class_name")")
  cat <<JQ
def dash: if (. == null or . == "") then "-" else . end;
def clean: (. // "") | tostring | gsub("[\\\\t\\\\n\\\\r]+"; " ") | dash;
def norm: (. // "") | tostring | ascii_downcase | gsub(" "; "");
def names:
  (. // [])
  | if type == "array" then map(if type == "object" then (.name // .login // "") else tostring end) else [] end
  | map(select(. != "")) | join(",") | dash;
def value(\$key):
  map(select((.field.name | norm) == \$key)) | (.[0].name // "") | dash;
(.data.repositoryOwner.projectV2.items.nodes // [])[]
| . as \$i
| (if ((\$i.fieldValues.pageInfo.hasNextPage // false) == true)
   then error("card field values truncated") else . end)
| ((\$i.content // {}) | if type == "object" then . else {} end) as \$c
| ([ (\$i.fieldValues.nodes // [])[]
     | select(type == "object" and (((.field // {}).name // "") != "")) ]) as \$v
| [ (\$i.id // "" | tostring | dash),
    (\$c.__typename // "" | tostring | dash),
    (\$c.url // "" | tostring | dash),
    (\$v | value($status_key)),
    ((\$c.labels).nodes | names),
    ((\$c.assignees).nodes | names),
    (\$c.title | clean),
    (\$c.body | clean),
    (\$v | value($class_key)),
    (\$c.state | norm | dash)
  ] | @tsv
JQ
}

# The batched id read's columns, drawn from the one document below:
#   "project"<TAB>id
#   "field"<TAB>field-id<TAB>normalized-name
#   "option"<TAB>option-id<TAB>field-id<TAB>normalized-name<TAB>name
#
# Every single-select field on the board is carried through, not just the one a
# caller happens to want. That is what makes a second synchronized field free:
# the one request already returns them all with their options, so the status
# field and the classification field are two rows of one answer rather than two
# reads. Widening this filter is how a field is added; adding a request is not.
#
# The wanted field is picked out in the shell rather than in the query because
# GitHub's own `field(name:)` lookup is an exact, case-sensitive match, while a
# `status-field` key spelled "status" has always resolved a board field named
# "Status". Matching on the normalized name keeps that tolerance, and doing it
# per lookup rather than per read is what lets one read serve both fields.
#
# The name is normalized here rather than by the shell so a board of many fields
# costs no subshell per option. An option carries its own field's id, so a name
# two fields both use resolves to the right one rather than to whichever came
# last - the decoy case the suite pins.
fields_jq() {
  cat <<'JQ'
def norm: ((. // "") | tostring | ascii_downcase | gsub(" "; ""));
(.data.repositoryOwner.projectV2 // empty)
| (["project", (.id // "" | tostring)] | @tsv),
  ( ((.fields.nodes // [])[]
     | select((.id // "") != "")
     | . as $f
     | (["field", ($f.id // "" | tostring), ($f.name | norm)] | @tsv),
       (($f.options // [])[]
        | ["option", (.id // "" | tostring), ($f.id // "" | tostring),
           (.name | norm), (.name // "" | tostring)]
        | @tsv)
    ) )
JQ
}

# The card lookup's filter: this one board's card, out of every board the issue
# sits on. Owner logins carry no spaces, but they are normalized on both sides
# so the comparison cannot drift from how every other name here is matched.
card_jq() {
  local owner_key number_key class_key
  class_key=$(json_string "$(norm_name "${3:--}")")
  owner_key=$(json_string "$(norm_name "$1")")
  number_key=$(json_string "$2")
  cat <<JQ
[ ((.data.repository.issue.projectItems.nodes // [])[]
   | select((((.project.owner.login // "") | ascii_downcase | gsub(" "; "")) == $owner_key)
            and (((.project.number // "") | tostring) == $number_key))
   | select((.id // "") != "")
   | if $class_key != "-" and .fieldValues.pageInfo.hasNextPage == true then
       error("card field values truncated")
     else
       [(.id | tostring),
        ([ (.fieldValues.nodes // [])[]
           | select(((.field.name // "") | ascii_downcase | gsub(" "; "")) == $class_key)
           | .name ] | first // "-")]
       | @tsv
     end) ]
| first // empty
JQ
}

# How many cards one page of the board read carries. GitHub caps a connection's
# `first:` at 100, so this is that ceiling rather than a tuning choice: a limit
# above it is walked page by page, and one at or below it is a single request.
BOARD_ITEMS_PAGE=100
# How many labels and assignees one card carries into the read. Both feed intake
# triggers alone, and a card wearing more of either than this has outgrown what a
# trigger can tell apart anyway.
BOARD_CARD_LIST_LIMIT=50
# GraphQL names its own variables with `$`, so this document is deliberately
# unexpanded; the values travel beside it as `-f`/`-F` arguments.
# shellcheck disable=SC2016
BOARD_ITEMS_QUERY='query($owner: String!, $number: Int!, $page: Int!, $fields: Int!, $labels: Int!, $people: Int!, $endCursor: String) {
  repositoryOwner(login: $owner) {
    ... on ProjectV2Owner {
      projectV2(number: $number) {
        items(first: $page, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            content {
              __typename
              ... on Issue {
                url
                title
                body
                state
                labels(first: $labels) { nodes { name } }
                assignees(first: $people) { nodes { login } }
              }
              ... on PullRequest {
                url
                title
                body
                state
                labels(first: $labels) { nodes { name } }
                assignees(first: $people) { nodes { login } }
              }
              ... on DraftIssue { title body }
            }
            fieldValues(first: $fields) {
              pageInfo { hasNextPage }
              nodes {
                ... on ProjectV2ItemFieldSingleSelectValue {
                  name
                  field { ... on ProjectV2SingleSelectField { name } }
                }
              }
            }
          }
        }
      }
    }
  }
}'

# board_items <owner> <number> <status_field> <classify_field|-> <limit> <outfile>
# The whole-board read, and the only call in this file whose cost grows with how
# many cards the board carries. One reconciliation cycle makes it exactly once;
# nothing below ever reaches for it to resolve a single card.
#
# It is GraphQL rather than `gh project item-list` for one reason: the CLI's
# `content` carries body, number, repository, title, type, and url alone, and
# never whether the issue is open or closed. Closure is a withdrawal signal
# WITHDRAWAL above owns, so the state has to arrive beside the card it belongs
# to, out of the one snapshot every other value on that card comes from. A second
# read would answer a different instant, and a per-card lookup is the shape the
# cost guard exists to refuse. The document asks for one page of cards with their
# content, their labels and assignees, and every single-select field value, which
# is everything the reader below needs and measurably cheaper than the CLI's own
# read (docs/verification/board-cost.md).
#
# A container's children are the one thing this read cannot be widened to carry,
# because they are not cards: a sub-issue anyone attached to a container need
# never have been put on the board at all, and PARENT STATUS is wrong the moment
# it counts only the ones that were. So they are read from the parent issue, one
# flat read per container card, which COST above bounds.
board_items() {
  local owner=$1 number=$2 status_field=$3 classify_field=$4 limit=$5 out=$6
  local page raw rc=0 cursor='' next remaining=$limit filter
  local -a args
  filter='(.data.repositoryOwner.projectV2.items.pageInfo | if .hasNextPage then .endCursor else "-" end), ('"$(items_jq "$status_field" "$classify_field")"')'
  raw=$(mktemp) || return 1
  : > "$out"
  while [ "$remaining" -gt 0 ]; do
    page=$remaining
    [ "$page" -le "$BOARD_ITEMS_PAGE" ] || page=$BOARD_ITEMS_PAGE
    args=(api graphql
      -f query="$BOARD_ITEMS_QUERY"
      -f owner="$owner"
      -F number="$number"
      -F page="$page"
      -F fields="$BOARD_FIELDS_LIMIT"
      -F labels="$BOARD_CARD_LIST_LIMIT"
      -F people="$BOARD_CARD_LIST_LIMIT"
      --jq "$filter")
    [ -z "$cursor" ] || args+=(-f endCursor="$cursor")
    "$GH" "${args[@]}" </dev/null > "$raw" || { rc=$?; break; }
    IFS= read -r next < "$raw"
    sed '1d' "$raw" >> "$out"
    remaining=$((remaining - page))
    [ "$next" != - ] || break
    if [ -z "$next" ] || [ "$next" = null ] || [ "$next" = "$cursor" ]; then
      rc=1
      break
    fi
    cursor=$next
  done
  rm -f "$raw"
  return "$rc"
}

# --- board writes -----------------------------------------------------------

# How many of the boards one issue sits on the card lookup enumerates. This
# bounds a card's own memberships, not a board's cards, so it is small on
# purpose: an issue on more boards than this is outside what a single-board
# adapter can resolve unambiguously anyway.
CARD_PROJECTS_LIMIT=20
# GraphQL names its own variables with `$`, so this document is deliberately
# unexpanded; the values travel beside it as `-f`/`-F` arguments.
# shellcheck disable=SC2016
CARD_QUERY='query($owner: String!, $name: String!, $number: Int!, $projects: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      projectItems(first: $projects, includeArchived: false) {
        nodes {
          id
          fieldValues(first: 100) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field { ... on ProjectV2SingleSelectField { name } }
              }
            }
            pageInfo { hasNextPage }
          }
          project {
            number
            owner {
              ... on Organization { login }
              ... on User { login }
            }
          }
        }
      }
    }
  }
}'

# board_card_values <owner> <number> <issue-url> <classify-field|->:
# the card id and observed area, tab-separated, read from the issue's own node.
#
# This is the whole reason a per-card write no longer costs what a board read
# costs. GitHub answers a card's id from the issue itself, so the request is the
# same size whether the board carries ten cards or a thousand, and a caller
# holding only an issue URL never has to page the board to find its card.
# Archived cards are excluded so this agrees with the board read, which does not
# list them either.
board_card_values() {
  local owner=$1 number=$2 issue=$3 classify_field=$4 repo id
  repo=$(issue_repo "$issue")
  id=$("$GH" api graphql \
    -f query="$CARD_QUERY" \
    -f owner="${repo%%/*}" -f name="${repo#*/}" \
    -F number="${issue##*/}" -F projects="$CARD_PROJECTS_LIMIT" \
    --jq "$(card_jq "$owner" "$number" "$classify_field")" </dev/null) || return 1
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

# The project, field, and option node IDs are the same for every card on one
# board, so they are read once per board and reused by every write in this run.
# Resolving them per write would turn a cheap cycle into a project read for each
# outstanding write it retries.
#
# They all come back in one request, where the CLI needs two: `project view`
# and `project field-list` are two round trips for what the API answers in one,
# and the second of them pages every field on the board to reach the single
# field that is wanted.
#
# The cache is keyed by the board alone rather than by the board and one field
# name, because the one response carries every single-select field the board
# has. That is the whole reason a second synchronized field costs no second
# read: the status field and the classification field are two lookups into one
# cached snapshot, and a third would be too.
BOARD_FIELDS_LIMIT=100
# shellcheck disable=SC2016
BOARD_IDS_QUERY='query($owner: String!, $number: Int!, $fields: Int!) {
  repositoryOwner(login: $owner) {
    ... on ProjectV2Owner {
      projectV2(number: $number) {
        id
        fields(first: $fields) {
          nodes {
            ... on ProjectV2SingleSelectField {
              id
              name
              options { id name }
            }
          }
        }
      }
    }
  }
}'
BOARD_IDS_KEY=
BOARD_PROJECT_ID=
# One `name<TAB>id` line per single-select field on the board, and one
# `field-id<TAB>normalized-name<TAB>option-id<TAB>name` line per option. The
# normalized name is what lookups match on; the name as the board spells it is
# kept beside it so `classifications` can answer in the board's own words.
BOARD_FIELD_IDS=
BOARD_OPTIONS=

# board_ids <owner> <number>: resolve and cache the board's snapshot.
# A failure caches nothing, so the next write retries the read.
board_ids() {
  local owner=$1 number=$2
  local key project_id field_ids options tmp kind a b c d
  key="$owner$TAB$number"
  if [ "$BOARD_IDS_KEY" = "$key" ]; then
    return 0
  fi
  tmp=$(mktemp) || return 1
  if ! "$GH" api graphql \
    -f query="$BOARD_IDS_QUERY" \
    -f owner="$owner" -F number="$number" -F fields="$BOARD_FIELDS_LIMIT" \
    --jq "$(fields_jq)" > "$tmp" </dev/null; then
    rm -f "$tmp"
    warn "could not read project $owner/$number"
    return 1
  fi
  project_id=''
  field_ids=''
  options=''
  while IFS=$TAB read -r kind a b c d; do
    case "$kind" in
      project) project_id=$a ;;
      field) field_ids="$field_ids${b:-}$TAB$a"$'\n' ;;
      option) options="$options${b:-}$TAB${c:-}$TAB$a$TAB${d:-}"$'\n' ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  if [ -z "$project_id" ]; then
    warn "project $owner/$number reported no id"
    return 1
  fi
  BOARD_PROJECT_ID=$project_id
  BOARD_FIELD_IDS=$field_ids
  BOARD_OPTIONS=$options
  BOARD_IDS_KEY=$key
  return 0
}

# board_field_id <field-name>: the cached single-select field id, or fail.
board_field_id() {
  local want name id
  want=$(norm_name "$1")
  while IFS=$TAB read -r name id; do
    [ "$name" = "$want" ] || continue
    printf '%s\n' "$id"
    return 0
  done <<< "$BOARD_FIELD_IDS"
  return 1
}

# board_option_id <field-id> <option-name>: the cached option id, or fail. The
# field id is part of the lookup because two fields on one board may well offer
# an option of the same name, and answering with whichever was read last would
# write the right value into the wrong field.
board_option_id() {
  local field=$1 want name id option
  want=$(norm_name "$2")
  while IFS=$TAB read -r id name option _; do
    [ "$id" = "$field" ] && [ "$name" = "$want" ] || continue
    printf '%s\n' "$option"
    return 0
  done <<< "$BOARD_OPTIONS"
  return 1
}

# board_field_options <field-name>: every option that field offers, in board
# order, one per line. Used only by the read-only `classifications` verb, so the
# vocabulary a caller must choose from comes from the board rather than from
# anything written down here.
board_field_options() {
  local field id name option raw
  field=$(board_field_id "$1") || return 1
  while IFS=$TAB read -r id name option raw; do
    [ "$id" = "$field" ] || continue
    [ -n "$option" ] || continue
    printf '%s\n' "${raw:-$name}"
  done <<< "$BOARD_OPTIONS"
  return 0
}

# Writing two single-select fields on one card is one request, not two. The CLI
# has no verb for it - `project item-edit` sets a single field - so a two-field
# write goes through GraphQL, where one document carries both mutations under
# aliases and GitHub applies them in order.
#
# That is what keeps the cost guard's promise through a second synchronized
# field: per-card requests are set by how many cards a cycle changes, never by
# how many fields each change touches. A one-field write stays on `project
# item-edit` exactly as it always was, so a board with no classification field
# configured makes precisely the calls it made before this existed.
# shellcheck disable=SC2016
BOARD_PAIR_MUTATION='mutation($project: ID!, $item: ID!, $fieldA: ID!, $optionA: String!, $fieldB: ID!, $optionB: String!) {
  a: updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $fieldA, value: {singleSelectOptionId: $optionA}}) {
    projectV2Item { id }
  }
  b: updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $fieldB, value: {singleSelectOptionId: $optionB}}) {
    projectV2Item { id }
  }
}'

# board_write_values <owner> <number> <item-id> <issue-url>
#                    <status-field|-> <column|-> <classify-field|-> <area|->
# Set the named values on one card in one request, whichever of the two are
# given. Any failing step returns non-zero so every write it was asked for stays
# outstanding; a partial success is not reported, because the caller's record
# has one confirmation per field and the next cycle reconciles whatever the
# board did not take.
board_write_values() {
  local owner=$1 number=$2 item_id=$3 issue=$4
  local status_field=$5 column=$6 classify_field=$7 area=$8
  local status_id='' status_option='' class_id='' class_option=''

  # Asked for nothing, so it reads nothing. A caller with no value to set never
  # pays even the id read.
  if [ "$column" = - ] && [ "$area" = - ]; then
    return 0
  fi
  board_ids "$owner" "$number" || return 1
  if [ "$column" != - ]; then
    status_id=$(board_field_id "$status_field") || {
      warn "project $owner/$number has no \"$status_field\" field"
      return 1
    }
    status_option=$(board_option_id "$status_id" "$column") || {
      warn "field \"$status_field\" has no \"$column\" option"
      return 1
    }
  fi
  if [ "$area" != - ]; then
    class_id=$(board_field_id "$classify_field") || {
      warn "project $owner/$number has no \"$classify_field\" field"
      return 1
    }
    class_option=$(board_option_id "$class_id" "$area") || {
      warn "field \"$classify_field\" has no \"$area\" option"
      return 1
    }
  fi

  if [ -n "$status_id" ] && [ -n "$class_id" ]; then
    "$GH" api graphql -f query="$BOARD_PAIR_MUTATION" \
      -f project="$BOARD_PROJECT_ID" -f item="$item_id" \
      -f fieldA="$status_id" -f optionA="$status_option" \
      -f fieldB="$class_id" -f optionB="$class_option" \
      >/dev/null </dev/null || {
      warn "could not set \"$column\" and \"$area\" on $issue"
      return 1
    }
    return 0
  fi
  if [ -n "$status_id" ]; then
    "$GH" project item-edit --id "$item_id" --project-id "$BOARD_PROJECT_ID" \
      --field-id "$status_id" --single-select-option-id "$status_option" \
      >/dev/null </dev/null || {
      warn "could not move $issue to \"$column\""
      return 1
    }
    return 0
  fi
  if [ -n "$class_id" ]; then
    "$GH" project item-edit --id "$item_id" --project-id "$BOARD_PROJECT_ID" \
      --field-id "$class_id" --single-select-option-id "$class_option" \
      >/dev/null </dev/null || {
      warn "could not set $issue to \"$area\""
      return 1
    }
    return 0
  fi
  return 0
}

# board_write_status <owner> <number> <status_field> <item-id> <issue-url> <option-name>
# For a caller that already holds the card's item id, which the board read hands
# it, and owes only the column.
board_write_status() {
  board_write_values "$1" "$2" "$4" "$5" "$3" "$6" - -
}

# board_set_values <owner> <number> <issue-url>
#                  <status-field|-> <column|-> <classify-field|-> <area|->
# For a caller that holds only the issue URL and has to find its card first.
# Two flat requests plus the write, none of them a board read, so this costs the
# same on a board of a thousand cards as on a board of ten - and the same
# whether it is setting one field or both.
board_set_values() {
  local owner=$1 number=$2 issue=$3
  local status_field=$4 column=$5 classify_field=$6 area=$7
  local card item_id observed_area
  card=$(board_card_values "$owner" "$number" "$issue" "$classify_field") || {
    warn "$issue is not a card on project $owner/$number"
    return 1
  }
  IFS=$TAB read -r item_id observed_area <<< "$card"
  if [ "$area" != - ]; then
    links_find issue "$issue" >/dev/null || return 1
    links_put "$LINK_PROJECT" "$issue" "$LINK_TASK" "$LINK_DESIRED" \
      "$LINK_SYNCED" "$LINK_PR" "$LINK_PR_SYNCED" "$area" "$observed_area"
  fi
  board_write_values "$owner" "$number" "$item_id" "$issue" \
    "$status_field" "$column" "$classify_field" "$area"
}

# board_set_status <owner> <number> <status_field> <issue-url> <option-name>
board_set_status() {
  board_set_values "$1" "$2" "$4" "$3" "$5" - -
}

# board_item_add <owner> <number> <issue-url>: card an issue and print the item
# id the add itself returned. The id is taken from the add's own answer and
# never by re-reading the board, because a freshly added card is not immediately
# visible in a board listing.
board_item_add() {
  local owner=$1 number=$2 issue=$3 id
  id=$("$GH" project item-add "$number" --owner "$owner" --url "$issue" \
    --format json --jq '.id' </dev/null) || {
    warn "could not add $issue to project $owner/$number"
    return 1
  }
  [ -n "$id" ] || {
    warn "adding $issue to project $owner/$number returned no card id"
    return 1
  }
  printf '%s\n' "$id"
}

# Every issue this adapter creates carries this marker line in its body, so an
# issue created moments before an interruption can be recognized rather than
# filed a second time.
MARKER_PREFIX='firstmate-task:'
# How far back the recovery scan looks. Deliberately shallow: the only gap it
# closes is an issue created seconds ago, which is necessarily among the newest.
MARKER_SCAN_LIMIT=30

issue_marker() {
  printf '%s %s\n' "$MARKER_PREFIX" "$1"
}

# issue_find_by_marker <repo> <task-id>: print the URL of a recent issue already
# carrying this task's marker, or fail. The match is made here rather than in the
# query so the scan stays one plain listing of recent issues.
issue_find_by_marker() {
  local repo=$1 task=$2 marker tmp url body found=
  marker=$(issue_marker "$task")
  tmp=$(mktemp) || return 1
  if "$GH" issue list --repo "$repo" --state all --limit "$MARKER_SCAN_LIMIT" \
    --json url,body \
    --jq '.[] | [(.url // ""), ((.body // "") | gsub("[\\n\\t\\r]+"; " "))] | @tsv' \
    > "$tmp" </dev/null; then
    while IFS=$TAB read -r url body; do
      case "$body" in
        *"$marker"*) ;;
        *) continue ;;
      esac
      found=$(issue_canonical "$url") || continue
      break
    done < "$tmp"
  else
    rm -f "$tmp"
    warn "could not read the recent issues of $repo"
    return 2
  fi
  rm -f "$tmp"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# issue_body <body> <task-id> <lands-in|->: the issue body actually filed.
issue_body() {
  local body=$1 task=$2 lands_in=$3 out=
  [ "$body" = - ] || out=$body
  if [ "$lands_in" != - ]; then
    out="${out:+$out

}Lands in: $lands_in"
  fi
  printf '%s\n' "${out:+$out

}$(issue_marker "$task")"
}

# issue_create <repo> <label> <title> <body> <parent|-> : print the new issue URL.
# A child is created as a native sub-issue in this same call, so a parent link is
# never a separate step that can be left half-done.
issue_create() {
  local repo=$1 label=$2 title=$3 body=$4 parent=$5
  local args url line
  args=(issue create --repo "$repo" --title "$title" --body "$body" --label "$label")
  [ "$parent" = - ] || args+=(--parent "$parent")
  url=''
  while IFS= read -r line; do
    case "$line" in
      https://*/issues/*) url=$line ;;
    esac
  done < <("$GH" "${args[@]}" </dev/null)
  [ -n "$url" ] || return 1
  issue_canonical "$url"
}

issue_parent_has_child() {
  local parent=$1 child=$2 repo number tmp url found=1
  repo=$(issue_repo "$parent")
  number=${parent##*/}
  tmp=$(mktemp) || return 2
  if ! "$GH" api "repos/$repo/issues/$number/sub_issues" --paginate \
    --jq '.[].html_url' > "$tmp" </dev/null; then
    rm -f "$tmp"
    return 2
  fi
  while IFS= read -r url; do
    url=$(issue_canonical "$url") || continue
    if [ "$url" = "$child" ]; then
      found=0
      break
    fi
  done < "$tmp"
  rm -f "$tmp"
  return "$found"
}

# issue_sub_issues <parent-issue-url> <outfile>: write one `url<TAB>state` line
# per sub-issue GitHub records under that parent. Returns non-zero when the read
# did not land, which is what lets a caller tell "this container has no children"
# apart from "this container's children could not be read".
#
# Membership and state authority are defined in PARENT STATUS above.
issue_sub_issues() {
  local parent=$1 out=$2 repo number
  repo=$(issue_repo "$parent")
  number=${parent##*/}
  "$GH" api "repos/$repo/issues/$number/sub_issues" --paginate \
    --jq '.[] | [.html_url, .state] | @tsv' > "$out" </dev/null || return 1
}

issue_parent_ensure() {
  local parent=$1 child=$2 child_repo child_number child_id rc=0
  issue_parent_has_child "$parent" "$child" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) ;;
    *)
      warn "could not read the sub-issues of $parent"
      return 1
      ;;
  esac
  child_repo=$(issue_repo "$child")
  child_number=${child##*/}
  child_id=$("$GH" api "repos/$child_repo/issues/$child_number" --jq '.id' </dev/null) || {
    warn "could not resolve $child before attaching it to $parent"
    return 1
  }
  [ -n "$child_id" ] || {
    warn "resolving $child returned no issue id"
    return 1
  }
  if "$GH" api "repos/$(issue_repo "$parent")/issues/${parent##*/}/sub_issues" \
    --method POST -F "sub_issue_id=$child_id" >/dev/null </dev/null; then
    return 0
  fi
  if issue_parent_has_child "$parent" "$child"; then
    return 0
  fi
  warn "could not attach $child to $parent"
  return 1
}

# board_comment <issue-url> <body>
# Runs from inside poll's item loop, so it never inherits the board read on
# stdin.
board_comment() {
  "$GH" issue comment "$1" --body "$2" >/dev/null </dev/null || {
    warn "could not comment on $1"
    return 1
  }
  return 0
}

# --- state vocabulary -------------------------------------------------------
#
# Todo, In Progress, and Done are always drivable, and the configured optional
# processed and queued columns join them. Firstmate writes all five from its own
# records. A column that is none of them is read as "other": the adapter neither
# drives it nor pretends to understand it, and a card sitting in one diverges
# from what firstmate recorded.

state_column() {
  local state=$1 todo=$2 in_progress=$3 done_col=$4 queued=${5:--} processed=${6:--}
  case "$state" in
    todo) printf '%s\n' "$todo" ;;
    in-progress) printf '%s\n' "$in_progress" ;;
    done) printf '%s\n' "$done_col" ;;
    queued)
      [ "$queued" != - ] || return 1
      printf '%s\n' "$queued"
      ;;
    processed)
      [ "$processed" != - ] || return 1
      printf '%s\n' "$processed"
      ;;
    *) return 1 ;;
  esac
}

column_state() {
  local raw=$1 todo=$2 in_progress=$3 done_col=$4 queued=${5:--} processed=${6:--} want
  want=$(norm_name "$raw")
  if [ "$want" = "$(norm_name "$todo")" ]; then
    printf 'todo\n'
  elif [ "$want" = "$(norm_name "$in_progress")" ]; then
    printf 'in-progress\n'
  elif [ "$want" = "$(norm_name "$done_col")" ]; then
    printf 'done\n'
  elif [ "$queued" != - ] && [ "$want" = "$(norm_name "$queued")" ]; then
    printf 'queued\n'
  elif [ "$processed" != - ] && [ "$want" = "$(norm_name "$processed")" ]; then
    printf 'processed\n'
  else
    printf 'other\n'
  fi
}

# Work firstmate itself files, and work it internalizes out of the captain's
# inbox, are both already internalized by the time their card is written, so
# they belong in the Processed column rather than in the inbox. A board with no
# `processed` key has no such column, and both fall back to Todo exactly as they
# did before the key existed.

board_entry_state() {
  if [ "${1:--}" = - ]; then
    printf 'todo\n'
  else
    printf 'processed\n'
  fi
}

# board_entry_column <todo-column> <processed-column>
board_entry_column() {
  if [ "${2:--}" = - ]; then
    printf '%s\n' "$1"
  else
    printf '%s\n' "$2"
  fi
}

# Work the captain has already cleared to launch enters in the cleared state, so
# that fact reaches the board from the command that already knows it rather than
# from a second command someone has to remember. It is stated per call and never
# inferred from the absence of a hold, from the task existing, or from any other
# proxy: filing a card is not by itself the captain's go, so an unstated call
# still enters internalized exactly as it did before the flag existed.
#
# A board with no `queued` key has no column for it, so the cleared state falls
# back through internalized to the inbox exactly as internalized falls back on
# its own. The caller is told which state was filed rather than left to assume,
# which is what keeps a fact the board cannot show visible instead of silent.

# place_entry_state <cleared> <queued-column> <processed-column>
place_entry_state() {
  local cleared=${1:-0} queued=${2:--} processed=${3:--}
  if [ "$cleared" = 1 ] && [ "$queued" != - ]; then
    printf 'queued\n'
  else
    board_entry_state "$processed"
  fi
}

# place_entry_column <state> <todo-column> <queued-column> <processed-column>
place_entry_column() {
  local state=$1 todo=$2 queued=$3 processed=$4
  if [ "$state" = queued ]; then
    printf '%s\n' "$queued"
  else
    board_entry_column "$todo" "$processed"
  fi
}

# The big-picture columns carry three states of their own, on a parallel set of
# column names. They are the container lane, never extra execution states, and
# `todo` names the lane's first column whatever the board calls it.

bp_state_column() {
  local state=$1 bp_todo=$2 bp_in_progress=$3 bp_done=$4
  case "$state" in
    todo) printf '%s\n' "$bp_todo" ;;
    in-progress) printf '%s\n' "$bp_in_progress" ;;
    done) printf '%s\n' "$bp_done" ;;
    *) return 1 ;;
  esac
}

# bp_column_state <raw> <bp_todo> <bp_in_progress> <bp_done>: the container state
# that column names, or nothing at all when it names no big-picture column.
bp_column_state() {
  local raw=$1 bp_todo=$2 bp_in_progress=$3 bp_done=$4 want
  [ "$bp_todo" != - ] || return 1
  want=$(norm_name "$raw")
  if [ "$want" = "$(norm_name "$bp_todo")" ]; then
    printf 'todo\n'
  elif [ "$want" = "$(norm_name "$bp_in_progress")" ]; then
    printf 'in-progress\n'
  elif [ "$want" = "$(norm_name "$bp_done")" ]; then
    printf 'done\n'
  else
    return 1
  fi
}

# THE CLASSIFICATION A CALL STATES.
#
# A board that configures a classification field expects the work firstmate
# files or takes in to arrive carrying one, in the same call that creates the
# card rather than in a second one someone has to remember. So the choice is
# stated per call and is never inferred from a title, a label, a repository, or
# any other proxy: which area a piece of work belongs to is a judgement, and an
# adapter that guessed it would be wrong quietly and at scale.
#
# Blank stays reachable, because genuine ambiguity is a real answer, but only by
# saying so. `--unclassified` is that word. Omitting both is refused rather than
# defaulted, which is the whole difference between a card left blank because the
# classification is genuinely open and one left blank for convenience.
#
# A board with no classification field configured has nothing to classify into,
# so `--area` there is a caller believing in a field the board does not have and
# is refused. `--unclassified` is not: it states the absence of a classification,
# which is simply true on such a board.
#
# The answer is left in BOARD_AREA rather than printed. A refusal here has to
# stop the command, and `die` inside a command substitution exits only that
# subshell, which a caller using `||` would swallow into an empty value and
# carry on from.
#
# board_area_resolve <project> <classify-field> <area> <unclassified>
BOARD_AREA=-
board_area_resolve() {
  local project=$1 field=$2 area=$3 unclassified=$4
  BOARD_AREA=-
  if [ "$field" = - ]; then
    [ "$area" = - ] \
      || die "board \"$project\" configures no classification field, so --area has nothing to set"
    return 0
  fi
  if [ "$unclassified" = 1 ]; then
    [ "$area" = - ] || die "--area and --unclassified contradict each other; state one"
    return 0
  fi
  [ "$area" != - ] \
    || die "board \"$project\" classifies its cards in the \"$field\" field, so state the area with --area <name>, or --unclassified when the classification is genuinely ambiguous"
  BOARD_AREA=$area
  return 0
}

# board_area_report <classify-field> <area>: the trailing token a caller appends
# to a record line, and nothing at all on a board that classifies nothing - so
# every line an unconfigured home has ever printed is unchanged.
board_area_report() {
  [ "${1:--}" != - ] || return 0
  if [ "${2:--}" = - ]; then
    printf ' unclassified'
  else
    printf ' %s' "$2"
  fi
}

# text_has <haystack> <needle>: normalized substring test.
text_has() {
  local hay needle
  hay=$(norm_name "$1")
  needle=$(norm_name "$2")
  case "$hay" in
    *"$needle"*) return 0 ;;
  esac
  return 1
}

# list_has <comma-list> <needle>: normalized membership test.
list_has() {
  local list needle
  list=",$(norm_name "$1"),"
  needle=",$(norm_name "$2"),"
  case "$list" in
    *"$needle"*) return 0 ;;
  esac
  return 1
}

# --- verbs ------------------------------------------------------------------

cmd_boards() {
  local want=${1:-} project owner number repo label mention assignee
  local status_field todo in_progress done_col bp_todo bp_in_progress bp_done
  local queued processed classify_field big
  while IFS=$'\t' read -r project owner number repo label mention assignee \
    status_field todo in_progress done_col bp_todo bp_in_progress bp_done \
    queued processed classify_field; do
    [ -n "$project" ] || continue
    if [ -n "$want" ] && [ "$want" != "$project" ]; then
      continue
    fi
    if [ "$bp_todo" = - ]; then
      big=off
    else
      big="$bp_todo|$bp_in_progress|$bp_done"
    fi
    printf 'board %s %s/%s repo=%s label=%s mention=%s assignee=%s field=%s columns=%s|%s|%s processed=%s queued=%s big-picture=%s classify=%s\n' \
      "$project" "$owner" "$number" "$repo" "$label" "$mention" "$assignee" \
      "$status_field" "$todo" "$in_progress" "$done_col" "$processed" \
      "$queued" "$big" "${classify_field:--}"
  done < <(boards_rows)
}

cmd_links() {
  local want=${1:-} row
  while IFS= read -r row; do
    if [ -n "$want" ]; then
      case "$row" in
        "$want$TAB"*) ;;
        *) continue ;;
      esac
    fi
    printf '%s\n' "$row"
  done < <(links_rows)
}

cmd_lookup() {
  local want=${1:?usage: fm-board.sh lookup <issue-url|task-id>} canonical
  if canonical=$(issue_canonical "$want"); then
    links_find issue "$canonical" || return 1
  else
    links_find task "$want" || return 1
  fi
}

IMPORT_USAGE='usage: fm-board.sh import <project> <issue-url> <task-id> [--area <name> | --unclassified]'

cmd_import() {
  local project='' raw_issue='' task='' area=- unclassified=0
  local issue board owner number repo status_field todo processed classify_field
  local entry entry_column

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --area)
        [ "$#" -gt 1 ] || die "--area needs a value"
        area=$2
        shift 2
        ;;
      --area=*)
        area=${1#--area=}
        shift
        ;;
      --unclassified)
        unclassified=1
        shift
        ;;
      -*) die "unknown option \"$1\"" ;;
      *)
        if [ -z "$project" ]; then
          project=$1
        elif [ -z "$raw_issue" ]; then
          raw_issue=$1
        elif [ -z "$task" ]; then
          task=$1
        else
          die "$IMPORT_USAGE"
        fi
        shift
        ;;
    esac
  done
  if [ -z "$project" ] || [ -z "$raw_issue" ] || [ -z "$task" ]; then
    die "$IMPORT_USAGE"
  fi

  board=$(board_for "$project")
  owner=$(printf '%s' "$board" | cut -f2)
  number=$(printf '%s' "$board" | cut -f3)
  repo=$(printf '%s' "$board" | cut -f4)
  status_field=$(printf '%s' "$board" | cut -f8)
  todo=$(printf '%s' "$board" | cut -f9)
  processed=$(printf '%s' "$board" | cut -f16)
  classify_field=$(printf '%s' "$board" | cut -f17)
  issue=$(issue_canonical "$raw_issue") || die "\"$raw_issue\" is not an issue URL"
  task_id_valid "$task" || die "\"$task\" is not a task id"
  board_area_resolve "$project" "$classify_field" "$area" "$unclassified"
  area=$BOARD_AREA
  if [ "$repo" != - ] && [ "$(issue_repo "$issue")" != "$repo" ]; then
    die "$issue is not in $repo, the repo configured for board \"$project\""
  fi

  # A container's children are the real work, so the container itself must never
  # spend the one binding an issue has. With poll never offering a big-picture
  # card for import, this closes the other direction.
  if decomps_find "$issue" >/dev/null; then
    die "$issue is a decomposition container on board \"$DECOMP_PROJECT\"; its children hold the work" 3
  fi
  # This duplicate check is deliberately fleet-wide rather than scoped to one
  # board: an issue holds at most one task no matter which board carries it.
  if links_find issue "$issue" >/dev/null; then
    if [ "$LINK_TASK" = "$task" ]; then
      printf 'already-linked %s %s %s\n' "$project" "$issue" "$task"
      return 0
    fi
    die "$issue is already linked to task $LINK_TASK; refusing to relink it to $task" 3
  fi
  if links_find task "$task" >/dev/null; then
    die "task $task is already linked to $LINK_ISSUE" 3
  fi

  # Internalizing is what moves the card out of the captain's inbox, and it is
  # written the moment the record supports it rather than deferred to the next
  # cycle. That is what keeps a card still sitting in Todo honest signal that
  # firstmate has not picked it up yet. A move that does not land leaves an
  # ordinary outstanding write for `poll` to retry.
  #
  # A board with no internalized column has nowhere to move the card to, so it
  # owes no column write at all; the classification is what may still be owed,
  # and the two travel together in the one request below rather than each
  # costing its own. With neither owed the link is the whole of the import and
  # no board is touched, exactly as it never was.
  entry=$(board_entry_state "$processed")
  entry_column=-
  [ "$entry" = todo ] || entry_column=$(board_entry_column "$todo" "$processed")
  if [ "$entry_column" = - ] && [ "$area" = - ]; then
    links_put "$project" "$issue" "$task" todo todo - - - -
    printf 'linked %s %s %s%s\n' "$project" "$issue" "$task" \
      "$(board_area_report "$classify_field" -)"
    return 0
  fi

  links_put "$project" "$issue" "$task" "$entry" todo - - "$area" -
  if board_set_values "$owner" "$number" "$issue" \
    "$status_field" "$entry_column" "$classify_field" "$area"; then
    links_put "$project" "$issue" "$task" "$entry" "$entry" - - "$area" "$area"
    printf 'linked %s %s %s %s%s\n' "$project" "$issue" "$task" "$entry" \
      "$(board_area_report "$classify_field" "$area")"
  else
    printf 'linked-stale %s %s %s %s%s\n' "$project" "$issue" "$task" "$entry" \
      "$(board_area_report "$classify_field" "$area")"
  fi
  return 0
}

# --- shared placement -------------------------------------------------------
#
# `place` and `child-add` are one operation with different parents, so they run
# the same two steps here rather than two implementations that can drift.

CARD_STEP=

# card_ensure <project> <owner> <number> <status_field> <state> <column> <issue>
#             <task> <classify-field|-> <area|->
# Card the issue, record the issue-to-task link, and set it to the column work
# firstmate itself files belongs in. The link is written the moment the card
# exists so the next cycle can never offer it as new work, and its `synced` stays
# unconfirmed until the column write lands, which leaves poll's ordinary
# outstanding-write retry to finish it.
#
# This is the boundary every binding route passes through, so it is where the
# bind side of the one-way door is shut: a container ships nothing, so an issue
# that already holds a decomposition record can never be given the one binding it
# has. The refusal is made before the board is touched, so a refused call leaves
# no card behind and a board write that fails stays as fail-soft as it ever was.
card_ensure() {
  local project=$1 owner=$2 number=$3 status_field=$4 state=$5 column=$6
  local issue=$7 task=$8 classify_field=${9:--} area=${10:--}
  local item_id pr=- pr_synced=-
  CARD_STEP=
  if decomps_find "$issue" >/dev/null; then
    die "$issue is a decomposition container on board \"$DECOMP_PROJECT\"; its children hold the work, so it can never bind task $task" 3
  fi
  item_id=$(board_item_add "$owner" "$number" "$issue") || {
    CARD_STEP=card
    return 1
  }
  if links_find issue "$issue" >/dev/null; then
    pr=$LINK_PR
    pr_synced=$LINK_PR_SYNCED
  fi
  links_put "$project" "$issue" "$task" "$state" other "$pr" "$pr_synced" "$area" -
  # Both fields share one request after card creation, but the aliased
  # mutations are not atomic. The durable record lets poll reconcile a
  # failed or partially applied write without another placement call.
  if ! board_write_values "$owner" "$number" "$item_id" "$issue" \
    "$status_field" "$column" "$classify_field" "$area"; then
    CARD_STEP=status
    return 1
  fi
  links_put "$project" "$issue" "$task" "$state" "$state" "$pr" "$pr_synced" \
    "$area" "$area"
  return 0
}

# issue_ensure <repo> <label> <title> <body> <task> <parent|-> <known-url|->
# Print the issue that carries this task's work, creating it only when neither
# the caller's own record nor a shallow scan of the repo's newest issues already
# holds one. A scan that cannot run stops the command instead of creating, so a
# transient read failure can never file the same work twice.
issue_ensure() {
  local repo=$1 label=$2 title=$3 body=$4 task=$5 parent=$6 known=$7 url rc=0
  if [ "$known" != - ]; then
    printf '%s\n' "$known"
    return 0
  fi
  url=$(issue_find_by_marker "$repo" "$task") || rc=$?
  case "$rc" in
    0)
      if [ "$parent" != - ] && ! issue_parent_ensure "$parent" "$url"; then
        return 1
      fi
      printf '%s\n' "$url"
      return 0
      ;;
    # A scan that could not run is not the same answer as one that found
    # nothing, so it refuses rather than risk filing a second issue.
    1) ;;
    *) return 1 ;;
  esac
  issue_create "$repo" "$label" "$title" "$body" "$parent"
}

PLACE_USAGE='usage: fm-board.sh place <project> <task-id> <title> [<body>] [--lands-in <owner/name>] [--parent <issue-url>] [--cleared] [--area <name> | --unclassified]'
CHILD_ADD_USAGE='usage: fm-board.sh child-add <project> <parent-issue-url> <title> <body> <task-id> [--area <name> | --unclassified]'

# `place` and `child-add` are one operation with different parents and different
# vocabulary, so they run one implementation from here rather than two that can
# drift. Callers read the outcome from these.
PLACE_ISSUE=- PLACE_PROJECT=- PLACE_STATE=- PLACE_REPO=- PLACE_STEP=
PLACE_AREA=- PLACE_FIELD=-

# container_open <project> <parent-issue> <require-recorded>
# Settle the container a child is being filed under, leaving its record in the
# DECOMP_ variables and defaulting one this project has not recorded yet. Every
# way the parent can be wrong is refused rather than degraded: a parent that
# already holds a task is ordinary work, and a parent another board owns stays
# that board's.
#
# With <require-recorded> set the parent must already be a recorded container,
# which is what stops `place --parent` becoming a second route by which an
# unjudged issue silently turns into one. `poll` first-sighting a card in the
# container lane and `promote` remain the only two, so the container-or-task
# judgement is still made exactly where it always was.
container_open() {
  local project=$1 parent=$2 require=$3
  if links_find issue "$parent" >/dev/null; then
    die "$parent is linked to task $LINK_TASK, so it is ordinary work rather than a container" 3
  fi
  if decomps_find "$parent" >/dev/null; then
    [ "$DECOMP_PROJECT" = "$project" ] \
      || die "$parent is already decomposed under project $DECOMP_PROJECT" 3
    return 0
  fi
  [ "$require" != 1 ] \
    || die "$parent is not a recorded container on board \"$project\"; poll the board or promote it before filing work under it" 3
  decomp_clear
  DECOMP_PROJECT=$project
  DECOMP_PARENT=$parent
  DECOMP_STATE=open
  return 0
}

# place_bind <board-row> <task> <title> <body> <lands-in|-> <parent|-> <cleared>
#            <require-recorded-container> <area|-> <unclassified>
# File the issue, card it in the column its entry state names, and record the
# link. With a parent it also creates the issue as a native GitHub sub-issue and
# records the child against that container in the same call, so work attached
# this way feeds exactly the books PARENT STATUS derives from rather than a
# second set.
#
# Returns 0 placed; 1 with the card write still outstanding and PLACE_STEP naming
# the step that did not land; 2 already bound, with PLACE_ISSUE and PLACE_PROJECT
# naming what it is bound to; and 3 for an issue that could not be created. Every
# refusal exits from here rather than returning, so no caller can report one as a
# soft outcome.
place_bind() {
  local board=$1 task=$2 title=$3 body=$4 lands_in=$5 parent=$6 cleared=$7 require=$8
  local area=${9:--} unclassified=${10:-0}
  local project owner number repo label status_field todo bp_todo queued processed
  local classify_field children known column issue

  project=$(printf '%s' "$board" | cut -f1)
  owner=$(printf '%s' "$board" | cut -f2)
  number=$(printf '%s' "$board" | cut -f3)
  repo=$(printf '%s' "$board" | cut -f4)
  label=$(printf '%s' "$board" | cut -f5)
  status_field=$(printf '%s' "$board" | cut -f8)
  todo=$(printf '%s' "$board" | cut -f9)
  bp_todo=$(printf '%s' "$board" | cut -f12)
  queued=$(printf '%s' "$board" | cut -f15)
  processed=$(printf '%s' "$board" | cut -f16)
  classify_field=$(printf '%s' "$board" | cut -f17)

  PLACE_ISSUE=- PLACE_PROJECT=$project PLACE_REPO=$repo PLACE_STEP=
  PLACE_FIELD=$classify_field
  board_area_resolve "$project" "$classify_field" "$area" "$unclassified"
  PLACE_AREA=$BOARD_AREA
  PLACE_STATE=$(place_entry_state "$cleared" "$queued" "$processed")
  children=- known=-
  if [ "$parent" != - ]; then
    [ "$bp_todo" != - ] \
      || die "board \"$project\" has no big-picture columns configured, so it has no containers to decompose"
    container_open "$project" "$parent" "$require"
    children=$DECOMP_CHILDREN
    known=$(children_child_for "$children" "$task") || known=-
    [ "$repo" != - ] || repo=$(issue_repo "$parent")
    PLACE_REPO=$repo
  fi

  # A task that already holds a link is finished, and says so without a single
  # network call: the link is written last precisely so that holding one proves
  # every earlier step landed. Under a parent it has to be that container's own
  # recorded child, because an issue's one binding is permanent and re-parenting
  # a bound issue is not this command's to do - so that case is refused rather
  # than reported as already done over the top of it.
  if links_find task "$task" >/dev/null; then
    PLACE_ISSUE=$LINK_ISSUE
    PLACE_PROJECT=$LINK_PROJECT
    if [ "$parent" = - ] || [ "$known" = "$LINK_ISSUE" ]; then
      return 2
    fi
    die "task $task is already linked to $LINK_ISSUE, which $parent does not record as a child" 3
  fi
  [ "$repo" != - ] \
    || die "board \"$project\" has no repo key, so there is no repository to file a card in"

  issue=$(issue_ensure "$repo" "$label" "$title" \
    "$(issue_body "$body" "$task" "$lands_in")" "$task" "$parent" "$known") || return 3
  PLACE_ISSUE=$issue
  if [ "$parent" != - ]; then
    # Recorded against the container the instant the child exists, so a run
    # interrupted before the card lands is resumed rather than repeated, and the
    # derived parent status carries the child from that same instant.
    children=$(children_add "$children" "$task" "$issue")
    decomps_put "$project" "$parent" "$DECOMP_STATE" "$DECOMP_DESIRED" \
      "$DECOMP_SYNCED" "$children"
  fi
  column=$(place_entry_column "$PLACE_STATE" "$todo" "$queued" "$processed")
  if card_ensure "$project" "$owner" "$number" "$status_field" "$PLACE_STATE" \
    "$column" "$issue" "$task" "$classify_field" "$PLACE_AREA"; then
    return 0
  fi
  PLACE_STEP=$CARD_STEP
  return 1
}

cmd_place() {
  local project='' task='' title='' body=- lands_in=- raw_parent=- parent=- cleared=0
  local area=- unclassified=0
  local board rc=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --area)
        [ "$#" -gt 1 ] || die "--area needs a value"
        area=$2
        shift 2
        ;;
      --area=*)
        area=${1#--area=}
        shift
        ;;
      --unclassified)
        unclassified=1
        shift
        ;;
      --lands-in)
        [ "$#" -gt 1 ] || die "--lands-in needs a value"
        lands_in=$2
        shift 2
        ;;
      --lands-in=*)
        lands_in=${1#--lands-in=}
        shift
        ;;
      --parent)
        [ "$#" -gt 1 ] || die "--parent needs a value"
        raw_parent=$2
        shift 2
        ;;
      --parent=*)
        raw_parent=${1#--parent=}
        shift
        ;;
      --cleared)
        cleared=1
        shift
        ;;
      -*) die "unknown option \"$1\"" ;;
      *)
        if [ -z "$project" ]; then
          project=$1
        elif [ -z "$task" ]; then
          task=$1
        elif [ -z "$title" ]; then
          title=$1
        elif [ "$body" = - ]; then
          body=$1
        else
          die "$PLACE_USAGE"
        fi
        shift
        ;;
    esac
  done
  if [ -z "$project" ] || [ -z "$task" ] || [ -z "$title" ]; then
    die "$PLACE_USAGE"
  fi
  task_id_valid "$task" || die "\"$task\" is not a task id"
  if [ "$lands_in" != - ]; then
    case "$lands_in" in
      */*/* | */ | /* | *' '*) die "--lands-in \"$lands_in\" is not owner/name" ;;
      */*) ;;
      *) die "--lands-in \"$lands_in\" is not owner/name" ;;
    esac
  fi
  if [ "$raw_parent" != - ]; then
    parent=$(issue_canonical "$raw_parent") || die "--parent \"$raw_parent\" is not an issue URL"
  fi

  board=$(board_for "$project")
  place_bind "$board" "$task" "$title" "$body" "$lands_in" "$parent" "$cleared" 1 \
    "$area" "$unclassified" || rc=$?
  case "$rc" in
    0)
      printf 'placed %s %s %s %s%s\n' "$project" "$PLACE_ISSUE" "$task" \
        "$PLACE_STATE" "$(board_area_report "$PLACE_FIELD" "$PLACE_AREA")"
      ;;
    1)
      printf 'placed-partial %s %s %s %s %s%s\n' \
        "$project" "$PLACE_ISSUE" "$task" "$PLACE_STATE" "$PLACE_STEP" \
        "$(board_area_report "$PLACE_FIELD" "$PLACE_AREA")"
      ;;
    2) printf 'already-placed %s %s %s\n' "$PLACE_PROJECT" "$PLACE_ISSUE" "$task" ;;
    *)
      printf 'error: could not create the issue for task %s in %s\n' "$task" "$PLACE_REPO" >&2
      return 1
      ;;
  esac
  return 0
}

cmd_child_add() {
  local project='' raw_parent='' title='' body='' task='' area=- unclassified=0
  local board parent rc=0 positional=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --area)
        [ "$#" -gt 1 ] || die "--area needs a value"
        area=$2
        shift 2
        ;;
      --area=*)
        area=${1#--area=}
        shift
        ;;
      --unclassified)
        unclassified=1
        shift
        ;;
      -*) die "unknown option \"$1\"" ;;
      *)
        positional=$((positional + 1))
        case "$positional" in
          1) project=$1 ;;
          2) raw_parent=$1 ;;
          3) title=$1 ;;
          4) body=$1 ;;
          5) task=$1 ;;
          *) die "$CHILD_ADD_USAGE" ;;
        esac
        shift
        ;;
    esac
  done
  [ "$positional" = 5 ] || die "$CHILD_ADD_USAGE"

  board=$(board_for "$project")
  parent=$(issue_canonical "$raw_parent") || die "\"$raw_parent\" is not an issue URL"
  task_id_valid "$task" || die "\"$task\" is not a task id"
  # A container the board itself has never shown is still broken down here, so
  # this route defaults the record rather than requiring one.
  place_bind "$board" "$task" "$title" "$body" - "$parent" 0 0 \
    "$area" "$unclassified" || rc=$?
  case "$rc" in
    0)
      printf 'child %s %s %s %s%s\n' "$project" "$parent" "$PLACE_ISSUE" "$task" \
        "$(board_area_report "$PLACE_FIELD" "$PLACE_AREA")"
      ;;
    1)
      printf 'child-partial %s %s %s %s %s%s\n' \
        "$project" "$parent" "$PLACE_ISSUE" "$task" "$PLACE_STEP" \
        "$(board_area_report "$PLACE_FIELD" "$PLACE_AREA")"
      ;;
    2) printf 'already-child %s %s %s %s\n' "$project" "$parent" "$PLACE_ISSUE" "$task" ;;
    *)
      printf 'error: could not create the child issue for task %s under %s\n' \
        "$task" "$parent" >&2
      return 1
      ;;
  esac
  return 0
}

PROMOTE_USAGE='usage: fm-board.sh promote <project> <issue-url>'

# Firstmate's own judgement that a card the captain filed as ordinary work is a
# programme rather than one shippable task: the card moves into the container
# lane and its durable record opens, after which `child-add` generates the
# children exactly as it does for a container the captain filed.
#
# This verb is where the one-way door is enforced, and it is enforced two ways
# at once. It takes no task id, so there is no parameter with which it could
# spend the issue's single binding however it is called; and it refuses an issue
# that already holds a link, so an already-bound issue can never become a
# container by this route or any future one. The judgement has to be made before
# anything binds, because a container that already spent its binding is
# recoverable only by abandoning that issue and filing a fresh one.
cmd_promote() {
  local project='' raw=''
  local board owner number repo status_field bp_todo bp_in_progress bp_done
  local issue desired synced children column

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -*) die "unknown option \"$1\"" ;;
      *)
        if [ -z "$project" ]; then
          project=$1
        elif [ -z "$raw" ]; then
          raw=$1
        else
          die "$PROMOTE_USAGE"
        fi
        shift
        ;;
    esac
  done
  if [ -z "$project" ] || [ -z "$raw" ]; then
    die "$PROMOTE_USAGE"
  fi

  board=$(board_for "$project")
  owner=$(printf '%s' "$board" | cut -f2)
  number=$(printf '%s' "$board" | cut -f3)
  repo=$(printf '%s' "$board" | cut -f4)
  status_field=$(printf '%s' "$board" | cut -f8)
  bp_todo=$(printf '%s' "$board" | cut -f12)
  bp_in_progress=$(printf '%s' "$board" | cut -f13)
  bp_done=$(printf '%s' "$board" | cut -f14)
  [ "$bp_todo" != - ] \
    || die "board \"$project\" has no big-picture columns configured, so it has no container lane to promote into"
  issue=$(issue_canonical "$raw") || die "\"$raw\" is not an issue URL"
  if [ "$repo" != - ] && [ "$(issue_repo "$issue")" != "$repo" ]; then
    die "$issue is not in $repo, the repo configured for board \"$project\""
  fi

  # THE ONE-WAY DOOR. A container ships nothing, so it must never hold the one
  # binding an issue has; an issue that already holds one is past the point where
  # this judgement could still be made.
  if links_find issue "$issue" >/dev/null; then
    die "$issue is already linked to task $LINK_TASK, so it is ordinary work rather than a programme; a bound issue can never become a container" 3
  fi

  desired=- synced=- children=-
  if decomps_find "$issue" >/dev/null; then
    [ "$DECOMP_PROJECT" = "$project" ] \
      || die "$issue is already a container under project $DECOMP_PROJECT" 3
    if [ "$DECOMP_STATE" = 'done' ]; then
      printf 'already-promoted %s %s\n' "$project" "$issue"
      return 0
    fi
    desired=$DECOMP_DESIRED
    synced=$DECOMP_SYNCED
    children=$DECOMP_CHILDREN
  fi
  # A promoted container belongs in the container lane's first column, unless
  # children it already has derived somewhere further along.
  [ "$desired" != - ] || desired=todo

  # Recorded before the board is touched, so every refusal above holds from this
  # instant even when the move does not land; the move is then an ordinary
  # outstanding write that `poll` retries.
  decomps_put "$project" "$issue" promoted "$desired" "$synced" "$children"
  column=$(bp_state_column "$desired" "$bp_todo" "$bp_in_progress" "$bp_done") \
    || die "board \"$project\" has no big-picture column for \"$desired\""
  if board_set_status "$owner" "$number" "$status_field" "$issue" "$column"; then
    decomps_put "$project" "$issue" promoted "$desired" "$desired" "$children"
    printf 'promoted %s %s\n' "$project" "$issue"
  else
    printf 'promoted-partial %s %s\n' "$project" "$issue"
  fi
  return 0
}

cmd_decomposed() {
  local project=${1:?usage: fm-board.sh decomposed <project> <parent-issue-url>}
  local raw_parent=${2:?usage: fm-board.sh decomposed <project> <parent-issue-url>}
  local parent
  board_for "$project" >/dev/null
  parent=$(issue_canonical "$raw_parent") || die "\"$raw_parent\" is not an issue URL"
  # Closing a container is the other way a container record is written, so it
  # refuses a bound issue exactly as `child-add` and `promote` do.
  if links_find issue "$parent" >/dev/null; then
    die "$parent is linked to task $LINK_TASK, so it is ordinary work rather than a container" 3
  fi
  if decomps_find "$parent" >/dev/null; then
    [ "$DECOMP_PROJECT" = "$project" ] \
      || die "$parent is decomposed under project $DECOMP_PROJECT" 3
    decomps_put "$project" "$parent" 'done' "$DECOMP_DESIRED" \
      "$DECOMP_SYNCED" "$DECOMP_CHILDREN"
  else
    decomps_put "$project" "$parent" 'done' - - -
  fi
  printf 'decomposed %s %s\n' "$project" "$parent"
}

cmd_decompositions() {
  local want=${1:-} row
  while IFS= read -r row; do
    if [ -n "$want" ]; then
      case "$row" in
        "$want$TAB"*) ;;
        *) continue ;;
      esac
    fi
    printf '%s\n' "$row"
  done < <(decomps_rows)
}

cmd_mark() {
  local task='' state=''
  local project issue synced pr pr_synced area area_synced board
  local owner number status_field todo in_progress done_col queued processed column

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -*) die "unknown option \"$1\"" ;;
      *)
        if [ -z "$task" ]; then
          task=$1
        elif [ -z "$state" ]; then
          state=$1
        else
          die "$MARK_USAGE"
        fi
        shift
        ;;
    esac
  done
  if [ -z "$task" ] || [ -z "$state" ]; then
    die "$MARK_USAGE"
  fi
  case "$state" in
    todo | in-progress | 'done') ;;
    queued | processed) ;;
    *) die "unknown board state \"$state\" (use todo, processed, queued, in-progress, or done)" ;;
  esac
  links_find task "$task" >/dev/null || die "task $task is not linked to a board issue"
  project=$LINK_PROJECT
  issue=$LINK_ISSUE
  synced=$LINK_SYNCED
  pr=$LINK_PR
  pr_synced=$LINK_PR_SYNCED
  area=$LINK_AREA
  area_synced=$LINK_AREA_SYNCED
  board=$(board_for "$project")
  owner=$(printf '%s' "$board" | cut -f2)
  number=$(printf '%s' "$board" | cut -f3)
  status_field=$(printf '%s' "$board" | cut -f8)
  todo=$(printf '%s' "$board" | cut -f9)
  in_progress=$(printf '%s' "$board" | cut -f10)
  done_col=$(printf '%s' "$board" | cut -f11)
  queued=$(printf '%s' "$board" | cut -f15)
  processed=$(printf '%s' "$board" | cut -f16)
  column=$(state_column "$state" "$todo" "$in_progress" "$done_col" "$queued" "$processed") \
    || die "board \"$project\" has no $state column configured"

  links_put "$project" "$issue" "$task" "$state" "$synced" "$pr" "$pr_synced" \
    "$area" "$area_synced"
  if board_set_status "$owner" "$number" "$status_field" "$issue" "$column"; then
    links_put "$project" "$issue" "$task" "$state" "$state" "$pr" "$pr_synced" \
      "$area" "$area_synced"
    printf 'synced %s %s %s %s\n' "$project" "$issue" "$task" "$state"
  else
    printf 'stale %s %s %s %s\n' "$project" "$issue" "$task" "$state"
  fi
  return 0
}

CLASSIFY_USAGE='usage: fm-board.sh classify <task-id> <area-name>'

# The classification of work already on the board, changed because the work's
# scope changed. It is `mark` for the other synchronized field and behaves the
# same way in every respect: it writes firstmate's own record first, reflects it
# onto the card, and degrades to a stale board that `poll` retries rather than
# failing the caller.
#
# It is also how a divergence on this field is resolved, for the same reason an
# explicit `mark` resolves one on the column: it is firstmate acting rather than
# the adapter reconciling behind the captain.
cmd_classify() {
  local task='' area=''
  local project issue desired synced pr pr_synced area_synced board
  local owner number status_field classify_field

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -*) die "unknown option \"$1\"" ;;
      *)
        if [ -z "$task" ]; then
          task=$1
        elif [ -z "$area" ]; then
          area=$1
        else
          die "$CLASSIFY_USAGE"
        fi
        shift
        ;;
    esac
  done
  if [ -z "$task" ] || [ -z "$area" ]; then
    die "$CLASSIFY_USAGE"
  fi
  links_find task "$task" >/dev/null || die "task $task is not linked to a board issue"
  project=$LINK_PROJECT
  issue=$LINK_ISSUE
  desired=$LINK_DESIRED
  synced=$LINK_SYNCED
  pr=$LINK_PR
  pr_synced=$LINK_PR_SYNCED
  area_synced=$LINK_AREA_SYNCED
  board=$(board_for "$project")
  owner=$(printf '%s' "$board" | cut -f2)
  number=$(printf '%s' "$board" | cut -f3)
  status_field=$(printf '%s' "$board" | cut -f8)
  classify_field=$(printf '%s' "$board" | cut -f17)
  [ "$classify_field" != - ] \
    || die "board \"$project\" configures no classification field, so there is nothing to classify into"

  links_put "$project" "$issue" "$task" "$desired" "$synced" "$pr" "$pr_synced" \
    "$area" "$area_synced"
  if board_set_values "$owner" "$number" "$issue" "$status_field" - \
    "$classify_field" "$area"; then
    links_put "$project" "$issue" "$task" "$desired" "$synced" "$pr" "$pr_synced" \
      "$area" "$area"
    printf 'classified %s %s %s %s\n' "$project" "$issue" "$task" "$area"
  else
    printf 'classification-stale %s %s %s %s\n' "$project" "$issue" "$task" "$area"
  fi
  return 0
}

# Every option the configured classification field offers, in board order, read
# from the board itself. The vocabulary lives on the board and nowhere in this
# repository, which is what keeps one project's areas from being another's - and
# what lets a caller pass an area it knows the board will accept rather than
# discovering a typo as a failed write.
cmd_classifications() {
  local want=${1:-} board project owner number classify_field option found=
  while IFS= read -r board; do
    [ -n "$board" ] || continue
    project=$(printf '%s' "$board" | cut -f1)
    if [ -n "$want" ] && [ "$want" != "$project" ]; then
      continue
    fi
    found=1
    owner=$(printf '%s' "$board" | cut -f2)
    number=$(printf '%s' "$board" | cut -f3)
    classify_field=$(printf '%s' "$board" | cut -f17)
    if [ "$classify_field" = - ]; then
      printf 'classify %s off\n' "$project"
      continue
    fi
    if ! board_ids "$owner" "$number"; then
      printf 'error %s could not read project %s/%s\n' "$project" "$owner" "$number"
      continue
    fi
    if ! board_field_id "$classify_field" >/dev/null; then
      printf 'error %s project %s/%s has no "%s" field\n' \
        "$project" "$owner" "$number" "$classify_field"
      continue
    fi
    while IFS= read -r option; do
      [ -n "$option" ] || continue
      printf 'classify %s %s %s\n' "$project" "$classify_field" "$option"
    done < <(board_field_options "$classify_field")
  done < <(boards_rows)
  if [ -n "$want" ] && [ -z "$found" ]; then
    die "no board configured for project \"$want\" in config/boards"
  fi
  return 0
}

cmd_pr() {
  local task=${1:?usage: fm-board.sh pr <task-id> <pr-url>}
  local url=${2:?usage: fm-board.sh pr <task-id> <pr-url>}
  local project issue desired synced pr pr_synced area area_synced

  pr_url_valid "$url" || die "\"$url\" is not a pull request URL"
  links_find task "$task" >/dev/null || die "task $task is not linked to a board issue"
  project=$LINK_PROJECT
  issue=$LINK_ISSUE
  desired=$LINK_DESIRED
  synced=$LINK_SYNCED
  pr=$LINK_PR
  pr_synced=$LINK_PR_SYNCED
  area=$LINK_AREA
  area_synced=$LINK_AREA_SYNCED
  if [ "$pr" = "$url" ] && [ "$pr_synced" = 1 ]; then
    printf 'already-attached %s %s %s %s\n' "$project" "$issue" "$task" "$url"
    return 0
  fi

  links_put "$project" "$issue" "$task" "$desired" "$synced" "$url" 0 \
    "$area" "$area_synced"
  if board_comment "$issue" "Working PR: $url"; then
    links_put "$project" "$issue" "$task" "$desired" "$synced" "$url" 1 \
      "$area" "$area_synced"
    printf 'attached %s %s %s %s\n' "$project" "$issue" "$task" "$url"
  else
    printf 'stale %s %s %s %s\n' "$project" "$issue" "$task" "$url"
  fi
  return 0
}

cmd_note() {
  local task=${1:?usage: fm-board.sh note <task-id> <text>}
  local text=${2:?usage: fm-board.sh note <task-id> <text>}
  local project issue
  links_find task "$task" >/dev/null || die "task $task is not linked to a board issue"
  project=$LINK_PROJECT
  issue=$LINK_ISSUE
  # A note is a point-in-time record, so it is never queued for retry: a blocker
  # posted three cycles late would be noise, and firstmate escalates the blocker
  # to the captain either way.
  if board_comment "$issue" "$text"; then
    printf 'noted %s %s %s\n' "$project" "$issue" "$task"
  else
    printf 'stale %s %s %s\n' "$project" "$issue" "$task"
  fi
  return 0
}

cmd_ack() {
  local task=${1:?usage: fm-board.sh ack <task-id>}
  local project issue pr pr_synced area area_synced
  links_find task "$task" >/dev/null || die "task $task is not linked to a board issue"
  project=$LINK_PROJECT
  issue=$LINK_ISSUE
  pr=$LINK_PR
  pr_synced=$LINK_PR_SYNCED
  area=$LINK_AREA
  area_synced=$LINK_AREA_SYNCED
  # The link stays forever so the issue can never be imported twice; only its
  # active execution state retires. The classification is part of what the link
  # records rather than part of its execution state, so a withdrawn card keeps
  # the one it was given.
  links_put "$project" "$issue" "$task" other other "$pr" "$pr_synced" \
    "$area" "$area_synced"
  printf 'acknowledged %s %s %s\n' "$project" "$issue" "$task"
}

# poll_board <board-row> <limit> <items-file> <all>
# Classifies every card from the one board read it is handed, reports what
# firstmate has to act on, and retries writes the board has not taken yet. Every
# write below reuses a card id from that same read, so nothing here refetches the
# board per item.
#
# A settled card is not something to act on, so `all` is what decides whether it
# is spoken about at all: empty prints only the records that call for a decision
# or a follow-up, and non-empty adds the `linked` record for every card already
# showing what firstmate recorded.
poll_board() {
  local board=$1 limit=$2 items=$3 all=$4
  local project owner number repo label mention assignee status_field todo in_progress done_col
  local bp_todo bp_in_progress bp_done queued processed classify_field
  local id type url status labels assignees title body class state
  local canonical task desired synced pr pr_synced board_state count=0
  local seen_file trigger column container
  local area area_synced board_area area_owed
  local l_project l_issue l_task l_desired

  project=$(printf '%s' "$board" | cut -f1)
  owner=$(printf '%s' "$board" | cut -f2)
  number=$(printf '%s' "$board" | cut -f3)
  repo=$(printf '%s' "$board" | cut -f4)
  label=$(printf '%s' "$board" | cut -f5)
  mention=$(printf '%s' "$board" | cut -f6)
  assignee=$(printf '%s' "$board" | cut -f7)
  status_field=$(printf '%s' "$board" | cut -f8)
  todo=$(printf '%s' "$board" | cut -f9)
  in_progress=$(printf '%s' "$board" | cut -f10)
  done_col=$(printf '%s' "$board" | cut -f11)
  bp_todo=$(printf '%s' "$board" | cut -f12)
  bp_in_progress=$(printf '%s' "$board" | cut -f13)
  bp_done=$(printf '%s' "$board" | cut -f14)
  queued=$(printf '%s' "$board" | cut -f15)
  processed=$(printf '%s' "$board" | cut -f16)
  classify_field=$(printf '%s' "$board" | cut -f17)

  seen_file=$(mktemp) || return 1
  while IFS=$TAB read -r id type url status labels assignees title body class state; do
    [ -n "$id" ] || continue
    count=$((count + 1))
    canonical=$(issue_canonical "$url") || continue
    # Presence on the board is established before any intake filter runs: a card
    # this cycle declines to import is still a card that has not left, and the
    # withdrawal scan below reads absence from this file.
    printf '%s\n' "$canonical" >> "$seen_file"
    board_state=$(column_state "$status" "$todo" "$in_progress" "$done_col" "$queued" "$processed")

    if links_find issue "$canonical" >/dev/null; then
      # An issue another configured board already owns is a misconfiguration,
      # not something to reconcile. Re-homing it would point every later event at
      # the wrong board, so this one is named and left entirely alone.
      if [ "$LINK_PROJECT" != "$project" ]; then
        printf 'foreign %s %s %s %s\n' \
          "$project" "$canonical" "$LINK_PROJECT" "$LINK_TASK"
        continue
      fi
      task=$LINK_TASK
      desired=$LINK_DESIRED
      synced=$LINK_SYNCED
      pr=$LINK_PR
      pr_synced=$LINK_PR_SYNCED
      area=$LINK_AREA
      area_synced=$LINK_AREA_SYNCED

      # WITHDRAWAL BY CLOSURE. A closed issue whose card is still on the board is
      # the third way the captain withdraws work, and the only one that leaves the
      # card where it was. It is reported as its own record rather than as
      # `cancelled`, because what happened differs: the card is still there to
      # look at, and the captain closed the issue behind it. Which one happened is
      # what firstmate tells the captain, so the two must not collapse into one
      # word.
      #
      # Only work still open is withdrawn. A closed issue whose task already
      # landed is the ordinary end of that task, and saying anything about it
      # would make every finished item shout - exactly the noise that would get
      # this signal turned off.
      #
      # Like `cancelled`, this reports and touches nothing: no card write, no
      # record change, and nothing about a branch or a worktree. It repeats every
      # cycle until `ack` records that firstmate reconciled it.
      if [ "$state" = closed ]; then
        case "$desired" in
          other) continue ;;
          todo | processed | queued | in-progress)
            printf 'closed %s %s %s %s\n' "$project" "$canonical" "$task" "$desired"
            continue
            ;;
        esac
      fi

      # THE CLASSIFICATION, RECONCILED EXACTLY AS THE COLUMN IS. It is read from
      # this same card, compared against what firstmate recorded, and either
      # confirmed, owed, or reported as a divergence - the same three answers,
      # against the same direction of authority. What it never does is take the
      # board's value as an instruction.
      #
      # A write it owes is not issued here. It is collected into `area_owed` and
      # travels with the column write below, so a card owing both still costs
      # the one request a card owing either costs.
      area_owed=-
      board_area=-
      if [ "$classify_field" != - ]; then
        [ "$class" = - ] || board_area=$(norm_name "$class")
        if [ "$area" != - ] && [ "$board_area" = "$(norm_name "$area")" ]; then
          if [ "$area_synced" != "$area" ]; then
            area_synced=$area
            links_put "$project" "$canonical" "$task" "$desired" "$synced" \
              "$pr" "$pr_synced" "$area" "$area_synced"
          fi
        elif [ "$area" != "$area_synced" ] \
          && { { [ "$area_synced" = - ] && [ "$board_area" = - ]; } \
               || { [ "$area_synced" != - ] && [ "$board_area" = "$(norm_name "$area_synced")" ]; }; }; then
          # Either firstmate has classified work the board has not taken yet, or
          # the classification changed because the work's scope did and the card
          # still shows the area last confirmed. Both are this adapter's own lag.
          [ "$area" = - ] || area_owed=$area
        elif [ "$area" = - ] && [ "$board_area" = - ]; then
          : # Blank on both sides: nothing owed, and surfaced below.
        else
          printf 'classification-divergence %s %s %s %s %s\n' \
            "$project" "$canonical" "$task" "$area" "$class"
        fi
      fi

      if [ "$board_state" = "$desired" ]; then
        # The board agrees. Record it as confirmed if a write was outstanding.
        if [ "$synced" != "$desired" ]; then
          synced=$desired
          links_put "$project" "$canonical" "$task" "$desired" "$desired" "$pr" \
            "$pr_synced" "$area" "$area_synced"
        fi
        # An outstanding classification is still owed even where the column is
        # settled, so it is written on its own rather than waiting for a column
        # event that may never come.
        if [ "$area_owed" != - ]; then
          if board_write_values "$owner" "$number" "$id" "$canonical" \
            "$status_field" - "$classify_field" "$area_owed"; then
            area_synced=$area_owed
            links_put "$project" "$canonical" "$task" "$desired" "$synced" "$pr" \
              "$pr_synced" "$area" "$area_synced"
            printf 'classified %s %s %s %s\n' "$project" "$canonical" "$task" "$area"
          else
            printf 'classification-stale %s %s %s %s\n' "$project" "$canonical" "$task" "$area"
          fi
        # Reconciled and therefore silent, exactly as a reconciled container is.
        # A board of settled cards would otherwise spend one record per card
        # every cycle saying nothing changed.
        elif [ -n "$all" ]; then
          printf 'linked %s %s %s %s\n' "$project" "$canonical" "$task" "$desired"
        fi
      elif [ "$desired" != "$synced" ] && [ "$board_state" = "$synced" ]; then
        # A write is outstanding and the board still shows the value this adapter
        # last confirmed, so this is its own lag rather than a change to it.
        column=$(state_column "$desired" "$todo" "$in_progress" "$done_col" "$queued" "$processed") || column=
        if [ -n "$column" ] && board_write_values "$owner" "$number" "$id" \
          "$canonical" "$status_field" "$column" "$classify_field" "$area_owed"; then
          synced=$desired
          [ "$area_owed" = - ] || area_synced=$area_owed
          links_put "$project" "$canonical" "$task" "$desired" "$desired" "$pr" \
            "$pr_synced" "$area" "$area_synced"
          printf 'synced %s %s %s %s\n' "$project" "$canonical" "$task" "$desired"
          [ "$area_owed" = - ] \
            || printf 'classified %s %s %s %s\n' "$project" "$canonical" "$task" "$area"
        else
          printf 'stale %s %s %s %s\n' "$project" "$canonical" "$task" "$desired"
          [ "$area_owed" = - ] \
            || printf 'classification-stale %s %s %s %s\n' "$project" "$canonical" "$task" "$area"
        fi
      else
        # The card shows a status firstmate did not write. Firstmate's records are
        # the truth here, so this changes nothing on either side and is reported
        # for the captain rather than reconciled behind them.
        printf 'divergence %s %s %s %s %s %s\n' \
          "$project" "$canonical" "$task" "$desired" "$board_state" "$status"
        # A classification this adapter owes is not held hostage by a column it
        # must not touch, so it is still written - on its own, and only to the
        # field this board configured for it.
        if [ "$area_owed" != - ]; then
          if board_write_values "$owner" "$number" "$id" "$canonical" \
            "$status_field" - "$classify_field" "$area_owed"; then
            area_synced=$area_owed
            links_put "$project" "$canonical" "$task" "$desired" "$synced" "$pr" \
              "$pr_synced" "$area" "$area_synced"
            printf 'classified %s %s %s %s\n' "$project" "$canonical" "$task" "$area"
          else
            printf 'classification-stale %s %s %s %s\n' "$project" "$canonical" "$task" "$area"
          fi
        fi
      fi

      # BLANK IS A SIGNAL, NOT SILENCE. A card this board classifies that
      # firstmate has recorded no area for is named every cycle until one is
      # recorded, exactly as `new` repeats until `import` runs. Work that has
      # already finished or left is settled and is not named, so a reconciled
      # board still polls quiet.
      if [ "$classify_field" != - ] && [ "$area" = - ] && [ "$board_area" = - ]; then
        case "$desired" in
          todo | processed | queued | in-progress)
            printf 'unclassified %s %s %s\n' "$project" "$canonical" "$task"
            ;;
        esac
      fi
      # An outstanding PR attachment is retried exactly like an outstanding card
      # move, because `pr` promised the next cycle would reconcile it.
      if [ "$pr" != - ] && [ "$pr_synced" != 1 ]; then
        if board_comment "$canonical" "Working PR: $pr"; then
          links_put "$project" "$canonical" "$task" "$desired" "$synced" "$pr" 1 \
            "$area" "$area_synced"
          printf 'synced %s %s %s %s\n' "$project" "$canonical" "$task" "$pr"
        else
          printf 'stale %s %s %s %s\n' "$project" "$canonical" "$task" "$pr"
        fi
      fi
      continue
    fi

    # Not linked. A container is never intake and never binds a task, and either
    # the board or the durable record can say it is one. The record is consulted
    # too rather than the column alone, so a card firstmate promoted is a
    # container from the instant that record exists - including while the move
    # out of the inbox is still outstanding, when the card is briefly still
    # sitting in an ordinary column.
    if [ "$bp_todo" != - ]; then
      container=$(bp_column_state "$status" "$bp_todo" "$bp_in_progress" "$bp_done") \
        || container=-
      if [ "$container" != - ] || decomps_find "$canonical" >/dev/null; then
        poll_container "$board" "$id" "$canonical" "$container" "$status" "$labels"
        continue
      fi
    fi

    # From here on this is intake alone. A draft card or a pull request is not a
    # real issue, and an issue outside the configured repo is not this board's
    # work to take.
    [ "$type" = Issue ] || continue
    if [ "$repo" != - ] && [ "$(issue_repo "$canonical")" != "$repo" ]; then
      continue
    fi
    [ "$board_state" = todo ] || continue
    trigger=
    if list_has "$labels" "$label"; then
      trigger=label
    elif [ "$assignee" != - ] && list_has "$assignees" "$assignee"; then
      trigger=assignee
    elif [ "$mention" != - ] && text_has "$title $body" "$mention"; then
      trigger=mention
    fi
    [ -n "$trigger" ] || continue
    printf 'new %s %s %s %s\n' "$project" "$canonical" "$trigger" "$title"
  done < "$items"

  # A card that vanished from the board while firstmate was still executing it.
  # Two reads cannot tell absence apart from something else and so reconcile
  # nothing: a full page may have another page behind it, and a board that
  # answers with no cards at all while links are open is far more likely to be
  # a changed project number or a lost permission than every card being cleared
  # by hand.
  if [ "$count" -ge "$limit" ]; then
    printf 'truncated %s %s\n' "$project" "$count"
  elif [ "$count" -eq 0 ] && [ -n "$(cmd_links "$project")" ]; then
    printf 'error %s the board returned no cards while links are open\n' "$project"
  else
    while IFS=$TAB read -r l_project l_issue l_task l_desired _ _ _; do
      [ "$l_project" = "$project" ] || continue
      if grep -Fqx -- "$l_issue" "$seen_file"; then
        continue
      fi
      # Leaving the board after Done is archiving, and an acknowledged
      # withdrawal is already reconciled; neither is open.
      case "$l_desired" in
        todo | processed | queued | in-progress) ;;
        *) continue ;;
      esac
      printf 'cancelled %s %s %s %s\n' "$project" "$l_issue" "$l_task" "$l_desired"
    done < <(links_rows)
  fi
  rm -f "$seen_file"
}

# poll_container <board-row> <card-id> <parent-issue> <container-state> <raw-status> <labels>
# A container is offered for decomposition until it is recorded as decomposed,
# and its card is reconciled under PARENT STATUS above. A parent
# whose card already shows what firstmate recorded prints nothing at all, so a
# reconciled board stays silent. The container state is `-` for a card sitting
# outside the container lane, which is what a promoted container looks like
# while the move that puts it there is still outstanding.
poll_container() {
  local board=$1 id=$2 parent=$3 container=$4 raw=$5 labels=$6
  local project owner number label status_field bp_todo bp_in_progress bp_done
  local state desired synced children now column child_state kids
  local child_url child_issue
  local any_in_progress='' any_open='' any_closed='' any_driven=''

  project=$(printf '%s' "$board" | cut -f1)
  owner=$(printf '%s' "$board" | cut -f2)
  number=$(printf '%s' "$board" | cut -f3)
  label=$(printf '%s' "$board" | cut -f5)
  status_field=$(printf '%s' "$board" | cut -f8)
  bp_todo=$(printf '%s' "$board" | cut -f12)
  bp_in_progress=$(printf '%s' "$board" | cut -f13)
  bp_done=$(printf '%s' "$board" | cut -f14)

  if decomps_find "$parent" >/dev/null; then
    if [ "$DECOMP_PROJECT" != "$project" ]; then
      printf 'foreign %s %s %s -\n' "$project" "$parent" "$DECOMP_PROJECT"
      return 0
    fi
    state=$DECOMP_STATE
    desired=$DECOMP_DESIRED
    synced=$DECOMP_SYNCED
    children=$DECOMP_CHILDREN
  else
    state=open desired=- synced=- children=-
    # Recorded the first time it is seen, not the first time it is decomposed.
    # `import` refuses any issue holding a decomposition record, so recording it
    # here is what makes a container structurally unable to bind a task rather
    # than merely never offered one.
    decomps_put "$project" "$parent" "$state" "$desired" "$synced" "$children"
  fi

  # Offering a container for decomposition repeats until `decomposed` closes it,
  # exactly as `new` repeats until `import` runs, so a decomposition interrupted
  # part way is finished rather than lost. What is enough to justify the offer
  # differs by how the container was recognized: the board called an `open` one a
  # container, so it is offered only while it sits labelled in the lane's first
  # column, whereas firstmate's own recorded judgement called a `promoted` one
  # that, and stands wherever its card has reached.
  if [ "$state" != 'done' ]; then
    if [ "$state" = promoted ] \
      || { [ "$container" = todo ] && list_has "$labels" "$label"; }; then
      printf 'decompose %s %s\n' "$project" "$parent"
    fi
  fi

  # Apply PARENT STATUS above; membership must come from this cycle's read.
  kids=$(mktemp) || return 0
  if issue_sub_issues "$parent" "$kids"; then
    while IFS=$TAB read -r child_url child_issue; do
      [ -n "$child_url" ] || continue
      child_url=$(issue_canonical "$child_url") || continue
      if links_find issue "$child_url" >/dev/null; then
        child_state=$LINK_DESIRED
      elif [ "$child_issue" = closed ]; then
        child_state='done'
      else
        child_state=todo
      fi
      case "$child_state" in
        in-progress)
          any_driven=1
          any_in_progress=1
          ;;
        done)
          any_driven=1
          any_closed=1
          ;;
        todo | processed | queued)
          any_driven=1
          any_open=1
          ;;
        *) ;;
      esac
    done < "$kids"
    rm -f "$kids"
    if [ -n "$any_driven" ]; then
      if [ -n "$any_open" ]; then
        # Only every child being finished finishes the container. Between those
        # two ends, a container with some work finished and some still open is
        # under way, which is the one honest thing its card can say.
        if [ -n "$any_in_progress" ] || [ -n "$any_closed" ]; then
          now=in-progress
        else
          now=todo
        fi
      elif [ -n "$any_in_progress" ]; then
        now=in-progress
      else
        now='done'
      fi
      # A newly derived state is firstmate's own event, exactly like `mark` on an
      # ordinary card: it says what the card should show from now on.
      if [ "$desired" != "$now" ]; then
        desired=$now
        decomps_put "$project" "$parent" "$state" "$desired" "$synced" "$children"
      fi
    fi
  else
    rm -f "$kids"
    printf 'error %s could not read the children of %s\n' "$project" "$parent"
    return 0
  fi

  # Nothing to reconcile until firstmate has recorded a state for this card,
  # which for a promoted container is true from the moment it was promoted and
  # for a first-sighted one only once its children derive one.
  [ "$desired" != - ] || return 0

  if [ "$container" = "$desired" ]; then
    # The card already shows it. Reconciled boards stay silent.
    if [ "$synced" != "$desired" ]; then
      decomps_put "$project" "$parent" "$state" "$desired" "$desired" "$children"
    fi
    return 0
  fi
  if [ "$desired" != "$synced" ] && { [ "$synced" = - ] || [ "$container" = "$synced" ]; }; then
    # A write this adapter owes: either it has never written this card, or the
    # card still shows the value it last confirmed.
    column=$(bp_state_column "$desired" "$bp_todo" "$bp_in_progress" "$bp_done") || return 0
    if board_write_status "$owner" "$number" "$status_field" "$id" "$parent" "$column"; then
      decomps_put "$project" "$parent" "$state" "$desired" "$desired" "$children"
      printf 'synced %s %s - %s\n' "$project" "$parent" "$desired"
    else
      printf 'stale %s %s - %s\n' "$project" "$parent" "$desired"
    fi
    return 0
  fi
  # The card shows a state firstmate never wrote.
  printf 'divergence %s %s - %s %s %s\n' "$project" "$parent" "$desired" "$container" "$raw"
}

cmd_poll() {
  local want='' limit=$DEFAULT_LIMIT all='' board items
  local project owner number status_field classify_field
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all)
        all=1
        shift
        ;;
      --limit)
        [ "$#" -gt 1 ] || die "--limit needs a value"
        limit=$2
        shift 2
        ;;
      --limit=*)
        limit=${1#--limit=}
        shift
        ;;
      -*) die "unknown option \"$1\"" ;;
      *)
        want=$1
        shift
        ;;
    esac
  done
  limit_valid "$limit" || die "--limit must be a positive number"
  if [ -n "$want" ]; then
    board_for "$want" >/dev/null
  fi

  while IFS= read -r board; do
    [ -n "$board" ] || continue
    project=$(printf '%s' "$board" | cut -f1)
    owner=$(printf '%s' "$board" | cut -f2)
    number=$(printf '%s' "$board" | cut -f3)
    status_field=$(printf '%s' "$board" | cut -f8)
    classify_field=$(printf '%s' "$board" | cut -f17)
    if [ -n "$want" ] && [ "$want" != "$project" ]; then
      continue
    fi
    items=$(mktemp) || die "cannot stage the board read" 1
    if board_items "$owner" "$number" "$status_field" "$classify_field" "$limit" "$items"; then
      poll_board "$board" "$limit" "$items" "$all"
    else
      # A read failure never halts the cycle; the next one reconciles.
      printf 'error %s could not read project %s/%s\n' "$project" "$owner" "$number"
    fi
    rm -f "$items"
  done < <(boards_rows)
  return 0
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  -h | --help | help | '')
    print_help
    exit 0
    ;;
esac
VERB=$1
shift
# Load and validate board configuration in this shell, before any verb runs, so
# a malformed file is one actionable error rather than a command that quietly
# behaves as though no board were configured.
boards_load
case "$VERB" in
  boards) cmd_boards "$@" ;;
  poll) cmd_poll "$@" ;;
  import) cmd_import "$@" ;;
  place) cmd_place "$@" ;;
  promote) cmd_promote "$@" ;;
  child-add) cmd_child_add "$@" ;;
  decomposed) cmd_decomposed "$@" ;;
  decompositions) cmd_decompositions "$@" ;;
  links) cmd_links "$@" ;;
  lookup) cmd_lookup "$@" ;;
  mark) cmd_mark "$@" ;;
  classify) cmd_classify "$@" ;;
  classifications) cmd_classifications "$@" ;;
  pr) cmd_pr "$@" ;;
  note) cmd_note "$@" ;;
  ack) cmd_ack "$@" ;;
  *) die "unknown command \"$VERB\" (see fm-board.sh --help)" ;;
esac
