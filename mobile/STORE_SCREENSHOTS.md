# Store screenshot capture plan

Capture these from a production-like preview build connected to a seeded test Mac. Do not use
generated or composited UI in place of the running app.

## Required exports

- iPhone 6.9-inch accepted size: 1290 x 2796 PNG
- iPad 13-inch accepted size: 2048 x 2732 PNG (the app declares tablet support)
- Android phone: 1080 x 1920 PNG (9:16)
- Google Play feature graphic: 1024 x 500 PNG
- No credentials, project secrets, personal paths, emails, or real terminal history in captures

## Gallery order

| Position | Capture | English caption | Korean caption |
| --- | --- | --- | --- |
| 1 | Session inbox with an online Mac and active sessions | Control your Mac sessions from anywhere | 어디서나 Mac 세션을 제어하세요 |
| 2 | Conversation view with a safe synthetic agent response | Stay in the loop without staying at your desk | 자리를 비워도 작업 흐름은 그대로 |
| 3 | Decision request with Allow once / Deny controls | Handle important requests right away | 중요한 요청에 바로 응답하세요 |
| 4 | Project and agent picker for a new session | Start the next task on your own Mac | 내 Mac에서 다음 작업을 시작하세요 |
| 5 | Interactive terminal using synthetic output | Drop into the terminal when precision matters | 정밀한 제어가 필요할 땐 터미널로 |
| 6 | Desktop/device security overview, not the settings-only hero | Pair once. Revoke whenever you choose. | 한 번 연결하고 언제든 해제하세요 |

The first three images are the primary storefront story. Capture both light localization sets from
the same seeded data and keep UI state, clock, device name, and connection status consistent.

## Seed data

- Desktop: `Studio Mac`
- Projects: `Pass`, `Design System`, `Relay`
- Sessions: `Ship remote console`, `Review authentication`, `Run release checks`
- Terminal output: a harmless release checklist with no filesystem paths or tokens
- Conversation: synthetic English/Korean text written for the screenshots

## Final checks

1. Capture after Google sign-in, account deletion, and reconnection pass on the preview build.
2. Verify every image at exact pixel dimensions and without alpha.
3. Keep captions to two lines at a readable store size.
4. Upload localized Korean and English sets; use the same gallery order on both stores.
5. Re-capture whenever the released UI materially changes.
