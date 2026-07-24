#!/bin/bash
# PowerMacToys 원클릭 설치 스크립트
# ─────────────────────────────────────────────────────────────────────────────
# 서명(Apple Developer 인증)이 없는 앱이라도 Gatekeeper 경고 없이 설치합니다.
# 핵심: DMG를 "내려받는" 대신 소스를 그 자리에서 컴파일하기 때문에,
#       결과 바이너리에 quarantine 딱지가 붙지 않아 우클릭·"열기 확인" 절차가 통째로 사라집니다.
#
# 사용법 (둘 중 아무거나):
#   A) 레포를 이미 받았다면:   ./install.sh
#   B) 한 줄 설치(터미널에):
#      curl -fsSL https://raw.githubusercontent.com/haseong23/plainpaste-macos/main/install.sh | bash
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO="https://github.com/haseong23/plainpaste-macos.git"
APP_NAME="PowerMacToys"

say()  { printf "\033[1;34m▸\033[0m %s\n" "$1"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$1"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$1"; }

# ── 1. Xcode Command Line Tools(swiftc) 확인 — 없으면 설치 안내 ────────────────
if ! command -v swiftc >/dev/null 2>&1; then
  warn "Swift 컴파일러가 없어 Command Line Tools를 설치합니다 (Apple 공식, 무료)."
  say  "설치 창이 뜨면 '설치'를 눌러 주세요. 완료되면 이 스크립트를 다시 실행합니다."
  xcode-select --install 2>/dev/null || true
  # GUI 설치가 끝날 때까지 대기 (최대 20분)
  for _ in $(seq 1 240); do
    command -v swiftc >/dev/null 2>&1 && break
    sleep 5
  done
  command -v swiftc >/dev/null 2>&1 || { warn "설치 후 다시 실행해 주세요: ./install.sh"; exit 1; }
fi
ok "Swift 컴파일러 확인"

# ── 2. 소스 위치 결정 — 레포 안에서 실행 중이면 그대로, 아니면(=curl 파이프) clone ──
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE:-}" ] && [ -f "${BASH_SOURCE[0]:-/nonexistent}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

CLEANUP_DIR=""
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/build.sh" ]; then
  SRC_DIR="$SCRIPT_DIR"
  say "레포에서 직접 빌드합니다: $SRC_DIR"
else
  SRC_DIR="$(mktemp -d)/plainpaste-macos"
  CLEANUP_DIR="$(dirname "$SRC_DIR")"
  trap '[ -n "$CLEANUP_DIR" ] && rm -rf "$CLEANUP_DIR"' EXIT
  say "소스를 내려받습니다 (git clone)…"
  git clone --depth 1 "$REPO" "$SRC_DIR" >/dev/null 2>&1
fi

# ── 3. 빌드 (소스 → ad-hoc 서명된 .app, quarantine 없음) ──────────────────────
say "컴파일 중…"
( cd "$SRC_DIR" && ./build.sh >/dev/null )
ok "빌드 완료"

# ── 4. 기존 인스턴스 종료 후 /Applications 로 설치 ────────────────────────────
osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 1
rm -rf "/Applications/$APP_NAME.app"
cp -R "$SRC_DIR/dist/$APP_NAME.app" /Applications/
# 혹시 레포를 zip으로 받아 quarantine이 묻었어도 확실히 제거
xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app" >/dev/null 2>&1 || true
ok "설치 완료: /Applications/$APP_NAME.app"

# ── 5. 실행 ───────────────────────────────────────────────────────────────────
open "/Applications/$APP_NAME.app"
echo
ok "$APP_NAME 실행됨 — 화면 오른쪽 위 메뉴바에 아이콘이 생겼습니다."
say "처음 한 번, 붙여넣기 키 전달을 위해 '손쉬운 사용' 권한 허용 창이 뜹니다."
say "  시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 → $APP_NAME 켜기"
say "기본 단축키는 ⌃⌥⌘V(서식 없는 붙여넣기) · ⌃⌥⌘T(창 항상 위 고정) 입니다."
