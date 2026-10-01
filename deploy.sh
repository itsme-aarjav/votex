#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${AWS_REGION:-eu-north-1}"
CLUSTER="${CLUSTER_NAME:-votex-cluster}"

echo "Starting deployment for Votex on AWS EKS (${REGION})..."

cd "$ROOT_DIR/terraform"
terraform init -upgrade
terraform apply -auto-approve

echo "Deployment complete."
