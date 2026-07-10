import React from 'react'
import { TraceBucket } from '../lib/usage'
import { humanizeTokens } from '../lib/format'

interface Props {
  buckets: TraceBucket[]
  windowSecs: number
  detailed: boolean
  title?: string
}

const CLIENT_LABEL: Record<string, string> = {
  'claude-code': 'Claude Code',
  'codex-cli': 'Codex CLI',
  hermes: 'Hermes',
  grok: 'Grok Build',
}

function clientLabel(id: string): string {
  return CLIENT_LABEL[id] ?? id
}

// Collapse (client, agent, model) buckets to one row per client when the
// user prefers the compact view. Joins agent/model strings for the label.
function collapseByClient(buckets: TraceBucket[]): TraceBucket[] {
  const groups = new Map<string, TraceBucket & { agents: Set<string>; models: Set<string> }>()
  for (const b of buckets) {
    let slot = groups.get(b.client)
    if (!slot) {
      slot = {
        ...b,
        tokens: 0,
        messages: 0,
        tokens_per_min: 0,
        agents: new Set<string>(),
        models: new Set<string>(),
      }
      groups.set(b.client, slot)
    }
    slot.tokens += b.tokens
    slot.messages += b.messages
    slot.tokens_per_min += b.tokens_per_min
    slot.agents.add(b.agent)
    slot.models.add(b.model)
  }
  return Array.from(groups.values()).map(slot => {
    const agents = Array.from(slot.agents).sort()
    let models = Array.from(slot.models).sort()
    if (models.length > 1) models = models.filter(m => m !== 'unknown')
    return {
      client: slot.client,
      agent: agents.join(', '),
      model: models.join(', '),
      tokens: slot.tokens,
      messages: slot.messages,
      tokens_per_min: slot.tokens_per_min,
    }
  }).sort((a, b) => b.tokens - a.tokens)
}

export function UsageTraceCard({ buckets, windowSecs, detailed, title = 'Live trace' }: Props) {
  const rows = detailed ? buckets : collapseByClient(buckets)
  const top = rows.slice(0, 5)
  const max = top.reduce((m, b) => Math.max(m, b.tokens_per_min), 0)
  const totalRate = rows.reduce((s, b) => s + b.tokens_per_min, 0)
  const windowMin = Math.max(1, Math.round(windowSecs / 60))

  return (
    <div className="trace-card">
      <div className="trace-head">
        <h2 className="trace-heading">{title}</h2>
        <div className="trace-sub">
          last {windowMin}m · {humanizeTokens(Math.round(totalRate))}/m total
        </div>
      </div>
      {top.length === 0 ? (
        <div className="trace-empty">No activity in this window</div>
      ) : (
        <div className="trace-rows">
          {top.map(b => {
            const pct = max > 0 ? Math.max(4, (b.tokens_per_min / max) * 100) : 0
            return (
              <div className="trace-row" key={`${b.client}|${b.agent}|${b.model}`}>
                <div className="trace-row-meta">
                  <span className="trace-client">{clientLabel(b.client)}</span>
                  <span className="trace-agent">{b.agent}</span>
                  <span className="trace-model">{b.model}</span>
                </div>
                <div className="trace-row-bar">
                  <div className="trace-bar-fill" style={{ width: `${pct}%` }} />
                </div>
                <div className="trace-row-val">
                  {humanizeTokens(Math.round(b.tokens_per_min))}/m
                </div>
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
