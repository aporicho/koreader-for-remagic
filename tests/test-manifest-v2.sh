#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST=$ROOT/manifests/koreader.toml

python3 - "$MANIFEST" <<'PY'
import pathlib
import sys
import tomllib

path = pathlib.Path(sys.argv[1])
manifest = tomllib.loads(path.read_text(encoding="utf-8"))

assert manifest["schema"] == 2
assert manifest["id"] == "koreader"
assert manifest["resident"] is True
assert manifest["display"] == "qtfb"
assert manifest["capabilities"] == [
    "display:qtfb-v1",
    "input:touch-v1",
    "lifecycle:v2",
    "network:outbound-v1",
]
assert manifest["supports_open_path"] is True
assert manifest["allowed_open_roots"] == [
    "/home/root/.local/share/koreader-for-remagic/library",
    "/home/root/books",
    "/home/root/koreader",
    "/home/root/.local/share/remarkable/xochitl",
]

assert manifest["readiness"] == {"mode": "first_frame", "timeout_ms": 20_000}
assert manifest["shutdown"] == {
    "graceful_timeout_ms": 3_500,
    "term_timeout_ms": 4_500,
    "kill_timeout_ms": 5_500,
}

data_schema = manifest["data_schema"]
assert data_schema["version"] == 2
assert data_schema["migrator"].endswith("/koreader-data-migrate")
assert data_schema["migration_timeout_ms"] == 120_000
assert data_schema["backup_paths"] == [
    "/home/root/.local/share/remagic-koreader/data",
    "/home/root/.local/share/koreader-for-remagic/data",
]

runtime = manifest["runtime"]
assert runtime["profile"] == "qtfb_compat"
assert runtime["background_execution"] == "freeze"
assert runtime["directories"]["home"] == "/home/root"
assert runtime["directories"]["data_home"] == "/home/root/.local/share/koreader-for-remagic"
assert runtime["directories"]["runtime_dir"] == "/run/remagic/apps/koreader"
assert runtime["network"]["mode"] == "outbound"
assert manifest["environment"] == {
    "KOREADER_DIR": "/home/root/apps/koreader-for-remagic/vendor/releases/v2026.03-56621d5ee66ad94f4f3e2e6d204e8c34be730343f915edc36bb076a043a2e468/koreader",
    "KOREADER_LIBEXEC_DIR": "/home/root/apps/koreader-for-remagic/adapter/releases/__REMAGIC_ADAPTER_RELEASE__/libexec",
    "KO_HOME": "/home/root/.local/share/koreader-for-remagic/data",
    "KOREADER_DATA_DIR": "/home/root/.local/share/koreader-for-remagic/data",
    "KOREADER_SETTINGS": "/home/root/.local/share/koreader-for-remagic/data/settings.reader.lua",
    "KOREADER_BACKUP_ROOT": "/home/root/.local/state/koreader-for-remagic/backups",
    "KOREADER_LEGACY_DATA_DIRS": "/home/root/.local/share/remagic-koreader/data:/home/root/apps/koreader:/home/root/.paperweight/services/koreader/koreader:/home/root/.config/koreader",
}
assert manifest["exec"] == "/home/root/apps/koreader-for-remagic/adapter/releases/__REMAGIC_ADAPTER_RELEASE__/bin/koreader-for-remagic"
assert manifest["working_dir"] == "/home/root/apps/koreader-for-remagic/vendor/releases/v2026.03-56621d5ee66ad94f4f3e2e6d204e8c34be730343f915edc36bb076a043a2e468/koreader"
assert runtime["fonts"]["directories"] == [
    "/home/root/apps/koreader-for-remagic/adapter/releases/__REMAGIC_ADAPTER_RELEASE__/share/fonts",
]

adapter_placeholder = "__REMAGIC_ADAPTER_RELEASE__"
for field in (
    manifest["exec"],
    manifest["data_schema"]["migrator"],
    manifest["environment"]["KOREADER_LIBEXEC_DIR"],
    *runtime["fonts"]["directories"],
):
    assert adapter_placeholder in field, field

for field in (manifest["exec"], manifest["working_dir"], *manifest["allowed_open_roots"]):
    assert pathlib.PurePosixPath(field).is_absolute(), field

print("KOReader schema-v2 manifest tests passed")
PY
