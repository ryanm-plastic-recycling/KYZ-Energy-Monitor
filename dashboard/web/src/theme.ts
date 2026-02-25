export type ThemeMode = 'light' | 'dark'

const THEME_STORAGE_KEY = 'kyz-theme'

export function getStoredTheme(): ThemeMode | null {
  const stored = window.localStorage.getItem(THEME_STORAGE_KEY)
  return stored === 'light' || stored === 'dark' ? stored : null
}

export function setStoredTheme(theme: ThemeMode): void {
  window.localStorage.setItem(THEME_STORAGE_KEY, theme)
}

export function getInitialTheme(): ThemeMode {
  const stored = getStoredTheme()
  if (stored) return stored
  if (window.matchMedia?.('(prefers-color-scheme: dark)').matches) return 'dark'
  return 'light'
}

export function applyTheme(theme: ThemeMode): void {
  document.documentElement.dataset.theme = theme
}
