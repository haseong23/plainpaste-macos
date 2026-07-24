import Cocoa

// MARK: - Text Extractor (화면 영역 OCR → 클립보드)
//
// 전역 단축키로 macOS 기본 영역 선택 UI(`screencapture -i`)를 띄워 사용자가 드래그한
// 영역을 캡처하고, 기존 Vision OCR 파이프라인(recognizeTextOCR, OCREngine.swift)으로
// 텍스트를 인식해 클립보드에 복사한다. PowerToys의 Text Extractor에 대응.
//
//  • 캡처는 Apple 기본 도구에 위임 → 익숙한 십자선 UI, 별도 오버레이 창 불필요.
//  • 화면 기록(Screen Recording) 권한이 필요할 수 있다(최초 1회 시스템 프롬프트).
//  • 붙여넣기 경로와 달리 결과를 "클립보드에 복사"만 한다 — 사용자가 원하는 곳에 붙여넣는다.
final class TextExtractor {
    private var running = false

    func capture() {
        guard !running else { return }   // 이미 캡처 중이면 무시(십자선 중복 방지)
        running = true

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pmt-ocr-\(UUID().uuidString).png")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-i", "-x", tmp.path]   // -i: 대화형 영역 선택, -x: 셔터음 없음
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.finish(at: tmp) }
        }
        do {
            try proc.run()
        } catch {
            running = false
            NSSound.beep()   // screencapture 실행 자체가 실패
        }
    }

    private func finish(at url: URL) {
        running = false
        // 이미지를 메모리로 올린 뒤(비동기 OCR가 참조) 임시 파일은 즉시 정리.
        defer { try? FileManager.default.removeItem(at: url) }

        // 사용자가 ESC로 취소하면 파일이 생성되지 않는다 → 조용히 종료.
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let nsImage = NSImage(data: data),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let text = recognizeTextOCR(in: cg)
            DispatchQueue.main.async {
                guard let text, !text.isEmpty else {
                    NSSound.beep()   // 인식된 글자 없음
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }
    }
}
