// Draws Resources/Duetbar.icns: four meter bars with peak holds, in the same
// green/pale/red the app uses. Every size is drawn natively rather than
// downsampled, so the 16pt one still reads as bars.
//
//   swift scripts/make-icon.swift
//
// Only needs rerunning if the artwork changes; the .icns is committed.

import AppKit

let strongGreen = NSColor(srgbRed: 0.04, green: 0.76, blue: 0.24, alpha: 1)
let paleGreen = NSColor(srgbRed: 0.62, green: 0.88, blue: 0.66, alpha: 1)
let over = NSColor(srgbRed: 1.0, green: 0.16, blue: 0.12, alpha: 1)

// Level and peak hold per bar, as a fraction of full scale.
let bars: [(level: CGFloat, peak: CGFloat)] = [
    (0.55, 0.68),
    (0.80, 0.88),
    (0.42, 0.52),
    (0.95, 0.97),
]

/// Colour at a point up the meter, on the same thresholds as the app: green to
/// -12, pale to 0, red above.
func tint(at fraction: CGFloat) -> NSColor {
    if fraction > 0.90 { return over }
    if fraction > 0.72 { return paleGreen }
    return strongGreen
}

func draw(size s: CGFloat) -> NSBitmapImageRep {
    let px = Int(s)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Rounded square, inset the way macOS app icons are, with Apple's
    // continuous corner ratio.
    let inset = s * 0.098
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = plate.width * 0.2237
    let shape = NSBezierPath(roundedRect: plate, xRadius: corner, yRadius: corner)

    NSGradient(colors: [
        NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1),
    ])!.draw(in: shape, angle: -90)

    // Meter area, inset inside the plate.
    let pad = plate.width * 0.155
    let field = plate.insetBy(dx: pad, dy: pad)
    let gapRatio: CGFloat = 0.42          // gap as a fraction of bar width
    let barW = field.width / (CGFloat(bars.count) + gapRatio * CGFloat(bars.count - 1))
    let gap = barW * gapRatio
    let radius = barW / 2

    for (i, bar) in bars.enumerated() {
        let x = field.minX + CGFloat(i) * (barW + gap)

        // Unlit track.
        let track = CGRect(x: x, y: field.minY, width: barW, height: field.height)
        NSColor(white: 1, alpha: 0.10).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        // Lit portion, clipped to the track so the pill ends stay round.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).addClip()

        // Painted in thin slices so the green/pale/red thresholds land in the
        // right places without banding artefacts at small sizes.
        let lit = field.height * bar.level
        let step = max(s / 256, 0.5)
        var y = field.minY
        while y < field.minY + lit {
            let h = min(step, field.minY + lit - y)
            tint(at: (y - field.minY) / field.height).setFill()
            CGRect(x: x, y: y, width: barW, height: h + 0.5).fill()
            y += step
        }

        // Peak hold: a short tick sitting above the level.
        let peakY = field.minY + field.height * bar.peak
        let tickH = max(barW * 0.16, s / 128)
        tint(at: bar.peak).setFill()
        CGRect(x: x, y: peakY, width: barW, height: tickH).fill()

        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Write the iconset

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/Duetbar.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        let data = draw(size: CGFloat(px)).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}

let out = root.appendingPathComponent("Resources/Duetbar.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }

try? FileManager.default.removeItem(at: iconset)
print("wrote \(out.path)")
