#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MIGRATOR=$ROOT/scripts/koreader-data-migrate
INSPECTOR=$ROOT/scripts/koreader-db-inspect
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT HUP INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is required for migration tests"

make_db() {
    db=$1
    books=$2
    pages=$3
    schema=${4:-20221111}
    mkdir -p "$(dirname -- "$db")"
    sqlite3 "$db" <<EOF
PRAGMA user_version=$schema;
CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT);
CREATE TABLE page_stat_data (id_book INTEGER, page INTEGER, start_time INTEGER, duration INTEGER, total_pages INTEGER);
CREATE VIEW page_stat AS SELECT id_book, page, start_time, duration FROM page_stat_data;
WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < $books)
INSERT INTO book(id, title) SELECT x, 'book-' || x FROM n WHERE x <= $books;
WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < $pages)
INSERT INTO page_stat_data(id_book, page, start_time, duration, total_pages)
SELECT 1, x, 1000 + x, 10, $pages FROM n WHERE x <= $pages;
EOF
}

inspect_counts() {
    "$INSPECTOR" "$1" | awk -F '\t' '$1 == "KOREADER_DB_VALID" { print $3 ":" $4; exit }'
}

run_migration() {
    data_dir=$1
    sources=$2
    KOREADER_DIR=$data_dir \
    KOREADER_DATA_DIR=$data_dir \
    KOREADER_LEGACY_DATA_DIRS=$sources \
    KOREADER_BACKUP_ROOT=$TMPDIR_TEST/backups \
    KOREADER_DB_INSPECTOR=$INSPECTOR \
        "$MIGRATOR"
}

# Empty active DB: choose the source with the richer page history, isolate the
# empty file, and merge missing settings without overwriting current files.
case1=$TMPDIR_TEST/case1
active=$case1/active
rich=$case1/rich
poor=$case1/poor
mkdir -p "$active/settings" "$rich/settings" "$poor/settings"
: >"$active/settings/statistics.sqlite3"
printf 'current history\n' >"$active/history.lua"
printf 'legacy history\n' >"$rich/history.lua"
printf 'return { legacy = true }\n' >"$rich/defaults.custom.lua"
make_db "$rich/settings/statistics.sqlite3" 7 26
make_db "$poor/settings/statistics.sqlite3" 1 1
run_migration "$active" "$poor:$rich"
[ "$(inspect_counts "$active/settings/statistics.sqlite3")" = 7:26 ] || fail "did not select richer recovery database"
grep -q '^current history$' "$active/history.lua" || fail "existing user history was overwritten"
grep -q 'legacy = true' "$active/defaults.custom.lua" || fail "missing user setting was not copied"
find "$active/settings" -name 'statistics.sqlite3.invalid.*' -type f | grep -q . || fail "empty target was not isolated"
find "$TMPDIR_TEST/backups" -path '*/data/settings/statistics.sqlite3' -type f | grep -q . || fail "pre-repair backup was not created"

hash_before=$(sha256sum "$active/settings/statistics.sqlite3" | awk '{ print $1 }')
invalid_before=$(find "$active/settings" -name 'statistics.sqlite3.invalid.*' -type f | wc -l)
run_migration "$active" "$poor:$rich"
hash_after=$(sha256sum "$active/settings/statistics.sqlite3" | awk '{ print $1 }')
invalid_after=$(find "$active/settings" -name 'statistics.sqlite3.invalid.*' -type f | wc -l)
[ "$hash_before" = "$hash_after" ] || fail "idempotent migration changed a valid current database"
[ "$invalid_before" -eq "$invalid_after" ] || fail "idempotent migration created another isolated database"

# A valid target newer than all sources is authoritative even when a source is
# richer, so current reading activity can never be rolled back.
case2=$TMPDIR_TEST/case2
active=$case2/active
source=$case2/source
make_db "$active/settings/statistics.sqlite3" 2 2
make_db "$source/settings/statistics.sqlite3" 8 30
touch -t 202601010101 "$source/settings/statistics.sqlite3"
touch -t 202601020101 "$active/settings/statistics.sqlite3"
hash_before=$(sha256sum "$active/settings/statistics.sqlite3" | awk '{ print $1 }')
run_migration "$active" "$source"
hash_after=$(sha256sum "$active/settings/statistics.sqlite3" | awk '{ print $1 }')
[ "$hash_before" = "$hash_after" ] || fail "newer valid target was overwritten"
[ "$(inspect_counts "$active/settings/statistics.sqlite3")" = 2:2 ] || fail "newer target counts changed"

# A non-empty WAL always protects the active DB because it may contain newer
# committed rows that an immutable migration inspection deliberately ignores.
printf 'uncheckpointed activity\n' >"$active/settings/statistics.sqlite3-wal"
touch -t 202601030101 "$source/settings/statistics.sqlite3"
hash_before=$(sha256sum "$active/settings/statistics.sqlite3" | awk '{ print $1 }')
run_migration "$active" "$source"
hash_after=$(sha256sum "$active/settings/statistics.sqlite3" | awk '{ print $1 }')
[ "$hash_before" = "$hash_after" ] || fail "target with a live WAL was overwritten"

# A valid target is always authoritative. An old source may have a newer mtime
# and richer counters, but migration must never guess that it should replace
# current user activity.
case3=$TMPDIR_TEST/case3
active=$case3/active
source=$case3/source
make_db "$active/settings/statistics.sqlite3" 1 1
make_db "$source/settings/statistics.sqlite3" 3 4
touch -t 202601010101 "$active/settings/statistics.sqlite3"
touch -t 202601020101 "$source/settings/statistics.sqlite3"
hash_before=$(sha256sum "$active/settings/statistics.sqlite3" | awk '{ print $1 }')
run_migration "$active" "$source"
hash_after=$(sha256sum "$active/settings/statistics.sqlite3" | awk '{ print $1 }')
[ "$hash_before" = "$hash_after" ] || fail "valid target was replaced by newer richer legacy data"
[ "$(inspect_counts "$active/settings/statistics.sqlite3")" = 1:1 ] || fail "valid target counts changed"
if find "$active/settings" -name 'statistics.sqlite3.superseded.*' -type f | grep -q .; then
    fail "valid target was incorrectly superseded"
fi

# With no valid recovery source, quarantine the bad file instead of feeding it
# to KOReader's schema migration path; KOReader can then create a fresh DB.
case4=$TMPDIR_TEST/case4
active=$case4/active
bad=$case4/bad
mkdir -p "$active/settings" "$bad/settings"
printf 'not sqlite\n' >"$active/settings/statistics.sqlite3"
printf 'also not sqlite\n' >"$bad/settings/statistics.sqlite3"
run_migration "$active" "$bad"
[ ! -e "$active/settings/statistics.sqlite3" ] || fail "invalid target without recovery source was left active"
find "$active/settings" -name 'statistics.sqlite3.invalid.*' -type f | grep -q . || fail "invalid target was not quarantined"

# User-owned document settings and history are merged recursively. Existing
# paths win at every depth, while missing nested and hidden files are copied.
case5=$TMPDIR_TEST/case5
active=$case5/active
source=$case5/source
make_db "$active/settings/statistics.sqlite3" 2 3
make_db "$source/settings/statistics.sqlite3" 9 40
mkdir -p \
    "$active/docsettings/同名书.sdr" \
    "$source/docsettings/同名书.sdr" \
    "$source/docsettings/新书.sdr" \
    "$source/hashdocsettings/ab" \
    "$source/history/最近" \
    "$source/settings/子目录"
printf 'current metadata\n' >"$active/docsettings/同名书.sdr/metadata.lua"
printf 'legacy metadata\n' >"$source/docsettings/同名书.sdr/metadata.lua"
printf 'new metadata\n' >"$source/docsettings/新书.sdr/metadata.lua"
printf 'hash metadata\n' >"$source/hashdocsettings/ab/123.lua"
printf 'history entry\n' >"$source/history/最近/一本书.lua"
printf 'nested setting\n' >"$source/settings/子目录/setting.lua"
printf 'hidden setting\n' >"$source/docsettings/.migration-note"
printf 'must not be copied as settings data\n' >"$source/settings/statistics.sqlite3.bkp.foreign"
hash_before=$(sha256sum "$active/settings/statistics.sqlite3" | awk '{ print $1 }')
run_migration "$active" "$source"
hash_after=$(sha256sum "$active/settings/statistics.sqlite3" | awk '{ print $1 }')
[ "$hash_before" = "$hash_after" ] || fail "recursive user-data merge replaced valid statistics"
grep -q '^current metadata$' "$active/docsettings/同名书.sdr/metadata.lua" || fail "recursive merge overwrote current docsettings"
grep -q '^new metadata$' "$active/docsettings/新书.sdr/metadata.lua" || fail "missing docsettings were not copied"
grep -q '^hash metadata$' "$active/hashdocsettings/ab/123.lua" || fail "hashdocsettings were not copied"
grep -q '^history entry$' "$active/history/最近/一本书.lua" || fail "history directory was not copied"
grep -q '^nested setting$' "$active/settings/子目录/setting.lua" || fail "nested settings were not copied"
grep -q '^hidden setting$' "$active/docsettings/.migration-note" || fail "hidden user data was not copied"
[ ! -e "$active/settings/statistics.sqlite3.bkp.foreign" ] || fail "foreign statistics backup leaked through generic data copy"
backup_metadata=$(find "$TMPDIR_TEST/backups" -path '*/data/docsettings/同名书.sdr/metadata.lua' -type f | sed -n '$p')
[ -n "$backup_metadata" ] || fail "recursive pre-migration backup omitted active docsettings"
grep -q '^current metadata$' "$backup_metadata" || fail "recursive backup did not preserve current docsettings"

# Only the currently supported schema can be used as an automatic recovery
# source. A structurally healthy current database from a future schema is
# protected in place rather than being downgraded to a known legacy source.
case6=$TMPDIR_TEST/case6
active=$case6/active
source=$case6/source
make_db "$active/settings/statistics.sqlite3" 5 8 20270101
make_db "$source/settings/statistics.sqlite3" 7 26
hash_before=$(sha256sum "$active/settings/statistics.sqlite3" | awk '{ print $1 }')
set +e
inspect_output=$($INSPECTOR "$active/settings/statistics.sqlite3" 2>/dev/null)
inspect_status=$?
set -e
[ "$inspect_status" -eq 3 ] || fail "future schema returned $inspect_status instead of unsupported status 3"
printf '%s\n' "$inspect_output" | grep -q '^KOREADER_DB_UNSUPPORTED' || fail "future schema has no unsupported marker"
run_migration "$active" "$source"
hash_after=$(sha256sum "$active/settings/statistics.sqlite3" | awk '{ print $1 }')
[ "$hash_before" = "$hash_after" ] || fail "future current database was downgraded"
[ "$(sqlite3 "$active/settings/statistics.sqlite3" 'PRAGMA user_version;')" = 20270101 ] || fail "future target schema changed"

# Unknown future layouts need only be healthy SQLite files. They must be
# protected before current-schema table names are queried.
case7=$TMPDIR_TEST/case7
active=$case7/active
source=$case7/source
mkdir -p "$active/settings"
sqlite3 "$active/settings/statistics.sqlite3" <<'EOF'
PRAGMA user_version=20280101;
CREATE TABLE future_reading_events (document TEXT, position INTEGER);
INSERT INTO future_reading_events VALUES ('book', 42);
EOF
make_db "$source/settings/statistics.sqlite3" 10 100
hash_before=$(sha256sum "$active/settings/statistics.sqlite3" | awk '{ print $1 }')
run_migration "$active" "$source"
hash_after=$(sha256sum "$active/settings/statistics.sqlite3" | awk '{ print $1 }')
[ "$hash_before" = "$hash_after" ] || fail "unknown future layout was replaced by legacy data"
[ "$(sqlite3 "$active/settings/statistics.sqlite3" 'SELECT position FROM future_reading_events;')" = 42 ] || \
    fail "future-schema content was not preserved"

# A live PID owns the migration lock and must never be broken by a concurrent
# installer. After SIGKILL, the kernel guard is released and the dead PID lock
# is reclaimed safely by the next run.
case8=$TMPDIR_TEST/case8
active=$case8/active
make_db "$active/settings/statistics.sqlite3" 2 5
blocking_inspector=$case8/blocking-inspector
ready_file=$case8/inspector.ready
release_file=$case8/inspector.release
inspector_pid_file=$case8/inspector.pid
mkdir -p "$case8"
cat >"$blocking_inspector" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$$" >"$TEST_INSPECTOR_PID"
: >"$TEST_READY_FILE"
while [ ! -e "$TEST_RELEASE_FILE" ]; do
    sleep 0.02
done
exit 1
EOF
chmod 0755 "$blocking_inspector"

TEST_READY_FILE=$ready_file \
TEST_RELEASE_FILE=$release_file \
TEST_INSPECTOR_PID=$inspector_pid_file \
KOREADER_DIR=$active \
KOREADER_DATA_DIR=$active \
KOREADER_LEGACY_DATA_DIRS=$case8/missing-source \
KOREADER_BACKUP_ROOT=$TMPDIR_TEST/backups \
KOREADER_DB_INSPECTOR=$blocking_inspector \
    "$MIGRATOR" >"$case8/first.log" 2>&1 &
first_migration_pid=$!
attempts=0
while [ ! -e "$ready_file" ] && [ "$attempts" -lt 200 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
done
[ -e "$ready_file" ] || fail "blocking migration did not acquire its lock"
lock_dir=$active/.remagic-data-migrate.lock
[ "$(cat "$lock_dir/owner")" = remagic-koreader-data-migrate ] || fail "migration lock has no owner identity"
lock_pid=$(cat "$lock_dir/pid")
[ "$lock_pid" = "$first_migration_pid" ] || fail "migration lock PID does not identify its owner"
kill -0 "$lock_pid" 2>/dev/null || fail "recorded migration owner is not alive"

set +e
KOREADER_DIR=$active \
KOREADER_DATA_DIR=$active \
KOREADER_LEGACY_DATA_DIRS=$case8/missing-source \
KOREADER_BACKUP_ROOT=$TMPDIR_TEST/backups \
KOREADER_DB_INSPECTOR=$INSPECTOR \
    "$MIGRATOR" >"$case8/concurrent.log" 2>&1
concurrent_status=$?
set -e
[ "$concurrent_status" -eq 75 ] || fail "live migration lock returned $concurrent_status instead of 75"
grep -q "pid=$lock_pid" "$case8/concurrent.log" || fail "live-lock refusal omitted owner PID"
[ "$(cat "$lock_dir/pid")" = "$lock_pid" ] || fail "concurrent migration broke the live lock"

kill -KILL "$first_migration_pid"
set +e
wait "$first_migration_pid" 2>/dev/null
killed_status=$?
set -e
[ "$killed_status" -eq 137 ] || fail "test migration was not killed with SIGKILL"
: >"$release_file"
inspector_pid=$(cat "$inspector_pid_file")
attempts=0
while kill -0 "$inspector_pid" 2>/dev/null && [ "$attempts" -lt 200 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
done

[ -d "$lock_dir" ] || fail "SIGKILL unexpectedly cleaned the stale lock"
set +e
KOREADER_DIR=$active \
KOREADER_DATA_DIR=$active \
KOREADER_LEGACY_DATA_DIRS=$case8/missing-source \
KOREADER_BACKUP_ROOT=$TMPDIR_TEST/backups \
KOREADER_DB_INSPECTOR=$INSPECTOR \
    "$MIGRATOR" >"$case8/recovery.log" 2>&1
recovery_status=$?
set -e
[ "$recovery_status" -eq 0 ] || fail "stale migration lock recovery returned $recovery_status"
grep -q "Removing stale KOReader data migration lock (pid=$lock_pid)" "$case8/recovery.log" || \
    fail "stale lock recovery was not reported"
[ ! -d "$lock_dir" ] || fail "stale migration lock survived successful recovery"

grep -F 'BACKUP_ROOT=${KOREADER_BACKUP_ROOT:-/home/root/.local/state/remagic-koreader/backups}' "$MIGRATOR" >/dev/null || \
    fail "persistent backup root regressed into an application directory"

echo "koreader data migration tests passed"
