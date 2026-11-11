#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_REGION:-eu-north-1}"
CLUSTER="${CLUSTER_NAME:-votex-cluster}"

echo "Starting infrastructure preflight for Votex on AWS EKS (${REGION})..."

cd "$ROOT_DIR/terraform"
terraform init -upgrade
terraform validate
terraform plan -out=tfplan

echo "Execution plan generated in terraform/tfplan."
echo "Execute 'terraform apply tfplan' only after explicit human review and approval."
