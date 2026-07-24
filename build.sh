#!/bin/bash
# PowerMacToys 빌드 스크립트 — swiftc 단일 컴파일, Xcode 프로젝트 불필요
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/PowerMacToys.app"

rm -rf dist
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

swiftc -O Sources/PowerMacToysCore.swift Sources/OCREngine.swift Sources/WindowPinner.swift Sources/TextExtractor.swift Sources/SleepPreventer.swift Sources/ColorPicker.swift Sources/main.swift -o "$APP/Contents/MacOS/PowerMacToys"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 서명 — SIGN_ID 환경변수 지정 시 해당 인증서, 미지정이어도 'PowerMacToys Dev' 인증서가
# 키체인에 있으면 자동 사용(재빌드해도 손쉬운 사용 권한 유지 — Tests/make_signing_cert.sh 참고).
# 인증서가 없으면 기존처럼 ad-hoc(배포/install.sh 경로 무영향).
if [[ -z "${SIGN_ID:-}" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"PowerMacToys Dev"'; then
    SIGN_ID="PowerMacToys Dev"
fi
codesign --force --sign "${SIGN_ID:--}" "$APP"

echo "빌드 완료: $PWD/$APP"
echo "서명:      ${SIGN_ID:-ad-hoc — 재빌드마다 손쉬운 사용 권한이 풀립니다 (고정하려면 Tests/make_signing_cert.sh)}"
echo "설치:      cp -R $APP /Applications/"
