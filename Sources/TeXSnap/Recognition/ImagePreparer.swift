import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct PreparedImage {
    let data: Data
    let mediaType: String
    let width: Int
    let height: Int
}

enum ImagePreparerError: LocalizedError {
    case unreadable
    case tooSmall
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The image could not be read."
        case .tooSmall: return "The image is too small to read."
        case .encodingFailed: return "The image could not be prepared for recognition."
        }
    }
}

/// Turns a screenshot, pasted image or file into the image that is sent to Claude:
/// oriented, flattened onto its own background colour, given a margin, and scaled to a readable size.
enum ImagePreparer {
    /// Claude reads up to 2576 px on the long edge and about 3.5 megapixels per image.
    static let maxLongEdge: CGFloat = 2576
    static let maxPixels: CGFloat = 3_500_000
    /// The API limit is 5 MB of base64, which is 4/3 of the raw size.
    static let maxBytes = 3_700_000

    struct Options {
        /// Off by default: in testing, enlarged small crops read as blurry and thin rules looked heavier.
        var upscale = false
        var pad = true
    }

    static func prepare(_ data: Data, options: Options = Options()) throws -> PreparedImage {
        guard let image = decode(data) else { throw ImagePreparerError.unreadable }
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        guard w >= 2, h >= 2 else { throw ImagePreparerError.tooSmall }

        // A margin keeps glyphs that touch the crop edge from looking cut off.
        let pad: CGFloat = options.pad ? min(32, max(8, (0.04 * max(w, h)).rounded())) : 0
        let paddedW = w + 2 * pad
        let paddedH = h + 2 * pad
        var scale: CGFloat = 1
        if options.upscale {
            // Small crops (tiny subscripts) are enlarged by a whole factor so each glyph gets more detail.
            let long = max(paddedW, paddedH)
            if long < 800 { scale = min(3, max(1, (1600 / long).rounded(.down))) }
        }
        scale = min(scale, maxLongEdge / max(paddedW, paddedH), (maxPixels / (paddedW * paddedH)).squareRoot())
        let outW = max(1, Int((paddedW * scale).rounded()))
        let outH = max(1, Int((paddedH * scale).rounded()))

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ImagePreparerError.encodingFailed }
        let bg = backgroundColor(of: image)
        ctx.setFillColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        ctx.interpolationQuality = .high
        let s = CGFloat(outW) / paddedW
        ctx.draw(image, in: CGRect(x: pad * s, y: pad * s, width: w * s, height: h * s))
        guard let composed = ctx.makeImage() else { throw ImagePreparerError.encodingFailed }

        if let png = encode(composed, type: .png), png.count <= maxBytes {
            return PreparedImage(data: png, mediaType: "image/png", width: outW, height: outH)
        }
        guard let jpeg = encode(composed, type: .jpeg, quality: 0.92) else { throw ImagePreparerError.encodingFailed }
        return PreparedImage(data: jpeg, mediaType: "image/jpeg", width: outW, height: outH)
    }

    /// Decodes any image format ImageIO or AppKit understands, applying EXIF orientation.
    static func decode(_ data: Data) -> CGImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            if w > 0, h > 0 {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(w, h),
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
            }
            if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
        }
        if let pdf = NSPDFImageRep(data: data) {
            pdf.currentPage = 0
            let size = pdf.bounds.size
            let scale = min(4, max(1, 2000 / max(size.width, size.height, 1)))
            let width = Int(size.width * scale), height = Int(size.height * scale)
            guard width > 0, height > 0,
                  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            pdf.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            return rep.cgImage
        }
        if let image = NSImage(data: data) {
            var rect = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return nil
    }

    /// The colour along the image's border (its background). For transparent images, white or a dark
    /// grey, whichever contrasts with the content.
    static func backgroundColor(of image: CGImage) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let side = 128
        let w = image.width >= image.height ? side : max(1, side * image.width / image.height)
        let h = image.height > image.width ? side : max(1, side * image.height / image.width)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return (1, 1, 1) }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let raw = ctx.data else { return (1, 1, 1) }
        let px = raw.assumingMemoryBound(to: UInt8.self)

        func rgba(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            let o = (y * w + x) * 4
            let a = CGFloat(px[o + 3]) / 255
            guard a > 0 else { return (0, 0, 0, 0) }
            return (CGFloat(px[o]) / 255 / a, CGFloat(px[o + 1]) / 255 / a, CGFloat(px[o + 2]) / 255 / a, a)
        }

        var reds: [CGFloat] = [], greens: [CGFloat] = [], blues: [CGFloat] = []
        var transparent = 0, total = 0
        var edge: [(Int, Int)] = []
        for x in 0..<w { edge.append((x, 0)); edge.append((x, h - 1)) }
        for y in 0..<h { edge.append((0, y)); edge.append((w - 1, y)) }
        for (x, y) in edge {
            let (r, g, b, a) = rgba(x, y)
            total += 1
            if a < 0.5 { transparent += 1; continue }
            reds.append(r); greens.append(g); blues.append(b)
        }
        if transparent * 2 > total || reds.isEmpty {
            var luminance: CGFloat = 0
            var count: CGFloat = 0
            for y in 0..<h {
                for x in 0..<w {
                    let (r, g, b, a) = rgba(x, y)
                    guard a >= 0.5 else { continue }
                    luminance += 0.2126 * r + 0.7152 * g + 0.0722 * b
                    count += 1
                }
            }
            return count > 0 && luminance / count > 0.6 ? (0.12, 0.12, 0.12) : (1, 1, 1)
        }
        func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }
        return (min(1, median(reds)), min(1, median(greens)), min(1, median(blues)))
    }

    static func encode(_ image: CGImage, type: UTType, quality: CGFloat? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
