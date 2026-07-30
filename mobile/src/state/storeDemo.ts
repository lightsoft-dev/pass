import type { PairedDesktop } from "../protocol/types";
import type { RemoteState } from "./reducer";

const capturedAt = "2026-07-25T09:41:00.000Z";

export const storeDemoPairedDesktop: PairedDesktop = {
  protocolVersion: 1,
  relayUrl: "https://relay.pass.lightsoft.dev",
  desktopId: "studio_mac",
  desktopName: "Studio Mac",
  deviceId: "store_demo_phone",
  credential: "store-demo",
  authenticationMode: "device",
  credentialExpiresAt: "2026-07-25T10:00:00.000Z",
  refreshCredential: "store-demo-refresh",
  refreshExpiresAt: "2026-08-24T09:41:00.000Z",
  scopes: [
    "sessions:read",
    "sessions:write",
    "sessions:stream",
    "sessions:terminal",
    "projects:read",
    "decisions:answer",
  ],
  pairedAt: "2026-07-20T02:15:00.000Z",
};

export const storeDemoState: RemoteState = {
  connection: {
    phase: "online",
    attempt: 0,
    desktopOnline: true,
    lastConnectedAt: capturedAt,
  },
  sessionsByName: {
    "pass-mobile": {
      name: "pass-mobile",
      displayName: "Pass Remote",
      defaultDisplayName: "Pass Remote",
      projectRoot: "/Users/zimin/lightsoft-projects/pass",
      cwd: "/Users/zimin/lightsoft-projects/pass/mobile",
      agent: "codex",
      gitBranch: "feat/mobile-store",
      attention: {
        status: "decision",
        receivedAt: "2026-07-25T09:39:00.000Z",
        preview: "Allow the release build to upload artifacts to Expo EAS?",
      },
      lastMessage:
        "The release checks passed. I’m ready to upload the signed Android bundle and continue with the iOS archive.",
      lastActivity: "2026-07-25T09:39:00.000Z",
      isAttached: true,
      unacknowledged: true,
      launching: false,
    },
    "client-dashboard": {
      name: "client-dashboard",
      displayName: "Client Dashboard",
      defaultDisplayName: "Client Dashboard",
      projectRoot: "/Users/zimin/lightsoft-projects/client-dashboard",
      cwd: "/Users/zimin/lightsoft-projects/client-dashboard",
      agent: "claude",
      gitBranch: "feat/analytics",
      attention: {
        status: "working",
        receivedAt: "2026-07-25T09:36:00.000Z",
        preview: "Building the analytics cards and checking responsive layouts.",
      },
      liveMessage:
        "I’ve completed the responsive dashboard layout and I’m running the final accessibility checks now.",
      lastMessage:
        "Implemented the analytics overview with responsive cards, loading states, and keyboard navigation.",
      lastActivity: "2026-07-25T09:38:30.000Z",
      isAttached: true,
      unacknowledged: false,
      launching: false,
    },
    "api-refactor": {
      name: "api-refactor",
      displayName: "API Refactor",
      defaultDisplayName: "API Refactor",
      projectRoot: "/Users/zimin/lightsoft-projects/platform-api",
      cwd: "/Users/zimin/lightsoft-projects/platform-api",
      agent: "claude",
      gitBranch: "refactor/auth",
      attention: {
        status: "finished",
        receivedAt: "2026-07-25T09:25:00.000Z",
        preview: "Authentication refactor completed with all integration tests passing.",
      },
      lastMessage:
        "Finished the authentication refactor. **42 tests passed** and the migration guide is ready for review.",
      lastActivity: "2026-07-25T09:25:00.000Z",
      isAttached: false,
      unacknowledged: false,
      launching: false,
    },
  },
  projectsByRoot: {
    "/Users/zimin/lightsoft-projects/pass": {
      rootPath: "/Users/zimin/lightsoft-projects/pass",
      name: "Pass",
      emoji: "⌁",
    },
    "/Users/zimin/lightsoft-projects/client-dashboard": {
      rootPath: "/Users/zimin/lightsoft-projects/client-dashboard",
      name: "Client Dashboard",
      emoji: "◫",
    },
    "/Users/zimin/lightsoft-projects/platform-api": {
      rootPath: "/Users/zimin/lightsoft-projects/platform-api",
      name: "Platform API",
      emoji: "◇",
    },
  },
  capabilities: storeDemoPairedDesktop.scopes,
  pendingCommands: {},
  activities: [
    {
      id: "store-user-message",
      kind: "message",
      title: "Message sent from mobile",
      detail: "Prepare the production builds and summarize anything blocking store submission.",
      session: "pass-mobile",
      at: "2026-07-25T09:34:00.000Z",
      status: "delivered",
    },
    {
      id: "store-dashboard-message",
      kind: "message",
      title: "Message sent from mobile",
      detail: "Finish the responsive dashboard and run accessibility checks.",
      session: "client-dashboard",
      at: "2026-07-25T09:31:00.000Z",
      status: "delivered",
    },
  ],
  messageStreamsBySession: {
    "client-dashboard": {
      messageID: "msg_store_live",
      sequence: 8,
      text:
        "I’ve completed the responsive dashboard layout.\n\n- Added adaptive cards for phone and desktop\n- Improved keyboard navigation\n- Verified color contrast\n\nRunning the final accessibility checks now…",
      truncated: false,
      phase: "streaming",
      updatedAt: "2026-07-25T09:38:30.000Z",
    },
  },
  terminalsBySubscription: {},
  voice: { status: "idle", turns: [], actions: [] },
  lastSyncedAt: capturedAt,
  latestSequence: 128,
  protocolErrors: 0,
};
