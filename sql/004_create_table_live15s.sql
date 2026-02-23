CREATE TABLE dbo.KYZ_Live15s (
    SampleEnd      DATETIME2(0) NOT NULL,
    PulseCount     BIGINT       NOT NULL,
    kWh            FLOAT        NOT NULL,
    kW             FLOAT        NOT NULL,
    Total_kWh      FLOAT        NULL,
    InsertedAtUtc  DATETIME2(3) NOT NULL CONSTRAINT DF_KYZ_Live15s_InsertedAtUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_KYZ_Live15s PRIMARY KEY CLUSTERED (SampleEnd)
);
GO

CREATE OR ALTER VIEW dbo.v_KYZ_Live15s_Latest
AS
SELECT TOP (1)
    SampleEnd,
    PulseCount,
    kWh,
    kW,
    Total_kWh,
    InsertedAtUtc
FROM dbo.KYZ_Live15s
ORDER BY SampleEnd DESC;
GO

CREATE OR ALTER VIEW dbo.v_KYZ_Live15s_24h
AS
SELECT
    SampleEnd AS t,
    kW,
    kWh
FROM dbo.KYZ_Live15s
WHERE SampleEnd >= DATEADD(hour, -24, GETDATE())
ORDER BY SampleEnd ASC;
GO
