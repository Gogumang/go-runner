import Foundation
import GoRunnerCore
import XCTest
@testable import CodexUsage

final class CodexNotifyInstallerTests: XCTestCase {
    private var tmp: TempDirectory!
    private var installer: CodexNotifyInstaller!

    override func setUpWithError() throws {
        tmp = try TempDirectory()
        // A space and a single quote in the support path exercise the shell quoting.
        let support = tmp.url.appendingPathComponent("Application Support/Run'AX", isDirectory: true)
        installer = CodexNotifyInstaller(codexConfigURL: tmp.url.appendingPathComponent("codex/config.toml"),
                                         binDirectory: support.appendingPathComponent("bin", isDirectory: true),
                                         backupsDirectory: support.appendingPathComponent("Backups", isDirectory: true),
                                         eventsFile: support.appendingPathComponent("agent-events.jsonl"))
    }

    override func tearDown() {
        tmp.remove()
    }

    // MARK: - Helpers

    private var wrapperURL: URL { installer.binDirectory.appendingPathComponent(installer.wrapperName) }
    private var previousBackupURL: URL { installer.backupsDirectory.appendingPathComponent(CodexNotifyInstaller.previousLineBackupName) }
    private var wrapperLine: String { "notify = [\"\(wrapperURL.path)\"]" }

    private func writeConfig(_ text: String) throws {
        try writeConfig(Data(text.utf8))
    }

    private func writeConfig(_ data: Data) throws {
        try FileManager.default.createDirectory(at: installer.codexConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: installer.codexConfigURL)
    }

    private func configData() throws -> Data { try Data(contentsOf: installer.codexConfigURL) }
    private func configText() throws -> String { String(decoding: try configData(), as: UTF8.self) }

    private func savedPreviousLine() throws -> Any? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: previousBackupURL)) as? [String: Any]
        return object?["line"]
    }

    private func fullBackups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: installer.backupsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("codex-config-") && $0.pathExtension == "toml" }
    }

    private func wrapperScript() throws -> String { try String(contentsOf: wrapperURL, encoding: .utf8) }

    private static let computerUse = "/Users/me/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"

    private static let userShapedRest = """
    model = "gpt-5-codex"
    model_reasoning_effort = "low"
    # 한국어 주석: keep me
    approval_policy = "never"
    sandbox_mode = "danger-full-access"

    [projects."/Users/me"]
    trust_level = "trusted"

    [profiles.work]
    notify = ["/usr/local/bin/other-notifier", "work"]

    """

    // MARK: - Round trips

    func testUserShapedConfigRoundTripIsByteIdentical() throws {
        let notify = "notify = [\"\(Self.computerUse)\", \"turn-ended\"]"
        let original = notify + "\n" + Self.userShapedRest
        try writeConfig(original)
        XCTAssertFalse(installer.isInstalled)

        try installer.install()

        XCTAssertTrue(installer.isInstalled)
        XCTAssertEqual(try configText(), wrapperLine + "\n" + Self.userShapedRest, "only the top-level notify line changes")
        XCTAssertEqual(try savedPreviousLine() as? String, notify)
        let backups = try fullBackups()
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), Data(original.utf8))
        XCTAssertTrue(backups[0].lastPathComponent.range(of: #"^codex-config-\d{8}-\d{6}\.toml$"#, options: .regularExpression) != nil)

        let permissions = try FileManager.default.attributesOfItem(atPath: wrapperURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o755)
        let script = try wrapperScript()
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("exec '\(Self.computerUse)' 'turn-ended' \"$@\"\n"), script)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AgentEventLog.recorderURL(binDirectory: installer.binDirectory).path))

        try installer.uninstall()

        XCTAssertEqual(try configData(), Data(original.utf8))
        XCTAssertFalse(installer.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrapperURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousBackupURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AgentEventLog.recorderURL(binDirectory: installer.binDirectory).path),
                      "the shared recorder is not ours to delete")
        XCTAssertEqual(try fullBackups().count, 1, "timestamped backups are kept")
    }

    func testMultiLineNotifyWithEscapesRoundTrip() throws {
        let notify = """
          notify = [
            "/opt/my tools/notify",   # program
            'C:\\literal\\path',
            "quote\\"d \\u00e9\\t",
          ] # trailing comment
        """
        let original = "# header comment\n" + notify + "\nmodel = \"o3\"\n\n[tui]\nnotifications = true\n"
        try writeConfig(original)

        try installer.install()

        XCTAssertEqual(try configText(), "# header comment\n" + wrapperLine + "\nmodel = \"o3\"\n\n[tui]\nnotifications = true\n")
        XCTAssertEqual(try savedPreviousLine() as? String, notify)
        let script = try wrapperScript()
        XCTAssertTrue(script.contains("exec '/opt/my tools/notify' 'C:\\literal\\path' 'quote\"d é\t' \"$@\"\n"), script)

        try installer.uninstall()
        XCTAssertEqual(try configData(), Data(original.utf8))
    }

    func testCRLFFileWithoutTrailingNewlineRoundTrip() throws {
        let original = "model = \"o3\"\r\nnotify = ['a', \"b\"]\r\n[projects.\"x\"]\r\ntrust_level = \"trusted\""
        try writeConfig(original)

        try installer.install()
        XCTAssertEqual(try configText(), "model = \"o3\"\r\n" + wrapperLine + "\r\n[projects.\"x\"]\r\ntrust_level = \"trusted\"")
        XCTAssertEqual(try savedPreviousLine() as? String, "notify = ['a', \"b\"]")

        try installer.uninstall()
        XCTAssertEqual(try configData(), Data(original.utf8))
    }

    func testTableNotifyAndMultiLineStringsAreNotMistakenForTopLevel() throws {
        let original = """
        instructions = \"\"\"
        [not a table]
        notify = ["fake"]
        \"\"\"
        literal = '''
        [also not a table]'''
        inline = { a = [1, 2], b = "}" }
        released = 1979-05-27 07:32:00Z
        notify = ["real"]

        [profiles.work]
        notify = ["inside-table"]

        """
        try writeConfig(original)

        try installer.install()

        let expected = original.replacingOccurrences(of: "notify = [\"real\"]", with: wrapperLine)
        XCTAssertEqual(try configText(), expected)
        XCTAssertTrue(try wrapperScript().contains("exec 'real' \"$@\""))
        try installer.uninstall()
        XCTAssertEqual(try configData(), Data(original.utf8))
    }

    // MARK: - Absent notify

    func testAbsentNotifyIsInsertedBeforeFirstTableAndRemovedOnUninstall() throws {
        let original = """
        model = "o3"
        # notify = ["commented-out"]

        # Projects trusted by Codex
        [projects."/Users/me"]
        trust_level = "trusted"

        """
        try writeConfig(original)

        try installer.install()

        XCTAssertEqual(try configText(), """
        model = "o3"
        # notify = ["commented-out"]

        \(wrapperLine)
        # Projects trusted by Codex
        [projects."/Users/me"]
        trust_level = "trusted"

        """)
        XCTAssertTrue(try savedPreviousLine() is NSNull)
        let script = try wrapperScript()
        XCTAssertTrue(script.hasSuffix("|| true\nexit 0\n"), script)
        XCTAssertTrue(installer.isInstalled)

        try installer.uninstall()
        XCTAssertEqual(try configData(), Data(original.utf8))
    }

    func testAbsentNotifyWithoutTablesIsAppended() throws {
        for original in ["model = \"o3\"\n", "model = \"o3\"", ""] {
            try writeConfig(original)
            try installer.install()
            let expected = original.isEmpty ? wrapperLine + "\n"
                : original.hasSuffix("\n") ? original + wrapperLine + "\n" : original + "\n" + wrapperLine
            XCTAssertEqual(try configText(), expected)
            try installer.uninstall()
            XCTAssertEqual(try configData(), Data(original.utf8), "round trip for \(original.debugDescription)")
        }
    }

    func testMissingConfigIsCreated() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.codexConfigURL.path))

        try installer.install()

        XCTAssertEqual(try configText(), wrapperLine + "\n")
        XCTAssertTrue(try savedPreviousLine() is NSNull)
        XCTAssertEqual(try fullBackups().count, 0)
        XCTAssertTrue(installer.isInstalled)

        try installer.uninstall()
        XCTAssertEqual(try configText(), "")
        XCTAssertFalse(installer.isInstalled)
    }

    // MARK: - Idempotence and errors

    func testInstallingTwiceKeepsOriginalBackup() throws {
        let notify = "notify = [\"\(Self.computerUse)\", \"turn-ended\"]"
        let original = notify + "\n" + Self.userShapedRest
        try writeConfig(original)

        try installer.install()
        let afterFirst = try configData()
        try installer.install()

        XCTAssertEqual(try configData(), afterFirst)
        XCTAssertEqual(try savedPreviousLine() as? String, notify)
        XCTAssertEqual(try fullBackups().count, 1, "an unchanged config is not backed up again")
        XCTAssertTrue(try wrapperScript().contains("exec '\(Self.computerUse)' 'turn-ended' \"$@\""))
        XCTAssertEqual(try configText().components(separatedBy: "gorunner-codex-notify").count, 2)

        try installer.uninstall()
        XCTAssertEqual(try configData(), Data(original.utf8))
    }

    func testUnparsableConfigIsLeftUntouched() throws {
        let cases = [
            "notify = \"just a string\"\n",
            "notify = [\"a\", 1]\n",
            "notify = [\"unterminated]\n",
            "notify = ['a'\n[table]\n",
            "notify = [\"\"\"multi\"\"\"]\n",
            "notify = [\"bad \\q escape\"]\n",
            "model = \n[t]\n",
        ]
        for text in cases {
            try writeConfig(text)
            XCTAssertThrowsError(try installer.install(), text) { error in
                XCTAssertTrue(error is CodexNotifyInstallerError, "\(error)")
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
            XCTAssertEqual(try configData(), Data(text.utf8), text)
            XCTAssertFalse(FileManager.default.fileExists(atPath: wrapperURL.path), text)
            XCTAssertFalse(FileManager.default.fileExists(atPath: previousBackupURL.path), text)
            XCTAssertFalse(installer.isInstalled)
        }
    }

    func testUninstallLeavesConfigAloneWhenNotifyWasChangedByUser() throws {
        try writeConfig("notify = [\"a\"]\n")
        try installer.install()
        try writeConfig("notify = [\"user-changed\"]\n")

        try installer.uninstall()

        XCTAssertEqual(try configText(), "notify = [\"user-changed\"]\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrapperURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousBackupURL.path))
    }

    /// Builds from before the rename pointed notify at "runax-codex-notify"; the app removes it with that name.
    func testWrapperNameTellsGoRunnerWrapperFromRunAXWrapper() throws {
        try writeConfig("model = \"o3\"\nnotify = [\"terminal-notifier\"]\n")
        // Its own folders, as on a real Mac: the two installs never share a notify backup.
        let runAXSupport = tmp.url.appendingPathComponent("Application Support/RunAX", isDirectory: true)
        let runAXInstaller = CodexNotifyInstaller(codexConfigURL: installer.codexConfigURL,
                                                  binDirectory: runAXSupport.appendingPathComponent("bin", isDirectory: true),
                                                  backupsDirectory: runAXSupport.appendingPathComponent("Backups", isDirectory: true),
                                                  eventsFile: runAXSupport.appendingPathComponent("agent-events.jsonl"),
                                                  wrapperName: "runax-codex-notify")
        try runAXInstaller.install()
        let installedByRunAX = try configText()

        try installer.uninstall()

        XCTAssertFalse(installer.isInstalled, "the GoRunner wrapper name must not claim the RunAX wrapper")
        XCTAssertEqual(try configText(), installedByRunAX, "GoRunner uninstall leaves the RunAX line alone")
        XCTAssertTrue(runAXInstaller.isInstalled)

        try runAXInstaller.uninstall()

        XCTAssertEqual(try configText(), "model = \"o3\"\nnotify = [\"terminal-notifier\"]\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runAXInstaller.binDirectory.appendingPathComponent("runax-codex-notify").path))
    }

    func testParseStringArray() throws {
        func parse(_ text: String) throws -> [String] {
            let bytes = Array(text.utf8)
            return try CodexConfigTOML.parseStringArray(bytes, range: 0..<bytes.count)
        }
        XCTAssertEqual(try parse("[]"), [])
        XCTAssertEqual(try parse("[ \"a\" , 'b\\n' , ]"), ["a", "b\\n"])
        XCTAssertEqual(try parse("[\"\\u00E9\\U0001F600\\\\\"]"), ["é😀\\"])
        XCTAssertThrowsError(try parse("[\"a\" \"b\"]"))
        XCTAssertThrowsError(try parse("[[\"a\"]]"))
    }

    // MARK: - Wrapper end to end

    func testWrapperRecordsEventAndExecsPreviousProgram() throws {
        let argvFile = tmp.url.appendingPathComponent("previous-argv.txt")
        let previous = try tmp.script("previous notify.sh", """
        #!/bin/sh
        : > \(AgentEventLog.shellSingleQuoted(argvFile.path))
        for arg; do printf '%s\\n' "$arg" >> \(AgentEventLog.shellSingleQuoted(argvFile.path)); done
        exit 7

        """)
        try writeConfig("notify = [\"\(previous)\", \"turn-ended\", \"it's quoted\"]\n\n[projects.\"/x\"]\ntrust_level = \"trusted\"\n")
        try installer.install()

        let payload = #"{"type":"agent-turn-complete","thread-id":"t-1","turn-id":"42","cwd":"/Users/me/Projects/my-app","client":"codex-tui","input-messages":["SECRET-PROMPT"],"last-assistant-message":"SECRET-ASSISTANT-MESSAGE"}"#
        let status = try run(wrapperURL, arguments: [payload])

        XCTAssertEqual(status, 7, "wrapper exits with the previous program's status")
        let receivedArgs = try String(contentsOf: argvFile, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(receivedArgs, ["turn-ended", "it's quoted", payload, ""])

        let events = try String(contentsOf: installer.eventsFile, encoding: .utf8)
        let lines = events.split(separator: "\n")
        XCTAssertEqual(lines.count, 1, events)
        XCTAssertFalse(events.contains("SECRET"), events)
        let event = try XCTUnwrap(AgentEventLog.parse(line: String(lines[0])))
        XCTAssertEqual(event.provider, .codex)
        XCTAssertEqual(event.event, "turn-complete")
        XCTAssertEqual(event.project, "my-app")
    }

    func testWrapperWithoutPreviousProgramExitsZero() throws {
        try writeConfig("model = \"o3\"\n")
        try installer.install()

        let status = try run(wrapperURL, arguments: [#"{"type":"agent-turn-complete","cwd":"/tmp/solo"}"#])

        XCTAssertEqual(status, 0)
        let event = try XCTUnwrap(AgentEventLog.parse(line: String(contentsOf: installer.eventsFile, encoding: .utf8)))
        XCTAssertEqual(event.project, "solo")
    }

    private func run(_ executable: URL, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
