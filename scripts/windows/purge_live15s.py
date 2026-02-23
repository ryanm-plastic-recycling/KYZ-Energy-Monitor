import argparse
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import pyodbc
from dotenv import load_dotenv


class ConfigError(Exception):
    """Raised when required configuration is missing."""


def load_repo_env() -> None:
    repo_root = Path(__file__).resolve().parents[2]
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
    parser.add_argument("--retention-days", type=int, default=7, help="Rows older than this many days are deleted")
    parser.add_argument("--batch-size", type=int, default=50000, help="Delete batch size")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    load_repo_env()

    if args.retention_days < 0:
        print("Error: --retention-days must be >= 0", file=sys.stderr)
        return 2

    if args.batch_size <= 0:
        print("Error: --batch-size must be > 0", file=sys.stderr)
        return 2

    cutoff_utc = datetime.now(timezone.utc)
    rows_deleted = None

    try:
        with pyodbc.connect(get_sql_connection_string(), autocommit=True) as conn:
            cursor = conn.cursor()
            cursor.execute(
                "EXEC dbo.usp_KYZ_Purge_Live15s @RetentionDays=?, @BatchSize=?",
                args.retention_days,
                args.batch_size,
            )
            row = cursor.fetchone()
            if row is not None and len(row) >= 2:
                rows_deleted = row[0]
                cutoff_utc = row[1]
    except (ConfigError, pyodbc.Error) as exc:
        print(f"Purge failed: {exc}", file=sys.stderr)
        return 1

    print(
        "KYZ_Live15s retention complete "
        f"rows_deleted={rows_deleted if rows_deleted is not None else 'unknown'} "
        f"cutoff_utc={cutoff_utc}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
