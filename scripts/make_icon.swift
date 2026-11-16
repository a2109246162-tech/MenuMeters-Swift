//  生成 MenuMeters 应用图标：深色圆角底板 + 青/紫/绿三色柱状条
//  用法：swift make_icon.swift   （随后用 iconutil 把 iconset 转为 icns）

import AppKit

// 基于源码文件所在位置推导 output 目录（scripts/ 的上一级即项目根目录）
let scriptDir = (NSString(string: #filePath).deletingLastPathComponent as NSString)
let outputDir = scriptDir + "/../output"
let iconSetPath = outputDir + "/MenuMeters.iconset"

// 三色与菜单栏指标一一对应：CPU 青、GPU 紫、内存 绿
let barColors: [NSColor] = [
    NSColor(red: 0.25, green: 0.72, blue: 0.95, alpha: 1.0),
    NSColor(red: 0.62, green: 0.45, blue: 0.96, alpha: 1.0),
    NSColor(red: 0.30, green: 0.84, blue: 0.56, alpha: 1.0)
]
let barRatios: [CGFloat] = [0.55, 0.38, 0.46]

func makeImage(pixels size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let s = CGFloat(size)
    let canvas = NSRect(x: 0, y: 0, width: s, height: s)

    // 底板：深色渐变圆角矩形
    let backgroundRect = canvas.insetBy(dx: s * 0.05, dy: s * 0.05)
    let backgroundPath = NSBezierPath(
        roundedRect: backgroundRect,
        xRadius: s * 0.23,
        yRadius: s * 0.23
    )
    let gradient = NSGradient(
        starting: NSColor(red: 0.15, green: 0.20, blue: 0.30, alpha: 1.0),
        ending:   NSColor(red: 0.06, green: 0.08, blue: 0.14, alpha: 1.0)
    )!
    gradient.draw(in: backgroundPath, angle: 270)

    // 柱状条：等宽、圆角、不同高度
    let barWidth = s * 0.14
    let gap = s * 0.085
    let totalWidth = barWidth * 3 + gap * 2
    let startX = (s - totalWidth) / 2
    let baseY = s * 0.29
    let maxHeight = s * 0.44

    for i in 0..<3 {
        let x = startX + CGFloat(i) * (barWidth + gap)
        let height = maxHeight * barRatios[i]
        let barRect = NSRect(x: x, y: baseY, width: barWidth, height: height)
        let barPath = NSBezierPath(
            roundedRect: barRect,
            xRadius: barWidth * 0.4,
            yRadius: barWidth * 0.4
        )
        barColors[i].setFill()
        barPath.fill()
    }

    image.unlockFocus()
    return image
}

// 生成 iconset 所需的 10 个尺寸（含 @2x）
let variants: [(base: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)
]

try? FileManager.default.createDirectory(atPath: iconSetPath, withIntermediateDirectories: true)

for variant in variants {
    let pixels = variant.base * variant.scale
    let image = makeImage(pixels: pixels)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { continue }
    let name = variant.scale == 1
        ? "icon_\(variant.base)x\(variant.base).png"
        : "icon_\(variant.base)x\(variant.base)@2x.png"
    try? png.write(to: URL(fileURLWithPath: iconSetPath + "/" + name))
}

print("ICONESET_READY: \(iconSetPath)")
