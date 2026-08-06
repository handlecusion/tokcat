// Parity dump bin: prints usage_graph output as JSON for diffing against the
// Swift `tokcat-dump` CLI (scripts/parity-check.sh).
//
//   usage_dump graph [--year YYYY] [--clients claude,codex]
//   usage_dump tail-sim --dir DIR [--window-secs N] [--now-ms N]
//
// tail-sim replays a fixture directory through the live tailer and dumps the
// event ring + trace as JSON. DIR is treated as a fake home: it may contain
// .claude/projects/**/*.jsonl, .codex/sessions/**/*.jsonl,
// .grok/sessions/**/updates.jsonl, and .hermes/state.db. Pass --now-ms with
// fixtures carrying fixed timestamps so window math is deterministic.

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("tail-sim") {
        return run_tail_sim(&args[1..]);
    }
    if args.first().map(String::as_str) != Some("graph") {
        eprintln!(
            "usage: usage_dump graph [--year YYYY] [--clients a,b]\n       \
             usage_dump tail-sim --dir DIR [--window-secs N] [--now-ms N]"
        );
        return ExitCode::from(2);
    }

    let mut year = String::new();
    // Default to the full ten-client roster so both dump CLIs stay
    // comparable even if one side's registry grows first; --clients still
    // overrides.
    let mut clients: Option<Vec<String>> = Some(
        [
            "claude", "codex", "cursor", "opencode", "gemini", "copilot", "amp", "droid",
            "hermes", "grok",
        ]
        .iter()
        .map(|c| c.to_string())
        .collect(),
    );
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--year" => {
                i += 1;
                year = args.get(i).cloned().unwrap_or_default();
            }
            "--clients" => {
                i += 1;
                let Some(list) = args.get(i) else {
                    eprintln!("--clients requires a value");
                    return ExitCode::from(2);
                };
                clients = Some(
                    list.split(',')
                        .map(|c| c.trim().to_string())
                        .filter(|c| !c.is_empty())
                        .collect(),
                );
            }
            other => {
                eprintln!("unknown arg: {}", other);
                return ExitCode::from(2);
            }
        }
        i += 1;
    }

    match tokcat_lib::usage_graph::run_filtered(&year, clients.as_deref()) {
        Ok(value) => {
            println!("{}", value);
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("{}", err);
            ExitCode::FAILURE
        }
    }
}

/// Replay DIR through the live tailer once (a single cold tick) and dump the
/// event ring, rates, and trace as sorted-key JSON. Note a cold tick stamps
/// Hermes baselines silently, so state.db fixtures yield no events here —
/// JSONL fixtures are the deterministic replay surface.
fn run_tail_sim(args: &[String]) -> ExitCode {
    let mut dir: Option<String> = None;
    let mut window_secs: i64 = 600;
    let mut now_ms: Option<i64> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--dir" => {
                i += 1;
                dir = args.get(i).cloned();
            }
            "--window-secs" => {
                i += 1;
                window_secs = match args.get(i).and_then(|v| v.parse().ok()) {
                    Some(v) => v,
                    None => {
                        eprintln!("--window-secs requires an integer");
                        return ExitCode::from(2);
                    }
                };
            }
            "--now-ms" => {
                i += 1;
                now_ms = match args.get(i).and_then(|v| v.parse().ok()) {
                    Some(v) => Some(v),
                    None => {
                        eprintln!("--now-ms requires an integer");
                        return ExitCode::from(2);
                    }
                };
            }
            other => {
                eprintln!("unknown arg: {}", other);
                return ExitCode::from(2);
            }
        }
        i += 1;
    }

    let Some(dir) = dir else {
        eprintln!("usage: usage_dump tail-sim --dir DIR [--window-secs N] [--now-ms N]");
        return ExitCode::from(2);
    };

    // Re-root every source under DIR. The tailer discovers roots from the
    // environment, so point HOME (claude/codex), GROK_HOME, and HERMES_HOME
    // at the fixture tree before it is constructed.
    std::env::set_var("HOME", &dir);
    std::env::set_var("GROK_HOME", format!("{}/.grok", dir));
    std::env::set_var("HERMES_HOME", format!("{}/.hermes", dir));

    let tailer = tokcat_lib::usage_tail::UsageTailer::new();
    tailer.set_now_override_ms(now_ms);
    let added = tailer.tick();

    // Deterministic output ordering: scan order depends on readdir order, so
    // sort events by all fields and break trace ties lexicographically.
    let mut events = tailer.events_snapshot();
    events.sort_by(|a, b| {
        (a.ts_ms, &a.client, &a.agent, &a.model, a.input, a.output, a.cache_read, a.cache_write)
            .cmp(&(
                b.ts_ms,
                &b.client,
                &b.agent,
                &b.model,
                b.input,
                b.output,
                b.cache_read,
                b.cache_write,
            ))
    });
    let mut trace = tailer.trace(window_secs);
    trace.sort_by(|a, b| {
        b.tokens
            .cmp(&a.tokens)
            .then_with(|| a.client.cmp(&b.client))
            .then_with(|| a.agent.cmp(&b.agent))
            .then_with(|| a.model.cmp(&b.model))
    });

    // serde_json::Map is a BTreeMap (sorted keys), matching the Swift
    // encoder's .sortedKeys output shape.
    let out = serde_json::json!({
        "added": added,
        "events": events,
        "rate_per_min": tailer.rate_per_min(),
        "rate_in_window": tailer.rate_in_window(window_secs),
        "trace": trace,
        "window_secs": window_secs,
    });
    println!("{}", out);
    ExitCode::SUCCESS
}
