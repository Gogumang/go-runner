#!/usr/bin/env bash
# Runs the bundled app headless with --smoke-test and validates the JSON it prints.
# Contract: docs/ralph/TASKS.md ("Smoke test JSON").
set -uo pipefail
cd "$(dirname "$0")/.."

APP_BIN="build/go-runner.app/Contents/MacOS/GoRunner"
OUT="build/smoke.json"

if [ ! -x "$APP_BIN" ]; then
  echo "missing $APP_BIN (run scripts/build-app.sh)" >&2
  exit 1
fi

# 120 s hard timeout without coreutils
perl -e 'alarm shift; exec @ARGV' 120 "$APP_BIN" --smoke-test > "$OUT" 2> build/smoke.stderr.log
code=$?
if [ $code -ne 0 ]; then
  echo "smoke run exited with $code" >&2
  tail -30 build/smoke.stderr.log >&2
  exit 1
fi

check() {
  local desc="$1" filter="$2"
  if jq -e "$filter" "$OUT" >/dev/null 2>&1; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc   ($filter)"
    failed=1
  fi
}

failed=0
check "valid JSON with ok=true"                 '.ok == true'
check "cpu usage in 0...1"                      '(.metrics.cpu.usage | type == "number") and .metrics.cpu.usage >= 0 and .metrics.cpu.usage <= 1'
check "memory sampled"                          '.metrics.memory.usage > 0'
check "storage sampled"                         '.metrics.storage.totalBytes > 0'
check "network section present"                 '.metrics.network.connection | type == "string"'
check "battery section present"                 '.metrics.battery | has("isInstalled")'
check "speed curve parity (50% -> 10)"          '.speedCurve.cpu50 == 10'
check "at least 5 built-in runners"             '[.runners[] | select(.source == "builtIn")] | length >= 5'
check "every runner renders >= 2 frames @36px"  '[.runners[] | select(.renderedFrames < 2 or .pixelHeight != 36)] | length == 0'
check "three providers reported"                '[.providers[].provider] | sort == ["bedrock","claude","codex"]'
check "each provider has snapshot or error"     '[.providers[] | select(.snapshot == null and .error == null)] | length == 0'
check "settings round-trip"                     '.settingsRoundTrip == true'
check "uninstall plan lists owned locations"    '.uninstallPlan | length >= 5'

exit $failed
