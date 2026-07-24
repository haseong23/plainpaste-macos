import Cocoa

// OCR 정확도 벤치 — 합성 코퍼스(+ Tests/fixtures/ocr/의 실제 스크린샷)를 여러 OCROptions
// 변형으로 인식해 CER(문자 오류율, 낮을수록 좋음)로 채점한다. OCR 개선은 감이 아니라
// 이 표를 근거로 결정한다. 인식 경로는 앱과 동일한 recognizeTextOCR(OCREngine.swift).
//
// 실행:  ./Tests/ocr_bench.sh [--verbose]
// 실제 실패 사례 추가: Tests/fixtures/ocr/이름.png + 이름.txt(기대 텍스트) 쌍을 넣으면
// 자동으로 포함된다 — 실패 스크린샷이 쌓일수록 벤치가 회귀 스위트가 된다.

struct BenchCase {
    let name: String
    let group: String        // ko / en / code / mixed / fixture
    let image: CGImage
    let truth: String
}

struct Variant {
    let name: String
    let note: String
    let options: OCROptions
}

@main
enum OCRBench {
    static func main() {
        let verbose = CommandLine.arguments.contains("--verbose")
        let cases = makeCorpus() + loadFixtures()
        let variants = makeVariants()

        // variant → case → (cer, 출력)
        var results: [String: [String: (cer: Double, got: String)]] = [:]
        var times: [String: TimeInterval] = [:]

        for v in variants {
            let t0 = Date()
            var perCase: [String: (Double, String)] = [:]
            for c in cases {
                let got = recognizeTextOCR(in: c.image, options: v.options) ?? ""
                perCase[c.name] = (cer(got: got, truth: c.truth), got)
                if verbose {
                    print("[\(v.name)] \(c.name)\n  want: \(normalize(c.truth))\n  got:  \(normalize(got))")
                }
            }
            results[v.name] = perCase
            times[v.name] = Date().timeIntervalSince(t0)
        }

        printTable(cases: cases, variants: variants, results: results, times: times)
        printFailures(of: "retryAT", cases: cases, results: results)
    }

    // MARK: 변형 정의 — retry(교정on + 코드재인식)가 제안 기본값

    static func makeVariants() -> [Variant] {
        var base = OCROptions(); base.codeAwareRetry = false
        var nocorr = OCROptions(); nocorr.languageCorrection = false; nocorr.codeAwareRetry = false
        var retry = OCROptions(); retry.codeRetryAutoDetect = false
        var retryEN = OCROptions(); retryEN.codeRetryAutoDetect = false
        retryEN.codeRetryLanguages = ["en-US"]
        let retryAuto = OCROptions()                               // = 채택된 기본값 (.default)
        var autolang = OCROptions(); autolang.autoDetectLanguage = true
        var noscale = OCROptions(); noscale.upscaleCap = 1.0
        var scale4x = OCROptions(); scale4x.upscaleTarget = 3000; scale4x.upscaleCap = 4.0
        var invert = OCROptions(); invert.invertIfDark = true
        var fastRT = OCROptions(); fastRT.codeRetryFastLevel = true
        return [
            Variant(name: "base",     note: "교정 on, 재인식 없음 (1.1까지의 동작)", options: base),
            Variant(name: "nocorr",   note: "교정 항상 off", options: nocorr),
            Variant(name: "retry",    note: "코드면 교정 off 재인식 (언어는 ko 우선 유지)", options: retry),
            Variant(name: "retryEN",  note: "재인식을 en-US 단독으로 — 한글 주석 파괴로 탈락", options: retryEN),
            Variant(name: "retryAT",  note: "재인식을 교정 off + 언어 자동 감지로 (채택된 기본값)", options: retryAuto),
            Variant(name: "fastRT",   note: "재인식을 .fast로 — 언더스코어 소실로 탈락", options: fastRT),
            Variant(name: "autolang", note: "항상 언어 자동 감지 (+재인식)", options: autolang),
            Variant(name: "noscale",  note: "업스케일 없음 (+재인식)", options: noscale),
            Variant(name: "scale4x",  note: "업스케일 목표 3000px·상한 4x (+재인식)", options: scale4x),
            Variant(name: "invert",   note: "다크 이미지 반전 전처리 (+재인식)", options: invert),
        ]
    }

    // MARK: 합성 코퍼스 — 증상별 대표 케이스 (한글 오인식 / 코드·URL 훼손 / 작은 글씨 / 다크)

    static func makeCorpus() -> [BenchCase] {
        let koLines = ["클립보드의 서식 있는 텍스트를 순수한 텍스트로 붙여넣는 도구입니다",
                       "메뉴 막대에서 단축키를 자유롭게 바꿀 수 있습니다"]
        let codeLines = ["let mode = textPasteMode(plainString: plain, hasRichText: rich)",
                         "guard pb.changeCount == sourceChangeCount else { return }"]
        let termLines = ["$ git rebase --autosquash HEAD~3",
                         "error: cannot rebase: You have unstaged changes."]
        let koCommentLines = ["let pb = NSPasteboard.general   // 클립보드 서버 프록시",
                              "pb.clearContents()              // 소유권 획득 후 재작성"]
        // 실사용 리포트(dd_l → dd_/dd_. 오인식) 기반 — 식별자 끝 l/1/I/| 모호 글리프.
        // 잔여 l→1 치환은 Vision 모델 한계로 확인됨(24px에서도 발생) — 이 케이스의 역할은
        // 설정 회귀 방지 + OS 업그레이드 시 모델 개선 여부 감지.
        let identLines = ["dd_l = df.load()", "count_l id_1 x_I total_li"]
        return [
            BenchCase(name: "ko-큰글씨", group: "ko",
                      image: render(koLines, w: 1400, h: 220, size: 34), truth: koLines.joined(separator: "\n")),
            BenchCase(name: "ko-작은글씨", group: "ko",
                      image: render(koLines, w: 620, h: 100, size: 14), truth: koLines.joined(separator: "\n")),
            BenchCase(name: "ko-다크", group: "ko",
                      image: render(koLines, w: 1400, h: 220, size: 34, dark: true), truth: koLines.joined(separator: "\n")),
            BenchCase(name: "en-산문", group: "en",
                      image: render(["PowerMacToys converts formatted clipboard text into plain text",
                                     "before pasting it into the frontmost application"],
                                    w: 1200, h: 200, size: 30),
                      truth: "PowerMacToys converts formatted clipboard text into plain text\nbefore pasting it into the frontmost application"),
            BenchCase(name: "code-밝음", group: "code",
                      image: render(codeLines, w: 1500, h: 200, size: 26, mono: true),
                      truth: codeLines.joined(separator: "\n")),
            BenchCase(name: "code-터미널", group: "code",
                      image: render(termLines, w: 1200, h: 200, size: 26, mono: true, dark: true),
                      truth: termLines.joined(separator: "\n")),
            BenchCase(name: "url", group: "code",
                      image: render(["https://github.com/haseong23/plainpaste-macos/releases/latest"],
                                    w: 1400, h: 120, size: 28, mono: true),
                      truth: "https://github.com/haseong23/plainpaste-macos/releases/latest"),
            BenchCase(name: "hash-hex", group: "code",
                      image: render(["commit ecc90dc359d7 flags 0x7FFF5FBF"], w: 1100, h: 120, size: 28, mono: true),
                      truth: "commit ecc90dc359d7 flags 0x7FFF5FBF"),
            BenchCase(name: "code-식별자", group: "code",
                      image: render(identLines, w: 560, h: 110, size: 14, mono: true),
                      truth: identLines.joined(separator: "\n")),
            BenchCase(name: "code-한글주석", group: "code",
                      image: render(koCommentLines, w: 1500, h: 200, size: 24, mono: true, dark: true),
                      truth: koCommentLines.joined(separator: "\n")),
            BenchCase(name: "ko-저대비", group: "ko",
                      image: render(koLines, w: 760, h: 120, size: 15,
                                    fg: NSColor(white: 0.52, alpha: 1), bg: NSColor(white: 0.78, alpha: 1)),
                      truth: koLines.joined(separator: "\n")),
            BenchCase(name: "ko-jpeg열화", group: "ko",
                      image: jpegRoundtrip(render(koLines, w: 760, h: 120, size: 15), quality: 0.35),
                      truth: koLines.joined(separator: "\n")),
            BenchCase(name: "ko-en혼용", group: "mixed",
                      image: render(["붙여넣기 단축키는 Control Option Command V 입니다"], w: 1300, h: 130, size: 30),
                      truth: "붙여넣기 단축키는 Control Option Command V 입니다"),
            BenchCase(name: "빽빽한줄", group: "mixed",
                      image: render(["1. 클립보드 감시는 하지 않습니다", "2. 단축키를 누를 때만 동작합니다",
                                     "3. OCR is on-device only", "4. 네트워크 접근이 없습니다",
                                     "5. Vision framework revision 3", "6. 마지막 줄입니다"],
                                    w: 700, h: 260, size: 14, spacing: 1.55),
                      truth: "1. 클립보드 감시는 하지 않습니다\n2. 단축키를 누를 때만 동작합니다\n3. OCR is on-device only\n4. 네트워크 접근이 없습니다\n5. Vision framework revision 3\n6. 마지막 줄입니다"),
        ]
    }

    // Tests/fixtures/ocr/이름.png + 이름.txt → 실측 케이스로 편입
    static func loadFixtures() -> [BenchCase] {
        let dir = "Tests/fixtures/ocr"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return files.filter { $0.hasSuffix(".png") }.sorted().compactMap { f in
            let base = String(f.dropLast(4))
            guard let img = NSImage(contentsOfFile: "\(dir)/\(f)")?
                      .cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let truth = try? String(contentsOfFile: "\(dir)/\(base).txt", encoding: .utf8)
            else { return nil }
            return BenchCase(name: "fx:\(base)", group: "fixture", image: img,
                             truth: truth.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: 텍스트 이미지 렌더링 (픽셀 정확)

    static func render(_ lines: [String], w: Int, h: Int, size: CGFloat,
                       mono: Bool = false, dark: Bool = false, spacing: CGFloat = 1.8,
                       fg: NSColor? = nil, bg: NSColor? = nil) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (bg ?? (dark ? NSColor(white: 0.12, alpha: 1) : .white)).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                        : NSFont.systemFont(ofSize: size)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg ?? (dark ? NSColor(white: 0.85, alpha: 1) : NSColor.black),
        ]
        var y = CGFloat(h) - size * spacing
        for line in lines {
            (line as NSString).draw(at: NSPoint(x: 24, y: y), withAttributes: attrs)
            y -= size * spacing
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    // 스크린샷 재압축(JPEG) 열화 모사 — 실전의 안티앨리어싱·압축 아티팩트에 근접
    static func jpegRoundtrip(_ image: CGImage, quality: CGFloat) -> CGImage {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg,
                                            properties: [.compressionFactor: quality]),
              let degraded = NSImage(data: data)?
                  .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        return degraded
    }

    // MARK: CER 채점

    static func normalize(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func cer(got: String, truth: String) -> Double {
        let g = Array(normalize(got)), t = Array(normalize(truth))
        guard !t.isEmpty else { return g.isEmpty ? 0 : 1 }
        return Double(levenshtein(g, t)) / Double(t.count)
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    // MARK: 출력

    static func printTable(cases: [BenchCase], variants: [Variant],
                           results: [String: [String: (cer: Double, got: String)]],
                           times: [String: TimeInterval]) {
        func fmt(_ v: Double) -> String { String(format: "%6.1f", v * 100) }

        print("")
        print("CER % (낮을수록 좋음) — 변형 설명:")
        for v in variants { print("  \(v.name.padding(toLength: 9, withPad: " ", startingAt: 0)) \(v.note)") }
        print("")
        let nameW = 14
        print("케이스".padding(toLength: nameW, withPad: " ", startingAt: 0)
              + variants.map { $0.name.leftPadded(7) }.joined())
        for c in cases {
            print(c.name.padding(toLength: nameW, withPad: " ", startingAt: 0)
                  + variants.map { fmt(results[$0.name]![c.name]!.cer).leftPadded(7) }.joined())
        }
        print("")
        for group in ["ko", "en", "code", "mixed", "fixture"] {
            let inGroup = cases.filter { $0.group == group }
            guard !inGroup.isEmpty else { continue }
            print("평균 \(group)".padding(toLength: nameW, withPad: " ", startingAt: 0)
                  + variants.map { v in
                      let mean = inGroup.map { results[v.name]![$0.name]!.cer }.reduce(0, +) / Double(inGroup.count)
                      return fmt(mean).leftPadded(7)
                  }.joined())
        }
        print("평균 전체".padding(toLength: nameW, withPad: " ", startingAt: 0)
              + variants.map { v in
                  let mean = cases.map { results[v.name]![$0.name]!.cer }.reduce(0, +) / Double(cases.count)
                  return fmt(mean).leftPadded(7)
              }.joined())
        print("시간(s)".padding(toLength: nameW, withPad: " ", startingAt: 0)
              + variants.map { String(format: "%6.1f", times[$0.name] ?? 0).leftPadded(7) }.joined())
    }

    // 제안 기본값(retry)이 아직 틀리는 케이스의 실제 출력 확인용
    static func printFailures(of variantName: String, cases: [BenchCase],
                              results: [String: [String: (cer: Double, got: String)]]) {
        guard let perCase = results[variantName] else { return }
        let failing = cases.filter { (perCase[$0.name]?.cer ?? 0) > 0.001 }
            .sorted { perCase[$0.name]!.cer > perCase[$1.name]!.cer }
        guard !failing.isEmpty else {
            print("\n'\(variantName)' 변형: 전 케이스 CER 0% — 남은 오류 없음"); return
        }
        print("\n'\(variantName)' 변형의 잔여 오류 상세 (CER 큰 순):")
        for c in failing.prefix(5) {
            print("  ▸ \(c.name) (CER \(String(format: "%.1f", perCase[c.name]!.cer * 100))%)")
            print("    want: \(normalize(c.truth))")
            print("    got:  \(normalize(perCase[c.name]!.got))")
        }
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
