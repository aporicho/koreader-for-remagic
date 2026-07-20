#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p /home/root/apps/remagic-koreader/bin /home/root/apps/remagic-koreader/lib
cp -f "$ROOT/scripts/koreader-remagic" /home/root/apps/remagic-koreader/bin/koreader-remagic
chmod 0755 /home/root/apps/remagic-koreader/bin/koreader-remagic
echo "KOReader adapter installed; register manifests/koreader.toml with Remagic Manager."
