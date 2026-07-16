#!/bin/bash
# OCR 정확도 벤치 실행 — 앱과 동일한 인식 경로(OCREngine)를 변형별로 CER 채점.
# 권한 불요·GUI 불요. 자세한 설명은 Tests/Bench/OCRBench.swift 상단 주석.
#
#   ./Tests/ocr_bench.sh             # 요약 표
#   ./Tests/ocr_bench.sh --verbose   # 케이스별 인식 결과 전체 출력
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$(mktemp -d)/ocr-bench"
swiftc -O Sources/PlainPasteCore.swift Sources/OCREngine.swift Tests/Bench/OCRBench.swift -o "$BIN"
"$BIN" "$@"
