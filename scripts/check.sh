#!/bin/sh
set -eu
scripts/check-architecture.sh
test -x scripts/koreader-for-remagic
test -x scripts/build-store-package.sh
test -f manifests/koreader.toml
sh -n scripts/koreader-for-remagic
sh -n scripts/build-store-package.sh
sh -n scripts/install-device.sh
sh -n scripts/koreader-data-migrate
sh -n scripts/koreader-db-inspect
sh -n scripts/koreader-library-sync
sh -n scripts/koreader-not-running
sh -n scripts/koreader-sync-state
lua -e 'assert(loadfile("scripts/koreader-library-index.lua"))'
lua -e 'assert(loadfile("scripts/koreader-sync-state.lua"))'
lua -e 'assert(loadfile("patches/10-remagic-environment.lua"))'
lua -e 'assert(loadfile("patches/20-remagic-policy.lua"))'
lua -e 'assert(loadfile("patches/21-remagic-lifecycle-v2.lua"))'
lua -e 'assert(loadfile("patches/22-remagic-library-collection.lua"))'
lua -e 'assert(loadfile("scripts/remagic-library-collection.lua"))'
lua -e 'assert(loadfile("scripts/remagic-lifecycle-protocol.lua"))'
lua -e 'assert(loadfile("scripts/remagic-open-path.lua"))'
bash -n scripts/stage-custom-fonts.sh
sh tests/test-koreader-for-remagic.sh
sh tests/test-manifest-v2.sh
sh tests/test-store-package.sh
sh tests/test-koreader-data-migrate.sh
sh tests/test-koreader-library-sync.sh
sh tests/test-koreader-not-running.sh
sh tests/test-install-device-transaction.sh
sh tests/test-remagic-runtime-userpatch.sh
sh tests/test-remagic-library-collection.sh
sh tests/test-remagic-runtime-fd.sh
echo "KOReader checks passed"
