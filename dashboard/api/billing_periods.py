from __future__ import annotations

from calendar import monthrange
from datetime import datetime


def parse_billing_anchor(env: str | None) -> datetime | None:
    if env is None:
        return None
    raw = env.strip()
    if not raw:
        return None

    parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    if parsed.tzinfo is not None:
        parsed = parsed.replace(tzinfo=None)
    return parsed


def add_months_clamped(dt: datetime, months: int) -> datetime:
    month_index = (dt.month - 1) + months
    year = dt.year + month_index // 12
    month = (month_index % 12) + 1
    day = min(dt.day, monthrange(year, month)[1])
    return dt.replace(year=year, month=month, day=day)


def billing_period_start(dt: datetime, anchor: datetime) -> datetime:
    candidate = add_months_clamped(anchor, (dt.year - anchor.year) * 12 + (dt.month - anchor.month))
    if dt < candidate:
        return add_months_clamped(candidate, -1)
    return candidate


def billing_period_end(dt: datetime, anchor: datetime) -> datetime:
    return add_months_clamped(billing_period_start(dt, anchor), 1)
