import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An 8-bit RGBA pixel buffer (not premultiplied); PNG reading and writing goes through ImageIO.
public struct RGBAImage: Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8, UInt8)) {
        self.init(width: width, height: height, pixels: Array([fill.0, fill.1, fill.2, fill.3].repeated(width * height)))
    }

    public init?(_ image: CGImage) {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, pixels: buf)
    }

    public init?(contentsOf url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        self.init(img)
    }

    public var cgImage: CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

extension Array {
    fileprivate func repeated(_ n: Int) -> [Element] {
        var out: [Element] = []
        out.reserveCapacity(count * n)
        for _ in 0..<n { out.append(contentsOf: self) }
        return out
    }
}

public enum PNG {
    public static func load(_ url: URL) -> CGImage? {
        // Decode into memory right away: the temporary screenshot file is deleted after reading
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    @discardableResult
    public static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dst, image, nil)
        return CGImageDestinationFinalize(dst)
    }
}

/// Crops a piece out of a window screenshot by an element's frame.
public enum Crop {
    /// The pixel rect of an element frame (global points) in the window screenshot: subtract the window's top-left corner, add `margin` points on every side, multiply by the ratio of screenshot width to window width
    /// (2 on Retina), then clip to the screenshot. nil when the whole rect lies outside the screenshot.
    public static func pixelRect(element: CGRect, window: CGRect, imageSize: CGSize, margin: CGFloat) -> CGRect? {
        guard window.width > 0, window.height > 0 else { return nil }
        let sx = imageSize.width / window.width, sy = imageSize.height / window.height
        let local = element.offsetBy(dx: -window.minX, dy: -window.minY).insetBy(dx: -margin, dy: -margin)
        let px = CGRect(x: local.minX * sx, y: local.minY * sy, width: local.width * sx, height: local.height * sy).integral
        let r = px.intersection(CGRect(origin: .zero, size: imageSize))
        return r.isNull || r.width < 1 || r.height < 1 ? nil : r
    }

    /// `NN-<step>-<identifier>`; without an identifier, the first 16 characters of the text.
    public static func fileName(step: String, id: String?, text: String?) -> String {
        let part = id.flatMap { $0.isEmpty ? nil : $0 } ?? String((text ?? "element").prefix(16))
        return step + "-" + FileName.safe(part)
    }

    public static func crop(_ image: CGImage, to r: CGRect) -> CGImage? { image.cropping(to: r) }
}
