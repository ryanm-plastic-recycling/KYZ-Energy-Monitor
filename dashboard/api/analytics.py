from __future__ import annotations

from dataclasses import dataclass
from datetime import date


@dataclass(frozen=True)
class TariffConfig:
    customer_charge: float = 120.00
    demand_rate_per_kw: float = 24.74
    energy_rate_per_kwh: float = 0.04143
    ratchet_percent: float = 0.60
    min_billing_kw: float = 50.0


@dataclass(frozen=True)
class BillingMonth:
    month_start: date
    top3_avg_kw: float
    energy_kwh: float


@dataclass(frozen=True)
class BillingResult:
    month_start: date
    top3_avg_kw: float
    ratchet_floor_kw: float
    billed_demand_kw: float
    demand_cost: float
    energy_kwh: float
    energy_cost: float
    customer_charge: float
    total_estimated_cost: float


def compute_billing_series(months: list[BillingMonth], tariff: TariffConfig) -> list[BillingResult]:
    results: list[BillingResult] = []
    prior_billed: list[float] = []

    for month in months:
        recent = prior_billed[-11:]
        ratchet_floor_kw = max(tariff.min_billing_kw, tariff.ratchet_percent * max(recent, default=0.0))
        billed_demand_kw = max(month.top3_avg_kw, ratchet_floor_kw)
        demand_cost = billed_demand_kw * tariff.demand_rate_per_kw
        energy_cost = month.energy_kwh * tariff.energy_rate_per_kwh
        total_estimated_cost = demand_cost + energy_cost + tariff.customer_charge

        results.append(
            BillingResult(
                month_start=month.month_start,
                top3_avg_kw=month.top3_avg_kw,
                ratchet_floor_kw=ratchet_floor_kw,
                billed_demand_kw=billed_demand_kw,
                demand_cost=demand_cost,
                energy_kwh=month.energy_kwh,
                energy_cost=energy_cost,
                customer_charge=tariff.customer_charge,
                total_estimated_cost=total_estimated_cost,
            )
        )
        prior_billed.append(billed_demand_kw)

    return results


def annualized_peak_cost(peak_kw: float, tariff: TariffConfig) -> float:
    return peak_kw * tariff.demand_rate_per_kw * 12.0
