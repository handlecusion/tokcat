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

    ;(async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core')
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
    }
  }, [refreshKey])

  return state
}
