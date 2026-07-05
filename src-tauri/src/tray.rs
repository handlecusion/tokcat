use crate::GraphPayload;
use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, LogicalPosition, Manager, PhysicalPosition, PhysicalSize, Runtime,
    WebviewWindow,
};

pub const POPOVER_W: f64 = 640.0;
pub const POPOVER_DEFAULT_H: f64 = 620.0;
pub const POPOVER_MIN_H: f64 = 420.0;
pub const POPOVER_MAX_H: f64 = 1200.0;
pub const POPOVER_SCREEN_MARGIN: f64 = 8.0;
const POPOVER_TRAY_GAP: f64 = 6.0;

pub fn setup<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<()> {
    let show = MenuItem::with_id(app, "show", "Open Tokcat", true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "Settings…", true, Some("Cmd+,"))?;
    let refresh = MenuItem::with_id(app, "refresh", "Refresh Now", true, Some("Cmd+R"))?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let about = MenuItem::with_id(app, "about", "About Tokcat", true, None::<&str>)?;
    let check_update = MenuItem::with_id(
        app,
        "check-update",
        "Check for Updates…",
        true,
        None::<&str>,
    )?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Tokcat", true, Some("Cmd+Q"))?;
    let menu = Menu::with_items(
        app,
        &[
            &show,
            &settings,
            &refresh,
            &sep1,
            &about,
            &check_update,
            &sep2,
            &quit,
        ],
    )?;

    TrayIconBuilder::with_id("main-tray")
        .icon(tauri::include_image!("icons/tray-icon.png"))
        .icon_as_template(true)
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "quit" => {
                app.exit(0);
            }
            "show" => {
                show_popover(app);
            }
            "settings" => {
                show_popover(app);
                let _ = app.emit("tray-action", "open-settings");
            }
            "refresh" => {
                let _ = app.emit("tray-action", "refresh");
            }
            "about" => {
                show_popover(app);
                let _ = app.emit("tray-action", "open-about");
            }
            "check-update" => {
                let _ = app.emit("tray-action", "check-update");
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let app = tray.app_handle();
                if let Some(w) = app.get_webview_window("main") {
                    let visible = w.is_visible().unwrap_or(false);
                    if visible {
                        hide_popover(app);
                    } else {
                        prepare_popover_window(&w);
                        let _ = position_window_under_tray(tray, &w);
                        let _ = w.show();
                        bring_popover_to_front(&w);
                        let _ = w.set_focus();
                        bring_popover_to_front(&w);
                        let _ = app.emit("popover-shown", ());
                    }
                }
            }
        })
        .build(app)?;
    if let Some(w) = app.get_webview_window("main") {
        prepare_popover_window(&w);
    }
    Ok(())
}

/// Hide the popover and hand keyboard focus back to the app that was in front
/// before it opened. Plain `w.hide()` (orderOut) leaves Tokcat the active
/// accessory app with no window, so focus lands nowhere; `app.hide()` (NSApp
/// hide) deactivates Tokcat and reactivates the previously-frontmost app. The
/// `w.hide()` runs first so the toggle's `is_visible()` check is reliable
/// regardless of how NSApp hide reports window visibility. Used by every
/// explicit dismiss (Ctrl+Cmd+T, tray-click toggle, ⌘W, Esc) but not the
/// blur-hide, where focus has already moved to whatever stole it.
pub fn hide_popover<R: Runtime>(app: &AppHandle<R>) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.hide();
    }
    #[cfg(target_os = "macos")]
    let _ = app.hide();
}

/// Show the popover under the tray if hidden, hide it if visible. Mirrors the
/// left-click tray toggle so the global shortcut (Ctrl+Cmd+T) behaves the same.
pub fn toggle_popover<R: Runtime>(app: &AppHandle<R>) {
    if let Some(w) = app.get_webview_window("main") {
        if w.is_visible().unwrap_or(false) {
            hide_popover(app);
        } else {
            prepare_popover_window(&w);
            if let Some(tray) = app.tray_by_id("main-tray") {
                let _ = position_window_under_tray(&tray, &w);
            }
            let _ = w.show();
            bring_popover_to_front(&w);
            let _ = w.set_focus();
            bring_popover_to_front(&w);
            let _ = app.emit("popover-shown", ());
        }
    }
}

pub fn show_popover<R: Runtime>(app: &AppHandle<R>) {
    if let Some(w) = app.get_webview_window("main") {
        prepare_popover_window(&w);
        if let Some(tray) = app.tray_by_id("main-tray") {
            let _ = position_window_under_tray(&tray, &w);
        }
        let _ = w.show();
        bring_popover_to_front(&w);
        let _ = w.set_focus();
        bring_popover_to_front(&w);
        let _ = app.emit("popover-shown", ());
    }
}

#[cfg(target_os = "macos")]
fn prepare_popover_window<R: Runtime>(window: &WebviewWindow<R>) {
    use objc2_app_kit::{NSPopUpMenuWindowLevel, NSWindow, NSWindowCollectionBehavior};

    let _ = window.set_visible_on_all_workspaces(true);

    let Ok(ns_window) = window.ns_window() else {
        return;
    };

    let ns_window = unsafe { &*(ns_window.cast::<NSWindow>()) };
    let behavior = ns_window.collectionBehavior()
        | NSWindowCollectionBehavior::CanJoinAllSpaces
        | NSWindowCollectionBehavior::CanJoinAllApplications
        | NSWindowCollectionBehavior::FullScreenAuxiliary
        | NSWindowCollectionBehavior::IgnoresCycle
        | NSWindowCollectionBehavior::Transient;
    ns_window.setCollectionBehavior(behavior);
    ns_window.setLevel(NSPopUpMenuWindowLevel);
}

#[cfg(not(target_os = "macos"))]
fn prepare_popover_window<R: Runtime>(window: &WebviewWindow<R>) {
    let _ = window.set_visible_on_all_workspaces(true);
}

#[cfg(target_os = "macos")]
fn bring_popover_to_front<R: Runtime>(window: &WebviewWindow<R>) {
    use objc2_app_kit::NSWindow;

    let Ok(ns_window) = window.ns_window() else {
        return;
    };

    let ns_window = unsafe { &*(ns_window.cast::<NSWindow>()) };
    ns_window.orderFrontRegardless();
}

#[cfg(not(target_os = "macos"))]
fn bring_popover_to_front<R: Runtime>(_window: &WebviewWindow<R>) {}

fn position_window_under_tray<R: Runtime>(
    tray: &tauri::tray::TrayIcon<R>,
    window: &WebviewWindow<R>,
) -> tauri::Result<()> {
    let rect = match tray.rect()? {
        Some(r) => r,
        None => return Ok(()),
    };

    let scale = window.scale_factor().unwrap_or(1.0);
    let pos: PhysicalPosition<f64> = rect.position.to_physical(scale);
    let size: PhysicalSize<f64> = rect.size.to_physical(scale);
    let tray_x_logical = pos.x / scale;
    let tray_y_logical = pos.y / scale;
    let tray_w_logical = size.width / scale;
    let tray_h_logical = size.height / scale;

    // Center popover horizontally under the tray icon
    let mut x = tray_x_logical + (tray_w_logical - POPOVER_W) / 2.0;
    let y = tray_y_logical + tray_h_logical + POPOVER_TRAY_GAP;
    let mut h = window
        .outer_size()
        .ok()
        .map(|size| size.height as f64 / scale)
        .unwrap_or(POPOVER_DEFAULT_H)
        .clamp(POPOVER_MIN_H, POPOVER_MAX_H);

    // Clamp to the monitor that owns the tray icon, not the monitor remembered
    // by the hidden popover window from its last Space.
    if let Ok(Some(monitor)) = window.monitor_from_point(tray_x_logical, tray_y_logical) {
        let m_pos = monitor.position();
        let m_size = monitor.size();
        let m_scale = monitor.scale_factor();
        let m_x = m_pos.x as f64 / m_scale;
        let m_y = m_pos.y as f64 / m_scale;
        let m_w = m_size.width as f64 / m_scale;
        let m_h = m_size.height as f64 / m_scale;
        let max_x = m_x + m_w - POPOVER_W - 8.0;
        let min_x = m_x + 8.0;
        if x > max_x {
            x = max_x;
        }
        if x < min_x {
            x = min_x;
        }
        let available_h = m_y + m_h - y - POPOVER_SCREEN_MARGIN;
        if available_h.is_finite() && available_h > 0.0 {
            h = h.min(available_h).max(POPOVER_MIN_H.min(available_h));
        }
    }

    let _ = window.set_size(tauri::LogicalSize::new(POPOVER_W, h));
    window.set_position(LogicalPosition::new(x, y))?;
    Ok(())
}

pub fn refresh_tray_title<R: Runtime>(
    app: &AppHandle<R>,
    _payload: &GraphPayload,
    _window: &WebviewWindow<R>,
) -> tauri::Result<()> {
    // Title is computed and pushed from frontend via update_tray_title.
    // This is a placeholder hook for future server-side formatting.
    let _ = app;
    Ok(())
}

#[tauri::command]
pub fn update_tray_title(app: AppHandle, title: String) -> Result<(), String> {
    if let Some(tray) = app.tray_by_id("main-tray") {
        // Always pass Some(String) — set_title(None) on macOS NSStatusItem
        // can leave a residual title gap; an empty string fully collapses
        // the status item to icon-only width.
        let value: Option<String> = if title.is_empty() {
            Some(String::new())
        } else {
            Some(format!(" {}", title))
        };
        tray.set_title(value).map_err(|e| e.to_string())?;
    }
    Ok(())
}
