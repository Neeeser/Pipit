// Draws the DMG installer background at 1x and 2x.
//
// Run: swift scripts/make-dmg-background.swift
// Writes Assets/Pipit/DMG/background.png (660x400) and background@2x.png
// (1320x800). Finder draws the two icons on top, so the icon areas stay empty.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width = 660.0
let height = 400.0
let iconCentreY = 190.0
let appIconX = 180.0
let applicationsX = 480.0

func url(named name: String) -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    return root.appendingPathComponent("Assets/Pipit/DMG/\(name)")
}

/// Draws one image. The context is flipped so y grows downward, which matches
/// the Finder coordinates the positions come from.
func draw(scale: Double, to output: URL) {
    let pixelWidth = Int(width * scale)
    let pixelHeight = Int(height * scale)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: pixelWidth,
              height: pixelHeight,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else {
        FileHandle.standardError.write(Data("cannot create the bitmap context\n".utf8))
        exit(1)
    }
    context.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))

    // Light neutral gradient, near white at the top.
    let stops: [CGFloat] = [
        0.98, 0.98, 0.98, 1,
        0.93, 0.93, 0.94, 1,
    ]
    if let gradient = CGGradient(colorSpace: space, colorComponents: stops, locations: [0, 1], count: 2) {
        context.saveGState()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: height),
            options: []
        )
        context.restoreGState()
    }

    func text(_ string: String, font: CTFont, grey: CGFloat, centreY: Double) {
        let attributes: [String: Any] = [
            kCTFontAttributeName as String: font,
            kCTForegroundColorAttributeName as String:
                CGColor(colorSpace: space, components: [grey, grey, grey, 1]) as Any,
        ]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)
        )
        var ascent = 0.0 as CGFloat
        var descent = 0.0 as CGFloat
        let lineWidth = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(
            x: (width - lineWidth) / 2,
            y: centreY + Double(ascent - descent) / 2
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    text(
        "Install Pipit",
        font: CTFontCreateUIFontForLanguage(.system, 34, nil)
            .flatMap { CTFontCreateCopyWithSymbolicTraits($0, 34, nil, .traitBold, .traitBold) }
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, 34, nil),
        grey: 0.13,
        centreY: 66
    )
    text(
        "Drag Pipit to Applications",
        font: CTFontCreateUIFontForLanguage(.system, 16, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 16, nil),
        grey: 0.45,
        centreY: 100
    )

    // A thin arrow between the icon positions, at the height of the icons.
    let shaftStart = appIconX + 88
    let shaftEnd = applicationsX - 88
    let head = 13.0
    context.setStrokeColor(CGColor(colorSpace: space, components: [0.62, 0.62, 0.64, 1])!)
    context.setLineWidth(2)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.beginPath()
    context.move(to: CGPoint(x: shaftStart, y: iconCentreY))
    context.addLine(to: CGPoint(x: shaftEnd - head * 0.7, y: iconCentreY))
    context.strokePath()
    context.beginPath()
    context.move(to: CGPoint(x: shaftEnd - head, y: iconCentreY - head * 0.62))
    context.addLine(to: CGPoint(x: shaftEnd, y: iconCentreY))
    context.addLine(to: CGPoint(x: shaftEnd - head, y: iconCentreY + head * 0.62))
    context.strokePath()

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              output as CFURL, UTType.png.identifier as CFString, 1, nil
          )
    else {
        FileHandle.standardError.write(Data("cannot write \(output.path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("cannot finalize \(output.path)\n".utf8))
        exit(1)
    }
    print("wrote \(output.path) at \(pixelWidth)x\(pixelHeight)")
}

draw(scale: 1, to: url(named: "background.png"))
draw(scale: 2, to: url(named: "background@2x.png"))
