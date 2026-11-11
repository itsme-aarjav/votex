"""Votex Synthetic Health Check AWS Lambda Handler.

Periodically queries Votex Vote and Result service /api/health endpoints,
measures response latency, validates JSON responses, and logs metrics
for CloudWatch ingestion.
"""

import json
import logging
import os
import time
import urllib.error
import urllib.request

logger = logging.getLogger()
logger.setLevel(os.getenv("LOG_LEVEL", "INFO"))


def check_endpoint(name: str, url: str, timeout_sec: float = 5.0) -> dict:
    """Performs HTTP GET to the health endpoint, measuring status and latency."""
    start_time = time.time()
    result = {
        "service": name,
        "url": url,
        "status": "DOWN",
        "http_code": 0,
        "latency_ms": 0.0,
        "details": {},
        "error": None,
    }

    if not url or not url.startswith(("http://", "https://")):
        result["error"] = f"Invalid or missing URL: '{url}'"
        result["status"] = "DOWN"
        return result

    req = urllib.request.Request(
        url,
        headers={"User-Agent": "Votex-Lambda-HealthCheck/1.0"},
        method="GET",
    )

    try:
        with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
            latency_ms = round((time.time() - start_time) * 1000, 2)
            result["http_code"] = resp.status
            result["latency_ms"] = latency_ms

            body = resp.read().decode("utf-8")
            try:
                parsed_body = json.loads(body)
                result["details"] = parsed_body
            except Exception:
                result["details"] = {"raw": body[:200]}

            if resp.status == 200:
                if isinstance(result["details"], dict) and result["details"].get("status") in ("unhealthy", "error", "down", "DOWN"):
                    result["status"] = "DEGRADED"
                    result["error"] = f"Service reported status: {result['details'].get('status')}"
                else:
                    result["status"] = "UP"
            else:
                result["status"] = "DEGRADED"

    except urllib.error.HTTPError as e:
        latency_ms = round((time.time() - start_time) * 1000, 2)
        result["http_code"] = e.code
        result["latency_ms"] = latency_ms
        result["status"] = "DOWN"
        result["error"] = f"HTTPError {e.code}: {e.reason}"
    except urllib.error.URLError as e:
        latency_ms = round((time.time() - start_time) * 1000, 2)
        result["latency_ms"] = latency_ms
        result["status"] = "DOWN"
        result["error"] = f"URLError: {e.reason}"
    except Exception as e:
        latency_ms = round((time.time() - start_time) * 1000, 2)
        result["latency_ms"] = latency_ms
        result["status"] = "DOWN"
        result["error"] = str(e)

    return result


def emit_cloudwatch_metrics(checks: list) -> None:
    """Optionally emit metrics to CloudWatch if boto3 is present."""
    try:
        import boto3
        cw = boto3.client("cloudwatch")
        metric_data = []
        for c in checks:
            is_up = 1.0 if c["status"] == "UP" else 0.0
            metric_data.append({
                "MetricName": "HealthCheckStatus",
                "Dimensions": [{"Name": "Service", "Value": c["service"]}],
                "Value": is_up,
                "Unit": "Count",
            })
            metric_data.append({
                "MetricName": "HealthCheckLatencyMs",
                "Dimensions": [{"Name": "Service", "Value": c["service"]}],
                "Value": c["latency_ms"],
                "Unit": "Milliseconds",
            })

        if metric_data:
            cw.put_metric_data(
                Namespace="Votex/SyntheticMonitoring",
                MetricData=metric_data,
            )
    except Exception as e:
        # Boto3 may not be available in local unit test environments; log and continue
        logger.debug(f"CloudWatch metric emission skipped: {e}")


def lambda_handler(event, context):
    """Main Lambda invocation entrypoint."""
    vote_url = os.getenv("VOTE_HEALTH_URL", "http://vote.votex.svc.cluster.local/api/health")
    result_url = os.getenv("RESULT_HEALTH_URL", "http://result.votex.svc.cluster.local/api/health")
    timeout = float(os.getenv("HEALTH_CHECK_TIMEOUT_SEC", "5.0"))

    vote_check = check_endpoint("vote", vote_url, timeout_sec=timeout)
    result_check = check_endpoint("result", result_url, timeout_sec=timeout)

    all_checks = [vote_check, result_check]
    all_up = all(c["status"] == "UP" for c in all_checks)
    overall_status = "OK" if all_up else "ERROR"

    report = {
        "status": overall_status,
        "timestamp": time.time(),
        "checks": all_checks,
    }

    log_level = logging.INFO if all_up else logging.ERROR
    logger.log(log_level, f"Votex Health Check Report: {json.dumps(report)}")

    emit_cloudwatch_metrics(all_checks)

    return {
        "statusCode": 200 if all_up else 503,
        "body": json.dumps(report),
    }


if __name__ == "__main__":
    # Local CLI invocation helper
    print(json.dumps(lambda_handler({}, None), indent=2))

