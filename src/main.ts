import "./styles.css";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

interface Settings {
  xray_path: string;
  tun2proxy_path: string;
  proxy: string;
  tun_name: string;
  dns_mode: string;
  dns_addr: string;
  bypass: string[];
  ipv6: boolean;
  use_pkexec: boolean;
  autostart: boolean;
  minimize_to_tray: boolean;
  autoconnect: boolean;
}

interface Status {
  xray: boolean;
  tun2proxy: boolean;
}

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const logBuffers: Record<string, string[]> = { xray: [], tun2proxy: [] };
let settings: Settings;

// ---------- toast ----------
function toast(msg: string, kind: "ok" | "err" | "" = "") {
  const el = document.createElement("div");
  el.className = `toast ${kind}`;
  el.textContent = msg;
  document.body.appendChild(el);
  requestAnimationFrame(() => el.classList.add("show"));
  setTimeout(() => {
    el.classList.remove("show");
    setTimeout(() => el.remove(), 250);
  }, 3200);
}

async function call<T>(cmd: string, args?: Record<string, unknown>): Promise<T | undefined> {
  try {
    return await invoke<T>(cmd, args);
  } catch (e) {
    toast(`Ошибка: ${e}`, "err");
    return undefined;
  }
}

// ---------- tabs ----------
document.querySelectorAll<HTMLButtonElement>(".nav-item").forEach((btn) => {
  btn.addEventListener("click", () => {
    const tab = btn.dataset.tab!;
    document.querySelectorAll(".nav-item").forEach((b) => b.classList.toggle("active", b === btn));
    document.querySelectorAll(".tab").forEach((s) =>
      s.classList.toggle("active", (s as HTMLElement).dataset.tab === tab)
    );
  });
});

// ---------- status rendering ----------
function setPill(el: HTMLElement, on: boolean) {
  el.textContent = on ? "работает" : "стоп";
  el.classList.toggle("on", on);
  el.classList.toggle("off", !on);
}

function renderStatus(s: Status) {
  setPill($("pill-xray"), s.xray);
  setPill($("pill-t2p"), s.tun2proxy);
  setPill($("card-xray"), s.xray);
  setPill($("card-t2p"), s.tun2proxy);
  $("brand-dot").classList.toggle("on", s.xray && s.tun2proxy);
}

// ---------- logs ----------
function appendLog(source: string, line: string) {
  const buf = logBuffers[source] ?? (logBuffers[source] = []);
  buf.push(line);
  if (buf.length > 2000) buf.splice(0, buf.length - 2000);
  if (($("log-source") as HTMLSelectElement).value === source) renderLog();
}

function renderLog() {
  const source = ($("log-source") as HTMLSelectElement).value;
  const view = $("log-view");
  view.textContent = (logBuffers[source] ?? []).join("\n");
  if (($("log-autoscroll") as HTMLInputElement).checked) view.scrollTop = view.scrollHeight;
}

// ---------- settings <-> form ----------
function settingsToForm(s: Settings) {
  ($("r-proxy") as HTMLInputElement).value = s.proxy;
  ($("r-tun") as HTMLInputElement).value = s.tun_name;
  ($("r-dns") as HTMLSelectElement).value = s.dns_mode;
  ($("r-dnsaddr") as HTMLInputElement).value = s.dns_addr;
  ($("r-bypass") as HTMLTextAreaElement).value = s.bypass.join("\n");
  ($("r-ipv6") as HTMLInputElement).checked = s.ipv6;
  ($("r-pkexec") as HTMLInputElement).checked = s.use_pkexec;
  ($("s-xray") as HTMLInputElement).value = s.xray_path;
  ($("s-t2p") as HTMLInputElement).value = s.tun2proxy_path;
  ($("s-autostart") as HTMLInputElement).checked = s.autostart;
  ($("s-tray") as HTMLInputElement).checked = s.minimize_to_tray;
  ($("s-autoconnect") as HTMLInputElement).checked = s.autoconnect;
}

function formToSettings(): Settings {
  return {
    ...settings,
    proxy: ($("r-proxy") as HTMLInputElement).value.trim(),
    tun_name: ($("r-tun") as HTMLInputElement).value.trim(),
    dns_mode: ($("r-dns") as HTMLSelectElement).value,
    dns_addr: ($("r-dnsaddr") as HTMLInputElement).value.trim(),
    bypass: ($("r-bypass") as HTMLTextAreaElement).value.split("\n").map((s) => s.trim()).filter(Boolean),
    ipv6: ($("r-ipv6") as HTMLInputElement).checked,
    use_pkexec: ($("r-pkexec") as HTMLInputElement).checked,
    xray_path: ($("s-xray") as HTMLInputElement).value.trim() || "xray",
    tun2proxy_path: ($("s-t2p") as HTMLInputElement).value.trim() || "tun2proxy-bin",
    autostart: ($("s-autostart") as HTMLInputElement).checked,
    minimize_to_tray: ($("s-tray") as HTMLInputElement).checked,
    autoconnect: ($("s-autoconnect") as HTMLInputElement).checked,
  };
}

async function persist(extra?: () => void) {
  settings = formToSettings();
  extra?.();
  await call("save_settings", { settings });
}

// ---------- capabilities ----------
async function refreshCaps() {
  if (settings.use_pkexec) {
    $("caps-warn").classList.add("hidden");
    return;
  }
  const ok = await call<boolean>("check_capabilities");
  $("caps-warn").classList.toggle("hidden", ok !== false);
}

// ---------- wire buttons ----------
function wire() {
  $("btn-xray-start").onclick = () => call("start_process", { which: "xray" });
  $("btn-xray-stop").onclick = () => call("stop_process", { which: "xray" });
  $("btn-t2p-start").onclick = () => call("start_process", { which: "tun2proxy" });
  $("btn-t2p-stop").onclick = () => call("stop_process", { which: "tun2proxy" });
  $("btn-connect").onclick = async () => {
    await call("start_process", { which: "xray" });
    await call("start_process", { which: "tun2proxy" });
  };
  $("btn-disconnect").onclick = () => call("stop_all");

  $("btn-grant").onclick = async () => {
    const r = await call<boolean>("grant_capabilities");
    if (r) { toast("Capabilities выданы", "ok"); refreshCaps(); }
  };

  // xray config
  $("btn-config-save").onclick = async () => {
    const text = ($("xray-config") as HTMLTextAreaElement).value;
    try { JSON.parse(text); } catch (e) { toast(`Невалидный JSON: ${e}`, "err"); return; }
    const ok = await call("save_xray_config", { content: text });
    if (ok !== undefined) { $("config-status").textContent = "сохранено"; toast("Конфиг сохранён", "ok"); }
  };
  $("btn-config-format").onclick = () => {
    const ta = $("xray-config") as HTMLTextAreaElement;
    try { ta.value = JSON.stringify(JSON.parse(ta.value), null, 2); }
    catch (e) { toast(`Невалидный JSON: ${e}`, "err"); }
  };
  $("btn-config-reset").onclick = async () => {
    const def = await call<string>("default_xray_config");
    if (def) ($("xray-config") as HTMLTextAreaElement).value = def;
  };

  // routing
  $("btn-routing-save").onclick = async () => {
    await persist();
    $("routing-status").textContent = "сохранено";
    toast("Настройки маршрутизации сохранены", "ok");
  };
  $("btn-bypass-extract").onclick = async () => {
    const addrs = await call<string[]>("extract_bypass");
    if (!addrs) return;
    if (addrs.length === 0) { toast("Адреса серверов в конфиге не найдены", ""); return; }
    const ta = $("r-bypass") as HTMLTextAreaElement;
    const existing = new Set(ta.value.split("\n").map((s) => s.trim()).filter(Boolean));
    addrs.forEach((a) => existing.add(a));
    ta.value = [...existing].join("\n");
    toast(`Добавлено адресов: ${addrs.length}`, "ok");
  };

  // settings
  $("btn-settings-save").onclick = async () => {
    const prevAutostart = settings.autostart;
    await persist();
    if (settings.autostart !== prevAutostart) await call("set_autostart", { enabled: settings.autostart });
    await refreshCaps();
    $("settings-status").textContent = "сохранено";
    toast("Настройки сохранены", "ok");
  };
  $("btn-caps-check").onclick = async () => {
    const ok = await call<boolean>("check_capabilities");
    toast(ok ? "cap_net_admin присутствует" : "cap_net_admin отсутствует", ok ? "ok" : "err");
    refreshCaps();
  };

  // logs
  $("log-source").onchange = renderLog;
  $("btn-log-clear").onclick = () => {
    const source = ($("log-source") as HTMLSelectElement).value;
    logBuffers[source] = [];
    renderLog();
  };
}

// ---------- init ----------
async function init() {
  wire();

  await listen<Status>("status", (e) => renderStatus(e.payload));
  await listen<{ source: string; line: string }>("log", (e) => appendLog(e.payload.source, e.payload.line));

  settings = (await call<Settings>("get_settings"))!;
  if (settings) settingsToForm(settings);

  const cfg = await call<string>("get_xray_config");
  if (cfg !== undefined) ($("xray-config") as HTMLTextAreaElement).value = cfg;

  const status = await call<Status>("get_status");
  if (status) renderStatus(status);

  for (const src of ["xray", "tun2proxy"]) {
    const lines = await call<string[]>("get_logs", { source: src });
    if (lines) logBuffers[src] = lines;
  }
  renderLog();

  await refreshCaps();
}

init();
