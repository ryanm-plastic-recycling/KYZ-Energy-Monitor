export type LatestRow = {
  IntervalEnd: string
  kW: number
  kWh: number
  PulseCount: number
  Total_kWh: number | null
  R17Exclude: boolean | null
  KyzInvalidAlarm: boolean | null
}

export type LiveLatestRow = {
  SampleEnd: string
  kW: number | null
  kWh: number | null
  PulseCount: number | null
  Total_kWh: number | null
}

export type LiveSeriesPoint = {
  t: string
  kW: number
  kWh: number
}

export type IntervalSeriesPoint = {
  t: string
  kW: number
  kWh: number
  flags?: {
    r17Exclude: boolean
    kyzInvalidAlarm: boolean
  }
}

export type Health = {
  serverTime: string
  dbConnected: boolean
  latestIntervalEnd: string | null
  secondsSinceLatest: number | null
  latestLiveEnd: string | null
  secondsSinceLatestLive: number | null
}

export type Summary = {
  plantName: string
  lastUpdated: string | null
  currentKW: number | null
  currentKW_15s: number | null
  todayKWh: number
  todayPeakKW: number
  mtdKWh: number
  energyEstimateMonth: number
  currentMonthTop3AvgKW: number
  ratchetFloorKW: number
  billedDemandEstimateKW: number
  demandEstimateMonth: number
  costOf100kwPeakAnnual: number
  billingPeriodStart: string | null
  billingPeriodEnd: string | null
  btdKWh: number | null
  billingEnergyEstimate: number | null
  currentBillingPeriodTop3AvgKW: number | null
  currentBillingPeriodBilledDemandKW: number | null
  billingRatchetFloorKW: number | null
  currentKWPrev15m: number | null
  currentKWPctVsPrev15m: number | null
  liveKWAvg5m: number | null
  liveKWPctVs5mAvg: number | null
  yesterdayKWhToTime: number | null
  todayKWhPctVsYesterdayToTime: number | null
  avgDailyKWh30d: number | null
  mtdKWhPacePctVs30dAvg: number | null
  maxIntervalKW11mo: number | null
  todayPeakPctOf11moMax: number | null
  lastMonthTop3AvgKW: number | null
  top3AvgPctVsLastMonth: number | null
  lastMonthBilledDemandKW: number | null
  billedDemandPctVsLastMonth: number | null
  lastMonthDemandCost: number | null
  demandCostPctVsLastMonth: number | null
}

export type BillingMonth = {
  monthStart: string
  periodStart: string
  periodEnd: string
  top3AvgKW: number
  ratchetFloorKW: number
  billedDemandKW: number
  demandCost: number
  energyKWh: number
  energyCost: number
  customerCharge: number
  totalEstimatedCost: number
}

export type BillingResponse = {
  basis: 'calendar' | 'billing'
  requestedBasis: 'calendar' | 'billing'
  anchorDate: string | null
  months: BillingMonth[]
}

export type Quality = {
  expectedIntervals24h: number
  observedIntervals24h: number
  missingIntervals24h: number
  kyzInvalidAlarm: { last24h: number; last7d: number }
  r17Exclude: { last24h: number; last7d: number }
}

export type Metrics = {
  dbConnected: boolean
  lastIntervalEnd: string | null
  secondsSinceLastInterval: number | null
  rowCount24h: number
  r17Exclude24h: number
  kyzInvalidAlarm24h: number
}

export type DailyPoint = {
  date: string
  kWh_sum: number
  kW_peak: number
  interval_count: number
}
