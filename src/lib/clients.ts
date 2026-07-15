import claudeIcon from '../assets/agent-icons/claude.svg?raw'
import geminiIcon from '../assets/agent-icons/gemini.svg?raw'
import copilotIcon from '../assets/agent-icons/copilot.svg?raw'
import cursorIcon from '../assets/agent-icons/cursor.svg?raw'
import qwenIcon from '../assets/agent-icons/qwen.svg?raw'
import ampIcon from '../assets/agent-icons/amp.svg?raw'
import piIcon from '../assets/agent-icons/pi.svg?raw'
import codexIcon from '../assets/agent-icons/codex.svg?raw'
import opencodeIcon from '../assets/agent-icons/opencode.svg?raw'
import droidIcon from '../assets/agent-icons/droid.svg?raw'
import kilocodeIcon from '../assets/agent-icons/kilocode.svg?raw'
import syntheticIcon from '../assets/agent-icons/synthetic.svg?raw'
import grokIcon from '../assets/agent-icons/grok.svg?raw'

// 'mono' icons are single-color glyphs we tint white over the brand-color disc.
// 'full' icons carry their own design (background + colors) and fill the disc as-is.
export type IconType = 'mono' | 'full'

export interface ClientStyle {
  id: string
  displayName: string
  color: string // logo disc color
  iconRaw?: string
  iconType?: IconType
}

interface RegistryEntry {
  displayName: string
  color: string
  iconRaw?: string
  iconType?: IconType
}

const REGISTRY: Record<string, RegistryEntry> = {
  claude: { displayName: 'Claude Code', color: '#d97706', iconRaw: claudeIcon, iconType: 'mono' },
  openclaw: { displayName: 'OpenClaw', color: '#dc2626' },
  gemini: { displayName: 'Gemini CLI', color: '#60a5fa', iconRaw: geminiIcon, iconType: 'mono' },
  opencode: { displayName: 'OpenCode', color: '#1f2937', iconRaw: opencodeIcon, iconType: 'full' },
  codex: { displayName: 'Codex CLI', color: '#9ca3af', iconRaw: codexIcon, iconType: 'full' },
  copilot: { displayName: 'Copilot CLI', color: '#1f2937', iconRaw: copilotIcon, iconType: 'mono' },
  cursor: { displayName: 'Cursor IDE', color: '#0ea5e9', iconRaw: cursorIcon, iconType: 'mono' },
  amp: { displayName: 'Amp', color: '#10b981', iconRaw: ampIcon, iconType: 'mono' },
  droid: { displayName: 'Droid', color: '#22c55e', iconRaw: droidIcon, iconType: 'full' },
  hermes: { displayName: 'Hermes', color: '#a78bfa' },
  grok: { displayName: 'Grok Build', color: '#111827', iconRaw: grokIcon, iconType: 'mono' },
  pi: { displayName: 'Pi', color: '#f472b6', iconRaw: piIcon, iconType: 'mono' },
  kimi: { displayName: 'Kimi CLI', color: '#fbbf24' },
  qwen: { displayName: 'Qwen CLI', color: '#7c3aed', iconRaw: qwenIcon, iconType: 'mono' },
  roocode: { displayName: 'Roo Code', color: '#ef4444' },
  kilocode: { displayName: 'KiloCode', color: '#f97316', iconRaw: kilocodeIcon, iconType: 'full' },
  kilo: { displayName: 'Kilo CLI', color: '#f59e0b' },
  mux: { displayName: 'Mux', color: '#06b6d4' },
  crush: { displayName: 'Crush', color: '#ec4899' },
  synthetic: { displayName: 'Synthetic', color: '#64748b', iconRaw: syntheticIcon, iconType: 'full' },
}

export function getClientStyle(id: string): ClientStyle {
  const entry = REGISTRY[id]
  if (entry) {
    return {
      id,
      displayName: entry.displayName,
      color: entry.color,
      iconRaw: entry.iconRaw,
      iconType: entry.iconType,
    }
  }
  // Fallback: title-case the id, neutral grey disc
  const displayName = id.charAt(0).toUpperCase() + id.slice(1)
  return { id, displayName, color: '#6b7280' }
}

export function clientInitial(displayName: string): string {
  return displayName.charAt(0).toUpperCase()
}
