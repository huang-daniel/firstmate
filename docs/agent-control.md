# Agent lifecycle control plane

Firstmate talks to a running agent two ways, and they are not the same channel.

The **data plane** is [`bin/fm-send.sh`](../bin/fm-send.sh): conversational text for the agent to read.
For a `kind=secondmate` target it always prepends the from-firstmate routing marker, because a secondmate is itself a firstmate and its reply must come back through the status path rather than a chat nobody reads.

The **control plane** is [`bin/fm-control.sh`](../bin/fm-control.sh): allowlisted lifecycle verbs addressed to an exact task id.

The split exists because the data plane's marking is exactly right for a message and exactly wrong for a lifecycle command.
A routing-marked `/quit` arrives as ordinary chat - `[fm-from-firstmate] /quit` - which the agent reasons about instead of executing.
The failure repeated across harnesses and homes, and the workaround (remember to use an unmarked send for agent-control commands, and improvise the right key or command per harness) lived only in agent prose, so it failed again every time a session did not happen to recall it.

## What the control plane owns

`bin/fm-control-lib.sh` is the single executable owner of three capability tables, which have no side effects, so they can be read as a contract:

- The **verb allowlist**: `interrupt`, `exit`, `stand-down`, `relaunch`, `compact`.
  There is no arbitrary-text and no generic raw-key entry point.
  A caller either names an allowlisted verb or is refused.
- **Per-harness mechanics**: the key that cancels a running turn, how many times it must be delivered, whether the composer needs clearing afterwards, the command that exits the agent, and which task kinds the adapter is verified to run.
  These were previously carried only in the [`harness-adapters`](../.agents/skills/harness-adapters/SKILL.md) skill's tool references, which now point here.
  `bin/fm-send.sh`'s `--key` path reads the composer-clear table from this owner too, rather than keeping a second copy of it.
- **Per-backend capability**: which named keys a runtime backend can deliver, and whether it has a recovery-grade agent-state classifier able to prove an agent stopped.

The one thing this file owns that is not a pure table is the [endpoint-absence proof](#reclaiming-a-task-whose-endpoint-is-gone) below, which does run backend reads; sourcing the file is still free.

A recorded `harness=` is not always an exact adapter name: a task launched from a raw command records that command's basename instead.
`fm_control_harness_family` is the one place that prefix rule is stated, and an unrecognized value resolves to no adapter rather than being guessed into one.

## Verbs

| Verb | Effect | Postcondition |
| --- | --- | --- |
| `interrupt` | Deliver the harness's verified interrupt sequence while leaving the agent running. | Delivery succeeds while the endpoint still exists and the agent is still alive where the backend can classify that; cancellation is confirmed only from an adapter-owned acknowledgement and otherwise reports `cancel=unconfirmed`. |
| `exit` | Stop the agent, preserving the endpoint, the worktree, and every uncommitted change. | The backend's recovery-grade classifier reports the agent gone. Already-stopped is idempotent success. An endpoint reading `missing` goes through the same [absence proof](#reclaiming-a-task-whose-endpoint-is-gone) the reclaim uses before anything is claimed about it, and only Herdr can supply one from a read: proven gone reports `endpoint-gone` (the agent went with it, and the endpoint this verb normally preserves did not survive), a pane that turns out to be there and idle is the ordinary `already-stopped`, one whose agent is back takes the ordinary interrupt-then-exit path. A tmux `missing` refuses rather than claim a stop it cannot see, unless the record says `stand-down` closed that endpoint, which reports `endpoint-gone`. |
| `stand-down` | Stand a finished ship worker down: stop its agent as `exit` does, then close its endpoint so a task held for a merge word leaves no blank terminal behind. The worktree, task record, status log, steering inbox, and merge poll are all preserved. | The endpoint reads gone to the recovery-grade classifier, and the task record carries `endpoint_closed=<endpoint>`. Already closed is idempotent success (`already-closed`). See [Standing a finished worker down](#standing-a-finished-worker-down). |
| `compact` | Compact a second mate's conversation in place with its harness's own compaction command, only behind the guards in [Guarded context compaction](#guarded-context-compaction). | The session transcript records a new completed compaction, the context is smaller, and a read-only probe answered through the parent channel shows the mate's role, its own id, and its durable records readable. Every attempt is recorded in the mate's status log. |
| `relaunch` | Replace the running agent with a new one in the same worktree - and the same endpoint whenever that endpoint still exists - on the exact recorded adapter or an explicitly chosen harness, model, and effort. | The new agent is alive on the endpoint the task's record now names, and that record names the harness that is actually running. An already authenticated merge watch remains valid, with trace propagation enabled or disabled. |

An exit that delivers lifecycle input but cannot prove the agent stopped fails with `exit=unconfirmed`, reports the observed agent state and any interrupt cancellation claim, and never claims that nothing changed.
Interrupt never rewrites busy state as proof of its own success.
Claude exposes no lifecycle acknowledgement for a manual interrupt, so delivery succeeds with `cancel=unconfirmed` and its adapter-owned busy state remains as observed.
muse's session log records `terminal=cancelled` for the interrupted run, so the control plane reports `cancel=confirmed` only after observing that exact acknowledgement.

An interrupt is not complete until the composer is empty.
muse is the one verified adapter that restores the cancelled prompt back into its composer as real text, so its interrupt key is followed by a Ctrl+U clear; without it the next submitted line - including this plane's own exit command - would concatenate onto the restored prompt and submit both as one line.
The clear is refused before anything is sent when the recorded backend cannot deliver it.

`exit` reads the composer's state before typing the exit command and requires the exact `empty` verdict; a `pending` verdict refuses by naming the pending text, and any other verdict (`unknown`, `pending-unproven`, or an unreadable read) refuses as not proven empty, matching the fail-safe contract every other consumer that can overwrite composer input follows.

**Teardown and discard are not verbs and will not become verbs.**
`exit` stops an agent and preserves everything else.
`stand-down` additionally closes a finished, fully pushed ship's endpoint and preserves everything else.
Removing a worktree, removing a task's records, or discarding work stays with [`bin/fm-teardown.sh`](../bin/fm-teardown.sh), which owns the landed-work test.

**`resume` is not a verb.**
It is not deterministic across the verified adapters: codex, grok, and gemini resume only from a session id printed at exit, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, omp, kimi, and agy have no verified pane-resume contract.
`relaunch` covers the same need on every adapter, because the brief on disk - not a harness-private session - is the durable instruction.

## Standing a finished worker down

A ship worker that reported done with its PR recorded usually waits for a merge word, and standing it down with `exit` left its endpoint as an empty shell until post-merge cleanup.
`stand-down` closes that endpoint, and it is allowed only from the done state with the recorded PR present.
Every one of these must hold before the agent is touched, or it refuses and nothing changes:

- The task is `kind=ship` on the no-mistakes or direct-PR path, with a recorded `pr=`.
- The status log's current declaration is `done`; an open decision or blocker, or any later event, refuses.
- [`bin/fm-crew-state.sh`](../bin/fm-crew-state.sh) reads `done`, so an active validation run, which it reads as working or parked, always refuses.
  The one exception is a direct-PR task whose agent is already stopped: it has no run to attribute, so its current state may read `unknown`.
- The worktree has no uncommitted or untracked change, and its HEAD is on a remote-tracking branch or is the recorded `pr_head`.
  This is checked again after the agent stops and before the endpoint closes.

The agent is stopped through the ordinary `exit` path, with its postcondition.
The record then gains `endpoint_closed=<endpoint>`, and the endpoint is closed through [`bin/fm-backend.sh`](../bin/fm-backend.sh)'s `fm_backend_close_task_endpoint`: tmux's exact-identity window close, or Herdr's focus-preserving pane close under the named-session presentation lock, which also retires a matching presentation journal.
A post-close probe that finds the endpoint still present drops the marker and reports that it remains.
An inconclusive probe reports that survival is unknown: it preserves the marker when the backend close already confirmed absence, and drops it otherwise.
An unreadable or ambiguous endpoint still refuses `exit` and `relaunch` until a readable probe permits the shared absence proof.
Only tmux and herdr are supported; every other backend refuses and keeps its endpoint.
Pool-slot retention through stand-down and the compatibility limit for older tasks are owned by [`bin/fm-spawn.sh`](../bin/fm-spawn.sh)'s durable-lease contract.

The marker is what keeps a stood-down task recoverable from its records alone:

- `exit` reports `endpoint-gone` for it, and `relaunch` creates one fresh endpoint in the recorded worktree - on tmux too, where no read can prove a window absent, because the record itself says `stand-down` closed that exact endpoint after proving its agent stopped.
  A tmux rebind opens the window in the session the record names, re-creating that session only when it no longer exists and using its initial window for the task, without an extra blank window.
  Every republished record drops the marker, so it never outlives the endpoint it names.
- [`bin/fm-teardown.sh`](../bin/fm-teardown.sh) meets the already-gone endpoint as an ordinary silent close and still runs its complete landed-work test.
- The session-start digest reports the endpoint as closed at stand-down rather than dead, and [`bin/fm-crew-state.sh`](../bin/fm-crew-state.sh) keeps reading the task's current state from its status log rather than reporting a gone endpoint.

## Guarded context compaction

`compact` keeps a long-running second mate's context small without restarting it, and only at a genuinely idle boundary.
Claude's automatic compaction setting stays off because it can fire between steps mid-turn; this verb is the one path, and firstmate invokes it deliberately.
Nothing schedules it, and it is not a way to type an arbitrary slash command: the command comes from `fm_control_compact_command` in `bin/fm-control-lib.sh`, and every guard must pass first.

It applies to a local `kind=secondmate` target only; a crew, a scout, and the primary are never targets.
Claude is the one verified adapter (`fm_control_compact_supported`), because it alone has all three legs: a structured context-size read, a provable second mate idle verdict, and an in-place compaction the session records.
Every other adapter refuses by name, and so does a backend without a recovery-grade agent-state classifier.

Each guard refuses when it fails or cannot be established, with exit status 4, before anything is typed:

1. **Eligible.** [`bin/fm-context-size.sh`](../bin/fm-context-size.sh) reads the mate's current context from its own session transcript, and it must be over 400,000 tokens.
   The threshold is eligibility, not an instruction to compact.
2. **Idle.** [`bin/fm-secondmate-health.sh`](../bin/fm-secondmate-health.sh) `idle`, the same owner the restart pass uses, reads it idle.
3. **Nothing in flight.** Its steering inbox holds no unhandled instruction, its status log in this home holds no open keyed decision, this home holds no reply expectation it still owes and no pending backlog handoff to it, its own home holds no queued notification, and every direct report of its home reads done, paused, or failed to [`bin/fm-crew-state.sh`](../bin/fm-crew-state.sh).
   Each report must also have independent semantic idle evidence or positive proof that its agent is gone; a completed validation run alone does not establish inactivity.
4. **Checkpointed.** It is sent the restart pass's open-work persistence request, framed for compaction and extended to outstanding work, decisions, ownership, blockers, and next action ([`bin/fm-secondmate-restart-lib.sh`](../bin/fm-secondmate-restart-lib.sh) owns the text, the correlated send, and the shared wait bounds).
   Its correlated answer must arrive within that bound and contain `checkpoint=complete`; no answer, `checkpoint=incomplete`, or an answer that does not affirm completeness refuses.
   It must then settle idle within the restart pass's settle window.
5. **Re-checked.** The before-size transcript read, agent-alive and empty-composer checks, and full direct-report reads run first.
   Idle and the remaining checks in 3 are read again last, immediately before the keystroke.

The command is then typed through the same verified keystroke path `exit` uses, never the steering inbox.
Completion is a new `compact_boundary` entry in the session transcript, and the recovery check follows:

- the context after compaction is smaller than before;
- the agent still reads alive;
- a read-only probe sent through the ordinary parent channel is answered with `role=secondmate`, the mate's own `id=`, and `records=readable`, showing its charter is intact and its outstanding work reads back from its durable records;
- the context read after that answer is still below the size before compaction.

Every attempt is recorded in the mate's status log in this home, with the before and after context sizes and the checkpoint's reply reference: `note: context-compact refused: <why>`, `note: context-compact compacted:`, and `note: context-compact recovery-ok:`.
A recovery that cannot be proven is recorded as `blocked [key=context-compact]: context-compact recovery-failed: <why>` and stops there with exit status 1.
Nothing is resumed, restarted, or re-dispatched, and that open blocker keeps every later `compact` refused until firstmate resolves it.

The primary never compacts itself through this verb or any automation; `AGENTS.md` section 8 owns its one-notice rule, and `bin/fm-context-size.sh` with no argument is the read-only way it reads its own size.

## Transactional relaunch

The update-and-restart pass opts into `relaunch --require-idle`, whose stop-boundary check and distinct refusal status are documented in [fm-control.sh](../bin/fm-control.sh).
A refusal defers the mate without stopping it or leaving an open restart transaction.

`relaunch` replaces the agent and republishes the task record, so it runs as a transaction with a journal at `state/<id>.control-relaunch`, the prior record preserved beside it, and a ship or scout's prior instructions preserved when a progress note is appended.

1. **Resolve the profile.**
   An explicit `--harness`, `--model`, or `--effort` wins.
   Otherwise a `kind=secondmate` task re-resolves its durable `config/secondmate-harness` pin, including that file's optional model and effort tokens, exactly as every other respawn does - so setting the pin and relaunching is the ordinary way to move a secondmate's runtime.
   A ship or scout keeps the harness already recorded for it, because that harness comes from firstmate's dispatch-profile judgment at intake and must not be silently re-read from configuration.
   A recorded raw-command basename that differs from its resolved adapter cannot reproduce the command actually running, so relaunch refuses before the checkpoint unless the caller passes an explicit `--harness` to choose the replacement runtime deliberately.
   A harness change resets model and effort unless they are named too, because a model chosen for one adapter does not transfer to another.
2. **Safe checkpoint.**
   The recorded worktree must exist and be a worktree root; its head and dirty state are recorded.
   For a `kind=secondmate` task, the home's identity marker must match and its child records must be readable, so a relaunch can never strand child work behind an unreadable home.
   A secondmate's own crewmates run in their own endpoints and outlive its relaunch; the relaunched secondmate reconciles them from its home's durable records at startup.
3. **Record the note.**
   A ship or scout relaunch requires `--note`, because the replacement inherits the local copy but none of the conversation; the note is appended to the instructions it reads.
   A secondmate relaunch does not require one and never rewrites its standing charter.
4. **Stop the old agent** through the `exit` verb, with its postcondition.
5. **Launch the replacement** through its single owner, `bin/fm-spawn.sh --relaunch`, which reuses the recorded worktree instead of creating one, adopts the recorded endpoint when it still exists, clears the previous harness's per-task wiring, and arms a fresh busy generation.
   When the recorded endpoint is proven gone rather than merely idle or unreachable, the launch owner creates one fresh endpoint in that same worktree and the republished record rebinds the task to it - see [Reclaiming a task whose endpoint is gone](#reclaiming-a-task-whose-endpoint-is-gone).

Switching harness is therefore one ordinary relaunch rather than a separate mechanism.

### Reclaiming a task whose endpoint is gone

A Herdr pane or workspace can be destroyed out from under a live task by churn or a session restart.
The task's worktree, branch, commits, and uncommitted changes all survive that; only its terminal does not.

**Absence proof from backend reads is Herdr-only.**
On tmux, both verbs refuse an unexplained `missing` endpoint.
The one exception is an endpoint the record says [`stand-down`](#standing-a-finished-worker-down) closed, which is proven gone by that record rather than by a read.

Two endpoint verdicts are agent-free, and both license a relaunch:

- `dead` - the endpoint exists and confidently holds no agent. It is **adopted**, so the task keeps its exact recorded address.
- gone, **proven** - there is no endpoint and therefore no agent, and it cannot be adopted, so the launch owner **creates one fresh endpoint in the recorded worktree** and the republished record rebinds the task to it.

That proof is its own step, because the classifier's `missing` is not one state: it conflates *the endpoint was destroyed* with *the endpoint is unreachable from here right now*.
An unreachable endpoint can still hold the live agent a rebind would duplicate, so absence is proven and never inferred from a failed read - and whether it is provable at all is a property of the backend:

- **Herdr can prove it.** Every read goes through the adapter's `--session <session>` CLI, so the recheck starts and reads the session the *record* names, through that session's own socket.
  It starts that server (only the server: no workspace and no tab are created) and **re-reads the recorded pane**.
  `dead` means the pane survived the restart and is adopted after all, with no second tab; `alive` means the agent came back and refuses; only a second `missing` proves the pane itself did not survive ([`docs/herdr-backend.md`](herdr-backend.md) "Restart and liveness behavior").
  That server start is a real side effect, and the parenthetical above does not cover it: when the recorded session's server no longer exists at all, the probe stands a fresh empty one up in order to ask, and nothing afterwards uses it.
  So in that state `exit` - which otherwise reads as a read-only inspection - leaves an idle herdr server behind.
- **tmux cannot.** `list-windows -a` describes only the tmux server the *current process* addresses (its `TMUX_TMPDIR`/socket), and a task record carries no socket identity for its endpoint.
  A different but running server would answer "not anywhere" about a window it was never able to see, so a server-wide read cannot tell a destroyed window from one on a server this process cannot address.
  There is no read available that closes that gap, so tmux refuses - for a renamed session, a moved window, a foreign socket, and a dead server alike - unless the record's stand-down marker names that exact endpoint.

Every transient or self-contradicting read stays `unreadable` or `ambiguous` and still refuses, so a momentary backend failure can never be mistaken for absence.

That proof has one owner for the whole control plane (`fm_control_endpoint_absence_verdict` in `bin/fm-control-lib.sh`), so `exit` and `relaunch` cannot reach two different answers about one endpoint.
`exit` reports what the proof established and nothing more - see its row in the verb table above.

What a reclaim is not:

- It is **not a teardown**. The worktree is reused exactly as the previous agent left it; nothing unlanded is ever discarded, and the ordinary `--note` requirement still applies.
- It does **not** change the task's identity. The task id, its armed poll and registration, and its status log are untouched; only the endpoint binding in the record moves.
  Its instructions are the one exception, and only in the way an ordinary relaunch already changes them: a ship or scout reclaim appends the required `--note` under a `## Progress note (<timestamp>)` heading in `data/<id>/brief.md`, so re-read that brief rather than assuming it is byte-identical - a reclaim that failed and was retried leaves one block per attempt.
  A secondmate's standing charter is never rewritten.
- It is **not** a peer seat's operation. `fm-control` resolves an exact task id against **this** home's `state/`, so only the home that owns the task can reclaim it.
- It does **not** cover a secondmate. A secondmate whose endpoint is gone already has one owner for that recovery - `bin/fm-spawn.sh <id> --secondmate`, driven by the session-start liveness sweep - so relaunch refuses and names it rather than becoming a second path to the same outcome.

The re-created tab is opened in the herdr session the record names, never in whichever session the recovering seat happens to sit in - relocating a task onto another herdr server would be an identity change published as a self-consistent but wrong record.
A seat that *claims* a herdr launcher pane belonging to a different session is refused rather than allowed to place the endpoint somewhere else, so reclaim such a task from a seat in the recorded session.
A seat with no herdr launcher pane at all - a plain ssh or cron shell, which is the ordinary way an operator reclaims - is not refused: placement falls back to the recorded session's labeled container, so the tab still lands in the session the record names.
The reclaim pins the recorded **session** but not the **workspace**: the container follows the reclaiming seat, so a reclaim run from a seat inside the recorded session places the new tab in *that seat's* workspace rather than the recorded `herdr_workspace_id`, even when the recorded workspace still exists and only the pane was destroyed.
The record is republished consistently and no work is lost, but the task's `herdr_workspace_id` moves with it.
The pane id necessarily changes (the pane did not survive), and the record follows it.
A Herdr reclaim deliberately uses the flat container shape rather than presentation projection: projection is a presentation-only layout that is never endpoint or ownership authority, and flat is already the documented fallback for every recovery it cannot bind exactly ([`docs/herdr-backend.md`](herdr-backend.md)).

**Known limitation - a refusal before the record is republished leaves a stray husk pane** (follow-up bead `fm-herdr-rebind-leak-20260913`).
The rebind registers no abort cleanup, so a refusal in the window between the new tab being created and the record being republished leaves that pane behind while the record still names the old, gone one.
The stray pane holds a bare shell - the harness is not delivered until after publication - so the next reclaim cleans up after it: the re-created tab carries the same `fm-<id>` label, `tab create` finds it, classifies it a husk, and closes and replaces it.
That self-heals only when the retry resolves the *same* workspace, which the placement rule above does not guarantee.
The worktree and the task's records are unaffected either way.

### Failure and rollback

- A refusal **before** the agent is stopped leaves the durable record and the instructions byte-identical.
- A launch failure **after** the agent is stopped restores the prior durable record, keeps the progress note so a later recovery still has it, marks the journal `failed:launching`, and reports plainly that no agent is running and where the work is preserved.
- If the launch owner already published the new record but no running agent can be confirmed, the new record is kept: the task is recorded on the new harness with no agent confirmed, which is exactly what recovery reconciles.
  Rewriting it back to the old harness would be a second, worse inaccuracy.

## Fail-closed boundaries

- Targeting is exact.
  Only a bare task id with a `state/<id>.meta` record in this home is accepted, and that record must pass the shared endpoint-identity validation.
  A legacy `fm-<id>` window label, an explicit `session:window` endpoint, and a record whose `endpoint_task_id` names another task are all refused.
- A remotely placed secondmate is refused by name.
  Its agent runs on another host, so none of the postconditions this plane verifies could be read for it here; local endpoint validation would refuse the record regardless, because `window=remote:<id>` can never match a local backend's required shape.
  Drive that lifecycle on its own host and reconcile it through the secondmate recovery path.
  For `relaunch` that host-side drive is `bin/fm-on.sh <id> fm-remote-secondmate-control.sh relaunch ...`, whose host-local leg runs this same plane against a record that is ordinary and local there, so every checkpoint, journal, rollback, and postcondition below applies unchanged ([`docs/remote-secondmates.md`](remote-secondmates.md)); `interrupt` and `exit` have no such route.
- An unverified harness is refused rather than guessed at.
- An implicit relaunch from a prefixed raw-command basename is refused before the agent or durable state is touched because its original launch command cannot be reconstructed.
- An adapter that is not verified for this task's kind is refused **before** the running agent is stopped, not after.
  Muse is a crewmate and scout adapter only, so relaunching a secondmate onto it refuses while its agent is still up rather than leaving that secondmate with no agent when the launch owner refuses.
- A backend that cannot deliver the harness's interrupt key, or the composer clear that key needs, is refused rather than sent a different key.
  Orca's terminal API exposes only an interrupt and an Enter, so it can deliver neither Escape nor Ctrl+U.
- `exit` and `relaunch` require a backend with a recovery-grade agent-state classifier - tmux and herdr - because without one the "the agent stopped" postcondition cannot be proven.
  zellij, orca, and cmux are refused rather than reported as successful blind.
- An ambiguous or unreadable endpoint state refuses.
  Only a positively classified state acts.
- `exit`'s composer-empty check, above, is itself a fail-closed boundary that `relaunch` inherits by stopping the old agent through `exit`.
- `fm-spawn --relaunch` independently refuses unless the endpoint is positively agent-free - either a `dead` endpoint that survives, or an endpoint proven gone by the shared absence proof above - so a replacement can never join a live agent.
  An `alive`, `ambiguous`, or `unreadable` verdict all refuse, and so does any endpoint whose absence is not provable, which on tmux is every `missing` the record does not mark as closed at stand-down; absence is claimed only from positive evidence of it.
  It also requires the shell to be in the recorded worktree: tmux refuses immediately when it is not, while Herdr sends one `cd` to the recorded path and refuses unless a subsequent path read confirms the move.

## Capability matrix

Backend capability comes from each adapter's real surface, not from a policy choice.

| Backend | Escape | Enter | Ctrl+C | Ctrl+U | Recovery-grade agent state |
| --- | --- | --- | --- | --- | --- |
| tmux | yes | yes | yes | yes | yes |
| herdr | yes | yes | yes | yes | yes |
| zellij | yes | yes | yes | yes | no |
| cmux | yes | yes | yes | yes | no |
| orca | no | yes | yes | no | no |

Per-harness interrupt keys, repeat counts, composer clears, exit commands, and supported task kinds live in `bin/fm-control-lib.sh` and are exercised for every verified harness by `tests/fm-control.test.sh`, with adapters outside its lane pinning their control mechanics in their own harness suites.
The empirical basis for each adapter's value is the `harness-adapters` skill's verification record for that adapter.

## Verification

- `tests/fm-control.test.sh` - the adapter contract for its verified-harness lane (adapters outside the lane pin their control mechanics in their own harness suites), the backend capability matrix, exact-id scoping, the closed verb list, the busy, idle, dead, and idempotent lifecycle cases, and marker non-regression, all against a stubbed session provider.
- `tests/fm-control-compact.test.sh` - guarded compaction: the structured context read, the checkpoint-compact-probe order, every refusal guard, the checkpoint gate, the re-check before the keystroke, and each recovery failure, against a stubbed session provider that models a live Claude mate and its transcript.
- `tests/fm-context-size-live-e2e.test.sh` - the opt-in live guard for the transcript facts compaction relies on, against the real installed Claude Code; its dated result is in [`docs/verification/runtime-backends.md`](verification/runtime-backends.md) "Claude context size and compaction".
- `tests/fm-control-relaunch.test.sh` - the relaunch transaction: identity preservation, harness switching, the progress note, checkpoint refusals, rollback after a failed launch, and the endpoint-absence proof both verbs share - the Herdr reclaim of a destroyed endpoint, and tmux refusing one it cannot prove absent.
- `tests/fm-control-herdr-smoke.test.sh` - the second state-verified backend against the real herdr binary, on an isolated throwaway lab session.
- `tests/fm-control-relaunch.test.sh` also pins `stand-down` on tmux against the same stubbed provider: the close, what it preserves, every refusal including an active validation run, idempotency, and relaunch into a fresh window afterwards; it checks authenticated merge-watch preservation across stand-down and relaunch with tracing on and off, and rejection of an unrecognized trailing metadata field.
- `tests/fm-control-herdr-standdown-smoke.test.sh` - `stand-down` against the real herdr binary on an isolated lab session: the pane close, idempotency, relaunch into a fresh pane, and cleanup afterwards.
- `tests/fm-teardown.test.sh` and `tests/fm-teardown-endpoint-safety.test.sh` - cleanup after `stand-down`: a merged PR completes, an unmerged one still refuses, and a real tmux window closed at stand-down completes silently.
