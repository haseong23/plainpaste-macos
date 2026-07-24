#!/bin/bash
# PowerMacToys DMG 패키징 — 드래그 설치 UI가 꾸며진 배포용 .dmg 생성
# 맥 내장 도구만 사용(swiftc·hdiutil·tiffutil·osascript). 의존성 0.
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/PowerMacToys.app"
VOL="PowerMacToys"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
DMG="dist/PowerMacToys-${VERSION}.dmg"

# 앱이 없으면 먼저 빌드
[ -d "$APP" ] || ./build.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || true' EXIT

# ── 1. 창 배경 이미지 생성 (1x + 2x → 레티나용 멀티레졸루션 TIFF) ──────────
swiftc -O Sources/make_dmg_bg.swift -o "$TMP/makebg"
"$TMP/makebg" "$TMP/bg.png"    1 >/dev/null
"$TMP/makebg" "$TMP/bg@2x.png" 2 >/dev/null
tiffutil -cathidpicheck "$TMP/bg.png" "$TMP/bg@2x.png" -out "$TMP/bg.tiff" >/dev/null

# ── 2. 쓰기 가능한 임시 DMG 생성 후 마운트 ───────────────────────────────
hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || true
RW="$TMP/rw.dmg"
hdiutil create -size 40m -fs HFS+ -volname "$VOL" -type UDIF -layout SPUD "$RW" >/dev/null
MNT="/Volumes/$VOL"
hdiutil attach "$RW" -nobrowse -noautoopen >/dev/null

# ── 3. 내용 채우기: 앱 + Applications 링크 + 숨김 배경 ────────────────────
cp -R "$APP" "$MNT/"
ln -s /Applications "$MNT/Applications"
mkdir "$MNT/.background"
cp "$TMP/bg.tiff" "$MNT/.background/bg.tiff"

# ── 4. Finder로 창 모양 구성 (아이콘 뷰·위치·배경·툴바 숨김) ──────────────
osascript <<EOF
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 160, 820, 658}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 12
    set background picture of opts to file ".background:bg.tiff"
    set position of item "PowerMacToys.app" of container window to {160, 210}
    set position of item "Applications" of container window to {460, 210}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

sync

# ── 5. 언마운트 후 압축 포맷(UDZO)으로 변환 ──────────────────────────────
hdiutil detach "$MNT" >/dev/null
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

# DMG ad-hoc 서명
codesign --force --sign - "$DMG" 2>/dev/null || true

echo "DMG 완료: $PWD/$DMG"
du -h "$DMG" | cut -f1 | sed 's/^/크기:      /'
