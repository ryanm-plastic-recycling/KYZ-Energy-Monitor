import pytest
from datetime import datetime

from main import bucket_end, compute_energy_metrics, parse_packed_pulse_payload


def test_parse_packed_payload_accepts_expected_fields() -> None:
    delta, total, r17_exclude, kyz_invalid_alarm = parse_packed_pulse_payload("d=42,c=1234567")

    assert delta == 42
    assert total == 1234567
    assert r17_exclude is None
    assert kyz_invalid_alarm is None


def test_parse_packed_payload_accepts_optional_spaces() -> None:
    delta, total, r17_exclude, kyz_invalid_alarm = parse_packed_pulse_payload(" d=5 , c=10 ")

    assert delta == 5
    assert total == 10
    assert r17_exclude is None
    assert kyz_invalid_alarm is None


def test_parse_packed_payload_parses_optional_flags() -> None:
    delta, total, r17_exclude, kyz_invalid_alarm = parse_packed_pulse_payload(
        "d=1,c=2,r17Exclude=1,kyzInvalidAlarm=0"
    )

    assert delta == 1
    assert total == 2
    assert r17_exclude is True
    assert kyz_invalid_alarm is False




def test_parse_packed_payload_parses_boolean_string_variants() -> None:
    _, _, r17_exclude, kyz_invalid_alarm = parse_packed_pulse_payload(
        "d=0,c=2,r17Exclude=yes,kyzInvalidAlarm=off"
    )

    assert r17_exclude is True
    assert kyz_invalid_alarm is False

def test_bucket_end_aligns_to_boundary() -> None:
    t1 = datetime(2025, 1, 1, 12, 0, 14)
    t2 = datetime(2025, 1, 1, 12, 0, 15)

    assert bucket_end(t1, 15) == datetime(2025, 1, 1, 12, 0, 15)
    assert bucket_end(t2, 15) == datetime(2025, 1, 1, 12, 0, 15)


def test_compute_energy_metrics_uses_bucket_seconds() -> None:
    metrics = compute_energy_metrics(30, pulses_per_kwh=1000.0, bucket_seconds=15, pulse_total=1200)

    assert metrics["kWh"] == 0.03
    assert metrics["kW"] == pytest.approx(7.2)
    assert metrics["total_kWh"] == 1.2
