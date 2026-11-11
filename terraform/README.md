# Terraform Infrastructure for Amazon EKS

Modular Terraform codebase to provision and manage AWS infrastructure for the Votex platform in `eu-north-1` (Stockholm).

---

## Infrastructure Architecture

```
                             Internet
                                │
                                ▼
                       [ Internet Gateway ]
                                │
 ┌──────────────────────────────┴──────────────────────────────┐
 │ AWS VPC (10.0.0.0/16) in eu-north-1                         │
 │                                                             │
 │   Public Subnets (AZ-a: 10.0.1.0/24, AZ-b: 10.0.2.0/24)    │
 │    ├── NAT Gateway (AZ-a)                                   │
 │    └── Route Table with IGW Default Route                   │
 │                                                             │
 │   Private Subnets (AZ-a: 10.0.11.0/24, AZ-b: 10.0.12.0/24) │
 │    ├── EKS Managed Node Group (2x m7i-flex.large)           │
 │    ├── Microservices Pods (Vote, Result, Worker, Redis)     │
 │    └── PostgreSQL Database (AWS EBS gp3 PVC)                │
 │                                                             │
 │   EKS Control Plane (Kubernetes 1.36)                       │
 │    ├── API Public Access: Restricted CIDR Allowlist         │
 │    ├── API Private Access: Enabled                          │
 │    └── Addons: VPC-CNI, CoreDNS, kube-proxy, EBS CSI (IRSA) │
 └─────────────────────────────────────────────────────────────┘
```

---

## Directory Structure

```
terraform/
├── modules/
│   ├── vpc/                    # VPC, 2 public & 2 private subnets, IGW, NAT GW
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── eks/                    # EKS cluster, node group (m7i-flex.large), IAM roles, EBS CSI driver (IRSA)
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
├── scripts/
│   └── post_apply.sh           # Standalone post-provisioning verification script (decoupled)
├── main.tf                     # Root module connecting VPC and EKS
├── variables.tf                # Input variables (defaults to eu-north-1)
├── outputs.tf                  # Useful outputs (cluster endpoint, kubeconfig)
├── versions.tf                 # Terraform & AWS provider constraints
├── terraform.tfvars            # Active variable configurations (git-ignored)
└── terraform.tfvars.example    # Sample configuration values
```

---

## Deployment Steps (Option B - Production Cloud Infrastructure)

### 1. Initialize
```bash
cd terraform
terraform init
```

### 2. Configure Variables
Copy `terraform.tfvars.example` to `terraform.tfvars` if not already present.
Set your operator workstation public IP in `cluster_endpoint_public_access_cidrs` to restrict Kubernetes API endpoint access:
```hcl
aws_region                           = "eu-north-1"
cluster_name                         = "votex-cluster"
environment                          = "production"
node_instance_types                  = ["m7i-flex.large"]
node_desired_size                    = 2
node_min_size                        = 2
node_max_size                        = 2
cluster_endpoint_public_access_cidrs = ["<OPERATOR_PUBLIC_IP>/32"]
```

### 3. Plan & Verify
Generate and review the execution plan before any infrastructure creation:
```bash
terraform plan -out=tfplan
```

### 4. Apply
Apply the approved plan (requires human verification):
```bash
terraform apply tfplan
```

### 5. Connect kubectl to EKS
Configure local kubeconfig with the Stockholm cluster credentials:
```bash
aws eks update-kubeconfig --region eu-north-1 --name votex-cluster
kubectl get nodes -o wide
```

### 6. Run Post-Apply Bootstrap Script
Execute the decoupled cluster bootstrap script to verify node readiness, register the EBS CSI driver, apply the `gp3` StorageClass, configure namespace `votex`, bootstrap `db-secret` securely, and record OTel IRSA parameters:
```bash
bash scripts/post_apply.sh
```

> [!NOTE]
> `scripts/post_apply.sh` automatically checks if `db-secret` exists in namespace `votex`. If missing, it generates a cryptographically secure random password and populates the exact required keys (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`) via `/dev/stdin` without exposing credentials in process lists, console logs, or Git. If already present, existing credentials are strictly preserved.

### 7. Build and Publish Application Images (linux/amd64)
Before deploying workloads via Helm, build and push verified `linux/amd64` images to Docker Hub:
```bash
cd ..
docker build --platform linux/amd64 -t aarjavjainn/votex-vote:v2.0.0 ./votex/vote
docker build --platform linux/amd64 -t aarjavjainn/votex-result:v2.0.0 ./votex/result
docker build --platform linux/amd64 -t aarjavjainn/votex-worker:v2.0.0 ./votex/worker

docker push aarjavjainn/votex-vote:v2.0.0
docker push aarjavjainn/votex-result:v2.0.0
docker push aarjavjainn/votex-worker:v2.0.0
```

### 8. Deploy Votex via Helm (Private ClusterIP Exposure)
Deploy the core microservices using the pinned `v2.0.0` container tags and OpenTelemetry IRSA role:
```bash
OTEL_ROLE=$(terraform -chdir=terraform output -raw otel_collector_role_arn)
helm upgrade --install votex ./k8s/helm/votex \
  -f ./k8s/helm/votex/values-eks.yaml \
  --set otel.collector.serviceAccount.roleArn="${OTEL_ROLE}" \
  --namespace votex
```

### 9. Online HTTPS & Private Service Access
Under Option B, Vote and Result services deploy with private `ClusterIP` (Service port `80`) to ensure no unauthenticated HTTP listener is exposed publicly:
- **Online HTTPS**: When a valid custom domain and ACM TLS certificate ARN are provisioned, enable the AWS ALB Ingress (`--set ingress.enabled=true --set ingress.className=alb`) with host-based routing on port 443.
- **Private Cluster Access**: For direct operational health verification within the VPC, services communicate over internal cluster DNS (`http://vote.votex.svc.cluster.local`, `http://result.votex.svc.cluster.local`).

### 10. Post-Deployment Verification
Verify internal application health across cluster deployments using Ansible:
```bash
ansible-playbook ansible/verify_deployment.yml \
  -e "k8s_namespace=votex vote_endpoint=http://vote.votex.svc.cluster.local result_endpoint=http://result.votex.svc.cluster.local"
```

---

## Teardown & Cost Control

Do NOT use `terraform destroy -auto-approve`. Instead, execute the structured repository teardown script:
```bash
cd ..
./ops/destroy.sh
```
The teardown script safely:
1. Uninstalls all Helm chart releases.
2. Deletes lingering EBS PVCs (`votex-db-pvc`, `votex-redis-pvc`, `jenkins-pvc`) to prevent cloud volume retention charges.
3. Generates a Terraform destroy plan (`destroy.tfplan`).
4. Requires explicit typed confirmation (`confirm-terraform-destroy`) before modifying any AWS resources.
5. Audits remaining VPC, ELB, and EBS resources to guarantee zero ongoing cloud costs.
