function normalizeAssetUrl(raw: string | undefined): string | null {
  if (!raw) return null

  const trimmed = raw.trim()
  if (!trimmed) return null
  if (/^https?:\/\//i.test(trimmed)) return trimmed

  let path = trimmed.replace(/\\/g, '/').replace(/^\.\//, '')
  if (path.toLowerCase().startsWith('public/')) path = path.slice('public/'.length)
  if (!path.startsWith('/')) path = `/${path}`

  return path
}

const priEnv = normalizeAssetUrl(import.meta.env.VITE_PRI_LOGO_URL)
const innovEnv = normalizeAssetUrl(import.meta.env.VITE_INNOVATION_LOGO_URL)

export const PRI_LOGO_SRC = priEnv ?? '/pri-logo-vector.png'

export const INNOV_LOGO_SRC = innovEnv ?? '/Innovation%20Triangle%20-%20avatar.png'
