#!/usr/bin/env bash
# Votex Platform Operations Integration & Failure-Path Test Suite
# Tests ops/deploy.sh, ops/dashboard.sh, and ops/destroy.sh (including partial-infrastructure recovery)
# 100% OFFLINE & SAFE: Uses isolated mock stubs; NEVER contacts AWS, Docker Hub, or Kubernetes.

set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export TEST_DIR="$(mktemp -d /tmp/votex-ops-tests-XXXXXX)"
ROOT_DIR="$TEST_DIR/project"
MOCK_BIN="$TEST_DIR/bin"
mkdir -p "$MOCK_BIN" "$ROOT_DIR/terraform"
cp -R "$SOURCE_ROOT/ops" "$SOURCE_ROOT/k8s" "$SOURCE_ROOT/jenkins" "$SOURCE_ROOT/sonarqube" "$ROOT_DIR/"
cp "$SOURCE_ROOT/terraform/backend.tf.example" "$ROOT_DIR/terraform/backend.tf.example"
cd "$ROOT_DIR"

CREATED_BACKEND_TF=0
cleanup() {
  cd "$SOURCE_ROOT"
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

run_test() {
  local name="$1"
  shift
  rm -f "$TEST_DIR/.tf_state_cleared"
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  printf "Running test [%02d]: %s ... " "$TOTAL_TESTS" "$name"
  local output_file="$TEST_DIR/test_${TOTAL_TESTS}.log"
  if "$@" > "$output_file" 2>&1; then
    echo "PASS"
    PASSED_TESTS=$((PASSED_TESTS + 1))
  else
    echo "FAIL"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo "------------------ Test Failure Output ------------------"
    cat "$output_file"
    echo "---------------------------------------------------------"
  fi
}

# Create mock CLI stubs
cat <<'STUB' > "$MOCK_BIN/aws"
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
subcmd="${2:-}"

case "$cmd" in
  sts)
    if [ "${MOCK_AWS_AUTH_FAIL:-0}" = "1" ]; then
      exit 254
    fi
    echo "${MOCK_AWS_ACCOUNT:-123456789012}"
    ;;
  s3api)
    if [ "${MOCK_S3_HEAD_FAIL:-0}" = "1" ]; then
      echo "An error occurred (404) when calling the HeadBucket operation: Not Found" >&2
      exit 1
    fi
    exit 0
    ;;
  eks)
    case "$subcmd" in
      describe-cluster)
        if [ "${MOCK_EKS_ACCESS_DENIED:-0}" = "1" ]; then
          echo "An error occurred (AccessDeniedException) when calling the DescribeCluster operation: Access denied" >&2
          exit 254
        fi
        if [ "${MOCK_EKS_TIMEOUT:-0}" = "1" ]; then
          echo "Connect timeout on endpoint URL: https://eks.eu-north-1.amazonaws.com" >&2
          exit 255
        fi
        status="${MOCK_EKS_STATUS:-ACTIVE}"
        if [ "$status" = "ABSENT" ]; then
          echo "An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: Cluster not found" >&2
          exit 254
        fi
        account="${MOCK_AWS_ACCOUNT:-123456789012}"
        if [ "${MOCK_EKS_ARN_MISMATCH:-0}" = "1" ]; then
          account="999888777666"
        fi
        region="${AWS_REGION:-eu-north-1}"
        cluster="${CLUSTER_NAME:-votex-cluster}"
        query="${4:-}"
        if [ "$query" = "cluster.arn" ]; then
          echo "arn:aws:eks:${region}:${account}:cluster/${cluster}"
        elif [ "$query" = "cluster.endpoint" ]; then
          echo "${MOCK_EKS_ENDPOINT:-https://test-eks.mock.internal}"
        elif [ "$query" = "cluster.status" ]; then
          echo "$status"
        else
          cat <<EOF
{
  "cluster": {
    "name": "${cluster}",
    "arn": "arn:aws:eks:${region}:${account}:cluster/${cluster}",
    "endpoint": "${MOCK_EKS_ENDPOINT:-https://test-eks.mock.internal}",
    "status": "${status}"
  }
}
EOF
        fi
        ;;
      update-kubeconfig)
        exit 0
        ;;
    esac
    ;;
  elbv2)
    case "$subcmd" in
      describe-load-balancers)
        if [ "${MOCK_AWS_API_FAIL:-0}" = "1" ]; then
          echo "API Error: AccessDeniedException" >&2
          exit 1
        fi
        echo "${MOCK_ALB_ARNS:-}"
        ;;
      describe-tags)
        if [ "${MOCK_ALB_IS_VOTEX:-1}" = "1" ]; then
          echo "votex-platform"
        else
          echo ""
        fi
        ;;
    esac
    ;;
  elb)
    echo "${MOCK_CLASSIC_ELBS:-}"
    ;;
  ec2)
    case "$subcmd" in
      describe-volumes)
        if [ "${MOCK_AWS_API_FAIL:-0}" = "1" ]; then
          echo "API Error: Unauthorized" >&2
          exit 1
        fi
        echo "${MOCK_EBS_VOLUMES:-}"
        ;;
      describe-instances)
        echo "${MOCK_EC2_INSTANCES:-}"
        ;;
      describe-nat-gateways)
        echo "${MOCK_NAT_GATEWAYS:-}"
        ;;
    esac
    ;;
  lambda)
    case "$subcmd" in
      get-function)
        if [ "${MOCK_LAMBDA_FAIL:-0}" = "1" ]; then
          echo "ResourceNotFoundException" >&2
          exit 1
        fi
        exit 0
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$MOCK_BIN/aws"

cat <<'STUB' > "$MOCK_BIN/kubectl"
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"

case "$cmd" in
  cluster-info)
    if [ "${MOCK_CLUSTER_OFFLINE:-0}" = "1" ]; then
      echo "Unable to connect to the server" >&2
      exit 1
    fi
    echo "Kubernetes control plane is running"
    ;;
  config)
    subcmd="${2:-}"
    if [ "$subcmd" = "current-context" ]; then
      if [ "${MOCK_KUBE_NO_CONTEXT:-0}" = "1" ]; then
        exit 1
      fi
      echo "${MOCK_KUBE_CONTEXT:-arn:aws:eks:eu-north-1:123456789012:cluster/votex-cluster}"
    elif [ "$subcmd" = "view" ]; then
      if [ "${MOCK_KUBE_ENDPOINT_MISMATCH:-0}" = "1" ]; then
        echo "https://different-endpoint.internal"
      else
        echo "${MOCK_EKS_ENDPOINT:-https://test-eks.mock.internal}"
      fi
    fi
    ;;
  get)
    resource="${2:-}"
    case "$resource" in
      nodes)
        if [ "${MOCK_CLUSTER_OFFLINE:-0}" = "1" ]; then
          exit 1
        fi
        count="${MOCK_NODE_COUNT:-2}"
        ntype="${MOCK_NODE_TYPE:-m7i-flex.large}"
        if [[ "$*" =~ "-o jsonpath=" ]]; then
          if [[ "$*" =~ "instance-type" ]]; then
            for _ in $(seq 1 "$count"); do echo "$ntype"; done
          else
            # Ready status
            ready_status="${MOCK_NODES_READY_STATUS:-True}"
            for _ in $(seq 1 "$count"); do echo "$ready_status"; done
          fi
        else
          for i in $(seq 1 "$count"); do echo "ip-10-0-1-$i Ready worker 10m v1.31.0"; done
        fi
        ;;
      namespaces)
        echo "votex monitoring logging jenkins sonarqube kube-system default"
        ;;
      service)
        if [ "${MOCK_SVC_MISSING:-0}" = "1" ]; then
          exit 1
        fi
        cat <<EOF
{"apiVersion":"v1","kind":"Service","metadata":{"name":"$3","namespace":"$5"},"spec":{"selector":{"app":"$3"}}}
EOF
        ;;
      pods|pod)
        if [ "${MOCK_PODS_FAIL:-0}" = "1" ]; then
          exit 1
        fi
        ready="${MOCK_POD_READY_COUNT:-2}"
        total="${MOCK_POD_TOTAL_COUNT:-2}"
        if [ "$total" -eq 0 ]; then
          echo '{"items":[]}'
        elif [ "$ready" -eq "$total" ]; then
          echo '{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
        else
          echo '{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}'
        fi
        ;;
      ingress)
        if [ "${MOCK_INGRESS_FAIL:-0}" = "1" ]; then
          exit 1
        fi
        if [ "${MOCK_INGRESS_PENDING_ALB:-0}" = "1" ]; then
          echo '{"items":[{"spec":{"rules":[{"host":"vote.test.example","http":{"paths":[{"path":"/","backend":{"service":{"name":"vote"}}}]}}]},"status":{"loadBalancer":{"ingress":[]}}}]}'
        elif [ "${MOCK_INGRESS_PLACEHOLDER:-0}" = "1" ]; then
          echo '{"items":[{"spec":{"rules":[{"host":"vote.votex.domain.tld","http":{"paths":[{"path":"/","backend":{"service":{"name":"vote"}}}]}}]},"status":{"loadBalancer":{"ingress":[{"hostname":"mock-alb-123.eu-north-1.elb.amazonaws.com"}]}}}]}'
        else
          echo '{"items":[{"spec":{"rules":[{"host":"vote.test.example","http":{"paths":[{"path":"/","backend":{"service":{"name":"vote"}}}]}}]},"status":{"loadBalancer":{"ingress":[{"hostname":"mock-alb-123.eu-north-1.elb.amazonaws.com"}]}}}]}'
        fi
        ;;
      pv)
        cat <<EOF
{"items":[{"spec":{"claimRef":{"namespace":"votex","name":"votex-db-pvc"},"csi":{"volumeHandle":"vol-0123456789abcdef0"}}}]}
EOF
        ;;
      storageclass|ingressclass|secret|configmap)
        if [ "${MOCK_INGRESSCLASS_MISSING:-0}" = "1" ] && [ "$resource" = "ingressclass" ]; then
          exit 1
        fi
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  wait|rollout)
    if [ "${MOCK_ROLLOUT_FAIL:-0}" = "1" ]; then
      echo "error: timed out waiting for condition" >&2
      exit 1
    fi
    exit 0
    ;;
  exec)
    if [ "${MOCK_SONAR_EXEC_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    echo "${MOCK_SONAR_EXEC_OUT:-HTTP 200}"
    ;;
  create|apply|delete)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$MOCK_BIN/kubectl"

cat <<'STUB' > "$MOCK_BIN/terraform"
#!/usr/bin/env bash
set -euo pipefail

while [[ "${1:-}" =~ ^-chdir= ]]; do
  shift
done

cmd="${1:-}"

case "$cmd" in
  state)
    sub="${2:-}"
    if [ "$sub" = "list" ]; then
      if [ "${MOCK_TF_STATE_FAIL:-0}" = "1" ]; then
        echo "Error loading state" >&2
        exit 1
      fi
      if [ -f "$TEST_DIR/.tf_state_cleared" ] || [ "${MOCK_TF_STATE_EMPTY:-0}" = "1" ]; then
        echo ""
      else
        echo "${MOCK_TF_STATE_RESOURCES:-module.vpc.aws_vpc.this[0]}"
      fi
    fi
    ;;
  plan)
    if [ "${MOCK_TF_PLAN_FAIL:-0}" = "1" ]; then
      echo "Error during terraform plan" >&2
      exit 1
    fi
    out_file=""
    for arg in "$@"; do
      if [[ "$arg" =~ -out= ]]; then
        out_file="${arg#-out=}"
      fi
    done
    if [ -n "$out_file" ]; then
      echo "mock_tfplan_binary" > "$out_file"
    fi
    echo "Plan: 0 to add, 0 to change, 2 to destroy."
    ;;
  show)
    echo "Terraform will destroy:"
    echo "  - module.vpc.aws_vpc.this[0]"
    ;;
  apply)
    if [ "${MOCK_TF_APPLY_FAIL:-0}" = "1" ]; then
      echo "Error applying plan" >&2
      exit 1
    fi
    if [ "${MOCK_TF_AFTER_DESTROY_LEFTOVERS:-0}" = "1" ]; then
      # Leaves resources tracked
      :
    else
      touch "$TEST_DIR/.tf_state_cleared"
    fi
    echo "Apply complete! Resources: 0 added, 0 changed, 2 destroyed."
    ;;
  output)
    var="${2:-}"
    if [ "$var" = "-raw" ]; then
      out_name="${3:-}"
      case "$out_name" in
        otel_collector_role_arn)
          echo "arn:aws:iam::123456789012:role/votex-otel-collector-role"
          ;;
        aws_lb_controller_role_arn)
          echo "arn:aws:iam::123456789012:role/votex-aws-lb-controller-role"
          ;;
        vpc_id)
          echo "vpc-0123456789abcdef0"
          ;;
      esac
    fi
    ;;
  init|validate|fmt)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$MOCK_BIN/terraform"

cat <<'STUB' > "$MOCK_BIN/helm"
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"

case "$cmd" in
  status)
    if [ "${MOCK_HELM_STATUS_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    exit 0
    ;;
  repo|upgrade|uninstall)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$MOCK_BIN/helm"

cat <<'STUB' > "$MOCK_BIN/curl"
#!/usr/bin/env bash
set -euo pipefail

url="${!#:-}"

# Docker Hub API stub
if [[ "$url" =~ "hub.docker.com" ]]; then
  if [ "${MOCK_DOCKER_IMG_FAIL:-0}" = "1" ]; then
    echo '{"message": "object not found"}'
    exit 0
  fi
  if [ "${MOCK_DOCKER_NOT_AMD64:-0}" = "1" ]; then
    echo '{"name": "v2.0.0", "images": [{"architecture": "arm64"}]}'
    exit 0
  fi
  echo '{"name": "v2.0.0", "images": [{"architecture": "amd64"}]}'
  exit 0
fi

# Ingress / service health check probe stubs
if [[ "$url" =~ "https://" ]] || [[ "$url" =~ "http://" ]]; then
  code="${MOCK_CURL_CODE:-200}"
  if [ "${MOCK_CURL_FAIL:-0}" = "1" ]; then
    exit 1
  fi
  for arg in "$@"; do
    if [ "$arg" = "-w" ] || [[ "$arg" =~ "%{http_code}" ]]; then
      echo "$code"
      exit 0
    fi
  done
  if [ "$code" = "200" ] || [ "$code" = "204" ]; then
    exit 0
  else
    exit 1
  fi
fi

exit 0
STUB
chmod +x "$MOCK_BIN/curl"

# Prepare mock Terraform backend state metadata in a test sandbox
setup_mock_backend() {
  local dir="$1"
  mkdir -p "$dir/terraform/.terraform"
  cat <<'EOF' > "$dir/terraform/.terraform/terraform.tfstate"
{
  "version": 3,
  "backend": {
    "type": "s3",
    "config": {
      "bucket": "votex-tfstate-123456789012-eu-north-1",
      "key": "votex/terraform.tfstate",
      "region": "eu-north-1",
      "use_lockfile": true
    }
  }
}
EOF
  if [ ! -f "$dir/terraform/backend.tf" ]; then
    cp "$dir/terraform/backend.tf.example" "$dir/terraform/backend.tf"
    CREATED_BACKEND_TF=1
  fi
}

setup_mock_backend "$ROOT_DIR"

if [ "$ROOT_DIR" = "$SOURCE_ROOT" ] || [ ! -f "$ROOT_DIR/terraform/.terraform/terraform.tfstate" ]; then
  echo "ERROR: Test sandbox not isolated from real project." >&2
  exit 1
fi
export PATH="$MOCK_BIN:$PATH"

echo "=============================================================================="
echo "VOTEX OPERATIONS INTEGRATION TEST SUITE"
echo "Isolated mock environment: $MOCK_BIN"
echo "=============================================================================="
echo ""

# ==============================================================================
# SECTION 1: DEPLOY.SH VALIDATIONS
# ==============================================================================
echo "--- Section 1: ops/deploy.sh Tests ---"

run_test "deploy.sh --offline mode validates without backend" \
  bash -c 'ops/deploy.sh --offline'

run_test "deploy.sh --plan fails when OPERATOR_CIDR is missing" \
  bash -c '! ops/deploy.sh --plan'

run_test "deploy.sh --plan fails when OPERATOR_CIDR is 0.0.0.0/0" \
  bash -c '! OPERATOR_CIDR="0.0.0.0/0" ops/deploy.sh --plan'

run_test "deploy.sh --plan fails when OPERATOR_CIDR is invalid format" \
  bash -c '! OPERATOR_CIDR="invalid-cidr" ops/deploy.sh --plan'

run_test "deploy.sh --plan succeeds with valid OPERATOR_CIDR" \
  bash -c 'OPERATOR_CIDR="203.0.113.10/32" ops/deploy.sh --plan'

run_test "deploy.sh --full fails when EXPECTED_AWS_ACCOUNT_ID is missing" \
  bash -c '! ops/deploy.sh --full'

run_test "deploy.sh --full fails when AWS caller account does not match EXPECTED_AWS_ACCOUNT_ID" \
  bash -c '! EXPECTED_AWS_ACCOUNT_ID="999999999999" MOCK_AWS_ACCOUNT="123456789012" ops/deploy.sh --full'

run_test "deploy.sh --full fails when AWS_REGION is not eu-north-1" \
  bash -c '! EXPECTED_AWS_ACCOUNT_ID="123456789012" AWS_REGION="us-east-1" ops/deploy.sh --full'

run_test "deploy.sh --full fails when OPERATOR_CIDR is missing" \
  bash -c '! EXPECTED_AWS_ACCOUNT_ID="123456789012" AWS_REGION="eu-north-1" ops/deploy.sh --full'

run_test "deploy.sh --full fails when public mode has missing APP_DOMAIN" \
  bash -c '! EXPECTED_AWS_ACCOUNT_ID="123456789012" OPERATOR_CIDR="203.0.113.10/32" ops/deploy.sh --full'

run_test "deploy.sh --full fails when public mode has placeholder APP_DOMAIN" \
  bash -c '! EXPECTED_AWS_ACCOUNT_ID="123456789012" OPERATOR_CIDR="203.0.113.10/32" APP_DOMAIN="votex.domain.tld" ops/deploy.sh --full'

run_test "deploy.sh --full fails when public mode has invalid ACM ARN" \
  bash -c '! EXPECTED_AWS_ACCOUNT_ID="123456789012" OPERATOR_CIDR="203.0.113.10/32" APP_DOMAIN="votex.realdomain.com" ACM_CERTIFICATE_ARN="invalid-arn" ops/deploy.sh --full'

run_test "deploy.sh --full fails when bootstrap images are missing from registry" \
  bash -c '! EXPECTED_AWS_ACCOUNT_ID="123456789012" OPERATOR_CIDR="203.0.113.10/32" DEPLOY_ACCESS_MODE=internal MOCK_DOCKER_IMG_FAIL=1 ops/deploy.sh --full'

run_test "deploy.sh --full fails when bootstrap image is not amd64 architecture" \
  bash -c '! EXPECTED_AWS_ACCOUNT_ID="123456789012" OPERATOR_CIDR="203.0.113.10/32" DEPLOY_ACCESS_MODE=internal MOCK_DOCKER_NOT_AMD64=1 ops/deploy.sh --full'

run_test "deploy.sh --full fails when VOTEX_DOCKERHUB credentials are missing" \
  bash -c '! EXPECTED_AWS_ACCOUNT_ID="123456789012" OPERATOR_CIDR="203.0.113.10/32" DEPLOY_ACCESS_MODE=internal ops/deploy.sh --full'

run_test "deploy.sh --full fails when S3 remote state bucket is inaccessible" \
  bash -c '! EXPECTED_AWS_ACCOUNT_ID="123456789012" OPERATOR_CIDR="203.0.113.10/32" DEPLOY_ACCESS_MODE=internal VOTEX_DOCKERHUB_USERNAME=user VOTEX_DOCKERHUB_TOKEN=tok MOCK_S3_HEAD_FAIL=1 ops/deploy.sh --full'

run_test "deploy.sh --full fails when Terraform planning fails" \
  bash -c '! EXPECTED_AWS_ACCOUNT_ID="123456789012" OPERATOR_CIDR="203.0.113.10/32" DEPLOY_ACCESS_MODE=internal VOTEX_DOCKERHUB_USERNAME=user VOTEX_DOCKERHUB_TOKEN=tok MOCK_TF_PLAN_FAIL=1 ops/deploy.sh --full'

run_test "deploy.sh --full aborts cleanly when operator rejects confirmation" \
  bash -c 'out=$(echo "no" | EXPECTED_AWS_ACCOUNT_ID="123456789012" OPERATOR_CIDR="203.0.113.10/32" DEPLOY_ACCESS_MODE=internal VOTEX_DOCKERHUB_USERNAME=user VOTEX_DOCKERHUB_TOKEN=tok ops/deploy.sh --full); echo "$out" | grep -q "Deployment aborted by operator"'

run_test "deploy.sh --full failure recovery instructions mention destroy.sh --recover-partial" \
  bash -c 'out=$(echo "deploy-votex" | EXPECTED_AWS_ACCOUNT_ID="123456789012" OPERATOR_CIDR="203.0.113.10/32" DEPLOY_ACCESS_MODE=internal VOTEX_DOCKERHUB_USERNAME=user VOTEX_DOCKERHUB_TOKEN=tok MOCK_TF_APPLY_FAIL=1 ops/deploy.sh --full 2>&1 || true); echo "$out" | grep -q "recover-partial"'

run_test "deploy.sh --full fails when worker node count is not exactly 2" \
  bash -c '! echo "deploy-votex" | EXPECTED_AWS_ACCOUNT_ID="123456789012" OPERATOR_CIDR="203.0.113.10/32" DEPLOY_ACCESS_MODE=internal VOTEX_DOCKERHUB_USERNAME=user VOTEX_DOCKERHUB_TOKEN=tok MOCK_NODE_COUNT=3 ops/deploy.sh --full'

run_test "deploy.sh --full fails when worker node instance type is not m7i-flex.large" \
  bash -c '! echo "deploy-votex" | EXPECTED_AWS_ACCOUNT_ID="123456789012" OPERATOR_CIDR="203.0.113.10/32" DEPLOY_ACCESS_MODE=internal VOTEX_DOCKERHUB_USERNAME=user VOTEX_DOCKERHUB_TOKEN=tok MOCK_NODE_TYPE="t3.medium" ops/deploy.sh --full'

# ==============================================================================
# SECTION 2: DASHBOARD.SH VALIDATIONS
# ==============================================================================
echo ""
echo "--- Section 2: ops/dashboard.sh Tests ---"

run_test "dashboard.sh displays offline pending status when cluster is unreachable" \
  bash -c 'out=$(MOCK_CLUSTER_OFFLINE=1 ops/dashboard.sh); echo "$out" | grep -q "STATUS: Offline / Pending Cloud Deployment"'

run_test "dashboard.sh handles missing service gracefully" \
  bash -c 'out=$(MOCK_SVC_MISSING=1 ops/dashboard.sh); echo "$out" | grep -q "service missing"'

run_test "dashboard.sh handles 0 pods running" \
  bash -c 'out=$(MOCK_POD_TOTAL_COUNT=0 MOCK_POD_READY_COUNT=0 ops/dashboard.sh); echo "$out" | grep -q "0 pods running"'

run_test "dashboard.sh handles degraded state (1/2 pods ready)" \
  bash -c 'out=$(MOCK_POD_TOTAL_COUNT=2 MOCK_POD_READY_COUNT=1 ops/dashboard.sh); echo "$out" | grep -q "Degraded (1/2 pods Ready)"'

run_test "dashboard.sh handles fully healthy pods (2/2 ready)" \
  bash -c 'out=$(MOCK_POD_TOTAL_COUNT=2 MOCK_POD_READY_COUNT=2 ops/dashboard.sh); echo "$out" | grep -q "Healthy (2/2 pods Ready)"'

run_test "dashboard.sh handles pending ALB in ingress" \
  bash -c 'out=$(MOCK_INGRESS_PENDING_ALB=1 ops/dashboard.sh); echo "$out" | grep -q "ALB pending provisioning"'

run_test "dashboard.sh handles placeholder domain without marking HTTPS ready" \
  bash -c 'out=$(MOCK_INGRESS_PLACEHOLDER=1 ops/dashboard.sh); echo "$out" | grep -q "Placeholder host"'

run_test "dashboard.sh detects HTTP 200 reachable endpoint" \
  bash -c 'out=$(MOCK_CURL_CODE=200 ops/dashboard.sh); echo "$out" | grep -q "HTTP 200"'

run_test "dashboard.sh detects HTTP 302 redirect response" \
  bash -c 'out=$(MOCK_CURL_CODE=302 ops/dashboard.sh); echo "$out" | grep -q "HTTP 302"'

run_test "dashboard.sh detects HTTP 401/403 access restriction" \
  bash -c 'out=$(MOCK_CURL_CODE=401 ops/dashboard.sh); echo "$out" | grep -q "HTTP 401"'

# ==============================================================================
# SECTION 3: DESTROY.SH & PARTIAL RECOVERY VALIDATIONS
# ==============================================================================
echo ""
echo "--- Section 3: ops/destroy.sh & Partial Recovery Tests ---"

run_test "destroy.sh fails when EXPECTED_AWS_ACCOUNT_ID is missing" \
  bash -c '! ops/destroy.sh'

run_test "destroy.sh fails when AWS caller account does not match EXPECTED_AWS_ACCOUNT_ID" \
  bash -c '! EXPECTED_AWS_ACCOUNT_ID="999999999999" MOCK_AWS_ACCOUNT="123456789012" ops/destroy.sh'

run_test "destroy.sh fails when region is not eu-north-1" \
  bash -c '! EXPECTED_AWS_ACCOUNT_ID="123456789012" AWS_REGION="us-east-1" ops/destroy.sh'

run_test "destroy.sh fails when remote S3 state bucket is inaccessible" \
  bash -c '! EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_S3_HEAD_FAIL=1 ops/destroy.sh'

run_test "destroy.sh standard mode fails when EKS cluster is absent and advises --recover-partial" \
  bash -c 'out=$(EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_STATUS="ABSENT" ops/destroy.sh 2>&1 || true); echo "$out" | grep -q "ops/destroy.sh --recover-partial"'

run_test "destroy.sh standard mode fails when EKS cluster is in FAILED status" \
  bash -c 'out=$(EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_STATUS="FAILED" ops/destroy.sh 2>&1 || true); echo "$out" | grep -q "non-ready status"'

run_test "destroy.sh standard mode fails when kubectl context does not match expected EKS endpoint" \
  bash -c '! EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_STATUS="ACTIVE" MOCK_KUBE_ENDPOINT_MISMATCH=1 ops/destroy.sh'

run_test "destroy.sh standard mode aborts cleanly when operator rejects first confirmation" \
  bash -c 'out=$(echo "cancel" | EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_STATUS="ACTIVE" ops/destroy.sh); echo "$out" | grep -q "Workload teardown cancelled"'

run_test "destroy.sh standard mode aborts cleanly when operator rejects second confirmation" \
  bash -c 'out=$(printf "confirm-votex-workload-cleanup\ncancel\n" | EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_STATUS="ACTIVE" ops/destroy.sh); echo "$out" | grep -q "Terraform destroy aborted by operator"'

run_test "destroy.sh --recover-partial rejects when healthy ACTIVE EKS exists" \
  bash -c 'out=$(EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_STATUS="ACTIVE" ops/destroy.sh --recover-partial 2>&1 || true); echo "$out" | grep -q "is ACTIVE and healthy"'

run_test "destroy.sh --recover-partial rejects AWS AccessDenied" \
  bash -c 'out=$(EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_ACCESS_DENIED=1 ops/destroy.sh --recover-partial 2>&1) && exit 1; echo "$out" | grep -q "absence was not proven"'

run_test "destroy.sh --recover-partial rejects AWS timeout" \
  bash -c 'out=$(EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_TIMEOUT=1 ops/destroy.sh --recover-partial 2>&1) && exit 1; echo "$out" | grep -q "absence was not proven"'

run_test "destroy.sh --recover-partial rejects EKS CREATING" \
  bash -c 'out=$(EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_STATUS=CREATING ops/destroy.sh --recover-partial 2>&1) && exit 1; echo "$out" | grep -q "partial recovery refused"'

run_test "destroy.sh --recover-partial rejects EKS DELETING" \
  bash -c 'out=$(EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_STATUS=DELETING ops/destroy.sh --recover-partial 2>&1) && exit 1; echo "$out" | grep -q "partial recovery refused"'

run_test "destroy.sh --recover-partial rejects wrong EKS ARN" \
  bash -c 'out=$(EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_STATUS=FAILED MOCK_EKS_ARN_MISMATCH=1 ops/destroy.sh --recover-partial 2>&1) && exit 1; echo "$out" | grep -q "EKS identity mismatch"'

run_test "destroy.sh --recover-partial exits cleanly when Terraform state is empty" \
  bash -c 'out=$(EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_STATUS="ABSENT" MOCK_TF_STATE_EMPTY=1 ops/destroy.sh --recover-partial); echo "$out" | grep -q "tracks 0 resources"'

run_test "destroy.sh --recover-partial aborts when Terraform state is unavailable" \
  bash -c '! EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_STATUS="ABSENT" MOCK_TF_STATE_FAIL=1 ops/destroy.sh --recover-partial'

run_test "destroy.sh --recover-partial aborts cleanly when operator rejects confirmation" \
  bash -c 'out=$(echo "cancel" | EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_STATUS="ABSENT" ops/destroy.sh --recover-partial); echo "$out" | grep -q "Partial recovery destroy aborted"'

run_test "destroy.sh --recover-partial successfully plans and destroys partial VPC/NAT resources" \
  bash -c 'out=$(echo "confirm-partial-recovery-destroy" | EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_STATUS="ABSENT" MOCK_TF_STATE_RESOURCES="module.vpc.aws_vpc.this[0] module.vpc.aws_nat_gateway.this[0]" ops/destroy.sh --recover-partial); echo "$out" | grep -q "Teardown workflow completed cleanly"'

run_test "destroy.sh --recover-partial succeeds when EKS is in FAILED state with matching ARN" \
  bash -c 'out=$(echo "confirm-partial-recovery-destroy" | EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_STATUS="FAILED" ops/destroy.sh --recover-partial); echo "$out" | grep -q "PARTIAL RECOVERY AUTHORIZED"'

run_test "destroy.sh --recover-partial fails if Terraform state still tracks resources after destroy" \
  bash -c '! echo "confirm-partial-recovery-destroy" | EXPECTED_AWS_ACCOUNT_ID="123456789012" MOCK_EKS_STATUS="ABSENT" MOCK_TF_AFTER_DESTROY_LEFTOVERS=1 ops/destroy.sh --recover-partial'

echo ""
echo "=============================================================================="
echo "OPERATIONS TEST SUMMARY: $PASSED_TESTS / $TOTAL_TESTS passed ($FAILED_TESTS failed)"
echo "=============================================================================="

if [ "$FAILED_TESTS" -ne 0 ]; then
  exit 1
fi
exit 0
