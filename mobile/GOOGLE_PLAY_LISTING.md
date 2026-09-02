# Google Play listing

## App details

- App name: `Pass mobile`
- Play Console app id: `4972209641706977884`
- Package name: `dev.lightsoft.passmobile`
- Default language: Korean (`ko-KR`)
- Initial pricing: Free
- Category: Productivity
- Contact website: `https://pass.lightsoft.dev`
- Privacy policy: `https://remote.pass.lightsoft.dev/privacy`
- Account deletion: `https://remote.pass.lightsoft.dev/account-deletion`

## Short description

Mac에서 실행 중인 Pass 개발 세션을 안전하게 확인하고 원격 제어하세요.

## Full description

Pass Remote는 내 Mac에서 실행 중인 개발 세션을 Android 휴대전화와 태블릿에서 확인하고
제어하는 Pass의 동반 앱입니다. Mac용 Pass와 같은 계정으로 로그인한 뒤 일회용 QR 코드를
스캔해 안전하게 연결하세요.

주요 기능:

- 데스크톱과 세션의 온라인 상태 확인
- Claude, Codex 및 터미널 작업 내용 확인
- 메시지 전송과 권한 요청 응답
- 등록된 프로젝트에서 새 세션 시작
- 정확한 TTY 제어가 필요할 때 대화형 터미널 사용
- 페어링 기기 해제 및 계정 영구 삭제

명령은 기기별 권한으로 제한된 Cloudflare Relay를 통해 전달됩니다. Pass는 명령이나 터미널
내용을 광고 또는 모델 학습에 사용하지 않습니다. 실제 작업은 Mac에서 실행되며 명령을
받으려면 Mac이 온라인이어야 합니다.

Pass Remote를 사용하려면 Mac용 Pass 앱이 필요합니다.

## Data safety answers to verify in Play Console

The final questionnaire must match the production build and provider contracts. Current code:

- collects account identifiers (Google subject, email, display name) for account management;
- collects app/device identifiers and desktop names for pairing and security;
- transmits user commands and terminal/session updates to provide remote-control functionality;
- encrypts data in transit;
- supports in-app deletion and a public authenticated web deletion path;
- does not use these data for advertising or model training;
- uses Google Sign-In, Cloudflare, and Expo Updates as service providers.

The completed Android version-code `7` AAB uses the previous application ID and is obsolete. It
must not be uploaded or submitted. Produce a new store build for `dev.lightsoft.passmobile` first.
The legacy Play record `4974358269922094715` remains attached to
`app.lightsoft.pass.remote`; do not upload a new build to it.

Create Android OAuth registrations for `dev.lightsoft.passmobile` and the EAS signing SHA-1. Add a
second registration after Play App Signing exposes the store signing SHA-1. The current EAS
signing SHA-1 is `5E:B8:3D:80:CA:44:8A:32:7C:22:17:2F:31:33:E6:9E:AF:22:C4:7D`.
