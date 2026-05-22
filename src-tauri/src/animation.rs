use crate::state::AppState;
use std::sync::Arc;
use std::time::Duration;
use tauri::{async_runtime, AppHandle, Runtime};

// The generated module exposes anim_cat2/anim_parrot and their _LEN/_rgba
// variants (light siblings are emitted for the eventual dark/light split
// but unused today). We consume only LEN here; the rgba bytes are read by
// native_tray.rs, and the Image helpers exist solely for the non-macOS
// fallback path below.
mod frames {
    #![allow(dead_code)]
    include!(concat!(env!("OUT_DIR"), "/frames.rs"));
}
use frames::{ANIM_CAT2_LEN, ANIM_PARROT_LEN};

#[cfg(not(target_os = "macos"))]
fn frame(style: u32, idx: usize) -> tauri::image::Image<'static> {
    match style {
        1 => frames::anim_parrot(idx),
        _ => frames::anim_cat2(idx),
    }
}

fn frame_count(style: u32) -> usize {
    match style {
        1 => ANIM_PARROT_LEN,
        _ => ANIM_CAT2_LEN,
    }
}

/// RunCat-style adaptive frame interval. `load` is in [0.0, 100.0] (see
/// `AppState::current_load`); formula `speed = max(1, load/5)` →
/// `interval_ms = 500/speed` maps idle to 500ms (2 fps) and full load to
/// 25ms (40 fps). CALayer-backed tray icon makes 40 fps essentially free.
fn load_to_interval_ms(load: f32) -> u64 {
    let speed = (load / 5.0).max(1.0);
    (500.0 / speed) as u64
}

fn swap_tray_icon<R: Runtime>(app: &AppHandle<R>, style: u32, idx: usize) {
    #[cfg(target_os = "macos")]
    crate::native_tray::set_frame(app, style, idx);
    #[cfg(not(target_os = "macos"))]
    {
        let image = frame(style, idx);
        if let Some(tray) = app.tray_by_id("main-tray") {
            let _ = tray.set_icon_with_as_template(Some(image), true);
        }
    }
}

pub fn spawn_animation_loop<R: Runtime>(app: AppHandle<R>, state: Arc<AppState>) {
    async_runtime::spawn(async move {
        let mut frame_idx: usize = 0;
        let mut last_style: u32 = u32::MAX;
        loop {
            let style = state.animation_style();
            if style != last_style {
                frame_idx = 0;
                last_style = style;
            }
            if !state.is_animate_enabled() {
                swap_tray_icon(&app, style, 0);
                tokio::time::sleep(Duration::from_millis(2000)).await;
                continue;
            }
            // Freeze the spin while a refresh is in flight; the bounce loop
            // takes over and bobs the icon up and down.
            if state.is_refreshing() {
                swap_tray_icon(&app, style, 0);
                tokio::time::sleep(Duration::from_millis(80)).await;
                continue;
            }
            let interval = load_to_interval_ms(state.current_load());
            swap_tray_icon(&app, style, frame_idx);
            frame_idx = (frame_idx + 1) % frame_count(style);
            tokio::time::sleep(Duration::from_millis(interval)).await;
        }
    });
}
