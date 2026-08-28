import Cocoa
import Carbon

// PlainPaste 스트레스·소크 하네스 — Tests/stress.sh가 구동한다.
//
// 기존 E2E(E2EDriver)가 "시나리오당 1회, 계약이 맞는가"를 본다면, 이 하네스는
// "반복하고, 앱을 오가고, 트리거 방법을 섞을 때 씹히거나 오염되는가"를 센다.
//
// ── 이 앱에는 설계된 드롭 경로가 4개 있다 ────────────────────────────────────
//   1) pasteText            의 changeCount 불일치 → 붙여넣기 포기
//   2) postCmdVAfterRelease 의 changeCount 불일치 → ⌘V 미전송
//   3) OCR 완료 후          의 changeCount 불일치 → 결과 폐기
//   4) modifier 해제 타임아웃(2초)                → ⌘V 미전송 + beep
// 전부 "잘못 붙이느니 안 붙인다"는 의도적 방어다. 따라서 씹힘(누락)은 그 자체로
// 결함이 아니고, 판정은 두 갈래로 나뉜다:
//
//   동기 패턴(사람의 실사용: 붙여넣기를 확인하고 다음 복사)  → 누락 0 이어야 한다
//   비동기 스트레스(사람보다 빠른 기계 속도)                → 누락 허용,
//                                                          단 밀림·중복·클립보드 오염 0
//
// 밀림(직전 값)·중복(이중 붙여넣기)·오염(클립보드가 예상 밖 상태)은 어느 모드에서도 결함이다.
//
// 입력(환경변수): PP_OUT_A/PP_PID_A, PP_OUT_B/PP_PID_B, PP_CYCLES, PP_SOAK
// 종료 코드: 0 통과 / 1 결함 / 2 캐너리 실패(권한 미설정 추정)

// MARK: - 환경

let env = ProcessInfo.processInfo.environment
guard let outA = env["PP_OUT_A"], let pidA = env["PP_PID_A"].flatMap({ Int32($0) }),
      let outB = env["PP_OUT_B"], let pidB = env["PP_PID_B"].flatMap({ Int32($0) }) else {
    FileHandle.standardError.write("PP_OUT_A/PP_PID_A/PP_OUT_B/PP_PID_B 필요 (Tests/stress.sh로 실행)\n"
        .data(using: .utf8)!)
    exit(64)
}
let cycles = env["PP_CYCLES"].flatMap { Int($0) } ?? 40
let soakCycles = env["PP_SOAK"].flatMap { Int($0) } ?? 150

let pb = NSPasteboard.general
let triggerName = Notification.Name("com.haseong23.plainpaste.test.trigger")
let appBundleID = "com.haseong23.plainpaste"
let axTrusted = AXIsProcessTrusted()

// MARK: - 캐처

struct Catcher {
    let label: String
    let outPath: String
    let pid: pid_t

    var running: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
    func text() -> String { (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? "" }

    // 이 캐처를 최전면으로. stress.sh는 캐처를 --no-autofocus로 띄우므로
    // 포커스 주도권은 전적으로 여기 있다 (캐처끼리 서로 뺏는 핑퐁이 없다).
    @discardableResult
    func focus(timeout: TimeInterval = 3) -> Bool {
        guard let app = running else { return false }
        if !app.isActive { app.activate(options: []) }
        return waitUntil(timeout) { app.isActive }
    }
}

let catcherA = Catcher(label: "A", outPath: outA, pid: pidA)
let catcherB = Catcher(label: "B", outPath: outB, pid: pidB)

// MARK: - 유틸

func runLoopSleep(_ t: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }

func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        runLoopSleep(0.02)
    }
    return cond()
}

func marker(_ tag: String, _ i: Int) -> String { String(format: "<<%@-%04d>>", tag, i) }

// 텍스트에서 <<TAG-NNNN>> 토큰의 번호를 등장 순서대로 뽑는다
let tokenRegex = try! NSRegularExpression(pattern: "<<([A-Z0-9]{1,8})-(\\d{4})>>")
func tokens(in s: String, tag: String) -> [Int] {
    let ns = s as NSString
    return tokenRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        .compactMap { m -> Int? in
            guard ns.substring(with: m.range(at: 1)) == tag else { return nil }
            return Int(ns.substring(with: m.range(at: 2)))
        }
}

// MARK: - 클립보드 쓰기 (반환 = 쓰기 직후 changeCount)

@discardableResult
func setPlain(_ s: String) -> Int {
    pb.clearContents(); pb.setString(s, forType: .string); return pb.changeCount
}

// 다른 프로세스가 복사한 상황을 실제로 만든다 — B1(직전 값 밀림)의 원래 조건인
// 크로스-프로세스 changeCount 전파 지연은 같은 프로세스 쓰기로는 재현되지 않는다.
func setPlainExternally(_ s: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
    let pipe = Pipe()
    p.standardInput = pipe
    try? p.run()
    pipe.fileHandleForWriting.write(s.data(using: .utf8)!)
    pipe.fileHandleForWriting.closeFile()
    p.waitUntilExit()
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
func setHTMLPlusPlain(_ s: String) -> Int {
    pb.clearContents()
    pb.setData("<b>\(s)</b>".data(using: .utf8)!, forType: .html)
    pb.setString(s, forType: .string)
    return pb.changeCount
}

@discardableResult
func setPNGText(_ s: String) -> Int {
    let w = 900, h = 180
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    (s as NSString).draw(at: NSPoint(x: 30, y: 55), withAttributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 62, weight: .semibold),
        .foregroundColor: NSColor.black,
    ])
    NSGraphicsContext.restoreGraphicsState()
    pb.clearContents()
    pb.setData(rep.representation(using: .png, properties: [:])!, forType: .png)
    return pb.changeCount
}

// MARK: - 트리거

enum TriggerMethod: String {
    case hook = "테스트 훅"
    case hotkey = "실제 단축키"
}

func triggerHook() {
    DistributedNotificationCenter.default().postNotificationName(
        triggerName, object: nil, userInfo: nil, deliverImmediately: true)
}

func postKey(_ key: CGKeyCode, down: Bool, flags: CGEventFlags, asFlagsChanged: Bool = false) {
    let src = CGEventSource(stateID: .combinedSessionState)
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { return }
    if asFlagsChanged { e.type = .flagsChanged }
    e.flags = flags
    e.post(tap: .cgSessionEventTap)
}

func registeredShortcut() -> (key: CGKeyCode, mods: UInt32) {
    let kc = (CFPreferencesCopyAppValue("shortcutKeyCode" as CFString, appBundleID as CFString) as? Int)
        .map { UInt32($0) } ?? UInt32(kVK_ANSI_V)
    let m = (CFPreferencesCopyAppValue("shortcutModifiers" as CFString, appBundleID as CFString) as? Int)
        .map { UInt32($0) } ?? UInt32(cmdKey | optionKey | controlKey)
    return (CGKeyCode(kc), m)
}

func cgFlags(_ m: UInt32) -> CGEventFlags {
    var f: CGEventFlags = []
    if m & UInt32(cmdKey) != 0 { f.insert(.maskCommand) }
    if m & UInt32(shiftKey) != 0 { f.insert(.maskShift) }
    if m & UInt32(optionKey) != 0 { f.insert(.maskAlternate) }
    if m & UInt32(controlKey) != 0 { f.insert(.maskControl) }
    return f
}

func postModifiers(_ mods: UInt32, down: Bool) {
    let keys: [(UInt32, CGKeyCode, CGEventFlags)] = [
        (UInt32(controlKey), CGKeyCode(kVK_Control), .maskControl),
        (UInt32(optionKey), CGKeyCode(kVK_Option), .maskAlternate),
        (UInt32(cmdKey), CGKeyCode(kVK_Command), .maskCommand),
        (UInt32(shiftKey), CGKeyCode(kVK_Shift), .maskShift),
    ]
    var held: CGEventFlags = down ? [] : cgFlags(mods)
    for (mask, key, flag) in keys where mods & mask != 0 {
        if down { held.insert(flag) } else { held.remove(flag) }
        postKey(key, down: down, flags: held, asFlagsChanged: true)
    }
}

func triggerHotkey() {
    let (key, mods) = registeredShortcut()
    postModifiers(mods, down: true)
    postKey(key, down: true, flags: cgFlags(mods))
    postKey(key, down: false, flags: cgFlags(mods))
    postModifiers(mods, down: false)
}

func fire(_ method: TriggerMethod) {
    switch method {
    case .hook: triggerHook()
    case .hotkey: triggerHotkey()
    }
}

// MARK: - 집계

struct Tally {
    var name: String
    var note: String
    var attempted = 0
    var arrived = 0
    var dropped = 0      // 아무것도 안 붙음
    var stale = 0        // 직전(또는 다른) 값이 붙음
    var duplicated = 0   // 한 번 트리거에 두 번 이상 붙음
    var polluted = 0     // 클립보드가 예상 밖 상태
    var latencies: [TimeInterval] = []
    var strict: Bool     // true면 누락도 결함 (동기 패턴)

    var defects: Int { stale + duplicated + polluted + (strict ? dropped : 0) }
    var ok: Bool { defects == 0 }

    func pct(_ p: Double) -> TimeInterval {
        guard !latencies.isEmpty else { return 0 }
        let s = latencies.sorted()
        return s[min(s.count - 1, max(0, Int((Double(s.count) * p).rounded(.down))))]
    }
}

var tallies: [Tally] = []
var notes: [String] = []

// MARK: - 동기 1회 사이클
//
// 사람의 실사용 패턴: 붙여넣기가 도착한 것을 확인하고 다음으로 넘어간다.
// 캐처는 append-only이므로 baseline 이후 증가분만 보면 이번 회차의 결과가 정확히 나온다.

@discardableResult
func syncCycle(into catcher: Catcher, expect: String, timeout: TimeInterval = 4,
               method: TriggerMethod = .hook, tally: inout Tally,
               copy: () -> Void) -> Bool {
    let baseline = catcher.text()
    copy()
    tally.attempted += 1
    let t0 = Date()
    fire(method)

    let grew = waitUntil(timeout) { catcher.text().count > baseline.count }
    guard grew else { tally.dropped += 1; return false }
    runLoopSleep(0.12)   // 기록 정착 — 늦게 오는 두 번째 붙여넣기(중복)도 잡는다

    let full = catcher.text()
    let delta = String(full.dropFirst(baseline.count))
    tally.latencies.append(Date().timeIntervalSince(t0))

    let hits = delta.components(separatedBy: expect).count - 1
    if hits >= 2 { tally.duplicated += 1; return false }
    if hits == 1 {
        // 기대값은 왔는데 다른 내용까지 섞였으면 그것도 이상 신호
        if delta.trimmingCharacters(in: .whitespacesAndNewlines) != expect { tally.stale += 1; return false }
        tally.arrived += 1
        return true
    }
    tally.stale += 1
    return false
}

// MARK: - 준비

print("PlainPaste 스트레스 — 실행 중 키보드/마우스를 만지지 마세요")
print("반복 \(cycles)회 · 소크 \(soakCycles)회 · 실제 단축키 경로 \(axTrusted ? "사용 가능" : "권한 없음 → skip")")
print("")

// ── 캐너리: 앱이 살아 있고 ⌘V를 보낼 수 있는가 ────────────────────────────────
catcherA.focus()
var canary = Tally(name: "canary", note: "", strict: true)
let canaryOK = syncCycle(into: catcherA, expect: marker("CAN", 1), tally: &canary) {
    setPlain(marker("CAN", 1))
}
if !canaryOK {
    // 실패 원인을 하네스 / 앱으로 갈라 준다 — 드라이버가 직접 ⌘V를 쏴 보고,
    // 그게 도착하면 캐처·포커스·관측 경로는 정상이므로 남는 변수는 PlainPaste뿐이다.
    var harnessOK = false
    if axTrusted {
        catcherA.focus()
        let base = catcherA.text()
        setPlain("<<PROBE-0001>>")
        let src = CGEventSource(stateID: .combinedSessionState)
        if let d = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
           let u = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) {
            d.flags = .maskCommand; u.flags = .maskCommand
            d.post(tap: .cgSessionEventTap); u.post(tap: .cgSessionEventTap)
            harnessOK = waitUntil(4) { catcherA.text().count > base.count }
        }
    }

    print("❌ 캐너리 실패 — PlainPaste가 ⌘V를 보내지 못했습니다.")
    print("")
    if harnessOK {
        print("   분리 진단: 러너가 직접 쏜 ⌘V는 정상 도착 → 하네스는 이상 없음.")
        print("   원인은 PlainPaste에 손쉬운 사용 권한이 없는 것입니다.")
    } else if !axTrusted {
        print("   분리 진단 불가 — 러너(터미널)에도 손쉬운 사용 권한이 없어 대조군을 만들 수 없습니다.")
    } else {
        print("   분리 진단: 러너가 직접 쏜 ⌘V도 도착하지 않음 → 하네스·환경 쪽 문제일 수 있습니다.")
    }
    print("")
    print("   조치 (택 1)")
    print("   A. 서명을 고정하고 1회만 권한 부여 — 이후 재빌드에도 유지 (권장)")
    print("        ./Tests/make_signing_cert.sh      # sudo·키체인 비밀번호 각 1회")
    print("        ./build.sh")
    print("        시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용")
    print("          → 기존 PlainPaste 항목 제거 후, 위에서 빌드한 앱을 추가")
    print("   B. 이번 빌드에만 권한 부여 — 소스가 바뀌어 재빌드하면 다시 풀립니다")
    print("        시스템 설정 → 손쉬운 사용에서 아래 경로를 추가:")
    let appPath = env["PP_APP_PATH"] ?? "dist/PlainPaste.app"
    print("        \(appPath)")
    exit(2)
}
print("캐너리 통과 — 붙여넣기 경로 정상\n")

// ── R1: 동기 반복 (같은 프로세스 복사) ───────────────────────────────────────
print("R1 동기 반복 \(cycles)회 — 같은 프로세스 복사, 훅 트리거")
var r1 = Tally(name: "R1 동기 반복", note: "같은 프로세스 복사 · 훅", strict: true)
catcherA.focus()
for i in 1...cycles {
    let m = marker("R1", i)
    syncCycle(into: catcherA, expect: m, tally: &r1) { setPlain(m) }
}
tallies.append(r1)
print("   도착 \(r1.arrived)/\(r1.attempted) · 누락 \(r1.dropped) · 밀림 \(r1.stale) · 중복 \(r1.duplicated)")

// ── R2: 동기 반복 (외부 프로세스 복사 — 크로스 프로세스 지연) ─────────────────
print("R2 동기 반복 \(cycles)회 — pbcopy(외부 프로세스) 복사")
var r2 = Tally(name: "R2 외부 복사", note: "pbcopy · 훅", strict: true)
catcherA.focus()
for i in 1...cycles {
    let m = marker("R2", i)
    syncCycle(into: catcherA, expect: m, tally: &r2) { setPlainExternally(m) }
}
tallies.append(r2)
print("   도착 \(r2.arrived)/\(r2.attempted) · 누락 \(r2.dropped) · 밀림 \(r2.stale) · 중복 \(r2.duplicated)")

// ── R3: 콘텐츠 타입 교대 (direct ↔ rewrite ↔ OCR 경로 전환) ──────────────────
print("R3 콘텐츠 타입 교대 — 순수/RTF/HTML 순환 + 클립보드 오염 검사")
var r3 = Tally(name: "R3 타입 교대", note: "plain→RTF→HTML 순환", strict: true)
catcherA.focus()
for i in 1...cycles {
    let m = marker("R3", i)
    let kind = i % 3
    let ok = syncCycle(into: catcherA, expect: m, tally: &r3) {
        switch kind {
        case 0: setPlain(m)
        case 1: setRTFPlusPlain(m)
        default: setHTMLPlusPlain(m)
        }
    }
    guard ok else { continue }
    // 경로별 클립보드 계약 검증
    let types = pb.types ?? []
    switch kind {
    case 0:
        // direct: 클립보드를 건드리지 않아야 한다
        if pb.string(forType: .string) != m { r3.polluted += 1 }
    default:
        // rewrite: 플레인만 남고 서식은 제거되어야 한다
        if pb.string(forType: .string) != m
            || types.contains(.rtf) || types.contains(.html) { r3.polluted += 1 }
    }
}
tallies.append(r3)
print("   도착 \(r3.arrived)/\(r3.attempted) · 누락 \(r3.dropped) · 밀림 \(r3.stale) · 오염 \(r3.polluted)")

// ── R4: 앱 전환 — 붙여넣을 때마다 대상 앱을 바꾼다 ────────────────────────────
print("R4 앱 전환 \(cycles)회 — 캐처 A/B를 번갈아 최전면으로")
var r4 = Tally(name: "R4 앱 전환", note: "A↔B 교대 · 훅", strict: true)
var misdelivered = 0
for i in 1...cycles {
    let target = i % 2 == 0 ? catcherA : catcherB
    let other = i % 2 == 0 ? catcherB : catcherA
    guard target.focus() else { r4.attempted += 1; r4.dropped += 1; continue }
    let otherBaseline = other.text()
    let m = marker("R4", i)
    syncCycle(into: target, expect: m, tally: &r4) { setPlain(m) }
    // 엉뚱한 앱에 붙지 않았는가 — 앱 전환 시나리오의 진짜 관심사
    if other.text().count != otherBaseline.count { misdelivered += 1 }
}
r4.polluted += misdelivered
tallies.append(r4)
if misdelivered > 0 { notes.append("R4: 비활성 앱에 붙여넣기가 샌 횟수 \(misdelivered)") }
print("   도착 \(r4.arrived)/\(r4.attempted) · 누락 \(r4.dropped) · 밀림 \(r4.stale) · 오배달 \(misdelivered)")

// ── R5: 실제 전역 단축키 경로로 반복 ─────────────────────────────────────────
print("R5 실제 단축키(⌃⌥⌘V) 반복 — RegisterEventHotKey 실경로")
if axTrusted {
    var r5 = Tally(name: "R5 실단축키", note: "합성 ⌃⌥⌘V", strict: true)
    catcherA.focus()
    for i in 1...cycles {
        let m = marker("R5", i)
        syncCycle(into: catcherA, expect: m, timeout: 5, method: .hotkey, tally: &r5) { setPlain(m) }
    }
    tallies.append(r5)
    print("   도착 \(r5.arrived)/\(r5.attempted) · 누락 \(r5.dropped) · 밀림 \(r5.stale) · 중복 \(r5.duplicated)")
} else {
    print("   ⊘ SKIP — 러너(터미널)에 손쉬운 사용 권한 없음")
    notes.append("R5 skip: 실제 단축키 경로 미검증 (터미널 손쉬운 사용 권한 필요)")
}

// ── R6: 비동기 스트레스 — 사람보다 빠른 속도로 밀어넣기 ───────────────────────
// 설계된 드롭이 발동하는 구간. 누락은 허용, 밀림·중복은 결함.
print("R6 비동기 스트레스 — 간격 20/60/120ms로 밀어넣기")
for (idx, gap) in [0.02, 0.06, 0.12].enumerated() {
    let tag = "S\(idx)"
    var t = Tally(name: "R6 비동기 \(Int(gap * 1000))ms", note: "누락 허용 · 오염 금지", strict: false)
    catcherA.focus()
    let baseline = catcherA.text()
    let n = max(10, cycles / 2)
    for i in 1...n {
        setPlain(marker(tag, i))
        triggerHook()
        t.attempted += 1
        runLoopSleep(gap)
    }
    _ = waitUntil(4) { false }   // 잔여 붙여넣기 정착 대기
    let seen = tokens(in: String(catcherA.text().dropFirst(baseline.count)), tag: tag)
    t.arrived = Set(seen).count
    t.dropped = t.attempted - t.arrived
    t.duplicated = seen.count - Set(seen).count
    // 순서 역전 = 밀림
    t.stale = zip(seen, seen.dropFirst()).filter { $0 >= $1 }.count - t.duplicated
    if t.stale < 0 { t.stale = 0 }
    tallies.append(t)
    print("   \(Int(gap * 1000))ms: 도착 \(t.arrived)/\(t.attempted) · 누락 \(t.dropped) · 밀림 \(t.stale) · 중복 \(t.duplicated)")
}

// ── R7: 소크 — 길게 돌려 후반 열화가 없는지 ──────────────────────────────────
print("R7 소크 \(soakCycles)회 — 전·후반 실패율 비교")
var r7 = Tally(name: "R7 소크", note: "\(soakCycles)회 연속", strict: true)
catcherA.focus()
var firstHalfFail = 0, secondHalfFail = 0
for i in 1...soakCycles {
    let m = marker("R7", i)
    let ok = syncCycle(into: catcherA, expect: m, tally: &r7) { setPlain(m) }
    if !ok { if i <= soakCycles / 2 { firstHalfFail += 1 } else { secondHalfFail += 1 } }
    if i % 50 == 0 { print("   … \(i)/\(soakCycles)") }
}
tallies.append(r7)
notes.append("R7 전반부 실패 \(firstHalfFail) · 후반부 실패 \(secondHalfFail)" +
             (secondHalfFail > firstHalfFail * 2 + 2 ? "  ← 후반 열화 의심" : "  (열화 없음)"))
print("   도착 \(r7.arrived)/\(r7.attempted) · 누락 \(r7.dropped) · 밀림 \(r7.stale) · 중복 \(r7.duplicated)")

// ── R8: OCR 경로 반복 ────────────────────────────────────────────────────────
print("R8 이미지 OCR 반복 — 비동기 완료 경로")
var r8 = Tally(name: "R8 OCR 반복", note: "이미지 → 인식 텍스트", strict: true)
catcherA.focus()
let ocrRounds = max(5, cycles / 4)
for i in 1...ocrRounds {
    let digits = String(format: "%04d", i)
    let baseline = catcherA.text()
    setPNGText("PPOCR \(digits)")
    r8.attempted += 1
    let t0 = Date()
    triggerHook()
    guard waitUntil(15, { catcherA.text().count > baseline.count }) else { r8.dropped += 1; continue }
    runLoopSleep(0.15)
    let delta = String(catcherA.text().dropFirst(baseline.count))
    r8.latencies.append(Date().timeIntervalSince(t0))
    if delta.replacingOccurrences(of: " ", with: "").contains(digits) { r8.arrived += 1 }
    else { r8.stale += 1; notes.append("R8 회차\(i) 인식 불일치: '\(delta.prefix(40))'") }
}
tallies.append(r8)
print("   도착 \(r8.arrived)/\(r8.attempted) · 누락 \(r8.dropped) · 불일치 \(r8.stale)")

// MARK: - 보고

func ms(_ t: TimeInterval) -> String { t == 0 ? "—" : String(format: "%.0fms", t * 1000) }
func pad(_ s: String, _ w: Int) -> String {
    let len = s.count
    return len >= w ? s : s + String(repeating: " ", count: w - len)
}
func rpad(_ s: String, _ w: Int) -> String {
    let len = s.count
    return len >= w ? s : String(repeating: " ", count: w - len) + s
}

print("")
print(String(repeating: "─", count: 84))
print(pad("시나리오", 20) + rpad("시도", 6) + rpad("도착", 6) + rpad("누락", 6)
      + rpad("밀림", 6) + rpad("중복", 6) + rpad("오염", 6)
      + rpad("p50", 9) + rpad("p95", 9) + rpad("판정", 7))
print(String(repeating: "─", count: 84))
for t in tallies {
    print(pad(t.name, 20) + rpad("\(t.attempted)", 6) + rpad("\(t.arrived)", 6)
          + rpad("\(t.dropped)", 6) + rpad("\(t.stale)", 6) + rpad("\(t.duplicated)", 6)
          + rpad("\(t.polluted)", 6) + rpad(ms(t.pct(0.5)), 9) + rpad(ms(t.pct(0.95)), 9)
          + rpad(t.ok ? "✓" : "✗", 7))
}
print(String(repeating: "─", count: 84))
print("판정 기준: 동기 시나리오는 누락도 결함 · 비동기(R6)는 누락 허용, 밀림·중복·오염만 결함")

if !notes.isEmpty {
    print("")
    print("관측:")
    for n in notes { print("  ◎ \(n)") }
}

let failed = tallies.filter { !$0.ok }
print("")
if failed.isEmpty {
    print("✅ 씹힘·밀림·중복·오염 없음 — \(tallies.count)개 시나리오 전부 통과")
    exit(0)
} else {
    print("❌ 결함 \(failed.count)개 시나리오")
    for t in failed {
        var why: [String] = []
        if t.strict, t.dropped > 0 { why.append("누락 \(t.dropped)") }
        if t.stale > 0 { why.append("밀림 \(t.stale)") }
        if t.duplicated > 0 { why.append("중복 \(t.duplicated)") }
        if t.polluted > 0 { why.append("오염 \(t.polluted)") }
        print("   ▸ \(t.name): \(why.joined(separator: " · "))")
    }
    exit(1)
}
