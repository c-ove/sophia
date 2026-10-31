const state = {
  q: "",
  ips: new Set(),
  team: "",
  events: [],
  ids: new Set(),
  nextCursor: null,
  hosts: [],
  teams: [],
  editingMappingId: null,
  stream: null,
  requestId: 0,
};

const elements = Object.fromEntries([
  "event-feed", "empty-state", "load-more", "result-count", "command-search",
  "host-search", "host-list", "host-count", "host-selection-summary", "team-filter", "clear-filters", "clear-hosts",
  "connection-status", "error-banner", "csv-file", "upload-button", "clear-teams",
  "upload-status", "team-summary", "mapping-cidr", "mapping-team",
  "mapping-save", "mapping-cancel", "mapping-status", "bulk-cidr",
  "bulk-teams", "bulk-add", "bulk-status", "theme-toggle",
].map((id) => [id, document.getElementById(id)]));

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function filterParams(includePagination = false) {
  const params = new URLSearchParams();
  if (state.q) params.set("q", state.q);
  for (const ip of [...state.ips].sort()) params.append("ip", ip);
  if (state.team) params.set("team", state.team);
  if (includePagination) params.set("limit", "50");
  return params;
}

async function fetchJson(path, options = {}) {
  const response = await fetch(path, options);
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.detail || `Request failed (${response.status})`);
  return body;
}

function formatTime(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString([], {
    month: "short", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
}

function eventCard(event) {
  const card = element("article", "event-card");
  const summary = element("div", "event-summary");
  const meta = element("div", "event-meta");
  meta.append(element("span", "event-time", formatTime(event.started_at)));
  meta.append(element("span", "host-badge", event.host_ip));
  for (const team of event.teams) meta.append(element("span", "team-badge", team));
  const commandLine = element("div", "command-line");
  commandLine.append(element("code", "command-text", event.command));
  summary.append(meta, commandLine);
  card.append(summary);

  const actions = element("div", "event-actions");
  if (event.output) {
    const output = element("details", "output-details");
    output.append(element("summary", "", "Output"));
    output.append(element("pre", "", event.output));
    actions.append(output);
  } else {
    actions.append(element("span", "no-output", "No output"));
  }

  const information = element("details", "event-information");
  information.append(element("summary", "", "Details"));
  const details = element("div", "event-details");
  const exitClass = event.exit_code === 0 ? "success" : "failure";
  const exitRow = element("div", "event-detail-row");
  exitRow.append(element("span", "", "Exit status"), element("strong", exitClass, String(event.exit_code ?? "?")));
  const durationRow = element("div", "event-detail-row");
  durationRow.append(element("span", "", "Duration"), element("span", "", `${event.duration_ms} ms`));
  details.append(exitRow, durationRow);
  if (event.truncated) {
    const truncatedRow = element("div", "event-detail-row");
    truncatedRow.append(element("span", "", "Output"), element("span", "warning", "Truncated"));
    details.append(truncatedRow);
  }
  const idRow = element("div", "event-detail-row");
  idRow.append(element("span", "", "Event ID"));
  const idButton = element("button", "event-id", event.id.slice(0, 8));
  idButton.type = "button";
  idButton.title = `Copy rerun ID: ${event.id}`;
  idButton.addEventListener("click", async () => {
    try {
      if (!navigator.clipboard) throw new Error("Clipboard unavailable");
      await navigator.clipboard.writeText(event.id);
      idButton.textContent = "Copied";
      setTimeout(() => { idButton.textContent = event.id.slice(0, 8); }, 1200);
    } catch (_) {
      window.prompt("Copy this event ID:", event.id);
    }
  });
  idRow.append(idButton);
  details.append(idRow);
  information.append(details);
  actions.append(information);
  card.append(actions);
  return card;
}

function renderEvents() {
  elements["event-feed"].replaceChildren(...state.events.map(eventCard));
  const count = state.events.length;
  elements["result-count"].textContent = `${count.toLocaleString()} command${count === 1 ? "" : "s"}`;
  elements["empty-state"].hidden = count !== 0;
  elements["load-more"].hidden = !state.nextCursor;
  elements["clear-filters"].hidden = !(state.q || state.ips.size || state.team);
}

async function loadEvents(reset = true) {
  const requestId = ++state.requestId;
  const params = filterParams(true);
  if (!reset && state.nextCursor) params.set("cursor", state.nextCursor);
  elements["error-banner"].hidden = true;
  try {
    const result = await fetchJson(`/api/events?${params}`);
    if (requestId !== state.requestId) return;
    if (reset) {
      state.events = result.items;
      state.ids = new Set(result.items.map((event) => event.id));
    } else {
      for (const event of result.items) {
        if (!state.ids.has(event.id)) {
          state.events.push(event);
          state.ids.add(event.id);
        }
      }
    }
    state.nextCursor = result.next_cursor;
    renderEvents();
  } catch (error) {
    elements["error-banner"].textContent = error.message;
    elements["error-banner"].hidden = false;
  }
}

function setConnection(status, label) {
  elements["connection-status"].className = `connection-status ${status}`;
  elements["connection-status"].replaceChildren(element("span"), document.createTextNode(label));
}

function connectStream() {
  if (state.stream) state.stream.close();
  setConnection("connecting", "Connecting");
  state.stream = new EventSource(`/api/events/stream?${filterParams()}`);
  state.stream.onopen = () => setConnection("live", "Live");
  state.stream.onerror = () => setConnection("offline", "Reconnecting");
  state.stream.addEventListener("command", (message) => {
    const event = JSON.parse(message.data);
    if (state.ids.has(event.id)) return;
    state.events.unshift(event);
    state.ids.add(event.id);
    if (state.events.length > 100) {
      const removed = state.events.pop();
      state.ids.delete(removed.id);
    }
    renderEvents();
  });
}

function renderHosts() {
  const query = elements["host-search"].value.trim().toLowerCase();
  const hosts = state.hosts.filter((host) =>
    `${host.host_ip} ${host.hostname} ${host.teams.join(" ")}`.toLowerCase().includes(query));
  elements["host-count"].textContent = `${state.hosts.length} host${state.hosts.length === 1 ? "" : "s"}`;
  elements["host-selection-summary"].textContent = state.ips.size
    ? `${state.ips.size} selected`
    : "Select hosts";
  elements["clear-hosts"].hidden = state.ips.size === 0;
  elements["clear-hosts"].textContent = state.ips.size ? `Clear (${state.ips.size})` : "Clear";
  if (!hosts.length) {
    elements["host-list"].replaceChildren(element("p", "muted", "No matching hosts"));
    return;
  }
  const buttons = hosts.map((host) => {
    const selected = state.ips.has(host.host_ip);
    const button = element("button", `host-item${selected ? " active" : ""}`);
    button.type = "button";
    button.setAttribute("aria-pressed", String(selected));
    const ipLine = element("div", "host-ip");
    ipLine.append(element("span", "", host.host_ip), element("span", "", host.command_count.toLocaleString()));
    const meta = element("div", "host-meta");
    meta.append(
      element("span", "host-team", host.teams.join(", ") || host.hostname),
      element("span", "", host.hostname),
    );
    button.append(ipLine, meta);
    button.addEventListener("click", () => {
      if (state.ips.has(host.host_ip)) {
        state.ips.delete(host.host_ip);
      } else {
        state.ips.add(host.host_ip);
      }
      renderHosts();
      loadEvents(true);
      connectStream();
    });
    return button;
  });
  elements["host-list"].replaceChildren(...buttons);
}

async function loadHosts() {
  try {
    state.hosts = (await fetchJson("/api/hosts")).items;
    renderHosts();
  } catch (_) {
    elements["host-list"].replaceChildren(element("p", "muted", "Hosts unavailable"));
  }
}

function setMappingStatus(message, isError = false) {
  elements["mapping-status"].textContent = message;
  elements["mapping-status"].className = `upload-status${isError ? " error" : ""}`;
}

function resetMappingForm() {
  state.editingMappingId = null;
  elements["mapping-cidr"].value = "";
  elements["mapping-team"].value = "";
  elements["mapping-save"].textContent = "Add mapping";
  elements["mapping-cancel"].hidden = true;
}

function renderTeamMappings() {
  const groups = [];
  for (const team of state.teams) {
    const group = element("div", "mapping-group");
    group.append(element("div", "mapping-team-name", team.name));
    for (const mapping of team.mappings) {
      const row = element("div", "mapping-row");
      row.append(element("span", "mapping-cidr", mapping.cidr));
      const edit = element("button", "", "Edit");
      edit.type = "button";
      edit.addEventListener("click", () => {
        state.editingMappingId = mapping.id;
        elements["mapping-cidr"].value = mapping.cidr;
        elements["mapping-team"].value = team.name;
        elements["mapping-save"].textContent = "Update mapping";
        elements["mapping-cancel"].hidden = false;
        elements["mapping-cidr"].focus();
      });
      const remove = element("button", "mapping-delete", "Delete");
      remove.type = "button";
      remove.addEventListener("click", async () => {
        if (!window.confirm(`Remove ${mapping.cidr} from ${team.name}?`)) return;
        try {
          await fetchJson(`/api/teams/mappings/${mapping.id}`, { method: "DELETE" });
          if (state.editingMappingId === mapping.id) resetMappingForm();
          setMappingStatus(`Removed ${mapping.cidr}`);
          await refreshMappings();
        } catch (error) {
          setMappingStatus(error.message, true);
        }
      });
      row.append(edit, remove);
      group.append(row);
    }
    groups.push(group);
  }
  if (!groups.length) groups.push(element("p", "muted", "No team mappings configured"));
  elements["team-summary"].replaceChildren(...groups);
}

async function refreshMappings() {
  await loadTeams();
  await Promise.all([loadHosts(), loadEvents(true)]);
  connectStream();
}

async function loadTeams() {
  try {
    state.teams = (await fetchJson("/api/teams")).items;
    const selected = state.team;
    const options = [new Option("All target teams", "")];
    for (const team of state.teams) options.push(new Option(team.name, String(team.id)));
    elements["team-filter"].replaceChildren(...options);
    elements["team-filter"].value = selected;
    if (!elements["team-filter"].value) state.team = "";
    renderTeamMappings();
  } catch (error) {
    setMappingStatus(error.message, true);
  }
}

let searchTimer;
elements["command-search"].addEventListener("input", (event) => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => {
    state.q = event.target.value.trim();
    loadEvents(true);
    connectStream();
  }, 300);
});

elements["host-search"].addEventListener("input", renderHosts);
elements["team-filter"].addEventListener("change", (event) => {
  state.team = event.target.value;
  loadEvents(true);
  connectStream();
});
elements["clear-filters"].addEventListener("click", () => {
  state.q = "";
  state.ips.clear();
  state.team = "";
  elements["command-search"].value = "";
  elements["team-filter"].value = "";
  renderHosts();
  loadEvents(true);
  connectStream();
});
elements["clear-hosts"].addEventListener("click", () => {
  state.ips.clear();
  renderHosts();
  loadEvents(true);
  connectStream();
});
elements["load-more"].addEventListener("click", () => loadEvents(false));

elements["mapping-save"].addEventListener("click", async () => {
  const cidr = elements["mapping-cidr"].value.trim();
  const team = elements["mapping-team"].value.trim();
  if (!cidr || !team) {
    setMappingStatus("Enter both a CIDR range and team name", true);
    return;
  }
  const mappingId = state.editingMappingId;
  const path = mappingId ? `/api/teams/mappings/${mappingId}` : "/api/teams/mappings";
  elements["mapping-save"].disabled = true;
  try {
    await fetchJson(path, {
      method: mappingId ? "PUT" : "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ cidr, team }),
    });
    setMappingStatus(mappingId ? `Updated ${cidr}` : `Added ${cidr}`);
    resetMappingForm();
    await refreshMappings();
  } catch (error) {
    setMappingStatus(error.message, true);
  } finally {
    elements["mapping-save"].disabled = false;
  }
});
elements["mapping-cancel"].addEventListener("click", () => {
  resetMappingForm();
  setMappingStatus("");
});

elements["bulk-add"].addEventListener("click", async () => {
  const cidr = elements["bulk-cidr"].value.trim();
  const teams = Number(elements["bulk-teams"].value);
  if (!cidr || !Number.isInteger(teams) || teams < 1 || teams > 100) {
    elements["bulk-status"].textContent = "Enter a starting /24 and 1–100 teams";
    elements["bulk-status"].className = "upload-status error";
    return;
  }
  elements["bulk-add"].disabled = true;
  elements["bulk-status"].textContent = `Generating ${teams} ranges…`;
  elements["bulk-status"].className = "upload-status";
  try {
    const result = await fetchJson("/api/teams/bulk", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ cidr, teams }),
    });
    elements["bulk-status"].textContent = `Added ${result.ranges} consecutive ranges`;
    await refreshMappings();
  } catch (error) {
    elements["bulk-status"].textContent = error.message;
    elements["bulk-status"].className = "upload-status error";
  } finally {
    elements["bulk-add"].disabled = false;
  }
});

elements["clear-teams"].addEventListener("click", async () => {
  if (!window.confirm("Remove all teams and CIDR mappings? Command history will not be deleted.")) return;
  try {
    await fetchJson("/api/teams", { method: "DELETE" });
    resetMappingForm();
    elements["upload-status"].className = "upload-status";
    elements["upload-status"].textContent = "Cleared all teams";
    await refreshMappings();
  } catch (error) {
    elements["upload-status"].textContent = error.message;
    elements["upload-status"].className = "upload-status error";
  }
});

elements["upload-button"].addEventListener("click", () => elements["csv-file"].click());
elements["csv-file"].addEventListener("change", async (event) => {
  const [file] = event.target.files;
  if (!file) return;
  elements["upload-status"].className = "upload-status";
  elements["upload-status"].textContent = `Importing ${file.name}…`;
  try {
    const content = await file.text();
    const result = await fetchJson("/api/teams/import", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ content }),
    });
    elements["upload-status"].textContent = `Imported ${result.ranges} ranges`;
    resetMappingForm();
    await refreshMappings();
  } catch (error) {
    elements["upload-status"].textContent = error.message;
    elements["upload-status"].className = "upload-status error";
  } finally {
    event.target.value = "";
  }
});

document.addEventListener("keydown", (event) => {
  if (event.key === "/" && !["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement.tagName)) {
    event.preventDefault();
    elements["command-search"].focus();
  }
});

elements["theme-toggle"].checked = document.documentElement.dataset.theme === "dark";
elements["theme-toggle"].addEventListener("change", (event) => {
  const dark = event.target.checked;
  if (dark) {
    document.documentElement.dataset.theme = "dark";
  } else {
    delete document.documentElement.dataset.theme;
  }
  try {
    localStorage.setItem("athena-theme", dark ? "dark" : "light");
  } catch (_) {}
});

loadTeams();
loadHosts();
loadEvents(true);
connectStream();
setInterval(loadHosts, 15000);
