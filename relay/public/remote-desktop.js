const INPUT_CHANNEL = "pass.screen.input.v1";
const APPROVAL_TIMEOUT_MS = 65_000;
const CONNECTION_TIMEOUT_MS = 20_000;
const POINTER_MOVE_INTERVAL_MS = 30;
const MAX_TEXT_CHARACTERS = 1_024;
const TEXT_CHUNK_CHARACTERS = 256;
const TEXT_CHUNK_BYTES = 1_024;

/** One browser viewer for the selected, account-linked Mac. The host approves every lease. */
export class RemoteDesktopViewer {
  constructor({ elements, send, notice }) {
    this.ui = elements;
    this.send = send;
    this.notice = notice;
    this.desktop = null;
    this.online = false;
    this.sessionId = null;
    this.openCommandId = null;
    this.offerCommandId = null;
    this.canceledOpenCommands = new Set();
    this.requestedControl = false;
    this.canControl = false;
    this.state = "idle";
    this.peer = null;
    this.inputChannel = null;
    this.pendingCandidates = [];
    this.pressedKeys = new Map();
    this.pressedButtons = new Set();
    this.approvalTimer = null;
    this.connectionTimer = null;
    this.expirationTimer = null;
    this.disconnectedTimer = null;
    this.lastPointerMove = 0;
    this.lastPoint = { x: 0.5, y: 0.5 };
    this.composing = false;
    this.suppressedKeys = new Set();
    this.committedComposition = null;
    this.generation = 0;

    this.ui.open.onclick = () => {
      if (this.state !== "idle") this.ui.screen.scrollIntoView({ block: "start", behavior: "smooth" });
      else this.open(false);
    };
    this.ui.control.onclick = () => {
      if (this.canControl) this.open(false);
      else this.open(true);
    };
    this.ui.disconnect.onclick = () => this.close();
    this.ui.fullscreen.onclick = () => this.toggleFullscreen();
    document.addEventListener("fullscreenchange", () => this.updateFullscreenButton());

    this.ui.input.addEventListener("pointerdown", (event) => this.pointer(event, "down"));
    this.ui.input.addEventListener("pointermove", (event) => this.pointer(event, "move"));
    this.ui.input.addEventListener("pointerup", (event) => this.pointer(event, "up"));
    this.ui.input.addEventListener("pointercancel", () => this.releaseInputs());
    this.ui.input.addEventListener("contextmenu", (event) => event.preventDefault());
    this.ui.input.addEventListener("wheel", (event) => this.wheel(event), { passive: false });
    this.ui.keyboard.addEventListener("keydown", (event) => this.key(event, "down"));
    this.ui.keyboard.addEventListener("keyup", (event) => this.key(event, "up"));
    this.ui.keyboard.addEventListener("compositionstart", () => { this.composing = true; });
    this.ui.keyboard.addEventListener("compositionend", (event) => {
      this.composing = false;
      this.committedComposition = event.data;
      this.sendText(event.data);
      setTimeout(() => {
        this.committedComposition = null;
        this.ui.keyboard.value = "";
      }, 0);
    });
    this.ui.keyboard.addEventListener("input", (event) => {
      if (this.composing) return;
      if (event.data && event.data !== this.committedComposition && event.inputType === "insertText") {
        this.sendText(event.data);
      }
      this.ui.keyboard.value = "";
    });
    this.ui.keyboard.addEventListener("paste", (event) => {
      event.preventDefault();
      this.sendText(event.clipboardData?.getData("text/plain") || "");
    });
    this.ui.keyboard.addEventListener("blur", () => this.releaseInputs());
    window.addEventListener("blur", () => this.releaseInputs());
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) this.releaseInputs();
    });
    this.ui.video.addEventListener("playing", () => this.videoPlaying());
    this.ui.video.addEventListener("click", () => {
      if (this.state !== "idle") this.ui.video.play().catch(() => {});
    });
    this.ui.video.addEventListener("ended", () => {
      if (this.state !== "idle") this.fail("원격 화면 전송이 종료되었습니다.");
    });
    this.render();
  }

  selectDesktop(desktop) {
    if (this.desktop?.id !== desktop?.id) this.close({ notifyHost: true });
    this.desktop = desktop;
    this.online = false;
    this.ui.machineName.textContent = desktop?.name || "REMOTE DESKTOP";
    this.render();
  }

  setOnline(online) {
    this.online = online;
    if (!online && this.state !== "idle") this.close({ notifyHost: false });
    this.render();
  }

  socketClosed() {
    this.online = false;
    this.close({ notifyHost: false });
  }

  async open(requestedControl) {
    if (!this.desktop || !this.online) {
      this.notice("원격 Mac이 온라인 상태일 때 화면을 열 수 있습니다.", true);
      return;
    }
    if (!window.RTCPeerConnection) {
      this.notice("이 브라우저는 WebRTC 원격 화면을 지원하지 않습니다.", true);
      return;
    }
    this.close({ notifyHost: true, hide: false });
    this.state = "awaitingApproval";
    this.requestedControl = requestedControl;
    this.ui.screen.hidden = false;
    this.ui.machineName.textContent = this.desktop.name;
    this.status(requestedControl ? "제어 승인을 기다리는 중…" : "화면 보기 승인을 기다리는 중…");
    this.openCommandId = this.send("desktop.screen.open", { requestedControl });
    if (!this.openCommandId) {
      this.fail("Relay 연결이 끊어졌습니다.");
      return;
    }
    const generation = this.generation;
    this.approvalTimer = setTimeout(() => {
      if (this.generation === generation && this.state === "awaitingApproval") {
        this.fail("Mac의 승인 시간이 지났습니다. 다시 시도해 주세요.");
      }
    }, APPROVAL_TIMEOUT_MS);
    this.render();
  }

  handleEvent(event) {
    const payload = event.payload || {};
    switch (event.type) {
      case "desktop.screen.pending":
        if (event.replyTo && this.canceledOpenCommands.delete(event.replyTo)) {
          return;
        }
        if (this.state !== "awaitingApproval" || !payload.sessionId) return;
        if (event.replyTo && event.replyTo !== this.openCommandId) return;
        this.sessionId = payload.sessionId;
        this.status(this.requestedControl ? "Mac에서 제어 승인을 기다리는 중…" : "Mac에서 화면 공유 승인을 기다리는 중…");
        break;
      case "desktop.screen.approved":
        if (event.replyTo && this.canceledOpenCommands.delete(event.replyTo)) {
          return;
        }
        if (this.state !== "awaitingApproval" || payload.sessionId !== this.sessionId) return;
        clearTimeout(this.approvalTimer);
        this.approvalTimer = null;
        this.canControl = payload.canControl === true;
        if (this.requestedControl && !this.canControl) this.notice("Mac이 보기 전용으로 승인했습니다.");
        const generation = this.generation;
        this.connectionTimer = setTimeout(() => {
          if (this.generation === generation && this.peer?.connectionState !== "connected" && this.state !== "streaming") {
            this.fail("화면 연결 시간이 지났습니다. 다시 시도해 주세요.");
          }
        }, CONNECTION_TIMEOUT_MS);
        this.startPeer(payload);
        break;
      case "desktop.screen.denied":
        if (event.replyTo && this.canceledOpenCommands.delete(event.replyTo)) return;
        if (this.state !== "awaitingApproval") return;
        if (event.replyTo && event.replyTo !== this.openCommandId) return;
        if (this.sessionId && payload.sessionId !== this.sessionId) return;
        this.fail(payload.message || "Mac에서 화면 공유 요청을 거절했습니다.", false);
        break;
      case "desktop.screen.answer":
        if (payload.sessionId === this.sessionId) this.acceptAnswer(payload);
        break;
      case "desktop.screen.ice":
        if (payload.sessionId === this.sessionId && payload.candidate) this.acceptCandidate(payload.candidate);
        break;
      case "desktop.screen.close":
        if (payload.sessionId === this.sessionId) {
          this.close({ notifyHost: false });
          this.notice("원격 Mac에서 화면 공유를 종료했습니다.");
        }
        break;
      case "error":
        if (event.replyTo === this.openCommandId || event.replyTo === this.offerCommandId) {
          this.fail(payload.message || "화면 공유 요청이 거부되었습니다.");
          return true;
        }
        return false;
      default:
        break;
    }
  }

  async startPeer(approval) {
    const generation = this.generation;
    this.state = "negotiating";
    this.status("화면 연결을 설정하는 중…");
    this.render();
    try {
      const iceServers = Array.isArray(approval.iceServers) ? approval.iceServers : [];
      const peer = new RTCPeerConnection({ iceServers });
      this.peer = peer;
      peer.addTransceiver("video", { direction: "recvonly" });
      this.inputChannel = peer.createDataChannel(INPUT_CHANNEL, { ordered: true });
      this.inputChannel.onopen = () => this.render();
      this.inputChannel.onclose = () => { this.releaseInputs(); this.render(); };
      peer.onicecandidate = (event) => {
        if (event.candidate && this.generation === generation) {
          this.send("desktop.screen.ice", {
            sessionId: this.sessionId,
            candidate: event.candidate.toJSON(),
          });
        }
      };
      peer.ontrack = (event) => {
        if (this.generation !== generation || event.track.kind !== "video") return;
        this.ui.video.srcObject = event.streams[0] || new MediaStream([event.track]);
        this.ui.video.play().catch(() => this.status("화면을 재생하려면 화면을 클릭하세요."));
      };
      peer.onconnectionstatechange = () => {
        if (this.generation !== generation) return;
        if (peer.connectionState === "failed" || peer.connectionState === "closed") {
          this.fail("화면 연결이 끊어졌습니다.");
        } else if (peer.connectionState === "disconnected") {
          this.status("화면 연결을 복구하는 중…");
          clearTimeout(this.disconnectedTimer);
          this.disconnectedTimer = setTimeout(() => {
            if (peer.connectionState === "disconnected") this.fail("화면 연결이 끊어졌습니다.");
          }, 10_000);
        } else if (peer.connectionState === "connected") {
          clearTimeout(this.connectionTimer);
          this.connectionTimer = null;
          clearTimeout(this.disconnectedTimer);
          this.disconnectedTimer = null;
          if (this.ui.video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) this.videoPlaying();
        }
      };
      const offer = await peer.createOffer();
      if (this.generation !== generation) return;
      await peer.setLocalDescription(offer);
      if (this.generation !== generation) return;
      this.offerCommandId = this.send("desktop.screen.offer", {
        sessionId: this.sessionId, sdp: peer.localDescription.sdp,
      });
      this.scheduleExpiration(approval.expiresAt, generation);
    } catch (error) {
      if (this.generation === generation) this.fail(`화면 연결을 시작할 수 없습니다: ${error.message}`);
    }
  }

  async acceptAnswer(payload) {
    const peer = this.peer;
    const generation = this.generation;
    if (!peer || peer.signalingState === "closed" || peer.remoteDescription) return;
    try {
      await peer.setRemoteDescription({ type: "answer", sdp: payload.sdp });
      if (this.generation !== generation) return;
      const candidates = this.pendingCandidates.splice(0);
      for (const candidate of candidates) await peer.addIceCandidate(candidate);
      if (this.generation !== generation) return;
      if (payload.displayWidth && payload.displayHeight) {
        this.status(`연결 중 · ${payload.displayWidth} × ${payload.displayHeight}`);
      }
    } catch (error) {
      if (this.generation === generation) this.fail(`화면 응답을 적용할 수 없습니다: ${error.message}`);
    }
  }

  async acceptCandidate(candidate) {
    const peer = this.peer;
    const generation = this.generation;
    if (!peer || peer.signalingState === "closed") return;
    if (!peer.remoteDescription) {
      this.pendingCandidates.push(candidate);
      return;
    }
    try { await peer.addIceCandidate(candidate); }
    catch (error) {
      if (this.generation === generation) this.notice(`화면 네트워크 경로 오류: ${error.message}`, true);
    }
  }

  scheduleExpiration(expiresAt, generation) {
    clearTimeout(this.expirationTimer);
    const delay = new Date(expiresAt).getTime() - Date.now();
    if (!Number.isFinite(delay) || delay <= 0) return;
    this.expirationTimer = setTimeout(() => {
      if (this.generation === generation) {
        this.close();
        this.notice("화면 공유 시간이 끝났습니다. 다시 연결해 주세요.");
      }
    }, delay);
  }

  videoPlaying() {
    if (this.state === "idle") return;
    clearTimeout(this.connectionTimer);
    this.connectionTimer = null;
    this.state = "streaming";
    this.ui.placeholder.hidden = true;
    this.status("화면 연결됨");
    this.render();
  }

  status(message) {
    this.ui.status.textContent = message;
    if (this.state !== "streaming") {
      this.ui.placeholder.hidden = false;
      this.ui.placeholder.textContent = message;
    }
  }

  fail(message, notifyHost = true) {
    this.close({ notifyHost, hide: false });
    this.status(message);
    this.notice(message, true);
  }

  close({ notifyHost = true, hide = true } = {}) {
    if (notifyHost && this.openCommandId && !this.sessionId) {
      this.canceledOpenCommands.add(this.openCommandId);
      this.send("desktop.screen.close", { requestId: this.openCommandId });
    }
    if (notifyHost && this.sessionId) this.send("desktop.screen.close", { sessionId: this.sessionId });
    this.releaseInputs();
    this.generation += 1;
    clearTimeout(this.approvalTimer);
    clearTimeout(this.connectionTimer);
    clearTimeout(this.expirationTimer);
    clearTimeout(this.disconnectedTimer);
    this.approvalTimer = this.connectionTimer = this.expirationTimer = this.disconnectedTimer = null;
    this.peer?.close();
    this.peer = null;
    this.inputChannel = null;
    this.pendingCandidates = [];
    this.ui.video.pause();
    this.ui.video.srcObject = null;
    this.ui.keyboard.blur();
    this.ui.keyboard.value = "";
    this.composing = false;
    this.committedComposition = null;
    this.suppressedKeys.clear();
    this.sessionId = null;
    this.openCommandId = null;
    this.offerCommandId = null;
    this.canControl = false;
    this.requestedControl = false;
    this.state = "idle";
    this.ui.input.hidden = true;
    this.ui.placeholder.hidden = false;
    if (hide) this.ui.screen.hidden = true;
    if (document.fullscreenElement === this.ui.screen) document.exitFullscreen().catch(() => {});
    this.render();
  }

  render() {
    this.ui.open.hidden = !this.desktop;
    this.ui.open.disabled = !this.online;
    this.ui.open.textContent = this.state === "idle"
      ? (this.ui.screen.hidden ? "화면 보기 ↗" : "다시 연결 ↗")
      : "화면으로 이동 ↗";
    const controlling = this.state === "streaming" && this.canControl && this.inputChannel?.readyState === "open";
    this.ui.mode.textContent = controlling ? "CONTROL" : "VIEW ONLY";
    this.ui.mode.classList.toggle("controlling", controlling);
    this.ui.input.hidden = !controlling;
    this.ui.control.disabled = this.state !== "streaming" || (this.canControl && !controlling);
    this.ui.control.textContent = this.canControl ? "보기 전용 전환" : "제어 요청";
    this.ui.screen.querySelector(".screen-live-dot").classList.toggle("connected", this.state === "streaming");
  }

  async toggleFullscreen() {
    try {
      if (document.fullscreenElement === this.ui.screen) await document.exitFullscreen();
      else await this.ui.screen.requestFullscreen();
    } catch (error) { this.notice(`전체 화면을 열 수 없습니다: ${error.message}`, true); }
  }

  updateFullscreenButton() {
    const active = document.fullscreenElement === this.ui.screen;
    this.ui.fullscreen.title = active ? "전체 화면 나가기" : "전체 화면";
    this.ui.fullscreen.setAttribute("aria-label", this.ui.fullscreen.title);
  }

  sendInput(payload) {
    if (!this.canControl || this.inputChannel?.readyState !== "open") return false;
    try {
      this.inputChannel.send(JSON.stringify(payload));
      return true;
    } catch {
      this.render();
      return false;
    }
  }

  sendText(value) {
    if (!value || !this.canControl) return;
    const normalized = value.replaceAll("\r\n", "\n").replaceAll("\r", "\n");
    const characters = (Intl.Segmenter
      ? Array.from(new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(normalized), ({ segment }) => segment)
      : Array.from(normalized))
      .filter((character) => Array.from(character).every((scalar) => scalar.codePointAt(0) >= 32)
        || character === "\n" || character === "\t");
    const encoder = new TextEncoder();
    let chunk = "";
    let chunkCharacters = 0;
    let chunkBytes = 0;
    for (const character of characters.slice(0, MAX_TEXT_CHARACTERS)) {
      const bytes = encoder.encode(character).byteLength;
      if (bytes > TEXT_CHUNK_BYTES || character.length > 20) continue;
      if (chunk && (chunkCharacters >= TEXT_CHUNK_CHARACTERS || chunkBytes + bytes > TEXT_CHUNK_BYTES)) {
        if (!this.sendInput({ type: "text", text: chunk })) return;
        chunk = "";
        chunkCharacters = 0;
        chunkBytes = 0;
      }
      chunk += character;
      chunkCharacters += 1;
      chunkBytes += bytes;
    }
    if (chunk) this.sendInput({ type: "text", text: chunk });
    if (characters.length > MAX_TEXT_CHARACTERS) {
      this.notice(`긴 텍스트는 처음 ${MAX_TEXT_CHARACTERS}자만 전송했습니다.`);
    }
  }

  point(event, clamp = false) {
    const video = this.ui.video;
    if (!video.videoWidth || !video.videoHeight) return null;
    const rect = video.getBoundingClientRect();
    const scale = Math.min(rect.width / video.videoWidth, rect.height / video.videoHeight);
    const width = video.videoWidth * scale;
    const height = video.videoHeight * scale;
    const left = rect.left + (rect.width - width) / 2;
    const top = rect.top + (rect.height - height) / 2;
    const x = (event.clientX - left) / width;
    const y = (event.clientY - top) / height;
    if (!clamp && (x < 0 || x > 1 || y < 0 || y > 1)) return null;
    return { x: Math.max(0, Math.min(1, x)), y: Math.max(0, Math.min(1, y)) };
  }

  pointer(event, action) {
    if (this.ui.input.hidden) return;
    const point = this.point(event, action === "up");
    if (!point) return;
    event.preventDefault();
    this.lastPoint = point;
    if (action === "down") {
      this.ui.keyboard.focus({ preventScroll: true });
      this.ui.input.setPointerCapture(event.pointerId);
      this.pressedButtons.add(event.button);
    } else if (action === "up") {
      this.pressedButtons.delete(event.button);
      if (this.ui.input.hasPointerCapture(event.pointerId)) this.ui.input.releasePointerCapture(event.pointerId);
    } else if (performance.now() - this.lastPointerMove < POINTER_MOVE_INTERVAL_MS) {
      return;
    } else {
      this.lastPointerMove = performance.now();
    }
    this.sendInput({ type: "pointer", action, ...point, button: event.button, buttons: event.buttons });
  }

  wheel(event) {
    if (this.ui.input.hidden) return;
    const point = this.point(event);
    if (!point) return;
    event.preventDefault();
    const factor = event.deltaMode === WheelEvent.DOM_DELTA_LINE ? 16
      : event.deltaMode === WheelEvent.DOM_DELTA_PAGE ? this.ui.video.clientHeight : 1;
    this.sendInput({ type: "wheel", ...point, deltaX: event.deltaX * factor, deltaY: event.deltaY * factor });
  }

  key(event, action) {
    if (this.ui.input.hidden) return;
    const pasteShortcut = event.code === "KeyV" && (event.metaKey || event.ctrlKey);
    const imeKey = this.composing || event.isComposing || event.key === "Process"
      || event.key === "Dead" || event.keyCode === 229;
    if (action === "down" && (pasteShortcut || imeKey)) {
      this.suppressedKeys.add(event.code);
      return; // Let the hidden textarea receive paste or IME composition.
    }
    if (action === "up" && this.suppressedKeys.delete(event.code)) return;
    if (imeKey) return;
    event.preventDefault();
    event.stopPropagation();
    const payload = {
      type: "key", action, code: event.code, key: event.key, repeat: event.repeat,
      modifiers: { shift: event.shiftKey, control: event.ctrlKey, alt: event.altKey, meta: event.metaKey },
    };
    if (action === "down") this.pressedKeys.set(event.code, payload);
    else this.pressedKeys.delete(event.code);
    this.sendInput(payload);
  }

  releaseInputs() {
    for (const payload of this.pressedKeys.values()) this.sendInput({ ...payload, action: "up", repeat: false });
    this.pressedKeys.clear();
    for (const button of this.pressedButtons) {
      this.sendInput({ type: "pointer", action: "up", ...this.lastPoint, button, buttons: 0 });
    }
    this.pressedButtons.clear();
    this.suppressedKeys.clear();
  }
}
