use chrono::{Local, SecondsFormat, TimeZone, Utc};
use rusqlite::{Connection, OpenFlags};
use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const VERSION: &str = concat!("tokcat-core/", env!("CARGO_PKG_VERSION"));

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenBreakdown {
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub reasoning: i64,
}

impl TokenBreakdown {
    fn total(&self) -> i64 {
        self.input + self.output + self.cache_read + self.cache_write + self.reasoning
    }

    fn add(&mut self, other: &Self) {
        self.input = self.input.saturating_add(other.input.max(0));
        self.output = self.output.saturating_add(other.output.max(0));
        self.cache_read = self.cache_read.saturating_add(other.cache_read.max(0));
        self.cache_write = self.cache_write.saturating_add(other.cache_write.max(0));
        self.reasoning = self.reasoning.saturating_add(other.reasoning.max(0));
    }
}

#[derive(Debug, Clone)]
struct UsageMessage {
    client: String,
    model_id: String,
    provider_id: String,
    timestamp_ms: i64,
    date: String,
    tokens: TokenBreakdown,
    cost: f64,
    messages: i32,
    dedup_key: Option<String>,
}

impl UsageMessage {
    fn new(
        client: impl Into<String>,
        model_id: impl Into<String>,
        provider_id: impl Into<String>,
        timestamp_ms: i64,
        tokens: TokenBreakdown,
        cost: f64,
    ) -> Self {
        Self {
            client: client.into(),
            model_id: normalize_model_id(&model_id.into()),
            provider_id: provider_id.into(),
            timestamp_ms,
            date: date_from_timestamp_ms(timestamp_ms),
            tokens,
            cost: cost.max(0.0),
            messages: 1,
            dedup_key: None,
        }
    }

    fn total_tokens(&self) -> i64 {
        self.tokens.total()
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ClientContribution {
    client: String,
    model_id: String,
    provider_id: String,
    tokens: TokenBreakdown,
    cost: f64,
    messages: i32,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct DailyTotals {
    tokens: i64,
    cost: f64,
    messages: i32,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct DailyContribution {
    date: String,
    totals: DailyTotals,
    intensity: u8,
    token_breakdown: TokenBreakdown,
    clients: Vec<ClientContribution>,
}

#[derive(Debug, Clone, Serialize)]
struct DateRange {
    start: String,
    end: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct YearSummary {
    year: String,
    total_tokens: i64,
    total_cost: f64,
    range: DateRange,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct DataSummary {
    total_tokens: i64,
    total_cost: f64,
    total_days: i32,
    active_days: i32,
    average_per_day: f64,
    max_cost_in_single_day: f64,
    clients: Vec<String>,
    models: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ExportMeta {
    generated_at: String,
    version: String,
    date_range: DateRange,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct TokenContributionData {
    meta: ExportMeta,
    summary: DataSummary,
    years: Vec<YearSummary>,
    contributions: Vec<DailyContribution>,
}

#[derive(Default)]
struct DayAccumulator {
    totals: DailyTotals,
    token_breakdown: TokenBreakdown,
    clients: HashMap<String, ClientContribution>,
}

pub fn run(year: &str) -> Result<Value, String> {
    let year = normalize_year(year)?;
    let mut messages = collect_messages();
    if let Some(year) = year.as_deref() {
        let prefix = format!("{}-", year);
        messages.retain(|m| m.date.starts_with(&prefix));
    }
    let payload = build_payload(messages);
    serde_json::to_value(payload).map_err(|e| format!("serialize usage graph: {}", e))
}

fn normalize_year(year: &str) -> Result<Option<String>, String> {
    let trimmed = year.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    if trimmed.len() == 4 && trimmed.chars().all(|c| c.is_ascii_digit()) {
        Ok(Some(trimmed.to_string()))
    } else {
        Err(format!("invalid year filter: {}", year))
    }
}

fn collect_messages() -> Vec<UsageMessage> {
    let mut messages = Vec::new();
    messages.extend(parse_claude());
    messages.extend(parse_codex());
    messages.extend(parse_cursor());
    messages.extend(parse_opencode());
    messages.extend(parse_gemini());
    messages.extend(parse_copilot());
    messages.extend(parse_amp());
    messages.extend(parse_droid());
    messages.extend(parse_hermes());
    messages.extend(parse_grok());

    dedup_messages(messages)
        .into_iter()
        .filter_map(|mut msg| {
            if msg.timestamp_ms <= 0 || msg.total_tokens() <= 0 {
                return None;
            }
            if msg.provider_id.trim().is_empty() {
                msg.provider_id = infer_provider(&msg.model_id).to_string();
            }
            if msg.cost <= 0.0 {
                msg.cost = estimate_cost(&msg.model_id, &msg.provider_id, &msg.tokens);
            }
            Some(msg)
        })
        .collect()
}

fn dedup_messages(messages: Vec<UsageMessage>) -> Vec<UsageMessage> {
    let mut seen = HashSet::new();
    let mut out = Vec::with_capacity(messages.len());
    for msg in messages {
        let key = msg.dedup_key.clone().unwrap_or_else(|| {
            format!(
                "{}:{}:{}:{}:{}:{}:{}:{}",
                msg.client,
                msg.model_id,
                msg.provider_id,
                msg.timestamp_ms,
                msg.tokens.input,
                msg.tokens.output,
                msg.tokens.cache_read,
                msg.tokens.cache_write
            )
        });
        if seen.insert(key) {
            out.push(msg);
        }
    }
    out
}

fn build_payload(messages: Vec<UsageMessage>) -> TokenContributionData {
    let mut day_map: BTreeMap<String, DayAccumulator> = BTreeMap::new();

    for msg in messages {
        let day = day_map.entry(msg.date.clone()).or_default();
        day.totals.tokens = day.totals.tokens.saturating_add(msg.total_tokens());
        day.totals.cost += msg.cost;
        day.totals.messages = day.totals.messages.saturating_add(msg.messages);
        day.token_breakdown.add(&msg.tokens);

        let key = format!("{}:{}:{}", msg.client, msg.provider_id, msg.model_id);
        let client = day
            .clients
            .entry(key)
            .or_insert_with(|| ClientContribution {
                client: msg.client.clone(),
                model_id: msg.model_id.clone(),
                provider_id: msg.provider_id.clone(),
                tokens: TokenBreakdown::default(),
                cost: 0.0,
                messages: 0,
            });
        client.tokens.add(&msg.tokens);
        client.cost += msg.cost;
        client.messages = client.messages.saturating_add(msg.messages);
    }

    let mut contributions: Vec<DailyContribution> = day_map
        .into_iter()
        .map(|(date, day)| {
            let mut clients: Vec<ClientContribution> = day.clients.into_values().collect();
            clients.sort_by(|a, b| {
                a.client
                    .cmp(&b.client)
                    .then(a.provider_id.cmp(&b.provider_id))
                    .then(a.model_id.cmp(&b.model_id))
            });
            DailyContribution {
                date,
                totals: day.totals,
                intensity: 0,
                token_breakdown: day.token_breakdown,
                clients,
            }
        })
        .collect();

    calculate_intensities(&mut contributions);
    let summary = calculate_summary(&contributions);
    let years = calculate_years(&contributions);
    let date_range = DateRange {
        start: contributions
            .first()
            .map(|c| c.date.clone())
            .unwrap_or_default(),
        end: contributions
            .last()
            .map(|c| c.date.clone())
            .unwrap_or_default(),
    };

    TokenContributionData {
        meta: ExportMeta {
            generated_at: Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
            version: VERSION.to_string(),
            date_range,
        },
        summary,
        years,
        contributions,
    }
}

fn calculate_summary(contributions: &[DailyContribution]) -> DataSummary {
    let mut clients = BTreeSet::new();
    let mut models = BTreeSet::new();
    let mut total_tokens = 0;
    let mut total_cost = 0.0;
    let mut max_cost = 0.0f64;

    for c in contributions {
        total_tokens += c.totals.tokens;
        total_cost += c.totals.cost;
        max_cost = max_cost.max(c.totals.cost);
        for client in &c.clients {
            clients.insert(client.client.clone());
            models.insert(client.model_id.clone());
        }
    }

    let active_days = contributions.iter().filter(|c| c.totals.tokens > 0).count() as i32;
    DataSummary {
        total_tokens,
        total_cost,
        total_days: contributions.len() as i32,
        active_days,
        average_per_day: if active_days > 0 {
            total_cost / active_days as f64
        } else {
            0.0
        },
        max_cost_in_single_day: max_cost,
        clients: clients.into_iter().collect(),
        models: models.into_iter().collect(),
    }
}

fn calculate_years(contributions: &[DailyContribution]) -> Vec<YearSummary> {
    #[derive(Default)]
    struct Acc {
        tokens: i64,
        cost: f64,
        start: String,
        end: String,
    }

    let mut by_year: BTreeMap<String, Acc> = BTreeMap::new();
    for c in contributions {
        if c.date.len() < 4 {
            continue;
        }
        let year = c.date[..4].to_string();
        let acc = by_year.entry(year).or_default();
        acc.tokens += c.totals.tokens;
        acc.cost += c.totals.cost;
        if acc.start.is_empty() || c.date < acc.start {
            acc.start = c.date.clone();
        }
        if acc.end.is_empty() || c.date > acc.end {
            acc.end = c.date.clone();
        }
    }

    by_year
        .into_iter()
        .map(|(year, acc)| YearSummary {
            year,
            total_tokens: acc.tokens,
            total_cost: acc.cost,
            range: DateRange {
                start: acc.start,
                end: acc.end,
            },
        })
        .collect()
}

fn calculate_intensities(contributions: &mut [DailyContribution]) {
    let max_cost = contributions
        .iter()
        .map(|c| c.totals.cost)
        .fold(0.0f64, f64::max);
    if max_cost <= 0.0 {
        return;
    }
    for c in contributions {
        let ratio = c.totals.cost / max_cost;
        c.intensity = if ratio >= 0.75 {
            4
        } else if ratio >= 0.5 {
            3
        } else if ratio >= 0.25 {
            2
        } else if ratio > 0.0 {
            1
        } else {
            0
        };
    }
}

fn parse_claude() -> Vec<UsageMessage> {
    let mut out = Vec::new();
    let Some(home) = home_dir() else {
        return out;
    };
    let roots = [
        home.join(".claude").join("projects"),
        home.join(".claude").join("transcripts"),
    ];
    for root in roots {
        let files = collect_files(&root, |p| {
            matches!(
                p.extension().and_then(|s| s.to_str()),
                Some("jsonl") | Some("json")
            )
        });
        for file in files {
            out.extend(parse_claude_file(&file));
        }
    }
    out
}

fn parse_claude_file(path: &Path) -> Vec<UsageMessage> {
    let file = match fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return Vec::new(),
    };
    let fallback_ts = file_modified_timestamp_ms(path);
    let mut out: Vec<UsageMessage> = Vec::new();
    let mut dedup: HashMap<String, usize> = HashMap::new();
    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(value) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        if value.get("type").and_then(Value::as_str) != Some("assistant") {
            continue;
        }
        let Some(message) = value.get("message") else {
            continue;
        };
        let Some(usage) = message.get("usage") else {
            continue;
        };
        let Some(model) = string_value(message.get("model")) else {
            continue;
        };
        let tokens = TokenBreakdown {
            input: i64_value(usage.get("input_tokens")).unwrap_or(0).max(0),
            output: i64_value(usage.get("output_tokens")).unwrap_or(0).max(0),
            cache_read: i64_value(usage.get("cache_read_input_tokens"))
                .unwrap_or(0)
                .max(0),
            cache_write: i64_value(usage.get("cache_creation_input_tokens"))
                .unwrap_or(0)
                .max(0),
            reasoning: 0,
        };
        if tokens.total() <= 0 {
            continue;
        }
        let ts = timestamp_ms_from_value(value.get("timestamp")).unwrap_or(fallback_ts);
        let mut msg = UsageMessage::new("claude", model, "anthropic", ts, tokens, 0.0);
        if let (Some(id), Some(req)) = (
            string_value(message.get("id")),
            string_value(value.get("requestId")),
        ) {
            let key = format!("claude:{}:{}", id, req);
            if let Some(index) = dedup.get(&key).copied() {
                let existing = &mut out[index].tokens;
                existing.input = existing.input.max(msg.tokens.input);
                existing.output = existing.output.max(msg.tokens.output);
                existing.cache_read = existing.cache_read.max(msg.tokens.cache_read);
                existing.cache_write = existing.cache_write.max(msg.tokens.cache_write);
                continue;
            }
            dedup.insert(key.clone(), out.len());
            msg.dedup_key = Some(key);
        }
        out.push(msg);
    }
    out
}

fn parse_codex() -> Vec<UsageMessage> {
    let mut out = Vec::new();
    let Some(home) = home_dir() else {
        return out;
    };
    let codex_home = std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".codex"));
    let mut codex_homes = vec![codex_home];
    // Orca runs Codex with CODEX_HOME redirected to its own runtime home, so
    // sessions started inside Orca never land in ~/.codex. The menubar app is
    // launched from /Applications and doesn't inherit that env var, so scan
    // Orca's known Codex homes directly to avoid under-counting Codex usage.
    codex_homes.extend(orca_codex_homes(&home));
    // Extra homes can be listed (path-separated) for other launchers that
    // redirect CODEX_HOME the way Orca does.
    if let Some(extra) = std::env::var_os("TOKCAT_CODEX_HOMES") {
        codex_homes.extend(std::env::split_paths(&extra));
    }

    let mut roots = Vec::new();
    for codex_home in codex_homes {
        roots.push(codex_home.join("sessions"));
        roots.push(codex_home.join("archived_sessions"));
    }
    // Keep reading this legacy env var so users with existing headless exports
    // do not lose Codex history after removing the runtime CLI dependency.
    if let Ok(headless) = std::env::var("TOKSCALE_HEADLESS_DIR") {
        roots.push(PathBuf::from(headless).join("codex"));
    }

    // A launcher-provided CODEX_HOME may already point at an Orca home, so drop
    // duplicate roots; parse_codex_file is also deduped downstream by content.
    let mut seen = HashSet::new();
    for root in roots {
        if !seen.insert(root.clone()) {
            continue;
        }
        for file in collect_files(&root, |p| {
            p.extension().and_then(|s| s.to_str()) == Some("jsonl")
        }) {
            out.extend(parse_codex_file(&file));
        }
    }
    out
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
struct CodexTotals {
    input: i64,
    output: i64,
    cached: i64,
    reasoning: i64,
}

impl CodexTotals {
    fn from_usage(value: &Value) -> Self {
        Self {
            input: i64_value(value.get("input_tokens")).unwrap_or(0).max(0),
            output: i64_value(value.get("output_tokens")).unwrap_or(0).max(0),
            cached: i64_value(value.get("cached_input_tokens"))
                .unwrap_or(0)
                .max(i64_value(value.get("cache_read_input_tokens")).unwrap_or(0))
                .max(0),
            reasoning: i64_value(value.get("reasoning_output_tokens"))
                .unwrap_or(0)
                .max(0),
        }
    }

    fn delta_from(self, previous: Self) -> Option<Self> {
        if self.input < previous.input
            || self.output < previous.output
            || self.cached < previous.cached
            || self.reasoning < previous.reasoning
        {
            return None;
        }

        Some(Self {
            input: self.input - previous.input,
            output: self.output - previous.output,
            cached: self.cached - previous.cached,
            reasoning: self.reasoning - previous.reasoning,
        })
    }

    fn saturating_add(self, other: Self) -> Self {
        Self {
            input: self.input.saturating_add(other.input),
            output: self.output.saturating_add(other.output),
            cached: self.cached.saturating_add(other.cached),
            reasoning: self.reasoning.saturating_add(other.reasoning),
        }
    }

    fn total(self) -> i64 {
        self.input
            .saturating_add(self.output)
            .saturating_add(self.cached)
            .saturating_add(self.reasoning)
    }

    fn looks_like_stale_regression(self, previous: Self, last: Self) -> bool {
        let previous_total = previous.total();
        let current_total = self.total();
        let last_total = last.total();

        if previous_total <= 0 || current_total <= 0 || last_total <= 0 {
            return false;
        }

        current_total.saturating_mul(100) >= previous_total.saturating_mul(98)
            || current_total.saturating_add(last_total.saturating_mul(2)) >= previous_total
    }

    fn into_tokens(self) -> TokenBreakdown {
        let cache_read = self.cached.min(self.input).max(0);
        TokenBreakdown {
            input: (self.input - cache_read).max(0),
            output: self.output.max(0),
            cache_read,
            cache_write: 0,
            reasoning: self.reasoning.max(0),
        }
    }
}

fn parse_codex_file(path: &Path) -> Vec<UsageMessage> {
    let file = match fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return Vec::new(),
    };
    let fallback_ts = file_modified_timestamp_ms(path);
    let mut current_model: Option<String> = None;
    let mut previous_totals: Option<CodexTotals> = None;
    let mut provider = "openai".to_string();
    let mut forked_child_waiting_for_turn_context = false;
    let mut forked_child_inherited_baseline: Option<CodexTotals> = None;
    let mut forked_child_inherited_reported_total: Option<i64> = None;
    let mut out = Vec::new();

    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(value) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        let entry_type = value.get("type").and_then(Value::as_str).unwrap_or("");
        let payload = value.get("payload").unwrap_or(&Value::Null);

        if entry_type == "session_meta" {
            if let Some(p) = string_value(payload.get("model_provider")) {
                provider = p;
            }
            if string_value(payload.get("forked_from_id"))
                .as_deref()
                .is_some_and(|id| !id.is_empty())
            {
                forked_child_waiting_for_turn_context = true;
                forked_child_inherited_baseline = None;
                forked_child_inherited_reported_total = None;
            }
        }

        if forked_child_waiting_for_turn_context {
            if entry_type == "turn_context" {
                forked_child_waiting_for_turn_context = false;
            } else {
                if entry_type == "event_msg"
                    && payload.get("type").and_then(Value::as_str) == Some("token_count")
                {
                    if let Some(info) = payload.get("info") {
                        remember_codex_forked_child_inherited_baseline(
                            info,
                            &mut previous_totals,
                            &mut forked_child_inherited_baseline,
                            &mut forked_child_inherited_reported_total,
                        );
                    }
                }
                continue;
            }
        }

        if entry_type == "turn_context" {
            if let Some(model) = string_value(
                payload
                    .get("model_info")
                    .and_then(|v| v.get("slug"))
                    .or_else(|| payload.get("model"))
                    .or_else(|| payload.get("model_name")),
            ) {
                if !model.is_empty() {
                    current_model = Some(model);
                }
            }
            continue;
        }

        if entry_type != "event_msg"
            || payload.get("type").and_then(Value::as_str) != Some("token_count")
        {
            continue;
        }
        let Some(info) = payload.get("info") else {
            continue;
        };
        let model = string_value(info.get("model"))
            .or_else(|| string_value(info.get("model_name")))
            .or_else(|| current_model.clone())
            .unwrap_or_else(|| "unknown".to_string());
        if model != "unknown" {
            current_model = Some(model.clone());
        }
        let total_usage_value = info.get("total_token_usage");
        let total_usage = total_usage_value.map(CodexTotals::from_usage);
        let last_usage = info.get("last_token_usage").map(CodexTotals::from_usage);

        if codex_forked_child_matches_inherited_baseline(
            total_usage_value,
            total_usage,
            forked_child_inherited_baseline,
            forked_child_inherited_reported_total,
        ) {
            if let Some(total) = total_usage {
                previous_totals = Some(total);
            }
            forked_child_inherited_baseline = None;
            forked_child_inherited_reported_total = None;
            continue;
        }
        forked_child_inherited_baseline = None;
        forked_child_inherited_reported_total = None;

        let (tokens, next_totals) = match (total_usage, last_usage, previous_totals) {
            (Some(total), Some(last), Some(previous)) => {
                if total == previous {
                    continue;
                }
                if total.delta_from(previous).is_none()
                    && total.looks_like_stale_regression(previous, last)
                {
                    continue;
                }
                (last.into_tokens(), Some(total))
            }
            (Some(total), Some(last), None) => (last.into_tokens(), Some(total)),
            (Some(total), None, Some(previous)) => {
                if total == previous {
                    continue;
                }
                if let Some(delta) = total.delta_from(previous) {
                    (delta.into_tokens(), Some(total))
                } else {
                    previous_totals = Some(total);
                    continue;
                }
            }
            (Some(total), None, None) => (total.into_tokens(), Some(total)),
            (None, Some(last), Some(previous)) => {
                (last.into_tokens(), Some(previous.saturating_add(last)))
            }
            (None, Some(last), None) => (last.into_tokens(), None),
            (None, None, _) => continue,
        };
        if tokens.total() <= 0 {
            continue;
        }
        previous_totals = next_totals;
        let ts = timestamp_ms_from_value(value.get("timestamp")).unwrap_or(fallback_ts);
        let mut msg = UsageMessage::new("codex", model, provider.clone(), ts, tokens, 0.0);
        msg.dedup_key = Some(format!(
            "codex:{}:{}:{}:{}:{}",
            msg.timestamp_ms,
            msg.model_id,
            msg.tokens.input,
            msg.tokens.output,
            msg.tokens.cache_read
        ));
        out.push(msg);
    }
    out
}

fn remember_codex_forked_child_inherited_baseline(
    info: &Value,
    previous_totals: &mut Option<CodexTotals>,
    forked_child_inherited_baseline: &mut Option<CodexTotals>,
    forked_child_inherited_reported_total: &mut Option<i64>,
) {
    let Some(total_usage) = info.get("total_token_usage") else {
        return;
    };
    let totals = CodexTotals::from_usage(total_usage);
    *previous_totals = Some(totals);
    *forked_child_inherited_baseline = Some(totals);
    *forked_child_inherited_reported_total = codex_reported_total_tokens(total_usage);
}

fn codex_forked_child_matches_inherited_baseline(
    total_usage_value: Option<&Value>,
    total_usage: Option<CodexTotals>,
    forked_child_inherited_baseline: Option<CodexTotals>,
    forked_child_inherited_reported_total: Option<i64>,
) -> bool {
    if let (Some(usage), Some(baseline)) =
        (total_usage_value, forked_child_inherited_reported_total)
    {
        if codex_reported_total_tokens(usage) == Some(baseline) {
            return true;
        }
    }

    if let (Some(totals), Some(baseline)) = (total_usage, forked_child_inherited_baseline) {
        return totals == baseline;
    }

    false
}

fn codex_reported_total_tokens(usage: &Value) -> Option<i64> {
    i64_value(usage.get("total_tokens")).filter(|total| *total >= 0)
}

fn parse_cursor() -> Vec<UsageMessage> {
    let Some(home) = home_dir() else {
        return Vec::new();
    };
    let root = home.join(".config").join("tokscale").join("cursor-cache");
    // Preferred source: the JSON cache written by the opt-in cursor_usage
    // fetcher (per-event tokens + cost from cursor.com). When present it
    // supersedes the legacy CSV — same data, richer — so we don't read both
    // and double-count.
    let json_cache = root.join("tokcat-events.json");
    if json_cache.is_file() {
        let msgs = parse_cursor_cache_json(&json_cache);
        if !msgs.is_empty() {
            return msgs;
        }
    }
    // Fallback: the local compatibility CSV cache produced by older
    // Tokcat/tokscale setups. Reading it avoids dropping historical data.
    collect_files(&root, |p| {
        p.file_name().and_then(|s| s.to_str()).is_some_and(|name| {
            name == "usage.csv" || (name.starts_with("usage.") && name.ends_with(".csv"))
        })
    })
    .into_iter()
    .flat_map(|p| parse_cursor_file(&p))
    .collect()
}

fn parse_cursor_cache_json(path: &Path) -> Vec<UsageMessage> {
    let Ok(content) = fs::read_to_string(path) else {
        return Vec::new();
    };
    #[derive(serde::Deserialize)]
    struct Cache {
        events: Vec<Event>,
    }
    #[derive(serde::Deserialize)]
    struct Event {
        timestamp_ms: i64,
        model: String,
        input_tokens: i64,
        output_tokens: i64,
        cache_read_tokens: i64,
        cost: f64,
    }
    let Ok(cache) = serde_json::from_str::<Cache>(&content) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for e in cache.events {
        if e.timestamp_ms <= 0 {
            continue;
        }
        let mut msg = UsageMessage::new(
            "cursor",
            e.model.as_str(),
            infer_provider(&e.model),
            e.timestamp_ms,
            TokenBreakdown {
                input: e.input_tokens.max(0),
                output: e.output_tokens.max(0),
                cache_read: e.cache_read_tokens.max(0),
                cache_write: 0,
                reasoning: 0,
            },
            e.cost.max(0.0),
        );
        msg.dedup_key = Some(format!(
            "cursor:{}:{}:{}",
            e.timestamp_ms, e.input_tokens, e.output_tokens
        ));
        out.push(msg);
    }
    out
}

fn parse_cursor_file(path: &Path) -> Vec<UsageMessage> {
    let Ok(content) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut lines = content.lines();
    let Some(header) = lines.next() else {
        return Vec::new();
    };
    let header_fields = parse_csv_line(header);
    let has_kind = header_fields.iter().any(|f| f.trim_matches('"') == "Kind");
    let column_count = header_fields.len();
    let (model_idx, input_with_cache_idx, input_no_cache_idx, cache_read_idx, output_idx, cost_idx) =
        if has_kind && column_count >= 12 {
            (4, 6, 7, 8, 9, 11)
        } else if has_kind && column_count >= 10 {
            (2, 4, 5, 6, 7, 9)
        } else {
            (1, 2, 3, 4, 5, 7)
        };

    let account = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("usage")
        .to_string();
    let mut out = Vec::new();
    for line in lines {
        let fields = parse_csv_line(line);
        if fields.len() <= cost_idx {
            continue;
        }
        let date = clean_csv(fields[0]);
        let model = clean_csv(fields[model_idx]);
        if model.is_empty() {
            continue;
        }
        let input_with_cache = clean_csv(fields[input_with_cache_idx])
            .parse::<i64>()
            .unwrap_or(0);
        let input_without_cache = clean_csv(fields[input_no_cache_idx])
            .parse::<i64>()
            .unwrap_or(0);
        let cache_read = clean_csv(fields[cache_read_idx])
            .parse::<i64>()
            .unwrap_or(0);
        let output = clean_csv(fields[output_idx]).parse::<i64>().unwrap_or(0);
        let cost = parse_cost(clean_csv(fields[cost_idx]));
        let ts = parse_date_to_timestamp_ms(clean_csv(fields[0]));
        if ts <= 0 {
            continue;
        }
        let mut msg = UsageMessage::new(
            "cursor",
            model,
            infer_provider(model),
            ts,
            TokenBreakdown {
                input: input_without_cache.max(0),
                output: output.max(0),
                cache_read: cache_read.max(0),
                cache_write: (input_with_cache - input_without_cache).max(0),
                reasoning: 0,
            },
            cost,
        );
        msg.dedup_key = Some(format!("cursor:{}:{}", account, date));
        out.push(msg);
    }
    out
}

fn parse_opencode() -> Vec<UsageMessage> {
    let mut out = Vec::new();
    let Some(home) = home_dir() else {
        return out;
    };
    let xdg = xdg_data_home(&home);
    let data_root = xdg.join("opencode");
    for db_path in discover_opencode_dbs(&data_root) {
        out.extend(parse_opencode_sqlite(&db_path));
    }
    let legacy = data_root.join("storage").join("message");
    for file in collect_files(&legacy, |p| {
        p.extension().and_then(|s| s.to_str()) == Some("json")
    }) {
        if let Some(msg) = parse_opencode_json_file(&file) {
            out.push(msg);
        }
    }
    out
}

fn discover_opencode_dbs(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(entries) = fs::read_dir(root) {
        for entry in entries.flatten() {
            let path = entry.path();
            let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
            if path.is_file()
                && (name == "opencode.db"
                    || (name.starts_with("opencode-") && name.ends_with(".db")))
            {
                out.push(path);
            }
        }
    }
    out.sort();
    out
}

fn parse_opencode_sqlite(path: &Path) -> Vec<UsageMessage> {
    let conn = match Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    let query_with_session = r#"
        SELECT m.id, m.session_id, m.data
        FROM message m
        LEFT JOIN session s ON s.id = m.session_id
        ORDER BY m.id, m.session_id
    "#;
    let query_legacy = "SELECT id, session_id, data FROM message ORDER BY id, session_id";

    let mut stmt = match conn
        .prepare(query_with_session)
        .or_else(|_| conn.prepare(query_legacy))
    {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let rows = match stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1).unwrap_or_default(),
            row.get::<_, String>(2)?,
        ))
    }) {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };

    let mut out = Vec::new();
    for row in rows.flatten() {
        if let Some(mut msg) = parse_opencode_json(&row.2) {
            if msg.dedup_key.is_none() {
                msg.dedup_key = Some(row.0);
            }
            if row.1.len() > 0 && msg.dedup_key.as_deref() == Some("unknown") {
                msg.dedup_key = Some(row.1);
            }
            out.push(msg);
        }
    }
    out
}

fn parse_opencode_json_file(path: &Path) -> Option<UsageMessage> {
    let data = fs::read_to_string(path).ok()?;
    let mut msg = parse_opencode_json(&data)?;
    if msg.dedup_key.is_none() {
        msg.dedup_key = path
            .file_stem()
            .and_then(|s| s.to_str())
            .map(str::to_string);
    }
    Some(msg)
}

fn parse_opencode_json(data: &str) -> Option<UsageMessage> {
    let value: Value = serde_json::from_str(data).ok()?;
    if value.get("role").and_then(Value::as_str) != Some("assistant") {
        return None;
    }
    let tokens = value.get("tokens")?;
    let cache = tokens.get("cache").unwrap_or(&Value::Null);
    let model = string_value(value.get("modelID")).or_else(|| string_value(value.get("model")))?;
    let provider =
        string_value(value.get("providerID")).unwrap_or_else(|| infer_provider(&model).to_string());
    let ts = value
        .get("time")
        .and_then(|t| t.get("created"))
        .and_then(|v| timestamp_ms_from_value(Some(v)))
        .or_else(|| timestamp_ms_from_value(value.get("created")))
        .unwrap_or_else(now_ms);
    let mut msg = UsageMessage::new(
        "opencode",
        model,
        provider,
        ts,
        TokenBreakdown {
            input: i64_value(tokens.get("input")).unwrap_or(0).max(0),
            output: i64_value(tokens.get("output")).unwrap_or(0).max(0),
            cache_read: i64_value(cache.get("read")).unwrap_or(0).max(0),
            cache_write: i64_value(cache.get("write")).unwrap_or(0).max(0),
            reasoning: i64_value(tokens.get("reasoning")).unwrap_or(0).max(0),
        },
        f64_value(value.get("cost")).unwrap_or(0.0),
    );
    msg.dedup_key = string_value(value.get("id")).map(|id| format!("opencode:{}", id));
    Some(msg)
}

fn parse_gemini() -> Vec<UsageMessage> {
    let Some(home) = home_dir() else {
        return Vec::new();
    };
    collect_files(&home.join(".gemini").join("tmp"), |p| {
        matches!(
            p.extension().and_then(|s| s.to_str()),
            Some("json") | Some("jsonl")
        )
    })
    .into_iter()
    .flat_map(|p| parse_gemini_file(&p))
    .collect()
}

fn parse_gemini_file(path: &Path) -> Vec<UsageMessage> {
    let fallback_ts = file_modified_timestamp_ms(path);
    if path.extension().and_then(|s| s.to_str()) == Some("jsonl") {
        return parse_gemini_jsonl(path, fallback_ts);
    }
    let Ok(data) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let Ok(value) = serde_json::from_str::<Value>(&data) else {
        return Vec::new();
    };
    parse_gemini_value(&value, fallback_ts)
}

fn parse_gemini_jsonl(path: &Path, fallback_ts: i64) -> Vec<UsageMessage> {
    let file = match fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return Vec::new(),
    };
    let mut out = Vec::new();
    let mut current_model: Option<String> = None;
    let mut session_id = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("gemini")
        .to_string();
    let mut direct_by_id: HashMap<String, usize> = HashMap::new();
    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(value) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        if let Some(id) = string_value(value.get("session_id").or_else(|| value.get("sessionId"))) {
            session_id = id;
        }
        if let Some(model) = string_value(value.get("model")) {
            current_model = Some(model);
        }
        if value.get("type").and_then(Value::as_str) == Some("gemini") {
            if let Some(mut msg) = build_gemini_message(&value, current_model.clone(), fallback_ts)
            {
                msg.dedup_key = string_value(value.get("id")).map(|id| format!("gemini:{}", id));
                if let Some(key) = msg.dedup_key.clone() {
                    if let Some(idx) = direct_by_id.get(&key).copied() {
                        out[idx] = msg;
                    } else {
                        direct_by_id.insert(key, out.len());
                        out.push(msg);
                    }
                } else {
                    msg.dedup_key = Some(format!("gemini:{}:{}", session_id, out.len()));
                    out.push(msg);
                }
            }
            continue;
        }
        if let Some(stats) = value
            .get("stats")
            .or_else(|| value.get("result").and_then(|r| r.get("stats")))
        {
            out.extend(build_gemini_stats_messages(
                stats,
                current_model.clone(),
                fallback_ts,
            ));
        }
    }
    out
}

fn parse_gemini_value(value: &Value, fallback_ts: i64) -> Vec<UsageMessage> {
    if let Some(messages) = value.get("messages").and_then(Value::as_array) {
        return messages
            .iter()
            .filter(|m| m.get("type").and_then(Value::as_str) == Some("gemini"))
            .filter_map(|m| build_gemini_message(m, None, fallback_ts))
            .collect();
    }
    if let Some(message) = build_gemini_message(value, None, fallback_ts) {
        return vec![message];
    }
    if let Some(stats) = value
        .get("stats")
        .or_else(|| value.get("result").and_then(|r| r.get("stats")))
    {
        return build_gemini_stats_messages(stats, string_value(value.get("model")), fallback_ts);
    }
    Vec::new()
}

fn build_gemini_message(
    value: &Value,
    model_hint: Option<String>,
    fallback_ts: i64,
) -> Option<UsageMessage> {
    let tokens = value.get("tokens")?;
    let model = string_value(value.get("model")).or(model_hint)?;
    let output = i64_value(tokens.get("output")).unwrap_or(0).max(0);
    let reasoning = i64_value(tokens.get("thoughts")).unwrap_or(0).max(0);
    let tool = i64_value(tokens.get("tool")).unwrap_or(0).max(0);
    let cache_read = i64_value(tokens.get("cached")).unwrap_or(0).max(0);
    let input_raw = i64_value(tokens.get("input")).unwrap_or(0).max(0);
    let total = i64_value(tokens.get("total"));
    let inclusive_total = input_raw + output + reasoning + tool;
    let input = if cache_read > 0 && total == Some(inclusive_total) {
        input_raw.saturating_sub(cache_read)
    } else {
        input_raw
    };
    let ts = timestamp_ms_from_value(value.get("timestamp").or_else(|| value.get("created_at")))
        .unwrap_or(fallback_ts);
    Some(UsageMessage::new(
        "gemini",
        model,
        "google",
        ts,
        TokenBreakdown {
            input: input + tool,
            output,
            cache_read,
            cache_write: 0,
            reasoning,
        },
        0.0,
    ))
}

fn build_gemini_stats_messages(
    stats: &Value,
    model_hint: Option<String>,
    fallback_ts: i64,
) -> Vec<UsageMessage> {
    let mut out = Vec::new();
    if let Some(models) = stats.get("models").and_then(Value::as_object) {
        for (model, data) in models {
            if let Some(msg) = build_gemini_stats_message(model, data, fallback_ts) {
                out.push(msg);
            }
        }
        if !out.is_empty() {
            return out;
        }
    }
    if let Some(model) = model_hint {
        if let Some(msg) = build_gemini_stats_message(&model, stats, fallback_ts) {
            out.push(msg);
        }
    }
    out
}

fn build_gemini_stats_message(
    model: &str,
    value: &Value,
    fallback_ts: i64,
) -> Option<UsageMessage> {
    let tokens = value.get("tokens").unwrap_or(value);
    let input_raw = i64_value(tokens.get("prompt"))
        .or_else(|| i64_value(tokens.get("input_tokens")))
        .or_else(|| i64_value(tokens.get("prompt_tokens")))
        .or_else(|| i64_value(tokens.get("input")))
        .unwrap_or(0);
    let output = i64_value(tokens.get("candidates"))
        .or_else(|| i64_value(tokens.get("output")))
        .or_else(|| i64_value(tokens.get("output_tokens")))
        .unwrap_or(0);
    let cache_read = i64_value(tokens.get("cached"))
        .or_else(|| i64_value(tokens.get("cached_tokens")))
        .unwrap_or(0);
    let reasoning = i64_value(tokens.get("thoughts"))
        .or_else(|| i64_value(tokens.get("thoughts_tokens")))
        .or_else(|| i64_value(tokens.get("reasoning")))
        .or_else(|| i64_value(tokens.get("reasoning_tokens")))
        .unwrap_or(0);
    if input_raw == 0 && output == 0 && cache_read == 0 && reasoning == 0 {
        return None;
    }
    Some(UsageMessage::new(
        "gemini",
        model.to_string(),
        "google",
        fallback_ts,
        TokenBreakdown {
            input: input_raw.saturating_sub(cache_read).max(0),
            output: output.max(0),
            cache_read: cache_read.max(0),
            cache_write: 0,
            reasoning: reasoning.max(0),
        },
        0.0,
    ))
}

fn parse_copilot() -> Vec<UsageMessage> {
    let Some(home) = home_dir() else {
        return Vec::new();
    };
    let mut files = collect_files(&home.join(".copilot").join("otel"), |p| {
        p.extension().and_then(|s| s.to_str()) == Some("jsonl")
    });
    if let Ok(path) = std::env::var("COPILOT_OTEL_FILE_EXPORTER_PATH") {
        let p = PathBuf::from(path);
        if p.is_file() {
            files.push(p);
        }
    }
    files
        .into_iter()
        .flat_map(|p| parse_copilot_file(&p))
        .collect()
}

fn parse_copilot_file(path: &Path) -> Vec<UsageMessage> {
    let file = match fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return Vec::new(),
    };
    let fallback_ts = file_modified_timestamp_ms(path);
    let mut out = Vec::new();
    for (index, line) in BufReader::new(file)
        .lines()
        .map_while(Result::ok)
        .enumerate()
    {
        let Ok(value) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        let Some(attrs) = value.get("attributes") else {
            continue;
        };
        let input = attr_i64(attrs, &["gen_ai.usage.input_tokens"]);
        let output = attr_i64(attrs, &["gen_ai.usage.output_tokens"]);
        let cache_read = attr_i64(attrs, &["gen_ai.usage.cache_read.input_tokens"]);
        let cache_write = attr_i64(
            attrs,
            &[
                "gen_ai.usage.cache_write.input_tokens",
                "gen_ai.usage.cache_creation.input_tokens",
            ],
        );
        let reasoning = attr_i64(
            attrs,
            &[
                "gen_ai.usage.reasoning.output_tokens",
                "gen_ai.usage.reasoning_tokens",
            ],
        );
        let cache_for_input = cache_read.max(0).min(input.max(0));
        let tokens = TokenBreakdown {
            input: input.saturating_sub(cache_for_input).max(0),
            output: output.max(0),
            cache_read: cache_read.max(0),
            cache_write: cache_write.max(0),
            reasoning: reasoning.max(0),
        };
        if tokens.total() <= 0 {
            continue;
        }
        let model = attr_string(attrs, &["gen_ai.response.model", "gen_ai.request.model"])
            .unwrap_or_else(|| "unknown".to_string());
        let session = attr_string(
            attrs,
            &[
                "gen_ai.conversation.id",
                "copilot_chat.session_id",
                "gen_ai.response.id",
                "session.id",
            ],
        )
        .unwrap_or_else(|| "unknown-session".to_string());
        let ts = copilot_timestamp_ms(&value).unwrap_or(fallback_ts);
        let provider = infer_provider(&model).to_string();
        let mut msg = UsageMessage::new("copilot", model, provider, ts, tokens, 0.0);
        let trace = string_value(value.get("traceId")).or_else(|| {
            value
                .get("spanContext")
                .and_then(|s| string_value(s.get("traceId")))
        });
        let span = string_value(value.get("spanId")).or_else(|| {
            value
                .get("spanContext")
                .and_then(|s| string_value(s.get("spanId")))
        });
        msg.dedup_key = Some(match (trace, span) {
            (Some(t), Some(s)) => format!("copilot:{}:{}", t, s),
            _ => format!("copilot:{}:{}:{}", session, ts, index),
        });
        out.push(msg);
    }
    out
}

fn parse_amp() -> Vec<UsageMessage> {
    let Some(home) = home_dir() else {
        return Vec::new();
    };
    let root = xdg_data_home(&home).join("amp").join("threads");
    collect_files(&root, |p| {
        p.file_name()
            .and_then(|s| s.to_str())
            .is_some_and(|name| name.starts_with("T-") && name.ends_with(".json"))
    })
    .into_iter()
    .flat_map(|p| parse_amp_file(&p))
    .collect()
}

fn parse_amp_file(path: &Path) -> Vec<UsageMessage> {
    let Ok(data) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let Ok(value) = serde_json::from_str::<Value>(&data) else {
        return Vec::new();
    };
    let fallback_ts = file_modified_timestamp_ms(path);
    let thread_created = i64_value(value.get("created")).unwrap_or(fallback_ts);
    let thread_id = string_value(value.get("id")).unwrap_or_else(|| {
        path.file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("amp")
            .to_string()
    });
    if let Some(events) = value
        .get("usageLedger")
        .and_then(|l| l.get("events"))
        .and_then(Value::as_array)
    {
        let mut out = Vec::new();
        for (index, event) in events.iter().enumerate() {
            let Some(model) = string_value(event.get("model")) else {
                continue;
            };
            let provider = infer_provider(&model).to_string();
            let tokens_value = event.get("tokens").unwrap_or(&Value::Null);
            let ts = timestamp_ms_from_value(event.get("timestamp")).unwrap_or(thread_created);
            let mut msg = UsageMessage::new(
                "amp",
                model,
                provider,
                ts,
                TokenBreakdown {
                    input: i64_value(tokens_value.get("input")).unwrap_or(0).max(0),
                    output: i64_value(tokens_value.get("output")).unwrap_or(0).max(0),
                    cache_read: i64_value(tokens_value.get("cacheReadInputTokens"))
                        .unwrap_or(0)
                        .max(0),
                    cache_write: i64_value(tokens_value.get("cacheCreationInputTokens"))
                        .unwrap_or(0)
                        .max(0),
                    reasoning: 0,
                },
                f64_value(event.get("credits")).unwrap_or(0.0),
            );
            msg.dedup_key = Some(format!("amp:{}:ledger:{}", thread_id, index));
            out.push(msg);
        }
        if !out.is_empty() {
            return out;
        }
    }
    value
        .get("messages")
        .and_then(Value::as_array)
        .map(|messages| {
            messages
                .iter()
                .filter(|m| m.get("role").and_then(Value::as_str) == Some("assistant"))
                .filter_map(|m| {
                    let usage = m.get("usage")?;
                    let model = string_value(usage.get("model"))?;
                    let provider = infer_provider(&model).to_string();
                    let message_id = i64_value(m.get("messageId")).unwrap_or(0);
                    let mut msg = UsageMessage::new(
                        "amp",
                        model,
                        provider,
                        thread_created.saturating_add(message_id.saturating_mul(1000)),
                        TokenBreakdown {
                            input: i64_value(usage.get("inputTokens")).unwrap_or(0).max(0),
                            output: i64_value(usage.get("outputTokens")).unwrap_or(0).max(0),
                            cache_read: i64_value(usage.get("cacheReadInputTokens"))
                                .unwrap_or(0)
                                .max(0),
                            cache_write: i64_value(usage.get("cacheCreationInputTokens"))
                                .unwrap_or(0)
                                .max(0),
                            reasoning: 0,
                        },
                        f64_value(usage.get("credits")).unwrap_or(0.0),
                    );
                    msg.dedup_key = Some(format!("amp:{}:message:{}", thread_id, message_id));
                    Some(msg)
                })
                .collect()
        })
        .unwrap_or_default()
}

fn parse_droid() -> Vec<UsageMessage> {
    let Some(home) = home_dir() else {
        return Vec::new();
    };
    collect_files(&home.join(".factory").join("sessions"), |p| {
        p.file_name()
            .and_then(|s| s.to_str())
            .is_some_and(|name| name.ends_with(".settings.json"))
    })
    .into_iter()
    .filter_map(|p| parse_droid_file(&p))
    .collect()
}

fn parse_droid_file(path: &Path) -> Option<UsageMessage> {
    let data = fs::read_to_string(path).ok()?;
    let value: Value = serde_json::from_str(&data).ok()?;
    let usage = value.get("tokenUsage")?;
    let provider = string_value(value.get("providerLock")).unwrap_or_else(|| {
        string_value(value.get("model"))
            .map(|m| infer_provider(&m).to_string())
            .unwrap_or_else(|| "unknown".to_string())
    });
    let model = string_value(value.get("model"))
        .map(|m| normalize_droid_model(&m))
        .unwrap_or_else(|| default_model_for_provider(&provider));
    let ts = timestamp_ms_from_value(value.get("providerLockTimestamp"))
        .unwrap_or_else(|| file_modified_timestamp_ms(path));
    let mut msg = UsageMessage::new(
        "droid",
        model,
        provider,
        ts,
        TokenBreakdown {
            input: i64_value(usage.get("inputTokens")).unwrap_or(0).max(0),
            output: i64_value(usage.get("outputTokens")).unwrap_or(0).max(0),
            cache_read: i64_value(usage.get("cacheReadTokens")).unwrap_or(0).max(0),
            cache_write: i64_value(usage.get("cacheCreationTokens"))
                .unwrap_or(0)
                .max(0),
            reasoning: i64_value(usage.get("thinkingTokens")).unwrap_or(0).max(0),
        },
        0.0,
    );
    msg.dedup_key = path
        .file_stem()
        .and_then(|s| s.to_str())
        .map(|s| format!("droid:{}", s));
    Some(msg)
}

fn parse_hermes() -> Vec<UsageMessage> {
    let Some(path) = hermes_db_path() else {
        return Vec::new();
    };
    parse_hermes_db(&path)
}

/// Grok Build session parser.
///
/// Grok writes JSON-RPC session updates under
/// `$GROK_HOME/sessions/<urlencoded-workspace>/<session-id>/updates.jsonl`
/// (default home: `~/.grok`). Logs expose a cumulative `totalTokens`
/// counter without a stable input/output split, so per-turn positive
/// total-token deltas are recorded as input tokens. Sibling
/// `signals.json` may report totals that include compaction history;
/// any remainder is reconciled as a separate message so compacted
/// sessions are not under-counted.
fn parse_grok() -> Vec<UsageMessage> {
    let Some(home) = grok_home() else {
        return Vec::new();
    };
    let sessions = home.join("sessions");
    if !sessions.is_dir() {
        return Vec::new();
    }
    collect_files(&sessions, |p| {
        p.file_name()
            .and_then(|s| s.to_str())
            .is_some_and(|name| name == "updates.jsonl")
    })
    .into_iter()
    .flat_map(|p| parse_grok_updates_file(&p))
    .collect()
}

fn grok_home() -> Option<PathBuf> {
    if let Some(home) = std::env::var_os("GROK_HOME") {
        let p = PathBuf::from(home);
        if p.is_dir() {
            return Some(p);
        }
    }
    let p = home_dir()?.join(".grok");
    p.is_dir().then_some(p)
}

const GROK_UNKNOWN_MODEL: &str = "grok-unknown";

#[derive(Debug, Clone)]
struct GrokMetadata {
    session_id: String,
    /// Percent-encoded workspace directory name under `sessions/`
    /// (e.g. `%2FUsers%2F…`). Used in dedup keys so the same session id
    /// under different cwd roots does not collide globally.
    workspace_key: String,
    model_id: Option<String>,
    timestamp_ms: i64,
}

#[derive(Debug, Clone)]
struct GrokActiveTurn {
    baseline_total: i64,
    max_total: i64,
    timestamp_ms: i64,
    model_id: String,
    turn_index: usize,
}

impl GrokActiveTurn {
    fn new(baseline_total: i64, timestamp_ms: i64, model_id: String, turn_index: usize) -> Self {
        Self {
            baseline_total,
            max_total: baseline_total,
            timestamp_ms,
            model_id,
            turn_index,
        }
    }

    fn observe_total(&mut self, total: i64, timestamp_ms: i64) {
        if total > self.max_total {
            self.max_total = total;
            self.timestamp_ms = timestamp_ms;
        }
    }

    fn into_message(self, metadata: &GrokMetadata) -> Option<UsageMessage> {
        let token_delta = self.max_total.saturating_sub(self.baseline_total);
        if token_delta <= 0 {
            return None;
        }
        let model_id = if self.model_id.trim().is_empty() {
            GROK_UNKNOWN_MODEL.to_string()
        } else {
            self.model_id
        };
        let mut msg = UsageMessage::new(
            "grok",
            model_id,
            "xai",
            self.timestamp_ms,
            TokenBreakdown {
                input: token_delta,
                output: 0,
                cache_read: 0,
                cache_write: 0,
                reasoning: 0,
            },
            0.0,
        );
        msg.dedup_key = Some(format!(
            "grok:{}:{}:{}",
            metadata.workspace_key, metadata.session_id, self.turn_index
        ));
        Some(msg)
    }
}

fn parse_grok_updates_file(path: &Path) -> Vec<UsageMessage> {
    if path.file_name().and_then(|name| name.to_str()) != Some("updates.jsonl") {
        return Vec::new();
    }

    let metadata = read_grok_metadata(path);
    let file = match fs::File::open(path) {
        Ok(file) => file,
        Err(_) => return Vec::new(),
    };

    let mut messages = Vec::new();
    let mut current_model = metadata
        .model_id
        .clone()
        .unwrap_or_else(|| GROK_UNKNOWN_MODEL.to_string());
    let mut last_total: Option<i64> = None;
    let mut last_total_timestamp = metadata.timestamp_ms;
    let mut active_turn: Option<GrokActiveTurn> = None;
    let mut turn_index = 0usize;

    for line in BufReader::new(file).lines().map_while(Result::ok) {
        if line.trim().is_empty() {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };

        if let Some(model_id) = extract_grok_model_id(&value) {
            current_model = model_id;
            if let Some(turn) = active_turn.as_mut() {
                if turn.model_id == GROK_UNKNOWN_MODEL {
                    turn.model_id = current_model.clone();
                }
            }
        }

        let timestamp = extract_grok_timestamp_ms(&value).unwrap_or(metadata.timestamp_ms);
        if is_grok_user_message_chunk(&value) {
            if let Some(turn) = active_turn.take() {
                if let Some(message) = turn.into_message(&metadata) {
                    messages.push(message);
                }
            }
            active_turn = Some(GrokActiveTurn::new(
                last_total.unwrap_or(0),
                timestamp,
                current_model.clone(),
                turn_index,
            ));
            turn_index = turn_index.saturating_add(1);
        }

        let Some(total_tokens) = extract_grok_total_tokens(&value) else {
            continue;
        };
        if total_tokens < 0 {
            continue;
        }

        match last_total {
            Some(previous) if total_tokens < previous => {
                // Transient stream rewinds can dip below the high-water mark.
                // Keep last_total so recovering totals are not double-counted;
                // compaction remainder is reconciled via signals.json.
                continue;
            }
            Some(previous) if total_tokens == previous => {
                last_total_timestamp = timestamp;
            }
            Some(previous) => {
                if active_turn.is_none() {
                    active_turn = Some(GrokActiveTurn::new(
                        previous,
                        timestamp,
                        current_model.clone(),
                        turn_index,
                    ));
                    turn_index = turn_index.saturating_add(1);
                }
                if let Some(turn) = active_turn.as_mut() {
                    turn.observe_total(total_tokens, timestamp);
                }
                last_total_timestamp = timestamp;
                last_total = Some(total_tokens);
            }
            None => {
                if let Some(turn) = active_turn.as_mut() {
                    turn.observe_total(total_tokens, timestamp);
                }
                last_total_timestamp = timestamp;
                last_total = Some(total_tokens);
            }
        }
    }

    if let Some(turn) = active_turn {
        if let Some(message) = turn.into_message(&metadata) {
            messages.push(message);
        }
    }

    if messages.is_empty() {
        if let Some(total_tokens) = last_total.filter(|tokens| *tokens > 0) {
            let aggregate_turn = GrokActiveTurn {
                baseline_total: 0,
                max_total: total_tokens,
                timestamp_ms: last_total_timestamp,
                model_id: current_model.clone(),
                turn_index: 0,
            };
            if let Some(message) = aggregate_turn.into_message(&metadata) {
                messages.push(message);
            }
        }
    }

    append_grok_signals_reconciliation(path, &metadata, &mut messages, &current_model);
    messages
}

fn read_grok_metadata(path: &Path) -> GrokMetadata {
    let session_dir = path.parent();
    let session_id = session_dir
        .and_then(|dir| dir.file_name())
        .and_then(|name| name.to_str())
        .filter(|id| !id.trim().is_empty())
        .unwrap_or("unknown")
        .to_string();
    // sessions/<urlencoded-workspace>/<session-id>/updates.jsonl
    let workspace_key = session_dir
        .and_then(|dir| dir.parent())
        .and_then(|workspace_dir| workspace_dir.file_name())
        .and_then(|name| name.to_str())
        .filter(|id| !id.trim().is_empty())
        .unwrap_or("unknown")
        .to_string();

    let fallback_timestamp = file_modified_timestamp_ms(path);
    let mut metadata = GrokMetadata {
        session_id,
        workspace_key,
        model_id: None,
        timestamp_ms: fallback_timestamp,
    };

    if let Some(summary_path) = grok_sibling(path, "summary.json") {
        read_grok_summary_metadata(&summary_path, &mut metadata);
    }
    // events.jsonl is a compact session journal; use it only as a fallback
    // when summary is missing model/session identity (tokscale parity).
    if metadata.model_id.is_none() || metadata.session_id == "unknown" {
        if let Some(events_path) = grok_sibling(path, "events.jsonl") {
            read_grok_events_metadata(&events_path, &mut metadata);
        }
    }
    if let Some(signals_path) = grok_sibling(path, "signals.json") {
        read_grok_signals_metadata(&signals_path, &mut metadata);
    }

    metadata
}

fn read_grok_events_metadata(path: &Path, metadata: &mut GrokMetadata) {
    let Ok(file) = fs::File::open(path) else {
        return;
    };
    for line in BufReader::new(file).lines().map_while(Result::ok).take(500) {
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if metadata.model_id.is_none() {
            metadata.model_id = string_value(value.get("model_id"))
                .or_else(|| string_value(value.get("modelId")));
        }
        if metadata.session_id == "unknown" {
            if let Some(session_id) = string_value(value.get("session_id"))
                .or_else(|| string_value(value.get("sessionId")))
            {
                metadata.session_id = session_id;
            }
        }
        if let Some(timestamp) = timestamp_ms_from_value(value.get("ts"))
            .or_else(|| timestamp_ms_from_value(value.get("timestamp")))
        {
            metadata.timestamp_ms = timestamp;
        }
        if metadata.model_id.is_some() && metadata.session_id != "unknown" {
            break;
        }
    }
}

fn read_grok_summary_metadata(path: &Path, metadata: &mut GrokMetadata) {
    let Ok(data) = fs::read_to_string(path) else {
        return;
    };
    let Ok(value) = serde_json::from_str::<Value>(&data) else {
        return;
    };

    if metadata.model_id.is_none() {
        metadata.model_id = string_value(value.get("current_model_id"))
            .or_else(|| string_value(value.get("model_id")));
    }
    if let Some(timestamp) = timestamp_ms_from_value(value.get("updated_at"))
        .or_else(|| timestamp_ms_from_value(value.get("created_at")))
        .or_else(|| timestamp_ms_from_value(value.get("last_active_at")))
    {
        metadata.timestamp_ms = timestamp;
    }
}

fn read_grok_signals_metadata(path: &Path, metadata: &mut GrokMetadata) {
    let Ok(data) = fs::read_to_string(path) else {
        return;
    };
    let Ok(value) = serde_json::from_str::<Value>(&data) else {
        return;
    };
    if metadata.model_id.is_none() {
        metadata.model_id = model_id_from_grok_signals(&value);
    }
}

fn model_id_from_grok_signals(value: &Value) -> Option<String> {
    string_value(value.get("primaryModelId")).or_else(|| {
        value
            .get("modelsUsed")
            .and_then(|models| models.as_array())
            .and_then(|models| models.first())
            .and_then(|model| string_value(Some(model)))
    })
}

fn non_negative_i64(value: Option<&Value>) -> i64 {
    i64_value(value).unwrap_or(0).max(0)
}

fn effective_total_from_grok_signals(value: &Value) -> i64 {
    let before = non_negative_i64(value.get("totalTokensBeforeCompaction"));
    let total = non_negative_i64(value.get("totalTokens"));
    match value.get("contextTokensUsed") {
        None => before.saturating_add(total),
        Some(ctx) => total.max(before.saturating_add(non_negative_i64(Some(ctx)))),
    }
}

fn append_grok_signals_reconciliation(
    updates_path: &Path,
    metadata: &GrokMetadata,
    messages: &mut Vec<UsageMessage>,
    fallback_model: &str,
) {
    let Some(signals_path) = grok_sibling(updates_path, "signals.json") else {
        return;
    };
    let Ok(data) = fs::read_to_string(&signals_path) else {
        return;
    };
    let Ok(value) = serde_json::from_str::<Value>(&data) else {
        return;
    };

    let signals_total = effective_total_from_grok_signals(&value);
    if signals_total <= 0 {
        return;
    }

    let updates_total: i64 = messages.iter().map(|message| message.tokens.input).sum();
    let extra = signals_total.saturating_sub(updates_total);
    if extra <= 0 {
        return;
    }

    let model_id = model_id_from_grok_signals(&value)
        .filter(|model| !model.trim().is_empty())
        .or_else(|| metadata.model_id.clone())
        .unwrap_or_else(|| fallback_model.to_string());
    // Anchor the reconciliation delta to the last recorded update activity
    // rather than signals.json mtime, so live-session rewrites do not migrate
    // multi-million-token extras onto a new day on each rescan.
    let timestamp = messages
        .iter()
        .map(|message| message.timestamp_ms)
        .max()
        .unwrap_or(metadata.timestamp_ms);

    let mut msg = UsageMessage::new(
        "grok",
        model_id,
        "xai",
        timestamp,
        TokenBreakdown {
            input: extra,
            output: 0,
            cache_read: 0,
            cache_write: 0,
            reasoning: 0,
        },
        0.0,
    );
    msg.dedup_key = Some(format!(
        "grok:{}:{}:signals",
        metadata.workspace_key, metadata.session_id
    ));
    messages.push(msg);
}

fn grok_sibling(path: &Path, file_name: &str) -> Option<PathBuf> {
    Some(path.parent()?.join(file_name))
}

fn json_path<'a>(value: &'a Value, path: &[&str]) -> Option<&'a Value> {
    path.iter()
        .try_fold(value, |current, key| current.get(*key))
}

fn extract_grok_model_id(value: &Value) -> Option<String> {
    for path in [
        &["params", "update", "content", "_meta", "modelId"][..],
        &["params", "update", "_meta", "modelId"][..],
        &["params", "_meta", "modelId"][..],
        &["params", "modelId"][..],
        &["model_id"][..],
        &["modelId"][..],
        &["model"][..],
    ] {
        if let Some(model_id) = string_value(json_path(value, path)) {
            if !model_id.trim().is_empty() {
                return Some(model_id);
            }
        }
    }
    None
}

fn extract_grok_total_tokens(value: &Value) -> Option<i64> {
    for path in [
        &["params", "_meta", "totalTokens"][..],
        &["params", "update", "_meta", "totalTokens"][..],
        &["params", "update", "totalTokens"][..],
        &["params", "totalTokens"][..],
        &["usage", "totalTokens"][..],
        &["totalTokens"][..],
    ] {
        if let Some(total) = i64_value(json_path(value, path)) {
            return Some(total);
        }
    }
    None
}

fn extract_grok_timestamp_ms(value: &Value) -> Option<i64> {
    for path in [
        &["params", "_meta", "agentTimestampMs"][..],
        &["params", "update", "_meta", "agentTimestampMs"][..],
        &["params", "timestamp"][..],
        &["timestamp"][..],
        &["ts"][..],
    ] {
        if let Some(timestamp) = timestamp_ms_from_value(json_path(value, path)) {
            return Some(timestamp);
        }
    }
    None
}

fn is_grok_user_message_chunk(value: &Value) -> bool {
    json_path(value, &["params", "update", "sessionUpdate"]).and_then(|v| v.as_str())
        == Some("user_message_chunk")
}

fn parse_hermes_db(path: &Path) -> Vec<UsageMessage> {
    let conn = match Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };

    let columns = sqlite_table_columns(&conn, "sessions");
    let reasoning_expr = sqlite_column_or(&columns, "reasoning_tokens", "0");
    let provider_expr = sqlite_column_or(&columns, "billing_provider", "''");
    let started_expr = sqlite_column_or(&columns, "started_at", "0");
    let ended_expr = sqlite_column_or(&columns, "ended_at", "0");
    let actual_cost_expr = sqlite_column_or(&columns, "actual_cost_usd", "0");
    let estimated_cost_expr = sqlite_column_or(&columns, "estimated_cost_usd", "0");
    let message_count_expr = sqlite_column_or(&columns, "message_count", "1");
    let order_expr = if columns.contains("started_at") {
        "started_at, id"
    } else {
        "id"
    };

    let query = format!(
        r#"
        SELECT id, model,
            COALESCE(input_tokens, 0),
            COALESCE(output_tokens, 0),
            COALESCE(cache_read_tokens, 0),
            COALESCE(cache_write_tokens, 0),
            {reasoning_expr},
            {provider_expr},
            {started_expr},
            {ended_expr},
            {actual_cost_expr},
            {estimated_cost_expr},
            {message_count_expr}
        FROM sessions
        WHERE model IS NOT NULL AND TRIM(model) != ''
        ORDER BY {order_expr}
        "#
    );

    let mut stmt = match conn.prepare(&query) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let rows = match stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)?,
            row.get::<_, i64>(3)?,
            row.get::<_, i64>(4)?,
            row.get::<_, i64>(5)?,
            row.get::<_, i64>(6)?,
            row.get::<_, String>(7)?,
            row.get::<_, f64>(8)?,
            row.get::<_, f64>(9)?,
            row.get::<_, f64>(10)?,
            row.get::<_, f64>(11)?,
            row.get::<_, i32>(12)?,
        ))
    }) {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };
    let fallback_ts = file_modified_timestamp_ms(path);
    let mut out = Vec::new();
    for row in rows.flatten() {
        let (
            id,
            model,
            input,
            output,
            cache_read,
            cache_write,
            reasoning,
            billing_provider,
            started_at,
            ended_at,
            actual_cost,
            estimated_cost,
            message_count,
        ) = row;
        let provider = hermes_provider(&billing_provider, &model);
        let ts = hermes_timestamp_ms(started_at, ended_at, fallback_ts);
        let cost = if actual_cost > 0.0 {
            actual_cost
        } else if estimated_cost > 0.0 {
            estimated_cost
        } else {
            0.0
        };
        let mut msg = UsageMessage::new(
            "hermes",
            model,
            provider,
            ts,
            TokenBreakdown {
                input: input.max(0),
                output: output.max(0),
                cache_read: cache_read.max(0),
                cache_write: cache_write.max(0),
                reasoning: reasoning.max(0),
            },
            cost,
        );
        msg.messages = message_count.max(1);
        msg.dedup_key = Some(format!("hermes:{}", id));
        out.push(msg);
    }
    out
}

fn sqlite_table_columns(conn: &Connection, table: &str) -> HashSet<String> {
    let mut columns = HashSet::new();
    let Ok(mut stmt) = conn.prepare(&format!("PRAGMA table_info({})", table)) else {
        return columns;
    };
    let Ok(rows) = stmt.query_map([], |row| row.get::<_, String>(1)) else {
        return columns;
    };
    for name in rows.flatten() {
        columns.insert(name);
    }
    columns
}

fn sqlite_column_or(columns: &HashSet<String>, name: &str, fallback: &str) -> String {
    if columns.contains(name) {
        format!("COALESCE({}, {})", name, fallback)
    } else {
        fallback.to_string()
    }
}

fn hermes_provider(billing_provider: &str, model: &str) -> String {
    let provider = billing_provider.trim().to_lowercase();
    if provider.contains("anthropic") {
        "anthropic".to_string()
    } else if provider.contains("openai") {
        "openai".to_string()
    } else if provider.contains("google") || provider.contains("gemini") {
        "google".to_string()
    } else if provider.contains("xai") || provider.contains("grok") {
        "xai".to_string()
    } else if provider.contains("deepseek") {
        "deepseek".to_string()
    } else if provider.contains("meta") || provider.contains("llama") {
        "meta".to_string()
    } else if provider.is_empty() {
        infer_provider(model).to_string()
    } else {
        provider
    }
}

fn hermes_timestamp_ms(started_at: f64, ended_at: f64, fallback_ts: i64) -> i64 {
    normalize_epoch_ms_f64(started_at)
        .or_else(|| normalize_epoch_ms_f64(ended_at))
        .unwrap_or(fallback_ts)
}

fn collect_files(root: &Path, pred: impl Fn(&Path) -> bool + Copy) -> Vec<PathBuf> {
    let mut out = Vec::new();
    collect_files_inner(root, pred, &mut out);
    out.sort();
    out
}

fn collect_files_inner(root: &Path, pred: impl Fn(&Path) -> bool + Copy, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() {
            collect_files_inner(&path, pred, out);
        } else if file_type.is_file() && pred(&path) {
            out.push(path);
        }
    }
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

fn xdg_data_home(home: &Path) -> PathBuf {
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".local").join("share"))
}

/// Codex homes that Orca manages under its own data dir. Orca stores each
/// runtime home as a subdirectory of `orca/codex-runtime-home/` (today just
/// `home`), so scan every immediate child that actually holds a `sessions`
/// folder rather than hardcoding the single known name.
fn orca_codex_homes(home: &Path) -> Vec<PathBuf> {
    let mut homes = Vec::new();
    let mut data_dirs = vec![
        // macOS
        home.join("Library")
            .join("Application Support")
            .join("orca"),
        // Linux (XDG)
        xdg_data_home(home).join("orca"),
    ];
    // Windows / explicit override
    if let Some(appdata) = std::env::var_os("APPDATA") {
        data_dirs.push(PathBuf::from(appdata).join("orca"));
    }

    for data_dir in data_dirs {
        let runtime_root = data_dir.join("codex-runtime-home");
        let Ok(entries) = fs::read_dir(&runtime_root) else {
            continue;
        };
        for entry in entries.flatten() {
            let candidate = entry.path();
            if candidate.join("sessions").is_dir()
                || candidate.join("archived_sessions").is_dir()
            {
                homes.push(candidate);
            }
        }
    }
    homes
}

fn hermes_db_path() -> Option<PathBuf> {
    if let Ok(home) = std::env::var("HERMES_HOME") {
        let p = PathBuf::from(home).join("state.db");
        if p.is_file() {
            return Some(p);
        }
    }
    let p = home_dir()?.join(".hermes").join("state.db");
    p.is_file().then_some(p)
}

fn file_modified_timestamp_ms(path: &Path) -> i64 {
    fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or_else(now_ms)
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn date_from_timestamp_ms(timestamp_ms: i64) -> String {
    Local
        .timestamp_millis_opt(timestamp_ms)
        .single()
        .or_else(|| Local.timestamp_millis_opt(timestamp_ms).earliest())
        .unwrap_or_else(Local::now)
        .format("%Y-%m-%d")
        .to_string()
}

fn timestamp_ms_from_value(value: Option<&Value>) -> Option<i64> {
    let value = value?;
    if let Some(s) = value.as_str() {
        if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(s) {
            return Some(dt.timestamp_millis());
        }
        return s.parse::<i64>().ok().map(normalize_epoch_ms);
    }
    if let Some(i) = value.as_i64() {
        return Some(normalize_epoch_ms(i));
    }
    if let Some(f) = value.as_f64() {
        if f.is_finite() {
            return Some(normalize_epoch_ms(f as i64));
        }
    }
    None
}

fn normalize_epoch_ms(raw: i64) -> i64 {
    match raw.abs() {
        100_000_000_000_000_000.. => raw / 1_000_000,
        100_000_000_000_000.. => raw / 1_000,
        100_000_000_000.. => raw,
        _ => raw.saturating_mul(1000),
    }
}

fn normalize_epoch_ms_f64(raw: f64) -> Option<i64> {
    if !raw.is_finite() || raw <= 0.0 {
        return None;
    }
    let abs = raw.abs();
    let millis = if abs >= 100_000_000_000_000_000.0 {
        raw / 1_000_000.0
    } else if abs >= 100_000_000_000_000.0 {
        raw / 1_000.0
    } else if abs >= 100_000_000_000.0 {
        raw
    } else {
        raw * 1000.0
    };
    Some(millis.round() as i64)
}

fn parse_date_to_timestamp_ms(date: &str) -> i64 {
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(date) {
        return dt.timestamp_millis();
    }
    if let Ok(date) = chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d") {
        if let Some(dt) = date.and_hms_opt(12, 0, 0) {
            return Utc.from_utc_datetime(&dt).timestamp_millis();
        }
    }
    0
}

fn string_value(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(s) if !s.trim().is_empty() => Some(s.trim().to_string()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

fn i64_value(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(n) => n
            .as_i64()
            .or_else(|| n.as_u64().map(|v| v as i64))
            .or_else(|| n.as_f64().map(|v| v as i64)),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

fn f64_value(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

fn attr_i64(attrs: &Value, names: &[&str]) -> i64 {
    names
        .iter()
        .find_map(|name| i64_value(attrs.get(*name)))
        .unwrap_or(0)
}

fn attr_string(attrs: &Value, names: &[&str]) -> Option<String> {
    names.iter().find_map(|name| string_value(attrs.get(*name)))
}

fn copilot_timestamp_ms(value: &Value) -> Option<i64> {
    for key in ["endTime", "startTime", "hrTime", "_hrTime", "time"] {
        if let Some(parts) = value.get(key).and_then(Value::as_array) {
            let sec = parts.first().and_then(|v| i64_value(Some(v)))?;
            let nanos = parts.get(1).and_then(|v| i64_value(Some(v))).unwrap_or(0);
            return Some(sec.saturating_mul(1000) + nanos / 1_000_000);
        }
    }
    timestamp_ms_from_value(value.get("timestamp"))
        .or_else(|| timestamp_ms_from_value(value.get("observedTimestamp")))
        .or_else(|| {
            i64_value(value.get("timeUnixNano")).and_then(|n| (n > 0).then_some(n / 1_000_000))
        })
}

fn parse_csv_line(line: &str) -> Vec<&str> {
    let mut fields = Vec::new();
    let mut start = 0;
    let mut in_quotes = false;
    let chars: Vec<(usize, char)> = line.char_indices().collect();
    for (i, c) in chars {
        if c == '"' {
            in_quotes = !in_quotes;
        } else if c == ',' && !in_quotes {
            fields.push(&line[start..i]);
            start = i + 1;
        }
    }
    fields.push(&line[start..]);
    fields
}

fn clean_csv(value: &str) -> &str {
    value.trim().trim_matches('"')
}

fn parse_cost(value: &str) -> f64 {
    let cleaned = value.replace(['$', ','], "");
    let trimmed = cleaned.trim();
    if trimmed.is_empty()
        || trimmed.eq_ignore_ascii_case("nan")
        || trimmed.eq_ignore_ascii_case("included")
        || trimmed == "-"
    {
        0.0
    } else {
        trimmed.parse().unwrap_or(0.0)
    }
}

fn normalize_model_id(id: &str) -> String {
    id.trim().to_lowercase()
}

fn normalize_droid_model(model: &str) -> String {
    let without_prefix = model.strip_prefix("custom:").unwrap_or(model);
    let mut out = String::with_capacity(without_prefix.len());
    let mut in_bracket = false;
    for c in without_prefix.chars() {
        match c {
            '[' => in_bracket = true,
            ']' => in_bracket = false,
            _ if in_bracket => {}
            '.' | '_' | ' ' => out.push('-'),
            c => out.push(c.to_ascii_lowercase()),
        }
    }
    while out.contains("--") {
        out = out.replace("--", "-");
    }
    out.trim_matches('-').to_string()
}

fn infer_provider(model: &str) -> &'static str {
    let model = model.to_lowercase();
    if model.contains("claude")
        || model.contains("sonnet")
        || model.contains("opus")
        || model.contains("haiku")
        || model.contains("fable")
    {
        "anthropic"
    } else if model.starts_with("gpt-")
        || model.starts_with("o1")
        || model.starts_with("o3")
        || model.starts_with("o4")
    {
        "openai"
    } else if model.contains("gemini") {
        "google"
    } else if model.contains("grok") {
        "xai"
    } else if model.contains("deepseek") {
        "deepseek"
    } else if model.contains("llama") {
        "meta"
    } else {
        "unknown"
    }
}

fn default_model_for_provider(provider: &str) -> String {
    match provider {
        "anthropic" => "claude-unknown",
        "openai" => "gpt-unknown",
        "google" => "gemini-unknown",
        "xai" => "grok-unknown",
        _ => "unknown",
    }
    .to_string()
}

#[derive(Clone, Copy, Debug)]
struct Price {
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
    input_above_200k: Option<f64>,
    output_above_200k: Option<f64>,
    cache_read_above_200k: Option<f64>,
    cache_write_above_200k: Option<f64>,
    input_above_272k: Option<f64>,
    output_above_272k: Option<f64>,
    cache_read_above_272k: Option<f64>,
}

impl Price {
    fn new(input: f64, output: f64, cache_read: f64, cache_write: f64) -> Self {
        Self {
            input,
            output,
            cache_read,
            cache_write,
            input_above_200k: None,
            output_above_200k: None,
            cache_read_above_200k: None,
            cache_write_above_200k: None,
            input_above_272k: None,
            output_above_272k: None,
            cache_read_above_272k: None,
        }
    }

    fn above_200k(mut self, input: f64, output: f64, cache_read: f64, cache_write: f64) -> Self {
        self.input_above_200k = Some(input);
        self.output_above_200k = Some(output);
        self.cache_read_above_200k = Some(cache_read);
        self.cache_write_above_200k = Some(cache_write);
        self
    }

    fn above_272k(mut self, input: f64, output: f64, cache_read: f64) -> Self {
        self.input_above_272k = Some(input);
        self.output_above_272k = Some(output);
        self.cache_read_above_272k = Some(cache_read);
        self
    }
}

fn estimate_cost(model: &str, provider: &str, tokens: &TokenBreakdown) -> f64 {
    let price = bundled_price(model, provider);
    let input = tiered_cost_per_million(
        tokens.input,
        price.input,
        &[
            (200_000.0, price.input_above_200k),
            (272_000.0, price.input_above_272k),
        ],
    );
    let output = tiered_cost_per_million(
        tokens.output.max(0).saturating_add(tokens.reasoning.max(0)),
        price.output,
        &[
            (200_000.0, price.output_above_200k),
            (272_000.0, price.output_above_272k),
        ],
    );
    let cache_read = tiered_cost_per_million(
        tokens.cache_read,
        price.cache_read,
        &[
            (200_000.0, price.cache_read_above_200k),
            (272_000.0, price.cache_read_above_272k),
        ],
    );
    let cache_write = tiered_cost_per_million(
        tokens.cache_write,
        price.cache_write,
        &[(200_000.0, price.cache_write_above_200k)],
    );
    (input + output + cache_read + cache_write) / 1_000_000.0
}

fn tiered_cost_per_million(tokens: i64, base_price: f64, tiers: &[(f64, Option<f64>)]) -> f64 {
    let tokens = tokens.max(0) as f64;
    let mut cost = 0.0;
    let mut lower_bound = 0.0;
    let mut active_price = base_price.max(0.0);

    for (threshold, tier_price) in tiers {
        let Some(tier_price) = tier_price.filter(|v| v.is_finite() && *v >= 0.0) else {
            continue;
        };
        if !threshold.is_finite() || *threshold <= lower_bound {
            continue;
        }
        if tokens <= *threshold {
            return cost + (tokens - lower_bound).max(0.0) * active_price;
        }
        cost += (*threshold - lower_bound) * active_price;
        lower_bound = *threshold;
        active_price = tier_price;
    }

    cost + (tokens - lower_bound).max(0.0) * active_price
}

fn bundled_price(model: &str, provider: &str) -> Price {
    // Snapshot from LiteLLM/models.dev/OpenRouter-style pricing data; Tokcat
    // keeps this bundled to avoid adding network reads to local usage scans.
    let m = model.to_lowercase();
    let normalized = m.replace(['.', '_', ' '], "-");
    let terminal = normalized.rsplit('/').next().unwrap_or(&normalized);

    if normalized.contains("fable") {
        return Price::new(10.0, 50.0, 1.0, 12.5);
    }
    if normalized.contains("opus-4-6-fast") || normalized.contains("opus-4-7-fast") {
        return Price::new(30.0, 150.0, 3.0, 37.5);
    }
    if normalized.contains("opus-4-8-fast") {
        return Price::new(10.0, 50.0, 1.0, 12.5);
    }
    if normalized.contains("opus-4-5")
        || normalized.contains("opus-4-6")
        || normalized.contains("opus-4-7")
        || normalized.contains("opus-4-8")
    {
        return Price::new(5.0, 25.0, 0.5, 6.25);
    }
    if m.contains("opus") {
        return Price::new(15.0, 75.0, 1.5, 18.75);
    }
    if normalized.contains("haiku-4-5") {
        return Price::new(1.0, 5.0, 0.1, 1.25);
    }
    if m.contains("haiku") {
        return Price::new(0.8, 4.0, 0.08, 1.0);
    }
    if normalized.contains("sonnet-4") {
        return Price::new(3.0, 15.0, 0.3, 3.75).above_200k(6.0, 22.5, 0.6, 7.5);
    }
    if normalized.contains("sonnet-3-5") || normalized.contains("3-5-sonnet") {
        return Price::new(3.0, 15.0, 0.3, 3.75).above_200k(6.0, 30.0, 0.6, 7.5);
    }
    if m.contains("sonnet") || m.contains("claude") {
        return Price::new(3.0, 15.0, 0.3, 3.75);
    }
    if terminal.contains("gpt-4o-2024-05-13") {
        return Price::new(5.0, 15.0, 0.0, 0.0);
    }
    if terminal.contains("gpt-4o-mini") {
        return Price::new(0.15, 0.6, 0.075, 0.0);
    }
    if m.contains("gpt-4o") {
        return Price::new(2.5, 10.0, 1.25, 0.0);
    }
    if terminal.contains("gpt-5-5-pro") || terminal.contains("gpt-5-4-pro") {
        return Price::new(30.0, 180.0, 0.0, 0.0).above_272k(60.0, 270.0, 0.0);
    }
    if terminal.contains("gpt-5-2-pro") {
        return Price::new(21.0, 168.0, 0.0, 0.0);
    }
    if terminal.starts_with("gpt-5-pro") {
        return Price::new(15.0, 120.0, 0.0, 0.0);
    }
    if terminal.contains("gpt-5-4-mini") {
        return Price::new(0.75, 4.5, 0.075, 0.0);
    }
    if terminal.contains("gpt-5-4-nano") {
        return Price::new(0.2, 1.25, 0.02, 0.0);
    }
    if terminal.starts_with("gpt-5-5") || terminal.contains("gpt-5-5-codex") {
        return Price::new(5.0, 30.0, 0.5, 0.0).above_272k(10.0, 45.0, 1.0);
    }
    if terminal.starts_with("gpt-5-4") || terminal.contains("gpt-5-4-codex") {
        return Price::new(2.5, 15.0, 0.25, 0.0).above_272k(5.0, 22.5, 0.5);
    }
    if terminal.starts_with("gpt-5-3") || terminal.contains("gpt-5-3-codex") {
        return Price::new(1.75, 14.0, 0.175, 0.0);
    }
    if terminal.starts_with("gpt-5-2") || terminal.contains("gpt-5-2-codex") {
        return Price::new(1.75, 14.0, 0.175, 0.0);
    }
    if terminal.contains("gpt-5-1-codex-mini") || terminal.starts_with("gpt-5-mini") {
        return Price::new(0.25, 2.0, 0.025, 0.0);
    }
    if terminal.starts_with("gpt-5-nano") {
        return Price::new(0.05, 0.4, 0.005, 0.0);
    }
    if terminal.starts_with("gpt-5") || terminal.contains("codex") || m.contains("codex") {
        return Price::new(1.25, 10.0, 0.125, 0.0);
    }
    if terminal.starts_with("o3-pro") {
        return Price::new(20.0, 80.0, 0.0, 0.0);
    }
    if terminal.starts_with("o3-mini") {
        return Price::new(1.1, 4.4, 0.55, 0.0);
    }
    if terminal.starts_with("o3-deep-research") {
        return Price::new(10.0, 40.0, 2.5, 0.0);
    }
    if terminal.starts_with("o3") {
        return Price::new(2.0, 8.0, 0.5, 0.0);
    }
    if terminal.starts_with("o4-mini-deep-research") {
        return Price::new(2.0, 8.0, 0.5, 0.0);
    }
    if terminal.starts_with("o4-mini") {
        return Price::new(1.1, 4.4, 0.275, 0.0);
    }
    if terminal.starts_with("o4") {
        return Price::new(2.0, 8.0, 0.5, 0.0);
    }
    if normalized.contains("glm-4-7-flashx") {
        return Price::new(0.07, 0.4, 0.01, 0.0);
    }
    if normalized.contains("glm-4-7") {
        return Price::new(0.6, 2.2, 0.11, 0.0);
    }
    if normalized.contains("kimi-k2-5") {
        return Price::new(0.6, 3.0, 0.1, 0.0);
    }
    // Grok Build sometimes prefixes Composer ids as `grok-composer-*`.
    let composer_id = terminal.strip_prefix("grok-").unwrap_or(terminal);
    if composer_id == "composer-1" {
        return Price::new(1.25, 10.0, 0.125, 0.0);
    }
    if composer_id == "composer-1-5" {
        return Price::new(3.5, 17.5, 0.35, 0.0);
    }
    if composer_id == "composer-2" || composer_id == "composer-2-5" {
        return Price::new(0.5, 2.5, 0.2, 0.0);
    }
    if composer_id == "composer-2-fast" || composer_id == "composer-2-5-fast" {
        return Price::new(1.5, 7.5, 0.35, 0.0);
    }
    if normalized.contains("gemini-3-5-flash") {
        return Price::new(1.5, 9.0, 0.15, 0.0);
    }
    if normalized.contains("gemini-3-1-flash-lite") {
        return Price::new(0.25, 1.5, 0.025, 0.0);
    }
    if normalized.contains("gemini-3-1-pro") || normalized.contains("gemini-3-pro") {
        return Price::new(2.0, 12.0, 0.2, 0.0).above_200k(4.0, 18.0, 0.4, 0.0);
    }
    if normalized.contains("gemini-3-flash") {
        return Price::new(0.5, 3.0, 0.05, 0.0);
    }
    if normalized.contains("gemini-2-5-flash-lite") {
        return Price::new(0.1, 0.4, 0.01, 0.0);
    }
    if normalized.contains("gemini-2-5-flash") {
        return Price::new(0.3, 2.5, 0.03, 0.0);
    }
    if normalized.contains("gemini-2-0-flash-lite") {
        return Price::new(0.075, 0.3, 0.0, 0.0);
    }
    if normalized.contains("gemini-2-0-flash") {
        return Price::new(0.1, 0.4, 0.025, 0.0);
    }
    if normalized.contains("gemini-2-5-pro") {
        return Price::new(1.25, 10.0, 0.125, 0.0).above_200k(2.5, 15.0, 0.25, 0.0);
    }
    if normalized.contains("gemini-flash-lite-latest") {
        return Price::new(0.1, 0.4, 0.025, 0.0);
    }
    if normalized.contains("gemini-flash-latest") {
        return Price::new(0.3, 2.5, 0.075, 0.0);
    }
    if m.contains("gemini") && m.contains("flash") {
        return Price::new(0.3, 2.5, 0.075, 0.0);
    }
    if m.contains("gemini") {
        return Price::new(1.25, 10.0, 0.125, 0.0);
    }
    // xAI Grok family — API list prices (per 1M tokens). SuperGrok /
    // subscription usage still gets an estimated API-equivalent cost so
    // multi-client dashboards stay comparable.
    if normalized.contains("grok-4-5") || terminal.contains("grok-4.5") {
        return Price::new(2.0, 6.0, 0.5, 0.0);
    }
    if normalized.contains("grok-4-3") || terminal.contains("grok-4.3") {
        return Price::new(1.25, 2.5, 0.2, 0.0);
    }
    if normalized.contains("grok-4-1-fast")
        || terminal.contains("grok-4.1-fast")
        || normalized.contains("grok-4-1")
    {
        return Price::new(0.2, 0.5, 0.05, 0.0);
    }
    if normalized.contains("grok-4") || terminal.starts_with("grok-4") {
        return Price::new(3.0, 15.0, 0.75, 0.0);
    }
    if normalized.contains("grok-3-mini") || terminal.contains("grok-3-mini") {
        return Price::new(0.3, 0.5, 0.075, 0.0);
    }
    if normalized.contains("grok-3") || terminal.starts_with("grok-3") {
        return Price::new(3.0, 15.0, 0.75, 0.0);
    }
    if m.contains("grok") {
        return Price::new(2.0, 6.0, 0.5, 0.0);
    }
    match provider {
        "anthropic" => Price::new(3.0, 15.0, 0.3, 3.75),
        "openai" => Price::new(1.25, 10.0, 0.125, 0.0),
        "google" => Price::new(1.25, 10.0, 0.125, 0.0),
        "xai" => Price::new(2.0, 6.0, 0.5, 0.0),
        _ => Price::new(0.0, 0.0, 0.0, 0.0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discovers_orca_managed_codex_homes() {
        // Simulate `~/Library/Application Support/orca/codex-runtime-home/<name>`
        // with a `sessions` dir, which is where Orca redirects CODEX_HOME.
        let home = std::env::temp_dir().join(format!(
            "tokcat-orca-home-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let runtime_root = home
            .join("Library")
            .join("Application Support")
            .join("orca")
            .join("codex-runtime-home");
        let managed_home = runtime_root.join("home");
        fs::create_dir_all(managed_home.join("sessions")).unwrap();
        // A sibling dir without any sessions folder must be ignored.
        fs::create_dir_all(runtime_root.join("scratch")).unwrap();

        let homes = orca_codex_homes(&home);
        assert_eq!(homes, vec![managed_home]);

        let _ = fs::remove_dir_all(home);
    }

    fn assert_price(model: &str, provider: &str, expected: Price) {
        let actual = bundled_price(model, provider);
        assert!((actual.input - expected.input).abs() < f64::EPSILON);
        assert!((actual.output - expected.output).abs() < f64::EPSILON);
        assert!((actual.cache_read - expected.cache_read).abs() < f64::EPSILON);
        assert!((actual.cache_write - expected.cache_write).abs() < f64::EPSILON);
        assert_eq!(actual.input_above_200k, expected.input_above_200k);
        assert_eq!(actual.output_above_200k, expected.output_above_200k);
        assert_eq!(actual.cache_read_above_200k, expected.cache_read_above_200k);
        assert_eq!(
            actual.cache_write_above_200k,
            expected.cache_write_above_200k
        );
        assert_eq!(actual.input_above_272k, expected.input_above_272k);
        assert_eq!(actual.output_above_272k, expected.output_above_272k);
        assert_eq!(actual.cache_read_above_272k, expected.cache_read_above_272k);
    }

    #[test]
    fn bundled_price_matches_current_claude_model_families() {
        assert_price(
            "claude-fable-5",
            "anthropic",
            Price::new(10.0, 50.0, 1.0, 12.5),
        );
        assert_price(
            "claude-fable-5[1m]",
            "anthropic",
            Price::new(10.0, 50.0, 1.0, 12.5),
        );
        assert_price(
            "claude-opus-4-7",
            "anthropic",
            Price::new(5.0, 25.0, 0.5, 6.25),
        );
        assert_price(
            "claude-opus-4.8",
            "anthropic",
            Price::new(5.0, 25.0, 0.5, 6.25),
        );
        assert_price(
            "anthropic/claude-opus-4.8-fast",
            "openrouter",
            Price::new(10.0, 50.0, 1.0, 12.5),
        );
        assert_price(
            "claude-opus-4-5-20251101",
            "anthropic",
            Price::new(5.0, 25.0, 0.5, 6.25),
        );
        assert_price(
            "claude-opus-4-1",
            "anthropic",
            Price::new(15.0, 75.0, 1.5, 18.75),
        );
        assert_price(
            "claude-haiku-4-5-20251001",
            "anthropic",
            Price::new(1.0, 5.0, 0.1, 1.25),
        );
        assert_price(
            "claude-sonnet-4-5",
            "anthropic",
            Price::new(3.0, 15.0, 0.3, 3.75).above_200k(6.0, 22.5, 0.6, 7.5),
        );
    }

    #[test]
    fn cursor_json_cache_maps_events_to_usage_messages() {
        let dir = std::env::temp_dir().join(format!("tokcat-cursor-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tokcat-events.json");
        // Shape mirrors a real get-filtered-usage-events row flattened by
        // cursor_usage::CachedCursorEvent.
        let json = r#"{"fetched_at_ms":1781757600000,"events":[
            {"timestamp_ms":1781757574236,"model":"composer-2.5","input_tokens":555,"output_tokens":599,"cache_read_tokens":3988,"cost":0.0025726},
            {"timestamp_ms":0,"model":"bad","input_tokens":1,"output_tokens":1,"cache_read_tokens":0,"cost":0.0}
        ]}"#;
        std::fs::write(&path, json).unwrap();

        let msgs = parse_cursor_cache_json(&path);
        std::fs::remove_dir_all(&dir).ok();

        // The zero-timestamp row is dropped; the valid one maps through.
        assert_eq!(msgs.len(), 1);
        let m = &msgs[0];
        assert_eq!(m.client, "cursor");
        assert_eq!(m.model_id, normalize_model_id("composer-2.5"));
        assert_eq!(m.tokens.input, 555);
        assert_eq!(m.tokens.output, 599);
        assert_eq!(m.tokens.cache_read, 3988);
        assert_eq!(m.tokens.cache_write, 0);
        assert!((m.cost - 0.0025726).abs() < 1e-9);
        assert_eq!(
            m.dedup_key.as_deref(),
            Some("cursor:1781757574236:555:599")
        );
    }

    #[test]
    fn bundled_price_matches_current_gpt_5_family() {
        assert_price(
            "gpt-5.5",
            "openai",
            Price::new(5.0, 30.0, 0.5, 0.0).above_272k(10.0, 45.0, 1.0),
        );
        assert_price(
            "gpt-5.3-codex",
            "openai",
            Price::new(1.75, 14.0, 0.175, 0.0),
        );
        assert_price(
            "gpt-5.1-codex-max",
            "openai",
            Price::new(1.25, 10.0, 0.125, 0.0),
        );
        assert_price(
            "openai/gpt-5.4-mini",
            "openai",
            Price::new(0.75, 4.5, 0.075, 0.0),
        );
        assert_price("gpt-5.2-pro", "openai", Price::new(21.0, 168.0, 0.0, 0.0));
        assert_price("gpt-5-nano", "openai", Price::new(0.05, 0.4, 0.005, 0.0));
    }

    #[test]
    fn bundled_price_matches_current_openai_o_family() {
        assert_price("o3", "openai", Price::new(2.0, 8.0, 0.5, 0.0));
        assert_price(
            "o3-deep-research",
            "openai",
            Price::new(10.0, 40.0, 2.5, 0.0),
        );
        assert_price("o3-mini", "openai", Price::new(1.1, 4.4, 0.55, 0.0));
        assert_price("o3-pro", "openai", Price::new(20.0, 80.0, 0.0, 0.0));
        assert_price("o4-mini", "openai", Price::new(1.1, 4.4, 0.275, 0.0));
    }

    #[test]
    fn bundled_price_matches_current_gemini_family() {
        assert_price(
            "gemini-2.5-flash",
            "google",
            Price::new(0.3, 2.5, 0.03, 0.0),
        );
        assert_price(
            "gemini-3.1-pro-preview",
            "google",
            Price::new(2.0, 12.0, 0.2, 0.0).above_200k(4.0, 18.0, 0.4, 0.0),
        );
        assert_price(
            "gemini-3.5-flash",
            "google",
            Price::new(1.5, 9.0, 0.15, 0.0),
        );
    }

    #[test]
    fn bundled_price_matches_current_openrouter_free_suffix_models() {
        assert_price("glm-4.7-free", "opencode", Price::new(0.6, 2.2, 0.11, 0.0));
        assert_price("glm-4.7", "opencode", Price::new(0.6, 2.2, 0.11, 0.0));
        assert_price("kimi-k2.5-free", "opencode", Price::new(0.6, 3.0, 0.1, 0.0));
        assert_price("kimi-k2.5", "opencode", Price::new(0.6, 3.0, 0.1, 0.0));
    }

    #[test]
    fn bundled_price_matches_current_cursor_composer_overrides() {
        assert_price("composer 1.5", "cursor", Price::new(3.5, 17.5, 0.35, 0.0));
        assert_price(
            "composer-2.5-fast",
            "cursor",
            Price::new(1.5, 7.5, 0.35, 0.0),
        );
    }

    #[test]
    fn estimate_cost_splits_tiered_prices() {
        let tokens = TokenBreakdown {
            input: 300_000,
            output: 100_000,
            cache_read: 300_000,
            cache_write: 0,
            reasoning: 0,
        };
        let cost = estimate_cost("gpt-5.5", "openai", &tokens);
        // input: 272k * 5 + 28k * 10, output: 100k * 30,
        // cache read: 272k * 0.5 + 28k * 1, all divided by 1M.
        assert!((cost - 4.804).abs() < 0.000_001);
    }

    #[test]
    fn codex_cached_tokens_do_not_double_count_input() {
        let tokens = CodexTotals {
            input: 100,
            output: 20,
            cached: 30,
            reasoning: 5,
        }
        .into_tokens();

        assert_eq!(tokens.input, 70);
        assert_eq!(tokens.cache_read, 30);
        assert_eq!(tokens.total(), 125);
    }

    #[test]
    fn codex_parser_skips_repeated_total_snapshots() {
        let path = codex_test_jsonl_path("repeated-total");
        fs::write(
            &path,
            [
                r#"{"type":"session_meta","payload":{"model_provider":"openai"}}"#,
                r#"{"type":"turn_context","payload":{"model_info":{"slug":"gpt-5.5"}}}"#,
                r#"{"timestamp":"2026-05-24T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.5","total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"total_tokens":110}}}}"#,
                r#"{"timestamp":"2026-05-24T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.5","total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"total_tokens":110}}}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let messages = parse_codex_file(&path);
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].tokens.input, 80);
        assert_eq!(messages[0].tokens.cache_read, 20);
        assert_eq!(messages[0].tokens.output, 10);

        cleanup_temp_file(&path);
    }

    #[test]
    fn codex_parser_skips_stale_regression_snapshots() {
        let path = codex_test_jsonl_path("stale-regression");
        fs::write(
            &path,
            [
                r#"{"type":"turn_context","payload":{"model_info":{"slug":"gpt-5.5"}}}"#,
                r#"{"timestamp":"2026-05-24T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.5","total_token_usage":{"input_tokens":1000,"total_tokens":1000},"last_token_usage":{"input_tokens":100,"total_tokens":100}}}}"#,
                r#"{"timestamp":"2026-05-24T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.5","total_token_usage":{"input_tokens":990,"total_tokens":990},"last_token_usage":{"input_tokens":50,"total_tokens":50}}}}"#,
                r#"{"timestamp":"2026-05-24T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.5","total_token_usage":{"input_tokens":1060,"total_tokens":1060},"last_token_usage":{"input_tokens":60,"total_tokens":60}}}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let messages = parse_codex_file(&path);
        assert_eq!(messages.len(), 2);
        assert_eq!(
            messages
                .iter()
                .map(|message| message.tokens.input)
                .sum::<i64>(),
            160
        );

        cleanup_temp_file(&path);
    }

    #[test]
    fn codex_parser_skips_forked_session_inherited_baseline() {
        let path = codex_test_jsonl_path("forked-baseline");
        fs::write(
            &path,
            [
                r#"{"type":"session_meta","payload":{"forked_from_id":"parent","model_provider":"openai"}}"#,
                r#"{"timestamp":"2026-05-24T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"total_tokens":1000},"last_token_usage":{"input_tokens":1000,"total_tokens":1000}}}}"#,
                r#"{"type":"turn_context","payload":{"model_info":{"slug":"gpt-5.5"}}}"#,
                r#"{"timestamp":"2026-05-24T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.5","total_token_usage":{"input_tokens":1000,"total_tokens":1000},"last_token_usage":{"input_tokens":20,"total_tokens":20}}}}"#,
                r#"{"timestamp":"2026-05-24T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.5","total_token_usage":{"input_tokens":1100,"total_tokens":1100},"last_token_usage":{"input_tokens":100,"total_tokens":100}}}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let messages = parse_codex_file(&path);
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].tokens.input, 100);

        cleanup_temp_file(&path);
    }

    #[test]
    fn payload_shape_uses_camel_case_fields() {
        let payload = build_payload(vec![UsageMessage::new(
            "claude",
            "claude-sonnet-4",
            "anthropic",
            1_700_000_000_000,
            TokenBreakdown {
                input: 10,
                output: 5,
                cache_read: 2,
                cache_write: 1,
                reasoning: 0,
            },
            0.01,
        )]);

        let value = serde_json::to_value(payload).unwrap();
        assert!(value.pointer("/meta/dateRange/start").is_some());
        assert!(value
            .pointer("/contributions/0/tokenBreakdown/cacheRead")
            .is_some());
        assert!(value
            .pointer("/contributions/0/clients/0/modelId")
            .is_some());
        assert!(value.pointer("/years/0/range/start").is_some());
    }

    #[test]
    fn hermes_sessions_use_started_at_and_stored_usage_fields() {
        let db_path = hermes_test_db_path("started-at");
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                model TEXT,
                started_at REAL,
                ended_at REAL,
                message_count INTEGER,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_tokens INTEGER,
                cache_write_tokens INTEGER,
                reasoning_tokens INTEGER,
                billing_provider TEXT,
                estimated_cost_usd REAL,
                actual_cost_usd REAL
            );
            "#,
        )
        .unwrap();
        conn.execute(
            r#"
            INSERT INTO sessions (
                id, model, started_at, ended_at, message_count,
                input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                reasoning_tokens, billing_provider, estimated_cost_usd, actual_cost_usd
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
            "#,
            rusqlite::params![
                "s1",
                "gpt-5.5",
                1_700_000_000.125_f64,
                0.0_f64,
                4_i32,
                100_i64,
                20_i64,
                300_i64,
                40_i64,
                5_i64,
                "openai-codex",
                0.25_f64,
                1.25_f64
            ],
        )
        .unwrap();
        conn.execute(
            r#"
            INSERT INTO sessions (
                id, model, started_at, ended_at, message_count,
                input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                reasoning_tokens, billing_provider, estimated_cost_usd, actual_cost_usd
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
            "#,
            rusqlite::params![
                "s2",
                "claude-sonnet-4",
                1_700_259_200.0_f64,
                0.0_f64,
                2_i32,
                10_i64,
                3_i64,
                7_i64,
                1_i64,
                2_i64,
                "anthropic",
                0.75_f64,
                0.0_f64
            ],
        )
        .unwrap();
        drop(conn);

        let messages = parse_hermes_db(&db_path);
        let first = messages
            .iter()
            .find(|m| m.dedup_key.as_deref() == Some("hermes:s1"))
            .unwrap();
        let second = messages
            .iter()
            .find(|m| m.dedup_key.as_deref() == Some("hermes:s2"))
            .unwrap();

        assert_eq!(first.provider_id, "openai");
        assert_eq!(first.timestamp_ms, 1_700_000_000_125);
        assert_eq!(first.tokens.reasoning, 5);
        assert_eq!(first.messages, 4);
        assert_eq!(first.cost, 1.25);

        assert_eq!(second.provider_id, "anthropic");
        assert_eq!(second.timestamp_ms, 1_700_259_200_000);
        assert_eq!(second.tokens.reasoning, 2);
        assert_eq!(second.messages, 2);
        assert_eq!(second.cost, 0.75);

        let payload = build_payload(messages);
        let dates: BTreeSet<_> = payload.contributions.iter().map(|c| &c.date).collect();
        assert_eq!(dates.len(), 2);

        let _ = fs::remove_file(&db_path);
        if let Some(parent) = db_path.parent() {
            let _ = fs::remove_dir(parent);
        }
    }

    #[test]
    fn hermes_parser_tolerates_minimal_session_schema() {
        let db_path = hermes_test_db_path("minimal");
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                model TEXT,
                started_at REAL,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_tokens INTEGER,
                cache_write_tokens INTEGER
            );
            INSERT INTO sessions (
                id, model, started_at, input_tokens, output_tokens,
                cache_read_tokens, cache_write_tokens
            ) VALUES ('s1', 'gpt-5.5', 1700000000, 1, 2, 3, 4);
            "#,
        )
        .unwrap();
        drop(conn);

        let messages = parse_hermes_db(&db_path);
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].timestamp_ms, 1_700_000_000_000);
        assert_eq!(messages[0].tokens.total(), 10);

        let _ = fs::remove_file(&db_path);
        if let Some(parent) = db_path.parent() {
            let _ = fs::remove_dir(parent);
        }
    }

    fn hermes_test_db_path(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "tokcat-hermes-{}-{}-{}",
            name,
            std::process::id(),
            now_ms()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir.join("state.db")
    }

    fn codex_test_jsonl_path(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "tokcat-codex-{}-{}-{}",
            name,
            std::process::id(),
            now_ms()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir.join("session.jsonl")
    }

    fn cleanup_temp_file(path: &Path) {
        let _ = fs::remove_file(path);
        if let Some(parent) = path.parent() {
            let _ = fs::remove_dir(parent);
        }
    }

    fn write_grok_fixture(
        name: &str,
        updates_jsonl: &str,
        summary_json: Option<&str>,
        signals_json: Option<&str>,
    ) -> (PathBuf, PathBuf) {
        // Include a per-call nonce so parallel tests never share a directory.
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let nonce = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "tokcat-grok-{}-{}-{}-{}",
            name,
            std::process::id(),
            now_ms(),
            nonce
        ));
        let session_dir = root
            .join(".grok")
            .join("sessions")
            .join("%2Ftmp%2Fproject")
            .join("session-1");
        fs::create_dir_all(&session_dir).unwrap();
        let updates_path = session_dir.join("updates.jsonl");
        fs::write(&updates_path, updates_jsonl).unwrap();
        if let Some(summary_json) = summary_json {
            fs::write(session_dir.join("summary.json"), summary_json).unwrap();
        }
        if let Some(signals_json) = signals_json {
            fs::write(session_dir.join("signals.json"), signals_json).unwrap();
        }
        (root, updates_path)
    }

    fn cleanup_grok_fixture(root: &Path) {
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn parses_grok_total_token_deltas_by_turn() {
        let (root, path) = write_grok_fixture(
            "by-turn",
            r#"{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"available_commands_update"},"_meta":{"totalTokens":100,"agentTimestampMs":1700000000000}}}
{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","_meta":{"modelId":"grok-4.5"}}},"_meta":{"agentTimestampMs":1700000001000}}}
{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_thought_chunk"},"_meta":{"totalTokens":250,"agentTimestampMs":1700000002000}}}
{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":300,"agentTimestampMs":1700000003000}}}
{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","_meta":{"modelId":"grok-4.5"}}},"_meta":{"agentTimestampMs":1700000004000}}}
{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":450,"agentTimestampMs":1700000005000}}}"#,
            Some(
                r#"{"current_model_id":"grok-4.5","updated_at":"2023-11-14T22:13:20Z"}"#,
            ),
            None,
        );

        let messages = parse_grok_updates_file(&path);
        cleanup_grok_fixture(&root);

        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].client, "grok");
        assert_eq!(messages[0].model_id, "grok-4.5");
        assert_eq!(messages[0].provider_id, "xai");
        assert_eq!(messages[0].tokens.input, 200);
        assert_eq!(messages[0].tokens.output, 0);
        assert_eq!(messages[0].timestamp_ms, 1700000003000);
        assert_eq!(
            messages[0].dedup_key.as_deref(),
            Some("grok:%2Ftmp%2Fproject:session-1:0")
        );
        assert_eq!(messages[1].tokens.input, 150);
        assert_eq!(messages[1].timestamp_ms, 1700000005000);
    }

    #[test]
    fn grok_uses_summary_model_when_update_model_is_missing() {
        let (root, path) = write_grok_fixture(
            "summary-model",
            r#"{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"user_message_chunk"},"_meta":{"agentTimestampMs":1700000000000}}}
{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":220,"agentTimestampMs":1700000001000}}}"#,
            Some(
                r#"{"current_model_id":"grok-4.5","updated_at":"2023-11-14T22:13:20Z"}"#,
            ),
            None,
        );

        let messages = parse_grok_updates_file(&path);
        cleanup_grok_fixture(&root);

        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].model_id, "grok-4.5");
        assert_eq!(messages[0].tokens.input, 220);
    }

    #[test]
    fn grok_ignores_repeated_and_decreasing_total_tokens() {
        let (root, path) = write_grok_fixture(
            "monotonic",
            r#"{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"available_commands_update"},"_meta":{"totalTokens":100,"agentTimestampMs":1700000000000}}}
{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","_meta":{"modelId":"grok-4.5"}}},"_meta":{"agentTimestampMs":1700000001000}}}
{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":150,"agentTimestampMs":1700000002000}}}
{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":150,"agentTimestampMs":1700000003000}}}
{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":120,"agentTimestampMs":1700000004000}}}
{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":200,"agentTimestampMs":1700000005000}}}"#,
            None,
            None,
        );

        let messages = parse_grok_updates_file(&path);
        cleanup_grok_fixture(&root);

        // Dip to 120 is ignored without lowering the high-water mark, so the
        // final 200 yields one turn delta of 100 (200 - baseline 100).
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].tokens.input, 100);
        assert_eq!(messages[0].timestamp_ms, 1700000005000);
    }

    #[test]
    fn grok_adds_signals_reconciliation_when_compaction_exceeds_updates() {
        let (root, path) = write_grok_fixture(
            "signals",
            r#"{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","_meta":{"modelId":"grok-4.5"}}},"_meta":{"agentTimestampMs":1700000000000}}}
{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":171056,"agentTimestampMs":1700000001000}}}"#,
            None,
            Some(
                r#"{"primaryModelId":"grok-4.5","totalTokensBeforeCompaction":3224659,"contextTokensUsed":172309}"#,
            ),
        );

        let messages = parse_grok_updates_file(&path);
        cleanup_grok_fixture(&root);

        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].tokens.input, 171056);
        assert_eq!(messages[1].tokens.input, 3225912);
        assert_eq!(messages[1].model_id, "grok-4.5");
        assert_eq!(
            messages[1].dedup_key.as_deref(),
            Some("grok:%2Ftmp%2Fproject:session-1:signals")
        );
        assert_eq!(messages[1].timestamp_ms, 1700000001000);
        assert_eq!(
            messages
                .iter()
                .map(|message| message.tokens.input)
                .sum::<i64>(),
            3396968
        );
    }

    #[test]
    fn bundled_price_matches_current_grok_family() {
        assert_price("grok-4.5", "xai", Price::new(2.0, 6.0, 0.5, 0.0));
        assert_price("grok-4.3", "xai", Price::new(1.25, 2.5, 0.2, 0.0));
        assert_price("grok-4.1-fast", "xai", Price::new(0.2, 0.5, 0.05, 0.0));
        assert_price("grok-4", "xai", Price::new(3.0, 15.0, 0.75, 0.0));
        assert_price("xai/grok-unknown", "xai", Price::new(2.0, 6.0, 0.5, 0.0));
        // Grok-prefixed Composer ids must hit Composer prices, not xAI default.
        assert_price(
            "grok-composer-2.5",
            "xai",
            Price::new(0.5, 2.5, 0.2, 0.0),
        );
        assert_price(
            "grok-composer-2.5-fast",
            "xai",
            Price::new(1.5, 7.5, 0.35, 0.0),
        );
    }

    #[test]
    fn grok_preserves_total_tokens_without_model_metadata() {
        let (root, path) = write_grok_fixture(
            "no-model",
            r#"{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"available_commands_update"},"_meta":{"totalTokens":120,"agentTimestampMs":1700000000000}}}"#,
            None,
            None,
        );
        let messages = parse_grok_updates_file(&path);
        cleanup_grok_fixture(&root);
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].model_id, GROK_UNKNOWN_MODEL);
        assert_eq!(messages[0].tokens.input, 120);
        assert_eq!(messages[0].timestamp_ms, 1700000000000);
    }

    #[test]
    fn grok_skips_signals_reconciliation_when_updates_cover_total() {
        let (root, path) = write_grok_fixture(
            "signals-covered",
            r#"{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"user_message_chunk"},"_meta":{"agentTimestampMs":1700000000000}}}
{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":500,"agentTimestampMs":1700000001000}}}"#,
            None,
            Some(r#"{"primaryModelId":"grok-4.5","contextTokensUsed":400}"#),
        );
        let messages = parse_grok_updates_file(&path);
        cleanup_grok_fixture(&root);
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].tokens.input, 500);
    }

    #[test]
    fn grok_events_jsonl_supplies_model_when_summary_missing() {
        let root = std::env::temp_dir().join(format!(
            "tokcat-grok-events-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let session_dir = root
            .join(".grok")
            .join("sessions")
            .join("%2Ftmp%2Fproject")
            .join("session-1");
        fs::create_dir_all(&session_dir).unwrap();
        let updates = session_dir.join("updates.jsonl");
        fs::write(
            &updates,
            r#"{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":90,"agentTimestampMs":1700000001000}}}"#,
        )
        .unwrap();
        fs::write(
            session_dir.join("events.jsonl"),
            r#"{"model_id":"grok-4.5","session_id":"session-1","ts":1700000000000}"#,
        )
        .unwrap();
        let messages = parse_grok_updates_file(&updates);
        let _ = fs::remove_dir_all(&root);
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].model_id, "grok-4.5");
        assert_eq!(messages[0].tokens.input, 90);
    }
}
