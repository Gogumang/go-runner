import AppKit
import GoRunnerCore
import SwiftUI

/// Small rounded label, e.g. trust level or license.
struct Chip: View {
    let text: String
    var tint: Color = .secondary

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .glassBadge(tint: tint)
    }
}

/// First frame of a runner. Template runners follow the current label color.
struct RunnerThumbnail: View {
    let image: NSImage?
    let isTemplate: Bool
    var height: CGFloat = 18

    var body: some View {
        if let image, image.size.width > 0, image.size.height > 0 {
            Image(nsImage: image)
                .renderingMode(isTemplate ? .template : .original)
                .interpolation(.none)
                .resizable()
                .aspectRatio(image.size, contentMode: .fit)
                .frame(height: height)
                .foregroundStyle(.primary)
        } else {
            Image(systemName: "figure.run")
                .font(.system(size: height * 0.8))
                .foregroundStyle(.secondary)
                .frame(width: height, height: height)
        }
    }
}

extension ProviderReport {
    /// One-line status used in the settings window.
    var statusSummary: String {
        if let error, snapshot == nil { return "⚠︎ " + error.message }
        if let snapshot {
            let base = Loc.t("성공", "OK") + " · " + MetricFormat.age(snapshot.fetchedAt)
            return error == nil ? base : base + " · ⚠︎ " + (error?.message ?? "")
        }
        return Loc.t("데이터 없음", "No data")
    }
}
