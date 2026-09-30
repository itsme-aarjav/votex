# Votex - Cloud-Native Distributed Microservices on AWS EKS

Votex is a 5-tier microservices polling application deployed on Amazon EKS using modular Terraform and Helm 3. It demonstrates zero-downtime rolling updates, auto-healing pods, isolated VPC networking in AWS `eu-north-1` (Stockholm), and persistent PostgreSQL storage with AWS EBS gp3.

---

## System Architecture & Data Flow

```
                      [ Client Traffic ]
                              │
                              ▼
                  [ AWS Elastic Load Balancer ]
                              │
            ┌─────────────────┴─────────────────┐
            ▼                                   ▼
      Vote Service                        Result Service
      (Python Flask)                   (Node.js + Socket.IO)
            │                                   ▲
            ▼ (LPUSH)                           │ (Real-time Broadcast)
       Redis Queue                              │
            │                                   │
            ▼ (BRPOP)                           │
      Worker Service                            │
       (.NET Core)                              │
            │                                   │
            ▼ (INSERT)                          │
      PostgreSQL Database (AWS EBS gp3 PVC) ────┘
```

1. **Vote Ingestion**: Users cast votes through the Python Flask API.
2. **Buffering**: Votes are pushed to an in-memory Redis queue (`LPUSH`) to absorb sudden traffic surges.
3. **Async Processing**: A .NET Core worker daemon continuously pops votes (`BRPOP`) and commits them to PostgreSQL.
4. **Live Dashboard**: The Node.js service watches the database and broadcasts live voting tallies via WebSockets (Socket.IO).

---

## AWS Cloud Infrastructure (eu-north-1)

All infrastructure is provisioned through modular Terraform in `eu-north-1`:

- **Custom Isolated VPC (`10.0.0.0/16`)**:
  - **2 Public Subnets** (`10.0.1.0/24`, `10.0.2.0/24`): Host the NAT Gateway and internet-facing AWS Load Balancers.
  - **2 Private Subnets** (`10.0.11.0/24`, `10.0.12.0/24`): Host EKS worker nodes and database storage with no public IP exposure.
- **Cost-Optimized NAT Gateway**: Single NAT Gateway deployed in public subnet 1 to provide outbound internet access for container pulls while keeping cloud costs minimal.
- **Amazon EKS Managed Node Group**: 2x `t3.medium` instances with 20 GB gp3 encrypted root volumes, auto-scaling from 1 to 3 nodes.
- **AWS EBS CSI Driver & gp3 StorageClass**: Dynamically provisions persistent AWS EBS gp3 volumes for PostgreSQL database data.
- **Instance Auto-Initialization**: EC2 worker nodes automatically update system packages and configure AWS Systems Manager (SSM) on boot via launch template user data.

---

## Zero-Downtime & Auto-Healing

- **Zero-Downtime Rolling Updates**:
  Deployments use `RollingUpdate` with `maxSurge: 1` and `maxUnavailable: 0`. Kubernetes ensures a new replacement pod is healthy and passing readiness probes before terminating an old pod.
- **PreStop Hook & Graceful Draining**:
  A 5-second `preStop` hook drains in-flight HTTP requests and active transactions before container shutdown.
- **Auto-Healing Pods**:
  - **Liveness Probes**: Automatically restart hung or deadlocked containers.
  - **Readiness Probes**: Prevent traffic from reaching pods that are still initializing.
  - **PodDisruptionBudget (PDB)**: Guarantees at least 1 pod is always available during node maintenance or upgrades.
- **Automated Rollback**:
  CI/CD verifies `kubectl rollout status` and automatically triggers `helm rollback` if any health check fails.

---

## Repository Structure

```
k8s-kind-voting-app/
├── terraform/                # Infrastructure as Code (AWS EKS & VPC)
│   ├── modules/
│   │   ├── vpc/              # VPC, public & private subnets, IGW, NAT GW
│   │   └── eks/              # EKS cluster, node group, IAM roles, EBS CSI driver
│   ├── scripts/
│   │   └── post_apply.sh     # Auto-configuration script triggered on apply
│   ├── main.tf               # Root module connecting VPC & EKS
│   ├── variables.tf          # Configurable variables (defaults to eu-north-1)
│   ├── outputs.tf            # Cluster endpoint & kubeconfig command
│   ├── versions.tf           # Terraform & AWS provider requirements
│   ├── terraform.tfvars      # Active configuration values
│   └── README.md             # Terraform operations guide
├── k8s/                      # Kubernetes Resources
│   ├── helm/votex/           # Helm 3 chart (values.yaml & values-eks.yaml)
│   ├── manifests/            # Raw Kubernetes YAML manifests (gp3, pdb, etc.)
│   └── monitoring/           # Prometheus alerts, Grafana setup, Loki & Promtail
├── vote/                     # Python Flask microservice
├── result/                   # Node.js Express & Socket.IO microservice
├── worker/                   # .NET Core background worker
├── seed-data/                # Vote generator for testing
├── tests/                    # Unit, load (K6), and resilience tests
├── deploy.sh                 # One-click automated deployment script
├── destroy.sh                # One-click automated teardown script
├── Jenkinsfile               # Declarative 8-stage CI/CD pipeline
└── docker-compose.yml        # Local multi-container development
```

---

## One-Click Deployment

### Option 1: Automated Script (Recommended)

Run the automated deploy script from the repository root:
```bash
./deploy.sh
```
This initializes Terraform, provisions the VPC and EKS cluster in `eu-north-1`, automatically configures `kubectl`, sets up the `gp3` storage class, and deploys Votex via Helm with zero downtime.

---

### Option 2: Step-by-Step Manual Deployment

1. **Provision Infrastructure**:
   ```bash
   cd terraform
   terraform init
   terraform apply
   ```

2. **Connect kubectl**:
   ```bash
   aws eks update-kubeconfig --region eu-north-1 --name votex-cluster
   kubectl get nodes -o wide
   ```

3. **Deploy via Helm**:
   ```bash
   cd ..
   helm upgrade --install votex ./k8s/helm/votex \
     -f ./k8s/helm/votex/values-eks.yaml \
     --namespace votex \
     --create-namespace
   ```

4. **Access the Application**:
   ```bash
   kubectl get svc -n votex
   ```
   Open the external Load Balancer DNS URLs for `vote` (port 80) and `result` (port 80) in your browser.

---

## Teardown (Cost Control)

To avoid ongoing AWS charges when you finish testing:
```bash
./destroy.sh
```
Or manually:
```bash
helm uninstall votex -n votex
cd terraform
terraform destroy -auto-approve
```

---

## Author & Maintainer

Developed by **[Aarjav Jain](https://github.com/itsme-aarjav)**.
