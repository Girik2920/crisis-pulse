"""
Crisis Pulse classifier Lambda.

Consumes incident records from Kinesis, derives a disaster type and severity score,
stores the classified event in DynamoDB and S3, and emits an EventBridge event for
high-level workflow fan-out.
"""

import base64
import hashlib
import json
import logging
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
s3 = boto3.client("s3")
events_client = boto3.client("events")

TABLE_NAME = os.environ["DYNAMODB_TABLE"]
S3_BUCKET = os.environ["S3_BUCKET"]
EVENT_BUS_NAME = os.environ["EVENT_BUS_NAME"]

table = dynamodb.Table(TABLE_NAME)

DISASTER_KEYWORDS = {
    "earthquake": ["earthquake", "seismic", "tremor", "quake", "magnitude", "richter"],
    "flood": ["flood", "flooding", "inundation", "storm surge", "flash flood"],
    "hurricane": ["hurricane", "typhoon", "cyclone", "tropical storm", "category"],
    "wildfire": ["wildfire", "fire", "blaze", "bushfire", "forest fire"],
    "tornado": ["tornado", "twister", "funnel cloud", "waterspout"],
    "tsunami": ["tsunami", "tidal wave"],
    "chemical": ["chemical", "hazmat", "spill", "toxic", "leak", "contamination"],
    "infrastructure": ["bridge", "collapse", "structural", "building collapse", "dam break"],
    "medical": ["outbreak", "epidemic", "pandemic", "mass casualty", "biological"],
}


def _score_from_value(value, thresholds):
    score = 10
    for threshold, scaled_score in thresholds:
        if float(value) >= threshold:
            score = scaled_score
    return score


SEVERITY_RULES = {
    "earthquake": lambda payload: _score_from_value(
        payload.get("magnitude", 0),
        [(3, 10), (5, 40), (6, 65), (7, 85), (8, 100)],
    ),
    "hurricane": lambda payload: _score_from_value(
        payload.get("category", 0),
        [(1, 20), (2, 40), (3, 60), (4, 80), (5, 100)],
    ),
    "flood": lambda payload: _score_from_value(
        payload.get("level_meters", 0),
        [(0.5, 20), (1, 40), (2, 60), (3, 80), (5, 95)],
    ),
    "wildfire": lambda payload: _score_from_value(
        payload.get("acres_burned", 0),
        [(100, 20), (1000, 40), (10000, 65), (50000, 85), (100000, 95)],
    ),
}


def classify_event(raw_signal):
    description = f"{raw_signal.get('description', '')} {raw_signal.get('type', '')}".lower()
    disaster_type = raw_signal.get("type", "unknown")

    if disaster_type == "unknown":
        for candidate, keywords in DISASTER_KEYWORDS.items():
            if any(keyword in description for keyword in keywords):
                disaster_type = candidate
                break

    scorer = SEVERITY_RULES.get(disaster_type)
    score = scorer(raw_signal) if scorer else int(raw_signal.get("severity_score", 50))
    score = max(0, min(100, score))

    if score >= 80:
        severity = "critical"
    elif score >= 60:
        severity = "high"
    elif score >= 35:
        severity = "medium"
    else:
        severity = "low"

    return {
        "disaster_type": disaster_type,
        "severity": severity,
        "severity_score": score,
    }


def build_event_id(raw_signal):
    if "event_id" in raw_signal:
        return raw_signal["event_id"]

    seed = (
        f"{raw_signal.get('source', '')}"
        f"{raw_signal.get('timestamp', '')}"
        f"{json.dumps(raw_signal.get('location', {}), sort_keys=True)}"
        f"{raw_signal.get('description', '')}"
    )
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()[:16]


def is_duplicate(event_id):
    response = table.query(
        KeyConditionExpression=Key("event_id").eq(event_id),
        Limit=1,
    )
    return bool(response.get("Items"))


def persist_to_dynamodb(event):
    ttl_seconds = 30 * 24 * 60 * 60
    ttl = int(datetime.now(timezone.utc).timestamp()) + ttl_seconds

    item = {
        "event_id": event["event_id"],
        "timestamp": event["timestamp"],
        "disaster_type": event["disaster_type"],
        "severity": event["severity"],
        "severity_score": Decimal(str(event["severity_score"])),
        "location": event.get("location", {}),
        "source": event.get("source", "unknown"),
        "raw": json.dumps(event.get("raw_signal", {})),
        "ttl": ttl,
    }
    table.put_item(Item=item)


def archive_to_s3(event):
    now = datetime.now(timezone.utc)
    key = f"events/{now.year}/{now.month:02d}/{now.day:02d}/{event['event_id']}.json"
    s3.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=json.dumps(event, default=str),
        ContentType="application/json",
    )


def emit_event(event):
    events_client.put_events(
        Entries=[
            {
                "Source": "crisis-pulse.classifier",
                "DetailType": "IncidentClassified",
                "Detail": json.dumps(
                    {
                        "event_id": event["event_id"],
                        "disaster_type": event["disaster_type"],
                        "severity": event["severity"],
                        "severity_score": event["severity_score"],
                        "location": event.get("location", {}),
                        "timestamp": event["timestamp"],
                    }
                ),
                "EventBusName": EVENT_BUS_NAME,
            }
        ]
    )


def process_record(raw_signal):
    event_id = build_event_id(raw_signal)
    if is_duplicate(event_id):
        logger.info("Skipping duplicate event %s", event_id)
        return {"status": "duplicate", "event_id": event_id}

    classification = classify_event(raw_signal)
    timestamp = raw_signal.get("timestamp", datetime.now(timezone.utc).isoformat())

    event = {
        "event_id": event_id,
        "timestamp": timestamp,
        "source": raw_signal.get("source", "unknown"),
        "location": raw_signal.get("location", {}),
        "raw_signal": raw_signal,
        **classification,
    }

    persist_to_dynamodb(event)
    archive_to_s3(event)
    emit_event(event)
    logger.info("Processed event %s", event_id)
    return {"status": "processed", "event_id": event_id, **classification}


def decode_record(record):
    if "kinesis" in record:
        return json.loads(base64.b64decode(record["kinesis"]["data"]).decode("utf-8"))
    return json.loads(record["body"])


def lambda_handler(event, context):
    del context
    results = []
    records = event.get("Records", [])
    logger.info("Processing %s records", len(records))

    for record in records:
        try:
            results.append(process_record(decode_record(record)))
        except Exception as exc:  # pragma: no cover - Lambda runtime path
            logger.error("Failed to process record: %s", exc, exc_info=True)
            results.append({"status": "error", "error": str(exc)})

    return {
        "processed": sum(1 for item in results if item["status"] == "processed"),
        "duplicates": sum(1 for item in results if item["status"] == "duplicate"),
        "errors": sum(1 for item in results if item["status"] == "error"),
    }
