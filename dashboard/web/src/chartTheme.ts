import type { EChartsOption, SeriesOption } from 'echarts'

function cssVar(name: string, fallback: string): string {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim() || fallback
}

function chartColors(): string[] {
  return [
    cssVar('--chart1', '#00a3ff'),
    cssVar('--chart2', '#3ecf8e'),
    cssVar('--chart3', '#f6b01e'),
    cssVar('--chart4', '#ff5a5f'),
  ]
}

type BuildChartOptionArgs = {
  xData: string[]
  yName?: string
  legend?: string[]
  series: SeriesOption[]
}

export function buildChartOption({ xData, yName, legend, series }: BuildChartOptionArgs): EChartsOption {
  const text = cssVar('--text', '#eaf2ff')
  const muted = cssVar('--muted', '#9ca8bc')
  const border = cssVar('--border', 'rgba(200,215,235,.12)')
  const surface = cssVar('--surface', '#0c1526')

  return {
    color: chartColors(),
    tooltip: {
      trigger: 'axis',
      backgroundColor: surface,
      borderColor: border,
      borderWidth: 1,
      textStyle: { color: text },
    },
    legend: legend
      ? {
          data: legend,
          textStyle: { color: muted },
          top: 0,
        }
      : undefined,
    grid: { left: 52, right: 24, top: legend ? 42 : 24, bottom: 42 },
    xAxis: {
      type: 'category',
      data: xData,
      axisLabel: { color: muted, fontSize: 11 },
      axisLine: { lineStyle: { color: border } },
    },
    yAxis: {
      type: 'value',
      name: yName,
      nameTextStyle: { color: muted },
      axisLabel: { color: muted, fontSize: 11 },
      axisLine: { lineStyle: { color: border } },
      splitLine: { lineStyle: { color: border, opacity: 0.55 } },
    },
    series,
  }
}
