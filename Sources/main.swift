import Cocoa
import Carbon
import ServiceManagement

// 순수 로직(Shortcut, carbonModifiers, keyName, textPasteMode, ocrUpscaleFactor,
// groupOCRLines, looksLikeCode)은 PowerMacToysCore.swift로 분리 — 유닛테스트 대상.
// OCR 파이프라인(recognizeTextOCR)은 OCREngine.swift로 분리 — 정확도 벤치(Tests/Bench) 대상.

// MARK: - 앱 본체

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var shortcut = Shortcut.load()

    // 창 항상 위 고정 (별도 전역 단축키 · AX 재-앞으로). 붙여넣기와 독립.
    private let pinner = WindowPinner()
    private var pinHotKeyRef: EventHotKeyRef?
    private let pinShortcut = Shortcut.load(keyPrefix: "pinShortcut", fallback: .pinDefault)

    // 화면 영역 텍스트 추출 (별도 전역 단축키 · 기본 OCR 파이프라인 재활용).
    private let textExtractor = TextExtractor()
    private var ocrHotKeyRef: EventHotKeyRef?
    private let ocrShortcut = Shortcut.load(keyPrefix: "ocrShortcut", fallback: .ocrDefault)

    // 잠자기 방지 (IOKit 전원 어서션 · 메뉴 토글).
    private let sleepPreventer = SleepPreventer()

    // 화면 색상 추출 (별도 전역 단축키 · NSColorSampler → HEX 클립보드).
    private let colorPicker = ColorPicker()
    private var colorHotKeyRef: EventHotKeyRef?
    private let colorShortcut = Shortcut.load(keyPrefix: "colorShortcut", fallback: .colorDefault)

    // 창 배치 (AX 이동/리사이즈 · ⌃⌥ 방향키 4개 + 메뉴 전체 존).
    private let snapper = WindowSnapper()
    private var snapHotKeyRefs: [EventHotKeyRef?] = []

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
    private let pinItem = NSMenuItem(title: "창 항상 위 고정",
                                     action: #selector(togglePinFromMenu), keyEquivalent: "")

    // 잠자기 방지 — 부모 항목 + 라디오 서브메뉴(끔/시스템/화면 포함)
    private let awakeParent = NSMenuItem(title: "잠자기 방지", action: nil, keyEquivalent: "")
    private let awakeOffItem = NSMenuItem(title: "끔",
                                          action: #selector(setAwakeOff), keyEquivalent: "")
    private let awakeSystemItem = NSMenuItem(title: "켜기 (화면은 꺼질 수 있음)",
                                             action: #selector(setAwakeSystem), keyEquivalent: "")
    private let awakeDisplayItem = NSMenuItem(title: "켜기 (화면도 켜둠)",
                                              action: #selector(setAwakeDisplay), keyEquivalent: "")

    // 화면 색상 추출 + 최근 색상 서브메뉴(refreshMenu에서 재구성).
    private let colorHistoryParent = NSMenuItem(title: "최근 색상", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        pinner.onChange = { [weak self] in self?.refreshMenu() }
        sleepPreventer.onChange = { [weak self] in self?.refreshMenu() }
        colorPicker.onChange = { [weak self] in self?.refreshMenu() }
        setupStatusItem()
        installHotKeyHandler()
        registerHotKey()
        registerPinHotKey()
        registerTextExtractorHotKey()
        registerColorPickerHotKey()
        registerSnapHotKeys()
        refreshMenu()
        _ = ensureAccessibility(prompt: true)   // 최초 실행 시 권한 안내
        setupTestHookIfEnabled()
    }

    // MARK: E2E 테스트 훅 — `-PPTestHook 1` 실행 인자로 켰을 때만 활성 (Tests/e2e.sh 전용)
    //
    // 분산 노티로 smartPaste()를 발동시켜, 합성 단축키 없이도 테스트 러너가 안정적으로
    // 붙여넣기 경로를 구동할 수 있게 한다. 평상시 실행에는 아무 영향 없음.

    private func setupTestHookIfEnabled() {
        guard UserDefaults.standard.bool(forKey: "PPTestHook") else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.haseong23.powermactoys.test.trigger"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.smartPaste()
        }
        // 메뉴 "직전 원본을 클립보드로 복원" 동작 모사 (E2E S13)
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.haseong23.powermactoys.test.restore"),
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
                                 accessibilityDescription: "PowerMacToys") {
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

        let extractItem = NSMenuItem(title: "화면에서 텍스트 추출  (\(ocrShortcut.display))",
                                     action: #selector(extractTextFromMenu), keyEquivalent: "")
        extractItem.target = self
        menu.addItem(extractItem)

        // 고급 붙여넣기 — 클립보드 텍스트를 포맷 변환(레지스트리 순서대로 서브메뉴 구성).
        let advParent = NSMenuItem(title: "고급 붙여넣기 (클립보드 변환)",
                                   action: nil, keyEquivalent: "")
        let advMenu = NSMenu()
        for (idx, t) in pasteTransforms.enumerated() {
            let item = NSMenuItem(title: t.title,
                                  action: #selector(applyPasteTransform(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = idx
            advMenu.addItem(item)
        }
        advParent.submenu = advMenu
        menu.addItem(advParent)

        restoreItem.target = self
        menu.addItem(restoreItem)

        let change = NSMenuItem(title: "단축키 변경…",
                                action: #selector(changeShortcut), keyEquivalent: "")
        change.target = self
        menu.addItem(change)

        menu.addItem(.separator())
        pinItem.target = self
        menu.addItem(pinItem)

        // 창 배치 — 모든 존을 서브메뉴로. 4개(절반 L/R·최대화·가운데)는 ⌃⌥ 방향키도 함께.
        let snapParent = NSMenuItem(title: "창 배치", action: nil, keyEquivalent: "")
        let snapMenu = NSMenu()
        for zone in SnapZone.allCases {
            let item = NSMenuItem(title: zone.title + snapHotkeyHint(zone),
                                  action: #selector(snapFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = zone.rawValue
            snapMenu.addItem(item)
        }
        snapParent.submenu = snapMenu
        menu.addItem(snapParent)

        let awakeMenu = NSMenu()
        for item in [awakeOffItem, awakeSystemItem, awakeDisplayItem] {
            item.target = self
            awakeMenu.addItem(item)
        }
        awakeParent.submenu = awakeMenu
        menu.addItem(awakeParent)

        let colorItem = NSMenuItem(title: "화면 색상 추출  (\(colorShortcut.display))",
                                   action: #selector(pickColorFromMenu), keyEquivalent: "")
        colorItem.target = self
        menu.addItem(colorItem)
        menu.addItem(colorHistoryParent)   // 서브메뉴·표시 여부는 refreshMenu에서 갱신

        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "PowerMacToys 종료",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func refreshMenu() {
        shortcutInfoItem.title = "현재 단축키: \(shortcut.display)"

        if pinner.isPinned {
            let name = pinner.pinnedTitle.map { " — \($0)" } ?? ""
            pinItem.title = "창 고정 해제\(name)"
            pinItem.state = .on
        } else {
            pinItem.title = "창 항상 위 고정  (\(pinShortcut.display))"
            pinItem.state = .off
        }

        awakeParent.state = sleepPreventer.mode == .off ? .off : .on   // 활성 시 부모에 체크
        awakeOffItem.state = sleepPreventer.mode == .off ? .on : .off
        awakeSystemItem.state = sleepPreventer.mode == .system ? .on : .off
        awakeDisplayItem.state = sleepPreventer.mode == .displayOn ? .on : .off

        // 최근 색상: 히스토리가 비면 숨기고, 있으면 스와치와 함께 서브메뉴 재구성.
        let history = colorPicker.history
        colorHistoryParent.isHidden = history.isEmpty
        if history.isEmpty {
            colorHistoryParent.submenu = nil
        } else {
            let sub = NSMenu()
            for hex in history {
                let item = NSMenuItem(title: hex, action: #selector(copyHistoryColor(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = hex
                item.image = colorSwatch(hex)
                sub.addItem(item)
            }
            colorHistoryParent.submenu = sub
        }

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
        // 단축키가 여러 개이므로 EventHotKeyID.id로 어느 조합이 눌렸는지 분기한다.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            switch hkID.id {
            case 1: delegate.smartPaste()
            case 2: delegate.togglePin()
            case 3: delegate.extractText()
            case 4: delegate.pickColor()
            case 10: delegate.snapWindow(.leftHalf)
            case 11: delegate.snapWindow(.rightHalf)
            case 12: delegate.snapWindow(.maximize)
            case 13: delegate.snapWindow(.center)
            default: break
            }
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
                  "\(shortcut.display) 조합을 등록할 수 없습니다 (다른 앱이나 이전 PowerMacToys가 선점했을 수 있습니다). 다른 조합을 지정하거나 이전 인스턴스를 종료해 주세요.")
        }
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    // 창 고정 단축키 (id 2). 붙여넣기 단축키와 signature는 같고 id로만 구분.
    private func registerPinHotKey() {
        if let ref = pinHotKeyRef { UnregisterEventHotKey(ref); pinHotKeyRef = nil }
        let hotKeyID = EventHotKeyID(signature: OSType(0x504C_5054), id: 2) // 'PLPT'
        let status = RegisterEventHotKey(pinShortcut.keyCode, pinShortcut.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &pinHotKeyRef)
        if status != noErr {
            pinHotKeyRef = nil
            // 핀 단축키는 부가 기능이라 모달 경고 대신 콘솔에만 남긴다(붙여넣기 흐름 방해 방지).
            FileHandle.standardError.write(
                Data("PowerMacToys: 창 고정 단축키(\(pinShortcut.display)) 등록 실패 — 다른 앱이 선점했을 수 있습니다.\n".utf8))
        }
    }

    // 텍스트 추출 단축키 (id 3). 화면 영역 OCR → 클립보드.
    private func registerTextExtractorHotKey() {
        if let ref = ocrHotKeyRef { UnregisterEventHotKey(ref); ocrHotKeyRef = nil }
        let hotKeyID = EventHotKeyID(signature: OSType(0x504C_5054), id: 3) // 'PLPT'
        let status = RegisterEventHotKey(ocrShortcut.keyCode, ocrShortcut.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ocrHotKeyRef)
        if status != noErr {
            ocrHotKeyRef = nil
            FileHandle.standardError.write(
                Data("PowerMacToys: 텍스트 추출 단축키(\(ocrShortcut.display)) 등록 실패 — 다른 앱이 선점했을 수 있습니다.\n".utf8))
        }
    }

    // 화면 영역을 캡처해 OCR한 뒤 클립보드에 복사. 키 입력을 보내지 않으므로 손쉬운 사용
    // 권한은 불필요(캡처엔 화면 기록 권한이 최초 1회 필요할 수 있음 — screencapture가 안내).
    func extractText() { textExtractor.capture() }

    @objc private func extractTextFromMenu() { extractText() }

    // MARK: 고급 붙여넣기 — 클립보드 텍스트를 변환해 클립보드에 되쓴다.
    // 메뉴 클릭 직후 합성 ⌘V는 포커스 복귀 타이밍이 불안정하므로, 클립보드만 바꾸고
    // 사용자가 원할 때 ⌘V 하도록 한다(smartPaste의 자동 붙여넣기와 역할이 다름).
    @objc private func applyPasteTransform(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, idx < pasteTransforms.count else { return }
        let pb = NSPasteboard.general
        guard let s = pb.string(forType: .string), !s.isEmpty else {
            NSSound.beep()   // 클립보드에 변환할 텍스트가 없음
            return
        }
        guard let result = pasteTransforms[idx].apply(s) else {
            NSSound.beep()   // 변환 실패(예: 잘못된 Base64/URL)
            return
        }
        pb.clearContents()
        pb.setString(result, forType: .string)
    }

    // 색상 추출 단축키 (id 4). NSColorSampler → HEX 클립보드.
    private func registerColorPickerHotKey() {
        if let ref = colorHotKeyRef { UnregisterEventHotKey(ref); colorHotKeyRef = nil }
        let hotKeyID = EventHotKeyID(signature: OSType(0x504C_5054), id: 4) // 'PLPT'
        let status = RegisterEventHotKey(colorShortcut.keyCode, colorShortcut.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &colorHotKeyRef)
        if status != noErr {
            colorHotKeyRef = nil
            FileHandle.standardError.write(
                Data("PowerMacToys: 색상 추출 단축키(\(colorShortcut.display)) 등록 실패 — 다른 앱이 선점했을 수 있습니다.\n".utf8))
        }
    }

    func pickColor() { colorPicker.pick() }

    @objc private func pickColorFromMenu() { pickColor() }

    // 최근 색상 항목 클릭 → 그 HEX를 다시 클립보드로 복사.
    @objc private func copyHistoryColor(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(hex, forType: .string)
    }

    // MARK: 창 배치 (⌃⌥ 방향키 4개 · id 10~13, 나머지 존은 메뉴)

    private func registerSnapHotKeys() {
        for ref in snapHotKeyRefs where ref != nil { UnregisterEventHotKey(ref!) }
        snapHotKeyRefs.removeAll()

        let ctrlOpt = UInt32(controlKey | optionKey)
        let bindings: [(UInt32, UInt32)] = [   // (hotkey id, keyCode)
            (10, UInt32(kVK_LeftArrow)),   // 왼쪽 절반
            (11, UInt32(kVK_RightArrow)),  // 오른쪽 절반
            (12, UInt32(kVK_UpArrow)),     // 최대화
            (13, UInt32(kVK_DownArrow)),   // 가운데
        ]
        for (id, key) in bindings {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x504C_5054), id: id)
            let status = RegisterEventHotKey(key, ctrlOpt, hotKeyID,
                                             GetApplicationEventTarget(), 0, &ref)
            if status != noErr {
                FileHandle.standardError.write(
                    Data("PowerMacToys: 창 배치 단축키(id \(id)) 등록 실패 — 다른 앱이 선점했을 수 있습니다.\n".utf8))
            }
            snapHotKeyRefs.append(ref)
        }
    }

    func snapWindow(_ zone: SnapZone) {
        guard ensureAccessibility(prompt: true) else {
            showAccessibilityAlert()   // 다른 앱 창 이동엔 손쉬운 사용 권한 필요
            return
        }
        snapper.snap(zone)
    }

    @objc private func snapFromMenu(_ sender: NSMenuItem) {
        guard let zone = SnapZone(rawValue: sender.tag) else { return }
        snapWindow(zone)
    }

    // ⌃⌥ 방향키가 걸린 4개 존에만 메뉴에 힌트 표기.
    private func snapHotkeyHint(_ zone: SnapZone) -> String {
        switch zone {
        case .leftHalf:  return "  (⌃⌥←)"
        case .rightHalf: return "  (⌃⌥→)"
        case .maximize:  return "  (⌃⌥↑)"
        case .center:    return "  (⌃⌥↓)"
        default:         return ""
        }
    }

    // 메뉴 항목용 작은 색상 스와치 (HEX가 유효할 때만).
    private func colorSwatch(_ hex: String) -> NSImage? {
        guard let rgb = rgbFromHex(hex) else { return nil }
        let color = NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255,
                            blue: CGFloat(rgb.b) / 255, alpha: 1)
        let size = NSSize(width: 14, height: 14)
        let img = NSImage(size: size)
        img.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                     xRadius: 3, yRadius: 3).fill()
        img.unlockFocus()
        return img
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
        case .rewrite:
            // 서식이 있으면 → 순수 텍스트로 재작성해 붙여넣기 (클립보드를 플레인으로 덮어씀)
            pasteText(plain!, ifPasteboardUnchangedFrom: sourceChangeCount)
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
                        NSSound.beep()   // 인식된 글자 없음
                        return
                    }
                    self.pasteText(text, ifPasteboardUnchangedFrom: sourceChangeCount)
                }
            }
            return
        }

        // 3) 붙여넣을 게 없음
        NSSound.beep()
    }

    // MARK: 창 항상 위 고정 토글 (단축키 id 2 / 메뉴)

    func togglePin() {
        guard ensureAccessibility(prompt: true) else {
            showAccessibilityAlert()   // 다른 앱 창 정보를 읽으려면 손쉬운 사용 권한 필요
            return
        }
        pinner.toggle()
    }

    @objc private func togglePinFromMenu() { togglePin() }

    // MARK: 잠자기 방지 토글 (메뉴 라디오)

    @objc private func setAwakeOff()     { sleepPreventer.setMode(.off) }
    @objc private func setAwakeSystem()  { sleepPreventer.setMode(.system) }
    @objc private func setAwakeDisplay() { sleepPreventer.setMode(.displayOn) }

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

    private func postCmdVAfterModifierRelease(expectedChangeCount: Int, settle: TimeInterval = 0) {
        DispatchQueue.global(qos: .userInteractive).async {
            let deadline = Date().addingTimeInterval(1.0)
            let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
            while Date() < deadline,
                  !CGEventSource.flagsState(.combinedSessionState).intersection(modifierMask).isEmpty {
                usleep(10_000)
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
              "시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 PowerMacToys를 켜 주세요.\n" +
              "(목록에 이미 있는데도 안 되면 PowerMacToys를 제거 후 다시 추가하세요 — 재빌드하면 서명이 바뀌어 권한이 풀립니다.)")
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
