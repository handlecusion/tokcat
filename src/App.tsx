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
  // True while the Cmd key is held — drives the translucent shortcut-hint pins
  // overlaid on each actionable control (⌘R, ⌘,, ⌘1…, ⌘G).
  const [cmdHeld, setCmdHeld] = useState(false)
  // True while a manual refresh (button / ⌘R / tray) is in flight — spins the
  // header refresh icon so the fetch is visible even when it returns instantly.
  const [refreshing, setRefreshing] = useState(false)

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

  // Manual refresh from the header button, ⌘R, or the tray menu — bypasses
  // cache. Drives `refreshing` for the whole fetch so the header icon spins;
  // refresh_graph holds a ~450ms floor, so the spin is always visible.
  useEffect(() => {
    if (refreshTick === 0) return
    setRefreshing(true)
    if (!isTauri()) {
      const id = window.setTimeout(() => setRefreshing(false), 600)
      return () => window.clearTimeout(id)
    }
    let done = false
    ;(async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        await invoke('refresh_graph', { year })
      } catch {}
      if (!done) setRefreshing(false)
    })()
    return () => { done = true }
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

  // Internal keyboard shortcuts. The global Ctrl+Cmd+T popover toggle is
  // registered natively in Rust; everything here is cmd-only and cmd-exclusive
  // (ctrl/alt/shift held → ignored) so it never collides with that global key.
  useEffect(() => {
    const tabs = ['overview', ...dashboardClients]

    async function hidePopover() {
      if (!isTauri()) return
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        await invoke('hide_popover')
      } catch {}
    }

    const onKeyDown = (e: KeyboardEvent) => {
      // Esc closes the top-most modal first, else hides the popover. Skipped
      // when a form control is focused so Esc can dismiss its native dropdown.
      if (e.key === 'Escape') {
        const tag = document.activeElement?.tagName
        if (tag === 'SELECT' || tag === 'INPUT' || tag === 'TEXTAREA') return
        if (settingsOpen) { setSettingsOpen(false); e.preventDefault(); return }
        if (aboutOpen) { setAboutOpen(false); e.preventDefault(); return }
        void hidePopover()
        e.preventDefault()
        return
      }

      if (!e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return
      const k = e.key.toLowerCase()

      if (k >= '1' && k <= '9') {
        const idx = Number(k) - 1
        if (idx < tabs.length) { setActiveTab(tabs[idx]); e.preventDefault() }
        return
      }

      switch (k) {
        case ',':
          setSettingsOpen(true); e.preventDefault(); break
        case 'r':
          setRefreshTick(t => t + 1); e.preventDefault(); break
        case 'w':
          // Mirror Esc: close the top-most modal first, only hide the popover
          // when nothing is open over it.
          if (settingsOpen) setSettingsOpen(false)
          else if (aboutOpen) setAboutOpen(false)
          else void hidePopover()
          e.preventDefault(); break
        case 'q':
          if (isTauri()) {
            ;(async () => {
              try {
                const { invoke } = await import('@tauri-apps/api/core')
                await invoke('quit_app')
              } catch {}
            })()
          }
          e.preventDefault(); break
        case 'g':
          setUsageView(v => (v === '2d' ? '3d' : '2d')); e.preventDefault(); break
        case 'u':
          if (isTauri()) void checkForUpdatesInteractive()
          e.preventDefault(); break
        case '[': {
          const i = tabs.indexOf(activeTab)
          setActiveTab(tabs[(i - 1 + tabs.length) % tabs.length]); e.preventDefault(); break
        }
        case ']': {
          const i = tabs.indexOf(activeTab)
          setActiveTab(tabs[(i + 1) % tabs.length]); e.preventDefault(); break
        }
      }
    }

    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [dashboardClients, activeTab, settingsOpen, aboutOpen])

  // Track the Cmd key for the shortcut-hint overlay. keyup can be missed if the
  // app loses focus mid-hold (e.g. Cmd+Tab), so blur/visibilitychange force the
  // pins off — otherwise they'd stay stuck after switching away.
  useEffect(() => {
    const onDown = (e: KeyboardEvent) => { if (e.key === 'Meta') setCmdHeld(true) }
    const onUp = (e: KeyboardEvent) => { if (e.key === 'Meta') setCmdHeld(false) }
    const reset = () => setCmdHeld(false)
    window.addEventListener('keydown', onDown)
    window.addEventListener('keyup', onUp)
    window.addEventListener('blur', reset)
    document.addEventListener('visibilitychange', reset)
    return () => {
      window.removeEventListener('keydown', onDown)
      window.removeEventListener('keyup', onUp)
      window.removeEventListener('blur', reset)
      document.removeEventListener('visibilitychange', reset)
    }
  }, [])

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
    if (!isTauri()) {
      let cancelled = false
      ;(async () => {
        try {
          const res = await fetch('/api/rate')
          if (!res.ok) throw new Error(`rate ${res.status}`)
          const payload: RateUpdate = await res.json()
          if (!cancelled) {
            setTokensPerMin(payload.tokensPerMin)
            setTrace(payload.trace)
          }
        } catch {}
      })()
      return () => {
        cancelled = true
      }
    }
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
    const title = computeTrayTitle(settings.trayMode, overviewStats, tokensPerMin, agentUsage.payload, {
      provider: settings.planProvider,
      window: settings.planWindow,
      displayMode: settings.planDisplayMode,
    })
    ;(async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        await invoke('update_tray_title', { title })
      } catch (e) {
        // ignore
      }
    })()
  }, [
    overviewStats,
    settings.trayMode,
    tokensPerMin,
    agentUsage.payload,
    settings.planProvider,
    settings.planWindow,
    settings.planDisplayMode,
  ])

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

  // Push the Cursor-usage opt-in to the backend. On enable the backend fetches
  // once; refresh the graph so the new data shows immediately. If the fetch
  // fails (Cursor signed out / offline), revert the toggle so it reflects what
  // actually happened.
  useEffect(() => {
    if (!isTauri()) return
    let cancelled = false
    ;(async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        await invoke('set_cursor_usage_enabled', { enabled: settings.cursorUsage })
        if (!cancelled && settings.cursorUsage) setRefreshTick(t => t + 1)
      } catch (e) {
        if (cancelled) return
        console.error('Cursor usage fetch failed:', e)
        if (settings.cursorUsage) setSettings(s => ({ ...s, cursorUsage: false }))
      }
    })()
    return () => {
      cancelled = true
    }
  }, [settings.cursorUsage])

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
                kbdHints={cmdHeld}
                refreshing={refreshing}
              />
              <DashboardTabs clients={dashboardClients} active={activeTab} onChange={setActiveTab} kbdHints={cmdHeld} />
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
                    kbdHints={cmdHeld}
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
                    kbdHints={cmdHeld}
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
        agentUsage={agentUsage.payload}
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
