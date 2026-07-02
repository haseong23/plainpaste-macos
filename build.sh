#!/bin/bash
# PlainPaste 빌드 스크립트 — swiftc 단일 컴파일, Xcode 프로젝트 불필요
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/PlainPaste.app"

rm -rf dist
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

swiftc -O Sources/main.swift -o "$APP/Contents/MacOS/PlainPaste"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# ad-hoc 서명 (손쉬운 사용 권한이 실행 파일에 매달리도록)
codesign --force --sign - "$APP"

echo "빌드 완료: $PWD/$APP"
echo "설치:      cp -R $APP /Applications/"
