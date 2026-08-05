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
//
// Five minutes rather than one: this only exists to cover the gap the backend
// cadence can't, and a full refresh is four upstream calls plus three
// subprocess spawns. At a minute, an active session re-fetches on essentially
// every open and the 30-minute cadence stops meaning anything.
const POPOVER_MAX_AGE_MS = 5 * 60 * 1000

export function useAgentUsage(refreshKey: number): State {
  const [state, setState] = useState<State>({ payload: null, error: null })
  // Wall-clock timestamp of the newest payload, for the popover staleness
  // check below. 0 until the first one lands, which reads as "stale".
  const generatedAtRef = useRef(0)
  // A full refresh can take a couple of minutes when an upstream is timing
  // out, which is longer than the staleness window — without this, opening the
  // popover a few times during one would start a fetch each time.
  const inFlightRef = useRef(false)

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
          const stamp = Number.isNaN(generatedAt) ? 0 : generatedAt
          // A slow fetch can resolve after a newer push. Rendering the older
          // one is merely wrong on screen; letting it walk `generatedAtRef`
          // backwards also makes the next popover open re-fetch for nothing.
          if (stamp && stamp < generatedAtRef.current) return
          generatedAtRef.current = stamp
          setState({ payload, error: null })
        }

        // Listen before the initial fetch, mirroring useGraphStream, so a
        // push that lands mid-invoke isn't dropped.
        unlisten = await listen<AgentUsagePayload>('agent-usage-update', e => apply(e.payload))
        unlistenShown = await listen('popover-shown', () => {
          if (disposed || inFlightRef.current) return
          if (Date.now() - generatedAtRef.current < POPOVER_MAX_AGE_MS) return
          // Deliberately not routed through `refreshTick`: this must not spin
          // the header icon or rebuild the graph, it's just a top-up.
          inFlightRef.current = true
          void invoke<AgentUsagePayload>('get_agent_usage')
            .then(apply, err => {
              // Keep whatever is on screen; the tiles carry per-agent errors
              // of their own, so blanking them here would lose more than it
              // explains.
              if (!disposed) {
                setState(s => ({ ...s, error: (err as Error).message ?? String(err) }))
              }
            })
            .finally(() => {
              inFlightRef.current = false
            })
        })
        inFlightRef.current = true
        try {
          apply(await invoke<AgentUsagePayload>('get_agent_usage'))
        } finally {
          inFlightRef.current = false
        }
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
