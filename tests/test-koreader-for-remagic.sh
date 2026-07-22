#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WRAPPER=$ROOT/scripts/koreader-for-remagic
ADAPTER_MANIFEST=$ROOT/manifests/koreader.toml
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT HUP INT TERM
export KOREADER_PLATFORM_PATCH_DIR=$ROOT/patches
export KOREADER_INSTALL_LOCK=$TMPDIR_TEST/koreader-for-remagic.install.lock
export KOREADER_INSTALL_FLOCK=$(command -v flock)

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
    'QTFB_SHIM_ONESHOT=1' \
    'QTFB_SHIM_MODEL=false' \
    'QTFB_SHIM_INPUT_MODE=NATIVE' \
    'QTFB_SHIM_MODE=N_RGB565' \
    'QTFB_SHIM_RESPECT_FULL_REFRESH_REQUESTS=1' \
    'KO_DONT_GRAB_INPUT=1' \
    'KO_DONT_SET_DEPTH=1'
do
    assert_contains "$assignment" "$WRAPPER"
done
if grep -E '(^|[^0-9])(954|1696|1620|2160)([^0-9]|$)|FBFMT_RMPP|FBFMT_RMPPM' "$WRAPPER" >/dev/null; then
    fail "wrapper contains device-specific geometry or QTFB format constants"
fi

assert_contains 'exec = "/home/root/apps/koreader/current/payload/adapter/releases/__REMAGIC_ADAPTER_RELEASE__/bin/koreader-for-remagic"' "$ADAPTER_MANIFEST"
assert_contains 'schema = 2' "$ADAPTER_MANIFEST"
assert_contains 'display = "qtfb"' "$ADAPTER_MANIFEST"
assert_contains 'resident = true' "$ADAPTER_MANIFEST"
for module_variable in REMAGIC_KOREADER_LIBEXEC_DIR REMAGIC_KOREADER_FLOCK; do
    assert_contains "$module_variable" "$WRAPPER"
done
assert_contains 'KOREADER_PLATFORM_PATCH_DIR' "$WRAPPER"
assert_contains 'KOREADER_INSTALL_LOCK=${KOREADER_INSTALL_LOCK:-/home/root/.local/state/koreader-for-remagic/install.lock}' "$WRAPPER"
assert_contains "EXT_FONT_DIR=\$(printf '%s' \"\$KOREADER_FONT_DIRECTORIES\" | tr ':' ';')" "$WRAPPER"
if grep -F 'KO_MULTIUSER' "$WRAPPER" "$ADAPTER_MANIFEST" >/dev/null; then
    fail "KO_MULTIUSER must not split state away from /home/root/apps/koreader"
fi

# Lightweight behavior check with a fake reader. Using the host C library as
# the preload target keeps the dynamic loader quiet while letting us inspect
# the exact child environment.
HOST_PRELOAD=$(ldd /bin/sh | awk '/libc\.so/{ print $3; exit }')
[ -r "$HOST_PRELOAD" ] || fail "could not locate a readable host preload library"

KOREADER_DIR_TEST=$TMPDIR_TEST/koreader
mkdir -p "$KOREADER_DIR_TEST"
DATA_HOME_TEST=$TMPDIR_TEST/data-home
mkdir -p "$DATA_HOME_TEST/settings"
printf 'healthy-test-database\n' >"$DATA_HOME_TEST/settings/statistics.sqlite3"
export KO_HOME=$DATA_HOME_TEST
export KOREADER_DATA_DIR=$DATA_HOME_TEST
FONT_ONE=$TMPDIR_TEST/adapter-fonts
FONT_TWO=$TMPDIR_TEST/extra-fonts
mkdir -p "$FONT_ONE" "$FONT_TWO"
export REMAGIC_FONT_DIRECTORIES=$FONT_ONE:$FONT_TWO
LIFECYCLE_CHANNEL=$TMPDIR_TEST/lifecycle.channel
: >"$LIFECYCLE_CHANNEL"
exec 7<>"$LIFECYCLE_CHANNEL"
export REMAGIC_LIFECYCLE_FD=7
export REMAGIC_APP_GENERATION=3719679425990660
PAPER_PRO_PROFILE='{"schema":1,"product":"paper_pro","codename":"ferrari"}'
PAPER_PRO_MOVE_PROFILE='{"schema":1,"product":"paper_pro_move","codename":"chiappa"}'
export REMAGIC_DEVICE_PROFILE=$PAPER_PRO_PROFILE
export KOREADER_LIBEXEC_DIR=$ROOT/scripts
LIBRARY_DIR_TEST=$TMPDIR_TEST/library
BOOKS_DIR_TEST=$TMPDIR_TEST/books
SOURCE_LIBRARY_TEST=$TMPDIR_TEST/xochitl
LAST_DIR_TEST=$LIBRARY_DIR_TEST/分册
BOOKS_LAST_DIR_TEST=$BOOKS_DIR_TEST/长篇
OUTSIDE_DIR_TEST=$TMPDIR_TEST/outside
mkdir -p "$LAST_DIR_TEST" "$BOOKS_LAST_DIR_TEST" "$SOURCE_LIBRARY_TEST" "$OUTSIDE_DIR_TEST"
: >"$LAST_DIR_TEST/论语.epub"
export KOREADER_BOOKS_DIR=$BOOKS_DIR_TEST
export KOREADER_SOURCE_LIBRARY_DIR=$SOURCE_LIBRARY_TEST
export KOREADER_LIBRARY_STATE_ROOT=$TMPDIR_TEST
export KOREADER_LIBRARY_INDEX=$TMPDIR_TEST/library.index
export KOREADER_COLLECTION_NAME=全部书籍
SETTINGS_TEST=$DATA_HOME_TEST/settings.reader.lua
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
printf 'run=%s oneshot=%s mode=%s model=%s input=%s full=%s grab=%s depth=%s argc=%s arg1=%s ko_home=%s dict=%s initial=%s\n' \
    "$count" "$QTFB_SHIM_ONESHOT" \
    "$QTFB_SHIM_MODE" "$QTFB_SHIM_MODEL" "$QTFB_SHIM_INPUT_MODE" \
    "$QTFB_SHIM_RESPECT_FULL_REFRESH_REQUESTS" "$KO_DONT_GRAB_INPUT" \
    "$KO_DONT_SET_DEPTH" "$#" "${1-}" "$KO_HOME" "$STARDICT_DATA_DIR" \
    "${REMAGIC_INITIAL_OPEN_PATH-}" >>"$TEST_TRACE"
printf 'libexec=%s fonts=%s managed=%s flock=%s\n' \
    "$REMAGIC_KOREADER_LIBEXEC_DIR" "$EXT_FONT_DIR" "$REMAGIC_MANAGED" \
    "$REMAGIC_KOREADER_FLOCK" >>"$TEST_TRACE"
printf 'device_profile=%s\n' "$REMAGIC_DEVICE_PROFILE" >>"$TEST_TRACE"
printf 'collection=%s source_library=%s library_index=%s\n' \
    "$KOREADER_COLLECTION_NAME" "$KOREADER_SOURCE_LIBRARY_DIR" \
    "$KOREADER_LIBRARY_INDEX" >>"$TEST_TRACE"
if [ -n "${TEST_CHILD_PID_FILE:-}" ]; then
    printf '%s\n' "$$" >"$TEST_CHILD_PID_FILE"
fi
if [ "${TEST_BLOCK:-0}" -eq 1 ]; then
    if [ "${TEST_IGNORE_TERM:-0}" -eq 1 ]; then
        trap '' TERM INT HUP
    else
        trap 'exit 0' TERM INT HUP
    fi
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

# DataStorage and the adapter must never split settings, patches, and database
# writes across two roots. Reject the launch before syncing a patch or starting
# reader.lua when both public variables disagree.
CONFLICT_HOME=$TMPDIR_TEST/conflicting-ko-home
CONFLICT_LOG=$TMPDIR_TEST/conflicting-data-root.log
set +e
KO_HOME=$CONFLICT_HOME KOREADER_DATA_DIR=$DATA_HOME_TEST \
TEST_STATE=$STATE TEST_TRACE=$TRACE \
KOREADER_DIR=$KOREADER_DIR_TEST QTFB_SHIM=$HOST_PRELOAD \
KOREADER_LIBRARY_DIR=$LIBRARY_DIR_TEST KOREADER_SETTINGS=$SETTINGS_TEST \
    "$WRAPPER" 2>"$CONFLICT_LOG"
conflict_status=$?
set -e
[ "$conflict_status" -ne 0 ] || fail "conflicting KOReader data roots were accepted"
assert_contains 'KO_HOME and KOREADER_DATA_DIR must identify the same data root' "$CONFLICT_LOG"
[ ! -e "$TRACE" ] || fail "reader.lua ran with conflicting data roots"
[ ! -e "$DATA_HOME_TEST/patches" ] || fail "data-root conflict wrote platform patches"
[ ! -e "$CONFLICT_HOME" ] || fail "data-root conflict created KO_HOME"

# A directory (or symlink-to-directory) at an authoritative patch filename
# must never turn atomic rename into "move inside attacker directory".
mkdir -p "$DATA_HOME_TEST/patches/10-remagic-environment.lua"
UNSAFE_PATCH_LOG=$TMPDIR_TEST/unsafe-patch-target.log
set +e
TEST_STATE=$STATE TEST_TRACE=$TRACE \
KOREADER_DIR=$KOREADER_DIR_TEST QTFB_SHIM=$HOST_PRELOAD \
KOREADER_LIBRARY_DIR=$LIBRARY_DIR_TEST KOREADER_SETTINGS=$SETTINGS_TEST \
    "$WRAPPER" 2>"$UNSAFE_PATCH_LOG"
unsafe_patch_status=$?
set -e
[ "$unsafe_patch_status" -ne 0 ] || fail "directory platform patch target was accepted"
assert_contains 'KOReader platform patch target is unsafe' "$UNSAFE_PATCH_LOG"
[ ! -e "$TRACE" ] || fail "reader.lua ran with an unsafe platform patch target"
rmdir "$DATA_HOME_TEST/patches/10-remagic-environment.lua"

# A managed launch must carry the platform-owned profile. The adapter does not
# infer a device from geometry or silently fall back to Move constants.
MISSING_PROFILE_LOG=$TMPDIR_TEST/missing-device-profile.log
set +e
REMAGIC_DEVICE_PROFILE= \
TEST_STATE=$STATE TEST_TRACE=$TRACE \
KOREADER_DIR=$KOREADER_DIR_TEST QTFB_SHIM=$HOST_PRELOAD \
KOREADER_LIBRARY_DIR=$LIBRARY_DIR_TEST KOREADER_SETTINGS=$SETTINGS_TEST \
    "$WRAPPER" 2>"$MISSING_PROFILE_LOG"
missing_profile_status=$?
set -e
[ "$missing_profile_status" -ne 0 ] || fail "launch without a ReMagic device profile was accepted"
assert_contains 'REMAGIC_DEVICE_PROFILE schema v1 is required' "$MISSING_PROFILE_LOG"
[ ! -e "$TRACE" ] || fail "reader.lua ran without a ReMagic device profile"

# Reproduce an in-place upgrade from the first .4 candidate.  Its collection
# patch used KOReader's early priority and must be removed before reader.lua
# gets a chance to discover userpatches.
printf '%s\n' 'error("obsolete early collection patch was loaded")' \
    >"$DATA_HOME_TEST/patches/15-remagic-library-collection.lua"

TEST_STATE=$STATE TEST_TRACE=$TRACE TEST_RESTART_ONCE=1 \
KOREADER_DIR=$KOREADER_DIR_TEST QTFB_SHIM=$HOST_PRELOAD \
KOREADER_LIBRARY_DIR=$LIBRARY_DIR_TEST KOREADER_SETTINGS=$SETTINGS_TEST \
    "$WRAPPER" 2>"$WRAPPER_LOG" || {
        cat "$WRAPPER_LOG" >&2
        fail "wrapper failed its managed-runtime launch"
    }
[ "$(cat "$STATE")" -eq 2 ] || fail "exit 85 did not restart reader.lua exactly once"
[ ! -e "$DATA_HOME_TEST/patches/15-remagic-library-collection.lua" ] \
    || fail "obsolete early collection patch survived the adapter upgrade"
assert_contains "run=1 oneshot=1 mode=N_RGB565 model=false input=NATIVE full=1 grab=1 depth=1 argc=1 arg1=$LAST_DIR_TEST" "$TRACE"
assert_contains "run=2 oneshot=1 mode=N_RGB565 model=false input=NATIVE full=1 grab=1 depth=1 argc=1 arg1=$LAST_DIR_TEST" "$TRACE"
assert_contains "ko_home=$DATA_HOME_TEST" "$TRACE"
assert_contains "libexec=$ROOT/scripts" "$TRACE"
assert_contains "fonts=$FONT_ONE;$FONT_TWO" "$TRACE"
assert_contains "managed=1" "$TRACE"
assert_contains "flock=$KOREADER_INSTALL_FLOCK" "$TRACE"
assert_contains "device_profile=$PAPER_PRO_PROFILE" "$TRACE"
assert_contains "collection=全部书籍 source_library=$SOURCE_LIBRARY_TEST library_index=$TMPDIR_TEST/library.index" "$TRACE"
[ ! -e "$KOREADER_DIR_TEST/settings.reader.lua" ] || fail "isolated KO_HOME wrote settings into the program tree"
for platform_patch in 10-remagic-environment.lua 20-remagic-policy.lua \
        21-remagic-lifecycle-v2.lua 22-remagic-library-collection.lua; do
    cmp -s "$KOREADER_PLATFORM_PATCH_DIR/$platform_patch" \
        "$DATA_HOME_TEST/patches/$platform_patch" \
        || fail "isolated KO_HOME did not receive $platform_patch"
    [ ! -e "$KOREADER_DIR_TEST/patches/$platform_patch" ] \
        || fail "isolated launch wrote $platform_patch into the program tree"
    [ "$(stat -c '%a' "$DATA_HOME_TEST/patches/$platform_patch")" = 644 ] \
        || fail "isolated $platform_patch has unsafe permissions"
done
assert_contains "dict=$DATA_HOME_TEST/data/dict" "$TRACE"
assert_contains "KOReader: library_dir=$LAST_DIR_TEST source=lastdir" "$WRAPPER_LOG"
[ "$(wc -l <"$LIBRARY_SYNC_TRACE")" -eq 1 ] || fail "friendly library was not synchronized once per wrapper launch"
cmp -s "$STARTUP_SCRIPT" "$ACTIVE_STARTUP_SCRIPT" || fail "wrapper did not refresh the active startup script"
[ "$(stat -c '%a' "$ACTIVE_STARTUP_SCRIPT")" = 755 ] || fail "active startup script is not executable"

reader_runs_before=$(cat "$STATE")
rm -f "$ACTIVE_STARTUP_SCRIPT"
mkdir "$ACTIVE_STARTUP_SCRIPT"
UNSAFE_STARTUP_LOG=$TMPDIR_TEST/unsafe-startup-target.log
set +e
TEST_STATE=$STATE TEST_TRACE=$TRACE \
KOREADER_DIR=$KOREADER_DIR_TEST QTFB_SHIM=$HOST_PRELOAD \
KOREADER_LIBRARY_DIR=$LIBRARY_DIR_TEST KOREADER_SETTINGS=$SETTINGS_TEST \
    "$WRAPPER" 2>"$UNSAFE_STARTUP_LOG"
unsafe_startup_status=$?
set -e
[ "$unsafe_startup_status" -ne 0 ] || fail "directory startup target was accepted"
assert_contains 'KOReader active startup target is unsafe' "$UNSAFE_STARTUP_LOG"
[ "$(cat "$STATE")" = "$reader_runs_before" ] || fail "reader.lua ran with an unsafe startup target"
rmdir "$ACTIVE_STARTUP_SCRIPT"
printf '%s\n' '#!/bin/sh' 'echo installed-startup-v1' >"$ACTIVE_STARTUP_SCRIPT"
chmod 0755 "$ACTIVE_STARTUP_SCRIPT"

# A stale lastdir outside the document library must not reopen a broad parent.
# The populated friendly view takes precedence over an empty /books fallback.
cat >"$SETTINGS_TEST" <<EOF
return {
    ["lastdir"] = "$OUTSIDE_DIR_TEST",
}
EOF
rm -f "$STATE" "$TRACE" "$WRAPPER_LOG"
export REMAGIC_DEVICE_PROFILE=$PAPER_PRO_MOVE_PROFILE
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
assert_contains "KOReader: library_dir=$LIBRARY_DIR_TEST source=friendly-fallback" "$WRAPPER_LOG"
assert_contains "device_profile=$PAPER_PRO_MOVE_PROFILE" "$TRACE"
[ "$(wc -l <"$LIBRARY_SYNC_TRACE")" -eq 2 ] || fail "second wrapper launch did not synchronize the friendly library"
cmp -s "$STARTUP_SCRIPT" "$ACTIVE_STARTUP_SCRIPT" || fail "second launch left a stale active startup script"
[ ! -L "$ACTIVE_STARTUP_SCRIPT" ] || fail "startup synchronization left an attacker-controlled symlink"
assert_contains 'must not be overwritten through a symlink' "$STARTUP_SENTINEL"

# This is the exact device regression: lastdir points at the valid but empty
# /books root while the generated friendly view contains books.
cat >"$SETTINGS_TEST" <<EOF
return {
    ["lastdir"] = "$BOOKS_DIR_TEST",
}
EOF
rm -f "$STATE" "$TRACE" "$WRAPPER_LOG"
TEST_STATE=$STATE TEST_TRACE=$TRACE \
KOREADER_DIR=$KOREADER_DIR_TEST QTFB_SHIM=$HOST_PRELOAD \
KOREADER_LIBRARY_DIR=$LIBRARY_DIR_TEST KOREADER_SETTINGS=$SETTINGS_TEST \
    "$WRAPPER" 2>"$WRAPPER_LOG"
assert_contains "argc=1 arg1=$LIBRARY_DIR_TEST" "$TRACE"
assert_contains "KOReader: library_dir=$LIBRARY_DIR_TEST source=friendly-fallback" "$WRAPPER_LOG"

# A non-empty remembered manual directory remains valid; the adapter only
# rejects stale or empty history and never forces the official view over an
# intentional /books location.
: >"$BOOKS_LAST_DIR_TEST/手动书籍.epub"
cat >"$SETTINGS_TEST" <<EOF
return {
    ["lastdir"] = "$BOOKS_LAST_DIR_TEST",
}
EOF
rm -f "$STATE" "$TRACE" "$WRAPPER_LOG"
TEST_STATE=$STATE TEST_TRACE=$TRACE \
KOREADER_DIR=$KOREADER_DIR_TEST QTFB_SHIM=$HOST_PRELOAD \
KOREADER_LIBRARY_DIR=$LIBRARY_DIR_TEST KOREADER_SETTINGS=$SETTINGS_TEST \
    "$WRAPPER" 2>"$WRAPPER_LOG"
assert_contains "argc=1 arg1=$BOOKS_LAST_DIR_TEST" "$TRACE"
assert_contains "KOReader: library_dir=$BOOKS_LAST_DIR_TEST source=lastdir" "$WRAPPER_LOG"

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
assert_contains "initial=$BOOK_PATH" "$TRACE"

# A busy/failed migration with no active statistics database is a hard launch
# failure. Opening reader.lua anyway could recreate the database while another
# installer owns it.
FAILING_MIGRATOR=$TMPDIR_TEST/failing-migrator
cat >"$FAILING_MIGRATOR" <<'EOF'
#!/bin/sh
[ "$KOREADER_DATA_DIR" = "$TEST_EXPECTED_DATA_DIR" ] || exit 74
[ "$KO_HOME" = "$TEST_EXPECTED_DATA_DIR" ] || exit 74
exit 75
EOF
chmod 0755 "$FAILING_MIGRATOR"
rm -f "$DATA_HOME_TEST/settings/statistics.sqlite3"
rm -f "$STATE" "$TRACE"
printf '%s\n' '#!/bin/sh' 'echo installed-startup-v3' >"$STARTUP_SCRIPT"
printf '%s\n' '#!/bin/sh' 'echo active-before-failed-migration' >"$ACTIVE_STARTUP_SCRIPT"
set +e
TEST_STATE=$STATE TEST_TRACE=$TRACE \
KOREADER_DIR=$KOREADER_DIR_TEST QTFB_SHIM=$HOST_PRELOAD \
KOREADER_LIBRARY_DIR=$LIBRARY_DIR_TEST KOREADER_SETTINGS=$SETTINGS_TEST \
KOREADER_MIGRATOR=$FAILING_MIGRATOR \
TEST_EXPECTED_DATA_DIR=$DATA_HOME_TEST \
    "$WRAPPER" >"$TMPDIR_TEST/migration-failure.log" 2>&1
status=$?
set -e
[ "$status" -eq 75 ] || fail "migration failure returned $status instead of 75"
[ ! -e "$TRACE" ] || fail "reader started despite an incomplete migration"
assert_contains 'refusing to open an incomplete data directory' "$TMPDIR_TEST/migration-failure.log"
assert_contains 'active-before-failed-migration' "$ACTIVE_STARTUP_SCRIPT"
printf 'healthy-test-database\n' >"$DATA_HOME_TEST/settings/statistics.sqlite3"

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
if flock -x -n "$KOREADER_INSTALL_LOCK" true; then
    kill -KILL "$wrapper_pid" "$reader_pid" 2>/dev/null || true
    fail "running wrapper did not hold the shared deployment lock"
fi
kill -TERM "$wrapper_pid"
set +e
wait "$wrapper_pid"
status=$?
set -e
[ "$status" -eq 143 ] || fail "TERM returned $status instead of 143"
if kill -0 "$reader_pid" 2>/dev/null; then
    fail "reader process survived wrapper termination"
fi
attempts=0
while ! flock -x -n "$KOREADER_INSTALL_LOCK" true; do
    [ "$attempts" -lt 200 ] || fail "wrapper descendants did not release the deployment lock"
    sleep 0.01
    attempts=$((attempts + 1))
done

# The manager's final KILL targets the wrapper PID. The wrapper must therefore
# bound its own TERM grace period and reap a reader that refuses to stop; an
# otherwise orphaned reader would keep QTFB and the data directory alive.
rm -f "$STATE" "$TRACE" "$CHILD_PID_FILE"
TEST_STATE=$STATE TEST_TRACE=$TRACE TEST_BLOCK=1 TEST_IGNORE_TERM=1 \
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
[ -s "$CHILD_PID_FILE" ] || fail "TERM-ignoring fake reader did not start"
reader_pid=$(cat "$CHILD_PID_FILE")
timeout_marker=$TMPDIR_TEST/term-timeout
(
    sleep 3
    if kill -KILL "$wrapper_pid" 2>/dev/null; then
        : >"$timeout_marker"
    fi
    kill -KILL "$reader_pid" 2>/dev/null || true
) &
timeout_pid=$!
kill -TERM "$wrapper_pid"
set +e
wait "$wrapper_pid"
status=$?
set -e
kill -TERM "$timeout_pid" 2>/dev/null || true
wait "$timeout_pid" 2>/dev/null || true
[ ! -e "$timeout_marker" ] || fail "wrapper exceeded its bounded child termination deadline"
[ "$status" -eq 143 ] || fail "bounded TERM returned $status instead of 143"
if kill -0 "$reader_pid" 2>/dev/null; then
    kill -KILL "$reader_pid" 2>/dev/null || true
    fail "TERM-ignoring reader survived wrapper termination"
fi

echo "koreader wrapper tests passed"
