#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
MODULE=$ROOT/scripts/remagic-library-collection.lua
LOCAL_SCAN_MODULE=$ROOT/scripts/remagic-library-local-scan.lua
MIGRATION_MODULE=$ROOT/scripts/remagic-library-collection-migrate.lua
MOCK=$ROOT/tests/remagic-library-collection-mock.lua
MIGRATION_MOCK=$ROOT/tests/remagic-library-collection-migrate-mock.lua
PATCH=$ROOT/patches/22-remagic-library-collection.lua
MIGRATION_PATCH=$ROOT/patches/20-remagic-collection-migration.lua
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT HUP INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }

luac -p "$MODULE"
luac -p "$LOCAL_SCAN_MODULE"
luac -p "$MIGRATION_MODULE"
luac -p "$MOCK"
luac -p "$MIGRATION_MOCK"
luac -p "$PATCH"
luac -p "$MIGRATION_PATCH"

# KOReader reserves priority 1 userpatches for the early boot phase, before
# G_reader_settings and UIManager exist.  This integration imports UI modules,
# so keeping it in priority 2 is a functional requirement rather than style.
case ${PATCH##*/} in
    2[0-9]-*) ;;
    *) fail "collection integration must be a late (priority 2) userpatch" ;;
esac

case ${MIGRATION_PATCH##*/}:${PATCH##*/} in
    20-*:*22-*) ;;
    *) fail "collection migration must load before lifecycle and collection integration" ;;
esac

mkdir -p "$TMPDIR_TEST/library" "$TMPDIR_TEST/books" "$TMPDIR_TEST/xochitl" \
    "$TMPDIR_TEST/custom"
: >"$TMPDIR_TEST/custom.epub"
: >"$TMPDIR_TEST/books/论语.epub"
for uuid in \
    00000000-0000-0000-0000-000000000001 \
    00000000-0000-0000-0000-000000000002 \
    00000000-0000-0000-0000-000000000003
do
    : >"$TMPDIR_TEST/xochitl/$uuid.epub"
done
printf '%s\n' \
    '# koreader-for-remagic-library-v1' \
    '00000000-0000-0000-0000-000000000001	epub	论语.epub' \
    '00000000-0000-0000-0000-000000000002	epub	孟子.epub' \
    >"$TMPDIR_TEST/library.index"

for mode in normal explicit existing invalid_index; do
    lua "$MOCK" "$MODULE" "$LOCAL_SCAN_MODULE" "$mode" "$TMPDIR_TEST"
done
lua "$MIGRATION_MOCK" "$MIGRATION_MODULE"

grep -F 'ReadCollection' "$MODULE" >/dev/null || fail "module does not use KOReader collections"
grep -F 'UIManager:scheduleIn(0.25, scan_slice)' "$LOCAL_SCAN_MODULE" >/dev/null || \
    fail "local collection scan is not deferred until after first paint"
if grep -F 'updateCollectionFromFolder' "$MODULE" >/dev/null; then
    fail "managed collection still invokes KOReader's synchronous folder scanner"
fi
if grep -E 'os\.execute|os\.remove|io\.popen' "$MODULE" >/dev/null; then
    fail "collection module contains an out-of-process or destructive operation"
fi

echo "KOReader managed collection tests passed"
