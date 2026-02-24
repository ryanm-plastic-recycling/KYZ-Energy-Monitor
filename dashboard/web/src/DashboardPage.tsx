import ReactECharts from 'echarts-for-react'
import { useEffect, useMemo, useState } from 'react'
import { NavLink, Route, Routes } from 'react-router-dom'
import { client } from './api'
import type { BillingMonth, Health, IntervalSeriesPoint, LiveSeriesPoint, Metrics, Quality, Summary } from './types'

const money = (n: number) => `$${n.toLocaleString(undefined, { maximumFractionDigits: 0 })}`

function getMonthRange(base: Date, offsetMonths = 0): { start: Date; end: Date } {
  const year = base.getFullYear()
  const month = base.getMonth() + offsetMonths
  const start = new Date(year, month, 1)
  const end = new Date(year, month + 1, 1)
  return { start, end }
}

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

function filterSeriesRange(data: IntervalSeriesPoint[], start: Date, end: Date): IntervalSeriesPoint[] {
  return data.filter((point) => {
    const current = new Date(point.t)
    return current >= start && current < end
  })
}

function getMonitorStatus(health: Health | null): { label: string; cls: 'good' | 'warn' | 'bad' } {
  if (!health?.dbConnected || !health.latestLiveEnd) return { label: 'KYZ Monitor Disconnected', cls: 'bad' }
  if ((health.secondsSinceLatestLive ?? Infinity) > 300) return { label: 'KYZ Monitor Delayed', cls: 'warn' }
  return { label: 'KYZ Monitor Connected', cls: 'good' }
}

export function DashboardPage() {
  const [summary, setSummary] = useState<Summary | null>(null)
  const [billing, setBilling] = useState<BillingMonth[]>([])
  const [quality, setQuality] = useState<Quality | null>(null)
  const [metrics, setMetrics] = useState<Metrics | null>(null)
  const [health, setHealth] = useState<Health | null>(null)
  const [series24h, setSeries24h] = useState<IntervalSeriesPoint[]>([])
  const [liveSeries30m, setLiveSeries30m] = useState<LiveSeriesPoint[]>([])
  const [intervalSeriesWindow, setIntervalSeriesWindow] = useState<IntervalSeriesPoint[]>([])

  useEffect(() => {
    const load = async () => {
      const now = new Date()
      const { start: lastMonthStart } = getMonthRange(now, -1)
      const [s, b, q, m, h, series, liveSeries, extendedSeries] = await Promise.all([
        client.summary(),
        client.billing(24),
        client.quality(),
        client.metrics(),
        client.health(),
        client.series(24 * 60),
        client.liveSeries(30),
        client.series(90 * 24 * 60, lastMonthStart.toISOString(), now.toISOString()),
      ])
      setSummary(s)
      setBilling(b.months)
      setQuality(q)
      setMetrics(m)
      setHealth(h)
      setSeries24h(series.points)
      setLiveSeries30m(liveSeries.points)
      setIntervalSeriesWindow(extendedSeries.points)
    }
    load().catch(() => undefined)
    const t = setInterval(() => load().catch(() => undefined), 15000)
    return () => clearInterval(t)
  }, [])

  const now = useMemo(() => new Date(), [intervalSeriesWindow])
  const lastMonthProfile = useMemo(() => {
    const range = getMonthRange(now, -1)
    return filterSeriesRange(intervalSeriesWindow, range.start, range.end)
  }, [intervalSeriesWindow, now])
  const currentMonthProfile = useMemo(() => {
    const range = getMonthRange(now)
    return filterSeriesRange(intervalSeriesWindow, range.start, range.end)
  }, [intervalSeriesWindow, now])
  const currentWeekProfile = useMemo(() => {
    const range = getCurrentWeekRange(now)
    return filterSeriesRange(intervalSeriesWindow, range.start, range.end)
  }, [intervalSeriesWindow, now])

  const monitorStatus = getMonitorStatus(health)

  return (
    <div className="page">
      <header className="header">
        <div>
          <h1>Plant Energy Dashboard</h1>
          <small>{summary?.plantName ?? 'Plant'} • Last updated: {summary?.lastUpdated ? new Date(summary.lastUpdated).toLocaleString() : '—'}</small>
        </div>
        <div className="pills">
          <span className={`pill ${metrics?.dbConnected ? 'good' : 'bad'}`}>DB {metrics?.dbConnected ? 'Connected' : 'Offline'}</span>
          <span className={`pill ${monitorStatus.cls}`}>{monitorStatus.label}</span>
        </div>
      </header>

      <nav className="topnav">
        <NavLink to="/">Executive</NavLink>
        <NavLink to="/operations">Operations</NavLink>
        <NavLink to="/billing-risk">Billing & Risk</NavLink>
        <NavLink to="/data-quality">Data Quality</NavLink>
        <NavLink to="/kiosk">Kiosk</NavLink>
      </nav>

      <Routes>
        <Route path="/" element={<Executive summary={summary} liveSeries30m={liveSeries30m} currentMonthProfile={currentMonthProfile} />} />
        <Route path="/operations" element={<Operations series24h={series24h} metrics={metrics} lastMonthProfile={lastMonthProfile} currentMonthProfile={currentMonthProfile} currentWeekProfile={currentWeekProfile} />} />
        <Route path="/billing-risk" element={<BillingRisk summary={summary} billing={billing} />} />
        <Route path="/data-quality" element={<DataQuality quality={quality} />} />
      </Routes>
    </div>
  )
}

function Executive({ summary, liveSeries30m, currentMonthProfile }: { summary: Summary | null; liveSeries30m: LiveSeriesPoint[]; currentMonthProfile: IntervalSeriesPoint[] }) {
  return <section className="grid kpis">
    <Card t="Current kW (15m demand)" v={summary?.currentKW?.toFixed(2) ?? '—'} />
    <Card t="Live kW (15s)" v={summary?.currentKW_15s?.toFixed(2) ?? '—'} />
    <Card t="Today kWh" v={summary?.todayKWh.toFixed(2) ?? '—'} />
    <Card t="Today Peak kW" v={summary?.todayPeakKW.toFixed(2) ?? '—'} />
    <Card t="MTD kWh" v={summary?.mtdKWh.toFixed(0) ?? '—'} />
    <Card t="MTD Energy Est." v={summary ? money(summary.energyEstimateMonth) : '—'} />
    <Card t="Top-3 Avg kW" v={summary?.currentMonthTop3AvgKW.toFixed(2) ?? '—'} />
    <Card t="Ratchet Floor kW" v={summary?.ratchetFloorKW.toFixed(2) ?? '—'} />
    <Card t="Billed Demand kW" v={summary?.billedDemandEstimateKW.toFixed(2) ?? '—'} />
    <Card t="Demand Est. $/month" v={summary ? money(summary.demandEstimateMonth) : '—'} />
    <Card t="Cost of 100 kW Peak" v={summary ? money(summary.costOf100kwPeakAnnual) + '/yr' : '—'} />
    <div className="card chart-card full"><h3>Live kW - Last 30 Minutes</h3><ReactECharts style={{ height: 260 }} option={{ xAxis: { type: 'category', data: liveSeries30m.map((p) => new Date(p.t).toLocaleTimeString()) }, yAxis: { type: 'value', name: 'kW' }, series: [{ type: 'line', data: liveSeries30m.map((p) => p.kW), smooth: true, lineStyle: { color: '#00a3ff' } }] }} /></div>
    <div className="card chart-card full"><h3>Current Month kW Profile (15-minute intervals)</h3><ReactECharts style={{ height: 280 }} option={{ tooltip: { trigger: 'axis' }, xAxis: { type: 'category', data: currentMonthProfile.map((p) => new Date(p.t).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })) }, yAxis: { type: 'value', name: 'kW' }, series: [{ type: 'line', data: currentMonthProfile.map((p) => p.kW), showSymbol: false, lineStyle: { color: '#4c6ef5' } }] }} /></div>
  </section>
}

function Operations({ series24h, metrics, lastMonthProfile, currentMonthProfile, currentWeekProfile }: { series24h: IntervalSeriesPoint[]; metrics: Metrics | null; lastMonthProfile: IntervalSeriesPoint[]; currentMonthProfile: IntervalSeriesPoint[]; currentWeekProfile: IntervalSeriesPoint[] }) {
  return <section className="grid charts">
    <div className="card chart-card full"><h3>kW Profile - Last 24 Hours</h3><ReactECharts style={{ height: 320 }} option={{ xAxis: { type: 'category', data: series24h.map((p) => new Date(p.t).toLocaleTimeString()) }, yAxis: { type: 'value', name: 'kW' }, series: [{ type: 'line', data: series24h.map((p) => p.kW), smooth: true, lineStyle: { color: '#0a3a66' } }] }} /></div>
    <div className="card chart-card full"><h3>Last Month kW Profile (15-minute intervals)</h3><ReactECharts style={{ height: 300 }} option={{ tooltip: { trigger: 'axis' }, xAxis: { type: 'category', data: lastMonthProfile.map((p) => new Date(p.t).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })) }, yAxis: { type: 'value', name: 'kW' }, series: [{ type: 'line', data: lastMonthProfile.map((p) => p.kW), showSymbol: false, lineStyle: { color: '#228be6' } }] }} /></div>
    <div className="card chart-card full"><h3>Current Month kW Profile to Date (15-minute intervals)</h3><ReactECharts style={{ height: 300 }} option={{ tooltip: { trigger: 'axis' }, xAxis: { type: 'category', data: currentMonthProfile.map((p) => new Date(p.t).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })) }, yAxis: { type: 'value', name: 'kW' }, series: [{ type: 'line', data: currentMonthProfile.map((p) => p.kW), showSymbol: false, lineStyle: { color: '#5f3dc4' } }] }} /></div>
    <div className="card chart-card full"><h3>Current Week kW (Monday to Sunday, 15-minute intervals)</h3><ReactECharts style={{ height: 300 }} option={{ tooltip: { trigger: 'axis' }, xAxis: { type: 'category', data: currentWeekProfile.map((p) => new Date(p.t).toLocaleString(undefined, { weekday: 'short', hour: '2-digit', minute: '2-digit' })) }, yAxis: { type: 'value', name: 'kW' }, series: [{ type: 'line', data: currentWeekProfile.map((p) => p.kW), showSymbol: false, lineStyle: { color: '#0ca678' } }] }} /></div>
    <Card t="Rows (24h)" v={String(metrics?.rowCount24h ?? '—')} />
    <Card t="Seconds Since Last Interval" v={String(metrics?.secondsSinceLastInterval ?? '—')} />
  </section>
}

function BillingRisk({ summary, billing }: { summary: Summary | null; billing: BillingMonth[] }) {
  return <section className="grid charts">
    <Card t="Demand Estimate" v={summary ? money(summary.demandEstimateMonth) : '—'} />
    <Card t="Energy Estimate" v={summary ? money(summary.energyEstimateMonth) : '—'} />
    <div className="card chart-card full"><h3>Ratchet-aware Billing Demand (24 months)</h3><ReactECharts style={{ height: 330 }} option={{ tooltip: { trigger: 'axis' }, legend: { data: ['Top3', 'Ratchet Floor', 'Billed Demand'] }, xAxis: { type: 'category', data: billing.map((m) => m.monthStart.slice(0, 7)) }, yAxis: { type: 'value', name: 'kW' }, series: [{ name: 'Top3', type: 'line', data: billing.map((m) => m.top3AvgKW) }, { name: 'Ratchet Floor', type: 'line', data: billing.map((m) => m.ratchetFloorKW) }, { name: 'Billed Demand', type: 'bar', data: billing.map((m) => m.billedDemandKW) }] }} /></div>
  </section>
}

function DataQuality({ quality }: { quality: Quality | null }) {
  return <section className="grid kpis">
    <Card t="Missing Intervals (24h)" v={String(quality?.missingIntervals24h ?? '—')} />
    <Card t="Invalid Alarm (24h)" v={String(quality?.kyzInvalidAlarm.last24h ?? '—')} />
    <Card t="Invalid Alarm (7d)" v={String(quality?.kyzInvalidAlarm.last7d ?? '—')} />
    <Card t="R17 Exclude (24h)" v={String(quality?.r17Exclude.last24h ?? '—')} />
    <Card t="R17 Exclude (7d)" v={String(quality?.r17Exclude.last7d ?? '—')} />
  </section>
}

function Card({ t, v }: { t: string; v: string }) {
  return <div className="card"><h3>{t}</h3><p>{v}</p></div>
}
