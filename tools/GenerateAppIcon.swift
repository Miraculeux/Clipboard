#!/usr/bin/env swift
// Renders ClipboardKit's app icon programmatically into all PNG sizes that
// AppIcon.appiconset/Contents.json expects. Run from the repo root:
//
//     swift tools/GenerateAppIcon.swift
//
// The visual is a rounded-rect background with a clipboard glyph, an inset
// crop / selection corner accent, and a photo-frame circle — to communicate
// both clipboard and screenshot capabilities at a glance.

import AppKit
import CoreGraphics

let outDir = "ClipboardKit/Assets.xcassets/AppIcon.appiconset"

/// Pixel sizes required by Contents.json (deduped).
let sizes: [(filename: String, side: Int)] = [
    ("AppIcon.png", 16),
    ("AppIcon-32.png", 32),
    ("AppIcon-64.png", 64),
    ("AppIcon-128.png", 128),
    ("AppIcon-256.png", 256),
    ("AppIcon-512.png", 512),
    ("AppIcon-1024.png", 1024)
]

func drawIcon(side: CGFloat) -> CGImage? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: Int(side),
        height: Int(side),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Background — vertical blue → purple gradient inside a rounded rect.
    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    let radius = side * 0.225 // matches macOS 26's squircle corner ratio
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    let top = CGColor(srgbRed: 0.35, green: 0.55, blue: 1.00, alpha: 1) // bright blue
    let bot = CGColor(srgbRed: 0.55, green: 0.30, blue: 0.95, alpha: 1) // purple
    let gradient = CGGradient(colorsSpace: space,
                              colors: [top, bot] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: side),
                           end: CGPoint(x: 0, y: 0),
                           options: [])
    ctx.restoreGState()

    // Clipboard body: rounded white plate centered, with a notch + clip.
    let plateInset = side * 0.18
    let plateRect = rect.insetBy(dx: plateInset, dy: plateInset * 1.05)
    let plateRadius = side * 0.07

    ctx.saveGState()
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.01),
                  blur: side * 0.015,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18))
    ctx.addPath(CGPath(roundedRect: plateRect,
                       cornerWidth: plateRadius,
                       cornerHeight: plateRadius,
                       transform: nil))
    ctx.fillPath()
    ctx.restoreGState()

    // Clipboard clip (the bar at the top of the plate).
    let clipWidth = plateRect.width * 0.45
    let clipHeight = plateRect.height * 0.10
    let clipRect = CGRect(
        x: plateRect.midX - clipWidth / 2,
        y: plateRect.maxY - clipHeight * 0.55,
        width: clipWidth,
        height: clipHeight
    )
    ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.35, blue: 0.55, alpha: 1))
    ctx.addPath(CGPath(roundedRect: clipRect,
                       cornerWidth: clipHeight * 0.45,
                       cornerHeight: clipHeight * 0.45,
                       transform: nil))
    ctx.fillPath()

    // Three "lines of text" on the plate.
    let lineHeight = plateRect.height * 0.055
    let lineCount = 3
    let lineSpacing = plateRect.height * 0.105
    let topLineY = plateRect.maxY - clipHeight * 1.7 - lineHeight
    for i in 0..<lineCount {
        let widthFactor: CGFloat = (i == lineCount - 1) ? 0.45 : 0.7
        let lineRect = CGRect(
            x: plateRect.midX - plateRect.width * widthFactor / 2,
            y: topLineY - CGFloat(i) * lineSpacing,
            width: plateRect.width * widthFactor,
            height: lineHeight
        )
        ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.62, blue: 0.78, alpha: 1))
        ctx.addPath(CGPath(roundedRect: lineRect,
                           cornerWidth: lineHeight * 0.4,
                           cornerHeight: lineHeight * 0.4,
                           transform: nil))
        ctx.fillPath()
    }

    // Screenshot accent — dashed selection rectangle overlapping bottom-right.
    let selSide = plateRect.width * 0.55
    let selRect = CGRect(
        x: plateRect.maxX - selSide * 0.7,
        y: plateRect.minY - selSide * 0.18,
        width: selSide,
        height: selSide * 0.82
    )

    ctx.saveGState()
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.95, blue: 0.35, alpha: 1))
    ctx.setLineWidth(side * 0.022)
    ctx.setLineDash(phase: 0, lengths: [side * 0.06, side * 0.03])
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    let selPath = CGPath(roundedRect: selRect,
                         cornerWidth: side * 0.025,
                         cornerHeight: side * 0.025,
                         transform: nil)
    ctx.addPath(selPath)
    ctx.strokePath()
    ctx.restoreGState()

    // Subtle highlight stroke on the outer squircle.
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
    ctx.setLineWidth(side * 0.012)
    ctx.strokePath()

    return ctx.makeImage()
}

func savePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                    "public.png" as CFString,
                                                    1, nil) else {
        throw NSError(domain: "GenerateAppIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Couldn't create PNG destination"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        throw NSError(domain: "GenerateAppIcon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Couldn't write PNG"])
    }
}

let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for (name, side) in sizes {
    guard let img = drawIcon(side: CGFloat(side)) else {
        FileHandle.standardError.write(Data("Failed to render \(name)\n".utf8))
        exit(1)
    }
    let path = "\(outDir)/\(name)"
    do {
        try savePNG(img, to: path)
        print("✓ \(path) (\(side)×\(side))")
    } catch {
        FileHandle.standardError.write(Data("✗ \(path): \(error)\n".utf8))
        exit(1)
    }
}
