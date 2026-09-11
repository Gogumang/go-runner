// Entry point.
//   --smoke-test         headless self-check, prints one JSON object (docs/ralph/TASKS.md)
//   --uninstall-cleanup  headless cleanup used by scripts/uninstall.sh, prints a JSON summary
//   --install-agent-hooks    headless: adds the finish-notification hooks for the tools on this Mac (scripts/install.sh)
//   --uninstall-agent-hooks  headless: removes both hooks and turns the notifications off
//   (no flag)            menu bar app
// Headless flags never reach AppLauncher, so they don't start the GUI or trip the single-instance guard.

let arguments = CommandLine.arguments

if arguments.contains("--smoke-test") {
    HeadlessRunner.run { await SmokeTest.run() }
} else if arguments.contains("--uninstall-cleanup") {
    LegacyInstallCleanup.standard.run()
    HeadlessRunner.run { await UninstallCleanupCommand.run() }
} else if arguments.contains("--install-agent-hooks") {
    // Old RunAX hooks go first, so the new hooks never chain to them.
    LegacyInstallCleanup.standard.run()
    HeadlessRunner.run { AgentHooksCommand.run(.install) }
} else if arguments.contains("--uninstall-agent-hooks") {
    LegacyInstallCleanup.standard.run()
    HeadlessRunner.run { AgentHooksCommand.run(.uninstall) }
} else if arguments.contains("--slack-badge-probe") {
    // Debug: read-only Slack Dock badge read, one JSON line, never prompts for Accessibility.
    HeadlessRunner.run { SlackDockBadgeReader.probeCommand() }
} else if arguments.contains(where: { $0.hasPrefix("--notification-images-probe=") }) {
    // Debug: render the notification images into a given folder and report bundled sounds.
    HeadlessRunner.run { NotificationDecor.probeCommand() }
} else {
    LegacyInstallCleanup.standard.run()
    MainActor.assumeIsolated {
        AppLauncher.run()
    }
}
