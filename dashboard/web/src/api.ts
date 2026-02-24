import type { BillingMonth, DailyPoint, Health, LatestRow, LiveLatestRow, LiveSeriesPoint, Metrics, Quality, Summary } from './types'

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
  liveLatest: () => apiGet<LiveLatestRow>('/api/live/latest'),
  series: (minutes: number) => apiGet<{ points: Array<{ t: string; kW: number; kWh: number }> }>(`/api/series?minutes=${minutes}`),
  liveSeries: (minutes: number) => apiGet<{ points: LiveSeriesPoint[] }>(`/api/live/series?minutes=${minutes}`),
  summary: () => apiGet<Summary>('/api/summary'),
  billing: (months = 24) => apiGet<{ months: BillingMonth[] }>(`/api/billing?months=${months}`),
  quality: () => apiGet<Quality>('/api/quality'),
  metrics: () => apiGet<Metrics>('/api/metrics'),
  daily: (days: number) => apiGet<{ days: DailyPoint[] }>(`/api/daily?days=${days}`),
}
