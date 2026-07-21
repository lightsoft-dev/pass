# Bundled extensions

pass 익스텐션 예제들. 이 폴더는 앱 번들 리소스로 복사되어, **Settings › Extensions › Install**
한 번으로 `~/.pass/extensions/<id>/`에 설치된다 (설치 후에도 활성화는 별도 — 켜기 전에
`extension.json`의 권한을 확인하는 것이 규칙이다).

수동 설치도 같다: 폴더째 `~/.pass/extensions/`로 복사하면 끝. 매니페스트 스키마·이벤트·액션
카탈로그는 `docs/EXTENSIONS.md` 참고.

| id | 무엇 | 팔레트 (⌘P) |
|---|---|---|
| `agent-usage` | Claude Code 토큰 사용량 리포트 (일자·모델·프로젝트별, 중복 턴 제거) | `usage`, `usage-month` 또는 `>usage` |
| `event-monitor` | 독립 HTML/CSS/JS 창, 세션 snapshot 및 실시간 이벤트 bridge 예제 | `events` 또는 `>events` |
| `ui-starter` | 가장 작은 독립 Web UI 창 예제 (snapshot 읽기 + host action 호출) | `ui`, `starter` 또는 `>ui-starter` |

> Command-P 일반 검색은 활성화된 extension command도 함께 찾는다. **`>`** 프리픽스는
> VS Code처럼 extension command만 보고 싶을 때 쓰며, `/`는 에이전트 슬래시 명령(`/compact` 등)을
> 세션으로 보내는 데 이미 쓰이므로 충돌을 피한다.
