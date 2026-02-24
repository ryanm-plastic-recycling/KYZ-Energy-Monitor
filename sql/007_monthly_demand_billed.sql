/* =========================================================
   007_monthly_demand_billed.sql
   - Monthly demand estimate and billed demand snapshot
   - Rate-SL billing rule:
       Billed_kW = max(top3_avg_kW, 0.60 * max(prior 11 billed months), 50)
   ========================================================= */

------------------------------------------------------------
-- 1) Base monthly estimate (top-3 average + monthly peak)
------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_KYZ_MonthlyBillingDemandEstimate
AS
WITH ranked AS (
    SELECT
        month_start = CONVERT(date, DATEFROMPARTS(YEAR(i.IntervalEnd), MONTH(i.IntervalEnd), 1)),
        i.kW,
        rn = ROW_NUMBER() OVER (
                PARTITION BY DATEFROMPARTS(YEAR(i.IntervalEnd), MONTH(i.IntervalEnd), 1)
                ORDER BY i.kW DESC, i.IntervalEnd DESC
             )
    FROM dbo.KYZ_Interval AS i
    WHERE ISNULL(i.KyzInvalidAlarm, 0) = 0
      AND ISNULL(i.R17Exclude, 0) = 0
)
SELECT
    month_start,
    top3_avg_kW = AVG(CASE WHEN rn <= 3 THEN CAST(kW AS float) END),
    peak_kW = MAX(CAST(kW AS float))
FROM ranked
GROUP BY month_start;
GO

------------------------------------------------------------
-- 2) Snapshot table (keep forever)
------------------------------------------------------------
IF OBJECT_ID('dbo.KYZ_MonthlyDemand', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.KYZ_MonthlyDemand
    (
        month_start             date         NOT NULL,
        top3_avg_kW             float        NULL,
        peak_kW                 float        NULL,
        Energy_kWh              float        NULL,
        HighestPrev11_Billed_kW float        NULL,
        RatchetFloor_kW         float        NULL,
        Billed_kW               float        NULL,
        ComputedAtUtc           datetime2(3) NOT NULL
            CONSTRAINT DF_KYZ_MonthlyDemand_ComputedAtUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_KYZ_MonthlyDemand PRIMARY KEY CLUSTERED (month_start)
    );
END;
GO

-- Add any missing columns for already-existing deployments
IF COL_LENGTH('dbo.KYZ_MonthlyDemand', 'top3_avg_kW') IS NULL
    ALTER TABLE dbo.KYZ_MonthlyDemand ADD top3_avg_kW float NULL;
IF COL_LENGTH('dbo.KYZ_MonthlyDemand', 'peak_kW') IS NULL
    ALTER TABLE dbo.KYZ_MonthlyDemand ADD peak_kW float NULL;
IF COL_LENGTH('dbo.KYZ_MonthlyDemand', 'Energy_kWh') IS NULL
    ALTER TABLE dbo.KYZ_MonthlyDemand ADD Energy_kWh float NULL;
IF COL_LENGTH('dbo.KYZ_MonthlyDemand', 'HighestPrev11_Billed_kW') IS NULL
    ALTER TABLE dbo.KYZ_MonthlyDemand ADD HighestPrev11_Billed_kW float NULL;
IF COL_LENGTH('dbo.KYZ_MonthlyDemand', 'RatchetFloor_kW') IS NULL
    ALTER TABLE dbo.KYZ_MonthlyDemand ADD RatchetFloor_kW float NULL;
IF COL_LENGTH('dbo.KYZ_MonthlyDemand', 'Billed_kW') IS NULL
    ALTER TABLE dbo.KYZ_MonthlyDemand ADD Billed_kW float NULL;
IF COL_LENGTH('dbo.KYZ_MonthlyDemand', 'ComputedAtUtc') IS NULL
BEGIN
    ALTER TABLE dbo.KYZ_MonthlyDemand ADD ComputedAtUtc datetime2(3) NOT NULL
        CONSTRAINT DF_KYZ_MonthlyDemand_ComputedAtUtc2 DEFAULT SYSUTCDATETIME();
END;
GO

------------------------------------------------------------
-- 3) Refresh proc (transparent month-by-month ratchet logic)
------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_KYZ_Refresh_MonthlyDemand
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#months') IS NOT NULL DROP TABLE #months;
    IF OBJECT_ID('tempdb..#calc')   IS NOT NULL DROP TABLE #calc;

    -- Gather monthly base inputs
    SELECT
        e.month_start,
        e.top3_avg_kW,
        e.peak_kW,
        en.Energy_kWh
    INTO #months
    FROM dbo.vw_KYZ_MonthlyBillingDemandEstimate AS e
    LEFT JOIN (
        SELECT
            month_start = CONVERT(date, DATEFROMPARTS(YEAR(i.IntervalEnd), MONTH(i.IntervalEnd), 1)),
            Energy_kWh = SUM(CAST(i.kWh AS float))
        FROM dbo.KYZ_Interval AS i
        WHERE ISNULL(i.KyzInvalidAlarm, 0) = 0
        GROUP BY DATEFROMPARTS(YEAR(i.IntervalEnd), MONTH(i.IntervalEnd), 1)
    ) AS en
        ON en.month_start = e.month_start;

    CREATE TABLE #calc
    (
        month_start             date   NOT NULL PRIMARY KEY,
        top3_avg_kW             float  NULL,
        peak_kW                 float  NULL,
        Energy_kWh              float  NULL,
        HighestPrev11_Billed_kW float  NULL,
        RatchetFloor_kW         float  NULL,
        Billed_kW               float  NULL
    );

    DECLARE
        @month_start date,
        @top3 float,
        @peak float,
        @energy float,
        @highest_prev11 float,
        @ratchet_floor float,
        @billed float;

    DECLARE month_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT month_start, top3_avg_kW, peak_kW, Energy_kWh
        FROM #months
        ORDER BY month_start ASC;

    OPEN month_cursor;
    FETCH NEXT FROM month_cursor INTO @month_start, @top3, @peak, @energy;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT
            @highest_prev11 = MAX(c.Billed_kW)
        FROM #calc AS c
        WHERE c.month_start >= DATEADD(MONTH, -11, @month_start)
          AND c.month_start <  @month_start;

        SET @ratchet_floor = ISNULL(0.60 * @highest_prev11, 0.0);

        SELECT @billed = MAX(v)
        FROM (VALUES
            (ISNULL(@top3, 0.0)),
            (ISNULL(@ratchet_floor, 0.0)),
            (50.0)
        ) AS x(v);

        INSERT INTO #calc
        (
            month_start,
            top3_avg_kW,
            peak_kW,
            Energy_kWh,
            HighestPrev11_Billed_kW,
            RatchetFloor_kW,
            Billed_kW
        )
        VALUES
        (
            @month_start,
            @top3,
            @peak,
            @energy,
            @highest_prev11,
            @ratchet_floor,
            @billed
        );

        FETCH NEXT FROM month_cursor INTO @month_start, @top3, @peak, @energy;
    END;

    CLOSE month_cursor;
    DEALLOCATE month_cursor;

    MERGE dbo.KYZ_MonthlyDemand AS tgt
    USING #calc AS src
      ON tgt.month_start = src.month_start
    WHEN MATCHED THEN
      UPDATE SET
        tgt.top3_avg_kW             = src.top3_avg_kW,
        tgt.peak_kW                 = src.peak_kW,
        tgt.Energy_kWh              = src.Energy_kWh,
        tgt.HighestPrev11_Billed_kW = src.HighestPrev11_Billed_kW,
        tgt.RatchetFloor_kW         = src.RatchetFloor_kW,
        tgt.Billed_kW               = src.Billed_kW,
        tgt.ComputedAtUtc           = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN
      INSERT (month_start, top3_avg_kW, peak_kW, Energy_kWh, HighestPrev11_Billed_kW, RatchetFloor_kW, Billed_kW, ComputedAtUtc)
      VALUES (src.month_start, src.top3_avg_kW, src.peak_kW, src.Energy_kWh, src.HighestPrev11_Billed_kW, src.RatchetFloor_kW, src.Billed_kW, SYSUTCDATETIME());
END;
GO

------------------------------------------------------------
-- 4) Output views from snapshot
------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_KYZ_MonthlyBillingDemandBilled
AS
SELECT
    month_start,
    top3_avg_kW,
    peak_kW,
    Energy_kWh,
    HighestPrev11_Billed_kW,
    RatchetFloor_kW,
    Billed_kW,
    ComputedAtUtc
FROM dbo.KYZ_MonthlyDemand;
GO

CREATE OR ALTER VIEW dbo.v_KYZ_MonthlyDemand_Latest
AS
SELECT TOP (1)
    month_start,
    top3_avg_kW,
    peak_kW,
    Energy_kWh,
    HighestPrev11_Billed_kW,
    RatchetFloor_kW,
    Billed_kW,
    ComputedAtUtc
FROM dbo.KYZ_MonthlyDemand
ORDER BY month_start DESC;
GO

------------------------------------------------------------
-- 5) Permissions
------------------------------------------------------------
GRANT SELECT ON dbo.vw_KYZ_MonthlyBillingDemandEstimate TO kyz_dashboard;
GRANT SELECT ON dbo.vw_KYZ_MonthlyBillingDemandBilled   TO kyz_dashboard;
GRANT SELECT ON dbo.v_KYZ_MonthlyDemand_Latest          TO kyz_dashboard;
GRANT SELECT ON dbo.KYZ_MonthlyDemand                   TO kyz_dashboard;

GRANT EXECUTE ON dbo.usp_KYZ_Refresh_MonthlyDemand TO kyz_ingestor;
GO
