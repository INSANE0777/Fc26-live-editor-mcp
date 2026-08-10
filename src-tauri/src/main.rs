// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::process::{Child, Command};
use std::sync::Mutex;

use tauri::Manager;

struct Sidecar(Mutex<Option<Child>>);

fn main() {
    tauri::Builder::default()
        .manage(Sidecar(Mutex::new(None)))
        .setup(|app| {
            // Spawn the Python sidecar (fc26-mcp.sidecar_server) before showing UI.
            let sidecar = app.state::<Sidecar>();
            let child = spawn_sidecar();
            *sidecar.0.lock().unwrap() = child;
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app_handle, event| {
            if let tauri::RunEvent::Exit = event {
                // Kill the sidecar when the app closes.
                if let Some(state) = app_handle.try_state::<Sidecar>() {
                    if let Some(mut child) = state.0.lock().unwrap().take() {
                        let _ = child.kill();
                        let _ = child.wait();
                    }
                }
            }
        });
}

fn spawn_sidecar() -> Option<Child> {
    // Find the Python we were launched with, else fall back to `python`.
    let python = std::env::var("PYTHON")
        .or_else(|_| std::env::var("FC26_PYTHON"))
        .unwrap_or_else(|_| "python".to_string());
    let code = "from fc26_mcp.sidecar_server import main; main()";
    match Command::new(&python)
        .arg("-c")
        .arg(&code)
        .env("FC26_SIDECAR_WATCH", "1")
        .stdin(std::process::Stdio::piped())
        .spawn()
    {
        Ok(child) => Some(child),
        Err(e) => {
            eprintln!("Failed to start sidecar ({python}): {e}");
            None
        }
    }
}