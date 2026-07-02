#!/bin/bash
# PlainPaste DMG 패키징 — 앱 빌드 후 배포용 .dmg 생성 (맥 내장 도구만 사용, 의존성 0)
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/PlainPaste.app"
VOL="PlainPaste"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
DMG="dist/PlainPaste-${VERSION}.dmg"

# 앱이 없으면 먼저 빌드
[ -d "$APP" ] || ./build.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 스테이징: 앱 + /Applications 심볼릭 링크 (드래그 설치 UX)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "$VOL" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

# DMG에도 ad-hoc 서명 (Gatekeeper 경고 최소화)
codesign --force --sign - "$DMG" 2>/dev/null || true

echo "DMG 완료: $PWD/$DMG"
du -h "$DMG" | cut -f1 | sed 's/^/크기:      /'
