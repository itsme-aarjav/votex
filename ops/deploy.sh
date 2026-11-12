#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
MODE="${1:---offline}"

case "$MODE" in
  --offline|--plan) ;;
  --help|-h)
    echo "Usage: ops/deploy.sh [--offline|--plan]"
    echo "  --offline  Format, initialize without backend, validate. No AWS calls (default)."
    echo "  --plan     Read-only AWS-backed Terraform plan; requires initialized S3 backend."
    exit 0
    ;;
  *) echo "Unknown option: $MODE" >&2; exit 2 ;;
esac

command -v terraform >/dev/null 2>&1 || { echo "terraform CLI is required" >&2; exit 1; }
echo "Votex Terraform preflight: $MODE (does not deploy resources)"
terraform -chdir="$TF_DIR" fmt -check -recursive
if [ "$MODE" = "--offline" ]; then
  terraform -chdir="$TF_DIR" init -backend=false -lockfile=readonly -input=false
  terraform -chdir="$TF_DIR" validate
  echo "Offline configuration checks completed; AWS live plan and apply not executed."
else
  if [ ! -f "$TF_DIR/backend.tf" ]; then
    echo "Initialized S3 backend configuration required for --plan." >&2
    exit 1
  fi
  terraform -chdir="$TF_DIR" init -lockfile=readonly -input=false
  terraform -chdir="$TF_DIR" validate
  terraform -chdir="$TF_DIR" plan -input=false -out=tfplan
  echo "Terraform plan saved to terraform/tfplan for human review. No apply executed."
fi
