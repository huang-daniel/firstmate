#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECRETS="${FM_SECRETS_OVERRIDE:-$CONFIG/secrets}"

while [[ $SECRETS = *//* ]]; do SECRETS=${SECRETS//\/\//\/}; done
while [[ $SECRETS = */ && $SECRETS != / ]]; do SECRETS=${SECRETS%/}; done
[[ $SECRETS = /* ]] || SECRETS="$PWD/$SECRETS"
if [ -d "$SECRETS" ]; then
  SECRETS=$(cd -- "$SECRETS" && pwd -P) || exit 1
fi
if [ "$SECRETS" = / ] || [ "${SECRETS##*/}" = secret-values ]; then
  printf 'error: credential store must have a distinct sibling value store\n' >&2
  exit 2
fi
VALUES="${SECRETS%/*}/secret-values"
MARKER='# fm-secret v2'
KEY_LINE_RE='^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*='

SECRET_LINES=()
SECRET_CONTENT=()

usage() {
  cat <<'USAGE'
Usage:
  fm-secret.sh list                         credential names held in the store
  fm-secret.sh names <credential>           key names, or the reference name, inside one credential
  fm-secret.sh reveal <credential> <key>    exactly one value, on stdout
  fm-secret.sh export <credential>          shell-quoted assignments, on stdout
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

secret_path_under() {
  local root=$1 name=$2 path part
  secret_name_valid "$name" || return 1
  [ ! -L "$root" ] || return 1
  path=$root
  local -a parts=()
  IFS=/ read -r -a parts <<< "$name"
  for part in "${parts[@]}"; do
    path+=/$part
    [ ! -L "$path" ] || return 1
  done
  printf '%s\n' "$path"
}

secret_resolve() {
  local name=$1 path
  secret_name_valid "$name" || die "invalid credential name" 2
  path=$(secret_path_under "$SECRETS" "$name") || die "credential path contains a symbolic link: $name"
  [ -e "$path" ] || die "no such credential: $name"
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

secret_unquote() {
  local v=$1 out='' quote='' i ch next tail
  for (( i=0; i<${#v}; i++ )); do
    ch=${v:i:1}
    if [ "$quote" = "'" ]; then
      if [ "$ch" = "'" ]; then quote=''; else out+=$ch; fi
    elif [ "$ch" = "\\" ]; then
      i=$((i + 1))
      [ "$i" -lt "${#v}" ] || return 1
      next=${v:i:1}
      if [ "$quote" = '"' ] && [[ $next != [\\\"\$\`] ]]; then out+='\'; fi
      out+=$next
    elif [ "$ch" = "$quote" ]; then
      quote=''
    elif [ -z "$quote" ] && { [ "$ch" = "'" ] || [ "$ch" = '"' ]; }; then
      quote=$ch
    elif [ -z "$quote" ] && [[ $ch = [[:space:]] ]]; then
      tail=$(secret_trim_left "${v:i}")
      [[ -z $tail || $tail = '#'* ]] || return 1
      break
    else
      out+=$ch
    fi
  done
  [ -z "$quote" ] || return 1
  printf '%s' "$out"
}

secret_manifest_keys() {
  local line
  [ "${SECRET_LINES[0]:-}" = "$MARKER" ] || return 1
  for line in "${SECRET_LINES[@]:1}"; do
    [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  done
  printf '%s\n' "${SECRET_LINES[@]:1}"
}

secret_value_file() {
  local name=$1 key=$2 path
  path=$(secret_path_under "$VALUES" "$name/$key") || return 1
  [ -f "$path" ] || return 1
  cat -- "$path"
}

secret_keys_at() {
  local path=$1
  sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$path"
}

# One value, by path and key. Handles both shapes and both marker states. Writes
# the value with no trailing newline so a caller can compare it exactly.
secret_value_at() {
  local path=$1 key=$2 name=$3 line rest ref
  secret_read_lines "$path"
  if secret_is_marked; then
    secret_manifest_keys >/dev/null || return 1
    for line in "${SECRET_LINES[@]:1}"; do
      [ "$line" != "$key" ] || { secret_value_file "$name" "$key"; return $?; }
    done
    return 1
  fi
  for line in ${SECRET_LINES[@]+"${SECRET_LINES[@]}"}; do
    [[ $line =~ $KEY_LINE_RE ]] || continue
    rest=$(secret_trim_left "$line")
    case $rest in export[[:space:]]*) rest=$(secret_trim_left "${rest#export}") ;; esac
    [ "${rest%%=*}" = "$key" ] || continue
    secret_unquote "${rest#*=}"
    return $?
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
    secret_manifest_keys || die "invalid credential manifest"
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

secret_published_matches() (
  local expected=$1 published=$2 file
  [ -d "$published" ] && [ ! -L "$published" ] || return 1
  shopt -s nullglob dotglob
  local -a expected_files=("$expected"/*) published_files=("$published"/*)
  [ "${#expected_files[@]}" -eq "${#published_files[@]}" ] || return 1
  for file in "${published_files[@]}"; do
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    cmp -s -- "$expected/${file##*/}" "$file" || return 1
  done
)

secret_apply() (
  local path=$1 name=$2 action=$3 ref=$4 tmp stage key value parent part
  umask 077
  secret_path_under "$VALUES" "$name" >/dev/null || {
    printf 'error: published values conflict for credential %s\n' "$name" >&2
    return 1
  }
  mkdir -p -- "$VALUES" || return 1
  chmod 0700 "$VALUES" || return 1
  parent=$VALUES
  local -a parts=()
  IFS=/ read -r -a parts <<< "$name"
  for part in "${parts[@]:0:${#parts[@]}-1}"; do
    parent+=/$part
    mkdir -p -- "$parent" && chmod 0700 "$parent" || return 1
  done
  stage=$(mktemp -d "$VALUES/.fm-secret.XXXXXX") || return 1
  tmp=$(mktemp "${path%/*}/.fm-secret.XXXXXX") || { rm -rf -- "$stage"; return 1; }
  trap '[ -z "$stage" ] || rm -rf -- "$stage"; rm -f -- "$tmp"' EXIT
  printf '%s\n' "$MARKER" > "$tmp" || return 1
  local -a keys=()
  if [ "$action" = keyed ]; then
    while IFS= read -r key; do keys+=("$key"); done < <(secret_keys_at "$path")
  else
    keys=("$ref")
  fi
  for key in "${keys[@]}"; do
    [ ! -e "$stage/$key" ] || return 1
    if [ "$action" = keyed ]; then
      value=$(secret_value_at "$path" "$key" "$name") || return 1
    else
      secret_read_lines "$path"
      secret_content_lines
      value=${SECRET_CONTENT[0]}
    fi
    printf '%s' "$value" > "$stage/$key" || return 1
    chmod 0600 "$stage/$key" || return 1
    cmp -s "$stage/$key" <(printf '%s' "$value") || return 1
    printf '%s\n' "$key" >> "$tmp" || return 1
  done
  chmod 0600 "$tmp" || return 1
  if [ -e "$VALUES/$name" ] || [ -L "$VALUES/$name" ]; then
    if ! secret_published_matches "$stage" "$VALUES/$name"; then
      printf 'error: published values conflict for credential %s\n' "$name" >&2
      return 1
    fi
    chmod 0700 "$VALUES/$name" || return 1
    for key in "${keys[@]}"; do chmod 0600 "$VALUES/$name/$key" || return 1; done
  else
    mv -- "$stage" "$VALUES/$name" || return 1
    stage=''
  fi
  mv -f -- "$tmp" "$path" || return 1
)

cmd_export() {
  local name=$1 path key value output=''
  path=$(secret_resolve "$name") || exit $?
  secret_read_lines "$path"
  secret_is_marked || die "migrate credential before export: $name"
  secret_manifest_keys >/dev/null || die "invalid credential manifest"
  for key in "${SECRET_LINES[@]:1}"; do
    value=$(secret_value_file "$name" "$key"; rc=$?; printf '.'; exit "$rc") || die "cannot read credential value"
    value=${value%.}
    output+="$key=$(secret_squote "$value")"$'\n'
  done
  printf '%s' "$output"
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
  export) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; cmd_export "$2" ;;
  reveal) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; cmd_reveal "$2" "$3" ;;
  migrate) [ "$#" -le 3 ] || { usage >&2; exit 2; }; cmd_migrate "${2:-}" "${3:-}" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
