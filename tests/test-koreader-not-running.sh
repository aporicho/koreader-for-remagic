#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CHECKER=$ROOT/scripts/koreader-not-running
INSTALLER=$ROOT/scripts/install-device.sh
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT HUP INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

PROC_ROOT=$TMPDIR_TEST/proc
mkdir -p "$PROC_ROOT/101"
printf '/usr/bin/unrelated\000--serve\000' >"$PROC_ROOT/101/cmdline"

KOREADER_PROC_ROOT=$PROC_ROOT "$CHECKER" || fail "unrelated process blocked installation"

mkdir -p "$PROC_ROOT/202"
printf '/home/root/apps/koreader/reader.lua\000/home/root/books/a.epub\000' >"$PROC_ROOT/202/cmdline"
set +e
KOREADER_PROC_ROOT=$PROC_ROOT "$CHECKER" 2>"$TMPDIR_TEST/running.log"
status=$?
set -e
[ "$status" -eq 1 ] || fail "running reader returned $status instead of refusing"
grep -q 'PID: 202' "$TMPDIR_TEST/running.log" || fail "refusal did not identify reader PID"
grep -q 'will not terminate' "$TMPDIR_TEST/running.log" || fail "refusal did not explain lifecycle ownership"

rm -rf "$PROC_ROOT/202"
mkdir -p "$PROC_ROOT/303"
printf '/bin/sh\000/home/root/apps/remagic-koreader/bin/koreader-remagic\000' >"$PROC_ROOT/303/cmdline"
set +e
KOREADER_PROC_ROOT=$PROC_ROOT "$CHECKER" 2>"$TMPDIR_TEST/wrapper.log"
status=$?
set -e
[ "$status" -eq 1 ] || fail "running adapter wrapper was not detected"

check_line=$(grep -n '^run_not_running_check$' "$INSTALLER" | sed -n '1s/:.*//p')
mutation_line=$(grep -n '^acquire_install_lock$' "$INSTALLER" | sed -n '1s/:.*//p')
[ -n "$check_line" ] && [ -n "$mutation_line" ] || fail "could not verify installer safety order"
[ "$check_line" -lt "$mutation_line" ] || fail "installer mutates files before checking the running process"

echo "koreader running-process guard tests passed"
