//! Tauri command handlers bridging the frontend to backend logic.

use std::sync::atomic::Ordering;
use std::sync::Arc;

use tauri::{AppHandle, State};

use crate::config::{self, Settings};
use crate::process::{self, AppState, Status};

#[tauri::command]
pub fn get_settings(app: AppHandle) -> Settings {
    config::load_settings(&app)
}

#[tauri::command]
pub fn save_settings(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    settings: Settings,
) -> Result<(), String> {
    state
        .minimize_to_tray
        .store(settings.minimize_to_tray, Ordering::Relaxed);
    config::save_settings(&app, &settings)
}

#[tauri::command]
pub fn get_xray_config(app: AppHandle) -> String {
    config::load_xray_config(&app)
}

#[tauri::command]
pub fn save_xray_config(app: AppHandle, content: String) -> Result<(), String> {
    config::save_xray_config(&app, &content)
}

#[tauri::command]
pub fn default_xray_config() -> String {
    config::DEFAULT_XRAY.to_string()
}

#[tauri::command]
pub fn get_status(state: State<'_, Arc<AppState>>) -> Status {
    process::poll_status(&state)
}

#[tauri::command]
pub fn start_process(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    which: String,
) -> Result<(), String> {
    process::start(&app, state.inner(), &which)
}

#[tauri::command]
pub fn stop_process(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    which: String,
) -> Result<(), String> {
    process::stop(&app, state.inner(), &which)
}

#[tauri::command]
pub fn stop_all(app: AppHandle, state: State<'_, Arc<AppState>>) {
    process::stop_all(&app, state.inner());
}

#[tauri::command]
pub fn get_logs(state: State<'_, Arc<AppState>>, source: String) -> Vec<String> {
    process::get_logs(&state, &source)
}

#[tauri::command]
pub fn check_capabilities(app: AppHandle) -> bool {
    config::check_capabilities(&app)
}

#[tauri::command]
pub fn grant_capabilities(app: AppHandle) -> Result<bool, String> {
    config::grant_capabilities(&app)
}

#[tauri::command]
pub fn extract_bypass(app: AppHandle) -> Vec<String> {
    config::extract_bypass(&app)
}

#[tauri::command]
pub fn set_autostart(app: AppHandle, enabled: bool) -> Result<(), String> {
    config::set_autostart(&app, enabled)
}
