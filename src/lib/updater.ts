import { isTauri } from './runtime'

// While a system dialog (ask/message) is up, the menubar window's
// blur-to-hide handler must not run — otherwise the dialog stealing
// focus would dismiss the window underneath it. We push/pop a counter
// in the Rust AppState around any dialog call.
async function withDialogShield<T>(fn: () => Promise<T>): Promise<T> {
  if (!isTauri()) return fn()
  const { invoke } = await import('@tauri-apps/api/core')
  await invoke('push_dialog_shield')
  try {
    return await fn()
  } finally {
    try {
      await invoke('pop_dialog_shield')
    } catch {}
  }
}

// Future Tokcat releases are native Swift builds that require macOS 13+.
// The Tauri updater replaces the .app without checking OS requirements, so
// on macOS 11/12 we must not offer the update at all — installing it would
// leave the user with an app that no longer launches. The WKWebView user
// agent is frozen at 10_15_7, so the real version comes from Rust.
const MIN_UPDATE_MACOS_MAJOR = 13

let cachedMajor: number | null = null
async function macosMajorVersion(): Promise<number> {
  if (cachedMajor !== null) return cachedMajor
  try {
    const { invoke } = await import('@tauri-apps/api/core')
    cachedMajor = await invoke<number>('macos_major_version')
  } catch {
    cachedMajor = 0
  }
  return cachedMajor
}

// 0 means "couldn't determine" — fail open so an sw_vers hiccup never
// strands an up-to-date-capable user on an old version.
async function updatesSupportedOnThisOS(): Promise<boolean> {
  const major = await macosMajorVersion()
  return major === 0 || major >= MIN_UPDATE_MACOS_MAJOR
}

async function applyUpdate(update: any) {
  const { relaunch } = await import('@tauri-apps/plugin-process')
  await update.downloadAndInstall()
  await relaunch()
}

async function promptInstall(update: any): Promise<boolean> {
  const { ask } = await import('@tauri-apps/plugin-dialog')
  const body = update.body ? `\n\n${update.body}` : ''
  return withDialogShield(() =>
    ask(
      `Tokcat ${update.version} is available.${body}\n\nInstall and restart now?`,
      {
        title: 'Update available',
        kind: 'info',
        okLabel: 'Install',
        cancelLabel: 'Later',
      },
    ),
  )
}

export async function checkForUpdatesSilent(): Promise<void> {
  if (!isTauri()) return
  if (!(await updatesSupportedOnThisOS())) return
  try {
    const { check } = await import('@tauri-apps/plugin-updater')
    const update = await check()
    if (!update) return
    if (await promptInstall(update)) await applyUpdate(update)
  } catch {
    // Silent: network failure, no manifest yet, etc. Don't bother the user.
  }
}

export async function checkForUpdatesInteractive(): Promise<void> {
  if (!isTauri()) return
  const { message } = await import('@tauri-apps/plugin-dialog')
  if (!(await updatesSupportedOnThisOS())) {
    await withDialogShield(() =>
      message(
        'Tokcat updates now require macOS 13 or later.\n\nThis Mac will stay on the current version. You can keep using it — nothing else changes.',
        { title: 'Tokcat', kind: 'info' },
      ),
    )
    return
  }
  let update: any = null
  try {
    const { check } = await import('@tauri-apps/plugin-updater')
    update = await check()
  } catch (e) {
    await withDialogShield(() =>
      message(String(e), { title: 'Update check failed', kind: 'error' }),
    )
    return
  }
  if (!update) {
    await withDialogShield(() =>
      message("You're on the latest version.", { title: 'Tokcat', kind: 'info' }),
    )
    return
  }
  if (await promptInstall(update)) await applyUpdate(update)
}
