"""
Crisis Pulse API Lambda.

Exposes:
- GET /events for geo-filtered reads
- POST /ingest for incident ingestion
"""

import base64
import json
import logging
import math
import os
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Attr

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
kinesis = boto3.client("kinesis")

TABLE_NAME = os.environ["DYNAMODB_TABLE"]
KINESIS_STREAM = os.environ["KINESIS_STREAM"]

table = dynamodb.Table(TABLE_NAME)


def haversine_km(lat1, lon1, lat2, lon2):
    radius_km = 6371.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_phi = math.radians(lat2 - lat1)
    delta_lambda = math.radians(lon2 - lon1)
    a = (
        math.sin(delta_phi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda / 2) ** 2
    )
    return radius_km * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body, default=str),
    }


def require_float(params, key):
    raw_value = params.get(key)
    if raw_value is None:
        raise ValueError(f"Missing required query parameter: {key}")
    return float(raw_value)


def handle_get_events(params):
    lat = require_float(params, "lat")
    lon = require_float(params, "lon")
    radius_km = float(params.get("radius", 100))
    severity_filter = params.get("severity")
    limit = min(int(params.get("limit", 50)), 200)

    filter_expression = Attr("event_id").exists()
    if severity_filter:
        filter_expression = filter_expression & Attr("severity").eq(severity_filter)

    items = table.scan(FilterExpression=filter_expression, Limit=500).get("Items", [])
    results = []

    for item in items:
        location = item.get("location", {})
        if "lat" not in location or "lon" not in location:
            continue

        distance_km = haversine_km(lat, lon, float(location["lat"]), float(location["lon"]))
        if distance_km > radius_km:
            continue

        item["distance_km"] = round(distance_km, 2)
        item["severity_score"] = float(item.get("severity_score", 0))
        item.pop("raw", None)
        results.append(item)

    results.sort(key=lambda item: (-float(item.get("severity_score", 0)), item.get("timestamp", "")))
    return {
        "events": results[:limit],
        "count": min(len(results), limit),
        "query": {
            "lat": lat,
            "lon": lon,
            "radius_km": radius_km,
            "severity": severity_filter,
        },
    }


def handle_post_ingest(body):
    missing = [field for field in ("type", "location") if field not in body]
    if missing:
        return None, {"error": f"Missing required fields: {', '.join(missing)}"}

    location = body.get("location", {})
    if "lat" not in location or "lon" not in location:
        return None, {"error": "location must include lat and lon"}

    if "timestamp" not in body:
        body["timestamp"] = datetime.now(timezone.utc).isoformat()

    kinesis.put_record(
        StreamName=KINESIS_STREAM,
        Data=json.dumps(body).encode("utf-8"),
        PartitionKey=f"{location['lat']},{location['lon']}",
    )
    return {"status": "ingested", "message": "Incident signal accepted for processing"}, None


def lambda_handler(event, context):
    del context
    request = event.get("requestContext", {}).get("http", {})
    method = request.get("method", "GET")
    path = request.get("path", "/")
    params = event.get("queryStringParameters") or {}

    try:
        if method == "GET" and path == "/events":
            return response(200, handle_get_events(params))

        if method == "POST" and path == "/ingest":
            raw_body = event.get("body", "{}")
            if event.get("isBase64Encoded"):
                raw_body = base64.b64decode(raw_body).decode("utf-8")

            result, error = handle_post_ingest(json.loads(raw_body))
            if error:
                return response(400, error)
            return response(202, result)

        return response(404, {"error": "Route not found", "method": method, "path": path})
    except ValueError as exc:
        return response(400, {"error": str(exc)})
    except Exception as exc:  # pragma: no cover - Lambda runtime path
        logger.error("Unhandled error: %s", exc, exc_info=True)
        return response(500, {"error": "Internal server error"})
