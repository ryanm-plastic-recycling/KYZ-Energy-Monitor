import type { Health, LatestRow } from './types'

const token = new URLSearchParams(window.location.search).get('token')

async function apiGet<T>(path: string): Promise<T> {
  const headers: HeadersInit = {}
  if (token) headers['X-Auth-Token'] = token
  const res = await fetch(path, { headers })
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
  return res.json()
}

export const client = {
  health: () => apiGet<Health>('/api/health'),
  latest: () => apiGet<LatestRow>('/api/latest'),
  series: (minutes: number) => apiGet<{ points: Array<{ t: string; kW: number; kWh: number }> }>(`/api/series?minutes=${minutes}`),
  daily: (days: number) => apiGet<{ days: Array<{ date: string; kWh_sum: number; kW_peak: number; interval_count: number }> }>(`/api/daily?days=${days}`),
  monthly: (months: number) => apiGet<{ months: Array<{ monthStart: string; peak_kW: number; top3_avg_kW: number }> }>(`/api/monthly-demand?months=${months}`),
}
