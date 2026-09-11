import Foundation

/// Tiny ko/en switch. GoRunner is Korean-first; any non-Korean preferred language gets English.
public enum Loc {
    public static var isKorean: Bool {
        (Locale.preferredLanguages.first ?? "").hasPrefix("ko")
    }

    public static func t(_ ko: String, _ en: String) -> String {
        isKorean ? ko : en
    }
}

/// Display formats shared by the status menu, the menu bar text and the smoke test.
public enum MetricFormat {
    /// SystemInfoKit style: `"%4.1f%%"` of a 0...1 fraction, e.g. `" 7.5%"`.
    public static func percent(_ fraction: Double, width: Int = 4) -> String {
        let value = (fraction * 1000).rounded() / 10
        return String(format: "%\(width).1f%%", value)
    }

    /// Compact percent without padding, e.g. `"42%"`.
    public static func shortPercent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Decimal units like SystemInfoKit's MeasurementFormatter output: `"6.4 GB"`, `"50.7 kB"`.
    public static func bytes(_ count: Double) -> String {
        let units = ["B", "kB", "MB", "GB", "TB", "PB"]
        var value = max(0, count)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return index == 0 ? "\(Int(value)) B" : String(format: "%.1f %@", value, units[index])
    }

    public static func usd(_ amount: Double) -> String {
        String(format: amount < 10 ? "$%.2f" : "$%.1f", amount)
    }

    public static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: "\(count)"
        case ..<1_000_000: String(format: "%.1fK", Double(count) / 1_000)
        case ..<1_000_000_000: String(format: "%.1fM", Double(count) / 1_000_000)
        default: String(format: "%.2fB", Double(count) / 1_000_000_000)
        }
    }

    /// Reset time for quota windows.
    /// Under 24 h: `"1시간 12분 후"` / `"in 1h 12m"`. Otherwise: `"9월 15일 14:30"` / `"Sep 15 14:30"`.
    public static func resetDescription(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return Loc.t("곧 리셋", "resetting") }
        if seconds < 24 * 3600 {
            let totalMinutes = Int((seconds / 60).rounded(.up))
            let h = totalMinutes / 60
            let m = totalMinutes % 60
            if h == 0 { return Loc.t("\(m)분 후", "in \(m)m") }
            return Loc.t("\(h)시간 \(m)분 후", "in \(h)h \(m)m")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Loc.isKorean ? "ko_KR" : "en_US")
        formatter.dateFormat = Loc.isKorean ? "M월 d일 HH:mm" : "MMM d HH:mm"
        return formatter.string(from: date)
    }

    /// `"방금"`, `"3분 전"`, `"2시간 전"` / `"just now"`, `"3m ago"`, `"2h ago"`.
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return Loc.t("방금", "just now") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return Loc.t("\(minutes)분 전", "\(minutes)m ago") }
        let hours = minutes / 60
        if hours < 48 { return Loc.t("\(hours)시간 전", "\(hours)h ago") }
        return Loc.t("\(hours / 24)일 전", "\(hours / 24)d ago")
    }
}
