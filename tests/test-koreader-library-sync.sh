#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SYNC=$ROOT/scripts/koreader-library-sync
INDEXER=$ROOT/scripts/koreader-library-index.lua
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT HUP INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

KOREADER_TEST_INSTALL=${KOREADER_TEST_INSTALL:-}
if [ -z "$KOREADER_TEST_INSTALL" ]; then
    for candidate in \
        "$ROOT/../remagic/dist/remagic/opt/koreader-for-remagic/vendor/releases/v2026.03-56621d5ee66ad94f4f3e2e6d204e8c34be730343f915edc36bb076a043a2e468/koreader" \
        /home/root/apps/koreader
    do
        if [ -r "$candidate/common/dkjson.lua" ]; then
            KOREADER_TEST_INSTALL=$candidate
            break
        fi
    done
fi
if [ -z "$KOREADER_TEST_INSTALL" ] || [ ! -r "$KOREADER_TEST_INSTALL/common/dkjson.lua" ]; then
    echo "koreader library sync tests skipped: set KOREADER_TEST_INSTALL to an extracted KOReader tree" >&2
    exit 0
fi

LUA=${KOREADER_TEST_LUA:-$(command -v lua)}
FLOCK=${KOREADER_TEST_FLOCK:-$(command -v flock)}
[ -x "$LUA" ] || fail "host Lua interpreter is required"
[ -x "$FLOCK" ] || fail "flock is required"

SOURCE=$TMPDIR_TEST/xochitl
STATE_ROOT=$TMPDIR_TEST/koreader-for-remagic
LIBRARY=$STATE_ROOT/library
mkdir -p "$SOURCE/.thumbnails"
mkdir -p "$STATE_ROOT/user-owned-sentinel"
printf 'not part of the friendly view\n' >"$SOURCE/.thumbnails/preview.png"
printf 'must survive every cleanup\n' >"$STATE_ROOT/user-owned-sentinel/keep.txt"

ID_CHINESE=11111111-1111-1111-1111-111111111111
ID_DUP_A=22222222-2222-2222-2222-222222222222
ID_DUP_B=33333333-3333-3333-3333-333333333333
ID_UNSAFE=44444444-4444-4444-4444-444444444444
ID_EMPTY=55555555-5555-5555-5555-555555555555
ID_MISSING=66666666-6666-6666-6666-666666666666
ID_COLLECTION=77777777-7777-7777-7777-777777777777

cat >"$SOURCE/$ID_CHINESE.metadata" <<'EOF'
{"type":"DocumentType","visibleName":"论语 大学 中庸","deleted":false}
EOF
printf 'epub preferred\n' >"$SOURCE/$ID_CHINESE.epub"
printf 'pdf fallback must not win\n' >"$SOURCE/$ID_CHINESE.pdf"

for id in "$ID_DUP_A" "$ID_DUP_B"; do
    cat >"$SOURCE/$id.metadata" <<'EOF'
{"type":"DocumentType","visibleName":"重复 书","deleted":false}
EOF
    printf 'duplicate fixture\n' >"$SOURCE/$id.epub"
done

cat >"$SOURCE/$ID_UNSAFE.metadata" <<'EOF'
{"type":"DocumentType","visibleName":"../危险/书\\名\u0001","deleted":false}
EOF
printf 'unsafe title fixture\n' >"$SOURCE/$ID_UNSAFE.epub"

cat >"$SOURCE/$ID_EMPTY.metadata" <<'EOF'
{"type":"DocumentType","visibleName":" .\u0000.\t ","deleted":false}
EOF
printf 'empty title fixture\n' >"$SOURCE/$ID_EMPTY.pdf"

cat >"$SOURCE/$ID_MISSING.metadata" <<'EOF'
{"type":"DocumentType","visibleName":"文件缺失","deleted":false}
EOF

cat >"$SOURCE/$ID_COLLECTION.metadata" <<'EOF'
{"type":"CollectionType","visibleName":"不应显示的目录","deleted":false}
EOF
printf 'collection fixture\n' >"$SOURCE/$ID_COLLECTION.epub"

# Invalid source basenames are ignored before parsing, so hostile shell text or
# malformed JSON cannot become a destination path.
printf '{broken json\n' >"$SOURCE/not-a-uuid;touch-pwned.metadata"
printf 'must not run\n' >"$SOURCE/not-a-uuid;touch-pwned.epub"

run_sync() {
    KOREADER_DIR=$KOREADER_TEST_INSTALL \
    KOREADER_JSON_DIR=$KOREADER_TEST_INSTALL/common \
    KOREADER_SOURCE_LIBRARY_DIR=$SOURCE \
    KOREADER_LIBRARY_STATE_ROOT=$STATE_ROOT \
    KOREADER_LIBRARY_DIR=$LIBRARY \
    KOREADER_LIBRARY_INDEXER=$INDEXER \
    KOREADER_LIBRARY_LUA=$LUA \
    KOREADER_LIBRARY_FLOCK=$FLOCK \
        "$SYNC"
}

source_hash_before=$(find "$SOURCE" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
run_sync
source_hash_after=$(find "$SOURCE" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
[ "$source_hash_before" = "$source_hash_after" ] || fail "synchronizer modified the official source fixture"

[ -L "$LIBRARY" ] || fail "friendly library was not published as an atomic symlink"
[ -L "$LIBRARY/论语 大学 中庸.epub" ] || fail "Chinese title with spaces was not preserved"
[ "$(readlink "$LIBRARY/论语 大学 中庸.epub")" = "$SOURCE/$ID_CHINESE.epub" ] || \
    fail "EPUB was not preferred over PDF"
[ -L "$LIBRARY/重复 书 [22222222].epub" ] || fail "first duplicate lacks a stable UUID suffix"
[ -L "$LIBRARY/重复 书 [33333333].epub" ] || fail "second duplicate lacks a stable UUID suffix"
[ -L "$LIBRARY/／危险／书＼名.epub" ] || fail "unsafe slash, backslash, dot and control characters were not sanitized"
[ -L "$LIBRARY/未命名-55555555.pdf" ] || fail "empty title did not receive a stable fallback"
[ ! -e "$LIBRARY/文件缺失.epub" ] || fail "metadata without a document created a broken entry"
[ ! -e "$LIBRARY/不应显示的目录.epub" ] || fail "CollectionType leaked into the flat book view"
[ ! -e "$LIBRARY/.thumbnails" ] || fail ".thumbnails leaked into the friendly view"
[ ! -e "$TMPDIR_TEST/touch-pwned" ] || fail "malicious metadata basename executed shell text"

generation_v1=$(readlink "$LIBRARY")
run_sync
[ "$(readlink "$LIBRARY")" = "$generation_v1" ] || fail "unchanged library was needlessly regenerated"

# Rename one book and remove another metadata record. A new complete generation
# must replace the old one, and cleanup must stay inside the private root.
cat >"$SOURCE/$ID_CHINESE.metadata" <<'EOF'
{"type":"DocumentType","visibleName":"四书","deleted":false}
EOF
mv "$SOURCE/$ID_DUP_A.metadata" "$SOURCE/$ID_DUP_A.metadata.removed"
run_sync
generation_v2=$(readlink "$LIBRARY")
[ "$generation_v2" != "$generation_v1" ] || fail "changed metadata did not publish a new generation"
[ -L "$LIBRARY/四书.epub" ] || fail "renamed book was not updated"
[ ! -e "$LIBRARY/论语 大学 中庸.epub" ] || fail "old friendly name survived an update"
[ -L "$LIBRARY/重复 书.epub" ] || fail "remaining duplicate did not collapse to its friendly name"
[ ! -e "$STATE_ROOT/$generation_v1" ] || fail "old private generation was not cleaned"
[ -f "$SOURCE/$ID_DUP_A.epub" ] || fail "source document was deleted while removing a view entry"
[ "$(cat "$STATE_ROOT/user-owned-sentinel/keep.txt")" = 'must survive every cleanup' ] || \
    fail "cleanup escaped the private generation directory"

# A partially written metadata file must fail before publication and leave the
# previously visible generation byte-for-byte intact.
visible_before_failure=$(find -L "$LIBRARY" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
printf '{"type":"DocumentType","visibleName":' >"$SOURCE/$ID_MISSING.metadata"
set +e
run_sync >"$TMPDIR_TEST/failure.log" 2>&1
failure_status=$?
set -e
[ "$failure_status" -ne 0 ] || fail "malformed metadata unexpectedly succeeded"
[ "$(readlink "$LIBRARY")" = "$generation_v2" ] || fail "failed sync replaced the complete generation"
visible_after_failure=$(find -L "$LIBRARY" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
[ "$visible_after_failure" = "$visible_before_failure" ] || fail "failed sync exposed a partial view"
if find "$STATE_ROOT/.library-generations" -mindepth 1 -maxdepth 1 -name '.staging.*' | grep . >/dev/null; then
    fail "failed sync left a staging directory"
fi
[ -f "$STATE_ROOT/user-owned-sentinel/keep.txt" ] || fail "failure cleanup removed unrelated state"

echo "koreader friendly library tests passed"
