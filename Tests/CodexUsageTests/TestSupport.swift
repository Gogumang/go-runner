import Foundation
@testable import CodexUsage

enum Fixtures {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    }

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func lines(_ name: String) throws -> [Data] {
        let text = try String(contentsOf: url(name), encoding: .utf8)
        return text.split(separator: "\n").map { Data($0.utf8) }
    }
}

/// Temp directory removed in `tearDown`.
final class TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("gorunner-codex-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes an executable `/bin/sh` script and returns its path.
    func script(_ name: String, _ body: String) throws -> String {
        let file = url.appendingPathComponent(name)
        try body.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }
}

enum UTC {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ iso: String) -> Date {
        CodexResponseParser.iso8601(iso)!
    }
}

/// Polls until the process with `pid` no longer exists (Foundation reaps our children).
func waitForProcessExit(pid: Int32, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if kill(pid, 0) != 0, errno == ESRCH { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return kill(pid, 0) != 0 && errno == ESRCH
}
