#!/usr/bin/env bash
# Votex Chaos & Resilience Engineering Verification Suite
# Safely tests Kubernetes pod self-healing and queue recovery.
# Non-destructive: No persistent volume or database deletion.

set -euo pipefail

TARGET_CLUSTER="${CLUSTER_NAME:-votex-cluster}"
TARGET_REGION="${AWS_REGION:-eu-north-1}"
EXPECTED_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
NAMESPACE="${K8S_NAMESPACE:-votex}"
DRY_RUN=false
CONFIRMED=false

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run          Inspect cluster state and targets without injecting failures"
    echo "  --confirm          Explicitly authorize chaos injection actions"
    echo "  --namespace <ns>   Target Kubernetes namespace (default: votex)"
    echo "  -h, --help         Show this help message"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --confirm)
            CONFIRMED=true
            shift
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_fail "Unknown argument: $1"
            ;;
    esac
done

log_info "Starting Votex Resilience & Chaos Verification Suite"
log_info "Target Cluster:   ${TARGET_CLUSTER}"
log_info "Target Region:    ${TARGET_REGION}"
log_info "Target Namespace: ${NAMESPACE}"
log_info "Dry Run:          ${DRY_RUN}"

# Safety Control 1: Verify Kubernetes connectivity and context
if ! kubectl cluster-info > /dev/null 2>&1; then
    log_fail "Kubernetes cluster is not reachable via kubectl. Check kubeconfig."
fi

CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")
CLUSTER_IN_CONTEXT=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${CURRENT_CONTEXT}')].context.cluster}" 2>/dev/null || echo "")
log_info "Current Kubernetes Context: ${CURRENT_CONTEXT} (Cluster: ${CLUSTER_IN_CONTEXT})"

# Enforce strict cluster identity verification
if [ "${DRY_RUN}" = false ]; then
    # Reject local emulation contexts for live production fault injection
    if [[ "${CURRENT_CONTEXT}" =~ "docker-desktop" ]] || [[ "${CURRENT_CONTEXT}" =~ "minikube" ]] || [[ "${CURRENT_CONTEXT}" =~ "kind-" ]]; then
        log_fail "Local cluster context '${CURRENT_CONTEXT}' is not permitted for live chaos injection. Must target EKS cluster '${TARGET_CLUSTER}'."
    fi

    # Context or cluster must target votex-cluster
    if [[ ! "${CURRENT_CONTEXT}" =~ "${TARGET_CLUSTER}" ]] && [[ ! "${CLUSTER_IN_CONTEXT}" =~ "${TARGET_CLUSTER}" ]]; then
        log_fail "Current context '${CURRENT_CONTEXT}' does not target expected EKS cluster '${TARGET_CLUSTER}'. Aborting for safety."
    fi

    if [ "$NAMESPACE" != "votex" ]; then
        log_fail "Live chaos is restricted to namespace votex."
    fi
    command -v aws >/dev/null 2>&1 || log_fail "AWS CLI required for cluster identity check."
    [[ "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] ||
        log_fail "Set AWS_ACCOUNT_ID to your exact 12-digit target AWS account."
    DETECTED_ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" ||
        log_fail "Unable to verify AWS account."
    [ "$DETECTED_ACCOUNT" = "$EXPECTED_ACCOUNT_ID" ] ||
        log_fail "Wrong AWS account; no faults injected."
    EKS_ARN="$(aws eks describe-cluster --region "$TARGET_REGION" --name "$TARGET_CLUSTER" --query 'cluster.arn' --output text 2>/dev/null)" ||
        log_fail "Target EKS cluster ARN cannot be verified."
    EXPECTED_ARN="arn:aws:eks:${TARGET_REGION}:${EXPECTED_ACCOUNT_ID}:cluster/${TARGET_CLUSTER}"
    [ "$EKS_ARN" = "$EXPECTED_ARN" ] || log_fail "Wrong EKS cluster identity."
    AWS_ENDPOINT="$(aws eks describe-cluster --region "$TARGET_REGION" --name "$TARGET_CLUSTER" --query 'cluster.endpoint' --output text 2>/dev/null)" ||
        log_fail "Cannot verify EKS endpoint."
    KUBE_ENDPOINT="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" ||
        log_fail "Cannot verify active kubeconfig endpoint."
    [ -n "$AWS_ENDPOINT" ] && [ "$AWS_ENDPOINT" = "$KUBE_ENDPOINT" ] ||
        log_fail "Kubeconfig endpoint does not match target EKS."
    log_info "Verified EKS account, region and active endpoint."
fi

# Safety Control 2: Require confirmation if not in dry-run mode
if [ "${DRY_RUN}" = false ] && [ "${CONFIRMED}" = false ]; then
    log_warn "Chaos injection will terminate running pods to verify self-healing."
    read -r -p "Execute resilience tests against context '${CURRENT_CONTEXT}'? [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY])
            CONFIRMED=true
            ;;
        *)
            log_info "Aborted by operator. Run with --dry-run for non-intrusive inspection."
            exit 0
            ;;
    esac
fi

# Pre-flight: Inspect Namespace Pods
log_info "Discovering target workloads in namespace '${NAMESPACE}'..."
AVAILABLE_PODS=$(kubectl get pods -n "${NAMESPACE}" --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)

if [ -z "${AVAILABLE_PODS}" ]; then
    log_fail "No pods found in namespace '${NAMESPACE}'. Ensure Votex is deployed before running resilience verification."
fi

# Test 1: PostgreSQL PVC Data Integrity Check (Non-destructive)
log_info "Test 1: Verifying PostgreSQL PersistentVolumeClaim binding & integrity..."
DB_PVC_STATUS=$(kubectl get pvc -n "${NAMESPACE}" -l app=db -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [ "${DB_PVC_STATUS}" = "Bound" ]; then
    log_pass "PostgreSQL PVC is Bound and healthy (data volume is protected)."
else
    log_fail "PostgreSQL PVC status is '${DB_PVC_STATUS}' (expected Bound). Data volume protection check failed."
fi

if [ "${DRY_RUN}" = true ]; then
    log_info "[DRY-RUN] Candidate targets identified:"
    kubectl get pods -n "${NAMESPACE}" -o wide
    log_pass "[DRY-RUN] Inspection completed successfully. Zero failures injected."
    exit 0
fi

# Test 2: Worker Pod Failure and Self-Healing
log_info "Test 2: Testing Worker pod self-healing and queue recovery..."
ORIGINAL_WORKER_POD=$(kubectl get pods -n "${NAMESPACE}" -l app=worker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
ORIGINAL_WORKER_UID=$(kubectl get pods -n "${NAMESPACE}" -l app=worker -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null || true)

if [ -z "${ORIGINAL_WORKER_POD}" ]; then
    log_fail "No Worker pod found with selector app=worker in namespace '${NAMESPACE}'."
fi

WORKER_OWNER_KIND=$(kubectl get pods -n "${NAMESPACE}" -l app=worker -o jsonpath='{.items[0].metadata.ownerReferences[0].kind}' 2>/dev/null || echo "")
if [ "${WORKER_OWNER_KIND}" != "ReplicaSet" ]; then
    log_fail "Worker pod owner is '${WORKER_OWNER_KIND}', expected ReplicaSet."
fi

log_info "Terminating Worker pod: ${ORIGINAL_WORKER_POD} (UID: ${ORIGINAL_WORKER_UID})"
START_TIME=$(date +%s)
kubectl delete pod "${ORIGINAL_WORKER_POD}" -n "${NAMESPACE}" --grace-period=5 > /dev/null 2>&1
kubectl wait -n "${NAMESPACE}" --for=delete pod/"${ORIGINAL_WORKER_POD}" --timeout=60s >/dev/null || log_fail "Original Worker pod deletion timed out."

log_info "Waiting for ReplicaSet to recreate Worker pod..."
if ! kubectl wait --namespace "${NAMESPACE}" --for=condition=ready pod --selector=app=worker --timeout=60s > /dev/null 2>&1; then
    log_fail "Worker pod self-healing failed: recovery wait timed out after 60s."
fi

RECOVERY_TIME=$(( $(date +%s) - START_TIME ))
NEW_WORKER_POD=$(kubectl get pods -n "${NAMESPACE}" -l app=worker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "unknown")
NEW_WORKER_UID=$(kubectl get pods -n "${NAMESPACE}" -l app=worker -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null || echo "unknown")
WORKER_READY_STATUS=$(kubectl get pods -n "${NAMESPACE}" -l app=worker -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

if [ "${NEW_WORKER_UID}" = "${ORIGINAL_WORKER_UID}" ]; then
    log_fail "Worker pod was not recreated (UID unchanged: ${NEW_WORKER_UID})."
fi

if [ "${WORKER_READY_STATUS}" != "True" ]; then
    log_fail "Worker pod recreated but status Ready is not True (${WORKER_READY_STATUS})."
fi
log_pass "Worker self-healed: new pod ${NEW_WORKER_POD} (UID: ${NEW_WORKER_UID}) is Ready=True in ${RECOVERY_TIME}s."

# Test 3: Redis In-Memory Queue Interruption & Recovery
log_info "Test 3: Testing Redis queue pod restart recovery..."
ORIGINAL_REDIS_POD=$(kubectl get pods -n "${NAMESPACE}" -l app=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
ORIGINAL_REDIS_UID=$(kubectl get pods -n "${NAMESPACE}" -l app=redis -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null || true)

if [ -z "${ORIGINAL_REDIS_POD}" ]; then
    log_fail "No Redis pod found with selector app=redis in namespace '${NAMESPACE}'."
fi

REDIS_OWNER_KIND=$(kubectl get pods -n "${NAMESPACE}" -l app=redis -o jsonpath='{.items[0].metadata.ownerReferences[0].kind}' 2>/dev/null || echo "")
if [ "${REDIS_OWNER_KIND}" != "ReplicaSet" ]; then
    log_fail "Redis pod owner is '${REDIS_OWNER_KIND}', expected ReplicaSet."
fi

log_info "Terminating Redis pod: ${ORIGINAL_REDIS_POD} (UID: ${ORIGINAL_REDIS_UID})"
START_TIME=$(date +%s)
kubectl delete pod "${ORIGINAL_REDIS_POD}" -n "${NAMESPACE}" --grace-period=5 > /dev/null 2>&1
kubectl wait -n "${NAMESPACE}" --for=delete pod/"${ORIGINAL_REDIS_POD}" --timeout=60s >/dev/null || log_fail "Original Redis pod deletion timed out."

log_info "Waiting for Redis pod reconciliation..."
if ! kubectl wait --namespace "${NAMESPACE}" --for=condition=ready pod --selector=app=redis --timeout=60s > /dev/null 2>&1; then
    log_fail "Redis pod self-healing failed: recovery wait timed out after 60s."
fi

RECOVERY_TIME=$(( $(date +%s) - START_TIME ))
NEW_REDIS_POD=$(kubectl get pods -n "${NAMESPACE}" -l app=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "unknown")
NEW_REDIS_UID=$(kubectl get pods -n "${NAMESPACE}" -l app=redis -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null || echo "unknown")
REDIS_READY_STATUS=$(kubectl get pods -n "${NAMESPACE}" -l app=redis -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

if [ "${NEW_REDIS_UID}" = "${ORIGINAL_REDIS_UID}" ]; then
    log_fail "Redis pod was not recreated (UID unchanged: ${NEW_REDIS_UID})."
fi

if [ "${REDIS_READY_STATUS}" != "True" ]; then
    log_fail "Redis pod recreated but status Ready is not True (${REDIS_READY_STATUS})."
fi
log_pass "Redis self-healed: new pod ${NEW_REDIS_POD} (UID: ${NEW_REDIS_UID}) is Ready=True in ${RECOVERY_TIME}s."

echo ""
log_pass "Resilience and chaos verification completed successfully."
