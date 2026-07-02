# PlainPaste

전역 단축키 하나로 **어디서든 서식 없는 Plain Text 붙여넣기**를 실행하는 macOS 메뉴바 앱.

- 기본 단축키: **⌘⇧V** (메뉴바 아이콘 → "단축키 변경…"으로 자유롭게 재지정)
- 의존성 0, 단일 Swift 파일, 바이너리 수백 KB — Dock 아이콘 없이 메뉴바에만 상주
- 붙여넣기 후 **원본 클립보드(서식 포함)를 자동 복원** — 클립보드를 훼손하지 않음

## 설치

### DMG (권장)

[Releases](../../releases)에서 `PlainPaste-1.0.dmg`를 받아 열고, PlainPaste를 **Applications 폴더로 드래그**하세요.

> ad-hoc 서명 앱이라 첫 실행 시 Gatekeeper 경고가 뜹니다.
> **Applications 폴더의 PlainPaste를 우클릭 → 열기 → 열기**로 한 번만 허용하면 됩니다.

### 소스에서 빌드

```bash
./build.sh                          # dist/PlainPaste.app 생성
cp -R dist/PlainPaste.app /Applications/
open /Applications/PlainPaste.app

./make_dmg.sh                       # (선택) 배포용 dist/PlainPaste-<버전>.dmg 생성
```

빌드는 맥 내장 `swiftc` / `hdiutil`만 사용하며 외부 의존성이 없습니다.

## 최초 실행 시 권한

키 입력(⌘V)을 시스템에 전달해야 하므로 **손쉬운 사용** 권한이 필요합니다.
첫 실행 시 안내 창이 뜨면: 시스템 설정 → 개인정보 보호 및 보안 → **손쉬운 사용** → PlainPaste 켜기.

> 재빌드하면 ad-hoc 서명이 바뀌어 권한이 풀릴 수 있습니다. 그 경우 목록에서 PlainPaste를 제거 후 다시 추가하세요.

## 동작 방식

1. Carbon `RegisterEventHotKey`로 전역 단축키 수신 (이벤트 탭 없이 — 가장 가볍고 입력 지연 없음)
2. 클립보드에서 plain string만 추출해 클립보드에 재기록
3. **물리 modifier 키가 모두 놓일 때까지 대기**(최대 1초) 후 활성 앱에 순수 ⌘V 전송
   — 단축키를 누른 손이 아직 ⌃⌥⌘를 누르고 있어도 엉뚱한 조합으로 전달되지 않음
4. 전송 후 0.3초 뒤 원본 서식 클립보드 복원 (그 사이 새로 복사했으면 건드리지 않음)

## 메뉴

- **현재 단축키** 표시
- **단축키 변경…** — 창이 뜬 상태에서 새 조합을 누르면 즉시 저장 (⌘/⌥/⌃ 중 1개 이상 필수, ESC 취소)
- **로그인 시 자동 시작** 토글 (macOS 13+)
- **종료**
