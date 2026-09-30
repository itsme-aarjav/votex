#!/usr/bin/env bash
set -e

echo "==> Cleaning up Kubernetes services and load balancers..."
helm uninstall votex -n votex 2>/dev/null || kubectl delete -f k8s/manifests/ -n votex 2>/dev/null || true

echo "==> Waiting 30s for AWS load balancers to detach..."
sleep 30

echo "==> Destroying Terraform infrastructure..."
cd terraform
terraform destroy -auto-approve
