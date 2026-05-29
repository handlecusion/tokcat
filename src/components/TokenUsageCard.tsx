import React from 'react'
import type { Stats } from '../lib/types'
import { formatCost, formatMMDD, formatMonthDay, humanizeTokens } from '../lib/format'

export function TokenUsageCard({ stats, bare = false }: { stats: Stats; bare?: boolean }) {
  const range = `${formatMMDD(stats.dateRange.start)} → ${formatMMDD(stats.dateRange.end)}`
  const grid = (
    <div className={`usage-row-card${bare ? ' is-bare' : ''}`}>
      <div className="usage-cell">
        <div className="usage-num">{formatCost(stats.totalCost)}</div>
        <div className="usage-label">Total</div>
        <div className="usage-sub">{range}</div>
      </div>
      <div className="usage-cell">
        <div className="usage-num">{humanizeTokens(stats.totalTokens)}</div>
        <div className="usage-label">Tokens</div>
        <div className="usage-sub">{stats.activeDays} active days</div>
      </div>
      <div className="usage-cell">
        <div className="usage-num">{stats.bestDay ? formatCost(stats.bestDay.cost) : '$0.00'}</div>
        <div className="usage-label">Best day</div>
        <div className="usage-sub">{stats.bestDay ? formatMonthDay(stats.bestDay.date) : '—'}</div>
      </div>
    </div>
  )
  if (bare) return grid
  return (
    <div className="usage-card">
      <h2 className="usage-heading">Token Usage</h2>
      {grid}
    </div>
  )
}
