import { useEffect, useState } from 'react'
import type { AgentUsagePayload } from '../lib/agentUsage'
import { isTauri } from '../lib/runtime'

interface State {
  payload: AgentUsagePayload | null
  error: string | null
}

export function useAgentUsage(refreshKey: number): State {
  const [state, setState] = useState<State>({ payload: null, error: null })

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
    ;(async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        const { listen } = await import('@tauri-apps/api/event')
        // Listen before the initial fetch, mirroring useGraphStream, so a
        // push that lands mid-invoke isn't dropped.
        unlisten = await listen<AgentUsagePayload>('agent-usage-update', e => {
          if (disposed || !e.payload) return
          setState({ payload: e.payload, error: null })
        })
        const payload = await invoke<AgentUsagePayload>('get_agent_usage')
        if (!disposed) setState({ payload, error: null })
      } catch (err) {
        if (!disposed) {
          setState(s => ({ ...s, error: (err as Error).message ?? String(err) }))
        }
      }
    })()
    return () => {
      disposed = true
      if (unlisten) unlisten()
    }
  }, [refreshKey])

  return state
}
