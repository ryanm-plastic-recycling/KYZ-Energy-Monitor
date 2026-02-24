import ReactECharts from 'echarts-for-react'
import { useEffect, useMemo, useState } from 'react'
import { client } from './api'
import type { Health, IntervalSeriesPoint, LatestRow, LiveLatestRow, LiveSeriesPoint } from './types'

function getCurrentWeekRange(base: Date): { start: Date; end: Date } {
  const day = base.getDay()
  const mondayOffset = day === 0 ? -6 : 1 - day
  const start = new Date(base)
  start.setHours(0, 0, 0, 0)
  start.setDate(base.getDate() + mondayOffset)
  const end = new Date(start)
  end.setDate(start.getDate() + 7)
  return { start, end }
}

function getMonitorStatus(health: Health | null): { label: string; cls: 'good' | 'warn' | 'bad' } {
  if (!health?.dbConnected || !health.latestLiveEnd) return { label: 'KYZ Monitor Disconnected', cls: 'bad' }
  if ((health.secondsSinceLatestLive ?? Infinity) > 300) return { label: 'KYZ Monitor Delayed', cls: 'warn' }
  return { label: 'KYZ Monitor Connected', cls: 'good' }
}

export function KioskPage() {
  const params = new URLSearchParams(window.location.search)
  const refresh = Number(params.get('refresh') ?? 10) * 1000
  const theme = params.get('theme') ?? 'light'
  const token = params.get('token')

  const [health, setHealth] = useState<Health | null>(null)
  const [latest, setLatest] = useState<LatestRow | null>(null)
  const [liveLatest, setLiveLatest] = useState<LiveLatestRow | null>(null)
  const [liveSeries30m, setLiveSeries30m] = useState<LiveSeriesPoint[]>([])
  const [weekSeries, setWeekSeries] = useState<IntervalSeriesPoint[]>([])

  const load = async () => {
    try {
      const now = new Date()
      const week = getCurrentWeekRange(now)
      const [h, l, ll, live, weekData] = await Promise.all([
        client.health(),
        client.latest(),
        client.liveLatest(),
        client.liveSeries(30),
        client.series(7 * 24 * 60, week.start.toISOString(), week.end.toISOString()),
      ])
      setHealth(h)
      setLatest(l)
      setLiveLatest(ll)
      setLiveSeries30m(live.points)
      setWeekSeries(weekData.points)
    } catch {
      // no-op for kiosk retry behavior
    }
  }

  useEffect(() => {
    load()
    const timer = setInterval(load, refresh)
    const streamUrl = token ? `/api/stream?token=${encodeURIComponent(token)}` : '/api/stream'
    const source = new EventSource(streamUrl)
    source.addEventListener('latest', () => {
      load()
    })
    return () => {
      clearInterval(timer)
      source.close()
    }
  }, [refresh, token])

  const stale = (health?.secondsSinceLatest ?? 99999) > 1800
  const monitorStatus = getMonitorStatus(health)
  const cls = useMemo(() => (theme === 'dark' ? 'kiosk dark' : 'kiosk'), [theme])

  return (
    <div className={cls}>
      <header className="header">
        <h1>Plant Energy Dashboard - Kiosk</h1>
        <div className="pills">
          <span className={`pill ${stale ? 'bad' : 'good'}`}>{stale ? 'STALE' : 'LIVE'}</span>
          <span className={`pill ${monitorStatus.cls}`}>{monitorStatus.label}</span>
          <span className="pill">{health?.latestIntervalEnd ? new Date(health.latestIntervalEnd).toLocaleString() : 'No data'}</span>
        </div>
      </header>
      <section className="grid kpis kiosk-kpis">
        <div className="card"><h3>Live kW (15s)</h3><p>{liveLatest?.kW?.toFixed(2) ?? '—'}</p></div>
        <div className="card"><h3>Current kW (15m demand)</h3><p>{latest?.kW?.toFixed(2) ?? '—'}</p></div>
        <div className="card"><h3>Current kWh</h3><p>{latest?.kWh?.toFixed(3) ?? '—'}</p></div>
        <div className="card"><h3>Pulse Count</h3><p>{latest?.PulseCount ?? '—'}</p></div>
      </section>
      <section className="grid charts">
        <div className="card chart-card full">
          <h3>Live kW - Last 30 Minutes</h3>
          <ReactECharts style={{ height: 300 }} option={{ tooltip: { trigger: 'axis' }, xAxis: { type: 'category', data: liveSeries30m.map((p) => new Date(p.t).toLocaleTimeString()) }, yAxis: { type: 'value', name: 'kW' }, series: [{ type: 'line', smooth: true, data: liveSeries30m.map((p) => p.kW), lineStyle: { width: 3, color: '#00a3ff' } }], grid: { left: 50, right: 30, top: 30, bottom: 40 } }} />
        </div>
        <div className="card chart-card full">
          <h3>Current Week kW (Monday to Sunday, 15-minute intervals)</h3>
          <ReactECharts style={{ height: 360 }} option={{ tooltip: { trigger: 'axis' }, xAxis: { type: 'category', data: weekSeries.map((p) => new Date(p.t).toLocaleString(undefined, { weekday: 'short', hour: '2-digit', minute: '2-digit' })) }, yAxis: { type: 'value', name: 'kW' }, series: [{ type: 'line', showSymbol: false, data: weekSeries.map((p) => p.kW), lineStyle: { width: 2, color: '#3ecf8e' } }], grid: { left: 50, right: 30, top: 30, bottom: 40 } }} />
        </div>
      </section>
    </div>
  )
}
