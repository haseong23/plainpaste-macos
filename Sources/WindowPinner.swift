import Cocoa
import ApplicationServices

// MARK: - 창 항상 위 고정 (AX 재-앞으로 방식)
//
// macOS에는 다른 앱의 창을 진짜 topmost(항상 위)로 만드는 공개 API가 없다
// (Windows의 SetWindowPos(HWND_TOPMOST)에 해당하는 게 없음). 대신 손쉬운 사용
// (Accessibility) API로 "핀한 창"을 기억해 두고, 다른 앱이 앞으로 나올 때마다 그
// 창을 다시 최상단으로 끌어올려 항상 위를 근사한다.
//
//  • 장점: 가볍고, 기존 전역 단축키·손쉬운 사용 권한 인프라에 그대로 붙는다.
//  • 한계: 창을 앞에 두려면 macOS에선 소유 앱을 활성화해야 하므로 전환 때 포커스가
//         핀한 창으로 넘어가고 살짝 튄다. 같은 앱의 다른 창 위로는 유지하지 않는다.
final class WindowPinner {
    private(set) var isPinned = false
    private(set) var pinnedTitle: String?

    private var pinnedWindow: AXUIElement?
    private var pinnedApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    // 상태가 바뀔 때(핀/해제/자동 해제) 메뉴 갱신 등에 쓰는 콜백.
    var onChange: (() -> Void)?

    // 현재 최전면 앱의 포커스 창을 핀 ↔ 해제 토글.
    // 이미 핀 상태면 어떤 창을 핀했든 무조건 해제하고, 아니면 지금 창을 핀한다.
    func toggle() {
        if isPinned { unpin() } else { pinFrontmostWindow() }
    }

    // MARK: 핀

    private func pinFrontmostWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            NSSound.beep()   // 최전면 앱이 없거나 우리 자신이면 핀할 대상이 없음
            return
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value)
        guard err == .success, let win = value,
              CFGetTypeID(win) == AXUIElementGetTypeID() else {
            NSSound.beep()   // 포커스 창을 못 얻음 (전체 화면 앱 등)
            return
        }

        let window = win as! AXUIElement
        pinnedWindow = window
        pinnedApp = app
        pinnedTitle = windowTitle(window) ?? app.localizedName
        isPinned = true
        startObserving()
        onChange?()
    }

    func unpin() {
        stopObserving()
        pinnedWindow = nil
        pinnedApp = nil
        pinnedTitle = nil
        isPinned = false
        onChange?()
    }

    // MARK: 다른 앱 활성화 감시 → 핀한 창 재-앞으로

    private func startObserving() {
        let nc = NSWorkspace.shared.notificationCenter
        activationObserver = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handleActivation(note)
        }
        terminationObserver = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let pinnedApp = self.pinnedApp,
                  let terminated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            if terminated.processIdentifier == pinnedApp.processIdentifier {
                self.unpin()   // 핀한 앱이 종료됨 → 자동 해제
            }
        }
    }

    private func stopObserving() {
        let nc = NSWorkspace.shared.notificationCenter
        if let o = activationObserver { nc.removeObserver(o); activationObserver = nil }
        if let o = terminationObserver { nc.removeObserver(o); terminationObserver = nil }
    }

    private func handleActivation(_ note: Notification) {
        guard isPinned, let pinnedApp,
              let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        // 핀한 앱 자신 / 우리 앱이 앞으로 온 경우는 재-앞으로 불필요(무한 루프 방지).
        let pid = activated.processIdentifier
        if pid == pinnedApp.processIdentifier { return }
        if pid == ProcessInfo.processInfo.processIdentifier { return }
        raisePinned()
    }

    // 핀한 앱을 활성화하고 그 창을 최상단으로 올린다.
    private func raisePinned() {
        guard let window = pinnedWindow, let app = pinnedApp else { return }
        if app.isTerminated { unpin(); return }

        if #available(macOS 14.0, *) {
            _ = app.activate()
        } else {
            _ = app.activate(options: [])
        }
        let err = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if err == .invalidUIElement || err == .cannotComplete {
            unpin()   // 창이 닫혔거나 더는 접근 불가 → 자동 해제
        }
    }

    // MARK: 창 제목

    private func windowTitle(_ window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success,
              let title = value as? String, !title.isEmpty else { return nil }
        return title
    }
}
