const state = {
  token: sessionStorage.getItem("noop_api_token") || "",
  status: null,
  devices: [],
  selected: null,
};

const byId = (id) => document.getElementById(id);
const errorBox = byId("errorMessage");

function showError(message) {
  errorBox.textContent = message;
  errorBox.classList.remove("hidden");
}

function clearError() {
  errorBox.textContent = "";
  errorBox.classList.add("hidden");
}

async function api(path, options = {}) {
  const headers = new Headers(options.headers || {});
  headers.set("Accept", "application/json");
  headers.set("Authorization", `Bearer ${state.token}`);
  if (options.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  const response = await fetch(path, { ...options, headers, cache: "no-store" });
  if (!response.ok) {
    let detail = `${response.status} ${response.statusText}`;
    try {
      const body = await response.json();
      detail = typeof body.detail === "string" ? body.detail : JSON.stringify(body.detail);
    } catch (_) {}
    throw new Error(detail);
  }
  return response;
}

function textElement(tag, className, value) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  element.textContent = value;
  return element;
}

function provenanceLabel(device) {
  const namespace = device?.metadata?.namespace;
  if (namespace === "official_reference") return "WHOOP import reference";
  if (namespace === "noop_computed") return "Noop computed";
  if (namespace === "noop_journal") return "Noop journal";
  if (namespace === "strap_measured" || namespace === "strap") return "Strap measured";
  return namespace ? namespace.replaceAll("_", " ") : "Unspecified source";
}

function prettyMetric(metric) {
  const names = {
    hr: "Heart rate",
    rr: "R–R interval",
    battery: "Battery",
    spo2: "SpO₂ channel",
    skin_temp: "Temperature channel",
    respiration: "Respiration channel",
    steps: "Step counter",
  };
  return names[metric] || metric.replaceAll("_", " ");
}

function formatValue(sample) {
  if (!sample) return { value: "—", unit: "", raw: false };
  const raw = ["raw_sensor", "unclassified_sensor"].includes(sample.measurement_class);
  const value = Number(sample.value);
  let rendered = Number.isInteger(value) ? value.toLocaleString() : value.toLocaleString(undefined, { maximumFractionDigits: 2 });
  return { value: rendered, unit: raw ? (sample.unit || "raw") : sample.unit, raw };
}

function renderMetrics(latest) {
  const grid = byId("summaryGrid");
  grid.replaceChildren();
  const preferred = ["hr", "rr", "battery", "steps", "spo2", "skin_temp", "respiration"];
  const keys = preferred.filter((key) => latest[key]).slice(0, 8);
  if (!keys.length) {
    const empty = textElement("p", "empty", "No decoded stream samples uploaded yet.");
    grid.append(empty);
    return;
  }
  for (const metric of keys) {
    const sample = latest[metric];
    const formatted = formatValue(sample);
    const card = document.createElement("article");
    card.className = "metric-card";
    const head = document.createElement("div");
    head.className = "metric-head";
    head.append(textElement("span", "", prettyMetric(metric)));
    head.append(textElement("span", `chip${formatted.raw ? " raw" : ""}`, formatted.raw ? "Raw sensor" : sample.measurement_class.replaceAll("_", " ")));
    const value = textElement("span", "metric-value", formatted.value);
    value.append(textElement("small", "metric-unit", formatted.unit));
    card.append(head, value);
    card.append(textElement("time", "metric-time", new Date(sample.recorded_at).toLocaleString()));
    grid.append(card);
  }
}

function appendDefinition(list, name, value) {
  list.append(textElement("dt", "", name), textElement("dd", "", value || "—"));
}

function renderProvenance(device) {
  byId("namespaceTitle").textContent = provenanceLabel(device);
  const list = byId("provenanceList");
  list.replaceChildren();
  appendDefinition(list, "Namespace ID", device.device_id);
  appendDefinition(list, "Role", provenanceLabel(device));
  appendDefinition(list, "Device", device.display_name || device.model);
  appendDefinition(list, "Platform", device.platform);
  appendDefinition(list, "App version", device.app_version);
  appendDefinition(list, "Last seen", device.last_seen ? new Date(device.last_seen).toLocaleString() : null);
  appendDefinition(list, "Score source", device.metadata?.score_provenance);
  appendDefinition(list, "Paired device", device.metadata?.paired_device_id);
}

function renderStats() {
  const container = byId("syncStats");
  container.replaceChildren();
  const stats = state.status?.stats || {};
  const fields = [
    ["Samples", stats.metric_samples],
    ["Daily values", stats.daily_metrics],
    ["Sleep sessions", stats.sleep_sessions],
    ["Sync batches", stats.sync_batches],
  ];
  for (const [label, value] of fields) {
    const card = document.createElement("div");
    card.className = "stat";
    card.append(textElement("strong", "", Number(value || 0).toLocaleString()), textElement("span", "", label));
    container.append(card);
  }
  const days = state.status?.retention_days;
  byId("retentionDescription").textContent = days
    ? `The server is configured to retain ${days} days. Running retention permanently purges older records and receipts.`
    : "Automatic retention is disabled. Set NOOP_RETENTION_DAYS on the server and restart to enable it.";
  byId("retentionButton").disabled = !days;
}

function renderChart(days) {
  const chart = byId("dailyChart");
  chart.replaceChildren();
  const values = days.filter((row) =>
    row.metrics?.recovery != null ||
    row.metrics?.charge != null ||
    row.metrics?.effort != null ||
    row.metrics?.whoop_strain != null
  ).slice(-30);
  if (!values.length) {
    chart.append(textElement("p", "empty", "No Recovery or Effort/WHOOP Strain values uploaded for this namespace."));
    return;
  }
  for (const row of values) {
    const column = document.createElement("div");
    column.className = "day-column";
    const recovery = row.metrics.recovery ?? row.metrics.charge;
    const load = row.metrics.whoop_strain ?? row.metrics.effort;
    const loadName = row.metrics.whoop_strain != null ? "WHOOP Strain" : "Noop Effort";
    const loadMax = row.metrics.whoop_strain != null ? 21 : 100;
    column.title = `${row.day}: Recovery ${recovery ?? "—"}, ${loadName} ${load ?? "—"}`;
    if (recovery != null) {
      const bar = document.createElement("i");
      bar.className = "bar recovery";
      const height = Math.max(1, Math.min(20, Math.ceil(Number(recovery) / 5)));
      bar.classList.add(`h-${height}`);
      column.append(bar);
    }
    if (load != null) {
      const bar = document.createElement("i");
      bar.className = "bar strain";
      const height = Math.max(1, Math.min(20, Math.ceil(Number(load) / loadMax * 20)));
      bar.classList.add(`h-${height}`);
      column.append(bar);
    }
    column.append(textElement("time", "", row.day.slice(5)));
    chart.append(column);
  }
}

async function loadSelected() {
  if (!state.selected) return;
  clearError();
  const encoded = encodeURIComponent(state.selected.device_id);
  const [latestResponse, dailyResponse] = await Promise.all([
    api(`/v1/devices/${encoded}/latest`),
    api(`/v1/devices/${encoded}/daily`),
  ]);
  const latest = await latestResponse.json();
  const daily = await dailyResponse.json();
  renderMetrics(latest.metrics);
  renderProvenance(state.selected);
  renderChart(daily.days);
}

async function connect() {
  clearError();
  const [statusResponse, devicesResponse] = await Promise.all([
    api("/v1/status"),
    api("/v1/devices"),
  ]);
  state.status = await statusResponse.json();
  state.devices = (await devicesResponse.json()).devices;
  const selector = byId("deviceSelect");
  selector.replaceChildren();
  for (const device of state.devices) {
    const option = document.createElement("option");
    option.value = device.device_id;
    option.textContent = `${provenanceLabel(device)} · ${device.device_id}`;
    selector.append(option);
  }
  state.selected = state.devices[0] || null;
  byId("workspace").classList.remove("hidden");
  byId("connectionState").classList.add("online");
  byId("connectionState").lastElementChild.textContent = "Connected";
  renderStats();
  if (state.selected) await loadSelected();
  else {
    renderMetrics({});
    byId("namespaceTitle").textContent = "Waiting for first upload";
  }
}

byId("connectForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  state.token = byId("token").value.trim();
  if (!state.token) return;
  sessionStorage.setItem("noop_api_token", state.token);
  try { await connect(); } catch (error) { showError(error.message); }
});

byId("deviceSelect").addEventListener("change", async (event) => {
  state.selected = state.devices.find((item) => item.device_id === event.target.value);
  try { await loadSelected(); } catch (error) { showError(error.message); }
});

byId("refreshButton").addEventListener("click", async () => {
  try { await connect(); } catch (error) { showError(error.message); }
});

byId("exportButton").addEventListener("click", async () => {
  if (!state.selected) return;
  try {
    const response = await api(`/v1/devices/${encodeURIComponent(state.selected.device_id)}/export`);
    const blob = await response.blob();
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = `noop-${state.selected.device_id}-export.json`;
    link.click();
    URL.revokeObjectURL(link.href);
  } catch (error) { showError(error.message); }
});

byId("retentionButton").addEventListener("click", async () => {
  if (!confirm("Permanently purge records older than the configured retention window? Export anything you need first.")) return;
  try {
    const response = await api("/v1/admin/retention/run", {
      method: "POST",
      headers: { "X-Noop-Confirm": "PURGE" },
      body: JSON.stringify({}),
    });
    const result = await response.json();
    alert(`Retention complete. Removed ${Object.values(result.counts).reduce((a, b) => a + b, 0)} records.`);
    await connect();
  } catch (error) { showError(error.message); }
});

byId("eraseButton").addEventListener("click", async () => {
  if (!state.selected) return;
  const id = state.selected.device_id;
  const typed = prompt(`This cannot be undone. Type the namespace ID to erase it:\n${id}`);
  if (typed !== id) return;
  try {
    await api(`/v1/devices/${encodeURIComponent(id)}`, {
      method: "DELETE",
      headers: { "X-Noop-Confirm": `DELETE ${id}` },
    });
    await connect();
  } catch (error) { showError(error.message); }
});

if (state.token) {
  byId("token").value = state.token;
  connect().catch((error) => showError(error.message));
}
