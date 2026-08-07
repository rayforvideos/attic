import AppKit
let S: CGFloat = 1024
let small = CommandLine.arguments.contains("--small")

/// 애플 아이콘 모서리는 초타원이다. 지수 5.2는 시스템 아이콘(Notes) 실루엣을
/// 픽셀로 재서 맞춘 값이다(여백 100, 도형 824, 평균 오차 2px).
func squircle(_ r: CGRect, n: CGFloat = 5.2) -> CGPath {
    let p = CGMutablePath(); let a = r.width/2, b = r.height/2
    for i in 0...1440 {
        let t = CGFloat(i)/1440 * 2 * .pi, ct = cos(t), st = sin(t)
        let x = r.midX + a * pow(abs(ct), 2/n) * (ct < 0 ? -1 : 1)
        let y = r.midY + b * pow(abs(st), 2/n) * (st < 0 ? -1 : 1)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath(); return p
}
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex>>16)&0xff)/255, green: CGFloat((hex>>8)&0xff)/255,
            blue: CGFloat(hex&0xff)/255, alpha: a)
}

let bm = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bm)
let ctx = NSGraphicsContext.current!.cgContext
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

// 흑연 바탕. 채도를 낮추고 명도 폭을 좁히면 조용해진다 — 파란 그라디언트는
// 흔하고 시끄럽다.
ctx.saveGState(); ctx.addPath(squircle(body)); ctx.clip()
let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [c(0x3C434E), c(0x22272E), c(0x171B21)] as CFArray, locations: [0, 0.6, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: body.minX, y: body.maxY),
                       end: CGPoint(x: body.maxX, y: body.minY), options: [])
// 위쪽 미세한 빛 — 평면이 아니라 물체로 보이게 한다
let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [c(0xFFFFFF, 0.10), c(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY),
                       end: CGPoint(x: body.midX, y: body.midY), options: [])
ctx.restoreGState()

// 저장장치 — 납작한 층 3개. 물컵으로 보이지 않게 폭을 넓히고 높이를 낮춘다.
let scale: CGFloat = small ? 1.12 : 1.0
let cx = S/2, rx: CGFloat = 214 * scale, ry: CGFloat = 62 * scale
let gap: CGFloat = 96 * scale
// 작은 판(16·32px)에서는 빈 층의 테두리가 손잡이처럼 뭉개져 바구니로 보인다
// (실제로 확인했다) — 채운 층만 남기고 조금 키운다.
let levels = small ? [S/2 + gap/2, S/2 - gap/2] : [S/2 + gap, S/2, S/2 - gap]
func disk(_ cy: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx-rx, y: cy-ry, width: rx*2, height: ry*2), transform: nil)
}

// 아래에서 위로 그려 겹침이 자연스럽게 되도록 한다.
for (index, y) in levels.enumerated().reversed() {
    let sil = CGMutablePath()
    sil.addPath(disk(y))
    sil.addRect(CGRect(x: cx-rx, y: y, width: rx*2, height: gap * 0.62))
    sil.addPath(disk(y + gap * 0.62))

    // 아래 두 층은 아직 쓰는 용량 — 강조색. 맨 위 층은 비운 자리 — 테두리만.
    if index == 0 && !small {
        // 합집합 경로를 그대로 stroke하면 내부 이음선까지 그려져 바구니처럼
        // 엉킨다(직접 그려보고 알았다) — 실루엣만 따로 그린다.
        let h = gap * 0.62
        ctx.setStrokeColor(c(0xEDEFF3, 0.82)); ctx.setLineWidth(20)
        ctx.setLineCap(.round)
        // 위 테두리(타원 전체)
        ctx.addPath(disk(y + h)); ctx.strokePath()
        // 몸통 양옆 + 앞쪽 아래 곡선만
        let side = CGMutablePath()
        side.move(to: CGPoint(x: cx - rx, y: y + h))
        side.addLine(to: CGPoint(x: cx - rx, y: y))
        side.addCurve(to: CGPoint(x: cx + rx, y: y),
                      control1: CGPoint(x: cx - rx, y: y - ry * 1.34),
                      control2: CGPoint(x: cx + rx, y: y - ry * 1.34))
        side.addLine(to: CGPoint(x: cx + rx, y: y + h))
        ctx.addPath(side); ctx.strokePath()
    } else {
        ctx.saveGState()
        ctx.addPath(sil); ctx.clip()
        let fill = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [c(index == 1 ? 0x7FB2E5 : 0x5B8DC4), c(index == 1 ? 0x6497CE : 0x4A76A8)] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(fill, start: CGPoint(x: cx-rx, y: y + gap),
                               end: CGPoint(x: cx+rx, y: y - ry), options: [])
        ctx.restoreGState()
        // 층 사이 경계
        ctx.addPath(disk(y + gap * 0.62))
        ctx.setStrokeColor(c(0x171B21, 0.28)); ctx.setLineWidth(14); ctx.strokePath()
    }
}

NSGraphicsContext.restoreGraphicsState()
try! bm.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: small ? "attic_small.png" : "attic.png"))
print("ok")
