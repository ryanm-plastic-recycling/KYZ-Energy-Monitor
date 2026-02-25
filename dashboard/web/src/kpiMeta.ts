import type { KpiTone } from './KpiTile'

export function formatPct(p: number): string {
  const arrow = p >= 0 ? '▲' : '▼'
  return `${arrow} ${Math.abs(p).toFixed(1)}%`
}

export function toneFromDelta(deltaPct: number | null | undefined, lowerIsBetter = true): KpiTone {
  if (deltaPct == null) return 'neutral'
  if (deltaPct === 0) return 'neutral'
  if (lowerIsBetter) return deltaPct < 0 ? 'good' : 'warn'
  return deltaPct > 0 ? 'good' : 'warn'
}
