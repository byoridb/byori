#!/usr/bin/env swift
import AppKit
import Foundation

struct IconVariant {
    let type: String
    let pixels: Int
}

let variants = [
    IconVariant(type: "icp4", pixels: 16),
    IconVariant(type: "ic11", pixels: 32),
    IconVariant(type: "icp5", pixels: 32),
    IconVariant(type: "ic12", pixels: 64),
    IconVariant(type: "icp6", pixels: 64),
    IconVariant(type: "ic07", pixels: 128),
    IconVariant(type: "ic13", pixels: 256),
    IconVariant(type: "ic08", pixels: 256),
    IconVariant(type: "ic14", pixels: 512),
    IconVariant(type: "ic09", pixels: 512),
    IconVariant(type: "ic10", pixels: 1_024),
]

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_icon.swift OUTPUT.icns\n", stderr)
    exit(64)
}

let outputFile = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: false)

do {
    try FileManager.default.createDirectory(
        at: outputFile.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
} catch {
    fputs("error: could not create icon output directory: \(error)\n", stderr)
    exit(1)
}

func drawIcon(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        return nil
    }

    let size = CGFloat(pixels)
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    NSColor.clear.setFill()
    canvas.fill()

    let inset = size * 0.055
    let backgroundRect = canvas.insetBy(dx: inset, dy: inset)
    let background = NSBezierPath(
        roundedRect: backgroundRect,
        xRadius: size * 0.225,
        yRadius: size * 0.225
    )
    let gradient = NSGradient(
        starting: NSColor(red: 0.12, green: 0.35, blue: 0.98, alpha: 1),
        ending: NSColor(red: 0.29, green: 0.08, blue: 0.68, alpha: 1)
    )
    gradient?.draw(in: background, angle: -55)

    let highlight = NSBezierPath(
        ovalIn: NSRect(
            x: size * 0.10,
            y: size * 0.50,
            width: size * 0.82,
            height: size * 0.52
        )
    )
    NSColor.white.withAlphaComponent(0.10).setFill()
    highlight.fill()

    let glyphRect = NSRect(
        x: size * 0.245,
        y: size * 0.255,
        width: size * 0.51,
        height: size * 0.49
    )
    let topHeight = size * 0.15
    let top = NSBezierPath(
        ovalIn: NSRect(
            x: glyphRect.minX,
            y: glyphRect.maxY - topHeight,
            width: glyphRect.width,
            height: topHeight
        )
    )

    let strokeWidth = max(1.2, size * 0.048)
    NSColor.white.withAlphaComponent(0.96).setStroke()
    top.lineWidth = strokeWidth
    top.stroke()

    let body = NSBezierPath()
    body.move(to: NSPoint(x: glyphRect.minX, y: glyphRect.maxY - topHeight / 2))
    body.line(to: NSPoint(x: glyphRect.minX, y: glyphRect.minY + topHeight / 2))
    body.curve(
        to: NSPoint(x: glyphRect.maxX, y: glyphRect.minY + topHeight / 2),
        controlPoint1: NSPoint(x: glyphRect.minX, y: glyphRect.minY - topHeight / 2),
        controlPoint2: NSPoint(x: glyphRect.maxX, y: glyphRect.minY - topHeight / 2)
    )
    body.line(to: NSPoint(x: glyphRect.maxX, y: glyphRect.maxY - topHeight / 2))
    body.lineWidth = strokeWidth
    body.lineCapStyle = .round
    body.stroke()

    for fraction in [0.38, 0.62] as [CGFloat] {
        let y = glyphRect.minY + glyphRect.height * fraction
        let layer = NSBezierPath()
        layer.move(to: NSPoint(x: glyphRect.minX, y: y + topHeight * 0.16))
        layer.curve(
            to: NSPoint(x: glyphRect.maxX, y: y + topHeight * 0.16),
            controlPoint1: NSPoint(x: glyphRect.minX + glyphRect.width * 0.22, y: y - topHeight * 0.30),
            controlPoint2: NSPoint(x: glyphRect.maxX - glyphRect.width * 0.22, y: y - topHeight * 0.30)
        )
        layer.lineWidth = strokeWidth * 0.72
        layer.lineCapStyle = .round
        layer.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { bytes in
        data.append(contentsOf: bytes)
    }
}

// ICNS is a small native container: an eight-byte file header followed by
// typed PNG chunks. Building it directly avoids external image dependencies.
var icon = Data("icns".utf8)
appendBigEndian(0, to: &icon)
var rendered: [Int: Data] = [:]

for variant in variants {
    let png: Data
    if let existing = rendered[variant.pixels] {
        png = existing
    } else if let image = drawIcon(pixels: variant.pixels) {
        png = image
        rendered[variant.pixels] = image
    } else {
        fputs("error: could not render \(variant.type)\n", stderr)
        exit(1)
    }

    guard let type = variant.type.data(using: .ascii), type.count == 4,
          png.count <= Int(UInt32.max) - 8 else {
        fputs("error: invalid ICNS chunk \(variant.type)\n", stderr)
        exit(1)
    }
    icon.append(type)
    appendBigEndian(UInt32(png.count + 8), to: &icon)
    icon.append(png)
}

guard icon.count <= Int(UInt32.max) else {
    fputs("error: generated ICNS is too large\n", stderr)
    exit(1)
}
var totalLength = UInt32(icon.count).bigEndian
withUnsafeBytes(of: &totalLength) { bytes in
    icon.replaceSubrange(4..<8, with: bytes)
}

do {
    try icon.write(to: outputFile, options: .atomic)
} catch {
    fputs("error: could not write ICNS: \(error)\n", stderr)
    exit(1)
}
