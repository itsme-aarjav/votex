#!/usr/bin/env bash
set -e

echo "Fetching service endpoints..."

format_endpoint() {
  local ns="$1"
  local svc="$2"
  local path_suffix="$3"
  local local_port="$4"

  if ! kubectl get svc "$svc" -n "$ns" >/dev/null 2>&1; then
    echo "not deployed (pending cluster deployment in Option B)"
    return
  fi

  # Check if an Ingress rule exists for this service with online hostname
  local ing_host
  ing_host=$(kubectl get ingress -n "$ns" -o jsonpath="{.items[?(@.spec.rules[*].http.paths[*].backend.service.name=='$svc')].spec.rules[0].host}" 2>/dev/null || echo "")
  local alb_host
  alb_host=$(kubectl get ingress -n "$ns" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

  if [ -n "$ing_host" ]; then
    echo "https://${ing_host}${path_suffix} (ALB Ingress: ${alb_host:-pending DNS})"
    return
  fi

  local svc_type
  svc_type=$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.spec.type}' 2>/dev/null || echo "ClusterIP")
  local svc_port
  svc_port=$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "$local_port")

  if [ "$svc_type" = "LoadBalancer" ]; then
    local host
    host=$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -z "$host" ]; then
      host=$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    fi
    if [ -z "$host" ]; then
      echo "pending (LoadBalancer provisioning)"
    else
      echo "https://${host}${path_suffix}"
    fi
  else
    echo "ClusterIP (Internal private: http://${svc}.${ns}.svc.cluster.local:${svc_port}${path_suffix} | Online HTTPS requires Ingress/ALB with custom domain & ACM certificate)"
  fi
}

echo ""
echo "Votex Service Endpoints:"
echo "  Vote UI:         $(format_endpoint votex vote "" 5000)"
echo "  Result UI:       $(format_endpoint votex result "" 4000)"
echo "  Jenkins:         $(format_endpoint jenkins jenkins ":8080/job/Votex-CICD/" 8080)"
echo "  GitHub Webhook:  $(format_endpoint jenkins jenkins ":8080/github-webhook/" 8080)"
echo "  SonarQube:       $(format_endpoint sonarqube sonarqube ":9000/dashboard?id=votex-platform" 9000)"
echo "  Grafana:         $(format_endpoint monitoring prometheus-grafana "" 3000)"
echo "  Prometheus:      $(format_endpoint monitoring prometheus-kube-prometheus-prometheus ":9090" 9090)"
echo ""
