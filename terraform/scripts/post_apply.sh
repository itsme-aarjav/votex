#!/usr/bin/env bash
set -e

REGION="${AWS_REGION:-eu-north-1}"
CLUSTER="${CLUSTER_NAME:-votex-cluster}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "==> Configuring kubectl for $CLUSTER ($REGION)..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"

echo "==> Waiting for worker nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s || true

echo "==> Applying gp3 storage class..."
kubectl apply -f "$ROOT_DIR/k8s/manifests/gp3-storageclass.yaml"

if command -v helm &> /dev/null; then
  echo "==> Deploying votex via helm..."
  helm upgrade --install votex "$ROOT_DIR/k8s/helm/votex" \
    -f "$ROOT_DIR/k8s/helm/votex/values-eks.yaml" \
    --namespace votex \
    --create-namespace \
    --wait --timeout 5m0s || true

  echo "==> Deploying Prometheus & Grafana Monitoring stack..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update prometheus-community 2>/dev/null || true
  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set alertmanager.enabled=false \
    --wait --timeout 5m0s || true

  kubectl apply -f "$ROOT_DIR/k8s/monitoring/prometheus-alerts.yaml" 2>/dev/null || true
else
  echo "==> Helm not found, applying manifests directly..."
  kubectl apply -f "$ROOT_DIR/k8s/manifests/namespace.yaml"
  kubectl apply -f "$ROOT_DIR/k8s/manifests/" -n votex
fi

echo "==> Current cluster resources in votex namespace:"
kubectl get pods,svc,pvc,pdb -n votex

echo "==> Monitoring stack in monitoring namespace:"
kubectl get pods,svc -n monitoring 2>/dev/null || true

echo "==> Service endpoints:"
kubectl get svc -n votex | grep -E "vote|result|NAME" || true
