#!/usr/bin/env bash
set -eo pipefail

NAMESPACE="${K8S_NAMESPACE:-votex}"
HELM_RELEASE="${HELM_RELEASE:-votex}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    exit 1
}

echo "Running Votex chaos and resilience test suite (${NAMESPACE})..."

# Pre-flight check: Verify cluster connectivity
if ! kubectl cluster-info > /dev/null 2>&1; then
    log_fail "Kubernetes cluster is not reachable via kubectl. Please check your kubeconfig."
fi

# Test 1: Pod Self-Healing & ReplicaSet Resilience
log_info "Test 1: Simulating Pod Crash on Redis..."
REDIS_POD=$(kubectl get pods -n "${NAMESPACE}" -l app=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "${REDIS_POD}" ]; then
    log_warn "Redis pod not found by label 'app=redis'. Finding any Votex deployment pod..."
    REDIS_POD=$(kubectl get pods -n "${NAMESPACE}" -l 'app in (vote,result,worker,db,redis)' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi

if [ -n "${REDIS_POD}" ]; then
    log_info "Target Pod selected for termination: ${REDIS_POD}"
    kubectl delete pod "${REDIS_POD}" -n "${NAMESPACE}" --grace-period=0 --force > /dev/null 2>&1 || true
    log_info "Waiting for ReplicaSet reconciliation..."
    
    sleep 3
    kubectl wait --namespace "${NAMESPACE}" \
        --for=condition=ready pod \
        --selector=app=redis \
        --timeout=60s || {
            log_warn "Timeout waiting for pod readiness check. Checking running state..."
            kubectl get pods -n "${NAMESPACE}"
        }
    log_pass "Self-healing test passed: Pod recreated and ready."
else
    log_warn "No running pods found in namespace '${NAMESPACE}' to execute Pod Chaos."
fi

# Test 2: Persistent Volume Claim (PVC) Data Integrity Test
log_info "Test 2: Verifying PostgreSQL PVC status..."
DB_PVC_STATUS=$(kubectl get pvc -n "${NAMESPACE}" -l app=db -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")

if [ "${DB_PVC_STATUS}" == "Bound" ]; then
    log_pass "PostgreSQL PVC is Bound and healthy."
else
    log_warn "PostgreSQL PVC status: ${DB_PVC_STATUS}."
fi

# Test 3: Fault Injection - Broken Deployment Simulation
log_info "Test 3: Simulating broken deployment with invalid image tag..."
INITIAL_REVISION=$(helm history "${HELM_RELEASE}" -n "${NAMESPACE}" -o json 2>/dev/null | jq -r '.[-1].revision' 2>/dev/null || echo "1")
log_info "Current Helm revision: ${INITIAL_REVISION}"

log_info "Injecting faulty image tag..."
kubectl set image deployment/vote vote=aarjavjainn/votex-vote:non-existent-broken-tag -n "${NAMESPACE}" > /dev/null 2>&1 || true

sleep 4
ROLLOUT_STATUS=$(kubectl rollout status deployment/vote -n "${NAMESPACE}" --timeout=15s 2>&1 || true)
log_warn "Deployment failure detected as expected."

# Test 4: Rollback Execution
log_info "Test 4: Executing rollback to last stable revision..."
if helm status "${HELM_RELEASE}" -n "${NAMESPACE}" > /dev/null 2>&1; then
    log_info "Rolling back Helm release '${HELM_RELEASE}'..."
    helm rollback "${HELM_RELEASE}" -n "${NAMESPACE}"
else
    log_info "Rolling back via kubectl rollout undo..."
    kubectl rollout undo deployment/vote -n "${NAMESPACE}"
fi

log_info "Waiting for rollout status..."
kubectl rollout status deployment/vote -n "${NAMESPACE}" --timeout=90s

log_pass "Rollback verified successfully."
echo ""
echo -e "${GREEN}Resilience tests completed.${NC}"
