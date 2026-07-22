#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LUAJIT=${KOREADER_TEST_LUAJIT:-}

if [ -z "$LUAJIT" ]; then
    LUAJIT=$(command -v luajit 2>/dev/null || true)
fi
if [ -z "$LUAJIT" ] || [ ! -x "$LUAJIT" ]; then
    echo "SKIP: direct lifecycle FD test requires KOREADER_TEST_LUAJIT or host luajit" >&2
    exit 0
fi
command -v python3 >/dev/null 2>&1 || {
    echo "FAIL: python3 is required for the direct lifecycle FD test" >&2
    exit 1
}

"$LUAJIT" -e 'assert(require("ffi"))'
python3 "$ROOT/tests/remagic-runtime-fd-test.py" \
    "$LUAJIT" \
    "$ROOT/tests/remagic-runtime-userpatch-mock.lua" \
    "$ROOT/patches/21-remagic-lifecycle-v2.lua"
