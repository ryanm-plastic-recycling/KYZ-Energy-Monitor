import { useEffect, useMemo, useState } from 'react'
import { client } from './api'
import type { IntervalSeriesPoint } from './types'

type RangeKey = '6h' | '24h' | '7d' | 'custom'

const MAX_MINUTES = 60 * 24 * 31

function formatInputDate(date: Date): string {
  const pad = (v: number) => String(v).padStart(2, '0')
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
}

function presetRange(range: Exclude<RangeKey, 'custom'>): { start: Date; end: Date } {
  const end = new Date()
  const start = new Date(end)
  if (range === '6h') start.setHours(end.getHours() - 6)
  if (range === '24h') start.setHours(end.getHours() - 24)
  if (range === '7d') start.setDate(end.getDate() - 7)
  return { start, end }
}

export function DataExplorerPage() {
  const initialRange = presetRange('24h')
  const [range, setRange] = useState<RangeKey>('24h')
  const [startInput, setStartInput] = useState(formatInputDate(initialRange.start))
  const [endInput, setEndInput] = useState(formatInputDate(initialRange.end))
  const [excludeR17, setExcludeR17] = useState(false)
  const [excludeInvalid, setExcludeInvalid] = useState(false)
  const [rows, setRows] = useState<IntervalSeriesPoint[]>([])
  const [selectedIndex, setSelectedIndex] = useState<number | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (range === 'custom') return
    const p = presetRange(range)
    setStartInput(formatInputDate(p.start))
    setEndInput(formatInputDate(p.end))
  }, [range])

  const load = async () => {
    const start = new Date(startInput)
    const end = new Date(endInput)
    if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime()) || end <= start) {
      setError('Please set a valid start/end range.')
      return
    }

    const minutes = Math.min(Math.max(1, Math.ceil((end.getTime() - start.getTime()) / 60000)), MAX_MINUTES)
    setLoading(true)
    setError(null)

    try {
      const data = await client.series(minutes, start.toISOString(), end.toISOString())
      setRows(data.points)
      setSelectedIndex(data.points.length ? 0 : null)
    } catch (err) {
      setError(`Could not load series data: ${err instanceof Error ? err.message : 'Unknown error'}`)
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    load().catch(() => undefined)
  }, [])

  const filtered = useMemo(
    () =>
      rows.filter((row) => {
        if (excludeR17 && row.flags?.r17Exclude) return false
        if (excludeInvalid && row.flags?.kyzInvalidAlarm) return false
        return true
      }),
    [rows, excludeInvalid, excludeR17],
  )

  const activeRow = selectedIndex != null ? filtered[selectedIndex] : null
  const previousRow = selectedIndex != null && selectedIndex > 0 ? filtered[selectedIndex - 1] : null

  return (
    <section className="data-explorer-layout">
      <aside className="card filter-rail">
        <h3>Filters</h3>
        <div className="range-buttons">
          <button className={range === '6h' ? 'active' : ''} onClick={() => setRange('6h')}>Last 6h</button>
          <button className={range === '24h' ? 'active' : ''} onClick={() => setRange('24h')}>Last 24h</button>
          <button className={range === '7d' ? 'active' : ''} onClick={() => setRange('7d')}>Last 7d</button>
          <button className={range === 'custom' ? 'active' : ''} onClick={() => setRange('custom')}>Custom</button>
        </div>

        <label>Start</label>
        <input type="datetime-local" value={startInput} onChange={(e) => { setRange('custom'); setStartInput(e.target.value) }} />

        <label>End</label>
        <input type="datetime-local" value={endInput} onChange={(e) => { setRange('custom'); setEndInput(e.target.value) }} />

        <button onClick={() => load().catch(() => undefined)} disabled={loading}>{loading ? 'Loading…' : 'Load Data'}</button>

        <label className="checkbox-row"><input type="checkbox" checked={excludeR17} onChange={(e) => setExcludeR17(e.target.checked)} /> Exclude R17</label>
        <label className="checkbox-row"><input type="checkbox" checked={excludeInvalid} onChange={(e) => setExcludeInvalid(e.target.checked)} /> Exclude Invalid Alarm</label>

        <div className="chip-row">
          {excludeR17 && <span className="pill warn"><span className="dot warn" />No R17</span>}
          {excludeInvalid && <span className="pill bad"><span className="dot bad" />No Invalid</span>}
        </div>
      </aside>

      <div className="card data-results">
        <div className="table-shell">
          {error && <div className="error-banner">{error}</div>}
          <table>
            <thead>
              <tr><th>Timestamp</th><th>kW</th><th>kWh</th><th>Flags</th></tr>
            </thead>
            <tbody>
              {filtered.map((row, idx) => (
                <tr key={`${row.t}-${idx}`} className={idx === selectedIndex ? 'selected' : ''} onClick={() => setSelectedIndex(idx)}>
                  <td>{new Date(row.t).toLocaleString()}</td>
                  <td>{row.kW.toFixed(2)}</td>
                  <td>{row.kWh.toFixed(3)}</td>
                  <td>
                    <div className="chip-row">
                      {row.flags?.r17Exclude && <span className="pill warn"><span className="dot warn" />R17</span>}
                      {row.flags?.kyzInvalidAlarm && <span className="pill bad"><span className="dot bad" />Invalid</span>}
                      {!row.flags?.r17Exclude && !row.flags?.kyzInvalidAlarm && <span className="muted">None</span>}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="row-preview">
          <h3>Row Preview</h3>
          {activeRow ? (
            <div className="preview-grid">
              <div><strong>Timestamp:</strong> {new Date(activeRow.t).toLocaleString()}</div>
              <div><strong>kW:</strong> {activeRow.kW.toFixed(2)}</div>
              <div><strong>kWh:</strong> {activeRow.kWh.toFixed(3)}</div>
              <div><strong>Flags:</strong> {activeRow.flags?.r17Exclude || activeRow.flags?.kyzInvalidAlarm ? `${activeRow.flags?.r17Exclude ? 'R17 ' : ''}${activeRow.flags?.kyzInvalidAlarm ? 'Invalid' : ''}` : 'None'}</div>
              {previousRow && <div><strong>ΔkW vs prev:</strong> {(activeRow.kW - previousRow.kW).toFixed(2)}</div>}
            </div>
          ) : (
            <p className="muted">Select a row to inspect details.</p>
          )}
        </div>
      </div>
    </section>
  )
}
