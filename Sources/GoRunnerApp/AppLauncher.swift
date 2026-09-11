import AppKit
import GoRunnerCore

extension Notification.Name {
    /// Posted (distributed) by a second launch so the running instance opens its menu.
    static let gorunnerShowDashboard = Notification.Name("dev.gorunner.GoRunner.showDashboard")
}

@MainActor
enum AppLauncher {
    private static var delegate: AppDelegate?

    static func run() {
        // `--allow-second-instance` (debug only): lets a verification build run next to the user's copy.
        if !CommandLine.arguments.contains("--allow-second-instance"), activateExistingInstance() {
            exit(0)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }

    /// Single-instance guard: if another GoRunner is running, bring it forward and tell it to open its menu.
    private static func activateExistingInstance() -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleID)
            .filter { $0.processIdentifier != ownPID && !$0.isTerminated }
        guard let other = others.first else { return false }
        DistributedNotificationCenter.default().postNotificationName(.gorunnerShowDashboard, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
        other.activate(options: [])
        Log.app.info("Another go-runner instance (pid \(other.processIdentifier)) is running; exiting.")
        return true
    }
}

/// Runs async headless work on the main actor while keeping the main run loop alive, then exits with its code.
enum HeadlessRunner {
    static func run(_ work: @escaping @MainActor @Sendable () async -> Int32) -> Never {
        Task { @MainActor in
            let code = await work()
            exit(code)
        }
        // A far-future timer keeps the run loop from returning immediately when no other sources exist.
        let keepAlive = Timer(timeInterval: 3600, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .default)
        while true {
            RunLoop.main.run(mode: .default, before: .distantFuture)
        }
    }

    static func printJSON(_ data: Data) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
