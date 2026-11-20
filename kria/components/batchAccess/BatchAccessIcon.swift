import AppKit

// Shared by the workbench, the running component and its build-time .icns exporter.
@MainActor
enum BatchAccessIcon {
    nonisolated static let accentRed = 0.94
    nonisolated static let accentGreen = 0.38
    nonisolated static let accentBlue = 0.17
    private static let pixelSizes = [16, 32, 64, 128, 256, 512, 1024]

    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 256, height: 256))
        for size in pixelSizes {
            let representation = NSBitmapImageRep(cgImage: render(pixelSize: size))
            representation.size = image.size
            image.addRepresentation(representation)
        }
        image.isTemplate = false
        return image
    }()

    private static func render(pixelSize: Int) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: pixelSize, height: pixelSize,
                                bitsPerComponent: 8, bytesPerRow: pixelSize * 4,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(pixelSize) / 256, y: CGFloat(pixelSize) / 256)
        context.setFillColor(CGColor(colorSpace: colorSpace,
                                     components: [accentRed, accentGreen, accentBlue, 1])!)
        context.addPath(CGPath(roundedRect: CGRect(x: 16, y: 16, width: 224, height: 224),
                               cornerWidth: 48, cornerHeight: 48, transform: nil))
        context.fillPath()

        // Explicit geometry avoids SF Symbol palette layers flattening into a white disc.
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(9)
        context.strokeEllipse(in: CGRect(x: 66, y: 66, width: 124, height: 124))
        let bolt = CGMutablePath()
        bolt.move(to: CGPoint(x: 142, y: 176))
        for point in [CGPoint(x: 99, y: 122), CGPoint(x: 126, y: 122),
                      CGPoint(x: 114, y: 80), CGPoint(x: 157, y: 136),
                      CGPoint(x: 130, y: 136)] {
            bolt.addLine(to: point)
        }
        bolt.closeSubpath()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(bolt)
        context.fillPath()
        return context.makeImage()!
    }

    #if ICON_EXPORT
    static func export(to directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let representation = NSBitmapImageRep(cgImage: render(pixelSize: size * scale))
                guard let png = representation.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let suffix = scale == 2 ? "@2x" : ""
                try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"), options: .atomic)
            }
        }
    }
    #endif
}

#if ICON_EXPORT
@main
@MainActor
private enum BatchAccessIconExporter {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try BatchAccessIcon.export(to: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
    }
}
#endif
