#!/usr/bin/env bash
# Regression tests for per-home Treehouse pools.
#
# Treehouse names a pool after the clone's folder name and its origin URL, so
# every home that clones one upstream under the same name used to land in one
# shared pool whose copies were worktrees of whichever home's clone built it
# first. These tests hold one upstream and three homes - the primary, oas-ops
# and oas-web - each with its own clone under the same project name, and prove:
#   - each home asks Treehouse for a copy from its own pool root, distinct from
#     every other home's and nested inside none of them;
#   - each home launches from a copy of its own clone;
#   - each home refuses a copy of another home's clone without claiming it.
# When an installed treehouse supports --root, the exact acquisition command a
# spawn sends is also run against the real treehouse from each home's clone,
# alongside the shared-root counterfactual that reproduces the original defect.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-home-pool)
HOMES="primary oas-ops oas-web"
UPSTREAM="$TMP_ROOT/upstream.git"
USER_HOME="$TMP_ROOT/user-home"
FAKEBIN=$(make_spawn_fakebin "$TMP_ROOT/fake")
# Every read of the fake pane already reports the settled path, so polling
# between reads only costs wall time.
fm_test_fake_sleep_noop "$FAKEBIN"
mkdir -p "$USER_HOME"

seed_upstream() {
  local seed="$TMP_ROOT/seed"
  git init --quiet -b main "$seed"
  printf 'app\n' > "$seed/README.md"
  git -C "$seed" add README.md
  git -C "$seed" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$seed" "$UPSTREAM"
}

home_dir() { printf '%s/homes/%s\n' "$TMP_ROOT" "$1"; }
clone_dir() { printf '%s/projects/app\n' "$(home_dir "$1")"; }

home_root() {  # <home-name>
  FM_HOME="$(home_dir "$1")" HOME="$USER_HOME" bash -c '. "$1"; fm_treehouse_home_root' _ \
    "$ROOT/bin/fm-wake-lib.sh"
}

# A copy in the pool Treehouse keeps under a home's own root: the managed
# <pool>/<slot>/<repo> layout, pool state, and a linked worktree of that home's
# clone. Echoes the copy path.
make_home_slot() {  # <home-name>
  local name=$1 root slot
  root=$(home_root "$name") || fail "could not resolve the pool root for $name"
  slot="$root/.treehouse/app-pool/1/app"
  mkdir -p "$(dirname "$slot")"
  git -C "$(clone_dir "$name")" worktree add --quiet --detach "$slot" HEAD
  printf '{"worktrees":[]}\n' > "$root/.treehouse/app-pool/treehouse-state.json"
  printf '%s\n' "$slot"
}

setup_homes() {
  local name home
  seed_upstream
  for name in $HOMES; do
    home=$(home_dir "$name")
    fm_test_spawn_home "$home" codex
    # Same project name and the same origin string in every home, exactly the
    # shape that made Treehouse hand all three homes one pool.
    git clone --quiet "file://$UPSTREAM" "$(clone_dir "$name")"
  done
}

run_home_spawn() {  # <home-name> <pane-path> <task-id>
  local name=$1 pane=$2 id=$3 home
  home=$(home_dir "$name")
  fm_test_spawn_brief "$home" "$id"
  FM_TEST_SPAWN_USER_HOME="$USER_HOME" FM_FAKE_PANE_LOG="$TMP_ROOT/$id.pane" \
    fm_test_run_spawn "$home" "$pane" "$FAKEBIN" "$id" "$(clone_dir "$name")" --scout
}

test_each_home_has_its_own_pool_root() {
  local name other root other_root home
  for name in $HOMES; do
    root=$(home_root "$name") || fail "could not resolve the pool root for $name"
    [ "$root" = "$(home_root "$name")" ] || fail "the pool root for $name is not stable"
    for other in $HOMES; do
      home=$(cd "$(home_dir "$other")" && pwd -P)
      case "$root/" in "$home"/*) fail "the pool root for $name nests inside home $other: $root" ;; esac
      [ "$other" != "$name" ] || continue
      other_root=$(home_root "$other")
      [ "$root" != "$other_root" ] || fail "homes $name and $other share one pool root: $root"
    done
  done
  pass "the primary, oas-ops and oas-web homes each resolve their own pool root outside every home"
}

test_each_home_launches_from_its_own_clone() {
  local name slot id out status root sent
  for name in $HOMES; do
    slot=$(make_home_slot "$name")
    id="own-$name"
    out=$(run_home_spawn "$name" "$slot" "$id")
    status=$?
    expect_code 0 "$status" "home $name should launch from a copy of its own clone"$'\n'"$out"
    assert_grep "worktree=$slot" "$(home_dir "$name")/state/$id.meta" \
      "home $name did not record its own copy"
    root=$(home_root "$name")
    sent=$(grep -F 'treehouse get' "$TMP_ROOT/$id.pane" || true)
    [ "$sent" = "treehouse get --root '$root'" ] \
      || fail "home $name did not ask Treehouse for a copy from its own pool root (sent: ${sent:-nothing})"
    printf '%s\n' "$sent" > "$TMP_ROOT/$name.acquire"
    printf '%s\n' "$slot" > "$TMP_ROOT/$name.slot"
  done
  pass "each home launches from a copy of its own clone, acquired from its own pool root"
}

test_each_home_refuses_another_homes_copy() {
  local name other foreign id out status claim
  for name in $HOMES; do
    for other in $HOMES; do
      [ "$other" != "$name" ] || continue
      foreign=$(cat "$TMP_ROOT/$other.slot")
      claim="$(dirname "$foreign")/.fm-slot-owner"
      id="foreign-$name-from-$other"
      out=$(run_home_spawn "$name" "$foreign" "$id")
      status=$?
      [ "$status" -ne 0 ] || fail "home $name launched in home $other's copy"$'\n'"$out"
      assert_contains "$out" "not a copy of this home's clone" \
        "home $name refused home $other's copy for the wrong reason"
      [ ! -e "$(home_dir "$name")/state/$id.meta" ] \
        || fail "home $name published a task record for home $other's copy"
      if [ -e "$claim" ]; then
        grep -Fx "task=$id" "$claim" >/dev/null && fail "home $name claimed home $other's copy"
      fi
    done
  done
  pass "each home refuses a copy of another home's clone, with no record and no claim"
}

is_copy_of() {  # <clone> <worktree>
  bash -c '. "$1"; fm_worktree_of_project "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

treehouse_supports_root() {
  command -v treehouse >/dev/null 2>&1 || return 1
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--root([^[:alnum:]_-]|$)'
}

# Run an interactive acquisition the way a pane does and print where its
# subshell landed.
real_acquire() {  # <clone> <command>
  ( cd "$1" && printf 'pwd -P\nexit\n' \
      | HOME="$USER_HOME" SHELL=/bin/bash TREEHOUSE_NO_UPDATE_CHECK=1 bash -c "$2" 2>/dev/null ) \
    | tail -n 1
}

test_real_treehouse_gives_each_home_its_own_clone() {
  local name other got shared_root first second
  if ! treehouse_supports_root; then
    printf '# skip: no installed treehouse supports --root; the real-treehouse check did not run\n'
    return 0
  fi
  for name in $HOMES; do
    got=$(real_acquire "$(clone_dir "$name")" "$(cat "$TMP_ROOT/$name.acquire")")
    [ -n "$got" ] && [ "$got" != "$(cd "$(clone_dir "$name")" && pwd -P)" ] \
      || fail "the real treehouse gave home $name no copy (landed in '${got:-nothing}')"
    is_copy_of "$(clone_dir "$name")" "$got" \
      || fail "the real treehouse gave home $name a copy that is not of its own clone: $got"
    for other in $HOMES; do
      [ "$other" != "$name" ] || continue
      ! is_copy_of "$(clone_dir "$other")" "$got" \
        || fail "the real treehouse gave home $name a copy of home $other's clone: $got"
    done
  done
  # Counterfactual: one shared root reproduces the original defect, so the
  # per-home assertions above cannot pass vacuously.
  shared_root="$TMP_ROOT/shared-root"
  first=$(real_acquire "$(clone_dir primary)" "treehouse get --root '$shared_root'")
  second=$(real_acquire "$(clone_dir oas-ops)" "treehouse get --root '$shared_root'")
  is_copy_of "$(clone_dir primary)" "$first" \
    || fail "the shared-root counterfactual did not start from the primary's clone: $first"
  is_copy_of "$(clone_dir primary)" "$second" \
    || fail "the shared-root counterfactual no longer hands oas-ops the primary's copy; recheck the premise ($second)"
  pass "the real treehouse ($(treehouse --version 2>/dev/null)) gives each home a copy of its own clone, and a shared root does not"
}

setup_homes
test_each_home_has_its_own_pool_root
test_each_home_launches_from_its_own_clone
test_each_home_refuses_another_homes_copy
test_real_treehouse_gives_each_home_its_own_clone

echo "# all fm-treehouse-home-pool tests passed"
