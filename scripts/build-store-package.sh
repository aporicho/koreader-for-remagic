#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
KOREADER_VERSION=v2026.03
KOREADER_ARCHIVE_SHA256=56621d5ee66ad94f4f3e2e6d204e8c34be730343f915edc36bb076a043a2e468
APP_VERSION=2026.3.0-remagic.4

fail() {
    echo "build-store-package: $*" >&2
    exit 1
}

[ "$#" -eq 2 ] || fail "usage: $0 OFFICIAL_KOREADER_ZIP OUTPUT_TAR_GZ"
ARCHIVE=$1
OUTPUT=$2

for command_name in bsdtar chmod cmp cp find grep gzip install mkdir mktemp mv python3 rm sed sha256sum tar; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: $command_name"
done
[ -f "$ARCHIVE" ] && [ ! -L "$ARCHIVE" ] || fail "official archive is missing or unsafe: $ARCHIVE"
archive_digest=$(sha256sum "$ARCHIVE") || fail "could not hash official archive"
[ "${archive_digest%% *}" = "$KOREADER_ARCHIVE_SHA256" ] || fail "official archive checksum mismatch"

case "$OUTPUT" in
    /*) ;;
    *) OUTPUT=$(pwd -P)/$OUTPUT ;;
esac
OUTPUT_PARENT=${OUTPUT%/*}
[ "$OUTPUT_PARENT" != "$OUTPUT" ] || OUTPUT_PARENT=/
mkdir -p "$OUTPUT_PARENT"
[ -d "$OUTPUT_PARENT" ] && [ ! -L "$OUTPUT_PARENT" ] || fail "output parent is unsafe: $OUTPUT_PARENT"

BUILD_ROOT=$(mktemp -d /tmp/koreader-for-remagic-package.XXXXXX) || fail "could not create build root"
OUTPUT_TMP=$OUTPUT.tmp.$$
cleanup() {
    rm -rf "$BUILD_ROOT"
    [ -z "$OUTPUT_TMP" ] || rm -f "$OUTPUT_TMP"
}
trap cleanup EXIT HUP INT TERM

PACKAGE_ROOT=$BUILD_ROOT/package
PAYLOAD_ROOT=$PACKAGE_ROOT/payload
APP_ROOT=$PAYLOAD_ROOT
VENDOR_RELEASE=$KOREADER_VERSION-$KOREADER_ARCHIVE_SHA256
VENDOR_PARENT=$APP_ROOT/vendor/releases/$VENDOR_RELEASE
VENDOR_ROOT=$VENDOR_PARENT/koreader
ADAPTER_STAGE=$APP_ROOT/adapter/.staging
mkdir -p "$VENDOR_PARENT" "$ADAPTER_STAGE/bin" "$ADAPTER_STAGE/libexec" \
    "$ADAPTER_STAGE/share/patches" "$ADAPTER_STAGE/share/fonts" \
    "$APP_ROOT/deployment"

# The pinned archive is extracted without deleting or rewriting any upstream
# file. In particular update_once.marker remains part of the read-only vendor
# inventory; ReMagic owns the write boundary rather than patching KOReader.
bsdtar -xf "$ARCHIVE" -C "$VENDOR_PARENT"
[ -d "$VENDOR_ROOT" ] && [ ! -L "$VENDOR_ROOT" ] || fail "archive has no safe koreader root"
[ -f "$VENDOR_ROOT/git-rev" ] && [ ! -L "$VENDOR_ROOT/git-rev" ] || fail "archive has no safe git-rev"
[ "$(sed -n '1p' "$VENDOR_ROOT/git-rev")" = "$KOREADER_VERSION" ] || fail "archive git-rev mismatch"
[ -f "$VENDOR_ROOT/update_once.marker" ] && [ ! -L "$VENDOR_ROOT/update_once.marker" ] || \
    fail "official update_once.marker is missing"
if find "$VENDOR_ROOT" ! -type f ! -type d -print -quit | grep . >/dev/null; then
    fail "official archive contains a symlink or special file"
fi

stage_file() {
    source=$1
    relative=$2
    mode=$3
    target=$ADAPTER_STAGE/$relative
    mkdir -p "${target%/*}"
    install -m "$mode" "$source" "$target"
    cmp -s "$source" "$target" || fail "staged adapter file did not verify: $relative"
}

stage_file "$ROOT/scripts/koreader-for-remagic" bin/koreader-for-remagic 0755
for executable in koreader-data-migrate koreader-db-inspect koreader-library-sync koreader-not-running; do
    stage_file "$ROOT/scripts/$executable" "libexec/$executable" 0755
done
for module in \
    koreader-db-inspect.lua \
    koreader-library-index.lua \
    remagic-library-collection.lua \
    remagic-lifecycle-protocol.lua \
    remagic-open-path.lua
do
    stage_file "$ROOT/scripts/$module" "libexec/$module" 0644
done
for platform_patch in 10-remagic-environment.lua 20-remagic-policy.lua \
        21-remagic-lifecycle-v2.lua 22-remagic-library-collection.lua; do
    stage_file "$ROOT/patches/$platform_patch" "share/patches/$platform_patch" 0644
done

case ${KOREADER_SKIP_CUSTOM_FONTS:-0} in
    0) "$ROOT/scripts/stage-custom-fonts.sh" "$ADAPTER_STAGE/share/fonts" ;;
    1) ;;
    *) fail "KOREADER_SKIP_CUSTOM_FONTS must be 0 or 1" ;;
esac

ADAPTER_HASH=$(python3 - "$ADAPTER_STAGE" <<'PY'
import hashlib
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
entries = []
for path in [root, *root.rglob("*")]:
    info = path.lstat()
    relative = "." if path == root else "./" + path.relative_to(root).as_posix()
    mode = stat.S_IMODE(info.st_mode)
    if stat.S_ISDIR(info.st_mode):
        entries.append((relative, f"d\t{mode:o}\t{relative}\n".encode()))
    elif stat.S_ISREG(info.st_mode):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        entries.append((relative, f"f\t{mode:o}\t{digest}\t{relative}\n".encode()))
    else:
        raise SystemExit(f"unsafe adapter entry: {path}")
hasher = hashlib.sha256()
for _, encoded in sorted(entries):
    hasher.update(encoded)
print(hasher.hexdigest())
PY
) || fail "could not calculate adapter content id"
case "$ADAPTER_HASH" in
    *[!0-9a-f]*|'') fail "adapter content id is invalid" ;;
esac
[ "${#ADAPTER_HASH}" -eq 64 ] || fail "adapter content id has the wrong length"
ADAPTER_RELEASE=adapter-$ADAPTER_HASH
ADAPTER_ROOT=$APP_ROOT/adapter/releases/$ADAPTER_RELEASE
mkdir -p "${ADAPTER_ROOT%/*}"
mv "$ADAPTER_STAGE" "$ADAPTER_ROOT"

printf 'vendor_release=%s\nadapter_release=%s\n' \
    "$VENDOR_RELEASE" "$ADAPTER_RELEASE" >"$APP_ROOT/deployment/current.env"

python3 - "$APP_ROOT" "$VENDOR_RELEASE" <<'PY'
import hashlib
import pathlib
import stat
import sys

app_root = pathlib.Path(sys.argv[1])
release = sys.argv[2]
vendor = app_root / "vendor" / "releases" / release / "koreader"
deployment = app_root / "deployment"
rows = []
hashes = []
for path in sorted([vendor, *vendor.rglob("*")], key=lambda item: item.as_posix()):
    info = path.lstat()
    relative = path.relative_to(app_root).as_posix()
    mode = stat.S_IMODE(info.st_mode)
    if stat.S_ISDIR(info.st_mode):
        rows.append(f"d\t{mode:o}\t{relative}\n")
    elif stat.S_ISREG(info.st_mode):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        rows.append(f"f\t{mode:o}\t{relative}\n")
        hashes.append(f"{digest}  {relative}\n")
    else:
        raise SystemExit(f"unsafe vendor entry: {path}")
(deployment / "vendor.files").write_text("".join(rows), encoding="utf-8")
(deployment / "vendor.sha256").write_text("".join(hashes), encoding="utf-8")
PY

sed "s/__REMAGIC_ADAPTER_RELEASE__/$ADAPTER_RELEASE/g" \
    "$ROOT/manifests/koreader.toml" >"$PACKAGE_ROOT/manifest.toml"
chmod 0644 "$PACKAGE_ROOT/manifest.toml"

python3 - \
    "$PACKAGE_ROOT" \
    "$PACKAGE_ROOT/manifest.toml" \
    "$APP_VERSION" <<'PY'
import hashlib
import json
import pathlib
import stat
import sys

package_root = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2]).read_bytes()
version = sys.argv[3]
payload = package_root / "payload"

def regular_files(root):
    files = []
    for path in root.rglob("*"):
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
            raise SystemExit(f"unsafe package entry: {path}")
        if stat.S_ISREG(info.st_mode):
            if info.st_nlink != 1:
                raise SystemExit(f"hard-linked package entry: {path}")
            relative = path.relative_to(package_root).as_posix()
            if "\n" in relative or "\r" in relative or "\0" in relative:
                raise SystemExit(f"unsafe package path: {relative!r}")
            if stat.S_IMODE(info.st_mode) not in (0o644, 0o755):
                raise SystemExit(f"unsupported package mode: {relative}")
            files.append(path)
    return sorted(files, key=lambda path: path.relative_to(package_root).as_posix().encode("utf-8"))

if b"__REMAGIC_" in manifest:
    raise SystemExit("unresolved ReMagic placeholder in final manifest")

files = []
for path in regular_files(package_root):
    if path.name == "bundle.json":
        continue
    info = path.stat()
    files.append({
        "path": path.relative_to(package_root).as_posix(),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "size": info.st_size,
        "mode": f"{stat.S_IMODE(info.st_mode):04o}",
    })

def record(entry):
    mode = format(int(entry["mode"], 8), "o")
    return f'{entry["path"]}\0{mode}\0{entry["size"]}\0{entry["sha256"]}\n'.encode()

files.sort(key=lambda entry: entry["path"].encode("utf-8"))
payload_hasher = hashlib.sha256()
content_hasher = hashlib.sha256()
content_hasher.update(b"remagic-bundle-content-v1\0")
for value in ("koreader", "koreader-for-remagic", version):
    content_hasher.update(value.encode())
    content_hasher.update(b"\0")
for entry in files:
    encoded = record(entry)
    content_hasher.update(encoded)
    if entry["path"].startswith("payload/"):
        payload_hasher.update(encoded)

bundle = {
    "schema": 1,
    "app_id": "koreader",
    "package": "koreader-for-remagic",
    "version": version,
    "content_id": content_hasher.hexdigest(),
    "manifest_path": "manifest.toml",
    "payload_sha256": payload_hasher.hexdigest(),
    "files": files,
}
(package_root / "bundle.json").write_text(
    json.dumps(bundle, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
(package_root / "bundle.json").chmod(0o644)
PY

python3 - "$PACKAGE_ROOT/bundle.json" "$PACKAGE_ROOT/manifest.toml" <<'PY'
import json
import pathlib
import sys
import tomllib

bundle = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
manifest = tomllib.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
assert bundle["app_id"] == manifest["id"] == "koreader"
assert bundle["version"] == manifest["version"]
assert manifest["supported_devices"] == ["paper_pro", "paper_pro_move"]
assert manifest["required_remagic_api"] == 2
assert manifest["uninstall_policy"] == "keep_data"
release_root = "/home/root/apps/koreader/current/"
assert manifest["exec"].startswith(release_root)
assert manifest["working_dir"].startswith(release_root)
PY

(cd "$PACKAGE_ROOT" && \
    tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
        -cf - bundle.json manifest.toml payload) | gzip -n >"$OUTPUT_TMP"
[ -s "$OUTPUT_TMP" ] || fail "package archive is empty"
mv -f "$OUTPUT_TMP" "$OUTPUT"
OUTPUT_TMP=
echo "Built KOReader Store package: $OUTPUT"
