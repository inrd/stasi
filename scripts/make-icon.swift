#!/usr/bin/env swift
//
//  make-icon.swift
//  Draws Resources/AppIcon.icns: a rounded tile with a simple ear outline.
//
//  Usage:  swift scripts/make-icon.swift [output-directory]
//
//  Vector, not a bitmap, so proportions can be tuned without redrawing.
//

import AppKit
import Foundation

// MARK: - Design

/// The ear is drawn in a 24×24 design space (y down), in the spirit of a line
/// icon: a dome, a back curve, a lobe curl, and an inner hook.
enum Design {
    static let canvas: CGFloat = 1024
    static let tileInset: CGFloat = 64
    static let tileRadius: CGFloat = 200

    /// How many canvas points one design unit occupies.
    static let scale: CGFloat = 34

    /// Stroke width in canvas points.
    static let stroke: CGFloat = 52

    static let backgroundTop = NSColor(srgbRed: 0.180, green: 0.180, blue: 0.196, alpha: 1)
    static let backgroundBottom = NSColor(srgbRed: 0.102, green: 0.102, blue: 0.114, alpha: 1)
    static let ink = NSColor(srgbRed: 0.960, green: 0.960, blue: 0.972, alpha: 1)
}

// MARK: - Geometry

/// Returns the ear path in canvas coordinates (y up).
///
/// Points come from design space with `y' = 24 - y`, so the path can be built
/// with Core Graphics' native orientation.
func earPath() -> CGPath {
    let path = CGMutablePath()

    // Helix: a tall C, open toward the front of the head (the left).
    path.move(to: CGPoint(x: 9.5, y: 6.0))
    path.addCurve(
        to: CGPoint(x: 18.2, y: 7.6),
        control1: CGPoint(x: 12.0, y: 3.2),
        control2: CGPoint(x: 16.5, y: 3.6)
    )
    path.addCurve(
        to: CGPoint(x: 18.0, y: 16.2),
        control1: CGPoint(x: 19.4, y: 10.6),
        control2: CGPoint(x: 19.4, y: 13.2)
    )
    path.addCurve(
        to: CGPoint(x: 10.6, y: 20.0),
        control1: CGPoint(x: 16.4, y: 19.6),
        control2: CGPoint(x: 13.2, y: 21.2)
    )
    path.addCurve(
        to: CGPoint(x: 8.4, y: 15.0),
        control1: CGPoint(x: 8.6, y: 19.0),
        control2: CGPoint(x: 8.2, y: 16.8)
    )

    // Concha: detached, sitting inside the lower half, left open.
    path.move(to: CGPoint(x: 10.9, y: 12.2))
    path.addCurve(
        to: CGPoint(x: 14.5, y: 10.3),
        control1: CGPoint(x: 11.0, y: 9.8),
        control2: CGPoint(x: 13.0, y: 8.9)
    )
    path.addCurve(
        to: CGPoint(x: 14.0, y: 14.7),
        control1: CGPoint(x: 15.7, y: 11.6),
        control2: CGPoint(x: 15.4, y: 13.7)
    )
    path.addCurve(
        to: CGPoint(x: 11.0, y: 14.3),
        control1: CGPoint(x: 12.9, y: 15.4),
        control2: CGPoint(x: 11.6, y: 15.2)
    )

    // Place the design on the canvas: centre the ear's bounding box.
    var transform = CGAffineTransform(translationX: Design.canvas / 2, y: Design.canvas / 2)
    transform = transform.scaledBy(x: Design.scale, y: Design.scale)
    transform = transform.translatedBy(x: -13.8, y: -12.2)

    return path.copy(using: &transform) ?? path
}

// MARK: - Rendering

func render(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(
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
    )!

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext

    let scale = size / Design.canvas
    cg.scaleBy(x: scale, y: scale)

    // Background tile.
    let tileRect = CGRect(
        x: Design.tileInset,
        y: Design.tileInset,
        width: Design.canvas - Design.tileInset * 2,
        height: Design.canvas - Design.tileInset * 2
    )
    let tile = CGPath(
        roundedRect: tileRect,
        cornerWidth: Design.tileRadius,
        cornerHeight: Design.tileRadius,
        transform: nil
    )

    cg.saveGState()
    cg.addPath(tile)
    cg.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [Design.backgroundTop.cgColor, Design.backgroundBottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
    cg.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: Design.canvas),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    cg.restoreGState()

    // A hairline keeps the tile from melting into a light background.
    cg.addPath(tile)
    cg.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor)
    cg.setLineWidth(2)
    cg.strokePath()

    // Ear.
    cg.addPath(earPath())
    cg.setStrokeColor(Design.ink.cgColor)
    cg.setLineWidth(Design.stroke)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func pngData(_ rep: NSBitmapImageRep) -> Data {
    rep.representation(using: .png, properties: [:])!
}

// MARK: - Output

let arguments = Array(CommandLine.arguments.dropFirst())
let wantsPreview = arguments.contains("--preview")
let outputDirectory = URL(fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") }) ?? "Resources")

let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Sizes expected by iconutil; each is rendered natively, not upscaled.
let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

for variant in variants {
    let data = pngData(render(size: variant.pixels))
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

// A 1024 PNG is handy for inspection; not committed.
if wantsPreview {
    try pngData(render(size: 1024))
        .write(to: outputDirectory.appendingPathComponent("AppIcon-1024.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c", "icns",
    iconset.path,
    "-o", outputDirectory.appendingPathComponent("AppIcon.icns").path,
]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

try? FileManager.default.removeItem(at: iconset)
print("wrote \(outputDirectory.appendingPathComponent("AppIcon.icns").path)")
