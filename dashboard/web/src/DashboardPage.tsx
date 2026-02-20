import ReactECharts from 'echarts-for-react'
import { useEffect, useMemo, useState } from 'react'
import { client } from './api'
import type { Health, LatestRow } from './types'

const fmt = (v?: string | null) => (v ? new Date(v).toLocaleString() : '—')

export function DashboardPage() {
  const [health, setHealth] = useState<Health | null>(null)
  const [latest, setLatest] = useState<LatestRow | null>(null)
  const [series4h, setSeries4h] = useState<Array<{ t: string; kW: number }>>([])
  const [series24h, setSeries24h] = useState<Array<{ t: string; kW: number }>>([])
  const [daily, setDaily] = useState<Array<{ date: string; kWh_sum: number }>>([])
  const [monthly, setMonthly] = useState<Array<{ monthStart: string; peak_kW: number; top3_avg_kW: number }>>([])
  const [error, setError] = useState<string>('')

  async function load() {
    try {
      const [h, l, s4, s24, d, m] = await Promise.all([
        client.health(),
        client.latest(),
        client.series(240),
        client.series(1440),
        client.daily(14),
        client.monthly(12),
      ])
      setHealth(h)
      setLatest(l)
      setSeries4h(s4.points)
      setSeries24h(s24.points)
      setDaily(d.days)
      setMonthly(m.months)
      setError('')
    } catch (e) {
      setError(`Disconnected: ${String(e)}`)
    }
  }

  useEffect(() => {
    load()
    const timer = setInterval(load, 15000)
    return () => clearInterval(timer)
  }, [])

  const stale = (health?.secondsSinceLatest ?? 99999) > 1800
  const currentMonth = useMemo(() => monthly[monthly.length - 1], [monthly])
  const today = useMemo(() => daily[daily.length - 1], [daily])

  return (
    <div className="page">
      <header className="header">
        <h1>Plant Energy Dashboard</h1>
        <div className="pills">
          <span className={`pill ${stale ? 'bad' : 'good'}`}>{stale ? 'STALE' : 'LIVE'}</span>
          <span className="pill">Last IntervalEnd: {fmt(health?.latestIntervalEnd)}</span>
          <span className={`pill ${health?.dbConnected ? 'good' : 'bad'}`}>DB: {health?.dbConnected ? 'OK' : 'FAIL'}</span>
        </div>
      </header>

      {error && <div className="banner bad">{error}</div>}
      {latest?.KyzInvalidAlarm && <div className="banner bad">KYZ Invalid Alarm is active on latest interval.</div>}
      {latest?.R17Exclude && <div className="banner warn">R17 Exclude flag is active on latest interval.</div>}

      <section className="grid kpis">
        <div className="card"><h3>Current kW</h3><p>{latest?.kW?.toFixed(2) ?? '—'}</p></div>
        <div className="card"><h3>Today kWh</h3><p>{today?.kWh_sum?.toFixed(2) ?? '—'}</p></div>
        <div className="card"><h3>Month peak kW</h3><p>{currentMonth?.peak_kW?.toFixed(2) ?? '—'}</p></div>
        <div className="card"><h3>Billing demand estimate</h3><p>{currentMonth?.top3_avg_kW?.toFixed(2) ?? '—'}</p></div>
      </section>

      <section className="grid charts">
        <div className="card chart-card">
          <h3>kW - Last 4 Hours</h3>
          <ReactECharts style={{ height: 280 }} option={lineOpt(series4h)} />
        </div>
        <div className="card chart-card">
          <h3>kW - Last 24 Hours</h3>
          <ReactECharts style={{ height: 280 }} option={lineOpt(series24h)} />
        </div>
        <div className="card chart-card full">
          <h3>Daily kWh - Last 14 Days</h3>
          <ReactECharts style={{ height: 320 }} option={dailyOpt(daily)} />
        </div>
      </section>
    </div>
  )
}

function lineOpt(data: Array<{ t: string; kW: number }>) {
  return {
    tooltip: { trigger: 'axis' },
    xAxis: { type: 'category', data: data.map((p) => new Date(p.t).toLocaleTimeString()) },
    yAxis: { type: 'value', name: 'kW' },
    series: [{ type: 'line', smooth: true, data: data.map((p) => p.kW), lineStyle: { width: 3, color: '#003366' } }],
    grid: { left: 40, right: 20, top: 30, bottom: 40 },
  }
}

function dailyOpt(data: Array<{ date: string; kWh_sum: number }>) {
  return {
    tooltip: { trigger: 'axis' },
    xAxis: { type: 'category', data: data.map((d) => d.date) },
    yAxis: { type: 'value', name: 'kWh' },
    series: [{ type: 'bar', data: data.map((d) => d.kWh_sum), itemStyle: { color: '#2f70a8', borderRadius: [6, 6, 0, 0] } }],
    grid: { left: 40, right: 20, top: 30, bottom: 40 },
  }
}
