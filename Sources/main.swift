import Cocoa
import Carbon
import ServiceManagement

// 순수 로직(Shortcut, carbonModifiers, keyName, textPasteMode, ocrUpscaleFactor,
// groupOCRLines, looksLikeCode)은 PlainPasteCore.swift로 분리 — 유닛테스트 대상.
// OCR 파이프라인(recognizeTextOCR)은 OCREngine.swift로 분리 — 정확도 벤치(Tests/Bench) 대상.

// MARK: - 앱 본체

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var shortcut = Shortcut.load()

    private var recorderWindow: NSWindow?
    private var keyMonitor: Any?

    // 서식/이미지를 벗겨 붙여넣기 전의 클립보드 원본 (아이템별 플레이버 → 데이터).
    // 메뉴 "직전 원본을 클립보드로 복원"으로만 되살린다 — 자동(지연) 복원은 ⌘C 경합(B2)으로
    // 두 번 회수된 전력이 있어, 경합이 원천 불가능한 사용자 주도 방식만 제공한다.
    private var savedOriginal: [[NSPasteboard.PasteboardType: Data]]?

    private let shortcutInfoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let restoreItem = NSMenuItem(title: "직전 원본을 클립보드로 복원",
                                         action: #selector(restoreOriginal), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "로그인 시 자동 시작",
                                       action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        handleExistingInstanceIfNeeded()
        setupStatusItem()
        installHotKeyHandler()
        registerHotKey()
        refreshMenu()
        _ = ensureAccessibility(prompt: true)   // 최초 실행 시 권한 안내
        setupTestHookIfEnabled()
    }

    // MARK: 중복 인스턴스 정리 — 전역 단축키는 먼저 등록한 프로세스가 선점한다
    //
    // 예전 인스턴스가 남아 있으면 새로 뜬 쪽은 RegisterEventHotKey가 실패하고, 사용자에겐
    // "단축키가 안 먹는다"는 증상만 남는다 — 원인이 화면 어디에도 드러나지 않는다.
    // 등록 실패(registerHotKey의 alert)를 기다리는 사후 감지 대신 기동 시점에 확인해
    // 정리 여부를 묻는다. E2E(-PPTestHook)는 러너가 이미 정리하므로 건너뛴다.
    private func handleExistingInstanceIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "PPTestHook"),
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        guard !others.isEmpty else { return }

        let a = NSAlert()
        a.messageText = "PlainPaste가 이미 실행 중입니다"
        a.informativeText = "전역 단축키는 먼저 실행된 쪽이 가져갑니다.\n" +
                            "기존 인스턴스를 종료하고 이 인스턴스로 계속할까요?"
        a.addButton(withTitle: "기존 인스턴스 종료")   // .alertFirstButtonReturn
        a.addButton(withTitle: "이 인스턴스 종료")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return
        }

        others.forEach { $0.terminate() }
        // 종료가 반영돼 단축키 선점이 풀린 뒤에 registerHotKey가 돌게 잠깐 대기 (최대 2초).
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, others.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: E2E 테스트 훅 — `-PPTestHook 1` 실행 인자로 켰을 때만 활성 (Tests/e2e.sh 전용)
    //
    // 분산 노티로 smartPaste()를 발동시켜, 합성 단축키 없이도 테스트 러너가 안정적으로
    // 붙여넣기 경로를 구동할 수 있게 한다. 평상시 실행에는 아무 영향 없음.

    private func setupTestHookIfEnabled() {
        guard UserDefaults.standard.bool(forKey: "PPTestHook") else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.haseong23.plainpaste.test.trigger"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.smartPaste()
        }
        // 메뉴 "직전 원본을 클립보드로 복원" 동작 모사 (E2E S13)
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.haseong23.plainpaste.test.restore"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.restoreOriginal()
        }
    }

    // MARK: 메뉴바

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "doc.plaintext",
                                 accessibilityDescription: "PlainPaste") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "PT"
            }
        }

        let menu = NSMenu()
        shortcutInfoItem.isEnabled = false
        menu.addItem(shortcutInfoItem)

        let hintItem = NSMenuItem(title: "이미지는 자동으로 OCR 후 텍스트로 붙여넣기",
                                  action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)

        restoreItem.target = self
        menu.addItem(restoreItem)

        let change = NSMenuItem(title: "단축키 변경…",
                                action: #selector(changeShortcut), keyEquivalent: "")
        change.target = self
        menu.addItem(change)

        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "PlainPaste 종료",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func refreshMenu() {
        shortcutInfoItem.title = "현재 단축키: \(shortcut.display)"
        if #available(macOS 13.0, *) {
            loginItem.isHidden = false
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginItem.isHidden = true
        }
    }

    // MARK: 전역 단축키 (Carbon RegisterEventHotKey — 이벤트 탭 불필요, 가장 가벼움)

    private func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue().smartPaste()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func registerHotKey() {
        unregisterHotKey()
        let hotKeyID = EventHotKeyID(signature: OSType(0x504C_5054), id: 1) // 'PLPT'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            hotKeyRef = nil
            alert("단축키 등록 실패",
                  "\(shortcut.display) 조합을 등록할 수 없습니다 (다른 앱이나 이전 PlainPaste가 선점했을 수 있습니다). 다른 조합을 지정하거나 이전 인스턴스를 종료해 주세요.")
        }
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    // MARK: 핵심 기능 — 클립보드 내용에 따라 자동 분기 (글자→플레인, 이미지→OCR)

    func smartPaste() {
        guard ensureAccessibility(prompt: true) else {
            showAccessibilityAlert()
            return
        }

        let pb = NSPasteboard.general
        let sourceChangeCount = pb.changeCount

        // 1) 클립보드에 글자가 있으면 → 플레인 텍스트 붙여넣기
        //    분기 규칙은 textPasteMode(순수 로직)로 두어 유닛테스트로 고정한다.
        let plain = pb.string(forType: .string)
        switch textPasteMode(plainString: plain, hasRichText: pasteboardHasRichText(pb)) {
        case .rewrite(let text):
            // 서식이 있으면 → 순수 텍스트로 재작성해 붙여넣기 (클립보드를 플레인으로 덮어씀).
            // 재작성할 문자열은 규칙 함수가 연관값으로 넘겨준다 — 강제 언래핑 불필요.
            pasteText(text, ifPasteboardUnchangedFrom: sourceChangeCount)
            return
        case .direct:
            // 이미 순수 텍스트라 지울 서식이 없다.
            // 우리 프로세스가 값을 되읽어 다시 쓰면 한 박자 밀리는(직전 값이 나오는) 문제가,
            // 지연 복원까지 하면 사용자의 다음 ⌘C를 덮어써(두 번 눌러야 하는) 문제가 생긴다.
            // → 클립보드는 손대지 않고 ⌘V만 보내 대상 앱이 살아 있는 클립보드를 직접 읽게 한다.
            postCmdVAfterModifierRelease(expectedChangeCount: sourceChangeCount)
            return
        case .none:
            break   // 글자가 없음 → 아래 이미지/OCR 분기로
        }

        // 2) 글자가 없고 이미지가 있으면 → OCR 후 인식 텍스트 붙여넣기
        if let image = clipboardImage() {
            guard pb.changeCount == sourceChangeCount else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let text = recognizeTextOCR(in: image)
                DispatchQueue.main.async {
                    // OCR 중 새 복사가 들어왔으면 그 내용을 절대 덮어쓰지 않는다.
                    guard pb.changeCount == sourceChangeCount else { return }
                    guard let text, !text.isEmpty else {
                        // 사용자에겐 같은 beep이지만 원인은 둘이다: nil = Vision 인식 실패
                        // (사유는 OCREngine이 남김), 빈 문자열 = 이미지에 글자가 없음.
                        NSLog("PlainPaste: OCR 결과 없음 (%@)",
                              text == nil ? "인식 실패" : "인식된 글자 없음")
                        NSSound.beep()
                        return
                    }
                    self.pasteText(text, ifPasteboardUnchangedFrom: sourceChangeCount)
                }
            }
            return
        }

        // 3) 붙여넣을 게 없음
        NSLog("PlainPaste: 클립보드에 붙여넣을 텍스트·이미지가 없습니다 (types: %@)",
              String(describing: pb.types?.map(\.rawValue) ?? []))
        NSSound.beep()
    }

    // 클립보드에 지워야 할 실제 서식(리치 텍스트)이 들어 있는지 확인
    private func pasteboardHasRichText(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types else { return false }
        let rich: Set<NSPasteboard.PasteboardType> = [.rtf, .rtfd, .html]
        return types.contains { rich.contains($0) }
    }

    // 주어진 텍스트를 플레인으로 붙여넣기 (서식/이미지를 벗겨 재작성하는 경로).
    // 붙여넣은 뒤 클립보드는 이 플레인 텍스트를 그대로 둔다 — 백그라운드 타이머로 원본을
    // 되돌리면 그 쓰기가 사용자의 ⌘C와 경합해(크로스-프로세스 changeCount 지연) 방금 복사한
    // 내용을 덮어써 "⌘C를 두 번 눌러야 복사되는" 문제가 생기므로 복원하지 않는다.
    private func pasteText(_ text: String, ifPasteboardUnchangedFrom sourceChangeCount: Int) {
        let pb = NSPasteboard.general
        guard pb.changeCount == sourceChangeCount else { return }

        savedOriginal = snapshotPasteboard(pb)   // 덮어쓰기 전 원본 보관 (메뉴로 온디맨드 복원)

        pb.clearContents()
        pb.setString(text, forType: .string)
        let plainChangeCount = pb.changeCount

        // 단축키의 물리 modifier(⌃⌥⌘ 등)가 아직 눌려 있으면 합성 ⌘V에 섞여
        // 대상 앱이 엉뚱한 조합(예: ⌘⇧V)을 받게 됨 → 모두 놓일 때까지 대기 후 전송.
        // settle: 방금 쓴 플레인 텍스트가 대상 앱에 반영되도록 아주 짧게 대기 후 ⌘V 전송.
        postCmdVAfterModifierRelease(expectedChangeCount: plainChangeCount, settle: 0.05)
    }

    // MARK: 원본 보관·복원 (온디맨드)

    // 클립보드 전체 스냅샷 — 모든 아이템·플레이버를 데이터로 보관.
    // 큰 스크린샷(TIFF+PNG)은 수십 MB일 수 있으나 1개만 유지하고 복원·교체 시 해제된다.
    private func snapshotPasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]]? {
        guard let items = pb.pasteboardItems, !items.isEmpty else { return nil }
        let snapshot = items.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { dict, type in
                if let data = item.data(forType: type) { dict[type] = data }
            }
        }.filter { !$0.isEmpty }
        return snapshot.isEmpty ? nil : snapshot
    }

    @objc private func restoreOriginal() {
        guard let saved = savedOriginal else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(saved.map { flavors in
            let item = NSPasteboardItem()
            for (type, data) in flavors { item.setData(data, forType: type) }
            return item
        })
        savedOriginal = nil   // 클립보드가 다시 원본을 가짐 — 보관본 해제, 메뉴 비활성화
    }

    // 원본 보관 중일 때만 복원 메뉴 활성화
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(restoreOriginal) { return savedOriginal != nil }
        return true
    }

    // 클립보드에서 이미지를 CGImage로 획득 (비트맵 또는 파일 URL)
    private func clipboardImage() -> CGImage? {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let image = NSImage(data: data) {
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        // Finder에서 이미지 파일을 복사한 경우 (파일 URL)
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first,
           let image = NSImage(contentsOf: url) {
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return nil
    }

    // 물리 modifier가 모두 놓일 때까지 기다렸다가 ⌘V를 보낸다.
    //
    // 데드라인 안에 놓이지 않으면 **보내지 않는다**. postCmdV가 합성 이벤트의 flags를 ⌘ 단독으로
    // 강제하긴 하지만 그건 이벤트에 실린 값일 뿐이고, 이벤트 탭이나 NSEvent.modifierFlags로
    // 하드웨어 상태를 따로 읽는 앱(터미널 멀티플렉서·에디터)은 여전히 ⌃⌥⌘가 눌린 것으로 본다
    // → ⌘V가 엉뚱한 명령으로 해석될 수 있다. 눌린 채 보내느니 안 보내는 쪽이 안전한 실패다.
    // 조용히 실패하지 않도록 beep + 로그로 알린다 (앱의 다른 실패 신호와 같은 방식).
    //
    // 2초: 단축키를 누른 손이 늦게 떨어지는 정상 범위(~수백 ms)는 넉넉히 덮으면서,
    // modifier가 물려 버린 비정상 상태에서는 무한정 기다리지 않는 값.
    private static let modifierReleaseTimeout: TimeInterval = 2.0

    private func postCmdVAfterModifierRelease(expectedChangeCount: Int, settle: TimeInterval = 0) {
        DispatchQueue.global(qos: .userInteractive).async {
            let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
            func modifiersReleased() -> Bool {
                CGEventSource.flagsState(.combinedSessionState).intersection(modifierMask).isEmpty
            }

            let deadline = Date().addingTimeInterval(Self.modifierReleaseTimeout)
            var released = modifiersReleased()
            while !released, Date() < deadline {
                usleep(10_000)
                released = modifiersReleased()
            }
            guard released else {
                NSLog("PlainPaste: modifier가 %.0f초 내에 해제되지 않아 붙여넣기를 취소했습니다",
                      Self.modifierReleaseTimeout)
                DispatchQueue.main.async { NSSound.beep() }
                return
            }

            if settle > 0 { usleep(useconds_t(settle * 1_000_000)) }
            DispatchQueue.main.async {
                guard NSPasteboard.general.changeCount == expectedChangeCount else { return }
                self.postCmdV()
            }
        }
    }

    private func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return }
        // flags를 ⌘ 단독으로 강제 — 사용자가 아직 ⇧ 등을 누르고 있어도 순수 ⌘V로 전달됨
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    @discardableResult
    private func ensureAccessibility(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private func showAccessibilityAlert() {
        alert("손쉬운 사용 권한 필요",
              "붙여넣기 키 입력을 보내려면 손쉬운 사용 권한이 필요합니다.\n\n" +
              "시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 PlainPaste를 켜 주세요.\n" +
              "(목록에 이미 있는데도 안 되면 PlainPaste를 제거 후 다시 추가하세요 — 재빌드하면 서명이 바뀌어 권한이 풀립니다.)")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 단축키 변경 UI

    @objc private func changeShortcut() {
        guard recorderWindow == nil else {
            recorderWindow?.makeKeyAndOrderFront(nil)
            return
        }
        unregisterHotKey()  // 현재 조합과 같은 키도 녹화할 수 있도록 잠시 해제

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "단축키 설정"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let label = NSTextField(labelWithString:
            "새 단축키 조합을 누르세요\n\n⌘ / ⌥ / ⌃ 중 하나 이상 포함 · ESC 취소")
        label.alignment = .center
        label.frame = window.contentView!.bounds.insetBy(dx: 16, dy: 16)
        label.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(label)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.closeRecorder()
                return nil
            }
            let mods = carbonModifiers(from: event.modifierFlags)
            // shift 단독은 일반 타이핑과 충돌하므로 ⌘/⌥/⌃ 중 하나는 필수
            guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 else {
                NSSound.beep()
                return nil
            }
            self.shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods)
            self.shortcut.save()
            self.closeRecorder()
            return nil
        }

        recorderWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeRecorder() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let window = recorderWindow {
            window.delegate = nil
            recorderWindow = nil
            window.close()
        }
        registerHotKey()
        refreshMenu()
    }

    func windowWillClose(_ notification: Notification) {
        // 사용자가 닫기 버튼으로 닫은 경우
        if (notification.object as? NSWindow) === recorderWindow {
            recorderWindow?.delegate = nil
            recorderWindow = nil
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
            registerHotKey()
            refreshMenu()
        }
    }

    // MARK: 로그인 시 자동 시작

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            alert("자동 시작 설정 실패", error.localizedDescription)
        }
        refreshMenu()
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// MARK: - 엔트리 포인트

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // Dock 아이콘 없음, 메뉴바 전용
app.run()
