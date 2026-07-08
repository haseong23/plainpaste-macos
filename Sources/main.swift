import Cocoa
import Carbon
import ServiceManagement
import Vision

// MARK: - 단축키 모델 (Carbon modifier 기준으로 저장)

struct Shortcut {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon: cmdKey/shiftKey/optionKey/controlKey

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_V),
                                    modifiers: UInt32(cmdKey | optionKey | controlKey))

    static func load() -> Shortcut {
        let d = UserDefaults.standard
        guard d.object(forKey: "shortcutKeyCode") != nil else { return .default }
        return Shortcut(keyCode: UInt32(d.integer(forKey: "shortcutKeyCode")),
                        modifiers: UInt32(d.integer(forKey: "shortcutModifiers")))
    }

    func save() {
        let d = UserDefaults.standard
        d.set(Int(keyCode), forKey: "shortcutKeyCode")
        d.set(Int(modifiers), forKey: "shortcutModifiers")
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

// MARK: - 앱 본체

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var shortcut = Shortcut.load()

    private var recorderWindow: NSWindow?
    private var keyMonitor: Any?

    private let shortcutInfoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "로그인 시 자동 시작",
                                       action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        installHotKeyHandler()
        registerHotKey()
        refreshMenu()
        _ = ensureAccessibility(prompt: true)   // 최초 실행 시 권한 안내
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

        // 1) 클립보드에 글자가 있으면 → 플레인 텍스트 붙여넣기
        if let plain = pb.string(forType: .string), !plain.isEmpty {
            pasteText(plain)
            return
        }

        // 2) 글자가 없고 이미지가 있으면 → OCR 후 인식 텍스트 붙여넣기
        if let image = clipboardImage() {
            DispatchQueue.global(qos: .userInitiated).async {
                let text = Self.recognizeText(in: image)
                DispatchQueue.main.async {
                    guard let text, !text.isEmpty else {
                        NSSound.beep()   // 인식된 글자 없음
                        return
                    }
                    self.pasteText(text)
                }
            }
            return
        }

        // 3) 붙여넣을 게 없음
        NSSound.beep()
    }

    // 주어진 텍스트를 플레인으로 붙여넣기 (클립보드 스냅샷 → 교체 → 합성 ⌘V → 복원)
    private func pasteText(_ text: String) {
        let pb = NSPasteboard.general

        // 원본 클립보드 스냅샷 (붙여넣기 후 복원해서 클립보드를 훼손하지 않음)
        let savedItems: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        let hadRichContent = savedItems.contains { item in
            item.types.contains { $0 != .string }
        }

        pb.clearContents()
        pb.setString(text, forType: .string)
        let expectedChangeCount = pb.changeCount

        // 단축키의 물리 modifier(⌃⌥⌘ 등)가 아직 눌려 있으면 합성 ⌘V에 섞여
        // 대상 앱이 엉뚱한 조합(예: ⌘⇧V)을 받게 됨 → 모두 놓일 때까지 대기 후 전송
        postCmdVAfterModifierRelease {
            // 붙여넣기가 전달된 뒤 원본 복원 (그 사이 사용자가 새로 복사했으면 건드리지 않음)
            if hadRichContent {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard pb.changeCount == expectedChangeCount else { return }
                    pb.clearContents()
                    pb.writeObjects(savedItems)
                }
            }
        }
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

    // Vision 온디바이스 OCR (한글 우선, 작은 글씨 보정 위해 업스케일)
    private static func recognizeText(in image: CGImage) -> String? {
        let target = upscaleForOCR(image)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.01                          // 작은 UI 글씨도 놓치지 않게
        if #available(macOS 13.0, *) {
            request.revision = VNRecognizeTextRequestRevision3     // 한국어 지원·최신 정확도
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = ["ko-KR", "en-US"]      // 빈도순: 한글 > 영어
        } else {
            request.recognitionLanguages = ["en-US"]               // 12.x: 한국어 미지원
        }
        let handler = VNImageRequestHandler(cgImage: target, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return nil }
        // 읽기 순서(위→아래, 같은 줄은 왼→오)로 정렬 후 줄 결합
        let sorted = observations.sorted { a, b in
            let ay = a.boundingBox.midY, by = b.boundingBox.midY
            if abs(ay - by) > 0.01 { return ay > by }              // boundingBox 원점은 좌하단
            return a.boundingBox.minX < b.boundingBox.minX
        }
        let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // 작은 이미지를 확대해 OCR 정확도(특히 1 l I | 같은 글자 구분)를 높임.
    // 이미 충분히 크면 원본을 그대로 반환.
    private static func upscaleForOCR(_ image: CGImage) -> CGImage {
        let maxDim = max(image.width, image.height)
        guard maxDim > 0 else { return image }
        let scale = min(3.0, max(1.0, 2000.0 / Double(maxDim)))
        guard scale > 1.01 else { return image }
        let w = Int(Double(image.width) * scale)
        let h = Int(Double(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    private func postCmdVAfterModifierRelease(completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            let deadline = Date().addingTimeInterval(1.0)
            let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
            while Date() < deadline,
                  !CGEventSource.flagsState(.combinedSessionState).intersection(modifierMask).isEmpty {
                usleep(10_000)
            }
            self.postCmdV()
            DispatchQueue.main.async(execute: completion)
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
