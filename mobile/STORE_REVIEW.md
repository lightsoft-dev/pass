# Pass Remote store review access

Pass Remote normally requires a same-account Mac and a single-use QR code that expires after five
minutes. Reviewers do not need credentials or a live Mac: the production app contains an isolated,
read-only store review demo.

## Reviewer steps

1. Launch the app on iPhone, iPad, or Android.
2. On the sign-in screen, tap **Explore demo**.
3. Use the labeled navigation to inspect **Inbox**, **Chat**, **Decision**, **Terminal**, and
   **Security**.
4. Tap **Exit demo** in the persistent purple banner to return to real sign-in.

The purple `DEMO` banner remains visible throughout the preview. Every name, project, command,
conversation, terminal line, and device is synthetic data bundled with the app. Entering the demo
does not authenticate, create an account, claim a pairing code, open a socket, call the Relay, read
SecureStore, or send a command. Decision buttons only update temporary on-screen state, messaging
and device revocation are disabled, and leaving the route discards the preview state.

## Google Play App access instructions

Use this text in **Policy and programs > App content > App access**:

> No login credentials are required for review. From the first sign-in screen, tap “Explore demo.”
> The persistent purple DEMO banner confirms that the app is showing bundled synthetic data. Use
> Inbox, Chat, Decision, Terminal, and Security to inspect the complete remote-session interface,
> then tap “Exit demo.” The demo does not connect to an account, network service, or Mac, and cannot
> send commands. Live use requires the same user to sign in on a Mac and scan a five-minute QR code,
> so no reusable production credentials exist to share.

Select the restricted-access declaration because live remote control still requires account and
device pairing, then provide the steps above. Attach a screenshot of the sign-in screen with the
**Explore demo** button if the console offers a supporting-file field.

## App Store Connect review notes

Use this text in **App Review Information > Notes**:

> A review account is not required. On the initial sign-in screen, tap “Explore demo” to inspect
> the complete UI with local synthetic sessions. The purple DEMO banner is always visible and its
> “Exit demo” button returns to real sign-in. The demo performs no authentication or network calls
> and cannot send terminal commands. Production remote access uses short-lived, device-scoped
> credentials obtained only after the same user signs in on a Mac and scans a single-use QR code
> that expires in five minutes.

Do not put a real Google/Apple account, pairing QR, Relay token, or desktop credential in either
store's review fields.
