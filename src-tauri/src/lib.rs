pub mod automations;
pub mod commands;
pub mod db;
pub mod error;
pub mod executor;
pub mod git;
pub mod models;
pub mod paths;
pub mod sessions;
pub mod state;
pub mod store;

use std::sync::Arc;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "backtick=info".into()),
        )
        .init();

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            let db = db::Db::open()?;
            let state = Arc::new(state::AppState::new(db));
            state.sessions.reconcile_on_start()?;
            app.manage(state.clone());

            automations::start_scheduler(app.handle().clone(), state.clone());
            build_tray(app.handle())?;
            Ok(())
        })
        .on_window_event(|window, event| {
            // Closing the window hides it: the scheduler has to keep running
            // for automations to fire. Quit from the tray menu really exits.
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::settings_get_all,
            commands::settings_set,
            commands::project_probe,
            commands::project_add,
            commands::projects_list,
            commands::project_update,
            commands::project_delete,
            commands::providers_detect,
            commands::session_create,
            commands::sessions_list,
            commands::session_get,
            commands::session_launch,
            commands::session_write,
            commands::session_stop,
            commands::session_set_status,
            commands::session_set_provider_session_id,
            commands::session_rename,
            commands::session_archive,
            commands::session_replay,
            commands::session_subscribe,
            commands::session_delete,
            commands::usage_record,
            commands::usage_summary,
            commands::usage_by_day,
            commands::worktrees_list,
            commands::worktree_remove,
            commands::worktree_prune,
            commands::diff_collect,
            commands::diff_file_contents,
            commands::diff_accept,
            commands::diff_reject,
            commands::automation_save,
            commands::automations_list,
            commands::automation_get,
            commands::automation_set_enabled,
            commands::automation_delete,
            commands::automation_runs,
            commands::automation_run_now,
            commands::automation_run_report,
            commands::schedule_preview,
            commands::schedule_preset,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Backtick");
}

fn build_tray(app: &tauri::AppHandle) -> tauri::Result<()> {
    let show = MenuItem::with_id(app, "show", "Open Backtick", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Backtick", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show, &quit])?;

    TrayIconBuilder::with_id("main")
        .icon(app.default_window_icon().cloned().unwrap())
        .tooltip("Backtick")
        .menu(&menu)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show" => {
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.show();
                    let _ = w.set_focus();
                }
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;
    Ok(())
}
