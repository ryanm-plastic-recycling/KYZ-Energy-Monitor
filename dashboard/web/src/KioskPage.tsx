import ReactECharts from 'echarts-for-react'
import { useEffect, useMemo, useState } from 'react'
import { client } from './api'
import type { Health, LatestRow } from './types'

export function KioskPage() {
  const params = new URLSearchParams(window.location.search)
  const refresh = Number(params.get('refresh') ?? 10) * 1000
  const theme = params.get('theme') ?? 'light'

  const [health, setHealth] = useState<Health | null>(null)
  const [latest, setLatest] = useState<LatestRow | null>(null)
  const [series4h, setSeries4h] = useState<Array<{ t: string; kW: number }>>([])

  const load = async () => {
    try {
      const [h, l, s] = await Promise.all([client.health(), client.latest(), client.series(240)])
      setHealth(h)
      setLatest(l)
      setSeries4h(s.points)
    } catch {
      // no-op for kiosk retry behavior
    }
  }

  useEffect(() => {
    load()
    const timer = setInterval(load, refresh)
    const source = new EventSource('/api/stream')
    source.addEventListener('latest', (event) => {
      const data = JSON.parse((event as MessageEvent).data) as LatestRow
      setLatest(data)
      load()
    })
    return () => {
      clearInterval(timer)
      source.close()
    }
  }, [refresh])

  const stale = (health?.secondsSinceLatest ?? 99999) > 1800
  const cls = useMemo(() => (theme === 'dark' ? 'kiosk dark' : 'kiosk'), [theme])

  return (
    <div className={cls}>
      <header className="header">
        <h1>Plant Energy Dashboard - Kiosk</h1>
        <div className="pills">
          <span className={`pill ${stale ? 'bad' : 'good'}`}>{stale ? 'STALE' : 'LIVE'}</span>
          <span className="pill">{health?.latestIntervalEnd ? new Date(health.latestIntervalEnd).toLocaleString() : 'No data'}</span>
        </div>
      </header>
      <section className="grid kpis kiosk-kpis">
        <div className="card"><h3>Current kW</h3><p>{latest?.kW?.toFixed(2) ?? '—'}</p></div>
        <div className="card"><h3>Current kWh</h3><p>{latest?.kWh?.toFixed(3) ?? '—'}</p></div>
        <div className="card"><h3>Pulse Count</h3><p>{latest?.PulseCount ?? '—'}</p></div>
      </section>
      <section className="card chart-card kiosk-chart">
        <h3>kW - Last 4 Hours</h3>
        <ReactECharts style={{ height: 460 }} option={{
          tooltip: { trigger: 'axis' },
          xAxis: { type: 'category', data: series4h.map((p) => new Date(p.t).toLocaleTimeString()) },
          yAxis: { type: 'value', name: 'kW' },
          series: [{ type: 'line', smooth: true, data: series4h.map((p) => p.kW), lineStyle: { width: 4, color: '#00a3ff' } }],
          grid: { left: 50, right: 30, top: 30, bottom: 40 },
        }} />
      </section>
    </div>
  )
}
