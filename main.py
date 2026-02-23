import argparse
import json
import logging
from logging.handlers import TimedRotatingFileHandler
import os
import signal
import sys
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import paho.mqtt.client as mqtt
import pyodbc
from dotenv import load_dotenv


TOPIC = "pri/energy/kyz/interval"


class ConfigError(Exception):
    """Raised when required configuration is missing."""


def configure_logging() -> logging.Logger:
    logs_dir = Path("logs")
    logs_dir.mkdir(parents=True, exist_ok=True)

    logger = logging.getLogger("kyz_ingestor")
    logger.setLevel(logging.INFO)

    formatter = logging.Formatter(
        "%(asctime)s %(levelname)s [%(threadName)s] %(name)s - %(message)s"
    )

    file_handler = TimedRotatingFileHandler(
        logs_dir / "kyz_ingestor.log",
        when="midnight",
        interval=1,
        backupCount=30,
        encoding="utf-8",
    )
    file_handler.setFormatter(formatter)

    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(formatter)

    logger.handlers.clear()
    logger.addHandler(file_handler)
    logger.addHandler(console_handler)

    return logger


def get_required_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise ConfigError(f"Missing required environment variable: {name}")
    return value


def get_sql_connection_string() -> str:
    return (
        "DRIVER={ODBC Driver 18 for SQL Server};"
        f"SERVER={get_required_env('SQL_SERVER')};"
        f"DATABASE={get_required_env('SQL_DATABASE')};"
        f"UID={get_required_env('SQL_USERNAME')};"
        f"PWD={get_required_env('SQL_PASSWORD')};"
        "Encrypt=yes;"
        "TrustServerCertificate=no;"
        "Connection Timeout=15;"
    )


def get_env_int(name: str, default: int | None = None) -> int:
    raw = os.getenv(name)
    if raw in (None, ""):
        if default is None:
            raise ConfigError(f"Missing required environment variable: {name}")
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise ConfigError(f"Invalid integer for {name}: {raw}") from exc


def get_env_float(name: str, default: float | None = None) -> float:
    raw = os.getenv(name)
    if raw in (None, ""):
        if default is None:
            raise ConfigError(f"Missing required environment variable: {name}")
        return default
    try:
        return float(raw)
    except ValueError as exc:
        raise ConfigError(f"Invalid float for {name}: {raw}") from exc


def parse_interval_end(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("intervalEnd must be a string in format YYYY-MM-DD HH:MM:SS")
    return datetime.strptime(value, "%Y-%m-%d %H:%M:%S")


def validate_payload(payload: dict[str, Any]) -> dict[str, Any]:
    required_fields = ["intervalEnd", "pulseCount", "kWh", "kW"]
    for field in required_fields:
        if field not in payload:
            raise ValueError(f"Missing required payload field: {field}")

    interval_end = parse_interval_end(payload["intervalEnd"])

    if not isinstance(payload["pulseCount"], int):
        raise ValueError("pulseCount must be an integer")

    for numeric_field in ["kWh", "kW"]:
        if not isinstance(payload[numeric_field], (int, float)):
            raise ValueError(f"{numeric_field} must be numeric")

    total_kwh = payload.get("total_kWh")
    if total_kwh is not None and not isinstance(total_kwh, (int, float)):
        raise ValueError("total_kWh must be numeric when provided")

    r17_exclude = payload.get("r17Exclude")
    if r17_exclude is not None and not isinstance(r17_exclude, bool):
        raise ValueError("r17Exclude must be boolean when provided")

    kyz_invalid_alarm = payload.get("kyzInvalidAlarm")
    if kyz_invalid_alarm is not None and not isinstance(kyz_invalid_alarm, bool):
        raise ValueError("kyzInvalidAlarm must be boolean when provided")

    return {
        "intervalEnd": interval_end,
        "pulseCount": payload["pulseCount"],
        "kWh": float(payload["kWh"]),
        "kW": float(payload["kW"]),
        "total_kWh": float(total_kwh) if total_kwh is not None else None,
        "r17Exclude": r17_exclude,
        "kyzInvalidAlarm": kyz_invalid_alarm,
    }


def _parse_int_field(payload: dict[str, Any], *field_names: str, required: bool = True) -> int | None:
    for name in field_names:
        if name in payload:
            value = payload[name]
            if isinstance(value, bool):
                raise ValueError(f"{name} must be an integer")
            if isinstance(value, int):
                return value
            if isinstance(value, str) and value.strip() and value.strip().lstrip("-").isdigit():
                return int(value.strip())
            raise ValueError(f"{name} must be an integer")
    if required:
        raise ValueError(f"Missing required payload field: {field_names[0]}")
    return None


def parse_minimal_kv_payload(raw_payload: str) -> tuple[int, int | None]:
    tokens = [part.strip() for part in raw_payload.split(",") if part.strip()]
    if not tokens:
        raise ValueError("Empty key/value payload")

    parsed: dict[str, str] = {}
    for index, token in enumerate(tokens):
        if "=" in token:
            key, value = token.split("=", 1)
            parsed[key.strip()] = value.strip()
            continue

        if index == 1 and "d" in parsed and token.lstrip("-").isdigit():
            parsed["t"] = token
            continue

        raise ValueError("Unsupported key/value payload format")

    delta = _parse_int_field(parsed, "d", "pulseDelta")
    total = _parse_int_field(parsed, "t", "pulseTotal", required=False)
    return delta, total


def derive_interval_end(now: datetime, interval_minutes: int, grace_seconds: int) -> datetime:
    interval_seconds = interval_minutes * 60
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    elapsed = int((now - midnight).total_seconds())
    floor_elapsed = (elapsed // interval_seconds) * interval_seconds
    floor_boundary = midnight + timedelta(seconds=floor_elapsed)
    delta_from_floor = elapsed - floor_elapsed
    if delta_from_floor <= grace_seconds:
        return floor_boundary
    return floor_boundary + timedelta(seconds=interval_seconds)


def build_interval_from_minimal(
    pulse_delta: int,
    pulse_total: int | None,
    pulses_per_kwh: float,
    interval_minutes: int,
    grace_seconds: int,
) -> dict[str, Any]:
    if pulses_per_kwh <= 0:
        raise ConfigError("KYZ_PULSES_PER_KWH must be greater than zero")
    if interval_minutes <= 0:
        raise ConfigError("KYZ_INTERVAL_MINUTES must be greater than zero")
    if grace_seconds < 0:
        raise ConfigError("KYZ_INTERVAL_GRACE_SECONDS must be zero or greater")

    interval_end = derive_interval_end(datetime.now(), interval_minutes, grace_seconds)
    kwh = pulse_delta / pulses_per_kwh
    kw = kwh * (60.0 / interval_minutes)
    total_kwh = (pulse_total / pulses_per_kwh) if pulse_total is not None else None

    return {
        "intervalEnd": interval_end,
        "pulseCount": pulse_delta,
        "kWh": float(kwh),
        "kW": float(kw),
        "total_kWh": float(total_kwh) if total_kwh is not None else None,
        "r17Exclude": None,
        "kyzInvalidAlarm": None,
    }


def is_transient_sql_error(exc: pyodbc.Error) -> bool:
    sql_state = ""
    if getattr(exc, "args", None):
        sql_state = str(exc.args[0])
    transient_prefixes = ("08", "40", "HYT")
    return sql_state.startswith(transient_prefixes)


class IntervalIngestor:
    def __init__(self, logger: logging.Logger):
        self.logger = logger
        self.conn_str = get_sql_connection_string()
        self.conn: pyodbc.Connection | None = None
        self.lock = threading.Lock()
        self._connect_with_backoff()

    def _connect_with_backoff(self) -> None:
        attempt = 0
        max_delay = 60
        while self.conn is None:
            attempt += 1
            try:
                self.conn = pyodbc.connect(self.conn_str, autocommit=False)
                self.logger.info("SQL connection established")
            except pyodbc.Error:
                delay = min(2 ** min(attempt, 6), max_delay)
                self.logger.exception("SQL connection failed (attempt %s). Retrying in %ss", attempt, delay)
                time.sleep(delay)

    def _ensure_connection(self) -> pyodbc.Connection:
        if self.conn is None:
            self._connect_with_backoff()
        assert self.conn is not None
        try:
            cursor = self.conn.cursor()
            cursor.execute("SELECT 1")
            cursor.fetchone()
            cursor.close()
            return self.conn
        except pyodbc.Error:
            self.logger.exception("SQL connection lost; reconnecting")
            try:
                self.conn.close()
            except Exception:
                pass
            self.conn = None
            self._connect_with_backoff()
            assert self.conn is not None
            return self.conn

    def close(self) -> None:
        if self.conn is not None:
            self.conn.close()
            self.conn = None

    def insert_interval(self, data: dict[str, Any]) -> None:
        sql = """
            INSERT INTO dbo.KYZ_Interval (
                IntervalEnd,
                PulseCount,
                kWh,
                kW,
                Total_kWh,
                R17Exclude,
                KyzInvalidAlarm
            )
            SELECT ?, ?, ?, ?, ?, ?, ?
            WHERE NOT EXISTS (
                SELECT 1
                FROM dbo.KYZ_Interval WITH (UPDLOCK, HOLDLOCK)
                WHERE IntervalEnd = ?
            )
        """

        params = (
            data["intervalEnd"],
            data["pulseCount"],
            data["kWh"],
            data["kW"],
            data["total_kWh"],
            None if data["r17Exclude"] is None else (1 if data["r17Exclude"] else 0),
            None if data["kyzInvalidAlarm"] is None else (1 if data["kyzInvalidAlarm"] else 0),
            data["intervalEnd"],
        )

        with self.lock:
            for attempt in range(1, 4):
                conn = self._ensure_connection()
                cursor = conn.cursor()
                try:
                    cursor.execute(sql, params)
                    inserted = cursor.rowcount
                    conn.commit()
                    if inserted == 0:
                        self.logger.info("Skipped duplicate intervalEnd=%s", data["intervalEnd"])
                    else:
                        self.logger.info("Inserted intervalEnd=%s", data["intervalEnd"])
                    return
                except pyodbc.Error as exc:
                    conn.rollback()
                    if is_transient_sql_error(exc) and attempt < 3:
                        self.logger.warning(
                            "Transient SQL write failure for intervalEnd=%s (attempt %s). Reconnecting.",
                            data["intervalEnd"],
                            attempt,
                        )
                        try:
                            conn.close()
                        except Exception:
                            pass
                        self.conn = None
                        time.sleep(attempt)
                        continue
                    raise
                finally:
                    cursor.close()


class MqttSqlService:
    def __init__(self, logger: logging.Logger, ingestor: IntervalIngestor):
        self.logger = logger
        self.ingestor = ingestor
        self.stop_event = threading.Event()

        self.mqtt_host = get_required_env("MQTT_HOST")
        self.mqtt_port = int(os.getenv("MQTT_PORT", "1883"))
        self.mqtt_username = os.getenv("MQTT_USERNAME")
        self.mqtt_password = os.getenv("MQTT_PASSWORD")
        self.mqtt_client_id = os.getenv("MQTT_CLIENT_ID", "kyz-sql-ingestor")
        self.mqtt_keepalive = int(os.getenv("MQTT_KEEPALIVE", "60"))
        self.kyz_interval_minutes = get_env_int("KYZ_INTERVAL_MINUTES", default=15)
        self.kyz_interval_grace_seconds = get_env_int("KYZ_INTERVAL_GRACE_SECONDS", default=30)

        self.client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=self.mqtt_client_id,
            clean_session=True,
        )
        self.client.reconnect_delay_set(min_delay=1, max_delay=60)

        if self.mqtt_username:
            self.client.username_pw_set(self.mqtt_username, self.mqtt_password)

        self.client.on_connect = self.on_connect
        self.client.on_disconnect = self.on_disconnect
        self.client.on_message = self.on_message

    def on_connect(self, client: mqtt.Client, userdata: Any, flags: Any, reason_code: Any, properties: Any = None) -> None:
        if reason_code == 0:
            self.logger.info("Connected to MQTT broker at %s:%s", self.mqtt_host, self.mqtt_port)
            client.subscribe(TOPIC, qos=1)
            self.logger.info("Subscribed to topic %s", TOPIC)
        else:
            self.logger.error("Failed MQTT connect with reason code: %s", reason_code)

    def on_disconnect(self, client: mqtt.Client, userdata: Any, disconnect_flags: Any, reason_code: Any, properties: Any = None) -> None:
        self.logger.warning("MQTT disconnected (reason=%s)", reason_code)

    def on_message(self, client: mqtt.Client, userdata: Any, msg: mqtt.MQTTMessage) -> None:
        raw_payload = msg.payload.decode("utf-8", errors="replace")
        payload_preview = raw_payload[:300]
        try:
            payload = json.loads(raw_payload)
            if not isinstance(payload, dict):
                raise ValueError("JSON payload must be an object")

            if all(field in payload for field in ["intervalEnd", "pulseCount", "kWh", "kW"]):
                data = validate_payload(payload)
            else:
                pulse_delta = _parse_int_field(payload, "d", "pulseDelta")
                pulse_total = _parse_int_field(payload, "t", "pulseTotal", required=False)
                pulses_per_kwh = get_env_float("KYZ_PULSES_PER_KWH")
                data = build_interval_from_minimal(
                    pulse_delta,
                    pulse_total,
                    pulses_per_kwh,
                    self.kyz_interval_minutes,
                    self.kyz_interval_grace_seconds,
                )
            self.ingestor.insert_interval(data)
        except json.JSONDecodeError:
            try:
                pulse_delta, pulse_total = parse_minimal_kv_payload(raw_payload)
                pulses_per_kwh = get_env_float("KYZ_PULSES_PER_KWH")
                data = build_interval_from_minimal(
                    pulse_delta,
                    pulse_total,
                    pulses_per_kwh,
                    self.kyz_interval_minutes,
                    self.kyz_interval_grace_seconds,
                )
                self.ingestor.insert_interval(data)
            except Exception:
                self.logger.exception(
                    "Invalid MQTT payload on topic %s raw=%r",
                    msg.topic,
                    payload_preview,
                )
        except Exception:
            self.logger.exception(
                "Failed to process MQTT payload on topic %s raw=%r",
                msg.topic,
                payload_preview,
            )

    def _connect_mqtt_with_backoff(self) -> None:
        delay = 1
        while not self.stop_event.is_set():
            try:
                self.client.connect(self.mqtt_host, self.mqtt_port, self.mqtt_keepalive)
                return
            except Exception:
                self.logger.exception("MQTT connect failed, retrying in %ss", delay)
                time.sleep(delay)
                delay = min(delay * 2, 60)

    def run(self) -> None:
        self.logger.info("Starting MQTT SQL service")
        self._connect_mqtt_with_backoff()
        self.client.loop_start()

        while not self.stop_event.is_set():
            time.sleep(0.2)

        self.client.loop_stop()
        self.client.disconnect()
        self.ingestor.close()
        self.logger.info("Service stopped")

    def stop(self) -> None:
        self.stop_event.set()


class MqttConnectivityProbe:
    def __init__(self, logger: logging.Logger):
        self.logger = logger
        self.connected = threading.Event()
        self.failed = threading.Event()

        self.mqtt_host = get_required_env("MQTT_HOST")
        self.mqtt_port = int(os.getenv("MQTT_PORT", "1883"))
        self.mqtt_username = os.getenv("MQTT_USERNAME")
        self.mqtt_password = os.getenv("MQTT_PASSWORD")

        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="kyz-sql-ingestor-test")
        if self.mqtt_username:
            self.client.username_pw_set(self.mqtt_username, self.mqtt_password)
        self.client.on_connect = self.on_connect

    def on_connect(self, client: mqtt.Client, userdata: Any, flags: Any, reason_code: Any, properties: Any = None) -> None:
        if reason_code == 0:
            self.logger.info("MQTT connectivity OK")
            self.connected.set()
        else:
            self.logger.error("MQTT connectivity failed, reason code: %s", reason_code)
            self.failed.set()

    def run(self, timeout_seconds: int = 10) -> bool:
        try:
            self.client.connect(self.mqtt_host, self.mqtt_port, 30)
            self.client.loop_start()
            deadline = time.time() + timeout_seconds
            while time.time() < deadline:
                if self.connected.is_set():
                    return True
                if self.failed.is_set():
                    return False
                time.sleep(0.2)
            self.logger.error("MQTT connectivity timed out")
            return False
        except Exception:
            self.logger.exception("MQTT connectivity probe error")
            return False
        finally:
            self.client.loop_stop()
            self.client.disconnect()


def test_connectivity(logger: logging.Logger) -> int:
    logger.info("Running connectivity tests")

    sql_ok = False

    try:
        conn = pyodbc.connect(get_sql_connection_string(), autocommit=True)
        cursor = conn.cursor()
        cursor.execute("SELECT 1")
        cursor.fetchone()
        cursor.close()
        conn.close()
        sql_ok = True
        logger.info("SQL connectivity OK")
    except Exception:
        logger.exception("SQL connectivity failed")

    mqtt_ok = MqttConnectivityProbe(logger).run()

    if sql_ok and mqtt_ok:
        logger.info("Connectivity test passed")
        return 0

    logger.error("Connectivity test failed")
    return 1


def main() -> int:
    load_dotenv()
    logger = configure_logging()

    parser = argparse.ArgumentParser(description="Subscribe to KYZ interval MQTT and ingest into Azure SQL")
    parser.add_argument("--test-conn", action="store_true", help="Test MQTT and SQL connectivity then exit")
    args = parser.parse_args()

    try:
        if args.test_conn:
            return test_connectivity(logger)

        ingestor = IntervalIngestor(logger)
        service = MqttSqlService(logger, ingestor)

        def _shutdown_handler(signum: int, frame: Any) -> None:
            logger.info("Received signal %s, shutting down", signum)
            service.stop()

        signal.signal(signal.SIGINT, _shutdown_handler)
        signal.signal(signal.SIGTERM, _shutdown_handler)

        service.run()
        return 0
    except ConfigError:
        logger.exception("Configuration error")
        return 2
    except Exception:
        logger.exception("Fatal error")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
