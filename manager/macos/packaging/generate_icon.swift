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

guard CommandLine.arguments.count == 3 else {
    fputs("usage: generate_icon.swift SOURCE.png OUTPUT.icns\n", stderr)
    exit(64)
}

let sourceFile = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: false)
let outputFile = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: false)

guard let sourceImage = NSImage(contentsOf: sourceFile), sourceImage.isValid else {
    fputs("error: could not read source icon at \(sourceFile.path)\n", stderr)
    exit(1)
}

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

    // Preserve the supplied artwork while adapting it to the standard macOS
    // icon silhouette. The transparent outer gutter keeps the icon from
    // touching its Finder/Dock bounding box on pre-Tahoe systems.
    let artworkRect = canvas.insetBy(dx: size * 0.055, dy: size * 0.055)
    let artworkMask = NSBezierPath(
        roundedRect: artworkRect,
        xRadius: size * 0.225,
        yRadius: size * 0.225
    )
    artworkMask.addClip()
    sourceImage.draw(
        in: artworkRect,
        from: NSRect(origin: .zero, size: sourceImage.size),
        operation: .copy,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )

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
