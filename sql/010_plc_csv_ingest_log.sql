IF OBJECT_ID('dbo.KYZ_PlcCsvIngestLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.KYZ_PlcCsvIngestLog (
        FilePath NVARCHAR(1024) NOT NULL,
        FileSizeBytes BIGINT NOT NULL,
        LastWriteTimeUtc DATETIME2(3) NOT NULL,
        Sha256 CHAR(64) NULL,
        ProcessedAtUtc DATETIME2(3) NOT NULL,
        Status NVARCHAR(16) NOT NULL,
        RowCount INT NOT NULL,
        IntervalMin DATETIME2(0) NULL,
        IntervalMax DATETIME2(0) NULL,
        ErrorMessage NVARCHAR(4000) NULL,
        CONSTRAINT PK_KYZ_PlcCsvIngestLog PRIMARY KEY CLUSTERED (FilePath)
    );
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.KYZ_PlcCsvIngestLog')
      AND name = 'IX_KYZ_PlcCsvIngestLog_ProcessedAtUtc'
)
BEGIN
    CREATE INDEX IX_KYZ_PlcCsvIngestLog_ProcessedAtUtc
        ON dbo.KYZ_PlcCsvIngestLog (ProcessedAtUtc DESC);
END
GO

CREATE OR ALTER VIEW dbo.vw_KYZ_PlcCsvIngestLatest
AS
SELECT TOP (1)
    FilePath,
    FileSizeBytes,
    LastWriteTimeUtc,
    Sha256,
    ProcessedAtUtc,
    Status,
    RowCount,
    IntervalMin,
    IntervalMax,
    ErrorMessage
FROM dbo.KYZ_PlcCsvIngestLog
ORDER BY ProcessedAtUtc DESC;
GO
