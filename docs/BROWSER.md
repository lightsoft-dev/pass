# M6 설계 — 내장 브라우저 + `passcli` CLI

> Status: **구현 완료(M6.1–M6.4), 온디바이스 검증 대기.** 이 문서가 M6의 계약이다.
> 머지 전 S6 스파이크(§10)를 실기기에서 실행해 위험 가정을 검증한다 — S0(FINDINGS.md)과
> 같은 방식. 결과에 따라 이 문서와 구현을 함께 갱신한다.

## 1. 배경과 목표

pass는 에이전트 세션의 관제탑이지만, 에이전트가 만든 **결과물을 보는 창**이 없다.
dev 서버 미리보기, PR 페이지, CI 로그, 에러 페이지 — 지금은 전부 Chrome으로 이탈한다.
스펙 문서 화면(M4)의 "Dev 미리보기"도 서버만 띄울 뿐 화면은 밖에서 봐야 한다.

**목표**

1. **내장 브라우저** — 선택된 세션의 터미널 *옆에* 웹 페이지를 띄운다(WKWebView).
   에이전트가 작업 중인 것과 그 결과 화면을 한 패널에서 같이 본다.
2. **`passcli` CLI** — 세션 안의 AI 에이전트가 `passcli browser open <url>` 한 줄로
   사용자의 pass 브라우저에 페이지를 띄운다. "제가 만든 거 여기서 확인하세요"가
   에이전트의 어휘가 된다.
3. **에이전트 관찰 루프(v1.5)** — `screenshot` / `read`로 에이전트가 그 페이지를
   다시 읽어 스스로 검증한다(프론트엔드 verify 루프).

**비목표 (명시적으로 안 하는 것)**

- **브라우저 자동화 아님.** 클릭/입력/JS 주입(`js`, `click` 등)은 만들지 않는다.
  자동화가 필요한 에이전트는 자기 도구(Playwright, chrome-devtools MCP)를 쓰면 된다.
  pass의 브라우저는 **에이전트와 사람이 공유하는 화면**이다 — pass가 제공하는 동사는
  "보여주기(open)"와 "관찰(screenshot/read)"까지.
- 탭 스트립, 북마크, 다중 창 — v2. v1은 세션당 활성 페이지 1개 + 최근 URL 회상.
- 다운로드 관리 — HTML이 아닌 응답은 기본 브라우저로 넘긴다.
- Safari/Chrome 프로필·쿠키 공유 — pass 전용 저장소만 쓴다.

## 2. 사용 시나리오

1. **에이전트가 결과를 보여준다** — Claude가 `npm run dev`를 띄우고
   `passcli browser open http://localhost:5173` 실행 → 숨어 있던 패널이 (포커스를
   뺏지 않고) 떠오르고, 그 세션 터미널 오른쪽에 페이지가 열린다.
2. **사람이 옆에 두고 본다** — ⌘B로 브라우저 스플릿을 열고 ⌘L에 URL 입력.
   PR 리뷰 페이지를 옆에 두고 세션에 회신한다.
3. **에이전트 자가 검증(v1.5)** — 에이전트가 `passcli browser screenshot -o /tmp/ui.png`
   → 파일을 Read → 스타일 깨짐을 스스로 발견하고 고친다. 사용자는 같은 화면을 실시간으로 본다.
4. **스펙 문서 연계** — SpecsView의 Dev 미리보기 실행 후 "브라우저에서 열기" 버튼이
   dev 서버 URL을 같은 브라우저 스플릿에 띄운다.

## 3. 아키텍처 개요

기존 파이프라인에 **관제 평면 하나(`/cli/*`)와 표시 평면 하나(BrowserPane)** 를 얹는다.
새 프로세스·새 포트 없음 — 루프백 서버(49817)와 패널을 그대로 재사용한다.

```
agent (tmux, PASS_SESSION=pass-myapp)
   │  "$PASS_CLI" browser open http://localhost:5173
   ▼
passcli ──POST /cli/browser/open──►  HookServer (127.0.0.1:49817)
                                         │  CLIHandlers (기존 ShareHandlers 패턴)
                                         ▼
                                    BrowserStore (@MainActor, 탭 = 데이터)
                                         │
                          ┌──────────────┴──────────────┐
                          ▼                             ▼
                 WebViewPool (WKWebView LRU,     panel: SessionWorkspaceView
                  TerminalPool과 동형)            = terminal │ browser 스플릿
```

- **탭은 데이터, 웹뷰는 풀.** `BrowserTab`(id, url, title, sessionName)은 가볍게 여러 개
  유지하고, 무거운 WKWebView는 LRU 풀(기본 4개)로만 살린다 — TerminalPool과 같은 원리.
- **세션 스코프.** 모든 탭은 세션에 귀속된다(`sessionName`). v1에서 무소속(글로벌) 탭은
  없다 — 대상 세션을 못 찾으면 CLI가 명확한 에러를 돌려준다(§7).

## 4. Part A — 내장 브라우저

### 4.1 모델과 스토어

```swift
// Sources/Pass/Core/Models.swift 에 추가
struct BrowserTab: Identifiable, Hashable, Sendable {
    let id: UUID
    var sessionName: String     // 귀속 세션 (v1: 필수)
    var url: URL                // 마지막으로 지시된/탐색된 URL
    var title: String?          // WKWebView.title 미러
    var lastVisited: Date
}

// Sources/Pass/Stores/BrowserStore.swift (신규)
@MainActor @Observable
final class BrowserStore {
    private(set) var tabs: [BrowserTab] = []
    /// 세션별 활성 탭. v1 UI는 이것 하나만 그린다.
    private(set) var activeTabBySession: [String: UUID] = [:]
    /// CLI가 페이지를 연 뒤 사용자가 아직 안 본 세션 — 행에 🌐 점 배지.
    private(set) var unseenBySession: Set<String> = []
    /// 세션별 최근 URL 히스토리 (탭 스트립 대신 회상 메뉴, 최대 20개).
    private(set) var recentURLsBySession: [String: [URL]] = [:]

    @discardableResult
    func open(url: URL, session: String, reuse: Bool = true) -> BrowserTab
    func close(session: String)                    // 활성 탭 제거 + 웹뷰 해제
    func markSeen(_ session: String)
    func pruneSessions(alive: Set<String>)         // 죽은 세션의 탭/웹뷰 정리
}
```

- `open(reuse: true)`(기본)는 그 세션의 활성 탭 URL을 **교체**한다. 에이전트가 루프 안에서
  여러 번 열어도 탭이 늘어나지 않는다. `reuse: false`(새 탭)는 v2에서 탭 UI와 함께.
- `pruneSessions`는 SessionStore reconcile에서 호출 — `TerminalPool.prune(keeping:)`과 동형.
- 영속화: `SessionStatePersistence.Snapshot`에 `browserURLs: [String: String]?` 필드 추가
  (옵셔널 — 기존 state.json 하위호환 규칙 그대로). 재시작 시 활성 탭 URL만 복원하고
  웹뷰는 처음 보일 때 로드한다.

### 4.2 WebViewPool

`Sources/Pass/UI/Browser/WebViewPool.swift` (신규). TerminalPool을 그대로 본뜬다.

- 탭 id → `WKWebView` LRU, 상한 **4** (웹뷰는 프로세스+메모리가 비싸다).
- 전 웹뷰 공통: 하나의 `WKProcessPool`, **앱 전용 persistent `WKWebsiteDataStore`**
  (Safari와 분리, 재시작 후 로그인 유지). Settings에 "웹 데이터 지우기" 버튼.
- `isInspectable = true` (개발자 도구 우클릭 → Inspect).
- `navigationDelegate`: title/URL 변화를 BrowserStore로 미러링, HTML이 아닌 응답
  (`navigationResponse`)과 `target=_blank`는 각각 기본 브라우저로 넘기거나 제자리 로드.
- `WKUIDelegate`: JS alert/confirm → 네이티브 시트.
- `file://`는 `loadFileURL(_:allowingReadAccessTo:)`로 디렉터리 접근 허용(비샌드박스 앱).

### 4.3 UI — SessionWorkspaceView (터미널 │ 브라우저)

터미널이 그려지는 세 자리(홈 stack 카드, list/sidebar의 terminalPanel, SessionDetailView)를
얇은 래퍼 하나로 감싼다:

```
SessionWorkspaceView(session:, terminal:)
 ├─ TerminalPaneView(controller:)          // 기존 그대로
 └─ (활성 탭 있고 표시 on일 때) BrowserPaneView(tab:)
      ├─ 툴바: ◀ ▶ ⟳ | URL 필드(⌘L) | 최근 URL 메뉴 | ↗ 기본 브라우저 | ✕ 닫기
      └─ WKWebView (WebViewPool에서 획득)
```

- **스플릿**: 좌 터미널 / 우 브라우저, 드래그 가능한 디바이더, 기본 브라우저 45%.
  비율은 `UserDefaults("browser.split")`로 영속(패널 크기와 같은 방식).
- **⌘B** — 선택 세션의 브라우저 표시 토글. 탭이 없으면 빈 탭 + URL 필드 포커스.
- **⌘L** — 브라우저가 보일 때 URL 필드로 포커스 이동(생략 스킴 보정은 §7.1 규칙).
- **⌘⇧B** — 브라우저 확대 토글(터미널을 잠시 접고 전폭). 다시 누르면 스플릿 복귀.
- **키보드 소유권은 기존 규칙 유지**: 일반 키는 터미널 소유. 웹 페이지 입력은 클릭으로
  포커스를 옮긴 뒤(패널이 key가 되므로 동작), 터미널 클릭/⌘P로 되돌아온다.
  ◀▶는 툴바 버튼 + (웹뷰 포커스 시) 표준 ⌘←/⌘→만 — 터미널의 방향키를 건드리지 않는다.
- `PanelNavKey`에 `toggleBrowser`(⌘B), `focusAddress`(⌘L), `expandBrowser`(⌘⇧B) 추가,
  SummonPanel.performKeyEquivalent → CommandView.handleNav 경유(기존 ⌘D/⌘N/⌘T와 동일 경로).

### 4.4 표면화(surfacing) 규칙 — CLI open이 도착했을 때

CommandView가 지키는 원칙("터미널이 조용히 다른 세션으로 바뀌지 않는다")을 그대로 따른다.

| 패널 상태 | 동작 |
|---|---|
| 숨김 | 패널 표시 + 대상 세션 preselect(알림 클릭과 같은 `pendingPreselect` 경로) + 스플릿 열기. 패널은 비활성화 패널이므로 에디터 포커스를 뺏지 않는다. |
| 표시 중 & 대상 세션 선택됨 | 스플릿 열고 URL 로드. 끝. |
| 표시 중 & 다른 세션 선택됨 | **선택을 훔치지 않는다.** 백그라운드 로드 + 그 세션 행에 🌐 배지(`unseenBySession`). 선택하면 배지 해제 + 스플릿 표시. |
| `--background` 플래그 | 어느 경우든 표면화 없이 로드 + 배지만. |

- 브라우저 open은 **attention 이벤트가 아니다**(decision/input/finished 불변) — FYI다.
  알림도 쏘지 않는다. 조용히 나타나는 것 자체가 신호.
- 같은 세션에 연속 open(에이전트 루프)은 탭 재사용 + 재표면화 애니메이션 생략(디바운스).

## 5. Part B — `passcli` CLI

### 5.1 이름과 형태

- 바이너리 이름 **`passcli`**. `pass`는 유닉스 패스워드 매니저(`brew install pass`)와
  충돌하므로 쓰지 않는다. "앱 이름 + cli"로 읽혀 에이전트에게 역할이 자명하다.
- **Swift 실행 파일 타깃 `PassCli`** (`Sources/PassCli/`), 의존성은
  `swift-argument-parser` 하나. `--help`가 곧 에이전트용 문서이므로 서브커맨드/플래그
  도움말 품질이 중요하다 — 셸 스크립트+curl로는 부족.
- 앱 번들에 내장: `Pass.app/Contents/MacOS/passcli` (project.yml의 Pass 타깃
  postBuildScript가 빌드 산출물을 복사 — 스크립트 페이즈는 앱 코드사인 전에 돌므로 번들
  seal에 포함된다. passcli 자체는 같은 Apple Development 아이덴티티로 서명 — BUILD.md 규칙).

### 5.2 배포와 발견 — 에이전트가 이 도구를 어떻게 아는가

설치 없는 경로를 기본으로, 세 겹:

1. **안정 경로 심링크** — 앱이 실행될 때마다 `~/.pass/bin/passcli` →
   `<현재 번들>/Contents/MacOS/passcli` 심링크를 갱신한다. 앱을 옮겨도/빌드 산출물로
   실행해도 항상 유효한 고정 경로가 생긴다.
2. **세션 환경변수** — 세션 생성 시 `tmux new-session -e PASS_CLI=~/.pass/bin/passcli`
   추가(`PASS_SESSION`과 같은 줄). 어댑트된 세션에는 `adoptTag`의
   `set-environment`로 주입. rc 파일이 PATH를 재구성해도(macOS `path_helper` 이슈,
   FINDINGS의 GUI/PATH 계열 gotcha) 환경변수는 살아남는다 → 에이전트는
   `"$PASS_CLI" browser open …`으로 호출하면 항상 안전.
   `-e PATH=` 조작은 하지 않는다(셸 rc가 덮어써 신뢰 불가).
3. **SessionStart advertise 훅 (발견의 핵심)** — ClaudeHooksInstaller에 **command 타입**
   SessionStart 훅을 추가(머지·백업·멱등 규칙 동일):

   ```json
   { "hooks": { "SessionStart": [ { "hooks": [
       { "type": "command", "command": "$HOME/.pass/bin/passcli advertise", "timeout": 5 }
   ] } ] } }
   ```

   `passcli advertise`는 `PASS_SESSION`이 없거나 pass가 안 떠 있으면 **아무것도 출력하지
   않고 0으로 종료**(비-pass 세션에 소음 0). 있으면 SessionStart `additionalContext`
   JSON을 출력해 에이전트 컨텍스트에 한 단락을 심는다:

   > pass's embedded browser is available beside this terminal. Show the user any URL with
   > `"$PASS_CLI" browser open <url>` (e.g. your dev server). Capture what they see with
   > `"$PASS_CLI" browser screenshot -o <path>` and Read the file to verify your UI work.

   주의: S0에서 **HTTP 타입** SessionStart는 발화하지 않음이 확인됐다(FINDINGS §1) —
   command 타입은 별개 경로라 동작이 기대되지만, **S6.4에서 실측 필수**.
4. (선택) Settings › "Install CLI" — `/usr/local/bin/passcli` 심링크(관리자 권한).
   pass 밖 일반 터미널에서 사람이 쓸 때용.

### 5.3 명령 집합

```
passcli browser open <url> [--session <name>] [--background] [--json]
passcli browser close [--session <name>] [--json]
passcli browser tabs [--json]
passcli browser screenshot [-o <path>] [--session <name>] [--json]   # v1.5
passcli browser read [--format text|html] [--session <name>]         # v1.5
passcli status [--json]        # pass 실행 여부 + 버전 + 포트
passcli advertise              # SessionStart 훅 전용 (§5.2)
```

- **세션 결정 순서**: `--session` 플래그 → `$PASS_SESSION` → (`$TMUX`가 있으면)
  `tmux display-message -p '#S'` → 실패 시 exit 2 + "no target session" 안내.
  tmux 폴백 덕에 PASS_SESSION 주입 전에 시작된 어댑트 세션에서도 동작한다.
- **출력**: 기본은 사람용 한 줄(`opened http://localhost:5173 · session pass-myapp`),
  `--json`은 서버 응답 그대로. 에러는 stderr.
- **종료 코드**: `0` 성공 · `1` 서버가 거부(본문에 이유) · `2` 사용법/세션 미결정 ·
  `3` pass 미실행(connection refused — "pass가 실행 중인지 확인하세요" 안내).
- 포트는 `PASS_PORT` 환경변수로 오버라이드 가능(기본 49817, `PassConfig.hookPort`).

### 5.4 HTTP 프로토콜 — `/cli/*`

기존 루프백 서버에 라우트 추가. ShareAPI와 같은 꼴: `Sources/Pass/Server/CLIAPI.swift`에
Codable 요청/응답 + `@MainActor` 핸들러, HookServer에는 `CLIHandlers` 클로저 구조체로 주입
(ShareHandlers와 동형; PassCli 타깃은 프레임워크 공유 없이 구조체를 미러 복사 —
PassShare와 같은 규칙, 파일 주석으로 동기화 의무 명시).

```
POST /cli/browser/open
  { "session": "pass-myapp", "url": "http://localhost:5173", "background": false }
  → { "ok": true, "tabId": "…", "resolvedURL": "http://localhost:5173/" }
  → { "ok": false, "error": "unknown session 'pass-x' — passcli browser tabs로 확인" }

POST /cli/browser/close      { "session": "pass-myapp" }            → { "ok": true }
GET  /cli/browser/tabs                                              → { "ok": true, "tabs": [ {id,url,title,session,unseen} ] }
POST /cli/browser/screenshot { "session": "…", "path": "/abs.png" } → { "ok": true, "path": "/abs.png" }   # v1.5
POST /cli/browser/read       { "session": "…", "format": "text" }   → { "ok": true, "content": "…" }       # v1.5, 512KB 상한
```

- 항상 200 + JSON 본문(`ok`/`error`) — 훅 서버의 "에이전트를 기다리게 하지 않는다"
  원칙과 달리 CLI는 **요청-응답**이므로 결과를 담아 돌려준다(open은 로드 완료가 아니라
  탭 생성+로드 시작 시점에 응답).
- `screenshot`: `path` 생략 시 pass가 `~/.pass/screenshots/<session>-<ts>.png`에 쓰고
  경로를 돌려준다 → CLI는 경로만 stdout에 출력(`open $(passcli browser screenshot)` 합성 가능).
  상대 경로는 CLI가 절대화해서 보낸다. 뷰포트 캡처(`takeSnapshot`); 전체 페이지는
  `createPDF` 기반 `passcli browser pdf`로 v2 후보.
- `read`: `document.body.innerText`(text) / `outerHTML`(html) evaluateJavaScript 1회.

## 6. 보안·신뢰 모델

- **권한 상승 없음이 핵심 논거.** pass 세션의 에이전트는 이미 사용자 권한의 비샌드박스
  셸이다 — tmux를 직접 조작해 어떤 세션에든 키를 보낼 수 있고 화면 전체 캡처도 가능하다.
  `passcli`은 새 능력을 부여하는 게 아니라 **의도를 구조화**한다(임의 AppleScript 대신
  선언적 open). 루프백 전용 바인딩(127.0.0.1)·무인증은 기존 `/hook/*`·`/share/*`와 동일
  자세를 유지하고, 공유 시크릿 도입은 서버 전체 차원의 후속 과제로 남긴다.
- **스킴 화이트리스트**: `http` `https` `file`만. `javascript:` 등은 서버에서 거부.
  URL 길이 8KB 상한, 본문 64KB 상한.
- **JS 주입 동사 없음**(§1 비목표). `read`/`screenshot`은 표시 중인 페이지의 관찰일 뿐.
  단, pass 브라우저에 로그인한 페이지도 에이전트가 읽을 수 있다는 사실을 Settings 문구로
  명시한다("이 브라우저 화면은 세션의 에이전트가 읽을 수 있습니다").
- 웹 콘텐츠 → pass 방향 브리지 없음(`WKScriptMessageHandler`는 v1.5 콘솔 수집 전까지
  등록하지 않고, 등록 후에도 수신 전용).

## 7. 동작 규칙·엣지 케이스

### 7.1 URL 정규화 (CLI와 ⌘L 공통, 순수 함수로 구현+테스트)

| 입력 | 해석 |
|---|---|
| `http(s)://…`, `file://…` | 그대로 |
| `:5173`, `5173` (숫자만) | `http://localhost:5173` |
| `localhost[:port][/path]` | `http://` 접두 |
| `foo.com/bar` | `https://` 접두 |
| `./dist/index.html`, `/abs/path.html` | 존재 확인 후 `file://` (CLI가 절대화) |
| 그 외 스킴 | 거부(`ok:false, error:"scheme not allowed"`) |

### 7.2 생명주기

- 세션 kill/소멸 → reconcile의 `pruneSessions`가 탭·웹뷰·배지 정리(터미널 풀과 동시).
- 앱 재시작 → 세션별 마지막 URL만 복원(§4.1), 웹뷰는 지연 생성.
- 패널 숨김 → 웹뷰는 풀에 유지(오디오 재생 등은 WebKit 기본 정책에 따름). LRU 초과로
  해제된 웹뷰는 다음 표시 때 URL 재로드(뒤로가기 히스토리는 잃는다 — 문서화).
- `open` 대상 세션이 launching placeholder면: 탭은 만들되 스플릿은 실세션 등장 후 표시.

### 7.3 스펙 문서 연계

`startSpecPreview` 성공 후 SpecsView 헤더에 "브라우저에서 열기" 버튼 — dev 서버 URL을
그 프로젝트의 활성 세션 탭으로 open. URL은 spec 문서의 `development.url` 필드(신규,
옵셔널)에서 읽고, 없으면 명령 출력에서 추정하지 않는다(부정확한 추측 금지 — 버튼 비활성).

## 8. 구현 계획 (파일 단위)

**신규**

| 파일 | 내용 |
|---|---|
| `Sources/Pass/Stores/BrowserStore.swift` | 탭 상태·배지·회상·영속화 (§4.1) |
| `Sources/Pass/UI/Browser/WebViewPool.swift` | WKWebView LRU 풀 (§4.2) |
| `Sources/Pass/UI/Browser/BrowserPaneView.swift` | 툴바+웹뷰 NSViewRepresentable |
| `Sources/Pass/UI/Browser/SessionWorkspaceView.swift` | 터미널│브라우저 스플릿 (§4.3) |
| `Sources/Pass/Server/CLIAPI.swift` | `/cli/*` Codable + 핸들러 (§5.4) |
| `Sources/Pass/Core/URLNormalizer.swift` | §7.1 순수 함수 |
| `Sources/PassCli/…` | CLI 타깃(main + Browser/Status/Advertise 커맨드) |

**수정**

| 파일 | 변경 |
|---|---|
| `Server/HookServer.swift` | `CLIHandlers` 주입 + `/cli/*` 라우트 |
| `App/AppDelegate.swift` | BrowserStore/CLI 핸들러 배선, `~/.pass/bin` 심링크 갱신 |
| `App/AppModel.swift` | `browser` 스토어 노출, `openBrowser(url:session:background:)` 표면화 규칙(§4.4) |
| `Core/Models.swift` | `BrowserTab` |
| `Core/Constants.swift` | `cliEnvVar = "PASS_CLI"`, `cliSymlinkPath`, 상한 상수 |
| `Core/TmuxClient.swift` | `new-session`/`adoptTag`에 `PASS_CLI` 주입 (§5.2-2) |
| `Stores/SessionStore.swift` | reconcile → `browser.pruneSessions` |
| `Stores/SessionStatePersistence.swift` | `browserURLs` 필드(옵셔널) |
| `UI/Panel/SummonPanel.swift` | `PanelNavKey.toggleBrowser/.focusAddress/.expandBrowser` |
| `UI/Panel/CommandView.swift` | 워크스페이스 래퍼 적용, 배지, 키 라우팅 |
| `UI/Panel/SessionDetailView.swift` | 워크스페이스 래퍼 적용 |
| `UI/SettingsView.swift` | CLI 설치 행·advertise 토글·웹 데이터 지우기 |
| `Services/ClaudeHooksInstaller.swift` | SessionStart command 훅 머지(§5.2-3) |
| `project.yml` | `PassCli` tool 타깃 + swift-argument-parser + copyFiles 임베드 |

### 마일스톤

- **M6.1 브라우저 패널** — BrowserStore/WebViewPool/워크스페이스 스플릿, ⌘B·⌘L·⌘⇧B,
  URL 정규화, 영속화. (사람이 손으로 쓰는 브라우저 완성)
- **M6.2 CLI 관제 평면** — PassCli 타깃, `/cli/browser/open|close|tabs`, `status`,
  심링크·PASS_CLI 주입, 표면화 규칙. (에이전트가 열 수 있음)
- **M6.3 발견** — `advertise` + ClaudeHooksInstaller 머지, Settings UI.
- **M6.4 관찰 (v1.5)** — `screenshot`, `read`, 스펙 문서 연계 버튼, (여유 시) 콘솔 로그 수집.

## 9. 테스트 계획

기존 방식(순수 로직 단위 테스트, UI 미기동) 유지:

- `URLNormalizerTests` — §7.1 표 전체.
- `BrowserStoreTests` — open reuse/새 세션, close, pruneSessions, unseen 배지 전이,
  recentURLs 상한, 영속 스냅숏 왕복.
- `CLIAPITests` — 요청/응답 인코딩, 미지 세션·비허용 스킴·크기 상한 거부.
- `ClaudeHooksInstallerTests` 확장 — advertise 훅 머지 멱등성, 기존 훅 보존.
- PassCli: 인자 파싱·세션 결정 순서·종료 코드(서버는 로컬 목 URLSession).
- 수동 검증 스크립트: `PASS_DEBUG_OPEN`과 나란히 `PASS_DEBUG_BROWSER=<session>|<url>`
  런치 훅 추가 → 헤드리스로 스플릿 렌더 확인.

## 10. S6 스파이크 — 구현 전 검증할 가정

FINDINGS.md에 결과를 추가한다. 하나라도 깨지면 이 문서를 갱신하고 진행한다.

1. **S6.1 비활성화 패널 안의 WKWebView** — 클릭으로 key 전환 후 폼 입력·한글 IME·스크롤이
   정상인가? 터미널⇄웹뷰 포커스 왕복이 기존 단축키를 깨지 않는가?
2. **S6.2 숨김 패널 스냅숏** — 패널 `orderOut` 상태에서 `takeSnapshot`이 공백/스테일을
   반환하는가? (그렇다면 screenshot은 자동 표면화 후 캡처로 문서화 — §5.4 주석 반영)
3. **S6.3 tool 타깃 임베드+서명** — XcodeGen copyFiles(executables)로 넣은 passcli이
   Apple Development 서명·알림 code identity(BUILD.md)와 충돌 없이 동작하는가?
4. **S6.4 SessionStart command 훅** — HTTP와 달리 실제로 발화하는가(2.1.x)?
   `additionalContext`가 에이전트 컨텍스트에 실리는가? 발화 안 하면: 대안은
   `~/.claude/CLAUDE.md` 안내 문구 설치(사용자 승인 하에)로 강등.
5. **S6.5 어댑트 세션의 PASS_CLI** — `set-environment` 이후 새 프로세스에만 반영되는
   한계에서 tmux `display-message` 폴백(§5.3)이 실사용을 커버하는가?

## 11. 열린 질문 (구현 전 결정)

1. 쿠키 저장소 기본값 — persistent(로그인 유지, 현 설계) vs non-persistent(프라이버시).
   현 설계: persistent + Settings 지우기 버튼 + §6 고지.
2. advertise 훅을 "Install hooks" 원클릭에 포함할지, 별도 토글(기본 off)로 둘지.
   현 설계: 포함하되 Settings에서 개별 해제 가능.
3. 홈 stack 모드의 카드(높이 340) 안 스플릿은 좁다 — 카드에서는 브라우저를 숨기고
   list/sidebar/detail에서만 스플릿을 켜는 절충안 검토.
