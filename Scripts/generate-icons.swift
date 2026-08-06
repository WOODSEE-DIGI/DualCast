#!/usr/bin/env swift
//
//  generate-icons.swift
//  DualCast icon generator — draws both app icons programmatically.
//
//  Usage:  swift Scripts/generate-icons.swift
//  Output: Resources/AppIcons/icon-dualcast-1024.png
//          Resources/AppIcons/icon-switcher-1024.png
//
//  Design: macOS Big Sur+ squircle (824pt content area on a 1024 canvas),
//  two overlapping display screens (the "dual" cast), magenta broadcast
//  waves for the sender, orange swap badge for the switcher.
//  Palette matches the SwiftMaestro theme accents.
//

import AppKit

// MARK: - Palette

private let bgTop    = NSColor(calibratedRed: 0.145, green: 0.125, blue: 0.286, alpha: 1) // deep indigo
private let bgBottom = NSColor(calibratedRed: 0.055, green: 0.047, blue: 0.118, alpha: 1) // near-black indigo
private let screenBg = NSColor(calibratedRed: 0.035, green: 0.043, blue: 0.082, alpha: 1)
private let screenEdge = NSColor.white.withAlphaComponent(0.85)
private let codeLine = NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.75, alpha: 0.9)
private let magenta  = NSColor(calibratedRed: 1.0, green: 0.0, blue: 0.824, alpha: 1)     // FF00D2
private let orange   = NSColor(calibratedRed: 1.0, green: 0.447, blue: 0.255, alpha: 1)   // FF7241

// MARK: - Geometry helpers

/// Continuous-corner squircle path (Apple-style superellipse approximation).
private func squirclePath(in rect: CGRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.height * 0.2237)
}

private func drawBackground(in canvas: CGRect, context: CGContext) {
    let iconRect = canvas.insetBy(dx: canvas.width * 0.0976, dy: canvas.width * 0.0976)
    let path = squirclePath(in: iconRect)
    path.addClip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [bgTop.cgColor, bgBottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: iconRect.midX, y: iconRect.maxY),
        end: CGPoint(x: iconRect.midX, y: iconRect.minY),
        options: []
    )

    // Subtle top-edge sheen band
    bgTop.withAlphaComponent(0).setFill()
    let sheenRect = CGRect(x: iconRect.minX, y: iconRect.midY,
                           width: iconRect.width, height: iconRect.height / 2)
    NSColor.white.withAlphaComponent(0.10).setFill()
    NSBezierPath(rect: sheenRect).fill()
}

/// Draws one display screen with stand. `rect` is the screen bezel area.
private func drawDisplay(in rect: CGRect, codeLines: Bool) {
    // Screen
    let screenPath = NSBezierPath(roundedRect: rect, xRadius: rect.height * 0.10, yRadius: rect.height * 0.10)
    screenEdge.withAlphaComponent(0.9).setFill()
    screenPath.fill()

    let inset = rect.insetBy(dx: rect.width * 0.035, dy: rect.height * 0.06)
    let innerPath = NSBezierPath(roundedRect: inset, xRadius: rect.height * 0.06, yRadius: rect.height * 0.06)
    screenBg.setFill()
    innerPath.fill()

    // Code lines
    if codeLines {
        codeLine.setFill()
        let lineCount = 4
        let lineHeight = inset.height * 0.09
        var y = inset.maxY - inset.height * 0.18 - lineHeight
        let widths: [CGFloat] = [0.62, 0.44, 0.70, 0.36]
        for i in 0..<lineCount {
            let w = inset.width * widths[i % widths.count]
            let indent: CGFloat = (i % 2 == 1) ? inset.width * 0.12 : 0
            let line = NSBezierPath(
                roundedRect: CGRect(x: inset.minX + inset.width * 0.08 + indent, y: y,
                                    width: w, height: lineHeight),
                xRadius: lineHeight / 2, yRadius: lineHeight / 2
            )
            line.fill()
            y -= lineHeight * 2.0
        }
    }

    // Stand: neck + base
    let neckWidth = rect.width * 0.10
    let neckHeight = rect.height * 0.22
    let neck = NSBezierPath(rect: CGRect(
        x: rect.midX - neckWidth / 2,
        y: rect.minY - neckHeight,
        width: neckWidth, height: neckHeight
    ))
    screenEdge.withAlphaComponent(0.75).setFill()
    neck.fill()

    let baseWidth = rect.width * 0.34
    let baseHeight = rect.height * 0.055
    let base = NSBezierPath(roundedRect: CGRect(
        x: rect.midX - baseWidth / 2,
        y: rect.minY - neckHeight - baseHeight,
        width: baseWidth, height: baseHeight
    ), xRadius: baseHeight / 2, yRadius: baseHeight / 2)
    base.fill()
}

/// Broadcast waves (dot + 2 arcs) above a point, tinted `color`.
private func drawBroadcastWaves(center: CGPoint, color: NSColor, scale: CGFloat) {
    color.setStroke()
    color.setFill()

    let dotRadius = 14 * scale
    NSBezierPath(ovalIn: CGRect(
        x: center.x - dotRadius, y: center.y - dotRadius,
        width: dotRadius * 2, height: dotRadius * 2
    )).fill()

    for (radius, alpha) in [(CGFloat(52), 0.9), (CGFloat(92), 0.55)] as [(CGFloat, CGFloat)] {
        let r = radius * scale
        for side in [-1.0, 1.0] {
            let path = NSBezierPath()
            let arcCenter = CGPoint(x: center.x, y: center.y)
            path.appendArc(
                withCenter: arcCenter, radius: r,
                startAngle: side < 0 ? 100 : -10,
                endAngle: side < 0 ? 190 : 80,
                clockwise: side < 0
            )
            path.lineWidth = 13 * scale
            path.lineCapStyle = .round
            color.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
    }
}

/// Swap badge: filled circle with two opposing arrows.
private func drawSwapBadge(center: CGPoint, radius: CGFloat) {
    // Badge disc with subtle border
    orange.setFill()
    NSBezierPath(ovalIn: CGRect(
        x: center.x - radius, y: center.y - radius,
        width: radius * 2, height: radius * 2
    )).fill()
    NSColor.white.withAlphaComponent(0.35).setStroke()
    let ring = NSBezierPath(ovalIn: CGRect(
        x: center.x - radius + 3, y: center.y - radius + 3,
        width: (radius - 3) * 2, height: (radius - 3) * 2
    ))
    ring.lineWidth = 4
    ring.stroke()

    // Two opposing horizontal arrows (⇄)
    NSColor.white.setStroke()
    NSColor.white.setFill()
    let arrowLen = radius * 0.62
    let arrowY = [radius * 0.22, -radius * 0.22]
    let lineW = radius * 0.14

    for (index, yOff) in arrowY.enumerated() {
        let goingRight = index == 0
        let y = center.y + yOff
        let path = NSBezierPath()
        path.lineWidth = lineW
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        let startX = center.x + (goingRight ? -arrowLen : arrowLen)
        let endX = center.x + (goingRight ? arrowLen : -arrowLen)
        path.move(to: CGPoint(x: startX, y: y))
        path.line(to: CGPoint(x: endX, y: y))

        // Arrowhead
        let headLen = radius * 0.30
        let dir: CGFloat = goingRight ? 1 : -1
        path.move(to: CGPoint(x: endX - dir * headLen, y: y + headLen * 0.8))
        path.line(to: CGPoint(x: endX, y: y))
        path.line(to: CGPoint(x: endX - dir * headLen, y: y - headLen * 0.8))
        path.stroke()
    }
}

// MARK: - Icon rendering

private func renderIcon(switcher: Bool, size: CGFloat) -> NSImage {
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    let image = NSImage(size: canvas.size)
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        fatalError("No graphics context")
    }

    drawBackground(in: canvas, context: context)

    // Back display (upper-left), front display (lower-right)
    let backRect = CGRect(x: size * 0.22, y: size * 0.44, width: size * 0.42, height: size * 0.26)
    drawDisplay(in: backRect, codeLines: true)

    let frontRect = CGRect(x: size * 0.40, y: size * 0.28, width: size * 0.42, height: size * 0.26)
    drawDisplay(in: frontRect, codeLines: true)

    if switcher {
        drawSwapBadge(center: CGPoint(x: size * 0.70, y: size * 0.68), radius: size * 0.085)
    } else {
        drawBroadcastWaves(center: CGPoint(x: size * 0.50, y: size * 0.80),
                           color: magenta, scale: size / 1024)
    }

    image.unlockFocus()
    return image
}

private func writePNG(image: NSImage, to path: String) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG for \(path)")
    }
    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
}

// MARK: - Main

let outputDir = "Resources/AppIcons"
try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let sender = renderIcon(switcher: false, size: 1024)
try writePNG(image: sender, to: "\(outputDir)/icon-dualcast-1024.png")
print("Wrote \(outputDir)/icon-dualcast-1024.png")

let switcher = renderIcon(switcher: true, size: 1024)
try writePNG(image: switcher, to: "\(outputDir)/icon-switcher-1024.png")
print("Wrote \(outputDir)/icon-switcher-1024.png")
