#!/bin/bash
set -e

apt-get update -y
apt-get install -y curl jq htop

# join eks cluster
/etc/eks/bootstrap.sh "${cluster_name}"
