import argparse
import logging
import os
import sys
from pathlib import Path

import pyodbc
from dotenv import load_dotenv


class ConfigError(Exception):
    """Raised when required configuration is missing."""


def get_repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def configure_logging(repo_root: Path) -> logging.Logger:
    logs_dir = repo_root / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)

    logger = logging.getLogger("purge_live15s")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()

    file_handler = logging.FileHandler(logs_dir / "purge_live15s.log", encoding="utf-8")
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)
    return logger


def load_repo_env(repo_root: Path) -> None:
    load_dotenv(repo_root / ".env")


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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Purge old rows from dbo.KYZ_Live15s")
    parser.add_argument("--retention-days", type=int, default=60, help="Rows older than this many days are deleted")
    parser.add_argument("--batch-size", type=int, default=50000, help="Delete batch size")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = get_repo_root()
    logger = configure_logging(repo_root)
    load_repo_env(repo_root)

    if args.retention_days < 0:
        logger.error("Invalid --retention-days: %s", args.retention_days)
        return 2

    if args.batch_size <= 0:
        logger.error("Invalid --batch-size: %s", args.batch_size)
        return 2

    try:
        with pyodbc.connect(get_sql_connection_string(), autocommit=True) as conn:
            cursor = conn.cursor()
            cursor.execute(
                "EXEC dbo.usp_KYZ_Purge_Live15s @RetentionDays=?, @BatchSize=?",
                args.retention_days,
                args.batch_size,
            )
            row = cursor.fetchone()
    except (ConfigError, pyodbc.Error) as exc:
        logger.exception("KYZ_Live15s retention failed: %s", exc)
        return 1

    rows_deleted = row[0] if row is not None and len(row) >= 1 else None
    cutoff_utc = row[1] if row is not None and len(row) >= 2 else None
    logger.info(
        "KYZ_Live15s retention complete retention_days=%s batch_size=%s rows_deleted=%s cutoff_utc=%s",
        args.retention_days,
        args.batch_size,
        rows_deleted,
        cutoff_utc,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
