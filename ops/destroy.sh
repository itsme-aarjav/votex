#!/usr/bin/env bash
set -eo pipefail

REGION="${AWS_REGION:-eu-north-1}"
CLUSTER="${CLUSTER_NAME:-votex-cluster}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_DIR="$ROOT_DIR/reports/teardown-$(date +%Y%m%d-%H%M%S)"

echo "Votex Platform Safe Cloud Teardown"
echo "Target AWS Region:  $REGION"
echo "Target EKS Cluster: $CLUSTER"
echo ""
echo "This action will systematically decommission Votex-owned workloads"
echo "and Terraform-managed infrastructure."
echo ""
read -r -p "Type 'destroy-votex' to confirm teardown: " CONFIRMATION
if [ "$CONFIRMATION" != "destroy-votex" ]; then
  echo "Teardown aborted by operator. Zero resources modified."
  exit 0
fi

# Step 1: Capture pre-destruction diagnostic evidence
echo "[1/7] Preserving deployment state and evidence..."
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
echo "[2/7] Terminating local port-forward tunnels..."
pkill -f "kubectl port-forward.*(vote|result|jenkins|sonarqube)" 2>/dev/null || true

# Step 3: Delete Votex-owned Helm releases and workloads
echo "[3/7] Decommissioning Votex application releases..."
if command -v helm >/dev/null 2>&1; then
  if helm status votex -n votex >/dev/null 2>&1; then
    helm uninstall votex -n votex
  fi
fi

if kubectl get deployment jenkins -n jenkins >/dev/null 2>&1; then
  kubectl delete -f "$ROOT_DIR/jenkins/jenkins.yaml" --ignore-not-found
fi

if kubectl get deployment sonarqube -n sonarqube >/dev/null 2>&1; then
  kubectl delete -f "$ROOT_DIR/sonarqube/sonarqube.yaml" --ignore-not-found
fi

# Step 4: Delete targeted PVCs to release AWS EBS storage volumes
echo "[4/7] Releasing Votex-owned Persistent Volume Claims..."
kubectl delete pvc votex-db-pvc votex-redis-pvc -n votex --ignore-not-found 2>/dev/null || true
kubectl delete pvc jenkins-pvc -n jenkins --ignore-not-found 2>/dev/null || true

echo "Waiting for Persistent Volumes to detach and delete..."
for i in {1..30}; do
  VOTEX_PVCS=$(kubectl get pvc votex-db-pvc votex-redis-pvc -n votex --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  JENKINS_PVCS=$(kubectl get pvc jenkins-pvc -n jenkins --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  if [ "$VOTEX_PVCS" -eq 0 ] && [ "$JENKINS_PVCS" -eq 0 ]; then
    echo "All Votex (votex-db-pvc, votex-redis-pvc) and Jenkins (jenkins-pvc) PVCs confirmed released."
    break
  fi
  sleep 3
done

# Step 5: Wait for AWS Load Balancers to release
echo "[5/7] Verifying AWS Elastic Load Balancer deprovisioning..."
for i in {1..40}; do
  ACTIVE_ELBS=$(aws elb describe-load-balancers --region "$REGION" \
    --query "LoadBalancerDescriptions[?contains(LoadBalancerName, 'votex') || Instances[?contains(InstanceId, 'i-')]].LoadBalancerName" \
    --output text 2>/dev/null || echo "")
  if [ -z "$ACTIVE_ELBS" ]; then
    echo "Cluster Load Balancers successfully released."
    break
  fi
  echo "Waiting for Load Balancers to release ($i/40): $ACTIVE_ELBS"
  sleep 5
done

# Step 6: Generate and review Terraform destruction plan
echo "[6/7] Planning and executing Terraform infrastructure destruction..."
cd "$ROOT_DIR/terraform"
echo "Generating Terraform destroy plan for review..."
terraform plan -destroy -out="$EVIDENCE_DIR/destroy.tfplan"
echo ""
echo "Destruction plan saved to: $EVIDENCE_DIR/destroy.tfplan"
echo "Review the resource deletions above carefully."
read -r -p "Type 'confirm-terraform-destroy' to apply destruction plan: " TF_CONFIRM
if [ "$TF_CONFIRM" != "confirm-terraform-destroy" ]; then
  echo "Terraform destroy aborted by operator. Infrastructure preserved."
  exit 0
fi
terraform apply "$EVIDENCE_DIR/destroy.tfplan"

# Step 7: Post-teardown verification of remaining cloud resources
echo "[7/7] Auditing remaining cloud resources in $REGION..."
echo "Running EC2 Instances:"
aws ec2 describe-instances --region "$REGION" \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text

echo "Active NAT Gateways:"
aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=state,Values=available,pending" \
  --query "NatGateways[].NatGatewayId" --output text

echo "Active Classic Load Balancers:"
aws elb describe-load-balancers --region "$REGION" \
  --query "LoadBalancerDescriptions[].LoadBalancerName" --output text

echo "Active EBS Volumes (in-use or available):"
aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=status,Values=available,in-use" \
  --query "Volumes[].VolumeId" --output text

echo ""
echo "Teardown and cloud audit verification complete."
