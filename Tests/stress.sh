#!/bin/bash
# PlainPaste 스트레스·소크 테스트 — 반복 붙여넣기·앱 전환·트리거 다양화에서
# 씹힘(누락)·밀림·중복·클립보드 오염이 생기는지 실기기에서 센다.
#
#   ./Tests/stress.sh                 # 기본 (반복 40회 · 소크 150회, 약 4분)
#   PP_CYCLES=15 PP_SOAK=40 ./Tests/stress.sh    # 빠른 확인 (약 1분)
#   PP_APP=/Applications/PlainPaste.app ./Tests/stress.sh   # 이미 권한이 있는 설치본으로
#
# PP_APP: 시험 대상 .app 경로 (기본 dist/PlainPaste.app — 이 스크립트가 빌드한 것).
#   ad-hoc 서명은 빌드마다 cdhash가 바뀌어 손쉬운 사용 권한이 풀린다. 권한을 이미 받은
#   설치본으로 돌리고 싶을 때 이 변수를 쓴다 — 단 그건 **현재 소스가 아닌 설치된 코드**를
#   재는 것이므로, 변경 검증에는 dist 경로에 권한을 부여하고 기본값으로 돌려야 한다.
#
# E2E(Tests/e2e.sh)와의 차이: e2e는 시나리오당 1회로 "계약이 맞는가"를 보고,
# 이 스크립트는 반복·경합·앱 전환에서 "씹히거나 오염되는가"를 센다.
#
# 1회 설정은 e2e.sh와 동일 (TESTPLAN.md 참고):
#   1. ./Tests/make_signing_cert.sh   — 서명 고정(재빌드해도 권한 유지)
#   2. 빌드된 앱에 손쉬운 사용 권한 부여
#   3. (선택) 터미널에도 손쉬운 사용 권한 — 없으면 R5(실제 단축키)만 skip
#
# 주의: 이 테스트는 실행 내내 포커스·클립보드·키 입력을 독점한다. 작업 중에는 돌리지 말 것.
#   • 시작 전 사람의 입력이 2초간 없을 때까지 기다린다(최대 30초, 넘으면 exit 3).
#   • 실행 중 하드웨어 입력이 섞인 회차는 '간섭'으로 무효 처리한다 — 결함으로 세지 않는다.
#   • 간섭이 한 시나리오에서 25%를 넘으면 중단한다(exit 3). 더 돌려도 쓰레기 수치만 쌓인다.
#   판별 근거: 합성 이벤트는 .combinedSessionState, 사람의 입력은 .hidSystemState 로 잡힌다.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(launchctl managername 2>/dev/null)" != "Aqua" ]]; then
    echo "❌ GUI 로그인 세션에서만 실행할 수 있습니다 (SSH/헤드리스 불가)."
    exit 1
fi

CYCLES="${PP_CYCLES:-40}"
SOAK="${PP_SOAK:-150}"
APP="${PP_APP:-dist/PlainPaste.app}"

echo "══════════════════════════════════════════════════════════"
echo " PlainPaste 스트레스 — 반복 ${CYCLES}회 · 소크 ${SOAK}회"
echo " 대상: ${APP}"
echo " 실행 중 키보드/마우스를 만지지 마세요 (포커스·클립보드 점유)"
echo " 사람의 입력이 섞이면 그 회차는 '간섭'으로 무효 처리됩니다"
echo "══════════════════════════════════════════════════════════"

WAS_RUNNING=0
pgrep -xq PlainPaste && WAS_RUNNING=1
killall PlainPaste 2>/dev/null || true
killall PasteCatcher 2>/dev/null || true

if [[ "$APP" == "dist/PlainPaste.app" ]]; then
    ./build.sh
elif [[ ! -d "$APP" ]]; then
    echo "❌ 대상 앱이 없습니다: $APP"
    exit 1
else
    echo "(빌드 건너뜀 — 외부 앱을 대상으로 지정했습니다: $APP)"
fi

TMP=$(mktemp -d)
OUT_A="$TMP/catcher-a.txt"
OUT_B="$TMP/catcher-b.txt"
swiftc -O Tests/E2E/PasteCatcher.swift -o "$TMP/PasteCatcher"
swiftc -O Tests/E2E/StressDriver.swift -o "$TMP/StressDriver"

OLDCLIP="$(pbpaste 2>/dev/null || true)"

PID_A=""
PID_B=""
cleanup() {
    [[ -n "$PID_A" ]] && kill "$PID_A" 2>/dev/null || true
    [[ -n "$PID_B" ]] && kill "$PID_B" 2>/dev/null || true
    killall PlainPaste 2>/dev/null || true
    printf '%s' "$OLDCLIP" | pbcopy 2>/dev/null || true
    if [[ "$WAS_RUNNING" == 1 && -d /Applications/PlainPaste.app ]]; then
        open -g /Applications/PlainPaste.app 2>/dev/null || true
        echo "(기존에 실행 중이던 PlainPaste를 다시 시작했습니다)"
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

open -n "$APP" --args -PPTestHook 1

# 캐처 2개 — 앱 전환(R4)용. 서로 포커스를 뺏지 않도록 자동 재활성화를 끄고,
# 포커스 주도권은 러너(StressDriver)가 명시적으로 갖는다.
PP_CATCHER_OFFSET=-260 "$TMP/PasteCatcher" "$OUT_A" --no-autofocus &
PID_A=$!
PP_CATCHER_OFFSET=260 "$TMP/PasteCatcher" "$OUT_B" --no-autofocus &
PID_B=$!

for _ in $(seq 1 100); do
    [[ -f "$OUT_A.ready" && -f "$OUT_B.ready" ]] && break
    sleep 0.1
done
if [[ ! -f "$OUT_A.ready" || ! -f "$OUT_B.ready" ]]; then
    echo "❌ PasteCatcher 2개가 10초 내에 준비되지 않았습니다."
    exit 1
fi
sleep 2     # 앱 쪽 훅 옵저버·RegisterEventHotKey 등록 정착 (0.5초는 부족했다 — 실측)

STATUS=0
PP_OUT_A="$OUT_A" PP_PID_A="$PID_A" \
PP_OUT_B="$OUT_B" PP_PID_B="$PID_B" \
PP_CYCLES="$CYCLES" PP_SOAK="$SOAK" \
PP_APP_PATH="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")" \
    "$TMP/StressDriver" || STATUS=$?

echo ""
echo "(클립보드는 테스트 전 문자열 내용으로 복원됩니다 — 이미지였다면 유실)"
exit "$STATUS"
