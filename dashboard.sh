#!/usr/bin/env bash
set -e

echo "Fetching service endpoints..."
VOTE_HOST=$(kubectl get svc vote -n votex -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
RESULT_HOST=$(kubectl get svc result -n votex -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
JENKINS_HOST=$(kubectl get svc jenkins -n jenkins -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
SONAR_HOST=$(kubectl get svc sonarqube -n sonarqube -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
GRAFANA_HOST=$(kubectl get svc prometheus-grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
PROM_HOST=$(kubectl get svc prometheus-kube-prometheus-prometheus -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

echo ""
echo "Votex Service Endpoints:"
echo "  Vote UI:         http://${VOTE_HOST}"
echo "  Result UI:       http://${RESULT_HOST}"
echo "  Jenkins:         http://${JENKINS_HOST}:8080/job/Votex-CICD/"
echo "  GitHub Webhook:  http://${JENKINS_HOST}:8080/github-webhook/"
echo "  SonarQube:       http://${SONAR_HOST}:9000/dashboard?id=votex-platform"
echo "  Grafana:         http://${GRAFANA_HOST} (admin / ZaekF5pstJaXWtpq87u8RKkvJRYlPaK4oE9PXiTu)"
echo "  Prometheus:      http://${PROM_HOST}:9090"
echo ""
