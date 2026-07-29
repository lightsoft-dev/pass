# Usage Leaderboard

`⌘P`에서 `>usage-leaderboard`를 실행하면 Claude Code, Codex, Pi의 로컬 로그에서 최근
30일 토큰 사용량을 집계하고 7일·30일 Pass 사용자 랭킹을 보여줍니다.

## 개인정보와 공유

- 창을 여는 것만으로는 아무 데이터도 업로드하지 않습니다.
- **내 사용량 공유**를 누를 때 날짜·에이전트별 input/output/cache 토큰 합계만 Pass relay로
  전송합니다.
- 프롬프트, 답변, 프로젝트 경로·이름, 세션 ID, 모델명, 비용은 수집 결과와 서버 요청에
  포함하지 않습니다.
- **공유 중지**를 누르면 계정의 서버 집계와 랭킹 참가 정보가 삭제됩니다.
- Pass 로그인 상태가 필요합니다. 인증 토큰은 익스텐션에 전달되지 않고 Pass가 허용된 usage
  API 요청만 대신 수행합니다.

## 파일

- `extension.json` — 창, 명령, 로컬 집계와 제한된 Pass API 액션 선언
- `scripts/collect_usage.py` — 로컬 JSONL 로그를 읽어 일별 합계 JSON 생성
- `ui/index.html`, `ui/styles.css`, `ui/app.js` — 네트워크 접근 없는 랭킹 창

## 권한

- `ui:window` — 독립 랭킹 창
- `run:script` — 로컬 로그를 읽는 번들 Python 집계기
- `network:pass-api` — `v2/usage/*` 허용 목록에 한정된 인증 요청

## 수동 테스트

1. Settings › Extensions에서 설치 후 파일과 권한을 검토하고 활성화합니다.
2. `⌘P` → `>usage-leaderboard`를 실행합니다.
3. 로컬 합계가 보이고 아직 랭킹에 참여하지 않은 상태인지 확인합니다.
4. **내 사용량 공유** 후 내 행과 순위가 보이는지 확인합니다.
5. 7일/30일 전환 후 **공유 중지**를 눌러 내 행이 제거되는지 확인합니다.
