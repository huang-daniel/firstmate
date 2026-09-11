# Generated brief matrix - bin/fm-brief.sh, run as firstmate would

```
$ FM_HOME=<home> bin/fm-brief.sh <id> acme-app --mode no-mistakes   (default verb)
```

## no-mistakes ship brief - Definition of done (generated output)

```markdown
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append `done: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make `--intent` preserve all relevant content from this brief's `# Task` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.
Before every pipeline call that blocks your pane for a long stretch with no output (a `no-mistakes axi run`, or a `respond` that resumes one), append `paused: {which call you are waiting on}` first, so your silence reads as a declared wait instead of a possible wedge.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies the authority contract in its `AGENTS.md` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid `--yes`: it would silently bypass firstmate's authority check and any required captain escalation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR {url} checks green` and stop. You are finished.
```

## Same brief with FM_CLASSIFY_PAUSED_VERB=awaiting

```markdown
Before every pipeline call that blocks your pane for a long stretch with no output (a `no-mistakes axi run`, or a `respond` that resumes one), append `awaiting: {which call you are waiting on}` first, so your silence reads as a declared wait instead of a possible wedge.
```

## Which generated scaffolds carry the obligation

| scaffold | declared-wait sentence |
|---|---|
| no-mistakes ship | present |
| no-mistakes ship --herdr-lab | present |
| no-mistakes ship (custom verb) | present |
| direct-PR ship | absent |
| local-only ship | absent |
| scout | absent |
| secondmate charter | absent |
