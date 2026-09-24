import Foundation
import GoRunnerCore

/// What the menu's 어드민 section shows. "Connected" means this Mac's heartbeats are reaching the collector, which is
/// exactly what keeps the admin's device session alive; the browser tab itself is invisible to go-runner.
public enum AdminConnection: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(lastSignalAt: Date)
    /// The last heartbeat failed. The collector drops the session after 3 minutes without one, so this is a warning,
    /// not yet a disconnect.
    case unstable(lastSignalAt: Date, reason: String)

    public enum Tone: Sendable { case neutral, pending, good, bad }

    public var tone: Tone {
        switch self {
        case .disconnected: .neutral
        case .connecting: .pending
        case .connected: .good
        case .unstable: .bad
        }
    }

    public var isConnected: Bool {
        if case .disconnected = self { return false }
        if case .connecting = self { return false }
        return true
    }

    /// Menu row title, e.g. "연결됨 · 방금 신호".
    public func title(now: Date) -> String {
        switch self {
        case .disconnected:
            Loc.t("연결 안 됨 · 연결하기", "Not connected · Connect")
        case .connecting:
            Loc.t("연결 중…", "Connecting…")
        case .connected(let lastSignalAt):
            Loc.t("연결됨 · \(Self.elapsed(since: lastSignalAt, now: now)) 신호", "Connected · signal \(Self.elapsedEnglish(since: lastSignalAt, now: now))")
        case .unstable(let lastSignalAt, _):
            Loc.t("연결 불안정 · \(Self.elapsed(since: lastSignalAt, now: now)) 마지막 신호 · 다시 연결",
                  "Unstable · last signal \(Self.elapsedEnglish(since: lastSignalAt, now: now)) · Reconnect")
        }
    }

    static func elapsed(since date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        return minutes == 0 ? "방금" : "\(minutes)분 전"
    }

    static func elapsedEnglish(since date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        return minutes == 0 ? "just now" : "\(minutes)m ago"
    }
}
