import Cocoa
import Carbon

// MARK: - 순수 로직 (UI/시스템 부수효과 없음 — 유닛테스트 대상)
//
// main.swift에서 분리한, GUI 세션 없이도 결정 가능한 로직만 모은 파일.
// 앱 빌드(build.sh)와 테스트(Tests/run.sh) 양쪽이 이 파일을 함께 컴파일한다.

// MARK: 단축키 모델 (Carbon modifier 기준으로 저장)

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon: cmdKey/shiftKey/optionKey/controlKey

    // 붙여넣기(smartPaste) 기본 단축키 — ⌃⌥⌘V
    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_V),
                                    modifiers: UInt32(cmdKey | optionKey | controlKey))

    // 창 항상 위 고정(WindowPinner) 기본 단축키 — ⌃⌥⌘T (T = Top)
    static let pinDefault = Shortcut(keyCode: UInt32(kVK_ANSI_T),
                                     modifiers: UInt32(cmdKey | optionKey | controlKey))

    // 화면 영역 텍스트 추출(TextExtractor) 기본 단축키 — ⌃⌥⌘O (O = OCR)
    static let ocrDefault = Shortcut(keyCode: UInt32(kVK_ANSI_O),
                                     modifiers: UInt32(cmdKey | optionKey | controlKey))

    // 화면 색상 추출(ColorPicker) 기본 단축키 — ⌃⌥⌘C (C = Color)
    static let colorDefault = Shortcut(keyCode: UInt32(kVK_ANSI_C),
                                       modifiers: UInt32(cmdKey | optionKey | controlKey))

    // keyPrefix로 여러 단축키를 독립 네임스페이스에 저장한다
    // (붙여넣기="shortcut", 핀="pinShortcut"). 저장값이 없으면 fallback 반환.
    static func load(from d: UserDefaults = .standard,
                     keyPrefix: String = "shortcut",
                     fallback: Shortcut = .default) -> Shortcut {
        guard d.object(forKey: keyPrefix + "KeyCode") != nil else { return fallback }
        return Shortcut(keyCode: UInt32(d.integer(forKey: keyPrefix + "KeyCode")),
                        modifiers: UInt32(d.integer(forKey: keyPrefix + "Modifiers")))
    }

    func save(to d: UserDefaults = .standard, keyPrefix: String = "shortcut") {
        d.set(Int(keyCode), forKey: keyPrefix + "KeyCode")
        d.set(Int(modifiers), forKey: keyPrefix + "Modifiers")
    }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + keyName(for: keyCode)
    }
}

func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.command) { m |= UInt32(cmdKey) }
    if flags.contains(.shift)   { m |= UInt32(shiftKey) }
    if flags.contains(.option)  { m |= UInt32(optionKey) }
    if flags.contains(.control) { m |= UInt32(controlKey) }
    return m
}

// 키코드 → 표시 문자열 (현재 키보드 레이아웃 기준)
func keyName(for keyCode: UInt32) -> String {
    let special: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤",
        114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    if let s = special[keyCode] { return s }

    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return "Key\(keyCode)" }

    let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
    var deadKeyState: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var length = 0
    let status = layoutData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
        let layout = ptr.bindMemory(to: UCKeyboardLayout.self).baseAddress!
        return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                              UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                              &deadKeyState, chars.count, &length, &chars)
    }
    guard status == noErr, length > 0 else { return "Key\(keyCode)" }
    return String(utf16CodeUnits: chars, count: length).uppercased()
}

// MARK: 붙여넣기 분기 결정 — 클립보드를 덮어쓸지 여부의 핵심 규칙
//
// 이 규칙이 리포트된 두 버그의 회귀 방지선이다:
//   • 순수 텍스트(.direct)는 클립보드를 절대 건드리지 않는다 → "직전 값 밀림"·"⌘C 두 번" 회피.
//   • 서식 텍스트(.rewrite)일 때만 플레인으로 재작성(=클립보드 덮어씀).

enum TextPasteMode: Equatable {
    case direct    // 순수 텍스트 그대로 — 클립보드를 건드리지 않고 ⌘V만 전송
    case rewrite   // 서식 텍스트 — 플레인으로 재작성 후 붙여넣기 (클립보드를 플레인으로 덮어씀)
    case none      // 쓸 만한 텍스트 없음 — 이미지/OCR 분기로 넘어감
}

func textPasteMode(plainString: String?, hasRichText: Bool) -> TextPasteMode {
    guard let s = plainString, !s.isEmpty else { return .none }
    return hasRichText ? .rewrite : .direct
}

// MARK: OCR 보조 계산

// 작은 이미지 확대 배율. 긴 변이 target px가 되도록 하되 [1.0, cap]으로 제한.
// (기본값 2000/3.0 = 앱 실사용 설정, 파라미터는 Tests/Bench의 A/B 측정용)
func ocrUpscaleFactor(maxDim: Int, target: Double = 2000.0, cap: Double = 3.0) -> Double {
    guard maxDim > 0 else { return 1.0 }
    return min(cap, max(1.0, target / Double(maxDim)))
}

// Vision 관측 결과를 시각적 줄로 재구성 — 세로로 충분히 겹치는 관측은 같은 줄.
// 줄 순서는 위→아래, 줄 안은 왼→오로 정렬해 공백으로 결합한다.
// Vision 타입에 의존하지 않도록 (문자열, boundingBox)만 받는다 — boundingBox 원점은 좌하단.
//
// midY 고정 임계값(과거 0.01) 대신 박스 높이 기반 겹침 비율을 쓰는 이유:
//   • 표·메뉴처럼 가로 간격 때문에 쪼개진 같은 줄 관측이 줄바꿈으로 분리되던 문제 해결
//   • 줄이 빽빽한 캡처(터미널 등)에서 인접 줄이 한 줄로 합쳐지는 오판 방지
func groupOCRLines(_ items: [(string: String, box: CGRect)]) -> [String] {
    let sorted = items.sorted { $0.box.midY > $1.box.midY }   // 위(y 큰 쪽)부터
    var lines: [(band: CGRect, members: [(string: String, box: CGRect)])] = []
    for item in sorted {
        if var last = lines.last, verticalOverlapRatio(last.band, item.box) >= 0.5 {
            last.members.append(item)
            last.band = last.band.union(item.box)
            lines[lines.count - 1] = last
        } else {
            lines.append((item.box, [item]))
        }
    }
    return lines.map { line in
        line.members.sorted { $0.box.minX < $1.box.minX }.map { $0.string }.joined(separator: " ")
    }
}

// 두 박스의 세로 겹침 / 낮은 쪽 높이 (0 = 안 겹침, 1 = 완전 포함)
private func verticalOverlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
    let minH = min(a.height, b.height)
    guard minH > 0 else { return abs(a.midY - b.midY) < 1e-9 ? 1 : 0 }   // 높이 0 보호
    return max(0, overlap / minH)
}

// MARK: 코드 텍스트 감지 — 언어 교정을 끌지 결정

// 인식 결과가 코드/터미널/URL 텍스트처럼 보이는가.
// 그렇다면 Vision의 언어 교정(사전 단어로의 "정정")이 식별자·플래그·해시를
// 훼손했을 가능성이 높아, 교정 없이 재인식하는 편이 원문에 가깝다 (OCREngine에서 사용).
func looksLikeCode(_ s: String) -> Bool {
    let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count >= 4 else { return false }

    let symbols = Set("{}[]()<>=;:|\\/_`~@#$%&*+")
    let nonSpace = text.filter { !$0.isWhitespace }
    guard !nonSpace.isEmpty else { return false }
    let density = Double(nonSpace.filter { symbols.contains($0) }.count) / Double(nonSpace.count)

    // 짧은 텍스트에서 밀도만으로 애매할 때를 위한 강한 신호
    let strongMarkers = ["://", "()", "{", "};", "->", "=>", "#!", "0x"]
    var strongHits = strongMarkers.filter { text.contains($0) }.count
    if text.hasPrefix("$ ") || text.contains("\n$ ") { strongHits += 1 }   // 쉘 프롬프트

    return density >= 0.06 || strongHits >= 2 || (strongHits >= 1 && text.count <= 120)
}

// MARK: 색상 HEX 변환 (ColorPicker — 순수 로직)

// sRGB 0~1 성분 → "#RRGGBB". 각 채널은 반올림 후 [0,255]로 클램프.
func hexFromComponents(_ r: Double, _ g: Double, _ b: Double) -> String {
    func channel(_ v: Double) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
    return String(format: "#%02X%02X%02X", channel(r), channel(g), channel(b))
}

// "#RRGGBB" 또는 "RRGGBB" → (r,g,b) 0~255. 6자리 16진수가 아니면 nil (스와치 그리기용).
func rgbFromHex(_ hex: String) -> (r: Int, g: Int, b: Int)? {
    let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
    return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
}

// MARK: 고급 붙여넣기 변환 (Advanced Paste — 순수 로직)
//
// 클립보드 텍스트를 여러 포맷으로 변환한다. 반환 nil = 변환 실패(예: 잘못된 Base64) → 호출부에서 beep.
// 모두 부수효과 없는 순수 함수라 유닛테스트로 고정한다(CoreTests).

func transformUppercase(_ s: String) -> String { s.uppercased() }
func transformLowercase(_ s: String) -> String { s.lowercased() }
func transformTrim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

// 연속된 공백·탭·개행을 단일 공백으로 합치고 양끝을 정리
func transformCollapseWhitespace(_ s: String) -> String {
    s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

// 여러 줄 → 한 줄: 각 줄을 트림하고 빈 줄은 버린 뒤 공백으로 결합
func transformJoinLines(_ s: String) -> String {
    s.replacingOccurrences(of: "\r\n", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

func transformBase64Encode(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

func transformBase64Decode(_ s: String) -> String? {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: trimmed),
          let decoded = String(data: data, encoding: .utf8) else { return nil }
    return decoded
}

func transformURLEncode(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
}

func transformURLDecode(_ s: String) -> String? { s.removingPercentEncoding }

// 메뉴 구성용 레지스트리 — main.swift가 이 순서대로 "고급 붙여넣기" 서브메뉴를 만든다.
struct PasteTransform {
    let title: String
    let apply: (String) -> String?   // nil = 변환 실패
}

let pasteTransforms: [PasteTransform] = [
    PasteTransform(title: "대문자로")            { transformUppercase($0) },
    PasteTransform(title: "소문자로")            { transformLowercase($0) },
    PasteTransform(title: "양끝 공백 다듬기")     { transformTrim($0) },
    PasteTransform(title: "여러 공백 → 하나로")   { transformCollapseWhitespace($0) },
    PasteTransform(title: "여러 줄 → 한 줄로")    { transformJoinLines($0) },
    PasteTransform(title: "Base64 인코딩")       { transformBase64Encode($0) },
    PasteTransform(title: "Base64 디코딩")       { transformBase64Decode($0) },
    PasteTransform(title: "URL 인코딩")          { transformURLEncode($0) },
    PasteTransform(title: "URL 디코딩")          { transformURLDecode($0) },
]
