#!/usr/bin/env bash
# Builds go-runner and installs it to ~/Applications (no sudo), then launches it.
#   GORUNNER_INSTALL_DIR=/Applications ./scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DEST_DIR="${GORUNNER_INSTALL_DIR:-$HOME/Applications}"
APP_NAME="go-runner.app"

./scripts/build-app.sh

pkill -x GoRunner 2>/dev/null || true
pkill -x RunAX 2>/dev/null || true
sleep 0.5

mkdir -p "$DEST_DIR"
rm -rf "$DEST_DIR/$APP_NAME"
# Earlier builds were named RunAX.app and NOL Runner.app (older bundle id or display name). macOS may keep showing
# the old name in notifications while any of them stays registered, so unregister and remove them.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for legacy in "$DEST_DIR/RunAX.app" "build/RunAX.app" "build/lead/RunAX.app" \
              "$DEST_DIR/NOL Runner.app" "build/NOL Runner.app" "build/lead/NOL Runner.app"; do
  if [ -d "$legacy" ]; then
    "$LSREGISTER" -u "$legacy" 2>/dev/null || true
    rm -rf "$legacy"
  fi
done
ditto "build/$APP_NAME" "$DEST_DIR/$APP_NAME"
"$LSREGISTER" -f "$DEST_DIR/$APP_NAME" 2>/dev/null || true

# Claude Code / Codex가 이 Mac에 있으면 작업 완료 알림 훅을 넣습니다 (기존 훅은 유지, 제거하면 원래대로 복원).
# 30초 제한: 이전 버전 앱이 이 옵션을 몰라도 설치가 멈추지 않게 합니다.
if hooks=$(perl -e 'alarm shift; exec @ARGV' 30 "$DEST_DIR/$APP_NAME/Contents/MacOS/GoRunner" --install-agent-hooks 2>/dev/null); then
  echo "작업 완료 알림 훅: $hooks"
else
  echo "작업 완료 알림 훅 설치를 건너뛰었습니다 (설정 → AI 서비스에서 켤 수 있습니다)."
fi
pkill -x GoRunner 2>/dev/null || true
pkill -x RunAX 2>/dev/null || true

open "$DEST_DIR/$APP_NAME"

echo "설치 완료: $DEST_DIR/$APP_NAME"
echo "제거하려면: ./scripts/uninstall.sh  (또는 메뉴 → 설정… → 정보 → go-runner 제거…)"
