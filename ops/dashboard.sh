#!/usr/bin/env bash
set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is unavailable. Service endpoints require a deployed cluster."
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to inspect Ingress service routing." >&2
  exit 1
fi
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "No accessible Kubernetes cluster. Online endpoints remain pending deployment."
  exit 0
fi

endpoint() {
  local ns="$1" svc="$2" path="$3"
  local ingress_json address host alb svc_type svc_port
  if ! kubectl get service "$svc" -n "$ns" >/dev/null 2>&1; then
    echo "not deployed (service $ns/$svc missing or inaccessible)"
    return
  fi
  if ! ingress_json="$(kubectl get ingress -n "$ns" -o json 2>/dev/null)"; then
    echo "Ingress status unavailable (check namespace access)"
    return
  fi
  address="$(printf '%s' "$ingress_json" | python3 -c '
import json, sys
service = sys.argv[1]
for ing in json.load(sys.stdin).get("items", []):
    lb = (ing.get("status", {}).get("loadBalancer", {}).get("ingress", []) or [{}])[0]
    for rule in ing.get("spec", {}).get("rules", []):
        paths = rule.get("http", {}).get("paths", [])
        if any(p.get("backend", {}).get("service", {}).get("name") == service for p in paths):
            print("{}|{}".format(rule.get("host", ""), lb.get("hostname") or lb.get("ip") or ""))
            sys.exit(0)
' "$svc")" || { echo "Unable to parse Ingress routing"; return; }
  IFS='|' read -r host alb <<< "$address"
  if [ -n "$host" ]; then
    if [[ "$host" == *domain.tld* || "$host" == *example.com* ]]; then
      echo "placeholder hostname ($host) — DNS/ACM not configured"
    elif [ -z "$alb" ]; then
      echo "https://$host$path (Ingress configured; ALB pending)"
    else
      echo "https://$host$path (ALB: $alb; DNS/TLS not verified)"
    fi
    return
  fi
  svc_type="$(kubectl get service "$svc" -n "$ns" -o jsonpath='{.spec.type}')"
  svc_port="$(kubectl get service "$svc" -n "$ns" -o jsonpath='{.spec.ports[0].port}')"
  if [ "$svc_type" = "LoadBalancer" ]; then
    echo "LoadBalancer service $ns/$svc:$svc_port (confirm endpoint scheme and TLS separately)"
  else
    echo "internal-only: http://$svc.$ns.svc.cluster.local:$svc_port$path (public HTTPS pending)"
  fi
}

echo "Votex service endpoints (inspection only; no deployment or port forwards)"
echo "  Vote UI:    $(endpoint votex vote /)"
echo "  Result UI:  $(endpoint votex result /)"
echo "  Jenkins:    $(endpoint jenkins jenkins /)"
echo "  SonarQube:  $(endpoint sonarqube sonarqube '/dashboard?id=votex-platform')"
echo "  Grafana:    $(endpoint monitoring prometheus-grafana /)"
echo "  Prometheus: $(endpoint monitoring prometheus-kube-prometheus-prometheus /)"
echo "  GitHub webhook: not configured (Jenkins uses SCM polling)"
