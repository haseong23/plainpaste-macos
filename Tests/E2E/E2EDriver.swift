import Cocoa
import Carbon

// PlainPaste E2E 시나리오 러너 — Tests/e2e.sh가 구동한다.
//
// 전제: PlainPaste(-PPTestHook 1)와 PasteCatcher가 이미 실행 중.
// 입력(환경변수): PP_OUT = 캐처 출력파일, PP_CATCHER_PID = 캐처 PID
// 종료 코드: 0 = 전부 통과(스킵 허용) / 1 = 실패 있음 / 2 = 캐너리 실패(권한 미설정 추정)
//
// 시나리오 ↔ TESTPLAN.md 매핑은 TESTPLAN.md의 E2E 매트릭스 표 참고.

let pb = NSPasteboard.general
let triggerName = Notification.Name("com.haseong23.plainpaste.test.trigger")
let clearName = Notification.Name("com.haseong23.plainpaste.test.catcher.clear")
let appBundleID = "com.haseong23.plainpaste"

guard let outPath = ProcessInfo.processInfo.environment["PP_OUT"],
      let pidStr = ProcessInfo.processInfo.environment["PP_CATCHER_PID"],
      let catcherPid = Int32(pidStr) else {
    FileHandle.standardError.write("PP_OUT / PP_CATCHER_PID 환경변수 필요 (Tests/e2e.sh로 실행하세요)\n".data(using: .utf8)!)
    exit(64)
}

var passed = 0, failed = 0, skippedCount = 0
var observations: [String] = []

// MARK: - 유틸

func runLoopSleep(_ t: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(t))
}

func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        runLoopSleep(0.05)
    }
    return cond()
}

func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond { passed += 1; print("  ✓ \(name)") }
    else { failed += 1; print("  ✗ FAIL: \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}

func skip(_ name: String, _ reason: String) {
    skippedCount += 1
    print("  ⊘ SKIP: \(name) — \(reason)")
}

func observe(_ s: String) {
    observations.append(s)
    print("  ◎ 관측: \(s)")
}

// MARK: - 캐처 통신

func catcherText() -> String {
    (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
}

func clearCatcher() {
    guard !catcherText().isEmpty else { return }
    DistributedNotificationCenter.default().postNotificationName(
        clearName, object: nil, userInfo: nil, deliverImmediately: true)
    _ = waitUntil(3) { catcherText().isEmpty }
}

func ensureCatcherFrontmost() {
    guard let capp = NSRunningApplication(processIdentifier: catcherPid) else {
        print("  ✗ PasteCatcher(pid \(catcherPid))가 죽었습니다 — 중단"); exit(1)
    }
    if !capp.isActive { capp.activate(options: []) }   // 캐처 자체도 0.3s 주기로 재활성화함
    if !waitUntil(3, { capp.isActive }) {
        print("  ⚠︎ 캐처가 frontmost가 아님 — 이 시나리오는 불안정할 수 있음")
    }
}

func trigger() {
    DistributedNotificationCenter.default().postNotificationName(
        triggerName, object: nil, userInfo: nil, deliverImmediately: true)
}

// marker가 캐처에 나타날 때까지 대기. marker=nil이면 "무엇이든 붙을 때"까지.
func waitPaste(marker: String?, timeout: TimeInterval = 6) -> String? {
    let ok = waitUntil(timeout) {
        let t = catcherText()
        return marker.map { t.contains($0) } ?? !t.isEmpty
    }
    guard ok else { return nil }
    runLoopSleep(0.15)   // 기록 정착
    return catcherText()
}

// MARK: - 클립보드 조작 (반환값 = 쓰기 직후 changeCount)

@discardableResult
func setPlain(_ s: String) -> Int {
    pb.clearContents(); pb.setString(s, forType: .string); return pb.changeCount
}

@discardableResult
func setRTFPlusPlain(_ s: String) -> Int {
    let attr = NSAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
    let rtf = try! attr.data(from: NSRange(location: 0, length: attr.length),
                             documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    pb.clearContents(); pb.setData(rtf, forType: .rtf); pb.setString(s, forType: .string)
    return pb.changeCount
}

@discardableResult
func setHTMLPlusPlain(_ s: String, html: String) -> Int {
    pb.clearContents()
    pb.setData(html.data(using: .utf8)!, forType: .html)
    pb.setString(s, forType: .string)
    return pb.changeCount
}

@discardableResult
func setPNG(_ data: Data) -> Int {
    pb.clearContents(); pb.setData(data, forType: .png); return pb.changeCount
}

// MARK: - OCR용 텍스트 이미지 렌더링 (픽셀 크기 정확 제어)

func renderPNG(lines: [String], width: Int, height: Int, fontSize: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)   // 1pt = 1px
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        .foregroundColor: NSColor.black,
    ]
    var y = CGFloat(height) - fontSize * 1.7
    for line in lines {
        (line as NSString).draw(at: NSPoint(x: 28, y: y), withAttributes: attrs)
        y -= fontSize * 1.9
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// 대소문자·공백 차이를 무시한 OCR 비교용 정규화
func normalizeEN(_ s: String) -> String {
    s.uppercased().components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }.joined(separator: " ")
}
func normalizeKO(_ s: String) -> String {
    s.components(separatedBy: .whitespacesAndNewlines).joined()
}

// MARK: - 합성 키 이벤트 (S11·S12 전용 — 러너에 손쉬운 사용 권한 필요)

let axTrusted = AXIsProcessTrusted()

func postKey(_ key: CGKeyCode, down: Bool, flags: CGEventFlags, asFlagsChanged: Bool = false) {
    let src = CGEventSource(stateID: .combinedSessionState)
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { return }
    if asFlagsChanged { e.type = .flagsChanged }
    e.flags = flags
    e.post(tap: .cgSessionEventTap)
}

// 앱이 실제 등록한 단축키(사용자 커스텀 반영) — 기본 ⌃⌥⌘V
func registeredShortcut() -> (key: CGKeyCode, carbonMods: UInt32) {
    let kc = (CFPreferencesCopyAppValue("shortcutKeyCode" as CFString, appBundleID as CFString) as? Int)
        .map { UInt32($0) } ?? UInt32(kVK_ANSI_V)
    let mods = (CFPreferencesCopyAppValue("shortcutModifiers" as CFString, appBundleID as CFString) as? Int)
        .map { UInt32($0) } ?? UInt32(cmdKey | optionKey | controlKey)
    return (CGKeyCode(kc), mods)
}

func cgFlags(fromCarbon m: UInt32) -> CGEventFlags {
    var f: CGEventFlags = []
    if m & UInt32(cmdKey) != 0 { f.insert(.maskCommand) }
    if m & UInt32(shiftKey) != 0 { f.insert(.maskShift) }
    if m & UInt32(optionKey) != 0 { f.insert(.maskAlternate) }
    if m & UInt32(controlKey) != 0 { f.insert(.maskControl) }
    return f
}

// carbon modifier 마스크의 각 키를 flagsChanged로 누름/뗌 (누적 flags 반영)
func postModifiers(_ carbonMods: UInt32, down: Bool) {
    let keys: [(UInt32, CGKeyCode, CGEventFlags)] = [
        (UInt32(controlKey), CGKeyCode(kVK_Control), .maskControl),
        (UInt32(optionKey), CGKeyCode(kVK_Option), .maskAlternate),
        (UInt32(cmdKey), CGKeyCode(kVK_Command), .maskCommand),
        (UInt32(shiftKey), CGKeyCode(kVK_Shift), .maskShift),
    ]
    var held: CGEventFlags = down ? [] : cgFlags(fromCarbon: carbonMods)
    for (mask, key, flag) in keys where carbonMods & mask != 0 {
        if down { held.insert(flag) } else { held.remove(flag) }
        postKey(key, down: down, flags: held, asFlagsChanged: true)
    }
}

// MARK: - 시나리오

print("PlainPaste E2E — 실행 중 키보드/마우스를 만지지 마세요")
print("")

// ── S1: 순수 텍스트 그대로 + 클립보드 무손상 (C1) — 캐너리 겸용 ──────────────
print("S1 순수 텍스트 (C1, 캐너리)")
clearCatcher(); ensureCatcherFrontmost()
let s1 = "PP-S1-CANARY"
let cc1 = setPlain(s1)
trigger()
if let got1 = waitPaste(marker: s1) {
    check("붙여넣기 도착 = 원문", got1 == s1, "got: \(got1)")
    check("클립보드 무손상 (changeCount 불변)", pb.changeCount == cc1,
          "changeCount \(cc1) → \(pb.changeCount)")
    check("클립보드 내용 유지", pb.string(forType: .string) == s1)
} else {
    print("")
    print("❌ 캐너리 실패 — PlainPaste가 ⌘V를 보내지 못했습니다.")
    print("   가장 흔한 원인: PlainPaste에 손쉬운 사용 권한이 없음.")
    print("   → 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 → PlainPaste 켜기")
    print("   → 재빌드로 서명이 바뀌었다면 기존 항목 제거 후 다시 추가")
    print("   → 서명을 고정해 재부여를 없애려면: ./Tests/make_signing_cert.sh")
    exit(2)
}

// ── S2: 직전 값 밀림 회귀 (B1) — 빠른 복사→붙여넣기 5연속 ────────────────────
print("S2 연속 복사→붙여넣기 5회 (B1 회귀: 직전 값 밀림)")
var s2AllFresh = true
var s2Detail = ""
for i in 1...5 {
    clearCatcher(); ensureCatcherFrontmost()
    let msg = "PP-S2-MSG-\(i)"
    setPlain(msg)
    trigger()
    let got = waitPaste(marker: nil) ?? "(없음)"
    if got != msg { s2AllFresh = false; s2Detail = "회차\(i): got '\(got)', want '\(msg)'"; break }
}
check("매회 방금 복사한 값이 붙음 (밀림 없음)", s2AllFresh, s2Detail)

// ── S3: 서식(RTF) → 플레인 재작성 (C2) ──────────────────────────────────────
print("S3 서식 텍스트 → 플레인 (C2)")
clearCatcher(); ensureCatcherFrontmost()
let s3 = "PP-S3 굵은글씨"
setRTFPlusPlain(s3)
trigger()
let got3 = waitPaste(marker: s3)
check("플레인으로 붙음", got3 == s3, "got: \(got3 ?? "(없음)")")
let types3 = pb.types ?? []
check("클립보드에서 서식 제거됨 (.rtf 부재, 플레인 재작성)",
      !types3.contains(.rtf) && pb.string(forType: .string) == s3,
      "types: \(types3.map(\.rawValue))")

// ── S4: HTML 병기(브라우저 모사) → 플레인 (D3 특성화) ────────────────────────
print("S4 HTML 병기 텍스트 (D3)")
clearCatcher(); ensureCatcherFrontmost()
let s4 = "PP-S4 웹 텍스트"
setHTMLPlusPlain(s4, html: "<b>PP-S4 웹 텍스트</b>")
trigger()
let got4 = waitPaste(marker: s4)
check("플레인으로 붙음", got4 == s4, "got: \(got4 ?? "(없음)")")
let types4 = pb.types ?? []
check("HTML 제거됨 (rewrite 경로)", !types4.contains(.html))
observe("D3 확인: 브라우저형(plain+html) 복사도 rewrite 경로 → 원본 클립보드가 플레인으로 덮임 (의도된 트레이드오프)")

// ── S5: ⌘C 두 번 회귀 (B2) — rewrite 붙여넣기 직후 사용자 복사 1회가 유지되는가 ─
print("S5 붙여넣기 직후 새 복사 유지 (B2 회귀: ⌘C 두 번)")
let s5 = "PP-S5-EEE"
let cc5 = setPlain(s5)          // 사용자 ⌘C 1회 모사
runLoopSleep(3.0)               // 과거 버그의 지연 복원 타이머가 발화할 시간
check("3초 후에도 새 복사 내용 유지 (지연 복원 없음)",
      pb.string(forType: .string) == s5 && pb.changeCount == cc5,
      "pb: \(pb.string(forType: .string) ?? "(nil)")")

// ── S6: 이미지 OCR + 줄 순서 (C3) ───────────────────────────────────────────
print("S6 이미지 OCR 2줄 (C3)")
clearCatcher(); ensureCatcherFrontmost()
setPNG(renderPNG(lines: ["HELLO 123", "SECOND LINE"], width: 900, height: 320, fontSize: 72))
trigger()
if let got6 = waitPaste(marker: nil, timeout: 15) {
    let norm6 = normalizeEN(got6)
    check("OCR 인식 + 줄 순서 위→아래", norm6.contains("HELLO 123 SECOND LINE"), "got: \(norm6)")
} else {
    check("OCR 결과 도착", false, "15초 내 붙여넣기 없음")
}

// ── S13: 온디맨드 원본 복원 — OCR 붙여넣기 후 메뉴 동작으로 스크린샷 복귀 ──────
print("S13 온디맨드 원본 복원 (S6 직후, 메뉴 동작 모사)")
// S6 직후 상태: 클립보드 = OCR 텍스트, 앱이 원본 PNG를 보관 중
let ccBeforeRestore = pb.changeCount
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.haseong23.plainpaste.test.restore"),
    object: nil, userInfo: nil, deliverImmediately: true)
check("복원으로 클립보드 변경됨", waitUntil(5) { pb.changeCount != ccBeforeRestore })
check("원본 PNG 플레이버 복귀", pb.data(forType: .png) != nil)
check("OCR 텍스트는 제거됨", pb.string(forType: .string) == nil)

// ── S7: 작은 한글 이미지 → 업스케일 경유 OCR (C3) ────────────────────────────
print("S7 작은 한글 이미지 OCR (C3, 업스케일 경로)")
if ProcessInfo.processInfo.isOperatingSystemAtLeast(
    OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)) {
    clearCatcher(); ensureCatcherFrontmost()
    // 긴 변 460px ≤ 500 → ocrUpscaleFactor가 3.0 상한으로 확대하는 경로
    setPNG(renderPNG(lines: ["테스트 문장"], width: 460, height: 140, fontSize: 34))
    trigger()
    if let got7 = waitPaste(marker: nil, timeout: 15) {
        check("한글 인식 (업스케일 경유)", normalizeKO(got7).contains("테스트"), "got: \(got7)")
    } else {
        check("OCR 결과 도착", false, "15초 내 붙여넣기 없음")
    }
} else {
    skip("한글 OCR", "macOS 13 미만은 한국어 미지원")
}

// ── S8: 빈 클립보드 → 아무 일도 없음 (C4) ────────────────────────────────────
print("S8 빈 클립보드 (C4)")
clearCatcher(); ensureCatcherFrontmost()
pb.clearContents()
let cc8 = pb.changeCount
trigger()
runLoopSleep(2.0)
check("아무 것도 안 붙고 클립보드 무변화 (beep은 관측 불가)",
      catcherText().isEmpty && pb.changeCount == cc8)

// ── S9: 이미지 파일 복사 (D2 특성화) — 파일명 vs OCR ─────────────────────────
print("S9 이미지 파일 복사 (D2 특성화)")
let fileText = "FILE TEST 42"
let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pp-e2e-ocr.png")
try! renderPNG(lines: [fileText], width: 800, height: 220, fontSize: 64).write(to: fileURL)

func s9Observe(_ label: String, _ got: String?) {
    guard let got, !got.isEmpty else { observe("\(label): 아무 것도 안 붙음"); return }
    let norm = normalizeEN(got)
    if norm.contains(fileText) { observe("\(label): OCR 텍스트가 붙음 (정상 동작) — '\(got)'") }
    else if got.contains("file://") { observe("\(label): 파일 URL 문자열이 붙음 → D2 버그 재현 — '\(got)'") }
    else if got.contains(fileURL.lastPathComponent) { observe("\(label): 파일명이 붙음 → D2 버그 재현 — '\(got)'") }
    else { observe("\(label): 예상 밖 내용 — '\(got)'") }
}

clearCatcher(); ensureCatcherFrontmost()
pb.clearContents()
pb.setData(fileURL.absoluteString.data(using: .utf8)!, forType: .fileURL)   // a) file-URL만
trigger()
s9Observe("S9a(file-URL만)", waitPaste(marker: nil, timeout: 15))

clearCatcher(); ensureCatcherFrontmost()
pb.clearContents()
pb.setData(fileURL.absoluteString.data(using: .utf8)!, forType: .fileURL)   // b) Finder 모사:
pb.setString(fileURL.lastPathComponent, forType: .string)                   //    URL + 파일명 문자열
trigger()
s9Observe("S9b(Finder 모사: URL+파일명)", waitPaste(marker: nil, timeout: 15))

// ── S10: 단축키 연타 (D4 특성화) ────────────────────────────────────────────
print("S10 트리거 2연타 (D4 특성화)")
clearCatcher(); ensureCatcherFrontmost()
let s10 = "PP-S10-DBL"
setPlain(s10)
trigger()
runLoopSleep(0.03)
trigger()
runLoopSleep(2.5)
let count10 = catcherText().components(separatedBy: s10).count - 1
observe("S10 연타 2회 → 붙은 횟수 = \(count10)회" +
        (count10 >= 2 ? " → D4(이중 붙여넣기) 재현" : " (자연 방어됨)"))

// ── S11: modifier 홀드 (B3) — 러너에 손쉬운 사용 권한 필요 ────────────────────
print("S11 modifier 홀드 중 트리거 (B3)")
if axTrusted {
    clearCatcher(); ensureCatcherFrontmost()
    let s11 = "PP-S11-MOD"
    setPlain(s11)
    let holdMods = UInt32(cmdKey | optionKey | controlKey)
    postModifiers(holdMods, down: true)     // 물리 ⌃⌥⌘ 홀드 모사
    trigger()
    runLoopSleep(0.35)
    let early = catcherText()
    postModifiers(holdMods, down: false)    // 해제
    if let got11 = waitPaste(marker: s11) {
        check("해제 후 붙여넣기 도착 (내용 정상)", got11 == s11, "got: \(got11)")
        if early.isEmpty { check("홀드 중에는 대기 (해제 후에만 붙음)", true) }
        else { observe("S11: 합성 modifier가 combinedSessionState에 반영되지 않는 환경 — 홀드 대기 검증은 참고용 (도착 자체는 정상)") }
    } else {
        check("해제 후 붙여넣기 도착", false, "6초 내 없음 (modifier 해제 대기 1초 초과?)")
    }
} else {
    skip("S11", "러너(터미널)에 손쉬운 사용 권한 없음 — 훅 경로(S1–S10)는 이미 커버됨")
}

// ── S12: 실제 전역 단축키 경로 스모크 (RegisterEventHotKey) ───────────────────
print("S12 실제 단축키 합성 입력 (핫키 등록 경로)")
if axTrusted {
    clearCatcher(); ensureCatcherFrontmost()
    let s12 = "PP-S12-HOTKEY"
    setPlain(s12)
    let (key12, mods12) = registeredShortcut()
    postModifiers(mods12, down: true)
    postKey(key12, down: true, flags: cgFlags(fromCarbon: mods12))
    postKey(key12, down: false, flags: cgFlags(fromCarbon: mods12))
    postModifiers(mods12, down: false)
    check("단축키로 붙여넣기 동작", waitPaste(marker: s12) == s12)
} else {
    skip("S12", "러너(터미널)에 손쉬운 사용 권한 없음")
}

// MARK: - 요약

print("")
if !observations.isEmpty {
    print("관측 요약 (특성화 — pass/fail 아님):")
    for o in observations { print("  ◎ \(o)") }
    print("")
}
print(failed == 0
      ? "✅ E2E 통과 — \(passed) passed\(skippedCount > 0 ? ", \(skippedCount) skipped" : "")"
      : "❌ E2E — \(failed) failed, \(passed) passed, \(skippedCount) skipped")
exit(failed == 0 ? 0 : 1)
