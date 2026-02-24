import os
import sys
from pathlib import Path

import pyodbc
from dotenv import load_dotenv

ENV_PATH = Path(r"C:\apps\kyz-energy-monitor\.env")


class ConfigError(Exception):
    """Raised when required configuration is missing."""


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


def main() -> int:
    load_dotenv(ENV_PATH)

    try:
        with pyodbc.connect(get_sql_connection_string(), autocommit=True) as conn:
            conn.execute("EXEC dbo.usp_KYZ_Refresh_MonthlyDemand;")
    except (ConfigError, pyodbc.Error) as exc:
        print(f"Monthly demand refresh failed: {exc}", file=sys.stderr)
        return 1

    print("Monthly demand refresh completed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
