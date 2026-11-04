
#!/usr/bin/env python3

import json
import logging
import math
import os
import re
import sys
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import paho.mqtt.publish as mqtt_publish
import requests


BASE_URL = "https://air.sviva.gov.il"
API_BASE_URL = "https://air-papi.sviva.gov.il"

STATION_ID = int(os.getenv("STATION_ID", "567"))
FILTER_CHANNELS = os.getenv("FILTER_CHANNELS", "9,1,3,2,4,5,10")

MQTT_HOST = os.getenv("MQTT_HOST", "").strip()
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_TOPIC = os.getenv("MQTT_TOPIC", "").strip()
MQTT_USERNAME = os.getenv("MQTT_USERNAME", "").strip()
MQTT_PASSWORD = os.getenv("MQTT_PASSWORD", "").strip()

REQUEST_TIMEOUT_SECONDS = int(
    os.getenv("REQUEST_TIMEOUT_SECONDS", "30")
)
LOOKBACK_MINUTES = int(os.getenv("LOOKBACK_MINUTES", "60"))

TIMEZONE = ZoneInfo("Asia/Jerusalem")

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("air_station_fetcher")

SESSION = requests.Session()

BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (X11; Linux x86_64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/145.0.0.0 Safari/537.36"
    ),
    "Accept-Language": "he-IL,he;q=0.9,en-US;q=0.8,en;q=0.7",
}

HTML_HEADERS = {
    **BROWSER_HEADERS,
    "Accept": (
        "text/html,application/xhtml+xml,application/xml;q=0.9,"
        "image/avif,image/webp,image/apng,*/*;q=0.8"
    ),
    "Referer": f"{BASE_URL}/",
}

API_HEADERS_BASE = {
    **BROWSER_HEADERS,
    "Accept": "application/json, text/plain, */*",
    "Origin": BASE_URL,
    "Referer": f"{BASE_URL}/",
    "X-Requested-With": "XMLHttpRequest",
}


def validate_config() -> None:
    if not MQTT_HOST:
        raise RuntimeError("MQTT_HOST is required")

    if not MQTT_TOPIC:
        raise RuntimeError("MQTT_TOPIC is required")

    if LOOKBACK_MINUTES <= 0:
        raise RuntimeError("LOOKBACK_MINUTES must be positive")


def fetch_homepage_html() -> str:
    response = SESSION.get(
        f"{BASE_URL}/",
        headers=HTML_HEADERS,
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    return response.text


def extract_cookie_token(html: str, cookie_name: str) -> str:
    pattern = (
        rf'document\.cookie\s*=\s*"'
        rf'{re.escape(cookie_name)}=([^";]+)'
    )

    matches = re.findall(pattern, html)

    for value in matches:
        value = value.strip()
        if value:
            return value

    raise RuntimeError(
        f"Could not extract non-empty cookie token: {cookie_name}"
    )


def extract_api_token(html: str) -> str:
    patterns = [
        r'"Authorization"\s*:\s*\'ApiToken\s+([^\']+)\'',
        r'"Authorization"\s*:\s*"ApiToken\s+([^"]+)"',
        r'Authorization\s*:\s*\'ApiToken\s+([^\']+)\'',
        r'Authorization\s*:\s*"ApiToken\s+([^"]+)"',
    ]

    for pattern in patterns:
        match = re.search(pattern, html)

        if match:
            token = match.group(1).strip()
            if token:
                return token

    raise RuntimeError(
        "Could not extract embedded ApiToken from homepage"
    )


def prime_session_from_html(html: str) -> str:
    request_token = extract_cookie_token(
        html, "__RequestVerificationToken"
    )
    form_token = extract_cookie_token(
        html, "__FormVerificationToken"
    )

    SESSION.cookies.set(
        "__RequestVerificationToken",
        request_token,
        domain="air.sviva.gov.il",
    )
    SESSION.cookies.set(
        "__FormVerificationToken",
        form_token,
        domain="air.sviva.gov.il",
    )

    return form_token


def build_average_params() -> dict:
    now = datetime.now(TIMEZONE)

    # Align to the nearest previous five-minute interval.
    end = now - timedelta(
        minutes=now.minute % 5,
        seconds=now.second,
        microseconds=now.microsecond,
    )

    start = end - timedelta(minutes=LOOKBACK_MINUTES)

    return {
        "filterChannels": FILTER_CHANNELS,
        "from": start.isoformat(timespec="seconds"),
        "to": end.isoformat(timespec="seconds"),
        "fromTimebase": 5,
        "toTimebase": 5,
        "precentValid": 75,
        "timeBeginning": "false",
        "useBackWard": "true",
        "roundType": 0,
        "unitConversion": "true",
        "includeSummary": "false",
        "onlySummary": "false",
    }


def fetch_station_data(
    form_verification_token: str,
    api_token: str,
) -> dict | None:
    params = build_average_params()

    headers = {
        **API_HEADERS_BASE,
        "Authorization": f"ApiToken {api_token}",
        "x-RequestVerificationToken": form_verification_token,
    }

    logger.info(
        "Requesting station %s measurements from %s to %s",
        STATION_ID,
        params["from"],
        params["to"],
    )

    response = SESSION.get(
        f"{API_BASE_URL}/v1/envista/stations/{STATION_ID}/Average",
        headers=headers,
        params=params,
        timeout=REQUEST_TIMEOUT_SECONDS,
    )

    logger.info(
        "Station response status=%s",
        response.status_code,
    )

    response.raise_for_status()

    if response.status_code == 204:
        logger.warning(
            "Station %s returned no measurements (HTTP 204)",
            STATION_ID,
        )
        return None

    return response.json()


def normalize(data: dict) -> dict | None:
    rows = data.get("data") or []

    if not rows:
        logger.warning("API returned no measurement rows")
        return None

    # Sort by timestamp instead of assuming API row order.
    rows = sorted(
        rows,
        key=lambda row: row.get("datetime") or row.get("time") or "",
        reverse=True,
    )

    result = {
        "station_id": STATION_ID,
        "available": True,
    }

    seen = set()
    latest_timestamp = None

    for row in rows:
        timestamp = row.get("datetime") or row.get("time")

        channels = (
            row.get("channels")
            or row.get("measurements")
            or []
        )

        for channel in channels:
            name = (
                channel.get("name")
                or channel.get("parameterName")
            )

            value = channel.get("value")

            if not name or name in seen:
                continue

            # Only accept valid numeric measurements.
            if channel.get("valid") is not True:
                continue

            if isinstance(value, bool):
                continue

            if not isinstance(value, (int, float)):
                continue

            if not math.isfinite(value) or value < 0:
                continue

            seen.add(name)

            result[name] = {
                "value": value,
                "valid": True,
                "status": channel.get("status"),
                "units": channel.get("units"),
            }

            if timestamp and (
                latest_timestamp is None
                or timestamp > latest_timestamp
            ):
                latest_timestamp = timestamp

    if not seen:
        logger.warning(
            "No valid channel measurements found in %s rows",
            len(rows),
        )
        return None

    result["timestamp"] = latest_timestamp

    if latest_timestamp:
        measurement_time = datetime.fromisoformat(
            latest_timestamp.replace("Z", "+00:00")
        )
        if measurement_time.tzinfo is None:
            measurement_time = measurement_time.replace(
                tzinfo=TIMEZONE
            )

        age = datetime.now(TIMEZONE) - measurement_time
        age_minutes = age.total_seconds() / 60

        logger.info(
            "Latest measurement timestamp=%s, age=%.1f minutes",
            latest_timestamp,
            age_minutes,
        )

    logger.info(
        "Normalized %s valid channels from %s rows",
        len(seen),
        len(rows),
    )

    return result


def publish_to_mqtt(payload: dict) -> None:
    auth = None

    if MQTT_USERNAME:
        auth = {
            "username": MQTT_USERNAME,
            "password": MQTT_PASSWORD,
        }

    mqtt_publish.single(
        topic=MQTT_TOPIC,
        payload=json.dumps(payload, ensure_ascii=False),
        hostname=MQTT_HOST,
        port=MQTT_PORT,
        auth=auth,
        retain=True,
    )


def main() -> int:
    logger.info("Fetching air station data...")

    try:
        validate_config()

        logger.info("Fetching tokens...")
        html = fetch_homepage_html()
        form_token = prime_session_from_html(html)
        api_token = extract_api_token(html)
        logger.info("Fetching tokens... DONE")

        logger.info("Fetching station data...")
        raw = fetch_station_data(form_token, api_token)

        payload = normalize(raw) if raw is not None else None

        if payload is None:
            # Keep the last retained MQTT measurement.
            # Do not overwrite numeric HA entities with missing values.
            logger.warning(
                "No valid measurements; preserving retained MQTT data"
            )
            return 0

        logger.info("Station data: %s", payload)

        logger.info(
            "Publishing to MQTT topic=%s",
            MQTT_TOPIC,
        )
        publish_to_mqtt(payload)

        logger.info("Publishing to MQTT... DONE")
        logger.info("Fetching air station data... DONE")

        return 0

    except Exception:
        logger.exception("Fetching air station data... FAILED")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
