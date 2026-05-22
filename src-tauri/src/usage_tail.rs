// Incremental tailer for per-CLI usage JSONL.
//
// Replaces the 3-minute `tokscale graph` subprocess polling cycle as the
// source of truth for the animation/rate signal. Patterned on tokscale's
// own SourceMessageCache strategy: track (file, offset, mtime), re-read
// only growth, dedup streaming retries by msgId:reqId with per-field max.
//
// Phase 1: Claude Code (~/.claude/projects/**/*.jsonl)
// Phase 2a: Codex CLI (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)
// Phase 2b (TODO): Hermes/OpenCode (SQLite — needs rusqlite).

use chrono::DateTime;
use parking_lot::Mutex;
use rusqlite::{Connection, OpenFlags};
use serde::Serialize;
use std::collections::{HashMap, VecDeque};
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const CLIENT_CLAUDE: &str = "claude-code";
const CLIENT_CODEX: &str = "codex-cli";
const CLIENT_HERMES: &str = "hermes";
const EVENT_WINDOW_SECS: i64 = 3600;
const COLD_SCAN_LOOKBACK_SECS: i64 = 6 * 3600;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ClientKind {
    Claude,
    Codex,
}

#[derive(Debug, Clone, Serialize)]
pub struct UsageEvent {
    pub ts_ms: i64,
    pub client: String,
    pub agent: String,
    pub model: String,
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
}

impl UsageEvent {
    fn total(&self) -> i64 {
        self.input + self.output + self.cache_read + self.cache_write
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct TraceBucket {
    pub client: String,
    pub agent: String,
    pub model: String,
    pub tokens: i64,
    pub messages: u32,
    pub tokens_per_min: f32,
}

#[derive(Debug)]
struct FileState {
    offset: u64,
    mtime_ms: i64,
    // Codex's token_count events carry no model field; the most recent
    // `turn_context` line in the same file does. We thread the parsed
    // model through file state so a tick that lands mid-file still
    // attributes events correctly.
    codex_model: Option<String>,
}

impl FileState {
    fn at_eof(size: u64, mtime_ms: i64) -> Self {
        Self {
            offset: size,
            mtime_ms,
            codex_model: None,
        }
    }
}

/// Per-session token counts last observed for a Hermes session row.
/// We diff these to derive deltas — Hermes stores aggregates that grow
/// in place, not a per-message append log, so there's no natural offset.
#[derive(Debug, Default, Clone, Copy)]
struct HermesSnapshot {
    input: i64,
    output: i64,
    cache_read: i64,
    cache_write: i64,
}

pub struct UsageTailer {
    files: Mutex<HashMap<PathBuf, FileState>>,
    events: Mutex<VecDeque<UsageEvent>>,
    seen: Mutex<HashMap<String, usize>>,
    cold: Mutex<bool>,
    hermes_snapshots: Mutex<HashMap<String, HermesSnapshot>>,
}

impl UsageTailer {
    pub fn new() -> Self {
        Self {
            files: Mutex::new(HashMap::new()),
            events: Mutex::new(VecDeque::new()),
            seen: Mutex::new(HashMap::new()),
            cold: Mutex::new(true),
            hermes_snapshots: Mutex::new(HashMap::new()),
        }
    }

    pub fn tick(&self) -> usize {
        let mut added = 0;
        let is_cold = {
            let mut c = self.cold.lock();
            let was = *c;
            *c = false;
            was
        };
        let cold_cutoff_ms = now_ms() - COLD_SCAN_LOOKBACK_SECS * 1000;

        added += self.tick_hermes(is_cold);

        for (root, client) in roots() {
            let mut stack: Vec<PathBuf> = vec![root];
            while let Some(dir) = stack.pop() {
                let entries = match fs::read_dir(&dir) {
                    Ok(e) => e,
                    Err(_) => continue,
                };
                for entry in entries.flatten() {
                    let path = entry.path();
                    let ft = match entry.file_type() {
                        Ok(t) => t,
                        Err(_) => continue,
                    };
                    if ft.is_dir() {
                        stack.push(path);
                        continue;
                    }
                    if path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
                        continue;
                    }
                    let meta = match entry.metadata() {
                        Ok(m) => m,
                        Err(_) => continue,
                    };
                    let size = meta.len();
                    let mtime_ms = system_time_to_ms(meta.modified().ok());
                    let prev = self
                        .files
                        .lock()
                        .get(&path)
                        .map(|f| (f.offset, f.mtime_ms));

                    if is_cold && prev.is_none() && mtime_ms < cold_cutoff_ms {
                        self.files
                            .lock()
                            .insert(path.clone(), FileState::at_eof(size, mtime_ms));
                        continue;
                    }

                    let (start_offset, _) = prev.unwrap_or((0, 0));
                    if size == start_offset {
                        self.files
                            .lock()
                            .insert(path.clone(), FileState::at_eof(size, mtime_ms));
                        continue;
                    }
                    if size < start_offset {
                        added += self.read_growth(&path, client, 0, size, mtime_ms);
                    } else {
                        added += self.read_growth(&path, client, start_offset, size, mtime_ms);
                    }
                }
            }
        }

        self.trim_events();
        added
    }

    fn read_growth(
        &self,
        path: &Path,
        client: ClientKind,
        start: u64,
        end: u64,
        mtime_ms: i64,
    ) -> usize {
        let mut added = 0;
        let mut file = match fs::File::open(path) {
            Ok(f) => f,
            Err(_) => return 0,
        };
        if file.seek(SeekFrom::Start(start)).is_err() {
            return 0;
        }
        let to_read = end.saturating_sub(start) as usize;
        let mut buf = Vec::with_capacity(to_read.min(8 * 1024 * 1024));
        if file.take(to_read as u64).read_to_end(&mut buf).is_err() {
            return 0;
        }

        // Lift the per-file codex_model out so we can mutate without
        // re-locking on every line; write it back when we're done.
        let mut codex_model: Option<String> = self
            .files
            .lock()
            .get(path)
            .and_then(|f| f.codex_model.clone());

        let mut consumed: u64 = 0;
        for line in buf.split(|&b| b == b'\n') {
            consumed += line.len() as u64;
            let has_terminator = consumed < buf.len() as u64;
            if !has_terminator {
                break;
            }
            consumed += 1;
            let trimmed = trim_ascii(line);
            if trimmed.is_empty() {
                continue;
            }
            let recorded = match client {
                ClientKind::Claude => self.parse_claude_line(path, trimmed),
                ClientKind::Codex => self.parse_codex_line(trimmed, &mut codex_model),
            };
            if recorded {
                added += 1;
            }
        }

        let new_offset = start + consumed;
        self.files.lock().insert(
            path.to_path_buf(),
            FileState {
                offset: new_offset,
                mtime_ms,
                codex_model,
            },
        );
        added
    }

    fn parse_claude_line(&self, path: &Path, raw: &[u8]) -> bool {
        let value: serde_json::Value = match serde_json::from_slice(raw) {
            Ok(v) => v,
            Err(_) => return false,
        };

        let entry_type = value.get("type").and_then(|v| v.as_str()).unwrap_or("");
        if entry_type != "assistant" {
            return false;
        }

        let message = match value.get("message") {
            Some(m) => m,
            None => return false,
        };
        let usage = match message.get("usage") {
            Some(u) => u,
            None => return false,
        };

        let input = usage.get("input_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
        let output = usage.get("output_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
        let cache_read = usage
            .get("cache_read_input_tokens")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        let cache_write = usage
            .get("cache_creation_input_tokens")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);

        if input + output + cache_read + cache_write <= 0 {
            return false;
        }

        let model = message
            .get("model")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string();
        let model = normalize_model(&model);

        let ts_ms = value
            .get("timestamp")
            .and_then(|v| v.as_str())
            .and_then(parse_rfc3339_ms)
            .unwrap_or_else(now_ms);

        let is_sidechain = value
            .get("isSidechain")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let agent_id = value.get("agentId").and_then(|v| v.as_str());

        let agent = if is_sidechain {
            match agent_id {
                Some(id) if !id.is_empty() => format!("subagent:{}", id),
                _ => sidechain_label_from_path(path),
            }
        } else {
            "main".to_string()
        };

        let msg_id = message.get("id").and_then(|v| v.as_str()).unwrap_or("");
        let req_id = value
            .get("requestId")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let dedup_key = if !msg_id.is_empty() {
            format!("claude:{}:{}", msg_id, req_id)
        } else {
            String::new()
        };

        self.push_event(
            UsageEvent {
                ts_ms,
                client: CLIENT_CLAUDE.to_string(),
                agent,
                model,
                input,
                output,
                cache_read,
                cache_write,
            },
            &dedup_key,
        )
    }

    fn parse_codex_line(&self, raw: &[u8], codex_model: &mut Option<String>) -> bool {
        let value: serde_json::Value = match serde_json::from_slice(raw) {
            Ok(v) => v,
            Err(_) => return false,
        };

        let entry_type = value.get("type").and_then(|v| v.as_str()).unwrap_or("");
        let payload = value.get("payload");

        if entry_type == "turn_context" {
            if let Some(model) = payload
                .and_then(|p| p.get("model"))
                .and_then(|v| v.as_str())
            {
                *codex_model = Some(model.to_string());
            }
            return false;
        }

        if entry_type != "event_msg" {
            return false;
        }
        let payload = match payload {
            Some(p) => p,
            None => return false,
        };
        let payload_type = payload.get("type").and_then(|v| v.as_str()).unwrap_or("");
        if payload_type != "token_count" {
            return false;
        }

        // Use last_token_usage (delta for this turn), not total_token_usage
        // (running counter — would inflate the rate every event).
        let usage = match payload
            .get("info")
            .and_then(|i| i.get("last_token_usage"))
        {
            Some(u) => u,
            None => return false,
        };

        let input = usage
            .get("input_tokens")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        let output = usage
            .get("output_tokens")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        // Codex reports cached input under cached_input_tokens; this is a
        // subset of input_tokens (not additive). Surface it as cache_read
        // for consistency with Claude's split, and subtract from input so
        // the bucket totals don't double-count.
        let cache_read = usage
            .get("cached_input_tokens")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        let input = (input - cache_read).max(0);

        if input + output + cache_read <= 0 {
            return false;
        }

        let model = codex_model
            .clone()
            .map(|m| normalize_model(&m))
            .unwrap_or_else(|| "unknown".to_string());

        let ts_ms = value
            .get("timestamp")
            .and_then(|v| v.as_str())
            .and_then(parse_rfc3339_ms)
            .unwrap_or_else(now_ms);

        self.push_event(
            UsageEvent {
                ts_ms,
                client: CLIENT_CODEX.to_string(),
                agent: "main".to_string(),
                model,
                input,
                output,
                cache_read,
                cache_write: 0,
            },
            "",
        )
    }

    /// Open the Hermes Agent state DB and diff against the previous
    /// snapshot to derive per-session deltas. Returns the number of
    /// events appended. Hermes stores aggregates that grow in place,
    /// so we can't use a file offset like the JSONL tailers — we keep
    /// per-session totals from the previous tick instead.
    fn tick_hermes(&self, is_cold: bool) -> usize {
        let path = match hermes_db_path() {
            Some(p) => p,
            None => return 0,
        };
        let conn = match Connection::open_with_flags(
            &path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        ) {
            Ok(c) => c,
            Err(_) => return 0,
        };
        let mut stmt = match conn.prepare(
            r#"
            SELECT id, model,
                COALESCE(input_tokens, 0),
                COALESCE(output_tokens, 0),
                COALESCE(cache_read_tokens, 0),
                COALESCE(cache_write_tokens, 0)
            FROM sessions
            WHERE model IS NOT NULL AND TRIM(model) != ''
            "#,
        ) {
            Ok(s) => s,
            Err(_) => return 0,
        };
        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, i64>(5)?,
                ))
            })
            .ok();
        let rows = match rows {
            Some(r) => r,
            None => return 0,
        };

        let mut added = 0;
        let ts_ms = now_ms();
        let mut snapshots = self.hermes_snapshots.lock();
        for row in rows.flatten() {
            let (session_id, model, input, output, cache_read, cache_write) = row;
            let prev = snapshots.get(&session_id).copied().unwrap_or_default();
            let new = HermesSnapshot {
                input,
                output,
                cache_read,
                cache_write,
            };
            snapshots.insert(session_id.clone(), new);
            if is_cold {
                // Cold start: stamp the current totals as the baseline so
                // we don't double-count historical activity as a fresh
                // burst.
                continue;
            }
            let d_input = (input - prev.input).max(0);
            let d_output = (output - prev.output).max(0);
            let d_cache_read = (cache_read - prev.cache_read).max(0);
            let d_cache_write = (cache_write - prev.cache_write).max(0);
            if d_input + d_output + d_cache_read + d_cache_write <= 0 {
                continue;
            }
            drop(snapshots);
            let event = UsageEvent {
                ts_ms,
                client: CLIENT_HERMES.to_string(),
                agent: "main".to_string(),
                model: normalize_model(&model),
                input: d_input,
                output: d_output,
                cache_read: d_cache_read,
                cache_write: d_cache_write,
            };
            if self.push_event(event, "") {
                added += 1;
            }
            snapshots = self.hermes_snapshots.lock();
        }
        added
    }

    /// Append an event, deduplicating against `dedup_key` (use `""` to
    /// skip dedup). Returns true if a new event was appended.
    fn push_event(&self, event: UsageEvent, dedup_key: &str) -> bool {
        let mut events = self.events.lock();
        let mut seen = self.seen.lock();
        if !dedup_key.is_empty() {
            if let Some(&idx) = seen.get(dedup_key) {
                if let Some(existing) = events.get_mut(idx) {
                    existing.input = existing.input.max(event.input);
                    existing.output = existing.output.max(event.output);
                    existing.cache_read = existing.cache_read.max(event.cache_read);
                    existing.cache_write = existing.cache_write.max(event.cache_write);
                    return false;
                }
            }
        }
        let idx = events.len();
        events.push_back(event);
        if !dedup_key.is_empty() {
            seen.insert(dedup_key.to_string(), idx);
        }
        true
    }

    fn trim_events(&self) {
        let cutoff = now_ms() - EVENT_WINDOW_SECS * 1000;
        let mut events = self.events.lock();
        let mut seen = self.seen.lock();
        let before = events.len();
        events.retain(|e| e.ts_ms >= cutoff);
        if events.len() == before {
            return;
        }
        seen.clear();
    }

    pub fn rate_per_min(&self) -> f32 {
        self.window_total(60) as f32
    }

    pub fn rate_in_window(&self, window_secs: i64) -> f32 {
        if window_secs <= 0 {
            return 0.0;
        }
        let total = self.window_total(window_secs) as f32;
        let window_min = window_secs as f32 / 60.0;
        total / window_min
    }

    fn window_total(&self, secs: i64) -> i64 {
        let cutoff = now_ms() - secs * 1000;
        let events = self.events.lock();
        events
            .iter()
            .filter(|e| e.ts_ms >= cutoff)
            .map(|e| e.total())
            .sum()
    }

    pub fn trace(&self, window_secs: i64) -> Vec<TraceBucket> {
        let cutoff = now_ms() - window_secs * 1000;
        let events = self.events.lock();
        // One row per client. agents (main, subagent:*) and model
        // variants are joined into a single label so each CLI shows up
        // exactly once in the trace card.
        let mut groups: HashMap<String, (i64, u32, Vec<String>, Vec<String>)> = HashMap::new();
        for e in events.iter() {
            if e.ts_ms < cutoff {
                continue;
            }
            let slot = groups
                .entry(e.client.clone())
                .or_insert_with(|| (0, 0, Vec::new(), Vec::new()));
            slot.0 += e.total();
            slot.1 += 1;
            if !slot.2.iter().any(|a| a == &e.agent) {
                slot.2.push(e.agent.clone());
            }
            if !slot.3.iter().any(|m| m == &e.model) {
                slot.3.push(e.model.clone());
            }
        }
        let window_min = (window_secs as f32 / 60.0).max(1.0 / 60.0);
        let mut out: Vec<TraceBucket> = groups
            .into_iter()
            .map(|(client, (tokens, messages, mut agents, mut models))| {
                agents.sort();
                models.sort();
                if models.len() > 1 {
                    models.retain(|m| m != "unknown");
                }
                TraceBucket {
                    client,
                    agent: agents.join(", "),
                    model: models.join(", "),
                    tokens,
                    messages,
                    tokens_per_min: tokens as f32 / window_min,
                }
            })
            .collect();
        out.sort_by(|a, b| b.tokens.cmp(&a.tokens));
        out
    }
}

fn hermes_db_path() -> Option<PathBuf> {
    if let Ok(home) = std::env::var("HERMES_HOME") {
        let p = PathBuf::from(home).join("state.db");
        if p.is_file() {
            return Some(p);
        }
    }
    let home = std::env::var_os("HOME")?;
    let p = PathBuf::from(home).join(".hermes").join("state.db");
    if p.is_file() {
        Some(p)
    } else {
        None
    }
}

fn roots() -> Vec<(PathBuf, ClientKind)> {
    let mut out = Vec::new();
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        let claude = home.join(".claude").join("projects");
        if claude.is_dir() {
            out.push((claude, ClientKind::Claude));
        }
        let codex = home.join(".codex").join("sessions");
        if codex.is_dir() {
            out.push((codex, ClientKind::Codex));
        }
    }
    out
}

fn system_time_to_ms(t: Option<SystemTime>) -> i64 {
    match t.and_then(|t| t.duration_since(UNIX_EPOCH).ok()) {
        Some(d) => d.as_millis() as i64,
        None => 0,
    }
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn parse_rfc3339_ms(s: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(s).ok().map(|dt| dt.timestamp_millis())
}

fn trim_ascii(s: &[u8]) -> &[u8] {
    let start = s
        .iter()
        .position(|&b| !b.is_ascii_whitespace())
        .unwrap_or(s.len());
    let end = s
        .iter()
        .rposition(|&b| !b.is_ascii_whitespace())
        .map(|i| i + 1)
        .unwrap_or(0);
    if start >= end {
        &[]
    } else {
        &s[start..end]
    }
}

fn normalize_model(id: &str) -> String {
    let mut name = id.to_lowercase();
    if name.len() > 9 {
        let tail = &name[name.len() - 8..];
        if tail.chars().all(|c| c.is_ascii_digit()) && name.as_bytes()[name.len() - 9] == b'-' {
            name.truncate(name.len() - 9);
        }
    }
    name
}

fn sidechain_label_from_path(path: &Path) -> String {
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("subagent");
    if let Some(rest) = stem.strip_prefix("agent-") {
        format!("subagent:{}", rest)
    } else {
        format!("subagent:{}", stem)
    }
}
