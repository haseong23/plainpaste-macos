# PlainPaste

전역 단축키 하나로 **어디서든 서식 없는 Plain Text 붙여넣기**를 실행하는 macOS 메뉴바 앱.

- 기본 단축키: **⌃⌥⌘V** (메뉴바 아이콘 → "단축키 변경…"으로 자유롭게 재지정)
- 클립보드가 **이미지(스크린샷 등)면 자동으로 OCR**해서 인식된 텍스트를 붙여넣기 — 온디바이스 Vision, 한글·영문 (단축키 하나로 글자/이미지 자동 분기)
- 의존성 0, 단일 Swift 파일, 바이너리 수백 KB — Dock 아이콘 없이 메뉴바에만 상주
- 붙여넣기 후 **원본 클립보드(서식·이미지 포함)를 자동 복원** — 클립보드를 훼손하지 않음

## 설치 — 한 줄이면 끝 (권장)

터미널에 아래 한 줄을 붙여넣고 Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/haseong23/plainpaste-macos/main/install.sh | bash
```

소스를 그 자리에서 컴파일해 설치하므로 **서명 없는 앱인데도 Gatekeeper 경고("확인되지 않은 개발자")가 전혀 뜨지 않습니다.** 내려받은 `.app`이 아니라 방금 만든 바이너리라 quarantine 딱지가 붙지 않기 때문입니다.

> 처음이라 Xcode Command Line Tools가 없으면 설치 창이 한 번 뜹니다(Apple 공식·무료). '설치'를 누르면 나머지는 자동으로 이어집니다.

레포를 이미 받아두었다면 클론 폴더에서 이렇게 실행해도 동일합니다:

```bash
./install.sh
```

설치가 끝나면 앱이 바로 실행되고, 처음 한 번 **손쉬운 사용** 권한 허용 창이 뜹니다(아래 [최초 실행 시 권한](#최초-실행-시-권한) 참고).

## 설치 — DMG (수동)

서명이 없는 앱이라 DMG로 받으면 macOS Sequoia(15) 이후에는 **우클릭 → 열기**로 열리지 않고, 아래처럼 시스템 설정에서 한 번 허용해야 합니다(그래서 위의 한 줄 설치를 권장합니다):

1. [Releases](../../releases)에서 `PlainPaste-1.1.dmg`를 받아 열고, **PlainPaste를 Applications 폴더로 드래그**
2. Applications의 PlainPaste를 한 번 더블클릭 → "확인되지 않은 개발자" 경고 → **완료/취소**
3. **시스템 설정 → 개인정보 보호 및 보안** → 스크롤 맨 아래 *"'PlainPaste'을(를) 열 수 없습니다"* 옆 **[그래도 열기]** 클릭 → 다시 한 번 **[열기]**

터미널이 편하다면 이 두 줄이 위 3단계를 대신합니다:

```bash
xattr -dr com.apple.quarantine /Applications/PlainPaste.app
open /Applications/PlainPaste.app
```

## 소스에서 직접 빌드

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
2. 클립보드에 **글자가 있으면** plain string만 추출; **이미지면** Vision으로 **OCR**해 텍스트로 변환(작은 글씨는 업스케일 후 인식) → 클립보드에 재기록
3. **물리 modifier 키가 모두 놓일 때까지 대기**(최대 1초) 후 활성 앱에 순수 ⌘V 전송
   — 단축키를 누른 손이 아직 ⌃⌥⌘를 누르고 있어도 엉뚱한 조합으로 전달되지 않음
4. 전송 후 0.3초 뒤 원본 서식 클립보드 복원 (그 사이 새로 복사했으면 건드리지 않음)

## 메뉴

- **현재 단축키** 및 안내(이미지는 자동 OCR) 표시
- **단축키 변경…** — 창이 뜬 상태에서 새 조합을 누르면 즉시 저장 (⌘/⌥/⌃ 중 1개 이상 필수, ESC 취소)
- **로그인 시 자동 시작** 토글 (macOS 13+)
- **종료**
