#!/usr/bin/env swift
//
// gen_appicon.swift
//
// Renders Tripto's app icon (light + dark) and writes them, plus the
// appiconset's Contents.json, into
// Tripto/Resources/Assets.xcassets/AppIcon.appiconset/. Runs out-of-band on
// the mac host, same convention as scripts/gen_tokens.py — CoreGraphics +
// ImageIO only (no UIKit/SwiftUI), so it needs nothing beyond the system.
//
// Composition (PLAN-signature-layer.md §D8): full-bleed "dusk departure"
// gradient ground (BUILD_PLAN.md §6.1 / Tokens.swift's CoverGradient.dusk),
// a soft indigo horizon arc across the bottom third, and a paper-white
// paper-plane silhouette climbing top-right with a single thin curved
// contrail. Honest ceiling, not a final mark — a human designer pass is the
// follow-up (DECISIONS.md, 2026-07-11).
//
// Deterministic: identical script -> byte-identical PNGs/JSON every run (no
// wall-clock, no random, no external state). Prints a SHA-256 per output
// file so re-runs are provably identical.
//
// Do not hand-edit the generated PNGs/Contents.json; edit this script and
// re-run it instead.
//
// Usage: swift scripts/gen_appicon.swift

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

// MARK: - Canvas + color

let canvas: CGFloat = 1024
let iconColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

/// Parses "#RRGGBB" into a CGColor. Fixed hex, not the app's adaptive
/// `Palette` — this script has no SwiftUI/UIKit to resolve dynamic colors,
/// and an icon has no runtime dark-mode toggle anyway, just the two static
/// variants rendered below (values lifted straight from Tokens.swift /
/// BUILD_PLAN §6.1 so both stay in sync by inspection).
func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
    var value: UInt64 = 0
    Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
    let r = CGFloat((value & 0xFF0000) >> 16) / 255
    let g = CGFloat((value & 0x00FF00) >> 8) / 255
    let b = CGFloat(value & 0x0000FF) / 255
    return CGColor(colorSpace: iconColorSpace, components: [r, g, b, alpha])!
}

// MARK: - Geometry helpers

/// Rotates + scales + translates a local-space point (plane nose sits on
/// local +X, climb angle applied here) into canvas space. One transform
/// shared by the plane body and its contrail so they stay attached at any
/// angle without hand-tuning two sets of coordinates.
func place(_ p: CGPoint, scale: CGFloat, angleDegrees: CGFloat, center: CGPoint) -> CGPoint {
    let a = angleDegrees * .pi / 180
    let x = p.x * scale, y = p.y * scale
    return CGPoint(
        x: center.x + x * cos(a) - y * sin(a),
        y: center.y + x * sin(a) + y * cos(a)
    )
}

// MARK: - Rendering

/// `groundStops`: the 3-stop dusk gradient, topLeading -> bottomTrailing
/// (BUILD_PLAN §6.1). SwiftUI's top-leading/bottom-trailing corners map to
/// (0, canvas)/(canvas, 0) in CoreGraphics' bottom-left-origin space.
func renderIcon(groundStops: [String]) -> CGImage {
    guard let ctx = CGContext(
        data: nil, width: Int(canvas), height: Int(canvas),
        bitsPerComponent: 8, bytesPerRow: 0, space: iconColorSpace,
        // No alpha channel in the output — app icons must render fully
        // opaque; noneSkipLast still blends semi-transparent fills (the
        // horizon/contrail) against what's already been painted, it just
        // never leaves the final buffer's own alpha as anything but 1.0.
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { fatalError("could not create bitmap context") }
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Ground: full-bleed dusk gradient.
    let ground = CGGradient(colorsSpace: iconColorSpace, colors: groundStops.map { color($0) } as CFArray, locations: nil)!
    ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: canvas), end: CGPoint(x: canvas, y: 0), options: [])

    // Horizon: a large ellipse mostly below the frame — only its crest
    // shows, across the bottom third, as a soft indigo arc. "Soft" comes
    // from fading the fill itself (there's no CoreImage/blur here), the
    // same bleeding-circle-as-horizon idiom EmptyStateArt.swift's home
    // scene uses.
    ctx.saveGState()
    let ellipse = CGRect(x: -canvas * 0.4, y: -canvas * 0.70, width: canvas * 1.8, height: canvas * 1.05)
    ctx.addPath(CGPath(ellipseIn: ellipse, transform: nil))
    ctx.clip()
    let crestY = ellipse.maxY
    // Palette.indigo (#2D2F52) is a fixed, non-adaptive token (Tokens.swift)
    // — the same hex is correct for both the light and dark variant.
    let horizon = CGGradient(
        colorsSpace: iconColorSpace,
        colors: [color("#2D2F52", alpha: 0), color("#2D2F52", alpha: 0.4)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        horizon,
        start: CGPoint(x: canvas / 2, y: crestY + canvas * 0.08),
        end: CGPoint(x: canvas / 2, y: 0),
        options: [.drawsAfterEndLocation]
    )
    ctx.restoreGState()

    // Paper-plane + contrail: one shared placement transform, nose climbing
    // toward the top-right — a plane taking off into "dusk departure".
    // paper-white glyph in both variants (D8: "glyph stays white" in dark).
    let paper = color("#FBFAF7")
    let scale: CGFloat = 195
    let angle: CGFloat = 34
    let center = CGPoint(x: canvas * 0.56, y: canvas * 0.55)

    // Contrail first (sits under the plane): a thin curved wedge built from
    // two quadratic curves that share the tail's width and the tip's single
    // point, so it tapers to nothing with no risk of the two edges crossing.
    // Faded with a clipped gradient (solid near the tail -> transparent at
    // the tip, same clip-then-gradient technique as the horizon above) so
    // it trails off instead of reading as a flat stroke.
    let tailStart = CGPoint(x: -0.78, y: 0)
    let control = CGPoint(x: -1.7, y: -0.42)
    let tip = CGPoint(x: -3.0, y: -0.62)
    let axis = CGPoint(x: tip.x - tailStart.x, y: tip.y - tailStart.y)
    let axisLen = hypot(axis.x, axis.y)
    let perp = CGPoint(x: -axis.y / axisLen, y: axis.x / axisLen)
    let halfWidth: CGFloat = 0.05
    let tailTop = CGPoint(x: tailStart.x + perp.x * halfWidth, y: tailStart.y + perp.y * halfWidth)
    let tailBottom = CGPoint(x: tailStart.x - perp.x * halfWidth, y: tailStart.y - perp.y * halfWidth)
    let controlTop = CGPoint(x: control.x + perp.x * halfWidth * 0.4, y: control.y + perp.y * halfWidth * 0.4)
    let controlBottom = CGPoint(x: control.x - perp.x * halfWidth * 0.4, y: control.y - perp.y * halfWidth * 0.4)
    let contrailPath = CGMutablePath()
    contrailPath.move(to: place(tailTop, scale: scale, angleDegrees: angle, center: center))
    contrailPath.addQuadCurve(
        to: place(tip, scale: scale, angleDegrees: angle, center: center),
        control: place(controlTop, scale: scale, angleDegrees: angle, center: center)
    )
    contrailPath.addQuadCurve(
        to: place(tailBottom, scale: scale, angleDegrees: angle, center: center),
        control: place(controlBottom, scale: scale, angleDegrees: angle, center: center)
    )
    contrailPath.closeSubpath()
    ctx.saveGState()
    ctx.addPath(contrailPath)
    ctx.clip()
    let fade = CGGradient(
        colorsSpace: iconColorSpace,
        colors: [color("#FBFAF7", alpha: 0.6), color("#FBFAF7", alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        fade,
        start: place(tailStart, scale: scale, angleDegrees: angle, center: center),
        end: place(tip, scale: scale, angleDegrees: angle, center: center),
        options: []
    )
    ctx.restoreGState()

    // Plane body: a flat dart silhouette (nose, swept wingtips, forked
    // tail notch) — six straight-line vertices, no hand-plotted pixels.
    let planeLocal: [CGPoint] = [
        CGPoint(x: 1.00, y: 0.00),
        CGPoint(x: -0.95, y: 0.50),
        CGPoint(x: -0.55, y: 0.10),
        CGPoint(x: -0.78, y: 0.00),
        CGPoint(x: -0.55, y: -0.10),
        CGPoint(x: -0.95, y: -0.50)
    ]
    let planePath = CGMutablePath()
    planePath.addLines(between: planeLocal.map { place($0, scale: scale, angleDegrees: angle, center: center) })
    planePath.closeSubpath()
    ctx.addPath(planePath)
    ctx.setFillColor(paper)
    ctx.fillPath()

    guard let image = ctx.makeImage() else { fatalError("could not rasterize icon") }
    return image
}

// MARK: - Output

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("could not create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("could not finalize PNG at \(url.path)")
    }
}

func sha256Hex(of url: URL) -> String {
    let data = try! Data(contentsOf: url)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

let contentsJSON = """
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "AppIcon-1024-dark.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

// MARK: - Main

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let appIconSet = repoRoot.appendingPathComponent("Tripto/Resources/Assets.xcassets/AppIcon.appiconset")

// CoverGradient.dusk (Tokens.swift), topLeading -> bottomTrailing.
let lightStops = ["#E8955A", "#C96B5B", "#2D2F52"]
// D8 dark variant: same stops shifted a step deeper, ending at
// Palette.paper's dark hex (#141522) instead of indigo.
let darkStops = ["#C96B5B", "#2D2F52", "#141522"]

let lightURL = appIconSet.appendingPathComponent("AppIcon-1024.png")
let darkURL = appIconSet.appendingPathComponent("AppIcon-1024-dark.png")
let jsonURL = appIconSet.appendingPathComponent("Contents.json")

writePNG(renderIcon(groundStops: lightStops), to: lightURL)
writePNG(renderIcon(groundStops: darkStops), to: darkURL)
try! (contentsJSON + "\n").write(to: jsonURL, atomically: true, encoding: .utf8)

for url in [lightURL, darkURL, jsonURL] {
    print("\(url.lastPathComponent)  sha256:\(sha256Hex(of: url))")
}
