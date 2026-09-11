#!/usr/bin/env bash
# go-runner(GoRunner)를 흔적 없이 제거합니다. 이 소스 코드 폴더는 건드리지 않습니다.
#   ./scripts/uninstall.sh            목록을 보여주고 확인 후 제거
#   ./scripts/uninstall.sh --dry-run  지울 항목만 보여주기
#   ./scripts/uninstall.sh --yes      확인 없이 제거
# 이전 이름(RunAX, NOL Runner)으로 설치된 앱, 폴더, 훅, 서명 인증서도 함께 지웁니다.
set -uo pipefail

BUNDLE_IDS=("dev.gorunner.GoRunner" "dev.runax.RunAX")
# "데이터 폴더 이름:훅 파일 접두사" — 현재 이름, 이전 이름 순서
INSTALL_NAMES=("GoRunner:gorunner" "RunAX:runax")
PROCESS_NAMES=("GoRunner" "RunAX")
if [ -z "${HOME:-}" ] || [ "$HOME" = "/" ]; then
  echo "HOME이 올바르지 않아 중단합니다." >&2
  exit 1
fi

YES=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1 ;;
    -n|--dry-run) DRY=1 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "알 수 없는 옵션: $arg" >&2; exit 2 ;;
  esac
done

APPS=("$HOME/Applications/go-runner.app" "/Applications/go-runner.app"
      "$HOME/Applications/NOL Runner.app" "/Applications/NOL Runner.app"
      "$HOME/Applications/RunAX.app" "/Applications/RunAX.app")
SIGN_IDENTITIES=("go-runner Local" "NOL Runner Local")
DATA=()
for pair in "${INSTALL_NAMES[@]}"; do
  folder="${pair%%:*}"
  DATA+=("$HOME/Library/Application Support/$folder" "$HOME/Library/Logs/$folder")
done
for id in "${BUNDLE_IDS[@]}"; do
  DATA+=("$HOME/Library/Caches/$id" "$HOME/Library/HTTPStorages/$id"
         "$HOME/Library/Saved Application State/$id.savedState" "$HOME/Library/Preferences/$id.plist")
done
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"

echo "go-runner 제거 대상:"
found=0
for p in "${APPS[@]}" "${DATA[@]}"; do
  if [ -e "$p" ]; then echo "  - $p"; found=1; fi
done
for pair in "${INSTALL_NAMES[@]}"; do
  folder="${pair%%:*}"; prefix="${pair##*:}"
  if [ -f "$CLAUDE_SETTINGS" ] && grep -q "$folder/bin/claude-statusline" "$CLAUDE_SETTINGS"; then
    echo "  - ~/.claude/settings.json 의 statusLine 훅 ($folder, 설치 전 설정으로 복원)"
    found=1
  fi
  if [ -f "$CLAUDE_SETTINGS" ] && grep -q "$folder/bin/$prefix-agent-event" "$CLAUDE_SETTINGS"; then
    echo "  - ~/.claude/settings.json 의 작업 완료 알림 훅 ($folder 항목만 제거)"
    found=1
  fi
  if [ -f "$CODEX_CONFIG" ] && grep -q "$prefix-codex-notify" "$CODEX_CONFIG"; then
    echo "  - ~/.codex/config.toml 의 notify 설정 ($folder, 설치 전 값으로 복원)"
    found=1
  fi
done
for identity in "${SIGN_IDENTITIES[@]}"; do
  if security find-certificate -c "$identity" >/dev/null 2>&1; then
    echo "  - 키체인의 코드 서명 인증서 '$identity'"
    found=1
  fi
done
for id in "${BUNDLE_IDS[@]}"; do
  if security find-generic-password -s "$id" >/dev/null 2>&1; then
    echo "  - 키체인 항목 (서비스: $id)"
    found=1
  fi
done
for name in "${PROCESS_NAMES[@]}"; do
  if pgrep -x "$name" >/dev/null 2>&1; then echo "  - 실행 중인 $name 프로세스"; found=1; fi
done
echo "  - 로그인 시 자동 실행 등록 (등록된 경우)"

if [ "$DRY" = 1 ]; then exit 0; fi
if [ "$found" = 0 ]; then
  echo "지울 항목이 없습니다."
fi
if [ "$YES" != 1 ]; then
  printf "모두 제거할까요? [y/N] "
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) echo "취소했습니다."; exit 0 ;; esac
fi

# 1) 앱만 할 수 있는 정리: 로그인 항목 해제, Claude statusline 복원, 키체인 삭제.
#    새 앱이 있으면 새 앱이 이전 RunAX 설치까지 정리하고, 없으면 남아 있는 이전 앱을 씁니다.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cleaned=0
for name in "${PROCESS_NAMES[@]}"; do
  for app in "${APPS[@]}" "$ROOT/build/go-runner.app" "$ROOT/build/NOL Runner.app" "$ROOT/build/RunAX.app"; do
    if [ "$cleaned" = 0 ] && [ -x "$app/Contents/MacOS/$name" ]; then
      "$app/Contents/MacOS/$name" --uninstall-cleanup >/dev/null 2>&1 || true
      cleaned=1
    fi
  done
done

for name in "${PROCESS_NAMES[@]}"; do pkill -x "$name" 2>/dev/null || true; done
sleep 0.5

# 2) 앱이 되돌리지 못한 훅은 여기서 되돌림 (현재 이름, 이전 이름 각각의 백업으로)
for pair in "${INSTALL_NAMES[@]}"; do
  folder="${pair%%:*}"; prefix="${pair##*:}"
  backups="$HOME/Library/Application Support/$folder/Backups"
  statusline_marker="$folder/bin/claude-statusline"
  stop_marker="$folder/bin/$prefix-agent-event"
  codex_wrapper="$prefix-codex-notify"

  if [ -f "$CLAUDE_SETTINGS" ] && grep -q "$statusline_marker" "$CLAUDE_SETTINGS"; then
    tmp="$(mktemp)"
    statusline_backup="$backups/claude-statusline-previous.json"
    if [ -f "$statusline_backup" ] && [ "$(tr -d '[:space:]' < "$statusline_backup")" != "null" ]; then
      jq --slurpfile prev "$statusline_backup" '.statusLine = $prev[0]' "$CLAUDE_SETTINGS" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
    else
      jq 'del(.statusLine)' "$CLAUDE_SETTINGS" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
    fi
    echo "Claude Code statusline 설정을 복원했습니다 ($folder)."
  fi

  if [ -f "$CLAUDE_SETTINGS" ] && grep -q "$stop_marker" "$CLAUDE_SETTINGS"; then
    tmp="$(mktemp)"
    if jq --arg marker "$stop_marker" '
        if (.hooks.Stop? // null) == null then . else
          .hooks.Stop |= (map(.hooks |= map(select((.command // "") | contains($marker) | not)))
                          | map(select((.hooks | length) > 0)))
          | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
          | if (.hooks | length) == 0 then del(.hooks) else . end
        end' "$CLAUDE_SETTINGS" > "$tmp"; then
      mv "$tmp" "$CLAUDE_SETTINGS"
      echo "Claude Code 작업 완료 알림 훅을 제거했습니다 ($folder)."
    else
      rm -f "$tmp"
    fi
  fi

  if [ -f "$CODEX_CONFIG" ] && grep -q "$codex_wrapper" "$CODEX_CONFIG"; then
    if python3 - "$CODEX_CONFIG" "$backups/codex-notify-previous.json" "$codex_wrapper" <<'PY'
import json, os, sys
config, backup, wrapper = sys.argv[1], sys.argv[2], sys.argv[3]
previous = None
if os.path.exists(backup):
    previous = json.load(open(backup)).get("line")
text = open(config, encoding="utf-8").read()
lines = text.splitlines(keepends=True)
out, replaced = [], False
for line in lines:
    stripped = line.lstrip()
    if not replaced and stripped.startswith("notify") and wrapper in line:
        if previous is not None:
            out.append(previous if previous.endswith("\n") else previous + "\n")
        replaced = True
        continue
    out.append(line)
open(config, "w", encoding="utf-8").write("".join(out))
PY
    then
      echo "Codex notify 설정을 복원했습니다 ($folder)."
    fi
  fi
done

# 3) 설정, 키체인, 파일 제거
for id in "${BUNDLE_IDS[@]}"; do
  defaults delete "$id" >/dev/null 2>&1 || true
  while security delete-generic-password -s "$id" >/dev/null 2>&1; do :; done
done
# Local code-signing identity created by scripts/setup-signing.sh (certificate + private key)
for identity in "${SIGN_IDENTITIES[@]}"; do
  while security find-certificate -c "$identity" >/dev/null 2>&1; do
    security delete-identity -c "$identity" >/dev/null 2>&1 \
      || security delete-certificate -c "$identity" -t >/dev/null 2>&1 \
      || break
  done
done
for p in "${APPS[@]}" "${DATA[@]}"; do
  case "$p" in
    "$HOME"/*|/Applications/go-runner.app|"/Applications/NOL Runner.app"|/Applications/RunAX.app) [ -e "$p" ] && rm -rf "$p" ;;
  esac
done

echo "go-runner를 제거했습니다."
