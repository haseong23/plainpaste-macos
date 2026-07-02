import AppKit

// DMG 창 배경 생성기 — 의존성 없이 Core Graphics로 직접 그림
// usage: makedmgbg <out.png> [scale]
//   window content = 620 x 420 pt (앱 아이콘 톤에 맞춘 라벤더 그라디언트 + 화살표)

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "bg.png"
let scale   = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2]) ?? 1) : 1

let W: CGFloat = 620, H: CGFloat = 420
let pxW = Int(W * scale), pxH = Int(H * scale)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
// rep.size 를 논리 크기(W×H)로 잡아뒀으므로 컨텍스트가 픽셀 매핑 시 자동으로
// scale 배 확대한다. 좌표는 모두 pt 단위(원점: 좌하단)로 그리면 레티나 대응 끝.

// 시각적 "위에서부터의 거리" → CG y(좌하단 기준) 변환
func top(_ t: CGFloat) -> CGFloat { H - t }

// MARK: 배경 세로 그라디언트 (아주 옅은 라벤더)
let bgGrad = CGGradient(colorsSpace: cs,
                        colors: [CGColor(red: 0.99, green: 0.99, blue: 1.00, alpha: 1),
                                 CGColor(red: 0.93, green: 0.92, blue: 0.99, alpha: 1)] as CFArray,
                        locations: [0, 1])!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

// MARK: 화살표 (앱 → Applications), 아이콘 세로 중심(top 210)에 정렬
let cy = top(210)
let x1: CGFloat = 250, x2: CGFloat = 370      // 화살표 시작/끝
let shaftH: CGFloat = 24
let headW: CGFloat = 44, headH: CGFloat = 58
let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: x1, y: cy - shaftH/2))
arrow.addLine(to: CGPoint(x: x2 - headW, y: cy - shaftH/2))
arrow.addLine(to: CGPoint(x: x2 - headW, y: cy - headH/2))
arrow.addLine(to: CGPoint(x: x2,          y: cy))
arrow.addLine(to: CGPoint(x: x2 - headW, y: cy + headH/2))
arrow.addLine(to: CGPoint(x: x2 - headW, y: cy + shaftH/2))
arrow.addLine(to: CGPoint(x: x1,          y: cy + shaftH/2))
arrow.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8,
              color: CGColor(red: 0.38, green: 0.35, blue: 0.92, alpha: 0.30))
ctx.addPath(arrow)
ctx.clip()
let arrowGrad = CGGradient(colorsSpace: cs,
                           colors: [CGColor(red: 0.42, green: 0.37, blue: 0.94, alpha: 1),
                                    CGColor(red: 0.60, green: 0.40, blue: 0.98, alpha: 1)] as CFArray,
                           locations: [0, 1])!
ctx.drawLinearGradient(arrowGrad, start: CGPoint(x: x1, y: cy), end: CGPoint(x: x2, y: cy), options: [])
ctx.restoreGState()

// MARK: 텍스트 (제목 + 부제)
func drawText(_ s: String, size: CGFloat, weight: NSFont.Weight,
              color: NSColor, topY: CGFloat) {
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: para,
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let h = str.size().height
    str.draw(with: CGRect(x: 0, y: top(topY) - h, width: W, height: h),
             options: [.usesLineFragmentOrigin])
}

drawText("PlainPaste", size: 34, weight: .bold,
         color: NSColor(red: 0.16, green: 0.15, blue: 0.25, alpha: 1), topY: 44)
drawText("아이콘을 Applications 폴더로 드래그하세요", size: 15, weight: .regular,
         color: NSColor(red: 0.44, green: 0.43, blue: 0.55, alpha: 1), topY: 86)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG 인코딩 실패\n".data(using: .utf8)!)
    exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("배경 생성: \(outPath) (\(pxW)x\(pxH))")
