import ReactECharts from 'echarts-for-react'
import { useEffect, useMemo, useRef, useState } from 'react'
import { NavLink, Route, Routes, useLocation } from 'react-router-dom'
import { client } from './api'
import { INNOV_LOGO_SRC, PRI_LOGO_SRC } from './brand'
import { buildChartOption } from './chartTheme'
import { DataExplorerPage } from './DataExplorerPage'
import { KpiTile } from './KpiTile'
import { formatPct, toneFromDelta } from './kpiMeta'
import { applyTheme, getInitialTheme, setStoredTheme, type ThemeMode } from './theme'
import type { BillingMonth, Health, IntervalSeriesPoint, LiveSeriesPoint, Metrics, Quality, Summary } from './types'

const money = (n: number) => `$${n.toLocaleString(undefined, { maximumFractionDigits: 0 })}`

function getMonthRange(base: Date, offsetMonths = 0): { start: Date; end: Date } {
  const start = new Date(base.getFullYear(), base.getMonth() + offsetMonths, 1)
  const end = new Date(base.getFullYear(), base.getMonth() + offsetMonths + 1, 1)
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

function getMonitorStatus(health: Health | null): { label: string; cls: 'good' | 'warn' | 'bad' } {
  if (!health?.dbConnected || !health.latestLiveEnd) return { label: 'KYZ Monitor Disconnected', cls: 'bad' }
  if ((health.secondsSinceLatestLive ?? Infinity) > 300) return { label: 'KYZ Monitor Delayed', cls: 'warn' }
  return { label: 'KYZ Monitor Connected', cls: 'good' }
}

function ChartOrPlaceholder({ title, data, height, xLabel, seriesType = 'line', className = '' }: { title: string; data: IntervalSeriesPoint[] | null; height: number; xLabel: Intl.DateTimeFormatOptions; seriesType?: 'line' | 'bar'; className?: string }) {
  const option = useMemo(() => {
    if (!data || !data.length) return null
    return buildChartOption({
      xData: data.map((p) => new Date(p.t).toLocaleString(undefined, xLabel)),
      yName: 'kW',
      series: [{ type: seriesType, data: data.map((p) => p.kW), smooth: true, showSymbol: false }],
    })
  }, [data, xLabel, seriesType])

  return (
    <div className={`card chart-card ${className}`.trim()}>
      <h3>{title}</h3>
      {option ? <ReactECharts style={{ height }} option={option} /> : <p className="muted">No data available.</p>}
    </div>
  )
}

export function DashboardPage() {
  const location = useLocation()
  const [theme, setTheme] = useState<ThemeMode>(() => getInitialTheme())
  const [summary, setSummary] = useState<Summary | null>(null)
  const [billing, setBilling] = useState<BillingMonth[]>([])
  const [billingBasis, setBillingBasis] = useState<'calendar' | 'billing'>('calendar')
  const [billingMode, setBillingMode] = useState<'calendar' | 'billing'>('calendar')
  const [billingAnchorDate, setBillingAnchorDate] = useState<string | null>(null)
  const [quality, setQuality] = useState<Quality | null>(null)
  const [metrics, setMetrics] = useState<Metrics | null>(null)
  const [health, setHealth] = useState<Health | null>(null)
  const [series24h, setSeries24h] = useState<IntervalSeriesPoint[]>([])
  const [liveSeries30m, setLiveSeries30m] = useState<LiveSeriesPoint[]>([])
  const [lastMonthProfile, setLastMonthProfile] = useState<IntervalSeriesPoint[] | null>(null)
  const [currentMonthProfile, setCurrentMonthProfile] = useState<IntervalSeriesPoint[] | null>(null)
  const [currentWeekProfile, setCurrentWeekProfile] = useState<IntervalSeriesPoint[] | null>(null)
  const slowRefreshAtRef = useRef(0)

  useEffect(() => {
    const loadFast = async () => {
      const settled = await Promise.allSettled([client.summary(), client.billing(24, billingBasis), client.quality(), client.metrics(), client.health(), client.series(24 * 60), client.liveSeries(30)])
      if (settled[0].status === 'fulfilled') setSummary(settled[0].value)
      if (settled[1].status === 'fulfilled') {
        setBilling(settled[1].value.months)
        setBillingMode(settled[1].value.basis)
        setBillingAnchorDate(settled[1].value.anchorDate)
      }
      if (settled[2].status === 'fulfilled') setQuality(settled[2].value)
      if (settled[3].status === 'fulfilled') setMetrics(settled[3].value)
      if (settled[4].status === 'fulfilled') setHealth(settled[4].value)
      if (settled[5].status === 'fulfilled') setSeries24h(settled[5].value.points)
      if (settled[6].status === 'fulfilled') setLiveSeries30m(settled[6].value.points)
    }

    const loadSlow = async () => {
      const now = new Date()
      const { start: currentMonthStart } = getMonthRange(now)
      const { start: lastMonthStart } = getMonthRange(now, -1)
      const { start: weekStart, end: weekEnd } = getCurrentWeekRange(now)
      const settled = await Promise.allSettled([
        client.series(24 * 60, lastMonthStart.toISOString(), currentMonthStart.toISOString()),
        client.series(24 * 60, currentMonthStart.toISOString(), now.toISOString()),
        client.series(7 * 24 * 60, weekStart.toISOString(), weekEnd.toISOString()),
      ])
      setLastMonthProfile(settled[0].status === 'fulfilled' ? settled[0].value.points : null)
      setCurrentMonthProfile(settled[1].status === 'fulfilled' ? settled[1].value.points : null)
      setCurrentWeekProfile(settled[2].status === 'fulfilled' ? settled[2].value.points : null)
    }

    const load = async () => {
      await loadFast()
      const nowMs = Date.now()
      if (nowMs - slowRefreshAtRef.current >= 5 * 60 * 1000) {
        slowRefreshAtRef.current = nowMs
        await loadSlow()
      }
    }

    load().catch(() => undefined)
    const t = setInterval(() => load().catch(() => undefined), 15000)
    return () => clearInterval(t)
  }, [billingBasis])

  const monitorStatus = getMonitorStatus(health)
  const withSearch = (path: string) => `${path}${location.search}`
  const toggleTheme = () => {
    const next: ThemeMode = theme === 'dark' ? 'light' : 'dark'
    setTheme(next)
    setStoredTheme(next)
    applyTheme(next)
  }

  return (
    <div className="page">
      <header className="header">
        <div className="headerLeft">
          <img className="priLogoImg" src={PRI_LOGO_SRC} alt="PRI Logo" />
          <div className="headerTitleBlock">
            <h1>Plant Energy Dashboard</h1>
            <div className="muted">{summary?.plantName ?? 'Plant'} • Last updated: {summary?.lastUpdated ? new Date(summary.lastUpdated).toLocaleString() : '—'}</div>
          </div>
        </div>
        <div className="headerRight">
          <button className="theme-toggle" onClick={toggleTheme}>{theme === 'dark' ? 'Dark' : 'Light'}</button>
          <img className="innovLogoImg" src={INNOV_LOGO_SRC} alt="Innovation Team" />
        </div>
      </header>

      <div className="pills">
        <span className={`pill ${metrics?.dbConnected ? 'good' : 'bad'}`}><span className={`dot ${metrics?.dbConnected ? 'good' : 'bad'}`} />DB {metrics?.dbConnected ? 'Connected' : 'Offline'}</span>
        <span className={`pill ${monitorStatus.cls}`}><span className={`dot ${monitorStatus.cls}`} />{monitorStatus.label}</span>
      </div>

      <nav className="topnav">
        <NavLink to={withSearch('/')}>Executive</NavLink>
        <NavLink to={withSearch('/operations')}>Operations</NavLink>
        <NavLink to={withSearch('/billing-risk')}>Billing & Risk</NavLink>
        <NavLink to={withSearch('/data-quality')}>Data Quality</NavLink>
        <NavLink to={withSearch('/data-explorer')}>Data Explorer</NavLink>
        <NavLink to={withSearch('/kiosk')}>Kiosk</NavLink>
      </nav>

      <Routes>
        <Route path="/" element={<Executive summary={summary} liveSeries30m={liveSeries30m} currentMonthProfile={currentMonthProfile} />} />
        <Route path="/operations" element={<Operations series24h={series24h} metrics={metrics} lastMonthProfile={lastMonthProfile} currentMonthProfile={currentMonthProfile} currentWeekProfile={currentWeekProfile} />} />
        <Route path="/billing-risk" element={<BillingRisk summary={summary} billing={billing} billingBasis={billingBasis} setBillingBasis={setBillingBasis} billingMode={billingMode} billingAnchorDate={billingAnchorDate} />} />
        <Route path="/data-quality" element={<DataQuality quality={quality} />} />
        <Route path="/data-explorer" element={<DataExplorerPage />} />
      </Routes>
    </div>
  )
}

function Executive({ summary, liveSeries30m, currentMonthProfile }: { summary: Summary | null; liveSeries30m: LiveSeriesPoint[]; currentMonthProfile: IntervalSeriesPoint[] | null }) {
  const billingPeriodText = summary?.billingPeriodStart && summary?.billingPeriodEnd
    ? `${new Date(summary.billingPeriodStart).toLocaleDateString()} → ${new Date(summary.billingPeriodEnd).toLocaleDateString()}`
    : 'billing basis not configured'
  const peakPct = summary?.todayPeakPctOf11moMax
  const headroomPct = peakPct != null ? Math.max(0, 100 - peakPct) : null
  const billedDemandVsRatchet = summary != null && Math.abs(summary.billedDemandEstimateKW - summary.ratchetFloorKW) < 0.01

  return <section className="grid kpis">
    <KpiTile
      title="Current kW (15m demand)"
      value={summary?.currentKW?.toFixed(2) ?? '—'}
      metaPillText={summary?.currentKWPctVsPrev15m != null ? formatPct(summary.currentKWPctVsPrev15m) : undefined}
      metaText="vs prior 15m"
      metaTone={toneFromDelta(summary?.currentKWPctVsPrev15m, true)}
    />
    <KpiTile
      title="Live kW (15s)"
      value={summary?.currentKW_15s?.toFixed(2) ?? '—'}
      metaPillText={summary?.liveKWPctVs5mAvg != null ? (Math.abs(summary.liveKWPctVs5mAvg) <= 1 ? 'Stable' : formatPct(summary.liveKWPctVs5mAvg)) : undefined}
      metaText="vs 5m avg • 15s cadence"
      metaTone={summary?.liveKWPctVs5mAvg != null ? (Math.abs(summary.liveKWPctVs5mAvg) <= 1 ? 'neutral' : 'warn') : 'neutral'}
    />
    <KpiTile
      title="Today kWh"
      value={summary?.todayKWh.toFixed(2) ?? '—'}
      metaPillText={summary?.todayKWhPctVsYesterdayToTime != null ? formatPct(summary.todayKWhPctVsYesterdayToTime) : undefined}
      metaText="vs yesterday (to this time)"
      metaTone={toneFromDelta(summary?.todayKWhPctVsYesterdayToTime, true)}
    />
    <KpiTile
      title="Today Peak kW"
      value={summary?.todayPeakKW.toFixed(2) ?? '—'}
      metaPillText={peakPct != null ? (peakPct >= 95 ? `Risk ${peakPct.toFixed(1)}%` : peakPct >= 90 ? `Watch ${peakPct.toFixed(1)}%` : `Headroom ${(headroomPct ?? 0).toFixed(1)}%`) : undefined}
      metaText="relative to 11-month max"
      metaTone={peakPct != null ? (peakPct >= 95 ? 'bad' : peakPct >= 90 ? 'warn' : 'neutral') : 'neutral'}
    />
    <KpiTile
      title="MTD kWh"
      value={summary?.mtdKWh.toFixed(0) ?? '—'}
      metaPillText={summary?.mtdKWhPacePctVs30dAvg != null ? `${summary.mtdKWhPacePctVs30dAvg.toFixed(1)}% pace` : undefined}
      metaText="vs 30-day avg pace"
      metaTone={summary?.mtdKWhPacePctVs30dAvg != null ? (summary.mtdKWhPacePctVs30dAvg > 100 ? 'warn' : 'good') : 'neutral'}
    />
    <KpiTile
      title="MTD Energy Est."
      value={summary ? money(summary.energyEstimateMonth) : '—'}
      metaPillText={summary?.mtdKWhPacePctVs30dAvg != null ? `${summary.mtdKWhPacePctVs30dAvg.toFixed(1)}% pace` : undefined}
      metaText="vs 30-day avg pace"
      metaTone={summary?.mtdKWhPacePctVs30dAvg != null ? (summary.mtdKWhPacePctVs30dAvg > 100 ? 'warn' : 'good') : 'neutral'}
    />
    <KpiTile title="Billing Period kWh (BTD)" value={summary?.btdKWh != null ? summary.btdKWh.toFixed(0) : '—'} metaPillText="Billing-to-date" metaText={billingPeriodText} metaTone={summary?.billingPeriodStart ? 'neutral' : 'warn'} />
    <KpiTile title="Billing Period Energy Est." value={summary?.billingEnergyEstimate != null ? money(summary.billingEnergyEstimate) : '—'} metaPillText="Billing-to-date" metaText={billingPeriodText} metaTone={summary?.billingPeriodStart ? 'neutral' : 'warn'} />
    <KpiTile
      title="Top-3 Avg kW"
      value={summary?.currentMonthTop3AvgKW.toFixed(2) ?? '—'}
      metaPillText={summary?.top3AvgPctVsLastMonth != null ? formatPct(summary.top3AvgPctVsLastMonth) : undefined}
      metaText="vs last month"
      metaTone={toneFromDelta(summary?.top3AvgPctVsLastMonth, true)}
    />
    <KpiTile
      title="Ratchet Floor kW"
      value={summary?.ratchetFloorKW.toFixed(2) ?? '—'}
      metaPillText="60% rule"
      metaText={peakPct != null ? `${peakPct.toFixed(1)}% of 11-month max` : 'ratchet baseline'}
      metaTone="neutral"
    />
    <KpiTile
      title="Billed Demand kW"
      value={summary?.billedDemandEstimateKW.toFixed(2) ?? '—'}
      metaPillText={billedDemandVsRatchet ? 'Ratchet binding' : 'Top-3 basis'}
      metaText="billed = max(top-3 avg, ratchet floor)"
      metaTone={billedDemandVsRatchet ? 'warn' : 'neutral'}
    />
    <KpiTile
      title="Demand Est. $/month"
      value={summary ? money(summary.demandEstimateMonth) : '—'}
      metaPillText={summary?.demandCostPctVsLastMonth != null ? formatPct(summary.demandCostPctVsLastMonth) : undefined}
      metaText="vs last month (ratchet-aware)"
      metaTone={toneFromDelta(summary?.demandCostPctVsLastMonth, true)}
    />
    <div className="card chart-card full">
      <h3>Live kW - Last 30 Minutes</h3>
      <ReactECharts style={{ height: 260 }} option={buildChartOption({ xData: liveSeries30m.map((p) => new Date(p.t).toLocaleTimeString()), yName: 'kW', series: [{ type: 'line', data: liveSeries30m.map((p) => p.kW), smooth: true, showSymbol: false }] })} />
    </div>
    <ChartOrPlaceholder title="Current Month kW Profile (15-minute intervals)" data={currentMonthProfile} height={280} xLabel={{ month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }} className="full" />
  </section>
}

function Operations({ series24h, metrics, lastMonthProfile, currentMonthProfile, currentWeekProfile }: { series24h: IntervalSeriesPoint[]; metrics: Metrics | null; lastMonthProfile: IntervalSeriesPoint[] | null; currentMonthProfile: IntervalSeriesPoint[] | null; currentWeekProfile: IntervalSeriesPoint[] | null }) {
  return <section className="grid charts">
    <div className="card chart-card full">
      <h3>kW Profile - Last 24 Hours</h3>
      <ReactECharts style={{ height: 320 }} option={buildChartOption({ xData: series24h.map((p) => new Date(p.t).toLocaleTimeString()), yName: 'kW', series: [{ type: 'line', data: series24h.map((p) => p.kW), smooth: true, showSymbol: false }] })} />
    </div>
    <ChartOrPlaceholder title="Last Month kW Profile (15-minute intervals)" data={lastMonthProfile} height={300} xLabel={{ month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }} />
    <ChartOrPlaceholder title="Current Month kW Profile to Date (15-minute intervals)" data={currentMonthProfile} height={300} xLabel={{ month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }} />
    <ChartOrPlaceholder title="Current Week kW (Monday to Sunday, 15-minute intervals)" data={currentWeekProfile} height={300} xLabel={{ weekday: 'short', hour: '2-digit', minute: '2-digit' }} />
    <Card t="Rows (24h)" v={String(metrics?.rowCount24h ?? '—')} />
    <Card t="Seconds Since Last Interval" v={String(metrics?.secondsSinceLastInterval ?? '—')} />
  </section>
}

function BillingRisk({ summary, billing, billingBasis, setBillingBasis, billingMode, billingAnchorDate }: { summary: Summary | null; billing: BillingMonth[]; billingBasis: 'calendar' | 'billing'; setBillingBasis: (b: 'calendar' | 'billing') => void; billingMode: 'calendar' | 'billing'; billingAnchorDate: string | null }) {
  return <section className="grid charts">
    <div className="card full">
      <h3>Billing Basis</h3>
      <div className="btn-group">
        <button onClick={() => setBillingBasis('calendar')} disabled={billingBasis === 'calendar'}>Calendar Months</button>
        <button onClick={() => setBillingBasis('billing')} disabled={billingBasis === 'billing'}>Billing Periods</button>
      </div>
      <p className="muted">{billingMode === 'billing' ? `Using anchored billing periods (anchor: ${billingAnchorDate ?? 'n/a'})` : 'Using calendar month aggregation.'}</p>
    </div>
    <Card t="Demand Estimate" v={summary ? money(summary.demandEstimateMonth) : '—'} />
    <Card t="Energy Estimate" v={summary ? money(summary.energyEstimateMonth) : '—'} />
    <div className="card chart-card full">
      <h3>Ratchet-aware Billing Demand (24 periods)</h3>
      <ReactECharts style={{ height: 330 }} option={buildChartOption({
        xData: billing.map((m) => billingMode === 'billing' ? m.periodStart : m.monthStart.slice(0, 7)),
        yName: 'kW',
        legend: ['Top3', 'Ratchet Floor', 'Billed Demand'],
        series: [
          { name: 'Top3', type: 'line', data: billing.map((m) => m.top3AvgKW), smooth: true, showSymbol: false },
          { name: 'Ratchet Floor', type: 'line', data: billing.map((m) => m.ratchetFloorKW), smooth: true, showSymbol: false },
          { name: 'Billed Demand', type: 'bar', data: billing.map((m) => m.billedDemandKW) },
        ],
      })} />
    </div>
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
  return <div className="card kpi-card"><h3>{t}</h3><p>{v}</p></div>
}
