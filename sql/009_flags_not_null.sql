UPDATE dbo.KYZ_Interval
SET R17Exclude = 0
WHERE R17Exclude IS NULL;

UPDATE dbo.KYZ_Interval
SET KyzInvalidAlarm = 0
WHERE KyzInvalidAlarm IS NULL;

ALTER TABLE dbo.KYZ_Interval
ADD CONSTRAINT DF_KYZ_Interval_R17Exclude DEFAULT (0) FOR R17Exclude;

ALTER TABLE dbo.KYZ_Interval
ADD CONSTRAINT DF_KYZ_Interval_KyzInvalidAlarm DEFAULT (0) FOR KyzInvalidAlarm;

ALTER TABLE dbo.KYZ_Interval
ALTER COLUMN R17Exclude BIT NOT NULL;

ALTER TABLE dbo.KYZ_Interval
ALTER COLUMN KyzInvalidAlarm BIT NOT NULL;
