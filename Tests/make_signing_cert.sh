#!/bin/bash
# 'PlainPaste Dev' 자가서명 코드서명 인증서 1회 생성 — 이후 build.sh가 자동으로 사용.
#
# 왜 필요한가:
#   ad-hoc 서명(codesign -)은 빌드마다 서명이 달라져 macOS(TCC)가 재빌드된 앱을
#   "다른 앱"으로 취급 → 손쉬운 사용 권한이 매번 풀린다. 이름 있는 인증서로 서명을
#   고정하면 권한이 유지된다 — E2E 테스트 자동화(./Tests/e2e.sh)의 전제 조건.
#
# 실행 중 나오는 프롬프트 (모두 정상):
#   1) sudo 비밀번호        — 인증서를 시스템 신뢰 목록에 등록
#   2) 키체인/로그인 비밀번호 — codesign이 키를 프롬프트 없이 쓰도록 허용
#
# 스크립트가 실패하면 아래 "수동 절차"로 동일한 결과를 만들 수 있다 (~5분):
#   1. 키체인 접근(Keychain Access) 실행
#   2. 메뉴: 키체인 접근 → 인증서 지원 → 인증서 생성…
#      · 이름: PlainPaste Dev
#      · 신원 유형: 자체 서명 루트
#      · 인증서 유형: 코드 서명       → [생성]
#   3. (선택) 로그인 키체인에서 인증서 더블클릭 → 신뢰 → 코드 서명: 항상 신뢰
#   4. ./build.sh — "서명: PlainPaste Dev" 출력 확인
#
# 인증서 교체 후 1회: 시스템 설정 → 손쉬운 사용에서 기존 PlainPaste 항목 제거 후
# 새로 빌드·실행한 앱을 다시 추가해야 한다(서명이 바뀌었으므로 마지막 재부여).
set -euo pipefail

NAME="PlainPaste Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "✅ '$NAME' 인증서가 이미 있습니다 — 할 일 없음."
    echo "   ./build.sh 가 자동으로 사용합니다."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1) 코드서명 용도(EKU)의 자가서명 인증서 생성 (LibreSSL 호환을 위해 config 파일 방식)
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_code
prompt = no
[dn]
CN = $NAME
[v3_code]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:FALSE
EOF
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -config "$TMP/cert.cnf" -extensions v3_code 2>/dev/null

# 2) 로그인 키체인으로 가져오기 (codesign에 접근 허용)
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:plainpaste -name "$NAME"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P plainpaste -T /usr/bin/codesign

# 3) 코드서명 용도로 신뢰 등록 (sudo 1회)
echo "→ 인증서를 시스템 신뢰 목록에 등록합니다 (sudo 비밀번호)…"
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
    -k /Library/Keychains/System.keychain "$TMP/cert.pem"

# 4) codesign이 GUI 프롬프트 없이 키를 쓰도록 허용 (로그인 비밀번호 1회)
echo "→ 키체인 접근 허용 설정 (로그인 비밀번호)…"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" 2>/dev/null \
    || security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$KEYCHAIN"

# 5) 검증: 실제로 서명이 되는지 더미 바이너리로 확인
cp /bin/ls "$TMP/dummy"
if codesign --force --sign "$NAME" "$TMP/dummy" 2>/dev/null \
   && codesign --verify "$TMP/dummy" 2>/dev/null; then
    echo ""
    echo "✅ '$NAME' 인증서 생성·검증 완료."
    echo ""
    echo "다음 단계:"
    echo "  1. ./build.sh                            # 이제 자동으로 이 인증서로 서명"
    echo "  2. 시스템 설정 → 손쉬운 사용에서 기존 PlainPaste 항목 제거"
    echo "  3. 새로 빌드된 앱 실행 후 손쉬운 사용 권한 부여 (이번이 마지막 — 이후 재빌드에도 유지)"
else
    echo ""
    echo "❌ 서명 검증 실패 — 파일 상단 주석의 '수동 절차'(키체인 접근 GUI)를 사용하세요."
    exit 1
fi
