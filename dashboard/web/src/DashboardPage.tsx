import ReactECharts from 'echarts-for-react'
import { useEffect, useState } from 'react'
import { NavLink, Route, Routes } from 'react-router-dom'
import { client } from './api'
import type { BillingMonth, Metrics, Quality, Summary } from './types'

const money = (n: number) => `$${n.toLocaleString(undefined, { maximumFractionDigits: 0 })}`

export function DashboardPage() {
  const [summary, setSummary] = useState<Summary | null>(null)
  const [billing, setBilling] = useState<BillingMonth[]>([])
  const [quality, setQuality] = useState<Quality | null>(null)
  const [metrics, setMetrics] = useState<Metrics | null>(null)
  const [series24h, setSeries24h] = useState<Array<{ t: string; kW: number }>>([])

  useEffect(() => {
    const load = async () => {
      const [s, b, q, m, series] = await Promise.all([
        client.summary(),
        client.billing(24),
        client.quality(),
        client.metrics(),
        client.series(24 * 60),
      ])
      setSummary(s)
      setBilling(b.months)
      setQuality(q)
      setMetrics(m)
      setSeries24h(series.points)
    }
    load().catch(() => undefined)
    const t = setInterval(() => load().catch(() => undefined), 15000)
    return () => clearInterval(t)
  }, [])

  return (
    <div className="page">
      <header className="header">
        <div>
          <h1>Plant Energy Dashboard</h1>
          <small>{summary?.plantName ?? 'Plant'} • Last updated: {summary?.lastUpdated ? new Date(summary.lastUpdated).toLocaleString() : '—'}</small>
        </div>
        <div className="pills"><span className={`pill ${metrics?.dbConnected ? 'good' : 'bad'}`}>DB {metrics?.dbConnected ? 'Connected' : 'Offline'}</span></div>
      </header>

      <nav className="topnav">
        <NavLink to="/">Executive</NavLink>
        <NavLink to="/operations">Operations</NavLink>
        <NavLink to="/billing-risk">Billing & Risk</NavLink>
        <NavLink to="/data-quality">Data Quality</NavLink>
        <NavLink to="/kiosk">Kiosk</NavLink>
      </nav>

      <Routes>
        <Route path="/" element={<Executive summary={summary} />} />
        <Route path="/operations" element={<Operations series24h={series24h} metrics={metrics} />} />
        <Route path="/billing-risk" element={<BillingRisk summary={summary} billing={billing} />} />
        <Route path="/data-quality" element={<DataQuality quality={quality} />} />
      </Routes>
    </div>
  )
}

function Executive({ summary }: { summary: Summary | null }) {
  return <section className="grid kpis">
    <Card t="Current kW" v={summary?.currentKW?.toFixed(2) ?? '—'} />
    <Card t="Today kWh" v={summary?.todayKWh.toFixed(2) ?? '—'} />
    <Card t="Today Peak kW" v={summary?.todayPeakKW.toFixed(2) ?? '—'} />
    <Card t="MTD kWh" v={summary?.mtdKWh.toFixed(0) ?? '—'} />
    <Card t="MTD Energy Est." v={summary ? money(summary.energyEstimateMonth) : '—'} />
    <Card t="Top-3 Avg kW" v={summary?.currentMonthTop3AvgKW.toFixed(2) ?? '—'} />
    <Card t="Ratchet Floor kW" v={summary?.ratchetFloorKW.toFixed(2) ?? '—'} />
    <Card t="Billed Demand kW" v={summary?.billedDemandEstimateKW.toFixed(2) ?? '—'} />
    <Card t="Demand Est. $/month" v={summary ? money(summary.demandEstimateMonth) : '—'} />
    <Card t="Cost of 100 kW Peak" v={summary ? money(summary.costOf100kwPeakAnnual) + '/yr' : '—'} />
  </section>
}

function Operations({ series24h, metrics }: { series24h: Array<{ t: string; kW: number }>; metrics: Metrics | null }) {
  return <section className="grid charts">
    <div className="card chart-card full"><h3>kW Profile - Last 24 Hours</h3><ReactECharts style={{ height: 320 }} option={{ xAxis: { type: 'category', data: series24h.map((p) => new Date(p.t).toLocaleTimeString()) }, yAxis: { type: 'value' }, series: [{ type: 'line', data: series24h.map((p) => p.kW), smooth: true, lineStyle: { color: '#0a3a66' } }] }} /></div>
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
