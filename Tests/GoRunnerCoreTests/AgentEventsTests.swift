import XCTest
@testable import GoRunnerCore

final class AgentEventsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("gorunner-agent-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testParseLine() {
        let event = AgentEventLog.parse(line: #"{"provider":"codex","event":"turn-complete","project":"gorunner","timestamp":1789108699}"#)
        XCTAssertEqual(event?.provider, .codex)
        XCTAssertEqual(event?.event, "turn-complete")
        XCTAssertEqual(event?.project, "gorunner")
        XCTAssertEqual(event?.timestamp, Date(timeIntervalSince1970: 1_789_108_699))
        XCTAssertNil(AgentEventLog.parse(line: "not json"))
        XCTAssertNil(AgentEventLog.parse(line: #"{"provider":"other","event":"x"}"#))
        XCTAssertNil(AgentEventLog.parse(line: #"{"provider":"claude","event":"stop","project":""}"#)?.project)
    }

    func testRecorderWritesOnlyProjectNameFromStdinAndArgument() throws {
        let bin = tempDir.appendingPathComponent("bin with space")
        let events = tempDir.appendingPathComponent("Application Support/agent-events.jsonl")
        let recorder = try AgentEventLog.installRecorder(binDirectory: bin, eventsFile: events)

        // Claude: payload on stdin, including content that must not be recorded.
        let claudePayload = #"{"session_id":"s1","transcript_path":"/Users/me/.claude/t.jsonl","cwd":"/Users/me/Desktop/code/gorunner","last_assistant_message":"SECRET"}"#
        try run(recorder, arguments: ["claude", "stop"], stdin: claudePayload)
        // Codex: payload as the last argument.
        let codexPayload = #"{"type":"agent-turn-complete","cwd":"/Users/me/work/my \"app\"","last-assistant-message":"SECRET"}"#
        try run(recorder, arguments: ["codex", "turn-complete", codexPayload], stdin: nil)

        let text = try String(contentsOf: events, encoding: .utf8)
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertFalse(text.contains("transcript"))
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(AgentEventLog.parse(line: lines[0])?.provider, .claude)
        XCTAssertEqual(AgentEventLog.parse(line: lines[0])?.project, "gorunner")
        XCTAssertEqual(AgentEventLog.parse(line: lines[1])?.provider, .codex)
        XCTAssertNotNil(AgentEventLog.parse(line: lines[1]))
    }

    func testRecorderExitsQuietlyWhenDataFolderIsMissing() throws {
        let bin = tempDir.appendingPathComponent("bin")
        let events = tempDir.appendingPathComponent("gone/agent-events.jsonl")
        let recorder = try AgentEventLog.installRecorder(binDirectory: bin, eventsFile: events)
        try FileManager.default.removeItem(at: events.deletingLastPathComponent())
        let status = try run(recorder, arguments: ["claude", "stop"], stdin: "{}")
        XCTAssertEqual(status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: events.path))
    }

    @discardableResult
    private func run(_ script: URL, arguments: [String], stdin: String?) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path] + arguments
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
