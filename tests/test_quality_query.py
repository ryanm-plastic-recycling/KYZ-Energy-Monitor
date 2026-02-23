from dashboard.api.app import build_quality_query, get_quality


def test_quality_query_uses_qualified_intervalend_references() -> None:
    query = build_quality_query()

    assert "FROM dbo.KYZ_Interval k" in query
    assert "LEFT JOIN ordered o ON o.IntervalEnd = k.IntervalEnd" in query

    select_clause = query.split("SELECT", 1)[1].split("FROM", 1)[0]
    assert " IntervalEnd" not in select_clause
    assert "(IntervalEnd" not in select_clause


class _Row:
    observed24h = None
    missing24h = None
    invalid24h = None
    invalid7d = None
    r1724h = None
    r177d = None


class _Cursor:
    def __init__(self, row):
        self._row = row

    def execute(self, _query: str) -> None:
        return None

    def fetchone(self):
        return self._row


class _Conn:
    def __init__(self, row):
        self._cursor = _Cursor(row)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def cursor(self):
        return self._cursor


def test_quality_returns_zeros_when_query_returns_no_row(monkeypatch) -> None:
    monkeypatch.setattr("dashboard.api.app.get_db_connection", lambda: _Conn(None))

    payload = get_quality()

    assert payload == {
        "expectedIntervals24h": 96,
        "observedIntervals24h": 0,
        "missingIntervals24h": 0,
        "kyzInvalidAlarm": {"last24h": 0, "last7d": 0},
        "r17Exclude": {"last24h": 0, "last7d": 0},
    }


def test_quality_handles_empty_aggregate_row(monkeypatch) -> None:
    monkeypatch.setattr("dashboard.api.app.get_db_connection", lambda: _Conn(_Row()))

    payload = get_quality()

    assert payload["expectedIntervals24h"] == 96
    assert payload["observedIntervals24h"] == 0
    assert payload["missingIntervals24h"] == 96
    assert payload["kyzInvalidAlarm"] == {"last24h": 0, "last7d": 0}
    assert payload["r17Exclude"] == {"last24h": 0, "last7d": 0}
