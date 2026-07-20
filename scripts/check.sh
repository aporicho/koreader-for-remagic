#!/bin/sh
set -eu
test -x scripts/koreader-remagic
test -f manifests/koreader.toml
sh -n scripts/koreader-remagic
sh -n scripts/install-device.sh
echo "remagic-koreader checks passed"
