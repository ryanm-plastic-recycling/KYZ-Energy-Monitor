from pathlib import Path

from plc_csv import parse_plc_csv


def test_parse_plc_csv_mapping_and_dedupe(tmp_path: Path) -> None:
    csv_text = """Date, Time, Sys_Year, Sys_Month, Sys_Day, Sys_Hour, Sys_Minute, Sys_Second, counter15min, LastEnergyUsage, LastDemand, TotalEnergyUsed, R17_Last_ExcludeDemand, KYZ_InvalidAlarm, KYZ_InvalidAlarmCount, KYZ_InvalidAlarmCountHourly
2/25/2026, 15:45:00.623, 2026, 2, 25, 15, 45, 0, 538, 915, 3660.000000, 966067.000, OFF - 0, ON - 1, 0, 0
2/25/2026, 15:45:00.100, 2026, 2, 25, 15, 45, 0, 999, 916, 3661.000000, 966068.000, ON - 1, OFF - 0, 0, 0
2/25/2026, 16:00:00.000, 2026, 2, 25, 16, 0, 0, 600, 920, 3680.000000, 966100.000, OFF - 0, OFF - 0, 0, 0
"""
    path = tmp_path / "plc.csv"
    path.write_text(csv_text, encoding="utf-8")

    rows = parse_plc_csv(path)

    assert len(rows) == 2
    first = rows[0]
    assert str(first["IntervalEnd"]) == "2026-02-25 15:45:00"
    assert first["PulseCount"] == 999
    assert first["kWh"] == 916.0
    assert first["kW"] == 3661.0
    assert first["Total_kWh"] == 966068.0
    assert first["R17Exclude"] == 1
    assert first["KyzInvalidAlarm"] == 0

    second = rows[1]
    assert str(second["IntervalEnd"]) == "2026-02-25 16:00:00"
