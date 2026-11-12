#!/usr/bin/env bash
# Votex Platform Safe Cloud Teardown Automation
# Systematically decommissions Kubernetes releases, storage volumes, and cloud infrastructure.
# Safely preserves the Terraform S3 remote state bucket and offline diagnostic evidence.
# Supports both standard full cluster teardown and safe partial-infrastructure recovery.

set -euo pipefail

RECOVERY_MODE=false
for arg in "$@"; do
  case "$arg" in
    --recover-partial|--recovery)
      RECOVERY_MODE=true
      ;;
    --help|-h)
      echo "Usage: ops/destroy.sh [--recover-partial]"
      echo "  (no flags)         Standard safe teardown of operational EKS cluster and workloads."
      echo "  --recover-partial  Safe recovery teardown when Terraform partially provisioned AWS"
      echo "                     infrastructure (VPC, NAT, IAM) but EKS is missing or failed."
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Run 'ops/destroy.sh --help' for usage." >&2
      exit 2
      ;;
  esac
done

REGION="${AWS_REGION:-eu-north-1}"
CLUSTER="${CLUSTER_NAME:-votex-cluster}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_DIR="$ROOT_DIR/reports/teardown-$(date +%Y%m%d-%H%M%S)"

echo "Starting Votex Platform Safe Cloud Teardown"
echo "Target AWS Region:  $REGION"
echo "Target EKS Cluster: $CLUSTER"
if [ "$RECOVERY_MODE" = true ]; then
  echo "Teardown Mode:      PARTIAL-INFRASTRUCTURE RECOVERY (--recover-partial)"
else
  echo "Teardown Mode:      STANDARD CLUSTER TEARDOWN"
fi

# Step 0: Ownership and Identity Verification (Mandatory for ALL modes)
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
  echo "ERROR: AWS caller account ($CURRENT_ACCOUNT) does not match EXPECTED_AWS_ACCOUNT_ID ($EXPECTED_AWS_ACCOUNT_ID)." >&2
  exit 1
fi
echo "Verified expected AWS account: $EXPECTED_AWS_ACCOUNT_ID"

if [ "$REGION" != "eu-north-1" ]; then
  echo "ERROR: AWS region mismatch. Target region must be strictly 'eu-north-1' (received: $REGION)." >&2
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

MANAGED_RESOURCES="$(terraform -chdir="$ROOT_DIR/terraform" state list 2>/dev/null)" ||
  { echo "ERROR: Unable to read Terraform state." >&2; exit 1; }

# Inspect EKS Cluster existence and state
set +e
EKS_DESCRIBE_OUT="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --output json 2>&1)"
EKS_DESCRIBE_EXIT=$?
set -e

EKS_STATUS=""
if [ "$EKS_DESCRIBE_EXIT" -eq 0 ]; then
  EKS_METADATA="$(printf '%s' "$EKS_DESCRIBE_OUT" | python3 -c '
import json, sys
cluster = json.load(sys.stdin)["cluster"]
status, arn = cluster["status"], cluster["arn"]
if not isinstance(status, str) or not isinstance(arn, str):
    sys.exit(1)
print(status + "|" + arn)
')" || { echo "ERROR: Invalid EKS describe-cluster response." >&2; exit 1; }
  IFS='|' read -r EKS_STATUS EKS_ARN <<< "$EKS_METADATA"
  EXPECTED_EKS_ARN="arn:aws:eks:${REGION}:${EXPECTED_AWS_ACCOUNT_ID}:cluster/${CLUSTER}"
  if [ "$EKS_ARN" != "$EXPECTED_EKS_ARN" ]; then
    echo "ERROR: EKS identity mismatch; refusing teardown." >&2
    exit 1
  fi
elif [[ "$EKS_DESCRIBE_OUT" == *"(ResourceNotFoundException)"* ]]; then
  EKS_STATUS="ABSENT"
else
  echo "ERROR: AWS EKS describe-cluster failed; cluster absence was not proven." >&2
  echo "$EKS_DESCRIBE_OUT" >&2
  exit 1
fi

if [ "$RECOVERY_MODE" = false ]; then
  # Standard Mode: Require healthy/active EKS cluster and valid kubectl context
  if [ "$EKS_STATUS" = "ABSENT" ]; then
    echo "ERROR: EKS cluster '$CLUSTER' was not found in region '$REGION'." >&2
    echo "Standard teardown requires an active cluster to drain workloads and delete ALBs safely." >&2
    echo "If Terraform provisioning failed before EKS was created, run partial recovery:" >&2
    echo "  ops/destroy.sh --recover-partial" >&2
    exit 1
  fi

  if [ "$EKS_STATUS" != "ACTIVE" ]; then
    echo "ERROR: EKS cluster '$CLUSTER' is in non-ready status '$EKS_STATUS'." >&2
    echo "Kubernetes workloads cannot be safely drained via kubectl." >&2
    echo "To tear down partially created infrastructure, run partial recovery:" >&2
    echo "  ops/destroy.sh --recover-partial" >&2
    exit 1
  fi

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

  EKS_ARN="$(echo "$EKS_DESCRIBE_OUT" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("cluster", {}).get("arn", ""))' 2>/dev/null || echo "")"
  EXPECTED_EKS_ARN="arn:aws:eks:${REGION}:${EXPECTED_AWS_ACCOUNT_ID}:cluster/${CLUSTER}"
  if [ "$EKS_ARN" != "$EXPECTED_EKS_ARN" ]; then
    echo "ERROR: AWS region, account or EKS cluster mismatch." >&2
    exit 1
  fi
  AWS_ENDPOINT="$(echo "$EKS_DESCRIBE_OUT" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("cluster", {}).get("endpoint", ""))' 2>/dev/null || echo "")"
  KUBE_ENDPOINT="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" ||
    { echo "ERROR: Cannot read active kubeconfig endpoint." >&2; exit 1; }
  if [ -z "$AWS_ENDPOINT" ] || [ "$AWS_ENDPOINT" != "$KUBE_ENDPOINT" ]; then
    echo "ERROR: kubectl context does not point to the verified EKS endpoint." >&2
    exit 1
  fi
else
  # Recovery Mode: Only allowed when EKS is absent or in failed/incomplete state
  case "$EKS_STATUS" in
    ABSENT|FAILED) ;;
    ACTIVE)
      echo "ERROR: EKS cluster '$CLUSTER' is ACTIVE and healthy; use standard teardown." >&2
      exit 1
      ;;
    *)
      echo "ERROR: EKS status '$EKS_STATUS' is transitional or unknown; partial recovery refused." >&2
      exit 1
      ;;
  esac

  if [ -z "$MANAGED_RESOURCES" ]; then
    echo "Terraform state tracks 0 resources. No partially created AWS resources to destroy."
    exit 0
  fi

  echo "PARTIAL RECOVERY AUTHORIZED: EKS cluster status is '$EKS_STATUS'."
  echo "Bypassing Kubernetes workload draining since cluster is absent or non-functional."
fi

echo "Preflight teardown authorization checks passed."
mkdir -p "$EVIDENCE_DIR"

if [ "$RECOVERY_MODE" = false ]; then
# Step 1: Capture pre-teardown diagnostics
echo "[1/10] Capturing pre-teardown cluster diagnostics..."
if kubectl get nodes >/dev/null 2>&1; then
  kubectl get nodes -o wide > "$EVIDENCE_DIR/nodes.txt" 2>&1 || true
  kubectl get pods -A -o wide > "$EVIDENCE_DIR/all-pods.txt" 2>&1 || true
  kubectl get ingress -A > "$EVIDENCE_DIR/ingress.txt" 2>&1 || true
  kubectl logs -n votex -l app=vote --tail=100 > "$EVIDENCE_DIR/vote-tail.log" 2>&1 || true
  kubectl logs -n votex -l app=worker --tail=100 > "$EVIDENCE_DIR/worker-tail.log" 2>&1 || true
  echo "Pre-teardown evidence saved to: $EVIDENCE_DIR"
else
  echo "Cluster unreachable or already offline; skipping evidence capture."
fi

read -r -p "Type 'confirm-votex-workload-cleanup' to begin deleting project Kubernetes resources: " WORKLOAD_CONFIRM
if [ "$WORKLOAD_CONFIRM" != "confirm-votex-workload-cleanup" ]; then
  echo "Workload teardown cancelled. No Kubernetes/AWS resources deleted."
  exit 0
fi

# Step 2: Preserve operator-owned local processes
echo "[2/10] Leaving local port-forward sessions under operator control."
NAMESPACES="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')" || {
  echo "ERROR: Namespace discovery failed; teardown cannot safely proceed." >&2
  exit 1
}
has_namespace() { [[ " $NAMESPACES " == *" $1 "* ]]; }

# Step 3: Delete project Ingress resources FIRST, keeping AWS Load Balancer Controller alive
echo "[3/10] Removing project Ingress resources (keeping ALB Controller active to reconcile)..."
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
  kubectl delete ingress/prometheus-grafana -n monitoring --ignore-not-found
  kubectl delete ingress/grafana-ingress -n monitoring --ignore-not-found
fi

# Step 4: Wait for AWS Load Balancer Controller to finish deleting ALBs in AWS ELBv2
echo "[4/10] Verifying AWS ELBv2 Application Load Balancer deprovisioning..."
if command -v aws >/dev/null 2>&1; then
  ALB_CLEANUP_SUCCESS=false
  for i in {1..35}; do
    set +e
    ACTIVE_ALB_OUTPUT=$(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[].LoadBalancerArn" --output text 2>&1)
    ALB_QUERY_EXIT=$?
    set -e

    if [ $ALB_QUERY_EXIT -ne 0 ]; then
      echo "ERROR: AWS ELBv2 describe-load-balancers query failed: $ACTIVE_ALB_OUTPUT" >&2
      echo "Teardown cannot verify ALB deletion safely without AWS API connectivity." >&2
      exit 1
    fi

    VOTEX_ALBS=""
    if [ -n "$ACTIVE_ALB_OUTPUT" ]; then
      for alb_arn in $ACTIVE_ALB_OUTPUT; do
        set +e
        IS_VOTEX=$(aws elbv2 describe-tags --region "$REGION" --resource-arns "$alb_arn" \
          --query "TagDescriptions[0].Tags[?Key=='ingress.k8s.aws/stack' && Value=='votex-platform'].Value" \
          --output text 2>&1)
        TAG_EXIT=$?
        set -e
        if [ $TAG_EXIT -ne 0 ]; then
          echo "ERROR: Failed to query tags for ALB $alb_arn: $IS_VOTEX" >&2
          echo "Teardown aborted: cannot verify ALB ownership safely." >&2
          exit 1
        fi
        if [ "$IS_VOTEX" = "votex-platform" ]; then
          VOTEX_ALBS="$VOTEX_ALBS $alb_arn"
        fi
      done
    fi

    if [ -z "$VOTEX_ALBS" ]; then
      echo "All project Application Load Balancers successfully deprovisioned by controller."
      ALB_CLEANUP_SUCCESS=true
      break
    fi
    echo "Waiting for project ALBs to release ($i/35): $VOTEX_ALBS"
    sleep 6
  done

  if [ "$ALB_CLEANUP_SUCCESS" = false ]; then
    echo "ERROR: Timed out waiting for Votex Application Load Balancers to deprovision." >&2
    echo "Do not uninstall the controller or proceed with Terraform destruction until ALBs release." >&2
    exit 1
  fi
fi

# Step 5: Now that ALBs are fully released, uninstall AWS Load Balancer Controller
echo "[5/10] Uninstalling AWS Load Balancer Controller..."
if has_namespace kube-system && helm status aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
  helm uninstall aws-load-balancer-controller -n kube-system
fi

# Step 6: Uninstall project-owned Helm releases and workloads
echo "[6/10] Removing Votex, CI/CD and observability workloads..."
for spec in "votex:votex" "prometheus:monitoring" "loki:monitoring" "alloy:logging"; do
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
if has_namespace jenkins; then
  kubectl delete configmap/jenkins-casc configmap/jenkins-agent-kubeconfig \
    secret/jenkins-admin-credentials secret/jenkins-pipeline-credentials \
    -n jenkins --ignore-not-found
fi
if has_namespace votex; then
  kubectl delete secret/db-secret configmap/votex-cluster-config -n votex --ignore-not-found
fi
if has_namespace monitoring; then
  kubectl delete secret/grafana-admin-credentials -n monitoring --ignore-not-found
fi

# Step 7: Remove exact project PVCs and release-owned monitoring PVCs
echo "[7/10] Releasing Votex PVCs and storage claims..."
OWNED_EBS_IDS="$(kubectl get pv -o json | python3 -c '
import json, sys
data = json.load(sys.stdin)
namespaces = {"votex", "jenkins", "sonarqube", "monitoring"}
for pv in data.get("items", []):
    claim = pv.get("spec", {}).get("claimRef", {})
    ns, name = claim.get("namespace", ""), claim.get("name", "")
    owned = (ns == "votex" and name in ("votex-db-pvc", "votex-redis-pvc")) or (ns == "jenkins" and name == "jenkins-pvc") or (ns == "sonarqube" and name == "sonarqube-data-pvc") or (ns == "monitoring" and any(x in name for x in ("prometheus", "loki", "grafana")))
    handle = pv.get("spec", {}).get("csi", {}).get("volumeHandle", "")
    if owned and handle.startswith("vol-"):
        print(handle)
' )" || {
  echo "ERROR: Cannot inventory owned EBS CSI volume IDs; refusing teardown." >&2
  exit 1
}
printf '%s\n' "$OWNED_EBS_IDS" > "$EVIDENCE_DIR/owned-ebs-volumes.txt"

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
  kubectl delete pvc/prometheus-grafana -n monitoring --ignore-not-found
fi

# Step 8: Verify EBS volume detachment
echo "[8/10] Verifying EBS volume detachment..."
if command -v aws >/dev/null 2>&1; then
  EBS_DETACH_SUCCESS=false
  for i in {1..20}; do
    set +e
    VOL_OUTPUT=$(aws ec2 describe-volumes --region "$REGION" \
      --filters "Name=tag:kubernetes.io/cluster/${CLUSTER},Values=owned,shared" "Name=status,Values=in-use" \
      --query "Volumes[].VolumeId" --output text 2>&1)
    VOL_EXIT=$?
    set -e
    if [ $VOL_EXIT -ne 0 ]; then
      echo "ERROR: aws ec2 describe-volumes query failed: $VOL_OUTPUT" >&2
      echo "Teardown aborted: cannot verify EBS volume detachment safely without EC2 API connectivity." >&2
      exit 1
    fi

    for owned_volume in $OWNED_EBS_IDS; do
      set +e
      OWNED_STATE="$(aws ec2 describe-volumes --region "$REGION" --filters "Name=volume-id,Values=$owned_volume" --query 'Volumes[].State' --output text 2>&1)"
      OWNED_EXIT=$?
      set -e
      if [ "$OWNED_EXIT" -ne 0 ]; then
        echo "ERROR: Could not verify CSI volume $owned_volume: $OWNED_STATE" >&2
        exit 1
      fi
      if [ -n "$OWNED_STATE" ] && [ "$OWNED_STATE" != "None" ]; then
        VOL_OUTPUT="$VOL_OUTPUT $owned_volume:$OWNED_STATE"
      fi
    done
    if [ -z "$VOL_OUTPUT" ]; then
      echo "All captured project CSI volume IDs removed; no matching in-use cluster-tagged volumes."
      EBS_DETACH_SUCCESS=true
      break
    fi
    echo "Waiting for EBS volumes to detach ($i/20): $VOL_OUTPUT"
    sleep 5
  done

  if [ "$EBS_DETACH_SUCCESS" = false ]; then
    echo "ERROR: Timed out waiting for EBS volumes to detach. In-use volumes remain: $VOL_OUTPUT" >&2
    echo "Teardown aborted: do NOT proceed with Terraform destruction while EBS volumes are attached." >&2
    exit 1
  fi
fi
else
  echo "[1/10 - 8/10] Skipped Kubernetes workload draining (partial-infrastructure recovery mode active)."
fi

# Step 9: Execute Terraform destruction plan
echo "[9/10] Planning and executing Terraform infrastructure destruction..."
cd "$ROOT_DIR/terraform"
echo "Generating Terraform destroy plan for operator inspection..."
OP_CIDR="${OPERATOR_CIDR:-${TF_VAR_cluster_endpoint_public_access_cidrs:-203.0.113.10/32}}"
terraform plan -destroy -input=false -var="cluster_endpoint_public_access_cidrs=[\"$OP_CIDR\"]" -out="$EVIDENCE_DIR/destroy.tfplan"
echo ""
echo "Destruction plan written to: $EVIDENCE_DIR/destroy.tfplan"
terraform show -no-color "$EVIDENCE_DIR/destroy.tfplan"
echo "Review the exact Terraform resource terminations above."

if [ "$RECOVERY_MODE" = true ]; then
  read -r -p "Type 'confirm-partial-recovery-destroy' to execute partial infrastructure destruction: " TF_CONFIRM
  if [ "$TF_CONFIRM" != "confirm-partial-recovery-destroy" ]; then
    echo "Partial recovery destroy aborted by operator. Core infrastructure preserved."
    exit 0
  fi
else
  read -r -p "Type 'confirm-terraform-destroy' to execute destruction: " TF_CONFIRM
  if [ "$TF_CONFIRM" != "confirm-terraform-destroy" ]; then
    echo "Terraform destroy aborted by operator. Core infrastructure preserved."
    exit 0
  fi
fi

terraform apply "$EVIDENCE_DIR/destroy.tfplan"
REMAINING_MANAGED_RESOURCES="$(terraform state list)" || {
  echo "ERROR: Could not verify Terraform state after destroy." >&2
  exit 1
}
if [ -n "$REMAINING_MANAGED_RESOURCES" ]; then
  echo "ERROR: Terraform still tracks resources after destroy: $REMAINING_MANAGED_RESOURCES" >&2
  exit 1
fi
rm -f "$ROOT_DIR/terraform/lambda.auto.tfvars"

# Step 10: Audit AWS resources and verify S3 bucket preservation
echo "[10/10] Auditing remaining cloud resources in $REGION..."
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
echo "Teardown workflow completed cleanly; S3 state bucket and evidence preserved."
echo "Diagnostic evidence retained in: $EVIDENCE_DIR"
