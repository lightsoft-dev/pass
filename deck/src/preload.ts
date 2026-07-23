import { contextBridge, ipcRenderer } from "electron";
import type { CreateSessionInput, DeckState, PassDeckAPI } from "./shared/types.ts";

const api: PassDeckAPI = {
  getState: () => ipcRenderer.invoke("deck:getState"),
  selectSession: (name?: string) => ipcRenderer.invoke("deck:select", name),
  sendMessage: (session, text) => ipcRenderer.invoke("deck:message", session, text),
  answerDecision: (session, decision) => ipcRenderer.invoke("deck:decision", session, decision),
  sendTerminalInput: (session, input) => ipcRenderer.invoke("deck:terminal", session, input),
  createSession: (input: CreateSessionInput) => ipcRenderer.invoke("deck:create", input),
  connectRemote: (raw) => ipcRenderer.invoke("deck:connectRemote", raw),
  startPairing: (relayUrl) => ipcRenderer.invoke("deck:startPairing", relayUrl),
  disconnectRemote: () => ipcRenderer.invoke("deck:disconnectRemote"),
  onState: (listener) => {
    const handler = (_event: Electron.IpcRendererEvent, state: DeckState) => listener(state);
    ipcRenderer.on("deck:state", handler);
    return () => ipcRenderer.removeListener("deck:state", handler);
  },
};
contextBridge.exposeInMainWorld("passDeck", api);
