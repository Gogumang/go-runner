import Foundation
import GoRunnerCore
import XCTest
@testable import ClaudeUsage

final class StatuslineInstallerTests: XCTestCase {
    private var root: URL!
    private var installer: ClaudeStatuslineInstaller!

    override func setUpWithError() throws {
        root = try makeTemporaryDirectory()
        installer = makeInstaller(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private let previousStatusLine: [String: Any] = [
        "type": "command",
        "command": #"bash -c 'plugin_dir=$(ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/*/claude-hud/*/); exec bun "${plugin_dir}src/index.ts"'"#,
        "refreshInterval": 5,
        "padding": 1,
    ]

    private func originalSettings(statusLine: Any?) -> [String: Any] {
        var settings: [String: Any] = [
            "model": "opus",
            "theme": "dark",
            "permissions": ["allow": ["Bash(ls:*)"], "deny": [String]()],
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff"]]]]],
            "enabledPlugins": ["claude-hud@claude-hud": true],
            "skipDangerousModePermissionPrompt": true,
        ]
        if let statusLine { settings["statusLine"] = statusLine }
        return settings
    }

    private func writeSettings(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: installer.claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: installer.claudeSettingsURL)
    }

    private func readSettings() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: installer.claudeSettingsURL)) as? [String: Any])
    }

    private func timestampedBackups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: installer.backupsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("claude-settings-") }
    }

    private func runHook(input: String) throws -> (status: Int32, stdout: String) {
        // Run the command exactly as Claude Code would: through a shell, using the settings value.
        let command = try XCTUnwrap(StatuslineInstallation.command(in: try readSettings()))
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

    private let samplePayload = #"{"session_id":"abc","model":{"id":"claude-opus-5","display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/it's a dir"},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":4102444800},"seven_day":{"used_percentage":41.2,"resets_at":4102444800}}}"#

    // MARK: Install / uninstall

    func testInstallChainsPreviousStatusLineAndPreservesOtherKeys() throws {
        let original = originalSettings(statusLine: previousStatusLine)
        try writeSettings(original)
        let originalData = try Data(contentsOf: installer.claudeSettingsURL)
        XCTAssertFalse(installer.isInstalled)

        try installer.install()

        let settings = try readSettings()
        let statusLine = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertEqual(statusLine["command"] as? String, "'\(installer.hookScriptURL.path)'")
        XCTAssertTrue((statusLine["command"] as? String ?? "").contains("Application Support/GoRunner/bin/claude-statusline.sh"))
        XCTAssertEqual(statusLine["refreshInterval"] as? Int, 5)
        XCTAssertEqual(statusLine["padding"] as? Int, 1)
        XCTAssertTrue(installer.isInstalled)

        var others = settings
        others.removeValue(forKey: "statusLine")
        var originalOthers = original
        originalOthers.removeValue(forKey: "statusLine")
        XCTAssertTrue(NSDictionary(dictionary: others).isEqual(to: originalOthers))

        let backup = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: installer.previousStatusLineBackupURL)) as? [String: Any])
        XCTAssertEqual(installer.previousStatusLineBackupURL.lastPathComponent, "claude-statusline-previous.json")
        XCTAssertTrue(NSDictionary(dictionary: backup).isEqual(to: previousStatusLine))
        XCTAssertEqual(try String(contentsOf: installer.previousCommandURL, encoding: .utf8), previousStatusLine["command"] as? String)

        let backups = try timestampedBackups()
        XCTAssertEqual(backups.count, 1)
        XCTAssertNotNil(backups[0].lastPathComponent.range(of: #"^claude-settings-\d{8}-\d{6}\.json$"#, options: .regularExpression))
        XCTAssertEqual(try Data(contentsOf: backups[0]), originalData)

        let permissions = try FileManager.default.attributesOfItem(atPath: installer.hookScriptURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o755)
        XCTAssertFalse(String(decoding: try Data(contentsOf: installer.claudeSettingsURL), as: UTF8.self).contains(#"\/"#),
                       "written without escaping slashes")
    }

    func testInstallTwiceKeepsOriginalBackup() throws {
        try writeSettings(originalSettings(statusLine: previousStatusLine))
        try installer.install()
        let backupData = try Data(contentsOf: installer.previousStatusLineBackupURL)
        let commandData = try Data(contentsOf: installer.previousCommandURL)

        try installer.install()

        XCTAssertEqual(try Data(contentsOf: installer.previousStatusLineBackupURL), backupData)
        XCTAssertEqual(try Data(contentsOf: installer.previousCommandURL), commandData)
        let statusLine = try XCTUnwrap(try readSettings()["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "'\(installer.hookScriptURL.path)'")
        XCTAssertEqual(statusLine["refreshInterval"] as? Int, 5)
        XCTAssertEqual(try timestampedBackups().count, 2, "each install keeps its own full backup")
    }

    func testUninstallRestoresExactly() throws {
        let original = originalSettings(statusLine: previousStatusLine)
        try writeSettings(original)
        try installer.install()
        try installer.install()
        try Data("{}".utf8).write(to: installer.statuslineFile)

        try installer.uninstall()

        XCTAssertTrue(NSDictionary(dictionary: try readSettings()).isEqual(to: original))
        XCTAssertFalse(installer.isInstalled)
        for url in [installer.hookScriptURL, installer.previousCommandURL, installer.statuslineFile] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }
        XCTAssertEqual(try timestampedBackups().count, 2, "timestamped backups are kept")

        let restored = try Data(contentsOf: installer.claudeSettingsURL)
        try installer.uninstall()
        XCTAssertEqual(try Data(contentsOf: installer.claudeSettingsURL), restored, "second uninstall is a no-op")
    }

    func testInstallAndUninstallWithoutPreviousStatusLine() throws {
        let original = originalSettings(statusLine: nil)
        try writeSettings(original)

        try installer.install()
        XCTAssertEqual(try String(contentsOf: installer.previousStatusLineBackupURL, encoding: .utf8), "null")
        XCTAssertEqual(try String(contentsOf: installer.previousCommandURL, encoding: .utf8), "")
        let statusLine = try XCTUnwrap(try readSettings()["statusLine"] as? [String: Any])
        XCTAssertEqual(Set(statusLine.keys), ["type", "command"])

        try installer.uninstall()
        let restored = try readSettings()
        XCTAssertNil(restored["statusLine"])
        XCTAssertTrue(NSDictionary(dictionary: restored).isEqual(to: original))
    }

    func testInstallWithoutSettingsFile() throws {
        try installer.install()
        XCTAssertTrue(installer.isInstalled)
        XCTAssertEqual(try timestampedBackups().count, 0, "nothing to back up")
        try installer.uninstall()
        XCTAssertEqual(try readSettings().count, 0)
    }

    func testUninstallLeavesForeignStatusLineAlone() throws {
        try writeSettings(originalSettings(statusLine: previousStatusLine))
        let before = try Data(contentsOf: installer.claudeSettingsURL)
        try installer.uninstall()
        XCTAssertEqual(try Data(contentsOf: installer.claudeSettingsURL), before)
    }

    /// Builds from before the rename installed their hook under "RunAX"; the app removes it with that marker.
    func testCommandMarkerTellsGoRunnerHookFromRunAXHook() throws {
        let original = originalSettings(statusLine: previousStatusLine)
        try writeSettings(original)
        let runAXSupport = root.appendingPathComponent("Library/Application Support/RunAX", isDirectory: true)
        let runAXInstaller = ClaudeStatuslineInstaller(claudeSettingsURL: installer.claudeSettingsURL,
                                                       binDirectory: runAXSupport.appendingPathComponent("bin", isDirectory: true),
                                                       backupsDirectory: runAXSupport.appendingPathComponent("Backups", isDirectory: true),
                                                       statuslineFile: runAXSupport.appendingPathComponent("claude-statusline.json"),
                                                       commandMarker: "RunAX/bin/claude-statusline")
        try runAXInstaller.install()
        let installedByRunAX = try Data(contentsOf: installer.claudeSettingsURL)

        try installer.uninstall()

        XCTAssertFalse(installer.isInstalled, "the GoRunner marker must not claim the RunAX hook")
        XCTAssertEqual(try Data(contentsOf: installer.claudeSettingsURL), installedByRunAX, "GoRunner uninstall leaves it alone")
        XCTAssertTrue(runAXInstaller.isInstalled)

        try runAXInstaller.uninstall()

        let restored = try readSettings()
        XCTAssertTrue(NSDictionary(dictionary: restored).isEqual(to: original), "\(restored)")
    }

    func testRefusesToOverwriteInvalidSettings() throws {
        try FileManager.default.createDirectory(at: installer.claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: installer.claudeSettingsURL)
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try String(contentsOf: installer.claudeSettingsURL, encoding: .utf8), "{ not json")
        XCTAssertFalse(installer.isInstalled)
    }

    // MARK: Hook script (actually executed)

    func testHookScriptRecordsPayloadAndChainsPreviousCommand() throws {
        try writeSettings(originalSettings(statusLine: ["type": "command", "command": "cat >/dev/null; echo PREV-OK"]))
        try installer.install()

        let before = Date()
        let result = try runHook(input: samplePayload)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "PREV-OK\n")

        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: installer.statuslineFile)) as? [String: Any])
        let receivedAt = try XCTUnwrap(written["receivedAt"] as? NSNumber).doubleValue
        XCTAssertEqual(receivedAt, before.timeIntervalSince1970, accuracy: 5)
        let payload = try XCTUnwrap(written["payload"] as? [String: Any])
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(samplePayload.utf8)) as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: payload).isEqual(to: expected))

        let folder = installer.statuslineFile.deletingLastPathComponent().path
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".tmp") }, [])

        let outcome = ClaudeStatuslineSource.read(fileURL: installer.statuslineFile, hookInstalled: installer.isInstalled, now: Date())
        XCTAssertEqual(outcome.result?.windows.map(\.id), ["five_hour", "seven_day"])
    }

    func testHookPassesIdenticalInputToPreviousCommand() throws {
        try writeSettings(originalSettings(statusLine: ["type": "command", "command": "cat"]))
        try installer.install()
        let result = try runHook(input: samplePayload)
        XCTAssertEqual(result.stdout, samplePayload + "\n")
    }

    func testHookPropagatesPreviousExitStatus() throws {
        try writeSettings(originalSettings(statusLine: ["type": "command", "command": "cat >/dev/null; echo X; exit 3"]))
        try installer.install()
        let result = try runHook(input: samplePayload)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout, "X\n")
    }

    func testHookWithoutPreviousCommandPrintsNothing() throws {
        try writeSettings(originalSettings(statusLine: nil))
        try installer.install()
        let result = try runHook(input: samplePayload)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.statuslineFile.path))
    }

    func testHookSurvivesMissingDataFolderAndEmptyInput() throws {
        let dataFolder = root.appendingPathComponent("Data Folder", isDirectory: true)
        installer = makeInstaller(root: root, statuslineDirectory: dataFolder)
        try writeSettings(originalSettings(statusLine: ["type": "command", "command": "cat >/dev/null; echo PREV-OK"]))
        try installer.install()
        try FileManager.default.removeItem(at: dataFolder)

        let result = try runHook(input: samplePayload)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "PREV-OK\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataFolder.path), "does not recreate GoRunner folders")

        try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        let empty = try runHook(input: "")
        XCTAssertEqual(empty.stdout, "PREV-OK\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.statuslineFile.path), "empty input is not recorded")
    }
}
