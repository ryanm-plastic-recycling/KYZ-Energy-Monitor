from dashboard.api.app import resolve_dashboard_sql_credentials


def test_dashboard_uses_ro_credentials_when_both_set(monkeypatch) -> None:
    monkeypatch.setenv("SQL_USERNAME", "rw_user")
    monkeypatch.setenv("SQL_PASSWORD", "rw_pass")
    monkeypatch.setenv("SQL_RO_USERNAME", "ro_user")
    monkeypatch.setenv("SQL_RO_PASSWORD", "ro_pass")

    username, password, mode = resolve_dashboard_sql_credentials()

    assert username == "ro_user"
    assert password == "ro_pass"
    assert mode == "ro"


def test_dashboard_falls_back_to_rw_credentials(monkeypatch) -> None:
    monkeypatch.setenv("SQL_USERNAME", "rw_user")
    monkeypatch.setenv("SQL_PASSWORD", "rw_pass")
    monkeypatch.delenv("SQL_RO_USERNAME", raising=False)
    monkeypatch.delenv("SQL_RO_PASSWORD", raising=False)

    username, password, mode = resolve_dashboard_sql_credentials()

    assert username == "rw_user"
    assert password == "rw_pass"
    assert mode == "rw"


def test_dashboard_requires_both_ro_values(monkeypatch) -> None:
    monkeypatch.setenv("SQL_USERNAME", "rw_user")
    monkeypatch.setenv("SQL_PASSWORD", "rw_pass")
    monkeypatch.setenv("SQL_RO_USERNAME", "ro_user")
    monkeypatch.delenv("SQL_RO_PASSWORD", raising=False)

    username, password, mode = resolve_dashboard_sql_credentials()

    assert username == "rw_user"
    assert password == "rw_pass"
    assert mode == "rw"
