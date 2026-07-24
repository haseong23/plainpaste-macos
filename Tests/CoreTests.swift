import Cocoa
import Carbon

// PowerMacToys 순수 로직 유닛테스트.
// 의존성 0 기조를 지키려 XCTest 대신 초경량 러너를 쓴다.
// 실행:  ./Tests/run.sh   (Sources/PowerMacToysCore.swift 와 함께 컴파일됨)

private var passed = 0
private var failures = 0

private func expect(_ cond: Bool, _ msg: String, line: UInt = #line) {
    if cond { passed += 1 } else { failures += 1; print("  ✗ FAIL(L\(line)): \(msg)") }
}

private func expectEqual<T: Equatable>(_ got: T, _ want: T, _ msg: String, line: UInt = #line) {
    if got == want { passed += 1 }
    else { failures += 1; print("  ✗ FAIL(L\(line)): \(msg) — got \(got), want \(want)") }
}

@main
enum CoreTests {
    static func main() {

        // MARK: textPasteMode — 리포트 버그 회귀 가드 (직전 값 밀림 / ⌘C 두 번)
        // 핵심 불변식: 순수 텍스트는 절대 .rewrite 가 되면 안 된다(클립보드를 건드리면 안 됨).
        expectEqual(textPasteMode(plainString: "hello", hasRichText: false), .direct,
                    "순수 텍스트 → .direct (클립보드 무손상)")
        expectEqual(textPasteMode(plainString: "hello", hasRichText: true), .rewrite,
                    "서식 텍스트 → .rewrite")
        expectEqual(textPasteMode(plainString: " \n\t", hasRichText: false), .direct,
                    "공백/개행만이어도 비어있지 않으면 .direct")
        expectEqual(textPasteMode(plainString: "", hasRichText: false), .none,
                    "빈 문자열 → .none (이미지 분기로)")
        expectEqual(textPasteMode(plainString: "", hasRichText: true), .none,
                    "빈 문자열이면 서식 여부와 무관하게 .none")
        expectEqual(textPasteMode(plainString: nil, hasRichText: true), .none,
                    "문자열 없음 → .none")

        // MARK: carbonModifiers — NSEvent 플래그 → Carbon 마스크
        expectEqual(carbonModifiers(from: [.command]), UInt32(cmdKey), "command 매핑")
        expectEqual(carbonModifiers(from: [.shift]),   UInt32(shiftKey), "shift 매핑")
        expectEqual(carbonModifiers(from: [.option]),  UInt32(optionKey), "option 매핑")
        expectEqual(carbonModifiers(from: [.control]), UInt32(controlKey), "control 매핑")
        expectEqual(carbonModifiers(from: [.command, .option, .control]),
                    UInt32(cmdKey | optionKey | controlKey), "⌃⌥⌘ 조합 매핑")
        expectEqual(carbonModifiers(from: [.capsLock, .function]), UInt32(0),
                    "capsLock/function 등 무관한 플래그는 무시")

        // MARK: Shortcut 저장/복원 (독립 UserDefaults suite)
        let suiteName = "com.haseong23.powermactoys.tests"
        let d = UserDefaults(suiteName: suiteName)!
        d.removePersistentDomain(forName: suiteName)
        expectEqual(Shortcut.load(from: d).keyCode, Shortcut.default.keyCode,
                    "저장값 없으면 기본 단축키 keyCode")
        expectEqual(Shortcut.load(from: d).modifiers, Shortcut.default.modifiers,
                    "저장값 없으면 기본 단축키 modifiers")
        Shortcut(keyCode: 49, modifiers: UInt32(cmdKey | shiftKey)).save(to: d)
        expectEqual(Shortcut.load(from: d).keyCode, UInt32(49), "keyCode 저장·복원 왕복")
        expectEqual(Shortcut.load(from: d).modifiers, UInt32(cmdKey | shiftKey),
                    "modifiers 저장·복원 왕복")
        d.removePersistentDomain(forName: suiteName)

        // MARK: 핀 단축키 — keyPrefix로 붙여넣기 단축키와 독립 저장 (창 항상 위 고정)
        // 핵심 불변식: 두 단축키는 서로 다른 네임스페이스라 한쪽 저장이 다른 쪽을 오염시키지 않는다.
        d.removePersistentDomain(forName: suiteName)
        expect(Shortcut.load(from: d, keyPrefix: "pinShortcut", fallback: .pinDefault) == .pinDefault,
               "핀: 저장값 없으면 pinDefault(⌃⌥⌘T) 반환")
        expect(Shortcut.default != Shortcut.pinDefault,
               "기본 붙여넣기(⌃⌥⌘V)·핀(⌃⌥⌘T) 단축키는 서로 다름 — 등록 충돌 없음")
        Shortcut.default.save(to: d)                            // shortcut* 에 저장
        Shortcut.pinDefault.save(to: d, keyPrefix: "pinShortcut")  // pinShortcut* 에 저장
        expect(Shortcut.load(from: d) == .default,
               "붙여넣기 키는 shortcut* 에서만 읽음 (핀 저장의 영향 없음)")
        expect(Shortcut.load(from: d, keyPrefix: "pinShortcut", fallback: .default) == .pinDefault,
               "핀 키는 pinShortcut* 에서만 읽음 (독립 네임스페이스)")
        Shortcut(keyCode: 50, modifiers: UInt32(controlKey)).save(to: d, keyPrefix: "pinShortcut")
        expect(Shortcut.load(from: d, keyPrefix: "pinShortcut", fallback: .pinDefault)
               == Shortcut(keyCode: 50, modifiers: UInt32(controlKey)),
               "핀 단축키 저장·복원 왕복 (사용자 재지정 대비)")
        expect(Shortcut.load(from: d) == .default,
               "핀 단축키를 바꿔도 붙여넣기 단축키는 그대로")
        d.removePersistentDomain(forName: suiteName)

        // MARK: Shortcut.display — modifier 순서(⌃⌥⇧⌘) + 레이아웃 독립 특수키
        expectEqual(Shortcut(keyCode: 49,
                             modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)).display,
                    "⌃⌥⇧⌘Space", "modifier 표시 순서 + Space")
        expectEqual(Shortcut(keyCode: 36, modifiers: UInt32(cmdKey)).display,
                    "⌘↩", "Return 특수키 표시")
        expectEqual(Shortcut(keyCode: 53, modifiers: UInt32(controlKey)).display,
                    "⌃⎋", "ESC 특수키 표시")

        // MARK: ocrUpscaleFactor — [1.0, cap] 범위, 긴 변 target px 목표
        expectEqual(ocrUpscaleFactor(maxDim: 0),    1.0, "0 크기 → 1.0 (업스케일 안 함)")
        expectEqual(ocrUpscaleFactor(maxDim: 100),  3.0, "아주 작은 이미지 → 3.0 상한")
        expectEqual(ocrUpscaleFactor(maxDim: 500),  3.0, "500px → 4.0이지만 3.0 상한")
        expectEqual(ocrUpscaleFactor(maxDim: 1000), 2.0, "1000px → 2.0")
        expectEqual(ocrUpscaleFactor(maxDim: 2000), 1.0, "2000px → 1.0")
        expectEqual(ocrUpscaleFactor(maxDim: 8000), 1.0, "큰 이미지 → 1.0 하한")
        expectEqual(ocrUpscaleFactor(maxDim: 1000, target: 3000, cap: 4.0), 3.0,
                    "target/cap 파라미터 반영 (벤치 A/B용)")
        expectEqual(ocrUpscaleFactor(maxDim: 100, target: 2000, cap: 4.0), 4.0,
                    "cap 4.0 상한")

        // MARK: groupOCRLines — 줄 그룹핑 (원점 좌하단: y 클수록 위)
        let vertical = [
            (string: "bottom", box: CGRect(x: 0.1, y: 0.10, width: 0.2, height: 0.05)),
            (string: "top",    box: CGRect(x: 0.1, y: 0.90, width: 0.2, height: 0.05)),
            (string: "middle", box: CGRect(x: 0.1, y: 0.50, width: 0.2, height: 0.05)),
        ]
        expectEqual(groupOCRLines(vertical), ["top", "middle", "bottom"], "위→아래 정렬")

        // 같은 줄이 가로 간격 때문에 관측 2개로 쪼개진 경우 → 공백으로 한 줄 결합
        // (과거 orderOCRStrings는 정렬만 하고 줄바꿈으로 분리 — 표·메뉴가 세로로 흩어지던 문제)
        let sameLine = [
            (string: "right", box: CGRect(x: 0.80, y: 0.500, width: 0.1, height: 0.02)),
            (string: "left",  box: CGRect(x: 0.10, y: 0.505, width: 0.1, height: 0.02)),
        ]
        expectEqual(groupOCRLines(sameLine), ["left right"],
                    "같은 줄(세로 겹침 ≥ 50%)은 왼→오 공백 결합")

        // 빽빽한 줄: midY 차 0.008 < 과거 임계값 0.01이지만 세로로 안 겹침 → 별개 줄 유지
        let dense = [
            (string: "line2", box: CGRect(x: 0.1, y: 0.492, width: 0.5, height: 0.006)),
            (string: "line1", box: CGRect(x: 0.1, y: 0.500, width: 0.5, height: 0.006)),
        ]
        expectEqual(groupOCRLines(dense), ["line1", "line2"],
                    "빽빽한 인접 줄은 midY가 가까워도 합치지 않음")

        // 베이스라인 흔들림: midY 차이가 있어도 겹침이 크면 같은 줄
        let jitter = [
            (string: "second", box: CGRect(x: 0.40, y: 0.504, width: 0.2, height: 0.020)),
            (string: "first",  box: CGRect(x: 0.10, y: 0.500, width: 0.2, height: 0.020)),
        ]
        expectEqual(groupOCRLines(jitter), ["first second"],
                    "베이스라인이 살짝 어긋나도 같은 줄로 결합")
        expectEqual(groupOCRLines([]), [], "빈 입력 → 빈 결과")

        // MARK: looksLikeCode — 교정 끄기 재인식 판정 (OCREngine의 codeAwareRetry)
        expect(!looksLikeCode("안녕하세요 오늘 회의는 세 시에 시작합니다"), "한글 산문 → 산문")
        expect(!looksLikeCode("The quick brown fox jumps over the lazy dog"), "영어 산문 → 산문")
        expect(looksLikeCode("let x = pasteText(plain, count: 3);"), "코드 라인 → 코드")
        expect(looksLikeCode("https://github.com/haseong23/plainpaste-macos"), "URL → 코드")
        expect(looksLikeCode("$ git commit -m \"fix\""), "쉘 프롬프트 → 코드")
        expect(looksLikeCode("0x1F 플래그 값"), "16진수 포함 짧은 텍스트 → 코드")
        expect(!looksLikeCode("자세한 내용은 https://example.com 참고. " +
                              String(repeating: "일반적인 산문 문장이 길게 이어집니다. ", count: 5)),
               "긴 산문 속 URL 하나 → 산문 유지 (전체 교정을 끄지 않음)")
        expect(!looksLikeCode("no"), "너무 짧은 텍스트 → 산문")

        // MARK: 색상 HEX 변환 (ColorPicker)
        expectEqual(hexFromComponents(0, 0, 0), "#000000", "검정")
        expectEqual(hexFromComponents(1, 1, 1), "#FFFFFF", "흰색")
        expectEqual(hexFromComponents(1, 0, 0), "#FF0000", "빨강")
        expectEqual(hexFromComponents(0, 1, 0), "#00FF00", "초록")
        expectEqual(hexFromComponents(0, 0, 1), "#0000FF", "파랑")
        expectEqual(hexFromComponents(-0.5, 2.0, 0.5), "#00FF80",
                    "범위 밖 성분은 [0,255] 클램프 + 반올림")
        expectEqual(rgbFromHex("#FF0000")?.r, 255, "HEX 파싱 R")
        expectEqual(rgbFromHex("00FF00")?.g, 255, "# 없어도 파싱, G")
        expectEqual(rgbFromHex("#0000ff")?.b, 255, "소문자 HEX 파싱, B")
        expect(rgbFromHex("#FFF") == nil, "3자리 축약형은 미지원 → nil")
        expect(rgbFromHex("nothex") == nil, "16진수가 아니면 nil")
        // 왕복: 성분 → HEX → 성분
        let round = rgbFromHex(hexFromComponents(0.2, 0.4, 0.6))
        expect(round?.r == 51 && round?.g == 102 && round?.b == 153,
               "hexFromComponents ↔ rgbFromHex 왕복 (0.2/0.4/0.6 → 51/102/153)")

        // MARK: 결과
        print("")
        print(failures == 0
              ? "✅ 모든 테스트 통과 — \(passed) passed"
              : "❌ \(failures) failed, \(passed) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
