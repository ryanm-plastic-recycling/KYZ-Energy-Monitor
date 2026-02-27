import sqlite3
from datetime import date, datetime, timedelta
from pathlib import Path
from threading import Lock
from typing import Any


class UsageStore:
    def __init__(self, db_path: str | Path = "logs/dashboard_usage.sqlite") -> None:
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = Lock()
        self._init_db()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS page_views_daily (
                    day TEXT NOT NULL,
                    path TEXT NOT NULL,
                    count INTEGER NOT NULL DEFAULT 0,
                    last_seen TEXT NOT NULL,
                    PRIMARY KEY(day, path)
                )
                """
            )

    @staticmethod
    def sanitize_path(raw_path: str) -> str:
        cleaned = (raw_path or "").strip()
        if "?" in cleaned:
            cleaned = cleaned.split("?", 1)[0]
        if not cleaned:
            cleaned = "/"
        if not cleaned.startswith("/"):
            cleaned = f"/{cleaned}"
        if len(cleaned) > 200:
            cleaned = cleaned[:200]
        return cleaned

    def prune(self, retention_days: int) -> None:
        retention_days = max(1, retention_days)
        cutoff = (date.today() - timedelta(days=retention_days)).isoformat()
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM page_views_daily WHERE day < ?", (cutoff,))

    def increment_page_view(self, raw_path: str) -> str:
        path = self.sanitize_path(raw_path)
        day = date.today().isoformat()
        now = datetime.now().isoformat(timespec="seconds")
        with self._lock, self._connect() as conn:
            conn.execute(
                """
                INSERT INTO page_views_daily(day, path, count, last_seen)
                VALUES(?, ?, 1, ?)
                ON CONFLICT(day, path) DO UPDATE SET
                    count = count + 1,
                    last_seen = excluded.last_seen
                """,
                (day, path, now),
            )
        return path

    def summary(self, days: int) -> dict[str, Any]:
        days = max(1, min(days, 365))
        start_day = (date.today() - timedelta(days=days - 1)).isoformat()
        by_day = self._empty_by_day(days)

        with self._lock, self._connect() as conn:
            rows_by_day = conn.execute(
                """
                SELECT day, SUM(count) AS count
                FROM page_views_daily
                WHERE day >= ?
                GROUP BY day
                ORDER BY day ASC
                """,
                (start_day,),
            ).fetchall()

            by_path_rows = conn.execute(
                """
                SELECT path, SUM(count) AS count
                FROM page_views_daily
                WHERE day >= ?
                GROUP BY path
                ORDER BY count DESC, path ASC
                """,
                (start_day,),
            ).fetchall()

            meta_row = conn.execute(
                """
                SELECT SUM(count) AS total_views, MAX(last_seen) AS last_seen
                FROM page_views_daily
                WHERE day >= ?
                """,
                (start_day,),
            ).fetchone()

        counts = {row["day"]: int(row["count"] or 0) for row in rows_by_day}
        for item in by_day:
            item["count"] = counts.get(item["date"], 0)

        return {
            "days": days,
            "totalViews": int((meta_row["total_views"] if meta_row else 0) or 0),
            "byDay": by_day,
            "byPath": [{"path": row["path"], "count": int(row["count"] or 0)} for row in by_path_rows],
            "lastSeen": (meta_row["last_seen"] if meta_row else None),
        }

    @staticmethod
    def _empty_by_day(days: int) -> list[dict[str, Any]]:
        today = date.today()
        return [
            {"date": (today - timedelta(days=offset)).isoformat(), "count": 0}
            for offset in range(days - 1, -1, -1)
        ]
