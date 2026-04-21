# Crisis Pulse

Real-time disaster intelligence and geo-alert platform built on AWS serverless services.

`Crisis Pulse` ingests incident signals, classifies disaster types, computes severity scores, stores events for search, and publishes real-time alerts for high-severity incidents. The project is designed as a portfolio-ready example of event-driven backend architecture with infrastructure as code.

## Architecture

```text
HTTP or feed input
  -> Kinesis stream
  -> classifier Lambda
      -> DynamoDB for hot event reads
      -> S3 for archive storage
      -> EventBridge for alert fan-out
  -> alert-engine Lambda
      -> SNS notifications

Public reads:
API Gateway
  -> api-handler Lambda
  -> DynamoDB scan/query and Kinesis ingest
```

## Tech Stack

| Layer | AWS service |
| --- | --- |
| Ingestion | Kinesis Data Streams |
| Processing | AWS Lambda (Python 3.11) |
| Hot storage | DynamoDB |
| Archive storage | S3 |
| Alerting | EventBridge, SNS |
| API | API Gateway HTTP API |
| Monitoring | CloudWatch |
| IaC | Terraform |

## Project Structure

```text
crisis-pulse/
  terraform/
    main.tf
    variables.tf
    outputs.tf
    terraform.tfvars.example
  lambdas/
    classifier/
      handler.py
      requirements.txt
    api_handler/
      handler.py
      requirements.txt
    alert_engine/
      handler.py
      requirements.txt
  scripts/
    deploy.sh
    deploy.ps1
```

## Reliability Notes

- Duplicate detection is based on deterministic event IDs.
- Classified events are persisted to both DynamoDB and S3.
- High and critical incidents are pushed onto EventBridge and then forwarded to SNS.
- CloudWatch alarms watch DLQ depth and Lambda error rate.

## Prerequisites

- AWS account with deployment permissions
- AWS CLI configured
- Terraform 1.4+
- Python 3.11+

## Local Setup

1. Copy the example Terraform values file:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

2. Edit values in `terraform/terraform.tfvars`.

3. Deploy infrastructure:

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

4. Deploy Lambda code:

On macOS/Linux:

```bash
bash scripts/deploy.sh
```

On Windows PowerShell:

```powershell
.\scripts\deploy.ps1
```

## API Examples

Get incidents near Washington, DC:

```bash
curl "https://<api-endpoint>/events?lat=38.9072&lon=-77.0369&radius=50"
```

Ingest a new incident:

```bash
curl -X POST "https://<api-endpoint>/ingest" \
  -H "Content-Type: application/json" \
  -d '{"type":"earthquake","location":{"lat":38.9,"lon":-77.0},"magnitude":4.2}'
```

## API Reference

### `GET /events`

Returns geo-filtered incident events.

Query parameters:
- `lat` - required latitude
- `lon` - required longitude
- `radius` - radius in km, default `100`
- `severity` - optional `low`, `medium`, `high`, or `critical`
- `limit` - maximum number of records, default `50`

### `POST /ingest`

Accepts a JSON incident signal with at least:
- `type`
- `location.lat`
- `location.lon`

## Author

**Girik Tripathi**  
[girik29@umd.edu](mailto:girik29@umd.edu)  
[LinkedIn](https://www.linkedin.com/in/girik-tripathi29/)  
[Portfolio](https://girik2920.github.io/girik-portfolio)
