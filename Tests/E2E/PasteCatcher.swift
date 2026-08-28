import Cocoa

// PlainPaste E2E 수신 앱 — 포커스를 잡고 서 있다가, 붙여넣어진(⌘V) 내용을 파일로 노출한다.
//
// 사용법:  PasteCatcher <출력파일경로> [--no-autofocus]
//   • 텍스트가 바뀔 때마다 전문을 <출력파일>에 원자적으로 기록
//   • 창이 키윈도우가 되고 앱이 활성화되면 <출력파일>.ready 에 자기 PID 기록
//   • 분산 노티 com.haseong23.plainpaste.test.catcher.clear 수신 → 텍스트·파일 비움
//   • 포커스를 뺏기면 0.3초 주기로 재활성화 (E2E 실행 중 항상 붙여넣기 대상 유지)
//   • --no-autofocus: 재활성화 루프를 끈다. 캐처를 둘 이상 띄워 앱 전환을 시험할 때
//     (Tests/stress.sh R4) 서로 포커스를 뺏는 무한 핑퐁을 막는다 — 이때 포커스 전환은
//     러너가 명시적으로 지시한다.
//
// TCC 권한 불요 — 포커스된 앱으로서 ⌘V 키 이벤트를 받기만 한다.

let clearNotification = Notification.Name("com.haseong23.plainpaste.test.catcher.clear")

final class CatcherDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    private let outPath: String
    private let autoFocus: Bool
    private var window: NSWindow!
    private var textView: NSTextView!
    private var wroteReady = false

    init(outPath: String, autoFocus: Bool) {
        self.outPath = outPath
        self.autoFocus = autoFocus
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 번들 없는 바이너리는 메뉴가 없어 ⌘V 키 이퀴벌런트가 동작하지 않는다 → 최소 Edit 메뉴 구성
        setupMenu()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "PasteCatcher (E2E)"
        window.level = .floating          // 다른 창에 가려 포커스를 잃지 않도록
        window.center()
        // 캐처를 둘 이상 띄울 때 창이 정확히 겹치면 어느 쪽이 받았는지 육안 확인이 안 된다.
        // 정확성에는 영향 없지만(붙여넣기는 키윈도우로 간다) 관찰 가능성을 위해 어긋나게 둔다.
        if let dx = ProcessInfo.processInfo.environment["PP_CATCHER_OFFSET"].flatMap({ Double($0) }),
           dx != 0 {
            let f = window.frame
            window.setFrameOrigin(NSPoint(x: f.origin.x + dx, y: f.origin.y))
        }

        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        textView = NSTextView(frame: scroll.bounds)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = self
        scroll.documentView = textView
        window.contentView?.addSubview(scroll)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)

        DistributedNotificationCenter.default().addObserver(
            forName: clearNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.textView.string = ""
            self?.writeOut("")
        }

        writeOut("")   // 초기 상태(빈 파일) 노출

        // 유지 루프 — 0.3초 주기.
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }

            if self.autoFocus, !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
                self.window.makeKeyAndOrderFront(nil)
                self.window.makeFirstResponder(self.textView)
                return
            }

            // 러너가 활성화해 준 직후 텍스트뷰가 first responder가 아니면 ⌘V를 못 받는다.
            if NSApp.isActive, self.window.isKeyWindow, self.window.firstResponder !== self.textView {
                self.window.makeFirstResponder(self.textView)
            }

            guard !self.wroteReady else { return }
            // autoFocus 모드는 스스로 최전면이 되므로 "활성 + 키윈도우"를 준비 완료로 본다.
            // --no-autofocus 모드는 캐처가 여럿이라 **동시에 활성일 수 없다** — 활성을
            // 조건으로 걸면 두 번째 캐처가 영영 ready를 쓰지 못한다. 창이 뜬 시점을
            // 준비 완료로 보고, 포커스는 러너가 준다.
            let ready = self.autoFocus ? (NSApp.isActive && self.window.isKeyWindow)
                                       : self.window.isVisible
            guard ready else { return }
            self.wroteReady = true
            try? String(ProcessInfo.processInfo.processIdentifier)
                .write(toFile: self.outPath + ".ready", atomically: true, encoding: .utf8)
        }
    }

    func textDidChange(_ notification: Notification) {
        writeOut(textView.string)
    }

    private func writeOut(_ s: String) {
        try? s.write(toFile: outPath, atomically: true, encoding: .utf8)
    }

    private func setupMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)),
                                keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}

// MARK: 엔트리 포인트

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("사용법: PasteCatcher <출력파일경로> [--no-autofocus]\n"
        .data(using: .utf8)!)
    exit(64)
}

let app = NSApplication.shared
let delegate = CatcherDelegate(outPath: CommandLine.arguments[1],
                               autoFocus: !CommandLine.arguments.contains("--no-autofocus"))
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
