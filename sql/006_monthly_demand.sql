/* =========================================================
   006_monthly_demand.sql
   - Raw monthly demand (top3 avg + peak), excludes R17 + invalid
   - Snapshot table + proc to compute billed demand with 11-month ratchet
   - Keeps results forever (no retention here)
   ========================================================= */

------------------------------------------------------------
-- 1) Raw view (top3 avg + peak per month)
------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_KYZ_MonthlyDemandRaw AS
WITH base AS (
    SELECT
        month_start = CONVERT(date, DATEFROMPARTS(YEAR(i.IntervalEnd), MONTH(i.IntervalEnd), 1)),
        i.kW,
        rn = ROW_NUMBER() OVER (
                PARTITION BY DATEFROMPARTS(YEAR(i.IntervalEnd), MONTH(i.IntervalEnd), 1)
                ORDER BY i.kW DESC
             )
    FROM dbo.KYZ_Interval i
    WHERE ISNULL(i.R17Exclude, 0) = 0
      AND ISNULL(i.KyzInvalidAlarm, 0) = 0
),
agg AS (
    SELECT
        month_start,
        top3_avg_kW = AVG(CASE WHEN rn <= 3 THEN CAST(kW AS decimal(18,6)) END),
        peak_kW     = MAX(CAST(kW AS decimal(18,6)))
    FROM base
    GROUP BY month_start
)
SELECT
    month_start,
    top3_avg_kW,
    peak_kW
FROM agg
WHERE top3_avg_kW IS NOT NULL;
GO

------------------------------------------------------------
-- 2) Snapshot table (audit-friendly, correct ratchet)
------------------------------------------------------------
IF OBJECT_ID('dbo.KYZ_MonthlyDemand', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.KYZ_MonthlyDemand
    (
        MonthStart        date          NOT NULL,
        Top3Avg_kW        decimal(18,6)  NOT NULL,
        Peak_kW           decimal(18,6)  NOT NULL,
        RatchetFloor_kW   decimal(18,6)  NOT NULL,
        BilledDemand_kW   decimal(18,6)  NOT NULL,
        UpdatedAtUtc      datetime2(3)   NOT NULL CONSTRAINT DF_KYZ_MonthlyDemand_UpdatedAtUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_KYZ_MonthlyDemand PRIMARY KEY CLUSTERED (MonthStart)
    );
END;
GO

------------------------------------------------------------
-- 3) Stored procedure to refresh snapshot (run nightly/monthly)
------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_KYZ_Refresh_MonthlyDemand
    @StartMonth     date = NULL,
    @EndMonth       date = NULL,
    @RatchetPercent decimal(9,6) = 0.60,
    @MinBillingKW   decimal(18,6) = 50.0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @minInterval datetime2(0) = (SELECT MIN(IntervalEnd) FROM dbo.KYZ_Interval);
    IF @minInterval IS NULL
        RETURN;

    DECLARE @start date = ISNULL(@StartMonth, CONVERT(date, DATEFROMPARTS(YEAR(@minInterval), MONTH(@minInterval), 1)));
    DECLARE @end   date = ISNULL(@EndMonth,   CONVERT(date, DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1)));

    IF @end < @start
        RETURN;

    --------------------------------------------------------
    -- Build month series (calendar months, no gaps)
    --------------------------------------------------------
    IF OBJECT_ID('tempdb..#months') IS NOT NULL DROP TABLE #months;

    ;WITH months AS (
        SELECT @start AS month_start
        UNION ALL
        SELECT DATEADD(month, 1, month_start)
        FROM months
        WHERE month_start < @end
    )
    SELECT month_start
    INTO #months
    FROM months
    OPTION (MAXRECURSION 0);

    --------------------------------------------------------
    -- Raw per-month (left join so missing months become 0)
    --------------------------------------------------------
    IF OBJECT_ID('tempdb..#raw') IS NOT NULL DROP TABLE #raw;

    SELECT
        m.month_start,
        Top3Avg_kW = ISNULL(r.top3_avg_kW, CAST(0 AS decimal(18,6))),
        Peak_kW    = ISNULL(r.peak_kW,    CAST(0 AS decimal(18,6)))
    INTO #raw
    FROM #months m
    LEFT JOIN dbo.vw_KYZ_MonthlyDemandRaw r
        ON r.month_start = m.month_start;

    --------------------------------------------------------
    -- Iterate months to apply ratchet correctly
    --------------------------------------------------------
    IF OBJECT_ID('tempdb..#out') IS NOT NULL DROP TABLE #out;

    CREATE TABLE #out
    (
        MonthStart      date         NOT NULL PRIMARY KEY,
        Top3Avg_kW      decimal(18,6) NOT NULL,
        Peak_kW         decimal(18,6) NOT NULL,
        RatchetFloor_kW decimal(18,6) NOT NULL,
        BilledDemand_kW decimal(18,6) NOT NULL
    );

    DECLARE @m date, @top3 decimal(18,6), @peak decimal(18,6);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT month_start, Top3Avg_kW, Peak_kW
        FROM #raw
        ORDER BY month_start;

    OPEN cur;
    FETCH NEXT FROM cur INTO @m, @top3, @peak;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @maxPrior decimal(18,6) =
        (
            SELECT MAX(BilledDemand_kW)
            FROM #out
            WHERE MonthStart >= DATEADD(month, -11, @m)
              AND MonthStart <  @m
        );

        IF @maxPrior IS NULL SET @maxPrior = 0;

        DECLARE @floor decimal(18,6) = @maxPrior * @RatchetPercent;
        IF @floor < @MinBillingKW SET @floor = @MinBillingKW;

        DECLARE @billed decimal(18,6) = @top3;
        IF @billed < @floor SET @billed = @floor;
        IF @billed < @MinBillingKW SET @billed = @MinBillingKW;

        INSERT INTO #out (MonthStart, Top3Avg_kW, Peak_kW, RatchetFloor_kW, BilledDemand_kW)
        VALUES (@m, @top3, @peak, @floor, @billed);

        FETCH NEXT FROM cur INTO @m, @top3, @peak;
    END

    CLOSE cur;
    DEALLOCATE cur;

    --------------------------------------------------------
    -- Upsert snapshot table
    --------------------------------------------------------
    MERGE dbo.KYZ_MonthlyDemand AS tgt
    USING #out AS src
      ON tgt.MonthStart = src.MonthStart
    WHEN MATCHED THEN
      UPDATE SET
        tgt.Top3Avg_kW      = src.Top3Avg_kW,
        tgt.Peak_kW         = src.Peak_kW,
        tgt.RatchetFloor_kW = src.RatchetFloor_kW,
        tgt.BilledDemand_kW = src.BilledDemand_kW,
        tgt.UpdatedAtUtc    = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN
      INSERT (MonthStart, Top3Avg_kW, Peak_kW, RatchetFloor_kW, BilledDemand_kW)
      VALUES (src.MonthStart, src.Top3Avg_kW, src.Peak_kW, src.RatchetFloor_kW, src.BilledDemand_kW);

END;
GO

------------------------------------------------------------
-- 4) Convenience view over snapshot
------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_KYZ_MonthlyDemandBilled AS
SELECT
    MonthStart AS month_start,
    Top3Avg_kW AS top3_avg_kW,
    Peak_kW    AS peak_kW,
    RatchetFloor_kW AS ratchet_floor_kW,
    BilledDemand_kW AS billed_demand_kW,
    UpdatedAtUtc
FROM dbo.KYZ_MonthlyDemand;
GO

------------------------------------------------------------
-- 5) Permissions
------------------------------------------------------------
GRANT SELECT ON dbo.vw_KYZ_MonthlyDemandRaw    TO kyz_dashboard;
GRANT SELECT ON dbo.vw_KYZ_MonthlyDemandBilled TO kyz_dashboard;
GRANT SELECT ON dbo.KYZ_MonthlyDemand          TO kyz_dashboard;

GRANT EXECUTE ON dbo.usp_KYZ_Refresh_MonthlyDemand TO kyz_ingestor;
GRANT INSERT, UPDATE ON dbo.KYZ_MonthlyDemand      TO kyz_ingestor;
GO
