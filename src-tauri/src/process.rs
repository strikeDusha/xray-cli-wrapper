//! Process lifecycle management for xray and tun2proxy child processes.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter};

use crate::config;

const LOG_CAP: usize = 2000;

#[derive(Clone, Serialize)]
pub struct Status {
    pub xray: bool,
    pub tun2proxy: bool,
}

#[derive(Clone, Serialize)]
struct LogLine {
    source: String,
    line: String,
}

/// Shared application state, managed by Tauri.
pub struct AppState {
    xray: Mutex<Option<Child>>,
    tun2proxy: Mutex<Option<Child>>,
    logs_xray: Mutex<VecDeque<String>>,
    logs_t2p: Mutex<VecDeque<String>>,
    last_status: Mutex<(bool, bool)>,
    pub minimize_to_tray: AtomicBool,
}

impl Default for AppState {
    fn default() -> Self {
        AppState {
            xray: Mutex::new(None),
            tun2proxy: Mutex::new(None),
            logs_xray: Mutex::new(VecDeque::new()),
            logs_t2p: Mutex::new(VecDeque::new()),
            last_status: Mutex::new((false, false)),
            minimize_to_tray: AtomicBool::new(true),
        }
    }
}

impl AppState {
    fn slot(&self, which: &str) -> Option<&Mutex<Option<Child>>> {
        match which {
            "xray" => Some(&self.xray),
            "tun2proxy" => Some(&self.tun2proxy),
            _ => None,
        }
    }

    fn log_buf(&self, source: &str) -> &Mutex<VecDeque<String>> {
        if source == "xray" {
            &self.logs_xray
        } else {
            &self.logs_t2p
        }
    }
}

fn push_log(state: &AppState, source: &str, line: &str) {
    let mut buf = state.log_buf(source).lock().unwrap();
    if buf.len() >= LOG_CAP {
        buf.pop_front();
    }
    buf.push_back(line.to_string());
}

pub fn get_logs(state: &AppState, source: &str) -> Vec<String> {
    state.log_buf(source).lock().unwrap().iter().cloned().collect()
}

/// Returns whether the process in `slot` is still alive, reaping it if it exited.
fn alive(slot: &Mutex<Option<Child>>) -> bool {
    let mut guard = slot.lock().unwrap();
    match guard.as_mut() {
        Some(child) => match child.try_wait() {
            Ok(Some(_)) => {
                *guard = None;
                false
            }
            Ok(None) => true,
            Err(_) => {
                *guard = None;
                false
            }
        },
        None => false,
    }
}

pub fn poll_status(state: &AppState) -> Status {
    Status {
        xray: alive(&state.xray),
        tun2proxy: alive(&state.tun2proxy),
    }
}

fn emit_status(app: &AppHandle, state: &AppState) {
    let s = poll_status(state);
    *state.last_status.lock().unwrap() = (s.xray, s.tun2proxy);
    let _ = app.emit("status", s);
}

fn spawn_reader<R: Read + Send + 'static>(
    reader: R,
    source: &'static str,
    app: AppHandle,
    state: Arc<AppState>,
) {
    thread::spawn(move || {
        let buffered = BufReader::new(reader);
        for line in buffered.lines() {
            let line = match line {
                Ok(l) => l,
                Err(_) => break,
            };
            push_log(&state, source, &line);
            let _ = app.emit(
                "log",
                LogLine {
                    source: source.to_string(),
                    line,
                },
            );
        }
    });
}

pub fn start(app: &AppHandle, state: &Arc<AppState>, which: &str) -> Result<(), String> {
    let slot = state
        .slot(which)
        .ok_or_else(|| format!("неизвестный процесс: {which}"))?;
    if alive(slot) {
        return Ok(());
    }

    let settings = config::load_settings(app);
    let (program, args) = config::build_command(which, &settings, app)?;

    let source: &'static str = if which == "xray" { "xray" } else { "tun2proxy" };
    push_log(state, source, &format!("$ {program} {}", args.join(" ")));

    let mut child = Command::new(&program)
        .args(&args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("не удалось запустить {program}: {e}"))?;

    if let Some(out) = child.stdout.take() {
        spawn_reader(out, source, app.clone(), state.clone());
    }
    if let Some(err) = child.stderr.take() {
        spawn_reader(err, source, app.clone(), state.clone());
    }

    *slot.lock().unwrap() = Some(child);
    emit_status(app, state);
    Ok(())
}

pub fn stop(app: &AppHandle, state: &Arc<AppState>, which: &str) -> Result<(), String> {
    let slot = state
        .slot(which)
        .ok_or_else(|| format!("неизвестный процесс: {which}"))?;

    let pid = {
        let guard = slot.lock().unwrap();
        guard.as_ref().map(|c| c.id())
    };

    if let Some(pid) = pid {
        // Graceful: SIGTERM lets tun2proxy restore routing/DNS on its way out.
        unsafe {
            libc::kill(pid as i32, libc::SIGTERM);
        }
        for _ in 0..30 {
            thread::sleep(Duration::from_millis(100));
            if !alive(slot) {
                emit_status(app, state);
                return Ok(());
            }
        }
        // Force-kill if it ignored SIGTERM.
        let mut guard = slot.lock().unwrap();
        if let Some(child) = guard.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        *guard = None;
    }

    emit_status(app, state);
    Ok(())
}

pub fn stop_all(app: &AppHandle, state: &Arc<AppState>) {
    // Stop tun2proxy first so the TUN routes are torn down before xray closes.
    let _ = stop(app, state, "tun2proxy");
    let _ = stop(app, state, "xray");
}

/// Background thread that pushes status changes to the frontend.
pub fn spawn_monitor(app: AppHandle, state: Arc<AppState>) {
    thread::spawn(move || loop {
        thread::sleep(Duration::from_millis(1000));
        let s = poll_status(&state);
        let mut last = state.last_status.lock().unwrap();
        if (s.xray, s.tun2proxy) != *last {
            *last = (s.xray, s.tun2proxy);
            drop(last);
            let _ = app.emit("status", s);
        }
    });
}
