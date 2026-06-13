mod commands;
mod config;
mod process;
mod tray;

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use tauri::{Manager, WindowEvent};

use process::AppState;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(Arc::new(AppState::default()))
        .setup(|app| {
            let handle = app.handle().clone();
            let state = app.state::<Arc<AppState>>().inner().clone();

            let settings = config::load_settings(&handle);
            state
                .minimize_to_tray
                .store(settings.minimize_to_tray, Ordering::Relaxed);

            tray::build(&handle)?;
            process::spawn_monitor(handle.clone(), state.clone());

            if settings.autoconnect {
                let h = handle.clone();
                let s = state.clone();
                thread::spawn(move || {
                    let _ = process::start(&h, &s, "xray");
                    thread::sleep(Duration::from_millis(800));
                    let _ = process::start(&h, &s, "tun2proxy");
                });
            }

            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                let app = window.app_handle();
                let state = app.state::<Arc<AppState>>();
                if state.minimize_to_tray.load(Ordering::Relaxed) {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_settings,
            commands::save_settings,
            commands::get_xray_config,
            commands::save_xray_config,
            commands::default_xray_config,
            commands::get_status,
            commands::start_process,
            commands::stop_process,
            commands::stop_all,
            commands::get_logs,
            commands::check_capabilities,
            commands::grant_capabilities,
            commands::extract_bypass,
            commands::set_autostart,
        ])
        .build(tauri::generate_context!())
        .expect("ошибка инициализации v3xtun")
        .run(|app, event| {
            if let tauri::RunEvent::ExitRequested { .. } = event {
                // Tear down the tunnel so routing/DNS are restored on exit.
                let state = app.state::<Arc<AppState>>();
                process::stop_all(app, state.inner());
            }
        });
}
