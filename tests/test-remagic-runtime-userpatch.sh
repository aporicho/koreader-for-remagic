#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PATCH=$ROOT/patches/2-remagic-runtime.lua
STORAGE_PATCH=$ROOT/patches/1-remagic-storage.lua
MOCK=$ROOT/tests/remagic-runtime-userpatch-mock.lua
HELPER=$ROOT/scripts/koreader-lifecycle
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT HUP INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

luac -p "$PATCH"
luac -p "$STORAGE_PATCH"
luac -p "$MOCK"

grep -F 'UIManager:broadcastEvent(Event:new("Exit"))' "$PATCH" >/dev/null || \
    fail "patch does not use KOReader's native Exit event"
grep -F 'UIManager:quit(0)' "$PATCH" >/dev/null || \
    fail "patch does not drain modal widgets after KOReader's native Exit event"
grep -F 'UIManager:tickAfterNext' "$PATCH" >/dev/null || \
    fail "patch does not wait through the first repaint"

storage_program=$TMPDIR_TEST/storage-program
storage_data=$TMPDIR_TEST/storage-data
storage_test=$TMPDIR_TEST/storage-test.lua
mkdir -p "$storage_program" "$storage_data"
cat >"$storage_test" <<'EOF'
local data_dir, patch = arg[1], arg[2]
local version = {}
package.preload.datastorage = function()
    return { getDataDir = function() return data_dir end }
end
package.preload.version = function() return version end
dofile(patch)
assert(version:getLastLogLine() == "")
assert(version:appendToLogFile("first"))
assert(version:appendToLogFile("second"))
assert(version:getLastLogLine() == "second")
EOF
(cd "$storage_program" && lua "$storage_test" "$storage_data" "$STORAGE_PATCH")
[ -s "$storage_data/version.log" ] || fail "storage patch did not write version log under KO_HOME"
[ ! -e "$storage_program/version.log" ] || fail "storage patch wrote version log into program tree"

run_mode() {
    mode=$1
    runtime=$TMPDIR_TEST/$mode
    mkdir -p "$runtime"
    REMAGIC_APP_PID=4321 \
    REMAGIC_APP_GENERATION=3719679425990660 \
    REMAGIC_RUNTIME_DIR=$runtime \
    REMAGIC_KOREADER_LIFECYCLE_HELPER=$HELPER \
    REMAGIC_KOREADER_POLL_SECONDS=0.05 \
        lua "$MOCK" "$PATCH" "$mode"
    if find "$runtime" -maxdepth 1 -type f -name '.koreader-ready.*.tmp' -print -quit | grep . >/dev/null; then
        fail "$mode left an incomplete atomic marker"
    fi
}

run_v2_mode() {
    mode=$1
    runtime=$TMPDIR_TEST/$mode
    mkdir -p "$runtime"
    bridge=$runtime/bridge
    inbox=$runtime/inbox
    trace=$runtime/trace
    : >"$inbox"
    : >"$trace"
    bridge_source='#!/bin/sh
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
    printf '%s\n' "$bridge_source" >"$bridge"
    chmod 0755 "$bridge"

    open_path=$runtime/一本书.epub
    open_dir=$runtime/书库
    : >"$open_path"
    mkdir -p "$open_dir"
    REMAGIC_APP_PID=4321 \
    REMAGIC_APP_GENERATION=3719679425990660 \
    REMAGIC_RUNTIME_DIR=$runtime \
    REMAGIC_KOREADER_LIFECYCLE_HELPER=$HELPER \
    REMAGIC_APP_BRIDGE=$bridge \
    TEST_BRIDGE_INBOX=$inbox \
    TEST_BRIDGE_TRACE=$trace \
    TEST_OPEN_PATH=$open_path \
    TEST_OPEN_DIR=$open_dir \
    REMAGIC_INITIAL_OPEN_PATH=$open_path \
    REMAGIC_ALLOWED_OPEN_ROOTS=$runtime \
    REMAGIC_KOREADER_POLL_SECONDS=0.05 \
        lua "$MOCK" "$PATCH" "$mode"

    grep -F '"protocol":2' "$trace" >/dev/null || fail "$mode emitted no v2 envelope"
    if find "$runtime" -maxdepth 1 -type f \( -name 'koreader-ready' -o -name 'koreader-exit' \) \
        -print -quit | grep . >/dev/null
    then
        fail "$mode unexpectedly used a schema-v1 lifecycle marker"
    fi
}

run_mode filemanager
run_mode reader
run_mode rapid_transition
run_mode stale_exit
run_mode exit_before_ready
run_mode modal_exit
run_v2_mode background_resume
run_v2_mode open_path
run_v2_mode foreground_open_file
run_v2_mode foreground_open_directory
run_v2_mode start_preapplied
run_v2_mode v2_shutdown

runtime=$TMPDIR_TEST/invalid_identity
mkdir -p "$runtime"
REMAGIC_APP_PID=not-a-pid \
REMAGIC_APP_GENERATION= \
REMAGIC_RUNTIME_DIR=$runtime \
REMAGIC_KOREADER_LIFECYCLE_HELPER=$HELPER \
    lua "$MOCK" "$PATCH" invalid_identity

echo "remagic KOReader runtime userpatch tests passed"
