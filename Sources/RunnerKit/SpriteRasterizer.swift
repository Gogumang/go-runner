import AppKit
import CoreGraphics
import GoRunnerCore

/// Validation and rasterization of `PixelSprite` text grids (implementation behind `SpriteRenderer`).
enum SpriteRasterizer {
    static let frameCountRange = 2...30

    static func problems(in sprite: PixelSprite) -> [String] {
        var problems: [String] = []
        let id = sprite.id
        let frameCount = sprite.frames.count

        if !frameCountRange.contains(frameCount) {
            problems.append(Loc.t(
                "\(id): 프레임이 \(frameCount)개입니다. \(frameCountRange.lowerBound)~\(frameCountRange.upperBound)개여야 합니다.",
                "\(id): has \(frameCount) frame(s); \(frameCountRange.lowerBound)...\(frameCountRange.upperBound) are required."
            ))
        }

        var expectedWidth: Int?
        var mismatch: (frame: Int, row: Int, width: Int)?
        var unknown: [Character] = []
        var hasInk = false

        for (frameIndex, rows) in sprite.frames.enumerated() {
            if rows.count != PixelSprite.rows {
                problems.append(Loc.t(
                    "\(id): \(frameIndex)번 프레임의 행이 \(rows.count)개입니다. \(PixelSprite.rows)행이어야 합니다.",
                    "\(id): frame \(frameIndex) has \(rows.count) rows; exactly \(PixelSprite.rows) are required."
                ))
            }
            for (rowIndex, row) in rows.enumerated() {
                let width = row.count
                if let expectedWidth {
                    if width != expectedWidth, mismatch == nil { mismatch = (frameIndex, rowIndex, width) }
                } else {
                    expectedWidth = width
                }
                for character in row where character != "." {
                    hasInk = true
                    if sprite.palette[character] == nil, !unknown.contains(character) {
                        unknown.append(character)
                    }
                }
            }
        }

        if let mismatch, let expectedWidth {
            problems.append(Loc.t(
                "\(id): 너비가 일정하지 않습니다(\(mismatch.frame)번 프레임 \(mismatch.row)행: \(mismatch.width)칸, 기준 \(expectedWidth)칸).",
                "\(id): rows have unequal widths (frame \(mismatch.frame) row \(mismatch.row) is \(mismatch.width) cells, expected \(expectedWidth))."
            ))
        }

        if frameCount > 0 {
            let width = expectedWidth ?? 0
            if !PixelSprite.widthRange.contains(width) {
                problems.append(Loc.t(
                    "\(id): 너비가 \(width)칸입니다. \(PixelSprite.widthRange.lowerBound)~\(PixelSprite.widthRange.upperBound)칸이어야 합니다.",
                    "\(id): width is \(width) cells; \(PixelSprite.widthRange.lowerBound)...\(PixelSprite.widthRange.upperBound) are allowed."
                ))
            }
        }

        if sprite.palette.isEmpty, hasInk {
            problems.append(Loc.t(
                "\(id): 팔레트가 비어 있습니다. '.' 이외의 문자는 팔레트에 색이 있어야 합니다.",
                "\(id): the palette is empty, but the sprite has non-transparent cells."
            ))
        } else if !unknown.isEmpty {
            let listed = unknown.map { "'\($0)'" }.joined(separator: ", ")
            problems.append(Loc.t(
                "\(id): 팔레트에 없는 문자가 있습니다: \(listed)",
                "\(id): unknown character(s) not in the palette: \(listed)"
            ))
        }

        if let order = sprite.frameOrder {
            if order.isEmpty {
                problems.append(Loc.t("\(id): frameOrder가 비어 있습니다.", "\(id): frameOrder is empty."))
            } else {
                let bad = order.filter { !(0..<frameCount).contains($0) }
                if !bad.isEmpty {
                    let listed = bad.map(String.init).joined(separator: ", ")
                    problems.append(Loc.t(
                        "\(id): frameOrder에 잘못된 인덱스가 있습니다: \(listed) (프레임 \(frameCount)개)",
                        "\(id): frameOrder has out-of-range indices: \(listed) (\(frameCount) frames)"
                    ))
                }
            }
        }

        return problems
    }

    static func render(_ sprite: PixelSprite) throws -> RunnerFrames {
        let problems = problems(in: sprite)
        guard problems.isEmpty else {
            throw RunnerKitError.invalidSprite(problems.joined(separator: "\n"))
        }
        let width = sprite.frames[0][0].count
        let images = try sprite.frames.enumerated().map { index, rows in
            guard let image = rasterize(rows: rows, width: width, palette: sprite.palette, isTemplate: sprite.isTemplate) else {
                throw RunnerKitError.invalidSprite(Loc.t(
                    "\(sprite.id): \(index)번 프레임을 그릴 수 없습니다.",
                    "\(sprite.id): could not rasterize frame \(index)."
                ))
            }
            return image
        }
        return RunnerFrames(
            images: images,
            pointSize: CGSize(width: width, height: PixelSprite.rows),
            isTemplate: sprite.isTemplate,
            order: sprite.frameOrder ?? Array(0..<images.count)
        )
    }

    /// One frame → CGImage of `width*2 × 36` px, 2×2 px per cell, sRGB premultiplied RGBA8.
    static func rasterize(rows: [String], width: Int, palette: [Character: UInt32], isTemplate: Bool) -> CGImage? {
        let scale = PixelSprite.pixelsPerCell
        let pixelWidth = width * scale
        let pixelHeight = PixelSprite.rows * scale
        guard let context = ImageUtilities.makeRGBAContext(width: pixelWidth, height: pixelHeight),
              let data = context.data
        else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: pixelWidth * pixelHeight * 4)
        // Bitmap context memory starts with the top row of the image, matching text row 0.
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, character) in row.enumerated() where character != "." {
                guard let rgba = palette[character] else { continue }
                let alpha = rgba & 0xFF
                guard alpha > 0 else { continue }
                let red = isTemplate ? 0 : (rgba >> 24) & 0xFF
                let green = isTemplate ? 0 : (rgba >> 16) & 0xFF
                let blue = isTemplate ? 0 : (rgba >> 8) & 0xFF
                let premultiplied = [red, green, blue].map { UInt8(($0 * alpha + 127) / 255) }
                for dy in 0..<scale {
                    for dx in 0..<scale {
                        let offset = ((rowIndex * scale + dy) * pixelWidth + columnIndex * scale + dx) * 4
                        buffer[offset] = premultiplied[0]
                        buffer[offset + 1] = premultiplied[1]
                        buffer[offset + 2] = premultiplied[2]
                        buffer[offset + 3] = UInt8(alpha)
                    }
                }
            }
        }
        return context.makeImage()
    }

    static func image(from frames: RunnerFrames, index: Int, tint: NSColor?) -> NSImage {
        guard !frames.images.isEmpty else { return placeholderImage(size: frames.pointSize) }
        let clamped = min(max(index, 0), frames.images.count - 1)
        let cgImage = frames.images[clamped]
        if frames.isTemplate {
            if let tint {
                let color = tint.usingColorSpace(.sRGB)?.cgColor ?? tint.cgColor
                let tinted = ImageUtilities.tinted(cgImage, color: color) ?? cgImage
                return NSImage(cgImage: tinted, size: frames.pointSize)
            }
            let image = NSImage(cgImage: cgImage, size: frames.pointSize)
            image.isTemplate = true
            return image
        }
        return NSImage(cgImage: cgImage, size: frames.pointSize)
    }

    static func placeholderImage(size: CGSize) -> NSImage {
        // A drawing handler that draws nothing: a valid, fully transparent image that AppKit lays out at `size`.
        let image = NSImage(size: size, flipped: false) { _ in true }
        image.isTemplate = true
        return image
    }
}
