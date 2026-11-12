#!/usr/bin/env bash
# Votex Platform Operations Dashboard
# Provides read-only status inspection for all application and platform services.
# Inspects EKS cluster endpoints, deployment status, and provides secure credential retrieval instructions.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_REGION:-eu-north-1}"
CLUSTER="${CLUSTER_NAME:-votex-cluster}"

echo "=============================================================================="
echo "VOTEX PLATFORM SERVICE & OPERATIONS DASHBOARD"
echo "Target AWS Region:  $REGION"
echo "Target EKS Cluster: $CLUSTER"
echo "Inspection Mode:    Read-Only"
echo "=============================================================================="
echo ""

HAS_KUBECTL=false
HAS_CLUSTER=false

if command -v kubectl >/dev/null 2>&1; then
  HAS_KUBECTL=true
  if kubectl cluster-info >/dev/null 2>&1; then
    HAS_CLUSTER=true
  fi
fi

if [ "$HAS_CLUSTER" = false ]; then
  echo "STATUS: Offline / Pending Cloud Deployment (Kubernetes cluster not reachable)."
  echo "Displaying architectural service catalog, expected endpoints, and access instructions."
  echo ""
fi

# Helper function to discover Ingress or Service routing
inspect_service() {
  local name="$1"
  local ns="$2"
  local svc="$3"
  local expected_host="$4"
  local default_path="$5"
  local user_ref="$6"
  local cred_instruction="$7"

  echo "------------------------------------------------------------------------------"
  echo "SERVICE: $name"

  if [ "$HAS_CLUSTER" = false ]; then
    echo "  Status:         Pending Deployment (cluster offline)"
    echo "  Expected Host:  https://$expected_host$default_path"
    echo "  Discovered URL: None (offline)"
    echo "  Availability:   Not tested (cluster unreachable)"
    echo "  Default User:   $user_ref"
    echo "  Credentials:    $cred_instruction"
    echo "  Missing Prereqs: Kubernetes cluster '$CLUSTER' ($REGION) not provisioned or unreachable"
    return
  fi

  # Check if service exists
  local svc_json
  if ! svc_json="$(kubectl get service "$svc" -n "$ns" -o json 2>/dev/null)"; then
    echo "  Status:         Unverified (service missing or Kubernetes API access denied)"
    echo "  Expected Host:  https://$expected_host$default_path"
    echo "  Discovered URL: None"
    echo "  Availability:   Service not present in cluster"
    echo "  Default User:   $user_ref"
    echo "  Credentials:    $cred_instruction"
    echo "  Missing Prereqs: Workload deployment for service '$svc' in namespace '$ns'"
    return
  fi

  # Extract Service selector dynamically using python
  local selector_arg
  selector_arg="$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    selectors = data.get('spec', {}).get('selector', {})
    if selectors:
        print(','.join(f'{k}={v}' for k, v in selectors.items()))
    else:
        print('')
except Exception:
    print('')
" "$svc_json" 2>/dev/null || echo "")"

  local pods_json
  if [ -n "$selector_arg" ]; then
    if ! pods_json="$(kubectl get pods -n "$ns" -l "$selector_arg" -o json 2>/dev/null)"; then
      echo "  Status:         Unverified (pod discovery failed; check API permissions)"
      return
    fi
  else
    if ! pods_json="$(kubectl get pods -n "$ns" -l "app=$svc" -o json 2>/dev/null)"; then
      echo "  Status:         Unverified (pod discovery failed; check API permissions)"
      return
    fi
  fi

  # Parse pod counts strictly via Python (avoids grep -c double-zero bug)
  local counts
  counts="$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1]) if sys.argv[1].strip() else {}
    items = data.get('items', [])
    total = len(items)
    ready = 0
    for pod in items:
        conditions = pod.get('status', {}).get('conditions', [])
        for c in conditions:
            if c.get('type') == 'Ready' and c.get('status') == 'True':
                ready += 1
                break
    print(f'{ready} {total}')
except Exception:
    print('0 0')
" "$pods_json" 2>/dev/null || echo "0 0")"

  local ready_count total_count
  read -r ready_count total_count <<< "$counts"

  if [ "$total_count" -gt 0 ] && [ "$ready_count" -eq "$total_count" ]; then
    echo "  Status:         Healthy ($ready_count/$total_count pods Ready)"
  elif [ "$total_count" -gt 0 ]; then
    echo "  Status:         Degraded ($ready_count/$total_count pods Ready)"
  else
    echo "  Status:         Unavailable (0 pods running)"
  fi

  # Inspect Ingress
  local discovered_url="None (internal ClusterIP only)"
  local missing_prereq="None (internal ClusterIP only; use port-forward to access)"
  local alb_host=""
  local ing_host=""
  local ingress_json
  if ! ingress_json="$(kubectl get ingress -n "$ns" -o json 2>/dev/null)"; then
    echo "  Ingress:        Unverified (Kubernetes API unavailable or access denied)"
    return
  fi

  if [ -n "$ingress_json" ] && [ "$ingress_json" != "{}" ]; then
    local address
    address="$(python3 -c "
import json, sys
svc = sys.argv[1]
try:
    data = json.loads(sys.argv[2])
    for ing in data.get('items', []):
        lb_list = ing.get('status', {}).get('loadBalancer', {}).get('ingress', []) or [{}]
        alb = lb_list[0].get('hostname') or lb_list[0].get('ip') or ''
        for rule in ing.get('spec', {}).get('rules', []):
            paths = rule.get('http', {}).get('paths', [])
            for p in paths:
                backend_svc = p.get('backend', {}).get('service', {}).get('name')
                if backend_svc == svc:
                    host = rule.get('host', '')
                    print(f'{host}|{alb}')
                    sys.exit(0)
except Exception:
    pass
" "$svc" "$ingress_json" 2>/dev/null || echo "")"

    if [ -n "$address" ]; then
      IFS='|' read -r ing_host alb_host <<< "$address"
      if [[ "$ing_host" == *domain.tld* || "$ing_host" == *example.com* ]]; then
        discovered_url="None (Placeholder host '$ing_host' — DNS/ACM not yet configured)"
        missing_prereq="Public domain and ACM certificate configuration required"
      elif [ -n "$alb_host" ]; then
        discovered_url="https://$ing_host$default_path"
        missing_prereq="Verify Route 53 / DNS CNAME points to ALB ($alb_host)"
      else
        discovered_url="https://$ing_host$default_path (ALB pending provisioning)"
        missing_prereq="AWS Load Balancer Controller provisioning in progress"
      fi
    fi
  fi

  # Check endpoint availability if public URL is discovered
  local availability="Internal service (ClusterIP)"
  if [[ "$discovered_url" =~ ^https:// && "$discovered_url" != *"pending"* && "$discovered_url" != *"Placeholder"* ]]; then
    local test_url="https://$ing_host$default_path"
    PROBE_CODE="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 8 "$test_url" 2>/dev/null)" || PROBE_CODE="000"
    if [ "$PROBE_CODE" = "200" ] || [ "$PROBE_CODE" = "204" ]; then
      availability="HTTPS reachable (HTTP $PROBE_CODE, valid TLS; login not verified)"
      missing_prereq="Verify authenticated access separately"
    elif [ "$PROBE_CODE" = "301" ] || [ "$PROBE_CODE" = "302" ] || [ "$PROBE_CODE" = "303" ] || [ "$PROBE_CODE" = "307" ] || [ "$PROBE_CODE" = "308" ]; then
      availability="HTTPS responding with redirect (HTTP $PROBE_CODE, valid TLS; destination not verified)"
      missing_prereq="Verify redirect destination and login separately"
    elif [ "$PROBE_CODE" = "401" ] || [ "$PROBE_CODE" = "403" ]; then
      availability="HTTPS reachable, authentication or access restriction enforced (HTTP $PROBE_CODE)"
      missing_prereq="Authenticate using approved credentials"
    else
      if curl -s -k -f --connect-timeout 2 -o /dev/null "$test_url" 2>/dev/null; then
        availability="Warning: Responding but Invalid / Untrusted TLS Certificate"
        missing_prereq="Install valid ACM certificate matching $ing_host"
      else
        availability="Unreachable (DNS not yet resolving to ALB or security group closed)"
      fi
    fi
  elif [ "$total_count" -gt 0 ] && [ "$ready_count" -gt 0 ]; then
    availability="ClusterIP active (Internal port-forward ready)"
  else
    availability="Not available (pods not ready)"
  fi

  echo "  Expected Host:  https://$expected_host$default_path"
  echo "  Discovered URL: $discovered_url"
  echo "  Availability:   $availability"
  echo "  Default User:   $user_ref"
  echo "  Credentials:    $cred_instruction"
  echo "  Missing Prereqs: $missing_prereq"
}

# 1. Vote Application
inspect_service \
  "Vote Application (Flask)" \
  "votex" "vote" \
  "vote.votex.domain.tld" "/" \
  "Self-registered voter / Anonymous" \
  "Register voter account in Vote UI or vote as anonymous session."

# 2. Result Analytics
inspect_service \
  "Result Analytics (Node.js)" \
  "votex" "result" \
  "result.votex.domain.tld" "/" \
  "Public analytics view (Read-only)" \
  "No authentication required for public real-time analytics."

# 3. Jenkins CI/CD
inspect_service \
  "Jenkins Automation Server" \
  "jenkins" "jenkins" \
  "jenkins.votex.domain.tld" "/" \
  "admin" \
  "kubectl get secret jenkins-admin-credentials -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d"

# 4. SonarQube Code Quality
inspect_service \
  "SonarQube Static Analysis" \
  "sonarqube" "sonarqube" \
  "sonarqube.votex.domain.tld" "/dashboard?id=votex-platform" \
  "admin" \
  "Rotate SonarQube's first-run password and generate the administrator API token; do not use default credentials."

# 5. Grafana Observability Dashboards
inspect_service \
  "Grafana Monitoring Dashboards" \
  "monitoring" "prometheus-grafana" \
  "grafana.votex.domain.tld" "/" \
  "admin" \
  "kubectl get secret -n monitoring grafana-admin-credentials -o jsonpath='{.data.admin-password}' | base64 -d"

# 6. Prometheus Metric Server
inspect_service \
  "Prometheus TSDB" \
  "monitoring" "prometheus-kube-prometheus-prometheus" \
  "prometheus.votex.domain.tld" "/targets" \
  "Internal / Operator" \
  "kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 (internal-only)"

echo "------------------------------------------------------------------------------"
echo "AWS NATIVE CONSOLE DASHBOARDS & LOGGING"
echo ""
echo "AWS X-Ray Distributed Traces:"
echo "  Location:       https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#xray:traces"
echo "  Tracing Flow:   Vote -> Redis Streams -> Worker -> PostgreSQL -> AWS X-Ray (via OTel Collector)"
echo "  Status:         OTel Collector ConfigMap configured with IAM IRSA role."
echo ""
echo "AWS CloudWatch Dashboards & Metrics:"
echo "  Location:       https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards"
echo "  Metrics:        Votex/SyntheticMonitoring (HealthStatus, CheckLatency)"
echo ""
LAMBDA_STATUS="Disabled (Enablement requires public HTTPS domain & ACM certificate)"
TF_STATE="$ROOT_DIR/terraform/terraform.tfstate"
LAMBDA_VARS="$ROOT_DIR/terraform/lambda.auto.tfvars"
if [ -f "$LAMBDA_VARS" ] && grep -q 'enable_health_check_lambda = true' "$LAMBDA_VARS" 2>/dev/null; then
  LAMBDA_STATUS="Desired in local Terraform config; AWS deployment not verified"
elif [ -f "$TF_STATE" ]; then
  HAS_LAMBDA="$(python3 -c "
import json
try:
    with open('$TF_STATE') as f:
        data = json.load(f)
    found = False
    for r in data.get('resources', []):
        if r.get('type') == 'aws_lambda_function' and len(r.get('instances', [])) > 0:
            found = True
            break
    print('yes' if found else 'no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")"
  if [ "$HAS_LAMBDA" = "yes" ]; then
    LAMBDA_STATUS="Recorded in local Terraform state; live AWS status not verified"
  fi
fi

echo "AWS Lambda Synthetic Health Monitor:"
echo "  Status:         $LAMBDA_STATUS"
echo "  Function Name:  ${CLUSTER}-synthetic-health-check"
echo "  Console:        https://console.aws.amazon.com/lambda/home?region=${REGION}#/functions/${CLUSTER}-synthetic-health-check"
echo "  Schedule:       rate(5 minutes) via EventBridge"
echo "  Target URLs:    Vote /api/health and Result /api/health"
echo "=============================================================================="
