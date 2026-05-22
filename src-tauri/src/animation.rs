use crate::state::AppState;
use std::sync::Arc;
use std::time::Duration;
use tauri::{async_runtime, AppHandle, Runtime};

include!(concat!(env!("OUT_DIR"), "/frames.rs"));

fn static_icon() -> tauri::image::Image<'static> {
    tauri::include_image!("icons/tray-icon.png")
}

fn frame(style: u32, idx: usize) -> tauri::image::Image<'static> {
    match style {
        1 => anim_cat(idx),
        2 => anim_cat2(idx),
        _ => anim(idx),
    }
}

fn frame_count(style: u32) -> usize {
    match style {
        1 => ANIM_CAT_LEN,
        2 => ANIM_CAT2_LEN,
        _ => ANIM_LEN,
    }
}

fn level_to_fps(level: u8) -> u64 {
    match level {
        0 => 0,
        1 => 2,
        2 => 3,
        3 => 5,
        _ => 8,
    }
}

fn swap_tray_icon<R: Runtime>(app: &AppHandle<R>, image: tauri::image::Image<'static>) {
    if let Some(tray) = app.tray_by_id("main-tray") {
        let _ = tray.set_icon_with_as_template(Some(image), true);
    }
}

pub fn spawn_animation_loop<R: Runtime>(app: AppHandle<R>, state: Arc<AppState>) {
    async_runtime::spawn(async move {
        let mut frame_idx: usize = 0;
        let mut last_kind: u8 = 255;
        let mut last_style: u32 = u32::MAX;
        loop {
            if !state.is_animate_enabled() {
                if last_kind != 0 {
                    swap_tray_icon(&app, static_icon());
                    last_kind = 0;
                }
                tokio::time::sleep(Duration::from_millis(2000)).await;
                continue;
            }
            let style = state.animation_style();
            if style != last_style {
                frame_idx = 0;
                last_style = style;
                last_kind = 255;
            }
            let level = state.current_level();
            let fps = level_to_fps(level);
            if fps == 0 {
                if last_kind != 1 {
                    swap_tray_icon(&app, frame(style, 0));
                    frame_idx = 0;
                    last_kind = 1;
                }
                tokio::time::sleep(Duration::from_millis(2000)).await;
                continue;
            }
            last_kind = 2;
            swap_tray_icon(&app, frame(style, frame_idx));
            frame_idx = (frame_idx + 1) % frame_count(style);
            tokio::time::sleep(Duration::from_millis(1000 / fps)).await;
        }
    });
}
