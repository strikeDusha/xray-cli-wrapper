//! Settings persistence, xray config handling, command building, capabilities & autostart.

use std::fs;
use std::net::{IpAddr, ToSocketAddrs};
use std::path::PathBuf;
use std::process::Command;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};

pub const DEFAULT_XRAY: &str = r#"{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": { "udp": true }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "YOUR_SERVER_ADDRESS",
            "port": 443,
            "users": [
              { "id": "YOUR_UUID", "encryption": "none", "flow": "xtls-rprx-vision" }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "serverName": "YOUR_SNI",
          "publicKey": "YOUR_REALITY_PUBLIC_KEY",
          "shortId": "",
          "spiderX": "/"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "direct" }
    ]
  }
}
"#;

#[derive(Clone, Serialize, Deserialize)]
pub struct Settings {
    pub xray_path: String,
    pub tun2proxy_path: String,
    pub proxy: String,
    pub tun_name: String,
    pub dns_mode: String,
    pub dns_addr: String,
    pub bypass: Vec<String>,
    pub ipv6: bool,
    pub use_pkexec: bool,
    pub autostart: bool,
    pub minimize_to_tray: bool,
    pub autoconnect: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            xray_path: "xray".into(),
            tun2proxy_path: "tun2proxy-bin".into(),
            proxy: "socks5://127.0.0.1:10808".into(),
            tun_name: "tun0".into(),
            dns_mode: "virtual".into(),
            dns_addr: String::new(),
            bypass: Vec::new(),
            ipv6: false,
            use_pkexec: false,
            autostart: false,
            minimize_to_tray: true,
            autoconnect: false,
        }
    }
}

fn config_dir(app: &AppHandle) -> PathBuf {
    app.path()
        .app_config_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
}

fn settings_path(app: &AppHandle) -> PathBuf {
    config_dir(app).join("settings.json")
}

fn xray_config_path(app: &AppHandle) -> PathBuf {
    config_dir(app).join("xray-config.json")
}

pub fn load_settings(app: &AppHandle) -> Settings {
    match fs::read_to_string(settings_path(app)) {
        Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
        Err(_) => Settings::default(),
    }
}

pub fn save_settings(app: &AppHandle, settings: &Settings) -> Result<(), String> {
    let dir = config_dir(app);
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let text = serde_json::to_string_pretty(settings).map_err(|e| e.to_string())?;
    fs::write(settings_path(app), text).map_err(|e| e.to_string())
}

pub fn load_xray_config(app: &AppHandle) -> String {
    fs::read_to_string(xray_config_path(app)).unwrap_or_else(|_| DEFAULT_XRAY.to_string())
}

pub fn save_xray_config(app: &AppHandle, content: &str) -> Result<(), String> {
    // Validate before persisting.
    serde_json::from_str::<serde_json::Value>(content)
        .map_err(|e| format!("невалидный JSON: {e}"))?;
    let dir = config_dir(app);
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    fs::write(xray_config_path(app), content).map_err(|e| e.to_string())
}

fn ensure_xray_config_file(app: &AppHandle) -> Result<PathBuf, String> {
    let path = xray_config_path(app);
    if !path.exists() {
        let dir = config_dir(app);
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        fs::write(&path, DEFAULT_XRAY).map_err(|e| e.to_string())?;
    }
    Ok(path)
}

/// Resolve bypass entries (host/IP/CIDR) into IP/CIDR strings tun2proxy understands.
fn resolve_bypass(entries: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for entry in entries {
        let e = entry.trim();
        if e.is_empty() {
            continue;
        }
        if e.contains('/') || e.parse::<IpAddr>().is_ok() {
            out.push(e.to_string()); // already an IP or CIDR
            continue;
        }
        // Hostname: resolve to its A/AAAA records.
        match (e, 0u16).to_socket_addrs() {
            Ok(addrs) => {
                for a in addrs {
                    let ip = a.ip().to_string();
                    if !out.contains(&ip) {
                        out.push(ip);
                    }
                }
            }
            Err(_) => out.push(e.to_string()), // leave as-is; tun2proxy will report it
        }
    }
    out.dedup();
    out
}

/// Build (program, args) for the requested process.
pub fn build_command(
    which: &str,
    settings: &Settings,
    app: &AppHandle,
) -> Result<(String, Vec<String>), String> {
    match which {
        "xray" => {
            let path = ensure_xray_config_file(app)?;
            Ok((
                settings.xray_path.clone(),
                vec![
                    "run".into(),
                    "-c".into(),
                    path.to_string_lossy().into_owned(),
                ],
            ))
        }
        "tun2proxy" => {
            let mut args: Vec<String> = Vec::new();
            let program = if settings.use_pkexec {
                args.push(settings.tun2proxy_path.clone());
                "pkexec".to_string()
            } else {
                settings.tun2proxy_path.clone()
            };

            args.push("--proxy".into());
            args.push(settings.proxy.clone());

            if !settings.tun_name.trim().is_empty() {
                args.push("--tun".into());
                args.push(settings.tun_name.clone());
            }

            args.push("--setup".into());

            if !settings.dns_mode.trim().is_empty() {
                args.push("--dns".into());
                args.push(settings.dns_mode.clone());
            }
            if !settings.dns_addr.trim().is_empty() {
                args.push("--dns-addr".into());
                args.push(settings.dns_addr.clone());
            }

            for ip in resolve_bypass(&settings.bypass) {
                args.push("--bypass".into());
                args.push(ip);
            }

            if settings.ipv6 {
                args.push("--ipv6".into());
            }

            Ok((program, args))
        }
        _ => Err(format!("неизвестный процесс: {which}")),
    }
}

/// Pull server addresses out of the xray config so they can be added to bypass.
pub fn extract_bypass(app: &AppHandle) -> Vec<String> {
    let text = load_xray_config(app);
    let value: serde_json::Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };
    let mut found: Vec<String> = Vec::new();
    let mut add = |addr: Option<&serde_json::Value>| {
        if let Some(s) = addr.and_then(|v| v.as_str()) {
            let s = s.trim();
            if !s.is_empty() && s != "YOUR_SERVER_ADDRESS" && !found.iter().any(|x| x == s) {
                found.push(s.to_string());
            }
        }
    };
    if let Some(outbounds) = value.get("outbounds").and_then(|v| v.as_array()) {
        for ob in outbounds {
            let settings = ob.get("settings");
            // vless / vmess
            if let Some(vnext) = settings.and_then(|s| s.get("vnext")).and_then(|v| v.as_array()) {
                for node in vnext {
                    add(node.get("address"));
                }
            }
            // shadowsocks / trojan / socks
            if let Some(servers) =
                settings.and_then(|s| s.get("servers")).and_then(|v| v.as_array())
            {
                for node in servers {
                    add(node.get("address"));
                }
            }
        }
    }
    found
}

fn resolve_bin(name: &str) -> Option<PathBuf> {
    if name.contains('/') {
        let p = PathBuf::from(name);
        return p.exists().then_some(p);
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|candidate| candidate.exists())
}

pub fn check_capabilities(app: &AppHandle) -> bool {
    let settings = load_settings(app);
    let bin = match resolve_bin(&settings.tun2proxy_path) {
        Some(p) => p,
        None => return false,
    };
    match Command::new("getcap").arg(&bin).output() {
        Ok(out) => String::from_utf8_lossy(&out.stdout).contains("cap_net_admin"),
        Err(_) => false,
    }
}

pub fn grant_capabilities(app: &AppHandle) -> Result<bool, String> {
    let settings = load_settings(app);
    let bin = resolve_bin(&settings.tun2proxy_path)
        .ok_or_else(|| format!("бинарь tun2proxy не найден: {}", settings.tun2proxy_path))?;
    let status = Command::new("pkexec")
        .arg("setcap")
        .arg("cap_net_admin,cap_net_raw+ep")
        .arg(&bin)
        .status()
        .map_err(|e| format!("не удалось запустить pkexec: {e}"))?;
    if status.success() {
        Ok(true)
    } else {
        Err("не удалось выдать capabilities (pkexec отменён или ошибка)".into())
    }
}

pub fn set_autostart(app: &AppHandle, enabled: bool) -> Result<(), String> {
    let base = app
        .path()
        .config_dir()
        .map_err(|e| e.to_string())?
        .join("autostart");
    let file = base.join("v3xtun.desktop");
    if enabled {
        fs::create_dir_all(&base).map_err(|e| e.to_string())?;
        let exe = std::env::current_exe()
            .map_err(|e| e.to_string())?
            .to_string_lossy()
            .into_owned();
        let desktop = format!(
            "[Desktop Entry]\nType=Application\nName=v3xtun\nComment=tun2proxy + xray GUI\nExec={exe}\nIcon=v3xtun\nTerminal=false\nX-GNOME-Autostart-enabled=true\n"
        );
        fs::write(&file, desktop).map_err(|e| e.to_string())?;
    } else if file.exists() {
        fs::remove_file(&file).map_err(|e| e.to_string())?;
    }
    Ok(())
}
