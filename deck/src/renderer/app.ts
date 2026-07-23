import { Terminal } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";
import type { AgentKind, DeckSession, DeckState } from "../shared/types.ts";

const byId = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
let state: DeckState;
let lastRevision = "";
let gamepadIndex = -1;
let previousButtons: boolean[] = [];

const terminal = new Terminal({
  convertEol: true, cursorBlink: true, disableStdin: false, fontFamily: '"DejaVu Sans Mono", monospace',
  fontSize: 12, lineHeight: 1.15, scrollback: 200, theme: {
    background: "#090c0a", foreground: "#dce5dc", cursor: "#c7f36b", selectionBackground: "#40512699",
    black: "#111713", red: "#ff6b5f", green: "#a8d95d", yellow: "#f2b84b", blue: "#78a9d1",
    magenta: "#b592cc", cyan: "#6dc7b0", white: "#dce5dc", brightBlack: "#59615c",
    brightRed: "#ff8a80", brightGreen: "#c7f36b", brightYellow: "#ffd278", brightBlue: "#9fc8eb",
    brightMagenta: "#d3adeb", brightCyan: "#94e2cf", brightWhite: "#ffffff",
  },
});
terminal.open(byId("terminal"));
terminal.onData((input) => { if (state?.selectedSession) void window.passDeck.sendTerminalInput(state.selectedSession, input); });

function age(iso: string): string {
  const seconds = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
  if (seconds < 60) return "NOW";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}M`;
  return `${Math.floor(seconds / 3600)}H`;
}

function sessionCard(session: DeckSession): HTMLButtonElement {
  const button = document.createElement("button");
  button.className = `session-card${session.name === state.selectedSession ? " active" : ""}${["decision", "input"].includes(session.attention.status) ? " needs-user" : ""}`;
  button.role = "option";
  button.dataset.session = session.name;
  button.innerHTML = `<div class="session-top"><span class="session-name"></span><span class="agent-chip"></span></div><p class="session-preview"></p><div class="session-foot"><span></span><span></span></div>`;
  button.querySelector(".session-name")!.textContent = session.displayName;
  button.querySelector(".agent-chip")!.textContent = session.agent.toUpperCase();
  button.querySelector(".session-preview")!.textContent = session.attention.preview || session.lastMessage || "세션이 준비되었습니다.";
  const foot = button.querySelectorAll(".session-foot span");
  foot[0].textContent = session.attention.status === "decision" ? "● NEEDS YOU" : session.gitBranch || session.attention.status;
  foot[1].textContent = age(session.lastActivity);
  button.addEventListener("click", () => void window.passDeck.selectSession(session.name));
  return button;
}

function render(next: DeckState): void {
  state = next;
  const connection = byId("connection");
  connection.className = `connection ${state.phase}`;
  connection.querySelector("span")!.textContent = state.statusText;
  byId("session-count").textContent = String(state.sessions.length).padStart(2, "0");
  const list = byId("session-list");
  list.replaceChildren(...state.sessions.map(sessionCard));

  const selected = state.sessions.find((item) => item.name === state.selectedSession);
  const showPairing = state.sessions.length === 0 &&
    (Boolean(state.pairing) || state.statusText.includes("NOT PAIRED") || state.statusText.includes("PAIRING ERROR") || state.statusText.includes("GENERATING LINK") || state.statusText.includes("WAITING FOR PHONE"));
  byId("remote-setup").classList.toggle("hidden", !showPairing);
  byId("empty-state").classList.toggle("hidden", Boolean(selected) || showPairing);
  byId("session-view").classList.toggle("hidden", !selected);
  if (selected) renderSession(selected);
  byId("pairing-start").classList.toggle("hidden", Boolean(state.pairing));
  byId("qr-panel").classList.toggle("hidden", !state.pairing);
  const qr = byId<HTMLImageElement>("pairing-qr");
  if (state.pairing && qr.src !== state.pairing.qrDataURL) qr.src = state.pairing.qrDataURL;
  if (state.pairing) byId("pairing-device").textContent = state.pairing.deviceName;
  if (state.pairingError) byId("pairing-error").textContent = state.pairingError;
  renderProjects();
}

function renderSession(session: DeckSession): void {
  byId("session-title").textContent = session.displayName;
  byId("session-agent").textContent = `${session.agent.toUpperCase()} · REMOTE`;
  byId("session-meta").textContent = `${session.cwd}${session.gitBranch ? `  /  ${session.gitBranch}` : ""}`;
  const attention = byId("attention");
  attention.classList.toggle("hidden", session.attention.status !== "decision");
  byId("attention-copy").textContent = session.attention.preview || "에이전트가 작업 진행 권한을 요청했습니다.";
  if (state.frame && state.frame.revision !== lastRevision) {
    lastRevision = state.frame.revision;
    if (terminal.cols !== state.frame.columns || terminal.rows !== state.frame.rows) terminal.resize(state.frame.columns, state.frame.rows);
    terminal.reset();
    terminal.write(`\x1b[?25l\x1b[H\x1b[2J${state.frame.content}\x1b[${state.frame.cursorY + 1};${state.frame.cursorX + 1}H\x1b[?25h`);
  }
}

function renderProjects(): void {
  const select = byId<HTMLSelectElement>("project");
  const current = select.value;
  select.replaceChildren();
  const manual = new Option("직접 경로 입력", ""); select.add(manual);
  for (const project of state.projects) select.add(new Option(`${project.emoji ?? "▣"} ${project.name}`, project.rootPath));
  if ([...select.options].some((option) => option.value === current)) select.value = current;
}

byId("home-button").addEventListener("click", () => void window.passDeck.selectSession());
byId("close-session").addEventListener("click", () => void window.passDeck.selectSession());
byId("new-session").addEventListener("click", () => byId<HTMLDialogElement>("create-dialog").showModal());
byId<HTMLSelectElement>("project").addEventListener("change", (event) => { byId<HTMLInputElement>("project-path").value = (event.target as HTMLSelectElement).value; });
byId("connect-remote").addEventListener("click", async () => {
  const result = await window.passDeck.connectRemote(byId<HTMLTextAreaElement>("pairing").value);
  byId("pairing-error").textContent = result.error ?? "";
});
byId("start-pairing").addEventListener("click", async () => {
  const relayUrl = byId<HTMLInputElement>("relay-url").value.trim();
  if (!relayUrl) { byId("pairing-error").textContent = "Relay 주소를 입력하세요."; return; }
  byId("pairing-error").textContent = "";
  const result = await window.passDeck.startPairing(relayUrl);
  if (!result.ok) byId("pairing-error").textContent = result.error ?? "QR을 만들지 못했습니다.";
});
document.querySelectorAll<HTMLButtonElement>("[data-decision]").forEach((button) => button.addEventListener("click", async () => {
  if (!state.selectedSession) return;
  const result = await window.passDeck.answerDecision(state.selectedSession, button.dataset.decision as "allowOnce" | "allowAll" | "deny");
  byId("result").textContent = result.ok ? "결정을 전송했습니다." : result.error ?? "전송하지 못했습니다.";
}));
byId<HTMLFormElement>("composer").addEventListener("submit", async (event) => {
  event.preventDefault();
  const input = byId<HTMLTextAreaElement>("message");
  if (!state.selectedSession || !input.value.trim()) return;
  const result = await window.passDeck.sendMessage(state.selectedSession, input.value.trim());
  byId("result").textContent = result.ok ? "메시지를 전송했습니다." : result.error ?? "전송하지 못했습니다.";
  if (result.ok) input.value = "";
});
byId<HTMLTextAreaElement>("message").addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); byId<HTMLFormElement>("composer").requestSubmit(); }
});
byId<HTMLFormElement>("create-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const root = byId<HTMLInputElement>("project-path").value.trim() || byId<HTMLSelectElement>("project").value;
  const agent = (document.querySelector<HTMLInputElement>('input[name="agent"]:checked')?.value ?? "claude") as Extract<AgentKind, "claude" | "codex" | "pi">;
  if (!root) { byId("create-error").textContent = "프로젝트 경로를 입력하세요."; return; }
  const result = await window.passDeck.createSession({ projectRoot: root, agent, initialPrompt: byId<HTMLTextAreaElement>("initial-prompt").value.trim() || undefined });
  if (result.ok) byId<HTMLDialogElement>("create-dialog").close();
  else byId("create-error").textContent = result.error ?? "세션을 시작하지 못했습니다.";
});

function moveSelection(delta: number): void {
  if (!state.sessions.length) return;
  const current = state.sessions.findIndex((item) => item.name === state.selectedSession);
  const next = state.sessions[(Math.max(0, current) + delta + state.sessions.length) % state.sessions.length];
  void window.passDeck.selectSession(next.name);
}

window.addEventListener("keydown", (event) => {
  if ((event.target as HTMLElement).matches("textarea,input,select")) return;
  if (event.key === "ArrowDown") { event.preventDefault(); moveSelection(1); }
  if (event.key === "ArrowUp") { event.preventDefault(); moveSelection(-1); }
  if (event.key === "Escape") void window.passDeck.selectSession();
});
window.addEventListener("gamepadconnected", (event) => { gamepadIndex = event.gamepad.index; requestAnimationFrame(pollGamepad); });
function pollGamepad(): void {
  const pad = navigator.getGamepads()[gamepadIndex];
  if (!pad) return;
  const pressed = pad.buttons.map((button) => button.pressed);
  const justPressed = (index: number) => pressed[index] && !previousButtons[index];
  if (justPressed(12)) moveSelection(-1);
  if (justPressed(13)) moveSelection(1);
  if (justPressed(0) && !state.selectedSession && state.sessions[0]) void window.passDeck.selectSession(state.sessions[0].name);
  if (justPressed(1)) void window.passDeck.selectSession();
  if (justPressed(2)) byId<HTMLTextAreaElement>("message").focus();
  if (justPressed(7) && state.selectedSession) byId<HTMLFormElement>("composer").requestSubmit();
  previousButtons = pressed;
  requestAnimationFrame(pollGamepad);
}

window.passDeck.onState(render);
void window.passDeck.getState().then(render);
