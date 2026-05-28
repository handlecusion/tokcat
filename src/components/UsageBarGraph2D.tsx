import React, { useMemo, useState } from 'react'
import { getClientStyle } from '../lib/clients'
import { addDays, formatCost, formatMonthDay, isoDate, parseISODate } from '../lib/format'
import type { Contribution, TokenBreakdown, UsagePayload } from '../lib/types'

interface Props {
  payload: UsagePayload
  clientIds: string[]
  title: string
  subtitle?: string
}

interface Segment {
  clientId: string
  tokens: number
  cost: number
}

interface DayBar {
  date: string
  totalTokens: number
  totalCost: number
  segments: Segment[]
}

interface HoverState {
  bar: DayBar
  left: string
  top: string
  transform: string
}

const DAYS = 30

function tokenTotal(tokens: TokenBreakdown): number {
  return (
    (tokens.input || 0) +
    (tokens.output || 0) +
    (tokens.cacheRead || 0) +
    (tokens.cacheWrite || 0) +
    (tokens.reasoning || 0)
  )
}

function dayFromContribution(contribution: Contribution, allowed: Set<string>): DayBar {
  const grouped = new Map<string, Segment>()
  for (const client of contribution.clients) {
    if (!allowed.has(client.client)) continue
    const tokens = tokenTotal(client.tokens)
    if (tokens <= 0 && (client.cost || 0) <= 0) continue
    const slot = grouped.get(client.client) ?? {
      clientId: client.client,
      tokens: 0,
      cost: 0,
    }
    slot.tokens += tokens
    slot.cost += client.cost || 0
    grouped.set(client.client, slot)
  }
  const segments = Array.from(grouped.values()).sort((a, b) => a.clientId.localeCompare(b.clientId))
  return {
    date: contribution.date,
    totalTokens: segments.reduce((sum, s) => sum + s.tokens, 0),
    totalCost: segments.reduce((sum, s) => sum + s.cost, 0),
    segments,
  }
}

function exactTokens(tokens: number): string {
  return tokens.toLocaleString('en-US')
}

export function UsageBarGraph2D({ payload, clientIds, title, subtitle }: Props) {
  const [hover, setHover] = useState<HoverState | null>(null)
  const bars = useMemo(() => {
    const allowed = new Set(clientIds)
    const byDate = new Map<string, DayBar>()
    for (const contribution of payload.contributions) {
      const day = dayFromContribution(contribution, allowed)
      if (day.totalTokens > 0 || day.totalCost > 0) byDate.set(day.date, day)
    }

    const fallbackEnd = isoDate(new Date())
    const end = payload.meta.dateRange.end || fallbackEnd
    const endDate = parseISODate(end)
    const startDate = addDays(endDate, -(DAYS - 1))
    const series: DayBar[] = []
    for (let i = 0; i < DAYS; i += 1) {
      const date = isoDate(addDays(startDate, i))
      series.push(byDate.get(date) ?? { date, totalTokens: 0, totalCost: 0, segments: [] })
    }
    return series
  }, [clientIds, payload])

  const maxTokens = Math.max(1, ...bars.map(b => b.totalTokens))
  const width = 520
  const height = 164
  const top = 14
  const bottom = 24
  const chartHeight = height - top - bottom
  const gap = 4
  const barWidth = (width - gap * (bars.length - 1)) / bars.length
  const activeClients = clientIds.map(id => getClientStyle(id))

  function showTooltip(bar: DayBar, index: number) {
    if (bar.totalTokens <= 0 && bar.totalCost <= 0) return
    const x = index * (barWidth + gap)
    const totalHeight = (bar.totalTokens / maxTokens) * chartHeight
    const centerX = ((x + barWidth / 2) / width) * 100
    const topY = ((height - bottom - Math.max(totalHeight, 4) - 8) / height) * 100
    const transform =
      centerX > 74
        ? 'translate(-100%, calc(-100% - 8px))'
        : centerX < 26
          ? 'translate(0, calc(-100% - 8px))'
          : 'translate(-50%, calc(-100% - 8px))'
    setHover({
      bar,
      left: `${centerX}%`,
      top: `${Math.max(6, topY)}%`,
      transform,
    })
  }

  return (
    <div className="bar2d-card">
      <div className="bar2d-head">
        <div>
          <h2 className="bar2d-title">{title}</h2>
          {subtitle && <div className="bar2d-sub">{subtitle}</div>}
        </div>
        <div className="bar2d-legend">
          {activeClients.slice(0, 5).map(style => (
            <span key={style.id} className="bar2d-legend-item">
              <span className="bar2d-dot" style={{ background: style.color }} />
              {style.displayName.replace(/\s+(CLI|Code|IDE)$/i, '')}
            </span>
          ))}
        </div>
      </div>

      <div className="bar2d-chart" onMouseLeave={() => setHover(null)}>
        <svg className="bar2d-svg" viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none">
          <line x1="0" x2={width} y1={height - bottom} y2={height - bottom} className="bar2d-axis" />
          {bars.map((bar, index) => {
            const x = index * (barWidth + gap)
            const totalHeight = (bar.totalTokens / maxTokens) * chartHeight
            let y = height - bottom
            return (
              <g key={bar.date}>
                {bar.segments.map(segment => {
                  const h = bar.totalTokens > 0 ? (segment.tokens / bar.totalTokens) * totalHeight : 0
                  y -= h
                  const color = getClientStyle(segment.clientId).color
                  return (
                    <rect
                      key={segment.clientId}
                      x={x}
                      y={y}
                      width={barWidth}
                      height={Math.max(0, h)}
                      rx={2}
                      fill={color}
                      opacity={0.86}
                    >
                      <title>
                        {`${formatMonthDay(bar.date)} • ${getClientStyle(segment.clientId).displayName} • ${exactTokens(segment.tokens)} tokens • ${formatCost(segment.cost)}`}
                      </title>
                    </rect>
                  )
                })}
                {bar.totalTokens === 0 && (
                  <rect x={x} y={height - bottom - 2} width={barWidth} height={2} rx={1} className="bar2d-empty" />
                )}
                {(bar.totalTokens > 0 || bar.totalCost > 0) && (
                  <rect
                    className="bar2d-hit"
                    x={x}
                    y={top}
                    width={barWidth}
                    height={chartHeight}
                    tabIndex={0}
                    role="img"
                    aria-label={`${formatMonthDay(bar.date)}, ${exactTokens(bar.totalTokens)} tokens, ${formatCost(bar.totalCost)}`}
                    onMouseEnter={() => showTooltip(bar, index)}
                    onMouseMove={() => showTooltip(bar, index)}
                    onFocus={() => showTooltip(bar, index)}
                    onBlur={() => setHover(null)}
                  />
                )}
              </g>
            )
          })}
          <text x="0" y={height - 6} className="bar2d-label">{formatMonthDay(bars[0]?.date ?? '')}</text>
          <text x={width} y={height - 6} textAnchor="end" className="bar2d-label">
            {formatMonthDay(bars[bars.length - 1]?.date ?? '')}
          </text>
        </svg>
        {hover && (
          <div
            className="bar2d-tooltip"
            style={{ left: hover.left, top: hover.top, transform: hover.transform }}
            role="status"
          >
            <div className="bar2d-tooltip-date">{formatMonthDay(hover.bar.date)}</div>
            <div className="bar2d-tooltip-total">
              <span>{exactTokens(hover.bar.totalTokens)} tokens</span>
              <span>{formatCost(hover.bar.totalCost)}</span>
            </div>
            <div className="bar2d-tooltip-rows">
              {hover.bar.segments.map(segment => {
                const style = getClientStyle(segment.clientId)
                return (
                  <div className="bar2d-tooltip-row" key={segment.clientId}>
                    <span className="bar2d-tooltip-name">
                      <span className="bar2d-tooltip-dot" style={{ background: style.color }} />
                      {style.displayName.replace(/\s+(CLI|Code|IDE)$/i, '')}
                    </span>
                    <span className="bar2d-tooltip-value">
                      {exactTokens(segment.tokens)} · {formatCost(segment.cost)}
                    </span>
                  </div>
                )
              })}
            </div>
          </div>
        )}
      </div>
    </div>
  )
}
