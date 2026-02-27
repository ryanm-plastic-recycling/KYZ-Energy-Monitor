from __future__ import annotations

import csv
import re
from datetime import datetime
from pathlib import Path


REQUIRED_COLUMNS = {
    "Date",
    "Time",
    "counter15min",
    "LastEnergyUsage",
    "LastDemand",
    "TotalEnergyUsed",
    "R17_Last_ExcludeDemand",
    "KYZ_InvalidAlarm",
}


def _parse_datetime(date_value: str, time_value: str) -> datetime:
    date_part = date_value.strip()
    time_part = time_value.strip().split(".", 1)[0]
    return datetime.strptime(f"{date_part} {time_part}", "%m/%d/%Y %H:%M:%S")


def _parse_flag(value: str) -> int:
    match = re.search(r"([01])\s*$", (value or "").strip())
    if not match:
        return 0
    return int(match.group(1))


def parse_plc_csv(path: Path, interval_minutes: int = 15) -> list[dict]:
    del interval_minutes  # reserved for future validation against counter cadence

    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise ValueError(f"CSV has no header row: {path}")

        normalized_headers = [header.strip() for header in reader.fieldnames]
        missing_columns = REQUIRED_COLUMNS - set(normalized_headers)
        if missing_columns:
            missing = ", ".join(sorted(missing_columns))
            raise ValueError(f"CSV missing required columns: {missing}")

        deduped: dict[datetime, dict] = {}
        for raw_row in reader:
            row = {str(key).strip(): value for key, value in raw_row.items() if key is not None}
            interval_end = _parse_datetime(row["Date"], row["Time"])
            deduped[interval_end] = {
                "IntervalEnd": interval_end,
                "PulseCount": int(float(row["counter15min"].strip())),
                "kWh": float(row["LastEnergyUsage"].strip()),
                "kW": float(row["LastDemand"].strip()),
                "Total_kWh": float(row["TotalEnergyUsed"].strip()),
                "R17Exclude": _parse_flag(row.get("R17_Last_ExcludeDemand", "")),
                "KyzInvalidAlarm": _parse_flag(row.get("KYZ_InvalidAlarm", "")),
            }

    return [deduped[key] for key in sorted(deduped)]
