# GoRunner Ralph loop — acceptance checklist

The loop: `./scripts/ralph-check.sh` → read `build/ralph-report.md` → fix the first failing item → repeat until **ALL PASS**,
then do the manual checks at the bottom. Never mark an item done without running the check.

## Gate (automated)

- [ ] `swift build` succeeds with no errors
- [ ] `swift test` — all tests pass
- [ ] `./scripts/build-app.sh` produces `build/go-runner.app` (ad-hoc signed)
- [ ] `./scripts/smoke-test.sh` — every check prints `ok`

## Smoke test JSON (`GoRunner --smoke-test`)

Headless: no status item, no windows, no Dock icon. Prints exactly one JSON object to stdout and exits 0.
Must not touch the user's Keychain, `~/.claude/settings.json` or real app settings (use a temporary UserDefaults suite).

```jsonc
{
  "ok": true,
  "version": "0.1.0",
  "metrics": {                       // two samples 1 s apart so CPU/network deltas are real
    "cpu":     { "usage": 0.12, "system": 0.04, "user": 0.08, "idle": 0.88 },
    "memory":  { "usage": 0.61, "pressure": 0.22, "appBytes": 0, "wiredBytes": 0, "compressedBytes": 0, "physicalBytes": 0 },
    "storage": { "totalBytes": 0, "availableBytes": 0 },
    "battery": { "isInstalled": true, "percentage": 0.98, "isCharging": false, "...": "..." },
    "network": { "connection": "wifi", "interfaceName": "en0", "localIP": "192.168.0.2", "uploadBytesPerSecond": 0, "downloadBytesPerSecond": 0 }
  },
  "speedCurve": { "cpu0": 1, "cpu50": 10, "cpu100": 20 },
  "runners": [
    { "id": "clawd", "name": "클로드", "source": "builtIn", "isTemplate": false,
      "renderedFrames": 6, "pixelWidth": 40, "pixelHeight": 36, "license": "Anthropic — personal use only", "isBrandInspired": true }
  ],
  "providers": [                     // claude, codex, bedrock — OAuth source forced off, Bedrock uses stored settings
    { "provider": "claude", "snapshot": { /* QuotaSnapshot JSON */ }, "error": null,
      "attempts": [ { "source": "statusline", "trust": 3, "succeeded": false, "message": "..." } ] }
  ],
  "settingsRoundTrip": true,         // encode → save to temp suite → load → equal
  "uninstallPlan": [ "/Users/.../Library/Application Support/GoRunner", "..." ]
}
```

## Functional (implemented and verified)

### Runner and menu bar
- [ ] Status item shows the animated runner using `LayerRunnerAnimator` (no per-frame `button.image` swaps)
- [ ] Speed follows `SpeedCurve` from CPU every update interval; invert / FPS limit apply immediately
- [ ] "Show CPU Usage" text (monospaced 11 pt, `%4.1f%%`) left of the runner
- [ ] Flip, accent tint, invert speed, stop runner, random runner and FPS limit have no UI (removed at the user's request) and stay at their defaults
- [ ] Pauses on sleep / screens sleep / Reduce Motion; resumes after
- [ ] Template runners follow light/dark menu bar; color runners keep colors

### Status menu (click the status item)
- [ ] Standard NSMenu with a "시스템" graph block: CPU history graph, memory / storage / battery bars with % (tap opens Activity Monitor), updating while open
- [ ] "AI 남은 한도" block per enabled provider: a remaining-% bar per limit window (orange ≤ 30%, red ≤ 10%), reset time of the tightest window, cached marker, error message when unavailable; no token or cost figures
- [ ] 러너 ▸ submenu with thumbnails and a check on the current runner, then 러너 설정…
- [ ] 설정… (⌘,), AI 사용량 새로고침 (⌘R), 종료 (⌘Q); notification permission row only while a notification is on but not allowed

### Settings window
- [ ] 일반: launch at login (SMAppService), reset settings
- [ ] Sidebar layout (System Settings style): 일반, 러너, 메뉴 막대, AI 서비스, 알림, 정보
- [ ] 러너: character picker only (built-in runners; no motion options, automatic change, runner packs or credits list)
- [ ] 메뉴 막대: CPU text in the menu bar, memory / storage / battery rows, interval 3/5/10 s (no AI usage in the menu bar)
- [ ] AI 서비스: per-provider toggles and sources; Claude statusline hook install/uninstall; OAuth opt-in with warning; Codex path; Bedrock profile/region/models/Cost Explorer; "지금 새로고침"
- [ ] 알림: macOS permission, test notification, Claude Code / Codex finish hooks, Slack
- [ ] 정보: version, team purpose, Apache-2.0 copyright, uninstall; no RunCat wording anywhere in the UI (LICENSE, NOTICE, THIRD_PARTY_NOTICES.md are bundled in Contents/Resources)

### Uninstall
- [ ] In-app "go-runner 제거…" shows exactly what will be removed, then: unregisters login item, restores Claude statusline, deletes Keychain items (service `dev.gorunner.GoRunner`), removes owned folders and defaults, moves the app to Trash, quits
- [ ] `GoRunner --uninstall-cleanup` does the same except moving the app bundle (used by `scripts/uninstall.sh`)
- [ ] `./scripts/uninstall.sh --dry-run` lists items; `--yes` leaves nothing behind

## Manual checks (lead does these after ALL PASS)
- [ ] `make run`: runner visible and animating in the menu bar; speed visibly increases under load (`yes > /dev/null` ×4)
- [ ] Menu and Settings screenshots look right in light and dark
- [ ] Settings changes persist across relaunch
- [ ] Install → uninstall round trip leaves no files (`./scripts/uninstall.sh --dry-run` shows nothing)
