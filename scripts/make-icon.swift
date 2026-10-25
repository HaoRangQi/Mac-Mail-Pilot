// 生成 MailPilot 应用图标（邮件 + AI 双元素 · 方案 D）
//
// 用法： swift scripts/make-icon.swift build/icon.iconset
// 产物： 各尺寸 PNG，交给 iconutil 打包成 .icns
//
// 设计要点
// - 苔绿底 #46734F 是品牌唯一识别资产（macOS 邮件类 App 全是蓝色）
// - 信封 = 邮件，四角星芒 = AI，星芒压在信封右上角并把它"咬"出缺口，两元素同级咬合
// - 缺口靠"重绘背景"实现：clip 到放大的星芒路径后重画一遍底色渐变，
//   这样缺口与底色严丝合缝，不依赖任何固定颜色去猜背景
// - 小尺寸换一套参数（填色封盖 / 更粗线 / 更大星芒 / 去掉小星芒），不是简单缩小

import AppKit
import CoreGraphics

// MARK: - 调色板（与 Theme.swift 同源）

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

let mossTop = rgb(0x4E7C57)
let mossBottom = rgb(0x3E6746)
let paper = rgb(0xF4F1E4)
let paperShade = rgb(0xDDD7BD)
let fold = rgb(0x3E6549)
let goldTop = rgb(0xF3DEB2)
let goldBottom = rgb(0xDCBC82)

// MARK: - 几何（全部在 1024 画布坐标系里定义，左上角为原点）

let canvas: CGFloat = 1024
let squircle = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircleRadius: CGFloat = 185.4

let envelope = CGRect(x: 190, y: 520, width: 468, height: 300)
let envelopeRadius: CGFloat = 38
let flapLeft = CGPoint(x: 224, y: 534)
let flapBottom = CGPoint(x: 424, y: 682)
let flapRight = CGPoint(x: 624, y: 534)

let sparkRadius: CGFloat = 180
/// 星芒尖端被信封遮住的深度。
/// 层叠关系是「星在后、信在前」：信封轮廓始终完整，
/// 星芒的尖只是插进纸背后消失——不切缺口、不留缝，
/// 缩小到 16px 也不会出现毛刺或断裂感。
let sparkTuckBehindPaper: CGFloat = 54
let sparkCenter = CGPoint(x: 648, y: envelope.minY - sparkRadius + sparkTuckBehindPaper)

/// 四角星芒：四条内凹的贝塞尔边，尖端在正上 / 右 / 下 / 左
func sparklePath(center: CGPoint, radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let c1: CGFloat = 0.10   // 沿轴向的控制点
    let c2: CGFloat = 0.30   // 垂直方向的控制点
    path.move(to: CGPoint(x: 0, y: -r))
    path.addCurve(to: CGPoint(x: r, y: 0),
                  control1: CGPoint(x: r * c1, y: -r * c2),
                  control2: CGPoint(x: r * c2, y: -r * c1))
    path.addCurve(to: CGPoint(x: 0, y: r),
                  control1: CGPoint(x: r * c2, y: r * c1),
                  control2: CGPoint(x: r * c1, y: r * c2))
    path.addCurve(to: CGPoint(x: -r, y: 0),
                  control1: CGPoint(x: -r * c1, y: r * c2),
                  control2: CGPoint(x: -r * c2, y: r * c1))
    path.addCurve(to: CGPoint(x: 0, y: -r),
                  control1: CGPoint(x: -r * c2, y: -r * c1),
                  control2: CGPoint(x: -r * c1, y: -r * c2))
    path.closeSubpath()
    var transform = CGAffineTransform(translationX: center.x, y: center.y)
    return path.copy(using: &transform) ?? path
}

// MARK: - 绘制

func drawBackground(_ ctx: CGContext, sheen: Bool, inset: CGFloat) {
    let side = canvas - inset * 2
    let box = CGRect(x: inset, y: inset, width: side, height: side)
    let radius = side * 0.225
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: box,
                       cornerWidth: radius,
                       cornerHeight: radius,
                       transform: nil))
    ctx.clip()

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    if let gradient = CGGradient(colorsSpace: space,
                                 colors: [mossTop, mossBottom] as CFArray,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 512, y: inset),
                               end: CGPoint(x: 512, y: canvas - inset),
                               options: [])
    }

    // 顶部一层极淡的高光，呼应界面里的液态玻璃；小尺寸关掉，避免灰蒙蒙
    if sheen, let highlight = CGGradient(colorsSpace: space,
                                         colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray,
                                         locations: [0, 1]) {
        ctx.drawLinearGradient(highlight,
                               start: CGPoint(x: 512, y: inset),
                               end: CGPoint(x: 512, y: inset + 360),
                               options: [])
    }
    ctx.restoreGState()
}

func renderIcon(size: Int) -> Data? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil,
                              width: size,
                              height: size,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }

    // 1024 设计坐标 → 实际像素；翻转 y 轴让"上"就是上
    let scale = CGFloat(size) / canvas
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    ctx.scaleBy(x: scale, y: scale)

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // 尺寸分档：不是等比缩放，小尺寸单独调参
    let isMid = size >= 128 && size < 256
    let sheen = size >= 128
    let flapStroke: CGFloat = size <= 64 ? 34 : (isMid ? 22 : 17)
    let fillFlap = size <= 64

    // 小尺寸做光学补偿：圆角方占比加大、星芒放大，否则 16px 下星芒只剩一个模糊的点
    let inset: CGFloat = size <= 32 ? 70 : (size <= 64 ? 88 : 100)
    let starGain: CGFloat = size <= 32 ? 1.30 : (size <= 64 ? 1.12 : 1)
    let tuckGain: CGFloat = size <= 32 ? 74 : (size <= 64 ? 64 : sparkTuckBehindPaper)

    let starR = sparkRadius * starGain
    let starCenter = CGPoint(x: sparkCenter.x, y: envelope.minY - starR + tuckGain)

    // 1. 底
    drawBackground(ctx, sheen: sheen, inset: inset)

    // 2. 星芒（先画，会被信封压住一截）
    let mainSpark = sparklePath(center: starCenter, radius: starR)
    ctx.saveGState()
    ctx.addPath(mainSpark)
    ctx.clip()
    if let gradient = CGGradient(colorsSpace: space,
                                 colors: [goldTop, goldBottom] as CFArray,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: starCenter.x, y: starCenter.y - starR),
                               end: CGPoint(x: starCenter.x, y: starCenter.y + starR),
                               options: [])
    }
    ctx.restoreGState()

    // 3. 信封（压住星芒尖端）
    ctx.setFillColor(paper)
    ctx.addPath(CGPath(roundedRect: envelope,
                       cornerWidth: envelopeRadius,
                       cornerHeight: envelopeRadius,
                       transform: nil))
    ctx.fillPath()

    // 4. 封盖折线
    if fillFlap {
        // 小尺寸把封盖做成一块实色梯形，靠明度差认出"这是信封"
        ctx.setFillColor(paperShade)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: envelope.minX, y: envelope.minY))
        ctx.addLine(to: CGPoint(x: flapBottom.x, y: flapBottom.y))
        ctx.addLine(to: CGPoint(x: envelope.maxX, y: envelope.minY))
        ctx.closePath()
        ctx.fillPath()
    } else {
        ctx.setStrokeColor(fold)
        ctx.setLineWidth(flapStroke)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: flapLeft)
        ctx.addLine(to: flapBottom)
        ctx.addLine(to: flapRight)
        ctx.strokePath()
    }

    // 5. 不做副星芒：两个大元素已经够了，第三颗小星在小尺寸只会变成脏点

    guard let image = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

// MARK: - 主流程

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// iconset 需要的 10 个文件（7 个独立尺寸，其中 32/256/512 各出现两次）
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

var cache: [Int: Data] = [:]
for (name, size) in entries {
    let data: Data
    if let cached = cache[size] {
        data = cached
    } else {
        guard let fresh = renderIcon(size: size) else {
            FileHandle.standardError.write("渲染失败：\(size)px\n".data(using: .utf8)!)
            exit(1)
        }
        cache[size] = fresh
        data = fresh
    }
    let path = "\(outDir)/\(name)"
    try data.write(to: URL(fileURLWithPath: path))
    print("  \(name)  \(size)px")
}

print("==> \(outDir)")
