import React from 'react'
import { TraceBucket } from '../lib/usage'
import { humanizeTokens } from '../lib/format'

interface Props {
  buckets: TraceBucket[]
  windowSecs: number
}

const CLIENT_LABEL: Record<string, string> = {
  'claude-code': 'Claude Code',
}

function clientLabel(id: string): string {
  return CLIENT_LABEL[id] ?? id
}

export function UsageTraceCard({ buckets, windowSecs }: Props) {
  const top = buckets.slice(0, 5)
  const max = top.reduce((m, b) => Math.max(m, b.tokens_per_min), 0)
  const totalRate = buckets.reduce((s, b) => s + b.tokens_per_min, 0)
  const windowMin = Math.max(1, Math.round(windowSecs / 60))

  return (
    <div className="trace-card">
      <div className="trace-head">
        <h2 className="trace-heading">Live trace</h2>
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
