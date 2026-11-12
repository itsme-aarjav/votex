"""Votex Synthetic External Health Check AWS Lambda Handler.

Periodically queries Votex Vote and Result public HTTPS /api/health endpoints,
measures response latency, validates JSON responses, distinguishes UP, DOWN,
and DEGRADED states, and emits CloudWatch metrics for alarm evaluation.
Independent of internal Kubernetes networking.
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
    """Performs HTTP GET to the health endpoint, measuring status and latency.

    States:
      UP: HTTP 200 and healthy payload.
      DEGRADED: HTTP 200 but unhealthy/degraded payload, or unexpected status code.
      DOWN: Network failure, timeout, 5xx error, or missing/unreachable endpoint.
    """
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
        logger.warning("[%s] Health check failed: %s", name.upper(), result["error"])
        return result

    req = urllib.request.Request(
        url,
        headers={"User-Agent": "Votex-Lambda-SyntheticMonitor/1.0"},
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
                # Sanitize: prevent logging sensitive fields if any exist
                result["details"] = {
                    k: v for k, v in parsed_body.items()
                    if k not in ("token", "password", "secret", "credentials")
                }
            except Exception:
                result["details"] = {"raw": body[:200]}

            if resp.status == 200:
                payload_status = ""
                if isinstance(result["details"], dict):
                    payload_status = str(result["details"].get("status", "")).lower()

                if payload_status in ("unhealthy", "error", "down", "degraded"):
                    result["status"] = "DEGRADED"
                    result["error"] = f"Service reported degraded state: status={payload_status}"
                    logger.warning("[%s] [STATUS: DEGRADED] %s (latency: %sms)", name.upper(), result["error"], latency_ms)
                else:
                    result["status"] = "UP"
                    logger.info("[%s] [STATUS: UP] HTTP %s in %sms", name.upper(), resp.status, latency_ms)
            else:
                result["status"] = "DEGRADED"
                result["error"] = f"Unexpected HTTP status code: {resp.status}"
                logger.warning("[%s] [STATUS: DEGRADED] %s", name.upper(), result["error"])

    except urllib.error.HTTPError as e:
        latency_ms = round((time.time() - start_time) * 1000, 2)
        result["http_code"] = e.code
        result["latency_ms"] = latency_ms
        result["status"] = "DOWN"
        result["error"] = f"HTTPError {e.code}: {e.reason}"
        logger.error("[%s] [STATUS: DOWN] %s", name.upper(), result["error"])
    except urllib.error.URLError as e:
        latency_ms = round((time.time() - start_time) * 1000, 2)
        result["latency_ms"] = latency_ms
        result["status"] = "DOWN"
        result["error"] = f"URLError: {e.reason}"
        logger.error("[%s] [STATUS: DOWN] %s", name.upper(), result["error"])
    except Exception as e:
        latency_ms = round((time.time() - start_time) * 1000, 2)
        result["latency_ms"] = latency_ms
        result["status"] = "DOWN"
        result["error"] = str(e)
        logger.error("[%s] [STATUS: DOWN] Exception: %s", name.upper(), str(e))

    return result


def emit_cloudwatch_metrics(checks: list) -> None:
    """Emits synthetic availability and latency metrics to AWS CloudWatch."""
    try:
        import boto3
        cw = boto3.client("cloudwatch")
        environment = os.getenv("ENVIRONMENT", "production")
        metric_data = []

        all_up = all(c["status"] == "UP" for c in checks) if checks else False

        # 1. Overall synthetic availability metric (for cluster/environment outage alarm)
        metric_data.append({
            "MetricName": "OverallHealthStatus",
            "Dimensions": [{"Name": "Environment", "Value": environment}],
            "Value": 1.0 if all_up else 0.0,
            "Unit": "Count",
        })

        # 2. Per-service metrics (for granular service-level alarms)
        for c in checks:
            is_up = 1.0 if c["status"] == "UP" else 0.0
            metric_data.append({
                "MetricName": "HealthCheckStatus",
                "Dimensions": [
                    {"Name": "Service", "Value": c["service"]},
                    {"Name": "Environment", "Value": environment},
                ],
                "Value": is_up,
                "Unit": "Count",
            })
            metric_data.append({
                "MetricName": "HealthCheckLatencyMs",
                "Dimensions": [
                    {"Name": "Service", "Value": c["service"]},
                    {"Name": "Environment", "Value": environment},
                ],
                "Value": c["latency_ms"],
                "Unit": "Milliseconds",
            })

        if metric_data:
            cw.put_metric_data(
                Namespace="Votex/SyntheticMonitoring",
                MetricData=metric_data,
            )
            logger.info("Emitted %d synthetic health metrics to CloudWatch namespace Votex/SyntheticMonitoring", len(metric_data))
    except Exception as e:
        # Boto3 may not be available in local test environments; log and continue safely
        logger.debug("CloudWatch metric emission skipped: %s", e)


def lambda_handler(event, context):
    """Main Lambda invocation entrypoint."""
    vote_url = os.getenv("VOTE_HEALTH_URL", "")
    result_url = os.getenv("RESULT_HEALTH_URL", "")
    timeout = float(os.getenv("HEALTH_CHECK_TIMEOUT_SEC", "5.0"))

    vote_check = check_endpoint("vote", vote_url, timeout_sec=timeout)
    result_check = check_endpoint("result", result_url, timeout_sec=timeout)

    all_checks = [vote_check, result_check]
    all_up = all(c["status"] == "UP" for c in all_checks)
    overall_status = "OK" if all_up else "ERROR"

    report = {
        "status": overall_status,
        "timestamp": time.time(),
        "environment": os.getenv("ENVIRONMENT", "production"),
        "checks": all_checks,
    }

    log_level = logging.INFO if all_up else logging.ERROR
    logger.log(log_level, "Votex Synthetic Health Report: %s", json.dumps(report))

    emit_cloudwatch_metrics(all_checks)

    return {
        "statusCode": 200 if all_up else 503,
        "body": json.dumps(report),
    }


if __name__ == "__main__":
    print(json.dumps(lambda_handler({}, None), indent=2))
