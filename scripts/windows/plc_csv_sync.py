import hashlib
import logging
import os
import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pyodbc
from dotenv import load_dotenv

from plc_csv import parse_plc_csv


class ConfigError(Exception):
    """Raised when required configuration is missing."""


def get_repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def configure_logging(repo_root: Path) -> logging.Logger:
    logs_dir = repo_root / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)

    logger = logging.getLogger("plc_csv_sync")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()

    file_handler = logging.FileHandler(logs_dir / "plc_csv_sync.log", encoding="utf-8")
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

    console_handler = logging.StreamHandler()
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)
    return logger


def get_required_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise ConfigError(f"Missing required environment variable: {name}")
    return value


def get_sql_connection_string() -> str:
    return (
        "DRIVER={ODBC Driver 18 for SQL Server};"
        f"SERVER={get_required_env('SQL_SERVER')};"
        f"DATABASE={get_required_env('SQL_DATABASE')};"
        f"UID={get_required_env('SQL_USERNAME')};"
        f"PWD={get_required_env('SQL_PASSWORD')};"
        "Encrypt=yes;"
        "TrustServerCertificate=no;"
        "Connection Timeout=15;"
    )


def get_env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw in (None, ""):
        return default
    return int(raw)


def get_env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw in (None, ""):
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def compute_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_mtime_utc(path: Path) -> datetime:
    return datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc).replace(tzinfo=None)


def get_log_row(cursor: pyodbc.Cursor, file_path: str) -> tuple | None:
    cursor.execute(
        """
        SELECT FileSizeBytes, LastWriteTimeUtc, Sha256, Status
        FROM dbo.KYZ_PlcCsvIngestLog
        WHERE FilePath = ?
        """,
        file_path,
    )
    return cursor.fetchone()


def upsert_intervals(cursor: pyodbc.Cursor, rows: list[dict]) -> None:
    if not rows:
        return

    sql = """
    MERGE dbo.KYZ_Interval WITH (HOLDLOCK) AS target
    USING (
        SELECT
            ? AS IntervalEnd,
            ? AS PulseCount,
            ? AS kWh,
            ? AS kW,
            ? AS Total_kWh,
            ? AS R17Exclude,
            ? AS KyzInvalidAlarm
    ) AS source
    ON target.IntervalEnd = source.IntervalEnd
    WHEN MATCHED THEN
        UPDATE SET
            PulseCount = source.PulseCount,
            kWh = source.kWh,
            kW = source.kW,
            Total_kWh = source.Total_kWh,
            R17Exclude = source.R17Exclude,
            KyzInvalidAlarm = source.KyzInvalidAlarm
    WHEN NOT MATCHED THEN
        INSERT (IntervalEnd, PulseCount, kWh, kW, Total_kWh, R17Exclude, KyzInvalidAlarm)
        VALUES (source.IntervalEnd, source.PulseCount, source.kWh, source.kW, source.Total_kWh, source.R17Exclude, source.KyzInvalidAlarm);
    """
    params = [
        (
            row["IntervalEnd"],
            row["PulseCount"],
            row["kWh"],
            row["kW"],
            row["Total_kWh"],
            row["R17Exclude"],
            row["KyzInvalidAlarm"],
        )
        for row in rows
    ]
    cursor.fast_executemany = True
    cursor.executemany(sql, params)


def upsert_ingest_log(
    cursor: pyodbc.Cursor,
    *,
    file_path: str,
    file_size: int,
    write_time_utc: datetime,
    sha256: str,
    status: str,
    row_count: int,
    interval_min: datetime | None,
    interval_max: datetime | None,
    error_message: str | None,
) -> None:
    cursor.execute(
        """
        MERGE dbo.KYZ_PlcCsvIngestLog AS target
        USING (
            SELECT
                ? AS FilePath,
                ? AS FileSizeBytes,
                ? AS LastWriteTimeUtc,
                ? AS Sha256,
                ? AS ProcessedAtUtc,
                ? AS Status,
                ? AS RowCount,
                ? AS IntervalMin,
                ? AS IntervalMax,
                ? AS ErrorMessage
        ) AS source
        ON target.FilePath = source.FilePath
        WHEN MATCHED THEN UPDATE SET
            FileSizeBytes = source.FileSizeBytes,
            LastWriteTimeUtc = source.LastWriteTimeUtc,
            Sha256 = source.Sha256,
            ProcessedAtUtc = source.ProcessedAtUtc,
            Status = source.Status,
            RowCount = source.RowCount,
            IntervalMin = source.IntervalMin,
            IntervalMax = source.IntervalMax,
            ErrorMessage = source.ErrorMessage
        WHEN NOT MATCHED THEN
            INSERT (FilePath, FileSizeBytes, LastWriteTimeUtc, Sha256, ProcessedAtUtc, Status, RowCount, IntervalMin, IntervalMax, ErrorMessage)
            VALUES (source.FilePath, source.FileSizeBytes, source.LastWriteTimeUtc, source.Sha256, source.ProcessedAtUtc, source.Status, source.RowCount, source.IntervalMin, source.IntervalMax, source.ErrorMessage);
        """,
        file_path,
        file_size,
        write_time_utc,
        sha256,
        datetime.utcnow(),
        status,
        row_count,
        interval_min,
        interval_max,
        error_message,
    )


def main() -> int:
    repo_root = get_repo_root()
    logger = configure_logging(repo_root)
    load_dotenv(repo_root / ".env")

    try:
        drop_dir = Path(os.getenv("PLC_CSV_DROP_DIR", str(repo_root / "plc_csv_drop")))
        glob_pattern = os.getenv("PLC_CSV_GLOB", "*.csv")
        min_age_seconds = get_env_int("PLC_CSV_MIN_AGE_SECONDS", 10)
        move_to_archive = get_env_bool("PLC_CSV_MOVE_TO_ARCHIVE", False)
        archive_dir = Path(os.getenv("PLC_CSV_ARCHIVE_DIR", str(drop_dir / "archive")))

        if not drop_dir.exists():
            raise ConfigError(f"PLC CSV drop directory does not exist: {drop_dir}")

        with pyodbc.connect(get_sql_connection_string(), autocommit=False) as conn:
            cursor = conn.cursor()
            processed = 0
            skipped = 0
            errored = 0
            threshold = datetime.now(timezone.utc) - timedelta(seconds=min_age_seconds)

            for file_path in sorted(drop_dir.glob(glob_pattern)):
                if not file_path.is_file():
                    continue

                mtime_aware = datetime.fromtimestamp(file_path.stat().st_mtime, tz=timezone.utc)
                if mtime_aware > threshold:
                    skipped += 1
                    logger.info("Skipping %s (too new)", file_path)
                    continue

                size = file_path.stat().st_size
                mtime_utc = mtime_aware.replace(tzinfo=None)
                file_str = str(file_path.resolve())
                sha256 = compute_sha256(file_path)
                existing = get_log_row(cursor, file_str)

                if existing is not None:
                    old_size, old_mtime, old_sha, old_status = existing
                    if old_status == "ok" and old_size == size and old_mtime == mtime_utc and old_sha == sha256:
                        skipped += 1
                        logger.info("Skipping %s (unchanged)", file_path)
                        continue

                try:
                    rows = parse_plc_csv(file_path)
                    upsert_intervals(cursor, rows)
                    interval_min = rows[0]["IntervalEnd"] if rows else None
                    interval_max = rows[-1]["IntervalEnd"] if rows else None
                    upsert_ingest_log(
                        cursor,
                        file_path=file_str,
                        file_size=size,
                        write_time_utc=mtime_utc,
                        sha256=sha256,
                        status="ok",
                        row_count=len(rows),
                        interval_min=interval_min,
                        interval_max=interval_max,
                        error_message=None,
                    )
                    conn.commit()
                    processed += 1
                    logger.info(
                        "Processed %s rows=%s interval_min=%s interval_max=%s",
                        file_path,
                        len(rows),
                        interval_min,
                        interval_max,
                    )

                    if move_to_archive:
                        archive_dir.mkdir(parents=True, exist_ok=True)
                        destination = archive_dir / file_path.name
                        if destination.exists():
                            timestamp_suffix = datetime.utcnow().strftime("%Y%m%d%H%M%S")
                            destination = archive_dir / f"{file_path.stem}_{timestamp_suffix}{file_path.suffix}"
                        shutil.move(str(file_path), str(destination))
                        logger.info("Moved %s -> %s", file_path, destination)
                except Exception as exc:  # noqa: BLE001
                    conn.rollback()
                    errored += 1
                    error_text = str(exc)
                    logger.exception("Failed processing %s: %s", file_path, error_text)
                    upsert_ingest_log(
                        cursor,
                        file_path=file_str,
                        file_size=size,
                        write_time_utc=mtime_utc,
                        sha256=sha256,
                        status="error",
                        row_count=0,
                        interval_min=None,
                        interval_max=None,
                        error_message=error_text[:4000],
                    )
                    conn.commit()

            logger.info("Run summary processed=%s skipped=%s errored=%s", processed, skipped, errored)
            return 1 if errored else 0

    except ConfigError as exc:
        logger.exception("Configuration error: %s", exc)
        return 2
    except Exception as exc:  # noqa: BLE001
        logger.exception("Unexpected failure: %s", exc)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
