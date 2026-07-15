mod animation;
mod agent_usage;
mod cursor_usage;
#[cfg(target_os = "macos")]
mod native_tray;
mod state;
mod tray;
mod usage_graph;
mod usage_tail;

use serde::Serialize;
use state::{AppState, CacheEntry};
use std::sync::Arc;
use std::time::Duration;
use tauri::{async_runtime, Emitter, Manager};
use usage_tail::TraceBucket;

const REFRESH_SECS: u64 = 1800;
const ONESHOT_MAX_AGE_SECS: u64 = 30;
const TAIL_TICK_SECS: u64 = 5;
const RATE_EMIT_SECS: u64 = 180;

#[derive(Clone, Serialize)]
pub struct GraphPayload {
    pub year: String,
    #[serde(rename = "fetchedAt")]
    pub fetched_at: String,
    pub payload: serde_json::Value,
}

#[derive(Clone, Serialize)]
pub struct RateUpdate {
    #[serde(rename = "tokensPerMin")]
    pub tokens_per_min: f32,
    pub trace: Vec<TraceBucket>,
}

#[tauri::command]
async fn get_agent_usage() -> Result<agent_usage::AgentUsagePayload, String> {
    Ok(agent_usage::run().await)
}

#[tauri::command]
async fn get_graph(
    year: String,
    state: tauri::State<'_, Arc<AppState>>,
) -> Result<GraphPayload, String> {
    let max_age = Duration::from_secs(ONESHOT_MAX_AGE_SECS);
    if let Some(CacheEntry { data, fetched_at }) = state.get(&year, max_age) {
        return Ok(GraphPayload {
            year: year.clone(),
            fetched_at,
            payload: data,
        });
    }
    let year_clone = year.clone();
    let data = async_runtime::spawn_blocking(move || usage_graph::run(&year_clone))
        .await
        .map_err(|e| format!("join: {}", e))??;
    let entry = state.put(year.clone(), data);
    Ok(GraphPayload {
        year,
        fetched_at: entry.fetched_at,
        payload: entry.data,
    })
}

#[tauri::command]
async fn refresh_graph(
    year: String,
    state: tauri::State<'_, Arc<AppState>>,
    app: tauri::AppHandle,
) -> Result<GraphPayload, String> {
    // Flip the bounce flag for the whole refresh duration so the tray cat
    // hops up and down while we're fetching. Cleared in the guard below
    // even if the graph refresh errors out.
    state.set_refreshing(true);
    struct RefreshGuard<'a> {
        state: &'a Arc<AppState>,
    }
    impl<'a> Drop for RefreshGuard<'a> {
        fn drop(&mut self) {
            self.state.set_refreshing(false);
        }
    }
    let state_inner: &Arc<AppState> = &*state;
    let _guard = RefreshGuard { state: state_inner };

    // Opt-in: refresh the Cursor usage cache before reading the graph so the
    // rebuild below sees the latest events. Best-effort — a fetch failure
    // (Cursor signed out, offline) must not block the local graph refresh.
    if state.is_cursor_usage_enabled() {
        let _ = cursor_usage::refresh_cache().await;
    }

    let year_clone = year.clone();
    let data = async_runtime::spawn_blocking(move || usage_graph::run(&year_clone))
        .await
        .map_err(|e| format!("join: {}", e))??;
    let entry = state.put(year.clone(), data);
    let payload = GraphPayload {
        year: year.clone(),
        fetched_at: entry.fetched_at,
        payload: entry.data,
    };
    let _ = app.emit("graph-update", &payload);

    // Tail any JSONL growth since the last tick and re-emit the rate +
    // trace so the popover updates in lockstep with the user's refresh.
    let state_arc: Arc<AppState> = (*state).clone();
    let _ = async_runtime::spawn_blocking(move || state_arc.tailer().tick()).await;
    let rate_payload = RateUpdate {
        tokens_per_min: state.tokens_per_min_estimate(),
        trace: state.usage_trace(600),
    };
    let _ = app.emit("rate-update", &rate_payload);

    // Guarantee a visible bounce even on cache-warm fetches that return in
    // under a frame; ~450ms gives roughly one full bob at the bounce_loop
    // frequency. Bounded so a slow graph refresh doesn't extend it further.
    tokio::time::sleep(Duration::from_millis(450)).await;

    Ok(payload)
}

#[tauri::command]
fn quit_app(app: tauri::AppHandle) {
    app.exit(0);
}

/// Hide the popover from the frontend (⌘W / Esc) and return focus to the
/// previously-frontmost app. Routed through the same helper as the tray-click
/// and Ctrl+Cmd+T toggle so every explicit dismiss behaves identically.
#[tauri::command]
fn hide_popover(app: tauri::AppHandle) {
    tray::hide_popover(&app);
}

#[tauri::command]
fn push_dialog_shield(state: tauri::State<'_, Arc<AppState>>) {
    state.push_suppress_blur_hide();
}

#[tauri::command]
fn pop_dialog_shield(state: tauri::State<'_, Arc<AppState>>) {
    state.pop_suppress_blur_hide();
}

#[tauri::command]
fn set_animate_tray(enabled: bool, state: tauri::State<'_, Arc<AppState>>) {
    state.set_animate_enabled(enabled);
}

#[tauri::command]
fn set_animation_style(style: String, state: tauri::State<'_, Arc<AppState>>) {
    let code = match style.as_str() {
        "parrot" => 1u32,
        _ => 0u32,
    };
    state.set_animation_style(code);
}

/// Toggle the opt-in Cursor usage fetch. On enable we fetch once immediately so
/// the user sees data without waiting for the next refresh tick; the returned
/// error (if any) lets the frontend surface why it couldn't (Cursor signed out,
/// offline). The frontend triggers a graph refresh after this resolves.
#[tauri::command]
async fn set_cursor_usage_enabled(
    enabled: bool,
    state: tauri::State<'_, Arc<AppState>>,
) -> Result<(), String> {
    state.set_cursor_usage_enabled(enabled);
    if enabled {
        cursor_usage::refresh_cache().await?;
    } else {
        // Opting out hides Cursor: drop the cache so parse_cursor stops
        // surfacing stale data on the next graph rebuild.
        cursor_usage::clear_cache();
    }
    Ok(())
}

#[tauri::command]
fn get_usage_trace(window_secs: i64, state: tauri::State<'_, Arc<AppState>>) -> Vec<TraceBucket> {
    state.usage_trace(window_secs)
}

#[tauri::command]
fn get_tokens_per_min(state: tauri::State<'_, Arc<AppState>>) -> f32 {
    state.tokens_per_min_estimate()
}

/// Resize the popover window so the trace card fits without trailing
/// whitespace. Called from the frontend whenever the bucket count
/// changes. Width is kept constant; height is clamped to the popover's
/// supported range and the visible monitor area.
#[tauri::command]
fn set_popover_height(height: f64, window: tauri::Window) -> Result<(), String> {
    let requested = height.clamp(tray::POPOVER_MIN_H, tray::POPOVER_MAX_H);
    let h = clamp_popover_height_to_visible_area(&window, requested);
    let current = window
        .outer_size()
        .map_err(|e| format!("outer_size: {}", e))?;
    let scale = window.scale_factor().unwrap_or(1.0);
    let logical_w = (current.width as f64) / scale;
    let logical_h = (current.height as f64) / scale;
    // Idempotent: skip set_size for tiny diffs so a ResizeObserver storm
    // doesn't fight itself (each set_size triggers another observe → invoke).
    if (logical_h - h).abs() < 2.0 {
        return Ok(());
    }
    window
        .set_size(tauri::LogicalSize::new(logical_w, h))
        .map_err(|e| format!("set_size: {}", e))?;
    Ok(())
}

fn clamp_popover_height_to_visible_area(window: &tauri::Window, requested: f64) -> f64 {
    let mut h = requested.clamp(tray::POPOVER_MIN_H, tray::POPOVER_MAX_H);
    let Ok(position) = window.outer_position() else {
        return h;
    };
    let Ok(Some(monitor)) = window.current_monitor() else {
        return h;
    };
    let scale = monitor.scale_factor();
    if !scale.is_finite() || scale <= 0.0 {
        return h;
    }

    let monitor_pos = monitor.position();
    let monitor_size = monitor.size();
    let monitor_y = monitor_pos.y as f64 / scale;
    let monitor_h = monitor_size.height as f64 / scale;
    let y = position.y as f64 / scale;
    let available_h = monitor_y + monitor_h - y - tray::POPOVER_SCREEN_MARGIN;
    if available_h.is_finite() && available_h > 0.0 {
        h = h.min(available_h).max(tray::POPOVER_MIN_H.min(available_h));
    }
    h
}

fn spawn_refresh_loop(app: tauri::AppHandle, state: Arc<AppState>) {
    // The popover graph is produced in-process from local usage logs.
    // Animation uses usage_tail at TAIL_TICK_SECS, so this is a steady
    // 30-minute refresh for the chart payload. Manual tray refresh still
    // fetches on demand and bypasses the cache.
    async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(REFRESH_SECS)).await;
            // Opt-in: pull fresh Cursor usage once per cycle (covers every year)
            // before the per-year graph rebuilds below. Best-effort.
            if state.is_cursor_usage_enabled() {
                let _ = cursor_usage::refresh_cache().await;
            }
            let years = state.known_years();
            for year in years {
                let s = state.clone();
                let app = app.clone();
                let y = year.clone();
                let res = async_runtime::spawn_blocking(move || usage_graph::run(&y)).await;
                if let Ok(Ok(data)) = res {
                    let entry = s.put(year.clone(), data);
                    let payload = GraphPayload {
                        year: year.clone(),
                        fetched_at: entry.fetched_at,
                        payload: entry.data,
                    };
                    let _ = app.emit("graph-update", &payload);
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = tray::refresh_tray_title(&app, &payload, &window);
                    }
                }
            }
        }
    });
}

#[cfg(target_os = "macos")]
fn spawn_bounce_loop(app: tauri::AppHandle, state: Arc<AppState>) {
    async_runtime::spawn(async move {
        // ~30 fps tick. The bounce uses a half-sine wave so the icon goes
        // up, comes back down, then up again — period 420ms, amplitude 5px.
        const PERIOD_MS: f64 = 420.0;
        const AMPLITUDE_PX: f64 = 5.0;
        let start = std::time::Instant::now();
        let mut last_was_bouncing = false;
        loop {
            tokio::time::sleep(Duration::from_millis(33)).await;
            if state.is_refreshing() {
                let t = start.elapsed().as_millis() as f64;
                let phase = (t % PERIOD_MS) / PERIOD_MS * std::f64::consts::PI;
                // NSStatusBarButton's backing layer is flipped (origin at
                // top), so a positive dy moves the icon down. Negate so the
                // bounce visually goes up like a real hop.
                let dy = -phase.sin() * AMPLITUDE_PX;
                native_tray::set_y_offset(&app, dy);
                last_was_bouncing = true;
            } else if last_was_bouncing {
                native_tray::set_y_offset(&app, 0.0);
                last_was_bouncing = false;
            }
        }
    });
}

fn spawn_usage_tail_loop(app: tauri::AppHandle, state: Arc<AppState>) {
    // 5s tick keeps the animation signal responsive; the emit cadence is
    // separate so the tray title / trace UI shows the stable 10m average
    // updated every 3 minutes.
    async_runtime::spawn(async move {
        // Emit immediately once the listener wires up, then settle into the
        // 3-minute cadence. Without the immediate emit, the tray title
        // depends on the initial `get_tokens_per_min` invoke racing the
        // setup-time sync tick.
        let payload = RateUpdate {
            tokens_per_min: state.tokens_per_min_estimate(),
            trace: state.usage_trace(600),
        };
        let _ = app.emit("rate-update", &payload);
        let mut last_emit = std::time::Instant::now();
        loop {
            tokio::time::sleep(Duration::from_secs(TAIL_TICK_SECS)).await;
            let s = state.clone();
            let _ = async_runtime::spawn_blocking(move || s.tailer().tick()).await;
            if last_emit.elapsed() >= Duration::from_secs(RATE_EMIT_SECS) {
                last_emit = std::time::Instant::now();
                let payload = RateUpdate {
                    tokens_per_min: state.tokens_per_min_estimate(),
                    trace: state.usage_trace(600),
                };
                let _ = app.emit("rate-update", &payload);
            }
        }
    });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let state = AppState::new();
    let state_clone = state.clone();

    // Ctrl+Cmd+T toggles the popover from anywhere — registered in setup, fired
    // by the plugin handler below. Shortcut is Copy, so the same value is reused
    // for both the handler match and the setup-time registration.
    use tauri_plugin_global_shortcut::{Code, Modifiers, Shortcut, ShortcutState};
    let toggle_shortcut = Shortcut::new(Some(Modifiers::CONTROL | Modifiers::SUPER), Code::KeyT);

    let mut builder = tauri::Builder::default()
        // Must be registered first. If a second Tokcat process is launched
        // (e.g. running the binary directly, or `open -n`), this fires in the
        // already-running instance instead of starting a duplicate tray — we
        // surface the popover, mirroring the RunEvent::Reopen path below.
        //
        // The plugin runs this callback on its socket-listener task (a
        // tokio-rt-worker thread), so it must NOT touch AppKit directly:
        // show_popover orders/focuses the NSWindow, which is main-thread-only
        // and traps ("Must only be used from the main thread") otherwise.
        // Hop to the main thread first — unlike the RunEvent::Reopen path,
        // which already runs on the main event loop.
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            let handle = app.clone();
            let _ = app.run_on_main_thread(move || {
                tray::show_popover(&handle);
            });
        }))
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_process::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(move |app, shortcut, event| {
                    if shortcut == &toggle_shortcut && event.state() == ShortcutState::Pressed {
                        tray::toggle_popover(app);
                    }
                })
                .build(),
        )
        .manage(state.clone())
        .invoke_handler(tauri::generate_handler![
            get_graph,
            refresh_graph,
            quit_app,
            hide_popover,
            push_dialog_shield,
            pop_dialog_shield,
            set_animate_tray,
            set_animation_style,
            set_cursor_usage_enabled,
            get_usage_trace,
            get_tokens_per_min,
            get_agent_usage,
            set_popover_height,
            tray::update_tray_title
        ]);

    builder = builder.setup(move |app| {
        // Hide from Dock on macOS (LSUIElement equivalent).
        #[cfg(target_os = "macos")]
        {
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
        }
        let handle = app.handle().clone();
        tray::setup(&handle)?;
        {
            use tauri_plugin_global_shortcut::GlobalShortcutExt;
            if let Err(e) = app.global_shortcut().register(toggle_shortcut) {
                log::warn!("global shortcut register failed: {}", e);
            }
        }
        #[cfg(target_os = "macos")]
        if let Err(e) = native_tray::init() {
            log::warn!(
                "native_tray::init failed, falling back to Tauri set_icon: {}",
                e
            );
        }
        // Standard menubar popover behavior: hide when the window loses focus
        // (e.g. user clicks another menubar app or anywhere outside Tokcat).
        // Skipped while a system dialog is in flight so an ask/message popup
        // stealing focus doesn't dismiss the window underneath it.
        if let Some(window) = handle.get_webview_window("main") {
            let w = window.clone();
            let s = state_clone.clone();
            window.on_window_event(move |event| {
                if let tauri::WindowEvent::Focused(false) = event {
                    if s.should_suppress_blur_hide() {
                        return;
                    }
                    let _ = w.hide();
                }
            });
        }
        // Prime the tailer synchronously so the first invoke from the
        // frontend (and the initial tray title push) sees the real 10m
        // average instead of zero. Cost: one directory walk + parse of any
        // files modified in the last 6h; runs once at launch.
        state_clone.tailer().tick();
        spawn_refresh_loop(handle.clone(), state_clone.clone());
        spawn_usage_tail_loop(handle.clone(), state_clone.clone());
        animation::spawn_animation_loop(handle.clone(), state_clone.clone());
        #[cfg(target_os = "macos")]
        spawn_bounce_loop(handle.clone(), state_clone.clone());
        Ok(())
    });

    let app = builder
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    app.run(move |app_handle, event| {
        // macOS sends a "reopen" event when the user launches Tokcat again while
        // it's already running (double-click in Finder/Launchpad, Spotlight,
        // `open`, Dock). Because Tokcat is an Accessory app with a hidden window,
        // the default behavior is a no-op — nothing appears on screen. Surface
        // the popover so re-launching acts as an explicit "open". This is also
        // the only way back in when the menu bar icon is hidden behind the notch
        // or menu-bar overflow on small screens.
        #[cfg(target_os = "macos")]
        {
            if let tauri::RunEvent::Reopen { .. } = event {
                tray::show_popover(app_handle);
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (app_handle, event);
        }
    });
}
