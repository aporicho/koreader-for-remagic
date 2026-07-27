#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
BUILDER=$ROOT/scripts/build-store-package.sh
ARCHIVE=${KOREADER_TEST_ARCHIVE:-/tmp/koreader-remarkable-aarch64-v2026.03.zip}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

sh -n "$BUILDER"
grep -Fq 'KOREADER_ARCHIVE_SHA256=56621d5ee66ad94f4f3e2e6d204e8c34be730343f915edc36bb076a043a2e468' \
    "$BUILDER" || fail "store builder does not pin the official archive"
grep -Fq '"app_id": "koreader"' "$BUILDER" || fail "store bundle has no canonical app id"
grep -Fq '"manifest_path": "manifest.toml"' "$BUILDER" || fail "store bundle has no manifest contract"

if [ ! -f "$ARCHIVE" ]; then
    echo "KOReader store package integration skipped: set KOREADER_TEST_ARCHIVE to the pinned official zip" >&2
    exit 0
fi

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT HUP INT TERM
OUTPUT=$TMPDIR_TEST/koreader-for-remagic.tar.gz
EXTRACTED=$TMPDIR_TEST/extracted
mkdir "$EXTRACTED"

KOREADER_SKIP_CUSTOM_FONTS=1 "$BUILDER" "$ARCHIVE" "$OUTPUT" >/dev/null
[ -s "$OUTPUT" ] || fail "store builder produced no archive"
tar -xzf "$OUTPUT" -C "$EXTRACTED"

[ -f "$EXTRACTED/bundle.json" ] || fail "bundle.json is missing"
[ -f "$EXTRACTED/manifest.toml" ] || fail "final manifest is missing"
[ -d "$EXTRACTED/payload/vendor" ] || fail "vendor payload is missing"
[ -d "$EXTRACTED/payload/adapter" ] || fail "adapter payload is missing"
if find "$EXTRACTED" ! -type f ! -type d -print -quit | grep . >/dev/null; then
    fail "store archive contains a symlink or special file"
fi

python3 - "$EXTRACTED" <<'PY'
import hashlib
import json
import pathlib
import stat
import sys
import tomllib

root = pathlib.Path(sys.argv[1])
bundle = json.loads((root / "bundle.json").read_text(encoding="utf-8"))
manifest = tomllib.loads((root / "manifest.toml").read_text(encoding="utf-8"))

assert bundle["app_id"] == manifest["id"] == "koreader"
assert bundle["schema"] == 1
assert bundle["package"] == manifest["package"] == "koreader-for-remagic"
assert bundle["version"] == manifest["version"] == "2026.3.0-remagic.12"
assert bundle["manifest_path"] == "manifest.toml"
assert len(bundle["content_id"]) == 64
int(bundle["content_id"], 16)
assert manifest["kind"] == "user"
assert manifest["name"] == "KOReader"
assert manifest["package"] == "koreader-for-remagic"
assert manifest["supported_devices"] == ["paper_pro", "paper_pro_move"]
assert manifest["supported_os"] == []
assert manifest["required_remagic_api"] == 5
assert manifest["uninstall_policy"] == "keep_data"
assert "__REMAGIC_" not in (root / "manifest.toml").read_text(encoding="utf-8")
release_root = "/home/root/apps/koreader/current/"
assert manifest["exec"].startswith(release_root)
assert manifest["working_dir"].startswith(release_root)
assert "/current/" in manifest["exec"]

payload_hasher = hashlib.sha256()
payload_files = []
for path in sorted((root / "payload").rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
    info = path.lstat()
    assert stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)
    if not stat.S_ISREG(info.st_mode):
        continue
    payload_files.append(path)
    relative = path.relative_to(root).as_posix()
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    payload_hasher.update(f"{relative}\0{stat.S_IMODE(info.st_mode):o}\0{info.st_size}\0{digest}\n".encode())
assert payload_hasher.hexdigest() == bundle["payload_sha256"]

expected = {}
for path in [root / "manifest.toml", *payload_files]:
    info = path.stat()
    relative = path.relative_to(root).as_posix()
    expected[relative] = {
        "path": relative,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "size": info.st_size,
        "mode": f"{stat.S_IMODE(info.st_mode):04o}",
    }
actual = {entry["path"]: entry for entry in bundle["files"]}
assert actual == expected

content_hasher = hashlib.sha256()
content_hasher.update(b"remagic-bundle-content-v1\0")
for value in ("koreader", "koreader-for-remagic", bundle["version"]):
    content_hasher.update(value.encode())
    content_hasher.update(b"\0")
for entry in sorted(bundle["files"], key=lambda item: item["path"].encode()):
    mode = format(int(entry["mode"], 8), "o")
    content_hasher.update(
        f'{entry["path"]}\0{mode}\0{entry["size"]}\0{entry["sha256"]}\n'.encode()
    )
assert content_hasher.hexdigest() == bundle["content_id"]

vendor_release = "v2026.03-56621d5ee66ad94f4f3e2e6d204e8c34be730343f915edc36bb076a043a2e468"
vendor = root / "payload" / "vendor" / "releases" / vendor_release / "koreader"
assert (vendor / "git-rev").read_text(encoding="utf-8").strip() == "v2026.03"
assert (vendor / "update_once.marker").is_file()
adapter_releases = list((root / "payload" / "adapter" / "releases").iterdir())
assert len(adapter_releases) == 1
assert adapter_releases[0].name.startswith("adapter-")
assert (adapter_releases[0] / "bin" / "koreader-for-remagic").is_file()
assert (adapter_releases[0] / "libexec" / "remagic-library-collection.lua").is_file()
assert (adapter_releases[0] / "libexec" / "remagic-library-collection-migrate.lua").is_file()
assert (adapter_releases[0] / "libexec" / "remagic-library-local-scan.lua").is_file()
assert (adapter_releases[0] / "libexec" / "koreader-sync-state").is_file()
assert (adapter_releases[0] / "libexec" / "koreader-sync-state.lua").is_file()
assert (adapter_releases[0] / "share" / "patches" / "22-remagic-library-collection.lua").is_file()
assert (adapter_releases[0] / "share" / "patches" / "20-remagic-collection-migration.lua").is_file()
PY

echo "KOReader Store package tests passed"
