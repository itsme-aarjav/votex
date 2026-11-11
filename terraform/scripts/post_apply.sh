#!/usr/bin/env bash
set -eo pipefail

REGION="${AWS_REGION:-eu-north-1}"
CLUSTER="${CLUSTER_NAME:-votex-cluster}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TERRAFORM_DIR="$ROOT_DIR/terraform"

echo "Configuring kubectl for $CLUSTER ($REGION)..."
if ! aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"; then
  echo "ERROR: Failed to update kubeconfig for $CLUSTER in $REGION." >&2
  exit 1
fi

echo "Verifying EKS cluster connectivity..."
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: Unable to communicate with EKS cluster '$CLUSTER' in region '$REGION'." >&2
  echo "Ensure AWS credentials have sufficient EKS access and the control plane is active." >&2
  exit 1
fi

echo "Waiting for worker nodes to register with EKS..."
FOUND_NODES=false
for i in {1..30}; do
  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  if [ "$NODE_COUNT" -gt 0 ]; then
    echo "Found $NODE_COUNT worker node(s) registered."
    FOUND_NODES=true
    break
  fi
  echo "Waiting for worker nodes to join cluster ($i/30)..."
  sleep 10
done

if [ "$FOUND_NODES" != "true" ]; then
  echo "ERROR: Worker nodes failed to join the cluster within 300 seconds." >&2
  exit 1
fi

echo "Waiting for worker nodes to become Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "Verifying AWS EBS CSI Driver and IAM role handoff..."
EBS_ROLE="$(terraform -chdir="$TERRAFORM_DIR" output -raw ebs_csi_role_arn 2>/dev/null || echo "")"
if [ -n "$EBS_ROLE" ]; then
  echo "Verified EBS CSI IRSA role: $EBS_ROLE"
fi

echo "Applying and verifying gp3 StorageClass..."
kubectl apply -f "$ROOT_DIR/k8s/manifests/gp3-storageclass.yaml"
kubectl get storageclass gp3

if [ -f "$ROOT_DIR/k8s/monitoring/metrics-server.yaml" ]; then
  echo "Applying metrics-server for Kubernetes HPA..."
  kubectl apply -f "$ROOT_DIR/k8s/monitoring/metrics-server.yaml"
fi

echo "Ensuring namespace 'votex' exists..."
kubectl create namespace votex --dry-run=client -o yaml | kubectl apply -f -

echo "Checking database credentials secret in namespace 'votex'..."
if kubectl get secret db-secret -n votex >/dev/null 2>&1; then
  echo "Secret 'db-secret' already exists in namespace 'votex'; preserving existing database credentials."
else
  GET_ERR="$(kubectl get secret db-secret -n votex 2>&1 || true)"
  if echo "$GET_ERR" | grep -qi "notfound"; then
    echo "Bootstrapping secure 'db-secret' (POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB)..."
    openssl rand -hex 16 | tr -d '\n' | kubectl create secret generic db-secret \
      --namespace votex \
      --from-literal=POSTGRES_USER=postgres \
      --from-literal=POSTGRES_DB=postgres \
      --from-file=POSTGRES_PASSWORD=/dev/stdin \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "Secret 'db-secret' bootstrapped successfully."
  else
    echo "ERROR: Unable to verify secret existence (RBAC / connectivity failure): $GET_ERR" >&2
    exit 1
  fi
fi

echo "Publishing infrastructure parameters to cluster for Helm releases..."
OTEL_ROLE="$(terraform -chdir="$TERRAFORM_DIR" output -raw otel_collector_role_arn 2>/dev/null || echo "")"
if [ -z "$OTEL_ROLE" ] || [[ ! "$OTEL_ROLE" =~ ^arn:aws:iam::[0-9]+:role/.+ ]]; then
  echo "ERROR: Failed to retrieve a valid otel_collector_role_arn from Terraform outputs." >&2
  echo "Expected format: arn:aws:iam::<ACCOUNT_ID>:role/<ROLE_NAME>" >&2
  echo "Received: '$OTEL_ROLE'" >&2
  exit 1
fi

kubectl create configmap votex-cluster-config \
  --namespace votex \
  --from-literal=OTEL_COLLECTOR_ROLE_ARN="$OTEL_ROLE" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Successfully recorded OTEL_COLLECTOR_ROLE_ARN in ConfigMap votex/votex-cluster-config."

echo "Cluster infrastructure bootstrap complete."
echo "Application releases can now be deployed via Helm: helm upgrade --install votex k8s/helm/votex -f k8s/helm/votex/values-eks.yaml --namespace votex"
