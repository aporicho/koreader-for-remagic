#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

# Updating reader.lua state while the manager owns a live KOReader process can
# corrupt its SQLite/WAL and settings files. Refuse safely; lifecycle ownership
# stays with Remagic Manager rather than this standalone installer.
"$ROOT/scripts/koreader-not-running"

mkdir -p /home/root/apps/remagic-koreader/bin /home/root/apps/remagic-koreader/libexec
mkdir -p /home/root/apps/koreader/patches
cp -f "$ROOT/scripts/koreader-remagic" /home/root/apps/remagic-koreader/bin/koreader-remagic
cp -f "$ROOT/scripts/koreader-data-migrate" /home/root/apps/remagic-koreader/libexec/koreader-data-migrate
cp -f "$ROOT/scripts/koreader-db-inspect" /home/root/apps/remagic-koreader/libexec/koreader-db-inspect
cp -f "$ROOT/scripts/koreader-db-inspect.lua" /home/root/apps/remagic-koreader/libexec/koreader-db-inspect.lua
cp -f "$ROOT/scripts/koreader-library-sync" /home/root/apps/remagic-koreader/libexec/koreader-library-sync
cp -f "$ROOT/scripts/koreader-library-index.lua" /home/root/apps/remagic-koreader/libexec/koreader-library-index.lua
cp -f "$ROOT/scripts/koreader-not-running" /home/root/apps/remagic-koreader/libexec/koreader-not-running
cp -f "$ROOT/patches/2-remagic-runtime.lua" /home/root/apps/koreader/patches/2-remagic-runtime.lua
chmod 0755 /home/root/apps/remagic-koreader/bin/koreader-remagic
chmod 0755 \
    /home/root/apps/remagic-koreader/libexec/koreader-data-migrate \
    /home/root/apps/remagic-koreader/libexec/koreader-db-inspect \
    /home/root/apps/remagic-koreader/libexec/koreader-library-sync \
    /home/root/apps/remagic-koreader/libexec/koreader-not-running
chmod 0644 \
    /home/root/apps/remagic-koreader/libexec/koreader-db-inspect.lua \
    /home/root/apps/remagic-koreader/libexec/koreader-library-index.lua \
    /home/root/apps/koreader/patches/2-remagic-runtime.lua
/home/root/apps/remagic-koreader/libexec/koreader-data-migrate
echo "KOReader QTFB adapter installed; launch it through Remagic Manager."
