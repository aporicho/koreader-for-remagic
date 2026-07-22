#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ENVIRONMENT_PATCH=$ROOT/patches/10-remagic-environment.lua
POLICY_PATCH=$ROOT/patches/20-remagic-policy.lua
LIFECYCLE_PATCH=$ROOT/patches/21-remagic-lifecycle-v2.lua
MOCK=$ROOT/tests/remagic-runtime-userpatch-mock.lua
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT HUP INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }

for lua_file in "$ENVIRONMENT_PATCH" "$POLICY_PATCH" "$LIFECYCLE_PATCH" \
    "$MOCK" "$ROOT/scripts/remagic-lifecycle-protocol.lua" \
    "$ROOT/scripts/remagic-open-path.lua"
do
    luac -p "$lua_file"
done

if grep -E 'REMAGIC_APP_BRIDGE|koreader-ready|koreader-exit|runInSubProcess|legacy' \
        "$LIFECYCLE_PATCH" >/dev/null; then
    fail "lifecycle patch retains a bridge, marker, subprocess, or legacy fallback"
fi
grep -F 'REMAGIC_LIFECYCLE_FD is required' "$LIFECYCLE_PATCH" >/dev/null || \
    fail "direct lifecycle descriptor is not mandatory"
grep -F 'UIManager:broadcastEvent(Event:new("Exit"))' "$LIFECYCLE_PATCH" >/dev/null || \
    fail "native KOReader Exit event is not used"
grep -F 'UIManager.tickAfterNext' "$LIFECYCLE_PATCH" >/dev/null || \
    fail "semantic readiness does not wait for a real repaint"

storage_data=$TMPDIR_TEST/storage-data
mkdir -p "$storage_data"
REMAGIC_MANAGED=1 EXT_FONT_DIR=/adapter/share/fonts \
lua - "$storage_data" "$ENVIRONMENT_PATCH" <<'LUA'
local data_dir, patch = arg[1], arg[2]
local version = {}
local canvas = { init = function(self, device) self.hasSystemFonts = device.hasSystemFonts end }
package.preload.datastorage = function()
    return { getDataDir = function() return data_dir end }
end
package.preload.version = function() return version end
package.preload["document/canvascontext"] = function() return canvas end
dofile(patch)
canvas:init({ hasSystemFonts = function() return true end })
assert(canvas:hasSystemFonts() == false)
assert(version:getLastLogLine() == "")
assert(version:appendToLogFile("first"))
assert(version:appendToLogFile("second"))
assert(version:getLastLogLine() == "second")
LUA
[ -s "$storage_data/version.log" ] || fail "version log was not redirected into KO_HOME"

lua - "$POLICY_PATCH" <<'LUA'
local patch = arg[1]
local Device = { hasOTAUpdates = function() return true end, hasOTARunning = function() return true end }
local settings = { plugins_disabled = { statistics = true } }
package.preload.device = function() return Device end
package.preload.logger = function() return { info = function() end } end
G_reader_settings = {
    readSetting = function(_, key) return settings[key] end,
    saveSetting = function(_, key, value) settings[key] = value end,
}
dofile(patch)
assert(Device:hasOTAUpdates() == false and Device:hasOTARunning() == false)
assert(settings.plugins_disabled.terminal == true)
assert(settings.plugins_disabled.statistics == true)
LUA

open_file=$TMPDIR_TEST/一本书.epub
open_dir=$TMPDIR_TEST/书库
: >"$open_file"
mkdir "$open_dir"

run_mode() {
    mode=$1
    REMAGIC_APP_PID=4321 \
    REMAGIC_APP_GENERATION=3719679425990660 \
    REMAGIC_LIFECYCLE_FD=7 \
    REMAGIC_KOREADER_LIBEXEC_DIR=$ROOT/scripts \
    REMAGIC_ALLOWED_OPEN_ROOTS=$TMPDIR_TEST \
    REMAGIC_INITIAL_OPEN_PATH=$open_file \
    TEST_OPEN_PATH=$open_file \
    TEST_OPEN_DIR=$open_dir \
        lua "$MOCK" "$LIFECYCLE_PATCH" "$mode"
}

for mode in filemanager reader rapid_transition background_resume \
    background_save_failure stale_fences foreground_failure_rollback \
    open_path open_directory open_rejected start_preapplied shutdown \
    shutdown_before_ready shutdown_failures
do
    run_mode "$mode"
done

echo "remagic KOReader userpatch tests passed"
