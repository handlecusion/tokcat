import type { Stats } from './types'
import type { AgentUsagePayload } from './agentUsage'
import { humanizeTokens, formatCost, isoDate } from './format'

export type TrayMode =
  | 'today_tokens'
  | 'today_cost'
  | 'total_tokens'
  | 'total_cost'
  | 'tokens_per_min'
  | 'plan_percent'
  | 'hidden'
export type AnimationStyle = 'cat' | 'parrot'

// Providers that expose an OAuth plan/quota cap, so a "% used / % left" is
// meaningful. Log-parsed clients (cursor, gemini, copilot, …) only report
// cumulative tokens and are intentionally excluded here.
export type PlanProvider = 'auto' | 'claude' | 'codex' | 'grok'
export type PlanDisplayMode = 'used' | 'left'

// Short labels shown in the (text-only) menubar title. The status item can't
// render SVGs, so we prefix the percentage with a compact provider name.
export const PLAN_PROVIDER_LABELS: Record<Exclude<PlanProvider, 'auto'>, string> = {
  claude: 'Claude',
  codex: 'Codex',
  grok: 'Grok',
}
export const PLAN_CAPABLE_PROVIDERS = ['claude', 'codex', 'grok'] as const

export interface Settings {
  trayMode: TrayMode
  autostart: boolean
  animateTray: boolean
  animationStyle: AnimationStyle
  // When true, the Live trace card splits rows by (client, agent, model);
  // otherwise rows collapse to one per client.
  detailedTrace: boolean
  // Opt-in: fetch Cursor usage from cursor.com. Off by default because, unlike
  // every other client, Cursor has no local token/cost ledger — enabling it
  // makes a network request authenticated with your Cursor session.
  cursorUsage: boolean
  // Menubar plan-percentage display (only used when trayMode === 'plan_percent').
  // planProvider === 'auto' shows whichever window is closest to its cap.
  planProvider: PlanProvider
  // Which usage window to pin (e.g. 'Session' / 'Weekly'); ignored when auto.
  planWindow: string
  // Show percentage consumed ('used') or remaining ('left').
  planDisplayMode: PlanDisplayMode
}

export const DEFAULT_SETTINGS: Settings = {
  trayMode: 'today_tokens',
  autostart: false,
  animateTray: true,
  animationStyle: 'cat',
  detailedTrace: false,
  cursorUsage: false,
  planProvider: 'auto',
  planWindow: 'Session',
  planDisplayMode: 'used',
}

export const ANIMATION_STYLE_LABELS: Record<AnimationStyle, string> = {
  cat: 'Spinning cat',
  parrot: 'Party parrot',
}

const KEY = 'tokcat:settings:v1'

export function loadSettings(): Settings {
  try {
    const raw = localStorage.getItem(KEY)
    if (!raw) return DEFAULT_SETTINGS
    const parsed = JSON.parse(raw)
    // Migrate legacy values: cube/cat1/cat2 all collapse to 'cat' so
    // existing installs keep an animation after the upgrade.
    if (parsed.animationStyle === 'cube' || parsed.animationStyle === 'cat1' || parsed.animationStyle === 'cat2') {
      parsed.animationStyle = 'cat'
    }
    return { ...DEFAULT_SETTINGS, ...parsed }
  } catch {
    return DEFAULT_SETTINGS
  }
}

export function saveSettings(s: Settings) {
  try {
    localStorage.setItem(KEY, JSON.stringify(s))
  } catch {}
}

export const TRAY_MODE_LABELS: Record<TrayMode, string> = {
  today_tokens: "Today's tokens (50M)",
  today_cost: "Today's cost ($5.20)",
  total_tokens: 'Total tokens (1.5B)',
  total_cost: 'Total cost ($889)',
  tokens_per_min: 'Tokens / min (12.4K/m)',
  plan_percent: 'Plan usage (42%)',
  hidden: 'Icon only',
}

export interface PlanSelection {
  provider: PlanProvider
  window: string
  displayMode: PlanDisplayMode
}

export const DEFAULT_PLAN_SELECTION: PlanSelection = {
  provider: 'auto',
  window: 'Session',
  displayMode: 'used',
}

function clampPercent(value: number): number {
  return Math.round(Math.min(100, Math.max(0, value)))
}

// Resolve which provider/window the menubar should show. In 'auto' mode we pick
// the window closest to its cap (highest usedPercent) across all plan-capable
// providers; otherwise we honor the pinned provider + window, falling back to
// that provider's first window if the pinned label is gone. Returns null when
// no plan-capable provider has any windows yet (loading / not signed in).
function pickPlanWindow(
  agentUsage: AgentUsagePayload | null,
  provider: PlanProvider,
  windowLabel: string,
): { providerId: string; usedPercent: number; remainingPercent: number } | null {
  const candidates = (agentUsage?.agents ?? []).filter(
    a => (PLAN_CAPABLE_PROVIDERS as readonly string[]).includes(a.clientId) && a.windows.length > 0,
  )
  if (candidates.length === 0) return null

  if (provider === 'auto') {
    let best: { providerId: string; usedPercent: number; remainingPercent: number } | null = null
    for (const agent of candidates) {
      for (const w of agent.windows) {
        if (!best || w.usedPercent > best.usedPercent) {
          best = { providerId: agent.clientId, usedPercent: w.usedPercent, remainingPercent: w.remainingPercent }
        }
      }
    }
    return best
  }

  const agent = candidates.find(a => a.clientId === provider)
  if (!agent) return null
  const w = agent.windows.find(x => x.label === windowLabel) ?? agent.windows[0]
  return { providerId: agent.clientId, usedPercent: w.usedPercent, remainingPercent: w.remainingPercent }
}

function computePlanTitle(agentUsage: AgentUsagePayload | null, plan: PlanSelection): string {
  const picked = pickPlanWindow(agentUsage, plan.provider, plan.window)
  if (!picked) return '—'
  const label = PLAN_PROVIDER_LABELS[picked.providerId as Exclude<PlanProvider, 'auto'>] ?? picked.providerId
  const used = clampPercent(picked.usedPercent)
  // Flag windows at/over 80% consumed so the menubar warns before you run out.
  const warn = used >= 80 ? '⚠ ' : ''
  if (plan.displayMode === 'left') {
    return `${warn}${label} ${clampPercent(picked.remainingPercent)}% left`
  }
  return `${warn}${label} ${used}%`
}

export function computeTrayTitle(
  mode: TrayMode,
  stats: Stats | null,
  tokensPerMin: number | null = null,
  agentUsage: AgentUsagePayload | null = null,
  plan: PlanSelection = DEFAULT_PLAN_SELECTION,
): string {
  if (mode === 'hidden') return ''
  // Plan percentage comes from OAuth quota, not the local token stats, so it is
  // resolved before the `!stats` guard that the token/cost modes depend on.
  if (mode === 'plan_percent') return computePlanTitle(agentUsage, plan)
  if (!stats) return ''
  const today = isoDate(new Date())
  const todayEntry = stats.perDayMap.get(today)
  switch (mode) {
    case 'today_tokens':
      return todayEntry ? humanizeTokens(todayEntry.tokens) : '0'
    case 'today_cost':
      return todayEntry ? formatCost(todayEntry.cost) : '$0.00'
    case 'total_tokens':
      return humanizeTokens(stats.totalTokens)
    case 'total_cost':
      return formatCost(stats.totalCost)
    case 'tokens_per_min':
      if (tokensPerMin === null) return '—/m'
      return `${humanizeTokens(Math.max(0, Math.round(tokensPerMin)))}/m`
  }
}
