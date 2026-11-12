#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORT_DIR="$ROOT_DIR/reports/zap"
CONF_FILE="$SCRIPT_DIR/zap-baseline.conf"
COMPOSE_FILE="$ROOT_DIR/docker/docker-compose.yml"

mkdir -p "$REPORT_DIR"
chmod 777 "$REPORT_DIR" 2>/dev/null || true

PROJECT_NAME="votex-zap-test"
TARGET_URL="${1:-}"
CANDIDATE_IMAGE="${CANDIDATE_IMAGE:-${VOTE_CANDIDATE_IMAGE:-}}"
CLEANUP_REQUIRED=false
ZAP_CONTAINER="zap-scan-$$"

cleanup() {
  local exit_status=$?
  if [ -n "${ZAP_CONTAINER:-}" ]; then
    docker rm -f "$ZAP_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [ "$CLEANUP_REQUIRED" = "true" ]; then
    echo "Tearing down isolated ZAP candidate deployment..."
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

if [ -z "$TARGET_URL" ]; then
  if [ -n "$CANDIDATE_IMAGE" ]; then
    echo "Targeting candidate image: $CANDIDATE_IMAGE"
    export VOTE_IMAGE="$CANDIDATE_IMAGE"
  fi
  echo "Spinning up isolated candidate release for DAST testing..."
  CLEANUP_REQUIRED=true
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d db redis vote

  echo "Waiting for candidate release container to become healthy..."
  READY=false
  for i in {1..30}; do
    VOTE_CID=$(docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" ps -q vote 2>/dev/null || docker ps -q --filter "name=${PROJECT_NAME}-vote" | head -n 1)
    if [ -n "$VOTE_CID" ]; then
      STATUS=$(docker inspect --format '{{.State.Health.Status}}' "$VOTE_CID" 2>/dev/null || echo "")
      if [ "$STATUS" = "healthy" ]; then
        READY=true
        echo "Candidate release is healthy (container healthcheck passed)."
        break
      fi
      if docker exec "$VOTE_CID" curl -s -f http://localhost:80/api/health >/dev/null 2>&1; then
        READY=true
        echo "Candidate release is healthy (verified via internal container curl)."
        break
      fi
    fi
    sleep 2
  done

  if [ "$READY" != "true" ]; then
    echo "ERROR: Candidate release failed to start within timeout." >&2
    exit 1
  fi

  TARGET_URL="http://vote:80/"
  NETWORK_ARG="--network ${PROJECT_NAME}_front-tier"
else
  echo "Scanning external/provided target: $TARGET_URL"
  NETWORK_ARG=""
fi

echo "Executing OWASP ZAP Baseline DAST Scan against $TARGET_URL..."

# DinD-compatible execution: use container copy for config and report extraction
docker create --name "$ZAP_CONTAINER" \
  $NETWORK_ARG \
  ghcr.io/zaproxy/zaproxy:stable zap-baseline.py \
    -t "$TARGET_URL" \
    -c /zap/rules.conf \
    -r zap-report.html \
    -J zap-report.json \
    -m 3 \
    -T 3 >/dev/null || {
  echo "ERROR: Failed to create OWASP ZAP container '$ZAP_CONTAINER'." >&2
  exit 1
}

if [ -f "$CONF_FILE" ]; then
  docker cp "$CONF_FILE" "$ZAP_CONTAINER:/zap/rules.conf" || {
    echo "ERROR: Failed to copy ZAP baseline rules file into container." >&2
    exit 1
  }
fi

ZAP_EXIT=0
docker start -a "$ZAP_CONTAINER" || ZAP_EXIT=$?

# Extract reports from container to host report directory (do NOT swallow copy errors)
docker cp "$ZAP_CONTAINER:/zap/wrk/zap-report.html" "$REPORT_DIR/zap-report.html" || {
  echo "ERROR: Failed to extract zap-report.html from container." >&2
  exit 1
}
docker cp "$ZAP_CONTAINER:/zap/wrk/zap-report.json" "$REPORT_DIR/zap-report.json" || {
  echo "ERROR: Failed to extract zap-report.json from container." >&2
  exit 1
}

# Verify report integrity: files must exist and be non-empty
if [ ! -s "$REPORT_DIR/zap-report.html" ]; then
  echo "ERROR: Generated zap-report.html is empty." >&2
  exit 1
fi
if [ ! -s "$REPORT_DIR/zap-report.json" ]; then
  echo "ERROR: Generated zap-report.json is empty." >&2
  exit 1
fi

# Verify JSON report structure
python3 -c "import json, sys; json.load(open('$REPORT_DIR/zap-report.json'))" || {
  echo "ERROR: zap-report.json contains invalid or corrupt JSON." >&2
  exit 1
}

docker rm -f "$ZAP_CONTAINER" >/dev/null 2>&1 || true

echo ""
echo "OWASP ZAP scan finished with exit code: $ZAP_EXIT"
echo "HTML Report: $REPORT_DIR/zap-report.html"
echo "JSON Report: $REPORT_DIR/zap-report.json"

# Exit code evaluation policy:
# ZAP 0: success -> wrapper exit 0
# ZAP 2: success when warnings are accepted -> wrapper exit 0
# ZAP 1: blocking findings -> wrapper exit 1 (fails security gate & blocks publish)
# ZAP 3+ or runtime failure: unexpected error -> wrapper exit nonzero
if [ "$ZAP_EXIT" -eq 1 ]; then
  echo "SECURITY GATE FAILED: OWASP ZAP detected blocking vulnerabilities (FAIL threshold triggered)." >&2
  exit 1
elif [ "$ZAP_EXIT" -eq 2 ]; then
  echo "SECURITY GATE PASSED: OWASP ZAP reported non-blocking warnings within accepted thresholds."
  exit 0
elif [ "$ZAP_EXIT" -eq 0 ]; then
  echo "SECURITY GATE PASSED: OWASP ZAP found zero vulnerabilities or warnings."
  exit 0
else
  echo "SECURITY GATE FAILED: ZAP scanner encountered an error or execution failure (code $ZAP_EXIT)." >&2
  exit "${ZAP_EXIT:-1}"
fi
