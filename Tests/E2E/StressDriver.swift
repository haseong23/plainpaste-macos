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
let focusName = Notification.Name("com.haseong23.plainpaste.test.catcher.focus")
let appBundleID = "com.haseong23.plainpaste"
let axTrusted = AXIsProcessTrusted()

// MARK: - 캐처

struct Catcher {
    let label: String
    let outPath: String
    let pid: pid_t

    var running: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
    func text() -> String { (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? "" }

    // 이 캐처를 최전면으로.
    //
    // 러너가 NSRunningApplication.activate(options:)로 직접 활성화하지 않는다 —
    // macOS Sonoma 이후 크로스-앱 활성화는 제한되어 조용히 실패하고, 그러면 ⌘V가
    // 엉뚱한 앱으로 가 "붙여넣기가 안 온다"는 잘못된 결론이 나온다(실측으로 겪음).
    // 대신 분산 노티로 대상만 지시하고, 활성화는 캐처가 스스로 한다.
    @discardableResult
    func focus(timeout: TimeInterval = 4) -> Bool {
        guard let app = running else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            focusName, object: outPath, userInfo: nil, deliverImmediately: true)
        let ok = waitUntil(timeout) { app.isActive }
        if ok { runLoopSleep(0.1) }   // 키윈도우·first responder 정착
        return ok
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

// MARK: 사람의 개입 감지
//
// 이 테스트는 포커스·클립보드·키 입력을 점유한다. 사용자가 그 사이에 타이핑하거나
// 창을 바꾸면 붙여넣기가 엉뚱한 곳으로 가거나(포커스 변경), modifier가 눌린 채로
// 트리거돼 앱이 정당하게 전송을 취소한다 — 둘 다 앱의 결함이 아닌데 "씹힘"으로 집계된다.
//
// .hidSystemState 는 **실제 하드웨어 입력만** 반영한다. 테스트가 쏘는 합성 이벤트는
// .combinedSessionState 쪽이라 여기 잡히지 않는다 — 이 차이가 "사람"과 "테스트 자신"을
// 가르는 판별자다. 개입이 섞인 회차는 결함이 아니라 **무효**로 처리한다.
let hidInputTypes: [CGEventType] = [
    .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
    .scrollWheel, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
]

func hardwareIdleSeconds() -> Double {
    hidInputTypes
        .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
        .min() ?? .greatestFiniteMagnitude
}

// 지정한 시간만큼 사람이 손을 뗄 때까지 기다린다. 못 기다리면 false.
func waitForHumanIdle(_ required: Double, timeout: Double) -> Bool {
    waitUntil(timeout) { hardwareIdleSeconds() >= required }
}

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

// 기본 트리거 — 실제 전역 단축키.
//
// 훅(분산 노티)을 기본으로 쓰다가 실측으로 갈아탔다: DistributedNotificationCenter는
// best-effort 전달이라 고빈도로 쏘면 조용히 유실된다. 같은 워크로드에서 훅은 0/6~6/6로
// 요동친 반면 단축키는 6/6로 일관됐다(R0가 매 실행 이 대조를 남긴다). 훅으로 측정하면
// 하네스의 유실을 앱의 씹힘으로 오독하게 된다 — 사용자가 실제로 쓰는 경로로 잰다.
var defaultTrigger: TriggerMethod = {
    if let forced = env["PP_TRIGGER"] {
        return forced == "hook" ? .hook : .hotkey
    }
    return axTrusted ? .hotkey : .hook
}()

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
    var interfered = 0   // 사람의 하드웨어 입력이 섞인 회차 — 무효, 결함 아님
    var latencies: [TimeInterval] = []
    var strict: Bool     // true면 누락도 결함 (동기 패턴)

    // 간섭 회차는 시도에서 뺀 "유효 시도"로 본다
    var valid: Int { attempted - interfered }
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
func syncCycle(into catcher: Catcher, expect: String, timeout: TimeInterval = 5,
               method: TriggerMethod? = nil, tally: inout Tally,
               copy: () -> Void) -> Bool {
    let method = method ?? defaultTrigger
    let baseline = catcher.text()
    copy()
    tally.attempted += 1
    let t0 = Date()
    fire(method)

    let grew = waitUntil(timeout) { catcher.text().count > baseline.count }
    if grew { runLoopSleep(0.12) }   // 기록 정착 — 늦게 오는 두 번째 붙여넣기(중복)도 잡는다
    let elapsed = Date().timeIntervalSince(t0)

    // 이 회차가 도는 동안 사람이 키보드·마우스를 건드렸으면 결과를 신뢰할 수 없다.
    // 여유 0.3초는 판정 직전에 들어온 입력까지 보수적으로 무효로 보기 위한 것.
    if hardwareIdleSeconds() < elapsed + 0.3 {
        tally.interfered += 1
        return false
    }

    guard grew else { tally.dropped += 1; return false }

    let delta = String(catcher.text().dropFirst(baseline.count))
    tally.latencies.append(elapsed)

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

// 시나리오 하나가 끝날 때마다 호출 — 개입이 심하면 더 돌려 봐야 쓰레기 수치만 쌓인다.
func abortIfContaminated(_ t: Tally) {
    guard t.attempted >= 4, Double(t.interfered) / Double(t.attempted) > 0.25 else { return }
    print("")
    print("⛔️ 중단 — '\(t.name)'에서 \(t.attempted)회 중 \(t.interfered)회가 사람의 입력과 겹쳤습니다.")
    print("   이 테스트는 포커스·클립보드·키 입력을 독점해야 의미 있는 수치가 나옵니다.")
    print("   자리를 비울 수 있을 때 다시 실행해 주세요. 지금까지의 수치는 신뢰할 수 없습니다.")
    exit(3)
}

// MARK: - 준비

print("PlainPaste 스트레스 — 실행 중 키보드/마우스를 만지지 마세요")
print("반복 \(cycles)회 · 소크 \(soakCycles)회 · 기본 트리거: \(defaultTrigger.rawValue)")
if !axTrusted {
    print("⚠︎ 러너에 손쉬운 사용 권한이 없어 훅(분산 노티)으로 폴백합니다 —")
    print("   훅은 고빈도에서 유실되므로 누락 수치를 앱의 결함으로 읽으면 안 됩니다.")
}
print("")

// ── 유휴 게이트: 사람이 손을 뗀 뒤에 시작한다 ────────────────────────────────
// 작업 중에 돌리면 포커스를 뺏어 사용자를 방해하고, 수치도 오염된다. 둘 다 막는다.
if hardwareIdleSeconds() < 2.0 {
    print("사람의 입력이 감지됨 — 손을 뗄 때까지 최대 30초 기다립니다…")
}
if !waitForHumanIdle(2.0, timeout: 30) {
    print("")
    print("⛔️ 시작하지 않습니다 — 키보드·마우스가 계속 사용 중입니다.")
    print("   이 테스트는 실행 내내 포커스·클립보드·키 입력을 독점합니다.")
    print("   자리를 비울 수 있을 때 다시 실행해 주세요.")
    exit(3)
}

// ── 캐너리: 앱이 살아 있고 ⌘V를 보낼 수 있는가 ────────────────────────────────
//
// 한 방에 판정하지 않는다. `open` 직후에는 앱이 아직 RegisterEventHotKey·노티 옵저버를
// 걸기 전일 수 있어, 첫 트리거만 보고 "권한 없음"으로 결론내면 오진이 된다(실측으로 겪음).
// 앱 프로세스가 뜰 때까지 기다린 뒤, 두 트리거를 번갈아 여러 번 시도하고 무엇이 언제
// 통했는지까지 남긴다.
catcherA.focus()
var canary = Tally(name: "canary", note: "", strict: true)

let appUp = waitUntil(10) {
    !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty
}
if !appUp { print("⚠︎ PlainPaste 프로세스를 10초 내에 찾지 못했습니다") }

var canaryOK = false
var canaryMethod: TriggerMethod?
var canaryAttempts = 0
for attempt in 1...6 {
    let method: TriggerMethod = (attempt % 2 == 1) ? defaultTrigger
                                                   : (defaultTrigger == .hotkey ? .hook : .hotkey)
    canaryAttempts = attempt
    if syncCycle(into: catcherA, expect: marker("CAN", attempt), timeout: 3,
                 method: method, tally: &canary, copy: { setPlain(marker("CAN", attempt)) }) {
        canaryOK = true
        canaryMethod = method
        break
    }
    runLoopSleep(0.5)
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
print("캐너리 통과 — \(canaryMethod?.rawValue ?? "?") 경로, \(canaryAttempts)번째 시도에서 성공")
if canaryAttempts > 1 {
    notes.append("캐너리가 \(canaryAttempts)번째에 통과 — 기동 직후 트리거 등록 지연 관측")
}
if let m = canaryMethod, m != defaultTrigger {
    print("⚠︎ 기본 트리거(\(defaultTrigger.rawValue))는 실패하고 \(m.rawValue)로 통과했습니다 —")
    print("   기본 트리거를 \(m.rawValue)로 바꿔 측정합니다.")
    notes.append("기본 트리거를 \(m.rawValue)로 자동 전환 (원래 \(defaultTrigger.rawValue) 실패)")
    defaultTrigger = m
}
print("")

// ── R0: 트리거 방법 대조 — 하네스 유효성의 근거를 매 실행 남긴다 ──────────────
// 같은 워크로드를 훅과 실제 단축키로 각각 돌려 도착률을 비교한다. 훅이 뚜렷이 낮으면
// 그 차이는 앱의 씹힘이 아니라 분산 노티의 유실이다 — 이 표가 없으면 두 원인을 구분할
// 근거가 사라진다. 판정하지 않고 관측만 한다.
print("R0 트리거 대조 — 훅 vs 실제 단축키, 각 \(max(10, cycles / 2))회")
if axTrusted {
    let n = max(10, cycles / 2)
    var viaHook = Tally(name: "R0 훅", note: "대조", strict: false)
    var viaKey = Tally(name: "R0 단축키", note: "대조", strict: false)
    catcherA.focus()
    // 성공한 붙여넣기는 ~150ms에 도착한다. 타임아웃을 길게 두면 실패 회차마다 그만큼
    // 기다릴 뿐 아니라, 간섭 판정 창(= 사이클 길이)이 넓어져 사람의 입력에 과다 노출된다.
    let probeTimeout: TimeInterval = 2.5
    for i in 1...n {
        let m = marker("R0H", i)
        syncCycle(into: catcherA, expect: m, timeout: probeTimeout,
                  method: .hook, tally: &viaHook) { setPlain(m) }
    }
    for i in 1...n {
        let m = marker("R0K", i)
        syncCycle(into: catcherA, expect: m, timeout: probeTimeout,
                  method: .hotkey, tally: &viaKey) { setPlain(m) }
    }
    let hookRate = Double(viaHook.arrived) / Double(max(1, viaHook.valid))
    let keyRate = Double(viaKey.arrived) / Double(max(1, viaKey.valid))
    print(String(format: "   훅 %d/%d (%.0f%%) · 단축키 %d/%d (%.0f%%) · 간섭 %d/%d",
                 viaHook.arrived, viaHook.valid, hookRate * 100,
                 viaKey.arrived, viaKey.valid, keyRate * 100,
                 viaHook.interfered + viaKey.interfered, viaHook.attempted + viaKey.attempted))
    if keyRate - hookRate > 0.15 {
        notes.append(String(format: "R0: 훅 도착률이 단축키보다 %.0f%%p 낮음 — 분산 노티 유실. "
                            + "훅 기반 수치는 앱의 씹힘으로 읽으면 안 됨",
                            (keyRate - hookRate) * 100))
    } else {
        notes.append("R0: 훅·단축키 도착률 차이 미미 — 두 트리거 모두 신뢰 가능")
    }
} else {
    print("   ⊘ SKIP — 러너 권한 없음 (단축키 경로를 만들 수 없어 대조 불가)")
}

// ── R1: 동기 반복 (같은 프로세스 복사) ───────────────────────────────────────
print("R1 동기 반복 \(cycles)회 — 같은 프로세스 복사, 훅 트리거")
var r1 = Tally(name: "R1 동기 반복", note: "같은 프로세스 복사 · 훅", strict: true)
catcherA.focus()
for i in 1...cycles {
    let m = marker("R1", i)
    syncCycle(into: catcherA, expect: m, tally: &r1) { setPlain(m) }
}
abortIfContaminated(r1)
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
abortIfContaminated(r2)
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
abortIfContaminated(r3)
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
abortIfContaminated(r4)
tallies.append(r4)
if misdelivered > 0 { notes.append("R4: 비활성 앱에 붙여넣기가 샌 횟수 \(misdelivered)") }
print("   도착 \(r4.arrived)/\(r4.attempted) · 누락 \(r4.dropped) · 밀림 \(r4.stale) · 오배달 \(misdelivered)")

// ── R5: 훅 트리거 반복 — 비게이팅 관측 ───────────────────────────────────────
// 기본 트리거가 실제 단축키가 된 뒤로 훅은 "테스트 훅 자체가 얼마나 믿을 만한가"를
// 추적하는 자리다. 유실이 하네스 쪽 특성이므로 누락으로 실패시키지 않는다(strict: false).
// R0가 이미 훅을 20회 대조하므로 여기서는 짧게만 확인한다 — 훅은 실패 시 매번
// 타임아웃까지 기다려 비용이 크고, 그 긴 사이클이 간섭 판정 창을 넓혀 오탐을 키운다.
let r5Cycles = max(8, cycles / 5)
print("R5 훅 트리거 \(r5Cycles)회 — 테스트 훅 신뢰도 관측 (비게이팅)")
var r5 = Tally(name: "R5 훅(관측)", note: "누락 비게이팅", strict: false)
catcherA.focus()
for i in 1...r5Cycles {
    let m = marker("R5", i)
    syncCycle(into: catcherA, expect: m, timeout: 2.5, method: .hook, tally: &r5) { setPlain(m) }
}
abortIfContaminated(r5)
tallies.append(r5)
print("   도착 \(r5.arrived)/\(r5.attempted) · 누락 \(r5.dropped) · 밀림 \(r5.stale) · 중복 \(r5.duplicated)")

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
        fire(defaultTrigger)
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
abortIfContaminated(r7)
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
    fire(defaultTrigger)
    guard waitUntil(15, { catcherA.text().count > baseline.count }) else { r8.dropped += 1; continue }
    runLoopSleep(0.15)
    let delta = String(catcherA.text().dropFirst(baseline.count))
    r8.latencies.append(Date().timeIntervalSince(t0))
    if delta.replacingOccurrences(of: " ", with: "").contains(digits) { r8.arrived += 1 }
    else { r8.stale += 1; notes.append("R8 회차\(i) 인식 불일치: '\(delta.prefix(40))'") }
}
abortIfContaminated(r8)
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
print(pad("시나리오", 20) + rpad("유효", 6) + rpad("도착", 6) + rpad("누락", 6)
      + rpad("밀림", 6) + rpad("중복", 6) + rpad("오염", 6) + rpad("간섭", 6)
      + rpad("p50", 9) + rpad("p95", 9) + rpad("판정", 7))
print(String(repeating: "─", count: 84))
for t in tallies {
    print(pad(t.name, 20) + rpad("\(t.valid)", 6) + rpad("\(t.arrived)", 6)
          + rpad("\(t.dropped)", 6) + rpad("\(t.stale)", 6) + rpad("\(t.duplicated)", 6)
          + rpad("\(t.polluted)", 6) + rpad("\(t.interfered)", 6)
          + rpad(ms(t.pct(0.5)), 9) + rpad(ms(t.pct(0.95)), 9)
          + rpad(t.ok ? "✓" : "✗", 7))
}
print(String(repeating: "─", count: 84))
print("판정 기준: 동기 시나리오는 누락도 결함 · 비동기(R6)는 누락 허용, 밀림·중복·오염만 결함")
print("유효 = 시도 − 간섭. 간섭 = 그 회차가 도는 동안 사람의 하드웨어 입력이 섞인 것 (무효 처리)")
let totalInterfered = tallies.reduce(0) { $0 + $1.interfered }
if totalInterfered > 0 {
    print("")
    print("⚠︎ 간섭 \(totalInterfered)회 — 실행 중 키보드·마우스 입력이 있었습니다.")
    print("   해당 회차는 집계에서 제외했지만, 수치의 신뢰도는 그만큼 낮습니다.")
}

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
