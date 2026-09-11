#!/usr/bin/env bash
# Ralph loop gate. Runs every check, writes build/ralph-report.md, exits 0 only when all pass.
#   ./scripts/ralph-check.sh            full gate
#   ./scripts/ralph-check.sh build test only selected steps
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

REPORT="build/ralph-report.md"
STEPS=("$@")
[ ${#STEPS[@]} -eq 0 ] && STEPS=(build test bundle smoke)

{
  echo "# Ralph report"
  echo
  echo "- time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo
} > "$REPORT"

failures=0
run_step() {
  local name="$1"; shift
  local log="build/ralph-$name.log"
  local start=$SECONDS
  if "$@" > "$log" 2>&1; then
    echo "- [x] $name ($((SECONDS - start))s)" >> "$REPORT"
    echo "PASS $name"
  else
    echo "- [ ] **$name** FAILED ($((SECONDS - start))s) — log: \`$log\`" >> "$REPORT"
    { echo '```'; grep -E "error:|FAIL|failed|Fatal|fatal" "$log" | head -40; echo "--- tail ---"; tail -25 "$log"; echo '```'; } >> "$REPORT"
    echo "FAIL $name  (see $log)"
    failures=$((failures + 1))
  fi
}

for step in "${STEPS[@]}"; do
  case "$step" in
    build)  run_step build swift build ;;
    test)   run_step test swift test ;;
    bundle) run_step bundle ./scripts/build-app.sh ;;
    smoke)  run_step smoke ./scripts/smoke-test.sh ;;
    *) echo "unknown step $step" >&2; exit 2 ;;
  esac
done

echo >> "$REPORT"
if [ $failures -eq 0 ]; then
  echo "**ALL PASS**" >> "$REPORT"
else
  echo "**$failures step(s) failing**" >> "$REPORT"
fi
echo "report: $REPORT"
exit $failures
