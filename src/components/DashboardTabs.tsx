import React from 'react'
import { clientInitial, getClientStyle } from '../lib/clients'

interface Props {
  clients: string[]
  active: string
  onChange: (tab: string) => void
}

function ClientMark({ id }: { id: string }) {
  const style = getClientStyle(id)
  if (style.iconRaw) {
    return (
      <span
        className={`dash-tab-icon dash-tab-icon-${style.iconType}`}
        style={style.iconType === 'mono' ? { background: style.color } : undefined}
        aria-hidden="true"
        dangerouslySetInnerHTML={{ __html: style.iconRaw }}
      />
    )
  }
  return (
    <span className="dash-tab-icon" style={{ background: style.color }} aria-hidden="true">
      {clientInitial(style.displayName)}
    </span>
  )
}

export function DashboardTabs({ clients, active, onChange }: Props) {
  return (
    <div className="dash-tabs" role="tablist" aria-label="Dashboard sections">
      <button
        type="button"
        className={`dash-tab${active === 'overview' ? ' is-active' : ''}`}
        onClick={() => onChange('overview')}
        role="tab"
        aria-selected={active === 'overview'}
      >
        <span className="dash-tab-overview" aria-hidden="true">
          <span />
          <span />
          <span />
          <span />
        </span>
        <span>Overview</span>
      </button>
      {clients.map(id => {
        const style = getClientStyle(id)
        const isActive = active === id
        return (
          <button
            key={id}
            type="button"
            className={`dash-tab${isActive ? ' is-active' : ''}`}
            onClick={() => onChange(id)}
            role="tab"
            aria-selected={isActive}
          >
            <ClientMark id={id} />
            <span>{style.displayName.replace(/\s+(CLI|Code|IDE)$/i, '')}</span>
          </button>
        )
      })}
    </div>
  )
}
