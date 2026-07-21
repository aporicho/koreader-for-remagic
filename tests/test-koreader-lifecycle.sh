#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ADAPTER=$ROOT/scripts/koreader-lifecycle
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT HUP INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    needle=$1
    file=$2
    grep -F "$needle" "$file" >/dev/null || fail "$file does not contain: $needle"
}

RUNTIME=$TMPDIR_TEST/runtime
mkdir -p "$RUNTIME"
export REMAGIC_RUNTIME_DIR=$RUNTIME
export REMAGIC_APP_ID=koreader
export REMAGIC_APP_PID=4321
export REMAGIC_APP_GENERATION=3719679425990660

READY_ENVELOPE='{"protocol":2,"request_id":"ready-1","body":{"event":"ready","app_id":"koreader","generation":3719679425990660,"ui":"filemanager"}}'
printf '%s\n' "$READY_ENVELOPE" | "$ADAPTER" emit
[ "$(cat "$RUNTIME/koreader-ready")" = 'pid=4321
generation=3719679425990660' ] || fail 'legacy readiness identity is incorrect'

[ -z "$("$ADAPTER" poll)" ] || fail 'fallback poll produced a command without an exit request'
printf 'pid=1\ngeneration=2\n' >"$RUNTIME/koreader-exit"
[ -z "$("$ADAPTER" poll)" ] || fail 'fallback poll accepted a stale exit identity'

printf 'pid=4321\ngeneration=3719679425990660\n' >"$RUNTIME/koreader-exit"
"$ADAPTER" poll >"$TMPDIR_TEST/legacy-command"
assert_contains '"protocol":2' "$TMPDIR_TEST/legacy-command"
assert_contains '"command":"shutdown"' "$TMPDIR_TEST/legacy-command"
assert_contains '"generation":3719679425990660' "$TMPDIR_TEST/legacy-command"
assert_contains '"legacy":true' "$TMPDIR_TEST/legacy-command"
"$ADAPTER" consume-legacy-shutdown
[ ! -e "$RUNTIME/koreader-exit" ] || fail 'consumed legacy shutdown marker remains'

# The helper's inherited-FD path is also usable by non-Lua callers. The
# userpatch uses the same transport directly through FFI to avoid this fork.
FD_TRACE=$TMPDIR_TEST/fd.trace
exec 3>"$FD_TRACE"
REMAGIC_LIFECYCLE_FD=3 printf '%s\n' "$READY_ENVELOPE" | \
    REMAGIC_LIFECYCLE_FD=3 "$ADAPTER" emit 3>&3
exec 3>&-
printf '%s\n' "$READY_ENVELOPE" >"$TMPDIR_TEST/expected-fd"
cmp -s "$FD_TRACE" "$TMPDIR_TEST/expected-fd" || fail 'inherited FD changed the event envelope'

# A bridge transport owns all v2 I/O. The adapter must not also publish legacy
# markers, and poll output must remain byte-for-byte newline JSON.
BRIDGE=$TMPDIR_TEST/bridge
BRIDGE_TRACE=$TMPDIR_TEST/bridge.trace
BRIDGE_INBOX=$TMPDIR_TEST/bridge.inbox
export TEST_BRIDGE_TRACE=$BRIDGE_TRACE
export TEST_BRIDGE_INBOX=$BRIDGE_INBOX
apply_bridge_source='#!/bin/sh
set -eu
case $1 in
    emit) sed -n "1p" >>"$TEST_BRIDGE_TRACE" ;;
    poll)
        if [ -s "$TEST_BRIDGE_INBOX" ]; then
            sed -n "1,64p" "$TEST_BRIDGE_INBOX"
            : >"$TEST_BRIDGE_INBOX"
        fi
        ;;
    *) exit 2 ;;
esac'
printf '%s\n' "$apply_bridge_source" >"$BRIDGE"
chmod 0755 "$BRIDGE"
export REMAGIC_APP_BRIDGE=$BRIDGE
rm -f "$RUNTIME/koreader-ready"

printf '%s\n' "$READY_ENVELOPE" | "$ADAPTER" emit
[ ! -e "$RUNTIME/koreader-ready" ] || fail 'v2 bridge emit also wrote a legacy ready marker'
printf '%s\n' "$READY_ENVELOPE" >"$TMPDIR_TEST/expected-trace"
cmp -s "$BRIDGE_TRACE" "$TMPDIR_TEST/expected-trace" || fail 'bridge changed the event envelope'

COMMAND='{"protocol":2,"request_id":"background-1","body":{"command":"enter_background","app_id":"koreader","generation":3719679425990660,"foreground_epoch":4}}'
printf '%s\n' "$COMMAND" >"$BRIDGE_INBOX"
"$ADAPTER" poll >"$TMPDIR_TEST/bridge-command"
printf '%s\n' "$COMMAND" >"$TMPDIR_TEST/expected-command"
cmp -s "$TMPDIR_TEST/bridge-command" "$TMPDIR_TEST/expected-command" || \
    fail 'bridge poll changed the command envelope'
[ ! -s "$BRIDGE_INBOX" ] || fail 'bridge poll did not consume its test inbox'

unset REMAGIC_APP_BRIDGE
printf 'pid=4321\ngeneration=3719679425990660\n' >"$RUNTIME/koreader-ready"
printf 'pid=4321\ngeneration=3719679425990660\n' >"$RUNTIME/koreader-exit"
SHUTDOWN_ENVELOPE='{"protocol":2,"request_id":"shutdown-1","body":{"event":"shutdown_complete","app_id":"koreader","generation":3719679425990660}}'
printf '%s\n' "$SHUTDOWN_ENVELOPE" | "$ADAPTER" emit
[ ! -e "$RUNTIME/koreader-ready" ] || fail 'shutdown cleanup left the ready marker'
[ ! -e "$RUNTIME/koreader-exit" ] || fail 'shutdown cleanup left the exit marker'

echo 'koreader lifecycle adapter tests passed'
