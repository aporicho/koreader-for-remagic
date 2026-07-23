#!/bin/sh
set -eu

# Standalone transactional installer for the KOReader for ReMagic.  This
# script deliberately does not install or modify KOReader itself.  A complete
# The official KOReader vendor tree must already exist at KOREADER_DIR. This
# installer publishes only a content-addressed adapter release and writable
# data; it never modifies the vendor tree.

die() {
    echo "KOReader install: $*" >&2
    exit 1
}

path_exists() {
    [ -e "$1" ] || [ -L "$1" ]
}

require_real_dir() {
    [ -d "$1" ] && [ ! -L "$1" ] || die "directory is missing, a symlink, or not a directory: $1"
}

require_regular_file() {
    [ -f "$1" ] && [ ! -L "$1" ] || die "source is missing, a symlink, or not a regular file: $1"
    [ -r "$1" ] || die "source is not readable: $1"
}

remove_owned_tree() {
    path=$1
    path_exists "$path" || return 0
    [ -d "$path" ] && [ ! -L "$path" ] || die "refusing to remove unexpected path: $path"
    rm -rf "$path"
}

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_MODE=${REMAGIC_INSTALL_TEST_MODE:-0}
KOREADER_DIR_OVERRIDE=${KOREADER_DIR:-}

case "$TEST_MODE" in
    0)
        [ -z "${REMAGIC_INSTALL_TEST_ROOT:-}" ] || die "test root is forbidden in production mode"
        [ -z "${REMAGIC_INSTALL_TEST_CRASH_AT:-}" ] || die "fault injection is forbidden in production mode"
        [ -z "${REMAGIC_INSTALL_TEST_FAIL_AT:-}" ] || die "fault injection is forbidden in production mode"
        [ -z "${REMAGIC_INSTALL_TEST_RECOVER_ONLY:-}" ] || die "test recovery mode is forbidden in production mode"
        [ -z "${REMAGIC_INSTALL_TEST_SKIP_SYNC:-}" ] || die "test sync override is forbidden in production mode"
        [ "$(id -u)" -eq 0 ] || die "run as root"
        PREFIX=
        INSTALL_UID=0
        INSTALL_GID=0
        ;;
    1)
        PREFIX=${REMAGIC_INSTALL_TEST_ROOT:-}
        [ -n "$PREFIX" ] || die "test mode requires REMAGIC_INSTALL_TEST_ROOT"
        case "$PREFIX" in /*) ;; *) die "test root must be an absolute path" ;; esac
        [ "$PREFIX" != / ] || die "test root must not be /"
        [ -d "$PREFIX" ] && [ ! -L "$PREFIX" ] || die "test root must be a real directory"
        canonical_prefix=$(CDPATH='' cd -- "$PREFIX" && pwd -P)
        [ "$canonical_prefix" = "$PREFIX" ] || die "test root must be canonical and contain no symlink at its leaf"
        marker=$PREFIX/.koreader-for-remagic-installer-test-root
        [ -f "$marker" ] && [ ! -L "$marker" ] || die "test root opt-in marker is missing"
        [ "$(sed -n '1p' "$marker")" = koreader-for-remagic-installer-test-root-v1 ] || \
            die "test root opt-in marker is invalid"
        INSTALL_UID=$(id -u)
        INSTALL_GID=$(id -g)
        ;;
    *) die "REMAGIC_INSTALL_TEST_MODE must be 0 or 1" ;;
esac

APPS_DIR=$PREFIX/home/root/apps
APP_ROOT=$APPS_DIR/koreader-for-remagic
ADAPTER_ROOT=$APP_ROOT/adapter
ADAPTER_RELEASES_DIR=$ADAPTER_ROOT/releases
ADAPTER_RELEASE_HASH=$(
    cd "$ROOT"
    digest_input=$(mktemp /tmp/koreader-for-remagic-standalone-digest.XXXXXX) || exit 1
    trap 'rm -f "$digest_input"' 0 HUP INT TERM
    for release_input in \
        scripts/koreader-for-remagic \
        scripts/koreader-data-migrate \
        scripts/koreader-db-inspect \
        scripts/koreader-db-inspect.lua \
        scripts/koreader-library-sync \
        scripts/koreader-library-index.lua \
        scripts/remagic-library-collection.lua \
        scripts/koreader-not-running \
        scripts/koreader-sync-state \
        scripts/koreader-sync-state.lua \
        scripts/remagic-lifecycle-protocol.lua \
        scripts/remagic-open-path.lua \
        patches/10-remagic-environment.lua \
        patches/20-remagic-policy.lua \
        patches/21-remagic-lifecycle-v2.lua \
        patches/22-remagic-library-collection.lua
    do
        sha256sum "$release_input" >>"$digest_input" || exit 1
    done
    digest_line=$(sha256sum "$digest_input") || exit 1
    printf '%s\n' "${digest_line%% *}"
) || die "could not calculate the standalone adapter release digest"
[ "${#ADAPTER_RELEASE_HASH}" -eq 64 ] || die "standalone adapter release digest is invalid"
ADAPTER_RELEASE_ID=standalone-$ADAPTER_RELEASE_HASH
ADAPTER_DIR=$ADAPTER_RELEASES_DIR/$ADAPTER_RELEASE_ID
if [ "$TEST_MODE" -eq 0 ] && [ -n "$KOREADER_DIR_OVERRIDE" ]; then
    case "$KOREADER_DIR_OVERRIDE" in /*) ;; *) die "KOREADER_DIR must be absolute" ;; esac
    KOREADER_DIR=$KOREADER_DIR_OVERRIDE
else
    [ -z "$KOREADER_DIR_OVERRIDE" ] || die "KOREADER_DIR override is forbidden in installer test mode"
    KOREADER_DIR=$APP_ROOT/vendor/releases/v2026.03-56621d5ee66ad94f4f3e2e6d204e8c34be730343f915edc36bb076a043a2e468/koreader
fi
DATA_PARENT=$PREFIX/home/root/.local/share/koreader-for-remagic
DATA_DIR=$DATA_PARENT/data
DATA_STAGE=$DATA_PARENT/.data.install-new
DATA_OLD=$DATA_PARENT/.data.install-old
STATE_PARENT=$PREFIX/home/root/.local/state/koreader-for-remagic
BACKUP_ROOT=$STATE_PARENT/backups
TXN_DIR=$APPS_DIR/.koreader-for-remagic.install-transaction
TXN_PREP=$APPS_DIR/.koreader-for-remagic.install-preparing
TXN_GC=$APPS_DIR/.koreader-for-remagic.install-garbage
LOCK_FILE=$STATE_PARENT/install.lock
TXN_STATE=$TXN_DIR/state
ADAPTER_STAGE=$TXN_DIR/adapter-new
ADAPTER_OLD=$TXN_DIR/adapter-old

SYNC_ENABLED=1
if [ "$TEST_MODE" -eq 1 ] && [ "${REMAGIC_INSTALL_TEST_SKIP_SYNC:-0}" = 1 ]; then
    SYNC_ENABLED=0
fi

sync_filesystems() {
    [ "$SYNC_ENABLED" -eq 0 ] || sync
}

write_state() {
    state=$1
    state_tmp=$TXN_DIR/.state.$$
    printf '%s\n' "$state" >"$state_tmp"
    chmod 0600 "$state_tmp"
    mv -f "$state_tmp" "$TXN_STATE"
    sync_filesystems
}

test_hook() {
    stage=$1
    [ "$TEST_MODE" -eq 1 ] || return 0
    if [ "${REMAGIC_INSTALL_TEST_CRASH_AT:-}" = "$stage" ]; then
        echo "KOReader install: simulated power loss at $stage" >&2
        trap - EXIT HUP INT TERM
        exit 97
    fi
    if [ "${REMAGIC_INSTALL_TEST_FAIL_AT:-}" = "$stage" ]; then
        echo "KOReader install: simulated failure at $stage" >&2
        return 96
    fi
}

preflight_commands_and_sources() {
    for command_name in awk chmod chown cmp cp date find flock grep id mkdir mv rm sed sha256sum sort stat sync tr wc; do
        command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
    done

    for source_path in \
        "$ROOT/scripts/koreader-for-remagic" \
        "$ROOT/scripts/koreader-data-migrate" \
        "$ROOT/scripts/koreader-db-inspect" \
        "$ROOT/scripts/koreader-db-inspect.lua" \
        "$ROOT/scripts/koreader-library-sync" \
        "$ROOT/scripts/koreader-library-index.lua" \
        "$ROOT/scripts/remagic-library-collection.lua" \
        "$ROOT/scripts/koreader-not-running" \
        "$ROOT/scripts/koreader-sync-state" \
        "$ROOT/scripts/koreader-sync-state.lua" \
        "$ROOT/scripts/remagic-lifecycle-protocol.lua" \
        "$ROOT/scripts/remagic-open-path.lua" \
        "$ROOT/patches/10-remagic-environment.lua" \
        "$ROOT/patches/20-remagic-policy.lua" \
        "$ROOT/patches/21-remagic-lifecycle-v2.lua" \
        "$ROOT/patches/22-remagic-library-collection.lua"
    do
        require_regular_file "$source_path"
    done
    for executable_path in \
        "$ROOT/scripts/koreader-for-remagic" \
        "$ROOT/scripts/koreader-data-migrate" \
        "$ROOT/scripts/koreader-db-inspect" \
        "$ROOT/scripts/koreader-library-sync" \
        "$ROOT/scripts/koreader-not-running" \
        "$ROOT/scripts/koreader-sync-state"
    do
        [ -x "$executable_path" ] || die "source is not executable: $executable_path"
    done
}

preflight_targets() {
    require_real_dir "$APPS_DIR"
    require_real_dir "$KOREADER_DIR"
    canonical_koreader=$(CDPATH='' cd -- "$KOREADER_DIR" && pwd -P)
    [ "$canonical_koreader" = "$KOREADER_DIR" ] || die "KOREADER_DIR must be canonical and not traverse symlinks"
    reader=$KOREADER_DIR/reader.lua
    [ -f "$reader" ] && [ ! -L "$reader" ] && [ -x "$reader" ] || \
        die "existing KOReader reader.lua is missing, a symlink, or not executable: $reader"

    for adapter_parent in "$APP_ROOT" "$ADAPTER_ROOT" "$ADAPTER_RELEASES_DIR"; do
        if path_exists "$adapter_parent"; then require_real_dir "$adapter_parent"; fi
    done
    if path_exists "$ADAPTER_DIR"; then require_real_dir "$ADAPTER_DIR"; fi
    if path_exists "$DATA_PARENT"; then
        require_real_dir "$DATA_PARENT"
    else
        require_real_dir "$PREFIX/home/root/.local/share"
    fi
    if path_exists "$DATA_DIR"; then
        require_real_dir "$DATA_DIR"
    fi
    for reserved_path in "$DATA_STAGE" "$DATA_OLD"; do
        if path_exists "$reserved_path"; then
            [ -d "$reserved_path" ] && [ ! -L "$reserved_path" ] || \
                die "reserved transaction path is a symlink or special file: $reserved_path"
            [ -d "$TXN_DIR" ] && [ ! -L "$TXN_DIR" ] || \
                die "orphan reserved transaction path has no valid journal: $reserved_path"
        fi
    done
    if path_exists "$TXN_DIR"; then
        require_real_dir "$TXN_DIR"
    fi
    for installer_path in "$TXN_PREP" "$TXN_GC"; do
        if path_exists "$installer_path"; then
            [ -d "$installer_path" ] && [ ! -L "$installer_path" ] || \
                die "reserved installer path is a symlink or special file: $installer_path"
            [ "$(stat -c '%u:%g' "$installer_path")" = "$INSTALL_UID:$INSTALL_GID" ] || \
                die "reserved installer path has unexpected owner: $installer_path"
        fi
    done
    if path_exists "$LOCK_FILE"; then
        [ -f "$LOCK_FILE" ] && [ ! -L "$LOCK_FILE" ] || die "installer lock is a symlink or special file"
        [ "$(stat -c %h "$LOCK_FILE")" -eq 1 ] || die "installer lock must not be a hard link"
        lock_owner=$(stat -c '%u:%g' "$LOCK_FILE")
        [ "$lock_owner" = "$INSTALL_UID:$INSTALL_GID" ] || die "installer lock has unexpected owner"
    fi
}

ensure_adapter_release_parent() {
    for adapter_parent in "$APP_ROOT" "$ADAPTER_ROOT" "$ADAPTER_RELEASES_DIR"; do
        if path_exists "$adapter_parent"; then
            require_real_dir "$adapter_parent"
        else
            mkdir "$adapter_parent"
            chmod 0755 "$adapter_parent"
            set_installed_owner "$adapter_parent"
        fi
    done
}

remove_empty_adapter_parents() {
    rmdir "$ADAPTER_RELEASES_DIR" 2>/dev/null || true
    rmdir "$ADAPTER_ROOT" 2>/dev/null || true
    rmdir "$APP_ROOT" 2>/dev/null || true
}

run_not_running_check() {
    proc_root=$PREFIX/proc
    [ "$TEST_MODE" -eq 0 ] && proc_root=/proc
    KOREADER_PROC_ROOT=$proc_root \
    KOREADER_DIR=$KOREADER_DIR \
    KOREADER_ADAPTER_EXEC=$ADAPTER_DIR/bin/koreader-for-remagic \
        "$ROOT/scripts/koreader-not-running"
}

validate_transaction() {
    require_real_dir "$TXN_DIR"
    transaction_owner=$(stat -c '%u:%g' "$TXN_DIR")
    [ "$transaction_owner" = "$INSTALL_UID:$INSTALL_GID" ] || die "transaction directory has unexpected owner"
    [ -f "$TXN_STATE" ] && [ ! -L "$TXN_STATE" ] || die "transaction journal has no regular state file"
    [ "$(stat -c '%u:%g' "$TXN_STATE")" = "$INSTALL_UID:$INSTALL_GID" ] || \
        die "transaction state has unexpected owner"
    state=$(sed -n '1p' "$TXN_STATE")
    case "$state" in
        transaction_created|prepared|migration_started|migration_complete|adapter_switching|adapter_old_saved|adapter_published|data_switching|data_old_saved|data_published|rolling_back|committed) ;;
        *) die "transaction journal has invalid state: $state" ;;
    esac
    for marker_name in adapter-original adapter.sha256 data-original migration-backups transaction-id pid; do
        marker_path=$TXN_DIR/$marker_name
        [ -f "$marker_path" ] && [ ! -L "$marker_path" ] || \
            die "transaction journal is missing a regular $marker_name marker"
        marker_owner=$(stat -c '%u:%g' "$marker_path")
        [ "$marker_owner" = "$INSTALL_UID:$INSTALL_GID" ] || die "transaction marker has unexpected owner: $marker_path"
    done
    for original_marker in adapter-original data-original; do
        marker_value=$(sed -n '1p' "$TXN_DIR/$original_marker")
        case "$marker_value" in present|absent) ;; *) die "invalid $original_marker marker" ;; esac
    done
    backup_marker=$(sed -n '1p' "$TXN_DIR/migration-backups")
    case "$backup_marker" in unknown|present|absent) ;; *) die "invalid migration-backups marker" ;; esac
}

restore_tree() {
    target=$1
    backup=$2
    original=$3
    label=$4
    if path_exists "$backup"; then
        [ -d "$backup" ] && [ ! -L "$backup" ] || die "$label rollback backup is unsafe: $backup"
        if path_exists "$target"; then
            remove_owned_tree "$target"
        fi
        mv "$backup" "$target"
    elif [ "$original" = absent ]; then
        remove_owned_tree "$target"
    elif ! path_exists "$target"; then
        die "$label original and rollback backup are both missing"
    else
        require_real_dir "$target"
    fi
}

rollback_transaction() {
    validate_transaction
    rollback_state=$(sed -n '1p' "$TXN_STATE")
    adapter_original=$(sed -n '1p' "$TXN_DIR/adapter-original")
    data_original=$(sed -n '1p' "$TXN_DIR/data-original")
    if [ "$rollback_state" != rolling_back ] && [ "$adapter_original" = present ]; then
        case "$rollback_state" in
            adapter_old_saved|adapter_published|data_switching|data_old_saved|data_published)
                path_exists "$ADAPTER_OLD" || die "adapter rollback backup is missing for state $rollback_state"
                ;;
        esac
    fi
    if [ "$rollback_state" != rolling_back ] && [ "$data_original" = present ]; then
        case "$rollback_state" in
            data_old_saved|data_published)
                path_exists "$DATA_OLD" || die "data rollback backup is missing for state $rollback_state"
                ;;
        esac
    fi
    if [ "$rollback_state" != rolling_back ]; then
        # Once this durable state is visible, either rollback copy may already
        # have been consumed by an earlier recovery attempt. restore_tree is
        # deliberately idempotent for both the pre- and post-restore shapes.
        write_state rolling_back
    fi
    restore_tree "$DATA_DIR" "$DATA_OLD" "$data_original" data
    restore_tree "$ADAPTER_DIR" "$ADAPTER_OLD" "$adapter_original" adapter
    remove_owned_tree "$DATA_STAGE"
    remove_owned_tree "$ADAPTER_STAGE"
    remove_empty_adapter_parents
    # The restored trees must be durable while the replayable journal still
    # exists. Only then may recovery retire its final source of truth.
    sync_filesystems
    test_hook rollback_restored
    path_exists "$TXN_GC" && die "installer garbage path already exists during rollback"
    mv "$TXN_DIR" "$TXN_GC"
    sync_filesystems
    test_hook rollback_retired
    rm -rf "$TXN_GC"
    if [ "$data_original" = absent ] && [ -d "$DATA_PARENT" ]; then
        rmdir "$DATA_PARENT" 2>/dev/null || true
    fi
}

finalize_committed_transaction() {
    validate_transaction
    [ "$(sed -n '1p' "$TXN_STATE")" = committed ] || die "cannot finalize an uncommitted transaction"
    require_real_dir "$ADAPTER_DIR"
    require_real_dir "$DATA_DIR"
    verify_installed_adapter
    backup_marker=$(sed -n '1p' "$TXN_DIR/migration-backups")
    [ "$backup_marker" != unknown ] || die "committed transaction has unresolved migration backup state"
    transaction_id=$(sed -n '1p' "$TXN_DIR/transaction-id")
    case "$transaction_id" in ''|*[!A-Za-z0-9._-]*) die "transaction id contains unsafe characters" ;; esac
    migration_backups=$TXN_DIR/migration-backups-data
    backup_target=$BACKUP_ROOT/standalone-$transaction_id
    backup_stage=$BACKUP_ROOT/.standalone-$transaction_id.new
    if [ "$backup_marker" = present ]; then
        if path_exists "$migration_backups"; then
            require_real_dir "$migration_backups"
            backup_identity=$migration_backups/.remagic-installer-transaction
            [ -f "$backup_identity" ] && [ ! -L "$backup_identity" ] && \
                [ "$(sed -n '1p' "$backup_identity")" = "$transaction_id" ] || \
                die "migration backup identity is missing or invalid"
            ensure_state_parent
            if path_exists "$BACKUP_ROOT"; then require_real_dir "$BACKUP_ROOT"; else
                mkdir "$BACKUP_ROOT"
                chmod 0700 "$BACKUP_ROOT"
                set_installed_owner "$BACKUP_ROOT"
            fi
            if path_exists "$backup_target"; then
                require_real_dir "$backup_target"
                backup_identity=$backup_target/.remagic-installer-transaction
                [ -f "$backup_identity" ] && [ ! -L "$backup_identity" ] && \
                    [ "$(sed -n '1p' "$backup_identity")" = "$transaction_id" ] || \
                    die "existing migration backup target has another identity"
            else
                remove_owned_tree "$backup_stage"
                cp -a "$migration_backups" "$backup_stage"
                backup_identity=$backup_stage/.remagic-installer-transaction
                [ -f "$backup_identity" ] && [ ! -L "$backup_identity" ] && \
                    [ "$(sed -n '1p' "$backup_identity")" = "$transaction_id" ] || \
                    die "staged migration backup verification failed"
                sync_filesystems
                test_hook backup_staged
                mv "$backup_stage" "$backup_target"
                sync_filesystems
                test_hook backup_published
            fi
        else
            require_real_dir "$backup_target"
            backup_identity=$backup_target/.remagic-installer-transaction
            [ -f "$backup_identity" ] && [ ! -L "$backup_identity" ] && \
                [ "$(sed -n '1p' "$backup_identity")" = "$transaction_id" ] || \
                die "published migration backup identity is missing or invalid"
        fi
    else
        remove_owned_tree "$migration_backups"
    fi
    remove_owned_tree "$ADAPTER_OLD"
    remove_owned_tree "$DATA_OLD"
    remove_owned_tree "$DATA_STAGE"
    remove_owned_tree "$ADAPTER_STAGE"
    path_exists "$TXN_GC" && die "installer garbage path already exists during finalization"
    mv "$TXN_DIR" "$TXN_GC"
    sync_filesystems
    test_hook journal_retired
    rm -rf "$TXN_GC"
}

recover_or_refuse_transaction() {
    remove_owned_tree "$TXN_GC"
    # A preparing tree contains no published path. It can only remain when
    # power failed before the complete journal was atomically renamed.
    remove_owned_tree "$TXN_PREP"
    if ! path_exists "$TXN_DIR"; then
        path_exists "$DATA_STAGE" && die "data staging tree exists without a transaction journal"
        path_exists "$DATA_OLD" && die "data rollback tree exists without a transaction journal"
        return 0
    fi
    validate_transaction
    owner_pid=$(sed -n '1p' "$TXN_DIR/pid")
    case "$owner_pid" in ''|*[!0-9]*|0|1) die "transaction journal has invalid owner PID" ;; esac
    # The exclusive flock is authoritative. Do not use kill -0 here: after a
    # reboot the stale PID may already belong to an unrelated process.
    state=$(sed -n '1p' "$TXN_STATE")
    if [ "$state" = committed ]; then
        echo "Finalizing committed KOReader adapter transaction." >&2
        finalize_committed_transaction
    else
        echo "Rolling back interrupted KOReader adapter transaction (state=$state)." >&2
        rollback_transaction
    fi
}

set_installed_owner() {
    target=$1
    if [ "$TEST_MODE" -eq 0 ]; then
        chown "$INSTALL_UID:$INSTALL_GID" "$target"
    else
        actual_owner=$(stat -c '%u:%g' "$target")
        [ "$actual_owner" = "$INSTALL_UID:$INSTALL_GID" ] || die "test artifact owner mismatch: $target"
    fi
}

stage_file() {
    source=$1
    relative=$2
    mode=$3
    target=$ADAPTER_STAGE/$relative
    target_parent=${target%/*}
    mkdir -p "$target_parent"
    cp "$source" "$target"
    chmod "$mode" "$target"
    set_installed_owner "$target"
    cmp -s "$source" "$target" || die "staged file verification failed: $relative"
}

stage_adapter() {
    mkdir -p "$ADAPTER_STAGE/bin" "$ADAPTER_STAGE/libexec" \
        "$ADAPTER_STAGE/share/patches" "$ADAPTER_STAGE/share/fonts"
    chmod 0755 "$ADAPTER_STAGE" "$ADAPTER_STAGE/bin" "$ADAPTER_STAGE/libexec" \
        "$ADAPTER_STAGE/share" "$ADAPTER_STAGE/share/patches" "$ADAPTER_STAGE/share/fonts"
    for directory in "$ADAPTER_STAGE" "$ADAPTER_STAGE/bin" "$ADAPTER_STAGE/libexec" \
        "$ADAPTER_STAGE/share" "$ADAPTER_STAGE/share/patches" "$ADAPTER_STAGE/share/fonts"; do
        set_installed_owner "$directory"
    done
    stage_file "$ROOT/scripts/koreader-for-remagic" bin/koreader-for-remagic 0755
    stage_file "$ROOT/scripts/koreader-data-migrate" libexec/koreader-data-migrate 0755
    stage_file "$ROOT/scripts/koreader-db-inspect" libexec/koreader-db-inspect 0755
    stage_file "$ROOT/scripts/koreader-db-inspect.lua" libexec/koreader-db-inspect.lua 0644
    stage_file "$ROOT/scripts/koreader-library-sync" libexec/koreader-library-sync 0755
    stage_file "$ROOT/scripts/koreader-library-index.lua" libexec/koreader-library-index.lua 0644
    stage_file "$ROOT/scripts/koreader-not-running" libexec/koreader-not-running 0755
    stage_file "$ROOT/scripts/koreader-sync-state" libexec/koreader-sync-state 0755
    stage_file "$ROOT/scripts/koreader-sync-state.lua" libexec/koreader-sync-state.lua 0644
    for module in remagic-library-collection.lua remagic-lifecycle-protocol.lua remagic-open-path.lua; do
        stage_file "$ROOT/scripts/$module" "libexec/$module" 0644
    done
    for platform_patch in 10-remagic-environment.lua 20-remagic-policy.lua \
            21-remagic-lifecycle-v2.lua 22-remagic-library-collection.lua; do
        stage_file "$ROOT/patches/$platform_patch" "share/patches/$platform_patch" 0644
    done
    (
        cd "$ADAPTER_STAGE"
        find bin libexec share -type f ! -type l -print | LC_ALL=C sort | while IFS= read -r relative; do
            sha256sum "$relative"
        done
    ) >"$TXN_DIR/adapter.sha256"
    [ "$(wc -l <"$TXN_DIR/adapter.sha256")" -eq 16 ] || die "staged adapter manifest is incomplete"
    chmod 0600 "$TXN_DIR/adapter.sha256"
    set_installed_owner "$TXN_DIR/adapter.sha256"
}

verify_installed_file() {
    relative=$1
    mode=$2
    installed=$ADAPTER_DIR/$relative
    [ -f "$installed" ] && [ ! -L "$installed" ] || die "installed adapter file is unsafe: $relative"
    [ "$(stat -c %a "$installed")" = "$mode" ] || die "installed adapter mode is wrong: $relative"
    [ "$(stat -c '%u:%g' "$installed")" = "$INSTALL_UID:$INSTALL_GID" ] || \
        die "installed adapter owner is wrong: $relative"
}

verify_installed_adapter() {
    require_real_dir "$ADAPTER_DIR"
    for directory in "$ADAPTER_DIR" "$ADAPTER_DIR/bin" "$ADAPTER_DIR/libexec" \
        "$ADAPTER_DIR/share" "$ADAPTER_DIR/share/patches" "$ADAPTER_DIR/share/fonts"; do
        require_real_dir "$directory"
        [ "$(stat -c %a "$directory")" = 755 ] || die "installed adapter directory mode is wrong: $directory"
        [ "$(stat -c '%u:%g' "$directory")" = "$INSTALL_UID:$INSTALL_GID" ] || \
            die "installed adapter directory owner is wrong: $directory"
    done
    [ "$(wc -l <"$TXN_DIR/adapter.sha256")" -eq 16 ] || die "adapter manifest is incomplete"
    (cd "$ADAPTER_DIR" && sha256sum -c "$TXN_DIR/adapter.sha256" >/dev/null) || \
        die "installed adapter checksum verification failed"
    verify_installed_file bin/koreader-for-remagic 755
    verify_installed_file libexec/koreader-data-migrate 755
    verify_installed_file libexec/koreader-db-inspect 755
    verify_installed_file libexec/koreader-db-inspect.lua 644
    verify_installed_file libexec/koreader-library-sync 755
    verify_installed_file libexec/koreader-library-index.lua 644
    verify_installed_file libexec/koreader-not-running 755
    verify_installed_file libexec/koreader-sync-state 755
    verify_installed_file libexec/koreader-sync-state.lua 644
    for module in remagic-library-collection.lua remagic-lifecycle-protocol.lua remagic-open-path.lua; do
        verify_installed_file "libexec/$module" 644
    done
    for platform_patch in 10-remagic-environment.lua 20-remagic-policy.lua \
            21-remagic-lifecycle-v2.lua 22-remagic-library-collection.lua; do
        verify_installed_file "share/patches/$platform_patch" 644
    done
}

stage_and_migrate_data() {
    if ! path_exists "$DATA_PARENT"; then
        mkdir "$DATA_PARENT"
        chmod 0755 "$DATA_PARENT"
        set_installed_owner "$DATA_PARENT"
    fi
    mkdir "$DATA_STAGE"
    chmod 0755 "$DATA_STAGE"
    set_installed_owner "$DATA_STAGE"
    if [ "$(sed -n '1p' "$TXN_DIR/data-original")" = present ]; then
        cp -a "$DATA_DIR/." "$DATA_STAGE/"
    fi

    write_state migration_started
    test_hook migration_started
    legacy_dirs=$PREFIX/home/root/.local/share/remagic-koreader/data:$PREFIX/home/root/apps/koreader:$KOREADER_DIR:$PREFIX/home/root/.paperweight/services/koreader/koreader:$PREFIX/home/root/.config/koreader
    mkdir "$TXN_DIR/migration-backups-data"
    KOREADER_DIR=$KOREADER_DIR \
    KOREADER_DATA_DIR=$DATA_STAGE \
    KO_HOME=$DATA_STAGE \
    KOREADER_LEGACY_DATA_DIRS=$legacy_dirs \
    KOREADER_BACKUP_ROOT=$TXN_DIR/migration-backups-data \
    KOREADER_DB_INSPECTOR=$ADAPTER_STAGE/libexec/koreader-db-inspect \
        "$ADAPTER_STAGE/libexec/koreader-data-migrate"
    if find "$TXN_DIR/migration-backups-data" -mindepth 1 -print -quit | grep -q .; then
        printf '%s\n' present >"$TXN_DIR/migration-backups"
        sed -n '1p' "$TXN_DIR/transaction-id" >"$TXN_DIR/migration-backups-data/.remagic-installer-transaction"
        chmod 0600 "$TXN_DIR/migration-backups-data/.remagic-installer-transaction"
        set_installed_owner "$TXN_DIR/migration-backups-data/.remagic-installer-transaction"
    else
        printf '%s\n' absent >"$TXN_DIR/migration-backups"
    fi
    chmod 0600 "$TXN_DIR/migration-backups"
    write_state migration_complete
    test_hook migration_complete
}

transaction_active=0
transaction_exit() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ "$transaction_active" -eq 1 ] && [ -d "$TXN_DIR" ] && [ ! -L "$TXN_DIR" ]; then
        current_state=
        [ ! -f "$TXN_STATE" ] || current_state=$(sed -n '1p' "$TXN_STATE" 2>/dev/null || true)
        if [ "$current_state" = committed ]; then
            finalize_committed_transaction || true
        else
            rollback_transaction || true
        fi
    fi
    remove_owned_tree "$TXN_PREP" 2>/dev/null || true
    exit "$status"
}

begin_transaction() {
    umask 077
    mkdir "$TXN_PREP" || die "could not prepare installer transaction"
    transaction_active=1
    trap transaction_exit EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    transaction_id=$(date +%Y%m%d-%H%M%S 2>/dev/null || printf unknown)-$$
    printf '%s\n' "$$" >"$TXN_PREP/pid"
    printf '%s\n' "$transaction_id" >"$TXN_PREP/transaction-id"
    if path_exists "$ADAPTER_DIR"; then adapter_original=present; else adapter_original=absent; fi
    if path_exists "$DATA_DIR"; then data_original=present; else data_original=absent; fi
    printf '%s\n' "$adapter_original" >"$TXN_PREP/adapter-original"
    : >"$TXN_PREP/adapter.sha256"
    printf '%s\n' "$data_original" >"$TXN_PREP/data-original"
    printf '%s\n' unknown >"$TXN_PREP/migration-backups"
    printf '%s\n' transaction_created >"$TXN_PREP/state"
    chmod 0600 "$TXN_PREP/pid" "$TXN_PREP/transaction-id" "$TXN_PREP/adapter-original" "$TXN_PREP/adapter.sha256" "$TXN_PREP/data-original" "$TXN_PREP/migration-backups" "$TXN_PREP/state"
    sync_filesystems
    mv "$TXN_PREP" "$TXN_DIR"
    sync_filesystems
    test_hook transaction_created
}

acquire_install_lock() {
    exec 8>>"$LOCK_FILE"
    chmod 0600 "$LOCK_FILE"
    set_installed_owner "$LOCK_FILE"
    flock -x -n 8 || die "KOReader is starting/running or another standalone installer holds the transaction lock"
}

ensure_state_parent() {
    local_state=$PREFIX/home/root/.local/state
    for state_dir in "$local_state" "$STATE_PARENT"; do
        if path_exists "$state_dir"; then require_real_dir "$state_dir"; continue; fi
        [ "$state_dir" != "$local_state" ] || require_real_dir "$PREFIX/home/root/.local"
        mkdir "$state_dir"
        chmod 0755 "$state_dir"
        set_installed_owner "$state_dir"
    done
}

commit_trees() {
    write_state adapter_switching
    test_hook adapter_switching
    if path_exists "$ADAPTER_DIR"; then
        mv "$ADAPTER_DIR" "$ADAPTER_OLD"
    fi
    write_state adapter_old_saved
    test_hook adapter_old_saved
    mv "$ADAPTER_STAGE" "$ADAPTER_DIR"
    verify_installed_adapter
    write_state adapter_published
    test_hook adapter_published

    write_state data_switching
    test_hook data_switching
    if path_exists "$DATA_DIR"; then
        mv "$DATA_DIR" "$DATA_OLD"
    fi
    write_state data_old_saved
    test_hook data_old_saved
    mv "$DATA_STAGE" "$DATA_DIR"
    write_state data_published
    test_hook data_published

    write_state committed
    test_hook committed
    finalize_committed_transaction
    transaction_active=0
}

# Every check through the running-process guard is read-only.  In particular,
# interrupted-transaction recovery is intentionally deferred until KOReader is
# confirmed stopped.
preflight_commands_and_sources
preflight_targets
run_not_running_check
ensure_state_parent
acquire_install_lock
recover_or_refuse_transaction
preflight_targets

if [ "$TEST_MODE" -eq 1 ] && [ "${REMAGIC_INSTALL_TEST_RECOVER_ONLY:-0}" = 1 ]; then
    echo "KOReader adapter transaction recovery complete."
    exit 0
fi

begin_transaction
# Close the small check/acquire race without weakening the read-only guard that
# already ran before the transaction directory was created.
run_not_running_check
ensure_adapter_release_parent
stage_adapter
write_state prepared
test_hook prepared
stage_and_migrate_data
commit_trees

echo "KOReader QTFB adapter installed transactionally; wire this standalone release into a compatible manager manifest before launching."
