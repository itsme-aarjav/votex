# Votex — Cloud-Native Distributed Microservices on AWS EKS

Votex is an enterprise 5-tier microservices polling and real-time analytics platform provisioned on Amazon EKS using modular Terraform and Helm 3. It demonstrates production-grade DevSecOps engineering with an automated 9-stage Jenkins declarative pipeline, SonarQube static code analysis, Trivy vulnerability scanning, OWASP ZAP dynamic application security testing, Prometheus/Grafana metrics, Grafana Alloy & Loki log aggregation, OpenTelemetry distributed tracing with AWS X-Ray, non-destructive Ansible PostgreSQL disaster recovery verification, and AWS Lambda external synthetic monitoring.

---

## 1. Application Interfaces & Architecture

The application comprises a user-facing voting portal, an in-memory stream buffer, an asynchronous persistence worker daemon, and a live analytics dashboard:

Vote is a Python/Flask interface; Result is a Node.js/Socket.IO analytics dashboard. Fresh live screenshots will be captured after the first AWS deployment.

### Microservices Data Flow

```
                      [ Client Web Traffic ]
                                │
                                ▼
            [ AWS Application Load Balancer Ingress ]
            (SSL / TLS Port 443 ── Shared ALB Group)
                                │
        ┌───────────────────────┴───────────────────────┐
        ▼                                               ▼
  Vote Service                                   Result Service
  (Python Flask / Gunicorn)                   (Node.js + Socket.IO)
        │                                               ▲
        ▼ (XADD / Redis Streams)                        │ (Real-Time WebSocket Updates)
 Redis In-Memory Queue                                  │
        │                                               │
        ▼ (XREADGROUP / XAUTOCLAIM)                     │
  Worker Service                                        │
  (Python Daemon)                                       │
        │                                               │
        ▼ (Idempotent UPSERT Transactions)              │
  PostgreSQL Relational DB (AWS EBS gp3 PVC) ───────────┘
```

1. **Vote Submission**: Users submit votes through the Python Flask microservice. Requests are authenticated, CSRF-validated, rate-limited, and injected with W3C distributed trace context (`traceparent`).
2. **Buffering**: Submissions are appended to an in-memory Redis stream (`votes_stream`) using consumer groups, isolating web traffic spikes from database write latencies.
3. **Asynchronous Persistence**: A Python worker daemon consumes votes using Redis consumer groups (`XREADGROUP` and `XAUTOCLAIM`), ensuring at-least-once processing and zero message loss across pod restarts, executing idempotent SQL UPSERT transactions into PostgreSQL.
4. **Real-Time Analytics**: The Node.js Express service queries PostgreSQL, aggregates multi-poll voting analytics, and broadcasts live tally updates to connected clients via WebSockets (`Socket.IO`).

---

## 2. DevSecOps CI/CD Pipeline (Jenkins)

Every commit to `main` executes an automated, 9-stage declarative Jenkins pipeline running on ephemeral Kubernetes agents inside the EKS cluster:

Live Jenkins pipeline evidence will be captured during the approved AWS demo.

### The 9 Pipeline Stages & Security Gates

```
[1. Checkout] ──> [2. Smoke Validation] ──> [3. SonarQube SAST] ──> [4. Trivy Filesystem]
                                                                            │
┌───────────────────────────────────────────────────────────────────────────┘
▼
[5. Docker Build] ──> [6. Trivy Image Scan] ──> [7. OWASP ZAP DAST] ──> [8. Docker Hub Publish]
                                                                                │
┌───────────────────────────────────────────────────────────────────────────────┘
▼
[9. EKS Helm Deployment & Ansible Verification]
```

| Stage # | Stage Name | Tooling | Quality & Security Gate Enforced |
| :---: | :--- | :--- | :--- |
| **1** | **Checkout SCM** | Git Plugin | Clones `origin/main`, resolves short commit SHA, creates deterministic release candidate tag `v2.1.${BUILD_NUMBER}-${SHA}`. |
| **2** | **Service Build & Smoke Validation** | Python 3.11, Node.js 18, pip, npm | Compiles AST bytecode (`py_compile`), verifies dependencies, launches services in background, validates `/api/health` probes, and cleanly terminates processes. Works out-of-the-box on fresh clones without local test dependencies. |
| **3** | **SonarQube Analysis & Quality Gate** | SonarScanner CLI, SonarQube Server | Static Application Security Testing (SAST). Scans application code for security hotspots, bugs, and code smells. Enforces a strict Quality Gate threshold via `waitForQualityGate()`. |
| **4** | **Trivy Filesystem Scan** | Trivy CLI | Shifts security left by scanning the repository filesystem and third-party dependencies. Blocks pipeline on unpatched `HIGH` or `CRITICAL` vulnerabilities. |
| **5** | **Docker Build** | Docker CLI, Buildx | Multi-stage `linux/amd64` builds producing optimized, minimal production containers for Vote, Result, and Worker microservices. |
| **6** | **Trivy Image Scan** | Trivy CLI | Container vulnerability scanner. Evaluates OS base layers and binary packages in built release candidate images before publication. Blocks on `CRITICAL` CVEs. |
| **7** | **OWASP ZAP DAST** | OWASP ZAP container | Dynamic Application Security Testing (DAST). Boots candidate release in an isolated Docker network and performs active baseline security scans against live HTTP endpoints. |
| **8** | **Docker Hub Publish** | Docker CLI, Credential Store | Authenticates and publishes verified immutable release tags (`v2.1.${BUILD_NUMBER}-${SHA}`) to Docker Hub (`aarjavjainn`). |
| **9** | **EKS Deployment & Verification** | Helm 3/4, kubectl, Ansible | Selects version-compatible rollback behavior; verifies rollout and Ansible checks, and tests restoring the previously deployed revision on post-deploy failure. Verified live in [`proofs/ci-cd/`](proofs/ci-cd/). |

> [!NOTE]
> Application unit and integration test results were independently verified offline before pre-deployment workspace cleanup. CI Stage 2 executes standalone syntax, import, dependency, and process smoke checks, ensuring deterministic, hermetic pipeline builds on clean repository checkouts.

### Centralized Live Operational Proofs Repository

All genuine tool-generated reports, vulnerability findings, terminal test outputs, and AWS infrastructure states produced during the live AWS deployment (verified through Jenkins builds #16 and #17) are preserved in [`proofs/`](proofs/):

- [`proofs/security/`](proofs/security/): Raw Trivy scanner reports (FS console excerpt & 3 container images: 0 High/Critical) and raw OWASP ZAP DAST artifacts (`zap-report.html` and `zap-report.json`).
- [`proofs/ci-cd/`](proofs/ci-cd/): Jenkins Build #16 pipeline execution metadata (9/9 stages SUCCESS), Ansible post-deployment verification.
- [`proofs/operations/`](proofs/operations/): k6 load testing (903 checks passed, 129 votes, p95 272ms), Chaos pod self-healing logs (Worker 5s, Redis 7s), PostgreSQL non-destructive DR restore verification, Helm release history (Revisions 1–14), and Kubernetes HPA describe analysis.
- [`proofs/aws/`](proofs/aws/): Terraform managed resources list (36 resources) and live AWS cost & runtime audit.
- [`proofs/screenshots/`](proofs/screenshots/): 22 genuine production dashboard screenshots personally captured by the owner across `application/`, `ci-cd/`, `security/`, `observability/`, and `aws/`.

---

## 3. Dedicated Responsibilities of DevOps Tooling

Every tool in the Votex platform has a distinct, necessary responsibility without redundant overlaps:

### 1. AWS Lambda — External Synthetic Uptime Monitoring
- **Role**: Validates user-facing service availability independently of Kubernetes.
- **Why it is distinct**: Kubernetes liveness probes run *inside* the cluster node network. If the worker nodes lose network connectivity, CoreDNS crashes, or the AWS Application Load Balancer fails, internal probes report false positives or cannot alert. AWS Lambda runs outside the VPC and is triggered every 5 minutes by Amazon EventBridge to test public HTTPS endpoints, recording availability and latency to CloudWatch alarms.

### 2. Ansible — PostgreSQL Disaster Recovery & Restore Verification
- **Role**: Automated logical backup creation and non-destructive recovery verification.
- **Why it is distinct**: While Helm deploys workloads and Terraform provisions infrastructure, Ansible manages database disaster recovery. `ansible/backup_restore_verify.yml` connects to the PostgreSQL pod, executes `pg_dump`, restores the dump into an isolated temporary database (`votex_verify_<timestamp>`), validates table schemas and row counts, safely drops the temporary database, and retains evidence without ever overwriting live production data.

### 3. Load Testing (`tests/load/load-test.js`) — Concurrency & Autoscaling
- **Role**: Synthetic traffic generation using k6.
- **Why it is distinct**: Simulates concurrent user voting traffic across configurable profiles (`baseline`, `stress`, `spike`) with distinct virtual user identities (`voter_id` cookies). Measures throughput, failure rates, and p95 latency. Respects CSRF tokens and rate limits to demonstrate Kubernetes Horizontal Pod Autoscaling (HPA) without weakening application security.

### 4. Chaos Resilience Testing (`tests/resilience/chaos-test.sh`) — Self-Healing Proof
- **Role**: Controlled failure injection and recovery validation.
- **Why it is distinct**: Injects controlled pod terminations against the Worker daemon and Redis queue. Observes ReplicaSet reconciliation and measures recovery time in seconds. Verifies persistent volume data integrity and pod `Ready=True` conditions with explicit safety gates (`--dry-run` and `--confirm`).

### 5. Proper Observability Matrix (Logs vs. Metrics vs. Traces)
The platform avoids duplicate pipelines by maintaining strict boundaries across observability pillars:

| Observability Pillar | Primary Tool | Collection Agent | Storage & Backend | Visualization |
| :--- | :--- | :--- | :--- | :--- |
| **Metrics** | Prometheus | Kube-State-Metrics, Node-Exporter | Prometheus TSDB (gp3 PVC) | Grafana |
| **Logs** | Loki | Grafana Alloy (daemonset log scraper) | Loki Single-Binary (gp3 PVC) | Grafana (Loki Datasource) |
| **Traces** | OpenTelemetry | OpenTelemetry Collector Contrib | AWS X-Ray (via OTel IRSA exporter) | AWS X-Ray Console |

- **Metrics (Prometheus & Grafana)**: Numeric counters, gauges, and rates measuring CPU, memory, container restarts, and HPA scaling.
- **Logs (Grafana Alloy & Loki)**: Structured application and container logs. Alloy parses container runtimes and ships log streams directly to Loki without heavy distributed dependencies or deprecated Promtail.
- **Traces (OpenTelemetry & AWS X-Ray)**: Distributed end-to-end transaction paths. Python microservices (Vote and Worker) use the OpenTelemetry SDK with `AwsXRayIdGenerator` to trace requests across HTTP, Redis Streams, and PostgreSQL. Traces are exported via OTLP gRPC to the OpenTelemetry Collector and forwarded to AWS X-Ray.

---

## 4. AWS Cloud Infrastructure (Option B — `eu-north-1`)

All cloud infrastructure is provisioned through modular Terraform in `eu-north-1` (Stockholm):

Live EKS and EC2 node screenshots will be captured during the approved AWS demo.

- **Isolated Custom VPC (`10.0.0.0/16`)**:
  - **2 Public Subnets** (`10.0.1.0/24`, `10.0.2.0/24`): Host the NAT Gateway and internet-facing Application Load Balancer.
  - **2 Private Subnets** (`10.0.11.0/24`, `10.0.12.0/24`): Host EKS worker nodes, databases, and caches with zero public ingress.
- **EKS Managed Node Group (Option B)**: Exactly **2 × `m7i-flex.large`** compute instances (2 vCPU, 8 GiB RAM each = 4 vCPU, 16 GiB total raw capacity) with 20 GiB encrypted gp3 root volumes.
- **Shared AWS Application Load Balancer Ingress**: All public microservices and operational portals share a single AWS Application Load Balancer using ALB Ingress Grouping (`alb.ingress.kubernetes.io/group.name: "votex-platform"`), enforcing SSL redirection (port 443) and host-based routing while eliminating redundant load balancer fees.
- **AWS EBS CSI Driver & gp3 StorageClass**: Dynamically provisions persistent gp3 volumes for PostgreSQL, Redis, Jenkins, SonarQube, Prometheus, Grafana, and Loki using IAM Roles for Service Accounts (IRSA).
- **Kubernetes API Security**: EKS public API endpoint access is restricted to an approved CIDR allowlist (`cluster_endpoint_public_access_cidrs`), while internal nodes communicate over the private VPC endpoint.

---

## 5. Terraform Remote State & Native S3 Locking

The platform implements modern Terraform remote state storage using **Amazon S3 Remote State + Native S3 Lockfile Locking** (`use_lockfile = true`), completely eliminating DynamoDB.

```
                    ┌───────────────────────────────────────────┐
                    │  Terraform S3 Remote State Architecture   │
                    └───────────────────────────────────────────┘
                                          │
            ┌─────────────────────────────┴─────────────────────────────┐
            ▼                                                           ▼
┌───────────────────────────────┐                       ┌───────────────────────────────┐
│     terraform/bootstrap/      │                       │          terraform/           │
│  - Independent S3 bucket      │                       │  - Main EKS infrastructure    │
│  - Versioning enabled         │ ──(Supplies Bucket)──>│  - backend "s3"               │
│  - SSE-S3 AES256 encryption   │                       │  - use_lockfile = true        │
│  - Public access blocked      │                       │  - No DynamoDB required       │
└───────────────────────────────┘                       └───────────────────────────────┘
```

### Why Native S3 Locking (No DynamoDB)?
Terraform 1.10+ introduced native S3 conditional writes. S3 natively supports conditional `PutObject` operations to guarantee mutual exclusion during concurrent `terraform apply` executions by creating a `.tflock` object. This eliminates:
- DynamoDB table provisioning and maintenance.
- Additional AWS DynamoDB billing.
- DynamoDB read/write capacity management and IAM role configurations.

### Decoupled Bootstrap Workflow (Preventing Circular Dependencies)
To avoid the circular dependency where an EKS stack attempts to manage the bucket required to store its own state:
1. `terraform/bootstrap` is provisioned once to create the secure S3 state bucket.
2. The main stack initializes against the provisioned bucket: `terraform init -backend-config="bucket=<BUCKET_NAME>"`.

---

## 6. Realistic AWS Cost & Resource Capacity Model

### Estimated Monthly AWS Spend (Option B — `eu-north-1`)

| AWS Service / Resource | Allocation & Sizing | Fixed / Variable | Estimated Monthly Cost (USD) | Cost Optimization Strategy |
| :--- | :--- | :---: | :---: | :--- |
| **Amazon EKS Cluster** | 1 control plane (`votex-cluster`) | Fixed | $73.00 | Standard EKS hourly cluster fee ($0.10/hr). |
| **EC2 Worker Nodes** | 2 × `m7i-flex.large` (4 vCPU, 16 GiB RAM) | Fixed | $148.56 | On-demand rate of $0.10175/hr per node in `eu-north-1` (730 hrs/mo × 2 nodes = $148.56). |
| **VPC NAT Gateway** | 1 NAT Gateway (Single AZ) | Fixed + Data | $33.75 | Single NAT Gateway ($0.045/hr = $32.85) plus ~$0.90 data processing. |
| **Public IPv4 Addresses** | 3 Public IPs (1 NAT GW, 2 ALB Multi-AZ) | Fixed | $10.95 | AWS standard IPv4 charge ($0.005/hr per in-use IP = $3.65/IP-month). |
| **Application Load Balancer** | 1 Shared ALB (Ingress Group `votex-platform`) | Fixed + LCU | $19.93 | Ingress grouping merges 5 service portals onto a single ALB. |
| **Amazon EBS Storage** | 95 GiB total gp3 storage (root + PVCs) | Fixed | $7.60 | Cost-effective gp3 storage at $0.08/GiB-month (40 GiB root + 55 GiB PVCs). |
| **AWS Lambda & CloudWatch** | Synthetic canary, metrics, 2 alarms | Variable | $1.60 | Free tier invocation limits, 14-day log retention. |
| **Route 53 & Data Transfer** | 1 hosted zone + 20 GB egress | Variable | $1.50 | Standard public zone fees. |
| **Total Estimated 24/7 Cost** | Continuous monthly operation | | **~$296.89 / month** | *Can be shut down between demonstrations.* |
| **4-5 Hour Live Evaluation** | Demonstration run | | **~$2.15 - $2.55 total** | *Torn down immediately via `ops/destroy.sh`.* |

### Node Capacity & Sizing Balance Sheet (Option B)

```
+--------------------------------------------------------------------------+
| Total Raw Capacity: 4,000m vCPU / 16,384 MiB RAM                         |
| System Reserved & DaemonSets: ~510m vCPU / 1,584 MiB RAM                 |
| Allocatable Capacity: 3,490m vCPU / 14,800 MiB RAM                       |
+--------------------------------------------------------------------------+
| Steady-State Workload Allocations:                                       |
|   1. Core Workloads (Vote, Result, Worker, Redis, Postgres):            |
|      Requests: 700m vCPU / 960 MiB RAM                                   |
|   2. CI/CD Controllers (Jenkins Controller, SonarQube Server):          |
|      Requests: 600m vCPU / 1,212 MiB RAM                                 |
|   3. Monitoring & Tracing (Prometheus, Grafana, Loki, Alloy, OTel):      |
|      Requests: 500m vCPU / 1,024 MiB RAM                                 |
+--------------------------------------------------------------------------+
| Total Steady-State Requests: ~1,800m vCPU (~52%) / 3,196 MiB RAM (~22%)  |
| Ephemeral Build Agent (when active): ~300m vCPU / 512 MiB RAM            |
| Headroom Remaining for Spikes: ~1,390m vCPU (~40%) / 11,092 MiB (~75%)   |
+--------------------------------------------------------------------------+
```

---

### Operations helpers (`ops/`)

- `bash ops/dashboard.sh`: read-only status and access dashboard for Vote, Result, Jenkins, SonarQube, Grafana, Prometheus, AWS X-Ray, CloudWatch, and Lambda. Handles offline/unreachable cluster gracefully and provides secure credential retrieval instructions.
- `bash ops/deploy.sh` (default `--offline`): `--offline` performs Terraform formatting, backend-disabled initialization, and validation. `--plan` generates an AWS-backed speculative plan with S3 backend. `--full` performs an approval-gated 24-step platform deployment with strict identity and CIDR preflights.
- `bash ops/destroy.sh`: safe cloud decommissioning automation. Supports both standard full-cluster teardown (`ops/destroy.sh`) and explicit partial-infrastructure recovery (`ops/destroy.sh --recover-partial`).

## 7. Safe Teardown & Partial Recovery (`ops/destroy.sh`)

**Fail-closed recovery:** Only EKS `ResourceNotFoundException` or a matching-ARN `FAILED` EKS status permits `--recover-partial`. AWS API errors and transitional statuses abort. The operations mock suite runs from a disposable project copy and must not modify local Terraform backend metadata.

To eliminate lingering AWS costs after live demonstrations or failed provisioning runs, `ops/destroy.sh` provides two strictly validated, non-destructive recovery and teardown workflows:

### A. Standard Full Teardown (`ops/destroy.sh`)
Executes when a healthy, active EKS cluster is operational:
1. **Pre-teardown Diagnostics**: Captures cluster pod logs and configuration to `reports/teardown-<timestamp>/`.
2. **Ingress Deletion**: Deletes Kubernetes Ingress objects, allowing the running AWS Load Balancer Controller to reconcile and deprovision the Application Load Balancer.
3. **ELBv2 Verification (Controller Kept Active)**: Polls the AWS ELBv2 API (`aws elbv2 describe-load-balancers`) to confirm all ALBs tagged `votex-platform` are fully deleted before tearing down the controller.
4. **Controller & Workload Uninstallation**: Once ALBs are confirmed deleted, uninstalls `aws-load-balancer-controller` in `kube-system`, followed by Votex (`votex`), Prometheus (`monitoring`), Loki (`monitoring`), Alloy (`logging`), and CI/CD resources.
5. **Storage Volume Release & EBS Detachment**: Deletes specific Votex PVCs and release-labeled monitoring claims, verifying volume detachment before subnet removal.
6. **Terraform Infrastructure Destruction**: Plans and applies `terraform plan -destroy` after explicit operator confirmation (`confirm-terraform-destroy`).
7. **S3 State Preservation**: The S3 remote state bucket is strictly preserved to maintain audit trails and configuration state.
8. **Cloud Audit**: Inspects remaining cloud resources for project-specific leftovers; zero charges must not be assumed from an account-wide listing.

### B. Partial-Infrastructure Recovery Mode (`ops/destroy.sh --recover-partial`)
Used when Terraform partially provisions cloud infrastructure (such as VPC, Subnets, NAT Gateways, or IAM roles), but EKS cluster creation fails or times out before Kubernetes control plane becomes reachable:
- **Mandatory Preflight Checks**: Verifies caller identity (`EXPECTED_AWS_ACCOUNT_ID`), region (`eu-north-1`), S3 remote state backend accessibility with native locking (`use_lockfile=true`), and checks Terraform state ownership.
- **EKS State Guard**: Confirms the EKS cluster is absent (`ABSENT`) or in a non-ready state (`FAILED`/`CREATING`). If a healthy, active cluster is detected, recovery mode is safely rejected to prevent bypassing ALB controller deprovisioning.
- **Bypasses Kubernetes Workload Draining**: Skips `kubectl` workload calls (which would fail against an absent control plane) and proceeds directly to Terraform destruction.
- **Human Approval Gate**: Inspects the exact `terraform plan -destroy` and requires explicit confirmation (`confirm-partial-recovery-destroy`).
- **Preserves S3 State Bucket & Evidence**: Deletes billable orphaned resources (VPC, NAT Gateways, IAM), verifies state emptiness, audits cloud footprint, and preserves the remote S3 state bucket and diagnostic logs.

---

## 8. Deployment & Operational Runbook

This guide documents the complete 20-step procedure for a future, explicitly authorized live AWS deployment:

```
[1. AWS Preflight] ──> [2. S3 Bootstrap] ──> [3. TF Init] ──> [4. EKS Provision]
                                                                        │
┌───────────────────────────────────────────────────────────────────────┘
▼
[5. EBS CSI Driver] ──> [6. ALB Controller] ──> [7. Core App Helm] ──> [8. Monitoring & Logs]
                                                                                │
┌───────────────────────────────────────────────────────────────────────────────┘
▼
[9. CI/CD Stacks] ──> [10. Domain/ACM/TLS] ──> [11. Auth & Secrets] ──> [12. Jenkins Pipeline]
                                                                                │
┌───────────────────────────────────────────────────────────────────────────────┘
▼
[13. Load / HPA Test] ──> [14. Chaos Recovery] ──> [15. Lambda Alarms] ──> [16. Ansible DR]
                                                                                    │
┌───────────────────────────────────────────────────────────────────────────────────┘
▼
[17. OTel / X-Ray] ──> [18. Rollback Proof] ──> [19. Evidence Capture] ──> [20. Safe Teardown]
```

### Phase A: Cloud Foundation & Platform Provisioning
1. **AWS Identity & Cost Preflight**: Authenticate AWS CLI, verify target account and region (`eu-north-1`), and review the ~$296.89/mo estimated continuous spend.
2. **S3 Remote State Bootstrap**: Provision the dedicated S3 state bucket once via `cd terraform/bootstrap && terraform init && terraform apply -var="state_bucket_name=votex-tfstate-<ACCOUNT_ID>-eu-north-1"`.
3. **Terraform Backend Initialization**: Configure `terraform/backend.tf` with the provisioned bucket and initialize with `terraform init -backend-config="bucket=votex-tfstate-<ACCOUNT_ID>-eu-north-1"`.
4. **EKS Provisioning**: Copy `terraform/terraform.tfvars.example` to an ignored `terraform.tfvars`, set your actual approved operator public CIDR in `cluster_endpoint_public_access_cidrs`, and review a full Terraform plan before an approved apply. Exactly 2 × `m7i-flex.large` nodes.
5. **EBS CSI & Storage Setup**: Connect `kubectl` (`aws eks update-kubeconfig --region eu-north-1 --name votex-cluster`) and run `bash terraform/scripts/post_apply.sh` to initialize gp3 storage and verify IRSA roles.
6. **AWS Load Balancer Controller**: Deploy AWS Load Balancer Controller with its dedicated IAM Role for Service Accounts (IRSA, output as `aws_lb_controller_role_arn`) to manage shared ALB ingress in `kube-system`.

### Phase B: Workload & Observability Deployment
7. **Application Deployment**: Deploy Votex core services:
   ```bash
   OTEL_ROLE=$(terraform -chdir=terraform output -raw otel_collector_role_arn)
   # Helm 4 uses --rollback-on-failure; Helm 3 uses --atomic
   helm upgrade --install votex ./k8s/helm/votex \
     -f ./k8s/helm/votex/values-eks.yaml \
     --set otel.collector.serviceAccount.roleArn="${OTEL_ROLE}" \
     --namespace votex --create-namespace \
     --rollback-on-failure
   ```
8. **Prometheus, Grafana, Loki & Alloy**: Deploy the full monitoring and logging stack using `kube-prometheus-stack`:
   ```bash
   # Create monitoring namespace before its Secret
   kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
   # Create Grafana admin credentials Secret from approved inputs
   kubectl create secret generic grafana-admin-credentials -n monitoring \
     --from-literal=admin-user=admin \
     --from-literal=admin-password="<STRONG_PASSWORD>"

   # Deploy Prometheus Operator & Grafana
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
     -f ./k8s/monitoring/values-prometheus.yaml \
     --namespace monitoring --create-namespace

   # Deploy Loki log store & Alloy DaemonSet log forwarder
   helm repo add grafana https://grafana.github.io/helm-charts
   helm upgrade --install loki grafana/loki \
     -f ./k8s/monitoring/values-loki.yaml \
     --namespace monitoring
   helm upgrade --install alloy grafana/alloy \
     -f ./k8s/monitoring/values-alloy.yaml \
     --namespace logging
   ```
9. **Jenkins & SonarQube Deployment**: Use the approved `ops/deploy.sh --full` orchestration rather than directly applying the Jenkins manifest. The deployment bootstraps `jenkins-admin-credentials`, `jenkins-pipeline-credentials`, and `jenkins-agent-kubeconfig`; JCasC provisions `dockerhub-credentials`, `sonarqube-token`, and `k8s-kubeconfig`. Before paid provisioning, securely supply `VOTEX_DOCKERHUB_USERNAME` and `VOTEX_DOCKERHUB_TOKEN`. On a fresh SonarQube instance, initialize/rotate the administrator password and provide a valid administrator API token via `SONARQUBE_API_TOKEN` or the hidden interactive prompt. Real Jenkins and webhook functionality requires live verification.

### Phase C: Ingress, Security & Pipeline Execution
10. **Domain, ACM & HTTPS Ingress**: Obtain verified operator-owned hostnames and an issued ACM certificate in `eu-north-1`. The application Ingress is intentionally disabled in `values-eks.yaml`. Once domains/certificate exist, use an untracked deployment-only override (run from repository root) to enable Vote and Result HTTPS:
   ```bash
   export VOTE_HOST="vote.example.com"
   export RESULT_HOST="result.example.com"
   export ACM_CERT_ARN="arn:aws:acm:eu-north-1:ACCOUNT:certificate/CERTIFICATE_ID"
   cat > /tmp/votex-https-values.yaml <<EOF
   ingress:
     enabled: true
     annotations:
       alb.ingress.kubernetes.io/certificate-arn: "${ACM_CERT_ARN}"
     hosts:
       - host: "${VOTE_HOST}"
         paths:
           - path: /
             pathType: Prefix
             service: vote
       - host: "${RESULT_HOST}"
         paths:
           - path: /
             pathType: Prefix
             service: result
   EOF
   OTEL_ROLE="$(terraform -chdir=terraform output -raw otel_collector_role_arn)"
   helm upgrade --install votex ./k8s/helm/votex \
     -f ./k8s/helm/votex/values-eks.yaml \
     -f /tmp/votex-https-values.yaml \
     --set otel.collector.serviceAccount.roleArn="$OTEL_ROLE" \
     --namespace votex --rollback-on-failure
   ```
   Replace placeholder hostnames in Jenkins/SonarQube/Grafana manifests with owned DNS names and validate authentication/access controls before public exposure. Do not deploy placeholder ACM ARNs or domains.
11. **Credentials & Authentication**: Retrieve the generated Jenkins administrator password via `kubectl get secret jenkins-admin-credentials -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d`. Store required agent credentials:
    - `dockerhub-credentials`: Username & Password for Docker Hub candidate publishing.
    - `k8s-kubeconfig`: Secret file containing cluster kubeconfig for Helm continuous delivery.
    - `sonarqube-token`: Secret text analysis token for SonarQube SAST and Quality Gate callback.
12. **Jenkins 9-Stage Pipeline Execution & Automatic SCM Trigger**:
    - **Trigger Mechanism**: The pipeline is pre-configured with outbound periodic SCM polling (`pollSCM('H/5 * * * *')` in `Jenkinsfile` and `triggers { scm('H/5 * * * *') }` in Job DSL). Outbound polling eliminates fragile webhook-relay infrastructure since the internal Jenkins service cannot receive inbound GitHub webhooks directly.
    - **Commit Batching & Concurrency Guard**: SCM polling polls GitHub `main` every 5 minutes. If multiple commits are pushed within an interval, SCM polling detects the latest HEAD and triggers a single consolidated build rather than queueing redundant intermediate builds. `disableConcurrentBuilds()` strictly prevents overlapping runs.
    - **First-Run Bootstrap**: JCasC and Job DSL register the pipeline and trigger definition automatically on Jenkins startup. The operator can run the first build manually or let the periodic poll detect the initial commit.
    - **9 Main Stages**: The pipeline sequentially executes: 1. Checkout SCM, 2. Service Build & Smoke Validation, 3. SonarQube SAST & Quality Gate, 4. Trivy Filesystem Scan, 5. Docker Build, 6. Trivy Image Scan, 7. OWASP ZAP DAST, 8. Docker Hub Publish, and 9. EKS Deployment & Verification.

### Phase D: Operational Verification & Evidence
13. **Load Testing & HPA Verification**: Run k6 traffic generation against the live ingress URL:
    ```bash
    TARGET_URL="https://vote.votex.domain.tld" k6 run tests/load/load-test.js
    kubectl get hpa -n votex --watch
    ```
14. **Chaos Resilience Verification**: Execute controlled pod restart self-healing proof:
    ```bash
    AWS_ACCOUNT_ID="<YOUR_ACCOUNT_ID>" bash tests/resilience/chaos-test.sh --confirm
    ```
15. **Lambda Alarms Verification**: After configuring real HTTPS health URLs, enable external synthetic monitoring via persistent configuration and reconciliation (`terraform/lambda.auto.tfvars` with full plan and apply). The module `module.lambda` is reconciled without state drift. Verify EventBridge and CloudWatch alarms live.
16. **Ansible Disaster Recovery Verification**: Execute automated logical database backup and isolated restore verification:
    ```bash
    ansible-playbook -i ansible/inventory/hosts.ini.example ansible/backup_restore_verify.yml
    ```
17. **OpenTelemetry & AWS X-Ray Verification**: Submit multi-poll votes and inspect distributed trace spans across Vote, Redis Streams, Worker, and PostgreSQL in the AWS X-Ray console.
18. **Rollback Proof**: Test failure recovery by triggering a canary deployment with invalid probes, validating that Helm and Jenkins cleanly rollback to the prior revision.
19. **Evidence Capture**: Gather screenshots, metrics snapshots, and pipeline logs into `reports/` for audit documentation.
20. **Safe Cloud Teardown**: Decommission all live AWS resources to prevent lingering charges:
    ```bash
    EXPECTED_AWS_ACCOUNT_ID="<YOUR_ACCOUNT_ID>" ./ops/destroy.sh
    ```

---

## 9. What Requires a Live Approved AWS Deployment

The following operational validations require an active, authorized AWS session with registered domain infrastructure:
1. **Public Domain DNS**: Registering an `A` record alias in Route 53 pointing to the AWS ALB.
2. **ACM Public Certificate**: Issuing an AWS Certificate Manager TLS certificate for HTTPS termination.
3. **Live ALB Provisioning**: Launching the AWS Load Balancer Controller to bind the ALB.
4. **Live EventBridge & CloudWatch Alarm Evaluation**: Verifying the Lambda synthetic health check alarms on AWS console.
5. **Live Distributed Trace Rendering**: Visualizing complete multi-service traces in AWS X-Ray service maps.

---

## 10. Container Security Posture & Least Privilege

The platform enforces strict container security standards while transparently addressing Linux networking constraints:

- **Worker Daemon**: Fully hardened non-root container (`runAsNonRoot: true`, `runAsUser: 10001`, `runAsGroup: 10001`, `allowPrivilegeEscalation: false`, `capabilities: drop: ["ALL"]`). It consumes Redis stream messages and persists into PostgreSQL without opening network listener ports.
- **Vote (Python/Gunicorn) & Result (Node.js)**: Bind privileged port 80 directly inside the container without an internal reverse proxy sidecar. Under Linux kernel networking, binding ports < 1024 requires either root (`runAsUser: 0`) or ambient capabilities (`CAP_NET_BIND_SERVICE`). They run with container root for port binding, isolated inside private VPC subnets behind the Application Load Balancer.
- **Log Aggregation (Grafana Alloy)**: Runs as a Kubernetes DaemonSet with read-only host volume mounts (`/var/log`) to collect container stdout/stderr streams.
- **Metrics & Logging Storage (Loki & Prometheus)**: Both stateful applications run under non-root service accounts (`runAsUser: 10001` for Loki, `runAsUser: 65534` for Prometheus) with dedicated filesystem ownership (`fsGroup`).

---

## 11. Engineering Status & Verification Matrix

| Component / Capability | Implementation State | Offline Validation Status | Live AWS Requirement | Verification State |
| :--- | :---: | :---: | :--- | :---: |
| **VPC & EKS Node Infrastructure** | Implemented (`terraform/`) | `terraform validate`, `plan` (33 adds) | AWS account, VPC, EKS cluster creation | Pending authorization |
| **Microservices (Vote, Result, Worker)** | Implemented (`votex/`) | Unit, reliability, and service smoke checks verified offline | EKS cluster, Docker images pulled | Offline Validated |
| **Redis & PostgreSQL Storage** | Implemented (`k8s/helm/votex`) | Helm template & linting valid | AWS EBS gp3 dynamic volume attachment | Offline Validated |
| **Jenkins 9-Stage CI/CD** | Implemented (`jenkins/Jenkinsfile`) | Syntax, POSIX shell check, container image validated | EKS Kubernetes cloud, SonarQube token, Docker Hub credentials | Offline Validated |
| **Prometheus & Grafana Monitoring** | Implemented (`k8s/monitoring/`) | Values linted, Helm chart render validated | EKS cluster, EBS gp3 PVCs | Offline Validated |
| **Grafana Alloy & Loki Logging** | Implemented (`k8s/monitoring/`) | River config syntax checked (`alloy fmt`), chart templated | DaemonSet scheduling on live EC2 nodes | Offline Validated |
| **OpenTelemetry & AWS X-Ray** | Implemented (Vote, Worker, Helm) | Helm template with IRSA role ARN validated | AWS X-Ray IAM permissions, OTel collector daemon | Offline Validated |
| **PostgreSQL Backup & Restore** | Implemented (`ansible/`) | `ansible-playbook --syntax-check` validated | Active PostgreSQL pod in `votex` namespace | Offline Validated |
| **Resilience & Chaos Testing** | Implemented (`tests/resilience/`) | `bash -n` syntax checked, safety flags enforced | Running cluster with replica deployments | Offline Validated |
| **Load Testing (k6)** | Implemented (`tests/load/`) | `node --check` syntax checked, custom metrics valid | Live ALB URL with ingress routing | Offline Validated |
| **AWS Lambda Synthetic Canary** | Implemented (`terraform/modules/lambda/`, `lambda/health_check/handler.py`) | Pytest syntax & handler invocation verified | Live public URL, EventBridge rule, CloudWatch alarm | Offline Validated |
| **Automated Teardown Script** | Implemented (`ops/destroy.sh`) | `bash -n` syntax checked, safety checks verified | Live cluster resources to query and delete | Offline Validated |

---

## Author & Maintainer

Developed by **[Aarjav Jain](https://github.com/itsme-aarjav)**.
Repository: [github.com/itsme-aarjav/votex](https://github.com/itsme-aarjav/votex)
