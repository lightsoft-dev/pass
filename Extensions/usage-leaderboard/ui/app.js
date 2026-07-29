const state = {
  period: 7,
  local: null,
  remote: null,
  busy: true,
};

const nodes = {
  rank: document.querySelector("#rank-value"),
  rankSuffix: document.querySelector("#rank-suffix"),
  rankCaption: document.querySelector("#rank-caption"),
  localPeriod: document.querySelector("#local-period"),
  localTotal: document.querySelector("#local-total"),
  providerBars: document.querySelector("#provider-bars"),
  mixInput: document.querySelector("#mix-input"),
  mixOutput: document.querySelector("#mix-output"),
  mixCache: document.querySelector("#mix-cache"),
  tableTitle: document.querySelector("#table-title"),
  rankings: document.querySelector("#rankings"),
  share: document.querySelector("#share"),
  shareLabel: document.querySelector("#share span"),
  stopSharing: document.querySelector("#stop-sharing"),
  updatedAt: document.querySelector("#updated-at"),
  toast: document.querySelector("#toast"),
};

const emptyTotals = () => ({
  inputTokens: 0,
  outputTokens: 0,
  cacheReadTokens: 0,
  cacheWriteTokens: 0,
  totalTokens: 0,
});

function localDateKey(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function periodRows() {
  if (!state.local) return [];
  const cutoff = new Date();
  cutoff.setHours(0, 0, 0, 0);
  cutoff.setDate(cutoff.getDate() - (state.period - 1));
  const key = localDateKey(cutoff);
  return (state.local.daily || []).filter((row) => row.date >= key);
}

function sumRows(rows) {
  return rows.reduce((total, row) => {
    for (const key of [
      "inputTokens",
      "outputTokens",
      "cacheReadTokens",
      "cacheWriteTokens",
    ]) {
      total[key] += Number(row[key]) || 0;
    }
    total.totalTokens =
      total.inputTokens +
      total.outputTokens +
      total.cacheReadTokens +
      total.cacheWriteTokens;
    return total;
  }, emptyTotals());
}

function formatTokens(value) {
  return new Intl.NumberFormat("ko-KR").format(Number(value) || 0);
}

function compactTokens(value) {
  return new Intl.NumberFormat("en", {
    notation: "compact",
    maximumFractionDigits: 1,
  }).format(Number(value) || 0);
}

function renderLocal() {
  const rows = periodRows();
  const totals = sumRows(rows);
  nodes.localPeriod.textContent = `LAST ${state.period} DAYS`;
  nodes.localTotal.textContent = formatTokens(totals.totalTokens);
  nodes.mixInput.textContent = compactTokens(totals.inputTokens);
  nodes.mixOutput.textContent = compactTokens(totals.outputTokens);
  nodes.mixCache.textContent = compactTokens(
    totals.cacheReadTokens + totals.cacheWriteTokens,
  );

  const providers = ["claude", "codex", "pi"].map((provider) => ({
    provider,
    total: sumRows(rows.filter((row) => row.provider === provider)).totalTokens,
  }));
  const maximum = Math.max(1, ...providers.map((item) => item.total));
  nodes.providerBars.replaceChildren();
  for (const item of providers) {
    const row = document.createElement("div");
    row.className = "provider-row";
    const name = document.createElement("span");
    name.textContent = item.provider.toUpperCase();
    const bar = document.createElement("span");
    bar.className = "bar";
    const fill = document.createElement("i");
    fill.style.setProperty("--bar-width", `${(item.total / maximum) * 100}%`);
    bar.append(fill);
    const total = document.createElement("span");
    total.textContent = compactTokens(item.total);
    row.append(name, bar, total);
    nodes.providerBars.append(row);
  }
}

function renderRemote() {
  const data = state.remote;
  nodes.tableTitle.textContent = `${state.period}-day standings`;
  nodes.rankings.replaceChildren();

  if (!data) {
    const row = document.createElement("li");
    row.className = "empty-row";
    row.textContent = "Pass 로그인 후 랭킹을 불러올 수 있습니다.";
    nodes.rankings.append(row);
    nodes.rank.textContent = "—";
    nodes.rankSuffix.innerHTML = "OFF<br>LINE";
    nodes.rankCaption.textContent = "로컬 사용량은 계속 확인할 수 있습니다.";
    nodes.stopSharing.hidden = true;
    return;
  }

  const rankings = Array.isArray(data.leaderboard) ? data.leaderboard : [];
  if (rankings.length === 0) {
    const row = document.createElement("li");
    row.className = "empty-row";
    row.textContent = "첫 번째 러너가 되어 보세요.";
    nodes.rankings.append(row);
  }
  rankings.forEach((runner, index) => {
    const row = document.createElement("li");
    row.className = `ranking-row${runner.isMe ? " is-me" : ""}`;
    row.style.setProperty("--index", index);

    const position = document.createElement("span");
    position.className = "position";
    position.textContent = String(runner.rank).padStart(2, "0");

    const name = document.createElement("span");
    name.className = "runner";
    name.textContent = runner.displayName || "Pass user";
    if (runner.isMe) {
      const marker = document.createElement("small");
      marker.textContent = "YOU";
      name.append(marker);
    }

    const total = document.createElement("span");
    total.className = "tokens";
    total.textContent = formatTokens(runner.totalTokens);
    row.append(position, name, total);
    nodes.rankings.append(row);
  });

  if (data.me) {
    nodes.rank.textContent = String(data.me.rank).padStart(2, "0");
    nodes.rankSuffix.innerHTML = "IN THE<br>LEAGUE";
    nodes.rankCaption.textContent = `${state.period}일 기준 ${formatTokens(data.me.totalTokens)} tokens`;
  } else {
    nodes.rank.textContent = "—";
    nodes.rankSuffix.innerHTML = "NOT<br>ENTERED";
    nodes.rankCaption.textContent = data.sharing
      ? "이 기간의 공유 사용량이 아직 없습니다."
      : "공유하기 전에는 로컬에만 보관됩니다.";
  }

  nodes.stopSharing.hidden = !data.sharing;
  nodes.shareLabel.textContent = data.sharing ? "공유 데이터 업데이트" : "내 사용량 공유";
  nodes.updatedAt.textContent = data.updatedAt
    ? `SYNC ${new Date(data.updatedAt).toLocaleString("ko-KR")}`
    : "아직 동기화하지 않음";
}

function renderBusy() {
  const hasUsage = sumRows(periodRows()).totalTokens > 0;
  nodes.share.disabled = state.busy || !state.local || !hasUsage;
  document.querySelectorAll(".period").forEach((button) => {
    button.disabled = state.busy;
    button.classList.toggle("is-active", Number(button.dataset.days) === state.period);
  });
}

function toast(message, isError = false) {
  nodes.toast.textContent = message;
  nodes.toast.classList.toggle("is-error", isError);
  nodes.toast.classList.add("is-visible");
  window.clearTimeout(toast.timer);
  toast.timer = window.setTimeout(() => nodes.toast.classList.remove("is-visible"), 3200);
}

async function loadRankings() {
  const action = state.period === 7 ? "rankings-week" : "rankings-month";
  state.remote = await pass.runAction(action);
  renderRemote();
}

async function initialize() {
  const [localResult, remoteResult] = await Promise.allSettled([
    pass.runAction("collect"),
    loadRankings(),
  ]);
  if (localResult.status === "fulfilled") {
    state.local = localResult.value;
    renderLocal();
  } else {
    nodes.localTotal.textContent = "ERROR";
    toast(localResult.reason.message || "로컬 사용량을 읽지 못했습니다.", true);
  }
  if (remoteResult.status === "rejected") {
    state.remote = null;
    renderRemote();
    toast(remoteResult.reason.message || "랭킹을 불러오지 못했습니다.", true);
  }
  state.busy = false;
  renderBusy();
}

document.querySelectorAll(".period").forEach((button) => {
  button.addEventListener("click", async () => {
    const days = Number(button.dataset.days);
    if (days === state.period || state.busy) return;
    state.period = days;
    state.busy = true;
    renderLocal();
    renderBusy();
    try {
      await loadRankings();
    } catch (error) {
      state.remote = null;
      renderRemote();
      toast(error.message || "랭킹을 불러오지 못했습니다.", true);
    } finally {
      state.busy = false;
      renderBusy();
    }
  });
});

nodes.share.addEventListener("click", async () => {
  if (!state.local || state.busy) return;
  state.busy = true;
  renderBusy();
  try {
    const days = (state.local.daily || []).map((row) => ({
      date: row.date,
      provider: row.provider,
      inputTokens: row.inputTokens,
      outputTokens: row.outputTokens,
      cacheReadTokens: row.cacheReadTokens,
      cacheWriteTokens: row.cacheWriteTokens,
    }));
    await pass.runAction("publish", {
      payload: JSON.stringify({ days }),
    });
    await loadRankings();
    toast("일별 합계를 안전하게 공유했습니다.");
  } catch (error) {
    toast(error.message || "사용량을 공유하지 못했습니다.", true);
  } finally {
    state.busy = false;
    renderBusy();
  }
});

nodes.stopSharing.addEventListener("click", async () => {
  if (state.busy || !window.confirm("서버의 내 사용량 합계를 삭제하고 랭킹에서 나갈까요?")) return;
  state.busy = true;
  renderBusy();
  try {
    await pass.runAction("stop-sharing");
    await loadRankings();
    toast("공유 데이터가 삭제되었습니다.");
  } catch (error) {
    toast(error.message || "공유를 중지하지 못했습니다.", true);
  } finally {
    state.busy = false;
    renderBusy();
  }
});

initialize();
