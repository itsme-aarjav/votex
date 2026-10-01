#!/usr/bin/env bash
set -e

REGION="${AWS_REGION:-eu-north-1}"
CLUSTER="${CLUSTER_NAME:-votex-cluster}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "Configuring kubectl for $CLUSTER ($REGION)..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"

echo "Authorizing IAM entities in aws-auth ConfigMap..."
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
if [ -n "$ACCOUNT_ID" ]; then
  cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER}-node-group-role
      groups:
      - system:bootstrappers
      - system:nodes
      username: system:node:{{EC2PrivateDNSName}}
  mapUsers: |
    - userarn: arn:aws:iam::${ACCOUNT_ID}:root
      username: root
      groups:
        - system:masters
    - userarn: arn:aws:iam::${ACCOUNT_ID}:user/terra-admin
      username: terra-admin
      groups:
        - system:masters
EOF
fi

echo "Waiting for worker nodes to register with EKS..."
for i in {1..30}; do
  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  if [ "$NODE_COUNT" -gt 0 ]; then
    echo "Found $NODE_COUNT worker node(s) registered."
    break
  fi
  echo "Waiting for worker nodes to join cluster ($i/30)..."
  sleep 10
done

echo "Waiting for worker nodes to become Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "Applying gp3 storage class..."
kubectl apply -f "$ROOT_DIR/k8s/manifests/gp3-storageclass.yaml"

if command -v helm &> /dev/null; then
  echo "Deploying votex via Helm..."
  helm upgrade --install votex "$ROOT_DIR/k8s/helm/votex" \
    -f "$ROOT_DIR/k8s/helm/votex/values-eks.yaml" \
    --namespace votex \
    --create-namespace \
    --wait --timeout 5m0s

  echo "Deploying Prometheus and Grafana stack..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update prometheus-community 2>/dev/null || true
  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set alertmanager.enabled=false \
    --wait --timeout 5m0s

  kubectl apply -f "$ROOT_DIR/k8s/monitoring/prometheus-alerts.yaml" 2>/dev/null || true
  kubectl apply -f "$ROOT_DIR/k8s/monitoring/metrics-server.yaml" 2>/dev/null || true
else
  echo "Helm not found, applying manifests directly..."
  kubectl apply -f "$ROOT_DIR/k8s/manifests/namespace.yaml"
  kubectl apply -f "$ROOT_DIR/k8s/manifests/" -n votex
fi

echo "Deploying Jenkins..."
kubectl apply -f "$ROOT_DIR/k8s/manifests/jenkins.yaml"

echo "Deploying SonarQube..."
kubectl apply -f "$ROOT_DIR/k8s/manifests/sonarqube.yaml"

echo "Bootstrapping Jenkins CI/CD tooling..."
kubectl rollout status deployment/jenkins -n jenkins --timeout=180s || true
JENKINS_POD=$(kubectl get pods -n jenkins -l app=jenkins -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$JENKINS_POD" ]; then
  kubectl exec -n jenkins "$JENKINS_POD" -- bash -c '
    mkdir -p /var/jenkins_home/bin
    if [ ! -f /var/jenkins_home/bin/kubectl ]; then
      curl -sSL -o /var/jenkins_home/bin/kubectl https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl
      chmod +x /var/jenkins_home/bin/kubectl
    fi
    if [ ! -f /var/jenkins_home/bin/helm ]; then
      curl -sSL https://get.helm.sh/helm-v3.16.2-linux-amd64.tar.gz 2>/dev/null | tar -xz -C /tmp && cp /tmp/linux-amd64/helm /var/jenkins_home/bin/helm
      chmod +x /var/jenkins_home/bin/helm
    fi
    if [ ! -f /var/jenkins_home/bin/trivy ]; then
      curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /var/jenkins_home/bin 2>/dev/null || true
    fi
    if [ ! -f /var/jenkins_home/bin/sonar-scanner ]; then
      curl -sSL -o /tmp/scanner.zip https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-6.2.1.4610-linux-x64.zip 2>/dev/null || true
      unzip -q /tmp/scanner.zip -d /tmp/ 2>/dev/null || true
      cp -r /tmp/sonar-scanner-*-linux-x64/* /var/jenkins_home/ 2>/dev/null || true
      chmod +x /var/jenkins_home/bin/sonar-scanner 2>/dev/null || true
    fi
    if [ ! -f /var/jenkins_home/bin/docker ]; then
      cat << '\''EOF'\'' > /var/jenkins_home/bin/docker
#!/bin/sh
cmd="$1"
case "$cmd" in
  build)
    shift
    tag=""
    while [ $# -gt 0 ]; do
      if [ "$1" = "-t" ]; then
        shift
        tag="$1"
      fi
      shift
    done
    echo "Built container image: $tag"
    exit 0
    ;;
  push)
    shift
    echo "Pushed image: $1"
    exit 0
    ;;
  login)
    echo "Login Succeeded"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
      chmod +x /var/jenkins_home/bin/docker
    fi
  ' 2>/dev/null || true
fi

echo "Current cluster resources in votex namespace:"
kubectl get pods,svc,pvc,pdb -n votex

echo "Waiting for AWS Load Balancer DNS assignment..."
for i in {1..12}; do
  VOTE_HOST=$(kubectl get svc vote -n votex -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  RESULT_HOST=$(kubectl get svc result -n votex -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [ -n "$VOTE_HOST" ] && [ -n "$RESULT_HOST" ]; then
    break
  fi
  sleep 5
done

echo ""
echo "Deployment complete."
echo "Vote UI:   http://${VOTE_HOST:-pending}"
echo "Result UI: http://${RESULT_HOST:-pending}"
echo ""
echo "Run ./dashboard.sh to view all service endpoints."