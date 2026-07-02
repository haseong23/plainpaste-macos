#!/bin/bash
# 아이콘 생성 — Swift로 1024 PNG를 그린 뒤 sips/iconutil(맥 내장)로 AppIcon.icns 빌드
set -euo pipefail
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -O Sources/make_icon.swift -o "$TMP/makeicon"
"$TMP/makeicon" "$TMP/icon_1024.png"

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

# iconutil이 요구하는 표준 사이즈 세트
gen() { sips -z "$1" "$1" "$TMP/icon_1024.png" --out "$ICONSET/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
cp "$TMP/icon_1024.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o AppIcon.icns
echo "빌드 완료: $PWD/AppIcon.icns"
