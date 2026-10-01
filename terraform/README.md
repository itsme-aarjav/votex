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
 │    └── AWS Load Balancers (External)                        │
 │                                                             │
 │   Private Subnets (AZ-a: 10.0.11.0/24, AZ-b: 10.0.12.0/24) │
 │    ├── EKS Managed Node Group (2x t3.medium)                │
 │    ├── Microservices Pods (Vote, Result, Worker, Redis)     │
 │    └── PostgreSQL Database (AWS EBS gp2 PVC)                │
 │                                                             │
 │   EKS Control Plane (Kubernetes 1.31)                       │
 │    └── VPC-CNI, CoreDNS, kube-proxy, aws-ebs-csi-driver     │
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
│   └── eks/                    # EKS cluster, node group, IAM roles, EBS CSI driver
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
├── main.tf                     # Root module connecting VPC and EKS
├── variables.tf                # Input variables (defaults to eu-north-1)
├── outputs.tf                  # Useful outputs (cluster endpoint, kubeconfig)
├── versions.tf                 # Terraform & AWS provider constraints
├── terraform.tfvars            # Active variable configurations
└── terraform.tfvars.example    # Sample configuration values
```

---

## Deployment Steps

### 1. Initialize
```bash
cd terraform
terraform init
```

### 2. Plan
```bash
terraform plan
```

### 3. Apply
```bash
terraform apply
```

### 4. Connect kubectl to EKS
```bash
aws eks update-kubeconfig --region eu-north-1 --name votex-cluster
kubectl get nodes -o wide
```

### 5. Deploy Votex via Helm
```bash
cd ..
helm upgrade --install votex ./k8s/helm/votex \
  -f ./k8s/helm/votex/values-eks.yaml \
  --namespace votex \
  --create-namespace
```

---

## Teardown (Cost Control)

```bash
# Delete Kubernetes resources first so AWS Load Balancers are removed
helm uninstall votex -n votex

# Destroy cloud infrastructure
cd terraform
terraform destroy -auto-approve
```
