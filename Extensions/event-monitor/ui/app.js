const sessionsNode = document.querySelector("#sessions");
const countNode = document.querySelector("#session-count");
const eventsNode = document.querySelector("#events");
const emptyNode = document.querySelector("#empty-state");
const connectionLight = document.querySelector("#connection-light");
const connectionLabel = document.querySelector("#connection-label");
const generatedAt = document.querySelector("#generated-at");
const clock = document.querySelector("#clock");

const state = { sessions: [], events: [] };

function text(value) {
  return value == null ? "—" : String(value);
}

function renderSessions() {
  sessionsNode.replaceChildren();
  countNode.textContent = String(state.sessions.length).padStart(2, "0");

  for (const session of state.sessions) {
    const article = document.createElement("article");
    const attention = session.attention || { state: "idle" };
    article.className = `session ${session.needsUser ? "needs-user" : attention.state}`;

    const name = document.createElement("p");
    name.className = "session-name";
    name.textContent = session.displayName;

    const meta = document.createElement("p");
    meta.className = "session-meta";
    const stateLabel = document.createElement("span");
    stateLabel.className = "session-state";
    stateLabel.textContent = attention.kind || attention.state;
    meta.append(`${text(session.agent).toUpperCase()} / `, stateLabel,
      document.createElement("br"), session.branch || session.cwd);

    article.append(name, meta);
    sessionsNode.append(article);
  }
}

function renderEvents() {
  eventsNode.replaceChildren();
  emptyNode.hidden = state.events.length > 0;

  for (const event of state.events) {
    const item = document.createElement("li");
    item.className = "event";

    const sequence = document.createElement("span");
    sequence.className = "event-sequence";
    sequence.textContent = String(event.sequence).padStart(3, "0");

    const copy = document.createElement("div");
    const name = document.createElement("p");
    name.className = "event-name";
    name.textContent = event.name;
    const detail = document.createElement("p");
    detail.className = "event-detail";
    detail.textContent = event.session?.displayName
      || event.context?.["session.name"]
      || "global event";
    copy.append(name, detail);

    const time = document.createElement("time");
    time.className = "event-time";
    time.textContent = new Date(event.occurredAt).toLocaleTimeString();
    item.append(sequence, copy, time);
    eventsNode.append(item);
  }
}

function applyEvent(event) {
  state.events.unshift(event);
  state.events = state.events.slice(0, 100);
  if (event.name === "session.created" && event.session) {
    state.sessions = [event.session, ...state.sessions.filter((item) => item.name !== event.session.name)];
  } else if (event.name === "session.ended") {
    const name = event.context?.["session.name"];
    state.sessions = state.sessions.filter((item) => item.name !== name);
  } else if (event.session) {
    state.sessions = state.sessions.map((item) => item.name === event.session.name ? event.session : item);
  }
  renderSessions();
  renderEvents();
}

async function start() {
  pass.on("*", applyEvent);
  try {
    const snapshot = await pass.getSnapshot();
    state.sessions = snapshot.sessions || [];
    generatedAt.textContent = `Snapshot ${new Date(snapshot.generatedAt).toLocaleTimeString()}`;
    connectionLight.classList.add("online");
    connectionLabel.textContent = "BRIDGE ONLINE";
    renderSessions();
  } catch (error) {
    connectionLabel.textContent = "BRIDGE ERROR";
    generatedAt.textContent = error.message;
  }
}

document.querySelector("#clear").addEventListener("click", () => {
  state.events = [];
  renderEvents();
});

document.querySelector("#ping").addEventListener("click", async () => {
  const button = document.querySelector("#ping");
  button.disabled = true;
  try {
    await pass.runAction("ping", { message: `Bridge online at ${new Date().toLocaleTimeString()}` });
    button.textContent = "SENT";
  } catch (error) {
    button.textContent = "FAILED";
  }
  setTimeout(() => { button.textContent = "PING HOST"; button.disabled = false; }, 900);
});

setInterval(() => { clock.textContent = new Date().toLocaleTimeString(); }, 1_000);
clock.textContent = new Date().toLocaleTimeString();
start();
