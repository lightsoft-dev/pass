const sessionsNode = document.querySelector("#sessions");
const sessionCount = document.querySelector("#session-count");
const updatedAt = document.querySelector("#updated-at");
const notifyButton = document.querySelector("#notify");

function attentionLabel(session) {
  const attention = session.attention || { state: "idle" };
  return attention.kind || attention.state || "idle";
}

function renderSessions(sessions) {
  sessionsNode.replaceChildren();
  sessionCount.textContent = sessions.length;
  updatedAt.textContent = new Date().toLocaleTimeString();

  if (sessions.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = "No sessions yet.";
    sessionsNode.append(empty);
    return;
  }

  for (const session of sessions) {
    const row = document.createElement("article");
    row.className = `session ${session.needsUser ? "needs-user" : ""}`;

    const title = document.createElement("strong");
    title.textContent = session.displayName;

    const meta = document.createElement("span");
    meta.textContent = `${session.agent} · ${attentionLabel(session)}`;

    row.append(title, meta);
    sessionsNode.append(row);
  }
}

async function refresh() {
  const snapshot = await pass.getSnapshot();
  renderSessions(snapshot.sessions || []);
}

notifyButton.addEventListener("click", async () => {
  notifyButton.disabled = true;
  try {
    await pass.runAction("notify", { message: "UI Starter action ran." });
    notifyButton.textContent = "Sent";
  } catch (error) {
    notifyButton.textContent = "Failed";
  }
  setTimeout(() => {
    notifyButton.textContent = "Notify";
    notifyButton.disabled = false;
  }, 900);
});

refresh().catch((error) => {
  sessionsNode.textContent = error.message;
});
