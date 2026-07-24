#!/bin/bash
# PowerMacToys E2E 테스트 — 실제 앱·실제 pasteboard·합성 ⌘V 왕복을 실기기에서 검증.
#
#   ./Tests/e2e.sh
#
# 하는 일: 빌드 → 기존 인스턴스 정리 → 테스트 훅 켠 앱 + PasteCatcher 실행
#          → E2EDriver로 시나리오 S1~S13 실행 → 정리(클립보드·기존 앱 복귀)
#
# 1회 설정(최초 1번만, TESTPLAN.md 참고):
#   1. ./Tests/make_signing_cert.sh   — 서명 고정(재빌드해도 권한 유지)
#   2. 빌드된 앱에 손쉬운 사용 권한 부여
#   3. (선택) 터미널에도 손쉬운 사용 권한 — 없으면 S11·S12만 자동 skip
#
# 주의: 실행 중(~1분) 키보드/마우스를 만지지 말 것 — 포커스·클립보드를 테스트가 점유한다.
set -euo pipefail
cd "$(dirname "$0")/.."

# 0) GUI 로그인 세션 확인 (분산 노티·합성 이벤트·창 포커스가 모두 Aqua 세션 전제)
if [[ "$(launchctl managername 2>/dev/null)" != "Aqua" ]]; then
    echo "❌ GUI 로그인 세션에서만 실행할 수 있습니다 (SSH/헤드리스 불가)."
    exit 1
fi

echo "══════════════════════════════════════════════════════════"
echo " PowerMacToys E2E — 약 1분 소요"
echo " 실행 중 키보드/마우스를 만지지 마세요 (포커스·클립보드 점유)"
echo "══════════════════════════════════════════════════════════"

# 1) 기존 인스턴스 정리 (핫키 선점 방지) — 있었으면 끝나고 복귀시킨다
WAS_RUNNING=0
pgrep -xq PowerMacToys && WAS_RUNNING=1
killall PowerMacToys 2>/dev/null || true
killall PasteCatcher 2>/dev/null || true

# 2) 앱 빌드 (키체인에 'PowerMacToys Dev' 인증서가 있으면 자동으로 안정 서명)
./build.sh

# 3) 테스트 하네스 컴파일
TMP=$(mktemp -d)
OUT="$TMP/catcher-out.txt"
swiftc -O Tests/E2E/PasteCatcher.swift -o "$TMP/PasteCatcher"
swiftc -O Tests/E2E/E2EDriver.swift -o "$TMP/E2EDriver"

# 4) 사용자 클립보드 백업 (문자열만 — 이미지 등은 복원 불가, 종료 시 안내)
OLDCLIP="$(pbpaste 2>/dev/null || true)"

CATCHER_PID=""
cleanup() {
    [[ -n "$CATCHER_PID" ]] && kill "$CATCHER_PID" 2>/dev/null || true
    killall PowerMacToys 2>/dev/null || true
    printf '%s' "$OLDCLIP" | pbcopy 2>/dev/null || true
    if [[ "$WAS_RUNNING" == 1 && -d /Applications/PowerMacToys.app ]]; then
        open -g /Applications/PowerMacToys.app 2>/dev/null || true
        echo "(기존에 실행 중이던 PowerMacToys를 다시 시작했습니다)"
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

# 5) 테스트 대상 앱(훅 켜서) + 수신 앱 실행
open -n dist/PowerMacToys.app --args -PPTestHook 1
"$TMP/PasteCatcher" "$OUT" &
CATCHER_PID=$!

for _ in $(seq 1 100); do
    [[ -f "$OUT.ready" ]] && break
    sleep 0.1
done
if [[ ! -f "$OUT.ready" ]]; then
    echo "❌ PasteCatcher가 10초 내에 준비되지 않았습니다."
    exit 1
fi
sleep 0.5   # 앱 쪽 훅·핫키 등록 정착

# 6) 시나리오 실행 (종료 코드: 0 통과 / 1 실패 / 2 캐너리 실패=권한 미설정)
STATUS=0
PP_OUT="$OUT" PP_CATCHER_PID="$CATCHER_PID" "$TMP/E2EDriver" || STATUS=$?

echo ""
echo "(클립보드는 테스트 전 문자열 내용으로 복원됩니다 — 이미지였다면 유실)"
exit "$STATUS"
