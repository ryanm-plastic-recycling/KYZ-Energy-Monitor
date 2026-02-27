from datetime import date

from dashboard.api.usage_store import UsageStore


def test_increment_and_summary(tmp_path) -> None:
    store = UsageStore(tmp_path / "usage.sqlite")

    store.increment_page_view("/operations")
    store.increment_page_view("operations?token=abc")
    store.increment_page_view("/billing-risk?foo=bar")

    summary = store.summary(30)

    assert summary["days"] == 30
    assert summary["totalViews"] == 3
    assert summary["lastSeen"] is not None

    by_path = {item["path"]: item["count"] for item in summary["byPath"]}
    assert by_path["/operations"] == 2
    assert by_path["/billing-risk"] == 1

    today = date.today().isoformat()
    today_row = next(row for row in summary["byDay"] if row["date"] == today)
    assert today_row["count"] == 3


def test_prune_removes_old_rows(tmp_path) -> None:
    store = UsageStore(tmp_path / "usage.sqlite")
    with store._connect() as conn:  # noqa: SLF001 - scoped test setup
        conn.execute(
            "INSERT INTO page_views_daily(day, path, count, last_seen) VALUES (?, ?, ?, ?)",
            ("2000-01-01", "/old", 5, "2000-01-01T00:00:00"),
        )

    store.prune(180)
    summary = store.summary(365)

    assert all(item["path"] != "/old" for item in summary["byPath"])
