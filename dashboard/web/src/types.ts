export type LatestRow = {
  IntervalEnd: string
  kW: number
  kWh: number
  PulseCount: number
  Total_kWh: number | null
  R17Exclude: boolean | null
  KyzInvalidAlarm: boolean | null
}

export type Health = {
  serverTime: string
  dbConnected: boolean
  latestIntervalEnd: string | null
  secondsSinceLatest: number | null
}
