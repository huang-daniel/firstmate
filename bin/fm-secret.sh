#!/usr/bin/env bash
# Named accessor for this home's private credential store, config/secrets.
#
# Usage:
#   fm-secret.sh list                         credential names held in the store
#   fm-secret.sh names <credential>           key names, or the reference name, inside one credential
#   fm-secret.sh reveal <credential> <key>    exactly one value, on stdout
#   fm-secret.sh migrate [--apply]            report, or perform, the store migration
#   fm-secret.sh migrate --keyed <credential> declare one ambiguous credential a KEY=value file
#   fm-secret.sh migrate --bare <credential>  declare one ambiguous credential a single unlabelled value
#
# WHY THIS EXISTS. The store held two file shapes: `KEY=value` lines, and a bare
# value with no key at all. A key-listing command shaped like
# `grep -o '^[A-Za-z_][A-Za-z0-9_]*' <file>` prints key names against the first
# shape and prints THE SECRET ITSELF against the second. Two agents independently
# ran that exact inspection against a bare-token file and printed a live token,
# each believing it was performing a safe listing. The defect is the
# representation, so the fix is a listing path that cannot emit a value whatever
# the file holds, plus a separate, explicitly named read for the value.
#
# NEVER inspect a file in this store with a generic text command. `names` is the
# only supported way to see what a credential holds and `reveal` the only
# supported way to obtain a value.
#
# WHAT MAKES `list` AND `names` SAFE. `list` emits directory entry names and
# never opens a credential. `names` decides what to print from a file's SHAPE,
# never from a value, and has four paths:
#   * a migrated file, whose first content line is the marker below, is
#     enumerated by a capture anchored at line start that requires a literal `=`
#     after the captured `[A-Za-z_][A-Za-z0-9_]*` run and keeps only that run,
#     so no byte at or after the `=` can reach stdout;
#   * an unmigrated file whose content is SEVERAL key-shaped lines is enumerated
#     the same way. One unlabelled value cannot take that shape, so this is not
#     the leaking case;
#   * an unmigrated file holding ONE line that is not key-shaped is unlabelled.
#     Its bytes never reach stdout at all: `names` prints the reference name
#     derived from the FILENAME;
#   * an unmigrated file holding ONE line that IS key-shaped could be either,
#     and `names` refuses rather than print anything from it.
# That last path is what closes the incident shape. A bare value ending in `=`
# padding, such as base64, satisfies a key-shaped pattern, so an unmigrated
# single line is never asked to prove its own shape.
#
# FILE FORMAT AFTER MIGRATION. The first content line is the marker. Every value
# sits on a `KEY=value` line, so `source`-ing a migrated file still works and
# marking an already-keyed file changes nothing else about it. A bare-value file
# gains the key `migrate` derives from its filename: uppercased, with every
# character outside `[A-Z0-9_]` replaced by `_`.
#
# WHAT MIGRATION REFUSES TO GUESS. A file holding exactly one content line that
# is itself key-shaped could be a real `KEY=value` pair or an unlabelled value
# that reads like one, because a base64 secret ending in `=` padding satisfies
# the same pattern. Guessing wrong either corrupts the value or marks a bare
# secret as keyed, which would make the marker lie and keep the leak alive past
# migration. `migrate` reports those as AMBIGUOUS and changes nothing until the
# operator declares the shape with `--keyed` or `--bare`.
#
# COMPATIBILITY. `reveal` reads both shapes and both marker states, so a caller
# never needs to know which shape a credential uses and never needs migration to
# have run. Values are unquoted the way `source` would: single- and double-quoted
# values are stripped and unescaped, and an unquoted value ends at its first
# whitespace, which is also what discards a trailing `# comment`. The single line
# of a bare, unmigrated file is returned verbatim, because nothing sources it.
# `reveal` writes the value followed by one newline.
#
# Overrides for tests and specialized setups: FM_HOME, FM_CONFIG_OVERRIDE,
# FM_SECRETS_OVERRIDE (the store directory itself).
#
# Exit status: 0 success, 1 error, 2 usage, 3 the store is absent.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECRETS="${FM_SECRETS_OVERRIDE:-$CONFIG/secrets}"

MARKER='# fm-secret v1'
KEY_LINE_RE='^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*='

SECRET_LINES=()
SECRET_CONTENT=()

usage() {
  cat <<'USAGE'
Usage:
  fm-secret.sh list                         credential names held in the store
  fm-secret.sh names <credential>           key names, or the reference name, inside one credential
  fm-secret.sh reveal <credential> <key>    exactly one value, on stdout
  fm-secret.sh migrate [--apply]            report, or perform, the store migration
  fm-secret.sh migrate --keyed <credential> declare one ambiguous credential a KEY=value file
  fm-secret.sh migrate --bare <credential>  declare one ambiguous credential a single unlabelled value

Never inspect a credential file with a generic text command: a bare value
matches a key-shaped pattern and prints itself. Use names, then reveal.
USAGE
}

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

# A credential name is a relative path of plain segments under the store. It can
# never climb out of the store, and the file it names must be a regular file and
# not a symlink, so a planted link cannot redirect a read outside the store.
secret_name_valid() {
  local name=$1 seg
  [ -n "$name" ] || return 1
  case $name in /*|*/) return 1 ;; esac
  local -a segs=()
  IFS='/' read -r -a segs <<< "$name"
  for seg in "${segs[@]}"; do
    if [ -z "$seg" ] || [ "$seg" = '.' ] || [ "$seg" = '..' ]; then
      return 1
    fi
    case $seg in *[!A-Za-z0-9._~-]*) return 1 ;; esac
  done
  return 0
}

secret_resolve() {
  local name=$1 path
  secret_name_valid "$name" || die "invalid credential name" 2
  path="$SECRETS/$name"
  [ -e "$path" ] || die "no such credential: $name"
  [ ! -L "$path" ] || die "credential is a symbolic link: $name"
  [ -f "$path" ] || die "credential is not a regular file: $name"
  [ -r "$path" ] || die "credential is not readable: $name"
  printf '%s\n' "$path"
}

# Derived from the FILENAME only. No byte of the file's contents reaches this.
secret_ref_name() {
  local base=${1##*/} ref
  ref=${base^^}
  ref=${ref//[^A-Z0-9_]/_}
  case $ref in [0-9]*) ref=_$ref ;; esac
  printf '%s\n' "$ref"
}

# Read a file into SECRET_LINES, tolerating a missing final newline.
secret_read_lines() {
  local path=$1 line
  SECRET_LINES=()
  while IFS= read -r line || [ -n "$line" ]; do
    SECRET_LINES+=("$line")
  done < "$path"
}

secret_trim_left() {
  local s=$1
  printf '%s' "${s#"${s%%[![:space:]]*}"}"
}

# True when the file's first non-blank line is exactly the marker.
secret_is_marked() {
  local line
  for line in ${SECRET_LINES[@]+"${SECRET_LINES[@]}"}; do
    [ -n "${line//[[:space:]]/}" ] || continue
    [ "$line" = "$MARKER" ]
    return $?
  done
  return 1
}

# Lines that are neither blank nor a comment: the lines that carry content.
secret_content_lines() {
  local line trimmed
  SECRET_CONTENT=()
  for line in ${SECRET_LINES[@]+"${SECRET_LINES[@]}"}; do
    [ -n "${line//[[:space:]]/}" ] || continue
    trimmed=$(secret_trim_left "$line")
    case $trimmed in '#'*) continue ;; esac
    SECRET_CONTENT+=("$line")
  done
}

# Unquote one `KEY=` right-hand side the way `source` would.
secret_unquote() {
  local v=$1 out='' i ch next
  case $v in
    "'"*)
      v=${v#\'}
      case $v in *"'") v=${v%\'} ;; esac
      printf '%s' "${v//\'\\\'\'/\'}"
      return 0
      ;;
    '"'*)
      v=${v#\"}
      case $v in *'"') v=${v%\"} ;; esac
      for (( i = 0; i < ${#v}; i++ )); do
        ch=${v:i:1}
        if [ "$ch" = "\\" ] && [ $((i + 1)) -lt ${#v} ]; then
          next=${v:i+1:1}
          if [ "$next" = '"' ] || [ "$next" = "\\" ] || [ "$next" = '$' ] || [ "$next" = '`' ]; then
            out+=$next; i=$((i + 1)); continue
          fi
        fi
        out+=$ch
      done
      printf '%s' "$out"
      return 0
      ;;
  esac
  # Unquoted: `source` ends the assignment at the first whitespace, which is also
  # what discards a trailing `# comment`.
  printf '%s' "${v%%[[:space:]]*}"
}

# Key names of a MIGRATED file. The capture requires a literal `=` and keeps only
# the run before it, so no value byte can reach stdout.
secret_keys_at() {
  local path=$1
  sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$path"
}

# One value, by path and key. Handles both shapes and both marker states. Writes
# the value with no trailing newline so a caller can compare it exactly.
secret_value_at() {
  local path=$1 key=$2 name=$3 line rest ref
  secret_read_lines "$path"
  for line in ${SECRET_LINES[@]+"${SECRET_LINES[@]}"}; do
    [[ $line =~ $KEY_LINE_RE ]] || continue
    rest=$(secret_trim_left "$line")
    case $rest in export[[:space:]]*) rest=$(secret_trim_left "${rest#export}") ;; esac
    [ "${rest%%=*}" = "$key" ] || continue
    secret_unquote "${rest#*=}"
    return 0
  done
  secret_content_lines
  ref=$(secret_ref_name "$name")
  if [ "$key" = "$ref" ] && [ "${#SECRET_CONTENT[@]}" -eq 1 ] \
    && ! [[ ${SECRET_CONTENT[0]} =~ $KEY_LINE_RE ]]; then
    # Unmigrated bare value: the single content line IS the value, verbatim.
    # A key-shaped line is excluded, so `KEY=value` is never returned whole.
    printf '%s' "${SECRET_CONTENT[0]}"
    return 0
  fi
  return 1
}

cmd_list() {
  [ -d "$SECRETS" ] || die "credential store is absent: $SECRETS" 3
  ( cd "$SECRETS" && find . -type f -print 2>/dev/null ) \
    | sed 's|^\./||' \
    | LC_ALL=C sort
}

cmd_names() {
  local name=$1 path shape ref
  path=$(secret_resolve "$name") || exit $?
  secret_read_lines "$path"
  if secret_is_marked; then
    secret_keys_at "$path"
    return 0
  fi
  shape=$(secret_shape "$path")
  case $shape in
    empty) die "credential holds no value: $name" ;;
    bare)
      # The single line carries no key, so the reference name derived from the
      # FILENAME is the whole listing. No file byte reaches stdout.
      ref=$(secret_ref_name "$name")
      printf '%s\n' "$ref"
      printf 'note: %s is not migrated. It holds one unlabelled value, which reveal accepts under %s. Run: fm-secret.sh migrate --apply\n' \
        "$name" "$ref" >&2
      ;;
    keyed)
      # More than one content line, every one of them a KEY= line. A single
      # unlabelled value cannot take this shape, so enumerating is safe.
      secret_keys_at "$path"
      printf 'note: %s is not migrated; its keys were read from its shape. Run: fm-secret.sh migrate --apply\n' \
        "$name" >&2
      ;;
    ambiguous)
      # One content line that is ALSO key-shaped. Deciding which it is would
      # mean reading it, and a bare value ending in `=` padding reads exactly
      # like a key. Emit nothing from the file and make the operator declare it.
      printf 'error: %s holds one line that could be either a KEY=value pair or an unlabelled value, and telling them apart would mean printing it. Declare it with: fm-secret.sh migrate --keyed %s  (or --bare %s)\n' \
        "$name" "$name" "$name" >&2
      exit 1
      ;;
    *) die "credential has an unrecognized shape: $name" ;;
  esac
}

cmd_reveal() {
  local name=$1 key=$2 path
  case $key in
    ''|[0-9]*|*[!A-Za-z0-9_]*) die "invalid key name" 2 ;;
  esac
  path=$(secret_resolve "$name") || exit $?
  if secret_value_at "$path" "$key" "$name"; then
    printf '\n'
    return 0
  fi
  die "credential $name holds no key $key"
}

# Classify an UNMARKED credential without letting any of its bytes decide an
# output string. Echoes one of: empty, bare, keyed, ambiguous, unrecognized.
#
#   empty        no content line at all
#   bare         exactly one content line, and it is NOT key-shaped
#   keyed        more than one content line, every one of them key-shaped
#   ambiguous    exactly one content line, and it IS key-shaped. It could be a
#                real `KEY=value` pair or an unlabelled value that happens to
#                read like one - a base64 secret ending in `=` padding does.
#                Nothing may guess: the operator declares it.
#   unrecognized anything else
secret_shape() {
  local path=$1 line all_keyed=1
  secret_read_lines "$path"
  secret_content_lines
  if [ "${#SECRET_CONTENT[@]}" -eq 0 ]; then printf 'empty\n'; return 0; fi
  for line in "${SECRET_CONTENT[@]}"; do
    if ! [[ $line =~ $KEY_LINE_RE ]]; then all_keyed=0; break; fi
  done
  if [ "${#SECRET_CONTENT[@]}" -eq 1 ]; then
    if [ "$all_keyed" -eq 1 ]; then printf 'ambiguous\n'; else printf 'bare\n'; fi
    return 0
  fi
  if [ "$all_keyed" -eq 1 ]; then printf 'keyed\n'; else printf 'unrecognized\n'; fi
}

# Single-quote a value for a `KEY=` line so `source` restores it byte for byte.
secret_squote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

# Rewrite one credential, but only after proving every value still reads back
# identically from the replacement. The comparison happens in this process; no
# value is ever printed. `keyed` only prepends the marker; `bare` relabels the
# single unlabelled line under the key derived from the filename.
secret_apply() {
  local path=$1 name=$2 action=$3 ref=$4 tmp dir key before after rc=0
  dir=${path%/*}
  tmp=$(mktemp "$dir/.fm-secret.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if [ "$action" = keyed ]; then
    { printf '%s\n' "$MARKER"; cat -- "$path"; } > "$tmp" || rc=1
  else
    secret_read_lines "$path"
    secret_content_lines
    { printf '%s\n' "$MARKER"
      printf '%s=%s\n' "$ref" "$(secret_squote "${SECRET_CONTENT[0]}")"
    } > "$tmp" || rc=1
  fi
  if [ "$rc" -eq 0 ] && [ "$action" = keyed ]; then
    # Every key the replacement exposes must reveal what the original revealed.
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      before=$(secret_value_at "$path" "$key" "$name") || { rc=1; break; }
      after=$(secret_value_at "$tmp" "$key" "$name") || { rc=1; break; }
      [ "$before" = "$after" ] || { rc=1; break; }
    done < <(secret_keys_at "$tmp")
  fi
  if [ "$rc" -eq 0 ] && [ "$action" = bare ]; then
    # The original line is the value by definition here, so it is compared
    # directly: looking it up in the original would fail for exactly the
    # key-shaped values `--bare` exists to relabel. The replacement must also
    # expose that one derived key and nothing else.
    before=${SECRET_CONTENT[0]}
    after=$(secret_value_at "$tmp" "$ref" "$name") || rc=1
    [ "$rc" -ne 0 ] || [ "$before" = "$after" ] || rc=1
    [ "$rc" -ne 0 ] || [ "$(secret_keys_at "$tmp")" = "$ref" ] || rc=1
  fi
  if [ "$rc" -ne 0 ]; then rm -f -- "$tmp"; return 1; fi
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$path" || return 1
  return 0
}

secret_migrate_one() {
  local name=$1 action=$2 path ref
  path=$(secret_resolve "$name") || exit $?
  secret_read_lines "$path"
  if secret_is_marked; then
    printf '%s is already migrated; nothing to declare.\n' "$name"
    return 0
  fi
  case $(secret_shape "$path") in
    ambiguous) : ;;
    bare)
      [ "$action" = bare ] || die "$name holds one unlabelled line, so it is not keyed; migrate handles it without a declaration"
      ;;
    keyed)
      [ "$action" = keyed ] || die "$name holds several KEY=value lines, so it is not one unlabelled value"
      ;;
    empty) die "$name holds no value" ;;
    *) die "$name has an unrecognized shape" ;;
  esac
  ref=$(secret_ref_name "$name")
  if secret_apply "$path" "$name" "$action" "$ref"; then
    if [ "$action" = keyed ]; then
      printf '%s marked as keyed.\n' "$name"
    else
      printf '%s relabelled under key %s.\n' "$name" "$ref"
    fi
    return 0
  fi
  die "$name could not be rewritten; it is unchanged"
}

cmd_migrate() {
  local apply=0 name path shape ref status=0
  case "${1:-}" in
    '') : ;;
    --apply) apply=1 ;;
    --keyed|--bare)
      [ -n "${2:-}" ] || { usage >&2; exit 2; }
      secret_migrate_one "$2" "${1#--}"
      return $?
      ;;
    *) usage >&2; exit 2 ;;
  esac
  [ -d "$SECRETS" ] || die "credential store is absent: $SECRETS" 3
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case ${name##*/} in .fm-secret.*) continue ;; esac
    if ! secret_name_valid "$name"; then
      printf '%-40s skipped, name not supported\n' "$name"; status=1; continue
    fi
    path="$SECRETS/$name"
    if [ ! -f "$path" ] || [ -L "$path" ]; then
      printf '%-40s skipped, not a regular file\n' "$name"; status=1; continue
    fi
    secret_read_lines "$path"
    if secret_is_marked; then
      printf '%-40s already migrated\n' "$name"
      continue
    fi
    shape=$(secret_shape "$path")
    ref=$(secret_ref_name "$name")
    case $shape in
      empty)
        printf '%-40s HOLDS NO VALUE, left for the captain\n' "$name"; status=1 ;;
      unrecognized)
        printf '%-40s UNRECOGNIZED SHAPE, not changed, report it\n' "$name"; status=1 ;;
      ambiguous)
        printf '%-40s AMBIGUOUS, declare it: migrate --keyed %s | --bare %s\n' "$name" "$name" "$name"
        status=1 ;;
      bare|keyed)
        if [ "$apply" -eq 0 ]; then
          if [ "$shape" = keyed ]; then
            printf '%-40s would mark, keys unchanged\n' "$name"
          else
            printf '%-40s would relabel its unlabelled value under %s\n' "$name" "$ref"
          fi
        elif secret_apply "$path" "$name" "$shape" "$ref"; then
          if [ "$shape" = keyed ]; then
            printf '%-40s marked\n' "$name"
          else
            printf '%-40s relabelled under %s\n' "$name" "$ref"
          fi
        else
          printf '%-40s FAILED, left unchanged\n' "$name"; status=1
        fi
        ;;
    esac
  done < <(cmd_list)
  if [ "$apply" -eq 0 ]; then
    printf '\nThis was a report. Re-run with --apply to change the store.\n'
  fi
  return "$status"
}

case "${1:-}" in
  list) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_list ;;
  names) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; cmd_names "$2" ;;
  reveal) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; cmd_reveal "$2" "$3" ;;
  migrate) [ "$#" -le 3 ] || { usage >&2; exit 2; }; cmd_migrate "${2:-}" "${3:-}" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
