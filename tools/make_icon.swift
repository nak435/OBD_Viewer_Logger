// アプリアイコン(1024x1024, 不透明PNG)を生成するスクリプト。
// 使い方: swift tools/make_icon.swift <出力先.png>
// App Storeの仕様どおり、アルファチャンネル無し・角丸無し(角丸はiOSが付ける)で出力する。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("context")
}
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1) // 以降は左上原点

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// ── 背景：深い紺 → ほぼ黒（中央上に薄く光源）──
let bg = CGGradient(colorsSpace: cs,
                    colors: [rgb(0x1C2C52), rgb(0x0B1226), rgb(0x04060C)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawRadialGradient(bg, startCenter: CGPoint(x: 512, y: 430), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 430), endRadius: 820,
                       options: .drawsAfterEndLocation)

// ── ゲージの幾何 ──
let cx: CGFloat = 512, cy: CGFloat = 520
let radius: CGFloat = 330
let startDeg: CGFloat = 135   // 左下
let sweep: CGFloat = 270      // 時計回りに270度（下側が開いた形）
let activeFraction: CGFloat = 0.72

func pt(_ r: CGFloat, _ deg: CGFloat) -> CGPoint {
    let a = deg * .pi / 180
    return CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
}

// 回転計らしい色の並び（シアン → 緑 → 黄 → 橙 → 赤）。位置=ゲージ上の目盛り位置
let stops: [(CGFloat, UInt32)] = [(0, 0x22D3EE), (0.35, 0x4ADE80), (0.65, 0xFACC15), (0.85, 0xFB923C), (1, 0xF43F5E)]
func ramp(_ t: CGFloat) -> CGColor {
    let t = max(0, min(1, t))
    for i in 1..<stops.count where t <= stops[i].0 {
        let (t0, c0) = stops[i - 1], (t1, c1) = stops[i]
        let k = (t - t0) / (t1 - t0)
        func ch(_ s: Int) -> CGFloat {
            let a = CGFloat((c0 >> UInt32(s)) & 0xFF), b = CGFloat((c1 >> UInt32(s)) & 0xFF)
            return (a + (b - a) * k) / 255
        }
        return CGColor(srgbRed: ch(16), green: ch(8), blue: ch(0), alpha: 1)
    }
    return rgb(stops.last!.1)
}

ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// ── トラック（暗い下地リング）──
ctx.setLineWidth(70)
ctx.setStrokeColor(rgb(0x182036))
ctx.move(to: pt(radius, startDeg))
for d in stride(from: startDeg, through: startDeg + sweep, by: 1) { ctx.addLine(to: pt(radius, d)) }
ctx.strokePath()

// ── 目盛り（リングの内側）──
for k in 0...27 {
    let deg = startDeg + CGFloat(k) * 10
    let major = k % 3 == 0
    ctx.setLineWidth(major ? 9 : 5)
    ctx.setStrokeColor(rgb(0xFFFFFF, major ? 0.75 : 0.32))
    ctx.move(to: pt(major ? 250 : 262, deg))
    ctx.addLine(to: pt(285, deg))
    ctx.strokePath()
}

// ── 値のアーク（グラデーション＋発光）──
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 55, color: rgb(0x22D3EE, 0.55))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setLineWidth(70)
let activeSweep = sweep * activeFraction
var d: CGFloat = 0
while d < activeSweep {
    let d1 = min(d + 1.6, activeSweep) // 少し重ねて継ぎ目を消す
    ctx.setStrokeColor(ramp((d + d1) / 2 / sweep))
    ctx.move(to: pt(radius, startDeg + d))
    ctx.addLine(to: pt(radius, startDeg + d1))
    ctx.strokePath()
    d += 1
}
ctx.endTransparencyLayer()
ctx.restoreGState()

// ── 針 ──
let needleDeg = startDeg + activeSweep
let dir = CGPoint(x: cos(needleDeg * .pi / 180), y: sin(needleDeg * .pi / 180))
let perp = CGPoint(x: -dir.y, y: dir.x)
let tip = pt(272, needleDeg)
let tail = CGPoint(x: cx - dir.x * 56, y: cy - dir.y * 56)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 28, color: rgb(0xFB923C, 0.8))
ctx.setFillColor(rgb(0xF8FAFC))
ctx.move(to: tip)
ctx.addLine(to: CGPoint(x: cx + perp.x * 21, y: cy + perp.y * 21))
ctx.addLine(to: tail)
ctx.addLine(to: CGPoint(x: cx - perp.x * 21, y: cy - perp.y * 21))
ctx.closePath()
ctx.fillPath()
ctx.restoreGState()

// ── ハブ ──
ctx.setFillColor(rgb(0x0B1020))
ctx.fillEllipse(in: CGRect(x: cx - 50, y: cy - 50, width: 100, height: 100))
ctx.setStrokeColor(rgb(0xF8FAFC))
ctx.setLineWidth(9)
ctx.strokeEllipse(in: CGRect(x: cx - 50, y: cy - 50, width: 100, height: 100))
ctx.setFillColor(rgb(0x22D3EE))
ctx.fillEllipse(in: CGRect(x: cx - 15, y: cy - 15, width: 30, height: 30))

// ── ロギングの波形（ゲージ下側の開いた部分）──
let wave: [CGFloat] = [0, -8, 7, -28, 22, -12, -46, 18, -7, -25, 10, -3, 0]
let wx0: CGFloat = 356, wx1: CGFloat = 668, wy: CGFloat = 790
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 26, color: rgb(0x22D3EE, 0.9))
ctx.setStrokeColor(rgb(0x67E8F9))
ctx.setLineWidth(13)
for (i, off) in wave.enumerated() {
    let p = CGPoint(x: wx0 + (wx1 - wx0) * CGFloat(i) / CGFloat(wave.count - 1), y: wy + off)
    i == 0 ? ctx.move(to: p) : ctx.addLine(to: p)
}
ctx.strokePath()
ctx.restoreGState()

// ── 出力 ──
guard let image = ctx.makeImage() else { fatalError("image") }
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png")
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("dest")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write") }
print("wrote \(out.path) (\(image.width)x\(image.height), alpha=\(image.alphaInfo.rawValue))")
