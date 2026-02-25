export type KpiTone = 'neutral' | 'good' | 'warn' | 'bad'

type KpiTileProps = {
  title: string
  value: string
  metaPillText?: string
  metaText?: string
  metaTone?: KpiTone
}

export function KpiTile({ title, value, metaPillText, metaText, metaTone = 'neutral' }: KpiTileProps) {
  const pill = metaPillText ?? '—'
  const text = metaText ?? 'comparison unavailable'
  return (
    <div className="card kpi-card">
      <h3>{title}</h3>
      <p>{value}</p>
      <div className="kpi-meta">
        <span className={`kpi-pill ${metaTone}`}>{pill}</span>
        <span>{text}</span>
      </div>
    </div>
  )
}
