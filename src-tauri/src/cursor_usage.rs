//! Cursor usage fetcher (opt-in).
//!
//! Cursor — unlike every other client Tokcat reads — keeps no local token/cost
//! ledger on disk; its usage lives server-side. This module fetches per-event
//! usage from Cursor's dashboard API and writes a local JSON cache that
//! `usage_graph::parse_cursor` reads, so the rest of the graph pipeline stays
//! purely local and synchronous.
//!
//! Opt-in only: it makes a network request to cursor.com authenticated with the
//! user's own Cursor session token, which breaks Tokcat's otherwise local-first
//! guarantee. Gated behind a settings toggle (AppState::cursor_usage_enabled).

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::Value;

const USAGE_EVENTS_URL: &str = "https://cursor.com/api/dashboard/get-filtered-usage-events";
const PAGE_SIZE: i64 = 250;
const HISTORY_DAYS: i64 = 400;
const DAY_MS: i64 = 86_400_000;

/// One usage event flattened to the fields the contribution graph needs.
#[derive(Serialize, Deserialize)]
pub struct CachedCursorEvent {
    pub timestamp_ms: i64,
    pub model: String,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub cost: f64,
}

#[derive(Serialize, Deserialize)]
pub struct CursorCache {
    pub fetched_at_ms: i64,
    pub events: Vec<CachedCursorEvent>,
}

#[derive(Deserialize)]
struct FilteredUsageResponse {
    #[serde(rename = "totalUsageEventsCount")]
    total: Option<i64>,
    #[serde(rename = "usageEventsDisplay")]
    events: Option<Vec<RawEvent>>,
}

#[derive(Deserialize)]
struct RawEvent {
    timestamp: Option<String>,
    model: Option<String>,
    #[serde(rename = "tokenUsage")]
    token_usage: Option<RawTokenUsage>,
}

#[derive(Deserialize)]
struct RawTokenUsage {
    #[serde(rename = "inputTokens")]
    input_tokens: Option<i64>,
    #[serde(rename = "outputTokens")]
    output_tokens: Option<i64>,
    #[serde(rename = "cacheReadTokens")]
    cache_read_tokens: Option<i64>,
    #[serde(rename = "totalCents")]
    total_cents: Option<f64>,
}

fn home() -> Result<PathBuf, String> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .ok_or_else(|| "HOME is not set".to_string())
}

/// `~/.config/tokscale/cursor-cache/tokcat-events.json` — the same directory the
/// legacy CSV cache lived in, so `usage_graph::parse_cursor` finds it.
pub fn cache_path() -> Result<PathBuf, String> {
    Ok(home()?
        .join(".config")
        .join("tokscale")
        .join("cursor-cache")
        .join("tokcat-events.json"))
}

fn state_db_path() -> Result<PathBuf, String> {
    Ok(home()?.join("Library/Application Support/Cursor/User/globalStorage/state.vscdb"))
}

/// Read Cursor's live OAuth access token from its Electron key/value store.
/// Cursor refreshes this token in place; the macOS Keychain copy is only written
/// at login and goes stale, so the state DB is the reliable source.
fn read_access_token() -> Result<String, String> {
    let path = state_db_path()?;
    if !path.exists() {
        return Err("Cursor not found. Install Cursor and sign in to enable usage.".to_string());
    }
    let conn = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| format!("open Cursor state.vscdb: {}", e))?;
    let token: String = conn
        .query_row(
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'",
            [],
            |row| row.get(0),
        )
        .map_err(|_| "Cursor session token not found. Open Cursor and sign in.".to_string())?;
    let token = token.trim().trim_matches('"').trim().to_string();
    if token.is_empty() {
        return Err("Cursor session token is empty. Sign in to Cursor.".to_string());
    }
    Ok(token)
}

/// The token's `sub` claim doubles as the WorkOS user id in the session cookie.
fn jwt_subject(token: &str) -> Result<String, String> {
    let payload_b64 = token
        .split('.')
        .nth(1)
        .ok_or_else(|| "Cursor token is not a JWT".to_string())?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload_b64)
        .map_err(|e| format!("decode Cursor token payload: {}", e))?;
    let claims: Value =
        serde_json::from_slice(&bytes).map_err(|e| format!("parse Cursor token claims: {}", e))?;
    claims
        .get("sub")
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| "Cursor token has no subject claim".to_string())
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Fetch all recent usage events from Cursor and rewrite the local JSON cache.
/// Best-effort: returns a user-facing error string the toggle command can show.
pub async fn refresh_cache() -> Result<(), String> {
    let token = read_access_token()?;
    let sub = jwt_subject(&token)?;
    let cookie = format!("WorkosCursorSessionToken={}::{}", sub, token);

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("build Cursor client: {}", e))?;

    // Pad a day past "now" so today's events are always inside the window.
    let end_ms = now_ms() + DAY_MS;
    let start_ms = end_ms - HISTORY_DAYS * DAY_MS;

    let mut events: Vec<CachedCursorEvent> = Vec::new();
    let mut page = 1i64;
    loop {
        let body = serde_json::json!({
            "teamId": 0,
            "startDate": start_ms.to_string(),
            "endDate": end_ms.to_string(),
            "page": page,
            "pageSize": PAGE_SIZE,
        });
        let resp = client
            .post(USAGE_EVENTS_URL)
            .header("Cookie", &cookie)
            // Cursor's dashboard endpoints reject cross-origin POSTs without a
            // matching Origin/Referer (CSRF guard).
            .header("Origin", "https://cursor.com")
            .header("Referer", "https://cursor.com/dashboard")
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("Cursor usage request failed: {}", e))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("read Cursor usage response: {}", e))?;
        if status.as_u16() == 401 {
            return Err("Cursor session expired. Open Cursor and sign in again.".to_string());
        }
        if !status.is_success() {
            return Err(format!("Cursor usage API returned {}.", status.as_u16()));
        }
        let parsed: FilteredUsageResponse = serde_json::from_str(&text)
            .map_err(|e| format!("decode Cursor usage response: {}", e))?;
        let batch = parsed.events.unwrap_or_default();
        let total = parsed.total.unwrap_or(0);
        if batch.is_empty() {
            break;
        }
        for raw in batch {
            let Some(ts) = raw
                .timestamp
                .as_deref()
                .and_then(|s| s.trim().parse::<i64>().ok())
            else {
                continue;
            };
            let tu = raw.token_usage;
            events.push(CachedCursorEvent {
                timestamp_ms: ts,
                model: raw.model.unwrap_or_else(|| "cursor".to_string()),
                input_tokens: tu.as_ref().and_then(|t| t.input_tokens).unwrap_or(0).max(0),
                output_tokens: tu.as_ref().and_then(|t| t.output_tokens).unwrap_or(0).max(0),
                cache_read_tokens: tu
                    .as_ref()
                    .and_then(|t| t.cache_read_tokens)
                    .unwrap_or(0)
                    .max(0),
                cost: tu.as_ref().and_then(|t| t.total_cents).unwrap_or(0.0).max(0.0) / 100.0,
            });
        }
        if total > 0 && (events.len() as i64) >= total {
            break;
        }
        page += 1;
        if page > 1000 {
            break; // safety valve against an endless paginate loop
        }
    }

    write_cache(&CursorCache {
        fetched_at_ms: now_ms(),
        events,
    })
}

/// Remove the JSON cache this module owns. Best-effort and intentionally leaves
/// any legacy `usage*.csv` cache (which predates Tokcat and we didn't create)
/// untouched.
pub fn clear_cache() {
    if let Ok(path) = cache_path() {
        let _ = std::fs::remove_file(path);
    }
}

fn write_cache(cache: &CursorCache) -> Result<(), String> {
    let path = cache_path()?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("create cursor cache dir: {}", e))?;
    }
    let json = serde_json::to_string(cache).map_err(|e| format!("serialize cursor cache: {}", e))?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json).map_err(|e| format!("write cursor cache: {}", e))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("commit cursor cache: {}", e))?;
    Ok(())
}
