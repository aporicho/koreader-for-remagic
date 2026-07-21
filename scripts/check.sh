#!/bin/sh
set -eu
scripts/check-architecture.sh
test -x scripts/koreader-remagic
test -f manifests/koreader.toml
sh -n scripts/koreader-remagic
sh -n scripts/install-device.sh
sh -n scripts/koreader-data-migrate
sh -n scripts/koreader-db-inspect
sh -n scripts/koreader-library-sync
sh -n scripts/koreader-not-running
sh -n scripts/koreader-lifecycle
lua -e 'assert(loadfile("scripts/koreader-library-index.lua"))'
lua -e 'assert(loadfile("patches/1-remagic-storage.lua"))'
lua -e 'assert(loadfile("patches/2-remagic-runtime.lua"))'
bash -n scripts/stage-custom-fonts.sh
sh tests/test-koreader-remagic.sh
sh tests/test-manifest-v2.sh
sh tests/test-koreader-data-migrate.sh
sh tests/test-koreader-library-sync.sh
sh tests/test-koreader-not-running.sh
sh tests/test-install-device-transaction.sh
sh tests/test-koreader-lifecycle.sh
sh tests/test-remagic-runtime-userpatch.sh
sh tests/test-remagic-runtime-fd.sh
echo "remagic-koreader checks passed"
