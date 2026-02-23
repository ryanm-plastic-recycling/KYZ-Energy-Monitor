import argparse
import os
import sys
import time
from typing import Any

import paho.mqtt.client as mqtt
from dotenv import load_dotenv


def main() -> int:
    load_dotenv()

    parser = argparse.ArgumentParser(description="Subscribe to an MQTT topic and print payloads")
    parser.add_argument("topic", help="MQTT topic to subscribe to")
    parser.add_argument("--host", default=os.getenv("MQTT_HOST"), help="MQTT host (defaults to MQTT_HOST)")
    parser.add_argument("--port", type=int, default=int(os.getenv("MQTT_PORT", "1883")), help="MQTT port")
    parser.add_argument("--client-id", default="kyz-mqtt-probe", help="MQTT client id")
    parser.add_argument("--qos", type=int, default=1, choices=[0, 1, 2], help="Subscription QoS")
    args = parser.parse_args()

    if not args.host:
        print("Error: MQTT host is required (set MQTT_HOST or pass --host)", file=sys.stderr)
        return 2

    username = os.getenv("MQTT_USERNAME")
    password = os.getenv("MQTT_PASSWORD")

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=args.client_id, clean_session=True)
    if username:
        client.username_pw_set(username, password)

    def on_connect(client: mqtt.Client, userdata: Any, flags: Any, reason_code: Any, properties: Any = None) -> None:
        if reason_code == 0:
            print(f"Connected to {args.host}:{args.port}; subscribing to {args.topic} qos={args.qos}")
            client.subscribe(args.topic, qos=args.qos)
        else:
            print(f"MQTT connect failed: reason={reason_code}", file=sys.stderr)

    def on_message(client: mqtt.Client, userdata: Any, msg: mqtt.MQTTMessage) -> None:
        payload = msg.payload.decode("utf-8", errors="replace")
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg.topic} qos={msg.qos} payload={payload}")

    client.on_connect = on_connect
    client.on_message = on_message

    client.connect(args.host, args.port, 30)
    print("Press Ctrl+C to exit")
    try:
        client.loop_forever()
    except KeyboardInterrupt:
        pass
    finally:
        client.disconnect()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
