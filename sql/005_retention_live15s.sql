IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.KYZ_Live15s')
      AND name = N'IX_KYZ_Live15s_InsertedAtUtc'
)
BEGIN
    CREATE INDEX IX_KYZ_Live15s_InsertedAtUtc
        ON dbo.KYZ_Live15s (InsertedAtUtc);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_KYZ_Purge_Live15s
    @RetentionDays INT = 7,
    @BatchSize INT = 50000
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    IF @RetentionDays < 0
        SET @RetentionDays = 0;

    IF @BatchSize <= 0
        SET @BatchSize = 50000;

    DECLARE @CutoffUtc DATETIME2(7) = DATEADD(day, -@RetentionDays, SYSUTCDATETIME());
    DECLARE @RowsDeleted INT = 1;
    DECLARE @TotalRowsDeleted BIGINT = 0;

    WHILE @RowsDeleted > 0
    BEGIN
        DELETE TOP (@BatchSize)
        FROM dbo.KYZ_Live15s
        WHERE InsertedAtUtc < @CutoffUtc;

        SET @RowsDeleted = @@ROWCOUNT;
        SET @TotalRowsDeleted += @RowsDeleted;
    END;

    SELECT @TotalRowsDeleted AS RowsDeleted, @CutoffUtc AS CutoffUtc;
END;
GO

GRANT EXECUTE ON dbo.usp_KYZ_Purge_Live15s TO kyz_ingestor;
GO
