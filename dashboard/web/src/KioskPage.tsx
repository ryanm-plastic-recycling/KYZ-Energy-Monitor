import ReactECharts from 'echarts-for-react'
import { useEffect, useMemo, useState } from 'react'
import { client } from './api'
import { INNOV_LOGO_SRC, PRI_LOGO_SRC } from './brand'
import { buildChartOption } from './chartTheme'
import { KpiTile } from './KpiTile'
import { formatPct } from './kpiMeta'
import { applyTheme, getInitialTheme, type ThemeMode } from './theme'
import type { Health, IntervalSeriesPoint, LatestRow, LiveLatestRow, LiveSeriesPoint, Summary } from './types'

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
  const token = params.get('token')
  const kioskThemeParam = params.get('theme')

  const [health, setHealth] = useState<Health | null>(null)
  const [latest, setLatest] = useState<LatestRow | null>(null)
  const [liveLatest, setLiveLatest] = useState<LiveLatestRow | null>(null)
  const [liveSeries30m, setLiveSeries30m] = useState<LiveSeriesPoint[]>([])
  const [weekSeries, setWeekSeries] = useState<IntervalSeriesPoint[]>([])
  const [summary, setSummary] = useState<Summary | null>(null)

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
      const [h, l, ll, live, weekData, s] = await Promise.all([
        client.health(),
        client.latest(),
        client.liveLatest(),
        client.liveSeries(30),
        client.series(7 * 24 * 60, week.start.toISOString(), week.end.toISOString()),
        client.summary(),
      ])
      setHealth(h)
      setLatest(l)
      setLiveLatest(ll)
      setLiveSeries30m(live.points)
      setWeekSeries(weekData.points)
      setSummary(s)
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
        <div className="headerLeft">
          <img className="priLogoImg" src={PRI_LOGO_SRC} alt="PRI Logo" />
          <div className="headerTitleBlock">
            <h1>Plant Energy Dashboard - Kiosk</h1>
            <div className="muted">Operations display</div>
          </div>
        </div>
        <div className="headerRight">
          <img className="innovLogoImg" src={INNOV_LOGO_SRC} alt="Innovation Team" />
        </div>
      </header>
      <div className="pills">
        <span className={`pill ${stale ? 'bad' : 'good'}`}><span className={`dot ${stale ? 'bad' : 'good'}`} />{stale ? 'STALE' : 'LIVE'}</span>
        <span className={`pill ${monitorStatus.cls}`}><span className={`dot ${monitorStatus.cls}`} />{monitorStatus.label}</span>
        <span className="pill">{health?.latestIntervalEnd ? new Date(health.latestIntervalEnd).toLocaleString() : 'No data'}</span>
      </div>
      <section className="grid kpis kiosk-kpis">
        <KpiTile
          title="Live kW (15s)"
          value={liveLatest?.kW?.toFixed(2) ?? '—'}
          metaPillText={summary?.liveKWPctVs5mAvg != null ? (Math.abs(summary.liveKWPctVs5mAvg) <= 1 ? 'Stable' : formatPct(summary.liveKWPctVs5mAvg)) : undefined}
          metaText="vs 5m avg • 15s cadence"
          metaTone={summary?.liveKWPctVs5mAvg != null ? (Math.abs(summary.liveKWPctVs5mAvg) <= 1 ? 'neutral' : 'warn') : 'neutral'}
        />
        <KpiTile
          title="Current kW (15m demand)"
          value={latest?.kW?.toFixed(2) ?? '—'}
          metaPillText={summary?.currentKWPctVsPrev15m != null ? formatPct(summary.currentKWPctVsPrev15m) : undefined}
          metaText="vs prior 15m"
          metaTone={summary?.currentKWPctVsPrev15m != null ? (summary.currentKWPctVsPrev15m <= 0 ? 'good' : 'warn') : 'neutral'}
        />
        <KpiTile title="Current kWh" value={latest?.kWh?.toFixed(3) ?? '—'} metaPillText="15m interval" metaText="interval energy" metaTone="neutral" />
        <KpiTile title="Pulse Count" value={String(latest?.PulseCount ?? '—')} metaPillText="meter pulses" metaText="raw counter" metaTone="neutral" />
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
