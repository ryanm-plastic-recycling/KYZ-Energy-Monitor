/* =========================================================
   007_monthly_demand_billed.sql
   - Adds billed demand (top3 avg + 60% ratchet prev 11 + min 50kW)
   - Optional snapshot table + refresh proc
   ========================================================= */

-- 1) Billed demand view (builds on your existing vw_KYZ_MonthlyBillingDemandEstimate)
CREATE OR ALTER VIEW dbo.vw_KYZ_MonthlyBillingDemandBilled
AS
WITH base AS (
    SELECT
        month_start,
        CAST(top3_avg_kW AS float) AS top3_avg_kW,
        CAST(peak_kW     AS float) AS peak_kW
    FROM dbo.vw_KYZ_MonthlyBillingDemandEstimate
),
w AS (
    SELECT
        b.*,
        MAX(b.top3_avg_kW) OVER (
            ORDER BY b.month_start
            ROWS BETWEEN 11 PRECEDING AND 1 PRECEDING
        ) AS HighestPrev11_Billed_kW
    FROM base b
),
final AS (
    SELECT
        month_start,
        top3_avg_kW,
        peak_kW,
        HighestPrev11_Billed_kW,
        CAST(ISNULL(0.60 * HighestPrev11_Billed_kW, 0.0) AS float) AS RatchetFloor_kW,
        ca.Billed_kW
    FROM w
    CROSS APPLY (
        SELECT MAX(v) AS Billed_kW
        FROM (VALUES
            (CAST(ISNULL(w.top3_avg_kW, 0.0) AS float)),
            (CAST(ISNULL(0.60 * w.HighestPrev11_Billed_kW, 0.0) AS float)),
            (CAST(50.0 AS float))
        ) AS x(v)
    ) ca
)
SELECT
    month_start,
    top3_avg_kW,
    peak_kW,
    HighestPrev11_Billed_kW,
    RatchetFloor_kW,
    Billed_kW
FROM final;
GO


-- 2) Snapshot table (audit-friendly; tiny; keep forever)
IF OBJECT_ID('dbo.KYZ_MonthlyDemand', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.KYZ_MonthlyDemand
    (
        month_start              date         NOT NULL,
        top3_avg_kW              float        NULL,
        peak_kW                  float        NULL,
        Energy_kWh               float        NULL,
        HighestPrev11_Billed_kW  float        NULL,
        RatchetFloor_kW          float        NULL,
        Billed_kW                float        NULL,
        ComputedAtUtc            datetime2(3) NOT NULL
            CONSTRAINT DF_KYZ_MonthlyDemand_ComputedAtUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_KYZ_MonthlyDemand PRIMARY KEY CLUSTERED (month_start)
    );
END;
GO

-- Add missing columns if table existed from a partial run
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


-- 3) Refresh proc (run nightly or on demand)
CREATE OR ALTER PROCEDURE dbo.usp_KYZ_Refresh_MonthlyDemand
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH energy AS (
        SELECT
            DATEFROMPARTS(YEAR(IntervalEnd), MONTH(IntervalEnd), 1) AS month_start,
            SUM(CAST(kWh AS float)) AS Energy_kWh
        FROM dbo.KYZ_Interval
        WHERE ISNULL(KyzInvalidAlarm, 0) = 0
        GROUP BY DATEFROMPARTS(YEAR(IntervalEnd), MONTH(IntervalEnd), 1)
    ),
    billed AS (
        SELECT
            b.month_start,
            b.top3_avg_kW,
            b.peak_kW,
            e.Energy_kWh,
            b.HighestPrev11_Billed_kW,
            b.RatchetFloor_kW,
            b.Billed_kW
        FROM dbo.vw_KYZ_MonthlyBillingDemandBilled b
        LEFT JOIN energy e
            ON e.month_start = b.month_start
    )
    MERGE dbo.KYZ_MonthlyDemand AS tgt
    USING billed AS src
        ON tgt.month_start = src.month_start
    WHEN MATCHED THEN
        UPDATE SET
            top3_avg_kW             = src.top3_avg_kW,
            peak_kW                 = src.peak_kW,
            Energy_kWh              = src.Energy_kWh,
            HighestPrev11_Billed_kW = src.HighestPrev11_Billed_kW,
            RatchetFloor_kW         = src.RatchetFloor_kW,
            Billed_kW               = src.Billed_kW,
            ComputedAtUtc           = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
        INSERT (month_start, top3_avg_kW, peak_kW, Energy_kWh, HighestPrev11_Billed_kW, RatchetFloor_kW, Billed_kW, ComputedAtUtc)
        VALUES (src.month_start, src.top3_avg_kW, src.peak_kW, src.Energy_kWh, src.HighestPrev11_Billed_kW, src.RatchetFloor_kW, src.Billed_kW, SYSUTCDATETIME());
END;
GO


-- 4) Latest view (this is the one your failed script tried to create)
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