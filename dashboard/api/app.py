import json
import logging
import os
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from logging.handlers import TimedRotatingFileHandler
from pathlib import Path
from threading import Lock
from typing import Any, Callable, Iterator

import pyodbc
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

from dashboard.api.analytics import BillingMonth, TariffConfig, annualized_peak_cost, compute_billing_series
from dashboard.api.billing_periods import add_months_clamped, billing_period_end, parse_billing_anchor

load_dotenv()


@dataclass
class CacheEntry:
    expires_at: float
    payload: Any


class TTLCache:
    def __init__(self) -> None:
        self._store: dict[str, CacheEntry] = {}
        self._lock = Lock()

    def get_or_set(self, key: str, ttl_seconds: int, producer: Callable[[], Any]) -> Any:
        now = time.time()
        with self._lock:
            cached = self._store.get(key)
            if cached and cached.expires_at > now:
                return cached.payload
        payload = producer()
        with self._lock:
            self._store[key] = CacheEntry(expires_at=now + ttl_seconds, payload=payload)
        return payload


def configure_logging() -> logging.Logger:
    logs_dir = Path("logs")
    logs_dir.mkdir(parents=True, exist_ok=True)

    formatter = logging.Formatter("%(asctime)s %(levelname)s [%(threadName)s] %(name)s - %(message)s")
    file_handler = TimedRotatingFileHandler(
        logs_dir / "dashboard_api.log",
        when="midnight",
        interval=1,
        backupCount=30,
        encoding="utf-8",
    )
    file_handler.setFormatter(formatter)

    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(formatter)

    root_logger = logging.getLogger()
    root_logger.setLevel(logging.INFO)
    root_logger.handlers.clear()
    root_logger.addHandler(file_handler)
    root_logger.addHandler(console_handler)

    for logger_name in ("uvicorn", "uvicorn.access", "uvicorn.error", "fastapi"):
        named = logging.getLogger(logger_name)
        named.handlers.clear()
        named.propagate = True

    return logging.getLogger("dashboard_api")


logger = configure_logging()
cache = TTLCache()


def get_tariff_config() -> TariffConfig:
    return TariffConfig(
        customer_charge=float(os.getenv("TARIFF_CUSTOMER_CHARGE", "120.00")),
        demand_rate_per_kw=float(os.getenv("TARIFF_DEMAND_RATE_PER_KW", "24.74")),
        energy_rate_per_kwh=float(os.getenv("TARIFF_ENERGY_RATE_PER_KWH", "0.04143")),
        ratchet_percent=float(os.getenv("TARIFF_RATCHET_PERCENT", "0.60")),
        min_billing_kw=float(os.getenv("TARIFF_MIN_BILLING_KW", "50")),
    )


def get_series_max_days() -> int:
    return int(os.getenv("API_SERIES_MAX_DAYS", "60"))


def get_allow_extended_ranges() -> bool:
    return os.getenv("API_ALLOW_EXTENDED_RANGE", "false").strip().lower() in {"1", "true", "yes"}


def get_billing_anchor() -> datetime | None:
    raw_anchor = os.getenv("BILLING_ANCHOR_DATE")
    if raw_anchor is None or not raw_anchor.strip():
        return None
    try:
        return parse_billing_anchor(raw_anchor)
    except ValueError as exc:
        logger.warning("Invalid BILLING_ANCHOR_DATE=%r; billing-period mode disabled", raw_anchor)
        logger.debug("Anchor parse failure", exc_info=exc)
        return None


def get_sql_connection_string() -> str:
    username, password, _ = resolve_dashboard_sql_credentials()
    return (
        "DRIVER={ODBC Driver 18 for SQL Server};"
        f"SERVER={os.getenv('SQL_SERVER', '')};"
        f"DATABASE={os.getenv('SQL_DATABASE', '')};"
        f"UID={username};"
        f"PWD={password};"
        "Encrypt=yes;"
        "TrustServerCertificate=no;"
        "Connection Timeout=15;"
    )


def resolve_dashboard_sql_credentials() -> tuple[str, str, str]:
    ro_username = os.getenv("SQL_RO_USERNAME", "").strip()
    ro_password = os.getenv("SQL_RO_PASSWORD", "")
    if ro_username and ro_password:
        return ro_username, ro_password, "ro"

    return os.getenv("SQL_USERNAME", ""), os.getenv("SQL_PASSWORD", ""), "rw"


def get_db_connection() -> pyodbc.Connection:
    return pyodbc.connect(get_sql_connection_string(), autocommit=True)


def row_to_latest(row: Any) -> dict[str, Any]:
    if row is None:
        return {}
    return {
        "IntervalEnd": row.IntervalEnd.isoformat() if row.IntervalEnd else None,
        "kW": float(row.kW) if row.kW is not None else None,
        "kWh": float(row.kWh) if row.kWh is not None else None,
        "PulseCount": row.PulseCount,
        "Total_kWh": float(row.Total_kWh) if row.Total_kWh is not None else None,
        "R17Exclude": bool(row.R17Exclude) if row.R17Exclude is not None else None,
        "KyzInvalidAlarm": bool(row.KyzInvalidAlarm) if row.KyzInvalidAlarm is not None else None,
    }




def row_to_live_latest(row: Any) -> dict[str, Any]:
    if row is None:
        return {}
    return {
        "SampleEnd": row.SampleEnd.isoformat() if row.SampleEnd else None,
        "kW": float(row.kW) if row.kW is not None else None,
        "kWh": float(row.kWh) if row.kWh is not None else None,
        "PulseCount": int(row.PulseCount) if row.PulseCount is not None else None,
        "Total_kWh": float(row.Total_kWh) if row.Total_kWh is not None else None,
    }

def parse_iso(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is not None:
            local_tz = datetime.now().astimezone().tzinfo
            if local_tz is not None:
                parsed = parsed.astimezone(local_tz)
            parsed = parsed.replace(tzinfo=None)
        return parsed
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"Invalid datetime: {value}") from exc


def enforce_series_window(start_dt: datetime, end_dt: datetime) -> None:
    if end_dt < start_dt:
        raise HTTPException(status_code=400, detail="end must be >= start")
    if get_allow_extended_ranges():
        return
    max_days = get_series_max_days()
    if end_dt - start_dt > timedelta(days=max_days):
        raise HTTPException(status_code=400, detail=f"Range exceeds limit of {max_days} days")


app = FastAPI(title="Plant Energy Dashboard API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def auth_middleware(request: Request, call_next: Callable[..., Any]) -> JSONResponse:
    if request.url.path.startswith("/api"):
        auth_token = os.getenv("DASHBOARD_AUTH_TOKEN", "").strip()
        if auth_token:
            provided = request.headers.get("X-Auth-Token", "") or request.query_params.get("token", "")
            if provided != auth_token:
                return JSONResponse(status_code=401, content={"detail": "Unauthorized"})
    return await call_next(request)


@app.get("/api/health")
def get_health() -> dict[str, Any]:
    server_time = datetime.now()
    db_connected = False
    latest_interval_end = None
    seconds_since_latest = None
    latest_live_end = None
    seconds_since_latest_live = None

    try:
        with get_db_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                """
                SELECT
                    MAX(i.IntervalEnd) AS latestIntervalEnd,
                    (SELECT MAX(l.SampleEnd) FROM dbo.KYZ_Live15s l) AS latestLiveEnd
                FROM dbo.KYZ_Interval i
                """
            )
            row = cursor.fetchone()
            db_connected = True
            latest_live_end = row.latestLiveEnd if row else None
            seconds_since_latest_live = None
            if row and row.latestIntervalEnd:
                latest_interval_end = row.latestIntervalEnd
                seconds_since_latest = int((server_time - latest_interval_end).total_seconds())
            if latest_live_end:
                seconds_since_latest_live = int((server_time - latest_live_end).total_seconds())
    except Exception:
        logger.exception("Health check DB failure")

    _, _, credential_mode = resolve_dashboard_sql_credentials()

    return {
        "serverTime": server_time.isoformat(),
        "dbConnected": db_connected,
        "latestIntervalEnd": latest_interval_end.isoformat() if latest_interval_end else None,
        "secondsSinceLatest": seconds_since_latest,
        "latestLiveEnd": latest_live_end.isoformat() if latest_live_end else None,
        "secondsSinceLatestLive": seconds_since_latest_live,
        "credentialMode": credential_mode,
    }


@app.get("/api/metrics")
def get_metrics() -> dict[str, Any]:
    try:
        with get_db_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                """
                SELECT
                    MAX(IntervalEnd) AS lastIntervalEnd,
                    COUNT(CASE WHEN IntervalEnd >= DATEADD(hour, -24, GETDATE()) THEN 1 END) AS rows24h,
                    SUM(CASE WHEN IntervalEnd >= DATEADD(hour, -24, GETDATE()) AND ISNULL(R17Exclude,0)=1 THEN 1 ELSE 0 END) AS r17Exclude24h,
                    SUM(CASE WHEN IntervalEnd >= DATEADD(hour, -24, GETDATE()) AND ISNULL(KyzInvalidAlarm,0)=1 THEN 1 ELSE 0 END) AS kyzInvalidAlarm24h
                FROM dbo.KYZ_Interval
                """
            )
            row = cursor.fetchone()
        last_interval_end = row.lastIntervalEnd if row else None
        return {
            "dbConnected": True,
            "lastIntervalEnd": last_interval_end.isoformat() if last_interval_end else None,
            "secondsSinceLastInterval": int((datetime.now() - last_interval_end).total_seconds()) if last_interval_end else None,
            "rowCount24h": int(row.rows24h or 0),
            "r17Exclude24h": int(row.r17Exclude24h or 0),
            "kyzInvalidAlarm24h": int(row.kyzInvalidAlarm24h or 0),
        }
    except Exception:
        logger.exception("Metrics query failed")
        return {
            "dbConnected": False,
            "lastIntervalEnd": None,
            "secondsSinceLastInterval": None,
            "rowCount24h": 0,
            "r17Exclude24h": 0,
            "kyzInvalidAlarm24h": 0,
        }


@app.get("/api/latest")
def get_latest() -> dict[str, Any]:
    with get_db_connection() as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT TOP 1 IntervalEnd, PulseCount, kWh, kW, Total_kWh, R17Exclude, KyzInvalidAlarm
            FROM dbo.KYZ_Interval
            ORDER BY IntervalEnd DESC
            """
        )
        row = cursor.fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="No interval rows found")
        return row_to_latest(row)


@app.get("/api/live/latest")
def get_live_latest() -> dict[str, Any]:
    with get_db_connection() as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT TOP 1 SampleEnd, PulseCount, kWh, kW, Total_kWh
            FROM dbo.KYZ_Live15s
            ORDER BY SampleEnd DESC
            """
        )
        row = cursor.fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="No live rows found")
        return row_to_live_latest(row)


@app.get("/api/live/series")
def get_live_series(minutes: int = 240) -> dict[str, Any]:
    minutes = max(1, min(minutes, 24 * 60 * 14))
    end_dt = datetime.now()
    start_dt = end_dt - timedelta(minutes=minutes)

    with get_db_connection() as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT SampleEnd AS t, kW, kWh
            FROM dbo.KYZ_Live15s
            WHERE SampleEnd >= ? AND SampleEnd <= ?
            ORDER BY SampleEnd ASC
            """,
            start_dt,
            end_dt,
        )
        rows = cursor.fetchall()

    points = [{"t": row.t.isoformat(), "kW": float(row.kW), "kWh": float(row.kWh)} for row in rows]
    return {"points": points}


@app.get("/api/series")
def get_series(minutes: int = 240, start: str | None = None, end: str | None = None) -> dict[str, Any]:
    minutes = max(15, min(minutes, get_series_max_days() * 24 * 60))
    end_dt = parse_iso(end) if end else datetime.now()
    start_dt = parse_iso(start) if start else (end_dt - timedelta(minutes=minutes))
    enforce_series_window(start_dt, end_dt)

    with get_db_connection() as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT IntervalEnd, kW, kWh, R17Exclude, KyzInvalidAlarm
            FROM dbo.KYZ_Interval
            WHERE IntervalEnd >= ? AND IntervalEnd <= ?
            ORDER BY IntervalEnd ASC
            """,
            start_dt,
            end_dt,
        )
        rows = cursor.fetchall()

    points = [
        {
            "t": row.IntervalEnd.isoformat(),
            "kW": float(row.kW),
            "kWh": float(row.kWh),
            "flags": {
                "r17Exclude": bool(row.R17Exclude) if row.R17Exclude is not None else False,
                "kyzInvalidAlarm": bool(row.KyzInvalidAlarm) if row.KyzInvalidAlarm is not None else False,
            },
        }
        for row in rows
    ]
    return {"points": points}




@app.get("/api/daily")
def get_daily(days: int = 14) -> dict[str, Any]:
    days = max(1, min(days, 90))
    key = f"daily:{days}"

    def producer() -> dict[str, Any]:
        with get_db_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                """
                SELECT
                    CAST(IntervalEnd AS date) AS [date],
                    SUM(CAST(kWh AS float)) AS kWh_sum,
                    MAX(CAST(kW AS float)) AS kW_peak,
                    COUNT(*) AS interval_count
                FROM dbo.KYZ_Interval
                WHERE IntervalEnd >= DATEADD(day, -?, CAST(GETDATE() AS date))
                  AND ISNULL(KyzInvalidAlarm, 0) = 0
                GROUP BY CAST(IntervalEnd AS date)
                ORDER BY [date] ASC
                """,
                days,
            )
            rows = cursor.fetchall()
        return {
            "days": [
                {
                    "date": row.date.isoformat(),
                    "kWh_sum": float(row.kWh_sum) if row.kWh_sum is not None else 0.0,
                    "kW_peak": float(row.kW_peak) if row.kW_peak is not None else 0.0,
                    "interval_count": int(row.interval_count),
                }
                for row in rows
            ]
        }

    return cache.get_or_set(key, ttl_seconds=30, producer=producer)


@app.get("/api/monthly-demand")
def get_monthly_demand(months: int = 12, basis: str = "calendar") -> dict[str, Any]:
    # KYZ_MonthlyDemand SQL snapshots remain calendar-month based for backward compatibility.
    payload = get_billing(months=max(12, min(months, 24)), basis=basis)
    return {
        "basis": payload["basis"],
        "anchorDate": payload["anchorDate"],
        "months": [
            {
                "monthStart": m["monthStart"],
                "periodStart": m["periodStart"],
                "periodEnd": m["periodEnd"],
                "peak_kW": m["billedDemandKW"],
                "top3_avg_kW": m["top3AvgKW"],
            }
            for m in payload["months"]
        ]
    }
@app.get("/api/summary")
def get_summary() -> dict[str, Any]:
    tariff = get_tariff_config()
    billing = get_billing(24, basis="calendar")
    months = billing["months"]
    current_month = months[-1] if months else None
    billing_anchor = get_billing_anchor()
    billing_period = get_billing(24, basis="billing")
    billing_months = billing_period["months"]
    current_billing_period = billing_months[-1] if billing_period["basis"] == "billing" and billing_months else None

    with get_db_connection() as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT TOP 1 IntervalEnd, kW
            FROM dbo.KYZ_Interval
            ORDER BY IntervalEnd DESC
            """
        )
        latest = cursor.fetchone()

        cursor.execute(
            """
            SELECT TOP 1 SampleEnd, kW
            FROM dbo.KYZ_Live15s
            ORDER BY SampleEnd DESC
            """
        )
        latest_live = cursor.fetchone()

        cursor.execute(
            """
            SELECT
                SUM(CASE WHEN CAST(IntervalEnd AS date)=CAST(GETDATE() AS date) THEN CAST(kWh AS float) ELSE 0 END) AS todayKwh,
                MAX(CASE WHEN CAST(IntervalEnd AS date)=CAST(GETDATE() AS date) THEN CAST(kW AS float) END) AS todayPeakKw,
                SUM(CASE WHEN IntervalEnd >= DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1) THEN CAST(kWh AS float) ELSE 0 END) AS mtdKwh,
                MAX(CASE WHEN IntervalEnd >= DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1) THEN IntervalEnd END) AS lastUpdated
            FROM dbo.KYZ_Interval
            WHERE ISNULL(KyzInvalidAlarm,0)=0
            """
        )
        totals = cursor.fetchone()

    response = {
        "plantName": os.getenv("PLANT_NAME", "KYZ Plant"),
        "lastUpdated": totals.lastUpdated.isoformat() if totals and totals.lastUpdated else None,
        "currentKW": float(latest.kW) if latest and latest.kW is not None else None,
        "currentKW_15s": float(latest_live.kW) if latest_live and latest_live.kW is not None else None,
        "todayKWh": float(totals.todayKwh or 0),
        "todayPeakKW": float(totals.todayPeakKw or 0),
        "mtdKWh": float(totals.mtdKwh or 0),
        "energyEstimateMonth": float((totals.mtdKwh or 0) * tariff.energy_rate_per_kwh),
        "currentMonthTop3AvgKW": current_month["top3AvgKW"] if current_month else 0,
        "ratchetFloorKW": current_month["ratchetFloorKW"] if current_month else tariff.min_billing_kw,
        "billedDemandEstimateKW": current_month["billedDemandKW"] if current_month else tariff.min_billing_kw,
        "demandEstimateMonth": current_month["demandCost"] if current_month else tariff.min_billing_kw * tariff.demand_rate_per_kw,
        "costOf100kwPeakAnnual": annualized_peak_cost(100.0, tariff),
    }

    if billing_anchor is None or current_billing_period is None:
        response.update(
            {
                "billingPeriodStart": None,
                "billingPeriodEnd": None,
                "btdKWh": None,
                "billingEnergyEstimate": None,
                "currentBillingPeriodTop3AvgKW": None,
                "currentBillingPeriodBilledDemandKW": None,
                "billingRatchetFloorKW": None,
            }
        )
        return response

    response.update(
        {
            "billingPeriodStart": current_billing_period["periodStart"],
            "billingPeriodEnd": current_billing_period["periodEnd"],
            "btdKWh": current_billing_period["energyKWh"],
            "billingEnergyEstimate": current_billing_period["energyCost"],
            "currentBillingPeriodTop3AvgKW": current_billing_period["top3AvgKW"],
            "currentBillingPeriodBilledDemandKW": current_billing_period["billedDemandKW"],
            "billingRatchetFloorKW": current_billing_period["ratchetFloorKW"],
        }
    )
    return response


@app.get("/api/billing")
def get_billing(months: int = 24, basis: str = "calendar") -> dict[str, Any]:
    months = max(12, min(months, 24))
    requested_basis = basis.strip().lower()
    if requested_basis not in {"calendar", "billing"}:
        raise HTTPException(status_code=400, detail="basis must be 'calendar' or 'billing'")

    anchor = get_billing_anchor()
    effective_basis = "billing" if requested_basis == "billing" and anchor is not None else "calendar"
    tariff = get_tariff_config()
    anchor_key = anchor.isoformat() if anchor else "none"
    key = f"billing:{months}:{requested_basis}:{effective_basis}:{anchor_key}:{tariff}"

    def producer() -> dict[str, Any]:
        with get_db_connection() as conn:
            cursor = conn.cursor()
            if effective_basis == "calendar":
                cursor.execute(
                    """
                WITH base AS (
                    SELECT
                        DATEFROMPARTS(YEAR(IntervalEnd), MONTH(IntervalEnd), 1) AS month_start,
                        CAST(kW AS float) AS kW,
                        CAST(kWh AS float) AS kWh,
                        ISNULL(R17Exclude,0) AS r17,
                        ISNULL(KyzInvalidAlarm,0) AS invalid
                    FROM dbo.KYZ_Interval
                    WHERE IntervalEnd >= DATEADD(month, -?, DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1))
                ), ranked AS (
                    SELECT
                        month_start,
                        kW,
                        ROW_NUMBER() OVER (PARTITION BY month_start ORDER BY kW DESC) AS rn
                    FROM base
                    WHERE invalid = 0 AND r17 = 0
                ), top3 AS (
                    SELECT month_start, AVG(kW) AS top3_avg_kW
                    FROM ranked
                    WHERE rn <= 3
                    GROUP BY month_start
                ), energy AS (
                    SELECT month_start, SUM(CASE WHEN invalid = 0 THEN kWh ELSE 0 END) AS energy_kWh
                    FROM base
                    GROUP BY month_start
                )
                SELECT e.month_start, t.top3_avg_kW, e.energy_kWh
                FROM energy e
                LEFT JOIN top3 t ON t.month_start = e.month_start
                ORDER BY e.month_start ASC
                    """,
                    months,
                )
            else:
                cursor.execute(
                    """
                WITH base AS (
                    SELECT
                        CASE
                            WHEN IntervalEnd < DATEADD(month, DATEDIFF(month, ?, IntervalEnd), ?)
                                THEN DATEADD(month, -1, DATEADD(month, DATEDIFF(month, ?, IntervalEnd), ?))
                            ELSE DATEADD(month, DATEDIFF(month, ?, IntervalEnd), ?)
                        END AS period_start,
                        CAST(kW AS float) AS kW,
                        CAST(kWh AS float) AS kWh,
                        ISNULL(R17Exclude,0) AS r17,
                        ISNULL(KyzInvalidAlarm,0) AS invalid
                    FROM dbo.KYZ_Interval
                    WHERE IntervalEnd >= DATEADD(month, -?, GETDATE())
                ), ranked AS (
                    SELECT
                        period_start,
                        kW,
                        ROW_NUMBER() OVER (PARTITION BY period_start ORDER BY kW DESC) AS rn
                    FROM base
                    WHERE invalid = 0 AND r17 = 0
                ), top3 AS (
                    SELECT period_start, AVG(kW) AS top3_avg_kW
                    FROM ranked
                    WHERE rn <= 3
                    GROUP BY period_start
                ), energy AS (
                    SELECT period_start, SUM(CASE WHEN invalid = 0 THEN kWh ELSE 0 END) AS energy_kWh
                    FROM base
                    GROUP BY period_start
                )
                SELECT e.period_start, t.top3_avg_kW, e.energy_kWh
                FROM energy e
                LEFT JOIN top3 t ON t.period_start = e.period_start
                ORDER BY e.period_start ASC
                """,
                    anchor,
                    anchor,
                    anchor,
                    anchor,
                    anchor,
                    anchor,
                    months,
                )
            rows = cursor.fetchall()

        source = [
            BillingMonth(
                month_start=(row.month_start if hasattr(row, "month_start") else row.period_start.date()),
                top3_avg_kw=float(row.top3_avg_kW or 0),
                energy_kwh=float(row.energy_kWh or 0),
            )
            for row in rows
        ]
        series = compute_billing_series(source, tariff)

        anchor_iso = anchor.date().isoformat() if anchor else None
        return {
            "basis": effective_basis,
            "requestedBasis": requested_basis,
            "anchorDate": anchor_iso,
            "tariff": {
                "customerCharge": tariff.customer_charge,
                "demandRatePerKW": tariff.demand_rate_per_kw,
                "energyRatePerKWh": tariff.energy_rate_per_kwh,
                "ratchetPercent": tariff.ratchet_percent,
                "minBillingKW": tariff.min_billing_kw,
            },
            "months": [
                {
                    "monthStart": row.month_start.isoformat(),
                    "periodStart": row.month_start.isoformat(),
                    "periodEnd": (
                        billing_period_end(datetime.combine(row.month_start, datetime.min.time()), anchor).date().isoformat()
                        if effective_basis == "billing" and anchor is not None
                        else add_months_clamped(datetime.combine(row.month_start, datetime.min.time()), 1).date().isoformat()
                    ),
                    "top3AvgKW": row.top3_avg_kw,
                    "ratchetFloorKW": row.ratchet_floor_kw,
                    "billedDemandKW": row.billed_demand_kw,
                    "demandCost": row.demand_cost,
                    "energyKWh": row.energy_kwh,
                    "energyCost": row.energy_cost,
                    "customerCharge": row.customer_charge,
                    "totalEstimatedCost": row.total_estimated_cost,
                }
                for row in series
            ],
        }

    return cache.get_or_set(key, ttl_seconds=30, producer=producer)


def build_quality_query() -> str:
    return """
            WITH ordered AS (
                SELECT k.IntervalEnd AS IntervalEnd,
                       LAG(k.IntervalEnd) OVER (ORDER BY k.IntervalEnd) AS prev_end
                FROM dbo.KYZ_Interval k
                WHERE k.IntervalEnd >= DATEADD(hour, -24, GETDATE())
            )
            SELECT
                SUM(CASE WHEN o.prev_end IS NOT NULL AND DATEDIFF(minute, o.prev_end, o.IntervalEnd) > 15
                    THEN (DATEDIFF(minute, o.prev_end, o.IntervalEnd) / 15) - 1
                    ELSE 0 END) AS missing24h,
                SUM(CASE WHEN k.IntervalEnd >= DATEADD(hour, -24, GETDATE()) AND ISNULL(k.KyzInvalidAlarm,0)=1 THEN 1 ELSE 0 END) AS invalid24h,
                SUM(CASE WHEN k.IntervalEnd >= DATEADD(day, -7, GETDATE()) AND ISNULL(k.KyzInvalidAlarm,0)=1 THEN 1 ELSE 0 END) AS invalid7d,
                SUM(CASE WHEN k.IntervalEnd >= DATEADD(hour, -24, GETDATE()) AND ISNULL(k.R17Exclude,0)=1 THEN 1 ELSE 0 END) AS r1724h,
                SUM(CASE WHEN k.IntervalEnd >= DATEADD(day, -7, GETDATE()) AND ISNULL(k.R17Exclude,0)=1 THEN 1 ELSE 0 END) AS r177d,
                SUM(CASE WHEN k.IntervalEnd >= DATEADD(hour, -24, GETDATE()) THEN 1 ELSE 0 END) AS observed24h
            FROM dbo.KYZ_Interval k
            LEFT JOIN ordered o ON o.IntervalEnd = k.IntervalEnd
            """


@app.get("/api/quality")
def get_quality() -> dict[str, Any]:
    with get_db_connection() as conn:
        cursor = conn.cursor()
        cursor.execute(build_quality_query())
        row = cursor.fetchone()

    expected = 96
    if row is None:
        return {
            "expectedIntervals24h": expected,
            "observedIntervals24h": 0,
            "missingIntervals24h": 0,
            "kyzInvalidAlarm": {"last24h": 0, "last7d": 0},
            "r17Exclude": {"last24h": 0, "last7d": 0},
        }

    observed = int(row.observed24h or 0)
    missing = int(row.missing24h or max(expected - observed, 0))

    return {
        "expectedIntervals24h": expected,
        "observedIntervals24h": observed,
        "missingIntervals24h": missing,
        "kyzInvalidAlarm": {"last24h": int(row.invalid24h or 0), "last7d": int(row.invalid7d or 0)},
        "r17Exclude": {"last24h": int(row.r1724h or 0), "last7d": int(row.r177d or 0)},
    }


@app.get("/api/stream")
def get_stream() -> StreamingResponse:
    poll_seconds = max(1, int(os.getenv("DASHBOARD_SSE_POLL_SECONDS", "5")))

    def event_generator() -> Iterator[str]:
        last_interval: str | None = None
        while True:
            try:
                with get_db_connection() as conn:
                    cursor = conn.cursor()
                    cursor.execute(
                        """
                        SELECT TOP 1 IntervalEnd, PulseCount, kWh, kW, Total_kWh, R17Exclude, KyzInvalidAlarm
                        FROM dbo.KYZ_Interval
                        ORDER BY IntervalEnd DESC
                        """
                    )
                    row = cursor.fetchone()
                if row:
                    current = row.IntervalEnd.isoformat()
                    if current != last_interval:
                        last_interval = current
                        payload = row_to_latest(row)
                        yield f"event: latest\ndata: {json.dumps(payload)}\n\n"
                else:
                    yield "event: heartbeat\ndata: {}\n\n"
            except GeneratorExit:
                logger.info("SSE client disconnected")
                return
            except Exception:
                logger.exception("SSE polling failed")
                yield 'event: error\ndata: {"message":"poll failure"}\n\n'

            time.sleep(poll_seconds)

    return StreamingResponse(event_generator(), media_type="text/event-stream")


static_dir = Path(__file__).parent / "static"
if static_dir.exists():
    app.mount("/assets", StaticFiles(directory=static_dir / "assets"), name="assets")


@app.get("/")
def serve_root() -> FileResponse:
    index_file = static_dir / "index.html"
    if index_file.exists():
        return FileResponse(index_file)
    return FileResponse(Path(__file__).parent / "placeholder.html")


@app.get("/kiosk")
def serve_kiosk() -> FileResponse:
    index_file = static_dir / "index.html"
    if index_file.exists():
        return FileResponse(index_file)
    return FileResponse(Path(__file__).parent / "placeholder.html")
