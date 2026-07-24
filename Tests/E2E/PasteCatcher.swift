import Cocoa

// PowerMacToys E2E 수신 앱 — 포커스를 잡고 서 있다가, 붙여넣어진(⌘V) 내용을 파일로 노출한다.
//
// 사용법:  PasteCatcher <출력파일경로>
//   • 텍스트가 바뀔 때마다 전문을 <출력파일>에 원자적으로 기록
//   • 창이 키윈도우가 되고 앱이 활성화되면 <출력파일>.ready 에 자기 PID 기록
//   • 분산 노티 com.haseong23.powermactoys.test.catcher.clear 수신 → 텍스트·파일 비움
//   • 포커스를 뺏기면 0.3초 주기로 재활성화 (E2E 실행 중 항상 붙여넣기 대상 유지)
//
// TCC 권한 불요 — 포커스된 앱으로서 ⌘V 키 이벤트를 받기만 한다.

let clearNotification = Notification.Name("com.haseong23.powermactoys.test.catcher.clear")

final class CatcherDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    private let outPath: String
    private var window: NSWindow!
    private var textView: NSTextView!
    private var wroteReady = false

    init(outPath: String) { self.outPath = outPath }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 번들 없는 바이너리는 메뉴가 없어 ⌘V 키 이퀴벌런트가 동작하지 않는다 → 최소 Edit 메뉴 구성
        setupMenu()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "PasteCatcher (E2E)"
        window.level = .floating          // 다른 창에 가려 포커스를 잃지 않도록
        window.center()

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

        // 활성화 유지 루프: frontmost가 아니면 재활성화, 준비되면 ready 파일 1회 기록
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
                self.window.makeKeyAndOrderFront(nil)
                self.window.makeFirstResponder(self.textView)
            } else if !self.wroteReady, self.window.isKeyWindow {
                self.wroteReady = true
                try? String(ProcessInfo.processInfo.processIdentifier)
                    .write(toFile: self.outPath + ".ready", atomically: true, encoding: .utf8)
            }
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
    FileHandle.standardError.write("사용법: PasteCatcher <출력파일경로>\n".data(using: .utf8)!)
    exit(64)
}

let app = NSApplication.shared
let delegate = CatcherDelegate(outPath: CommandLine.arguments[1])
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
