/* =========================================================
   007_monthly_demand_billed.sql   (CANONICAL)
   ---------------------------------------------------------
   Creates/updates:
     - dbo.vw_KYZ_MonthlyBillingDemandEstimate  (raw: top3 avg + peak per month)
     - dbo.KYZ_MonthlyDemand                   (snapshot table; keep forever)
     - dbo.usp_KYZ_Refresh_MonthlyDemand       (sequential ratchet calc; upserts)
     - dbo.vw_KYZ_MonthlyBillingDemandBilled   (selects from snapshot)
     - dbo.v_KYZ_MonthlyDemand_Latest          (latest snapshot row)

   Notes:
     - Excludes invalid intervals and R17Exclude=1 for demand calcs.
     - Billed_kW computed per Rate SL:
         billed = max(top3_avg_kW, 0.60 * max(billed over prior 11 months), 50)
   ========================================================= */

SET NOCOUNT ON;
GO

--------------------------------------------------------------------------------
-- 0) If something weird exists with the table name, clear it
--------------------------------------------------------------------------------
IF OBJECT_ID('dbo.KYZ_MonthlyDemand', 'V') IS NOT NULL
BEGIN
    DROP VIEW dbo.KYZ_MonthlyDemand;
END
GO

--------------------------------------------------------------------------------
-- 1) If dbo.KYZ_MonthlyDemand exists but is schema-mismatched, rename it away.
--------------------------------------------------------------------------------
DECLARE @need_rebuild bit = 0;

IF OBJECT_ID('dbo.KYZ_MonthlyDemand', 'U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.KYZ_MonthlyDemand', 'month_start') IS NULL SET @need_rebuild = 1;
    IF COL_LENGTH('dbo.KYZ_MonthlyDemand', 'Billed_kW')   IS NULL SET @need_rebuild = 1;
    IF COL_LENGTH('dbo.KYZ_MonthlyDemand', 'ComputedAtUtc') IS NULL SET @need_rebuild = 1;
END

IF @need_rebuild = 1
BEGIN
    DECLARE @legacy_table sysname =
        CONCAT('KYZ_MonthlyDemand__legacy_',
               CONVERT(char(8), GETDATE(), 112), '_',
               REPLACE(CONVERT(char(8), GETDATE(), 108), ':', ''));

    PRINT CONCAT('Renaming schema-mismatched dbo.KYZ_MonthlyDemand -> dbo.', @legacy_table);
    EXEC sp_rename @objname='dbo.KYZ_MonthlyDemand', @newname=@legacy_table;
END
GO

--------------------------------------------------------------------------------
-- 2) Create snapshot table if missing (constraints intentionally unnamed
--    to avoid collisions with legacy constraint names).
--------------------------------------------------------------------------------
IF OBJECT_ID('dbo.KYZ_MonthlyDemand', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.KYZ_MonthlyDemand
    (
        month_start              date         NOT NULL PRIMARY KEY CLUSTERED,
        top3_avg_kW              float        NULL,
        peak_kW                  float        NULL,
        Energy_kWh               float        NULL,
        HighestPrev11_Billed_kW  float        NULL,
        RatchetFloor_kW          float        NULL,
        Billed_kW                float        NULL,
        ComputedAtUtc            datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
    );
END
GO

--------------------------------------------------------------------------------
-- 3) Patch missing columns (future-proof if you ever add/remove columns).
--------------------------------------------------------------------------------
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
    ALTER TABLE dbo.KYZ_MonthlyDemand ADD ComputedAtUtc datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME();
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_KYZ_MonthlyDemand_ComputedAtUtc'
      AND object_id = OBJECT_ID('dbo.KYZ_MonthlyDemand')
)
BEGIN
    CREATE INDEX IX_KYZ_MonthlyDemand_ComputedAtUtc
        ON dbo.KYZ_MonthlyDemand(ComputedAtUtc);
END
GO

--------------------------------------------------------------------------------
-- 4) Raw monthly view: top3 avg + peak per calendar month
--------------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_KYZ_MonthlyBillingDemandEstimate
AS
WITH cleaned AS (
    SELECT
        DATEFROMPARTS(YEAR(IntervalEnd), MONTH(IntervalEnd), 1) AS month_start,
        CAST(kW AS float) AS kW
    FROM dbo.KYZ_Interval
    WHERE kW IS NOT NULL
      AND ISNULL(KyzInvalidAlarm, 0) = 0
      AND ISNULL(R17Exclude, 0) = 0
),
ranked AS (
    SELECT
        month_start,
        kW,
        ROW_NUMBER() OVER (PARTITION BY month_start ORDER BY kW DESC) AS rn
    FROM cleaned
)
SELECT
    month_start,
    AVG(CASE WHEN rn <= 3 THEN kW END) AS top3_avg_kW,
    MAX(kW) AS peak_kW
FROM ranked
GROUP BY month_start;
GO

--------------------------------------------------------------------------------
-- 5) Refresh proc: sequentially computes billed demand (ratchet is recursive)
--------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_KYZ_Refresh_MonthlyDemand
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @months TABLE
    (
        month_start date PRIMARY KEY,
        top3_avg_kW float NULL,
        peak_kW     float NULL,
        Energy_kWh  float NULL
    );

    ;WITH energy AS (
        SELECT
            DATEFROMPARTS(YEAR(IntervalEnd), MONTH(IntervalEnd), 1) AS month_start,
            SUM(CAST(kWh AS float)) AS Energy_kWh
        FROM dbo.KYZ_Interval
        WHERE ISNULL(KyzInvalidAlarm, 0) = 0
          AND ISNULL(R17Exclude, 0) = 0
        GROUP BY DATEFROMPARTS(YEAR(IntervalEnd), MONTH(IntervalEnd), 1)
    )
    INSERT INTO @months (month_start, top3_avg_kW, peak_kW, Energy_kWh)
    SELECT
        d.month_start,
        d.top3_avg_kW,
        d.peak_kW,
        e.Energy_kWh
    FROM dbo.vw_KYZ_MonthlyBillingDemandEstimate d
    LEFT JOIN energy e
        ON e.month_start = d.month_start;

    IF NOT EXISTS (SELECT 1 FROM @months)
        RETURN;

    DECLARE
        @m date,
        @raw float,
        @peak float,
        @kwh float,
        @prev11_max float,
        @ratchet float,
        @billed float;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT month_start FROM @months ORDER BY month_start;

    OPEN cur;
    FETCH NEXT FROM cur INTO @m;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT
            @raw = top3_avg_kW,
            @peak = peak_kW,
            @kwh = Energy_kWh
        FROM @months
        WHERE month_start = @m;

        SELECT @prev11_max = MAX(Billed_kW)
        FROM dbo.KYZ_MonthlyDemand
        WHERE month_start < @m
          AND month_start >= DATEADD(month, -11, @m);

        SET @ratchet = 0.60 * ISNULL(@prev11_max, 0.0);

        SELECT @billed = MAX(v)
        FROM (VALUES (ISNULL(@raw, 0.0)), (ISNULL(@ratchet, 0.0)), (50.0)) AS X(v);

        MERGE dbo.KYZ_MonthlyDemand AS tgt
        USING (SELECT @m AS month_start) AS src
            ON tgt.month_start = src.month_start
        WHEN MATCHED THEN
            UPDATE SET
                top3_avg_kW             = @raw,
                peak_kW                 = @peak,
                Energy_kWh              = @kwh,
                HighestPrev11_Billed_kW = @prev11_max,
                RatchetFloor_kW         = @ratchet,
                Billed_kW               = @billed,
                ComputedAtUtc           = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN
            INSERT
            (
                month_start,
                top3_avg_kW,
                peak_kW,
                Energy_kWh,
                HighestPrev11_Billed_kW,
                RatchetFloor_kW,
                Billed_kW,
                ComputedAtUtc
            )
            VALUES
            (
                @m,
                @raw,
                @peak,
                @kwh,
                @prev11_max,
                @ratchet,
                @billed,
                SYSUTCDATETIME()
            );

        FETCH NEXT FROM cur INTO @m;
    END

    CLOSE cur;
    DEALLOCATE cur;
END;
GO

--------------------------------------------------------------------------------
-- 6) Billed view: reads from snapshot (audit-friendly)
--------------------------------------------------------------------------------
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

--------------------------------------------------------------------------------
-- 7) Latest snapshot row
--------------------------------------------------------------------------------
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

--------------------------------------------------------------------------------
-- 8) Grants (only if principals exist)
--------------------------------------------------------------------------------
IF DATABASE_PRINCIPAL_ID('kyz_dashboard') IS NOT NULL
BEGIN
    GRANT SELECT ON dbo.vw_KYZ_MonthlyBillingDemandEstimate TO kyz_dashboard;
    GRANT SELECT ON dbo.vw_KYZ_MonthlyBillingDemandBilled   TO kyz_dashboard;
    GRANT SELECT ON dbo.KYZ_MonthlyDemand                   TO kyz_dashboard;
    GRANT SELECT ON dbo.v_KYZ_MonthlyDemand_Latest          TO kyz_dashboard;
END

IF DATABASE_PRINCIPAL_ID('kyz_ingestor') IS NOT NULL
BEGIN
    GRANT EXECUTE ON dbo.usp_KYZ_Refresh_MonthlyDemand TO kyz_ingestor;
END
GO
