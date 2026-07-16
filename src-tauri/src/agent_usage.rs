use chrono::{DateTime, SecondsFormat, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;
use std::fs;
use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const CODEX_USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
const CODEX_REFRESH_URL: &str = "https://auth.openai.com/oauth/token";
const CODEX_CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const CLAUDE_USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
const CLAUDE_REFRESH_URL: &str = "https://platform.claude.com/v1/oauth/token";
const CLAUDE_CLIENT_ID: &str = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const CLAUDE_DEFAULT_SCOPES: &str =
    "user:profile user:inference user:sessions:claude_code user:mcp_servers";
const CLAUDE_KEYCHAIN_SERVICE: &str = "Claude Code-credentials";

// Grok Build OAuth / billing — same endpoints as tokscale's usage/grok module.
const GROK_SUBSCRIPTIONS_URL: &str = "https://grok.com/rest/subscriptions";
const GROK_TASK_USAGE_URL: &str = "https://grok.com/rest/tasks/usage";
const GROK_BILLING_GRPC_URL: &str =
    "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig";
const GROK_USER_AGENT: &str = "Grok Build";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentUsagePayload {
    generated_at: String,
    agents: Vec<AgentUsageSnapshot>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentUsageSnapshot {
    client_id: String,
    source: String,
    updated_at: String,
    identity: Option<AgentIdentity>,
    windows: Vec<UsageWindow>,
    credits: Option<CreditsSnapshot>,
    error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentIdentity {
    email: Option<String>,
    plan: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageWindow {
    label: String,
    used_percent: f64,
    remaining_percent: f64,
    resets_at: Option<String>,
    reset_text: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CreditsSnapshot {
    remaining: Option<f64>,
    unlimited: bool,
}

#[derive(Debug, Clone)]
struct CodexCredentials {
    access_token: String,
    refresh_token: Option<String>,
    id_token: Option<String>,
    account_id: Option<String>,
    last_refresh: Option<DateTime<Utc>>,
    auth_path: PathBuf,
    raw_json: Value,
}

#[derive(Debug, Clone)]
struct ClaudeCredentials {
    access_token: String,
    refresh_token: Option<String>,
    expires_at: Option<DateTime<Utc>>,
    scopes: Vec<String>,
    rate_limit_tier: Option<String>,
    subscription_type: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ClaudeCredentialsRoot {
    #[serde(default, rename = "claudeAiOauth")]
    claude_ai_oauth: Option<ClaudeCredentialsOauth>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClaudeCredentialsOauth {
    access_token: Option<String>,
    refresh_token: Option<String>,
    expires_at: Option<f64>,
    scopes: Option<Vec<String>>,
    rate_limit_tier: Option<String>,
    subscription_type: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CodexUsageResponse {
    #[serde(default)]
    plan_type: Option<String>,
    #[serde(default)]
    rate_limit: Option<CodexRateLimit>,
    #[serde(default)]
    additional_rate_limits: Option<Vec<CodexAdditionalRateLimit>>,
    #[serde(default)]
    credits: Option<CodexCredits>,
    #[serde(default)]
    spend_control: Option<CodexSpendControl>,
}

#[derive(Debug, Deserialize)]
struct CodexRateLimit {
    #[serde(default)]
    primary_window: Option<CodexWindow>,
    #[serde(default)]
    secondary_window: Option<CodexWindow>,
}

#[derive(Debug, Clone, Deserialize)]
struct CodexWindow {
    used_percent: f64,
    reset_at: i64,
    limit_window_seconds: i64,
}

#[derive(Debug, Deserialize)]
struct CodexAdditionalRateLimit {
    #[serde(default)]
    limit_name: Option<String>,
    #[serde(default)]
    metered_feature: Option<String>,
    #[serde(default)]
    rate_limit: Option<CodexRateLimit>,
}

#[derive(Debug, Deserialize)]
struct CodexCredits {
    #[serde(default)]
    unlimited: bool,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    balance: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct CodexSpendControl {
    #[serde(default)]
    individual_limit: Option<CodexSpendLimit>,
}

#[derive(Debug, Deserialize)]
struct CodexSpendLimit {
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    limit: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    used: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    used_percent: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    remaining_percent: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_i64")]
    reset_at: Option<i64>,
}

#[derive(Debug, Deserialize, Default)]
struct ClaudeUsageResponse {
    #[serde(default)]
    five_hour: Option<ClaudeWindow>,
    #[serde(default)]
    seven_day: Option<ClaudeWindow>,
    #[serde(default)]
    seven_day_oauth_apps: Option<ClaudeWindow>,
    #[serde(default)]
    seven_day_opus: Option<ClaudeWindow>,
    #[serde(default)]
    seven_day_sonnet: Option<ClaudeWindow>,
    #[serde(default)]
    seven_day_design: Option<ClaudeWindow>,
    #[serde(default)]
    seven_day_claude_design: Option<ClaudeWindow>,
    #[serde(default)]
    claude_design: Option<ClaudeWindow>,
    #[serde(default)]
    design: Option<ClaudeWindow>,
    #[serde(default)]
    seven_day_omelette: Option<ClaudeWindow>,
    #[serde(default)]
    omelette: Option<ClaudeWindow>,
    #[serde(default)]
    omelette_promotional: Option<ClaudeWindow>,
    #[serde(default)]
    seven_day_routines: Option<ClaudeWindow>,
    #[serde(default)]
    seven_day_claude_routines: Option<ClaudeWindow>,
    #[serde(default)]
    claude_routines: Option<ClaudeWindow>,
    #[serde(default)]
    routines: Option<ClaudeWindow>,
    #[serde(default)]
    routine: Option<ClaudeWindow>,
    #[serde(default)]
    seven_day_cowork: Option<ClaudeWindow>,
    #[serde(default)]
    cowork: Option<ClaudeWindow>,
    #[serde(default)]
    extra_usage: Option<ClaudeExtraUsage>,
}

#[derive(Debug, Clone, Deserialize)]
struct ClaudeWindow {
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    utilization: Option<f64>,
    #[serde(default)]
    resets_at: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ClaudeExtraUsage {
    #[serde(default)]
    is_enabled: bool,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    monthly_limit: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    used_credits: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    utilization: Option<f64>,
    #[serde(default)]
    currency: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ClaudeRefreshResponse {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    expires_in: i64,
}

pub async fn run() -> AgentUsagePayload {
    let generated_at = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let mut agents = Vec::new();
    if codex_is_configured() {
        agents.push(fetch_codex().await);
    }
    if claude_is_configured() {
        agents.push(fetch_claude().await);
    }
    if grok_is_configured() {
        agents.push(fetch_grok().await);
    }
    AgentUsagePayload {
        generated_at,
        agents,
    }
}

/// Whether Codex OAuth has been set up at all. A missing auth.json means Codex
/// isn't installed / logged in, so we hide its tile rather than render a
/// perpetual "not found" error. A present-but-broken auth.json still surfaces
/// an error tile so the user knows to re-authenticate.
fn codex_is_configured() -> bool {
    codex_home().join("auth.json").exists()
}

/// Whether Claude OAuth has been set up at all, mirroring the lookup order in
/// load_claude_credentials (env override, Keychain, credentials file).
fn claude_is_configured() -> bool {
    let env_token = std::env::var("TOKCAT_CLAUDE_OAUTH_TOKEN")
        .or_else(|_| std::env::var("CODEXBAR_CLAUDE_OAUTH_TOKEN"))
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    if env_token.is_some() {
        return true;
    }
    if matches!(load_claude_credentials_from_keychain(), Ok(Some(_))) {
        return true;
    }
    claude_credentials_path().exists()
}

/// Whether Grok Build OAuth credentials exist under `$GROK_HOME/auth.json`
/// (default `~/.grok/auth.json`). Missing file hides the Grok limits tile.
fn grok_is_configured() -> bool {
    grok_auth_path().is_file()
}

async fn fetch_grok() -> AgentUsageSnapshot {
    match fetch_grok_inner().await {
        Ok(snapshot) => snapshot,
        Err(error) => AgentUsageSnapshot {
            client_id: "grok".to_string(),
            source: "oauth".to_string(),
            updated_at: Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
            identity: None,
            windows: Vec::new(),
            credits: None,
            error: Some(error),
        },
    }
}

async fn fetch_grok_inner() -> Result<AgentUsageSnapshot, String> {
    let credentials = load_grok_credentials()?;
    let mut errors = Vec::new();
    let mut plan_only: Option<(Option<String>, Option<String>)> = None;
    let now = Utc::now();

    for (index, credential) in credentials.iter().enumerate() {
        match fetch_grok_network_usage(credential).await {
            Ok((plan, email, windows)) if !windows.is_empty() => {
                return Ok(AgentUsageSnapshot {
                    client_id: "grok".to_string(),
                    source: "oauth".to_string(),
                    updated_at: now.to_rfc3339_opts(SecondsFormat::Millis, true),
                    identity: Some(AgentIdentity {
                        email: email.or_else(|| credential.email.clone()),
                        plan,
                    }),
                    windows,
                    credits: None,
                    error: None,
                });
            }
            Ok((plan, email, _)) => {
                if plan_only.is_none() {
                    plan_only = Some((plan, email.or_else(|| credential.email.clone())));
                }
            }
            Err(error) => errors.push(format!("Grok credential #{} failed: {error}", index + 1)),
        }
    }

    // Agent stdio billing has no credential context — skip when multiple
    // accounts are present (same policy as tokscale).
    if credentials.len() == 1 {
        if let Some(billing) = fetch_grok_agent_billing(Duration::from_secs(4)) {
            let mut metrics = Vec::new();
            if let Some(metric) = parse_grok_billing_json_metric(&billing) {
                metrics.push(metric);
            }
            collect_grok_task_usage_metrics(&billing, &mut metrics);
            if !metrics.is_empty() {
                let (plan, email) = plan_only.unwrap_or((None, credentials[0].email.clone()));
                return Ok(AgentUsageSnapshot {
                    client_id: "grok".to_string(),
                    source: "oauth".to_string(),
                    updated_at: now.to_rfc3339_opts(SecondsFormat::Millis, true),
                    identity: Some(AgentIdentity { email, plan }),
                    windows: metrics
                        .into_iter()
                        .map(|m| map_grok_metric(m, now))
                        .collect(),
                    credits: None,
                    error: None,
                });
            }
        } else {
            errors.push("Grok agent billing RPC unavailable".to_string());
        }
    } else if credentials.len() > 1 {
        errors
            .push("Grok agent billing fallback skipped: multiple credentials present".to_string());
    }

    if let Some((plan, email)) = plan_only {
        // Plan-only: show SuperGrok identity even when percent metrics fail.
        // Do not set error — AgentLimitsCard prefers error over identity and
        // would hide a valid plan behind a red "Error" status.
        let _ = errors;
        return Ok(AgentUsageSnapshot {
            client_id: "grok".to_string(),
            source: "oauth".to_string(),
            updated_at: now.to_rfc3339_opts(SecondsFormat::Millis, true),
            identity: Some(AgentIdentity { email, plan }),
            windows: Vec::new(),
            credits: None,
            error: None,
        });
    }

    let detail = if errors.is_empty() {
        "no usage or active subscription data returned".to_string()
    } else {
        errors.join("; ")
    };
    Err(format!("Grok usage unavailable: {detail}"))
}

async fn fetch_codex() -> AgentUsageSnapshot {
    match fetch_codex_inner().await {
        Ok(snapshot) => snapshot,
        Err(error) => AgentUsageSnapshot {
            client_id: "codex".to_string(),
            source: "oauth".to_string(),
            updated_at: Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
            identity: None,
            windows: Vec::new(),
            credits: None,
            error: Some(error),
        },
    }
}

async fn fetch_claude() -> AgentUsageSnapshot {
    match fetch_claude_inner().await {
        Ok(snapshot) => snapshot,
        Err(error) => AgentUsageSnapshot {
            client_id: "claude".to_string(),
            source: "oauth".to_string(),
            updated_at: Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
            identity: None,
            windows: Vec::new(),
            credits: None,
            error: Some(error),
        },
    }
}

async fn fetch_codex_inner() -> Result<AgentUsageSnapshot, String> {
    let mut credentials = load_codex_credentials()?;
    if credentials_needs_refresh(credentials.last_refresh) {
        if credentials
            .refresh_token
            .as_deref()
            .unwrap_or("")
            .is_empty()
        {
            return Err(
                "Codex OAuth token needs refresh but auth.json has no refresh token.".to_string(),
            );
        }
        credentials = refresh_codex_credentials(credentials).await?;
    }

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("build Codex OAuth client: {}", e))?;

    let mut request = client
        .get(CODEX_USAGE_URL)
        .bearer_auth(&credentials.access_token)
        .header(reqwest::header::ACCEPT, "application/json")
        .header(reqwest::header::USER_AGENT, "Tokcat");
    if let Some(account_id) = credentials.account_id.as_deref().filter(|s| !s.is_empty()) {
        request = request.header("ChatGPT-Account-Id", account_id);
    }

    let response = request
        .send()
        .await
        .map_err(|e| format!("Codex OAuth request failed: {}", e))?;
    let status = response.status();
    let body = response
        .text()
        .await
        .map_err(|e| format!("read Codex OAuth response: {}", e))?;

    if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
        return Err(
            "Codex OAuth token expired or invalid. Run `codex` to log in again.".to_string(),
        );
    }
    if !status.is_success() {
        return Err(format!("Codex usage API returned {}.", status.as_u16()));
    }

    let usage: CodexUsageResponse =
        serde_json::from_str(&body).map_err(|e| format!("decode Codex usage response: {}", e))?;
    let now = Utc::now();
    let identity = Some(AgentIdentity {
        email: credentials.id_token.as_deref().and_then(jwt_email),
        plan: usage.plan_type.as_deref().map(clean_plan).or_else(|| {
            credentials
                .id_token
                .as_deref()
                .and_then(jwt_plan)
                .map(clean_plan)
        }),
    });
    let windows = codex_windows(
        usage.rate_limit.as_ref(),
        usage.additional_rate_limits.as_deref(),
        usage.spend_control.as_ref(),
        now,
    );
    if windows.is_empty() && usage.credits.as_ref().and_then(|c| c.balance).is_none() {
        return Err("Codex usage API returned no rate-limit windows.".to_string());
    }

    Ok(AgentUsageSnapshot {
        client_id: "codex".to_string(),
        source: "oauth".to_string(),
        updated_at: now.to_rfc3339_opts(SecondsFormat::Millis, true),
        identity,
        windows,
        credits: usage.credits.map(|credits| CreditsSnapshot {
            remaining: credits.balance,
            unlimited: credits.unlimited,
        }),
        error: None,
    })
}

async fn fetch_claude_inner() -> Result<AgentUsageSnapshot, String> {
    let mut credentials = load_claude_credentials()?;
    if claude_credentials_expired(&credentials) {
        credentials = refresh_claude_credentials(&credentials).await?;
    }

    if !credentials.scopes.is_empty()
        && !credentials
            .scopes
            .iter()
            .any(|scope| scope == "user:profile")
    {
        return Err(
            "Claude OAuth token lacks the user:profile scope. Run `claude logout && claude login`."
                .to_string(),
        );
    }

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("build Claude OAuth client: {}", e))?;

    let response = client
        .get(CLAUDE_USAGE_URL)
        .bearer_auth(&credentials.access_token)
        .header(reqwest::header::ACCEPT, "application/json")
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .header(reqwest::header::USER_AGENT, claude_user_agent())
        .header("anthropic-beta", "oauth-2025-04-20")
        .send()
        .await
        .map_err(|e| format!("Claude OAuth request failed: {}", e))?;
    let status = response.status();
    let body = response
        .text()
        .await
        .map_err(|e| format!("read Claude OAuth response: {}", e))?;

    if status == reqwest::StatusCode::UNAUTHORIZED {
        return Err(
            "Claude OAuth token expired or invalid. Run `claude` to re-authenticate.".to_string(),
        );
    }
    if status == reqwest::StatusCode::FORBIDDEN {
        return Err(
            "Claude OAuth usage was denied. Run `claude logout && claude login` to grant user:profile."
                .to_string(),
        );
    }
    if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
        return Err(
            "Claude OAuth usage endpoint is rate limited. Try Refresh again later.".to_string(),
        );
    }
    if !status.is_success() {
        return Err(format!("Claude usage API returned {}.", status.as_u16()));
    }

    let usage: ClaudeUsageResponse =
        serde_json::from_str(&body).map_err(|e| format!("decode Claude usage response: {}", e))?;
    let now = Utc::now();
    let windows = claude_windows(&usage, now);
    if windows.is_empty() {
        return Err("Claude usage API returned no rate-limit windows.".to_string());
    }

    Ok(AgentUsageSnapshot {
        client_id: "claude".to_string(),
        source: "oauth".to_string(),
        updated_at: now.to_rfc3339_opts(SecondsFormat::Millis, true),
        identity: Some(AgentIdentity {
            email: None,
            plan: first_non_empty([
                credentials.subscription_type.as_deref(),
                credentials.rate_limit_tier.as_deref(),
            ])
            .map(clean_plan),
        }),
        windows,
        credits: claude_credits(usage.extra_usage.as_ref()),
        error: None,
    })
}

fn load_codex_credentials() -> Result<CodexCredentials, String> {
    let auth_path = codex_home().join("auth.json");
    let raw = fs::read_to_string(&auth_path)
        .map_err(|_| "Codex auth.json not found. Run `codex` to log in.".to_string())?;
    let raw_json: Value =
        serde_json::from_str(&raw).map_err(|e| format!("decode Codex auth.json: {}", e))?;

    if raw_json
        .get("OPENAI_API_KEY")
        .and_then(Value::as_str)
        .is_some_and(|key| !key.trim().is_empty())
    {
        return Err(
            "Codex is using API-key auth; OAuth usage limits require `codex login`.".to_string(),
        );
    }

    let tokens = raw_json
        .get("tokens")
        .and_then(Value::as_object)
        .ok_or_else(|| "Codex auth.json exists but contains no OAuth tokens.".to_string())?;
    let access_token = string_key(tokens, "access_token", "accessToken")
        .ok_or_else(|| "Codex auth.json has no access token.".to_string())?;
    let refresh_token = string_key(tokens, "refresh_token", "refreshToken");
    let id_token = string_key(tokens, "id_token", "idToken");
    let account_id = string_key(tokens, "account_id", "accountId");
    let last_refresh = raw_json
        .get("last_refresh")
        .and_then(Value::as_str)
        .and_then(parse_datetime);

    Ok(CodexCredentials {
        access_token,
        refresh_token,
        id_token,
        account_id,
        last_refresh,
        auth_path,
        raw_json,
    })
}

fn load_claude_credentials() -> Result<ClaudeCredentials, String> {
    if let Some(credentials) = load_claude_credentials_from_environment()? {
        return Ok(credentials);
    }

    if let Some(raw) = load_claude_credentials_from_keychain()? {
        return parse_claude_credentials_data(&raw);
    }

    let credentials_path = claude_credentials_path();
    match fs::read_to_string(&credentials_path) {
        Ok(raw) => return parse_claude_credentials_data(&raw),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(format!(
                "read Claude credentials file {}: {}",
                credentials_path.display(),
                error
            ));
        }
    }

    Err("Claude OAuth credentials not found. Run `claude` to authenticate.".to_string())
}

fn load_claude_credentials_from_environment() -> Result<Option<ClaudeCredentials>, String> {
    let token = std::env::var("TOKCAT_CLAUDE_OAUTH_TOKEN")
        .or_else(|_| std::env::var("CODEXBAR_CLAUDE_OAUTH_TOKEN"))
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let Some(access_token) = token else {
        return Ok(None);
    };
    let scopes = std::env::var("TOKCAT_CLAUDE_OAUTH_SCOPES")
        .or_else(|_| std::env::var("CODEXBAR_CLAUDE_OAUTH_SCOPES"))
        .unwrap_or_default()
        .split([',', ' '])
        .map(str::trim)
        .filter(|scope| !scope.is_empty())
        .map(str::to_string)
        .collect();
    Ok(Some(ClaudeCredentials {
        access_token,
        refresh_token: None,
        expires_at: None,
        scopes,
        rate_limit_tier: None,
        subscription_type: None,
    }))
}

fn parse_claude_credentials_data(raw: &str) -> Result<ClaudeCredentials, String> {
    let root: ClaudeCredentialsRoot =
        serde_json::from_str(raw).map_err(|e| format!("decode Claude OAuth credentials: {}", e))?;
    let oauth = root
        .claude_ai_oauth
        .ok_or_else(|| "Claude OAuth credentials are missing claudeAiOauth.".to_string())?;
    let access_token = oauth
        .access_token
        .map(|token| token.trim().to_string())
        .filter(|token| !token.is_empty())
        .ok_or_else(|| "Claude OAuth credentials have no access token.".to_string())?;
    let expires_at = oauth
        .expires_at
        .and_then(|millis| Utc.timestamp_millis_opt(millis as i64).single());
    Ok(ClaudeCredentials {
        access_token,
        refresh_token: oauth
            .refresh_token
            .map(|token| token.trim().to_string())
            .filter(|token| !token.is_empty()),
        expires_at,
        scopes: oauth.scopes.unwrap_or_default(),
        rate_limit_tier: oauth.rate_limit_tier,
        subscription_type: oauth.subscription_type,
    })
}

#[cfg(target_os = "macos")]
fn load_claude_credentials_from_keychain() -> Result<Option<String>, String> {
    let output = std::process::Command::new("/usr/bin/security")
        .args(["find-generic-password", "-s", CLAUDE_KEYCHAIN_SERVICE, "-w"])
        .output()
        .map_err(|e| format!("read Claude Keychain credentials: {}", e))?;
    if !output.status.success() {
        return Ok(None);
    }
    let raw = String::from_utf8(output.stdout)
        .map_err(|_| "Claude Keychain credentials are not UTF-8 JSON.".to_string())?;
    let raw = raw.trim_matches(['\r', '\n']).to_string();
    if raw.trim().is_empty() {
        return Ok(None);
    }
    Ok(Some(raw))
}

#[cfg(not(target_os = "macos"))]
fn load_claude_credentials_from_keychain() -> Result<Option<String>, String> {
    Ok(None)
}

async fn refresh_codex_credentials(
    credentials: CodexCredentials,
) -> Result<CodexCredentials, String> {
    let refresh_token = credentials
        .refresh_token
        .as_deref()
        .ok_or_else(|| "Codex auth.json has no refresh token.".to_string())?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("build Codex refresh client: {}", e))?;
    let body = serde_json::json!({
        "client_id": CODEX_CLIENT_ID,
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "scope": "openid profile email"
    });
    let response = client
        .post(CODEX_REFRESH_URL)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("Codex token refresh failed: {}", e))?;
    let status = response.status();
    let body = response
        .text()
        .await
        .map_err(|e| format!("read Codex refresh response: {}", e))?;
    if !status.is_success() {
        return Err("Codex OAuth refresh failed. Run `codex` to log in again.".to_string());
    }
    let json: Value =
        serde_json::from_str(&body).map_err(|e| format!("decode Codex refresh response: {}", e))?;

    let refreshed = CodexCredentials {
        access_token: json
            .get("access_token")
            .and_then(Value::as_str)
            .unwrap_or(&credentials.access_token)
            .to_string(),
        refresh_token: json
            .get("refresh_token")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or(credentials.refresh_token),
        id_token: json
            .get("id_token")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or(credentials.id_token),
        account_id: credentials.account_id,
        last_refresh: Some(Utc::now()),
        auth_path: credentials.auth_path,
        raw_json: credentials.raw_json,
    };
    save_codex_credentials(&refreshed)?;
    Ok(refreshed)
}

async fn refresh_claude_credentials(
    credentials: &ClaudeCredentials,
) -> Result<ClaudeCredentials, String> {
    let refresh_token = credentials.refresh_token.as_deref().ok_or_else(|| {
        "Claude OAuth token is expired and has no refresh token. Run `claude`.".to_string()
    })?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("build Claude refresh client: {}", e))?;
    let request_body = serde_json::json!({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": CLAUDE_CLIENT_ID,
        "scope": claude_refresh_scope(&credentials.scopes),
    });
    let response = client
        .post(CLAUDE_REFRESH_URL)
        .header(reqwest::header::ACCEPT, "application/json")
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .json(&request_body)
        .send()
        .await
        .map_err(|e| format!("Claude OAuth refresh failed: {}", e))?;
    let status = response.status();
    let body = response
        .text()
        .await
        .map_err(|e| format!("read Claude refresh response: {}", e))?;
    if !status.is_success() {
        return Err("Claude OAuth refresh failed. Run `claude` to re-authenticate.".to_string());
    }
    let token_response: ClaudeRefreshResponse = serde_json::from_str(&body)
        .map_err(|e| format!("decode Claude refresh response: {}", e))?;
    Ok(ClaudeCredentials {
        access_token: token_response.access_token,
        refresh_token: token_response
            .refresh_token
            .or_else(|| credentials.refresh_token.clone()),
        expires_at: Some(Utc::now() + chrono::Duration::seconds(token_response.expires_in)),
        scopes: credentials.scopes.clone(),
        rate_limit_tier: credentials.rate_limit_tier.clone(),
        subscription_type: credentials.subscription_type.clone(),
    })
}

fn claude_refresh_scope(scopes: &[String]) -> String {
    if scopes.is_empty() {
        CLAUDE_DEFAULT_SCOPES.to_string()
    } else {
        scopes.join(" ")
    }
}

fn save_codex_credentials(credentials: &CodexCredentials) -> Result<(), String> {
    let mut raw = credentials.raw_json.clone();
    raw["tokens"]["access_token"] = Value::String(credentials.access_token.clone());
    if let Some(refresh_token) = &credentials.refresh_token {
        raw["tokens"]["refresh_token"] = Value::String(refresh_token.clone());
    }
    if let Some(id_token) = &credentials.id_token {
        raw["tokens"]["id_token"] = Value::String(id_token.clone());
    }
    if let Some(account_id) = &credentials.account_id {
        raw["tokens"]["account_id"] = Value::String(account_id.clone());
    }
    raw["last_refresh"] = Value::String(Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true));
    let data =
        serde_json::to_vec_pretty(&raw).map_err(|e| format!("encode Codex auth.json: {}", e))?;
    fs::write(&credentials.auth_path, data).map_err(|e| format!("save Codex auth.json: {}", e))
}

fn codex_windows(
    rate_limit: Option<&CodexRateLimit>,
    additional_rate_limits: Option<&[CodexAdditionalRateLimit]>,
    spend_control: Option<&CodexSpendControl>,
    now: DateTime<Utc>,
) -> Vec<UsageWindow> {
    let mut windows = Vec::new();
    if let Some(rate_limit) = rate_limit {
        let mut primary = rate_limit.primary_window.clone();
        let mut secondary = rate_limit.secondary_window.clone();
        if role(primary.as_ref()) == Some("weekly") && role(secondary.as_ref()) != Some("weekly") {
            std::mem::swap(&mut primary, &mut secondary);
        }

        if let Some(window) = primary {
            windows.push(map_window("Session", window, now));
        }
        if let Some(window) = secondary {
            windows.push(map_window("Weekly", window, now));
        }
    }

    let mut seen = windows
        .iter()
        .map(|w| w.label.clone())
        .collect::<HashSet<_>>();
    for extra in additional_rate_limits.unwrap_or(&[]) {
        let Some(rate_limit) = extra.rate_limit.as_ref() else {
            continue;
        };
        let Some(window) = rate_limit
            .primary_window
            .clone()
            .or_else(|| rate_limit.secondary_window.clone())
        else {
            continue;
        };
        let label = additional_limit_label(extra);
        if seen.insert(label.clone()) {
            windows.push(map_window(&label, window, now));
        }
    }
    if let Some(window) = codex_spend_control_window(spend_control, now) {
        windows.push(window);
    }
    windows
}

fn codex_spend_control_window(
    spend_control: Option<&CodexSpendControl>,
    now: DateTime<Utc>,
) -> Option<UsageWindow> {
    let limit = spend_control?.individual_limit.as_ref()?;
    let used_percent = limit
        .used_percent
        .or_else(|| limit.remaining_percent.map(|remaining| 100.0 - remaining))
        .or_else(|| {
            let used = limit.used?;
            let total = limit.limit?;
            (total > 0.0).then_some((used / total) * 100.0)
        })?;
    Some(map_window(
        "Monthly spend",
        CodexWindow {
            used_percent,
            reset_at: limit.reset_at.unwrap_or_default(),
            limit_window_seconds: 0,
        },
        now,
    ))
}

fn claude_windows(usage: &ClaudeUsageResponse, now: DateTime<Utc>) -> Vec<UsageWindow> {
    let mut windows = Vec::new();
    push_claude_window(&mut windows, "Session", usage.five_hour.as_ref(), now);
    push_claude_window(&mut windows, "Weekly", usage.seven_day.as_ref(), now);
    push_claude_window(
        &mut windows,
        "OAuth Apps",
        usage.seven_day_oauth_apps.as_ref(),
        now,
    );
    push_claude_window(&mut windows, "Sonnet", usage.seven_day_sonnet.as_ref(), now);
    push_claude_window(&mut windows, "Opus", usage.seven_day_opus.as_ref(), now);
    push_claude_window(&mut windows, "Designs", usage.design_window(), now);
    push_claude_window(&mut windows, "Daily Routines", usage.routines_window(), now);
    if let Some(extra) = claude_extra_usage_window(usage.extra_usage.as_ref()) {
        windows.push(extra);
    }
    windows
}

impl ClaudeUsageResponse {
    fn design_window(&self) -> Option<&ClaudeWindow> {
        [
            self.seven_day_design.as_ref(),
            self.seven_day_claude_design.as_ref(),
            self.claude_design.as_ref(),
            self.design.as_ref(),
            self.seven_day_omelette.as_ref(),
            self.omelette.as_ref(),
            self.omelette_promotional.as_ref(),
        ]
        .into_iter()
        .flatten()
        .next()
    }

    fn routines_window(&self) -> Option<&ClaudeWindow> {
        [
            self.seven_day_routines.as_ref(),
            self.seven_day_claude_routines.as_ref(),
            self.claude_routines.as_ref(),
            self.routines.as_ref(),
            self.routine.as_ref(),
            self.seven_day_cowork.as_ref(),
            self.cowork.as_ref(),
        ]
        .into_iter()
        .flatten()
        .next()
    }
}

fn push_claude_window(
    windows: &mut Vec<UsageWindow>,
    label: &str,
    window: Option<&ClaudeWindow>,
    now: DateTime<Utc>,
) {
    if let Some(mapped) = window.and_then(|window| map_claude_window(label, window, now)) {
        windows.push(mapped);
    }
}

fn map_claude_window(
    label: &str,
    window: &ClaudeWindow,
    now: DateTime<Utc>,
) -> Option<UsageWindow> {
    let used = window.utilization?.clamp(0.0, 100.0);
    let resets_at = window.resets_at.as_deref().and_then(parse_datetime);
    Some(UsageWindow {
        label: label.to_string(),
        used_percent: used,
        remaining_percent: (100.0 - used).max(0.0),
        resets_at: resets_at.map(|date| date.to_rfc3339_opts(SecondsFormat::Millis, true)),
        reset_text: resets_at.map(|date| reset_text(date, now)),
    })
}

fn claude_extra_usage_window(extra: Option<&ClaudeExtraUsage>) -> Option<UsageWindow> {
    let extra = extra?;
    if !extra.is_enabled {
        return None;
    }
    let used = extra.utilization.or_else(|| {
        let used = extra.used_credits?;
        let limit = extra.monthly_limit?;
        if limit > 0.0 {
            Some((used / limit) * 100.0)
        } else {
            None
        }
    })?;
    let reset_text = match (extra.used_credits, extra.monthly_limit) {
        (Some(used), Some(limit)) => Some(format!(
            "Monthly cap: {} / {}",
            format_currency_minor_units(used, extra.currency.as_deref()),
            format_currency_minor_units(limit, extra.currency.as_deref())
        )),
        _ => None,
    };
    Some(UsageWindow {
        label: "Extra usage".to_string(),
        used_percent: used.clamp(0.0, 100.0),
        remaining_percent: (100.0 - used).max(0.0),
        resets_at: None,
        reset_text,
    })
}

fn claude_credits(extra: Option<&ClaudeExtraUsage>) -> Option<CreditsSnapshot> {
    let extra = extra?;
    if !extra.is_enabled {
        return None;
    }
    let remaining = match (extra.monthly_limit, extra.used_credits) {
        (Some(limit), Some(used)) => Some(((limit - used) / 100.0).max(0.0)),
        _ => None,
    };
    Some(CreditsSnapshot {
        remaining,
        unlimited: false,
    })
}

fn format_currency_minor_units(value: f64, currency: Option<&str>) -> String {
    let major = value / 100.0;
    match currency.unwrap_or("USD").trim().to_uppercase().as_str() {
        "USD" => format!("${:.2}", major),
        code if !code.is_empty() => format!("{:.2} {}", major, code),
        _ => format!("${:.2}", major),
    }
}

fn additional_limit_label(limit: &CodexAdditionalRateLimit) -> String {
    let source = first_non_empty([
        limit.limit_name.as_deref(),
        limit.metered_feature.as_deref(),
    ])
    .unwrap_or("Codex extra limit");
    let lower = source.to_lowercase();
    if lower.contains("spark") {
        return "Codex Spark".to_string();
    }
    clean_limit_label(source)
}

fn first_non_empty(values: [Option<&str>; 2]) -> Option<&str> {
    values
        .into_iter()
        .flatten()
        .map(str::trim)
        .find(|value| !value.is_empty())
}

fn clean_limit_label(value: &str) -> String {
    value
        .replace(['_', '-'], " ")
        .split_whitespace()
        .map(|part| {
            if part.eq_ignore_ascii_case("gpt") {
                "GPT".to_string()
            } else if part.eq_ignore_ascii_case("codex") {
                "Codex".to_string()
            } else {
                let mut chars = part.chars();
                match chars.next() {
                    Some(first) => format!("{}{}", first.to_uppercase(), chars.as_str()),
                    None => String::new(),
                }
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn map_window(label: &str, window: CodexWindow, now: DateTime<Utc>) -> UsageWindow {
    let resets_at = if window.reset_at > 0 {
        Utc.timestamp_opt(window.reset_at, 0).single()
    } else {
        None
    };
    let used = window.used_percent.clamp(0.0, 100.0);
    UsageWindow {
        label: label.to_string(),
        used_percent: used,
        remaining_percent: (100.0 - used).max(0.0),
        resets_at: resets_at.map(|date| date.to_rfc3339_opts(SecondsFormat::Millis, true)),
        reset_text: resets_at.map(|date| reset_text(date, now)),
    }
}

fn role(window: Option<&CodexWindow>) -> Option<&'static str> {
    match window?.limit_window_seconds {
        18_000 => Some("session"),
        604_800 => Some("weekly"),
        _ => None,
    }
}

fn reset_text(reset: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let seconds = (reset - now).num_seconds();
    if seconds <= 0 {
        return "Resets now".to_string();
    }
    let minutes = (seconds + 59) / 60;
    if minutes < 60 {
        return format!("Resets in {}m", minutes);
    }
    let hours = minutes / 60;
    let mins = minutes % 60;
    if hours < 48 {
        if mins > 0 {
            return format!("Resets in {}h {}m", hours, mins);
        }
        return format!("Resets in {}h", hours);
    }
    let days = hours / 24;
    let rem_hours = hours % 24;
    if rem_hours > 0 {
        format!("Resets in {}d {}h", days, rem_hours)
    } else {
        format!("Resets in {}d", days)
    }
}

fn codex_home() -> PathBuf {
    std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".codex")))
        .unwrap_or_else(|| PathBuf::from(".codex"))
}

fn claude_credentials_path() -> PathBuf {
    std::env::var_os("HOME")
        .map(|home| PathBuf::from(home).join(".claude/.credentials.json"))
        .unwrap_or_else(|| PathBuf::from(".claude/.credentials.json"))
}

// ---------------------------------------------------------------------------
// Grok Build quota (OAuth credits / task limits)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct GrokCredentials {
    token: String,
    email: Option<String>,
}

#[derive(Debug, Clone)]
struct GrokMetric {
    label: String,
    used_percent: f64,
    remaining_percent: f64,
    remaining_label: Option<String>,
    resets_at: Option<String>,
}

#[derive(Debug)]
enum GrokProtoValue<'a> {
    Varint(u64),
    Fixed32(u32),
    Fixed64,
    Bytes(&'a [u8]),
}

fn grok_home() -> PathBuf {
    std::env::var_os("GROK_HOME")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".grok")))
        .unwrap_or_else(|| PathBuf::from(".grok"))
}

fn grok_auth_path() -> PathBuf {
    grok_home().join("auth.json")
}

fn load_grok_credentials() -> Result<Vec<GrokCredentials>, String> {
    let path = grok_auth_path();
    let content = fs::read_to_string(&path).map_err(|_| {
        "Grok auth.json not found. Run `grok login` to authenticate.".to_string()
    })?;
    let doc: Value = serde_json::from_str(&content)
        .map_err(|e| format!("parse Grok auth.json: {e}"))?;
    grok_credential_candidates_from_value(&doc)
}

fn grok_credential_candidates_from_value(doc: &Value) -> Result<Vec<GrokCredentials>, String> {
    let entries = doc
        .as_object()
        .ok_or_else(|| "Grok auth.json must contain an object.".to_string())?;

    let mut candidates: Vec<(u8, GrokCredentials)> = entries
        .iter()
        .filter_map(|(scope, value)| {
            let entry = value.as_object()?;
            let token = entry
                .get("key")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())?
                .to_string();
            let email = entry
                .get("email")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map(ToString::to_string);
            let priority = if scope.contains("auth.x.ai") { 0 } else { 1 };
            Some((priority, GrokCredentials { token, email }))
        })
        .collect();

    candidates.sort_by_key(|(priority, _)| *priority);
    let credentials: Vec<_> = candidates
        .into_iter()
        .map(|(_, credentials)| credentials)
        .collect();

    if credentials.is_empty() {
        return Err("No Grok token found. Run `grok login`.".to_string());
    }
    Ok(credentials)
}

fn grok_bearer_request(
    client: &reqwest::Client,
    token: &str,
    url: &str,
) -> reqwest::RequestBuilder {
    client
        .get(url)
        .header("Authorization", format!("Bearer {token}"))
        .header("X-XAI-Token-Auth", "xai-grok-cli")
        .header("Accept", "application/json")
        .header("User-Agent", GROK_USER_AGENT)
}

async fn fetch_grok_network_usage(
    credentials: &GrokCredentials,
) -> Result<(Option<String>, Option<String>, Vec<UsageWindow>), String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(12))
        .build()
        .map_err(|e| format!("http client: {e}"))?;

    let mut plan: Option<String> = None;
    let mut metrics = Vec::new();
    let mut errors = Vec::new();
    let now = Utc::now();

    match fetch_grok_billing_grpc(&client, &credentials.token).await {
        Ok(body) => {
            if let Some(metric) = parse_grok_grpc_billing_metric(&body) {
                metrics.push(metric);
            } else {
                errors.push("Grok billing response was not recognized".to_string());
            }
        }
        Err(error) => errors.push(format!("Grok billing request failed: {error}")),
    }

    if metrics.is_empty() {
        match fetch_grok_task_usage(&client, &credentials.token).await {
            Ok(task_usage) => collect_grok_task_usage_metrics(&task_usage, &mut metrics),
            Err(error) => errors.push(format!("Grok task usage request failed: {error}")),
        }
    }

    match fetch_grok_subscriptions(&client, &credentials.token).await {
        Ok(subscriptions) => {
            plan = parse_grok_subscription_plan(&subscriptions);
        }
        Err(error) => errors.push(format!("Grok subscriptions request failed: {error}")),
    }

    if metrics.is_empty() && plan.is_none() {
        let detail = if errors.is_empty() {
            "no usage or active subscription data returned".to_string()
        } else {
            errors.join("; ")
        };
        return Err(detail);
    }

    let windows = metrics
        .into_iter()
        .map(|m| map_grok_metric(m, now))
        .collect();
    Ok((plan, credentials.email.clone(), windows))
}

async fn fetch_grok_subscriptions(
    client: &reqwest::Client,
    token: &str,
) -> Result<Value, String> {
    let resp = grok_bearer_request(client, token, GROK_SUBSCRIPTIONS_URL)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status();
    if !status.is_success() {
        return Err(format!("HTTP {status}"));
    }
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if text.trim_start().starts_with('<') {
        return Err("returned HTML".to_string());
    }
    serde_json::from_str(&text).map_err(|e| e.to_string())
}

async fn fetch_grok_task_usage(client: &reqwest::Client, token: &str) -> Result<Value, String> {
    let resp = grok_bearer_request(client, token, GROK_TASK_USAGE_URL)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status();
    if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
        return Err("NEEDS_AUTH".to_string());
    }
    if !status.is_success() {
        return Err(format!("HTTP {status}"));
    }
    resp.json().await.map_err(|e| e.to_string())
}

async fn fetch_grok_billing_grpc(
    client: &reqwest::Client,
    token: &str,
) -> Result<Vec<u8>, String> {
    let resp = client
        .post(GROK_BILLING_GRPC_URL)
        .header("Authorization", format!("Bearer {token}"))
        .header("X-XAI-Token-Auth", "xai-grok-cli")
        .header("Accept", "application/grpc-web+proto")
        .header("Content-Type", "application/grpc-web+proto")
        .header("User-Agent", GROK_USER_AGENT)
        .body(vec![0, 0, 0, 0, 0])
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status();
    if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
        return Err("NEEDS_AUTH".to_string());
    }
    if !status.is_success() {
        return Err(format!("HTTP {status}"));
    }
    Ok(resp.bytes().await.map_err(|e| e.to_string())?.to_vec())
}

fn resolve_grok_binary() -> PathBuf {
    // Packaged/menu-bar apps do not source shell rc, so `~/.grok/bin` is often
    // missing from PATH. Prefer the install locations Grok Build uses.
    if let Ok(home) = std::env::var("GROK_HOME") {
        let candidate = PathBuf::from(home).join("bin").join("grok");
        if candidate.is_file() {
            return candidate;
        }
    }
    if let Some(home) = std::env::var_os("HOME") {
        let candidate = PathBuf::from(home).join(".grok").join("bin").join("grok");
        if candidate.is_file() {
            return candidate;
        }
    }
    PathBuf::from("grok")
}

fn fetch_grok_agent_billing(timeout: Duration) -> Option<Value> {
    let mut child = Command::new(resolve_grok_binary())
        .args(["agent", "--no-leader", "stdio"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;

    let stdout = child.stdout.take()?;
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let reader = std::io::BufReader::new(stdout);
        for line in reader.lines().map_while(std::result::Result::ok) {
            let _ = tx.send(line);
        }
    });

    let result = (|| {
        let stdin = child.stdin.as_mut()?;
        let initialize = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "1",
                "clientCapabilities": {
                    "fs": { "readTextFile": false, "writeTextFile": false },
                    "terminal": false
                }
            }
        });
        let billing = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "x.ai/billing",
            "params": {}
        });
        writeln!(stdin, "{}", serde_json::to_string(&initialize).ok()?).ok()?;
        writeln!(stdin, "{}", serde_json::to_string(&billing).ok()?).ok()?;
        stdin.flush().ok()?;

        let response = wait_for_grok_rpc_response(&rx, 2, timeout)?;
        if response.get("error").is_some() {
            return None;
        }
        response.get("result").cloned()
    })();

    let _ = child.kill();
    let _ = child.wait();
    result
}

fn wait_for_grok_rpc_response(
    rx: &mpsc::Receiver<String>,
    expected_id: i64,
    timeout: Duration,
) -> Option<Value> {
    let deadline = Instant::now() + timeout;
    loop {
        let remaining = deadline.checked_duration_since(Instant::now())?;
        let line = rx.recv_timeout(remaining).ok()?;
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if value.get("id").and_then(Value::as_i64) == Some(expected_id) {
            return Some(value);
        }
    }
}

fn map_grok_metric(metric: GrokMetric, now: DateTime<Utc>) -> UsageWindow {
    let resets = metric
        .resets_at
        .as_deref()
        .and_then(parse_datetime);
    let reset_text = metric.remaining_label.or_else(|| {
        resets.map(|date| reset_text(date, now))
    });
    UsageWindow {
        label: metric.label,
        used_percent: metric.used_percent,
        remaining_percent: metric.remaining_percent,
        resets_at: resets.map(|date| date.to_rfc3339_opts(SecondsFormat::Millis, true)),
        reset_text,
    }
}

fn grok_title_words(raw: &str) -> String {
    raw.replace(['_', '-'], " ")
        .split_whitespace()
        .map(|word| {
            let lower = word.to_lowercase();
            let mut chars = lower.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn normalize_grok_subscription_tier(raw: &str) -> String {
    let trimmed = raw
        .trim_start_matches("SUBSCRIPTION_TIER_")
        .trim_start_matches("TIER_");
    grok_title_words(trimmed)
}

fn grok_subscription_is_active(status: &str) -> bool {
    // Real responses use `SUBSCRIPTION_STATUS_ACTIVE`; older/simple APIs
    // may use plain `active`. Avoid matching `…_INACTIVE`.
    let upper = status.trim().to_uppercase();
    upper == "ACTIVE" || upper.ends_with("STATUS_ACTIVE")
}

fn parse_grok_subscription_plan(value: &Value) -> Option<String> {
    let subscriptions = value.get("subscriptions")?.as_array()?;
    let chosen = subscriptions.iter().find(|sub| {
        sub.get("status")
            .and_then(Value::as_str)
            .map(grok_subscription_is_active)
            .unwrap_or(false)
    })?;
    let tier = chosen.get("tier").and_then(Value::as_str)?;
    Some(normalize_grok_subscription_tier(tier))
}

fn grok_numeric_value(value: &Value) -> Option<f64> {
    if let Some(number) = value.as_f64() {
        return number.is_finite().then_some(number);
    }
    if let Some(text) = value.as_str() {
        return text.parse::<f64>().ok().filter(|number| number.is_finite());
    }
    value
        .as_object()
        .and_then(|object| object.get("val").or_else(|| object.get("value")))
        .and_then(grok_numeric_value)
}

fn grok_number_at(value: &Value, path: &[&str]) -> Option<f64> {
    let mut current = value;
    for segment in path {
        current = current.get(*segment)?;
    }
    grok_numeric_value(current)
}

fn grok_string_at(value: &Value, path: &[&str]) -> Option<String> {
    let mut current = value;
    for segment in path {
        current = current.get(*segment)?;
    }
    current.as_str().map(ToString::to_string)
}

fn grok_epoch_at(value: &Value, path: &[&str]) -> Option<String> {
    grok_number_at(value, path).and_then(|ts| grok_epoch_to_rfc3339(ts as i64))
}

fn format_grok_cents(cents: f64) -> String {
    format!("${:.2}", cents / 100.0)
}

fn grok_cycle_label(start: Option<&str>, end: Option<&str>) -> String {
    let Some(start) = start else {
        return "Credits".into();
    };
    let Some(end) = end else {
        return "Credits".into();
    };
    let Ok(start) = DateTime::parse_from_rfc3339(start) else {
        return "Credits".into();
    };
    let Ok(end) = DateTime::parse_from_rfc3339(end) else {
        return "Credits".into();
    };
    let days = (end - start).num_days();
    if (6..=8).contains(&days) {
        "Weekly".into()
    } else if (27..=33).contains(&days) {
        "Monthly".into()
    } else {
        "Credits".into()
    }
}

fn parse_grok_billing_json_metric(value: &Value) -> Option<GrokMetric> {
    if let Some(metric) = parse_grok_billing_json_object(value) {
        return Some(metric);
    }
    match value {
        Value::Array(items) => items.iter().find_map(parse_grok_billing_json_metric),
        Value::Object(object) => object.values().find_map(parse_grok_billing_json_metric),
        _ => None,
    }
}

fn parse_grok_billing_json_object(value: &Value) -> Option<GrokMetric> {
    let monthly_limit = grok_number_at(value, &["monthlyLimit"])
        .or_else(|| grok_number_at(value, &["config", "monthlyLimit"]));
    let total_used = grok_number_at(value, &["usage", "totalUsed"])
        .or_else(|| grok_number_at(value, &["totalUsed"]))
        .or_else(|| grok_number_at(value, &["config", "usage", "totalUsed"]));
    let percent = if let (Some(limit), Some(used)) = (monthly_limit, total_used) {
        if limit > 0.0 {
            Some((used / limit * 100.0).clamp(0.0, 100.0))
        } else {
            None
        }
    } else {
        grok_number_at(value, &["usedPercent"])
            .or_else(|| grok_number_at(value, &["usagePercent"]))
            .or_else(|| grok_number_at(value, &["creditUsagePercent"]))
    }?;
    let percent = percent.is_finite().then(|| percent.clamp(0.0, 100.0))?;

    let start = grok_string_at(value, &["billingCycle", "billingPeriodStart"])
        .or_else(|| grok_string_at(value, &["billingPeriodStart"]))
        .or_else(|| grok_epoch_at(value, &["billingPeriodStart"]));
    let end = grok_string_at(value, &["billingCycle", "billingPeriodEnd"])
        .or_else(|| grok_string_at(value, &["billingPeriodEnd"]))
        .or_else(|| grok_epoch_at(value, &["billingPeriodEnd"]));

    let remaining_label = if let (Some(limit), Some(used)) = (monthly_limit, total_used) {
        let remaining = (limit - used).max(0.0);
        Some(format!(
            "{}/{} left",
            format_grok_cents(remaining),
            format_grok_cents(limit)
        ))
    } else {
        None
    };

    Some(GrokMetric {
        label: grok_cycle_label(start.as_deref(), end.as_deref()),
        used_percent: percent,
        remaining_percent: 100.0 - percent,
        remaining_label,
        resets_at: end,
    })
}

fn push_grok_limit_metric(
    metrics: &mut Vec<GrokMetric>,
    label: &str,
    used: Option<f64>,
    limit: Option<f64>,
    reset: Option<String>,
) {
    let Some(limit) = limit.filter(|limit| *limit > 0.0) else {
        return;
    };
    let used = used.unwrap_or(0.0).clamp(0.0, limit);
    let used_percent = (used / limit * 100.0).clamp(0.0, 100.0);
    let remaining_label = format!("{:.0}/{:.0} left", limit - used, limit);
    if metrics.iter().any(|metric| {
        metric.label == label
            && (metric.used_percent - used_percent).abs() < 0.0001
            && metric.remaining_label.as_deref() == Some(remaining_label.as_str())
    }) {
        return;
    }
    metrics.push(GrokMetric {
        label: label.into(),
        used_percent,
        remaining_percent: 100.0 - used_percent,
        remaining_label: Some(remaining_label),
        resets_at: reset,
    });
}

fn collect_grok_task_usage_metrics(value: &Value, metrics: &mut Vec<GrokMetric>) {
    if let Value::Object(object) = value {
        let reset = object
            .get("resetTime")
            .or_else(|| object.get("resetsAt"))
            .or_else(|| object.get("resetAt"))
            .and_then(Value::as_str)
            .map(ToString::to_string);
        push_grok_limit_metric(
            metrics,
            "Tasks",
            object.get("usage").and_then(grok_numeric_value),
            object.get("limit").and_then(grok_numeric_value),
            reset.clone(),
        );
        push_grok_limit_metric(
            metrics,
            "Frequent",
            object.get("frequentUsage").and_then(grok_numeric_value),
            object.get("frequentLimit").and_then(grok_numeric_value),
            reset.clone(),
        );
        push_grok_limit_metric(
            metrics,
            "Occasional",
            object.get("occasionalUsage").and_then(grok_numeric_value),
            object.get("occasionalLimit").and_then(grok_numeric_value),
            reset,
        );
        for child in object.values() {
            collect_grok_task_usage_metrics(child, metrics);
        }
    } else if let Value::Array(items) = value {
        for child in items {
            collect_grok_task_usage_metrics(child, metrics);
        }
    }
}

fn read_grok_varint(data: &[u8], pos: &mut usize) -> Option<u64> {
    let mut result = 0_u64;
    let mut shift = 0_u32;
    while *pos < data.len() && shift <= 63 {
        let byte = data[*pos];
        *pos += 1;
        result |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Some(result);
        }
        shift += 7;
    }
    None
}

fn next_grok_proto_field<'a>(
    data: &'a [u8],
    pos: &mut usize,
) -> Option<(u32, GrokProtoValue<'a>)> {
    let key = read_grok_varint(data, pos)?;
    let field = u32::try_from(key >> 3).ok()?;
    let wire = key & 0x07;
    match wire {
        0 => read_grok_varint(data, pos).map(|value| (field, GrokProtoValue::Varint(value))),
        1 => {
            if *pos + 8 > data.len() {
                return None;
            }
            *pos += 8;
            Some((field, GrokProtoValue::Fixed64))
        }
        2 => {
            let len = usize::try_from(read_grok_varint(data, pos)?).ok()?;
            if *pos + len > data.len() {
                return None;
            }
            let bytes = &data[*pos..*pos + len];
            *pos += len;
            Some((field, GrokProtoValue::Bytes(bytes)))
        }
        5 => {
            if *pos + 4 > data.len() {
                return None;
            }
            let value =
                u32::from_le_bytes([data[*pos], data[*pos + 1], data[*pos + 2], data[*pos + 3]]);
            *pos += 4;
            Some((field, GrokProtoValue::Fixed32(value)))
        }
        _ => None,
    }
}

fn grok_timestamp_message_to_rfc3339(data: &[u8]) -> Option<String> {
    let mut pos = 0;
    while pos < data.len() {
        let (field, value) = next_grok_proto_field(data, &mut pos)?;
        if field == 1 {
            if let GrokProtoValue::Varint(seconds) = value {
                return grok_epoch_to_rfc3339(i64::try_from(seconds).ok()?);
            }
        }
    }
    None
}

fn grok_epoch_to_rfc3339(seconds: i64) -> Option<String> {
    Utc.timestamp_opt(seconds, 0)
        .single()
        .map(|dt| dt.to_rfc3339())
}

fn parse_grok_billing_config_proto(data: &[u8]) -> Option<GrokMetric> {
    let mut pos = 0;
    let mut used_percent: Option<f64> = None;
    let mut start: Option<String> = None;
    let mut end: Option<String> = None;

    while pos < data.len() {
        let (field, value) = next_grok_proto_field(data, &mut pos)?;
        match (field, value) {
            (1, GrokProtoValue::Fixed32(bits)) => {
                let percent = f32::from_bits(bits) as f64;
                if percent.is_finite() {
                    used_percent = Some(percent.clamp(0.0, 100.0));
                }
            }
            (4, GrokProtoValue::Bytes(bytes)) => {
                start = grok_timestamp_message_to_rfc3339(bytes);
            }
            (5, GrokProtoValue::Bytes(bytes)) => {
                end = grok_timestamp_message_to_rfc3339(bytes);
            }
            _ => {}
        }
    }

    // Proto3 omits default fixed32 (0% used). If the frame only carries period
    // bounds, treat missing percent as zero instead of dropping the window.
    if used_percent.is_none() && start.is_none() && end.is_none() {
        return None;
    }
    let percent = used_percent.unwrap_or(0.0);
    Some(GrokMetric {
        label: grok_cycle_label(start.as_deref(), end.as_deref()),
        used_percent: percent,
        remaining_percent: 100.0 - percent,
        remaining_label: None,
        resets_at: end,
    })
}

fn parse_grok_grpc_billing_metric(body: &[u8]) -> Option<GrokMetric> {
    let mut pos = 0;
    while pos + 5 <= body.len() {
        let flag = body[pos];
        let len = u32::from_be_bytes([body[pos + 1], body[pos + 2], body[pos + 3], body[pos + 4]])
            as usize;
        pos += 5;
        if pos + len > body.len() {
            return None;
        }
        let payload = &body[pos..pos + len];
        pos += len;
        if flag & 0x80 != 0 {
            continue;
        }

        let mut payload_pos = 0;
        while payload_pos < payload.len() {
            let (field, value) = next_grok_proto_field(payload, &mut payload_pos)?;
            if field == 1 {
                if let GrokProtoValue::Bytes(config) = value {
                    if let Some(metric) = parse_grok_billing_config_proto(config) {
                        return Some(metric);
                    }
                }
            }
        }
    }
    None
}

fn credentials_needs_refresh(last_refresh: Option<DateTime<Utc>>) -> bool {
    let Some(last_refresh) = last_refresh else {
        return true;
    };
    (Utc::now() - last_refresh).num_days() > 8
}

fn claude_credentials_expired(credentials: &ClaudeCredentials) -> bool {
    credentials
        .expires_at
        .is_some_and(|expires_at| Utc::now() >= expires_at)
}

fn parse_datetime(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|dt| dt.with_timezone(&Utc))
        .ok()
}

fn claude_user_agent() -> String {
    std::process::Command::new("claude")
        .arg("--version")
        .output()
        .ok()
        .and_then(|output| {
            if output.status.success() {
                String::from_utf8(output.stdout).ok()
            } else {
                None
            }
        })
        .and_then(|stdout| stdout.split_whitespace().next().map(str::to_string))
        .filter(|version| !version.is_empty())
        .map(|version| format!("claude-code/{}", version))
        .unwrap_or_else(|| "claude-code/2.1.0".to_string())
}

fn string_key(
    map: &serde_json::Map<String, Value>,
    snake_case: &str,
    camel_case: &str,
) -> Option<String> {
    map.get(snake_case)
        .or_else(|| map.get(camel_case))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

fn jwt_payload(token: &str) -> Option<Value> {
    let payload = token.split('.').nth(1)?;
    let mut encoded = payload.replace('-', "+").replace('_', "/");
    while encoded.len() % 4 != 0 {
        encoded.push('=');
    }
    use base64::Engine;
    let data = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .ok()?;
    serde_json::from_slice(&data).ok()
}

fn jwt_email(token: &str) -> Option<String> {
    let payload = jwt_payload(token)?;
    payload
        .get("email")
        .and_then(Value::as_str)
        .or_else(|| {
            payload
                .get("https://api.openai.com/profile")
                .and_then(Value::as_object)
                .and_then(|profile| profile.get("email"))
                .and_then(Value::as_str)
        })
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

fn jwt_plan(token: &str) -> Option<String> {
    let payload = jwt_payload(token)?;
    payload
        .get("chatgpt_plan_type")
        .and_then(Value::as_str)
        .or_else(|| {
            payload
                .get("https://api.openai.com/auth")
                .and_then(Value::as_object)
                .and_then(|auth| auth.get("chatgpt_plan_type"))
                .and_then(Value::as_str)
        })
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

fn clean_plan(value: impl AsRef<str>) -> String {
    value
        .as_ref()
        .split(['_', '-'])
        .filter(|part| !part.is_empty())
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                Some(first) => format!("{}{}", first.to_uppercase(), chars.as_str()),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn deserialize_optional_f64<'de, D>(deserializer: D) -> Result<Option<f64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<Value>::deserialize(deserializer)?;
    Ok(match value {
        Some(Value::Number(n)) => n.as_f64(),
        Some(Value::String(s)) => s.parse::<f64>().ok(),
        _ => None,
    })
}

fn deserialize_optional_i64<'de, D>(deserializer: D) -> Result<Option<i64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<Value>::deserialize(deserializer)?;
    Ok(match value {
        Some(Value::Number(n)) => n.as_i64(),
        Some(Value::String(s)) => s.parse::<i64>().ok(),
        _ => None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_tile_gated_on_auth_json_presence() {
        // The agent-limits panel hides Codex unless it's actually set up. The
        // gate is the presence of auth.json under CODEX_HOME — a missing file
        // means "not installed / not logged in" and the tile stays hidden.
        let dir =
            std::env::temp_dir().join(format!("tokcat-codex-cfg-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::env::set_var("CODEX_HOME", &dir);

        assert!(
            !codex_is_configured(),
            "no auth.json under CODEX_HOME => Codex not configured"
        );

        std::fs::write(dir.join("auth.json"), "{}").unwrap();
        assert!(
            codex_is_configured(),
            "auth.json present => Codex configured"
        );

        std::env::remove_var("CODEX_HOME");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn maps_codex_primary_and_secondary_windows() {
        let now = Utc.timestamp_opt(1_700_000_000, 0).single().unwrap();
        let rate_limit = CodexRateLimit {
            primary_window: Some(CodexWindow {
                used_percent: 8.0,
                reset_at: 1_700_005_400,
                limit_window_seconds: 18_000,
            }),
            secondary_window: Some(CodexWindow {
                used_percent: 35.0,
                reset_at: 1_700_172_800,
                limit_window_seconds: 604_800,
            }),
        };
        let windows = codex_windows(Some(&rate_limit), None, None, now);
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].label, "Session");
        assert_eq!(windows[0].remaining_percent, 92.0);
        assert_eq!(windows[1].label, "Weekly");
        assert_eq!(windows[1].remaining_percent, 65.0);
    }

    #[test]
    fn maps_codex_additional_model_limits() {
        let now = Utc.timestamp_opt(1_700_000_000, 0).single().unwrap();
        let extra = CodexAdditionalRateLimit {
            limit_name: Some("gpt-5.2-codex-spark".to_string()),
            metered_feature: None,
            rate_limit: Some(CodexRateLimit {
                primary_window: Some(CodexWindow {
                    used_percent: 41.0,
                    reset_at: 1_700_003_600,
                    limit_window_seconds: 18_000,
                }),
                secondary_window: None,
            }),
        };
        let windows = codex_windows(None, Some(&[extra]), None, now);
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].label, "Codex Spark");
        assert_eq!(windows[0].remaining_percent, 59.0);
    }

    #[test]
    fn maps_codex_business_spend_control() {
        let raw = r#"{
            "plan_type": "business",
            "rate_limit": null,
            "additional_rate_limits": null,
            "credits": {
                "has_credits": true,
                "unlimited": false,
                "balance": "910"
            },
            "spend_control": {
                "reached": false,
                "individual_limit": {
                    "source": "account_user_spend_controls",
                    "limit": "1000",
                    "used": "90",
                    "remaining": "910",
                    "used_percent": 9,
                    "remaining_percent": 91,
                    "reset_after_seconds": 1426374,
                    "reset_at": 1785542400
                }
            }
        }"#;
        let usage: CodexUsageResponse = serde_json::from_str(raw).unwrap();
        let now = Utc.timestamp_opt(1_768_435_200, 0).single().unwrap();
        let windows = codex_windows(
            usage.rate_limit.as_ref(),
            usage.additional_rate_limits.as_deref(),
            usage.spend_control.as_ref(),
            now,
        );
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].label, "Monthly spend");
        assert_eq!(windows[0].used_percent, 9.0);
        assert_eq!(windows[0].remaining_percent, 91.0);
        assert_eq!(
            windows[0].resets_at.as_deref(),
            Some("2026-08-01T00:00:00.000Z")
        );
    }

    #[test]
    fn derives_codex_spend_percent_when_api_omits_percentages() {
        let spend_control = CodexSpendControl {
            individual_limit: Some(CodexSpendLimit {
                limit: Some(200.0),
                used: Some(50.0),
                used_percent: None,
                remaining_percent: None,
                reset_at: None,
            }),
        };
        let now = Utc.timestamp_opt(1_700_000_000, 0).single().unwrap();
        let window = codex_spend_control_window(Some(&spend_control), now).unwrap();
        assert_eq!(window.used_percent, 25.0);
        assert_eq!(window.remaining_percent, 75.0);
        assert_eq!(window.resets_at, None);
        assert_eq!(window.reset_text, None);
    }

    #[test]
    fn parses_claude_credentials_file() {
        let raw = r#"{
            "claudeAiOauth": {
                "accessToken": "access",
                "refreshToken": "refresh",
                "expiresAt": 1700000000000,
                "scopes": ["user:profile"],
                "rateLimitTier": "max",
                "subscriptionType": "pro"
            }
        }"#;
        let credentials = parse_claude_credentials_data(raw).unwrap();
        assert_eq!(credentials.access_token, "access");
        assert_eq!(credentials.refresh_token.as_deref(), Some("refresh"));
        assert_eq!(credentials.scopes, vec!["user:profile"]);
        assert_eq!(credentials.subscription_type.as_deref(), Some("pro"));
    }

    #[test]
    fn builds_claude_refresh_scope_from_credentials() {
        let scopes = vec![
            "user:profile".to_string(),
            "user:inference".to_string(),
            "user:sessions:claude_code".to_string(),
        ];
        assert_eq!(
            claude_refresh_scope(&scopes),
            "user:profile user:inference user:sessions:claude_code"
        );
        assert_eq!(claude_refresh_scope(&[]), CLAUDE_DEFAULT_SCOPES);
    }

    #[test]
    fn maps_claude_oauth_windows() {
        let now = Utc.timestamp_opt(1_700_000_000, 0).single().unwrap();
        let usage = ClaudeUsageResponse {
            five_hour: Some(ClaudeWindow {
                utilization: Some(8.0),
                resets_at: Some("2023-11-14T23:13:20Z".to_string()),
            }),
            seven_day: Some(ClaudeWindow {
                utilization: Some(23.0),
                resets_at: Some("2023-11-17T22:13:20Z".to_string()),
            }),
            seven_day_oauth_apps: None,
            seven_day_opus: None,
            seven_day_sonnet: Some(ClaudeWindow {
                utilization: Some(3.0),
                resets_at: None,
            }),
            seven_day_design: Some(ClaudeWindow {
                utilization: Some(0.0),
                resets_at: None,
            }),
            seven_day_routines: None,
            extra_usage: None,
            ..Default::default()
        };
        let windows = claude_windows(&usage, now);
        assert_eq!(windows.len(), 4);
        assert_eq!(windows[0].label, "Session");
        assert_eq!(windows[0].remaining_percent, 92.0);
        assert_eq!(windows[1].label, "Weekly");
        assert_eq!(windows[1].remaining_percent, 77.0);
        assert_eq!(windows[2].label, "Sonnet");
        assert_eq!(windows[2].remaining_percent, 97.0);
        assert_eq!(windows[3].label, "Designs");
        assert_eq!(windows[3].remaining_percent, 100.0);
    }

    #[test]
    fn decodes_claude_alias_windows_without_duplicate_error() {
        let raw = r#"{
            "five_hour": { "utilization": 5, "resets_at": "2026-05-28T14:00:00Z" },
            "seven_day": { "utilization": 23, "resets_at": "2026-05-31T14:00:00Z" },
            "seven_day_sonnet": { "utilization": 3, "resets_at": null },
            "seven_day_omelette": { "utilization": 0, "resets_at": null },
            "omelette_promotional": { "utilization": 0, "resets_at": null },
            "seven_day_cowork": { "utilization": 0, "resets_at": null }
        }"#;
        let usage: ClaudeUsageResponse = serde_json::from_str(raw).unwrap();
        let now = Utc.timestamp_opt(1_700_000_000, 0).single().unwrap();
        let windows = claude_windows(&usage, now);
        assert_eq!(
            windows.iter().map(|w| w.label.as_str()).collect::<Vec<_>>(),
            vec!["Session", "Weekly", "Sonnet", "Designs", "Daily Routines"]
        );
    }

    /// Serializes tests that mutate process-global `GROK_HOME`.
    static GROK_HOME_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn grok_tile_gated_on_auth_json_presence() {
        let _guard = GROK_HOME_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let dir = std::env::temp_dir().join(format!("tokcat-grok-cfg-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::env::set_var("GROK_HOME", &dir);

        assert!(!grok_is_configured(), "no auth.json => Grok not configured");
        std::fs::write(dir.join("auth.json"), "{}").unwrap();
        assert!(grok_is_configured(), "auth.json present => Grok configured");

        std::env::remove_var("GROK_HOME");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn resolve_grok_binary_prefers_grok_home_bin() {
        let _guard = GROK_HOME_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let dir = std::env::temp_dir().join(format!("tokcat-grok-bin-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let bin_dir = dir.join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();
        let binary = bin_dir.join("grok");
        std::fs::write(&binary, b"#!/bin/sh\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&binary).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&binary, perms).unwrap();
        }
        std::env::set_var("GROK_HOME", &dir);
        assert_eq!(resolve_grok_binary(), binary);
        std::env::remove_var("GROK_HOME");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn reads_grok_credentials_auth_scope_first() {
        let value = serde_json::json!({
            "https://example.com": {
                "key": "secondary-token",
                "email": "secondary@example.com"
            },
            "https://auth.x.ai": {
                "key": "primary-token",
                "email": "primary@example.com"
            }
        });
        let credentials = grok_credential_candidates_from_value(&value).unwrap();
        assert_eq!(credentials.len(), 2);
        assert_eq!(credentials[0].token, "primary-token");
        assert_eq!(credentials[0].email.as_deref(), Some("primary@example.com"));
    }

    #[test]
    fn parses_grok_billing_json_metric() {
        let value = serde_json::json!({
            "billingCycle": {
                "billingPeriodStart": "2026-06-01T00:00:00Z",
                "billingPeriodEnd": "2026-07-01T00:00:00Z"
            },
            "monthlyLimit": { "val": 10000 },
            "usage": {
                "totalUsed": { "val": 1250 }
            }
        });
        let metric = parse_grok_billing_json_metric(&value).expect("billing metric");
        assert_eq!(metric.label, "Monthly");
        assert!((metric.used_percent - 12.5).abs() < 1e-9);
        assert_eq!(
            metric.remaining_label.as_deref(),
            Some("$87.50/$100.00 left")
        );
        let now = Utc.timestamp_opt(1_700_000_000, 0).single().unwrap();
        let window = map_grok_metric(metric, now);
        assert_eq!(window.label, "Monthly");
        assert!((window.remaining_percent - 87.5).abs() < 1e-9);
        assert_eq!(
            window.reset_text.as_deref(),
            Some("$87.50/$100.00 left")
        );
    }

    #[test]
    fn parses_grok_task_usage_metrics() {
        let value = serde_json::json!({
            "frequentUsage": 3,
            "frequentLimit": 10,
            "occasionalUsage": 1,
            "occasionalLimit": 5
        });
        let mut metrics = Vec::new();
        collect_grok_task_usage_metrics(&value, &mut metrics);
        assert_eq!(metrics.len(), 2);
        assert_eq!(metrics[0].label, "Frequent");
        assert!((metrics[0].used_percent - 30.0).abs() < 1e-9);
        assert_eq!(metrics[1].label, "Occasional");
        assert!((metrics[1].used_percent - 20.0).abs() < 1e-9);
    }

    #[test]
    fn parses_grok_subscription_plan() {
        let value = serde_json::json!({
            "subscriptions": [
                {
                    "tier": "SUBSCRIPTION_TIER_SUPER_GROK_PRO",
                    "status": "SUBSCRIPTION_STATUS_ACTIVE"
                }
            ]
        });
        assert_eq!(
            parse_grok_subscription_plan(&value).as_deref(),
            Some("Super Grok Pro")
        );

        let inactive = serde_json::json!({
            "subscriptions": [
                {
                    "tier": "SUBSCRIPTION_TIER_SUPER_GROK_PRO",
                    "status": "SUBSCRIPTION_STATUS_INACTIVE"
                }
            ]
        });
        assert_eq!(parse_grok_subscription_plan(&inactive), None);
    }

    #[test]
    fn parses_grok_grpc_billing_percent_frame() {
        fn push_varint(mut value: u64, out: &mut Vec<u8>) {
            while value >= 0x80 {
                out.push((value as u8 & 0x7f) | 0x80);
                value >>= 7;
            }
            out.push(value as u8);
        }
        fn push_len_field(field: u64, payload: &[u8], out: &mut Vec<u8>) {
            push_varint((field << 3) | 2, out);
            push_varint(payload.len() as u64, out);
            out.extend_from_slice(payload);
        }
        fn push_fixed32_field(field: u64, value: u32, out: &mut Vec<u8>) {
            push_varint((field << 3) | 5, out);
            out.extend_from_slice(&value.to_le_bytes());
        }
        fn timestamp_message(seconds: u64) -> Vec<u8> {
            let mut out = Vec::new();
            push_varint(1 << 3, &mut out);
            push_varint(seconds, &mut out);
            out
        }

        let mut config = Vec::new();
        push_fixed32_field(1, 25.0_f32.to_bits(), &mut config);
        push_len_field(4, &timestamp_message(1_780_272_000), &mut config);
        push_len_field(5, &timestamp_message(1_782_864_000), &mut config);

        let mut message = Vec::new();
        push_len_field(1, &config, &mut message);

        let mut frame = Vec::new();
        frame.push(0);
        frame.extend_from_slice(&(message.len() as u32).to_be_bytes());
        frame.extend_from_slice(&message);

        let metric = parse_grok_grpc_billing_metric(&frame).expect("billing metric");
        assert_eq!(metric.label, "Monthly");
        assert!((metric.used_percent - 25.0).abs() < 1e-6);
        assert!(metric.resets_at.is_some());
    }

    #[test]
    fn parses_grok_grpc_billing_with_omitted_zero_percent() {
        // Period bounds only — proto3 omits default 0% fixed32 field 1.
        fn push_varint(mut value: u64, out: &mut Vec<u8>) {
            while value >= 0x80 {
                out.push((value as u8 & 0x7f) | 0x80);
                value >>= 7;
            }
            out.push(value as u8);
        }
        fn push_len_field(field: u64, payload: &[u8], out: &mut Vec<u8>) {
            push_varint((field << 3) | 2, out);
            push_varint(payload.len() as u64, out);
            out.extend_from_slice(payload);
        }
        fn timestamp_message(seconds: u64) -> Vec<u8> {
            let mut out = Vec::new();
            push_varint(1 << 3, &mut out);
            push_varint(seconds, &mut out);
            out
        }

        let mut config = Vec::new();
        push_len_field(4, &timestamp_message(1_780_272_000), &mut config);
        push_len_field(5, &timestamp_message(1_782_864_000), &mut config);

        let mut message = Vec::new();
        push_len_field(1, &config, &mut message);

        let mut frame = Vec::new();
        frame.push(0);
        frame.extend_from_slice(&(message.len() as u32).to_be_bytes());
        frame.extend_from_slice(&message);

        let metric = parse_grok_grpc_billing_metric(&frame).expect("zero-usage billing");
        assert_eq!(metric.label, "Monthly");
        assert!((metric.used_percent - 0.0).abs() < 1e-9);
        assert!((metric.remaining_percent - 100.0).abs() < 1e-9);
    }
}
