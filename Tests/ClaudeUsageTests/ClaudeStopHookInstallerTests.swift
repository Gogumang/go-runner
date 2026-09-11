import Foundation
import GoRunnerCore
import XCTest
@testable import ClaudeUsage

final class ClaudeStopHookInstallerTests: XCTestCase {
    private var root: URL!
    private var installer: ClaudeStopHookInstaller!

    override func setUpWithError() throws {
        root = try makeTemporaryDirectory()
        // Same layout as the app ("…/GoRunner/bin"), so AgentEventLog.hookMarker matches the written command.
        let support = root.appendingPathComponent("Library/Application Support/GoRunner", isDirectory: true)
        installer = ClaudeStopHookInstaller(claudeSettingsURL: root.appendingPathComponent(".claude/settings.json"),
                                            binDirectory: support.appendingPathComponent("bin", isDirectory: true),
                                            backupsDirectory: support.appendingPathComponent("Backups", isDirectory: true),
                                            eventsFile: support.appendingPathComponent("Events/agent-events.jsonl"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures (shape of a real ~/.claude/settings.json, values replaced)

    private func group(_ command: String, matcher: String? = nil, timeout: Int = 10) -> [String: Any] {
        var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": timeout]]]
        if let matcher { group["matcher"] = matcher }
        return group
    }

    private var userHooks: [String: Any] {
        [
            "SessionStart": [group("~/.claude/hooks/session-start.sh")],
            "UserPromptSubmit": [group("~/.claude/hooks/prompt.sh")],
            "Stop": [group("afplay /System/Library/Sounds/Glass.aiff", timeout: 5), group("~/.claude/hooks/stop-log.sh")],
            "StopFailure": [group("~/.claude/hooks/stop-failure.sh")],
            "SubagentStop": [group("~/.claude/hooks/subagent-stop.sh")],
            "PreToolUse": [group("~/.claude/hooks/guard.sh", matcher: "Bash"), group("~/.claude/hooks/edit.sh", matcher: "Edit|Write")],
            "PostToolUse": [group("~/.claude/hooks/post.sh", matcher: "*")],
        ]
    }

    private func originalSettings(hooks: [String: Any]?) -> [String: Any] {
        var settings: [String: Any] = [
            "permissions": ["allow": ["Bash(ls:*)"], "deny": [String]()],
            "model": "opus",
            "statusLine": ["type": "command", "command": "'/Users/me/Library/Application Support/GoRunner/bin/claude-statusline.sh'",
                           "refreshInterval": 5],
            "enabledPlugins": ["claude-hud@claude-hud": true],
            "extraKnownMarketplaces": ["claude-hud": ["source": ["source": "github", "repo": "example/claude-hud"]]],
            "tui": ["compact": false],
            "skipDangerousModePermissionPrompt": true,
            "theme": "dark",
        ]
        if let hooks { settings["hooks"] = hooks }
        return settings
    }

    private var expectedGroup: [String: Any] {
        ["hooks": [["type": "command", "command": installer.hookCommand, "timeout": 10]]]
    }

    // MARK: Helpers

    private func writeSettings(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: prepareSettingsURL())
    }

    private func writeRaw(_ contents: String) throws {
        try Data(contents.utf8).write(to: prepareSettingsURL())
    }

    private func prepareSettingsURL() throws -> URL {
        try FileManager.default.createDirectory(at: installer.claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return installer.claudeSettingsURL
    }

    private func readSettings() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: installer.claudeSettingsURL)) as? [String: Any])
    }

    private func stopGroups() throws -> [[String: Any]] {
        let hooks = try XCTUnwrap(try readSettings()["hooks"] as? [String: Any])
        return try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
    }

    private func goRunnerCommands() throws -> [String] {
        try stopGroups().flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
            .filter { $0.contains(AgentEventLog.hookMarker) }
    }

    private func timestampedBackups() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: installer.backupsDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: installer.backupsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("claude-settings-") }
    }

    private func removing(_ key: String, from object: [String: Any]) -> [String: Any] {
        var copy = object
        copy.removeValue(forKey: key)
        return copy
    }

    private func assertEqualJSON(_ lhs: [String: Any], _ rhs: [String: Any], _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(NSDictionary(dictionary: lhs).isEqual(to: rhs), "\(message)\n\(lhs)\n!=\n\(rhs)", file: file, line: line)
    }

    /// Runs the command exactly as Claude Code does: through a shell, with the hook payload on stdin.
    private func runThroughShell(_ command: String, stdin input: String) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    // MARK: Install

    func testInstallAppendsGroupAndKeepsExistingHooks() throws {
        let original = originalSettings(hooks: userHooks)
        try writeSettings(original)
        let originalData = try Data(contentsOf: installer.claudeSettingsURL)
        XCTAssertFalse(installer.isInstalled)

        try installer.install()

        XCTAssertTrue(installer.isInstalled)
        let settings = try readSettings()
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let stop = try stopGroups()
        let originalStop = try XCTUnwrap(userHooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, originalStop.count + 1)
        for (index, existing) in originalStop.enumerated() {
            assertEqualJSON(stop[index], existing, "existing Stop group \(index) is unchanged and in place")
        }
        assertEqualJSON(try XCTUnwrap(stop.last), expectedGroup, "GoRunner group is appended last")

        XCTAssertEqual(installer.hookCommand, "'\(installer.binDirectory.path)/gorunner-agent-event' claude stop")
        XCTAssertTrue(installer.hookCommand.contains("Application Support/GoRunner/bin/gorunner-agent-event"))
        XCTAssertTrue(installer.hookCommand.contains(AgentEventLog.hookMarker))

        assertEqualJSON(removing("Stop", from: hooks), removing("Stop", from: userHooks), "other hook events are unchanged")
        assertEqualJSON(removing("hooks", from: settings), removing("hooks", from: original), "other keys are unchanged")
        assertEqualJSON(try XCTUnwrap(settings["statusLine"] as? [String: Any]),
                        try XCTUnwrap(original["statusLine"] as? [String: Any]), "statusLine is preserved")

        let backups = try timestampedBackups()
        XCTAssertEqual(backups.count, 1)
        XCTAssertNotNil(backups[0].lastPathComponent.range(of: #"^claude-settings-\d{8}-\d{6}\.json$"#, options: .regularExpression))
        XCTAssertEqual(try Data(contentsOf: backups[0]), originalData)

        let recorder = AgentEventLog.recorderURL(binDirectory: installer.binDirectory)
        let permissions = try FileManager.default.attributesOfItem(atPath: recorder.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o755)
        XCTAssertFalse(String(decoding: try Data(contentsOf: installer.claudeSettingsURL), as: UTF8.self).contains(#"\/"#),
                       "written without escaping slashes")
    }

    func testInstallTwiceAddsOneEntry() throws {
        try writeSettings(originalSettings(hooks: userHooks))
        try installer.install()
        let afterFirst = try Data(contentsOf: installer.claudeSettingsURL)

        try installer.install()

        XCTAssertEqual(try goRunnerCommands().count, 1)
        XCTAssertEqual(try stopGroups().count, 3)
        XCTAssertEqual(try Data(contentsOf: installer.claudeSettingsURL), afterFirst, "second install does not rewrite settings")
        XCTAssertEqual(try timestampedBackups().count, 1, "no backup when nothing changes")
    }

    func testInstallRecognizesExistingGoRunnerEntryFromAnotherLocation() throws {
        var hooks = userHooks
        hooks["Stop"] = [group("'/Users/other/Library/Application Support/GoRunner/bin/gorunner-agent-event' claude stop")]
        try writeSettings(originalSettings(hooks: hooks))
        let before = try Data(contentsOf: installer.claudeSettingsURL)

        try installer.install()

        XCTAssertTrue(installer.isInstalled)
        XCTAssertEqual(try Data(contentsOf: installer.claudeSettingsURL), before)
    }

    func testInstallWhenHooksMissing() throws {
        let original = originalSettings(hooks: nil)
        try writeSettings(original)

        try installer.install()

        let settings = try readSettings()
        assertEqualJSON(try XCTUnwrap(settings["hooks"] as? [String: Any]), ["Stop": [expectedGroup]])
        assertEqualJSON(removing("hooks", from: settings), original)
        XCTAssertEqual(try timestampedBackups().count, 1)

        try installer.uninstall()
        let restored = try readSettings()
        XCTAssertNil(restored["hooks"], "hooks created by GoRunner is removed again")
        assertEqualJSON(restored, original)
    }

    func testInstallWhenStopMissingKeepsOtherEvents() throws {
        let original = originalSettings(hooks: removing("Stop", from: userHooks))
        try writeSettings(original)

        try installer.install()

        let hooks = try XCTUnwrap(try readSettings()["hooks"] as? [String: Any])
        XCTAssertEqual(try stopGroups().count, 1)
        assertEqualJSON(removing("Stop", from: hooks), removing("Stop", from: userHooks))

        try installer.uninstall()
        let restored = try readSettings()
        XCTAssertNil((restored["hooks"] as? [String: Any])?["Stop"], "Stop created by GoRunner is removed again")
        assertEqualJSON(restored, original)
    }

    func testInstallWhenSettingsFileMissing() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.claudeSettingsURL.path))

        try installer.install()

        assertEqualJSON(try readSettings(), ["hooks": ["Stop": [expectedGroup]]])
        XCTAssertTrue(installer.isInstalled)
        XCTAssertEqual(try timestampedBackups().count, 0, "nothing to back up")

        try installer.uninstall()
        XCTAssertEqual(try readSettings().count, 0)
        XCTAssertFalse(installer.isInstalled)
    }

    func testBackupNameGetsSuffixOnCollision() throws {
        try writeSettings(originalSettings(hooks: userHooks))
        let now = Date()
        try installer.install(now: now)
        try installer.uninstall()
        try installer.install(now: now)

        let names = try timestampedBackups().map(\.lastPathComponent).sorted()
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.contains { $0.hasSuffix("-2.json") }, "\(names)")
    }

    // MARK: Uninstall

    func testUninstallRestoresPreviousValueExactly() throws {
        let original = originalSettings(hooks: userHooks)
        try writeSettings(original)
        try installer.install()
        try installer.install()

        try installer.uninstall()

        assertEqualJSON(try readSettings(), original)
        XCTAssertFalse(installer.isInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AgentEventLog.recorderURL(binDirectory: installer.binDirectory).path),
                      "recorder stays for Codex")

        let restored = try Data(contentsOf: installer.claudeSettingsURL)
        try installer.uninstall()
        XCTAssertEqual(try Data(contentsOf: installer.claudeSettingsURL), restored, "second uninstall is a no-op")
    }

    func testUninstallRemovesOnlyGoRunnerCommands() throws {
        try writeSettings(originalSettings(hooks: userHooks))
        try installer.install()

        // The user edits settings after installing: adds a command into GoRunner's group, a later group, and there is
        // a stale GoRunner entry from another install location plus an unrelated event that mentions the marker.
        var settings = try readSettings()
        var hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        var stop = try stopGroups()
        var goRunnerGroup = stop.removeLast()
        var entries = try XCTUnwrap(goRunnerGroup["hooks"] as? [[String: Any]])
        let foreign: [String: Any] = ["type": "command", "command": "say done"]
        entries.append(foreign)
        goRunnerGroup["hooks"] = entries
        stop.append(goRunnerGroup)
        let later: [String: Any] = ["matcher": "", "hooks": [["type": "command", "command": "echo later"]]]
        stop.append(later)
        stop.insert(group("'/Old Place/GoRunner/bin/gorunner-agent-event' claude stop"), at: 0)
        hooks["Stop"] = stop
        let subagentStop = [group("'/Old Place/GoRunner/bin/gorunner-agent-event' claude subagent-stop")]
        hooks["SubagentStop"] = subagentStop
        settings["hooks"] = hooks
        try writeSettings(settings)

        try installer.uninstall()

        let result = try readSettings()
        let resultHooks = try XCTUnwrap(result["hooks"] as? [String: Any])
        let originalStop = try XCTUnwrap(userHooks["Stop"] as? [[String: Any]])
        let expectedStop: [[String: Any]] = originalStop + [["hooks": [foreign]], later]
        let resultStop = try stopGroups()
        XCTAssertTrue(NSArray(array: resultStop).isEqual(to: expectedStop), "\(resultStop)")
        XCTAssertTrue(NSArray(array: try XCTUnwrap(resultHooks["SubagentStop"] as? [Any])).isEqual(to: subagentStop),
                      "only hooks.Stop is touched")
        assertEqualJSON(removing("Stop", from: removing("SubagentStop", from: resultHooks)),
                        removing("Stop", from: removing("SubagentStop", from: userHooks)))
        assertEqualJSON(removing("hooks", from: result), removing("hooks", from: settings))
        XCTAssertFalse(installer.isInstalled)
    }

    /// Builds from before the rename left entries under "RunAX"; the app removes them with that marker.
    func testHookMarkerRemovesOnlyEntriesWithThatMarker() throws {
        try writeSettings(originalSettings(hooks: userHooks))
        try installer.install()
        var settings = try readSettings()
        var hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        hooks["Stop"] = try stopGroups() + [group("'/Users/me/Library/Application Support/RunAX/bin/runax-agent-event' claude stop")]
        settings["hooks"] = hooks
        try writeSettings(settings)
        let runAXInstaller = ClaudeStopHookInstaller(claudeSettingsURL: installer.claudeSettingsURL,
                                                     binDirectory: installer.binDirectory,
                                                     backupsDirectory: installer.backupsDirectory,
                                                     eventsFile: installer.eventsFile,
                                                     hookMarker: "RunAX/bin/runax-agent-event")
        XCTAssertTrue(runAXInstaller.isInstalled)

        try runAXInstaller.uninstall()

        let remaining = try stopGroups()
        let userGroupCount = (userHooks["Stop"] as? [Any])?.count ?? 0
        XCTAssertFalse(runAXInstaller.isInstalled)
        XCTAssertFalse(String(describing: remaining).contains("runax-agent-event"), "\(remaining)")
        XCTAssertTrue(installer.isInstalled, "the GoRunner entry stays")
        XCTAssertEqual(try goRunnerCommands().count, 1)
        XCTAssertEqual(remaining.count, userGroupCount + 1, "user groups + GoRunner group: \(remaining)")
    }

    func testUninstallWithoutGoRunnerEntryLeavesFileUntouched() throws {
        try writeSettings(originalSettings(hooks: userHooks))
        let before = try Data(contentsOf: installer.claudeSettingsURL)
        try installer.uninstall()
        XCTAssertEqual(try Data(contentsOf: installer.claudeSettingsURL), before)
    }

    func testUninstallWithoutSettingsFileDoesNothing() throws {
        try installer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.claudeSettingsURL.path))
    }

    // MARK: Invalid settings

    func testInvalidJSONThrowsAndLeavesFileUntouched() throws {
        for contents in ["{ not json", "[1, 2]"] {
            try writeRaw(contents)
            XCTAssertThrowsError(try installer.install()) { error in
                XCTAssertEqual(error as? ClaudeStopHookError, .settingsNotJSONObject(installer.claudeSettingsURL.path))
                XCTAssertTrue(error.localizedDescription.contains(installer.claudeSettingsURL.path))
            }
            XCTAssertThrowsError(try installer.uninstall())
            XCTAssertEqual(try String(contentsOf: installer.claudeSettingsURL, encoding: .utf8), contents)
            XCTAssertFalse(installer.isInstalled)
        }
        XCTAssertEqual(try timestampedBackups().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AgentEventLog.recorderURL(binDirectory: installer.binDirectory).path),
                       "nothing is installed when settings are unreadable")
    }

    func testUnexpectedHooksShapeThrowsAndLeavesFileUntouched() throws {
        for (contents, key) in [(#"{"hooks": "nope"}"#, "hooks"), (#"{"hooks": {"Stop": {"hooks": []}}}"#, "hooks.Stop")] {
            try writeRaw(contents)
            XCTAssertThrowsError(try installer.install()) { error in
                XCTAssertEqual(error as? ClaudeStopHookError, .unexpectedShape(path: installer.claudeSettingsURL.path, key: key))
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
            try installer.uninstall()
            XCTAssertEqual(try String(contentsOf: installer.claudeSettingsURL, encoding: .utf8), contents)
            XCTAssertFalse(installer.isInstalled)
        }
        XCTAssertEqual(try timestampedBackups().count, 0)
    }

    // MARK: End to end (installed command actually executed)

    func testInstalledCommandRecordsProjectWithoutMessage() throws {
        try writeSettings(originalSettings(hooks: userHooks))
        try installer.install()
        let command = try XCTUnwrap(try goRunnerCommands().first)

        let payload = #"{"session_id":"abc123","transcript_path":"/Users/me/.claude/projects/-Users-me-Projects-My-App/abc123.jsonl","cwd":"/Users/me/Projects/My App","permission_mode":"default","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"SECRET-MESSAGE: all \"done\" in /Users/me/Elsewhere"}"#
        let before = Date()
        let result = try runThroughShell(command, stdin: payload)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        let contents = try String(contentsOf: installer.eventsFile, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 1, contents)
        let event = try XCTUnwrap(AgentEventLog.parse(line: String(lines[0])))
        XCTAssertEqual(event.provider, .claude)
        XCTAssertEqual(event.event, "stop")
        XCTAssertEqual(event.project, "My App")
        XCTAssertEqual(event.timestamp.timeIntervalSince1970, before.timeIntervalSince1970, accuracy: 5)
        for secret in ["SECRET", "done", "Elsewhere", "abc123", "transcript", "/Users/me"] {
            XCTAssertFalse(contents.contains(secret), "events file must not contain \(secret)")
        }
    }
}
