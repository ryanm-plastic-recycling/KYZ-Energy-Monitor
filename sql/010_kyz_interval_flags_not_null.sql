/*
Migration: Enforce BIT NOT NULL + DEFAULT(0) for dbo.KYZ_Interval flags.

CRITICAL: Apply only after ingestor writes 0/1 (or omits columns so DEFAULT applies).
If ingestion still inserts explicit NULL, inserts will fail after this migration.

Preflight:
- Run the dependency discovery query below.
- If any index depends on R17Exclude/KyzInvalidAlarm besides IX_KYZ_Interval_Exclude_Alarm,
  script its CREATE statement before drop and add it to the recreate section.
*/

-- Preflight dependency discovery query
SELECT
  i.name AS IndexName,
  i.type_desc,
  c.name AS ColumnName,
  ic.key_ordinal,
  ic.is_included_column
FROM sys.indexes i
JOIN sys.index_columns ic
  ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns c
  ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID('dbo.KYZ_Interval')
  AND c.name IN ('R17Exclude','KyzInvalidAlarm')
ORDER BY i.name, ic.is_included_column, ic.key_ordinal;

SET XACT_ABORT ON;
BEGIN TRAN;

-- Backfill
UPDATE dbo.KYZ_Interval SET R17Exclude = 0 WHERE R17Exclude IS NULL;
UPDATE dbo.KYZ_Interval SET KyzInvalidAlarm = 0 WHERE KyzInvalidAlarm IS NULL;

-- Defaults (idempotent)
IF NOT EXISTS (
  SELECT 1 FROM sys.default_constraints
  WHERE parent_object_id = OBJECT_ID('dbo.KYZ_Interval')
    AND name = 'DF_KYZ_Interval_R17Exclude'
)
BEGIN
  ALTER TABLE dbo.KYZ_Interval
  ADD CONSTRAINT DF_KYZ_Interval_R17Exclude DEFAULT (0) FOR R17Exclude;
END

IF NOT EXISTS (
  SELECT 1 FROM sys.default_constraints
  WHERE parent_object_id = OBJECT_ID('dbo.KYZ_Interval')
    AND name = 'DF_KYZ_Interval_KyzInvalidAlarm'
)
BEGIN
  ALTER TABLE dbo.KYZ_Interval
  ADD CONSTRAINT DF_KYZ_Interval_KyzInvalidAlarm DEFAULT (0) FOR KyzInvalidAlarm;
END

-- Drop dependent index
IF EXISTS (
  SELECT 1 FROM sys.indexes
  WHERE object_id = OBJECT_ID('dbo.KYZ_Interval')
    AND name = 'IX_KYZ_Interval_Exclude_Alarm'
)
BEGIN
  DROP INDEX IX_KYZ_Interval_Exclude_Alarm ON dbo.KYZ_Interval;
END

-- Alter columns
ALTER TABLE dbo.KYZ_Interval ALTER COLUMN R17Exclude BIT NOT NULL;
ALTER TABLE dbo.KYZ_Interval ALTER COLUMN KyzInvalidAlarm BIT NOT NULL;

-- Recreate index (exact)
CREATE NONCLUSTERED INDEX [IX_KYZ_Interval_Exclude_Alarm] ON [dbo].[KYZ_Interval]
(
    [R17Exclude] ASC,
    [KyzInvalidAlarm] ASC
)
INCLUDE([IntervalEnd],[kWh],[kW],[PulseCount])
WITH (
    STATISTICS_NORECOMPUTE = OFF,
    DROP_EXISTING = OFF,
    ONLINE = OFF,
    OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF
) ON [PRIMARY];

COMMIT;

-- Post-check validation
SELECT
  SUM(CASE WHEN R17Exclude IS NULL THEN 1 ELSE 0 END) AS R17ExcludeNullCount,
  SUM(CASE WHEN KyzInvalidAlarm IS NULL THEN 1 ELSE 0 END) AS KyzInvalidAlarmNullCount
FROM dbo.KYZ_Interval;

SELECT
  c.name,
  c.is_nullable
FROM sys.columns c
WHERE c.object_id = OBJECT_ID('dbo.KYZ_Interval')
  AND c.name IN ('R17Exclude', 'KyzInvalidAlarm');

SELECT
  dc.name AS DefaultConstraintName,
  col.name AS ColumnName
FROM sys.default_constraints dc
JOIN sys.columns col
  ON col.object_id = dc.parent_object_id
 AND col.column_id = dc.parent_column_id
WHERE dc.parent_object_id = OBJECT_ID('dbo.KYZ_Interval')
  AND dc.name IN ('DF_KYZ_Interval_R17Exclude', 'DF_KYZ_Interval_KyzInvalidAlarm')
ORDER BY dc.name;

SELECT
  i.name AS IndexName,
  i.type_desc
FROM sys.indexes i
WHERE i.object_id = OBJECT_ID('dbo.KYZ_Interval')
  AND i.name = 'IX_KYZ_Interval_Exclude_Alarm';
