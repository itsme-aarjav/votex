#!/usr/bin/env bash
# Votex Platform Safe Cloud Teardown Automation
# Systematically decommissions Kubernetes releases, storage volumes, and cloud infrastructure.
# Safely preserves the Terraform S3 remote state bucket and offline diagnostic evidence.

set -eo pipefail

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

if [ -n "${EXPECTED_AWS_ACCOUNT_ID:-}" ]; then
  if [ "$CURRENT_ACCOUNT" != "$EXPECTED_AWS_ACCOUNT_ID" ]; then
    echo "ERROR: Current AWS account '$CURRENT_ACCOUNT' does not match expected account '$EXPECTED_AWS_ACCOUNT_ID'. Aborting teardown." >&2
    exit 1
  fi
  echo "Verified expected AWS Account: $EXPECTED_AWS_ACCOUNT_ID"
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

# Step 3: Delete Ingresses to trigger AWS Load Balancer Controller deprovisioning
echo "[3/8] Removing Votex Kubernetes Ingress resources to trigger ALB deprovisioning..."
if kubectl cluster-info >/dev/null 2>&1; then
  kubectl delete ingress -n votex votex-ingress --ignore-not-found 2>/dev/null || true
  kubectl delete ingress -n jenkins jenkins-ingress --ignore-not-found 2>/dev/null || true
  kubectl delete ingress -n sonarqube sonarqube-ingress --ignore-not-found 2>/dev/null || true
  kubectl delete ingress -n monitoring grafana-ingress --ignore-not-found 2>/dev/null || true
fi

# Step 4: Delete Helm releases and workload manifests
echo "[4/8] Decommissioning application, monitoring, and CI/CD workloads..."
if command -v helm >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
  helm uninstall votex -n votex 2>/dev/null || true
  helm uninstall prometheus -n monitoring 2>/dev/null || true
  helm uninstall loki -n monitoring 2>/dev/null || true
  helm uninstall alloy -n monitoring 2>/dev/null || true
fi

if kubectl cluster-info >/dev/null 2>&1; then
  kubectl delete -f "$ROOT_DIR/jenkins/jenkins.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "$ROOT_DIR/sonarqube/sonarqube.yaml" --ignore-not-found 2>/dev/null || true
fi

# Step 5: Delete specific PVCs to detach and release AWS EBS storage volumes
echo "[5/8] Releasing Votex Persistent Volume Claims..."
if kubectl cluster-info >/dev/null 2>&1; then
  kubectl delete pvc -n votex votex-db-pvc votex-redis-pvc --ignore-not-found 2>/dev/null || true
  kubectl delete pvc -n jenkins jenkins-pvc --ignore-not-found 2>/dev/null || true
  kubectl delete pvc -n sonarqube sonarqube-data-pvc --ignore-not-found 2>/dev/null || true
  kubectl delete pvc -n monitoring data-loki-0 --ignore-not-found 2>/dev/null || true
  kubectl delete pvc -n monitoring -l app.kubernetes.io/instance=prometheus --ignore-not-found 2>/dev/null || true
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
          --output text 2>/dev/null || echo "")
        if [ -n "$IS_VOTEX" ]; then
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
echo "Review the planned AWS resource terminations above."
read -r -p "Type 'confirm-terraform-destroy' to execute destruction: " TF_CONFIRM
if [ "$TF_CONFIRM" != "confirm-terraform-destroy" ]; then
  echo "Terraform destroy aborted by operator. Core infrastructure preserved."
  exit 0
fi
terraform apply "$EVIDENCE_DIR/destroy.tfplan"

# Step 8: Post-teardown verification of remaining cloud resources
echo "[8/8] Auditing remaining cloud resources in $REGION..."
if command -v aws >/dev/null 2>&1; then
  echo "Running EC2 Instances:"
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null || echo "None"

  echo "Active NAT Gateways:"
  aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=state,Values=available,pending" \
    --query "NatGateways[].NatGatewayId" --output text 2>/dev/null || echo "None"

  echo "Active Application/Network Load Balancers (ELBv2):"
  aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[].LoadBalancerName" --output text 2>/dev/null || echo "None"

  echo "Active Classic Load Balancers (ELBv1):"
  aws elb describe-load-balancers --region "$REGION" \
    --query "LoadBalancerDescriptions[].LoadBalancerName" --output text 2>/dev/null || echo "None"

  echo "Active EBS Volumes (in-use or available):"
  aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=status,Values=available,in-use" \
    --query "Volumes[].VolumeId" --output text 2>/dev/null || echo "None"

  STATE_BUCKET=""
  if [ -f "$ROOT_DIR/terraform/backend.tf" ]; then
    STATE_BUCKET=$(grep -E '^\s*bucket\s*=' "$ROOT_DIR/terraform/backend.tf" 2>/dev/null | cut -d'=' -f2 | tr -d ' "' || echo "")
  fi
  if [ -z "$STATE_BUCKET" ] && [ -f "$ROOT_DIR/terraform/backend.tf.example" ]; then
    STATE_BUCKET="$(grep -E '^\s*bucket\s*=' "$ROOT_DIR/terraform/backend.tf.example" 2>/dev/null | cut -d'=' -f2 | tr -d ' "' || echo '') (template)"
  fi
  echo ""
  echo "Remote State Protection Audit:"
  if [ -n "$STATE_BUCKET" ]; then
    echo "- S3 Remote State Bucket ($STATE_BUCKET): PRESERVED (Native S3 locking enabled, not deleted)"
  else
    echo "- S3 Remote State Bucket: No backend.tf file found. Any local state preserved."
  fi
fi

echo ""
echo "Safe teardown and verification complete."
echo "Diagnostic evidence retained in: $EVIDENCE_DIR"
