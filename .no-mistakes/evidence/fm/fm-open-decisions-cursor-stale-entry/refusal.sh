set -eu
lab="$PWD/.test-live-phase/home"
printf 'window=isolated-test:worker\nkind=ship\n' > "$lab/state/a.meta"
printf '$ bin/fm-send.sh a --resolve-key pending-reply-abcdef answer\n'
set +e
FM_GATE_REFUSE_BYPASS=1 FM_HOME="$lab" FM_ROOT_OVERRIDE="$lab" bin/fm-send.sh a --resolve-key pending-reply-abcdef answer
rc=$?
set -e
printf 'exit=%s\n' "$rc"
[ "$rc" -ne 0 ]
