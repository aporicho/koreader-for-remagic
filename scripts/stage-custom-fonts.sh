#!/bin/bash
set -euo pipefail

OUTPUT=${1:?usage: stage-custom-fonts.sh OUTPUT_DIRECTORY}
DONGGUAN_DIR=${KOREADER_DONGGUAN_FONT_DIR:-/home/aporicho/Downloads/上图东观体（3种规格）}
YASONG_FONT=${KOREADER_YASONG_FONT:-/home/aporicho/Downloads/方正屏显雅宋.TTF}
DONGGUAN_REGULAR_FONT=${KOREADER_DONGGUAN_REGULAR_FONT:-$DONGGUAN_DIR/上图东观体-常规.ttf}
DONGGUAN_BOLD_FONT=${KOREADER_DONGGUAN_BOLD_FONT:-$DONGGUAN_DIR/上图东观体-粗体.ttf}
DONGGUAN_LIGHT_FONT=${KOREADER_DONGGUAN_LIGHT_FONT:-$DONGGUAN_DIR/上图东观体-细体.ttf}

stage_font() {
    expected=$1
    source=$2
    target=$3
    if [ ! -f "$source" ]; then
        echo "KOReader custom font is missing: $source" >&2
        exit 1
    fi
    printf '%s  %s\n' "$expected" "$source" | sha256sum -c - >/dev/null
    cp "$source" "$OUTPUT/$target"
}

mkdir -p "$OUTPUT"
stage_font 7fac32a774ae5259ca9a3bd02cc5582db1bce6eea18b3325505fa92877da5320 \
    "$DONGGUAN_REGULAR_FONT" STDongGuanTi-Regular.ttf
stage_font 868ce8d748eef37837a0ed0b547de2c6c33c655459e69d4957d74fae8cd1c6be \
    "$DONGGUAN_BOLD_FONT" STDongGuanTi-Bold.ttf
stage_font 00e349cc5211e9e044ad9947351daf2f415188a136ed27a2ed825d9cbd9ffe35 \
    "$DONGGUAN_LIGHT_FONT" STDongGuanTi-Light.ttf
stage_font dbbdf59d7035d980abecf4f820e615b72107865a00f6eb41a1bbb9d9d1492fd1 \
    "$YASONG_FONT" FZPingXianYaSong.ttf

(
    cd "$OUTPUT"
    sha256sum \
        STDongGuanTi-Regular.ttf \
        STDongGuanTi-Bold.ttf \
        STDongGuanTi-Light.ttf \
        FZPingXianYaSong.ttf >fonts.sha256
    sha256sum -c fonts.sha256 >/dev/null
)
chmod 0644 "$OUTPUT"/*.ttf "$OUTPUT/fonts.sha256"

printf 'Staged KOReader fonts in %s\n' "$OUTPUT"
