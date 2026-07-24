#!/bin/bash
# PowerMacToys 순수 로직 유닛테스트 실행 — 앱 본체(main.swift) 없이 Core만 컴파일
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$(mktemp -d)/powermactoys-tests"
swiftc -O Sources/PowerMacToysCore.swift Tests/CoreTests.swift -o "$BIN"
"$BIN"
