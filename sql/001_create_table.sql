CREATE TABLE dbo.KYZ_Interval (
    IntervalEnd      DATETIME2(0) NOT NULL,
    PulseCount       INT           NOT NULL,
    kWh              DECIMAL(18,6) NOT NULL,
    kW               DECIMAL(18,6) NOT NULL,
    Total_kWh        DECIMAL(18,6) NULL,
    R17Exclude       BIT           NULL,
    KyzInvalidAlarm  BIT           NULL,
    CONSTRAINT PK_KYZ_Interval PRIMARY KEY CLUSTERED (IntervalEnd)
);
