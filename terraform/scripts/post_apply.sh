#!/usr/bin/env bash
set -e

REGION="${AWS_REGION:-eu-north-1}"
CLUSTER="${CLUSTER_NAME:-votex-cluster}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "==> Configuring kubectl for $CLUSTER ($REGION)..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"

echo "==> Waiting for worker nodes to register with EKS..."
for i in {1..30}; do
  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  if [ "$NODE_COUNT" -gt 0 ]; then
    echo "==> Found $NODE_COUNT worker node(s) registered."
    break
  fi
  echo "==> Waiting for worker nodes to join cluster... ($i/30)"
  sleep 10
done

echo "==> Waiting for worker nodes to become Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s


echo "==> Applying gp3 storage class..."
kubectl apply -f "$ROOT_DIR/k8s/manifests/gp3-storageclass.yaml"

if command -v helm &> /dev/null; then
  echo "==> Deploying votex via helm..."
  helm upgrade --install votex "$ROOT_DIR/k8s/helm/votex" \
    -f "$ROOT_DIR/k8s/helm/votex/values-eks.yaml" \
    --namespace votex \
    --create-namespace \
    --wait --timeout 5m0s

  echo "==> Deploying Prometheus & Grafana Monitoring stack..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update prometheus-community 2>/dev/null || true
  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set alertmanager.enabled=false \
    --wait --timeout 5m0s

  kubectl apply -f "$ROOT_DIR/k8s/monitoring/prometheus-alerts.yaml" 2>/dev/null || true
else
  echo "==> Helm not found, applying manifests directly..."
  kubectl apply -f "$ROOT_DIR/k8s/manifests/namespace.yaml"
  kubectl apply -f "$ROOT_DIR/k8s/manifests/" -n votex
fi

echo "==> Current cluster resources in votex namespace:"
kubectl get pods,svc,pvc,pdb -n votex

echo "==> Waiting for AWS Load Balancer DNS assignment..."
for i in {1..12}; do
  VOTE_HOST=$(kubectl get svc vote -n votex -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  RESULT_HOST=$(kubectl get svc result -n votex -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [ -n "$VOTE_HOST" ] && [ -n "$RESULT_HOST" ]; then
    break
  fi
  sleep 5
done

echo ""
echo "================================================================="
echo " Microservices & Monitoring Endpoints:"
echo " Vote UI:       http://${VOTE_HOST:-pending}"
echo " Result UI:     http://${RESULT_HOST:-pending}"
echo ""
echo " Observability Access (Port-Forward):"
echo " Grafana:    kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80"
echo " Prometheus: kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090"
echo "================================================================="

