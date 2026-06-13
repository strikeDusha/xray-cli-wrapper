// Prevents an extra console window on Windows in release. No-op on Linux.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

const HELP: &str = "\
v3xtun — GUI для tun2proxy + xray

ИСПОЛЬЗОВАНИЕ:
    v3xtun [ОПЦИИ]

ОПЦИИ:
    (без аргументов)   запустить графический интерфейс
    -h, --help         показать эту справку
    -V, --version      показать версию

После установки команда `v3xtun` доступна в PATH и открывает приложение.
Настройки и конфиг xray хранятся в ~/.config/dev.v3xtun.app/.";

fn main() {
    // WebKitGTK на Wayland (особенно KDE Plasma) падает с
    // "Gdk-Message: Error 71 (Protocol error) dispatching to wayland display"
    // из-за DMABUF-рендерера. Отключаем его до инициализации GTK.
    // Не перезаписываем, если переменная уже задана пользователем.
    #[cfg(target_os = "linux")]
    {
        if std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_none() {
            std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
        }
    }

    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "-h" || a == "--help") {
        println!("{HELP}");
        return;
    }
    if args.iter().any(|a| a == "-V" || a == "--version") {
        println!("v3xtun {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    v3xtun_lib::run()
}
