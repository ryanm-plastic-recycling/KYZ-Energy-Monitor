import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from datetime import date

from dashboard.api.analytics import BillingMonth, TariffConfig, annualized_peak_cost, compute_billing_series


def test_ratchet_respects_minimum_floor_under_12_months() -> None:
    tariff = TariffConfig(min_billing_kw=50.0, ratchet_percent=0.60)
    months = [
        BillingMonth(month_start=date(2025, 1, 1), top3_avg_kw=20.0, energy_kwh=1000.0),
        BillingMonth(month_start=date(2025, 2, 1), top3_avg_kw=45.0, energy_kwh=1100.0),
    ]

    series = compute_billing_series(months, tariff)

    assert series[0].ratchet_floor_kw == 50.0
    assert series[0].billed_demand_kw == 50.0
    assert series[1].ratchet_floor_kw == 50.0
    assert series[1].billed_demand_kw == 50.0


def test_ratchet_uses_prior_11_month_max_billed_demand() -> None:
    tariff = TariffConfig(min_billing_kw=50.0, ratchet_percent=0.60)
    months = [BillingMonth(month_start=date(2024, m, 1), top3_avg_kw=100.0, energy_kwh=1000.0) for m in range(1, 13)]
    months.append(BillingMonth(month_start=date(2025, 1, 1), top3_avg_kw=40.0, energy_kwh=900.0))

    series = compute_billing_series(months, tariff)

    assert series[-1].ratchet_floor_kw == 60.0
    assert series[-1].billed_demand_kw == 60.0


def test_cost_computation() -> None:
    tariff = TariffConfig(customer_charge=120.0, demand_rate_per_kw=10.0, energy_rate_per_kwh=0.05)
    months = [BillingMonth(month_start=date(2025, 1, 1), top3_avg_kw=80.0, energy_kwh=2000.0)]

    result = compute_billing_series(months, tariff)[0]

    assert result.demand_cost == 800.0
    assert result.energy_cost == 100.0
    assert result.total_estimated_cost == 1020.0
    assert annualized_peak_cost(100.0, tariff) == 12000.0
