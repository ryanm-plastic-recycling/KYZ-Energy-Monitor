import ReactECharts from 'echarts-for-react'
import { useEffect, useMemo, useState } from 'react'
import { client } from './api'
import { buildChartOption } from './chartTheme'
import { applyTheme, getInitialTheme, type ThemeMode } from './theme'
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

function HeaderLogos() {
  const priLogo = import.meta.env.VITE_PRI_LOGO_URL
  const innovationLogo = import.meta.env.VITE_INNOVATION_LOGO_URL
  return (
    <div className="logo-row">
      {priLogo ? <img src={priLogo} alt="PRI logo" className="brand-logo" /> : null}
      {innovationLogo ? <img src={innovationLogo} alt="Innovation Team logo" className="brand-logo" /> : null}
    </div>
  )
}

export function KioskPage() {
  const params = new URLSearchParams(window.location.search)
  const refresh = Number(params.get('refresh') ?? 10) * 1000
  const token = params.get('token')
  const kioskThemeParam = params.get('theme')

  const [health, setHealth] = useState<Health | null>(null)
  const [latest, setLatest] = useState<LatestRow | null>(null)
  const [liveLatest, setLiveLatest] = useState<LiveLatestRow | null>(null)
  const [liveSeries30m, setLiveSeries30m] = useState<LiveSeriesPoint[]>([])
  const [weekSeries, setWeekSeries] = useState<IntervalSeriesPoint[]>([])

  useEffect(() => {
    if (kioskThemeParam === 'light' || kioskThemeParam === 'dark') {
      applyTheme(kioskThemeParam as ThemeMode)
      return
    }
    applyTheme(getInitialTheme())
  }, [kioskThemeParam])

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

  return (
    <div className="kiosk page">
      <header className="header">
        <div className="brand-cluster">
          <div>
            <h1>Plant Energy Dashboard - Kiosk</h1>
            <small>Operations display</small>
          </div>
          <HeaderLogos />
        </div>
        <div className="pills">
          <span className={`pill ${stale ? 'bad' : 'good'}`}><span className={`dot ${stale ? 'bad' : 'good'}`} />{stale ? 'STALE' : 'LIVE'}</span>
          <span className={`pill ${monitorStatus.cls}`}><span className={`dot ${monitorStatus.cls}`} />{monitorStatus.label}</span>
          <span className="pill">{health?.latestIntervalEnd ? new Date(health.latestIntervalEnd).toLocaleString() : 'No data'}</span>
        </div>
      </header>
      <section className="grid kpis kiosk-kpis">
        <div className="card kpi-card"><h3>Live kW (15s)</h3><p>{liveLatest?.kW?.toFixed(2) ?? '—'}</p></div>
        <div className="card kpi-card"><h3>Current kW (15m demand)</h3><p>{latest?.kW?.toFixed(2) ?? '—'}</p></div>
        <div className="card kpi-card"><h3>Current kWh</h3><p>{latest?.kWh?.toFixed(3) ?? '—'}</p></div>
        <div className="card kpi-card"><h3>Pulse Count</h3><p>{latest?.PulseCount ?? '—'}</p></div>
      </section>
      <section className="grid charts">
        <div className="card chart-card full">
          <h3>Live kW - Last 30 Minutes</h3>
          <ReactECharts style={{ height: 300 }} option={buildChartOption({ xData: liveSeries30m.map((p) => new Date(p.t).toLocaleTimeString()), yName: 'kW', series: [{ type: 'line', smooth: true, data: liveSeries30m.map((p) => p.kW), showSymbol: false }] })} />
        </div>
        <div className="card chart-card full">
          <h3>Current Week kW (Monday to Sunday, 15-minute intervals)</h3>
          <ReactECharts style={{ height: 360 }} option={buildChartOption({ xData: weekSeries.map((p) => new Date(p.t).toLocaleString(undefined, { weekday: 'short', hour: '2-digit', minute: '2-digit' })), yName: 'kW', series: [{ type: 'line', showSymbol: false, data: weekSeries.map((p) => p.kW), smooth: true }] })} />
        </div>
      </section>
    </div>
  )
}
