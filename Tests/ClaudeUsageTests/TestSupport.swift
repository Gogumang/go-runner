import Foundation
import GoRunnerCore
@testable import ClaudeUsage

enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
}

/// Temp folder whose name contains spaces (like "Application Support").
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("GoRunner ClaudeUsageTests \(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeInstaller(root: URL, statuslineDirectory: URL? = nil) -> ClaudeStatuslineInstaller {
    let support = root.appendingPathComponent("Library/Application Support/GoRunner", isDirectory: true)
    return ClaudeStatuslineInstaller(claudeSettingsURL: root.appendingPathComponent(".claude/settings.json"),
                                     binDirectory: support.appendingPathComponent("bin", isDirectory: true),
                                     backupsDirectory: support.appendingPathComponent("Backups", isDirectory: true),
                                     statuslineFile: (statuslineDirectory ?? support).appendingPathComponent("claude-statusline.json"))
}

func utcDate(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: iso) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso)!
}

var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var count: Int { lock.withLock { requests.count } }
    var lastRequest: URLRequest? { lock.withLock { requests.last } }

    func record(_ request: URLRequest) { lock.withLock { requests.append(request) } }
}

/// OAuth client with an injected credential and a fake transport (no Keychain, no network).
func makeOAuthClient(credential: Data?, status: Int = 200, body: Data = Data(), recorder: CallRecorder,
                     delay: TimeInterval = 0) -> ClaudeOAuthClient {
    ClaudeOAuthClient(
        loadCredential: {
            guard let credential else { return .failure(ProviderError(kind: .authMissing, message: "no credential")) }
            return .success(credential)
        },
        transport: { request in
            recorder.record(request)
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            let response = HTTPURLResponse(url: ClaudeOAuthClient.usageURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (body, response)
        },
        appVersion: "9.9.9")
}

func makeEntry(_ iso: String, model: String = "claude-opus-5", input: Int = 1, output: Int = 1,
               id: String? = nil, request: String? = nil) -> ClaudeUsageEntry {
    ClaudeUsageEntry(timestamp: utcDate(iso), model: model, inputTokens: input, outputTokens: output,
                     cacheCreationTokens: 0, cacheCreation1hTokens: 0, cacheReadTokens: 0, isFastMode: false,
                     messageID: id, requestID: request)
}
