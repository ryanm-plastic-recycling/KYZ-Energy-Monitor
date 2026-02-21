# Mosquitto Setup (Windows)

This setup is for broker-side hardening used by `main.py` subscriber topic `pri/energy/kyz/interval`.

## Install

1. Install Mosquitto for Windows.
2. Install as a Windows service.

## Recommended baseline config (`mosquitto.conf`)

```conf
persistence true
persistence_location C:/mosquitto/data/
log_dest file C:/mosquitto/log/mosquitto.log

listener 1883
allow_anonymous false
password_file C:/mosquitto/config/passwd

# Optional TLS listener
# listener 8883
# cafile C:/mosquitto/certs/ca.crt
# certfile C:/mosquitto/certs/server.crt
# keyfile C:/mosquitto/certs/server.key
# require_certificate false
```

## Create credentials

```powershell
cd 'C:\Program Files\mosquitto'
.\mosquitto_passwd.exe -c C:\mosquitto\config\passwd kyz_ingestor
```

Use created username/password in `.env`:
- `MQTT_USERNAME`
- `MQTT_PASSWORD`

## Connectivity tests

Publish test message:

```powershell
mosquitto_pub -h <broker> -p 1883 -u <user> -P <pass> -t pri/energy/kyz/interval -m "{\"intervalEnd\":\"2026-01-31 14:15:00\",\"pulseCount\":1,\"kWh\":0.25,\"kW\":1.00}"
```

Ingestor-side test:

```powershell
cd C:\apps\kyz-energy-monitor
.\.venv\Scripts\python.exe main.py --test-conn
```

## Hardening checklist

- Disable anonymous access (`allow_anonymous false`)
- Use strong per-client credentials
- Restrict inbound firewall to plant network only
- Prefer TLS (`8883`) if certificates are available
- Back up `mosquitto.conf`, password file, and broker logs
