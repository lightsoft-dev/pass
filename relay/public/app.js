import { PassAPIError, parseAPIResponse } from "./api-error.js";

const $ = (selector) => document.querySelector(selector);
const ui = {
  signIn: $("#sign-in"), console: $("#console"), googleButton: $("#google-button"),
  desktops: $("#desktop-list"), desktopName: $("#desktop-name"), presence: $("#presence"),
  sessions: $("#sessions"), empty: $("#empty-state"), composer: $("#composer"),
  message: $("#message"), notice: $("#notice"), connection: $(".connection"),
  connectionLabel: $("#connection-label"),
};

let googleToken = null;
let desktops = [];
let activeDesktop = null;
let accessToken = null;
let socket = null;
let socketRefreshTimer = null;
let selectedSession = null;
let latestSnapshot = { sessions: [], projects: [] };
const controllers = new Map();

function notice(message, error = false) {
  ui.notice.textContent = message;
  ui.notice.className = `notice visible${error ? " error" : ""}`;
  clearTimeout(notice.timer);
  notice.timer = setTimeout(() => ui.notice.classList.remove("visible"), 4500);
}

function connection(label, state = "") {
  ui.connection.className = `connection ${state}`;
  ui.connectionLabel.textContent = label;
}

async function api(path, options = {}, token = googleToken) {
  const headers = new Headers(options.headers);
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (options.body) headers.set("Content-Type", "application/json");
  const response = await fetch(path, { ...options, headers, redirect: "error" });
  const body = await response.json().catch(() => ({}));
  return parseAPIResponse(response, body);
}

function renderDesktops() {
  ui.desktops.replaceChildren(...desktops.map((desktop) => {
    const button = document.createElement("button");
    button.className = "desktop";
    button.setAttribute("aria-current", String(activeDesktop?.id === desktop.id));
    button.innerHTML = `<b>${escapeHTML(desktop.name)}</b><small>${desktop.lastSeenAt ? "LAST SEEN " + new Date(desktop.lastSeenAt).toLocaleDateString() : "AWAITING CONNECTION"}</small>`;
    button.onclick = () => connectDesktop(desktop);
    return button;
  }));
}

function renderSessions() {
  ui.sessions.replaceChildren(...latestSnapshot.sessions.map((session) => {
    const button = document.createElement("button");
    button.className = `session${selectedSession === session.name ? " selected" : ""}`;
    button.innerHTML = `<b>${escapeHTML(session.displayName || session.name)}</b><span>${escapeHTML(session.attention?.status || "ACTIVE")}</span><p>${escapeHTML(session.lastMessage || session.projectRoot || "대기 중")}</p>`;
    button.onclick = () => { selectedSession = session.name; ui.composer.hidden = false; renderSessions(); ui.message.focus(); };
    return button;
  }));
  ui.empty.hidden = latestSnapshot.sessions.length > 0 || activeDesktop === null;
  if (latestSnapshot.sessions.length === 0 && activeDesktop) ui.empty.textContent = "이 데스크톱에는 표시할 세션이 없습니다.";
}

async function signedIn(response) {
  googleToken = response.credential;
  try {
    const [account, list] = await Promise.all([api("/v2/me"), api("/v2/desktops")]);
    desktops = list.desktops;
    ui.signIn.hidden = true;
    ui.console.hidden = false;
    connection(`SIGNED IN · ${account.account.displayName || account.account.email || "GOOGLE"}`);
    renderDesktops();
    if (!desktops.length) notice("등록된 Pass 데스크톱이 없습니다. 먼저 Mac 앱에서 이 Google 계정으로 로그인하세요.");
  } catch (error) { signOut(); notice(error.message, true); }
}

async function connectDesktop(desktop) {
  closeSocket();
  activeDesktop = desktop;
  selectedSession = null;
  latestSnapshot = { sessions: [], projects: [] };
  ui.desktopName.textContent = desktop.name;
  ui.composer.hidden = true;
  ui.presence.textContent = "CONNECTING";
  ui.presence.className = "presence";
  renderDesktops(); renderSessions(); connection("AUTHORIZING REMOTE");
  try {
    const controller = await ensureController(desktop);
    accessToken = controller.accessToken;
    openSocket(desktop, controller);
  } catch (error) { connection("CONNECTION FAILED", "error"); notice(error.message, true); }
}

async function ensureController(desktop) {
  let controller = controllers.get(desktop.id);
  if (!controller) {
    const authorization = await api(`/v2/desktops/${encodeURIComponent(desktop.id)}/controllers`, {
      method: "POST", body: JSON.stringify({ deviceName: `Pass Web · ${navigator.platform || "Browser"}`.slice(0, 100), platform: "unknown" }),
    });
    controller = { ...authorization.credentials, relayUrl: authorization.relayUrl };
    controllers.set(desktop.id, controller);
  } else if (credentialExpiresSoon(controller)) {
    controller = await refreshController(desktop.id, controller);
  }
  return controller;
}

function credentialExpiresSoon(controller, margin = 60_000) {
  const expiresAt = new Date(controller.accessExpiresAt).getTime();
  return !Number.isFinite(expiresAt) || expiresAt <= Date.now() + margin;
}

async function refreshController(desktopId, controller) {
  const rotation = await api("/v2/token/refresh", { method: "POST" }, controller.refreshToken);
  const refreshed = { ...controller, ...rotation.credentials };
  controllers.set(desktopId, refreshed);
  return refreshed;
}

function scheduleControllerRefresh(desktop, controller) {
  clearTimeout(socketRefreshTimer);
  const expiresAt = new Date(controller.accessExpiresAt).getTime();
  const delay = Number.isFinite(expiresAt) ? Math.max(1_000, expiresAt - Date.now() - 60_000) : 1_000;
  socketRefreshTimer = setTimeout(async () => {
    if (activeDesktop?.id !== desktop.id) return;
    try {
      const current = controllers.get(desktop.id);
      if (!current) return;
      const refreshed = await refreshController(desktop.id, current);
      closeSocket();
      if (activeDesktop?.id !== desktop.id) return;
      accessToken = refreshed.accessToken;
      openSocket(desktop, refreshed);
    } catch (error) {
      connection("SESSION EXPIRED", "error");
      notice(error.message, true);
    }
  }, delay);
}

function openSocket(desktop, controller) {
  const url = new URL("/connect", controller.relayUrl);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  url.searchParams.set("version", "1");
  // The credential is a WebSocket subprotocol, never a URL parameter.
  const openedSocket = new WebSocket(url, ["pass.v1", `pass.auth.${controller.accessToken}`]);
  socket = openedSocket;
  openedSocket.onopen = () => {
    if (socket !== openedSocket) return;
    connection("RELAY CONNECTED", "connected");
    scheduleControllerRefresh(desktop, controller);
    send("session.list", {});
  };
  openedSocket.onmessage = (event) => receive(JSON.parse(event.data));
  openedSocket.onerror = () => notice("Relay 연결을 열 수 없습니다.", true);
  openedSocket.onclose = async (event) => {
    if (socket !== openedSocket) return;
    socket = null;
    clearTimeout(socketRefreshTimer);
    if (activeDesktop) connection("RELAY DISCONNECTED", "error");
    ui.presence.textContent = "OFFLINE";
    ui.presence.className = "presence";
    if (event.code !== 4003 || activeDesktop?.id !== desktop.id) return;
    try {
      const current = controllers.get(desktop.id);
      if (!current) return;
      const refreshed = await refreshController(desktop.id, current);
      accessToken = refreshed.accessToken;
      openSocket(desktop, refreshed);
    } catch (error) { notice(error.message, true); }
  };
}

function receive(event) {
  if (event.type === "desktop.presence") {
    const online = event.payload.desktopOnline === true;
    ui.presence.textContent = online ? "ONLINE" : "OFFLINE";
    ui.presence.className = `presence${online ? " online" : ""}`;
    if (online) send("session.list", {});
  } else if (event.type === "session.snapshot") {
    latestSnapshot = event.payload;
    renderSessions();
  } else if (event.type === "error") {
    notice(event.payload?.message || "원격 명령이 거부되었습니다.", true);
  }
}

function send(type, payload) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  socket.send(JSON.stringify({ version: 1, id: `web_${crypto.randomUUID()}`, type, sentAt: new Date().toISOString(), payload }));
}

function closeSocket() { clearTimeout(socketRefreshTimer); if (socket) { socket.onclose = null; socket.close(1000, "Changing desktop"); } socket = null; accessToken = null; }
function signOut() { closeSocket(); controllers.clear(); googleToken = null; desktops = []; activeDesktop = null; ui.console.hidden = true; ui.signIn.hidden = false; connection("SIGN IN REQUIRED"); window.google?.accounts.id.disableAutoSelect(); }
function escapeHTML(value) { const element = document.createElement("span"); element.textContent = String(value || ""); return element.innerHTML; }

$("#refresh").onclick = async () => { try { desktops = (await api("/v2/desktops")).desktops; renderDesktops(); } catch (error) { notice(error.message, true); } };
$("#sign-out").onclick = signOut;
const deleteAccountButton = $("#delete-account");
deleteAccountButton.onclick = async () => {
  if (!window.confirm("Pass 계정과 연결된 모든 데스크톱 및 기기 정보를 영구 삭제할까요? 이 작업은 되돌릴 수 없습니다.")) return;
  deleteAccountButton.disabled = true;
  try {
    await api("/v2/account", { method: "DELETE" });
    signOut();
    notice("Pass 계정이 삭제되었습니다.");
  } catch (error) {
    if (!(error instanceof PassAPIError) || !error.manualRevocationAvailable) {
      notice(error.message, true);
      return;
    }
    const confirmed = window.confirm(
      "Apple 자동 연결 해제에 실패했습니다. 계속하면 Pass 데이터는 영구 삭제되지만 Apple 쪽 Pass 권한은 남을 수 있어 직접 철회해야 합니다. 수동 철회를 전제로 지금 데이터를 삭제할까요?",
    );
    if (!confirmed) {
      notice("계정 삭제를 취소했습니다. Apple 로그인을 다시 완료한 뒤 재시도할 수 있습니다.");
      return;
    }
    try {
      const deleted = await api("/v2/account", {
        method: "DELETE",
        headers: { "X-Pass-Apple-Revocation-Fallback": "manual" },
      });
      signOut();
      notice("Pass 데이터가 삭제되었습니다. 이제 Apple 설정에서 Pass 권한을 직접 철회해 주세요.");
      if (deleted.appleRevocation === "manual_required") {
        window.alert(
          "Pass 데이터 삭제가 완료되었습니다.\n\nApple 설정 > [사용자 이름] > 로그인 및 보안 > Apple로 로그인 > Pass에서 권한을 수동으로 철회해 주세요.\n(Apple Settings > [name] > Sign-In & Security > Sign in with Apple > Pass)",
        );
      }
    } catch (fallbackError) {
      notice(fallbackError.message, true);
    }
  } finally {
    deleteAccountButton.disabled = false;
  }
};
ui.composer.onsubmit = (event) => { event.preventDefault(); const text = ui.message.value.trim(); if (!text || !selectedSession) return; send("session.sendMessage", { session: selectedSession, text }); ui.message.value = ""; };

async function boot() {
  try {
    const config = await api("/v2/web/config", {}, null);
    const deadline = Date.now() + 5000;
    while (!window.google?.accounts?.id && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 50));
    if (!window.google?.accounts?.id) throw new Error("Google 로그인 도구를 불러오지 못했습니다.");
    window.google.accounts.id.initialize({ client_id: config.googleClientId, callback: signedIn, auto_select: false, cancel_on_tap_outside: true });
    window.google.accounts.id.renderButton(ui.googleButton, { theme: "filled_black", size: "large", type: "standard", text: "signin_with", shape: "rectangular", width: 280, locale: "ko" });
  } catch (error) { notice(error.message, true); }
}
boot();
