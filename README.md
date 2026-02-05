# KYZ Energy Monitor MQTT -> Azure SQL Ingestor

Python 3.11 service that subscribes to MQTT topic `pri/energy/kyz/interval` and inserts interval rows into `dbo.KYZ_Interval` in Azure SQL.

## Behavior

- Subscribes to `pri/energy/kyz/interval` using `paho-mqtt`.
- Validates and parses payload JSON.
- Inserts into `dbo.KYZ_Interval` using `pyodbc` and **ODBC Driver 18 for SQL Server**.
- Idempotent insert logic: if `IntervalEnd` already exists, the message is ignored.
- Does **not** create or alter schema at runtime.
- Logs to `./logs/kyz_ingestor.log` with daily rotation and 30-day retention.
- Includes `python main.py --test-conn` to verify SQL and MQTT connectivity.

## Expected Payload

```json
{
  "intervalEnd": "2026-01-31 14:15:00",
  "pulseCount": 42,
  "kWh": 0.25,
  "kW": 1.0,
  "total_kWh": 12345.67,
  "r17Exclude": false,
  "kyzInvalidAlarm": false
}
```

Required fields:
- `intervalEnd` (`YYYY-MM-DD HH:MM:SS`)
- `pulseCount` (int)
- `kWh` (number)
- `kW` (number)

Optional fields:
- `total_kWh` (number)
- `r17Exclude` (bool)
- `kyzInvalidAlarm` (bool)

## Windows Server (PACE server) Setup

1. **Install Python 3.11**
   - Download/install Python 3.11 (64-bit).
   - Ensure `python` and `pip` are available in PATH.

2. **Install Microsoft ODBC Driver 18 for SQL Server**
   - Download/install: "ODBC Driver 18 for SQL Server" from Microsoft.
   - Verify installation in **ODBC Data Sources (64-bit)** > **Drivers**.

3. **Deploy project files**
   ```powershell
   mkdir C:\apps\kyz-energy-monitor
   # Copy repository contents into C:\apps\kyz-energy-monitor
   cd C:\apps\kyz-energy-monitor
   ```

4. **Create and activate virtual environment**
   ```powershell
   python -m venv .venv
   .\.venv\Scripts\activate
   ```

5. **Install dependencies**
   ```powershell
   pip install --upgrade pip
   pip install -r requirements.txt
   ```

6. **Configure environment**
   ```powershell
   copy .env.example .env
   notepad .env
   ```
   Set valid MQTT broker and Azure SQL credentials.

7. **Run connectivity check**
   ```powershell
   python main.py --test-conn
   ```

8. **Run service**
   ```powershell
   python main.py
   ```

9. **Run continuously on server (recommended)**
   - Use **Task Scheduler** (At startup + restart on failure), or
   - Use a service wrapper such as NSSM pointing to:
     - Program: `C:\apps\kyz-energy-monitor\.venv\Scripts\python.exe`
     - Arguments: `C:\apps\kyz-energy-monitor\main.py`
     - Start in: `C:\apps\kyz-energy-monitor`

## SQL Scripts

The application does not execute DDL. Use scripts in `/sql` manually during deployment/change management.

- `sql/001_create_table.sql`
- `sql/002_indexes.sql` (optional)

## Manual SQL script (same as `sql/001_create_table.sql`)

```sql
CREATE TABLE dbo.KYZ_Interval (
    IntervalEnd      DATETIME2(0) NOT NULL,
    PulseCount       INT          NOT NULL,
    kWh              DECIMAL(18,6) NOT NULL,
    kW               DECIMAL(18,6) NOT NULL,
    Total_kWh        DECIMAL(18,6) NULL,
    R17Exclude       BIT          NULL,
    KyzInvalidAlarm  BIT          NULL,
    CONSTRAINT PK_KYZ_Interval PRIMARY KEY CLUSTERED (IntervalEnd)
);
```

## Notes

- Idempotency relies on `IntervalEnd` uniqueness in the existing table.
- If duplicates arrive, they are skipped and logged.
