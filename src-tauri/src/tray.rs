//! System tray icon with a quick-action menu.

use std::sync::Arc;
use std::thread;
use std::time::Duration;

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager};

use crate::process::{self, AppState};

pub fn build(app: &AppHandle) -> tauri::Result<()> {
    let show = MenuItem::with_id(app, "show", "Показать окно", true, None::<&str>)?;
    let connect = MenuItem::with_id(app, "connect", "Подключить всё", true, None::<&str>)?;
    let disconnect = MenuItem::with_id(app, "disconnect", "Отключить всё", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Выход", true, None::<&str>)?;
    let sep = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(app, &[&show, &connect, &disconnect, &sep, &quit])?;

    let icon = app
        .default_window_icon()
        .cloned()
        .expect("default window icon");

    TrayIconBuilder::with_id("main")
        .icon(icon)
        .tooltip("v3xtun — tun2proxy + xray")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| handle_menu(app, event.id().as_ref()))
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                show_window(tray.app_handle());
            }
        })
        .build(app)?;

    Ok(())
}

fn show_window(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn handle_menu(app: &AppHandle, id: &str) {
    let state = app.state::<Arc<AppState>>().inner().clone();
    match id {
        "show" => show_window(app),
        "connect" => {
            let handle = app.clone();
            thread::spawn(move || {
                let _ = process::start(&handle, &state, "xray");
                thread::sleep(Duration::from_millis(800));
                let _ = process::start(&handle, &state, "tun2proxy");
            });
        }
        "disconnect" => process::stop_all(app, &state),
        "quit" => {
            process::stop_all(app, &state);
            app.exit(0);
        }
        _ => {}
    }
}
