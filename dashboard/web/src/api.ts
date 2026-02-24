import type { BillingResponse, DailyPoint, Health, IntervalSeriesPoint, LatestRow, LiveLatestRow, LiveSeriesPoint, Metrics, Quality, Summary } from './types'

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
  series: (minutes: number, start?: string, end?: string) => {
    const params = new URLSearchParams({ minutes: String(minutes) })
    if (start) params.set('start', start)
    if (end) params.set('end', end)
    return apiGet<{ points: IntervalSeriesPoint[] }>(`/api/series?${params.toString()}`)
  },
  liveSeries: (minutes: number) => apiGet<{ points: LiveSeriesPoint[] }>(`/api/live/series?minutes=${minutes}`),
  summary: () => apiGet<Summary>('/api/summary'),
  billing: (months = 24, basis: 'calendar' | 'billing' = 'calendar') => apiGet<BillingResponse>(`/api/billing?months=${months}&basis=${basis}`),
  quality: () => apiGet<Quality>('/api/quality'),
  metrics: () => apiGet<Metrics>('/api/metrics'),
  daily: (days: number) => apiGet<{ days: DailyPoint[] }>(`/api/daily?days=${days}`),
}
