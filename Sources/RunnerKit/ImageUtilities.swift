import AppKit
import CoreGraphics

/// CoreGraphics helpers used by the sprite renderer.
enum ImageUtilities {
    static let sRGB: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// 8-bit RGBA, premultiplied alpha, sRGB. Memory row 0 is the top row of the image.
    static let rgbaBitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    static func makeRGBAContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: sRGB, bitmapInfo: rgbaBitmapInfo)
    }

    /// Premultiplied RGBA8 bytes, top row first.
    static func rgbaPixels(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: sRGB, bitmapInfo: rgbaBitmapInfo)
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// Fills the image's alpha silhouette with `color` (source-in compositing).
    static func tinted(_ image: CGImage, color: CGColor) -> CGImage? {
        guard let context = makeRGBAContext(width: image.width, height: image.height) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.interpolationQuality = .none
        context.draw(image, in: rect)
        context.setBlendMode(.sourceIn)
        context.setFillColor(color)
        context.fill(rect)
        return context.makeImage()
    }
}
