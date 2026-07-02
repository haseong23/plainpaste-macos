import AppKit

// 아이콘 1024x1024 PNG 생성기 — 의존성 없이 Core Graphics로 직접 그림
// usage: makeicon <out.png>

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
let S = CGFloat(size)

// MARK: 배경 스퀘어클(둥근 사각형) + 대각선 그라디언트
let bg = CGRect(x: 0, y: 0, width: S, height: S)
let bgRadius = S * 0.2237
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: bg, cornerWidth: bgRadius, cornerHeight: bgRadius, transform: nil))
ctx.clip()
let bgGrad = CGGradient(colorsSpace: cs,
                        colors: [CGColor(red: 0.38, green: 0.35, blue: 0.92, alpha: 1),
                                 CGColor(red: 0.60, green: 0.37, blue: 0.98, alpha: 1)] as CFArray,
                        locations: [0, 1])!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
ctx.restoreGState()

// MARK: 흰색 카드(문서) + 그림자
let cardW = S * 0.54, cardH = S * 0.62
let card = CGRect(x: (S - cardW) / 2, y: (S - cardH) / 2, width: cardW, height: cardH)
let cardRadius = S * 0.055
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.014), blur: S * 0.035,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
ctx.addPath(CGPath(roundedRect: card, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// MARK: 텍스트 라인(캡슐) — plain text 은유
let available = cardW * 0.72
let leftX = card.minX + cardW * 0.14
let lineH = cardH * 0.062
let gap = cardH * 0.095
let accent = CGColor(red: 0.45, green: 0.37, blue: 0.94, alpha: 1)
let gray = CGColor(red: 0.62, green: 0.63, blue: 0.70, alpha: 1)

// 위에서부터: 강조 라인 1개 + 본문 라인들
let lines: [(CGFloat, CGColor)] = [
    (0.85, accent),
    (1.00, gray),
    (0.70, gray),
    (0.92, gray),
    (0.55, gray),
]
var y = card.maxY - cardH * 0.19
for (widthRatio, color) in lines {
    let lw = available * widthRatio
    let lineRect = CGRect(x: leftX, y: y - lineH, width: lw, height: lineH)
    ctx.addPath(CGPath(roundedRect: lineRect, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
    y -= (lineH + gap)
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG 인코딩 실패\n".data(using: .utf8)!)
    exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("아이콘 생성: \(outPath)")
