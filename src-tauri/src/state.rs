use parking_lot::Mutex;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::usage_tail::{TraceBucket, UsageTailer};

#[derive(Clone, Serialize)]
pub struct CacheEntry {
    pub data: serde_json::Value,
    pub fetched_at: String,
}

pub struct AppState {
    inner: Mutex<HashMap<String, (serde_json::Value, Instant, String)>>,
    animate_enabled: AtomicBool,
    // 0 = cube, 1 = cat, 2 = cat2
    animation_style: AtomicU32,
    // Bumped from JS while a system dialog (ask/message) is in flight so the
    // blur-to-hide window handler doesn't dismiss the menubar window when the
    // dialog steals focus.
    suppress_blur_hide: AtomicU32,
    // Set while a refresh fetch is in flight. The bounce loop reads this to
    // start the up/down animation on the tray cat.
    refreshing: AtomicBool,
    tailer: Arc<UsageTailer>,
}

impl AppState {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(HashMap::new()),
            animate_enabled: AtomicBool::new(true),
            animation_style: AtomicU32::new(2),
            suppress_blur_hide: AtomicU32::new(0),
            refreshing: AtomicBool::new(false),
            tailer: Arc::new(UsageTailer::new()),
        })
    }

    pub fn tailer(&self) -> &UsageTailer {
        &self.tailer
    }

    pub fn usage_trace(&self, window_secs: i64) -> Vec<TraceBucket> {
        self.tailer.trace(window_secs)
    }

    /// Tokens/min for the tray title and trace total. 10-minute moving
    /// average — stable enough that 3-minute refresh feels natural while
    /// still tracking trends. The animation signal (current_load) uses a
    /// shorter 60s window for cat responsiveness.
    pub fn tokens_per_min_estimate(&self) -> f32 {
        self.tailer.rate_in_window(600)
    }

    pub fn push_suppress_blur_hide(&self) {
        self.suppress_blur_hide.fetch_add(1, Ordering::SeqCst);
    }

    pub fn pop_suppress_blur_hide(&self) {
        let prev = self.suppress_blur_hide.load(Ordering::SeqCst);
        if prev > 0 {
            self.suppress_blur_hide.fetch_sub(1, Ordering::SeqCst);
        }
    }

    pub fn should_suppress_blur_hide(&self) -> bool {
        self.suppress_blur_hide.load(Ordering::SeqCst) > 0
    }

    pub fn set_refreshing(&self, v: bool) {
        self.refreshing.store(v, Ordering::SeqCst);
    }

    pub fn is_refreshing(&self) -> bool {
        self.refreshing.load(Ordering::SeqCst)
    }

    pub fn set_animation_style(&self, style: u32) {
        self.animation_style.store(style, Ordering::SeqCst);
    }

    pub fn animation_style(&self) -> u32 {
        self.animation_style.load(Ordering::SeqCst)
    }

    pub fn get(&self, year: &str, max_age: Duration) -> Option<CacheEntry> {
        let guard = self.inner.lock();
        guard.get(year).and_then(|(d, t, ts)| {
            if t.elapsed() <= max_age {
                Some(CacheEntry {
                    data: d.clone(),
                    fetched_at: ts.clone(),
                })
            } else {
                None
            }
        })
    }

    pub fn put(&self, year: String, data: serde_json::Value) -> CacheEntry {
        let now_iso = chrono::Utc::now().to_rfc3339();
        let mut guard = self.inner.lock();
        guard.insert(year.clone(), (data.clone(), Instant::now(), now_iso.clone()));
        CacheEntry {
            data,
            fetched_at: now_iso,
        }
    }

    /// Continuous activity signal in [0.0, 100.0], shaped to mirror RunCat's
    /// CPU-load input. Animation.rs feeds this through the RunCat formula
    /// `speed = max(1, load/5)` → `interval_ms = 500/speed`, yielding a
    /// 2 fps (idle) ↔ 40 fps (heavy) range.
    ///
    /// Source: live JSONL tailer rate. 1,000,000 tokens/min → load 100,
    /// matching the user-confirmed RunCat-equivalent max. Idle is implicit —
    /// no events in the last 60s yields rate 0.
    pub fn current_load(&self) -> f32 {
        let rate_per_min = self.tailer.rate_per_min();
        (rate_per_min / 10_000.0).min(100.0)
    }

    pub fn set_animate_enabled(&self, enabled: bool) {
        self.animate_enabled.store(enabled, Ordering::SeqCst);
    }

    pub fn is_animate_enabled(&self) -> bool {
        self.animate_enabled.load(Ordering::SeqCst)
    }

    pub fn known_years(&self) -> Vec<String> {
        self.inner.lock().keys().cloned().collect()
    }
}
