# GoRunner (go-runner)

Apache-2.0, Copyright 2026 gogumang (`LICENSE`, `NOTICE`). RunCat-style macOS menu bar app: an animated runner whose speed follows CPU usage, a standard macOS menu with system info,
brand/AI character runners, and Claude / Codex / Bedrock usage monitoring. Korean-first UI (`Loc.t(ko, en)`).

AI quota research cited by the providers: `docs/research/04-ai-quota.md`. Acceptance checklist: `docs/ralph/TASKS.md`.
Manual test guide: `docs/TESTING.md`.

## Commands

| Task | Command |
|---|---|
| Build everything | `swift build` |
| Build one target | `swift build --target <Target>` |
| Tests | `swift test` (one target: `swift test --filter <Target>Tests`) |
| App bundle | `./scripts/build-app.sh` → `build/go-runner.app` |
| Run | `make run` |
| Install to ~/Applications | `./scripts/install.sh` |
| Uninstall everything | `./scripts/uninstall.sh` (`--dry-run`, `--yes`) |
| Ralph gate | `./scripts/ralph-check.sh` → `build/ralph-report.md` |

When several agents build at once, use a private scratch path to avoid the `.build` lock:
`swift build --target <Target> --scratch-path .build-<name>`.

## Modules

| Target | Owns | Depends on |
|---|---|---|
| `GoRunnerCore` | models, protocols, `SpeedCurve`, `AppSettings`/`SettingsStore`, `AppPaths`, `MetricFormat`, `Loc`, `ProcessRunner`/`ExecutableLocator` | — |
| `SystemMetrics` | `SystemMonitor` (Mach/IOKit/getifaddrs sampling) | Core |
| `RunnerKit` | `SpriteRenderer`, `RunnerCatalog` (built-in runners only), `LayerRunnerAnimator` | Core |
| `RunnerArt` | `RunnerArtCatalog.all` built-in pixel sprites | Core |
| `ClaudeUsage` | `ClaudeUsageProvider`, `ClaudeStatuslineInstaller` | Core |
| `CodexUsage` | `CodexUsageProvider` | Core |
| `BedrockUsage` | `BedrockUsageProvider`, `AWSProfiles` | Core |
| `DeviceTrust` | Secure Enclave device key (`AppPaths.deviceSigningKeyFile`), JWK thumbprint, DPoP proofs, `DeviceTrustClient` for the collector's `/api/device/sessions` and `/api/device/heartbeat` ("어드민 열기") | Core |
| `GoRunnerApp` | app shell: status item, status menu, settings, quota coordinator, smoke test, uninstall, `LegacyInstallCleanup` (removes pre-rename RunAX installs at launch) | all |

Files marked `FACADE` define public API used by other targets — keep those signatures.

## Rules

- Swift 5 language mode, macOS 14+. No third-party dependencies. No SwiftPM resources (sprites are code; fixtures load via `#filePath`).
- Never swap `NSStatusItem.button.image` per frame — animate with `CAKeyframeAnimation` on a layer (RunCat Neo technique).
- Every file GoRunner writes must live under `AppPaths` locations so the uninstaller can remove it. Anything written elsewhere
  (only `~/.claude/settings.json` statusLine) must be backed up and restorable.
- Never store, refresh or transmit other tools' credentials. The Claude OAuth usage source is opt-in only.
- Third-party code/art: attribution comment at the top of the file and an entry in `THIRD_PARTY_NOTICES.md`.
- GUI apps don't inherit shell PATH: always resolve CLIs with `ExecutableLocator` and run them with `ProcessRunner`.
