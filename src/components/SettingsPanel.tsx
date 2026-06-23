import React, { useEffect, useState } from 'react'
import {
  AnimationStyle,
  ANIMATION_STYLE_LABELS,
  Settings,
  TrayMode,
  TRAY_MODE_LABELS,
} from '../lib/settings'
import { isTauri } from '../lib/runtime'
import { checkForUpdatesInteractive } from '../lib/updater'

interface Props {
  open: boolean
  onClose: () => void
  settings: Settings
  onChange: (s: Settings) => void
}

function SwitchToggle({
  checked,
  disabled,
  onChange,
}: {
  checked: boolean
  disabled?: boolean
  onChange: (next: boolean) => void
}) {
  return (
    <label className={`settings-switch${disabled ? ' is-disabled' : ''}`}>
      <input
        type="checkbox"
        checked={checked}
        disabled={disabled}
        onChange={e => onChange(e.target.checked)}
      />
      <span className="settings-switch-track" aria-hidden="true" />
      <span className="settings-switch-thumb" aria-hidden="true" />
    </label>
  )
}

function CheckIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="20 6 9 17 4 12" />
    </svg>
  )
}

export function SettingsPanel({ open, onClose, settings, onChange }: Props) {
  const [autostartBusy, setAutostartBusy] = useState(false)
  const [version, setVersion] = useState<string>('')
  const [updateBusy, setUpdateBusy] = useState(false)
  const tauri = isTauri()

  useEffect(() => {
    if (!open || !tauri) return
    let cancelled = false
    ;(async () => {
      try {
        const m = await import('@tauri-apps/plugin-autostart')
        const enabled = await m.isEnabled()
        if (!cancelled && enabled !== settings.autostart) {
          onChange({ ...settings, autostart: enabled })
        }
      } catch {}
    })()
    return () => {
      cancelled = true
    }
  }, [open, tauri])

  useEffect(() => {
    if (!open) return
    if (!tauri) {
      setVersion('dev')
      return
    }
    let cancelled = false
    ;(async () => {
      try {
        const { getVersion } = await import('@tauri-apps/api/app')
        const v = await getVersion()
        if (!cancelled) setVersion(v)
      } catch {
        if (!cancelled) setVersion('')
      }
    })()
    return () => {
      cancelled = true
    }
  }, [open, tauri])

  async function setAutostart(enabled: boolean) {
    if (!tauri) {
      onChange({ ...settings, autostart: enabled })
      return
    }
    setAutostartBusy(true)
    try {
      const m = await import('@tauri-apps/plugin-autostart')
      if (enabled) await m.enable()
      else await m.disable()
      onChange({ ...settings, autostart: enabled })
    } catch (e) {
      console.error('autostart toggle failed', e)
    } finally {
      setAutostartBusy(false)
    }
  }

  async function checkUpdates() {
    if (!tauri || updateBusy) return
    setUpdateBusy(true)
    try {
      await checkForUpdatesInteractive()
    } finally {
      setUpdateBusy(false)
    }
  }

  async function quitApp() {
    if (!tauri) return
    try {
      const { invoke } = await import('@tauri-apps/api/core')
      await invoke('quit_app')
    } catch {}
  }

  if (!open) return null

  const modes: TrayMode[] = [
    'today_tokens',
    'today_cost',
    'total_tokens',
    'total_cost',
    'tokens_per_min',
    'hidden',
  ]

  return (
    <>
      <div className="settings-overlay" onClick={onClose} />
      <div className="settings-panel" role="dialog">
        <div className="settings-head">
          <strong>Settings</strong>
          <button className="settings-close" onClick={onClose} aria-label="Close">
            ×
          </button>
        </div>

        <div className="settings-body">
          <section className="settings-section">
            <div className="settings-label">Menubar title</div>
            <div className="settings-group">
              {modes.map((m, i) => {
                const active = settings.trayMode === m
                return (
                  <button
                    key={m}
                    type="button"
                    className={`settings-row settings-row-radio${active ? ' is-active' : ''}`}
                    onClick={() => onChange({ ...settings, trayMode: m })}
                    aria-pressed={active}
                  >
                    <span className="settings-row-label">{TRAY_MODE_LABELS[m]}</span>
                    <span className="settings-row-check">{active && <CheckIcon />}</span>
                  </button>
                )
              })}
            </div>
          </section>

          {tauri && (
            <section className="settings-section">
              <div className="settings-label">Startup</div>
              <div className="settings-group">
                <div className="settings-row">
                  <span className="settings-row-label">Launch at login</span>
                  <SwitchToggle
                    checked={settings.autostart}
                    disabled={autostartBusy}
                    onChange={setAutostart}
                  />
                </div>
              </div>
            </section>
          )}

          {tauri && (
            <section className="settings-section">
              <div className="settings-label">Menubar icon</div>
              <div className="settings-group">
                <div className="settings-row">
                  <span className="settings-row-label">Animate based on token usage</span>
                  <SwitchToggle
                    checked={settings.animateTray}
                    onChange={next => onChange({ ...settings, animateTray: next })}
                  />
                </div>
                {settings.animateTray &&
                  (['cat', 'parrot'] as AnimationStyle[]).map(s => {
                    const active = settings.animationStyle === s
                    return (
                      <button
                        key={s}
                        type="button"
                        className={`settings-row settings-row-radio${active ? ' is-active' : ''}`}
                        onClick={() => onChange({ ...settings, animationStyle: s })}
                        aria-pressed={active}
                      >
                        <span className="settings-row-label">{ANIMATION_STYLE_LABELS[s]}</span>
                        <span className="settings-row-check">{active && <CheckIcon />}</span>
                      </button>
                    )
                  })}
              </div>
            </section>
          )}

          <section className="settings-section">
            <div className="settings-label">Live trace</div>
            <div className="settings-group">
              <div className="settings-row">
                <span className="settings-row-label">Split by agent / model</span>
                <SwitchToggle
                  checked={settings.detailedTrace}
                  onChange={next => onChange({ ...settings, detailedTrace: next })}
                />
              </div>
            </div>
          </section>

          {tauri && (
            <section className="settings-section">
              <div className="settings-label">Cursor usage</div>
              <div className="settings-group">
                <div className="settings-row">
                  <span className="settings-row-label">Fetch from cursor.com</span>
                  <SwitchToggle
                    checked={settings.cursorUsage}
                    onChange={next => onChange({ ...settings, cursorUsage: next })}
                  />
                </div>
              </div>
            </section>
          )}

          <section className="settings-section">
            <div className="settings-label">About</div>
            <div className="settings-group">
              <div className="settings-row">
                <span className="settings-row-label">Version</span>
                <span className="settings-row-meta">{version || '—'}</span>
              </div>
              {tauri && (
                <div className="settings-row">
                  <span className="settings-row-label">Check for updates</span>
                  <button
                    className="settings-button"
                    onClick={checkUpdates}
                    disabled={updateBusy}
                  >
                    {updateBusy ? 'Checking…' : 'Check Now'}
                  </button>
                </div>
              )}
            </div>
          </section>

          {tauri && (
            <section className="settings-section">
              <button className="settings-quit" onClick={quitApp}>
                Quit Tokcat
              </button>
            </section>
          )}
        </div>
      </div>
    </>
  )
}
