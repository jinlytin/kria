import AppKit

@MainActor
enum CustomsIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 256, height: 256))
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            let representation = NSBitmapImageRep(cgImage: render(size))
            representation.size = image.size
            image.addRepresentation(representation)
        }
        image.isTemplate = false
        return image
    }()

    private static func render(_ size: Int) -> CGImage {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(size) / 256, y: CGFloat(size) / 256)
        context.setFillColor(CGColor(srgbRed: 0.10, green: 0.48, blue: 0.62, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 16, y: 16, width: 224, height: 224), cornerWidth: 48, cornerHeight: 48, transform: nil))
        context.fillPath()
        let shield = CGMutablePath()
        shield.move(to: CGPoint(x: 128, y: 198))
        shield.addLine(to: CGPoint(x: 187, y: 175))
        shield.addLine(to: CGPoint(x: 187, y: 116))
        shield.addQuadCurve(to: CGPoint(x: 128, y: 58), control: CGPoint(x: 187, y: 77))
        shield.addQuadCurve(to: CGPoint(x: 69, y: 116), control: CGPoint(x: 69, y: 77))
        shield.addLine(to: CGPoint(x: 69, y: 175))
        shield.closeSubpath()
        context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(9)
        context.addPath(shield); context.strokePath()
        context.setLineCap(.round); context.setLineJoin(.round); context.setLineWidth(8)
        for (y, direction) in [(148.0, 1.0), (114.0, -1.0)] {
            let start = direction > 0 ? 97.0 : 159.0
            let end = direction > 0 ? 159.0 : 97.0
            context.move(to: CGPoint(x: start, y: y)); context.addLine(to: CGPoint(x: end, y: y))
            context.move(to: CGPoint(x: end - direction * 13, y: y + 12))
            context.addLine(to: CGPoint(x: end, y: y)); context.addLine(to: CGPoint(x: end - direction * 13, y: y - 12))
            context.strokePath()
        }
        return context.makeImage()!
    }

    #if CUSTOMS_ICON_EXPORT
    static func export(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let rep = NSBitmapImageRep(cgImage: render(size * scale))
                guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                let suffix = scale == 2 ? "@2x" : ""
                try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"), options: .atomic)
            }
        }
    }
    #endif
}

#if CUSTOMS_ICON_EXPORT
@main
@MainActor
private enum CustomsIconExporter {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileWriteInvalidFileName) }
        try CustomsIcon.export(to: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
    }
}
#endif
