#!/usr/bin/env bash
# tests/fm-board.test.sh - the board-to-backlog bridge's correctness properties.
#
# Four of these are load-bearing rather than incidental. Importing an issue twice
# must never produce two tasks, and the record that prevents it has to outlive
# the task it names. A card the captain moved is an instruction, so a sync that
# "corrects" it back is the defect this suite is written to catch. A board write
# that fails must degrade to a stale board instead of blocking delivery. And a
# withdrawn card must stop the work without touching it, so both withdrawal cases
# - the card pulled off the board and the issue closed under a card that stayed -
# run against a real repository with real unlanded changes and prove they survive.
#
# Every board here is invented for the case at hand - different owners, project
# numbers, labels, status fields, and column names - because the adapter is a
# firstmate capability rather than any one project's integration, and a fixture
# that reused one canonical board would not show that.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-board)

# --- fixture plumbing -------------------------------------------------------

# THE JQ HARNESS.
#
# The adapter asks GitHub for whole GraphQL documents and reduces them with three
# filters it generates itself: fields_jq, which finds the project and the wanted
# status field among every field on the board, card_jq, which picks this board's
# card out of every board the issue sits on, and items_jq, which turns one page of
# the board into one line per card. A stub that printed the
# already-reduced answer would stand in for those filters rather than run them,
# and both could rot to nothing while the suite stayed green - every write path
# would then report `stale` against real GitHub forever.
#
# So the stubs below emit the response shape GitHub actually returns and pipe it
# through the adapter's own `--jq` expression with real jq. Each payload carries
# a decoy the wanted thing has to be told apart from, which is what makes the
# guard bidirectional: a selector matching nothing fails, and so does a selector
# matching everything. The card payload carries one entry per board the home
# configures, plus a card on a project no board configures sitting ahead of them
# all. The ids payload carries an empty node, which is how GitHub renders a
# field that is not single-select, and a second single-select field after the
# wanted one - after, because the adapter keeps the last field it matches, so an
# unfiltered selector comes away with the decoy's id.
#
# WHAT IT HAS BEEN SEEN TO CATCH. A guard nobody has watched fail is not yet a
# guard, so each of these was broken once, run, and restored. The first failure
# each produced:
#
#   card_jq's owner selector never matches
#     fm-board: dispatch did not move the card (missing `synced tidewheel ...`)
#     fm-board-dispatch: the card was never moved to In Progress
#     fm-pr-merge: a confirmed merge did not close the card on the board
#   card_jq's project number selector never matches
#     the same three failures, one per suite
#   fields_jq's .data.repositoryOwner.projectV2 path renamed
#     the same three failures, one per suite
#   card_jq's selector replaced by select(true), so the decoy wins
#     fm-board: the dispatch write did not set this board's own In Progress
#     option, having written the decoy's card id against the wrong board
#   fields_jq's name selector replaced by select(true), so the decoy field wins
#     fm-board: the dispatch write did not set this board's own In Progress
#     option, having named the decoy field rather than the board's own
#   fields_jq's `.name // ""` reduced to `.name`, dropping the empty-node guard
#     fm-board: dispatch did not move the card (missing `synced tidewheel ...`)
#   the closed-issue withdrawal check disabled entirely
#     fm-board: a closed issue holding queued work was not reported as withdrawn
#   that check's desired-state gate removed, so it fires on every closed issue
#     fm-board: closing a finished task's issue was reported as a withdrawal
#
# The middle three fail in this suite alone, because its fixtures are the only
# ones configuring a board whose own field and card a decoy can be mistaken for.

# new_home <name>: create an isolated firstmate home with a stub GitHub CLI.
new_home() {
  local home
  home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/bin"
  cat > "$home/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
l_prev=''
# The adapter's two flat reads are both `gh api graphql`, so they are told apart
# by what they ask for, exactly as a reader of the log has to tell them apart:
# `graphql card` resolves one issue's card, `graphql ids` resolves the project
# and its status field. GH_FAIL names either one.
# gh_jq_filter <args...>: the --jq expression the adapter passed. A real gh
# applies it to the response; so does this stub, which is what puts the
# adapter's own translation filters under test instead of around them.
gh_jq_filter() {
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --jq ]; then
      printf '%s' "${2:-}"
      return 0
    fi
    shift
  done
  printf '.'
}
command -v jq >/dev/null || { printf 'stub gh: jq is required\n' >&2; exit 9; }
# board_apply_edit <item-id> <option-id>: set that card's value for whichever
# field the option belongs to, exactly as the real board would.
board_apply_edit() {
  local e_id=$1 e_option=$2 e_name e_col e_tmp
  [ -n "$e_option" ] || return 0
  e_name=$(awk -F'\t' -v o="$e_option" '$1 == "option" && $2 == o { print $3 }' "$GH_FIELDS")
  e_col=$(awk -F'\t' -v o="$e_option" '
    $1 == "option" && $2 == o { f = $4 }
    $1 == "field" { col[$2] = $4 }
    END { print (f in col ? col[f] : 4) }
  ' "$GH_FIELDS")
  e_tmp=$(mktemp)
  awk -F'\t' -v OFS='\t' -v id="$e_id" -v s="$e_name" -v c="$e_col" \
    '$1 == id { $c = s } { print }' "$GH_ITEMS" > "$e_tmp"
  mv "$e_tmp" "$GH_ITEMS"
}
kind="$1 $2"
if [ "$kind" = "api graphql" ]; then
  case "$*" in
    *updateProjectV2ItemFieldValue*) kind="graphql write" ;;
    *projectItems*) kind="graphql card" ;;
    # The board read names the owner exactly as the id read does, so it is
    # matched first, on the pagination cursor only it carries.
    *'endCursor'*) kind="graphql items" ;;
    *repositoryOwner*) kind="graphql ids" ;;
  esac
fi
# One line per call, unlike the argument log, whose GraphQL documents span many.
# Counting these is how the cost guard sees what an invocation actually spent.
printf '%s\n' "$kind" >> "$GH_CALLS"
if [ -n "${GH_FAIL:-}" ]; then
  case "$kind" in
    $GH_FAIL)
      printf 'simulated GitHub failure\n' >&2
      exit 1
      ;;
  esac
fi
case "$kind" in
  "graphql items")
    # The real response shape, reduced by the adapter's own filter. A board read
    # carries every single-select field the board sets on a card as one of that
    # card's own field values, so this is where the adapter's own translation of
    # a card's column, its classification, and its issue state is put under test
    # rather than stood in for. The payload carries a decoy field value beside
    # them, so a selector matching everything comes away with the decoy exactly
    # as it does above.
    #
    # A card's state is the issue's own, `open` unless the fixture closed it, and
    # absent altogether on a card with no issue behind it - which is how GitHub
    # answers a draft card and is the case the state column must read as `-`.
    {
      printf '{"data":{"repositoryOwner":{"projectV2":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":['
      awk -F'\t' '
        function esc(v) { gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v); return v }
        function names(v, key,   parts, n, i, out) {
          if (v == "-" || v == "") return "{\"nodes\":[]}"
          n = split(v, parts, ",")
          out = "{\"nodes\":["
          for (i = 1; i <= n; i++) {
            out = out (i > 1 ? "," : "") "{\"" key "\":\"" esc(parts[i]) "\"}"
          }
          return out "]}"
        }
        function value(name, v) {
          if (name == "" || v == "-") return ""
          return ",{\"name\":\"" esc(v) "\",\"field\":{\"name\":\"" esc(name) "\"}}"
        }
        # The field names come from the fixture itself, read ahead of the cards.
        FILENAME == fieldsfile {
          if ($1 == "field") {
            if ($4 == 4) statusname = $3
            if ($4 == 9) classname = $3
          }
          next
        }
        NF == 0 { next }
        {
          if (nr++) printf ","
          printf "{\"id\":\"%s\",\"fieldValues\":{\"pageInfo\":{\"hasNextPage\":false},\"nodes\":[{},{\"name\":\"decoy\",\"field\":{\"name\":\"Decoy Field\"}}%s%s]}", \
            esc($1), value(statusname, $4), value(classname, $9)
          printf ",\"content\":{\"__typename\":\"%s\",\"url\":\"%s\",\"title\":\"%s\",\"body\":\"%s\",\"labels\":%s,\"assignees\":%s", \
            esc($2), esc($3), esc($7), esc($8), names($5, "name"), names($6, "login")
          # GitHub answers this enum in upper case, which is why the adapter
          # normalizes it rather than comparing it as it arrives.
          if ($3 != "-" && $3 != "") printf ",\"state\":\"%s\"", ($10 == "" || $10 == "-" ? "OPEN" : toupper(esc($10)))
          printf "}}"
        }
      ' fieldsfile="$GH_FIELDS" "$GH_FIELDS" "$GH_ITEMS"
      printf ']}}}}}'
    } | jq -r "$(gh_jq_filter "$@")"
    ;;
  "graphql ids")
    # The real response shape, reduced by the adapter's own filter. The stub
    # never reproduces what that filter does; running it is the point.
    {
      printf '{"data":{"repositoryOwner":{"projectV2":{"id":"PVT_fixture","fields":{"nodes":['
      # A real board answers with every field, so the payload carries what one
      # looks like around the wanted field: an empty node, which is how GitHub
      # renders a field that is not single-select, and a second single-select
      # field after it. Together they are the negative case for the name
      # selector - stop filtering by name and the decoy's id is the one that
      # survives - and for the empty-node guard that keeps jq from indexing it.
      printf '{},'
      awk -F'\t' '
        function closefield() { if (inf) { printf "]}"; inf = 0 } }
        $1 == "field" {
          closefield()
          if (nf++) printf ","
          printf "{\"id\":\"%s\",\"name\":\"%s\",\"options\":[", $2, $3
          inf = 1; no = 0
        }
        $1 == "option" {
          if (no++) printf ","
          printf "{\"id\":\"%s\",\"name\":\"%s\"}", $2, $3
        }
        END { closefield() }
      ' "$GH_FIELDS"
      printf ',{"id":"PVTSSF_decoy","name":"Not The Status Field","options":[{"id":"opt_decoy","name":"Todo"}]}'
      printf ']}}}}}'
    } | jq -r "$(gh_jq_filter "$@")"
    ;;
  "graphql card")
    # Every board this home configures carries the same card, exactly as the
    # whole-board read answers for each of them, and one card from a project no
    # board configures sits ahead of them all. So the adapter's filter has to
    # both find its own board and decline the one that is not it.
    g_owner=''; g_name=''; g_number=''
    for g_arg in "$@"; do
      case "$g_arg" in
        owner=*) g_owner=${g_arg#owner=} ;;
        name=*) g_name=${g_arg#name=} ;;
        number=*) g_number=${g_arg#number=} ;;
      esac
    done
    g_url="https://github.com/$g_owner/$g_name/issues/$g_number"
    g_id=$(awk -F'\t' -v u="$g_url" '$3 == u { print $1; exit }' "$GH_ITEMS")
    {
      printf '{"data":{"repository":{"issue":'
      if [ -z "$g_id" ]; then
        printf 'null'
      else
        printf '{"projectItems":{"nodes":['
        printf '{"id":"PVTI_not_this_board","project":{"number":9999,"owner":{"login":"no-such-owner"}}}'
        awk -F'=' -v id="$g_id" '
          /^[[:space:]]*owner[[:space:]]*=/ { o = $2; gsub(/^[ \t]+|[ \t]+$/, "", o) }
          /^[[:space:]]*number[[:space:]]*=/ {
            n = $2; gsub(/^[ \t]+|[ \t]+$/, "", n)
            if (o != "") printf ",{\"id\":\"%s\",\"project\":{\"number\":%s,\"owner\":{\"login\":\"%s\"}}}", id, n, o
          }
        ' "$GH_BOARDS"
        printf ']}}'
      fi
      printf '}}}'
    } | jq --rawfile fields "$GH_FIELDS" --rawfile items "$GH_ITEMS" '
      ($fields | split("\n") | map(split("\t"))
       | map(select(.[0] == "field"))) as $fields
      | ($items | split("\n") | map(split("\t"))) as $items
      | if .data.repository.issue != null then
          .data.repository.issue.projectItems.nodes |= map(
            .id as $id
            | ([$items[] | select(.[0] == $id)] | first // []) as $item
            | .fieldValues = {
                nodes: [$fields[]
                  | . as $field
                  | ($item[($field[3] | tonumber) - 1] // "-") as $value
                  | select($value != "-" and $value != "")
                  | {name: $value, field: {name: $field[2]}}],
                pageInfo: {hasNextPage: false}
              })
        else . end
    ' | jq -r "$(gh_jq_filter "$@")"
    ;;
  "project item-edit")
    # Behave like the real board: the edit is visible to the next read, and it
    # lands in the column the edited field owns rather than always in the first
    # one - which is what makes writing the wrong field a visible failure.
    edit_id=''
    edit_option=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --id) edit_id=$2; shift 2 ;;
        --single-select-option-id) edit_option=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    board_apply_edit "$edit_id" "$edit_option"
    ;;
  "graphql write")
    # The two-field write: one document, both mutations, applied in order.
    w_item=''; w_a=''; w_b=''
    for w_arg in "$@"; do
      case "$w_arg" in
        item=*) w_item=${w_arg#item=} ;;
        optionA=*) w_a=${w_arg#optionA=} ;;
        optionB=*) w_b=${w_arg#optionB=} ;;
      esac
    done
    board_apply_edit "$w_item" "$w_a"
    board_apply_edit "$w_item" "$w_b"
    printf '{}\n'
    ;;
  "issue comment") : ;;
  "issue create")
    # A real create: allocate the next number in the named repo, store the
    # issue, and print its URL, exactly as gh does.
    c_repo=''; c_title=''; c_body=''; c_labels=''; c_parent='-'
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo) c_repo=$2; shift 2 ;;
        --title) c_title=$2; shift 2 ;;
        --body) c_body=$2; shift 2 ;;
        --label) c_labels=$2; shift 2 ;;
        --parent) c_parent=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "${GH_NO_LABEL:-}" ] && [ "$c_labels" = "$GH_NO_LABEL" ]; then
      printf 'label %s not found\n' "$c_labels" >&2
      exit 1
    fi
    c_next=$(( $(wc -l < "$GH_ISSUES") + 900 ))
    c_url="https://github.com/$c_repo/issues/$c_next"
    printf '%s\t%s\t%s\t%s\t%s\t%s\topen\n' "$c_repo" "$c_url" "$c_title" \
      "$(printf '%s' "$c_body" | tr '\n' ' ')" "$c_labels" "$c_parent" >> "$GH_ISSUES"
    printf '%s\n' "$c_url"
    ;;
  "issue list")
    # Only the shape the adapter asks for: url and body, newest first.
    l_repo=''
    for l_arg in "$@"; do
      case "$l_prev" in
        --repo) l_repo=$l_arg ;;
      esac
      l_prev=$l_arg
    done
    awk -F'\t' -v OFS='\t' -v r="$l_repo" '$1 == r { print $2, $4 }' "$GH_ISSUES" \
      | tac
    ;;
  "project item-add")
    a_url=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --url) a_url=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    a_id="PVTI_added$(wc -l < "$GH_ITEMS")"
    # A real board keeps a card with no status until one is set.
    a_title=$(awk -F'\t' -v u="$a_url" '$2 == u { print $3 }' "$GH_ISSUES")
    a_labels=$(awk -F'\t' -v u="$a_url" '$2 == u { print $5 }' "$GH_ISSUES")
    a_state=$(awk -F'\t' -v u="$a_url" '$2 == u { print $7 }' "$GH_ISSUES")
    printf '%s\tIssue\t%s\t-\t%s\t-\t%s\t-\t-\t%s\n' \
      "$a_id" "$a_url" "${a_labels:--}" "${a_title:--}" "${a_state:-open}" \
      >> "$GH_ITEMS"
    printf '%s\n' "$a_id"
    ;;
  "api repos/"*)
    api_path=$2
    case "$api_path" in
      repos/*/issues/*/sub_issues)
        api_repo=${api_path#repos/}
        api_repo=${api_repo%/issues/*}
        api_parent_number=${api_path%/sub_issues}
        api_parent_number=${api_parent_number##*/}
        api_parent="https://github.com/$api_repo/issues/$api_parent_number"
        if [ "${3:-}" = --method ]; then
          api_child_id=''
          while [ "$#" -gt 0 ]; do
            case "$1" in
              sub_issue_id=*) api_child_id=${1#sub_issue_id=} ;;
            esac
            shift
          done
          api_tmp=$(mktemp)
          awk -F'\t' -v OFS='\t' -v id="$api_child_id" -v p="$api_parent" \
            '$2 ~ ("/issues/" id "$") { $6 = p } { print }' "$GH_ISSUES" > "$api_tmp"
          mv "$api_tmp" "$GH_ISSUES"
        else
          # The real response shape, reduced by the adapter's own filter, for
          # the same reason the GraphQL stubs do it: the adapter asks this one
          # path for two different shapes, and a stub that answered the already
          # reduced form would stand in for both filters rather than run them.
          {
            printf '['
            awk -F'\t' -v p="$api_parent" '
              $6 == p {
                if (n++) printf ","
                printf "{\"html_url\":\"%s\",\"state\":\"%s\"}", $2, ($7 == "" ? "open" : $7)
              }
            ' "$GH_ISSUES"
            printf ']'
          } | jq -r "$(gh_jq_filter "$@")"
        fi
        ;;
      repos/*/issues/*)
        api_number=${api_path##*/}
        printf '%s\n' "$api_number"
        ;;
      *) exit 9 ;;
    esac
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 9
    ;;
esac
SH
  chmod +x "$home/bin/gh"
  : > "$home/gh.log"
  : > "$home/calls"
  : > "$home/items"
  : > "$home/fields"
  : > "$home/issues"
  printf '%s\n' "$home"
}

# board <home> <args...>: run the adapter against that home.
board() {
  local home=$1
  shift
  FM_HOME="$home" \
  FM_CONFIG_OVERRIDE="$home/config" \
  FM_DATA_OVERRIDE="$home/data" \
  FM_BOARD_GH="$home/bin/gh" \
  GH_LOG="$home/gh.log" \
  GH_CALLS="$home/calls" \
  GH_ITEMS="$home/items" \
  GH_BOARDS="$home/config/boards" \
  GH_FIELDS="$home/fields" \
  GH_ISSUES="$home/issues" \
  GH_FAIL="${GH_FAIL:-}" \
  GH_NO_LABEL="${GH_NO_LABEL:-}" \
    "$BOARD" "$@"
}

# item <home> <id> <type> <url> <status> <labels> <assignees> <title> <body>
#      [<classification>] [open|closed]
# The classification defaults to blank, which is what a real board shows for a
# card nobody has classified, and the issue behind the card is open unless the
# fixture says otherwise.
item() {
  local home=$1 class state
  shift
  class=${9:--}
  state=${10:-open}
  set -- "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" "$class" "$state" \
    >> "$home/items"
}

# close_card_issue <home> <url>: close the issue behind that card on GitHub,
# leaving the card exactly where it is. This is the withdrawal the board itself
# shows nothing of.
close_card_issue() {
  local home=$1 url=$2 tmp
  tmp=$(mktemp)
  awk -F'\t' -v OFS='\t' -v u="$url" '$3 == u { $10 = "closed" } { print }' \
    "$home/items" > "$tmp"
  mv "$tmp" "$home/items"
}

# sub_issue <home> <url> <parent> [open|closed]: an issue GitHub records as a
# sub-issue of that container, which firstmate did not create and holds no task
# for. This is the case the recorded children can never see, so a fixture that
# only ever used `child-add` could not show it.
sub_issue() {
  local home=$1 url=$2 parent=$3 state=${4:-open} repo
  repo=${url#https://github.com/}
  repo=${repo%%/issues/*}
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$repo" "$url" 'Attached on GitHub' '-' '-' "$parent" "$state" >> "$home/issues"
}

# close_sub_issue <home> <url>: close that issue on GitHub, the only signal a
# sub-issue firstmate holds no task for ever gives about being finished.
close_sub_issue() {
  local tmp
  tmp=$(mktemp)
  awk -F'\t' -v OFS='\t' -v u="$2" '$2 == u { $7 = "closed" } { print }' \
    "$1/issues" > "$tmp"
  mv "$tmp" "$1/issues"
}

# fields <home> [--name <field-name>] <field-id> <option-id:option-name>...
# The name defaults to Status because most fixtures configure that; a board
# whose status-field is called something else states it, since the adapter's own
# filter selects the field by name.
fields() {
  local home=$1 name=Status field spec
  shift
  if [ "$1" = --name ]; then
    name=$2
    shift 2
  fi
  field=$1
  shift
  # The trailing column is the card column this field's value lives in, which is
  # what lets the stub apply an edit to the right one once a board carries two
  # single-select fields. Each option carries its own field for the same reason.
  printf 'field\t%s\t%s\t4\n' "$field" "$name" > "$home/fields"
  for spec in "$@"; do
    printf 'option\t%s\t%s\t%s\n' "${spec%%:*}" "${spec#*:}" "$field" >> "$home/fields"
  done
}

# classify_field <home> <field-name> <field-id> <option-id:option-name>...
# A second single-select field on the same board, appended to the one above. The
# adapter reads both from one request, so a fixture that could only describe one
# could not show that.
classify_field() {
  local home=$1 name=$2 field=$3 spec
  shift 3
  printf 'field\t%s\t%s\t9\n' "$field" "$name" >> "$home/fields"
  for spec in "$@"; do
    printf 'option\t%s\t%s\t%s\n' "${spec%%:*}" "${spec#*:}" "$field" >> "$home/fields"
  done
}

gh_log() {
  cat "$1/gh.log"
}

# How many calls the adapter made, and how many of one kind.
gh_calls() {
  local n
  n=$(wc -l < "$1/calls")
  printf '%s\n' "$((n))"
}

gh_calls_of() {
  local n
  n=$(grep -c "^$2\$" "$1/calls" || true)
  printf '%s\n' "$((n))"
}

# --- a board with an ordinary shape, and one with an unusual one -------------

ordinary_board() {
  local home=$1
  cat > "$home/config/boards" <<'EOF'
project = harbourlight
owner = harbour-collective
number = 4
label = firstmate
EOF
  fields "$home" PVTSSF_status opt_todo:Todo 'opt_prog:In Progress' opt_done:Done
}

unusual_board() {
  local home=$1
  cat > "$home/config/boards" <<'EOF'
project = tidewheel
owner = personal-account
number = 91
repo = personal-account/tidewheel
label = take-it-mate
mention = @deckhand
assignee = deckhand-bot
status-field = Lane
todo = Waiting
in-progress = Under Way
done = Landed
EOF
  fields "$home" --name Lane PVTSSF_lane opt_wait:Waiting 'opt_under:Under Way' opt_landed:Landed
}

# An ordinary board that names the one repository its cards are filed in, which
# is what a board has to state before firstmate can file a card on it.
repo_board() {
  local home=$1
  cat > "$home/config/boards" <<'EOF'
project = harbourlight
owner = harbour-collective
number = 4
repo = harbour-collective/app
label = firstmate
EOF
  fields "$home" PVTSSF_status opt_todo:Todo 'opt_prog:In Progress' opt_done:Done
}

# An ordinary board that also carries the optional authorized-to-launch column.
queued_board() {
  local home=$1
  cat > "$home/config/boards" <<'EOF'
project = harbourlight
owner = harbour-collective
number = 4
label = firstmate
queued = Queued
EOF
  fields "$home" PVTSSF_status opt_todo:Todo opt_queued:Queued \
    'opt_prog:In Progress' opt_done:Done
}

# An ordinary board that also carries the optional internalized column, so
# ownership of a card alternates: Todo is the captain's inbox and Processed is
# firstmate's answer.
processed_board() {
  local home=$1
  cat > "$home/config/boards" <<'EOF'
project = harbourlight
owner = harbour-collective
number = 4
repo = harbour-collective/app
label = firstmate
processed = Processed
queued = Queued
EOF
  fields "$home" PVTSSF_status opt_todo:Todo opt_processed:Processed \
    opt_queued:Queued 'opt_prog:In Progress' opt_done:Done
}

# The same board with the container lane, named the way a board whose ordinary
# lane runs Todo -> Processed names it.
programme_board() {
  local home=$1
  cat > "$home/config/boards" <<'EOF'
project = harbourlight
owner = harbour-collective
number = 4
repo = harbour-collective/app
label = firstmate
processed = Processed
big-picture-todo = Big Picture Processed
big-picture-in-progress = Big Picture In Progress
big-picture-done = Big Picture Done
EOF
  fields "$home" PVTSSF_status opt_todo:Todo opt_processed:Processed \
    'opt_prog:In Progress' opt_done:Done \
    'opt_bptodo:Big Picture Processed' 'opt_bpprog:Big Picture In Progress' \
    'opt_bpdone:Big Picture Done'
}

# The same board carrying the whole vocabulary, including the captain's go. This
# is the shape a roadmap has once a programme on it is being fed follow-on work
# that the captain has already cleared.
roadmap_board() {
  local home=$1
  cat > "$home/config/boards" <<'EOF'
project = harbourlight
owner = harbour-collective
number = 4
repo = harbour-collective/app
label = firstmate
processed = Processed
queued = Queued
big-picture-todo = Big Picture Processed
big-picture-in-progress = Big Picture In Progress
big-picture-done = Big Picture Done
EOF
  fields "$home" PVTSSF_status opt_todo:Todo opt_processed:Processed \
    opt_queued:Queued 'opt_prog:In Progress' opt_done:Done \
    'opt_bptodo:Big Picture Processed' 'opt_bpprog:Big Picture In Progress' \
    'opt_bpdone:Big Picture Done'
}

# --- configuration is the whole board identity ------------------------------

test_boards_are_configuration_not_convention() {
  local home out
  home=$(new_home boards_are_configuration_not_convention)
  ordinary_board "$home"
  cat >> "$home/config/boards" <<'EOF'

project = tidewheel
owner = personal-account
number = 91
label = take-it-mate
status-field = Lane
todo = Waiting
in-progress = Under Way
done = Landed
EOF
  out=$(board "$home" boards)
  assert_contains "$out" 'board harbourlight harbour-collective/4' "the first board is not listed"
  assert_contains "$out" 'board tidewheel personal-account/91' "the second board is not listed"
  assert_contains "$out" 'columns=Waiting|Under Way|Landed' "a board's own column names are not carried"
  assert_contains "$out" 'label=take-it-mate' "a board's own trigger label is not carried"

  home=$(new_home unconfigured_home)
  out=$(board "$home" boards)
  [ -z "$out" ] || fail "a home with no board configuration reported a board"
  out=$(board "$home" poll)
  [ -z "$out" ] || fail "a home with no board configuration polled something"
  pass "boards come entirely from local configuration, and an unconfigured home has none"
}

test_the_bridge_is_inert_until_a_board_is_configured() {
  local home out rc verb
  home=$(new_home the_bridge_is_inert_until_a_board_is_configured)
  [ ! -e "$home/config/boards" ] || fail "the fixture home already has board configuration"

  out=$(board "$home" boards)
  [ -z "$out" ] || fail "an unconfigured home listed a board: $out"
  out=$(board "$home" poll)
  [ -z "$out" ] || fail "an unconfigured home polled a board: $out"
  out=$(board "$home" links)
  [ -z "$out" ] || fail "an unconfigured home reported a link: $out"

  # Every verb that needs a board refuses, and none of them reaches GitHub.
  board "$home" lookup fm-nothing >/dev/null 2>&1 && rc=0 || rc=$?
  [ "$rc" != 0 ] || fail "an unconfigured home resolved a link"
  board "$home" import somewhere https://github.com/someone/app/issues/1 fm-x >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "an unconfigured home accepted an import"
  for verb in mark pr note ack; do
    board "$home" "$verb" fm-x https://github.com/someone/app/pull/1 >/dev/null 2>&1 && rc=0 || rc=$?
    [ "$rc" != 0 ] || fail "an unconfigured home accepted \"$verb\""
  done
  # Placement refuses for the same reason, whichever facts it is asked to state.
  board "$home" place somewhere fm-x 'Work' 'body' >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "an unconfigured home accepted a placement"
  board "$home" place somewhere fm-x 'Work' 'body' --cleared \
    --parent https://github.com/someone/app/issues/1 >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "an unconfigured home accepted a placement stating a go and a programme"

  [ -z "$(gh_log "$home")" ] || fail "an unconfigured home called the GitHub CLI: $(gh_log "$home")"
  assert_absent "$home/data/board-links.tsv" "an unconfigured home created a link record"
  [ -z "$(ls -A "$home/state")" ] || fail "an unconfigured home created runtime state"

  # An empty configuration file is the same as no file at all.
  : > "$home/config/boards"
  out=$(board "$home" poll)
  [ -z "$out" ] || fail "an empty board configuration polled a board: $out"
  printf '# only a comment\n\n' > "$home/config/boards"
  out=$(board "$home" boards)
  [ -z "$out" ] || fail "a configuration with no stanza reported a board: $out"
  [ -z "$(gh_log "$home")" ] || fail "an empty board configuration called the GitHub CLI"
  pass "with no board configured the bridge reads nothing, writes nothing, and creates nothing"
}

test_removing_the_configuration_is_the_off_switch() {
  local home issue out before
  home=$(new_home removing_the_configuration_is_the_off_switch)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/130
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Runs while configured' -
  board "$home" import harbourlight "$issue" fm-configured >/dev/null
  board "$home" mark fm-configured in-progress >/dev/null
  [ -n "$(gh_log "$home")" ] || fail "the configured board never reached GitHub"

  rm -f "$home/config/boards"
  : > "$home/gh.log"
  out=$(board "$home" poll)
  [ -z "$out" ] || fail "the bridge still polled after its configuration was removed: $out"
  out=$(board "$home" boards)
  [ -z "$out" ] || fail "the bridge still reported a board after its configuration was removed"
  [ -z "$(gh_log "$home")" ] || fail "the bridge called GitHub after its configuration was removed"

  # No residue: the only artifact is the durable link record, and it is inert.
  before=$(cat "$home/data/board-links.tsv")
  [ -z "$(ls -A "$home/state")" ] || fail "disabling left runtime state behind"
  assert_absent "$home/config/x-mode.env" "disabling left a generated cadence file behind"
  board "$home" poll >/dev/null
  [ "$(cat "$home/data/board-links.tsv")" = "$before" ] || fail "a disabled bridge still rewrote its record"

  # And disabling is not an undo: what was already imported is still recorded.
  assert_contains "$before" 'fm-configured' "disabling erased an import that had already happened"
  pass "removing the configuration disables the bridge with no residue, and undoes nothing already done"
}

test_malformed_configuration_is_an_actionable_error() {
  local home out rc
  home=$(new_home malformed_configuration_is_an_actionable_error)
  printf 'project = alpha\nowner = someone\n' > "$home/config/boards"
  out=$(board "$home" poll 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a board with no project number was accepted"
  assert_contains "$out" 'has no number' "the missing project number was not named"

  printf 'project = alpha\nowner = someone\nnumber = 4\ncolumn = Todo\n' > "$home/config/boards"
  out=$(board "$home" poll 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "an unknown configuration key was accepted"
  assert_contains "$out" 'unknown key "column"' "the unknown key was not named"

  printf 'project = alpha\nowner = someone\nnumber = four\n' > "$home/config/boards"
  out=$(board "$home" poll 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a non-numeric project number was accepted"
  pass "malformed board configuration is refused with the reason, not guessed around"
}

# --- intake -----------------------------------------------------------------

test_only_projects_with_a_board_are_ever_mapped() {
  local home issue out rc log
  home=$(new_home only_projects_with_a_board_are_ever_mapped)
  # Two projects in one home: one has a board, the other deliberately does not.
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/140
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'On the board' -
  board "$home" import harbourlight "$issue" fm-onboard >/dev/null
  : > "$home/gh.log"

  # Work on a project with no board has nowhere to go, and nothing is touched.
  out=$(board "$home" import elsewhere https://github.com/other-org/elsewhere/issues/1 fm-elsewhere 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a project with no configured board was mapped to one"
  assert_contains "$out" 'no board configured for project "elsewhere"' \
    "the refusal did not name the unconfigured project"
  board "$home" mark fm-elsewhere in-progress >/dev/null 2>&1 && rc=0 || rc=$?
  [ "$rc" != 0 ] || fail "a task from a project with no board was moved on a board"
  board "$home" note fm-elsewhere 'Blocked: nothing' >/dev/null 2>&1 && rc=0 || rc=$?
  [ "$rc" != 0 ] || fail "a task from a project with no board commented on an issue"
  [ -z "$(gh_log "$home")" ] || fail "work on a project with no board reached GitHub: $(gh_log "$home")"
  out=$(board "$home" poll)
  assert_not_contains "$out" 'elsewhere' "polling reported a project that has no board"

  # A second, differently configured board never receives the first one's work.
  cat >> "$home/config/boards" <<'EOF'

project = tidewheel
owner = personal-account
number = 91
EOF
  : > "$home/gh.log"
  board "$home" mark fm-onboard in-progress >/dev/null
  log=$(gh_log "$home")
  assert_contains "$log" 'owner=harbour-collective' "the event did not resolve its own project's board"
  assert_not_contains "$log" 'personal-account' "the event reached another project's board"
  assert_not_contains "$log" 'endCursor' "an ordinary event read a whole board"
  pass "only a project with a configured board is mapped, and boards never cross"
}

test_only_tagged_todo_issues_are_importable() {
  local home out
  home=$(new_home only_tagged_todo_issues_are_importable)
  unusual_board "$home"
  item "$home" PVTI_a Issue https://github.com/personal-account/tidewheel/issues/1 \
    Waiting take-it-mate - 'Tagged and waiting' 'ordinary body'
  item "$home" PVTI_b DraftIssue - Waiting take-it-mate - 'A draft card' -
  item "$home" PVTI_c PullRequest https://github.com/personal-account/tidewheel/pull/2 \
    Waiting take-it-mate - 'A pull request' -
  item "$home" PVTI_d Issue https://github.com/personal-account/tidewheel/issues/3 \
    'Under Way' take-it-mate - 'Tagged but already moved' -
  item "$home" PVTI_e Issue https://github.com/personal-account/tidewheel/issues/4 \
    Waiting - - 'Waiting but untagged' 'no trigger here'
  item "$home" PVTI_f Issue https://github.com/personal-account/tidewheel/issues/5 \
    Waiting - - 'Mentioned instead' 'hey @deckhand take this'
  item "$home" PVTI_g Issue https://github.com/personal-account/tidewheel/issues/6 \
    Waiting - deckhand-bot 'Assigned instead' -
  item "$home" PVTI_h Issue https://github.com/other-org/elsewhere/issues/7 \
    Waiting take-it-mate - 'Another repo on the same board' -

  out=$(board "$home" poll)
  assert_contains "$out" 'new tidewheel https://github.com/personal-account/tidewheel/issues/1 label' \
    "a tagged issue waiting in the first column is not importable"
  assert_contains "$out" 'issues/5 mention' "the optional mention trigger did not fire"
  assert_contains "$out" 'issues/6 assignee' "the optional assignee trigger did not fire"
  assert_not_contains "$out" 'A draft card' "a draft card was offered as importable work"
  assert_not_contains "$out" 'pull/2' "a pull request was offered as importable work"
  assert_not_contains "$out" 'issues/3' "an issue already past the first column was offered for import"
  assert_not_contains "$out" 'issues/4' "an untagged issue was offered for import"
  assert_not_contains "$out" 'other-org' "an issue outside the configured repo was offered for import"
  pass "intake takes real issues, in the first column, carrying the configured trigger"
}

test_mention_and_assignee_triggers_are_off_by_default() {
  local home out
  home=$(new_home mention_and_assignee_triggers_are_off_by_default)
  ordinary_board "$home"
  item "$home" PVTI_a Issue https://github.com/harbour-collective/app/issues/1 \
    Todo - - 'Only mentioned' 'please @firstmate take this'
  item "$home" PVTI_b Issue https://github.com/harbour-collective/app/issues/2 \
    Todo - firstmate 'Only assigned' -
  out=$(board "$home" poll)
  [ -z "$out" ] || fail "an unconfigured mention or assignee trigger fired anyway: $out"
  pass "the label is the authoritative trigger; mention and assignee stay off unless configured"
}

# --- idempotent import ------------------------------------------------------

test_importing_the_same_issue_twice_is_a_no_op() {
  local home out rc issue
  home=$(new_home importing_the_same_issue_twice_is_a_no_op)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/12
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Add a mooring' -

  out=$(board "$home" import harbourlight "$issue" fm-mooring)
  assert_contains "$out" "linked harbourlight $issue fm-mooring" "the first import did not link"

  out=$(board "$home" import harbourlight "$issue" fm-mooring) && rc=0 || rc=$?
  expect_code 0 "$rc" "re-importing an already-linked issue failed instead of being a no-op"
  assert_contains "$out" 'already-linked' "the repeat import was not reported as already linked"
  [ "$(board "$home" links | wc -l)" = 1 ] || fail "re-importing produced a second linkage record"

  out=$(board "$home" poll --all)
  assert_not_contains "$out" 'new harbourlight' "an already-linked issue was offered for import again"
  assert_contains "$out" "linked harbourlight $issue fm-mooring todo" "the linked issue was not reported as linked"

  out=$(board "$home" import harbourlight "$issue" fm-different 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "relinking an issue to a different task was allowed"
  assert_contains "$out" 'already linked to task fm-mooring' "the refusal did not name the existing task"
  [ "$(board "$home" links | wc -l)" = 1 ] || fail "a refused relink still wrote a record"
  pass "one issue holds one task: repeat import is a no-op and a conflicting relink is refused"
}

test_the_link_outlives_the_task_it_names() {
  local home out issue
  home=$(new_home the_link_outlives_the_task_it_names)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/20
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Long-lived work' -
  board "$home" import harbourlight "$issue" fm-longlived >/dev/null

  # Everything a finished task leaves in state/ goes away at cleanup.
  printf 'window=x\n' > "$home/state/fm-longlived.meta"
  printf 'done: shipped\n' > "$home/state/fm-longlived.status"
  rm -rf "$home/state"

  out=$(board "$home" lookup "$issue") || fail "the link did not survive task cleanup"
  assert_contains "$out" 'fm-longlived' "the surviving link lost its task identity"
  out=$(board "$home" poll)
  assert_not_contains "$out" 'new harbourlight' "a torn-down task's issue became importable again"
  pass "the linkage record lives with the durable fleet records and survives task cleanup"
}

# --- status transitions driven by execution events --------------------------

test_transitions_follow_firstmate_execution_events() {
  local home issue out log
  home=$(new_home transitions_follow_firstmate_execution_events)
  unusual_board "$home"
  issue=https://github.com/personal-account/tidewheel/issues/8
  item "$home" PVTI_a Issue "$issue" Waiting take-it-mate - 'Ship it' -
  board "$home" import tidewheel "$issue" fm-ship >/dev/null
  assert_contains "$(board "$home" lookup fm-ship)" "	todo	todo	" "a fresh import did not start in the first column"

  # Dispatch.
  out=$(board "$home" mark fm-ship in-progress)
  assert_contains "$out" "synced tidewheel $issue fm-ship in-progress" "dispatch did not move the card"
  log=$(gh_log "$home")
  assert_contains "$log" 'project item-edit --id PVTI_a --project-id PVT_fixture --field-id PVTSSF_lane --single-select-option-id opt_under' \
    "the dispatch write did not set this board's own In Progress option"

  # Merge.
  : > "$home/gh.log"
  out=$(board "$home" mark fm-ship 'done')
  assert_contains "$out" "synced tidewheel $issue fm-ship done" "the merge did not move the card"
  assert_contains "$(gh_log "$home")" '--single-select-option-id opt_landed' \
    "the merge write did not set this board's own Done option"
  assert_contains "$(board "$home" lookup fm-ship)" "	done	done	" "the record did not follow the card"
  pass "Todo, In Progress, and Done are driven by dispatch and merge, on the board's own column names"
}

test_a_column_firstmate_does_not_drive_is_recorded_not_invented() {
  local home issue out rc
  home=$(new_home a_column_firstmate_does_not_drive_is_recorded_not_invented)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/30
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Parked work' -
  board "$home" import harbourlight "$issue" fm-parked >/dev/null

  : > "$home/items"
  item "$home" PVTI_a Issue "$issue" 'Needs Review' firstmate - 'Parked work' -
  out=$(board "$home" poll)
  assert_contains "$out" "divergence harbourlight $issue fm-parked todo other Needs Review" \
    "a column outside the driven ones did not surface as a divergence carrying its own name"
  assert_contains "$(board "$home" lookup fm-parked)" "	todo	todo	" \
    "firstmate's record was rewritten to a column it never drove"

  out=$(board "$home" mark fm-parked blocked 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "the adapter accepted a state it does not drive"
  pass "a column the adapter does not drive is reported by its own name, never adopted as a state"
}

# --- PR linkage -------------------------------------------------------------

test_the_pull_request_is_attached_to_the_originating_issue() {
  local home issue pr out
  home=$(new_home the_pull_request_is_attached_to_the_originating_issue)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/40
  pr=https://github.com/harbour-collective/app/pull/41
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Needs a PR' -
  board "$home" import harbourlight "$issue" fm-pr >/dev/null

  out=$(board "$home" pr fm-pr "$pr")
  assert_contains "$out" "attached harbourlight $issue fm-pr $pr" "the PR was not attached"
  assert_contains "$(gh_log "$home")" "issue comment $issue --body Working PR: $pr" \
    "the PR link did not land on the originating issue"
  assert_contains "$(board "$home" lookup fm-pr)" "$pr" "the PR was not recorded against the link"

  : > "$home/gh.log"
  out=$(board "$home" pr fm-pr "$pr")
  assert_contains "$out" 'already-attached' "re-attaching the same PR was not a no-op"
  [ -z "$(gh_log "$home")" ] || fail "re-attaching the same PR commented on the issue a second time"
  pass "the working PR is attached to the issue that started the work, once"
}

test_a_blocker_is_recorded_on_the_issue() {
  local home issue out
  home=$(new_home a_blocker_is_recorded_on_the_issue)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/50
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Will block' -
  board "$home" import harbourlight "$issue" fm-blocked >/dev/null
  board "$home" mark fm-blocked in-progress >/dev/null

  out=$(board "$home" note fm-blocked 'Blocked: the staging credential expired')
  assert_contains "$out" "noted harbourlight $issue fm-blocked" "the blocker was not recorded"
  assert_contains "$(gh_log "$home")" 'issue comment '"$issue"' --body Blocked: the staging credential expired' \
    "the blocker did not land on the issue"
  out=$(board "$home" poll --all)
  assert_contains "$out" "linked harbourlight $issue fm-blocked in-progress" \
    "a blocked item stopped being visible on the board"
  pass "a blocker is recorded on the issue while the item stays visible where it is"
}

# --- firstmate's records are the truth the board reports ---------------------

test_a_status_firstmate_did_not_write_is_reported_not_reconciled() {
  local home issue out log record
  home=$(new_home a_status_firstmate_did_not_write_is_reported_not_reconciled)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/60
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Reprioritized work' -
  board "$home" import harbourlight "$issue" fm-repri >/dev/null
  board "$home" mark fm-repri in-progress >/dev/null
  record=$(board "$home" lookup fm-repri)

  # Something outside firstmate pulls the card back to the first column.
  : > "$home/items"
  : > "$home/gh.log"
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Reprioritized work' -
  out=$(board "$home" poll)
  assert_contains "$out" "divergence harbourlight $issue fm-repri in-progress todo Todo" \
    "a status firstmate never wrote was not surfaced as a divergence"
  assert_not_contains "$out" 'instruction' "a board status was still treated as an instruction"
  log=$(gh_log "$home")
  assert_not_contains "$log" 'item-edit' "the poll reconciled the board behind the captain"
  [ "$(board "$home" lookup fm-repri)" = "$record" ] \
    || fail "the poll changed firstmate's own record to match the board"

  # It keeps being reported, and still changes nothing, until firstmate acts.
  out=$(board "$home" poll)
  assert_contains "$out" 'divergence' "an unreconciled divergence stopped being reported"
  [ "$(board "$home" lookup fm-repri)" = "$record" ] || fail "a later poll adopted the board status"

  # An explicit mark is how it resolves: firstmate acting, not the poll deciding.
  board "$home" mark fm-repri in-progress >/dev/null
  out=$(board "$home" poll)
  assert_not_contains "$out" 'divergence' "an explicitly re-marked card kept diverging"
  pass "a status firstmate did not write is reported and changes nothing on either side"
}

test_a_queued_card_firstmate_did_not_place_never_starts_work() {
  local home issue out
  home=$(new_home a_queued_card_firstmate_did_not_place_never_starts_work)
  queued_board "$home"
  issue=https://github.com/harbour-collective/app/issues/62
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Not cleared yet' -
  board "$home" import harbourlight "$issue" fm-notcleared >/dev/null

  # A card appears in the authorized column that firstmate never put there.
  : > "$home/items"
  : > "$home/gh.log"
  item "$home" PVTI_a Issue "$issue" Queued firstmate - 'Not cleared yet' -
  out=$(board "$home" poll)
  assert_contains "$out" "divergence harbourlight $issue fm-notcleared todo queued Queued" \
    "a card in the authorized column that firstmate never placed was not reported"
  assert_contains "$(board "$home" lookup fm-notcleared)" "	todo	todo	" \
    "the record adopted an authorization firstmate never gave"
  assert_not_contains "$(gh_log "$home")" 'item-edit' "the divergence caused a board write"

  # Firstmate's own record is what puts a card in that column.
  : > "$home/gh.log"
  out=$(board "$home" mark fm-notcleared queued)
  assert_contains "$out" "synced harbourlight $issue fm-notcleared queued" \
    "firstmate could not record the work as cleared to launch"
  assert_contains "$(gh_log "$home")" '--single-select-option-id opt_queued' \
    "the queued write did not set this board's own Queued option"
  pass "the queued column is written from firstmate's records, and a card it did not place starts nothing"
}

test_the_queued_column_does_not_exist_until_it_is_configured() {
  local home issue out rc
  home=$(new_home the_queued_column_does_not_exist_until_it_is_configured)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/64
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Ordinary work' -
  board "$home" import harbourlight "$issue" fm-ordinary >/dev/null

  out=$(board "$home" mark fm-ordinary queued 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "an unconfigured queued column was still writable"
  assert_contains "$out" 'no queued column configured' "the refusal did not name the missing column"
  assert_contains "$(board "$home" boards)" 'queued=-' "an unconfigured board reported a queued column"

  # A board that happens to carry such a column reads it as a column firstmate
  # does not drive, exactly as it did before the key existed.
  : > "$home/items"
  item "$home" PVTI_a Issue "$issue" Queued firstmate - 'Ordinary work' -
  out=$(board "$home" poll)
  assert_contains "$out" "divergence harbourlight $issue fm-ordinary todo other Queued" \
    "an unconfigured queued column was read as a queued state"
  pass "with no queued key configured the column does not exist in either direction"
}

test_a_withdrawn_card_stops_the_work_without_touching_it() {
  local home issue out repo before after
  home=$(new_home a_withdrawn_card_stops_the_work_without_touching_it)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/70
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Withdrawn work' -
  board "$home" import harbourlight "$issue" fm-withdrawn >/dev/null
  board "$home" mark fm-withdrawn in-progress >/dev/null

  # A real worktree with real unlanded work, exactly what a cancellation must
  # never cost.
  repo="$home/work"
  fm_git_init_commit "$repo"
  git -C "$repo" checkout -q -b fm/withdrawn-work
  printf 'half-finished\n' > "$repo/feature.txt"
  before=$(git -C "$repo" status --porcelain)

  : > "$home/items"
  : > "$home/gh.log"
  item "$home" PVTI_other Issue https://github.com/harbour-collective/app/issues/71 \
    Done - - 'Something else on the board' -
  out=$(board "$home" poll)
  assert_contains "$out" "cancelled harbourlight $issue fm-withdrawn in-progress" \
    "a card that left the board was not reported as withdrawn"
  assert_not_contains "$(gh_log "$home")" 'item-edit' "the withdrawal triggered a board write"

  board "$home" ack fm-withdrawn >/dev/null
  after=$(git -C "$repo" status --porcelain)
  [ "$before" = "$after" ] || fail "unlanded work changed while reconciling a withdrawn card"
  assert_present "$repo/feature.txt" "unlanded work was removed while reconciling a withdrawn card"
  git -C "$repo" rev-parse --verify -q fm/withdrawn-work >/dev/null \
    || fail "the branch was removed while reconciling a withdrawn card"

  out=$(board "$home" poll)
  assert_not_contains "$out" 'cancelled' "an acknowledged withdrawal kept being reported"
  out=$(board "$home" lookup "$issue") || fail "the link was dropped when the card was withdrawn"
  pass "a withdrawn card is reported until reconciled, and never costs unlanded work"
}

test_a_completed_card_leaving_the_board_is_not_a_withdrawal() {
  local home issue out
  home=$(new_home a_completed_card_leaving_the_board_is_not_a_withdrawal)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/80
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Finished work' -
  board "$home" import harbourlight "$issue" fm-finished >/dev/null
  board "$home" mark fm-finished 'done' >/dev/null
  : > "$home/items"
  item "$home" PVTI_other Issue https://github.com/harbour-collective/app/issues/81 \
    Todo - - 'Something else on the board' -
  out=$(board "$home" poll)
  assert_not_contains "$out" 'cancelled' "archiving a finished card was reported as a withdrawal"
  pass "archiving a finished card is ordinary housekeeping, not a withdrawal"
}

# The third way the captain withdraws work, and the one the board shows nothing
# of: the issue is closed and its card stays exactly where it was. Before this
# was read, closing an issue reached firstmate as nothing at all.
test_a_closed_issue_withdraws_the_work_its_card_still_shows() {
  local home queued running out repo before after
  home=$(new_home a_closed_issue_withdraws_the_work_its_card_still_shows)
  ordinary_board "$home"
  queued=https://github.com/harbour-collective/app/issues/90
  running=https://github.com/harbour-collective/app/issues/91
  item "$home" PVTI_q Issue "$queued" Todo firstmate - 'Queued work' -
  item "$home" PVTI_r Issue "$running" Todo firstmate - 'Running work' -
  board "$home" import harbourlight "$queued" fm-queued >/dev/null
  board "$home" import harbourlight "$running" fm-running >/dev/null
  board "$home" mark fm-running in-progress >/dev/null

  # A real worktree with real unlanded work, exactly what a withdrawal must never
  # cost however it was said.
  repo="$home/work"
  fm_git_init_commit "$repo"
  git -C "$repo" checkout -q -b fm/running-work
  printf 'half-finished\n' > "$repo/feature.txt"
  before=$(git -C "$repo" status --porcelain)

  close_card_issue "$home" "$queued"
  close_card_issue "$home" "$running"
  : > "$home/gh.log"
  out=$(board "$home" poll)
  assert_contains "$out" "closed harbourlight $queued fm-queued todo" \
    "a closed issue holding queued work was not reported as withdrawn"
  assert_contains "$out" "closed harbourlight $running fm-running in-progress" \
    "a closed issue holding work in flight was not reported as withdrawn"
  assert_not_contains "$(gh_log "$home")" 'item-edit' \
    "withdrawal by closure triggered a board write"

  after=$(git -C "$repo" status --porcelain)
  [ "$before" = "$after" ] || fail "unlanded work changed while reporting a closed issue"
  assert_present "$repo/feature.txt" "unlanded work was removed while reporting a closed issue"
  git -C "$repo" rev-parse --verify -q fm/running-work >/dev/null \
    || fail "the branch was removed while reporting a closed issue"

  # It repeats until firstmate reconciles it, exactly as a card that left does,
  # so a missed cycle cannot lose the withdrawal.
  out=$(board "$home" poll)
  assert_contains "$out" "closed harbourlight $running fm-running in-progress" \
    "a closed issue stopped being reported before it was reconciled"

  board "$home" ack fm-queued >/dev/null
  board "$home" ack fm-running >/dev/null
  out=$(board "$home" poll)
  assert_not_contains "$out" 'closed harbourlight' \
    "an acknowledged closure kept being reported"
  out=$(board "$home" lookup "$running") \
    || fail "the link was dropped when the issue was closed"
  pass "a closed issue withdraws work still open, and never costs unlanded work"
}

test_a_closed_issue_whose_work_landed_is_not_a_withdrawal() {
  local home landed out
  home=$(new_home a_closed_issue_whose_work_landed_is_not_a_withdrawal)
  ordinary_board "$home"
  landed=https://github.com/harbour-collective/app/issues/95
  item "$home" PVTI_a Issue "$landed" Todo firstmate - 'Finished work' -
  board "$home" import harbourlight "$landed" fm-landed >/dev/null
  board "$home" mark fm-landed 'done' >/dev/null

  # The ordinary end of a task: the work merged, firstmate moved the card to
  # Done, and closing the issue is what finishing it means. This is the case that
  # would otherwise shout on every completed item.
  close_card_issue "$home" "$landed"
  out=$(board "$home" poll)
  assert_not_contains "$out" 'closed' \
    "closing a finished task's issue was reported as a withdrawal"
  assert_equals "" "$out" "a settled board stopped polling quiet once an issue closed"
  pass "a closed issue whose work already landed is the end of it, not a withdrawal"
}

test_closure_and_card_removal_are_told_apart() {
  local home gone closed out
  home=$(new_home closure_and_card_removal_are_told_apart)
  ordinary_board "$home"
  gone=https://github.com/harbour-collective/app/issues/96
  closed=https://github.com/harbour-collective/app/issues/97
  item "$home" PVTI_g Issue "$gone" Todo firstmate - 'Card pulled off the board' -
  item "$home" PVTI_c Issue "$closed" Todo firstmate - 'Issue closed in place' -
  board "$home" import harbourlight "$gone" fm-gone >/dev/null
  board "$home" import harbourlight "$closed" fm-closed >/dev/null
  board "$home" mark fm-gone in-progress >/dev/null
  board "$home" mark fm-closed in-progress >/dev/null

  # One card leaves the board; the other stays put with its issue closed. What
  # firstmate tells the captain differs, so the two records must differ too.
  : > "$home/items"
  item "$home" PVTI_c Issue "$closed" 'In Progress' firstmate - 'Issue closed in place' \
    - - closed
  out=$(board "$home" poll)
  assert_contains "$out" "cancelled harbourlight $gone fm-gone in-progress" \
    "a card that left the board was not reported as withdrawn"
  assert_contains "$out" "closed harbourlight $closed fm-closed in-progress" \
    "an issue closed in place was not reported as withdrawn"
  assert_not_contains "$out" "cancelled harbourlight $closed" \
    "an issue closed in place was reported as a card that left the board"
  assert_not_contains "$out" "closed harbourlight $gone" \
    "a card that left the board was reported as a closed issue"
  pass "which way the captain withdrew the work is what the record says"
}

# --- fail soft --------------------------------------------------------------

test_a_failed_board_write_never_blocks_delivery() {
  local home issue out rc
  home=$(new_home a_failed_board_write_never_blocks_delivery)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/90
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Ships anyway' -
  board "$home" import harbourlight "$issue" fm-ships >/dev/null

  out=$(GH_FAIL='project item-edit' board "$home" mark fm-ships in-progress 2>/dev/null) && rc=0 || rc=$?
  expect_code 0 "$rc" "a failed board write stopped the dispatch"
  assert_contains "$out" "stale harbourlight $issue fm-ships in-progress" \
    "the failed write was not reported as a stale board"
  assert_contains "$(board "$home" lookup fm-ships)" "	in-progress	todo	" \
    "the failed write was not left outstanding for the next cycle"

  out=$(GH_FAIL='issue comment' board "$home" pr fm-ships https://github.com/harbour-collective/app/pull/91 2>/dev/null) && rc=0 || rc=$?
  expect_code 0 "$rc" "a failed PR comment stopped the delivery report"
  assert_contains "$out" 'stale' "the failed PR comment was not reported as a stale board"

  out=$(GH_FAIL='issue comment' board "$home" note fm-ships 'Blocked: nothing' 2>/dev/null) && rc=0 || rc=$?
  expect_code 0 "$rc" "a failed blocker note stopped the cycle"

  # The next cycle reconciles what the failed write left behind.
  out=$(board "$home" poll)
  assert_contains "$out" "synced harbourlight $issue fm-ships in-progress" \
    "the next cycle did not retry the outstanding board write"
  assert_contains "$(board "$home" lookup fm-ships)" "	in-progress	in-progress	" \
    "the retried write was not recorded as confirmed"
  pass "board writes degrade to a stale board and reconcile on the next cycle"
}

test_a_failed_board_read_never_blocks_the_cycle() {
  local home out rc
  home=$(new_home a_failed_board_read_never_blocks_the_cycle)
  ordinary_board "$home"
  item "$home" PVTI_a Issue https://github.com/harbour-collective/app/issues/100 \
    Todo firstmate - 'Unreadable today' -
  out=$(GH_FAIL='graphql items' board "$home" poll 2>/dev/null) && rc=0 || rc=$?
  expect_code 0 "$rc" "a board read failure stopped the cycle"
  assert_contains "$out" 'error harbourlight could not read project harbour-collective/4' \
    "the board read failure was not reported"
  assert_not_contains "$out" 'cancelled' "an unreadable board was mistaken for withdrawn work"
  pass "an unreadable board is reported and retried, never mistaken for withdrawn work"
}

test_an_empty_board_is_not_taken_as_mass_withdrawal() {
  local home out
  home=$(new_home an_empty_board_is_not_taken_as_mass_withdrawal)
  ordinary_board "$home"
  item "$home" PVTI_a Issue https://github.com/harbour-collective/app/issues/120 \
    Todo firstmate - 'Still open' -
  board "$home" import harbourlight https://github.com/harbour-collective/app/issues/120 fm-open >/dev/null

  # The board answers successfully with nothing at all - a changed project
  # number or a lost permission looks exactly like this.
  : > "$home/items"
  out=$(board "$home" poll)
  assert_contains "$out" 'error harbourlight the board returned no cards while links are open' \
    "an empty board read was not reported"
  assert_not_contains "$out" 'cancelled' "an empty board read was taken as withdrawing every card"
  assert_contains "$(board "$home" lookup fm-open)" '	todo	todo	' "an empty board read changed a record"
  pass "a board that answers with nothing while links are open is reported, not obeyed"
}

test_a_truncated_read_reconciles_nothing() {
  local home out
  home=$(new_home a_truncated_read_reconciles_nothing)
  ordinary_board "$home"
  item "$home" PVTI_a Issue https://github.com/harbour-collective/app/issues/110 \
    Todo firstmate - 'First' -
  item "$home" PVTI_b Issue https://github.com/harbour-collective/app/issues/111 \
    Todo firstmate - 'Second' -
  board "$home" import harbourlight https://github.com/harbour-collective/app/issues/999 fm-offpage >/dev/null
  out=$(board "$home" poll --limit 2)
  assert_contains "$out" 'truncated harbourlight 2' "a full page was not reported as possibly truncated"
  assert_not_contains "$out" 'cancelled' "a page boundary was mistaken for a withdrawn card"
  pass "a page boundary is never mistaken for absence"
}

test_a_card_an_intake_filter_skips_is_not_a_withdrawal() {
  local home issue out
  home=$(new_home a_card_an_intake_filter_skips_is_not_a_withdrawal)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/150
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Filtered but plainly there' -
  board "$home" import harbourlight "$issue" fm-filtered >/dev/null
  board "$home" mark fm-filtered in-progress >/dev/null

  # The captain narrows the board to one repository after the import, so the
  # intake repo filter now skips a card that has not moved at all.
  cat > "$home/config/boards" <<'EOF'
project = harbourlight
owner = harbour-collective
number = 4
repo = harbour-collective/somewhere-else
label = firstmate
EOF
  out=$(board "$home" poll --all)
  assert_not_contains "$out" 'cancelled' "a card the repo filter skips was reported as withdrawn"
  assert_contains "$out" "linked harbourlight $issue fm-filtered in-progress" \
    "a card the repo filter skips stopped being reconciled"

  # A card whose type intake does not recognize is still a card on the board.
  ordinary_board "$home"
  : > "$home/items"
  item "$home" PVTI_a ISSUE "$issue" 'In Progress' firstmate - 'Filtered but plainly there' -
  out=$(board "$home" poll)
  assert_not_contains "$out" 'cancelled' "a card the type filter skips was reported as withdrawn"
  assert_contains "$(board "$home" lookup fm-filtered)" "	in-progress	in-progress	" \
    "a skipped card's record was changed"
  pass "an intake filter decides what is importable, never what is still on the board"
}

test_an_issue_another_board_owns_is_skipped_not_re_homed() {
  local home issue out log
  home=$(new_home an_issue_another_board_owns_is_skipped_not_re_homed)
  ordinary_board "$home"
  cat >> "$home/config/boards" <<'EOF'

project = tidewheel
owner = personal-account
number = 91
EOF
  issue=https://github.com/harbour-collective/app/issues/160
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'The first board owns this' -
  board "$home" import harbourlight "$issue" fm-owned >/dev/null
  board "$home" mark fm-owned in-progress >/dev/null

  # Both boards now answer with the same card, which is the misconfiguration.
  : > "$home/gh.log"
  out=$(board "$home" poll)
  assert_contains "$out" "foreign tidewheel $issue harbourlight fm-owned" \
    "a card another board owns was not reported with the project that owns it"
  assert_not_contains "$out" 'new tidewheel' "a card another board owns was offered for import"
  assert_not_contains "$out" 'cancelled' "a card another board owns was read as a withdrawal"
  assert_not_contains "$(gh_log "$home")" 'item-edit' "polling a card another board owns wrote to a board"
  assert_contains "$(board "$home" lookup fm-owned)" "harbourlight	$issue" \
    "the link was re-homed to the board that does not own the issue"

  # And every later event still resolves the board that does own it.
  : > "$home/gh.log"
  board "$home" mark fm-owned 'done' >/dev/null
  log=$(gh_log "$home")
  assert_contains "$log" 'owner=harbour-collective' "a later event stopped resolving the owning board"
  assert_not_contains "$log" 'personal-account' "a later event reached the board that does not own the issue"
  pass "an issue another board owns is named and left alone, never silently re-homed"
}

test_an_outstanding_pr_attachment_is_retried_on_the_next_cycle() {
  local home issue pr out
  home=$(new_home an_outstanding_pr_attachment_is_retried_on_the_next_cycle)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/170
  pr=https://github.com/harbour-collective/app/pull/171
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Reports a PR' -
  board "$home" import harbourlight "$issue" fm-latepr >/dev/null

  out=$(GH_FAIL='issue comment' board "$home" pr fm-latepr "$pr" 2>/dev/null)
  assert_contains "$out" "stale harbourlight $issue fm-latepr $pr" \
    "the failed attachment was not reported as a stale board"
  assert_contains "$(board "$home" lookup fm-latepr)" "$pr	0" \
    "the failed attachment was not left outstanding for the next cycle"

  : > "$home/gh.log"
  out=$(board "$home" poll)
  assert_contains "$out" "synced harbourlight $issue fm-latepr $pr" \
    "the next cycle did not retry the outstanding PR attachment"
  assert_contains "$(gh_log "$home")" "issue comment $issue --body Working PR: $pr" \
    "the retry did not land the PR link on the originating issue"
  assert_contains "$(board "$home" lookup fm-latepr)" "$pr	1" \
    "the retried attachment was not recorded as confirmed"

  : > "$home/gh.log"
  board "$home" poll >/dev/null
  assert_not_contains "$(gh_log "$home")" 'issue comment' \
    "a confirmed attachment was posted onto the issue again"
  pass "an outstanding PR attachment is retried until the issue has it, then left alone"
}

# A board read is the one call here whose price grows with the board, so the
# verbs that move a single card must never make one. They find the card through
# the issue that holds it instead, which is also why a board too large for one
# read no longer puts a card out of their reach.
test_a_single_card_event_never_reads_the_board() {
  local home issue log out rc
  home=$(new_home a_single_card_event_never_reads_the_board)
  # The internalized column is what makes import write to the board at all, so
  # this is the fixture on which import has a board read to avoid.
  processed_board "$home"
  issue=https://github.com/harbour-collective/app/issues/180
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'On a crowded board' -

  : > "$home/gh.log"
  board "$home" import harbourlight "$issue" fm-crowded >/dev/null
  log=$(gh_log "$home")
  assert_not_contains "$log" 'endCursor' "import read the whole board"
  assert_contains "$log" '--single-select-option-id opt_processed' \
    "import did not move the card, so it had no board read to avoid"

  : > "$home/gh.log"
  board "$home" mark fm-crowded in-progress >/dev/null
  log=$(gh_log "$home")
  assert_not_contains "$log" 'endCursor' "mark read the whole board"
  assert_contains "$log" 'number=180' "mark did not resolve the card from its own issue"
  assert_contains "$log" '--single-select-option-id opt_prog' "mark did not move the card"

  # The ceiling itself is gone from this verb: `mark` refuses `--limit` rather
  # than quietly accepting an option it no longer uses.
  out=$(board "$home" mark fm-crowded 'done' --limit 500 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "mark still accepted a board-read ceiling it no longer uses"
  assert_contains "$out" 'unknown option' "the refused option was not named"
  pass "a single-card event resolves its card from the issue and never reads the board"
}

# --- silence, and what an invocation costs ----------------------------------

test_a_reconciled_board_polls_to_silence() {
  local home i issue out listed
  home=$(new_home a_reconciled_board_polls_to_silence)
  ordinary_board "$home"
  i=1
  while [ "$i" -le 12 ]; do
    issue="https://github.com/harbour-collective/app/issues/$((400 + i))"
    item "$home" "PVTI_s$i" Issue "$issue" Todo firstmate - "Settled work $i" -
    board "$home" import harbourlight "$issue" "fm-settled-$i" >/dev/null
    board "$home" mark "fm-settled-$i" in-progress >/dev/null
    i=$((i + 1))
  done

  : > "$home/gh.log"
  : > "$home/calls"
  out=$(board "$home" poll)
  [ -z "$out" ] || fail "a board with nothing to act on printed records: $out"
  assert_not_contains "$(gh_log "$home")" 'item-edit' "a reconciled cycle wrote to the board"
  [ "$(gh_calls "$home")" = 1 ] || \
    fail "a reconciled cycle spent more than its one board read: $(cat "$home/calls")"

  # The full listing is still one flag away, and it is only a listing: it writes
  # nothing the silent cycle did not already write.
  out=$(board "$home" poll --all)
  listed=$(printf '%s\n' "$out" | grep -c '^linked ' || true)
  [ "$listed" = 12 ] || fail "--all did not list every settled card, listed $listed"
  assert_contains "$out" "linked harbourlight https://github.com/harbour-collective/app/issues/401 fm-settled-1 in-progress" \
    "--all did not carry each card's recorded state"
  pass "a board with nothing to act on polls to no output, and --all still lists it"
}

# Silence is not the absence of an effect. A card whose board state already
# matches what firstmate wants, recorded against an older `synced`, is confirmed
# in the link record - the one durable thing a silent cycle does, and the only
# place it can be observed.
test_poll_confirms_a_write_the_board_already_shows() {
  local home issue out
  home=$(new_home poll_confirms_a_write_the_board_already_shows)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/510
  item "$home" PVTI_conf Issue "$issue" Todo firstmate - 'Landed by another hand' -
  board "$home" import harbourlight "$issue" fm-confirm >/dev/null
  board "$home" mark fm-confirm in-progress >/dev/null

  GH_FAIL='project item-edit' board "$home" mark fm-confirm 'done' >/dev/null 2>&1
  assert_contains "$(board "$home" lookup fm-confirm)" "done	in-progress" \
    "the refused move was not left owing a write"

  # The card reaches Done without firstmate writing it, so the write the next
  # cycle owes is already on the board.
  awk -F'\t' -v OFS='\t' '$1 == "PVTI_conf" { $4 = "Done" } { print }' \
    "$home/items" > "$home/items.next"
  mv "$home/items.next" "$home/items"

  : > "$home/gh.log"
  out=$(board "$home" poll)
  [ -z "$out" ] || fail "a card the board already agreed with printed a record: $out"
  assert_not_contains "$(gh_log "$home")" 'item-edit' \
    "poll rewrote a status the board was already showing"
  assert_contains "$(board "$home" lookup fm-confirm)" "done	done" \
    "poll did not confirm the write the board already showed"
  pass "poll confirms a write the board already shows, without printing or writing"
}

# THE COST GUARD.
#
# WHAT IT CATCHES. The stub records one line per call the adapter makes, so this
# counts them exactly. It fails the moment the number of calls one invocation
# makes depends on how many cards the board carries: a whole-board read moved
# back inside a per-item loop, a project or field id resolved per write instead
# of once for the run, or a single card found by paging the board. That is the
# defect worth a guard, because one board read costs around a hundred of the
# hourly five thousand GraphQL points, so forty-five of them exhaust the budget
# and rate-limit the account.
#
# WHAT IT DOES NOT CATCH. It counts calls, never points, so it says nothing
# about one call growing dearer - a raised `--limit`, or a query asking for more
# fields per card - and a board read is around a hundred times the price of the
# flat reads beside it, so equal call counts are not equal spend. It bounds one
# invocation, so a caller that loops a single-card verb still pays that verb's
# constant once per card; what makes that affordable is only that the constant
# no longer contains a board read. And it can only see the calls the stub
# models, so it would not notice pagination the real API forces on a response
# this fixture returns whole.
#
# The assertions are deliberately equalities rather than upper bounds, and there
# are three of them because they fail on different regressions. Comparing two
# boards an order of magnitude apart catches a read whose count follows the
# board: a read per card seen took the large board from 5 calls to 65 while the
# small one went to 11. That comparison alone is not enough, because a read per
# CHANGED card costs the same on both boards, so the exact call count catches
# that one: it went from 5 to 8 at three changed cards. And counting the
# whole-board read alone catches a single-card verb resolving its card by paging
# the board, which neither of the other two would see. Each of the three was
# reintroduced on purpose and confirmed to fail exactly the assertion named here.

# settled_board <home> <cards>: a board of that many cards, each imported,
# moved, and confirmed, so a poll of it has nothing left to do.
settled_board() {
  local home=$1 cards=$2 i=1 issue
  ordinary_board "$home"
  while [ "$i" -le "$cards" ]; do
    issue="https://github.com/harbour-collective/app/issues/$((7000 + i))"
    item "$home" "PVTI_c$i" Issue "$issue" Todo firstmate - "Card $i" -
    board "$home" import harbourlight "$issue" "fm-card-$i" >/dev/null
    board "$home" mark "fm-card-$i" in-progress >/dev/null
    i=$((i + 1))
  done
}

# owing <home> <count>: leave that many of the board's cards owing a write, by
# recording a move the board would not take.
owing() {
  local home=$1 count=$2 i=1
  while [ "$i" -le "$count" ]; do
    GH_FAIL='project item-edit' board "$home" mark "fm-card-$i" 'done' >/dev/null 2>&1
    i=$((i + 1))
  done
}

test_api_calls_do_not_grow_with_the_board() {
  local small large k=3 small_calls large_calls
  small=$(new_home api_calls_do_not_grow_small)
  large=$(new_home api_calls_do_not_grow_large)
  settled_board "$small" 6
  settled_board "$large" 60
  owing "$small" "$k"
  owing "$large" "$k"

  : > "$small/calls"
  : > "$large/calls"
  board "$small" poll >/dev/null
  board "$large" poll >/dev/null
  small_calls=$(gh_calls "$small")
  large_calls=$(gh_calls "$large")
  [ "$small_calls" = "$large_calls" ] || fail \
    "a cycle over 60 cards cost $large_calls calls where 6 cards cost $small_calls, for the same $k changed"
  # One board read, one id read for the run, one write per card that owes one.
  [ "$large_calls" = "$((k + 2))" ] || fail \
    "a cycle with $k changed cards cost $large_calls calls, not $((k + 2)): $(cat "$large/calls")"
  [ "$(gh_calls_of "$large" 'graphql items')" = 1 ] || fail \
    "the cycle read the board more than once"
  [ "$(gh_calls_of "$large" 'graphql ids')" = 1 ] || fail \
    "the project and field ids were resolved more than once in one cycle"
  [ "$(gh_calls_of "$large" 'project item-edit')" = "$k" ] || fail \
    "the cycle wrote to cards it did not owe a write"

  # A cycle with nothing to do costs its one board read and nothing else, at
  # either size.
  : > "$small/calls"
  : > "$large/calls"
  board "$small" poll >/dev/null
  board "$large" poll >/dev/null
  [ "$(gh_calls "$small")" = 1 ] && [ "$(gh_calls "$large")" = 1 ] || fail \
    "a settled cycle cost more than its one board read"

  # And the same holds for a single-card event, which is where the measured
  # exhaustion came from: forty-five of them in a row.
  : > "$small/calls"
  : > "$large/calls"
  board "$small" mark fm-card-1 todo >/dev/null
  board "$large" mark fm-card-1 todo >/dev/null
  small_calls=$(gh_calls "$small")
  large_calls=$(gh_calls "$large")
  [ "$small_calls" = "$large_calls" ] || fail \
    "moving one card cost $large_calls calls on 60 cards and $small_calls on 6"
  # The card lookup, the ids, and the write itself.
  [ "$large_calls" = 3 ] || fail \
    "moving one card cost $large_calls calls, not 3: $(cat "$large/calls")"
  [ "$(gh_calls_of "$large" 'graphql items')" = 0 ] || fail \
    "moving one card read the whole board"
  pass "what an invocation costs is set by the work it does, never by the board's size"
}

# --- containers and their children ------------------------------------------

# The same ordinary board, plus the three container columns.
big_picture_board() {
  local home=$1
  cat > "$home/config/boards" <<'EOF'
project = harbourlight
owner = harbour-collective
number = 4
repo = harbour-collective/app
label = firstmate
big-picture-todo = Big Picture Todo
big-picture-in-progress = Big Picture In Progress
big-picture-done = Big Picture Done
EOF
  fields "$home" PVTSSF_status opt_todo:Todo 'opt_prog:In Progress' opt_done:Done \
    'opt_bptodo:Big Picture Todo' 'opt_bpprog:Big Picture In Progress' \
    'opt_bpdone:Big Picture Done'
}

issues_created() {
  wc -l < "$1/issues" | tr -d ' '
}

test_the_container_lane_does_not_exist_until_it_is_configured() {
  local home out
  home=$(new_home the_container_lane_does_not_exist_until_it_is_configured)
  # Exactly the container board, minus the three keys.
  ordinary_board "$home"
  item "$home" PVTI_a Issue https://github.com/harbour-collective/app/issues/200 \
    'Big Picture Todo' firstmate - 'A container nobody configured for' -
  item "$home" PVTI_b Issue https://github.com/harbour-collective/app/issues/201 \
    Todo firstmate - 'Ordinary work' -

  out=$(board "$home" poll)
  assert_not_contains "$out" 'decompose' "an unconfigured home offered a decomposition"
  assert_not_contains "$out" 'issues/200' "an unconfigured home acted on a container column at all"
  assert_contains "$out" 'new harbourlight https://github.com/harbour-collective/app/issues/201 label' \
    "an ordinary Todo card stopped being importable"
  assert_absent "$home/data/board-decompositions.tsv" \
    "an unconfigured home created a decomposition record"
  [ "$(issues_created "$home")" = 0 ] || fail "an unconfigured home created an issue"
  assert_contains "$(board "$home" boards)" 'big-picture=off' \
    "an unconfigured board reported container columns"
  pass "with no container columns configured nothing about decomposition exists"
}

test_a_partial_container_configuration_is_refused() {
  local home out rc
  home=$(new_home a_partial_container_configuration_is_refused)
  cat > "$home/config/boards" <<'EOF'
project = harbourlight
owner = harbour-collective
number = 4
big-picture-todo = Big Picture Todo
big-picture-done = Big Picture Done
EOF
  out=$(board "$home" poll 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a half-configured container lane was accepted"
  assert_contains "$out" 'big-picture' "the refusal did not name the incomplete key set"
  [ -z "$(gh_log "$home")" ] || fail "a refused configuration still reached GitHub"

  cat > "$home/config/boards" <<'EOF'
project = harbourlight
owner = harbour-collective
number = 4
todo = Todo
big-picture-todo = Todo
big-picture-in-progress = Big Picture In Progress
big-picture-done = Big Picture Done
EOF
  out=$(board "$home" poll 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "one column serving as both ordinary and container work was accepted"
  assert_contains "$out" 'more than one column' "the duplicate column was not named"
  pass "a half-configured or self-overlapping container lane is refused, never half-enabled"
}

test_a_container_is_offered_for_decomposition_and_never_imported() {
  local home parent out rc
  home=$(new_home a_container_is_offered_for_decomposition_and_never_imported)
  big_picture_board "$home"
  parent=https://github.com/harbour-collective/app/issues/210
  item "$home" PVTI_p Issue "$parent" 'Big Picture Todo' firstmate - 'Rebuild the harbour' 'lots of work'
  item "$home" PVTI_q Issue https://github.com/harbour-collective/app/issues/211 \
    'Big Picture Todo' - - 'An untagged container' -

  out=$(board "$home" poll)
  assert_contains "$out" "decompose harbourlight $parent" "a labelled container was not offered for decomposition"
  assert_not_contains "$out" "new harbourlight $parent" "a container was offered as importable work"
  assert_not_contains "$out" 'issues/211' "an untagged container was offered for decomposition"

  # The binding a container must never spend is unspendable from the moment the
  # board first showed the card, not only once it has been broken down.
  out=$(board "$home" import harbourlight "$parent" fm-container 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "a container was allowed to bind a task"
  assert_contains "$out" 'container' "the refusal did not say why the container cannot hold a task"
  [ -z "$(board "$home" links)" ] || fail "a container wrote a linkage record"

  board "$home" decomposed harbourlight "$parent" >/dev/null
  board "$home" import harbourlight "$parent" fm-container >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 3 "$rc" "a decomposed container was allowed to bind a task"

  # And the refusal closes from the other side too: an issue that already holds a
  # task can never be turned into a container.
  item "$home" PVTI_w Issue https://github.com/harbour-collective/app/issues/212 \
    Todo firstmate - 'Ordinary work' -
  board "$home" import harbourlight https://github.com/harbour-collective/app/issues/212 fm-ordinary >/dev/null
  out=$(board "$home" child-add harbourlight https://github.com/harbour-collective/app/issues/212 \
    'A child of ordinary work' 'body' fm-child 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "work that already holds a task was accepted as a container"
  assert_contains "$out" 'ordinary work' "the refusal did not say why the task cannot be a container"
  pass "a labelled container is offered for decomposition, and container and task can never be the same issue"
}

test_a_container_is_never_offered_twice_once_decomposed() {
  local home parent out
  home=$(new_home a_container_is_never_offered_twice_once_decomposed)
  big_picture_board "$home"
  parent=https://github.com/harbour-collective/app/issues/220
  item "$home" PVTI_p Issue "$parent" 'Big Picture Todo' firstmate - 'Rebuild the harbour' -

  out=$(board "$home" poll)
  assert_contains "$out" 'decompose' "the container was not offered at all"
  # An interrupted decomposition is finished, not lost: it keeps being offered.
  out=$(board "$home" poll)
  assert_contains "$out" 'decompose' "an unfinished decomposition stopped being offered"

  board "$home" decomposed harbourlight "$parent" >/dev/null
  out=$(board "$home" poll)
  assert_not_contains "$out" 'decompose' "a decomposed container was offered a second time"

  # The record outlives the tasks it produced, exactly as the linkage record does.
  rm -rf "$home/state"
  out=$(board "$home" poll)
  assert_not_contains "$out" 'decompose' "the decomposition record did not survive task cleanup"
  pass "a container is decomposed once, ever, and the record outlives the work"
}

test_a_child_is_created_linked_and_never_re_imported() {
  local home parent out child log
  home=$(new_home a_child_is_created_linked_and_never_re_imported)
  big_picture_board "$home"
  parent=https://github.com/harbour-collective/app/issues/230
  item "$home" PVTI_p Issue "$parent" 'Big Picture Todo' firstmate - 'Rebuild the harbour' -

  out=$(board "$home" child-add harbourlight "$parent" 'Replace the mooring lines' \
    'The first piece of the rebuild.' fm-moorings)
  assert_contains "$out" "child harbourlight $parent" "the child was not reported as created"
  child=$(printf '%s' "$out" | cut -d" " -f4)
  log=$(gh_log "$home")
  assert_contains "$log" "--parent $parent" "the child was not created as a native sub-issue of the parent"
  assert_contains "$log" '--label firstmate' "the child did not carry the trigger label"
  assert_contains "$log" '--single-select-option-id opt_todo' "the child was not set to the ordinary Todo column"
  assert_not_contains "$log" 'endCursor' "creating a child read the whole board"
  assert_contains "$(board "$home" lookup fm-moorings)" "$child" "the child did not record its issue-to-task link"

  # The next cycle sees an ordinary linked card, never new work.
  out=$(board "$home" poll --all)
  assert_contains "$out" "linked harbourlight $child fm-moorings todo" "the child was not reported as linked"
  assert_not_contains "$out" "new harbourlight $child" "the child was offered as fresh work to import"
  pass "a child is created labelled, linked to its parent, carded in Todo, and never re-imported"
}

test_child_add_converges_instead_of_filing_a_second_issue() {
  local home parent out first
  home=$(new_home child_add_converges_instead_of_filing_a_second_issue)
  big_picture_board "$home"
  parent=https://github.com/harbour-collective/app/issues/240
  item "$home" PVTI_p Issue "$parent" 'Big Picture Todo' firstmate - 'Rebuild the harbour' -

  # The card cannot be added, so the run stops half way with the issue created.
  out=$(GH_FAIL="project item-add" board "$home" child-add harbourlight "$parent" \
    'Dredge the channel' 'Second piece.' fm-dredge)
  assert_contains "$out" 'child-partial' "an interrupted child was reported as complete"
  assert_contains "$out" ' card' "the partial result did not name the step that failed"
  [ "$(issues_created "$home")" = 1 ] || fail "the interrupted run did not create exactly one issue"
  first=$(cut -f2 "$home/issues")
  [ -z "$(board "$home" lookup fm-dredge)" ] || fail "an uncarded child recorded a link"

  # Re-running finishes the job rather than filing the work twice.
  out=$(board "$home" child-add harbourlight "$parent" 'Dredge the channel' 'Second piece.' fm-dredge)
  assert_contains "$out" "child harbourlight $parent $first fm-dredge" \
    "the repeat run did not converge on the issue that already existed"
  [ "$(issues_created "$home")" = 1 ] || fail "the repeat run filed a second issue for the same work"

  # And a third run is a plain no-op that touches nothing at all.
  : > "$home/gh.log"
  out=$(board "$home" child-add harbourlight "$parent" 'Dredge the channel' 'Second piece.' fm-dredge)
  assert_contains "$out" 'already-child' "a settled child was not reported as already done"
  [ -z "$(gh_log "$home")" ] || fail "a settled child still reached GitHub"
  pass "an interrupted child-add converges on the issue it already filed, never a second one"
}

test_a_container_card_follows_its_children() {
  local home parent out log
  home=$(new_home a_container_card_follows_its_children)
  big_picture_board "$home"
  parent=https://github.com/harbour-collective/app/issues/250
  item "$home" PVTI_p Issue "$parent" 'Big Picture Todo' firstmate - 'Rebuild the harbour' -
  board "$home" child-add harbourlight "$parent" 'Piece one' 'body' fm-piece-one >/dev/null
  board "$home" child-add harbourlight "$parent" 'Piece two' 'body' fm-piece-two >/dev/null
  board "$home" decomposed harbourlight "$parent" >/dev/null

  # Nothing has started, so the container stays where it is and says nothing.
  : > "$home/gh.log"
  out=$(board "$home" poll)
  assert_not_contains "$out" "$parent" "a settled container printed a record with nothing to report"
  assert_not_contains "$(gh_log "$home")" 'item-edit' "a settled container was written to the board"

  # One child starts.
  board "$home" mark fm-piece-one in-progress >/dev/null
  : > "$home/gh.log"
  out=$(board "$home" poll)
  assert_contains "$out" "synced harbourlight $parent - in-progress" \
    "a child in progress did not move its container"
  assert_contains "$(gh_log "$home")" '--single-select-option-id opt_bpprog' \
    "the container was not moved to this board's own container In Progress column"

  # Both children finish.
  board "$home" mark fm-piece-one 'done' >/dev/null
  board "$home" mark fm-piece-two 'done' >/dev/null
  : > "$home/gh.log"
  out=$(board "$home" poll)
  assert_contains "$out" "synced harbourlight $parent - done" "all children done did not finish the container"
  assert_contains "$(gh_log "$home")" '--single-select-option-id opt_bpdone' \
    "the container was not moved to this board's own container Done column"

  # Settled again, and silent again.
  out=$(board "$home" poll)
  assert_not_contains "$out" "$parent" "a settled container kept reporting"
  pass "a container card follows its children's recorded states, and is silent once it matches"
}

# THE DEFECT THIS PINS. A container's card used to be derived from the children
# firstmate had recorded, which only ever holds what `child-add` put there. A
# programme whose sub-issues someone added on GitHub therefore derived done the
# moment the handful firstmate created had closed, and moved to the big-picture
# done column with most of its real work still open. A poll of that board
# reported everything settled and printed nothing, because the card and the
# record agreed with each other; the disagreement was between the record and
# GitHub, and nothing compared those. So the assertion that matters most here is
# the silent one: a clean cycle has to stop being compatible with an umbrella
# that is wrong.
test_a_container_follows_every_sub_issue_github_records() {
  local home parent recorded out
  home=$(new_home a_container_follows_every_sub_issue_github_records)
  big_picture_board "$home"
  parent=https://github.com/harbour-collective/app/issues/270
  item "$home" PVTI_p Issue "$parent" 'Big Picture Todo' firstmate - 'Rebuild the harbour' -

  # One piece firstmate created and holds a task for, and four more attached to
  # the container on GitHub by someone else. The record can only ever see the
  # first of them.
  out=$(board "$home" child-add harbourlight "$parent" 'Piece one' 'body' fm-recorded)
  recorded=$(printf '%s' "$out" | cut -d" " -f4)
  sub_issue "$home" https://github.com/harbour-collective/app/issues/271 "$parent" closed
  sub_issue "$home" https://github.com/harbour-collective/app/issues/272 "$parent" closed
  sub_issue "$home" https://github.com/harbour-collective/app/issues/273 "$parent" open
  sub_issue "$home" https://github.com/harbour-collective/app/issues/274 "$parent" open
  board "$home" decomposed harbourlight "$parent" >/dev/null

  assert_contains "$(board "$home" decompositions)" "fm-recorded=$recorded" \
    "the recorded children stopped holding the child-to-task binding"
  assert_not_contains "$(board "$home" decompositions)" 'issues/273' \
    "the fixture recorded a child firstmate never created, so it proves nothing"

  # Every child firstmate recorded is finished. Under the old derivation that was
  # the whole of the answer and the container moved to done.
  board "$home" mark fm-recorded 'done' >/dev/null
  : > "$home/gh.log"
  out=$(board "$home" poll)
  assert_not_contains "$out" "$parent - done" \
    "a container with four open sub-issues was finished by its recorded children alone"
  assert_not_contains "$(gh_log "$home")" '--single-select-option-id opt_bpdone' \
    "the card was moved to the container Done column with work still open"
  assert_contains "$out" "synced harbourlight $parent - in-progress" \
    "a container part finished and part open did not report itself under way"
  assert_contains "$(gh_log "$home")" '--single-select-option-id opt_bpprog' \
    "the card was not moved to this board's own container In Progress column"

  # Finishing the sub-issues firstmate holds no task for is what finishes the
  # container, which is the other half of counting them at all.
  close_sub_issue "$home" https://github.com/harbour-collective/app/issues/273
  : > "$home/gh.log"
  out=$(board "$home" poll)
  assert_not_contains "$out" "$parent - done" \
    "one of two remaining children closing already finished the container"
  assert_not_contains "$(gh_log "$home")" 'item-edit' \
    "a container already showing under way was written to the board again"
  close_sub_issue "$home" https://github.com/harbour-collective/app/issues/274
  out=$(board "$home" poll)
  assert_contains "$out" "synced harbourlight $parent - done" \
    "every child being closed did not finish the container"
  out=$(board "$home" poll)
  assert_not_contains "$out" "$parent" "a settled container kept reporting"
  pass "a container is finished by every sub-issue GitHub records under it, not by the ones firstmate created"
}

test_a_container_with_no_sub_issues_derives_nothing() {
  local home parent out
  home=$(new_home a_container_with_no_sub_issues_derives_nothing)
  big_picture_board "$home"
  parent=https://github.com/harbour-collective/app/issues/280
  item "$home" PVTI_p Issue "$parent" 'Big Picture Todo' firstmate - 'Nothing under it yet' -
  board "$home" decomposed harbourlight "$parent" >/dev/null

  : > "$home/gh.log"
  out=$(board "$home" poll)
  assert_not_contains "$out" "synced harbourlight $parent" \
    "a container with no children was given a derived state"
  assert_not_contains "$(gh_log "$home")" 'item-edit' \
    "a container with no children was written to the board"
  # Emphatically not done: having nothing under it is not having finished.
  assert_not_contains "$out" 'done' "a container with no children was reported finished"
  pass "a container with no sub-issues derives no state at all, exactly as before"
}

# A read that did not land must not fall back to the recorded children, because
# that subset is the wrong answer this read exists to replace: falling back is
# how a container reports done while its real work is open.
test_children_that_cannot_be_read_derive_nothing_and_say_so() {
  local home parent out
  home=$(new_home children_that_cannot_be_read_derive_nothing_and_say_so)
  big_picture_board "$home"
  parent=https://github.com/harbour-collective/app/issues/290
  item "$home" PVTI_p Issue "$parent" 'Big Picture Todo' firstmate - 'Rebuild the harbour' -
  board "$home" child-add harbourlight "$parent" 'Piece one' 'body' fm-recorded >/dev/null
  board "$home" decomposed harbourlight "$parent" >/dev/null
  board "$home" mark fm-recorded 'done' >/dev/null

  out=$(GH_FAIL='project item-edit' board "$home" poll)
  assert_contains "$out" "stale harbourlight $parent - done" \
    "the setup did not leave a pending Done transition"
  assert_equals "$(printf 'done\t-')" "$(board "$home" decompositions | cut -f4,5)" \
    "the failed write did not persist an outstanding Done transition"
  sub_issue "$home" https://github.com/harbour-collective/app/issues/291 "$parent" open

  : > "$home/gh.log"
  out=$(GH_FAIL='api repos/*sub_issues' board "$home" poll)
  assert_contains "$out" "error harbourlight could not read the children of $parent" \
    "a container whose children could not be read said nothing about it"
  assert_not_contains "$out" "$parent - done" \
    "an unreadable read fell back to the recorded children and finished the container"
  assert_not_contains "$(gh_log "$home")" 'item-edit' \
    "a container whose state could not be told was still written to the board"
  assert_equals 'Big Picture Todo' \
    "$(awk -F'\t' '$1 == "PVTI_p" { print $4 }' "$home/items")" \
    "a failed children read moved the container to Done"

  # The next cycle reads them and reconciles, so nothing is lost by declining.
  out=$(board "$home" poll)
  assert_contains "$out" "synced harbourlight $parent - in-progress" \
    "the cycle after a failed children read did not reconcile the container"
  pass "children that cannot be read derive nothing, report it, and are reconciled next cycle"
}

# The cost guard's own reasoning applied to the one per-card read in this file.
# What makes it affordable is not that it is free but that it contains no board
# read, and that only a card in the container lane pays it.
test_a_container_costs_one_flat_read_and_never_a_board_read() {
  local home parent i out containers
  home=$(new_home a_container_costs_one_flat_read_and_never_a_board_read)
  big_picture_board "$home"
  parent=https://github.com/harbour-collective/app/issues/300
  item "$home" PVTI_p Issue "$parent" 'Big Picture Todo' firstmate - 'Rebuild the harbour' -
  board "$home" decomposed harbourlight "$parent" >/dev/null
  # Forty ordinary cards beside it, each imported, moved, and confirmed.
  i=1
  while [ "$i" -le 40 ]; do
    item "$home" "PVTI_c$i" Issue "https://github.com/harbour-collective/app/issues/$((7000 + i))" \
      Todo firstmate - "Card $i" -
    board "$home" import harbourlight "https://github.com/harbour-collective/app/issues/$((7000 + i))" "fm-card-$i" >/dev/null
    board "$home" mark "fm-card-$i" in-progress >/dev/null
    i=$((i + 1))
  done

  : > "$home/calls"
  out=$(board "$home" poll)
  containers=$(grep -c 'sub_issues' "$home/calls" || true)
  [ "$containers" = 1 ] || fail \
    "a cycle over one container and forty ordinary cards read sub-issues $containers times"
  [ "$(gh_calls "$home")" = 2 ] || fail \
    "a settled cycle with one container cost more than its board read and that container's children: $(cat "$home/calls")"
  [ "$(gh_calls_of "$home" 'graphql items')" = 1 ] || fail \
    "reading a container's children read the board"

  # A second container costs one more flat read, and the ordinary cards cost none.
  item "$home" PVTI_q Issue https://github.com/harbour-collective/app/issues/301 \
    'Big Picture Todo' firstmate - 'Another programme' -
  board "$home" decomposed harbourlight https://github.com/harbour-collective/app/issues/301 >/dev/null
  : > "$home/calls"
  board "$home" poll >/dev/null
  [ "$(grep -c 'sub_issues' "$home/calls" || true)" = 2 ] || fail \
    "two containers did not cost exactly two flat reads: $(cat "$home/calls")"
  [ "$(gh_calls "$home")" = 3 ] || fail \
    "the cycle cost more than its board read and one read per container: $(cat "$home/calls")"
  pass "a container's children cost one flat read per container, never a board read, and ordinary cards pay nothing"
}

test_an_outstanding_container_move_is_retried_on_the_next_cycle() {
  local home parent out
  home=$(new_home an_outstanding_container_move_is_retried_on_the_next_cycle)
  big_picture_board "$home"
  parent=https://github.com/harbour-collective/app/issues/260
  item "$home" PVTI_p Issue "$parent" 'Big Picture Todo' firstmate - 'Rebuild the harbour' -
  board "$home" child-add harbourlight "$parent" 'Piece one' 'body' fm-only-piece >/dev/null
  board "$home" decomposed harbourlight "$parent" >/dev/null
  board "$home" mark fm-only-piece in-progress >/dev/null

  out=$(GH_FAIL="project item-edit" board "$home" poll)
  assert_contains "$out" "stale harbourlight $parent - in-progress" \
    "a container move that did not land was not reported as stale"
  out=$(board "$home" poll)
  assert_contains "$out" "synced harbourlight $parent - in-progress" \
    "an outstanding container move was not retried on the next cycle"
  pass "a container move that does not land leaves a stale card the next cycle reconciles"
}

# --- placing work firstmate already holds ------------------------------------

test_place_is_the_inverse_of_import() {
  local home out issue log
  home=$(new_home place_is_the_inverse_of_import)
  repo_board "$home"

  out=$(board "$home" place harbourlight fm-already-mine 'Work that started in the backlog' \
    'Filed by firstmate, not by the captain.')
  assert_contains "$out" 'placed harbourlight' "the task was not placed on the board"
  issue=$(printf '%s' "$out" | cut -d" " -f3)
  log=$(gh_log "$home")
  assert_contains "$log" '--label firstmate' "the placed card did not carry the trigger label"
  assert_contains "$log" '--single-select-option-id opt_todo' "the placed card was not set to Todo"
  assert_not_contains "$log" 'endCursor' "placing a card read the whole board"
  assert_contains "$(board "$home" lookup fm-already-mine)" "$issue" "placing did not record the link"

  # From here it is an ordinary board task: dispatch, PR and merge all work.
  out=$(board "$home" mark fm-already-mine in-progress)
  assert_contains "$out" "synced harbourlight $issue fm-already-mine in-progress" \
    "a placed task did not move on dispatch"
  out=$(board "$home" poll)
  assert_not_contains "$out" 'new harbourlight' "a placed card was offered as fresh work to import"

  # Repeating is a no-op that never files a second issue and never asks GitHub.
  : > "$home/gh.log"
  out=$(board "$home" place harbourlight fm-already-mine 'Work that started in the backlog')
  assert_contains "$out" "already-placed harbourlight $issue fm-already-mine" \
    "a repeat placement was not reported as already done"
  [ "$(issues_created "$home")" = 1 ] || fail "a repeat placement filed a second issue"
  [ -z "$(gh_log "$home")" ] || fail "a repeat placement reached GitHub at all"
  pass "place is the inverse of import: one command, convergent, and ordinary afterwards"
}

test_place_says_where_the_change_actually_lands() {
  local home out body
  home=$(new_home place_says_where_the_change_actually_lands)
  repo_board "$home"
  board "$home" place harbourlight fm-elsewhere-work 'Work that lands in another repo' \
    'The roadmap carries it; the diff does not.' --lands-in harbour-collective/tooling >/dev/null
  body=$(cut -f4 "$home/issues")
  assert_contains "$body" 'Lands in: harbour-collective/tooling' \
    "the card did not say which repository the change lands in"
  out=$(board "$home" place harbourlight fm-bad-repo 'Bad' 'Bad' --lands-in 'not a repo' 2>&1) && rc=0 || rc=$?
  expect_code 2 "${rc:-0}" "a malformed landing repository was accepted"
  pass "a card can state plainly that its change lands somewhere other than its own repository"
}

test_placement_converges_after_an_interrupted_run() {
  local home out first
  home=$(new_home placement_converges_after_an_interrupted_run)
  repo_board "$home"

  out=$(GH_FAIL="project item-add" board "$home" place harbourlight fm-interrupted 'Interrupted placement' 'body')
  assert_contains "$out" 'placed-partial' "an interrupted placement was reported as complete"
  [ "$(issues_created "$home")" = 1 ] || fail "the interrupted run did not create exactly one issue"
  first=$(cut -f2 "$home/issues")

  out=$(board "$home" place harbourlight fm-interrupted 'Interrupted placement' 'body')
  assert_contains "$out" "placed harbourlight $first fm-interrupted" \
    "the repeat run did not converge on the issue it had already filed"
  [ "$(issues_created "$home")" = 1 ] || fail "the repeat run filed a second issue for the same task"
  pass "an interrupted placement is finished on the next run, never filed twice"
}

test_an_unreadable_repo_never_files_a_duplicate() {
  local home out rc
  home=$(new_home an_unreadable_repo_never_files_a_duplicate)
  repo_board "$home"
  out=$(GH_FAIL="issue list" board "$home" place harbourlight fm-unreadable 'Work' 'body' 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a placement continued after it could not check for an existing issue"
  [ "$(issues_created "$home")" = 0 ] || fail "an unchecked placement filed an issue anyway"
  pass "a check that cannot run stops the placement rather than risking a duplicate"
}

# --- the captain's inbox and firstmate's answer ------------------------------

test_the_processed_column_does_not_exist_until_it_is_configured() {
  local home issue out rc
  home=$(new_home the_processed_column_does_not_exist_until_it_is_configured)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/300
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Ordinary work' -

  assert_contains "$(board "$home" boards)" 'processed=-' \
    "an unconfigured board reported an internalized column"
  out=$(board "$home" import harbourlight "$issue" fm-ordinary)
  assert_contains "$out" "linked harbourlight $issue fm-ordinary" \
    "import stopped reporting the link it made"
  assert_not_contains "$out" 'processed' "an unconfigured home reported an internalized card"
  assert_contains "$(board "$home" lookup fm-ordinary)" "	todo	todo	" \
    "an unconfigured home recorded a column it never had"
  [ -z "$(gh_log "$home")" ] || fail "an unconfigured home reached the board to internalize: $(gh_log "$home")"

  out=$(board "$home" mark fm-ordinary processed 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "an unconfigured internalized column was still writable"
  assert_contains "$out" 'no processed column configured' "the refusal did not name the missing column"

  # A board that happens to carry such a column reads it as a column firstmate
  # does not drive, exactly as it did before the key existed.
  : > "$home/items"
  item "$home" PVTI_a Issue "$issue" Processed firstmate - 'Ordinary work' -
  out=$(board "$home" poll)
  assert_contains "$out" "divergence harbourlight $issue fm-ordinary todo other Processed" \
    "an unconfigured internalized column was read as an internalized state"
  pass "with no processed key configured the column does not exist in either direction"
}

test_internalizing_a_filed_card_moves_it_out_of_the_inbox() {
  local home issue out
  home=$(new_home internalizing_a_filed_card_moves_it_out_of_the_inbox)
  processed_board "$home"
  issue=https://github.com/harbour-collective/app/issues/310
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Filed by the captain' -

  out=$(board "$home" poll)
  assert_contains "$out" "new harbourlight $issue label" "a filed card was not offered"

  : > "$home/gh.log"
  out=$(board "$home" import harbourlight "$issue" fm-filed)
  assert_contains "$out" "linked harbourlight $issue fm-filed processed" \
    "internalizing did not report the card leaving the inbox"
  assert_contains "$(gh_log "$home")" '--single-select-option-id opt_processed' \
    "internalizing did not write this board's own Processed option"
  assert_contains "$(board "$home" lookup fm-filed)" "	processed	processed	" \
    "the record did not carry the internalized state it wrote"

  # The card has left the inbox, so it is never offered as new work again and a
  # reconciled board says only that it agrees.
  : > "$home/gh.log"
  out=$(board "$home" poll --all)
  assert_not_contains "$out" 'new ' "an internalized card was offered as new work again"
  assert_contains "$out" "linked harbourlight $issue fm-filed processed" \
    "the internalized card was not reported as agreeing"
  assert_not_contains "$(gh_log "$home")" 'item-edit' "a reconciled card was written again"

  # And the ordinary execution events still run from there with no special case.
  board "$home" mark fm-filed in-progress >/dev/null
  assert_contains "$(board "$home" lookup fm-filed)" "	in-progress	in-progress	" \
    "an internalized card could not move on to the ordinary events"
  pass "internalizing a filed card moves it from the captain's inbox to firstmate's answer"
}

test_a_card_left_in_the_inbox_is_never_restatused() {
  local home issue out
  home=$(new_home a_card_left_in_the_inbox_is_never_restatused)
  processed_board "$home"
  issue=https://github.com/harbour-collective/app/issues/320
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Not picked up yet' -

  # Firstmate has not internalized it, so nothing moves it and it keeps being
  # offered. A card still sitting in the inbox is honest signal about that.
  out=$(board "$home" poll)
  assert_contains "$out" "new harbourlight $issue label" "an un-internalized card stopped being offered"
  out=$(board "$home" poll)
  assert_contains "$out" "new harbourlight $issue label" "an un-internalized card was offered only once"
  assert_not_contains "$(gh_log "$home")" 'item-edit' "a card nobody internalized was moved anyway"
  assert_contains "$(awk -F'\t' '$1 == "PVTI_a" { print $4 }' "$home/items")" 'Todo' \
    "a card nobody internalized left the inbox"

  # A write that does not land is the same honesty in the other direction: the
  # record says internalized, the card still says inbox, and the next cycle
  # finishes the job rather than the adapter claiming it already had.
  out=$(GH_FAIL="project item-edit" board "$home" import harbourlight "$issue" fm-notyet 2>/dev/null)
  assert_contains "$out" "linked-stale harbourlight $issue fm-notyet processed" \
    "an internalizing write that failed was reported as if it had landed"
  assert_contains "$(board "$home" lookup fm-notyet)" "	processed	todo	" \
    "a failed write did not leave an outstanding move"
  assert_contains "$(awk -F'\t' '$1 == "PVTI_a" { print $4 }' "$home/items")" 'Todo' \
    "a failed write moved the card anyway"

  out=$(board "$home" poll)
  assert_contains "$out" "synced harbourlight $issue fm-notyet processed" \
    "the outstanding move was not retried on the next cycle"
  assert_not_contains "$out" 'new ' "a linked card was offered as new work"
  pass "a card in the inbox is left there until firstmate internalizes it, and never restatused early"
}

test_work_firstmate_files_itself_never_sits_in_the_inbox() {
  local home out parent
  home=$(new_home work_firstmate_files_itself_never_sits_in_the_inbox)
  programme_board "$home"

  # Work that started in the backlog never sat in the captain's inbox, so its
  # card is filed already internalized.
  out=$(board "$home" place harbourlight fm-ours 'Work firstmate already held' 'body')
  assert_contains "$out" 'placed harbourlight' "placing work firstmate holds did not land"
  assert_contains "$(board "$home" lookup fm-ours)" "	processed	processed	" \
    "work firstmate filed itself was recorded as sitting in the captain's inbox"
  assert_contains "$(gh_log "$home")" '--single-select-option-id opt_processed' \
    "work firstmate filed itself was carded into the inbox"

  # A child of a container is firstmate's own work for the same reason.
  parent=https://github.com/harbour-collective/app/issues/330
  item "$home" PVTI_p Issue "$parent" 'Big Picture Processed' firstmate - 'A programme' -
  board "$home" poll >/dev/null
  : > "$home/gh.log"
  out=$(board "$home" child-add harbourlight "$parent" 'A concrete piece' 'body' fm-piece)
  assert_contains "$out" "child harbourlight $parent" "a child was not created"
  assert_contains "$(board "$home" lookup fm-piece)" "	processed	processed	" \
    "a generated child was recorded as sitting in the captain's inbox"
  assert_contains "$(gh_log "$home")" '--single-select-option-id opt_processed' \
    "a generated child was carded into the inbox"
  pass "work firstmate creates itself is filed already internalized, never into the captain's inbox"
}

test_a_queued_card_still_reports_rather_than_launches() {
  local home issue out
  home=$(new_home a_queued_card_still_reports_rather_than_launches)
  processed_board "$home"
  issue=https://github.com/harbour-collective/app/issues/340
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Awaiting the go' -
  board "$home" import harbourlight "$issue" fm-awaiting >/dev/null

  # The captain's go is a chat instruction, so a card that appears in the go
  # column on its own can only mean something outside firstmate wrote there.
  : > "$home/items"
  : > "$home/gh.log"
  item "$home" PVTI_a Issue "$issue" Queued firstmate - 'Awaiting the go' -
  out=$(board "$home" poll)
  assert_contains "$out" "divergence harbourlight $issue fm-awaiting processed queued Queued" \
    "a go firstmate never gave was not reported"
  assert_contains "$(board "$home" lookup fm-awaiting)" "	processed	processed	" \
    "the record adopted a go firstmate never gave"
  assert_not_contains "$(gh_log "$home")" 'item-edit' "the divergence caused a board write"

  # Firstmate's own record is still the only thing that puts a card there.
  : > "$home/gh.log"
  out=$(board "$home" mark fm-awaiting queued)
  assert_contains "$out" "synced harbourlight $issue fm-awaiting queued" \
    "firstmate could not record the captain's go"
  assert_contains "$(gh_log "$home")" '--single-select-option-id opt_queued' \
    "the go was not written to this board's own column"
  pass "a card appearing in the go column unbidden is reported, never obeyed"
}

# --- firstmate-initiated promotion to a programme ----------------------------

test_firstmate_promotes_a_filed_card_to_a_programme() {
  local home issue out rc
  home=$(new_home firstmate_promotes_a_filed_card_to_a_programme)
  programme_board "$home"
  issue=https://github.com/harbour-collective/app/issues/350
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Rebuild the harbour' 'far too big for one task'

  # It arrives as ordinary filed work, because the captain files into one inbox.
  out=$(board "$home" poll)
  assert_contains "$out" "new harbourlight $issue label" "a filed card was not offered"

  out=$(board "$home" promote harbourlight "$issue")
  assert_contains "$out" "promoted harbourlight $issue" "the card was not promoted to a programme"
  assert_contains "$(awk -F'\t' -v u="$issue" '$3 == u { print $4 }' "$home/items")" \
    'Big Picture Processed' "a promoted card did not reach the container lane"

  # It is a container from that moment: never offered as work again, never
  # bindable, and offered for breaking down until it is closed.
  out=$(board "$home" poll)
  assert_not_contains "$out" 'new ' "a promoted card was still offered as ordinary work"
  assert_contains "$out" "decompose harbourlight $issue" "a promoted card was not offered for breaking down"
  board "$home" import harbourlight "$issue" fm-programme >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 3 "$rc" "a promoted container was allowed to bind a task"

  board "$home" child-add harbourlight "$issue" 'Dredge the channel' 'body' fm-dredge >/dev/null
  board "$home" child-add harbourlight "$issue" 'Rebuild the jetty' 'body' fm-jetty >/dev/null
  board "$home" decomposed harbourlight "$issue" >/dev/null
  out=$(board "$home" poll)
  assert_not_contains "$out" 'decompose' "a broken-down programme was offered again"

  # The children hold the work; the parent holds none of it.
  board "$home" lookup "$issue" >/dev/null 2>&1 && rc=0 || rc=$?
  [ "$rc" != 0 ] || fail "a promoted container ended up holding a task binding"
  board "$home" lookup fm-dredge >/dev/null || fail "a generated child holds no link"
  board "$home" lookup fm-jetty >/dev/null || fail "a generated child holds no link"

  # And the container's own card then follows those children with no further
  # instruction, exactly as a captain-filed container's does.
  board "$home" mark fm-dredge in-progress >/dev/null
  out=$(board "$home" poll)
  assert_contains "$out" "synced harbourlight $issue - in-progress" \
    "a promoted container's card did not follow its children"
  pass "firstmate promotes a filed card to a programme, and its children carry the work"
}

test_a_bound_issue_can_never_become_a_container() {
  local home issue out rc parent child placed before
  home=$(new_home a_bound_issue_can_never_become_a_container)
  programme_board "$home"
  issue=https://github.com/harbour-collective/app/issues/360
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Internalized as one task' -

  # Judged as one shippable task first, which spends the issue's one binding.
  board "$home" import harbourlight "$issue" fm-onetask >/dev/null

  # Promotion after that is a one-way door already shut. It is refused by the
  # mechanism rather than by the caller remembering the order.
  out=$(board "$home" promote harbourlight "$issue" 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "a bound issue was allowed to become a container"
  assert_contains "$out" 'fm-onetask' "the refusal did not name the task holding the binding"
  assert_contains "$out" 'never become a container' "the refusal did not say the door is shut"
  assert_absent "$home/data/board-decompositions.tsv" \
    "a refused promotion still recorded a container"
  assert_contains "$(board "$home" lookup fm-onetask)" "	processed	processed	" \
    "a refused promotion disturbed the binding it refused to spend"

  # Nor by the other route into the same record.
  out=$(board "$home" child-add harbourlight "$issue" 'A child' 'body' fm-child 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "a bound issue was allowed to parent children"

  # Nor by declaring the breakdown finished over the top of the binding, which is
  # the third way a container record gets written.
  out=$(board "$home" decomposed harbourlight "$issue" 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "a bound issue was allowed to be recorded as a decomposed container"
  assert_contains "$out" 'fm-onetask' "the refusal did not name the task holding the binding"
  assert_absent "$home/data/board-decompositions.tsv" \
    "a refused decomposed still recorded a container"
  assert_contains "$(board "$home" lookup fm-onetask)" "	processed	processed	" \
    "a refused decomposed disturbed the binding it refused to spend"

  # Judged the other way round, on an issue that never bound, it works - which is
  # the whole point of making the judgement before anything binds.
  : > "$home/items"
  item "$home" PVTI_b Issue https://github.com/harbour-collective/app/issues/361 \
    Todo firstmate - 'A programme instead' -
  board "$home" promote harbourlight https://github.com/harbour-collective/app/issues/361 >/dev/null
  out=$(board "$home" import harbourlight https://github.com/harbour-collective/app/issues/361 fm-late 2>&1) \
    && rc=0 || rc=$?
  expect_code 3 "$rc" "a container was allowed to bind a task after promotion"

  # `import` is not the only way a task reaches an issue, so the door has to be
  # shut on the routes that file their own issue too. An interrupted placement
  # leaves the issue filed and unlinked, which is exactly the state promotion
  # still accepts - and the convergence run that would have bound the container
  # is refused rather than spending its binding.
  home=$(new_home a_placed_container_can_never_be_bound_afterwards)
  programme_board "$home"
  out=$(GH_FAIL="project item-add" board "$home" place harbourlight fm-interrupted \
    'Interrupted placement' 'body')
  assert_contains "$out" 'placed-partial' "an interrupted placement was reported as complete"
  placed=$(cut -f2 "$home/issues")
  [ -z "$(board "$home" lookup fm-interrupted)" ] || fail "an uncarded placement recorded a link"
  board "$home" promote harbourlight "$placed" >/dev/null 2>&1
  before=$(board "$home" decompositions)
  out=$(board "$home" place harbourlight fm-interrupted 'Interrupted placement' 'body' 2>&1) \
    && rc=0 || rc=$?
  expect_code 3 "$rc" "a placement was allowed to bind a task to a container"
  [ -z "$(board "$home" lookup fm-interrupted)" ] || fail "a refused placement bound the container anyway"
  [ "$(board "$home" decompositions)" = "$before" ] \
    || fail "a refused placement disturbed the container record"

  # And the same sequence through `child-add`, where the issue that gets promoted
  # is a child the parent's record already names.
  parent=https://github.com/harbour-collective/app/issues/380
  item "$home" PVTI_p Issue "$parent" 'Big Picture Processed' firstmate - 'Rebuild the harbour' -
  out=$(GH_FAIL="project item-add" board "$home" child-add harbourlight "$parent" \
    'Dredge the channel' 'Second piece.' fm-dredge)
  assert_contains "$out" 'child-partial' "an interrupted child was reported as complete"
  child=$(printf '%s' "$out" | cut -d' ' -f4)
  [ -z "$(board "$home" lookup fm-dredge)" ] || fail "an uncarded child recorded a link"
  board "$home" promote harbourlight "$child" >/dev/null 2>&1
  before=$(board "$home" decompositions | sort)
  out=$(board "$home" child-add harbourlight "$parent" 'Dredge the channel' 'Second piece.' fm-dredge 2>&1) \
    && rc=0 || rc=$?
  expect_code 3 "$rc" "a child-add was allowed to bind a task to a container"
  [ -z "$(board "$home" lookup fm-dredge)" ] || fail "a refused child-add bound the container anyway"
  [ "$(board "$home" decompositions | sort)" = "$before" ] \
    || fail "a refused child-add disturbed the container record"
  pass "the container-or-task judgement is made before anything binds, and cannot be reversed after"
}

test_a_promotion_the_board_did_not_take_is_still_a_container() {
  local home issue out rc
  home=$(new_home a_promotion_the_board_did_not_take_is_still_a_container)
  programme_board "$home"
  issue=https://github.com/harbour-collective/app/issues/370
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'A programme' -

  out=$(GH_FAIL="project item-edit" board "$home" promote harbourlight "$issue" 2>/dev/null)
  assert_contains "$out" "promoted-partial harbourlight $issue" \
    "a promotion whose card move failed was reported as if it had landed"
  assert_contains "$(awk -F'\t' -v u="$issue" '$3 == u { print $4 }' "$home/items")" 'Todo' \
    "a promotion the board refused moved the card anyway"

  # The record is what makes it a container, so the card sitting in an ordinary
  # column for one more cycle changes nothing about what it is.
  board "$home" import harbourlight "$issue" fm-late >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 3 "$rc" "a container whose card had not moved was allowed to bind a task"
  out=$(board "$home" poll)
  assert_not_contains "$out" 'new ' "a container whose card had not moved was offered as ordinary work"
  assert_contains "$out" "decompose harbourlight $issue" \
    "a container whose card had not moved stopped being offered for breaking down"
  assert_contains "$out" "synced harbourlight $issue - todo" \
    "the outstanding promotion move was not retried on the next cycle"
  assert_contains "$(awk -F'\t' -v u="$issue" '$3 == u { print $4 }' "$home/items")" \
    'Big Picture Processed' "the retried promotion did not reach the container lane"
  pass "a promotion the board did not take is still a container, and the move is retried"
}

test_promotion_needs_a_container_lane_and_converges() {
  local home issue out rc
  home=$(new_home promotion_needs_a_container_lane_and_converges)
  processed_board "$home"
  issue=https://github.com/harbour-collective/app/issues/380
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'A programme' -

  out=$(board "$home" promote harbourlight "$issue" 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a board with no container lane accepted a promotion"
  assert_contains "$out" 'big-picture' "the refusal did not name the missing lane"
  assert_absent "$home/data/board-decompositions.tsv" "a refused promotion recorded a container"

  # Repeating a promotion converges rather than doing anything a second time.
  home=$(new_home promotion_converges)
  programme_board "$home"
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'A programme' -
  board "$home" promote harbourlight "$issue" >/dev/null
  out=$(board "$home" promote harbourlight "$issue")
  assert_contains "$out" "promoted harbourlight $issue" "a repeated promotion did not converge"
  [ "$(board "$home" decompositions | grep -c "$issue")" = 1 ] \
    || fail "a repeated promotion recorded the container twice"

  # And once it is broken down it is finished, however often it is asked again.
  board "$home" decomposed harbourlight "$issue" >/dev/null
  out=$(board "$home" promote harbourlight "$issue")
  assert_contains "$out" "already-promoted harbourlight $issue" \
    "a broken-down programme was reopened by promoting it again"
  out=$(board "$home" poll)
  assert_not_contains "$out" 'decompose' "a broken-down programme was offered again after a repeat promotion"
  pass "promotion needs a configured container lane, and repeating it converges"
}

# --- the two facts a placement already knows ---------------------------------
#
# These exist because both were once known, said in chat, and still never
# reached the board: they had no owning command, so they became things to
# remember and were forgotten. Each is now stated on the call that files the
# card, which is the only shape that has ever reflected reliably here.

test_placing_work_under_a_programme_attaches_it_there() {
  local home parent out child log
  home=$(new_home placing_work_under_a_programme_attaches_it_there)
  roadmap_board "$home"
  parent=https://github.com/harbour-collective/app/issues/400
  item "$home" PVTI_p Issue "$parent" 'Big Picture Processed' firstmate - 'Rebuild the harbour' -
  board "$home" poll >/dev/null
  board "$home" decomposed harbourlight "$parent" >/dev/null

  # Follow-on work firstmate files itself, long after the breakdown closed.
  : > "$home/gh.log"
  out=$(board "$home" place harbourlight fm-followon 'Follow-on from the rebuild' \
    'Filed by firstmate.' --parent "$parent")
  assert_contains "$out" 'placed harbourlight' "the follow-on work was not placed"
  child=$(printf '%s' "$out" | cut -d' ' -f3)
  log=$(gh_log "$home")
  assert_contains "$log" "--parent $parent" \
    "the follow-on work was not attached as a native sub-issue of the programme"
  assert_not_contains "$log" 'endCursor' "placing under a programme read the whole board"
  assert_contains "$(board "$home" decompositions)" "fm-followon=$child" \
    "the programme's own record did not gain the child"

  # It feeds the parent status the adapter already derives, not a second
  # mechanism: the container's card follows the new child with no further
  # command.
  board "$home" mark fm-followon in-progress >/dev/null
  : > "$home/gh.log"
  out=$(board "$home" poll)
  assert_contains "$out" "synced harbourlight $parent - in-progress" \
    "a child attached by placement did not move its programme's card"
  assert_contains "$(gh_log "$home")" '--single-select-option-id opt_bpprog' \
    "the programme's card was not moved through the container lane"

  # And the child is ordinary work from there on, never offered as fresh intake.
  assert_not_contains "$out" "new harbourlight $child" \
    "work placed under a programme was offered as fresh work to import"

  # A run interrupted after the issue exists is finished on the next one rather
  # than filing the work under the programme twice, exactly as an ordinary
  # placement converges.
  out=$(GH_FAIL="project item-add" board "$home" place harbourlight fm-second \
    'A second follow-on' 'body' --parent="$parent")
  assert_contains "$out" 'placed-partial' "an interrupted placement was reported as complete"
  [ -z "$(board "$home" lookup fm-second)" ] || fail "an uncarded placement recorded a link"
  out=$(board "$home" place harbourlight fm-second 'A second follow-on' 'body' --parent "$parent")
  assert_contains "$out" 'placed harbourlight' "the repeat run did not finish the placement"
  [ "$(issues_created "$home")" = 2 ] \
    || fail "the repeat run filed the same work under the programme a second time"
  pass "work placed under a programme is attached to it in that same operation, through GitHub's own sub-issue relationship"
}

test_parenting_recovers_an_issue_created_without_a_parent() {
  local home parent out child before
  home=$(new_home parenting_recovers_an_issue_created_without_a_parent)
  roadmap_board "$home"
  parent=https://github.com/harbour-collective/app/issues/405
  item "$home" PVTI_p Issue "$parent" 'Big Picture Processed' firstmate - 'Rebuild the harbour' -
  board "$home" poll >/dev/null

  out=$(GH_FAIL="project item-add" board "$home" place harbourlight fm-recovered \
    'Recovered follow-on' 'body')
  assert_contains "$out" 'placed-partial' "the parentless setup placement did not stop after filing"
  child=$(cut -f2 "$home/issues")
  [ "$(cut -f6 "$home/issues")" = - ] || fail "the setup issue already had a native parent"
  before=$(board "$home" decompositions)

  out=$(board "$home" place harbourlight fm-recovered 'Recovered follow-on' 'body' --parent "$parent")
  assert_contains "$out" 'placed harbourlight' "the parented retry did not recover the existing issue"
  [ "$(cut -f6 "$home/issues")" = "$parent" ] \
    || fail "the recovered issue was recorded without its native sub-issue relationship"
  assert_contains "$(board "$home" decompositions)" "fm-recovered=$child" \
    "the attached recovered issue was not recorded as the container's child"
  assert_not_contains "$before" 'fm-recovered=' "the setup unexpectedly recorded a child"
  assert_contains "$(gh_log "$home")" "--method POST -F sub_issue_id=${child##*/}" \
    "the retry did not attach the recovered issue through GitHub's sub-issue API"
  pass "a parented retry attaches a recovered parentless issue before recording the child"
}

test_placing_under_a_programme_refuses_rather_than_inventing_one() {
  local home parent ordinary out rc before
  home=$(new_home placing_under_a_programme_refuses_rather_than_inventing_one)
  roadmap_board "$home"

  # An issue nothing has recorded as a container is not one. Deciding that it is
  # one is the judgement `promote` owns, made before anything binds, so this is
  # refused rather than quietly becoming a second route to the same record.
  parent=https://github.com/harbour-collective/app/issues/410
  out=$(board "$home" place harbourlight fm-orphan 'Work' 'body' --parent "$parent" 2>&1) \
    && rc=0 || rc=$?
  expect_code 3 "$rc" "an unjudged issue became a container by having work placed under it"
  assert_contains "$out" 'not a recorded container' "the refusal did not say why"
  [ "$(issues_created "$home")" = 0 ] || fail "a refused placement filed an issue anyway"
  assert_absent "$home/data/board-decompositions.tsv" "a refused placement recorded a container"
  [ -z "$(board "$home" links)" ] || fail "a refused placement recorded a link"

  # Nor can work that already holds a task become a container from this side.
  ordinary=https://github.com/harbour-collective/app/issues/411
  item "$home" PVTI_o Issue "$ordinary" Todo firstmate - 'Ordinary work' -
  board "$home" import harbourlight "$ordinary" fm-ordinary >/dev/null
  out=$(board "$home" place harbourlight fm-under-a-task 'Work' 'body' --parent "$ordinary" 2>&1) \
    && rc=0 || rc=$?
  expect_code 3 "$rc" "work that already holds a task was accepted as a programme"
  assert_contains "$out" 'ordinary work' "the refusal did not say why the task cannot be a container"

  # A task already bound to an issue the container does not name is refused, not
  # reported as already done over the top of the parent it was asked for.
  parent=https://github.com/harbour-collective/app/issues/412
  item "$home" PVTI_p Issue "$parent" 'Big Picture Processed' firstmate - 'A programme' -
  board "$home" poll >/dev/null
  before=$(board "$home" decompositions | sort)
  out=$(board "$home" place harbourlight fm-ordinary 'Already bound' 'body' --parent "$parent" 2>&1) \
    && rc=0 || rc=$?
  expect_code 3 "$rc" "a task bound to another issue was quietly re-parented"
  assert_contains "$out" 'does not record as a child' "the refusal did not say why"
  [ "$(board "$home" decompositions | sort)" = "$before" ] \
    || fail "a refused placement disturbed the container record"

  # And a board with no container lane has no programmes to place under at all.
  home=$(new_home placing_under_a_programme_needs_the_lane)
  processed_board "$home"
  out=$(board "$home" place harbourlight fm-nolane 'Work' 'body' \
    --parent https://github.com/harbour-collective/app/issues/413 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a board with no container lane accepted a parent"
  assert_contains "$out" 'big-picture' "the refusal did not name the missing lane"
  [ "$(issues_created "$home")" = 0 ] || fail "a refused placement filed an issue anyway"
  pass "placing under a programme refuses loudly rather than inventing a container or re-parenting bound work"
}

test_placing_cleared_work_records_the_go_in_the_same_operation() {
  local home out issue
  home=$(new_home placing_cleared_work_records_the_go_in_the_same_operation)
  roadmap_board "$home"

  # Work the captain cleared in chat, whose only remaining obstacle is another
  # task landing first, is filed as cleared by the command that files the card.
  out=$(board "$home" place harbourlight fm-cleared 'Cleared, waiting on another task' \
    'body' --cleared)
  assert_contains "$out" 'placed harbourlight' "cleared work was not placed"
  issue=$(printf '%s' "$out" | cut -d' ' -f3)
  assert_contains "$out" 'fm-cleared queued' "the placement did not report the state it filed"
  assert_contains "$(gh_log "$home")" '--single-select-option-id opt_queued' \
    "the go was not written to this board's own go column"
  assert_contains "$(board "$home" lookup fm-cleared)" "	queued	queued	" \
    "the record did not carry the go the card was filed with"

  # The board and the record agree, so the next cycle reads it as settled work
  # rather than as a go firstmate never gave.
  out=$(board "$home" poll --all)
  assert_contains "$out" "linked harbourlight $issue fm-cleared queued" \
    "a card firstmate placed as cleared was not reported as settled"
  assert_not_contains "$out" 'divergence' "work firstmate placed as cleared read back as a divergence"

  # Filing a card is not by itself the captain's go, so an unstated call still
  # files internalized work exactly as it did before the flag existed.
  : > "$home/gh.log"
  out=$(board "$home" place harbourlight fm-not-cleared 'Filed, not cleared' 'body')
  assert_contains "$out" 'fm-not-cleared processed' "an unstated placement invented a go"
  assert_not_contains "$(gh_log "$home")" 'opt_queued' "an unstated placement wrote the go column"
  pass "work the captain already cleared is placed as cleared, and work that is not stays internalized"
}

test_a_board_with_no_go_column_never_grows_one() {
  local home out
  home=$(new_home a_board_with_no_go_column_never_grows_one)
  repo_board "$home"
  assert_contains "$(board "$home" boards)" 'queued=-' "the fixture board configured a go column"

  out=$(board "$home" place harbourlight fm-cleared-nowhere 'Cleared work' 'body' --cleared)
  assert_contains "$out" 'fm-cleared-nowhere todo' \
    "a board with neither optional column did not fall back to the inbox"
  assert_contains "$(gh_log "$home")" '--single-select-option-id opt_todo' \
    "the card was not filed in a column this board actually configures"
  assert_not_contains "$(gh_log "$home")" 'opt_queued' "a board grew a go column it never configured"

  # With the internalized column configured and no go column, it falls back one
  # step rather than inventing the other.
  home=$(new_home a_board_with_only_the_internalized_column)
  cat > "$home/config/boards" <<'EOF'
project = harbourlight
owner = harbour-collective
number = 4
repo = harbour-collective/app
label = firstmate
processed = Processed
EOF
  fields "$home" PVTSSF_status opt_todo:Todo opt_processed:Processed \
    'opt_prog:In Progress' opt_done:Done
  out=$(board "$home" place harbourlight fm-cleared-somewhere 'Cleared work' 'body' --cleared)
  assert_contains "$out" 'fm-cleared-somewhere processed' \
    "a board with no go column did not fall back to its internalized column"
  assert_contains "$(gh_log "$home")" '--single-select-option-id opt_processed' \
    "the card was not filed in a column this board actually configures"
  assert_not_contains "$(gh_log "$home")" 'opt_queued' "a board grew a go column it never configured"
  pass "a board with no go column reports the state it could file and never grows a column it did not ask for"
}

# --- run --------------------------------------------------------------------

test_boards_are_configuration_not_convention
test_the_bridge_is_inert_until_a_board_is_configured
test_removing_the_configuration_is_the_off_switch
test_malformed_configuration_is_an_actionable_error
test_only_projects_with_a_board_are_ever_mapped
test_only_tagged_todo_issues_are_importable
test_mention_and_assignee_triggers_are_off_by_default
test_importing_the_same_issue_twice_is_a_no_op
test_the_link_outlives_the_task_it_names
test_transitions_follow_firstmate_execution_events
test_a_column_firstmate_does_not_drive_is_recorded_not_invented
test_the_pull_request_is_attached_to_the_originating_issue
test_a_blocker_is_recorded_on_the_issue
test_a_status_firstmate_did_not_write_is_reported_not_reconciled
test_a_queued_card_firstmate_did_not_place_never_starts_work
test_the_queued_column_does_not_exist_until_it_is_configured
test_a_withdrawn_card_stops_the_work_without_touching_it
test_a_completed_card_leaving_the_board_is_not_a_withdrawal
test_a_closed_issue_withdraws_the_work_its_card_still_shows
test_a_closed_issue_whose_work_landed_is_not_a_withdrawal
test_closure_and_card_removal_are_told_apart
test_a_failed_board_write_never_blocks_delivery
test_a_failed_board_read_never_blocks_the_cycle
test_an_empty_board_is_not_taken_as_mass_withdrawal
test_a_truncated_read_reconciles_nothing
test_a_card_an_intake_filter_skips_is_not_a_withdrawal
test_an_issue_another_board_owns_is_skipped_not_re_homed
test_an_outstanding_pr_attachment_is_retried_on_the_next_cycle
test_a_single_card_event_never_reads_the_board
test_a_reconciled_board_polls_to_silence
test_poll_confirms_a_write_the_board_already_shows
test_api_calls_do_not_grow_with_the_board
test_the_container_lane_does_not_exist_until_it_is_configured
test_a_partial_container_configuration_is_refused
test_a_container_is_offered_for_decomposition_and_never_imported
test_a_container_is_never_offered_twice_once_decomposed
test_a_child_is_created_linked_and_never_re_imported
test_child_add_converges_instead_of_filing_a_second_issue
test_a_container_card_follows_its_children
test_a_container_follows_every_sub_issue_github_records
test_a_container_with_no_sub_issues_derives_nothing
test_children_that_cannot_be_read_derive_nothing_and_say_so
test_a_container_costs_one_flat_read_and_never_a_board_read
test_an_outstanding_container_move_is_retried_on_the_next_cycle
test_place_is_the_inverse_of_import
test_place_says_where_the_change_actually_lands
test_placement_converges_after_an_interrupted_run
test_an_unreadable_repo_never_files_a_duplicate
test_the_processed_column_does_not_exist_until_it_is_configured
test_internalizing_a_filed_card_moves_it_out_of_the_inbox
test_a_card_left_in_the_inbox_is_never_restatused
test_work_firstmate_files_itself_never_sits_in_the_inbox
test_a_queued_card_still_reports_rather_than_launches
test_firstmate_promotes_a_filed_card_to_a_programme
test_a_bound_issue_can_never_become_a_container
test_a_promotion_the_board_did_not_take_is_still_a_container
test_promotion_needs_a_container_lane_and_converges
test_placing_work_under_a_programme_attaches_it_there
test_parenting_recovers_an_issue_created_without_a_parent
test_placing_under_a_programme_refuses_rather_than_inventing_one
test_placing_cleared_work_records_the_go_in_the_same_operation
test_a_board_with_no_go_column_never_grows_one

# --- the second synchronized field -------------------------------------------
#
# A board may classify its work in a field of its own beside the column - an
# area, a component, a workstream. The properties worth pinning are that the
# adapter treats that field exactly as it treats the column, that it never forms
# the judgement of which value a card should carry, that a board configuring no
# such field is untouched, and - the one that made this more than a small change
# - that synchronizing a second field costs no second request per card.

# A board that classifies its work, with an Area field beside the columns. Area
# deliberately offers an option the status field also offers, because two fields
# sharing an option name is the case a lookup that ignored which field it was
# resolving for would write into the wrong one.
classified_board() {
  local home=$1
  cat > "$home/config/boards" <<'EOF'
project = harbourlight
owner = harbour-collective
number = 4
repo = harbour-collective/app
label = firstmate
processed = Processed
classify-field = Area
EOF
  fields "$home" PVTSSF_status opt_todo:Todo 'opt_prog:In Progress' \
    opt_done:Done opt_proc:Processed
  classify_field "$home" Area PVTSSF_area opt_platform:Platform \
    'opt_auth:Auth & Portal' opt_area_todo:Todo
}

test_a_card_is_classified_in_the_call_that_creates_it() {
  local home issue out
  home=$(new_home a_card_is_classified_in_the_call_that_creates_it)
  classified_board "$home"
  issue=https://github.com/harbour-collective/app/issues/501
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Something to take in' -

  # Taking work in and classifying it are one operation, not a card filed now
  # and tidied up later.
  out=$(board "$home" import harbourlight "$issue" fm-taken --area Platform)
  assert_contains "$out" "linked harbourlight $issue fm-taken processed Platform" \
    "the import did not report the area it filed"
  assert_contains "$(board "$home" lookup fm-taken)" "	Platform	Platform" \
    "the classification was not recorded as confirmed"
  assert_contains "$(gh_log "$home")" 'optionA=opt_proc' \
    "the column and the area were not written together"
  assert_contains "$(gh_log "$home")" 'optionB=opt_platform' \
    "the area was not part of that same write"

  # And the board really shows it, in its own field rather than in the column's.
  out=$(board "$home" poll)
  assert_not_contains "$out" 'unclassified' "a classified card was reported as blank"
  assert_not_contains "$out" 'divergence' "the area landed somewhere firstmate did not expect"

  # Work firstmate files itself carries its area from the same call.
  out=$(board "$home" place harbourlight fm-filed 'Filed by firstmate' 'body' \
    --area 'Auth & Portal')
  assert_contains "$out" 'fm-filed processed Auth & Portal' \
    "the placement did not report the area it filed"
  assert_contains "$(board "$home" lookup fm-filed)" "	Auth & Portal	Auth & Portal" \
    "the placed card's classification was not confirmed"
  pass "work is classified in the call that files or takes it in, never afterwards"
}

test_the_adapter_never_decides_a_classification() {
  local home issue rc=0 out
  home=$(new_home the_adapter_never_decides_a_classification)
  classified_board "$home"
  issue=https://github.com/harbour-collective/app/issues/502
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Contractor template work' -

  # The title says "Contractor template" and the board has areas: an adapter
  # that guessed would take it. Stating neither flag is refused instead.
  out=$(board "$home" import harbourlight "$issue" fm-guess 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "an import with no stated area was accepted"
  assert_contains "$out" '--area' "the refusal did not say how to state one"
  assert_not_contains "$(gh_log "$home")" 'item-edit' "the refused import still wrote to the board"
  [ -z "$(board "$home" links)" ] || fail "the refused import still recorded a link"

  # Contradicting yourself is refused too, rather than one flag quietly winning.
  rc=0
  board "$home" import harbourlight "$issue" fm-guess --area Platform --unclassified \
    >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "--area and --unclassified together were accepted"

  # An area the board does not offer is not invented; the write degrades to a
  # stale board exactly as any other write that does not land.
  out=$(board "$home" import harbourlight "$issue" fm-guess --area 'Invented Area' 2>&1)
  assert_contains "$out" 'linked-stale' "an area the board never offered was reported as landed"
  pass "which area work belongs to is stated by the caller, never guessed here"
}

test_a_blank_classification_is_surfaced_rather_than_silent() {
  local home issue out
  home=$(new_home a_blank_classification_is_surfaced_rather_than_silent)
  classified_board "$home"
  issue=https://github.com/harbour-collective/app/issues/503
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Genuinely ambiguous' -

  # Blank is reachable, but only by saying so.
  out=$(board "$home" import harbourlight "$issue" fm-open --unclassified)
  assert_contains "$out" "linked harbourlight $issue fm-open processed unclassified" \
    "the import did not report that it filed the card unclassified"

  # And it is named every cycle until an area is recorded, exactly as a card
  # awaiting import repeats as `new`.
  out=$(board "$home" poll)
  assert_contains "$out" "unclassified harbourlight $issue fm-open" \
    "a blank card was passed over in silence"
  out=$(board "$home" poll)
  assert_contains "$out" "unclassified harbourlight $issue fm-open" \
    "the blank card was reported once and then forgotten"

  # Recording one stops it, and the card stops being reported at all.
  out=$(board "$home" classify fm-open Platform)
  assert_contains "$out" "classified harbourlight $issue fm-open Platform" \
    "classifying the card did not report it"
  out=$(board "$home" poll)
  assert_not_contains "$out" 'unclassified' "a classified card was still reported as blank"
  [ -z "$out" ] || fail "a settled classified board did not poll to silence: $out"

  # Work that has already finished is settled, not something to go back and
  # classify, so it is never named.
  board "$home" mark fm-open 'done' >/dev/null
  : > "$home/data/board-links.tsv"
  board "$home" import harbourlight "$issue" fm-open --unclassified >/dev/null
  board "$home" mark fm-open 'done' >/dev/null
  out=$(board "$home" poll)
  assert_not_contains "$out" 'unclassified' "finished work was reported as needing an area"
  pass "a card left blank is named until an area is recorded, and never quietly"
}

test_a_classification_the_work_outgrew_is_updated() {
  local home issue out
  home=$(new_home a_classification_the_work_outgrew_is_updated)
  classified_board "$home"
  issue=https://github.com/harbour-collective/app/issues/504
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Scope moved' -
  board "$home" import harbourlight "$issue" fm-moved --area Platform >/dev/null

  out=$(board "$home" classify fm-moved 'Auth & Portal')
  assert_contains "$out" "classified harbourlight $issue fm-moved Auth & Portal" \
    "the changed area was not reported"
  assert_contains "$(board "$home" lookup fm-moved)" "	Auth & Portal	Auth & Portal" \
    "the changed area was not confirmed in the record"
  assert_contains "$(gh_log "$home")" 'opt_auth' "the board was never told about the change"

  # A change the board does not take stays outstanding, and the next cycle
  # finishes it rather than losing it.
  : > "$home/gh.log"
  out=$(GH_FAIL='project item-edit' board "$home" classify fm-moved Platform 2>/dev/null)
  assert_contains "$out" 'classification-stale' "a change the board refused was reported as landed"
  assert_contains "$(board "$home" lookup fm-moved)" "	Platform	Auth & Portal" \
    "the outstanding change was not recorded as owed"
  out=$(board "$home" poll)
  assert_contains "$out" "classified harbourlight $issue fm-moved Platform" \
    "the next cycle did not finish the outstanding change"
  assert_contains "$(board "$home" lookup fm-moved)" "	Platform	Platform" \
    "the retried change was not confirmed"
  pass "an area that changed with the work's scope is updated, and retried if it does not land"
}

test_a_classification_firstmate_did_not_write_is_reported_never_corrected() {
  local home issue out
  home=$(new_home a_classification_firstmate_did_not_write_is_reported)
  classified_board "$home"
  issue=https://github.com/harbour-collective/app/issues/505
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Reclassified by hand' -
  board "$home" import harbourlight "$issue" fm-hand --area Platform >/dev/null

  # Someone moves the card into another area on the board. Firstmate's records
  # are the truth here, so this is reported and nothing is written in either
  # direction - the same answer the column gets.
  : > "$home/items"
  : > "$home/gh.log"
  item "$home" PVTI_a Issue "$issue" Processed firstmate - 'Reclassified by hand' - \
    'Auth & Portal'
  out=$(board "$home" poll)
  assert_contains "$out" "classification-divergence harbourlight $issue fm-hand Platform Auth & Portal" \
    "an area firstmate never wrote was not reported"
  assert_not_contains "$(gh_log "$home")" 'item-edit' "the divergence was corrected behind the captain"
  assert_not_contains "$(gh_log "$home")" 'updateProjectV2ItemFieldValue' \
    "the divergence was corrected behind the captain"
  assert_contains "$(board "$home" lookup fm-hand)" "	Platform	Platform" \
    "the divergence changed firstmate's own record"

  # An explicit classify is how it is resolved, because that is firstmate acting.
  board "$home" classify fm-hand 'Auth & Portal' >/dev/null
  out=$(board "$home" poll)
  assert_not_contains "$out" 'classification-divergence' \
    "the resolved divergence was still reported"
  pass "an area the board shows that firstmate did not write is reported, never reconciled away"
}

test_two_fields_sharing_an_option_name_stay_apart() {
  local home issue
  home=$(new_home two_fields_sharing_an_option_name_stay_apart)
  classified_board "$home"
  issue=https://github.com/harbour-collective/app/issues/506
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Both offer Todo' -
  board "$home" import harbourlight "$issue" fm-both --area Todo >/dev/null

  # Both fields offer an option called Todo. The card must come away with the
  # Area field's Todo in Area and the column untouched by it.
  assert_contains "$(gh_log "$home")" 'optionB=opt_area_todo' \
    "the area write resolved the column field's option of the same name"
  board "$home" poll >/dev/null
  assert_contains "$(board "$home" lookup fm-both)" "	Todo	Todo" \
    "the area the board came back with was not the one that was written"
  pass "an option name two fields share resolves to the field being written"
}

test_the_board_names_the_areas_it_accepts() {
  local home out
  home=$(new_home the_board_names_the_areas_it_accepts)
  classified_board "$home"
  : > "$home/calls"
  out=$(board "$home" classifications)
  assert_contains "$out" 'classify harbourlight Area Platform' "the board's own areas were not listed"
  assert_contains "$out" 'classify harbourlight Area Auth & Portal' "an area with a space was not listed"
  assert_not_contains "$out" 'In Progress' "the column field's options were listed as areas"
  [ "$(gh_calls "$home")" = 1 ] || fail \
    "listing the areas cost more than the one id read: $(cat "$home/calls")"

  # A board that classifies nothing says so rather than failing.
  ordinary_board "$home"
  assert_contains "$(board "$home" classifications)" 'classify harbourlight off' \
    "a board with no classification field did not say so"
  pass "the areas a board accepts come from the board, and cost one read to list"
}

test_a_board_that_classifies_nothing_is_untouched() {
  local home issue rc=0 out
  home=$(new_home a_board_that_classifies_nothing_is_untouched)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/507
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Ordinary work' -

  # Naming a field this board does not have is refused, on every route that
  # takes one. `place` is checked as carefully as `import` because a refusal
  # raised inside a command substitution is only a message, not a refusal: the
  # caller reads an empty value and carries on, which is how this one first got
  # as far as trying to file the issue.
  out=$(board "$home" import harbourlight "$issue" fm-plain --area Platform 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "--area was accepted on a board that configures no such field"
  rc=0
  out=$(board "$home" place harbourlight fm-plain 'Work' 'body' --area Platform 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "place accepted --area on a board that configures no such field"
  assert_not_contains "$out" 'could not' "the refused placement went on to try the board anyway"
  [ "$(wc -l < "$home/issues")" = 0 ] || fail "the refused placement still filed an issue"
  rc=0
  board "$home" classify fm-plain Platform >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "classify was accepted on a board that configures no such field"
  [ -z "$(cat "$home/gh.log")" ] || fail "a refused classification still reached the board"

  # And every ordinary path answers exactly as it did before the field existed:
  # the same records, the same calls, and no trailing area on any line.
  : > "$home/calls"
  out=$(board "$home" import harbourlight "$issue" fm-plain)
  [ "$out" = "linked harbourlight $issue fm-plain" ] || fail \
    "an unclassified board's import line changed: $out"
  [ "$(gh_calls "$home")" = 0 ] || fail \
    "an unclassified board's import reached the board: $(cat "$home/calls")"
  out=$(board "$home" poll)
  [ -z "$out" ] || fail "an unclassified board's poll grew a record: $out"
  assert_contains "$(board "$home" boards)" 'classify=-' "the listing did not say classification was off"

  # Stating that no classification is being given is simply true here, so it is
  # accepted and changes nothing. That asymmetry is what lets a caller with no
  # view of the board's configuration - the dispatch reflection in
  # bin/fm-spawn.sh, which files a card for work nobody placed deliberately -
  # state it on every call and stay correct on every board. Configured last, so
  # nothing above is measured against a board it did not run on.
  processed_board "$home"
  out=$(board "$home" place harbourlight fm-said-nothing 'Work' 'body' --unclassified)
  assert_contains "$out" 'placed harbourlight' \
    "--unclassified was refused on a board that classifies nothing: $out"
  assert_not_contains "$out" 'unclassified' \
    "a board that classifies nothing reported a classification anyway: $out"
  assert_contains "$(board "$home" lookup fm-said-nothing)" 'processed	processed	-	-	-	-' \
    "the placement recorded a classification on a board that has none"
  pass "a board configuring no classification field behaves exactly as it did before one could be"
}

test_a_record_written_before_classification_reads_as_unclassified() {
  local home issue out
  home=$(new_home a_record_written_before_classification)
  classified_board "$home"
  issue=https://github.com/harbour-collective/app/issues/508
  item "$home" PVTI_a Issue "$issue" Processed firstmate - 'From an older home' -

  # The seven-column row an existing home already holds, written before this
  # field existed. It must read as work with no area rather than as a broken
  # record, and keep every column it already had.
  printf '%s\n' '# fm-board.sh durable issue-to-task links' > "$home/data/board-links.tsv"
  printf 'harbourlight\t%s\tfm-old\tprocessed\tprocessed\t-\t-\n' "$issue" \
    >> "$home/data/board-links.tsv"

  out=$(board "$home" lookup fm-old)
  assert_contains "$out" 'fm-old	processed	processed' "the older row did not read back"
  out=$(board "$home" poll)
  assert_contains "$out" "unclassified harbourlight $issue fm-old" \
    "an older row was not read as work with no area recorded"
  board "$home" classify fm-old Platform >/dev/null
  assert_contains "$(board "$home" lookup fm-old)" 'processed	processed	-	-	Platform	Platform' \
    "classifying an older row did not preserve its other columns"
  pass "a record written before this field existed reads as unclassified, not as broken"
}

# THE COST GUARD, FOR THE SECOND FIELD.
#
# The guard above pins that what an invocation costs follows the work it does
# rather than the board's size. This one pins the property that made adding a
# second synchronized field more than a small change: that cost must not follow
# how many FIELDS each change touches either.
#
# Two boards of the same size run the same cycle, one synchronizing the column
# alone and one synchronizing the column and the area, with every changed card
# owing a write on both. Equal call counts are the whole assertion, and the
# per-kind counts say why they are equal: one board read and one id read however
# many fields are wanted, because the one id document carries every field on the
# board; and one write per changed card however many fields that write sets,
# because two fields on one card go in one batched mutation.
#
# Each half was broken on purpose and confirmed to fail. Resolving the area's
# field id in its own request took the classified board from 5 calls to 8 at
# three changed cards, failing the equality and the `graphql ids` count. Writing
# the area in a second `item-edit` took it from 5 to 8 as well, failing the
# equality and the write count while leaving the id count untouched - which is
# why both counts are asserted rather than either alone.

# settled_classified_board <home> <cards>: the classified board's equivalent of
# settled_board, every card taken in with an area and moved to in progress.
settled_classified_board() {
  local home=$1 cards=$2 i=1 issue
  classified_board "$home"
  while [ "$i" -le "$cards" ]; do
    issue="https://github.com/harbour-collective/app/issues/$((7000 + i))"
    item "$home" "PVTI_c$i" Issue "$issue" Todo firstmate - "Card $i" -
    board "$home" import harbourlight "$issue" "fm-card-$i" --area Platform >/dev/null
    board "$home" mark "fm-card-$i" in-progress >/dev/null
    i=$((i + 1))
  done
}

# owing_both <home> <count>: leave that many cards owing a write on both fields.
owing_both() {
  local home=$1 count=$2 i=1
  while [ "$i" -le "$count" ]; do
    GH_FAIL='project item-edit' board "$home" mark "fm-card-$i" 'done' >/dev/null 2>&1
    GH_FAIL='project item-edit' board "$home" classify "fm-card-$i" 'Auth & Portal' \
      >/dev/null 2>&1
    i=$((i + 1))
  done
}

test_a_second_synchronized_field_costs_no_second_request() {
  local plain classified k=3 plain_calls classified_calls out
  plain=$(new_home second_field_cost_plain)
  classified=$(new_home second_field_cost_classified)
  settled_board "$plain" 12
  settled_classified_board "$classified" 12
  owing "$plain" "$k"
  owing_both "$classified" "$k"

  : > "$plain/calls"
  : > "$classified/calls"
  board "$plain" poll >/dev/null
  out=$(board "$classified" poll)
  plain_calls=$(gh_calls "$plain")
  classified_calls=$(gh_calls "$classified")

  [ "$plain_calls" = "$classified_calls" ] || fail \
    "a cycle synchronizing two fields cost $classified_calls calls where one field cost $plain_calls, for the same $k changed cards"
  # One board read, one id read for the run, one write per card that owes one -
  # unchanged by the second field.
  [ "$classified_calls" = "$((k + 2))" ] || fail \
    "a two-field cycle with $k changed cards cost $classified_calls calls, not $((k + 2)): $(cat "$classified/calls")"
  [ "$(gh_calls_of "$classified" 'graphql items')" = 1 ] || fail \
    "the classified cycle read the board more than once"
  [ "$(gh_calls_of "$classified" 'graphql ids')" = 1 ] || fail \
    "a second synchronized field resolved its ids in a second request"
  [ "$(gh_calls_of "$classified" 'graphql write')" = "$k" ] || fail \
    "a card owing both fields did not have them written in one request: $(cat "$classified/calls")"
  [ "$(gh_calls_of "$classified" 'project item-edit')" = 0 ] || fail \
    "a card owing both fields paid a second write as well as the batched one"

  # Both fields really did land, so the equal cost is not the cost of doing less.
  assert_contains "$out" 'synced harbourlight' "the column write did not land"
  assert_contains "$out" 'classified harbourlight' "the area write did not land"
  assert_contains "$(board "$classified" lookup fm-card-1)" 'done	done' \
    "the column was not confirmed"
  assert_contains "$(board "$classified" lookup fm-card-1)" 'Auth & Portal	Auth & Portal' \
    "the area was not confirmed"

  # A single-card event costs the same on both boards too: the card lookup, the
  # ids, and the one write.
  : > "$plain/calls"
  : > "$classified/calls"
  board "$plain" mark fm-card-1 todo >/dev/null
  board "$classified" classify fm-card-1 Platform >/dev/null
  [ "$(gh_calls "$classified")" = "$(gh_calls "$plain")" ] || fail \
    "a single classification cost $(gh_calls "$classified") calls where a single move cost $(gh_calls "$plain")"
  [ "$(gh_calls_of "$classified" 'graphql items')" = 0 ] || fail \
    "classifying one card read the whole board"

  # And a settled two-field cycle still costs its one board read and nothing
  # else, the same as a settled one-field cycle.
  : > "$classified/calls"
  board "$classified" poll >/dev/null
  [ "$(gh_calls "$classified")" = 1 ] || fail \
    "a settled two-field cycle cost more than its one board read: $(cat "$classified/calls")"
  pass "synchronizing a second field costs no extra request, per card or per cycle"
}

test_a_card_is_classified_in_the_call_that_creates_it
test_the_adapter_never_decides_a_classification
test_a_blank_classification_is_surfaced_rather_than_silent
test_a_classification_the_work_outgrew_is_updated
test_a_classification_firstmate_did_not_write_is_reported_never_corrected
test_two_fields_sharing_an_option_name_stay_apart
test_the_board_names_the_areas_it_accepts
test_a_board_that_classifies_nothing_is_untouched
test_a_record_written_before_classification_reads_as_unclassified
test_a_second_synchronized_field_costs_no_second_request
