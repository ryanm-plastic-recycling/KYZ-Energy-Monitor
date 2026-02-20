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

    logger = logging.getLogger("dashboard_api")
    logger.setLevel(logging.INFO)

    formatter = logging.Formatter(
        "%(asctime)s %(levelname)s [%(threadName)s] %(name)s - %(message)s"
    )

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

    logger.handlers.clear()
    logger.addHandler(file_handler)
    logger.addHandler(console_handler)

    return logger


logger = configure_logging()
cache = TTLCache()


def get_sql_connection_string() -> str:
    return (
        "DRIVER={ODBC Driver 18 for SQL Server};"
        f"SERVER={os.getenv('SQL_SERVER','')};"
        f"DATABASE={os.getenv('SQL_DATABASE','')};"
        f"UID={os.getenv('SQL_USERNAME','')};"
        f"PWD={os.getenv('SQL_PASSWORD','')};"
        "Encrypt=yes;"
        "TrustServerCertificate=no;"
        "Connection Timeout=15;"
    )


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


def parse_iso(value: str) -> datetime:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).replace(tzinfo=None)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"Invalid datetime: {value}") from exc


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
            provided = request.headers.get("X-Auth-Token", "")
            if provided != auth_token:
                return JSONResponse(status_code=401, content={"detail": "Unauthorized"})
    return await call_next(request)


@app.get("/api/health")
def get_health() -> dict[str, Any]:
    server_time = datetime.now()
    db_connected = False
    latest_interval_end = None
    seconds_since_latest = None

    try:
        with get_db_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT MAX(IntervalEnd) AS latestIntervalEnd FROM dbo.KYZ_Interval")
            row = cursor.fetchone()
            db_connected = True
            if row and row.latestIntervalEnd:
                latest_interval_end = row.latestIntervalEnd
                seconds_since_latest = int((server_time - latest_interval_end).total_seconds())
    except Exception:
        logger.exception("Health check DB failure")

    return {
        "serverTime": server_time.isoformat(),
        "dbConnected": db_connected,
        "latestIntervalEnd": latest_interval_end.isoformat() if latest_interval_end else None,
        "secondsSinceLatest": seconds_since_latest,
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


@app.get("/api/series")
def get_series(minutes: int = 240, start: str | None = None, end: str | None = None) -> dict[str, Any]:
    where_clause = "WHERE IntervalEnd >= ?"
    params: list[Any] = [datetime.now() - timedelta(minutes=minutes)]

    if start:
        where_clause = "WHERE IntervalEnd >= ?"
        params = [parse_iso(start)]
    if end:
        where_clause += " AND IntervalEnd <= ?"
        params.append(parse_iso(end))

    with get_db_connection() as conn:
        cursor = conn.cursor()
        cursor.execute(
            f"""
            SELECT IntervalEnd, kW, kWh, R17Exclude, KyzInvalidAlarm
            FROM dbo.KYZ_Interval
            {where_clause}
            ORDER BY IntervalEnd ASC
            """,
            tuple(params),
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
def get_monthly_demand(months: int = 12) -> dict[str, Any]:
    months = max(1, min(months, 36))
    key = f"monthly:{months}"

    def producer() -> dict[str, Any]:
        with get_db_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                """
                WITH base AS (
                    SELECT
                        DATEFROMPARTS(YEAR(IntervalEnd), MONTH(IntervalEnd), 1) AS month_start,
                        CAST(kW AS float) AS kW
                    FROM dbo.KYZ_Interval
                    WHERE IntervalEnd >= DATEADD(month, -?, DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1))
                      AND ISNULL(KyzInvalidAlarm, 0) = 0
                      AND ISNULL(R17Exclude, 0) = 0
                ), ranked AS (
                    SELECT
                        month_start,
                        kW,
                        ROW_NUMBER() OVER (PARTITION BY month_start ORDER BY kW DESC) AS rn
                    FROM base
                )
                SELECT
                    b.month_start,
                    MAX(b.kW) AS peak_kW,
                    AVG(CASE WHEN r.rn <= 3 THEN r.kW END) AS top3_avg_kW
                FROM base b
                LEFT JOIN ranked r ON r.month_start = b.month_start
                GROUP BY b.month_start
                ORDER BY b.month_start ASC
                """,
                months,
            )
            rows = cursor.fetchall()
        return {
            "months": [
                {
                    "monthStart": row.month_start.isoformat(),
                    "peak_kW": float(row.peak_kW) if row.peak_kW is not None else 0.0,
                    "top3_avg_kW": float(row.top3_avg_kW) if row.top3_avg_kW is not None else 0.0,
                }
                for row in rows
            ]
        }

    return cache.get_or_set(key, ttl_seconds=30, producer=producer)


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
                yield "event: error\ndata: {\"message\":\"poll failure\"}\n\n"

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
