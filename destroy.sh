#!/usr/bin/env bash
set -e

REGION="${AWS_REGION:-eu-north-1}"
CLUSTER="${CLUSTER_NAME:-votex-cluster}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/6] Stopping local port-forward processes..."
pkill -f "kubectl port-forward" 2>/dev/null || true

echo "[2/6] Deleting application workloads and services..."
if command -v helm &> /dev/null; then
  helm uninstall votex -n votex 2>/dev/null || true
  helm uninstall prometheus -n monitoring 2>/dev/null || true
fi
kubectl delete -f "$ROOT_DIR/k8s/manifests/" -n votex 2>/dev/null || true

echo "[3/6] Deleting PVCs to release AWS EBS storage volumes..."
kubectl delete pvc --all -n votex --timeout=45s 2>/dev/null || true
kubectl delete pvc --all -n jenkins --timeout=45s 2>/dev/null || true

echo "[4/6] Deleting namespaces..."
kubectl delete namespace votex --timeout=30s 2>/dev/null || true
kubectl delete namespace monitoring --timeout=30s 2>/dev/null || true
kubectl delete namespace jenkins --timeout=30s 2>/dev/null || true
kubectl delete namespace sonarqube --timeout=30s 2>/dev/null || true

echo "[5/6] Waiting for AWS Load Balancers to release..."
for i in {1..30}; do
  ACTIVE_ELBS=$(aws elb describe-load-balancers --region "$REGION" --query "LoadBalancerDescriptions[].LoadBalancerName" --output text 2>/dev/null || echo "")
  if [ -z "$ACTIVE_ELBS" ]; then
    echo "Load balancers released."
    break
  fi
  echo "Waiting for active ELB cleanup: $ACTIVE_ELBS ($i/30)..."
  sleep 5
done

# Buffer to allow AWS to release and detach ENIs from subnets
sleep 10

echo "[6/6] Destroying Terraform-managed infrastructure..."
cd "$ROOT_DIR/terraform"
terraform destroy -auto-approve

echo "Cleaning up local kubeconfig context..."
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
if [ -n "$ACCOUNT_ID" ]; then
  kubectl config delete-context "arn:aws:eks:${REGION}:${ACCOUNT_ID}:cluster/${CLUSTER}" 2>/dev/null || true
  kubectl config unset "clusters.arn:aws:eks:${REGION}:${ACCOUNT_ID}:cluster/${CLUSTER}" 2>/dev/null || true
fi

echo "Teardown complete."
