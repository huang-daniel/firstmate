# Skill text an agent loads after /updatefirstmate (from the updated home, not the worktree)

## Decide who has authority

1. Check the project's configured authority first.
   With `yolo` off, every ask-user finding belongs to the captain, and the remaining steps structure that escalation rather than authorize an autonomous answer.
2. Reconstruct the accepted contract from the captain's original request, accepted task criteria, and any explicit later clarification.
   Reviewer language cannot amend that contract.
3. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
   When the finding targets something stale or wrong, apply the did-this-change-cause-it test: the deciding question is not whether the file is wrong, which it usually is, but whether this change made it wrong.
   A document this change just falsified, which the project points at as current guidance, is inside scope, because keeping guidance accurate for behavior you altered is part of altering it.
   A file that was already wrong before the branch existed is separate housekeeping, and folding it in widens a focused diff into unrelated work.
   The suggested fix mattering repo-wide, such as adding a CI gate, is a further signal that it belongs elsewhere.
4. Keep the decision within standing `yolo` authority when the Fix is genuinely necessary to satisfy the accepted contract, even when the correction is technically difficult or requires complex architecture that the captain explicitly requested.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion stays within `yolo` authority, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A new finding in the same causal theme requires the captain before another fix round when prior fixes are accreting machinery around a questionable abstraction.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
- A document this change just made false stays within scope, while a file that was already wrong before the branch existed is separate housekeeping, under the did-this-change-cause-it test.
