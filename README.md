# go-runner

macOS 메뉴 막대 앱입니다. 메뉴 막대의 러너가 CPU 사용량에 맞춰 달리고, 러너를 누르면 시스템 상태와 Claude · Codex 남은 한도를 그래프로 보여 줍니다.

## 주요 기능

- **메뉴 막대 러너**: CPU를 많이 쓸수록 빨리 달립니다. 클로드, 코덱스, 코디, 고퍼, 턱스, 키로, 그록 중에서 고를 수 있습니다.
- **메뉴**: CPU 사용량 그래프, 메모리 · 저장 공간 · 배터리 막대, Claude · Codex 남은 한도(5시간 · 주간) 막대
- **작업 완료 알림**: Claude Code · Codex 작업이 끝나거나 Slack에 새 메시지가 오면 macOS 알림을 보냅니다.
- **가볍게 동작**: AI 사용량은 메뉴를 열 때 새로 읽고, 화면이 꺼져 있거나 저전력 모드일 때는 측정과 애니메이션을 멈춥니다.
- **쉬운 제거**: 설정과 설치 때 바꾼 파일을 모두 원래대로 되돌립니다.

## 설치와 제거

| 하고 싶은 것 | 명령 (프로젝트 폴더에서) |
|---|---|
| 설치하지 않고 바로 실행 | `make run` |
| `~/Applications`에 설치하고 실행 | `./scripts/install.sh` |
| 지울 항목만 확인 | `./scripts/uninstall.sh --dry-run` |
| 완전히 제거 | `./scripts/uninstall.sh` (확인 없이: `--yes`) |

앱 안에서도 지울 수 있습니다: 러너 클릭 → **설정…** → **정보** → **go-runner 제거…**

요구 사항: macOS 14 이상, Xcode 26 (Swift 6.2). 테스트 방법은 [docs/TESTING.md](docs/TESTING.md)에 있습니다.

## 라이선스

Apache License 2.0 — Copyright 2026 gogumang. [LICENSE](LICENSE), [NOTICE](NOTICE)

참고한 오픈소스, 캐릭터와 앱 아이콘의 출처는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)에 있습니다.
브랜드 캐릭터(클로드, 코덱스, 키로, 그록)와 앱 아이콘은 Apache License 2.0 적용 대상이 아니며 개인용으로만 포함되어 있습니다.
