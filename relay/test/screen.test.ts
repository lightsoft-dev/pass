import { env, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import { generateScreenIceServers } from "../src/screen";

type Message = { type: string; id?: string; replyTo?: string; payload: Record<string, unknown> };

class Peer {
  private readonly inbox: Message[] = [];

  constructor(readonly socket: WebSocket) {
    socket.addEventListener("message", (event) => {
      if (typeof event.data === "string") this.inbox.push(JSON.parse(event.data) as Message);
    });
    socket.accept();
  }

  send(type: string, payload: Record<string, unknown>): string {
    const id = crypto.randomUUID();
    this.socket.send(JSON.stringify({
      version: 1,
      id,
      type,
      sentAt: new Date().toISOString(),
      payload,
    }));
    return id;
  }

  async next(type: string): Promise<Message> {
    const deadline = Date.now() + 2_000;
    while (Date.now() < deadline) {
      const index = this.inbox.findIndex((message) => message.type === type);
      if (index >= 0) return this.inbox.splice(index, 1)[0]!;
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    throw new Error(`Missing ${type}; received ${JSON.stringify(this.inbox)}`);
  }

  async none(type: string): Promise<void> {
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(this.inbox.some((message) => message.type === type)).toBe(false);
  }

  close(): void {
    if (this.socket.readyState === 1) this.socket.close(1000, "Test complete.");
  }
}

const peers: Peer[] = [];
afterEach(() => {
  for (const peer of peers.splice(0)) peer.close();
});

async function connect(
  desktopId: string,
  role: "desktop" | "mobile",
  deviceId: string,
  scopes: string[],
): Promise<Peer> {
  const room = env.DESKTOP_ROOMS.getByName(desktopId);
  const response = await room.fetch("https://relay.internal/connect", {
    headers: {
      Upgrade: "websocket",
      "X-Pass-Internal-Desktop-ID": desktopId,
      "X-Pass-Internal-Role": role,
      "X-Pass-Internal-Device-ID": deviceId,
      "X-Pass-Internal-Authorization": "device",
      "X-Pass-Internal-Scopes": JSON.stringify(scopes),
      "X-Pass-Internal-Credential-Expires-At": String(Date.now() + 60_000),
    },
  });
  expect(response.status).toBe(101);
  if (response.webSocket === null) throw new Error("WebSocket was not returned.");
  const peer = new Peer(response.webSocket);
  peers.push(peer);
  return peer;
}

describe("screen signaling", () => {
  it("generates short-lived Cloudflare TURN credentials without exposing the API token", async () => {
    const calls: Array<{ url: string; authorization: string | null; body: unknown }> = [];
    const request: typeof fetch = async (input, init) => {
      calls.push({
        url: String(input),
        authorization: new Headers(init?.headers).get("Authorization"),
        body: JSON.parse(String(init?.body)),
      });
      return Response.json({ iceServers: [
        { urls: ["stun:stun.cloudflare.com:3478"] },
        { urls: ["turn:turn.cloudflare.com:3478?transport=udp"], username: "temporary-user", credential: "temporary-secret" },
      ] }, { status: 201 });
    };
    const servers = await generateScreenIceServers(
      { TURN_KEY_ID: "test-key", TURN_KEY_API_TOKEN: "server-only-token" },
      request,
    );
    expect(calls).toEqual([{
      url: "https://rtc.live.cloudflare.com/v1/turn/keys/test-key/credentials/generate-ice-servers",
      authorization: "Bearer server-only-token",
      body: { ttl: 960 },
    }]);
    expect(servers[1]).toMatchObject({ username: "temporary-user", credential: "temporary-secret" });
    expect(JSON.stringify(servers)).not.toContain("server-only-token");
    await expect(generateScreenIceServers({ TURN_KEY_ID: "test-key" }, request))
      .rejects.toThrow("Incomplete TURN configuration");
  });

  it("requires screen scopes and explicit host approval before targeted SDP/ICE", async () => {
    const desktopId = `desk_screen_${crypto.randomUUID().replaceAll("-", "")}`;
    const host = await connect(desktopId, "desktop", desktopId, []);
    const qrDevice = await connect(desktopId, "mobile", "qr-device", ["sessions:read"]);
    const viewOnly = await connect(desktopId, "mobile", "view-device", ["screen:view"]);
    const controller = await connect(desktopId, "mobile", "controller-device", ["screen:view", "screen:control"]);
    const observer = await connect(desktopId, "mobile", "observer-device", ["screen:view", "screen:control"]);

    qrDevice.send("desktop.screen.open", { requestedControl: false });
    expect((await qrDevice.next("error")).payload).toMatchObject({ code: "scope.denied" });
    viewOnly.send("desktop.screen.open", { requestedControl: true });
    expect((await viewOnly.next("error")).payload).toMatchObject({ code: "scope.denied" });
    await host.none("desktop.screen.requested");

    controller.send("desktop.screen.open", { requestedControl: true });
    const pending = await controller.next("desktop.screen.pending");
    const sessionId = pending.payload.sessionId as string;
    expect(sessionId).toMatch(/^screen_/);
    expect((await host.next("desktop.screen.requested")).payload).toMatchObject({
      sessionId,
      deviceId: "controller-device",
      requestedControl: true,
    });
    await observer.none("desktop.screen.pending");

    observer.send("desktop.screen.open", { requestedControl: false });
    expect((await observer.next("error")).payload).toMatchObject({ code: "screen.busy" });
    controller.send("desktop.screen.offer", { sessionId, sdp: "v=0" });
    expect((await controller.next("error")).payload).toMatchObject({ code: "screen.not_approved" });
    await host.none("desktop.screen.offer");

    host.send("desktop.screen.approve", { sessionId, allowControl: true });
    expect((await host.next("desktop.screen.approved")).payload).toMatchObject({ sessionId, canControl: true });
    const approved = await controller.next("desktop.screen.approved");
    expect(approved.payload).toMatchObject({ sessionId, canControl: true });
    expect(approved.payload.iceServers).toBeInstanceOf(Array);
    await observer.none("desktop.screen.approved");

    observer.send("desktop.screen.offer", { sessionId, sdp: "v=0" });
    expect((await observer.next("error")).payload).toMatchObject({ code: "screen.not_found" });
    controller.send("desktop.screen.offer", { sessionId, sdp: "v=0" });
    expect((await host.next("desktop.screen.offer")).payload).toMatchObject({ sessionId, sdp: "v=0" });
    await observer.none("desktop.screen.offer");

    host.send("desktop.screen.answer", {
      sessionId, sdp: "v=0", displayWidth: 1440, displayHeight: 900,
    });
    expect((await controller.next("desktop.screen.answer")).payload).toMatchObject({
      sessionId, sdp: "v=0", displayWidth: 1440, displayHeight: 900,
    });
    await observer.none("desktop.screen.answer");

    controller.send("desktop.screen.ice", {
      sessionId, candidate: { candidate: "candidate:1 1 udp 1 127.0.0.1 12345 typ host", sdpMid: "0", sdpMLineIndex: 0 },
    });
    expect((await host.next("desktop.screen.ice")).payload).toMatchObject({ sessionId });
    host.send("desktop.screen.ice", {
      sessionId, candidate: { candidate: "candidate:2 1 udp 1 127.0.0.1 12346 typ host", sdpMid: "0", sdpMLineIndex: 0 },
    });
    expect((await controller.next("desktop.screen.ice")).payload).toMatchObject({ sessionId });
    await observer.none("desktop.screen.ice");

    controller.send("desktop.screen.close", { sessionId });
    expect((await host.next("desktop.screen.close")).payload).toMatchObject({ sessionId });
    expect((await controller.next("desktop.screen.close")).payload).toMatchObject({ sessionId });
    observer.send("desktop.screen.open", { requestedControl: false });
    expect((await observer.next("desktop.screen.pending")).payload.sessionId).toMatch(/^screen_/);
  });

  it("keeps view-only approval read-only and releases the lease on host denial", async () => {
    const desktopId = `desk_screen_${crypto.randomUUID().replaceAll("-", "")}`;
    const host = await connect(desktopId, "desktop", desktopId, []);
    const viewer = await connect(desktopId, "mobile", "viewer", ["screen:view"]);
    viewer.send("desktop.screen.open", { requestedControl: false });
    const sessionId = (await viewer.next("desktop.screen.pending")).payload.sessionId as string;
    await host.next("desktop.screen.requested");
    host.send("desktop.screen.approve", { sessionId, allowControl: true });
    await viewer.none("desktop.screen.approved");
    host.send("desktop.screen.approve", { sessionId, allowControl: false });
    expect((await viewer.next("desktop.screen.approved")).payload).toMatchObject({
      sessionId, canControl: false,
    });
    host.send("desktop.screen.close", { sessionId });
    await viewer.next("desktop.screen.close");
    viewer.send("desktop.screen.open", { requestedControl: false });
    const nextSession = (await viewer.next("desktop.screen.pending")).payload.sessionId as string;
    await host.next("desktop.screen.requested");
    host.send("desktop.screen.deny", { sessionId: nextSession });
    expect((await viewer.next("desktop.screen.denied")).payload).toMatchObject({
      sessionId: nextSession,
      reason: "denied",
    });
  });

  it("expires pending requests and releases approved sessions on credential revocation", async () => {
    const desktopId = `desk_screen_${crypto.randomUUID().replaceAll("-", "")}`;
    const room = env.DESKTOP_ROOMS.getByName(desktopId);
    const host = await connect(desktopId, "desktop", desktopId, []);
    const viewer = await connect(desktopId, "mobile", "viewer", ["screen:view"]);
    const secondViewer = await connect(desktopId, "mobile", "second-viewer", ["screen:view"]);

    viewer.send("desktop.screen.open", { requestedControl: false });
    const firstSession = (await viewer.next("desktop.screen.pending")).payload.sessionId as string;
    await host.next("desktop.screen.requested");
    await runInDurableObject(room, (_instance, state) => {
      state.storage.sql.exec("UPDATE screen_session SET expires_at = ?", Date.now() - 1);
    });
    host.send("desktop.screen.approve", { sessionId: firstSession, allowControl: false });
    expect((await viewer.next("desktop.screen.denied")).payload).toMatchObject({
      sessionId: firstSession,
      reason: "timeout",
    });
    await host.next("desktop.screen.close");

    viewer.send("desktop.screen.open", { requestedControl: false });
    const activeSession = (await viewer.next("desktop.screen.pending")).payload.sessionId as string;
    await host.next("desktop.screen.requested");
    host.send("desktop.screen.approve", { sessionId: activeSession, allowControl: false });
    await viewer.next("desktop.screen.approved");
    await host.next("desktop.screen.approved");

    const revoked = await room.fetch("https://relay.internal/disconnect", {
      method: "POST",
      headers: {
        "X-Pass-Internal-Desktop-ID": desktopId,
        "X-Pass-Internal-Device-ID": "viewer",
      },
    });
    expect(revoked.status).toBe(200);
    expect((await host.next("desktop.screen.close")).payload).toMatchObject({
      sessionId: activeSession,
      reason: "credential_revoked",
    });
    secondViewer.send("desktop.screen.open", { requestedControl: false });
    expect((await secondViewer.next("desktop.screen.pending")).payload.sessionId).toMatch(/^screen_/);
  });

  it("cancels a pending request by its open id before the browser knows the session id", async () => {
    const desktopId = `desk_screen_${crypto.randomUUID().replaceAll("-", "")}`;
    const host = await connect(desktopId, "desktop", desktopId, []);
    const viewer = await connect(desktopId, "mobile", "viewer", ["screen:view"]);
    const requestId = viewer.send("desktop.screen.open", { requestedControl: false });
    viewer.send("desktop.screen.close", { requestId });
    const pending = await viewer.next("desktop.screen.pending");
    await host.next("desktop.screen.requested");
    expect((await viewer.next("desktop.screen.denied")).payload).toMatchObject({
      sessionId: pending.payload.sessionId,
      reason: "controller_closed",
    });
    await host.next("desktop.screen.close");
    viewer.send("desktop.screen.open", { requestedControl: false });
    expect((await viewer.next("desktop.screen.pending")).payload.sessionId).toMatch(/^screen_/);
  });

  it("closes an approved session by its open id when approval races with cancellation", async () => {
    const desktopId = `desk_screen_${crypto.randomUUID().replaceAll("-", "")}`;
    const host = await connect(desktopId, "desktop", desktopId, []);
    const viewer = await connect(desktopId, "mobile", "viewer", ["screen:view"]);
    const otherViewer = await connect(desktopId, "mobile", "other-viewer", ["screen:view"]);

    const requestId = viewer.send("desktop.screen.open", { requestedControl: false });
    const pending = await viewer.next("desktop.screen.pending");
    const sessionId = pending.payload.sessionId as string;
    await host.next("desktop.screen.requested");
    host.send("desktop.screen.approve", { sessionId, allowControl: false });
    await host.next("desktop.screen.approved");
    await viewer.next("desktop.screen.approved");

    otherViewer.send("desktop.screen.close", { requestId });
    expect((await otherViewer.next("error")).payload).toMatchObject({ code: "screen.not_found" });
    await host.none("desktop.screen.close");

    viewer.send("desktop.screen.close", { requestId });
    expect((await host.next("desktop.screen.close")).payload).toMatchObject({
      sessionId,
      reason: "controller_closed",
    });
    expect((await viewer.next("desktop.screen.close")).payload).toMatchObject({
      sessionId,
      reason: "controller_closed",
    });
    otherViewer.send("desktop.screen.open", { requestedControl: false });
    expect((await otherViewer.next("desktop.screen.pending")).payload.sessionId).toMatch(/^screen_/);
  });
});
