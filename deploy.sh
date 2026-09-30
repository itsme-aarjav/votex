#!/usr/bin/env bash
set -e

echo "Starting automated provisioning and deployment on AWS EKS (eu-north-1)..."
cd terraform
terraform init
terraform apply -auto-approve
