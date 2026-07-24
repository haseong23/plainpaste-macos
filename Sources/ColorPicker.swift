import Cocoa

// MARK: - Color Picker (화면 색상 추출 → HEX 클립보드)
//
// macOS 기본 스포이드(NSColorSampler, 10.15+)로 화면의 한 픽셀 색을 집어 HEX(#RRGGBB)로
// 클립보드에 복사한다. 최근 추출 색을 히스토리로 유지(메뉴에서 재복사). PowerToys "Color Picker" 대응.
// HEX 포맷/파싱은 순수 로직(hexFromComponents·rgbFromHex, PowerMacToysCore.swift)에 두어 유닛테스트한다.
final class ColorPicker {
    private(set) var history: [String] = []   // 최근 추출한 HEX (최신이 앞)
    private let maxHistory = 8

    // 히스토리 변화 시 메뉴 갱신용 콜백.
    var onChange: (() -> Void)?

    func pick() {
        // 배포 타깃(12.0)이 10.15 이상이라 항상 사용 가능. 핸들러가 샘플러를 선택 동안 유지한다.
        NSColorSampler().show { [weak self] color in
            guard let self, let color else { return }   // nil = 사용자 취소
            self.record(color)
        }
    }

    private func record(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { NSSound.beep(); return }
        let hex = hexFromComponents(Double(rgb.redComponent),
                                    Double(rgb.greenComponent),
                                    Double(rgb.blueComponent))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(hex, forType: .string)

        history.removeAll { $0 == hex }        // 중복 제거 후 맨 앞에
        history.insert(hex, at: 0)
        if history.count > maxHistory { history.removeLast(history.count - maxHistory) }
        onChange?()
    }
}
