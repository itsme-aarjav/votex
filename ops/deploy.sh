#!/usr/bin/env bash
# Votex Platform Deployment Automation
# Supports offline validation, read-only plan, and approval-gated full platform deployment.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
MODE="${1:---offline}"
REGION="${AWS_REGION:-eu-north-1}"
CLUSTER="${CLUSTER_NAME:-votex-cluster}"
ACCESS_MODE="${DEPLOY_ACCESS_MODE:-}"

CURRENT_STEP="Initialization"
handle_error() {
  local exit_code=$?
  local failed_line=$1
  echo "" >&2
  echo "==============================================================================" >&2
  echo "DEPLOYMENT FAILURE DETECTED at step: $CURRENT_STEP (line: $failed_line, exit code: $exit_code)" >&2
  echo "==============================================================================" >&2
  echo "The deployment did not complete. DO NOT assume the platform is UP." >&2
  echo "State preservation policy: Remote Terraform state has NOT been rolled back" >&2
  echo "to prevent orphaned AWS resource dependencies." >&2
  echo "" >&2
  echo "Recovery instructions:" >&2
  echo "  1. Review the specific error log above." >&2
  echo "  2. Review cluster status with: kubectl get nodes,pods -A" >&2
  echo "  3. To resume or retry after fixing the blocker, re-run:" >&2
  echo "     EXPECTED_AWS_ACCOUNT_ID=\"\${EXPECTED_AWS_ACCOUNT_ID}\" OPERATOR_CIDR=\"\${OPERATOR_CIDR}\" ops/deploy.sh --full" >&2
  echo "  4. To tear down partially provisioned resources cleanly, run:" >&2
  echo "     ops/destroy.sh (or 'ops/destroy.sh --recover-partial' if EKS was not reached)" >&2
  echo "==============================================================================" >&2
  exit "$exit_code"
}
trap 'handle_error $LINENO' ERR

case "$MODE" in
  --offline|--plan|--full) ;;
  --help|-h)
    echo "Usage: ops/deploy.sh [--offline|--plan|--full]"
    echo "  --offline  Format, initialize without backend, validate. No AWS calls (default)."
    echo "  --plan     Read-only AWS-backed Terraform plan; requires initialized S3 backend."
    echo "  --full     Complete approved platform deployment workflow with strict preflights."
    exit 0
    ;;
  *)
    echo "Unknown option: $MODE" >&2
    echo "Run 'ops/deploy.sh --help' for usage." >&2
    exit 2
    ;;
esac

command -v terraform >/dev/null 2>&1 || { echo "ERROR: terraform CLI is required" >&2; exit 1; }

echo "Votex deployment mode: $MODE"

if [ "$MODE" = "--offline" ]; then
  CURRENT_STEP="Offline Validation"
  echo "Executing offline configuration checks..."
  terraform -chdir="$TF_DIR" fmt -check -recursive
  terraform -chdir="$TF_DIR" init -backend=false -lockfile=readonly -input=false
  terraform -chdir="$TF_DIR" validate
  echo "Offline configuration checks completed successfully; AWS live plan and apply not executed."
  exit 0
fi

if [ "$MODE" = "--plan" ]; then
  CURRENT_STEP="Terraform Plan Preflight"
  if [ ! -f "$TF_DIR/backend.tf" ]; then
    echo "ERROR: Initialized S3 backend configuration required for --plan." >&2
    exit 1
  fi
  OP_CIDR="${OPERATOR_CIDR:-${TF_VAR_cluster_endpoint_public_access_cidrs:-}}"
  if [ -z "$OP_CIDR" ]; then
    echo "ERROR: OPERATOR_CIDR is required for --plan to evaluate EKS public access CIDRs." >&2
    echo "Example: export OPERATOR_CIDR=\"$(curl -s https://checkip.amazonaws.com 2>/dev/null || echo '203.0.113.50')/32\"" >&2
    exit 1
  fi
  if [[ "$OP_CIDR" == "0.0.0.0/0" ]]; then
    echo "ERROR: Unrestricted 0.0.0.0/0 operator CIDR is strictly prohibited." >&2
    exit 1
  fi
  if [[ ! "$OP_CIDR" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    echo "ERROR: OPERATOR_CIDR '$OP_CIDR' is not a valid IPv4 CIDR string." >&2
    exit 1
  fi

  terraform -chdir="$TF_DIR" fmt -check -recursive
  terraform -chdir="$TF_DIR" init -lockfile=readonly -input=false
  terraform -chdir="$TF_DIR" validate
  terraform -chdir="$TF_DIR" plan -input=false -var="cluster_endpoint_public_access_cidrs=[\"$OP_CIDR\"]" -out="$TF_DIR/tfplan"
  echo "Terraform plan saved to terraform/tfplan for human review. No apply executed."
  exit 0
fi

# ==============================================================================
# FULL PLATFORM DEPLOYMENT WORKFLOW (--full)
# ==============================================================================

echo "Starting Votex Full Platform Deployment Workflow"

# Step 1: Verify AWS identity
CURRENT_STEP="[1/24] AWS Identity Verification"
echo "$CURRENT_STEP..."
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI is required but not found in PATH." >&2; exit 1; }
CURRENT_ACCOUNT="$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null || echo "")"
if [ -z "$CURRENT_ACCOUNT" ]; then
  echo "ERROR: AWS caller identity could not be authenticated. Check credentials and region." >&2
  exit 1
fi

# Step 2: Verify exact expected account
CURRENT_STEP="[2/24] Target AWS Account Validation"
echo "$CURRENT_STEP..."
if [[ ! "${EXPECTED_AWS_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]]; then
  echo "ERROR: Set mandatory EXPECTED_AWS_ACCOUNT_ID to your exact 12-digit AWS account ID before deploying." >&2
  exit 1
fi
if [ "$CURRENT_ACCOUNT" != "$EXPECTED_AWS_ACCOUNT_ID" ]; then
  echo "ERROR: AWS caller account ($CURRENT_ACCOUNT) does not match EXPECTED_AWS_ACCOUNT_ID ($EXPECTED_AWS_ACCOUNT_ID)." >&2
  exit 1
fi
echo "Verified AWS account: $CURRENT_ACCOUNT"

# Step 3: Verify region eu-north-1
CURRENT_STEP="[3/24] AWS Region Validation"
echo "$CURRENT_STEP..."
if [ "$REGION" != "eu-north-1" ]; then
  echo "ERROR: Region mismatch. Target region must be strictly 'eu-north-1' (received: $REGION)." >&2
  exit 1
fi
echo "Verified region: $REGION"

# Step 4: Verify operator CIDR
CURRENT_STEP="[4/24] Operator CIDR Validation"
echo "$CURRENT_STEP..."
OP_CIDR="${OPERATOR_CIDR:-${TF_VAR_cluster_endpoint_public_access_cidrs:-${TF_VAR_operator_cidr:-}}}"
if [ -z "$OP_CIDR" ]; then
  echo "ERROR: OPERATOR_CIDR is required to restrict EKS public API access." >&2
  echo "Example: export OPERATOR_CIDR=\"$(curl -s https://checkip.amazonaws.com 2>/dev/null || echo '203.0.113.50')/32\"" >&2
  exit 1
fi
if [[ "$OP_CIDR" == "0.0.0.0/0" ]]; then
  echo "ERROR: Unrestricted 0.0.0.0/0 operator CIDR is strictly prohibited." >&2
  exit 1
fi
if [[ ! "$OP_CIDR" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
  echo "ERROR: OPERATOR_CIDR '$OP_CIDR' is not a valid IPv4 CIDR string." >&2
  exit 1
fi
echo "Verified operator CIDR: $OP_CIDR"

# Step 5: Verify required CLI tools
CURRENT_STEP="[5/24] Required CLI Tools Verification"
echo "$CURRENT_STEP..."
for tool in terraform kubectl helm python3 openssl curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: Required tool '$tool' is missing." >&2; exit 1; }
done

# Step 6: Verify Public HTTPS or Internal-Only Ingress Preflight (Phase 4)
CURRENT_STEP="[6/24] Access Mode & Ingress Preflight Validation"
echo "$CURRENT_STEP..."
if [ "${DEPLOY_ACCESS_MODE:-}" = "internal" ]; then
  ACCESS_MODE="internal"
  echo "WARNING: EXPLICIT INTERNAL-ONLY RECOVERY/TEST MODE SELECTED."
  echo "Public ALB Ingress disabled. Workloads accessible only via internal ClusterIP / kubectl port-forward."
  echo "NOTE: This mode does NOT satisfy full online public deployment acceptance."
else
  ACCESS_MODE="public"
  echo "Verifying Public HTTPS deployment prerequisites (Full Production Mode)..."
  MISSING_INPUTS=()
  if [ -z "${APP_DOMAIN:-}" ]; then
    MISSING_INPUTS+=("APP_DOMAIN: Operator-owned fully qualified domain (e.g. votex.yourdomain.com)")
  elif [[ "$APP_DOMAIN" == *"domain.tld"* || "$APP_DOMAIN" == *"example.com"* || "$APP_DOMAIN" == "localhost" ]]; then
    MISSING_INPUTS+=("APP_DOMAIN: Placeholder domain '$APP_DOMAIN' is prohibited for live public deployment")
  elif [[ ! "$APP_DOMAIN" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+$ ]]; then
    MISSING_INPUTS+=("APP_DOMAIN: '$APP_DOMAIN' is not a valid fully qualified domain name")
  fi

  if [ -z "${ACM_CERTIFICATE_ARN:-}" ]; then
    MISSING_INPUTS+=("ACM_CERTIFICATE_ARN: Valid ACM certificate ARN in region eu-north-1")
  elif [[ ! "$ACM_CERTIFICATE_ARN" =~ ^arn:aws:acm:eu-north-1:[0-9]{12}:certificate/.+ ]]; then
    MISSING_INPUTS+=("ACM_CERTIFICATE_ARN: '$ACM_CERTIFICATE_ARN' is not a valid ARN in region eu-north-1")
  fi

  if [ ${#MISSING_INPUTS[@]} -gt 0 ]; then
    echo "ERROR: Full production deployment requires public HTTPS prerequisites:" >&2
    for input_err in "${MISSING_INPUTS[@]}"; do
      echo "  - $input_err" >&2
    done
    echo "" >&2
    echo "Supply APP_DOMAIN and ACM_CERTIFICATE_ARN for full deployment." >&2
    echo "For isolated offline testing or disaster recovery only, explicitly set DEPLOY_ACCESS_MODE=internal." >&2
    exit 1
  fi
  echo "Verified public domain: $APP_DOMAIN"
  echo "Verified ACM certificate: $ACM_CERTIFICATE_ARN"
fi

# Step 7: Verify Initial Application Images before billable provisioning (Issue 4)
CURRENT_STEP="[7/24] Preflight Initial Application Image Availability"
echo "$CURRENT_STEP..."
for img_tuple in "aarjavjainn/votex-vote:v2.0.0" "aarjavjainn/votex-result:v2.0.0" "aarjavjainn/votex-worker:v2.0.0"; do
  repo="${img_tuple%%:*}"
  tag="${img_tuple##*:}"
  echo "Verifying image availability: $repo:$tag on Docker Hub..."
  IMG_JSON=$(curl -s "https://hub.docker.com/v2/repositories/$repo/tags/$tag" 2>/dev/null || echo "")
  if ! echo "$IMG_JSON" | grep -q "\"name\": *\"$tag\""; then
    echo "ERROR: Required bootstrap image '$repo:$tag' does not exist in registry." >&2
    echo "Initial images must be published before provisioning live cluster infrastructure." >&2
    exit 1
  fi
  if ! echo "$IMG_JSON" | grep -q "\"architecture\": *\"amd64\""; then
    echo "ERROR: Image '$repo:$tag' does not provide required 'amd64' architecture for m7i-flex.large nodes." >&2
    exit 1
  fi
  echo "Verified bootstrap image: $repo:$tag (amd64)"
done

if [ -z "${VOTEX_DOCKERHUB_USERNAME:-}" ] || [ -z "${VOTEX_DOCKERHUB_TOKEN:-}" ]; then
  echo "ERROR: Supply VOTEX_DOCKERHUB_USERNAME and VOTEX_DOCKERHUB_TOKEN securely before paid provisioning." >&2
  echo "These inputs are needed to bootstrap actual Jenkins credentials; the pipeline will not use placeholders." >&2
  exit 1
fi

# Step 8: Verify S3 backend/bootstrap prerequisites
CURRENT_STEP="[8/24] Terraform Remote State Backend Verification"
echo "$CURRENT_STEP..."
if [ ! -f "$TF_DIR/backend.tf" ]; then
  echo "ERROR: terraform/backend.tf is missing. Run S3 backend initialization first." >&2
  exit 1
fi
BACKEND_META="$TF_DIR/.terraform/terraform.tfstate"
if [ ! -f "$BACKEND_META" ]; then
  echo "ERROR: Terraform state metadata missing. Run 'terraform init' in terraform/ first." >&2
  exit 1
fi
STATE_BUCKET="$(python3 - "$BACKEND_META" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        backend = json.load(f).get("backend") or {}
    config = backend.get("config") or {}
    bucket = config.get("bucket")
    if backend.get("type") != "s3" or not bucket:
        raise ValueError("S3 backend bucket missing")
    print(bucket)
except Exception as err:
    print(f"Invalid backend: {err}", file=sys.stderr)
    sys.exit(1)
PY
)" || { echo "ERROR: Could not parse remote state bucket." >&2; exit 1; }
aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1 || {
  echo "ERROR: Remote state bucket '$STATE_BUCKET' is inaccessible." >&2
  exit 1
}

# Step 9: Display infrastructure plan and cost warning
CURRENT_STEP="[9/24] Terraform Execution Plan Generation"
echo "$CURRENT_STEP..."
terraform -chdir="$TF_DIR" init -lockfile=readonly -input=false
terraform -chdir="$TF_DIR" validate
terraform -chdir="$TF_DIR" plan -input=false -var="cluster_endpoint_public_access_cidrs=[\"$OP_CIDR\"]" -out="$TF_DIR/tfplan"

echo ""
echo "=============================================================================="
echo "COST WARNING & APPROVAL GATE:"
echo "Target: EKS Option B (2x m7i-flex.large) in $REGION."
echo "Costs include EKS control plane, 2 EC2 workers, NAT, ALB, EBS, logging and data transfer; verify current AWS pricing before approval."
echo "Explicit human authorization is required before provisioning live AWS resources."
echo "=============================================================================="
echo ""

# Step 10: Require explicit human confirmation before billable changes
CURRENT_STEP="[10/24] Operator Confirmation Gate"
echo "$CURRENT_STEP..."
read -r -p "Type 'deploy-votex' to confirm live infrastructure provisioning: " CONFIRMATION
if [ "$CONFIRMATION" != "deploy-votex" ]; then
  echo "Deployment aborted by operator. Zero cloud resources modified."
  exit 0
fi

# Step 11: Provision approved Terraform infrastructure
CURRENT_STEP="[11/24] Applying Terraform Infrastructure Plan"
echo "$CURRENT_STEP..."
terraform -chdir="$TF_DIR" apply -input=false "$TF_DIR/tfplan"

# Step 12: Configure kubectl for the exact EKS cluster
CURRENT_STEP="[12/24] Kubernetes Context Configuration"
echo "$CURRENT_STEP for $CLUSTER in $REGION..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
kubectl cluster-info

# Step 13: Verify exact two-node EKS capacity & readiness (Issue 11)
CURRENT_STEP="[13/24] Worker Node Count & Instance Type Verification"
echo "$CURRENT_STEP..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
NODE_COUNT="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
if [ "$NODE_COUNT" -ne 2 ]; then
  echo "ERROR: Expected exactly 2 worker nodes, found $NODE_COUNT." >&2
  exit 1
fi
READY_COUNT="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | awk '$1 == "True" { n++ } END { print n+0 }')"
if [ "$READY_COUNT" -ne 2 ]; then
  echo "ERROR: Expected 2 Ready nodes, but only $READY_COUNT are Ready." >&2
  exit 1
fi
NODE_TYPES="$(kubectl get nodes -o jsonpath='{.items[*].metadata.labels.node\.kubernetes\.io/instance-type}')"
for ntype in $NODE_TYPES; do
  if [ "$ntype" != "m7i-flex.large" ]; then
    echo "ERROR: Node instance type '$ntype' does not match approved 'm7i-flex.large'." >&2
    exit 1
  fi
done
echo "Verified exactly 2 worker node(s) Ready on approved instance type 'm7i-flex.large'."

# Step 14: Verify EBS CSI and gp3 storage
CURRENT_STEP="[14/24] StorageClass gp3 Verification"
echo "$CURRENT_STEP..."
kubectl apply -f "$ROOT_DIR/k8s/manifests/gp3-storageclass.yaml"
kubectl get storageclass gp3

# Step 15: Apply metrics-server for Kubernetes HPA
CURRENT_STEP="[15/24] Kubernetes Metrics Server Deployment"
echo "$CURRENT_STEP..."
if [ -f "$ROOT_DIR/k8s/monitoring/metrics-server.yaml" ]; then
  kubectl apply -f "$ROOT_DIR/k8s/monitoring/metrics-server.yaml"
fi

# Step 16: Install and verify AWS Load Balancer Controller (Issue 1)
CURRENT_STEP="[16/24] AWS Load Balancer Controller Installation"
echo "$CURRENT_STEP..."
OTEL_ROLE="$(terraform -chdir="$TF_DIR" output -raw otel_collector_role_arn 2>/dev/null || echo "")"
ALB_ROLE="$(terraform -chdir="$TF_DIR" output -raw aws_lb_controller_role_arn 2>/dev/null || echo "")"
VPC_ID="$(terraform -chdir="$TF_DIR" output -raw vpc_id 2>/dev/null || echo "")"

if [ -z "$OTEL_ROLE" ] || [[ ! "$OTEL_ROLE" =~ ^arn:aws:iam::[0-9]+:role/.+ ]]; then
  echo "ERROR: Failed to retrieve a valid otel_collector_role_arn from Terraform outputs." >&2
  exit 1
fi
if [ -z "$ALB_ROLE" ] || [[ ! "$ALB_ROLE" =~ ^arn:aws:iam::[0-9]+:role/.+ ]]; then
  echo "ERROR: Failed to retrieve a valid aws_lb_controller_role_arn from Terraform outputs." >&2
  exit 1
fi
if [ -z "$VPC_ID" ]; then
  echo "ERROR: Failed to retrieve vpc_id from Terraform outputs." >&2
  exit 1
fi

echo "Installing AWS Load Balancer Controller (pinned chart v1.8.2)..."
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update eks >/dev/null 2>&1 || true

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 1.8.2 \
  --namespace kube-system \
  --set clusterName="$CLUSTER" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ALB_ROLE" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --wait --timeout 300s

kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s
kubectl get ingressclass alb >/dev/null 2>&1 || {
  echo "ERROR: IngressClass 'alb' not available after controller installation." >&2
  exit 1
}
echo "AWS Load Balancer Controller successfully initialized and IngressClass 'alb' active."

# Step 17: Create required namespaces and secrets safely (Issue 7)
CURRENT_STEP="[17/24] Namespaces and Credentials Bootstrapping"
echo "$CURRENT_STEP..."
for ns in votex monitoring logging jenkins sonarqube; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# Record cluster config for Helm releases
kubectl create configmap votex-cluster-config \
  --namespace votex \
  --from-literal=OTEL_COLLECTOR_ROLE_ARN="$OTEL_ROLE" \
  --dry-run=client -o yaml | kubectl apply -f -

# Bootstrap application database secret if not already existing
if ! kubectl get secret db-secret -n votex >/dev/null 2>&1; then
  echo "Bootstrapping secure db-secret in votex namespace..."
  openssl rand -hex 16 | tr -d '\n' | kubectl create secret generic db-secret \
    --namespace votex \
    --from-literal=POSTGRES_USER=postgres \
    --from-literal=POSTGRES_DB=postgres \
    --from-file=POSTGRES_PASSWORD=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "Preserving existing db-secret in votex namespace."
fi

# Bootstrap Jenkins administrator secret if not already existing
if ! kubectl get secret jenkins-admin-credentials -n jenkins >/dev/null 2>&1; then
  echo "Bootstrapping secure jenkins-admin-credentials in jenkins namespace..."
  openssl rand -hex 16 | tr -d '\n' | kubectl create secret generic jenkins-admin-credentials \
    --namespace jenkins \
    --from-file=jenkins-admin-password=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "Preserving existing jenkins-admin-credentials in jenkins namespace."
fi

# Bootstrap SonarQube administrator secret if not already existing
if ! kubectl get secret sonarqube-admin-credentials -n sonarqube >/dev/null 2>&1; then
  echo "Bootstrapping sonarqube-admin-credentials in sonarqube namespace..."
  echo "No SonarQube admin credentials stored. Configure the real administrator account in SonarQube, then supply a valid API token for webhook setup."
else
  echo "Preserving existing sonarqube-admin-credentials in sonarqube namespace."
fi

# Step 18: Deploy Vote, Result, Worker, Redis and PostgreSQL
CURRENT_STEP="[18/24] Core Application Deployment via Helm"
echo "$CURRENT_STEP..."
helm upgrade --install votex "$ROOT_DIR/k8s/helm/votex" \
  --namespace votex \
  --values "$ROOT_DIR/k8s/helm/votex/values-eks.yaml" \
  --set otel.collector.serviceAccount.roleArn="$OTEL_ROLE" \
  --wait --timeout 300s

# Step 19: Deploy kube-prometheus-stack, Grafana, Loki and Alloy
CURRENT_STEP="[19/24] Observability Stack Deployment"
echo "$CURRENT_STEP (Prometheus, Grafana, Loki, Alloy)..."
if ! kubectl get secret grafana-admin-credentials -n monitoring >/dev/null 2>&1; then
  openssl rand -hex 12 | tr -d '\n' | kubectl create secret generic grafana-admin-credentials \
    --namespace monitoring \
    --from-literal=admin-user=admin \
    --from-file=admin-password=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community grafana >/dev/null 2>&1 || true

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values "$ROOT_DIR/k8s/monitoring/values-prometheus.yaml" \
  --wait --timeout 300s

helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --values "$ROOT_DIR/k8s/monitoring/values-loki.yaml" \
  --wait --timeout 300s

helm upgrade --install alloy grafana/alloy \
  --namespace logging \
  --values "$ROOT_DIR/k8s/monitoring/values-alloy.yaml" \
  --wait --timeout 300s

if [ -f "$ROOT_DIR/k8s/monitoring/prometheus-alerts.yaml" ]; then
  kubectl apply -f "$ROOT_DIR/k8s/monitoring/prometheus-alerts.yaml"
fi

# Step 20: Deploy Jenkins, SonarQube, and configure Quality Gate webhook (Phase 2 & Phase 3)
CURRENT_STEP="[20/24] CI/CD Infrastructure & Quality Gate Webhook Configuration"
echo "$CURRENT_STEP..."
kubectl apply -f "$ROOT_DIR/sonarqube/sonarqube.yaml"

echo "Waiting for SonarQube rollout and health readiness..."
kubectl rollout status deployment/sonarqube -n sonarqube --timeout=300s

SONAR_TOKEN="${SONARQUBE_API_TOKEN:-${SONAR_AUTH_TOKEN:-}}"
if [ -z "$SONAR_TOKEN" ]; then
  echo "SonarQube requires one-time administrator initialization and API token creation."
  echo "Use the existing Kubernetes deployment to initialize SonarQube privately, rotate its default password, and create a Webhooks-admin API token."
  read -r -s -p "Enter the approved SonarQube administrator API token (hidden input): " SONAR_TOKEN
  echo
fi
if [ -z "$SONAR_TOKEN" ]; then
  echo "ERROR: A real SonarQube API token is mandatory. Nothing will be reported as CI/CD-ready." >&2
  exit 1
fi

export VOTEX_DOCKERHUB_USERNAME VOTEX_DOCKERHUB_TOKEN
export VOTEX_SONARQUBE_TOKEN="${VOTEX_SONARQUBE_TOKEN:-$SONAR_TOKEN}"
python3 -c '
import os, json, base64
keys = ("VOTEX_DOCKERHUB_USERNAME", "VOTEX_DOCKERHUB_TOKEN", "VOTEX_SONARQUBE_TOKEN")
data = {key: base64.b64encode(os.environ[key].encode()).decode() for key in keys}
print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":"jenkins-pipeline-credentials","namespace":"jenkins"},"type":"Opaque","data":data}))
' | kubectl apply -f -

cat <<'KUBE' | kubectl create configmap jenkins-agent-kubeconfig -n jenkins --from-file=kubeconfig=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -
apiVersion: v1
kind: Config
clusters:
- name: in-cluster
  cluster:
    server: https://kubernetes.default.svc.cluster.local
    certificate-authority: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
contexts:
- name: jenkins
  context:
    cluster: in-cluster
    namespace: votex
    user: jenkins
current-context: jenkins
users:
- name: jenkins
  user:
    tokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
KUBE

kubectl apply -f "$ROOT_DIR/jenkins/jenkins.yaml"
kubectl rollout status deployment/jenkins -n jenkins --timeout=300s

SONAR_POD="$(kubectl get pod -l app=sonarqube -n sonarqube -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"
if [ -z "$SONAR_POD" ]; then
  echo "ERROR: SonarQube pod not found. Webhook cannot be configured." >&2
  exit 1
fi

CURL_AUTH_CFG="header = \"Authorization: Bearer $SONAR_TOKEN\""
echo "Using the approved SonarQube API token for webhook configuration."

echo "Configuring SonarQube Quality Gate webhook for Jenkins (idempotent & verified)..."
WEBHOOK_SUCCESS=false
for i in $(seq 1 40); do
  STATUS=$(kubectl exec -n sonarqube "$SONAR_POD" -- curl -s "http://localhost:9000/api/system/status" 2>/dev/null || echo "")
  if echo "$STATUS" | grep -q '"status":"UP"'; then
    JENKINS_PING=$(kubectl exec -n sonarqube "$SONAR_POD" -- curl -s -o /dev/null -w "%{http_code}" "http://jenkins.jenkins.svc.cluster.local:8080/login" 2>/dev/null || echo "")
    if [ "$JENKINS_PING" != "200" ]; then
      echo "Waiting for Jenkins internal endpoint to become responsive (status: $JENKINS_PING)..."
      sleep 5
      continue
    fi

    LIST_RESP=$(printf '%s\n' "$CURL_AUTH_CFG" | kubectl exec -i -n sonarqube "$SONAR_POD" -- curl -s --config - -w "\n%{http_code}" "http://localhost:9000/api/webhooks/list" 2>/dev/null || echo "")
    HTTP_LIST_CODE=$(echo "$LIST_RESP" | tail -n 1)
    LIST_JSON=$(echo "$LIST_RESP" | sed '$d')

    if [ "$HTTP_LIST_CODE" = "401" ] || [ "$HTTP_LIST_CODE" = "403" ]; then
      echo "ERROR: SonarQube authentication failed (HTTP $HTTP_LIST_CODE). Webhook registration cannot proceed." >&2
      exit 1
    fi

    ALREADY_CONFIGURED=$(python3 -c "
import json, sys
try:
    data = json.loads('''$LIST_JSON''')
    hooks = data.get('webhooks', [])
    target_name = 'Jenkins'
    target_url = 'http://jenkins.jenkins.svc.cluster.local:8080/sonarqube-webhook/'
    found = any(h.get('name') == target_name and h.get('url') == target_url for h in hooks)
    print('true' if found else 'false')
except Exception:
    print('false')
" 2>/dev/null || echo "false")

    if [ "$ALREADY_CONFIGURED" = "true" ]; then
      echo "SonarQube Quality Gate webhook already configured and verified with matching name and URL."
      WEBHOOK_SUCCESS=true
      break
    fi

    CREATE_RESP=$(printf '%s\n' "$CURL_AUTH_CFG" | kubectl exec -i -n sonarqube "$SONAR_POD" -- curl -s --config - -w "\n%{http_code}" -X POST "http://localhost:9000/api/webhooks/create?name=Jenkins&url=http://jenkins.jenkins.svc.cluster.local:8080/sonarqube-webhook/" 2>/dev/null || echo "")
    HTTP_CREATE_CODE=$(echo "$CREATE_RESP" | tail -n 1)
    CREATE_JSON=$(echo "$CREATE_RESP" | sed '$d')

    if [ "$HTTP_CREATE_CODE" = "200" ] || [ "$HTTP_CREATE_CODE" = "201" ] || [ "$HTTP_CREATE_CODE" = "204" ]; then
      VERIFIED_NAME=$(python3 -c "
import json, sys
try:
    data = json.loads('''$CREATE_JSON''')
    print(data.get('webhook', {}).get('name', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")
      if [ "$VERIFIED_NAME" = "Jenkins" ]; then
        echo "SonarQube Quality Gate webhook registered and verified successfully."
        WEBHOOK_SUCCESS=true
        break
      fi
    elif [ "$HTTP_CREATE_CODE" = "401" ] || [ "$HTTP_CREATE_CODE" = "403" ]; then
      echo "ERROR: SonarQube webhook creation unauthorized (HTTP $HTTP_CREATE_CODE)." >&2
      exit 1
    else
      echo "SonarQube webhook registration returned HTTP $HTTP_CREATE_CODE, retrying..."
    fi
  fi
  sleep 4
done

if [ "$WEBHOOK_SUCCESS" != "true" ]; then
  echo "ERROR: Failed to establish SonarQube Quality Gate webhook callback to Jenkins." >&2
  exit 1
fi

# Step 21: Configure Ingress (Public HTTPS or Internal-only)
CURRENT_STEP="[21/24] Ingress Configuration"
echo "$CURRENT_STEP..."
if [ "$ACCESS_MODE" = "public" ]; then
  echo "Applying production ALB Ingress with verified domain ($APP_DOMAIN) and ACM certificate..."
  helm upgrade votex "$ROOT_DIR/k8s/helm/votex" \
    --namespace votex \
    --reuse-values \
    --set ingress.enabled=true \
    --set "ingress.annotations.alb\.ingress\.kubernetes\.io/certificate-arn=$ACM_CERTIFICATE_ARN" \
    --set "ingress.hosts[0].host=vote.$APP_DOMAIN" \
    --set "ingress.hosts[1].host=result.$APP_DOMAIN" \
    --set "vote.env.resultUrl=https://result.$APP_DOMAIN" \
    --set "result.env.voteUrl=https://vote.$APP_DOMAIN"

  if [ -f "$ROOT_DIR/jenkins/jenkins-ingress.yaml" ]; then
    sed -e "s/jenkins\.votex\.domain\.tld/jenkins.$APP_DOMAIN/g" \
        -e "s|alb\.ingress\.kubernetes\.io/ssl-redirect: \"443\"|alb.ingress.kubernetes.io/ssl-redirect: \"443\"\n    alb.ingress.kubernetes.io/certificate-arn: \"$ACM_CERTIFICATE_ARN\"|g" \
        "$ROOT_DIR/jenkins/jenkins-ingress.yaml" | kubectl apply -f -
  fi

  if [ -f "$ROOT_DIR/sonarqube/sonarqube-ingress.yaml" ]; then
    sed -e "s/sonarqube\.votex\.domain\.tld/sonarqube.$APP_DOMAIN/g" \
        -e "s|alb\.ingress\.kubernetes\.io/ssl-redirect: \"443\"|alb.ingress.kubernetes.io/ssl-redirect: \"443\"\n    alb.ingress.kubernetes.io/certificate-arn: \"$ACM_CERTIFICATE_ARN\"|g" \
        "$ROOT_DIR/sonarqube/sonarqube-ingress.yaml" | kubectl apply -f -
  fi

  helm upgrade prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --reuse-values \
    --set grafana.ingress.enabled=true \
    --set "grafana.ingress.annotations.alb\.ingress\.kubernetes\.io/certificate-arn=$ACM_CERTIFICATE_ARN" \
    --set "grafana.ingress.hosts[0]=grafana.$APP_DOMAIN"
else
  echo "Internal-only mode selected. Public Ingresses remain disabled."
  echo "Services accessible via internal ClusterIP / kubectl port-forward."
fi

# Step 22: Complete Lambda Deployment Integration (Phase 7)
CURRENT_STEP="[22/24] External Lambda Synthetic Monitoring Integration"
echo "$CURRENT_STEP..."
if [ "$ACCESS_MODE" = "public" ]; then
  echo "Testing public health endpoints for Lambda synthetic monitoring..."
  VOTE_OK=false
  RESULT_OK=false
  for i in $(seq 1 20); do
    if curl -s -f -o /dev/null --connect-timeout 3 "https://vote.$APP_DOMAIN/api/health"; then VOTE_OK=true; fi
    if curl -s -f -o /dev/null --connect-timeout 3 "https://result.$APP_DOMAIN/api/health"; then RESULT_OK=true; fi
    if [ "$VOTE_OK" = true ] && [ "$RESULT_OK" = true ]; then
      break
    fi
    sleep 5
  done

  if [ "$VOTE_OK" = true ] && [ "$RESULT_OK" = true ]; then
    echo "Enabling AWS Lambda synthetic health verifier via persistent Terraform configuration..."
    cat <<EOF > "$TF_DIR/lambda.auto.tfvars"
enable_health_check_lambda = true
vote_health_url            = "https://vote.$APP_DOMAIN/api/health"
result_health_url          = "https://result.$APP_DOMAIN/api/health"
EOF
    echo "Executing complete Terraform reconciliation plan for Lambda module..."
    terraform -chdir="$TF_DIR" plan -input=false -var="cluster_endpoint_public_access_cidrs=[\"$OP_CIDR\"]" -out="$TF_DIR/lambda-reconcile.tfplan"
    terraform -chdir="$TF_DIR" apply "$TF_DIR/lambda-reconcile.tfplan"
    rm -f "$TF_DIR/lambda-reconcile.tfplan"
    aws lambda get-function --function-name "${CLUSTER}-synthetic-health-check" --region "$REGION" >/dev/null || {
      echo "ERROR: Lambda apply finished but the expected synthetic monitoring function was not verified." >&2
      exit 1
    }
    echo "AWS Lambda synthetic monitoring successfully deployed and independently verified."
  else
    echo "ERROR: Public HTTPS health endpoints unavailable; required synthetic monitoring cannot be verified." >&2
    echo "Terraform Lambda desired configuration is preserved; investigate DNS/ACM/Ingress before retrying." >&2
    exit 1
  fi
else
  echo "Lambda Synthetic Monitoring: Disabled (public HTTPS domain and ACM certificate required)."
  echo "Existing Lambda Terraform configuration is preserved; no implicit disable or destroy."
fi

# Step 23: Complete Platform Component Readiness Verification (Issue 9)
CURRENT_STEP="[23/24] Full Platform Component Readiness Verification"
echo "$CURRENT_STEP..."
kubectl rollout status deployment/vote -n votex --timeout=120s
kubectl rollout status deployment/result -n votex --timeout=120s
kubectl rollout status deployment/worker -n votex --timeout=120s
kubectl rollout status deployment/db -n votex --timeout=120s
kubectl rollout status deployment/redis -n votex --timeout=120s
kubectl rollout status deployment/ebs-csi-controller -n kube-system --timeout=120s
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s
kubectl rollout status deployment/jenkins -n jenkins --timeout=120s
kubectl rollout status deployment/sonarqube -n sonarqube --timeout=120s
kubectl rollout status deployment/prometheus-grafana -n monitoring --timeout=120s
kubectl rollout status statefulset/loki -n monitoring --timeout=120s
kubectl rollout status daemonset/alloy -n logging --timeout=120s

# Step 24: Final Deployment Summary
CURRENT_STEP="[24/24] Completion Summary"
echo "$CURRENT_STEP..."
echo ""
echo "=============================================================================="
echo "VOTEX PLATFORM DEPLOYMENT SUMMARY:"
echo "EKS Cluster:      $CLUSTER ($REGION)"
echo "AWS Account:      $CURRENT_ACCOUNT"
echo "Nodes:            $NODE_COUNT Ready (m7i-flex.large)"
echo "Access Mode:      $ACCESS_MODE"
echo "Core App:         Deployed & Ready (votex namespace)"
echo "Monitoring:       Deployed & Ready (monitoring: Prometheus, Grafana, Loki)"
echo "Logging:          Deployed & Ready (logging: Alloy daemonset)"
echo "CI/CD:            Deployed & Ready (jenkins, sonarqube with Quality Gate webhook)"
echo "ALB Controller:   Active (kube-system, IngressClass alb)"
echo ""
echo "Execute 'ops/dashboard.sh' to inspect endpoints and access details."
echo "=============================================================================="
