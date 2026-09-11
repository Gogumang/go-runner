// Graph rows hosted inside the standard status menu (the user found text-only rows hard to scan). Every row uses the
// same columns: 16 pt icon, 62 pt label, flexible bar or graph, 42 pt value.

import AppKit
import GoRunnerCore
import SwiftUI

private enum MenuColumns {
    static let icon: CGFloat = 16
    static let label: CGFloat = 62
    static let value: CGFloat = 42
    static let spacing: CGFloat = 8
    /// Indent that lines a row up with the label column.
    static var labelIndent: CGFloat { icon + spacing }
}

/// CPU (recent history graph), memory, storage and battery bars.
struct SystemGaugesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    let onTap: () -> Void

    var body: some View {
        let gauges = StatusMenuContent.systemGauges(model.snapshot, settings: store.settings)
        VStack(alignment: .leading, spacing: 7) {
            if gauges.isEmpty {
                Text(verbatim: Loc.t("측정 중…", "Measuring…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(gauges) { gauge in
                HStack(spacing: MenuColumns.spacing) {
                    Image(systemName: gauge.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: MenuColumns.icon)
                    Text(verbatim: gauge.label)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .frame(width: MenuColumns.label, alignment: .leading)
                    if gauge.id == StatusMenuContent.cpuGaugeID {
                        HistoryGraph(values: model.cpuHistory)
                            .frame(height: 16)
                    } else {
                        MeterBar(fraction: gauge.fraction,
                                 tint: gauge.isChargeLevel ? MeterBar.chargeTint(gauge.fraction) : MeterBar.usageTint(gauge.fraction))
                    }
                    Text(verbatim: gauge.value)
                        .font(.system(size: 12).monospacedDigit())
                        .lineLimit(1)
                        .frame(width: MenuColumns.value, alignment: .trailing)
                }
                .frame(height: 18)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// One block per enabled AI service: name, a remaining-% bar per limit window, and the reset time of the tightest one.
struct ProviderGaugesView: View {
    @ObservedObject var quota: QuotaCoordinator
    @ObservedObject var store: SettingsStore
    let icons: [ProviderID: NSImage]
    let onTap: () -> Void

    private var providers: [ProviderID] {
        ProviderID.allCases.filter { QuotaCoordinator.isEnabled($0, in: store.settings.quota) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(providers) { id in
                ProviderGaugeBlock(gauge: StatusMenuContent.providerGauge(id, report: quota.reports[id],
                                                                         isStale: quota.staleProviders.contains(id),
                                                                         isRefreshing: quota.refreshingProviders.contains(id)),
                                   icon: icons[id])
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

private struct ProviderGaugeBlock: View {
    let gauge: StatusMenuContent.ProviderGauge
    let icon: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: MenuColumns.spacing) {
                iconView
                    .frame(width: MenuColumns.icon, height: MenuColumns.icon)
                Text(verbatim: gauge.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let status = gauge.status {
                    Text(verbatim: status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ForEach(gauge.windows) { window in
                HStack(spacing: MenuColumns.spacing) {
                    Text(verbatim: window.label)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: MenuColumns.label, alignment: .leading)
                    MeterBar(fraction: window.remaining, tint: MeterBar.remainingTint(window.remaining))
                    Text(verbatim: MetricFormat.shortPercent(window.remaining))
                        .font(.system(size: 12).monospacedDigit())
                        .lineLimit(1)
                        .frame(width: MenuColumns.value, alignment: .trailing)
                }
                .padding(.leading, MenuColumns.labelIndent)
                .frame(height: 16)
            }
            if let caption = gauge.caption {
                Text(verbatim: caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, MenuColumns.labelIndent)
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            // Template images (the Codex logo) follow the label color; pixel art (Clawd) keeps hard edges.
            Image(nsImage: icon)
                .renderingMode(icon.isTemplate ? .template : .original)
                .interpolation(icon.isTemplate ? .high : .none)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}

/// Rounded track with a filled share.
struct MeterBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let clamped = CGFloat(max(0, min(1, fraction)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if clamped > 0 {
                    Capsule().fill(tint)
                        .frame(width: max(geo.size.height, clamped * geo.size.width))
                }
            }
        }
        .frame(height: 6)
    }

    /// Used share: accent below 75%, orange from 75%, red from 90%.
    static func usageTint(_ used: Double) -> Color {
        used >= 0.9 ? .red : used >= 0.75 ? .orange : .accentColor
    }

    /// Battery charge: green above 20%, orange down to 10%, red below.
    static func chargeTint(_ charge: Double) -> Color {
        charge <= 0.1 ? .red : charge <= 0.2 ? .orange : .green
    }

    /// Remaining share: green above 30%, orange down to 10%, red below.
    static func remainingTint(_ left: Double) -> Color {
        left <= 0.1 ? .red : left <= 0.3 ? .orange : .green
    }
}

/// Recent CPU usage (percentages 0...100, oldest first) as a filled line graph.
struct HistoryGraph: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let points = Self.points(values, in: geo.size)
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                Path { path in
                    guard let first = points.first, let last = points.last else { return }
                    path.move(to: CGPoint(x: first.x, y: geo.size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(Color.accentColor.opacity(0.3))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }

    private static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count > 1, size.width > 0 else { return [] }
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let clamped = CGFloat(min(100, max(0, value)))
            return CGPoint(x: CGFloat(index) * step, y: size.height - 1 - (size.height - 2) * clamped / 100)
        }
    }
}
