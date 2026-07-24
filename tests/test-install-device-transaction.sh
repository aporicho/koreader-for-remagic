#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
INSTALLER=$ROOT/scripts/install-device.sh
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT HUP INT TERM
unset KOREADER_DIR
VENDOR_DIR=/home/root/apps/koreader-for-remagic/vendor/releases/v2026.03-56621d5ee66ad94f4f3e2e6d204e8c34be730343f915edc36bb076a043a2e468/koreader

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

make_db() {
    db=$1
    mkdir -p "${db%/*}"
    sqlite3 "$db" <<'EOF'
PRAGMA user_version=20221111;
CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT);
CREATE TABLE page_stat_data (id_book INTEGER, page INTEGER, start_time INTEGER, duration INTEGER, total_pages INTEGER);
CREATE VIEW page_stat AS SELECT id_book, page, start_time, duration FROM page_stat_data;
INSERT INTO book VALUES (1, 'legacy-book');
INSERT INTO page_stat_data VALUES (1, 7, 1007, 10, 100);
EOF
}

tree_fingerprint() {
    tree=$1
    output=$2
    : >"$output"
    if [ ! -e "$tree" ] && [ ! -L "$tree" ]; then
        printf 'missing\n' >"$output"
        return
    fi
    find "$tree" -mindepth 0 -print | LC_ALL=C sort | while IFS= read -r path; do
        relative=${path#"$tree"}
        kind=$(stat -c %F "$path")
        metadata=$(stat -c '%a:%u:%g' "$path")
        case "$kind" in
            'regular file') digest=$(sha256sum "$path" | awk '{ print $1 }') ;;
            'symbolic link') digest=$(readlink "$path") ;;
            *) digest=- ;;
        esac
        printf '%s\t%s\t%s\t%s\n' "$relative" "$kind" "$metadata" "$digest"
    done >"$output"
}

same_fingerprint() {
    tree=$1
    expected=$2
    actual=$TMPDIR_TEST/actual.$$.fingerprint
    tree_fingerprint "$tree" "$actual"
    cmp -s "$expected" "$actual" || {
        diff -u "$expected" "$actual" >&2 || true
        fail "tree changed unexpectedly: $tree"
    }
}

prepare_case() {
    mode=$1
    case_root=$2
    rm -rf "$case_root"
    mkdir -p \
        "$case_root$VENDOR_DIR" \
        "$case_root/home/root/.local/share" \
        "$case_root/home/root/.local/state" \
        "$case_root/proc/101"
    printf 'koreader-for-remagic-installer-test-root-v1\n' >"$case_root/.koreader-for-remagic-installer-test-root"
    printf '#!/bin/sh\nexit 0\n' >"$case_root$VENDOR_DIR/reader.lua"
    chmod 0755 "$case_root$VENDOR_DIR/reader.lua"
    printf 'program must remain byte-identical\n' >"$case_root$VENDOR_DIR/program-sentinel"
    mkdir -p \
        "$case_root/home/root/apps/koreader/clipboard" \
        "$case_root/home/root/apps/koreader/plugins/legacy.plugin" \
        "$case_root/home/root/apps/koreader/patches" \
        "$case_root/home/root/apps/koreader/cache" \
        "$case_root/home/root/apps/koreader/ota"
    mkdir -p "$case_root/home/root/.local/share/remagic-koreader/data/history"
    printf 'renamed layout should migrate\n' \
        >"$case_root/home/root/.local/share/remagic-koreader/data/history/renamed.lua"
    printf 'do not migrate plugin\n' >"$case_root/home/root/apps/koreader/plugins/legacy.plugin/main.lua"
    printf 'do not migrate patch\n' >"$case_root/home/root/apps/koreader/patches/0-legacy.lua"
    printf 'do not migrate cache\n' >"$case_root/home/root/apps/koreader/cache/item"
    printf 'do not migrate ota\n' >"$case_root/home/root/apps/koreader/ota/item"
    printf 'clipboard should migrate\n' >"$case_root/home/root/apps/koreader/clipboard/history.lua"
    make_db "$case_root/home/root/apps/koreader/settings/statistics.sqlite3"
    printf '/usr/bin/unrelated\000--serve\000' >"$case_root/proc/101/cmdline"
    mkdir -p "$case_root/home/root/.local/state/koreader-for-remagic"
    : >"$case_root/home/root/.local/state/koreader-for-remagic/install.lock"
    chmod 0600 "$case_root/home/root/.local/state/koreader-for-remagic/install.lock"

    if [ "$mode" = existing ]; then
        mkdir -p \
            "$case_root/home/root/.local/share/koreader-for-remagic/data/settings"
        printf 'existing app root\n' >"$case_root/home/root/apps/koreader-for-remagic/old-only"
        printf 'current data\n' >"$case_root/home/root/.local/share/koreader-for-remagic/data/current-only"
        make_db "$case_root/home/root/.local/share/koreader-for-remagic/data/settings/statistics.sqlite3"
    fi
}

run_installer() {
    case_root=$1
    shift
    REMAGIC_INSTALL_TEST_MODE=1 \
    REMAGIC_INSTALL_TEST_ROOT=$case_root \
    REMAGIC_INSTALL_TEST_SKIP_SYNC=1 \
        "$@" "$INSTALLER"
}

assert_installed() {
    case_root=$1
    releases=$case_root/home/root/apps/koreader-for-remagic/adapter/releases
    [ -d "$releases" ] || fail "adapter release directory was not installed"
    adapter=$(find "$releases" -mindepth 1 -maxdepth 1 -type d -name 'standalone-*' -print)
    [ "$(printf '%s\n' "$adapter" | sed '/^$/d' | wc -l)" -eq 1 ] || fail "adapter release is not unique"
    data=$case_root/home/root/.local/share/koreader-for-remagic/data
    [ -x "$adapter/bin/koreader-for-remagic" ] || fail "adapter wrapper was not installed"
    [ -x "$adapter/libexec/koreader-data-migrate" ] || fail "migrator was not installed"
    [ -d "$adapter/share/fonts" ] || fail "adapter font asset directory was not installed"
    for patch in 10-remagic-environment.lua 20-remagic-collection-migration.lua \
            20-remagic-policy.lua \
            21-remagic-lifecycle-v2.lua 22-remagic-library-collection.lua; do
        [ -f "$adapter/share/patches/$patch" ] || fail "platform patch was not installed: $patch"
    done
    for module in remagic-lifecycle-protocol.lua remagic-open-path.lua; do
        [ -f "$adapter/libexec/$module" ] || fail "lifecycle module was not installed: $module"
        [ "$(stat -c %a "$adapter/libexec/$module")" = 644 ] || fail "unsafe lifecycle module mode: $module"
    done
    [ "$(stat -c %a "$adapter/bin/koreader-for-remagic")" = 755 ] || fail "wrapper mode is not 0755"
    [ "$(stat -c %a "$adapter/share/patches/21-remagic-lifecycle-v2.lua")" = 644 ] || fail "patch mode is not 0644"
    [ "$(stat -c %u:%g "$adapter")" = "$(id -u):$(id -g)" ] || fail "adapter owner is not explicit"
    [ -f "$data/clipboard/history.lua" ] || fail "allowed legacy clipboard was not migrated"
    [ -f "$data/history/renamed.lua" ] || fail "previous project-name data was not migrated"
    [ ! -e "$data/plugins" ] || fail "legacy plugins were migrated"
    [ ! -e "$data/patches" ] || fail "legacy patches were migrated"
    [ ! -e "$data/cache" ] || fail "legacy cache was migrated"
    [ ! -e "$data/ota" ] || fail "legacy OTA state was migrated"
    [ ! -e "$case_root/home/root/apps/.koreader-for-remagic.install-transaction" ] || fail "committed journal was not cleaned"
    [ ! -e "$case_root/home/root/.local/share/koreader-for-remagic/.data.install-new" ] || fail "data stage was not cleaned"
    [ ! -e "$case_root/home/root/.local/share/koreader-for-remagic/.data.install-old" ] || fail "data rollback tree was not cleaned"
}

case_root=$TMPDIR_TEST/case
stages='transaction_created prepared migration_started migration_complete adapter_switching adapter_old_saved adapter_published data_switching data_old_saved data_published committed backup_staged backup_published journal_retired'

for mode in existing absent; do
    for stage in $stages; do
        prepare_case "$mode" "$case_root"
        tree_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"
        tree_fingerprint "$case_root$VENDOR_DIR" "$TMPDIR_TEST/program-baseline"

        set +e
        run_installer "$case_root" env REMAGIC_INSTALL_TEST_CRASH_AT=$stage \
            >"$TMPDIR_TEST/crash.log" 2>&1
        crash_status=$?
        set -e
        if [ "$crash_status" -ne 97 ]; then
            cat "$TMPDIR_TEST/crash.log" >&2 || true
            fail "$mode crash at $stage returned $crash_status"
        fi

        run_installer "$case_root" env REMAGIC_INSTALL_TEST_RECOVER_ONLY=1 \
            >"$TMPDIR_TEST/recover.log" 2>&1 || fail "$mode recovery failed at $stage"
        same_fingerprint "$case_root$VENDOR_DIR" "$TMPDIR_TEST/program-baseline"

        case "$stage" in
        committed|backup_staged|backup_published|journal_retired)
            assert_installed "$case_root"
            tree_fingerprint "$case_root/home" "$TMPDIR_TEST/recovered"
            run_installer "$case_root" env REMAGIC_INSTALL_TEST_RECOVER_ONLY=1 >/dev/null
            same_fingerprint "$case_root/home" "$TMPDIR_TEST/recovered"
            ;;
        *)
            same_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"
            run_installer "$case_root" env REMAGIC_INSTALL_TEST_RECOVER_ONLY=1 >/dev/null
            same_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"
            ;;
        esac
    done
done

# A committed journal never discards rollback copies until the installed
# adapter still matches the manifest written before publication.
prepare_case absent "$case_root"
run_installer "$case_root" env >/dev/null
tree_fingerprint "$case_root$VENDOR_DIR" "$TMPDIR_TEST/program-baseline"
set +e
run_installer "$case_root" env REMAGIC_INSTALL_TEST_CRASH_AT=committed >/dev/null 2>&1
manifest_crash_status=$?
set -e
[ "$manifest_crash_status" -eq 97 ] || fail "manifest-integrity setup did not stop at committed"
adapter=$(find "$case_root/home/root/apps/koreader-for-remagic/adapter/releases" \
    -mindepth 1 -maxdepth 1 -type d -name 'standalone-*' -print -quit)
printf 'corrupted after commit\n' >"$adapter/bin/koreader-for-remagic"
set +e
run_installer "$case_root" env REMAGIC_INSTALL_TEST_RECOVER_ONLY=1 \
    >"$TMPDIR_TEST/checksum.log" 2>&1
checksum_status=$?
set -e
[ "$checksum_status" -ne 0 ] || fail "committed recovery accepted a corrupted adapter"
grep -q 'checksum verification failed' "$TMPDIR_TEST/checksum.log" || fail "checksum refusal was not explicit"
[ -d "$case_root/home/root/apps/.koreader-for-remagic.install-transaction/adapter-old" ] || \
    fail "checksum refusal discarded adapter rollback data"
cp "$ROOT/scripts/koreader-for-remagic" "$adapter/bin/koreader-for-remagic"
chmod 0755 "$adapter/bin/koreader-for-remagic"
run_installer "$case_root" env REMAGIC_INSTALL_TEST_RECOVER_ONLY=1 >/dev/null
assert_installed "$case_root"
same_fingerprint "$case_root$VENDOR_DIR" "$TMPDIR_TEST/program-baseline"

# A normal install migrates through a staged data tree and leaves the upstream
# program tree byte-for-byte unchanged.
prepare_case absent "$case_root"
tree_fingerprint "$case_root$VENDOR_DIR" "$TMPDIR_TEST/program-baseline"
run_installer "$case_root" env >"$TMPDIR_TEST/install.log" 2>&1 || fail "normal install failed"
assert_installed "$case_root"
same_fingerprint "$case_root$VENDOR_DIR" "$TMPDIR_TEST/program-baseline"
find "$case_root/home/root/.local/state/koreader-for-remagic/backups" \
    -name .remagic-installer-transaction -type f | grep -q . || fail "migration backup was not preserved"

# Graceful failure after publication must restore both trees immediately.
prepare_case existing "$case_root"
tree_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"
set +e
run_installer "$case_root" env REMAGIC_INSTALL_TEST_FAIL_AT=adapter_published \
    >"$TMPDIR_TEST/failure.log" 2>&1
failure_status=$?
set -e
[ "$failure_status" -eq 96 ] || fail "graceful injected failure returned $failure_status"
same_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"

# A second power loss while retiring a rolled-back journal leaves only a
# garbage directory; the next recovery removes it without touching targets.
prepare_case existing "$case_root"
tree_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"
set +e
run_installer "$case_root" env \
    REMAGIC_INSTALL_TEST_FAIL_AT=adapter_published \
    REMAGIC_INSTALL_TEST_CRASH_AT=rollback_restored \
    >"$TMPDIR_TEST/rollback-restored.log" 2>&1
restored_status=$?
set -e
[ "$restored_status" -eq 97 ] || fail "rollback-restored crash returned $restored_status"
[ -d "$case_root/home/root/apps/.koreader-for-remagic.install-transaction" ] || \
    fail "durable rollback retired its journal before the retirement barrier"
[ ! -e "$case_root/home/root/apps/.koreader-for-remagic.install-garbage" ] || \
    fail "durable rollback published garbage before the retirement barrier"
run_installer "$case_root" env REMAGIC_INSTALL_TEST_RECOVER_ONLY=1 >/dev/null
same_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"

# A second power loss after retiring a rolled-back journal leaves only a
# garbage directory; the next recovery removes it without touching targets.
prepare_case existing "$case_root"
tree_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"
set +e
run_installer "$case_root" env \
    REMAGIC_INSTALL_TEST_FAIL_AT=adapter_published \
    REMAGIC_INSTALL_TEST_CRASH_AT=rollback_retired \
    >"$TMPDIR_TEST/rollback-retired.log" 2>&1
retired_status=$?
set -e
[ "$retired_status" -eq 97 ] || fail "rollback-retired crash returned $retired_status"
[ -d "$case_root/home/root/apps/.koreader-for-remagic.install-garbage" ] || fail "retired rollback journal was not retained"
run_installer "$case_root" env REMAGIC_INSTALL_TEST_RECOVER_ONLY=1 >/dev/null
same_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"

# A partial preparing directory contains no published state and is safe to
# discard idempotently after the read-only live-process check.
prepare_case existing "$case_root"
tree_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"
mkdir "$case_root/home/root/apps/.koreader-for-remagic.install-preparing"
printf 'partial journal\n' >"$case_root/home/root/apps/.koreader-for-remagic.install-preparing/pid"
run_installer "$case_root" env REMAGIC_INSTALL_TEST_RECOVER_ONLY=1 >/dev/null
same_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"

# A running wrapper holds the install inode shared for its entire lifetime.
# The installer's exclusive transaction lock must reject it even if a process
# table scan races or cannot yet identify the just-starting reader.
prepare_case existing "$case_root"
tree_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"
shared_lock=$case_root/home/root/.local/state/koreader-for-remagic/install.lock
exec 7>>"$shared_lock"
flock -s 7
set +e
run_installer "$case_root" env >"$TMPDIR_TEST/shared-lock.log" 2>&1
shared_lock_status=$?
set -e
flock -u 7
exec 7>&-
[ "$shared_lock_status" -ne 0 ] || fail "installer entered a transaction while runtime held the shared lock"
grep -q 'KOReader is starting/running' "$TMPDIR_TEST/shared-lock.log" || \
    fail "runtime-lock refusal was not explicit"
same_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"

# The live-process guard runs before journal creation or any target mutation.
prepare_case existing "$case_root"
rm "$case_root/home/root/.local/state/koreader-for-remagic/install.lock"
mkdir -p "$case_root/proc/222"
printf '%s\000%s\000' \
    "$case_root$VENDOR_DIR/reader.lua" \
    "$case_root/home/root/books/a.epub" >"$case_root/proc/222/cmdline"
tree_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"
set +e
run_installer "$case_root" env >"$TMPDIR_TEST/live.log" 2>&1
live_status=$?
set -e
[ "$live_status" -eq 1 ] || fail "live KOReader did not block install"
grep -q 'PID: 222' "$TMPDIR_TEST/live.log" || fail "live refusal omitted PID"
same_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"

# Existing Manager releases are immutable siblings. A standalone release must
# be installed beside them without replacing or deleting their content.
prepare_case existing "$case_root"
manager_release=$case_root/home/root/apps/koreader-for-remagic/adapter/releases/manager-release
mkdir -p "$manager_release"
printf 'manager-owned adapter\n' >"$manager_release/sentinel"
tree_fingerprint "$manager_release" "$TMPDIR_TEST/manager-release-baseline"
run_installer "$case_root" env >/dev/null
same_fingerprint "$manager_release" "$TMPDIR_TEST/manager-release-baseline"
assert_installed "$case_root"

# Test hooks are fail-closed unless the explicit marker and test mode agree.
prepare_case existing "$case_root"
tree_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"
set +e
REMAGIC_INSTALL_TEST_ROOT=$case_root "$INSTALLER" >"$TMPDIR_TEST/fail-closed.log" 2>&1
hook_status=$?
set -e
[ "$hook_status" -ne 0 ] || fail "production mode accepted a test root"
grep -q 'test root is forbidden' "$TMPDIR_TEST/fail-closed.log" || fail "test-root refusal was not explicit"
same_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"

rm "$case_root/.koreader-for-remagic-installer-test-root"
set +e
REMAGIC_INSTALL_TEST_MODE=1 REMAGIC_INSTALL_TEST_ROOT=$case_root "$INSTALLER" \
    >"$TMPDIR_TEST/marker.log" 2>&1
marker_status=$?
set -e
[ "$marker_status" -ne 0 ] || fail "test mode accepted a root without its opt-in marker"
same_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"

# Symlink and special-file targets are rejected without following or replacing
# them. These are separate cases because the preflight must remain read-only.
prepare_case existing "$case_root"
rm -rf "$case_root/home/root/apps/koreader-for-remagic"
ln -s koreader "$case_root/home/root/apps/koreader-for-remagic"
tree_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"
set +e
run_installer "$case_root" env >"$TMPDIR_TEST/symlink.log" 2>&1
symlink_status=$?
set -e
[ "$symlink_status" -ne 0 ] || fail "adapter symlink target was accepted"
same_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"

prepare_case existing "$case_root"
rm -rf "$case_root/home/root/.local/share/koreader-for-remagic/data"
mkfifo "$case_root/home/root/.local/share/koreader-for-remagic/data"
tree_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"
set +e
run_installer "$case_root" env >"$TMPDIR_TEST/special.log" 2>&1
special_status=$?
set -e
[ "$special_status" -ne 0 ] || fail "special data target was accepted"
same_fingerprint "$case_root/home" "$TMPDIR_TEST/baseline"

echo "transactional standalone installer fault-injection tests passed"
