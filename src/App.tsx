import React, { useEffect, useMemo, useRef, useState } from 'react'
import { Panel } from './components/Panel'
import { HeaderBar } from './components/HeaderBar'
import { StreaksCard } from './components/StreaksCard'
import { SettingsPanel } from './components/SettingsPanel'
import { AgentLimitsCard } from './components/AgentLimitsCard'
import { DashboardTabs } from './components/DashboardTabs'
import { UsageBarGraph2D, UsageView } from './components/UsageBarGraph2D'
import { buildGrid } from './lib/grid'
import { useGraphStream } from './hooks/useGraphStream'
import { useAgentUsage } from './hooks/useAgentUsage'
import { computeStats } from './lib/stats'
import { isTauri } from './lib/runtime'
import { computeTrayTitle, loadSettings, saveSettings, Settings } from './lib/settings'
import { TraceBucket, RateUpdate } from './lib/usage'
import { UsageTraceCard } from './components/UsageTraceCard'
import { checkForUpdatesSilent, checkForUpdatesInteractive } from './lib/updater'
import { getTheme, THEMES, ThemeName } from './lib/themes'
import { getClientStyle } from './lib/clients'

const THEME_KEY = 'tokcat:theme:v1'
const USAGE_VIEW_KEY = 'tokcat:usageview:v1'

function loadTheme(): ThemeName {
  try {
    const raw = localStorage.getItem(THEME_KEY)
    if (raw && THEMES.some(t => t.name === raw)) return raw as ThemeName
  } catch {}
  return 'Blue'
}

function loadUsageView(): UsageView {
  try {
    const raw = localStorage.getItem(USAGE_VIEW_KEY)
    if (raw === '2d' || raw === '3d') return raw
  } catch {}
  return '2d'
}

function defaultYear(): string {
  return String(new Date().getFullYear())
}

export default function App() {
  const [year, setYear] = useState<string>(defaultYear())
  const [refreshTick, setRefreshTick] = useState(0)
  const { payload, error } = useGraphStream(year)
  const agentUsage = useAgentUsage(refreshTick)
  const [theme, setTheme] = useState<ThemeName>(() => loadTheme())
  const [isDark, setIsDark] = useState<boolean>(() =>
    typeof window !== 'undefined' && window.matchMedia
      ? window.matchMedia('(prefers-color-scheme: dark)').matches
      : false
  )
  const [activeTab, setActiveTab] = useState<string>('overview')
  const [usageView, setUsageView] = useState<UsageView>(() => loadUsageView())
  const [settings, setSettings] = useState<Settings>(() => loadSettings())
  const [settingsOpen, setSettingsOpen] = useState(false)

  const [aboutOpen, setAboutOpen] = useState(false)
  const [appVersion, setAppVersion] = useState('')

  useEffect(() => {
    saveSettings(settings)
  }, [settings])

  useEffect(() => {
    try { localStorage.setItem(THEME_KEY, theme) } catch {}
  }, [theme])

  useEffect(() => {
    try { localStorage.setItem(USAGE_VIEW_KEY, usageView) } catch {}
  }, [usageView])

  useEffect(() => {
    if (typeof window === 'undefined' || !window.matchMedia) return
    const mql = window.matchMedia('(prefers-color-scheme: dark)')
    const handler = (e: MediaQueryListEvent) => setIsDark(e.matches)
    if (mql.addEventListener) mql.addEventListener('change', handler)
    else mql.addListener(handler)
    return () => {
      if (mql.removeEventListener) mql.removeEventListener('change', handler)
      else mql.removeListener(handler)
    }
  }, [])

  const palette = useMemo(() => getTheme(theme), [theme])
  const mode = isDark ? palette.dark : palette.light

  useEffect(() => {
    const root = document.documentElement
    root.style.setProperty('--blue', mode.accent)
    root.style.setProperty('--blue-light', mode.accent)
    root.style.setProperty('--blue-soft', mode.soft)
    root.style.setProperty('--chip-bg-on', mode.chipBg)
    root.style.setProperty('--chip-border-on', mode.chipBorder)
    root.style.setProperty('--chip-color-on', mode.chipColor)
  }, [mode.accent, mode.soft, mode.chipBg, mode.chipBorder, mode.chipColor])

  useEffect(() => {
    if (!isTauri()) return
    let unlisten: (() => void) | null = null
    ;(async () => {
      const { listen } = await import('@tauri-apps/api/event')
      unlisten = await listen<string>('tray-action', e => {
        const action = e.payload
        if (action === 'open-settings') setSettingsOpen(true)
        else if (action === 'open-about') setAboutOpen(true)
        else if (action === 'refresh') setRefreshTick(t => t + 1)
        else if (action === 'check-update') void checkForUpdatesInteractive()
      })
    })()
    return () => {
      if (unlisten) unlisten()
    }
  }, [])

  useEffect(() => {
    if (!aboutOpen) return
    if (!isTauri()) {
      setAppVersion('dev')
      return
    }

    let cancelled = false
    ;(async () => {
      try {
        const { getVersion } = await import('@tauri-apps/api/app')
        const version = await getVersion()
        if (!cancelled) setAppVersion(version)
      } catch {
        if (!cancelled) setAppVersion('')
      }
    })()

    return () => {
      cancelled = true
    }
  }, [aboutOpen])

  // Silent update check on startup, then every 30 min while the app runs.
  // Without the recurring tick, releases published after launch are only
  // surfaced on the next restart.
  useEffect(() => {
    if (!isTauri()) return
    void checkForUpdatesSilent()
    const id = window.setInterval(() => {
      void checkForUpdatesSilent()
    }, 30 * 60 * 1000)
    return () => window.clearInterval(id)
  }, [])

  // Manual refresh from tray menu — bypasses cache.
  useEffect(() => {
    if (refreshTick === 0) return
    if (!isTauri()) return
    ;(async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        await invoke('refresh_graph', { year })
      } catch {}
    })()
  }, [refreshTick, year])

  const allYears = useMemo(() => {
    if (!payload) return [year]
    return payload.years.map(y => y.year)
  }, [payload, year])

  const presentClients = useMemo(() => {
    if (!payload) return []
    const set = new Set<string>()
    for (const c of payload.contributions) for (const cc of c.clients) set.add(cc.client)
    return Array.from(set).sort()
  }, [payload])

  const dashboardClients = useMemo(() => {
    const set = new Set(presentClients)
    for (const agent of agentUsage.payload?.agents ?? []) set.add(agent.clientId)
    return Array.from(set).sort()
  }, [agentUsage.payload, presentClients])

  useEffect(() => {
    if (activeTab === 'overview') return
    if (!dashboardClients.includes(activeTab)) setActiveTab('overview')
  }, [activeTab, dashboardClients])

  const overviewClientSet = useMemo(() => new Set(presentClients), [presentClients])
  const activeClientIds = useMemo(
    () => (activeTab === 'overview' ? presentClients : [activeTab]),
    [activeTab, presentClients],
  )
  const activeClientSet = useMemo(() => new Set(activeClientIds), [activeClientIds])

  const overviewStats = useMemo(() => {
    if (!payload) return null
    return computeStats(payload, overviewClientSet)
  }, [overviewClientSet, payload])

  const activeStats = useMemo(() => {
    if (!payload) return null
    return computeStats(payload, activeClientSet)
  }, [activeClientSet, payload])

  // Calendar grids for the 3D usage view, one per visible card. Built from the
  // same per-day token totals the stats already aggregate, so 3D and 2D show
  // identical data for the selected year.
  const overviewGrid = useMemo(
    () => buildGrid(year, overviewStats?.perDayMap ?? new Map()),
    [year, overviewStats],
  )
  const activeGrid = useMemo(
    () => buildGrid(year, activeStats?.perDayMap ?? new Map()),
    [year, activeStats],
  )

  // Live tokens-per-minute + per-(client, agent, model) breakdown, pushed
  // by the backend's JSONL tailer every ~5s. No client-side diffing — the
  // tailer parses only growth since the last poll, so values stay accurate
  // even when the popover is closed and `stats` isn't refreshing.
  const [tokensPerMin, setTokensPerMin] = useState<number | null>(null)
  const [trace, setTrace] = useState<TraceBucket[]>([])
  useEffect(() => {
    if (!isTauri()) return
    let unlisten: (() => void) | null = null
    ;(async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        const { listen } = await import('@tauri-apps/api/event')
        const initial = await invoke<number>('get_tokens_per_min')
        setTokensPerMin(initial)
        const initialTrace = await invoke<TraceBucket[]>('get_usage_trace', {
          windowSecs: 600,
        })
        setTrace(initialTrace)
        unlisten = await listen<RateUpdate>('rate-update', e => {
          setTokensPerMin(e.payload.tokensPerMin)
          setTrace(e.payload.trace)
        })
      } catch {}
    })()
    return () => {
      if (unlisten) unlisten()
    }
  }, [])

  // Push tray title from the all-agent overview, regardless of the visible tab.
  useEffect(() => {
    if (!isTauri()) return
    const title = computeTrayTitle(settings.trayMode, overviewStats, tokensPerMin)
    ;(async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        await invoke('update_tray_title', { title })
      } catch (e) {
        // ignore
      }
    })()
  }, [overviewStats, settings.trayMode, tokensPerMin])

  // Push animateTray flag to backend whenever it changes (Tauri only).
  useEffect(() => {
    if (!isTauri()) return
    ;(async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        await invoke('set_animate_tray', { enabled: settings.animateTray })
      } catch {}
    })()
  }, [settings.animateTray])

  // Push animationStyle to backend whenever it changes (Tauri only).
  useEffect(() => {
    if (!isTauri()) return
    ;(async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        await invoke('set_animation_style', { style: settings.animationStyle })
      } catch {}
    })()
  }, [settings.animationStyle])

  // Resize the native window to fit the current content height. The trace
  // card's row count changes as buckets come and go; without this the
  // window either crops the trace or shows trailing whitespace.
  const pageRef = useRef<HTMLDivElement>(null)
  const contentRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!isTauri() || !pageRef.current || !contentRef.current) return
    const page = pageRef.current
    const content = contentRef.current
    let raf = 0
    let disposed = false
    let unlistenShown: (() => void) | null = null
    const push = () => {
      cancelAnimationFrame(raf)
      raf = requestAnimationFrame(async () => {
        const pageStyle = getComputedStyle(page)
        const verticalPadding =
          (parseFloat(pageStyle.paddingTop) || 0) + (parseFloat(pageStyle.paddingBottom) || 0)
        const h = content.getBoundingClientRect().height + verticalPadding
        try {
          const { invoke } = await import('@tauri-apps/api/core')
          await invoke('set_popover_height', { height: Math.ceil(h + 2) })
        } catch {}
      })
    }
    push()
    const ro = new ResizeObserver(push)
    ro.observe(content)
    ;(async () => {
      try {
        const { listen } = await import('@tauri-apps/api/event')
        const unlisten = await listen('popover-shown', () => push())
        if (disposed) unlisten()
        else unlistenShown = unlisten
      } catch {}
    })()
    return () => {
      disposed = true
      cancelAnimationFrame(raf)
      ro.disconnect()
      if (unlistenShown) unlistenShown()
    }
  }, [activeStats?.totalTokens, activeTab, trace.length, settings.trayMode, settings.detailedTrace])

  return (
    <div className="page" ref={pageRef}>
      <div className="page-content" ref={contentRef}>
        <Panel>
          {!payload && !error && <div className="loading">Loading…</div>}
          {error && <div className="error">Error: {error}</div>}
          {payload && overviewStats && activeStats && (
            <>
              <HeaderBar
                totalTokens={overviewStats.totalTokens}
                year={year}
                years={allYears}
                onYearChange={setYear}
                theme={theme}
                onThemeChange={(t) => setTheme(t as ThemeName)}
                onRefresh={() => setRefreshTick(t => t + 1)}
                onOpenSettings={() => setSettingsOpen(true)}
              />
              <DashboardTabs clients={dashboardClients} active={activeTab} onChange={setActiveTab} />
              {activeTab === 'overview' ? (
                <div className="dashboard-stack">
                  <UsageBarGraph2D
                    payload={payload}
                    clientIds={presentClients}
                    title="Token Usage"
                    subtitle="Stacked by agent"
                    view={usageView}
                    onViewChange={setUsageView}
                    grid={overviewGrid}
                    graphLight={palette.graphLight}
                    graphDark={palette.graphDark}
                    accent={mode.accent}
                    stats={overviewStats}
                  />
                  <AgentLimitsCard clients={dashboardClients} trace={trace} agentUsage={agentUsage.payload} />
                  <UsageTraceCard
                    buckets={trace}
                    windowSecs={600}
                    detailed={settings.detailedTrace}
                    title="Live session"
                  />
                  <StreaksCard longest={overviewStats.streaks.longest} current={overviewStats.streaks.current} />
                </div>
              ) : (
                <div className="dashboard-stack">
                  <AgentLimitsCard
                    clients={[activeTab]}
                    trace={trace}
                    agentUsage={agentUsage.payload}
                    title={`${getClientStyle(activeTab).displayName} limits`}
                    note="Session / weekly / model limits"
                  />
                  <UsageBarGraph2D
                    payload={payload}
                    clientIds={[activeTab]}
                    title="Token Usage"
                    subtitle="Local token history"
                    view={usageView}
                    onViewChange={setUsageView}
                    grid={activeGrid}
                    graphLight={palette.graphLight}
                    graphDark={palette.graphDark}
                    accent={mode.accent}
                    stats={activeStats}
                  />
                  <StreaksCard longest={activeStats.streaks.longest} current={activeStats.streaks.current} />
                </div>
              )}
            </>
          )}
        </Panel>
      </div>
      <SettingsPanel
        open={settingsOpen}
        onClose={() => setSettingsOpen(false)}
        settings={settings}
        onChange={setSettings}
      />
      {aboutOpen && (
        <>
          <div className="settings-overlay" onClick={() => setAboutOpen(false)} />
          <div className="settings-panel" role="dialog">
            <div className="settings-head">
              <strong>About Tokcat</strong>
              <button className="settings-close" onClick={() => setAboutOpen(false)}>×</button>
            </div>
            <div style={{ fontSize: 13, lineHeight: 1.6, color: 'var(--text-secondary)' }}>
              <div><strong>Tokcat</strong> — version {appVersion || 'unknown'}</div>
              <div style={{ marginTop: 8 }}>
                Native macOS menubar dashboard for local AI token usage.
              </div>
              <div style={{ marginTop: 8 }}>
                <a
                  href="https://github.com/handlecusion/tokcat"
                  target="_blank"
                  rel="noreferrer"
                  style={{ color: 'var(--blue)' }}
                >
                  github.com/handlecusion/tokcat
                </a>
              </div>
            </div>
          </div>
        </>
      )}
    </div>
  )
}
