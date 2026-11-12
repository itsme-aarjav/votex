# Votex — Live AWS Production Proofs & Evidence Portfolio

This directory contains the verified, authentic evidence demonstrating the live production deployment, DevSecOps pipeline execution, operational resilience, and cloud observability of the **Votex Distributed Polling Platform** on Amazon Web Services (AWS `eu-north-1`).

> [!IMPORTANT]
> - **All screenshots are 100% genuine and personally captured by the project owner.** No automated or synthetic browser captures were used.
> - **AWS infrastructure remains live pending user-approved teardown.** The environment runs on an active EKS cluster (Kubernetes 1.36) with 2 × `m7i-flex.large` worker nodes.

---

## 1. Selected Pipeline Evidence Snapshot (Jenkins Build #16)

The primary raw security and pipeline artifacts in this directory are preserved directly from **Jenkins Build #16**, which corresponds to the user-captured Jenkins pipeline and artifact screenshots:

- **Selected Reference Build**: **Jenkins Build #16 (SUCCESS)**
- **Git Commit SHA**: `afc353a71079fc870421e1005e477848a8a721ad`
- **Release Tag**: `v2.1.16-afc353a`
- **Duration**: `452,203 ms (~7m 32s)`
- **Pipeline Architecture**: 9 automated stages (Checkout SCM → Smoke Validation → SonarQube Quality Gate → Trivy Filesystem Scan → Docker Build → Trivy Image Scan → OWASP ZAP DAST → Docker Hub Publish → EKS Deployment & Ansible Verification).
- *(Note: Subsequent documentation-only commits also triggered builds, e.g. Build #17 on commit `0beb680`, which also completed with status `SUCCESS` in 454,349 ms).*

---

## 2. Raw Technical Reports & Test Artifacts

Where terminal testing or scanner outputs provide the definitive engineering proof, genuine raw reports are retained directly:

### A. Security Scans (Aqua Security Trivy & OWASP ZAP)
- [`trivy-fs-scan-console.txt`](security/trivy-fs-scan-console.txt): Jenkins Build #16 Stage 4 console trace proving the zero-tolerance filesystem vulnerability check passed with Exit Code 0 (0 High/Critical findings).
- [`trivy-image-vote-scan.txt`](security/trivy-image-vote-scan.txt): Raw Trivy scanner output for `aarjavjainn/votex-vote` (0 High, 0 Critical).
- [`trivy-image-result-scan.txt`](security/trivy-image-result-scan.txt): Raw Trivy scanner output for `aarjavjainn/votex-result` (0 High, 0 Critical).
- [`trivy-image-worker-scan.txt`](security/trivy-image-worker-scan.txt): Raw Trivy scanner output for `aarjavjainn/votex-worker` (0 High, 0 Critical).
- [`zap-report.html`](security/zap-report.html): Complete interactive OWASP ZAP DAST assessment report.
- [`zap-report.json`](security/zap-report.json): Raw OWASP ZAP scan data documenting 0 High/Critical, 3 Medium, 6 Low, and 2 Informational alert types.

### B. CI/CD & Delivery Verification
- [`jenkins-build-16-pipeline.json`](ci-cd/jenkins-build-16-pipeline.json): Live Jenkins API export of Build #16 stage timings and outcomes.
- [`ansible-deployment-verification.txt`](ci-cd/ansible-deployment-verification.txt): Ansible post-deployment playbook execution log (**7/7 tasks OK, 0 failed**).

### C. Operational Tests & Resilience
- [`k6-load-test-summary.txt`](operations/k6-load-test-summary.txt): Terminal output from Grafana k6 load test (**903/903 checks passed**, 129 votes, p95: 272.7ms, 0% errors).
- [`chaos-resilience-test-log.txt`](operations/chaos-resilience-test-log.txt): Intentional pod kill resilience tests: stateless Worker healed in 5s; stateful Redis remounted EBS gp3 in 7s without data loss.
- [`ansible-disaster-recovery-log.txt`](operations/ansible-disaster-recovery-log.txt): PostgreSQL automated logical backup and non-destructive restore verification (**10/10 test rows verified**).
- [`helm-release-history.txt`](operations/helm-release-history.txt): Audit trail of Helm revisions 1 to 14 documenting automated rollbacks (revisions 9 and 12).
- [`kubernetes-hpa.txt`](operations/kubernetes-hpa.txt): Live HPA describe output and engineering analysis.

### D. Cloud Infrastructure & Cost Model
- [`terraform-resources.txt`](aws/terraform-resources.txt): Managed resource list from the remote S3 state backend (36 provisioned resources).
- [`aws-cost-and-runtime-audit.txt`](aws/aws-cost-and-runtime-audit.txt): Cost breakdown based on AWS hourly pricing for Stockholm, elapsed runtime hours, and budget margin.

---

## 3. Genuine Production Dashboard Screenshots

All visual dashboards are verified by **22 owner-captured screenshots** organized in [`screenshots/`](screenshots/):

| Category | Retained Screenshots | Key Visible Insights |
| :--- | :--- | :--- |
| [`screenshots/application/`](screenshots/application/) | 2 files (`vote-application.png`, `result-analytics-dashboard.png`) | Public web applications: interactive voting interface and real-time WebSocket percentage charts. |
| [`screenshots/ci-cd/`](screenshots/ci-cd/) | 3 files (`jenkins-pipeline-stageview.png`, `jenkins-trivy-artifacts.png`, `jenkins-zap-artifacts.png`) | Jenkins pipeline 9-stage green dashboard and archived security scan directories. |
| [`screenshots/security/`](screenshots/security/) | 5 files (`sonarqube-quality-gate.png`, `sonarqube-overall-measures.png`, `sonarqube-code-metrics.png`, etc.) | SonarQube Quality Gate status (**OK**), 22 hotspots, 111 smells, 9 minor bugs, and per-component line counts. |
| [`screenshots/observability/`](screenshots/observability/) | 7 files (`grafana-cluster-cpu-memory.png`, `grafana-cluster-network.png`, `grafana-node-metrics.png`, `grafana-pod-*.png`, `grafana-loki-logs.png`, `aws-xray-service-map.png`) | Live host CPU/RAM, network bandwidth, container working set memory, Loki log streams, and X-Ray trace map. |
| [`screenshots/aws/`](screenshots/aws/) | 5 files (`aws-eks-cluster-overview.png`, `aws-eks-cluster-resources.png`, `aws-vpc-configuration.png`, `aws-lambda-*.png`) | AWS Management Console: Active EKS control plane (1.36), VPC details, Lambda synthetic monitor and metrics. |

---

## 4. Engineering Limitations & Missing Coverage

To maintain technical authenticity, the following genuine limitations are documented:
1. **Prometheus Native Targets Screenshot**: Not captured in the initial screenshot batch; Prometheus scrape health (23/23 UP) is evidenced via the Grafana Node Exporter and Cluster dashboards.
2. **CloudWatch Alarms Console Screenshot**: Not captured; synthetic health check metrics are evidenced via Lambda CloudWatch metrics (100% success rate, 0 errors) and CLI outputs.
3. **HPA Replica Scale-up**: While HPA actively samples metrics (`ScalingActive: True`), the baseline k6 load test (129 requests) did not breach the 70% CPU threshold; replica scale-up beyond 2/2 is unproven.
4. **AWS Cost Explorer Lag**: AWS Cost Explorer has a 24-hour settlement lag; reported costs (~$1.88 USD / ~₹163.50 INR) represent real-time hourly model calculations based on AWS public pricing.
