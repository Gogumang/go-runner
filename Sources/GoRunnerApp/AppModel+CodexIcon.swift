import AppKit

extension AppModel {
    /// Cached Codex app icon (outer nil = not looked up yet, inner nil = Codex app not installed).
    private static var codexIconCache: NSImage??

    /// Logo from the user's installed Codex desktop app (bundle id `com.openai.codex`) for the menu's Codex row,
    /// with the app icon's white rounded-square background removed. Read at runtime from the local install, like Finder
    /// shows app icons; nothing is bundled with GoRunner. Returns nil when the app isn't installed (the row keeps its SF Symbol).
    func codexAppIcon() -> NSImage? {
        if let cached = Self.codexIconCache { return cached }
        var image: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            image = Self.logoMask(from: NSWorkspace.shared.icon(forFile: url.path))
        }
        Self.codexIconCache = .some(image)
        return image
    }

    /// Turns a dark-logo-on-white app icon into a template image of just the logo: crops away the rounded square and its
    /// shadow, then maps brightness to opacity (white → transparent, dark strokes → opaque). As a template it follows the
    /// label color in light and dark mode like the SF Symbols in the other rows.
    /// - Parameters:
    ///   - pixels: output bitmap edge in pixels (48 px = 24 pt at 2×).
    ///   - inset: fraction cropped from each side; the logo sits inside the central ~64% of macOS app icons.
    static func logoMask(from icon: NSImage, pixels: Int = 48, inset: CGFloat = 0.17) -> NSImage? {
        var proposed = CGRect(x: 0, y: 0, width: 512, height: 512)
        guard let full = icon.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        let width = CGFloat(full.width)
        let height = CGFloat(full.height)
        let crop = CGRect(x: width * inset, y: height * inset,
                          width: width * (1 - 2 * inset), height: height * (1 - 2 * inset)).integral
        guard let logo = full.cropping(to: crop),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(logo, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let data = context.data else { return nil }

        let buffer = data.bindMemory(to: UInt8.self, capacity: pixels * pixels * 4)
        for pixel in 0..<(pixels * pixels) {
            let offset = pixel * 4
            let alpha = Double(buffer[offset + 3]) / 255
            var coverage = 0.0
            if alpha > 0 {
                // Unpremultiply to get the pixel's own brightness.
                let red = Double(buffer[offset]) / 255 / alpha
                let green = Double(buffer[offset + 1]) / 255 / alpha
                let blue = Double(buffer[offset + 2]) / 255 / alpha
                let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                // White background → 0, dark strokes → 1, soft anti-aliased edge in between.
                coverage = max(0, min(1, (0.85 - luminance) / 0.45)) * alpha
            }
            buffer[offset] = 0
            buffer[offset + 1] = 0
            buffer[offset + 2] = 0
            buffer[offset + 3] = UInt8((coverage * 255).rounded())
        }
        guard let mask = context.makeImage() else { return nil }
        let image = NSImage(cgImage: mask, size: NSSize(width: CGFloat(pixels) / 2, height: CGFloat(pixels) / 2))
        image.isTemplate = true
        return image
    }
}
