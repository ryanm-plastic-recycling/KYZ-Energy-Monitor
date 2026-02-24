import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from datetime import datetime

from dashboard.api.billing_periods import add_months_clamped, billing_period_end, billing_period_start


def test_add_months_clamped_anchor_31_into_feb_and_apr() -> None:
    anchor = datetime(2025, 1, 31, 0, 0, 0)
    assert add_months_clamped(anchor, 1) == datetime(2025, 2, 28, 0, 0, 0)
    assert add_months_clamped(anchor, 3) == datetime(2025, 4, 30, 0, 0, 0)


def test_dates_before_anchor_roll_back_previous_period() -> None:
    anchor = datetime(2025, 1, 17, 0, 0, 0)
    dt = datetime(2025, 1, 16, 23, 59, 59)
    assert billing_period_start(dt, anchor) == datetime(2024, 12, 17, 0, 0, 0)
    assert billing_period_end(dt, anchor) == datetime(2025, 1, 17, 0, 0, 0)


def test_exact_boundary_belongs_to_new_period() -> None:
    anchor = datetime(2025, 1, 17, 0, 0, 0)
    dt = datetime(2025, 2, 17, 0, 0, 0)
    assert billing_period_start(dt, anchor) == datetime(2025, 2, 17, 0, 0, 0)
    assert billing_period_end(dt, anchor) == datetime(2025, 3, 17, 0, 0, 0)
