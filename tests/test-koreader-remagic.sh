#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WRAPPER=$ROOT/scripts/koreader-remagic
MANAGER_MANIFEST=$ROOT/../remagic-manager/native/appload-runtime/apps/koreader/external.manifest.json
ADAPTER_MANIFEST=$ROOT/manifests/koreader.toml
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

# Static guardrails: this adapter must not regress to the old display host or
# framebuffer-probing launch path.
if sed '/^[[:space:]]*#/d' "$WRAPPER" | \
    grep -E 'xochitl\.service|pidof[[:space:]]+xochitl|paperweight|einkface|fbdepth|fbink|systemctl' >/dev/null
then
    fail "wrapper contains a forbidden host or framebuffer dependency"
fi
if grep -E '^[[:space:]]*export[[:space:]]+LD_PRELOAD' "$WRAPPER" >/dev/null; then
    fail "LD_PRELOAD must be scoped to reader.lua"
fi
for assignment in \
    'QTFB_SHIM_MODEL=false' \
    'QTFB_SHIM_INPUT_MODE=NATIVE' \
    'QTFB_SHIM_MODE=N_RGB565' \
    'QTFB_SHIM_RESPECT_FULL_REFRESH_REQUESTS=1' \
    'KO_DONT_GRAB_INPUT=1' \
    'KO_DONT_SET_DEPTH=1'
do
    assert_contains "$assignment" "$WRAPPER"
done

assert_contains 'exec = "/home/root/apps/remagic-koreader/bin/koreader-remagic"' "$ADAPTER_MANIFEST"
assert_contains 'display = "qtfb"' "$ADAPTER_MANIFEST"
if grep -F 'KO_MULTIUSER' "$WRAPPER" "$ADAPTER_MANIFEST" >/dev/null; then
    fail "KO_MULTIUSER must not split state away from /home/root/apps/koreader"
fi

# The manager is a sibling checkout in the development workspace, but the
# adapter's own checks must remain runnable from a standalone clone.
if [ -f "$MANAGER_MANIFEST" ]; then
    assert_contains '"application": "/home/root/apps/remagic-koreader/bin/koreader-remagic"' "$MANAGER_MANIFEST"
    if grep -F '"LD_PRELOAD"' "$MANAGER_MANIFEST" >/dev/null; then
        fail "manager manifest must not preload the shim into the wrapper"
    fi
fi

# Lightweight behavior check with a fake reader. Using the host C library as
# the preload target keeps the dynamic loader quiet while letting us inspect
# the exact child environment.
HOST_PRELOAD=$(ldd /bin/sh | awk '/libc\.so/{ print $3; exit }')
[ -r "$HOST_PRELOAD" ] || fail "could not locate a readable host preload library"

KOREADER_DIR_TEST=$TMPDIR_TEST/koreader
mkdir -p "$KOREADER_DIR_TEST"
LIBRARY_DIR_TEST=$TMPDIR_TEST/library
LAST_DIR_TEST=$LIBRARY_DIR_TEST/分册
OUTSIDE_DIR_TEST=$TMPDIR_TEST/outside
mkdir -p "$LAST_DIR_TEST" "$OUTSIDE_DIR_TEST"
SETTINGS_TEST=$KOREADER_DIR_TEST/settings.reader.lua
TRACE=$TMPDIR_TEST/trace
STATE=$TMPDIR_TEST/state
WRAPPER_LOG=$TMPDIR_TEST/wrapper.log
CHILD_PID_FILE=$TMPDIR_TEST/child.pid
FAKE_READER=$KOREADER_DIR_TEST/reader.lua
STARTUP_SCRIPT=$KOREADER_DIR_TEST/koreader.sh
ACTIVE_STARTUP_SCRIPT=$TMPDIR_TEST/active/koreader.sh
LIBRARY_SYNC_TRACE=$TMPDIR_TEST/library-sync.trace
FAKE_LIBRARY_SYNC=$TMPDIR_TEST/koreader-library-sync

mkdir -p "${ACTIVE_STARTUP_SCRIPT%/*}"
printf '%s\n' '#!/bin/sh' 'echo installed-startup-v1' >"$STARTUP_SCRIPT"
printf '%s\n' '#!/bin/sh' 'echo stale-active-copy' >"$ACTIVE_STARTUP_SCRIPT"
export KOREADER_ACTIVE_STARTUP_SCRIPT="$ACTIVE_STARTUP_SCRIPT"

cat >"$FAKE_LIBRARY_SYNC" <<'EOF'
#!/bin/sh
set -eu
printf 'sync\n' >>"$TEST_LIBRARY_SYNC_TRACE"
mkdir -p "$KOREADER_LIBRARY_DIR"
EOF
chmod 0755 "$FAKE_LIBRARY_SYNC"
export KOREADER_LIBRARY_SYNC="$FAKE_LIBRARY_SYNC"
export TEST_LIBRARY_SYNC_TRACE="$LIBRARY_SYNC_TRACE"

cat >"$FAKE_READER" <<'EOF'
#!/bin/sh
set -u
count=0
[ ! -f "$TEST_STATE" ] || count=$(cat "$TEST_STATE")
count=$((count + 1))
printf '%s\n' "$count" >"$TEST_STATE"
printf 'run=%s mode=%s model=%s input=%s full=%s grab=%s depth=%s argc=%s arg1=%s\n' \
    "$count" "$QTFB_SHIM_MODE" "$QTFB_SHIM_MODEL" "$QTFB_SHIM_INPUT_MODE" \
    "$QTFB_SHIM_RESPECT_FULL_REFRESH_REQUESTS" "$KO_DONT_GRAB_INPUT" \
    "$KO_DONT_SET_DEPTH" "$#" "${1-}" >>"$TEST_TRACE"
if [ -n "${TEST_CHILD_PID_FILE:-}" ]; then
    printf '%s\n' "$$" >"$TEST_CHILD_PID_FILE"
fi
if [ "${TEST_BLOCK:-0}" -eq 1 ]; then
    trap 'exit 0' TERM INT HUP
    while :; do
        sleep 1
    done
fi
if [ "${TEST_RESTART_ONCE:-0}" -eq 1 ] && [ "$count" -eq 1 ]; then
    exit 85
fi
exit "${TEST_FINAL_STATUS:-0}"
EOF
chmod 0755 "$FAKE_READER"

cat >"$SETTINGS_TEST" <<EOF
return {
    ["lastdir"] = "$LAST_DIR_TEST",
}
EOF

TEST_STATE=$STATE TEST_TRACE=$TRACE TEST_RESTART_ONCE=1 \
KOREADER_DIR=$KOREADER_DIR_TEST QTFB_SHIM=$HOST_PRELOAD \
KOREADER_LIBRARY_DIR=$LIBRARY_DIR_TEST KOREADER_SETTINGS=$SETTINGS_TEST \
    "$WRAPPER" 2>"$WRAPPER_LOG"
[ "$(cat "$STATE")" -eq 2 ] || fail "exit 85 did not restart reader.lua exactly once"
assert_contains "run=1 mode=N_RGB565 model=false input=NATIVE full=1 grab=1 depth=1 argc=1 arg1=$LAST_DIR_TEST" "$TRACE"
assert_contains "run=2 mode=N_RGB565 model=false input=NATIVE full=1 grab=1 depth=1 argc=1 arg1=$LAST_DIR_TEST" "$TRACE"
assert_contains "koreader-remagic: library_dir=$LAST_DIR_TEST source=lastdir" "$WRAPPER_LOG"
[ "$(wc -l <"$LIBRARY_SYNC_TRACE")" -eq 1 ] || fail "friendly library was not synchronized once per wrapper launch"
cmp -s "$STARTUP_SCRIPT" "$ACTIVE_STARTUP_SCRIPT" || fail "wrapper did not refresh the active startup script"
[ "$(stat -c '%a' "$ACTIVE_STARTUP_SCRIPT")" = 755 ] || fail "active startup script is not executable"

# A stale lastdir outside the document library must not reopen a broad parent;
# an explicit library argument forces KOReader's file manager instead.
cat >"$SETTINGS_TEST" <<EOF
return {
    ["lastdir"] = "$OUTSIDE_DIR_TEST",
}
EOF
rm -f "$STATE" "$TRACE" "$WRAPPER_LOG"
STARTUP_SENTINEL=$TMPDIR_TEST/startup-sentinel
printf '%s\n' 'must not be overwritten through a symlink' >"$STARTUP_SENTINEL"
printf '%s\n' '#!/bin/sh' 'echo installed-startup-v2' >"$STARTUP_SCRIPT"
rm -f "$ACTIVE_STARTUP_SCRIPT"
ln -s "$STARTUP_SENTINEL" "$ACTIVE_STARTUP_SCRIPT"
TEST_STATE=$STATE TEST_TRACE=$TRACE \
KOREADER_DIR=$KOREADER_DIR_TEST QTFB_SHIM=$HOST_PRELOAD \
KOREADER_LIBRARY_DIR=$LIBRARY_DIR_TEST KOREADER_SETTINGS=$SETTINGS_TEST \
    "$WRAPPER" 2>"$WRAPPER_LOG"
assert_contains "argc=1 arg1=$LIBRARY_DIR_TEST" "$TRACE"
assert_contains "koreader-remagic: library_dir=$LIBRARY_DIR_TEST source=fallback" "$WRAPPER_LOG"
[ "$(wc -l <"$LIBRARY_SYNC_TRACE")" -eq 2 ] || fail "second wrapper launch did not synchronize the friendly library"
cmp -s "$STARTUP_SCRIPT" "$ACTIVE_STARTUP_SCRIPT" || fail "second launch left a stale active startup script"
[ ! -L "$ACTIVE_STARTUP_SCRIPT" ] || fail "startup synchronization left an attacker-controlled symlink"
assert_contains 'must not be overwritten through a symlink' "$STARTUP_SENTINEL"

rm -f "$STATE" "$TRACE"
BOOK_PATH="$TMPDIR_TEST/一本 有空格的书.epub"
: >"$BOOK_PATH"
set +e
TEST_STATE=$STATE TEST_TRACE=$TRACE TEST_FINAL_STATUS=17 \
KOREADER_DIR=$KOREADER_DIR_TEST QTFB_SHIM=$HOST_PRELOAD \
KOREADER_LIBRARY_DIR=$LIBRARY_DIR_TEST KOREADER_SETTINGS=$SETTINGS_TEST \
    "$WRAPPER" "$BOOK_PATH"
status=$?
set -e
[ "$status" -eq 17 ] || fail "reader exit 17 became $status"
assert_contains "argc=1 arg1=$BOOK_PATH" "$TRACE"

# A busy/failed migration with no active statistics database is a hard launch
# failure. Opening reader.lua anyway could recreate the database while another
# installer owns it.
FAILING_MIGRATOR=$TMPDIR_TEST/failing-migrator
cat >"$FAILING_MIGRATOR" <<'EOF'
#!/bin/sh
exit 75
EOF
chmod 0755 "$FAILING_MIGRATOR"
rm -f "$STATE" "$TRACE"
printf '%s\n' '#!/bin/sh' 'echo installed-startup-v3' >"$STARTUP_SCRIPT"
printf '%s\n' '#!/bin/sh' 'echo active-before-failed-migration' >"$ACTIVE_STARTUP_SCRIPT"
set +e
TEST_STATE=$STATE TEST_TRACE=$TRACE \
KOREADER_DIR=$KOREADER_DIR_TEST QTFB_SHIM=$HOST_PRELOAD \
KOREADER_LIBRARY_DIR=$LIBRARY_DIR_TEST KOREADER_SETTINGS=$SETTINGS_TEST \
KOREADER_MIGRATOR=$FAILING_MIGRATOR \
    "$WRAPPER" >"$TMPDIR_TEST/migration-failure.log" 2>&1
status=$?
set -e
[ "$status" -eq 75 ] || fail "migration failure returned $status instead of 75"
[ ! -e "$TRACE" ] || fail "reader started despite an incomplete migration"
assert_contains 'refusing to open an incomplete data directory' "$TMPDIR_TEST/migration-failure.log"
assert_contains 'active-before-failed-migration' "$ACTIVE_STARTUP_SCRIPT"

rm -f "$STATE" "$TRACE" "$CHILD_PID_FILE"
TEST_STATE=$STATE TEST_TRACE=$TRACE TEST_BLOCK=1 \
TEST_CHILD_PID_FILE=$CHILD_PID_FILE \
KOREADER_DIR=$KOREADER_DIR_TEST QTFB_SHIM=$HOST_PRELOAD \
KOREADER_LIBRARY_DIR=$LIBRARY_DIR_TEST KOREADER_SETTINGS=$SETTINGS_TEST \
    "$WRAPPER" &
wrapper_pid=$!
attempts=0
while [ ! -s "$CHILD_PID_FILE" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
done
[ -s "$CHILD_PID_FILE" ] || fail "blocking fake reader did not start"
reader_pid=$(cat "$CHILD_PID_FILE")
kill -TERM "$wrapper_pid"
set +e
wait "$wrapper_pid"
status=$?
set -e
[ "$status" -eq 143 ] || fail "TERM returned $status instead of 143"
if kill -0 "$reader_pid" 2>/dev/null; then
    fail "reader process survived wrapper termination"
fi

echo "koreader wrapper tests passed"
