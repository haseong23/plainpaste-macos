import AppKit

// DMG 창 배경 생성기 — 의존성 없이 Core Graphics로 직접 그림
// usage: makedmgbg <out.png> [scale]
//   window content = 620 x 470 pt
//   구성: 라벤더 그라디언트 · 드래그 화살표(①) · 하단 첫-실행 안내 카드(②)

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "bg.png"
let scale   = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2]) ?? 1) : 1

let W: CGFloat = 620, H: CGFloat = 470
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

// MARK: 텍스트 헬퍼
func attrs(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor,
           _ align: NSTextAlignment = .center) -> [NSAttributedString.Key: Any] {
    let para = NSMutableParagraphStyle(); para.alignment = align
    return [.font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: para]
}

// 가로 전체(W)에 가운데 정렬로 한 줄 그리기 (topY = 위에서부터의 거리)
func drawCentered(_ s: String, size: CGFloat, weight: NSFont.Weight,
                  color: NSColor, topY: CGFloat) {
    let str = NSAttributedString(string: s, attributes: attrs(size, weight, color))
    let h = str.size().height
    str.draw(with: CGRect(x: 0, y: top(topY) - h, width: W, height: h),
             options: [.usesLineFragmentOrigin])
}

// 둥근 사각형 경로
func roundedRect(_ r: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: 상단 — 제목 + 1단계
drawCentered("PlainPaste", size: 34, weight: .bold,
             color: NSColor(red: 0.16, green: 0.15, blue: 0.25, alpha: 1), topY: 40)
drawCentered("①  아이콘을 Applications 폴더로 드래그", size: 15, weight: .medium,
             color: NSColor(red: 0.40, green: 0.38, blue: 0.52, alpha: 1), topY: 82)

// MARK: 하단 — 2단계 안내 카드 (첫 실행 시 Gatekeeper 허용)
// 카드: top 300 ~ 448 영역 (아이콘 라벨 아래 여백에 배치)
let cardTop: CGFloat = 300, cardBottom: CGFloat = 448
let cardRect = CGRect(x: 46, y: top(cardBottom), width: W - 92, height: cardBottom - cardTop)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 6,
              color: CGColor(red: 0.30, green: 0.28, blue: 0.55, alpha: 0.12))
ctx.addPath(roundedRect(cardRect, radius: 16))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.72))
ctx.fillPath()
ctx.restoreGState()
ctx.addPath(roundedRect(cardRect.insetBy(dx: 0.5, dy: 0.5), radius: 16))
ctx.setStrokeColor(CGColor(red: 0.55, green: 0.52, blue: 0.80, alpha: 0.30))
ctx.setLineWidth(1)
ctx.strokePath()

drawCentered("②  처음 열 때 “확인되지 않은 개발자” 경고가 뜨면",
             size: 14, weight: .semibold,
             color: NSColor(red: 0.20, green: 0.18, blue: 0.30, alpha: 1), topY: 322)
drawCentered("시스템 설정 › 개인정보 보호 및 보안 › 맨 아래에서",
             size: 13, weight: .regular,
             color: NSColor(red: 0.42, green: 0.41, blue: 0.53, alpha: 1), topY: 350)

// "그래도 열기" 버튼 모형(pill) — 실제로 눌러야 할 버튼을 그대로 보여줌
let pillLabel = NSAttributedString(string: "그래도 열기",
                                   attributes: attrs(13, .semibold, .white))
let pillTextW = pillLabel.size().width
let pillW = pillTextW + 34, pillH: CGFloat = 26
let pillRect = CGRect(x: (W - pillW)/2, y: top(408), width: pillW, height: pillH)
ctx.saveGState()
ctx.addPath(roundedRect(pillRect, radius: pillH/2))
ctx.clip()
ctx.drawLinearGradient(arrowGrad,
                       start: CGPoint(x: pillRect.minX, y: pillRect.midY),
                       end: CGPoint(x: pillRect.maxX, y: pillRect.midY), options: [])
ctx.restoreGState()
pillLabel.draw(with: CGRect(x: pillRect.minX,
                            y: pillRect.midY - pillLabel.size().height/2,
                            width: pillW, height: pillLabel.size().height),
               options: [.usesLineFragmentOrigin])

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG 인코딩 실패\n".data(using: .utf8)!)
    exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("배경 생성: \(outPath) (\(pxW)x\(pxH))")
