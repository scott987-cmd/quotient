#!/usr/bin/env swift
//
// 生成 LLMQuotaBar 的 app 图标。
//
// 纯 CoreGraphics，不引第三方 —— 和这个项目其余部分同一条规矩。
// 跑法：swift Tools/make-icon.swift <输出目录>
// 然后 iconutil -c icns <输出目录>/LLMQuotaBar.iconset
//
// # 设计说明
//
// 画的不是仪表盘。这个工具的问题是「你有多少额度没用掉」，
// 所以主角是**空的那一截**：实心柱子是已用，上面那截半透明轮廓是
// 还没用、且到期就作废的部分。三根柱子 = 多个平台并排看。
//
// 配色刻意避开紫蓝渐变（那是所有 AI 工具的默认长相）：
// 深青灰底 + 琥珀。琥珀在这个 App 里本来就是「要浪费了」的语义色，
// 图标和界面用同一套语言。

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 形状

/// macOS 的圆角不是圆弧，是超椭圆。用圆角矩形凑出来的图标放大看会「肩膀太方」。
func squirclePath(in rect: CGRect, n: CGFloat = 5.0, steps: Int = 720) -> CGPath {
    let p = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        // |x/a|^n + |y/b|^n = 1 的参数form
        let x = cx + a * CGFloat(sign(ct)) * pow(abs(ct), 2 / n)
        let y = cy + b * CGFloat(sign(st)) * pow(abs(st), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

func sign(_ v: CGFloat) -> CGFloat { v < 0 ? -1 : 1 }

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// MARK: - 绘制

func drawIcon(size S: CGFloat) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // **小尺寸画简化版。**
    //
    // 16px 上，「没用掉那一截」的淡填充 + 描边会和实心部分糊成一块，
    // 整个图标读作「一个带缺口的方块」，三根柱子的信息全丢了。
    // 实测过才发现 —— 只看 512 的话完全不会察觉。
    // 所以 32 及以下只留实心柱子：高度差本身就够说明问题。
    let tiny = S <= 32

    // macOS 图标不铺满画布：内容占约 824/1024，四周留气口。
    // 小尺寸留白要收窄，否则本来就没几个像素还被边距吃掉。
    let inset = S * (tiny ? 0.055 : 0.098)
    let tile = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let shape = squirclePath(in: tile)

    // 底：深青灰，从上到下略微变深。不是纯黑 —— 纯黑在浅色 Dock 上会糊成一块。
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    if let g = CGGradient(colorsSpace: cs,
                          colors: [rgb(0x16323B), rgb(0x0B1A20)] as CFArray,
                          locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: tile.maxY),
                               end: CGPoint(x: 0, y: tile.minY), options: [])
    }

    // 顶部一道很淡的高光，给这块面一点体积感，别做成纯平色块。
    if let g = CGGradient(colorsSpace: cs,
                          colors: [rgb(0x5FD3C4, 0.16), rgb(0x5FD3C4, 0.0)] as CFArray,
                          locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: tile.maxY),
                               end: CGPoint(x: 0, y: tile.midY), options: [])
    }

    // MARK: 三根柱子
    //
    // 高度 = 该平台的额度上限（都一样高，因为「一整个周期」对每家都是满的）。
    // 实心 = 已用；上面那截淡的 = 没用掉、到期作废。
    // 故意让三根的已用比例差别很大 —— 一眼就能看出「有的在漏」。
    let used: [CGFloat] = [0.72, 0.34, 0.55]

    let barW = tile.width * (tiny ? 0.20 : 0.138)
    let gap = tile.width * (tiny ? 0.12 : 0.090)
    let totalW = barW * 3 + gap * 2
    let x0 = tile.midX - totalW / 2
    let barBottom = tile.minY + tile.height * 0.175
    let barTop = tile.maxY - tile.height * 0.175
    let barH = barTop - barBottom
    let r = barW / 2

    for (i, u) in used.enumerated() {
        let x = x0 + CGFloat(i) * (barW + gap)

        // 没用掉的那一截：极淡的填充 + 一圈描边。
        // 这一截才是这个图标想说的事，所以它必须**看得见**，
        // 不能淡到只剩个影子。
        let ghost = CGRect(x: x, y: barBottom, width: barW, height: barH)
        let ghostPath = CGPath(roundedRect: ghost, cornerWidth: r, cornerHeight: r,
                               transform: nil)
        if !tiny {
            ctx.addPath(ghostPath)
            ctx.setFillColor(rgb(0xF5A623, 0.10))
            ctx.fillPath()
            ctx.addPath(ghostPath)
            ctx.setStrokeColor(rgb(0xF5A623, 0.42))
            ctx.setLineWidth(max(1, S * 0.0075))
            ctx.strokePath()
        }

        // 已用：实心琥珀，底部略深、顶部略亮。
        //
        // **填充画成平顶的矩形，再用容器的圆角去裁。**
        // 第一版把填充也画成全圆角，结果三根柱子看着像悬浮的胶囊 ——
        // 读出来是调音台推子，不是「装到这个高度」。
        // 底部圆角由容器给，顶部保持平的，液面感才对。
        let h = barH * u
        let fill = CGRect(x: x, y: barBottom, width: barW, height: h)
        ctx.saveGState()
        if tiny {
            // 没有容器可裁，柱子自己就是全形，两端都要圆。
            ctx.addPath(CGPath(roundedRect: fill, cornerWidth: min(r, h / 2),
                               cornerHeight: min(r, h / 2), transform: nil))
            ctx.clip()
        } else {
            ctx.addPath(ghostPath)      // 用容器裁，不是用填充自己的形状
            ctx.clip()
            ctx.addRect(fill)
            ctx.clip()
        }
        if let g = CGGradient(colorsSpace: cs,
                              colors: [rgb(0xFFCC5C), rgb(0xE8912A)] as CFArray,
                              locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: barBottom + h),
                                   end: CGPoint(x: 0, y: barBottom), options: [])
        }
        ctx.restoreGState()
    }

    ctx.restoreGState()

    // 边缘一圈内描边，让图标在深色 Dock 上也有轮廓。
    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
    ctx.setLineWidth(max(1, S * 0.004))
    ctx.strokePath()

    return ctx.makeImage()
}

// MARK: - 落盘

let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let setDir = URL(fileURLWithPath: out).appendingPathComponent("LLMQuotaBar.iconset")
try? FileManager.default.createDirectory(at: setDir, withIntermediateDirectories: true)

// .icns 要的全套尺寸。
let specs: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

for (px, name) in specs {
    guard let img = drawIcon(size: CGFloat(px)) else {
        FileHandle.standardError.write(Data("画不出 \(px)\n".utf8)); exit(1)
    }
    let url = setDir.appendingPathComponent("\(name).png")
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}
print(setDir.path)
