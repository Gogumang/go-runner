# go-runner 테스트 안내

## 설치와 실행

| 하고 싶은 것 | 명령 (프로젝트 폴더에서) |
|---|---|
| 설치하지 않고 바로 실행 | `make run` |
| `~/Applications`에 설치하고 실행 | `./scripts/install.sh` |
| 지울 항목만 확인 | `./scripts/uninstall.sh --dry-run` |
| 완전히 제거 | `./scripts/uninstall.sh` (확인 없이: `--yes`) |

앱 안에서도 지울 수 있습니다: 러너 클릭 → **설정…** → **정보** → **go-runner 제거…**

제거하면 앱, 설정, 캐시, 로그, 키체인 항목, 로그인 시 자동 실행 등록을 모두 지우고,
Claude Code statusline을 설치 전 설정으로 되돌립니다. 소스 코드 폴더는 건드리지 않습니다.

## 확인할 것

### 메뉴바 러너
- [ ] 메뉴바에 러너가 보이고 달린다
- [ ] 부하를 주면 빨라진다: 터미널에서 `yes > /dev/null &` 를 4번 실행, 끝낼 때 `killall yes`
- [ ] 라이트/다크 메뉴바 모두에서 잘 보인다

### 메뉴 (러너 클릭)
- [ ] 시스템: CPU 최근 사용량 그래프, 메모리 · 저장 공간 · 배터리 막대와 % (누르면 활성 상태 보기, 열어 둔 채로 값이 바뀜)
- [ ] AI 남은 한도: 서비스마다 5시간 · 주간 남은 % 막대 (30% 이하 주황, 10% 이하 빨강)와 가장 빠듯한 한도의 리셋 시각 (누르면 설정 → AI 서비스)
- [ ] **러너 ▸**: 캐릭터를 고르면 메뉴바 러너가 바로 바뀐다
- [ ] **설정…** · **AI 사용량 새로고침** · **go-runner 종료**
- [ ] 설정 창에서 바꾼 값이 앱을 다시 켜도 유지된다

### 배터리 · 메모리
- [ ] 활성 상태 보기에서 go-runner의 CPU가 평소 1% 안팎, 메모리가 수십 MB 수준이다
- [ ] AI 사용량은 메뉴를 열 때만 새로 읽는다 (1분 이내에 다시 열면 그대로). 백그라운드 주기 새로고침은 없다
- [ ] Claude Code 로컬 로그 분석(토큰 · 비용 추정)은 기본으로 꺼져 있다 (설정 → AI 서비스에서 켤 수 있음)
- [ ] 화면이 꺼지면 측정과 러너 애니메이션이 멈추고, 저전력 모드에서는 러너가 멈춘다

### AI 사용량
| 서비스 | 기본으로 보이는 값 | 더 정확하게 보려면 |
|---|---|---|
| Claude | 한도를 연결하기 전에는 "남은 한도 정보 없음" | 설정 → AI 서비스 → statusline 훅 설치 후 Claude Code 사용 → 5시간 · 주간 남은 % |
| Codex | `codex app-server`로 읽은 5시간 · 주간 남은 % | — |
| Bedrock | 기본 꺼짐 | 설정에서 켜기, 만료된 경우 `aws sso login --profile default` |

### 작업 완료 알림
- [ ] 설치 직후 "go-runner에서 알림을 보내려고 합니다" 창에서 허용 → "go-runner 알림이 켜졌어요" 알림
- [ ] Claude Code 작업이 끝나면 "Claude 작업 완료 · <프로젝트>" 알림 (새로 연 Claude Code 세션부터 적용)
- [ ] Codex 작업이 끝나면 "Codex 작업 완료 · <프로젝트>" 알림, Computer Use 알림도 그대로 동작
- [ ] 설정 → AI 서비스 → 작업 완료 알림에서 끄면 훅이 빠지고, 켜면 다시 들어감
- [ ] 알림 기록에는 프로젝트 폴더 이름과 시각만 남음: `~/Library/Application Support/GoRunner/agent-events.jsonl`

| 설치 때 바뀌는 파일 | 바뀌는 내용 | 되돌리기 |
|---|---|---|
| `~/.claude/settings.json` | `hooks.Stop`에 go-runner 항목 1개 추가 (기존 훅 유지) | 설정 → 알림에서 끄기 또는 go-runner 제거 |
| `~/.codex/config.toml` | `notify` 한 줄이 go-runner 래퍼로 바뀜 (래퍼가 원래 알림 프로그램을 그대로 실행) | 설정 → 알림에서 끄기 또는 go-runner 제거 → 원래 줄로 복원 |

## 피드백 주실 때
- 어떤 화면에서 무엇이 이상한지, 가능하면 스크린샷
- RunCat과 달라서 바꾸고 싶은 부분
- 다듬고 싶은 캐릭터 (미리보기: `build/sprite-previews/_overview.png`)

## 문제가 생기면
- 앱 로그: `log show --last 10m --predicate 'subsystem == "dev.gorunner.GoRunner"'`
- 헤드리스 점검: `"build/go-runner.app/Contents/MacOS/GoRunner" --smoke-test | jq .`
- 전체 자동 점검: `./scripts/ralph-check.sh` → `build/ralph-report.md`
