import type { Stats } from './types'
import { humanizeTokens, formatCost, isoDate } from './format'

export type TrayMode =
  | 'today_tokens'
  | 'today_cost'
  | 'total_tokens'
  | 'total_cost'
  | 'tokens_per_min'
  | 'hidden'
export type AnimationStyle = 'cat' | 'parrot'

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
}

export const DEFAULT_SETTINGS: Settings = {
  trayMode: 'today_tokens',
  autostart: false,
  animateTray: true,
  animationStyle: 'cat',
  detailedTrace: false,
  cursorUsage: false,
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
  hidden: 'Icon only',
}

export function computeTrayTitle(
  mode: TrayMode,
  stats: Stats | null,
  tokensPerMin: number | null = null,
): string {
  if (mode === 'hidden' || !stats) return ''
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
