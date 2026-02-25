/*
  KPI context baseline procedure for KYZ Energy Monitor.
  NOTE: The FastAPI /api/summary endpoint currently computes these values inline.
  This proc is intended for future optimization / change control standardization.
*/
CREATE OR ALTER PROCEDURE dbo.usp_KYZ_KpiContext
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @today date = CAST(GETDATE() AS date);
  DECLARE @yesterday_start datetime = DATEADD(day, -1, @today);
  DECLARE @seconds_since_midnight int = DATEDIFF(second, @today, GETDATE());
  DECLARE @yesterday_end datetime = DATEADD(second, @seconds_since_midnight, @yesterday_start);

  ;WITH latest_two AS (
      SELECT TOP (2)
          IntervalEnd,
          CAST(kW AS float) AS kW,
          ROW_NUMBER() OVER (ORDER BY IntervalEnd DESC) AS rn
      FROM dbo.KYZ_Interval
      WHERE kW IS NOT NULL
        AND ISNULL(KyzInvalidAlarm, 0) = 0
      ORDER BY IntervalEnd DESC
  ),
  today_agg AS (
      SELECT SUM(CAST(kWh AS float)) AS today_kwh
      FROM dbo.KYZ_Interval
      WHERE CAST(IntervalEnd AS date) = @today
        AND ISNULL(KyzInvalidAlarm, 0) = 0
  ),
  yday_to_time AS (
      SELECT SUM(CAST(kWh AS float)) AS yday_kwh_to_time
      FROM dbo.KYZ_Interval
      WHERE IntervalEnd >= @yesterday_start
        AND IntervalEnd < @yesterday_end
        AND ISNULL(KyzInvalidAlarm, 0) = 0
  ),
  daily_30 AS (
      SELECT
          CAST(IntervalEnd AS date) AS d,
          SUM(CAST(kWh AS float)) AS daily_kwh
      FROM dbo.KYZ_Interval
      WHERE IntervalEnd >= DATEADD(day, -30, @today)
        AND IntervalEnd < @today
        AND ISNULL(KyzInvalidAlarm, 0) = 0
      GROUP BY CAST(IntervalEnd AS date)
  )
  SELECT
      MAX(CASE WHEN l2.rn = 1 THEN l2.kW END) AS current_kw,
      MAX(CASE WHEN l2.rn = 2 THEN l2.kW END) AS prev_kw,
      (
          SELECT AVG(CAST(l.kW AS float))
          FROM dbo.KYZ_Live15s l
          WHERE l.SampleEnd >= DATEADD(minute, -5, GETDATE())
      ) AS live_kw_avg_5m,
      ta.today_kwh,
      yt.yday_kwh_to_time,
      (SELECT AVG(daily_kwh) FROM daily_30) AS avg_daily_kwh_30d,
      (
          SELECT MAX(CAST(i.kW AS float))
          FROM dbo.KYZ_Interval i
          WHERE i.IntervalEnd >= DATEADD(month, -11, @today)
            AND ISNULL(i.KyzInvalidAlarm, 0) = 0
            AND ISNULL(i.R17Exclude, 0) = 0
      ) AS max_kw_11mo
  FROM latest_two l2
  CROSS JOIN today_agg ta
  CROSS JOIN yday_to_time yt;
END;
GO
