import logging
import os
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

    logger = logging.getLogger("monthly_demand_refresh")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()

    file_handler = logging.FileHandler(logs_dir / "monthly_demand_refresh.log", encoding="utf-8")
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)
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


def main() -> int:
    repo_root = get_repo_root()
    logger = configure_logging(repo_root)
    load_dotenv(repo_root / ".env")

    try:
        with pyodbc.connect(get_sql_connection_string(), autocommit=True) as conn:
            conn.execute("EXEC dbo.usp_KYZ_Refresh_MonthlyDemand;")
    except (ConfigError, pyodbc.Error) as exc:
        logger.exception("Monthly demand refresh failed: %s", exc)
        return 1

    logger.info("Monthly demand refresh completed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
