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

cleanup() {
  if [ "$CLEANUP_REQUIRED" = "true" ]; then
    echo "Tearing down isolated ZAP candidate deployment..."
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ -z "$TARGET_URL" ]; then
  if [ -z "$CANDIDATE_IMAGE" ] && curl -s -f http://localhost:5002/api/health >/dev/null 2>&1; then
    echo "Detected running Votex candidate on port 5002."
    CLEANUP_REQUIRED=false
    VOTE_CID=$(docker ps --filter "publish=5002" --format "{{.ID}}" 2>/dev/null | head -n 1)
    if [ -z "$VOTE_CID" ]; then
      VOTE_CID=$(docker ps --filter "name=vote" --format "{{.ID}}" 2>/dev/null | head -n 1)
    fi
    DETECTED_NET=""
    if [ -n "$VOTE_CID" ]; then
      DETECTED_NET=$(docker inspect "$VOTE_CID" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{break}}{{end}}' 2>/dev/null || echo "")
    fi
    if [ -n "$DETECTED_NET" ]; then
      TARGET_URL="http://vote:80/"
      NETWORK_ARG="--network $DETECTED_NET"
      echo "Discovered active container network: $DETECTED_NET"
    else
      TARGET_URL="http://127.0.0.1:5002/"
      NETWORK_ARG="--network host"
      echo "Fallback to host network mode against 127.0.0.1:5002"
    fi
  else
    if [ -n "$CANDIDATE_IMAGE" ]; then
      echo "Targeting candidate image: $CANDIDATE_IMAGE"
      export VOTE_IMAGE="$CANDIDATE_IMAGE"
    fi
    echo "Spinning up isolated candidate release for DAST testing..."
    CLEANUP_REQUIRED=true
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d db redis vote

    echo "Waiting for candidate release to become healthy at http://localhost:5002/api/health..."
    READY=false
    for i in {1..30}; do
      if curl -s -f http://localhost:5002/api/health >/dev/null 2>&1; then
        READY=true
        echo "Candidate release is healthy and ready for DAST scanning."
        break
      fi
      sleep 2
    done

    if [ "$READY" != "true" ]; then
      echo "ERROR: Candidate release failed to start within timeout." >&2
      exit 1
    fi

    # In container network, target is the vote service on port 80
    TARGET_URL="http://vote:80/"
    NETWORK_ARG="--network ${PROJECT_NAME}_front-tier"
  fi
else
  echo "Scanning external/provided target: $TARGET_URL"
  NETWORK_ARG=""
fi

echo "Executing OWASP ZAP Baseline DAST Scan against $TARGET_URL..."

# Docker run ZAP baseline scan
ZAP_EXIT=0
docker run --rm \
  $NETWORK_ARG \
  -v "$REPORT_DIR:/zap/wrk/:rw" \
  -v "$CONF_FILE:/zap/rules.conf:ro" \
  ghcr.io/zaproxy/zaproxy:stable zap-baseline.py \
    -t "$TARGET_URL" \
    -c /zap/rules.conf \
    -r zap-report.html \
    -J zap-report.json \
    -m 3 \
    -T 3 || ZAP_EXIT=$?

echo ""
echo "OWASP ZAP scan finished with exit code: $ZAP_EXIT"
echo "HTML Report: $REPORT_DIR/zap-report.html"
echo "JSON Report: $REPORT_DIR/zap-report.json"

# Exit code evaluation policy:
# ZAP 0: success -> wrapper exit 0
# ZAP 2: success when warnings are accepted -> wrapper exit 0
# ZAP 1: blocking findings -> wrapper exit 1
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

