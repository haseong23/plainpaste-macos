import Cocoa
import IOKit.pwr_mgt

// MARK: - Awake (잠자기 방지)
//
// IOKit 전원 어서션(IOPMAssertion)으로 시스템 유휴 잠자기를 막는다. PowerToys "Awake" 대응.
//  • .system    — 시스템 잠자기만 막음 (화면은 설정대로 꺼질 수 있음)
//  • .displayOn — 화면 잠자기까지 막음 (디스플레이가 켜져 있으면 시스템도 깨어 있음)
// 앱이 종료되면 어서션도 자동 해제된다(프로세스 소멸 시 커널이 회수) — caffeinate와 동일 원리.
final class SleepPreventer {
    enum Mode { case off, system, displayOn }

    private(set) var mode: Mode = .off
    private var assertionID: IOPMAssertionID = 0

    // 상태 변화 시 메뉴 갱신용 콜백.
    var onChange: (() -> Void)?

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        release()
        mode = newMode
        switch newMode {
        case .off:       break
        case .system:    create(kIOPMAssertionTypePreventUserIdleSystemSleep)
        case .displayOn: create(kIOPMAssertionTypePreventUserIdleDisplaySleep)
        }
        onChange?()
    }

    private func create(_ type: String) {
        var id: IOPMAssertionID = 0
        let reason = "PowerMacToys: 잠자기 방지" as CFString
        let result = IOPMAssertionCreateWithName(type as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 reason, &id)
        if result == kIOReturnSuccess {
            assertionID = id
        } else {
            mode = .off   // 어서션 생성 실패 → 꺼짐 유지
            NSSound.beep()
        }
    }

    private func release() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }
}
