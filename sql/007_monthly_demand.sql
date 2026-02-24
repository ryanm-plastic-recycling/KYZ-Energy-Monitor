/* =========================================================
   007_monthly_demand.sql
   - Raw monthly demand view (top3 avg / peak / energy)
   - Snapshot table + proc for billed demand (ratchet + min 50)
   ========================================================= */

-- ---------- Option A: raw monthly stats ----------
CREATE OR ALTER VIEW dbo.v_KYZ_MonthlyDemandRaw AS
WITH base AS (
    SELECT
        CAST(DATEFROMPARTS(YEAR(IntervalEnd), MONTH(IntervalEnd), 1) AS date) AS MonthStart,
        kW,
        kWh
    FROM dbo.KYZ_Interval
    WHERE kW IS NOT NULL
      AND ISNULL(R17Exclude, 0) = 0
      AND ISNULL(KyzInvalidAlarm, 0) = 0
),
ranked AS (
    SELECT
        MonthStart,
        kW,
        kWh,
        ROW_NUMBER() OVER (PARTITION BY MonthStart ORDER BY kW DESC) AS rn
    FROM base
)
SELECT
    MonthStart,
    AVG(CASE WHEN rn <= 3 THEN kW END) AS Top3Avg_kW,
    MAX(kW) AS Peak_kW,
    SUM(kWh) AS Energy_kWh
FROM ranked
GROUP BY MonthStart;
GO


-- ---------- Option B: snapshot billed demand (ratchet-aware) ----------
IF OBJECT_ID('dbo.KYZ_MonthlyDemand', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.KYZ_MonthlyDemand
    (
        MonthStart               date         NOT NULL,
        Top3Avg_kW               float        NOT NULL,
        Peak_kW                  float        NOT NULL,
        Energy_kWh               float        NOT NULL,

        HighestPrev11_Billed_kW  float        NOT NULL,
        RatchetFloor_kW          float        NOT NULL,
        Billed_kW                float        NOT NULL,

        ComputedAtUtc            datetime2(3) NOT NULL
            CONSTRAINT DF_KYZ_MonthlyDemand_ComputedAtUtc DEFAULT SYSUTCDATETIME(),

        CONSTRAINT PK_KYZ_MonthlyDemand PRIMARY KEY CLUSTERED (MonthStart)
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_KYZ_Refresh_MonthlyDemand
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @MinMonth date =
        (SELECT MIN(CAST(DATEFROMPARTS(YEAR(IntervalEnd), MONTH(IntervalEnd), 1) AS date))
         FROM dbo.KYZ_Interval);

    IF @MinMonth IS NULL
        RETURN;

    DECLARE @MaxMonth date =
        CAST(DATEFROMPARTS(YEAR(SYSUTCDATETIME()), MONTH(SYSUTCDATETIME()), 1) AS date);

    ;WITH MonthList AS (
        SELECT @MinMonth AS MonthStart
        UNION ALL
        SELECT DATEADD(month, 1, MonthStart)
        FROM MonthList
        WHERE MonthStart < @MaxMonth
    )
    SELECT MonthStart
    INTO #months
    FROM MonthList
    OPTION (MAXRECURSION 32767);

    -- Raw per month (0-filled if no data)
    SELECT
        m.MonthStart,
        COALESCE(r.Top3Avg_kW, 0.0) AS Top3Avg_kW,
        COALESCE(r.Peak_kW, 0.0)    AS Peak_kW,
        COALESCE(r.Energy_kWh, 0.0) AS Energy_kWh
    INTO #raw
    FROM #months m
    LEFT JOIN dbo.v_KYZ_MonthlyDemandRaw r
        ON r.MonthStart = m.MonthStart;

    CREATE TABLE #out
    (
        MonthStart              date  NOT NULL PRIMARY KEY,
        Top3Avg_kW              float NOT NULL,
        Peak_kW                 float NOT NULL,
        Energy_kWh              float NOT NULL,
        HighestPrev11_Billed_kW float NOT NULL,
        RatchetFloor_kW         float NOT NULL,
        Billed_kW               float NOT NULL
    );

    DECLARE @m date;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT MonthStart FROM #months ORDER BY MonthStart;

    OPEN c;
    FETCH NEXT FROM c INTO @m;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @top3 float = (SELECT Top3Avg_kW FROM #raw WHERE MonthStart = @m);
        DECLARE @peak float = (SELECT Peak_kW    FROM #raw WHERE MonthStart = @m);
        DECLARE @kwh  float = (SELECT Energy_kWh FROM #raw WHERE MonthStart = @m);

        DECLARE @highestPrev11 float =
            COALESCE((
                SELECT MAX(Billed_kW)
                FROM #out
                WHERE MonthStart >= DATEADD(month, -11, @m)
                  AND MonthStart <  @m
            ), 0.0);

        DECLARE @ratchetFloor float = 0.60 * @highestPrev11;

        -- billed = max(top3, ratchetFloor, 50)
        DECLARE @billed float =
            (SELECT MAX(v) FROM (VALUES (@top3), (@ratchetFloor), (50.0)) AS x(v));

        INSERT INTO #out(MonthStart, Top3Avg_kW, Peak_kW, Energy_kWh, HighestPrev11_Billed_kW, RatchetFloor_kW, Billed_kW)
        VALUES (@m, @top3, @peak, @kwh, @highestPrev11, @ratchetFloor, @billed);

        FETCH NEXT FROM c INTO @m;
    END

    CLOSE c;
    DEALLOCATE c;

    MERGE dbo.KYZ_MonthlyDemand AS tgt
    USING #out AS src
      ON tgt.MonthStart = src.MonthStart
    WHEN MATCHED THEN
      UPDATE SET
        Top3Avg_kW              = src.Top3Avg_kW,
        Peak_kW                 = src.Peak_kW,
        Energy_kWh              = src.Energy_kWh,
        HighestPrev11_Billed_kW = src.HighestPrev11_Billed_kW,
        RatchetFloor_kW         = src.RatchetFloor_kW,
        Billed_kW               = src.Billed_kW,
        ComputedAtUtc           = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
      INSERT (MonthStart, Top3Avg_kW, Peak_kW, Energy_kWh, HighestPrev11_Billed_kW, RatchetFloor_kW, Billed_kW)
      VALUES (src.MonthStart, src.Top3Avg_kW, src.Peak_kW, src.Energy_kWh, src.HighestPrev11_Billed_kW, src.RatchetFloor_kW, src.Billed_kW);

END;
GO

CREATE OR ALTER VIEW dbo.v_KYZ_MonthlyDemand_Latest AS
SELECT TOP (1)
    MonthStart,
    Top3Avg_kW,
    Peak_kW,
    Energy_kWh,
    HighestPrev11_Billed_kW,
    RatchetFloor_kW,
    Billed_kW,
    ComputedAtUtc
FROM dbo.KYZ_MonthlyDemand
ORDER BY MonthStart DESC;
GO

-- Grants (adjust users if yours differ)
GRANT SELECT ON dbo.v_KYZ_MonthlyDemandRaw     TO kyz_dashboard;
GRANT SELECT ON dbo.KYZ_MonthlyDemand          TO kyz_dashboard;
GRANT SELECT ON dbo.v_KYZ_MonthlyDemand_Latest TO kyz_dashboard;

GRANT EXEC  ON dbo.usp_KYZ_Refresh_MonthlyDemand TO kyz_ingestor;
GO
