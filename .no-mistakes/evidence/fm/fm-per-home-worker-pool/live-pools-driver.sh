#!/usr/bin/env bash
set -euo pipefail
base="$PWD/.test-pool/live"
mkdir -p "$base/user" "$base/seed"
export HOME="$base/user" TREEHOUSE_NO_UPDATE_CHECK=1
export PATH="$PWD/.test-pool/bin:$PATH"
. bin/fm-wake-lib.sh
git init -q -b main "$base/seed"
printf 'pool validation\n' > "$base/seed/README.md"
git -C "$base/seed" add README.md
git -C "$base/seed" -c user.name=Test -c user.email=test@example.invalid commit -qm seed
git clone -q --bare "$base/seed" "$base/upstream.git"
for name in primary oas-ops oas-web; do
  mkdir -p "$base/$name/projects"
  git clone -q "$base/upstream.git" "$base/$name/projects/app"
  root=$(fm_treehouse_home_root "$base/$name")
  slot=$(cd "$base/$name/projects/app" && treehouse get --lease --root "$root" --lease-holder "validation-$name")
  printf '%s\n' "$slot" > "$base/$name.slot"
  fm_worktree_of_project "$base/$name/projects/app" "$slot"
  printf 'HOME=%s\nPOOL=%s\nWORKER=%s\nGIT_COMMON_DIR=%s\n' "$name" "$root" "$slot" "$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir)"
done
for name in primary oas-ops oas-web; do
  for other in primary oas-ops oas-web; do
    [ "$name" != "$other" ] || continue
    slot=$(cat "$base/$other.slot")
    if fm_worktree_of_project "$base/$name/projects/app" "$slot"; then exit 1; fi
    printf 'OWNERSHIP_REJECTED home=%s foreign_copy=%s\n' "$name" "$other"
  done
done
for name in primary oas-ops oas-web; do
  treehouse return "$(cat "$base/$name.slot")"
done
