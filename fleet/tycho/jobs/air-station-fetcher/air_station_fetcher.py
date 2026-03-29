#!/usr/bin/env python3

import json
import logging
import os
import re
import sys
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from urllib import response


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

REQUEST_TIMEOUT_SECONDS = int(os.getenv("REQUEST_TIMEOUT_SECONDS", "30"))

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("air_station_fetcher")
timezone = ZoneInfo("Asia/Jerusalem")

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
    "Referer": "https://air.sviva.gov.il/",
}

API_HEADERS_BASE = {
    **BROWSER_HEADERS,
    "Accept": "application/json, text/plain, */*",
    "Origin": "https://air.sviva.gov.il",
    "Referer": "https://air.sviva.gov.il/",
    "X-Requested-With": "XMLHttpRequest",
}


def validate_config() -> None:
    if not MQTT_HOST:
        raise RuntimeError("MQTT_HOST is required")
    if not MQTT_TOPIC:
        raise RuntimeError("MQTT_TOPIC is required")


def fetch_homepage_html() -> str:
    response = SESSION.get(
        f"{BASE_URL}/",
        headers=HTML_HEADERS,
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    return response.text


def extract_cookie_token(html: str, cookie_name: str) -> str:
    pattern = rf'document\.cookie\s*=\s*"{re.escape(cookie_name)}=([^";]+)'
    matches = re.findall(pattern, html)

    for value in matches:
        value = value.strip()
        if value:
            return value

    raise RuntimeError(f"Could not extract non-empty cookie token: {cookie_name}")


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

    raise RuntimeError("Could not extract embedded ApiToken from homepage")


def prime_session_from_html(html: str) -> str:
    request_verification_token = extract_cookie_token(html, "__RequestVerificationToken")
    form_verification_token = extract_cookie_token(html, "__FormVerificationToken")

    SESSION.cookies.set(
        "__RequestVerificationToken",
        request_verification_token,
        domain="air.sviva.gov.il",
    )
    SESSION.cookies.set(
        "__FormVerificationToken",
        form_verification_token,
        domain="air.sviva.gov.il",
    )

    return form_verification_token


def build_average_params() -> dict:
    now = datetime.now(timezone)
    
    # floor to nearest 5-minute mark
    aligned = now - timedelta(
        minutes=now.minute % 5,
        seconds=now.second,
        microseconds=now.microsecond,
    )

    end = aligned
    start = end - timedelta(minutes=5)

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


def fetch_station_data(form_verification_token: str, api_token: str) -> dict:
    params=build_average_params()
    
    headers = {
        **API_HEADERS_BASE,
        "Authorization": f"ApiToken {api_token}",
        "x-RequestVerificationToken": form_verification_token,
    }

    response = SESSION.get(
        f"{API_BASE_URL}/v1/envista/stations/{STATION_ID}/Average",
        headers=headers,
        params=params,
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    logger.info("recieving response from station, status=%s", response.status_code)
    
    response.raise_for_status()
    
    if response.status_code == 204:
        logger.warning(
            "No data returned for station_id=%s, params=%s",
            STATION_ID,
            params,
        )
        return None
    
    return response.json()


def normalize(data: dict) -> dict:
    rows = data.get("data") or []
    if not rows:
        raise RuntimeError("No data rows returned from API")

    latest = rows[-1]

    result = {
        "station_id": STATION_ID,
        "timestamp": latest.get("datetime") or latest.get("time"),
        "available": True,
    }

    channels = latest.get("channels") or latest.get("measurements") or []
    for channel in channels:
        name = channel.get("name") or channel.get("parameterName")
        if not name:
            continue

        result[name] = {
            "value": channel.get("value"),
            "valid": channel.get("valid"),
            "status": channel.get("status"),
            "units": channel.get("units"),
        }

    return result

def normalize_unavailable() -> dict:
    return {
        "station_id": STATION_ID,
        "timestamp": datetime.now(timezone).isoformat(timespec="seconds"),
        "available": False,
        "reason": "no_data_available",
    }

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
        form_verification_token = prime_session_from_html(html)
        api_token = extract_api_token(html)
        logger.info("Fetching tokens... DONE")

        logger.info("Fetching station data...")
        raw = fetch_station_data(form_verification_token, api_token)
        
        if raw is not None:
            payload = normalize(raw)
            logger.info("station data: %s", payload)
            logger.info("Fetching station data... DONE")
            
        else:
            payload = normalize_unavailable()
            logger.info("Fetching station data... UNAVAILABLE")

        logger.info("Publishing to MQTT topic=%s", MQTT_TOPIC)
        publish_to_mqtt(payload)
        logger.info("Publishing to MQTT... DONE")

        logger.info("Fetching air station data... DONE")
        return 0
    except Exception:
        logger.exception("Fetching air station data... FAILED")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())