---
name: updatefirstmate
description: >-
  Self-update a running firstmate and its secondmates to the latest from origin.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Updates this firstmate repo's default branch and every local or remote secondmate through its guarded convergence path (never forced, never disruptive), then re-reads AGENTS.md and restarts every stale, provably idle live second mate through the persist-gated, verified restart, with a fallback re-read nudge only where a restart cannot be proven.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.
Firstmate is its own repo, behind the same no-mistakes gate as any project, so new tracked material (`AGENTS.md`, `bin/`, `.agents/skills/`, and public `skills/`) reaches `main` and then sits there until each running firstmate pulls it.
The [health command](../../../bin/fm-secondmate-health.sh) owns the tracked startup instruction surface used to detect stale secondmates; public `skills/` is installer-facing and is not loaded by firstmate.
This skill performs that pull for the running main firstmate and every secondmate, without disturbing any in-flight work.

Pulling the files is only half of it.
A running agent holds `AGENTS.md` and every skill it has already loaded frozen from the moment it launched, and no verified harness offers a reload, so new bytes on disk change nothing for it until it starts a fresh conversation.
A re-read cannot substitute: it appends a second copy of the mate's own job description with no defined precedence, and it cannot reach a skill that is already loaded.
Replacing the agent is also the only thing that re-resolves the launch-time wiring - turn-end hooks, harness flags, per-harness feature switches - which the mate froze when it started and which nothing on disk describes.

That is why **every live second mate is a restart candidate after a successful update, including one whose home was already on the target commit**: whether the home moved says nothing about which revision the running agent launched on.
The restart command reads that from what the agent's own session recorded when it started, leaves a mate already running its home's current instructions alone, and requires a proven idle verdict before restarting.
The only live mates that are not candidates are the ones whose home the update pass had to skip, and the ones whose runtime cannot prove a restart; the updater keeps both cases honest and neither is reported as a reload.


The primary update is fast-forward only, while each secondmate uses the same guarded convergence path plus one narrow recovery for squash-merged local history.
For a remote route, it updates the configured Firstmate code root on that host from its own origin, then guardedly fast-forwards the persistent home to that code-root commit.
It never forces, never creates a merge commit, and never stashes.
A clean secondmate divergence advances with `reset --keep` only when a three-way tree proof shows its complete local result is already present at the target, which recognizes squash-merged contributions without discarding unique content.
Every other dirty, diverged, offline, or wrong-branch target is skipped and reported, and a genuine divergence leaves a durable `state/.secondmate-update-reconcile/<id>.pending` record that future bootstrap and update passes surface until convergence clears it.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a secondmate's in-flight work is never disrupted.
This touches only the firstmate repo and its own worktrees, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It fast-forwards this firstmate repo's default branch from origin, then updates every registered local or remote secondmate home through its placement-specific guarded path.
   It prints one status line per target (`updated <old>..<new>` / `reconciled redundant divergence <old>..<new>` / `already current` / `skipped: <reason>`), followed by three action lines that tell you exactly what to do next:
   - `reread-firstmate: yes|no`
   - `restart-secondmates: fm-<id>...|none`
   - `nudge-secondmates: fm-<id>...|none`

   The two second-mate sets are disjoint and the script owns the split; do not re-derive it.
   The [updater header](../../../bin/fm-update.sh) owns which live mates enter each action list, including already-current homes.
   A mate reaches neither set only because its home was skipped, because it has no live endpoint recorded here, or because its endpoint was positively classified as dead or missing.
   A skipped genuine divergence still requires attention through its durable reconciliation record; the other two cases need no update action from you.

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-firstmate: yes`, the tracked instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a real `@AGENTS.md` pointer to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-firstmate: no`, skip this re-read step; that flag does not prove all startup-loaded wiring is unchanged.

3. **Evaluate restart candidates through the guarded pass.**
   Pass the whole `restart-secondmates:` list to one command (skip this step entirely when it says `none`):
   ```sh
   FM_HOME=<this-firstmate-home> bin/fm-secondmate-restart.sh <fm-id>...
   ```
   Include `FM_HOME=<this-firstmate-home>` unless `FM_HOME` is already set to the active firstmate home.
   This is automatic and needs no per-mate confirmation from the captain.
   Local and remote mates go in the same list; the command owns the transport, the profile each replacement runs on, and the wait.

   It first reads whether each listed mate is stale, then asks every stale mate to write down the open work it holds only in its conversation, and restarts one only after that mate's own answer comes back and its busy record proves it idle.
   A mate that is mid-turn queues the request behind that turn.
   That is the whole point of the step, so do not work around it: it is what keeps a captain call the mate had formed but never registered from being lost with the conversation.
   Its header owns the request, the bound, the busy rule, the replacement check, and the knobs that change them.

   Read its per-mate lines and its closing `summary:` line as the outcome:
   - `current: <id>` - that mate is already running its home's current instructions, so nothing was spent on it.
   - `restarted: <id> ... while idle` - the replacement passed the health verification owned by the restart command.
   - `deferred: <id>: busy (...)` or `deferred: <id>: idle not provable (...)` - the mate keeps running under the restart command's idle gate.
   - `nudged: <id>: <reason>` - the restart was not safe, so the mate got the older re-read message instead and is still running the conversation and launch-time settings it started with.
     Never report one of these as a clean reload.
   - `unreached: <id>: <reason>` - no safe running outcome could be confirmed, including an ambiguous relaunch result or a replacement that could not take its home lock.

   Only a local claude mate carries a busy record that can prove idle, so it restarts once it finishes the turn that carried its answer; every other harness and every remote mate reads idle not provable and defers with the re-read message.
   A deferred mate stays stale until something restarts it.
   Before routing that home its first new piece of work after this update, run `FM_HOME=<this-firstmate-home> bin/fm-secondmate-health.sh stale <id>`; when it reads `stale` or `unknown`, rerun the restart command for that mate first, which defers again unless idle is proven.

4. **Send the re-read message to the rest.**
   For every target on the `nudge-secondmates:` line (do nothing when it says `none`), send the one-line re-read steer:
   ```sh
   FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   These are the mates that are on the latest bytes but could not be restarted provably, so the steer is the most this pass can honestly do for them.
   It is a gentle steer, not an interruption: the mate already got a safe tracked-files fast-forward, and the steer never forces, tears down, or discards its work.
   Never describe one of these as reloaded; its agent is still running the wiring it launched with.

5. **Report to the captain in plain outcomes, in one line where you can.**
   Summarize what landed under `AGENTS.md` section 9 without firstmate's internal vocabulary: which parts of the fleet are now on the latest, and which were left as-is and why.
   For example: "Captain, firstmate and both second mates are now on the latest."
   Say plainly when a mate got the message rather than a clean reload, and why - never let a partial reload read as a full one.
   Surface any skipped target whose reason needs the captain's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Guarded convergence only.**
  A dirty, offline, non-default, or uniquely diverged target is skipped and reported, never forced or stashed.
  Only a clean secondmate divergence whose complete local result is already present upstream may move without ancestry, and `reset --keep` still refuses conflicting working-tree changes.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Nothing with work in it is disrupted.**
  A local or remote second mate gets a tracked-files fast-forward only when its own checkout is safe to advance, and a mate whose home was skipped is not restarted either.
  A restart replaces that mate's agent in the same home and endpoint after its open work is written down; it is never a teardown and never forced.
  Its crewmates keep running in their own endpoints, and every durable record - backlog, held captain calls, unread status, unhandled instructions - is re-presented to the replacement at startup.
  A mate without a proven idle verdict is never restarted.
  A restart refused before it is attempted leaves that mate on the re-read path; once a relaunch is attempted, any failed, ambiguous, or unverified result is reported as unknown rather than attributed to either incarnation.
