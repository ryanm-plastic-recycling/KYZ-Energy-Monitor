-- Optional supporting indexes for downstream reporting/query patterns.
-- Do not run unless they align with your workload and change control policy.

CREATE INDEX IX_KYZ_Interval_Total_kWh
    ON dbo.KYZ_Interval (Total_kWh)
    WHERE Total_kWh IS NOT NULL;

CREATE INDEX IX_KYZ_Interval_Exclude_Alarm
    ON dbo.KYZ_Interval (R17Exclude, KyzInvalidAlarm)
    INCLUDE (IntervalEnd, kWh, kW, PulseCount);
