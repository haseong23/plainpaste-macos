import Cocoa
import ApplicationServices

// MARK: - Window Snapping (창 배치)
//
// 손쉬운 사용(AX) API로 최전면 앱의 포커스 창을 화면의 사용가능 영역(메뉴바·Dock 제외)
// 안에서 절반/사분면/최대화/가운데로 이동·리사이즈한다. PowerToys "FancyZones"의 키보드 버전.
// 목표 사각형 계산·좌표 변환은 순수 함수(snapRect·flipVertically, PowerMacToysCore.swift).
//
//  • 한계: 드래그-투-존은 아직 없음(단축키/메뉴 기반). 창 최소 크기가 크면 앱이 리사이즈를 클램프.
final class WindowSnapper {
    func snap(_ zone: SnapZone) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            NSSound.beep()   // 최전면 앱이 없거나 우리 자신
            return
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winVal) == .success,
              let winObj = winVal, CFGetTypeID(winObj) == AXUIElementGetTypeID() else {
            NSSound.beep()   // 포커스 창을 못 얻음(전체화면 앱 등)
            return
        }
        let window = winObj as! AXUIElement

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // 현재 창 중심이 속한 화면을 고른다(멀티 모니터). 못 찾으면 주 화면.
        let current = axFrame(of: window) ?? .zero
        let screen = screenForAXPoint(CGPoint(x: current.midX, y: current.midY),
                                      primaryHeight: primaryHeight) ?? NSScreen.main
        guard let screen else { NSSound.beep(); return }

        // visibleFrame(Cocoa) → AX 좌표로 뒤집어 목표 사각형 계산 후 적용.
        let visibleAX = flipVertically(screen.visibleFrame, in: primaryHeight)
        setAXFrame(window, snapRect(zone, in: visibleAX))
    }

    // MARK: AX 프레임 읽기/쓰기

    private func axFrame(of window: AXUIElement) -> CGRect? {
        var posVal: CFTypeRef?
        var sizeVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeVal) == .success,
              let posObj = posVal, let sizeObj = sizeVal,
              CFGetTypeID(posObj) == AXValueGetTypeID(), CFGetTypeID(sizeObj) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posObj as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeObj as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private func setAXFrame(_ window: AXUIElement, _ rect: CGRect) {
        var pos = rect.origin
        var size = rect.size
        // 화면 간 이동 시 위치가 옛 화면 크기에 클램프될 수 있어 위치→크기→위치 순으로 두 번 적용.
        setValue(window, kAXPositionAttribute, .cgPoint, &pos)
        setValue(window, kAXSizeAttribute, .cgSize, &size)
        setValue(window, kAXPositionAttribute, .cgPoint, &pos)
    }

    private func setValue(_ window: AXUIElement, _ attr: String,
                          _ type: AXValueType, _ ptr: UnsafeRawPointer) {
        if let value = AXValueCreate(type, ptr) {
            AXUIElementSetAttributeValue(window, attr as CFString, value)
        }
    }

    // 주어진 AX 좌표 점을 포함하는 화면(각 화면 frame을 AX로 뒤집어 비교).
    private func screenForAXPoint(_ point: CGPoint, primaryHeight: CGFloat) -> NSScreen? {
        for screen in NSScreen.screens where flipVertically(screen.frame, in: primaryHeight).contains(point) {
            return screen
        }
        return nil
    }
}
