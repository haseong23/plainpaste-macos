import Cocoa
import CoreImage
import Vision

// OCR 엔진 — 앱(main.swift)과 정확도 벤치(Tests/Bench/OCRBench.swift)가 공유하는 파이프라인.
// main.swift에서 분리하고 파라미터를 OCROptions로 열어, 벤치가 변형(교정 on/off·업스케일·
// 전처리·언어 순서)을 같은 코드 경로로 A/B 측정할 수 있게 했다.
// OCROptions.default가 곧 앱의 실사용 설정이다 — 벤치 데이터로 근거가 생긴 값만 바꾼다.

struct OCROptions {
    var languageCorrection = true    // Vision 사전 기반 교정 (일반 문장 ↑, 코드/식별자 ↓)
    var codeAwareRetry = true        // 결과가 코드처럼 보이면(looksLikeCode) 교정 없이 1회 재인식
    var codeRetryAutoDetect = true   // 재인식 패스는 언어 자동 감지 — ko 우선 편향으로 인한
                                     // camelCase 대문자 오류 복구, 한글 주석은 무손상 (벤치 근거)
    var codeRetryLanguages: [String]?  // 재인식 패스 언어 강제 (nil = 기본 languages 유지)
    var fastLevel = false            // .fast 인식 레벨 — 글리프 직독에 가까움 (라틴 중심, 실험용)
    var codeRetryFastLevel = false   // 재인식 패스를 .fast로 (l/1/I 모호 글리프 실험)
    var languages = ["ko-KR", "en-US"]
    var autoDetectLanguage = false
    var upscaleTarget = 2000.0       // 긴 변 목표 px (ocrUpscaleFactor)
    var upscaleCap = 3.0
    var invertIfDark = false         // 어두운 이미지(다크모드) 반전 전처리 — 벤치 실험용
    static let `default` = OCROptions()
}

// Vision 온디바이스 OCR (한글 우선, 작은 글씨 보정 위해 업스케일)
func recognizeTextOCR(in image: CGImage, options: OCROptions = .default) -> String? {
    var target = upscaleForOCR(image, target: options.upscaleTarget, cap: options.upscaleCap)
    if options.invertIfDark, meanLuminance(of: target) < 0.4,
       let inverted = invertImage(target) {
        target = inverted
    }

    guard let first = performRecognition(on: target, options: options) else { return nil }

    // 코드/터미널/URL로 보이면 교정이 식별자·해시를 사전 단어로 훼손했을 수 있다
    // → 교정 끄고(+ 필요 시 언어 정책 바꿔) 재인식한 결과를 채택 (근거: Tests/ocr_bench.sh)
    if options.codeAwareRetry, options.languageCorrection, looksLikeCode(first) {
        var retryOptions = options
        retryOptions.languageCorrection = false
        if options.codeRetryAutoDetect { retryOptions.autoDetectLanguage = true }
        if let langs = options.codeRetryLanguages { retryOptions.languages = langs }
        if options.codeRetryFastLevel { retryOptions.fastLevel = true }
        if let retried = performRecognition(on: target, options: retryOptions), !retried.isEmpty {
            return retried
        }
    }
    return first
}

private func performRecognition(on image: CGImage, options: OCROptions) -> String? {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = options.fastLevel ? .fast : .accurate
    request.usesLanguageCorrection = options.languageCorrection
    request.minimumTextHeight = 0.01                          // 작은 UI 글씨도 놓치지 않게
    if #available(macOS 13.0, *) {
        request.revision = VNRecognizeTextRequestRevision3     // 한국어 지원·최신 정확도
        request.automaticallyDetectsLanguage = options.autoDetectLanguage
        if !options.autoDetectLanguage {
            request.recognitionLanguages = options.languages   // 빈도순: 한글 > 영어 (기본)
        }
    } else {
        request.recognitionLanguages = ["en-US"]               // 12.x: 한국어 미지원
    }
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    guard (try? handler.perform([request])) != nil,
          let observations = request.results else { return nil }
    // 시각적 줄로 재구성: 같은 줄은 공백 결합, 줄들은 위→아래 (로직은 groupOCRLines에서 테스트)
    let items: [(string: String, box: CGRect)] = observations.compactMap {
        guard let s = $0.topCandidates(1).first?.string else { return nil }
        return (s, $0.boundingBox)
    }
    return groupOCRLines(items).joined(separator: "\n")
}

// 작은 이미지를 확대해 OCR 정확도(특히 1 l I | 같은 글자 구분)를 높임.
// 이미 충분히 크면 원본을 그대로 반환.
func upscaleForOCR(_ image: CGImage, target: Double = 2000.0, cap: Double = 3.0) -> CGImage {
    let scale = ocrUpscaleFactor(maxDim: max(image.width, image.height), target: target, cap: cap)
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

// 평균 밝기(0~1) — 다크모드 캡처 감지용 (16×16 다운샘플 평균)
func meanLuminance(of image: CGImage) -> Double {
    let w = 16, h = 16
    var pixels = [UInt8](repeating: 0, count: w * h)
    guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 1.0 }
    ctx.interpolationQuality = .low
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let sum = pixels.reduce(0) { $0 + Int($1) }
    return Double(sum) / Double(w * h) / 255.0
}

private func invertImage(_ image: CGImage) -> CGImage? {
    let inverted = CIImage(cgImage: image).applyingFilter("CIColorInvert")
    let ctx = CIContext(options: [.useSoftwareRenderer: true])   // 헤드리스/샌드박스 안전
    return ctx.createCGImage(inverted, from: inverted.extent)
}
