#!/usr/bin/env bash
# Behavior tests for fm-secret.sh, the credential-store accessor.
#
# The guard these tests exist for: a listing path must not emit credential
# material for EITHER file shape. A test that only exercises `KEY=value` files
# would pass while leaving the real defect live, because the incident happened
# against a file holding a bare value with no key, where
# `grep -o '^[A-Za-z_][A-Za-z0-9_]*'` prints the secret itself. Every fixture
# value below is synthetic and resembles a credential without being one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SECRET="$ROOT/bin/fm-secret.sh"
TMP_ROOT=$(fm_test_tmproot fm-secret)

# The exact inspection that leaked a live token, twice, in one morning.
INCIDENT_PATTERN='^[A-Za-z_][A-Za-z0-9_]*'

# Synthetic values. BARE_PADDED is the nastiest real shape: a base64-looking
# secret whose leading run is followed by `=`, so it satisfies a key pattern.
BARE_PLAIN='fakeToken_AAAABBBBCCCCDDDD1111'
BARE_PADDED='FAKEPADDEDSECRET0000AAAA=='
BARE_URL='https://hooks.example.invalid/notify?token=fakefakefake'
KV_VALUE='fakeauth_2222333344445555'

make_store() {
  local name=$1 store
  store="$TMP_ROOT/$name/secrets"
  mkdir -p "$store/clients"
  printf '%s\n' "$BARE_PLAIN" > "$store/vercel-token"
  printf '%s' "$BARE_PADDED" > "$store/padded-key"           # no trailing newline
  printf '%s\n' "$BARE_URL" > "$store/notice-url"
  printf 'ACCOUNT_SID=ACfake0000000000\nAUTH_TOKEN=%s\nFROM_NUMBER=+15550000000\n' \
    "$KV_VALUE" > "$store/twilio"
  printf '# operator note\nPLAN=hobby  # inline comment\nURL="postgres://u:p%%40x@h/db"\n' \
    > "$store/mixed"
  printf 'TEAM=fakeTeam\nID=fakeId\n' > "$store/clients/nested"
  printf '# only a comment\nCRON_SECRET=fakecron22223333\n' > "$store/single-kv"
  find "$store" -type f -exec chmod 0600 {} +
  find "$store" -type d -exec chmod 0700 {} +
  printf '%s\n' "$store"
}

run_secret() {
  local store=$1; shift
  FM_SECRETS_OVERRIDE="$store" "$SECRET" "$@"
}

# Every synthetic value that must never appear in a listing's output.
assert_no_secret_material() {
  local haystack=$1 label=$2
  assert_not_contains "$haystack" "$BARE_PLAIN" "$label leaked the bare token"
  assert_not_contains "$haystack" "$BARE_PADDED" "$label leaked the padded bare secret"
  # The padded secret without its `=` padding is what the incident pattern
  # actually printed, so the truncated form has to be absent too.
  assert_not_contains "$haystack" "${BARE_PADDED%%=*}" "$label leaked the padded secret's body"
  assert_not_contains "$haystack" "$BARE_URL" "$label leaked the bare URL"
  assert_not_contains "$haystack" "$KV_VALUE" "$label leaked a KEY=value value"
}

test_incident_pattern_still_leaks_a_raw_bare_file() {
  local store hit
  store=$(make_store incident)

  # Not vacuous: prove the fixture really does reproduce the incident, so the
  # later assertions are testing a fix rather than an impossible input.
  hit=$(grep -o "$INCIDENT_PATTERN" "$store/padded-key" || true)
  assert_equals "${BARE_PADDED%%=*}" "$hit" \
    "the padded bare fixture no longer reproduces the incident, so the guard below proves nothing"

  hit=$(grep -o "$INCIDENT_PATTERN" "$store/twilio" | head -1 || true)
  assert_equals "ACCOUNT_SID" "$hit" "the KEY=value fixture stopped behaving like a key file"

  pass "the fixtures reproduce the incident: the bare file prints its own secret"
}

test_list_emits_names_only() {
  local store out
  store=$(make_store list)
  out=$(run_secret "$store" list)
  assert_no_secret_material "$out" "list"
  assert_contains "$out" "vercel-token" "list omitted a credential"
  assert_contains "$out" "clients/nested" "list omitted a nested credential"
  pass "list emits credential names and no credential material"
}

test_names_emits_no_secret_material_for_either_shape() {
  local store out err status
  store=$(make_store names)

  for cred in twilio mixed clients/nested vercel-token notice-url padded-key single-kv; do
    status=0
    out=$(run_secret "$store" names "$cred" 2>"$TMP_ROOT/names.err") || status=$?
    err=$(cat "$TMP_ROOT/names.err")
    assert_no_secret_material "$out" "names $cred stdout"
    assert_no_secret_material "$err" "names $cred stderr"
  done

  # KEY=value shape: the real keys, and nothing else.
  out=$(run_secret "$store" names twilio 2>/dev/null)
  assert_equals "ACCOUNT_SID
AUTH_TOKEN
FROM_NUMBER" "$out" "names did not list the KEY=value keys"

  # Bare shape: the reference name derived from the FILENAME.
  out=$(run_secret "$store" names vercel-token 2>/dev/null)
  assert_equals "VERCEL_TOKEN" "$out" "names did not derive the bare reference name"

  # The padded bare secret is the incident's worst case: refuse, emit nothing.
  status=0
  out=$(run_secret "$store" names padded-key 2>"$TMP_ROOT/names.err") || status=$?
  expect_code 1 "$status" "names on an ambiguous single line"
  assert_equals "" "$out" "names printed something for an ambiguous credential"
  assert_contains "$(cat "$TMP_ROOT/names.err")" "--keyed" "the ambiguous refusal did not say how to resolve it"

  pass "names emits no credential material for the bare, padded-bare or KEY=value shape"
}

test_reveal_returns_each_value_for_either_shape() {
  local store
  store=$(make_store reveal)
  assert_equals "$KV_VALUE" "$(run_secret "$store" reveal twilio AUTH_TOKEN)" \
    "reveal failed on a KEY=value credential"
  assert_equals "$BARE_PLAIN" "$(run_secret "$store" reveal vercel-token VERCEL_TOKEN)" \
    "reveal failed on a bare credential"
  assert_equals "$BARE_URL" "$(run_secret "$store" reveal notice-url NOTICE_URL)" \
    "reveal failed on a bare credential holding a URL"
  assert_equals "fakeTeam" "$(run_secret "$store" reveal clients/nested TEAM)" \
    "reveal failed on a nested credential"
  # `source` semantics: an inline comment is not part of the value, and a
  # double-quoted value is unquoted.
  assert_equals "hobby" "$(run_secret "$store" reveal mixed PLAN)" \
    "reveal kept an inline comment in the value"
  assert_equals 'postgres://u:p%40x@h/db' "$(run_secret "$store" reveal mixed URL)" \
    "reveal did not unquote a double-quoted value"
  # A single KEY=value line is never returned whole as if it were bare.
  assert_equals "fakecron22223333" "$(run_secret "$store" reveal single-kv CRON_SECRET)" \
    "reveal failed on a single-key credential"
  pass "reveal returns each value, for both shapes, without the caller knowing the shape"
}

test_reveal_refuses_to_escape_the_store() {
  local store status out
  store=$(make_store escape)
  printf 'OUTSIDE=fakeOutsideValue\n' > "$TMP_ROOT/escape/outside"
  ln -s "$TMP_ROOT/escape/outside" "$store/linked"

  for bad in ../outside ./twilio /etc/hostname 'a/../../outside'; do
    status=0
    out=$(run_secret "$store" reveal "$bad" OUTSIDE 2>/dev/null) || status=$?
    assert_not_equals 0 "$status" "reveal accepted the out-of-store name $bad"
    assert_not_contains "$out" "fakeOutsideValue" "reveal $bad read outside the store"
  done

  status=0
  out=$(run_secret "$store" reveal linked OUTSIDE 2>/dev/null) || status=$?
  assert_not_equals 0 "$status" "reveal followed a symlink out of the store"
  assert_not_contains "$out" "fakeOutsideValue" "reveal followed a symlink out of the store"

  local command outside="$TMP_ROOT/escape/external" value_root
  mkdir -p "$outside"
  printf 'TOKEN=%s\n' "$BARE_PLAIN" > "$outside/token"
  cp "$outside/token" "$TMP_ROOT/escape/original"
  ln -s "$outside" "$store/redirected"
  for command in reveal names migrate; do
    status=0
    case $command in
      reveal) out=$(run_secret "$store" reveal redirected/token TOKEN 2>&1) || status=$? ;;
      names) out=$(run_secret "$store" names redirected/token 2>&1) || status=$? ;;
      migrate) out=$(run_secret "$store" migrate --keyed redirected/token 2>&1) || status=$? ;;
    esac
    [ "$status" -ne 0 ] || fail "intermediate manifest symlink accepted"
    [[ $out != *"$BARE_PLAIN"* ]] || fail "outside credential disclosed"
    cmp -s "$outside/token" "$TMP_ROOT/escape/original" || fail "outside credential modified"
  done

  value_root="${store%/*}/secret-values"
  mkdir -p "$value_root" "$store/value-client"
  printf '# fm-secret v2\nTOKEN\n' > "$store/value-client/token"
  mkdir -p "$outside/token-values"
  printf '%s' "$BARE_PLAIN" > "$outside/token-values/TOKEN"
  cp "$outside/token-values/TOKEN" "$TMP_ROOT/escape/value-original"
  ln -s "$outside" "$value_root/value-client"
  mv "$store/value-client/token" "$store/value-client/token-values"
  for command in reveal export; do
    status=0
    if [ "$command" = reveal ]; then
      out=$(run_secret "$store" reveal value-client/token-values TOKEN 2>&1) || status=$?
    else
      out=$(run_secret "$store" export value-client/token-values 2>&1) || status=$?
    fi
    [ "$status" -ne 0 ] || fail "intermediate value symlink accepted"
    [[ $out != *"$BARE_PLAIN"* ]] || fail "outside value disclosed"
    cmp -s "$outside/token-values/TOKEN" "$TMP_ROOT/escape/value-original" || fail "outside value modified"
  done
  printf 'TOKEN=%s\n' "$BARE_PLAIN" > "$store/value-client/legacy"
  cp "$store/value-client/legacy" "$TMP_ROOT/escape/legacy-original"
  status=0
  out=$(run_secret "$store" migrate --keyed value-client/legacy 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "migration followed intermediate value symlink"
  [[ $out != *"$BARE_PLAIN"* ]] || fail "migration disclosed outside value"
  [ ! -e "$outside/legacy" ] || fail "migration created outside value directory"
  cmp -s "$store/value-client/legacy" "$TMP_ROOT/escape/legacy-original" || fail "refused migration modified legacy credential"

  pass "reveal refuses traversal and symlinked credentials"
}

test_migration_closes_the_incident_for_both_shapes() {
  local store out status leaked
  store=$(make_store migrate)

  run_secret "$store" migrate --apply >/dev/null 2>&1 || true
  run_secret "$store" migrate --keyed single-kv >/dev/null 2>&1 || true
  run_secret "$store" migrate --bare padded-key >/dev/null 2>&1 || true

  # The incident command itself, run against every migrated file, must now
  # print key names only. This is the assertion the whole task exists for.
  for cred in vercel-token padded-key notice-url twilio mixed single-kv clients/nested; do
    leaked=$(grep -o "$INCIDENT_PATTERN" "$store/$cred" || true)
    assert_no_secret_material "$leaked" "the incident pattern against migrated $cred"
  done

  # Values survive the rewrite byte for byte, padding included.
  assert_equals "$BARE_PLAIN" "$(run_secret "$store" reveal vercel-token VERCEL_TOKEN)" \
    "migration changed a bare value"
  assert_equals "$BARE_PADDED" "$(run_secret "$store" reveal padded-key PADDED_KEY)" \
    "migration changed the padded bare value"
  assert_equals "$BARE_URL" "$(run_secret "$store" reveal notice-url NOTICE_URL)" \
    "migration changed a bare URL value"
  assert_equals "$KV_VALUE" "$(run_secret "$store" reveal twilio AUTH_TOKEN)" \
    "migration changed a KEY=value value"
  assert_equals 'postgres://u:p%40x@h/db' "$(run_secret "$store" reveal mixed URL)" \
    "migration changed a quoted value"

  out=$(FM_SECRETS_OVERRIDE="$store" bash -c 'eval "$("$1" export twilio)"; printf "%s" "$AUTH_TOKEN"' _ "$SECRET")
  [ "$out" = "$KV_VALUE" ] || fail "export round trip failed"
  out=$(FM_SECRETS_OVERRIDE="$store" bash -c 'eval "$("$1" export padded-key)"; printf "%s" "$PADDED_KEY"' _ "$SECRET")
  [ "$out" = "$BARE_PADDED" ] || fail "bare export round trip failed"

  local value file
  for value in "$BARE_PLAIN" "$BARE_PADDED" "$BARE_URL" "$KV_VALUE" ACfake0000000000 +15550000000 hobby 'postgres://u:p%40x@h/db' fakeTeam fakeId fakecron22223333; do
    while IFS= read -r file; do
      if grep -Fq -- "$value" "$file"; then fail "manifest tree contains credential material"; fi
    done < <(find "$store" -type f)
  done
  while IFS= read -r file; do
    [ "$(stat -c %a "$file")" = 600 ] || fail "value file permissions incorrect"
  done < <(find "${store%/*}/secret-values" -type f)
  while IFS= read -r file; do
    [ "$(stat -c %a "$file")" = 700 ] || fail "value directory permissions incorrect"
  done < <(find "${store%/*}/secret-values" -type d)

  # names is now exact for what used to be the bare shape.
  assert_equals "PADDED_KEY" "$(run_secret "$store" names padded-key 2>/dev/null)" \
    "names is not exact after migration"

  # Re-running changes nothing.
  out=$(run_secret "$store" migrate --apply 2>&1 || true)
  assert_not_contains "$out" "relabelled" "migration was not idempotent"
  assert_contains "$out" "already migrated" "migration did not report migrated files as done"
  assert_equals "$BARE_PADDED" "$(run_secret "$store" reveal padded-key PADDED_KEY)" \
    "a second migration pass changed a value"

  status=0
  run_secret "$store" migrate --apply >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "a fully migrated store still reported work to do"

  pass "migration closes the incident for both shapes and preserves every value"
}

test_migration_refuses_to_guess_an_ambiguous_file() {
  local store out before
  store=$(make_store ambiguous)
  before=$(cat "$store/padded-key")

  out=$(run_secret "$store" migrate 2>&1 || true)
  assert_contains "$out" "AMBIGUOUS" "the report did not flag the ambiguous credential"
  assert_no_secret_material "$out" "the migration report"
  assert_equals "$before" "$(cat "$store/padded-key")" "the dry run changed a file"

  out=$(run_secret "$store" migrate --apply 2>&1 || true)
  assert_contains "$out" "AMBIGUOUS" "--apply guessed at the ambiguous credential"
  assert_equals "$before" "$(cat "$store/padded-key")" "--apply rewrote an ambiguous file"

  # A wrong declaration on an unmigrated credential is refused rather than
  # corrupting the value. This needs a store the report above has not touched.
  store=$(make_store misdeclared)
  run_secret "$store" migrate --bare twilio >/dev/null 2>&1 \
    && fail "--bare was accepted for a multi-key credential"
  assert_equals "$KV_VALUE" "$(run_secret "$store" reveal twilio AUTH_TOKEN)" \
    "a refused declaration still altered the credential"
  run_secret "$store" migrate --keyed vercel-token >/dev/null 2>&1 \
    && fail "--keyed was accepted for a single unlabelled value"
  assert_equals "$BARE_PLAIN" "$(run_secret "$store" reveal vercel-token VERCEL_TOKEN)" \
    "a refused declaration still altered a bare credential"

  pass "migration refuses to guess a shape it cannot tell apart without printing it"
}

test_quoted_comments() {
  local store key expected actual
  store=$(make_store quoted)
  cat > "$store/quoted" <<'FIXTURE'
SINGLE='synthetic-single' # production
DOUBLE="synthetic-double" # production
APOSTROPHE='synthetic'\''quote' # note
FIXTURE
  for key in SINGLE DOUBLE APOSTROPHE; do
    expected=$(bash -c '. "$1"; printf "%s" "${!2}"' _ "$store/quoted" "$key")
    actual=$(run_secret "$store" reveal quoted "$key")
    [ "$actual" = "$expected" ] || fail "quoted legacy value differs from shell interpretation"
    printf '%s' "$expected" > "$TMP_ROOT/expected-$key"
  done
  run_secret "$store" migrate --keyed quoted >/dev/null || fail "quoted migration failed"
  for key in SINGLE DOUBLE APOSTROPHE; do
    cmp -s "$TMP_ROOT/expected-$key" "${store%/*}/secret-values/quoted/$key" || fail "migration changed independently extracted bytes"
  done
  actual=$(FM_SECRETS_OVERRIDE="$store" bash -c 'eval "$("$1" export quoted)"; printf "%s" "$APOSTROPHE"' _ "$SECRET")
  [ "$actual" = "$(cat "$TMP_ROOT/expected-APOSTROPHE")" ] || fail "quoted export failed"
  pass "quoted comments and export preserve independently extracted values"
}

test_store_path_spellings() {
  local store spelling value file status
  for spelling in trailing repeated relative; do
    store=$(make_store "path-$spelling")
    case $spelling in
      trailing) spelling="$store/" ;;
      repeated) spelling="${store//\//\/\/}///" ;;
      relative) spelling=secrets ;;
    esac
    (
      cd "${store%/*}" || exit 1
      run_secret "$spelling" migrate --apply >/dev/null 2>&1 || true
      run_secret "$spelling" migrate --keyed single-kv >/dev/null || exit 1
      run_secret "$spelling" migrate --bare padded-key >/dev/null || exit 1
      run_secret "$spelling" migrate --apply >/dev/null || exit 1
    ) || fail "store path migration failed"
    for value in "$BARE_PLAIN" "$BARE_PADDED" "$BARE_URL" "$KV_VALUE" ACfake0000000000 +15550000000 hobby 'postgres://u:p%40x@h/db' fakeTeam fakeId fakecron22223333; do
      while IFS= read -r file; do
        if grep -Fq -- "$value" "$file"; then fail "manifest tree contains value after path normalization"; fi
      done < <(find "$store" -type f)
    done
    [ "$(run_secret "$store" reveal padded-key PADDED_KEY)" = "$BARE_PADDED" ] || fail "normalized store value changed"
    [ -f "${store%/*}/secret-values/padded-key/PADDED_KEY" ] || fail "value store is not a sibling"
  done
  for spelling in / ////; do
    status=0
    run_secret "$spelling" migrate --apply >/dev/null 2>&1 || status=$?
    expect_code 2 "$status" "root store must be refused"
  done
  pass "store path spellings preserve the manifest boundary"
}

test_partial_publication() {
  local store destination mode out status
  for mode in matching mismatch extra symlink; do
    store=$(make_store "partial-$mode")
    destination="${store%/*}/secret-values/vercel-token"
    mkdir -p "$destination"
    printf '%s' "$BARE_PLAIN" > "$destination/VERCEL_TOKEN"
    case $mode in
      mismatch) printf '%s' "$KV_VALUE" > "$destination/VERCEL_TOKEN" ;;
      extra) touch "$destination/.extra" ;;
      symlink)
        rm "$destination/VERCEL_TOKEN"
        ln -s "$store/vercel-token" "$destination/VERCEL_TOKEN"
        ;;
    esac
    cp "$store/vercel-token" "$TMP_ROOT/legacy-before"
    cp -RP "$destination" "$TMP_ROOT/published-$mode"
    status=0
    out=$(run_secret "$store" migrate --bare vercel-token 2>&1) || status=$?
    if [ "$mode" = matching ]; then
      expect_code 0 "$status" "matching partial publication must resume"
      [ "$(run_secret "$store" reveal vercel-token VERCEL_TOKEN)" = "$BARE_PLAIN" ] || fail "resumed value changed"
      cmp -s "$destination/VERCEL_TOKEN" "$TMP_ROOT/published-$mode/VERCEL_TOKEN" || fail "published bytes changed"
      if grep -Fq "$BARE_PLAIN" "$store/vercel-token"; then fail "legacy value remains after resume"; fi
      run_secret "$store" migrate --bare vercel-token >/dev/null || fail "resumed migration is not idempotent"
    else
      expect_code 1 "$status" "conflicting publication must refuse"
      assert_contains "$out" "published values conflict for credential vercel-token" "conflict must identify credential"
      cmp -s "$store/vercel-token" "$TMP_ROOT/legacy-before" || fail "conflict changed legacy file"
      diff -rq "$destination" "$TMP_ROOT/published-$mode" >/dev/null || fail "conflict changed published files"
    fi
  done
  pass "partial publication resumes only for identical values"
}

test_store_path_spellings
test_partial_publication

test_quoted_comments
test_incident_pattern_still_leaks_a_raw_bare_file
test_list_emits_names_only
test_names_emits_no_secret_material_for_either_shape
test_reveal_returns_each_value_for_either_shape
test_reveal_refuses_to_escape_the_store
test_migration_closes_the_incident_for_both_shapes
test_migration_refuses_to_guess_an_ambiguous_file
