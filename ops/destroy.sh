#!/usr/bin/env bash
# Votex Platform Safe Cloud Teardown Automation
# Systematically decommissions Kubernetes releases, storage volumes, and cloud infrastructure.
# Safely preserves the Terraform S3 remote state bucket and offline diagnostic evidence.

set -euo pipefail

REGION="${AWS_REGION:-eu-north-1}"
CLUSTER="${CLUSTER_NAME:-votex-cluster}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_DIR="$ROOT_DIR/reports/teardown-$(date +%Y%m%d-%H%M%S)"

echo "Starting Votex Platform Safe Cloud Teardown"
echo "Target AWS Region:  $REGION"
echo "Target EKS Cluster: $CLUSTER"

# Step 0: Ownership and Identity Verification
echo "Verifying AWS account and cluster identity..."
if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: AWS CLI is required but not installed or found in PATH. Aborting teardown." >&2
  exit 1
fi

CURRENT_ACCOUNT=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null || echo "")
if [ -z "$CURRENT_ACCOUNT" ]; then
  echo "ERROR: AWS caller identity could not be authenticated. Check AWS credentials and region. Aborting teardown." >&2
  exit 1
fi
echo "AWS Account ID:     $CURRENT_ACCOUNT"

if [[ ! "${EXPECTED_AWS_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]]; then
  echo "ERROR: Set mandatory EXPECTED_AWS_ACCOUNT_ID to your intended AWS account." >&2
  exit 1
fi
if [ "$CURRENT_ACCOUNT" != "$EXPECTED_AWS_ACCOUNT_ID" ]; then
  echo "ERROR: AWS caller account does not match EXPECTED_AWS_ACCOUNT_ID." >&2
  exit 1
fi
echo "Verified expected AWS account: $EXPECTED_AWS_ACCOUNT_ID"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl CLI is required but not found in PATH. Aborting teardown." >&2
  exit 1
fi

CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")
if [ -z "$CURRENT_CONTEXT" ]; then
  echo "ERROR: No active kubectl context found. Aborting teardown." >&2
  exit 1
fi
echo "Kubernetes Context: $CURRENT_CONTEXT"

# Strictly reject local emulation contexts from production teardown
if [[ "$CURRENT_CONTEXT" =~ "docker-desktop" ]] || [[ "$CURRENT_CONTEXT" =~ "minikube" ]] || [[ "$CURRENT_CONTEXT" =~ "kind-" ]]; then
  echo "ERROR: Current context '$CURRENT_CONTEXT' is a local development cluster, not target EKS cluster '$CLUSTER'. Aborting teardown." >&2
  exit 1
fi

if [[ ! "$CURRENT_CONTEXT" =~ "$CLUSTER" ]]; then
  CLUSTER_IN_CONTEXT=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${CURRENT_CONTEXT}')].context.cluster}" 2>/dev/null || echo "")
  if [[ ! "$CLUSTER_IN_CONTEXT" =~ "$CLUSTER" ]]; then
    echo "ERROR: Current kubectl context '$CURRENT_CONTEXT' does not target expected EKS cluster '$CLUSTER'. Aborting teardown." >&2
    exit 1
  fi
fi

# Verify exact EKS identity and initialized S3 backend before deleting anything
EKS_ARN="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --query 'cluster.arn' --output text)" ||
  { echo "ERROR: Unable to verify EKS cluster identity." >&2; exit 1; }
EXPECTED_EKS_ARN="arn:aws:eks:${REGION}:${EXPECTED_AWS_ACCOUNT_ID}:cluster/${CLUSTER}"
if [ "$EKS_ARN" != "$EXPECTED_EKS_ARN" ]; then
  echo "ERROR: AWS region, account or EKS cluster mismatch." >&2
  exit 1
fi
AWS_ENDPOINT="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --query 'cluster.endpoint' --output text)" ||
  { echo "ERROR: Cannot retrieve EKS endpoint." >&2; exit 1; }
KUBE_ENDPOINT="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" ||
  { echo "ERROR: Cannot read active kubeconfig endpoint." >&2; exit 1; }
if [ -z "$AWS_ENDPOINT" ] || [ "$AWS_ENDPOINT" != "$KUBE_ENDPOINT" ]; then
  echo "ERROR: kubectl context does not point to the verified EKS endpoint." >&2
  exit 1
fi
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required to validate state backend." >&2; exit 1; }
BACKEND_META="$ROOT_DIR/terraform/.terraform/terraform.tfstate"
if [ ! -f "$BACKEND_META" ]; then
  echo "ERROR: Initialized Terraform S3 backend metadata missing." >&2
  exit 1
fi
STATE_BUCKET="$(python3 - "$BACKEND_META" <<'PY'
import json
import sys
try:
    with open(sys.argv[1]) as f:
        backend = json.load(f).get("backend") or {}
    config = backend.get("config") or {}
    bucket = config.get("bucket")
    if backend.get("type") != "s3" or not bucket or config.get("use_lockfile") is not True:
        raise ValueError("S3 bucket/native locking missing")
    print(bucket)
except Exception as error:
    print(f"Invalid backend metadata: {error}", file=sys.stderr)
    sys.exit(1)
PY
)" || exit 1
aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null ||
  { echo "ERROR: Remote state bucket not accessible." >&2; exit 1; }
terraform -chdir="$ROOT_DIR/terraform" state list >/dev/null ||
  { echo "ERROR: Cannot inspect Terraform remote state." >&2; exit 1; }
kubectl cluster-info >/dev/null ||
  { echo "ERROR: Target Kubernetes API is unreachable." >&2; exit 1; }
helm list -A >/dev/null ||
  { echo "ERROR: Cannot inspect Helm releases in target cluster." >&2; exit 1; }

echo ""
echo "WARNING: This action will systematically decommission Votex-owned"
echo "workloads, monitoring, CI/CD, and Terraform-managed EKS infrastructure."
echo "Remote S3 state buckets and local test evidence are strictly preserved."
echo ""
read -r -p "Type 'destroy-votex' to confirm teardown: " CONFIRMATION
if [ "$CONFIRMATION" != "destroy-votex" ]; then
  echo "Teardown aborted by operator. Zero resources modified."
  exit 0
fi

# Step 1: Capture pre-destruction diagnostic evidence
echo "[1/8] Preserving deployment state and evidence..."
mkdir -p "$EVIDENCE_DIR"
if kubectl cluster-info >/dev/null 2>&1; then
  kubectl get pods,svc,pvc,ingress,nodes -A -o wide > "$EVIDENCE_DIR/cluster-state.txt" 2>&1 || true
  kubectl logs -n votex -l app=vote --tail=100 > "$EVIDENCE_DIR/vote-tail.log" 2>&1 || true
  kubectl logs -n votex -l app=worker --tail=100 > "$EVIDENCE_DIR/worker-tail.log" 2>&1 || true
  echo "Pre-teardown evidence saved to: $EVIDENCE_DIR"
else
  echo "Cluster unreachable or already offline; skipping evidence capture."
fi

# Step 2: Stop local proxy processes
echo "[2/8] Terminating local port-forward tunnels..."
pkill -f "kubectl port-forward.*(vote|result|jenkins|sonarqube|grafana|prometheus)" 2>/dev/null || true

# Step 3: Delete exact project Ingresses, never shared namespaces
echo "[3/8] Removing project Ingress resources..."
NAMESPACES="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')"
has_namespace() { [[ " $NAMESPACES " == *" $1 "* ]]; }
if has_namespace votex; then
  kubectl delete ingress/votex-ingress -n votex --ignore-not-found
fi
if has_namespace jenkins; then
  kubectl delete ingress/jenkins-ingress -n jenkins --ignore-not-found
fi
if has_namespace sonarqube; then
  kubectl delete ingress/sonarqube-ingress -n sonarqube --ignore-not-found
fi
if has_namespace monitoring; then
  kubectl delete ingress/grafana-ingress -n monitoring --ignore-not-found
fi

# Step 4: Uninstall only project-owned releases and workloads
echo "[4/8] Removing Votex, CI/CD and observability workloads..."
for spec in "votex:votex" "prometheus:monitoring" "loki:monitoring" "alloy:monitoring"; do
  release="${spec%%:*}"
  ns="${spec#*:}"
  if has_namespace "$ns" && helm status "$release" -n "$ns" >/dev/null 2>&1; then
    helm uninstall "$release" -n "$ns"
  fi
done
if has_namespace jenkins; then
  kubectl delete deployment/jenkins service/jenkins serviceaccount/jenkins \
    role/jenkins-agent-role rolebinding/jenkins-agent-binding -n jenkins --ignore-not-found
fi
if has_namespace votex; then
  kubectl delete role/jenkins-deployer-role rolebinding/jenkins-deployer-binding -n votex --ignore-not-found
fi
kubectl delete clusterrole/jenkins-cluster-viewer \
  clusterrolebinding/jenkins-cluster-viewer-binding --ignore-not-found
if has_namespace sonarqube; then
  kubectl delete deployment/sonarqube service/sonarqube -n sonarqube --ignore-not-found
fi

# Step 5: Remove exact project PVCs and release-owned monitoring PVCs
echo "[5/8] Releasing Votex PVCs..."
if has_namespace votex; then
  kubectl delete pvc/votex-db-pvc pvc/votex-redis-pvc -n votex --ignore-not-found
fi
if has_namespace jenkins; then
  kubectl delete pvc/jenkins-pvc -n jenkins --ignore-not-found
fi
if has_namespace sonarqube; then
  kubectl delete pvc/sonarqube-data-pvc -n sonarqube --ignore-not-found
fi
if has_namespace monitoring; then
  kubectl delete pvc -n monitoring -l 'app.kubernetes.io/instance=loki,app.kubernetes.io/name=loki' --ignore-not-found
  kubectl delete pvc -n monitoring -l 'app.kubernetes.io/instance=prometheus' --ignore-not-found
fi

# Step 6: Wait for AWS Application Load Balancers (ELBv2) to release
echo "[6/8] Verifying AWS ELBv2 Application Load Balancer deprovisioning..."
if command -v aws >/dev/null 2>&1; then
  ALB_CLEANUP_SUCCESS=false
  for i in {1..30}; do
    set +e
    ACTIVE_ALB_OUTPUT=$(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[].LoadBalancerArn" --output text 2>&1)
    ALB_QUERY_EXIT=$?
    set -e

    if [ $ALB_QUERY_EXIT -ne 0 ]; then
      echo "WARNING: AWS ELBv2 query returned error (attempt $i/30): $ACTIVE_ALB_OUTPUT"
      sleep 6
      continue
    fi

    VOTEX_ALBS=""
    if [ -n "$ACTIVE_ALB_OUTPUT" ]; then
      for alb_arn in $ACTIVE_ALB_OUTPUT; do
        IS_VOTEX=$(aws elbv2 describe-tags --region "$REGION" --resource-arns "$alb_arn" \
          --query "TagDescriptions[0].Tags[?Key=='ingress.k8s.aws/stack' && Value=='votex-platform'].Value" \
          --output text) || { echo "ERROR: ALB ownership lookup failed." >&2; exit 1; }
        if [ "$IS_VOTEX" = "votex-platform" ]; then
          VOTEX_ALBS="$VOTEX_ALBS $alb_arn"
        fi
      done
    fi

    if [ -z "$VOTEX_ALBS" ]; then
      echo "All Votex Application Load Balancers successfully deprovisioned."
      ALB_CLEANUP_SUCCESS=true
      break
    fi
    echo "Waiting for Votex ALBs to release ($i/30): $VOTEX_ALBS"
    sleep 6
  done

  if [ "$ALB_CLEANUP_SUCCESS" = false ]; then
    echo "ERROR: Timed out waiting for Votex Application Load Balancers to deprovision." >&2
    echo "Do not proceed with Terraform destruction until ALBs release to prevent orphaned VPC dependencies." >&2
    exit 1
  fi
fi

# Step 7: Execute Terraform destruction plan
echo "[7/8] Planning and executing Terraform infrastructure destruction..."
cd "$ROOT_DIR/terraform"
echo "Generating Terraform destroy plan for operator inspection..."
terraform plan -destroy -out="$EVIDENCE_DIR/destroy.tfplan"
echo ""
echo "Destruction plan written to: $EVIDENCE_DIR/destroy.tfplan"
terraform show -no-color "$EVIDENCE_DIR/destroy.tfplan"
echo "Review the exact Terraform resource terminations above."
read -r -p "Type 'confirm-terraform-destroy' to execute destruction: " TF_CONFIRM
if [ "$TF_CONFIRM" != "confirm-terraform-destroy" ]; then
  echo "Terraform destroy aborted by operator. Core infrastructure preserved."
  exit 0
fi
terraform apply "$EVIDENCE_DIR/destroy.tfplan"

# Step 8: Audit AWS resources without converting access errors into "None"
echo "[8/8] Auditing remaining cloud resources in $REGION..."
audit_aws() {
  local label="$1"
  shift
  echo "$label"
  "$@" || { echo "ERROR: AWS audit failed for $label; teardown cannot be certified." >&2; exit 1; }
}
audit_aws "Running EC2 instances:" aws ec2 describe-instances --region "$REGION" \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text
audit_aws "Active NAT Gateways:" aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=state,Values=available,pending" --query "NatGateways[].NatGatewayId" --output text
audit_aws "Application/Network Load Balancers:" aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[].LoadBalancerName" --output text
audit_aws "Classic Load Balancers:" aws elb describe-load-balancers --region "$REGION" \
  --query "LoadBalancerDescriptions[].LoadBalancerName" --output text
audit_aws "EBS volumes:" aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=status,Values=available,in-use" --query "Volumes[].VolumeId" --output text
aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null ||
  { echo "ERROR: Preserved S3 state bucket is inaccessible." >&2; exit 1; }
echo "Preserved remote S3 state bucket verified: $STATE_BUCKET"

echo ""
echo "Teardown commands finished; inspect remaining project-owned resources before claiming zero residual charges."
echo "Diagnostic evidence retained in: $EVIDENCE_DIR"
