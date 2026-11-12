# Votex — Production Dashboard Screenshots Portfolio

All 22 screenshots in this directory were **personally captured by the project owner** from the live AWS production environment (`eu-north-1`).

- **Original Screenshots Captured**: 32
- **Retained High-Value Evidence**: 22
- **Removed Duplicate / Micro-Scrolls**: 10

---

## 1. Application Layer (`application/`)

| Screenshot | Target Endpoint | Description |
| :--- | :--- | :--- |
| [`vote-application.png`](application/vote-application.png) | `https://vote.votex.aarjav.site` | Main user polling interface (Cats vs Dogs) displaying interactive voting options, platform navigation, and secure HTTPS lock. |
| [`result-analytics-dashboard.png`](application/result-analytics-dashboard.png) | `https://result.votex.aarjav.site` | Real-time analytics dashboard displaying live vote distribution, percentage breakdown, and active WebSocket state. |

---

## 2. CI/CD & Delivery Pipeline (`ci-cd/`)

| Screenshot | Target View | Description |
| :--- | :--- | :--- |
| [`jenkins-pipeline-stageview.png`](ci-cd/jenkins-pipeline-stageview.png) | `jenkins.votex.aarjav.site/job/votex-pipeline/` | Pipeline overview and Stage View showing all 9 stages green (`SUCCESS`) across consecutive builds. |
| [`jenkins-trivy-artifacts.png`](ci-cd/jenkins-trivy-artifacts.png) | `job/votex-pipeline/16/artifact/reports/trivy/` | Archived Trivy scan outputs (`fs-scan.txt`, `image-vote-scan.txt`, `image-result-scan.txt`, `image-worker-scan.txt`). |
| [`jenkins-zap-artifacts.png`](ci-cd/jenkins-zap-artifacts.png) | `job/votex-pipeline/16/artifact/reports/zap/` | Archived OWASP ZAP DAST scan outputs (`zap-report.html` and `zap-report.json`). |

---

## 3. Security & Code Quality (`security/`)

| Screenshot | Target View | Description |
| :--- | :--- | :--- |
| [`sonarqube-projects-list.png`](security/sonarqube-projects-list.png) | `sonarqube.votex.aarjav.site/projects` | SonarQube portfolio view showing `Votex - Distributed Polling Platform` with Quality Gate **PASSED**. |
| [`sonarqube-quality-gate.png`](security/sonarqube-quality-gate.png) | `sonarqube.votex.aarjav.site/dashboard?id=votex-platform` | Clean Quality Gate status (**OK**, 0 new blocker/critical issues on new code, Cayc: compliant). |
| [`sonarqube-overall-measures.png`](security/sonarqube-overall-measures.png) | `/dashboard?id=votex-platform&codeScope=overall` | Complete code health metrics: 22 security hotspots, 111 code smells, 9 minor bugs, and 0.0% coverage. |
| [`sonarqube-code-metrics.png`](security/sonarqube-code-metrics.png) | `sonarqube.votex.aarjav.site/code?id=votex-platform` | Component-level code inspection for Vote (Python), Result (Node.js), and Worker (Python). |
| [`sonarqube-activity-timeline.png`](security/sonarqube-activity-timeline.png) | `sonarqube.votex.aarjav.site/project/activity?id=votex-platform` | Historical analysis timeline showing version progressions and release tags. |

---

## 4. Observability & Monitoring (`observability/`)

| Screenshot | Target View | Description |
| :--- | :--- | :--- |
| [`grafana-cluster-cpu-memory.png`](observability/grafana-cluster-cpu-memory.png) | Grafana / Kubernetes Compute Resources / Cluster | Cluster CPU Utilization (3%), CPU Requests (37%), and Memory Utilization (38%) across worker nodes. |
| [`grafana-cluster-network.png`](observability/grafana-cluster-network.png) | Grafana / Cluster Compute Resources | Live network traffic bandwidth and packet rates broken down by Kubernetes namespace. |
| [`grafana-node-metrics.png`](observability/grafana-node-metrics.png) | Grafana / Node Exporter / Nodes | Host-level performance: CPU cores, RAM, Disk I/O, and system load on both `m7i-flex.large` EC2 instances. |
| [`grafana-pod-cpu-usage.png`](observability/grafana-pod-cpu-usage.png) | Grafana / Pod Compute Resources | Container-level CPU consumption graphs for `vote`, `result`, `worker`, and Jenkins pods. |
| [`grafana-pod-memory-usage.png`](observability/grafana-pod-memory-usage.png) | Grafana / Pod Compute Resources | Container-level Memory Working Set (WSS) consumption across all active workloads. |
| [`grafana-loki-logs.png`](observability/grafana-loki-logs.png) | Grafana Explore (`Loki` datasource) | Live ingested container log streams (`{namespace="votex"}`) collected by the Grafana Alloy DaemonSet. |
| [`aws-xray-service-map.png`](observability/aws-xray-service-map.png) | AWS CloudWatch → X-Ray Traces → Service Map | End-to-end distributed service dependency map exported by the OpenTelemetry Collector. |

---

## 5. AWS Cloud Infrastructure (`aws/`)

| Screenshot | AWS Console Service | Description |
| :--- | :--- | :--- |
| [`aws-eks-cluster-overview.png`](aws/aws-eks-cluster-overview.png) | AWS EKS Console (`votex-cluster`) | EKS Control Plane overview showing Status: **Active**, Kubernetes version 1.36, and Stockholm `eu-north-1`. |
| [`aws-eks-cluster-resources.png`](aws/aws-eks-cluster-resources.png) | AWS EKS Console → Resources | Workload inventory showing DaemonSets, Deployments, and core add-ons (VPC CNI, CoreDNS, kube-proxy). |
| [`aws-vpc-configuration.png`](aws/aws-vpc-configuration.png) | AWS VPC Console | VPC details (`vpc-0cad9e240f7ebfe9c`, `10.0.0.0/16`) showing multi-AZ public and private subnets. |
| [`aws-lambda-synthetic-function.png`](aws/aws-lambda-synthetic-function.png) | AWS Lambda Console | Synthetic health check function (`votex-cluster-synthetic-health-check`), EventBridge trigger, and Python 3.11 code. |
| [`aws-lambda-monitoring-metrics.png`](aws/aws-lambda-monitoring-metrics.png) | AWS Lambda Console → Monitoring | CloudWatch execution metrics: Continuous 5-minute invocations, ~300ms duration, 0 errors, 100% success rate. |
