"""
Crisis Pulse alert engine Lambda.

Consumes EventBridge events for high-severity incidents and sends an SNS alert.
"""

import json
import logging
import os
from datetime import datetime

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sns = boto3.client("sns")
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

SEVERITY_LABELS = {
    "critical": "CRITICAL",
    "high": "HIGH",
    "medium": "MEDIUM",
    "low": "LOW",
}


def format_alert(detail):
    severity = detail.get("severity", "unknown")
    severity_label = SEVERITY_LABELS.get(severity, "UNKNOWN")
    disaster_type = detail.get("disaster_type", "unknown").upper()
    location = detail.get("location", {})
    timestamp = detail.get("timestamp", datetime.utcnow().isoformat())

    subject = f"[Crisis Pulse] {severity_label} {disaster_type} alert"
    message = (
        "CRISIS PULSE ALERT\n"
        "==================\n"
        f"Severity : {severity_label}\n"
        f"Type     : {disaster_type}\n"
        f"Score    : {detail.get('severity_score', 'N/A')}/100\n"
        f"Location : {location.get('lat', 'N/A')}, {location.get('lon', 'N/A')}\n"
        f"Event ID : {detail.get('event_id', 'N/A')}\n"
        f"Time     : {timestamp}\n"
    )
    return subject, message


def lambda_handler(event, context):
    del context
    logger.info("Received EventBridge event: %s", json.dumps(event))

    detail = event.get("detail", {})
    subject, message = format_alert(detail)

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=subject,
        Message=message,
        MessageAttributes={
            "severity": {
                "DataType": "String",
                "StringValue": detail.get("severity", "unknown"),
            },
            "disaster_type": {
                "DataType": "String",
                "StringValue": detail.get("disaster_type", "unknown"),
            },
        },
    )

    return {"status": "alert_sent", "event_id": detail.get("event_id", "unknown")}
