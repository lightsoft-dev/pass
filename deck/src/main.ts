import { app, BrowserWindow, ipcMain, safeStorage } from "electron";
import { readFile, writeFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { parsePairingProfile, RemoteDeckClient } from "./remote/remoteClient.ts";
import { DeckPairingClient } from "./remote/deckPairing.ts";
import type { CreateSessionInput, DeckState, PairingProfile } from "./shared/types.ts";

let window: BrowserWindow | undefined;
let selectedSession: string | undefined;
let phase: DeckState["phase"] = "offline";
let statusText = "REMOTE · NOT PAIRED";
let pairing: DeckState["pairing"];
let pairingError: string | undefined;
const remote = new RemoteDeckClient(() => publish(), (profile) => void saveProfile(profile));
const deckPairing = new DeckPairingClient();

function currentState(): DeckState {
  const data = remote.data;
  const effectivePhase = data.desktopOnline
    ? "online"
    : phase === "connecting"
      ? "connecting"
      : phase === "error"
        ? "error"
        : "desktop-offline";
  return {
    phase: effectivePhase,
    statusText: data.desktopOnline
      ? "REMOTE · DESKTOP ONLINE"
      : effectivePhase === "connecting"
        ? "REMOTE · CONNECTING"
        : statusText,
    sessions: data.sessions,
    projects: data.projects,
    selectedSession,
    frame: data.frame,
    pairing,
    pairingError,
  };
}

function publish(): void {
  const next = currentState();
  if (next.phase === "online") phase = "online";
  const target = window;
  if (target && !target.isDestroyed()) target.webContents.send("deck:state", next);
}

function profilePath(): string { return join(app.getPath("userData"), "remote-profile.bin"); }

async function saveProfile(profile: PairingProfile): Promise<void> {
  if (!safeStorage.isEncryptionAvailable()) return;
  const encrypted = safeStorage.encryptString(JSON.stringify(profile));
  await writeFile(profilePath(), encrypted.toString("base64"), { mode: 0o600 });
}

async function loadProfile(): Promise<PairingProfile | undefined> {
  if (!safeStorage.isEncryptionAvailable()) return undefined;
  try {
    const encoded = await readFile(profilePath(), "utf8");
    return JSON.parse(safeStorage.decryptString(Buffer.from(encoded, "base64"))) as PairingProfile;
  } catch { return undefined; }
}

async function connect(raw: string): Promise<{ ok: boolean; error?: string }> {
  try {
    const profile = parsePairingProfile(raw);
    phase = "connecting";
    statusText = "REMOTE · CONNECTING";
    remote.connect(profile);
    await saveProfile(profile);
    publish();
    return { ok: true };
  } catch (error) {
    phase = "error";
    statusText = "REMOTE · PAIRING ERROR";
    publish();
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
}

async function startPairing(relayUrl: string): Promise<{ ok: boolean; error?: string }> {
  try {
    deckPairing.stop();
    pairing = undefined;
    pairingError = undefined;
    phase = "connecting";
    statusText = "REMOTE · GENERATING LINK";
    publish();
    void deckPairing.start(relayUrl, (challenge) => {
      pairing = challenge;
      statusText = "REMOTE · WAITING FOR PHONE";
      phase = "offline";
      publish();
    }).then(async (profile) => {
      pairing = undefined;
      await saveProfile(profile);
      phase = "connecting";
      statusText = "REMOTE · APPROVED";
      remote.connect(profile);
      publish();
    }).catch((error: unknown) => {
      pairing = undefined;
      pairingError = error instanceof Error ? error.message : String(error);
      phase = "error";
      statusText = "REMOTE · PAIRING ERROR";
      publish();
      console.error(error);
    });
    return { ok: true };
  } catch (error) {
    phase = "error";
    pairingError = error instanceof Error ? error.message : String(error);
    statusText = "REMOTE · PAIRING ERROR";
    publish();
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
}

function installIPC(): void {
  ipcMain.handle("deck:getState", () => currentState());
  ipcMain.handle("deck:select", (_event, name?: string) => {
    selectedSession = name;
    remote.select(name);
    publish();
    return currentState();
  });
  ipcMain.handle("deck:message", (_event, session: string, text: string) => remote.sendMessage(session, text));
  ipcMain.handle("deck:decision", (_event, session: string, decision: "allowOnce" | "allowAll" | "deny") => remote.answerDecision(session, decision));
  ipcMain.handle("deck:terminal", (_event, session: string, input: string) => remote.sendTerminalInput(session, input));
  ipcMain.handle("deck:create", (_event, input: CreateSessionInput) => remote.createSession(input));
  ipcMain.handle("deck:connectRemote", (_event, raw: string) => connect(raw));
  ipcMain.handle("deck:startPairing", (_event, relayUrl: string) => startPairing(relayUrl));
  ipcMain.handle("deck:disconnectRemote", async () => {
    remote.disconnect();
    deckPairing.stop();
    pairing = undefined;
    pairingError = undefined;
    phase = "offline";
    statusText = "REMOTE · NOT PAIRED";
    await rm(profilePath(), { force: true });
    publish();
  });
}

app.whenReady().then(async () => {
  installIPC();
  window = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 900,
    minHeight: 600,
    fullscreen: process.env.PASS_DECK_FULLSCREEN === "1",
    backgroundColor: "#0a0d0c",
    autoHideMenuBar: true,
    webPreferences: { preload: join(__dirname, "preload.cjs"), contextIsolation: true, nodeIntegration: false },
  });
  await window.loadFile(join(__dirname, "renderer", "index.html"));
  const saved = await loadProfile();
  if (saved) {
    phase = "connecting";
    statusText = "REMOTE · RECONNECTING";
    remote.connect(saved);
    publish();
  }
});

app.on("window-all-closed", () => app.quit());
