#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PATCH=$ROOT/patches/2-remagic-runtime.lua
MOCK=$ROOT/tests/remagic-runtime-userpatch-mock.lua
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT HUP INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

luac -p "$PATCH"
luac -p "$MOCK"

grep -F 'UIManager:broadcastEvent(Event:new("Exit"))' "$PATCH" >/dev/null || \
    fail "patch does not use KOReader's native Exit event"
grep -F 'UIManager:quit(0)' "$PATCH" >/dev/null || \
    fail "patch does not drain modal widgets after KOReader's native Exit event"
grep -F 'UIManager:tickAfterNext' "$PATCH" >/dev/null || \
    fail "patch does not wait through the first repaint"

run_mode() {
    mode=$1
    runtime=$TMPDIR_TEST/$mode
    mkdir -p "$runtime"
    REMAGIC_APP_PID=4321 \
    REMAGIC_APP_GENERATION=3719679425990660 \
    REMAGIC_RUNTIME_DIR=$runtime \
    REMAGIC_KOREADER_POLL_SECONDS=0.05 \
        lua "$MOCK" "$PATCH" "$mode"
    if find "$runtime" -maxdepth 1 -type f -name '.koreader-ready.*.tmp' -print -quit | grep . >/dev/null; then
        fail "$mode left an incomplete atomic marker"
    fi
}

run_mode filemanager
run_mode reader
run_mode rapid_transition
run_mode stale_exit
run_mode exit_before_ready
run_mode modal_exit

runtime=$TMPDIR_TEST/invalid_identity
mkdir -p "$runtime"
REMAGIC_APP_PID=not-a-pid \
REMAGIC_APP_GENERATION= \
REMAGIC_RUNTIME_DIR=$runtime \
    lua "$MOCK" "$PATCH" invalid_identity

echo "remagic KOReader runtime userpatch tests passed"
