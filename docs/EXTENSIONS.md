# pass 익스텐션 시스템 설계

> 상태: **Tier 1 (E1–E3) 구현됨.** 매니페스트 로더(`ExtensionStore`) + 검증
> (`ExtensionManifest.problems`), ⌘P `>명령` 팔레트, 이벤트 규칙 + 액션 실행기
> (`ExtensionRuntime`), Settings › Extensions(토글/리로드/실행 로그/번들 예제 설치)가
> 동작한다. 번들 예제: **agent-usage** (`>usage` — Claude Code 토큰 사용량 리포트,
> `Extensions/agent-usage/`). 남은 것: E4 AI 빌더, E5 상주 프로세스·에이전트 기여, E6 공유.

---

## 1. 목표와 비전

- **사용자가 pass를 자기 워크플로에 맞게 확장한다.** 예: "세션이 permission을 기다리면 Slack DM",
  "⌘P에서 `>deploy` 치면 선택된 세션에 배포 지시", "매일 아침 각 프로젝트에 스탠드업 요약 세션 생성".
- **AI가 익스텐션을 만들어준다.** 사용자는 자연어로 원하는 동작을 설명하고, pass가 Claude Code
  세션을 띄워 익스텐션을 생성 → 사용자가 검토 → 활성화. pass는 이미 Claude 세션을 관리하는
  앱이므로, 이 기능은 새 인프라 없이 기존 스펙-에이전트 패턴(`runSpecAgent`)의 재사용이다.
- **코어는 계속 작게.** 익스텐션 포인트를 열어두면 "이 기능도 넣어달라"는 요구를 코어 밖으로
  밀어낼 수 있다. M5의 멀티 에이전트(codex/pi/기타)도 결국 "에이전트 어댑터 익스텐션"으로 수렴한다.

### 비목표 (v1)

- **임의의 커스텀 UI 렌더링** (VS Code의 webview 같은 것). 배지·명령·알림 수준의 선언적 기여만.
- **샌드박스/서명 기반 보안.** 익스텐션은 사용자 권한의 스크립트다 (아래 §8 신뢰 모델 참고).
- **중앙 마켓플레이스.** 배포는 git 저장소 기반으로 시작한다 (§9).

---

## 2. 왜 pass에 잘 맞는가 — 기존 확장 포인트

pass의 아키텍처는 이미 "확장 가능하게" 생겼다. 새로 발명할 것이 적다:

| 기존 구조 | 익스텐션 시스템에서의 역할 |
|---|---|
| `HookServer` — loopback HTTP, `POST /hook/*` | 익스텐션 프로세스와의 통신 채널로 그대로 확장 (`/ext/*` 라우트 추가) |
| `EventRouter` + `AgentAdapter` — hook을 `AgentEvent`로 정규화 | 이벤트 규칙 엔진의 탭(tap) 지점; 커스텀 어댑터 기여 지점 |
| `AttentionState` 상태 머신 (decision/input/finished) | 익스텐션이 구독하는 핵심 이벤트 소스 |
| `ReplyInjector` — 세션에 안전한 텍스트 주입 (bare shell 거부) | 익스텐션 액션 `sendText`의 실행기 |
| `Shell` / `TmuxClient` | 익스텐션 액션 `runScript`의 실행기 |
| `.pass/specs.json` — "JSON 계약을 에이전트가 읽고 쓴다" | AI 빌더의 계약 패턴 원형 (`extension.json` + 상태 writeback) |
| `LaunchCommands` — 에이전트별 실행 명령 사용자 오버라이드 | "선언적 설정이 코드를 대체한다"는 선례 |
| ⌘P 퀵 명령 (`@` 점프, `+branch` 워크트리) | 익스텐션 명령의 진입점 (`>명령` 프리픽스) |

핵심 통찰: **pass의 철학(tmux+git이 데이터베이스, loopback HTTP hook, JSON 계약)을 그대로 따르면
익스텐션 = "매니페스트 JSON + 스크립트"가 된다.** VS Code처럼 자바스크립트 런타임을 임베드할
필요가 없다.

---

## 3. 설계 원칙

1. **선언이 코드보다 먼저.** 대부분의 요구(이벤트→액션, 팔레트 명령)는 매니페스트만으로 충족된다.
   코드가 필요한 지점만 스크립트/프로세스로 연다.
2. **크래시 격리.** 익스텐션 코드는 절대 pass 프로세스 안에서 돌지 않는다 (dylib 로딩 금지).
   스크립트는 자식 프로세스, 상주 익스텐션은 별도 프로세스 + HTTP/JSON.
3. **언어 자유.** 스크립트는 실행 가능하기만 하면 된다 (bash, python, swift, 컴파일 바이너리).
   AI가 생성하기도, 사용자가 읽고 검증하기도 쉽다.
4. **계약은 JSON 파일.** `extension.json`이 유일한 진실이다 — 앱 내부 미러 없음 (SpecStore와 동일).
5. **활성화 전 검토.** 특히 AI가 생성한 익스텐션은, 생성된 파일 전체와 요청 권한을 보여주고
   사용자가 명시적으로 켠다.

---

## 4. 아키텍처 — 3계층

```
┌─ Tier 1: 선언적 매니페스트 (v1 핵심) ──────────────────────────┐
│  extension.json — 명령, 이벤트 규칙, 에이전트 정의, 배지        │
│  액션: runScript / sendText / createSession / notify / openURL  │
└──────────────────────────────────────────────────────────────┘
┌─ Tier 2: 상주 익스텐션 프로세스 (v2) ─────────────────────────┐
│  pass가 실행·감독하는 자식 프로세스. loopback HTTP로 양방향:     │
│  pass → ext: 이벤트 push (POST)   ext → pass: /ext/api 호출     │
│  용도: 상태 유지 자동화, 커스텀 에이전트 어댑터(정규화 로직)      │
└──────────────────────────────────────────────────────────────┘
┌─ Tier 3: UI 기여 (보류) ─────────────────────────────────────┐
│  세션 카드 배지·버튼, 상세 패널 위젯 — 선언적 스키마로만, 필요해지면 │
└──────────────────────────────────────────────────────────────┘
```

Tier 1이 사용자 요구의 80%를 덮는다는 가설로 시작한다. Tier 2는 E5에서 M5(멀티 에이전트)와
함께 간다 — codex/pi 어댑터를 "번들 익스텐션"으로 만들면 코어가 검증된다.

### 실행 흐름 (Tier 1)

```
hook 수신 ──► EventRouter.route() ──► (기존) AttentionState 갱신
                     │
                     └──► ExtensionRuntime.dispatch(event)      ← 새 탭 지점
                              │  매니페스트 규칙 매칭 (on / if)
                              ▼
                        ActionExecutor
                          ├─ runScript   → Shell (자식 프로세스, cwd=익스텐션 디렉토리)
                          ├─ sendText    → ReplyInjector (bare shell 거부 그대로 적용)
                          ├─ createSession → SessionStore
                          ├─ notify      → NotificationService
                          └─ openURL     → NSWorkspace
```

⌘P 팔레트: 입력이 `>`로 시작하면 익스텐션 명령 검색 모드 (기존 `@` 점프, `+branch`와 나란히).
프리픽스가 `/`가 아닌 이유: 슬래시는 에이전트 슬래시 명령(`/compact` 등)을 세션으로 보내는 데
이미 쓰인다 — VS Code의 커맨드 팔레트 관례(`>`)를 따른다.
선택된 세션/프로젝트가 명령의 컨텍스트가 된다.

---

## 5. 매니페스트 스키마 v1

위치: `~/.pass/extensions/<id>/extension.json`

```jsonc
{
  "apiVersion": 1,                       // 스키마 버전 — 호환성 게이트
  "id": "slack-notify",                  // 디렉토리명과 일치, [a-z0-9-]
  "name": "Slack Notify",
  "version": "0.1.0",
  "description": "세션이 입력을 기다리면 Slack으로 알림",

  // 설치/활성화 시 사용자에게 보여주는 권한 선언. 선언 안 한 액션은 실행 거부.
  "permissions": ["events:attention", "run:script"],

  "contributes": {
    // (a) 이벤트 → 액션 규칙
    "rules": [
      {
        "on": "attention.pending",
        "if": { "kind": ["decision", "input"] },          // 선택적 필터
        "run": {
          "script": "notify.sh",                           // 익스텐션 디렉토리 기준 상대경로
          "args": ["${session.displayName}", "${attention.preview}"],
          "timeoutSeconds": 10
        }
      }
    ],

    // (b) ⌘P 팔레트 명령
    "commands": [
      {
        "id": "deploy",                                    // 팔레트에서 >deploy
        "title": "스테이징 배포 지시",
        "context": "session",                              // session | project | global
        "run": { "sendText": "스테이징에 배포하고 스모크 테스트 결과를 보고해줘" }
      }
    ],

    // (c) 에이전트 정의 (M5 연계 — glyph, 실행 명령, hook 라우트)
    "agents": [
      {
        "id": "aider",
        "glyph": "◆",
        "launchCommand": "aider --watch",
        "hookRoute": "/hook/aider",
        "hookFormat": "claude-compatible"                  // v1: Claude hook 포맷 호환만
      }
    ]
  }
}
```

### 이벤트 카탈로그 (v1)

| 이벤트 | 페이로드 | 발생 지점 |
|---|---|---|
| `attention.pending` | kind(decision/input/finished), preview, session | EventRouter.emit |
| `attention.resolved` | session | pending→해소 전환 시에만 (매 프롬프트 제출이 아니라) |
| `session.created` | session, project | reconcile diff (런치 시 이미 떠 있던 세션은 제외) |
| `session.ended` | session.name | reconcile diff + 명시적 kill |
| `project.added` (v2) | rootPath | 미구현 |

주의: 익스텐션이 `terminal`로 띄운 리포트 세션은 `session.created/ended`를 발생시키지 않는다
(자기 규칙을 재귀 트리거하는 루프 방지). 마지막 세션이 tmux 장애로 사라진 경우의 `ended`는
전달되지 않을 수 있다 — 순간적인 tmux 실패와 구분할 수 없기 때문 (SessionStore reconcile 규칙).

### 액션 카탈로그와 필요 권한

| 액션 | 권한 | 실행기 | 비고 |
|---|---|---|---|
| `script` | `run:script` | 자식 프로세스 | cwd=익스텐션 디렉토리, 페이로드는 argv+stdin(JSON), timeoutSeconds(기본 30) |
| `script` + `terminal: true` | `run:script`, `session:create` | tmux 명령 세션 | 결과를 보이는 터미널로 — 스크립트가 끝나면 세션도 닫히므로, 출력을 읽게 하려면 스크립트 끝에서 키 입력을 기다릴 것 (agent-usage 예제 참고) |
| `sendText` | `session:send` | ReplyInjector | bare shell 거부 로직 그대로 |
| `notify` | `notify` | NotificationService | 제목/본문 템플릿 |
| `openURL` | `open:url` | NSWorkspace | |

### 템플릿 변수

`${session.name}`, `${session.displayName}`, `${session.cwd}`, `${project.root}`,
`${project.name}`, `${git.branch}`, `${attention.kind}`, `${attention.preview}`,
`${event.name}`. 스크립트에는 동일 내용이 **stdin으로 JSON 전문**으로도 들어간다
(파싱이 필요한 스크립트는 argv 대신 stdin을 쓰면 된다).

---

## 6. 로딩과 생명주기

- **검색 경로**: `~/.pass/extensions/*/extension.json`. **v1은 글로벌 전용** — 프로젝트 로컬
  (`<repo>/.pass/extensions/`)은 "저장소를 clone하면 코드가 실행된다"는 공급망 위험이 있어 보류.
- **ExtensionStore** (새 스토어, SpecStore 패턴): 디스크가 진실. 로드 시 스키마 검증, 실패한
  매니페스트는 에러와 함께 Settings에 표시 (조용히 사라지지 않음).
- **활성/비활성**: UserDefaults에 enabled 집합만 저장. 파일 삭제 = 제거.
- **핫 리로드**: Settings의 "Reload" + 익스텐션 디렉토리 FSEvents 감시(개발 편의).
- **Settings › Extensions 탭**: 목록(이름/버전/권한/상태), 켜기/끄기, 폴더 열기, 로그 보기,
  "AI로 새 익스텐션 만들기" 버튼(§7).
- **실행 로그**: 익스텐션별 최근 실행 N건(액션, exit code, stderr 꼬리)을 메모리에 유지 —
  "왜 안 되지?"의 1차 디버깅 수단.

---

## 7. AI 익스텐션 빌더 (핵심 차별화)

pass는 이미 (1) Claude 세션을 만들고, (2) JSON 계약을 주입하고, (3) 완료를 hook으로 감지하고,
(4) 피드백 재주입으로 rework를 돌리는 전체 루프를 갖고 있다 (`AppModel.runSpecAgent`).
AI 빌더는 이 루프의 대상을 `.pass/specs.json` 대신 `~/.pass/extensions/<id>/`로 바꾼 것이다.

### 플로우

```
사용자: Settings › Extensions › "AI로 만들기" (또는 ⌘P → >new-extension)
   │  자연어 설명 입력: "세션이 permission 기다리면 내 Slack DM으로 보내줘"
   ▼
pass: ~/.pass/extensions/<slug>/ 생성 (초기엔 disabled 상태로 격리)
      Claude 세션 시작 (createSession — cwd를 해당 디렉토리로)
      계약 프롬프트 주입 (ReplyInjector; runSpecAgent와 동일한 재시도 루프)
   ▼
Claude: 번들 문서(EXTENSION_API.md)를 읽고 extension.json + 스크립트 작성
        `pass-ext validate` 실행해 스키마 자체 검증 (CLI 검증기 제공, §7.3)
        완료 시 Stop hook → pass가 감지
   ▼
pass: 매니페스트 재검증 → 검토 화면
      "생성된 파일 (전문 표시) / 요청 권한 / 트리거될 이벤트" → [활성화] [피드백 주고 재작업]
   ▼
활성화 — 또는 피드백 입력 시 같은 세션에 재주입 (컨텍스트 연속성, spec rework와 동일)
```

### 계약 프롬프트 (spec 프롬프트의 변형)

```
You are building a pass extension in this directory.
Read <app-bundle>/EXTENSION_API.md for the manifest schema, events, actions, and rules.

Goal: <사용자의 자연어 설명>

Rules:
- Write extension.json (apiVersion 1) and any scripts it references, in THIS directory only.
- Declare the minimal permissions the extension needs.
- Validate with `pass-ext validate .` and fix every error before finishing.
- Scripts must be executable, self-contained, and safe to show a reviewer.
- When done, write a one-paragraph SUMMARY.md describing what the extension does and why
  each permission is needed.
```

### 지원 요소

1. **EXTENSION_API.md** — 앱 번들에 포함되는 단일 API 문서. 사람용 문서이자 AI용 컨텍스트.
   스키마, 이벤트/액션 카탈로그, 템플릿 변수, 예제 3종. **이 문서의 품질이 곧 AI 빌더의 품질이다.**
2. **`pass-ext` CLI 검증기** — 앱 번들에 포함하는 작은 실행 파일 (또는 앱 자체의 `--validate`
   모드). 스키마 검증 + 참조 스크립트 존재/실행권한 확인 + 권한-액션 일치 검사. 에이전트가
   피드백 루프를 스스로 돌 수 있게 하는 열쇠.
3. **검토 화면** — AI 생성물은 무조건 여기를 거친다. 파일 전문 + 권한 + 트리거 조건.
   활성화 전까지 어떤 규칙도 디스패치되지 않는다.

---

## 8. 신뢰/보안 모델 (정직하게)

- **익스텐션 = 사용자 권한으로 도는 스크립트다.** macOS 샌드박스나 서명 검증을 시도하지 않는다.
  이는 pass의 기존 현실과 동급이다 — pass는 이미 tmux 세션에 임의 텍스트를 주입하는 앱이고,
  Claude Code 자체가 임의 명령을 실행한다. 위장하지 말고 명확히 고지한다.
- 방어선은 세 겹:
  1. **설치·활성화 시 검토** — 권한 목록과 (AI 생성물은) 파일 전문을 보여주고 명시적 동의.
  2. **권한 선언 강제** — 선언하지 않은 액션 종류는 런타임이 실행 거부.
  3. **프로젝트 로컬 익스텐션 금지(v1)** — clone만으로 코드가 실행되는 경로를 차단.
- `sendText`는 ReplyInjector의 bare-shell 거부를 그대로 상속 — 익스텐션이 쉘 프롬프트에
  명령을 흘리는 사고를 기존 로직이 막는다.
- v2 검토 항목: permission 프롬프트 **자동 응답** 액션 (`answer: "y"`). 가장 요구가 많을
  기능이지만 가장 위험하다. 넣는다면 패턴 allowlist + 별도 권한 + 감사 로그가 전제.

---

## 9. 배포와 공유 (git 기반)

- **설치 = git clone**: `pass-ext install <git-url>` 또는 Settings에서 URL 입력 →
  `~/.pass/extensions/<id>`로 clone → 검토 화면 → 활성화. 업데이트 = `git pull` + 재검토
  (diff 표시).
- 중앙 서버 없음. 필요해지면 큐레이션된 인덱스(JSON 한 파일, GitHub 저장소)로 시작.
- AI로 만든 익스텐션이 디렉토리 = git repo이므로, "만들고 → push하면 → 남이 설치"가 바로 성립.

---

## 10. 구현 마일스톤

기존 코드베이스가 ~6.7k LOC임을 감안한 상대 규모 추정.

| 단계 | 내용 | 신규 코드 (추정) |
|---|---|---|
| ~~**E0 스파이크**~~ | (E1–E3와 함께 진행) | — |
| ✅ **E1 로더/스토어** | `ExtensionManifest`(Codable+검증), `ExtensionStore`, Settings › Extensions 탭 (목록/토글/리로드/에러 표시) | ~500 LOC |
| ✅ **E2 명령** | ⌘P `>명령` 라우팅, 템플릿 변수 확장, 액션 실행 (script/terminal/sendText/notify/openURL), 실행 로그 | ~450 LOC |
| ✅ **E3 이벤트 규칙** | `ExtensionRuntime` — EventRouter·SessionStore 탭, 규칙 매칭(on/if), 액션 디스패치 | ~300 LOC |
| **E4 AI 빌더** | EXTENSION_API.md, `pass-ext validate`, 생성 플로우(세션 생성+계약 프롬프트+Stop 감지), 검토·활성화 UI, rework 루프 | ~450 LOC + 문서 |
| **E5 상주 프로세스 + 에이전트** | 프로세스 감독(spawn/restart/log), 이벤트 push(HTTP), `/ext/api`, 에이전트 기여를 AgentRegistry에 연결 — codex/pi 어댑터를 번들 익스텐션으로 이관(M5 합류) | 설계 후 산정 |
| **E6 공유** | git install/update UI, 재검토 diff | ~250 LOC |

E0→E4까지가 "AI로 익스텐션을 만들어 쓰는" 최소 완결 경험이다. E4는 E2·E3 위에서만 의미가
있으므로 순서를 바꾸지 않는다.

---

## 11. 열린 질문 (추천안 포함)

1. **Tier 2 통신: HTTP push vs WebSocket?** — 추천: 기존 HookServer(FlyingFox) 재사용 관점에서
   v1은 단방향 HTTP POST(pass→ext)와 폴백 폴링. WebSocket은 필요가 증명되면.
2. **JavaScriptCore 임베드 안?** — 비추천. 크래시 격리·언어 자유·검토 용이성 모두 프로세스
   모델이 우세하고, pass 철학(프로세스+HTTP+JSON)과 정합. VS Code가 JS 런타임을 쓴 건
   에디터 DOM과의 밀결합 때문인데 pass에는 그 결합이 없다.
3. **이벤트 동기 개입** (규칙이 attention을 삼키거나 자동 응답) — v1은 순수 관찰자(fire-and-forget).
   §8의 v2 항목으로만.
4. **프로젝트 로컬 익스텐션** — 팀 공유엔 매력적이지만 v1 금지 유지. 허용한다면 "저장소별 명시적
   신뢰 + 커밋 해시 고정" 같은 장치가 선행되어야 한다.
5. **명령의 인자** (`>deploy staging` 처럼) — v1은 무인자, `${input}` 한 개 정도는 E2에서 저비용으로
   추가 가능. 팔레트 UX를 보고 결정.
6. **번들 익스텐션** — notify 사운드, 세션 자동 정리(오래된 shell 세션 킬 제안) 같은 것을 번들
   익스텐션으로 출하하면 API의 dogfooding이 된다. E2~E3에서 최소 2개를 번들로 만들며 API를 다듬을 것.
