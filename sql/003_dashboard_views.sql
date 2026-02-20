CREATE OR ALTER VIEW dbo.vw_KYZ_LatestInterval
AS
SELECT TOP (1)
    IntervalEnd,
    PulseCount,
    kWh,
    kW,
    Total_kWh,
    R17Exclude,
    KyzInvalidAlarm
FROM dbo.KYZ_Interval
ORDER BY IntervalEnd DESC;
GO

CREATE OR ALTER VIEW dbo.vw_KYZ_DailySummary
AS
SELECT
    CAST(IntervalEnd AS DATE) AS [date],
    SUM(kWh) AS kWh_sum,
    MAX(kW) AS kW_peak,
    MAX(CASE WHEN ISNULL(R17Exclude, 0) = 0 THEN kW END) AS kW_peak_excluding_r17,
    COUNT_BIG(*) AS interval_count
FROM dbo.KYZ_Interval
WHERE ISNULL(KyzInvalidAlarm, 0) = 0
GROUP BY CAST(IntervalEnd AS DATE);
GO

CREATE OR ALTER VIEW dbo.vw_KYZ_MonthlyBillingDemandEstimate
AS
WITH MonthlyRanked AS (
    SELECT
        DATEFROMPARTS(YEAR(IntervalEnd), MONTH(IntervalEnd), 1) AS month_start,
        kW,
        ROW_NUMBER() OVER (
            PARTITION BY DATEFROMPARTS(YEAR(IntervalEnd), MONTH(IntervalEnd), 1)
            ORDER BY kW DESC, IntervalEnd DESC
        ) AS kw_rank
    FROM dbo.KYZ_Interval
    WHERE ISNULL(KyzInvalidAlarm, 0) = 0
      AND ISNULL(R17Exclude, 0) = 0
)
SELECT
    month_start,
    AVG(CASE WHEN kw_rank <= 3 THEN kW END) AS top3_avg_kW,
    MAX(kW) AS peak_kW
FROM MonthlyRanked
GROUP BY month_start;
GO
