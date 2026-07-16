#!/bin/bash
# PlainPaste 순수 로직 유닛테스트 실행 — 앱 본체(main.swift) 없이 Core만 컴파일
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$(mktemp -d)/plainpaste-tests"
swiftc -O Sources/PlainPasteCore.swift Tests/CoreTests.swift -o "$BIN"
"$BIN"
