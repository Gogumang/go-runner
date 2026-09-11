import ClaudeUsage
import CodexUsage
import Foundation
import GoRunnerCore

extension AgentKind {
    /// Name of the tool the hook goes into.
    var toolName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// Claude Code's Stop hook and Codex's notify program behind one API, plus tool detection.
struct AgentHooks: Sendable {
    struct Status: Sendable, Equatable {
        var present: Bool
        var installed: Bool
    }

    var claude: ClaudeStopHookInstaller
    var codex: CodexNotifyInstaller
    /// Sandboxed instances only look at their fake config folders, never the real PATH.
    var usesExecutableLookup = true

    static let standard = AgentHooks(claude: .standard, codex: .standard)

    /// Debug only (`--agent-hooks-root=<dir>`): every file lives under `root` — `root/.claude/settings.json`,
    /// `root/.codex/config.toml` and `root/Library/Application Support/GoRunner/…` — so the headless flags can be
    /// exercised without touching the real home folder (Foundation ignores `$HOME`).
    static func sandboxed(root: URL) -> AgentHooks {
        let support = root.appendingPathComponent("Library/Application Support/GoRunner", isDirectory: true)
        let bin = support.appendingPathComponent("bin", isDirectory: true)
        let backups = support.appendingPathComponent("Backups", isDirectory: true)
        let events = support.appendingPathComponent("agent-events.jsonl")
        return AgentHooks(
            claude: ClaudeStopHookInstaller(claudeSettingsURL: root.appendingPathComponent(".claude/settings.json"),
                                            binDirectory: bin, backupsDirectory: backups, eventsFile: events),
            codex: CodexNotifyInstaller(codexConfigURL: root.appendingPathComponent(".codex/config.toml"),
                                        binDirectory: bin, backupsDirectory: backups, eventsFile: events),
            usesExecutableLookup: false)
    }

    /// `~/.claude`, or `$CODEX_HOME` / `~/.codex`.
    func configDirectory(_ kind: AgentKind) -> URL {
        switch kind {
        case .claude: claude.claudeSettingsURL.deletingLastPathComponent()
        case .codex: codex.codexConfigURL.deletingLastPathComponent()
        }
    }

    /// The tool's config folder exists or its CLI is on the login-shell PATH. May run the login shell once (≤ 4 s),
    /// so call it off the main thread from UI code.
    func isToolPresent(_ kind: AgentKind) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: configDirectory(kind).path, isDirectory: &isDirectory), isDirectory.boolValue {
            return true
        }
        return usesExecutableLookup && ExecutableLocator.locate(kind.rawValue) != nil
    }

    func isInstalled(_ kind: AgentKind) -> Bool {
        switch kind {
        case .claude: claude.isInstalled
        case .codex: codex.isInstalled
        }
    }

    func status(_ kind: AgentKind) -> Status {
        Status(present: isToolPresent(kind), installed: isInstalled(kind))
    }

    /// Installs and verifies: throws `AgentHookError.notDetected` when the installer returned but the hook isn't there.
    func install(_ kind: AgentKind) throws {
        switch kind {
        case .claude: try claude.install()
        case .codex: try codex.install()
        }
        guard isInstalled(kind) else { throw AgentHookError.notDetected(kind) }
    }

    func uninstall(_ kind: AgentKind) throws {
        switch kind {
        case .claude: try claude.uninstall()
        case .codex: try codex.uninstall()
        }
    }

    static func setEnabled(_ enabled: Bool, for kind: AgentKind, in settings: inout AppSettings) {
        switch kind {
        case .claude: settings.notifyOnClaudeFinish = enabled
        case .codex: settings.notifyOnCodexFinish = enabled
        }
    }

    /// Launch consistency: a toggle that is on while its hook is gone (e.g. removed by hand) is turned off.
    /// Never reinstalls silently.
    @MainActor
    func reconcile(_ store: SettingsStore) {
        for kind in AgentKind.allCases where AgentNotifier.isEnabled(kind, in: store.settings) && !isInstalled(kind) {
            Log.app.notice("\(kind.rawValue, privacy: .public) finish hook is missing; turning its notification off")
            Self.setEnabled(false, for: kind, in: &store.settings)
        }
    }
}

enum AgentHookError: LocalizedError {
    case notDetected(AgentKind)

    var errorDescription: String? {
        switch self {
        case .notDetected(let kind):
            Loc.t("설치를 마쳤지만 \(kind.toolName) 설정에서 \(AppDisplayName.current) 항목을 찾지 못했습니다",
                  "Installation finished, but the \(AppDisplayName.current) entry wasn't found in the \(kind.toolName) settings")
        }
    }
}

/// `GoRunner --install-agent-hooks` (scripts/install.sh) and `GoRunner --uninstall-agent-hooks`. Headless: no status item,
/// no single-instance guard. Prints one JSON line and exits 0:
/// `{"claude":{"present":true,"installed":true,"error":null},"codex":{"present":false,"installed":false,"error":null}}`
enum AgentHooksCommand {
    enum Action { case install, uninstall }

    struct ToolResult: Equatable {
        var present: Bool
        var installed: Bool
        var error: String?
    }

    /// Debug only: sandbox every path under this folder and write settings to `sandboxSettingsSuite`.
    static let sandboxRootPrefix = "--agent-hooks-root="
    static let sandboxSettingsSuite = "dev.gorunner.GoRunner.agenthooks-test"

    @MainActor
    static func run(_ action: Action, arguments: [String] = CommandLine.arguments) -> Int32 {
        var hooks = AgentHooks.standard
        var defaults = UserDefaults.standard
        if let arg = arguments.first(where: { $0.hasPrefix(sandboxRootPrefix) }) {
            let path = (String(arg.dropFirst(sandboxRootPrefix.count)) as NSString).expandingTildeInPath
            guard !path.isEmpty, let suite = UserDefaults(suiteName: sandboxSettingsSuite) else { return 1 }
            hooks = .sandboxed(root: URL(fileURLWithPath: path, isDirectory: true))
            defaults = suite
        }

        let store = SettingsStore(defaults: defaults)
        var results: [AgentKind: ToolResult] = [:]
        for kind in AgentKind.allCases {
            switch action {
            case .install: results[kind] = install(kind, hooks: hooks, store: store)
            case .uninstall: results[kind] = uninstall(kind, hooks: hooks, store: store)
            }
        }
        store.save()
        defaults.synchronize()
        HeadlessRunner.printJSON(Data(json(results).utf8))
        return 0
    }

    @MainActor
    private static func install(_ kind: AgentKind, hooks: AgentHooks, store: SettingsStore) -> ToolResult {
        guard hooks.isToolPresent(kind) else {
            return ToolResult(present: false, installed: hooks.isInstalled(kind), error: nil)
        }
        do {
            try hooks.install(kind)
            AgentHooks.setEnabled(true, for: kind, in: &store.settings)
            return ToolResult(present: true, installed: true, error: nil)
        } catch {
            return ToolResult(present: true, installed: hooks.isInstalled(kind), error: error.localizedDescription)
        }
    }

    @MainActor
    private static func uninstall(_ kind: AgentKind, hooks: AgentHooks, store: SettingsStore) -> ToolResult {
        var message: String?
        do {
            try hooks.uninstall(kind)
        } catch {
            message = error.localizedDescription
        }
        AgentHooks.setEnabled(false, for: kind, in: &store.settings)
        return ToolResult(present: hooks.isToolPresent(kind), installed: hooks.isInstalled(kind), error: message)
    }

    /// Hand-built so the key order is fixed: claude, codex; present, installed, error.
    static func json(_ results: [AgentKind: ToolResult]) -> String {
        let parts = AgentKind.allCases.map { kind -> String in
            let result = results[kind] ?? ToolResult(present: false, installed: false, error: nil)
            return "\"\(kind.rawValue)\":{\"present\":\(result.present),\"installed\":\(result.installed),\"error\":\(quoted(result.error))}"
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private static func quoted(_ value: String?) -> String {
        guard let value else { return "null" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}
