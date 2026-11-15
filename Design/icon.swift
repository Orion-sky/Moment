import AppKit

let out = CommandLine.arguments[1]
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
// macOS 图标网格:1024 画布里放 824 的圆角方块,圆角约 185
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
func squircle(_ r: CGRect = tile, radius: CGFloat = 185) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func gradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func render(_ name: String, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // 底下一层柔和的投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.28))
    ctx.addPath(squircle()); ctx.setFillColor(rgb(0x000000)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle()); ctx.clip()
    draw(ctx)
    // 顶部一点高光,让它有点玻璃感
    gradient(ctx, [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 560))
    ctx.restoreGState()
    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    return img
}

// A 取景框:暮色渐变 + 四角取景框 + 中间一个光点——"框住的那一刻"
let a = render("A") { ctx in
    gradient(ctx, [rgb(0x2A2468), rgb(0x7A3F9A), rgb(0xFF8F6B)], from: CGPoint(x: 760, y: 924), to: CGPoint(x: 300, y: 100))
    ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(46); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let inset: CGFloat = 185, len: CGFloat = 150
    let l = tile.minX + inset, r = tile.maxX - inset, b = tile.minY + inset, t = tile.maxY - inset
    for (x, y, dx, dy) in [(l, t, 1.0, -1.0), (r, t, -1.0, -1.0), (l, b, 1.0, 1.0), (r, b, -1.0, 1.0)] {
        ctx.move(to: CGPoint(x: x + CGFloat(dx) * len, y: y))
        ctx.addLine(to: CGPoint(x: x, y: y))
        ctx.addLine(to: CGPoint(x: x, y: y + CGFloat(dy) * len))
        ctx.strokePath()
    }
    ctx.setShadow(offset: .zero, blur: 60, color: rgb(0xFFE9C8, 0.9))
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: 512 - 74, y: 512 - 74, width: 148, height: 148))
}

// B 光圈:深色底 + 六片光圈叶片
let b = render("B") { ctx in
    gradient(ctx, [rgb(0x2B2D3A), rgb(0x14151B)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    let c = CGPoint(x: 512, y: 512), R: CGFloat = 300, r: CGFloat = 118
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)); ctx.clip()
    gradient(ctx, [rgb(0x5FE0C8), rgb(0x3A7BFF), rgb(0x7B4DFF)], from: CGPoint(x: 260, y: 800), to: CGPoint(x: 770, y: 220))
    ctx.setStrokeColor(rgb(0x14151B, 0.92)); ctx.setLineWidth(20); ctx.setLineCap(.round)
    for k in 0..<6 {
        let a0 = CGFloat(k) * .pi / 3 + .pi / 6
        let inner = CGPoint(x: c.x + r * cos(a0), y: c.y + r * sin(a0))
        let a1 = a0 + .pi * 0.62
        let outer = CGPoint(x: c.x + (R + 30) * cos(a1), y: c.y + (R + 30) * sin(a1))
        ctx.move(to: inner); ctx.addLine(to: outer); ctx.strokePath()
    }
    ctx.restoreGState()
    // 中间的六边形开口
    let hex = CGMutablePath()
    for k in 0..<6 {
        let a0 = CGFloat(k) * .pi / 3 + .pi / 6
        let p = CGPoint(x: c.x + r * cos(a0), y: c.y + r * sin(a0))
        k == 0 ? hex.move(to: p) : hex.addLine(to: p)
    }
    hex.closeSubpath()
    ctx.addPath(hex); ctx.setFillColor(rgb(0x14151B)); ctx.fillPath()
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.9)); ctx.setLineWidth(14)
    ctx.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
}

// C 山与日:两座山峰连成字母 M,太阳从中间的山谷升起——Moment 的 M,也是一张风景照
let c = render("C") { ctx in
    gradient(ctx, [rgb(0x3552E8), rgb(0x7DAEFF), rgb(0xFFD8B0)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 300))
    // 太阳:在 M 中间的山谷上方,被两座山峰夹着
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 90, color: rgb(0xFFF0BE, 1))
    ctx.setFillColor(rgb(0xFFF6DC)); ctx.fillEllipse(in: CGRect(x: 512 - 88, y: 560 - 88, width: 176, height: 176))
    ctx.restoreGState()
    func fill(_ pts: [CGPoint], _ colors: [CGColor], from: CGFloat, to: CGFloat) {
        let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath()
        ctx.saveGState(); ctx.addPath(p); ctx.clip()
        gradient(ctx, colors, from: CGPoint(x: 512, y: from), to: CGPoint(x: 512, y: to))
        ctx.restoreGState()
    }
    // 远山:矮一些、起伏多一些,越往下越淡,像隔着一层雾气
    fill([CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 360), CGPoint(x: 190, y: 420), CGPoint(x: 270, y: 370),
          CGPoint(x: 345, y: 440), CGPoint(x: 430, y: 380), CGPoint(x: 512, y: 410), CGPoint(x: 600, y: 370),
          CGPoint(x: 690, y: 450), CGPoint(x: 770, y: 390), CGPoint(x: 850, y: 430), CGPoint(x: 924, y: 380),
          CGPoint(x: 924, y: 100)],
         [rgb(0x7388EE), rgb(0xA9BBFF)], from: 450, to: 180)
    // 前面的 M:左峰、中间的谷、右峰
    let m = [CGPoint(x: 60, y: 100), CGPoint(x: 150, y: 100), CGPoint(x: 356, y: 650), CGPoint(x: 512, y: 372),
             CGPoint(x: 668, y: 650), CGPoint(x: 874, y: 100), CGPoint(x: 964, y: 100)]
    fill(m, [rgb(0xFFFFFF), rgb(0xD3DCFF)], from: 650, to: 100)
    // 两座山峰背光的一面略暗,有一点体积感
    fill([CGPoint(x: 356, y: 650), CGPoint(x: 512, y: 372), CGPoint(x: 512, y: 100), CGPoint(x: 318, y: 100)],
         [rgb(0x8FA3F2, 0.10), rgb(0x8FA3F2, 0.42)], from: 650, to: 100)
    fill([CGPoint(x: 668, y: 650), CGPoint(x: 874, y: 100), CGPoint(x: 630, y: 100)],
         [rgb(0x8FA3F2, 0.10), rgb(0x8FA3F2, 0.42)], from: 650, to: 100)
}

// 三个并排的预览图
let sheet = CGContext(data: nil, width: 3072, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sheet.setFillColor(rgb(0xE9E9EE)); sheet.fill(CGRect(x: 0, y: 0, width: 3072, height: 1024))
for (i, img) in [a, b, c].enumerated() { sheet.draw(img, in: CGRect(x: i * 1024, y: 0, width: 1024, height: 1024)) }
let rep = NSBitmapImageRep(cgImage: sheet.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/preview.png"))
