import { useEffect, useRef, useState } from 'react'
import type { AgentUsagePayload } from '../lib/agentUsage'
import { isTauri } from '../lib/runtime'

interface State {
  payload: AgentUsagePayload | null
  error: string | null
}

// How stale the snapshot may be when the popover opens before we re-fetch.
// Opening the popover is the only moment anyone actually reads these numbers,
// and the backend cadence alone can't keep them current: tokio's sleep runs on
// a clock that stops while the machine is asleep, so after a lid-close the
// payload can be many hours old with most of a cycle still left to run. Age is
// measured against the payload's own `generatedAt`, which is wall-clock, so a
// sleep is counted rather than skipped. See #44.
const POPOVER_MAX_AGE_MS = 60 * 1000

export function useAgentUsage(refreshKey: number): State {
  const [state, setState] = useState<State>({ payload: null, error: null })
  // Wall-clock timestamp of the newest payload, for the popover staleness
  // check below. 0 until the first one lands, which reads as "stale".
  const generatedAtRef = useRef(0)

  useEffect(() => {
    let disposed = false
    if (!isTauri()) {
      ;(async () => {
        try {
          const res = await fetch('/api/agent-usage')
          if (!res.ok) throw new Error(`agent usage ${res.status}`)
          const payload = await res.json()
          if (!disposed) setState({ payload, error: null })
        } catch (err) {
          if (!disposed) {
            setState(s => ({ ...s, error: (err as Error).message ?? String(err) }))
          }
        }
      })()
      return () => {
        disposed = true
      }
    }

    // The 30-minute cadence lives in spawn_refresh_loop, not in a webview
    // timer: the main window is hidden for most of a menubar session and
    // macOS suspends JS timers there, so a setInterval only fires when some
    // other event happens to wake the webview. A push wakes it on its own.
    // See #44.
    let unlisten: (() => void) | null = null
    let unlistenShown: (() => void) | null = null
    ;(async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        const { listen } = await import('@tauri-apps/api/event')

        const apply = (payload: AgentUsagePayload) => {
          if (disposed || !payload) return
          const generatedAt = Date.parse(payload.generatedAt)
          generatedAtRef.current = Number.isNaN(generatedAt) ? 0 : generatedAt
          setState({ payload, error: null })
        }

        // Listen before the initial fetch, mirroring useGraphStream, so a
        // push that lands mid-invoke isn't dropped.
        unlisten = await listen<AgentUsagePayload>('agent-usage-update', e => apply(e.payload))
        unlistenShown = await listen('popover-shown', () => {
          if (disposed) return
          if (Date.now() - generatedAtRef.current < POPOVER_MAX_AGE_MS) return
          // Deliberately not routed through `refreshTick`: this must not spin
          // the header icon or rebuild the graph, it's just a top-up.
          void invoke<AgentUsagePayload>('get_agent_usage').then(apply, () => {})
        })
        apply(await invoke<AgentUsagePayload>('get_agent_usage'))
      } catch (err) {
        if (!disposed) {
          setState(s => ({ ...s, error: (err as Error).message ?? String(err) }))
        }
      }
    })()
    return () => {
      disposed = true
      if (unlisten) unlisten()
      if (unlistenShown) unlistenShown()
    }
  }, [refreshKey])

  return state
}
