#!/usr/bin/env bash
# Kubernetes Cluster Cleanup Script
# Removes evicted pods, failed pods, completed jobs, and stuck namespaces
# Author: Greg Hendrickson
# License: MIT

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Defaults
DRY_RUN=false
NAMESPACE=""
VERBOSE=false
ACTIONS=()

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [ACTIONS...]

Kubernetes cluster cleanup utility for removing stale resources.

ACTIONS:
    evicted         Delete pods in Evicted state
    failed          Delete pods in Failed state (Error, OOMKilled, etc.)
    completed       Delete completed/succeeded pods
    jobs            Delete completed Jobs (keeps last N via TTL if set)
    stuck-ns        Force delete namespaces stuck in Terminating state
    all             Run all cleanup actions

OPTIONS:
    -n, --namespace NS    Target specific namespace (default: all namespaces)
    -d, --dry-run         Show what would be deleted without deleting
    -v, --verbose         Verbose output
    -h, --help            Show this help message

EXAMPLES:
    # Dry-run cleanup of evicted pods across all namespaces
    $(basename "$0") --dry-run evicted

    # Clean failed pods in specific namespace
    $(basename "$0") -n production failed

    # Full cluster cleanup
    $(basename "$0") all

SAFETY:
    - Always runs with confirmation prompt unless --dry-run
    - Stuck namespace cleanup removes finalizers (use with caution)
    - Jobs with ownerReferences are skipped (managed by CronJob/etc)
EOF
    exit 0
}

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

# Check kubectl is available and configured
check_prereqs() {
    if ! command -v kubectl &> /dev/null; then
        error "kubectl not found in PATH"
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    log "Connected to cluster: $(kubectl config current-context)"
}

# Get namespace flag for kubectl commands
ns_flag() {
    if [[ -n "$NAMESPACE" ]]; then
        echo "-n $NAMESPACE"
    else
        echo "--all-namespaces"
    fi
}

# Clean evicted pods
clean_evicted() {
    log "Finding evicted pods..."
    
    local pods
    pods=$(kubectl get pods $(ns_flag) --field-selector=status.phase=Failed \
        -o jsonpath='{range .items[?(@.status.reason=="Evicted")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    
    if [[ -z "$pods" ]]; then
        success "No evicted pods found"
        return
    fi

    local count
    count=$(echo "$pods" | wc -l)
    log "Found $count evicted pod(s)"

    if $VERBOSE; then
        echo "$pods"
    fi

    if $DRY_RUN; then
        warn "[DRY-RUN] Would delete $count evicted pod(s)"
        return
    fi

    echo "$pods" | while IFS='/' read -r ns name; do
        [[ -z "$name" ]] && continue
        kubectl delete pod "$name" -n "$ns" --grace-period=0 2>/dev/null && \
            success "Deleted evicted pod: $ns/$name" || \
            warn "Failed to delete: $ns/$name"
    done
}

# Clean failed pods (excluding evicted, handled separately)
clean_failed() {
    log "Finding failed pods..."
    
    local pods
    pods=$(kubectl get pods $(ns_flag) --field-selector=status.phase=Failed \
        -o jsonpath='{range .items[?(@.status.reason!="Evicted")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    
    if [[ -z "$pods" ]]; then
        success "No failed pods found"
        return
    fi

    local count
    count=$(echo "$pods" | grep -c . || echo 0)
    log "Found $count failed pod(s)"

    if $VERBOSE; then
        echo "$pods"
    fi

    if $DRY_RUN; then
        warn "[DRY-RUN] Would delete $count failed pod(s)"
        return
    fi

    echo "$pods" | while IFS='/' read -r ns name; do
        [[ -z "$name" ]] && continue
        kubectl delete pod "$name" -n "$ns" --grace-period=0 2>/dev/null && \
            success "Deleted failed pod: $ns/$name" || \
            warn "Failed to delete: $ns/$name"
    done
}

# Clean completed/succeeded pods
clean_completed() {
    log "Finding completed pods..."
    
    local pods
    pods=$(kubectl get pods $(ns_flag) --field-selector=status.phase=Succeeded \
        -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    
    if [[ -z "$pods" ]]; then
        success "No completed pods found"
        return
    fi

    local count
    count=$(echo "$pods" | grep -c . || echo 0)
    log "Found $count completed pod(s)"

    if $DRY_RUN; then
        warn "[DRY-RUN] Would delete $count completed pod(s)"
        return
    fi

    echo "$pods" | while IFS='/' read -r ns name; do
        [[ -z "$name" ]] && continue
        kubectl delete pod "$name" -n "$ns" 2>/dev/null && \
            success "Deleted completed pod: $ns/$name" || \
            warn "Failed to delete: $ns/$name"
    done
}

# Clean completed jobs (without ownerReferences - not managed by CronJob)
clean_jobs() {
    log "Finding completed Jobs..."
    
    # Get completed jobs that aren't owned by CronJobs
    local jobs
    jobs=$(kubectl get jobs $(ns_flag) -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.succeeded != null) | select(.status.succeeded > 0) | select(.metadata.ownerReferences == null) | "\(.metadata.namespace)/\(.metadata.name)"' || true)
    
    if [[ -z "$jobs" ]]; then
        success "No orphaned completed Jobs found"
        return
    fi

    local count
    count=$(echo "$jobs" | grep -c . || echo 0)
    log "Found $count completed Job(s) without owner"

    if $DRY_RUN; then
        warn "[DRY-RUN] Would delete $count completed Job(s)"
        return
    fi

    echo "$jobs" | while IFS='/' read -r ns name; do
        [[ -z "$name" ]] && continue
        kubectl delete job "$name" -n "$ns" --cascade=foreground 2>/dev/null && \
            success "Deleted completed job: $ns/$name" || \
            warn "Failed to delete: $ns/$name"
    done
}

# Force delete stuck terminating namespaces
clean_stuck_namespaces() {
    log "Finding namespaces stuck in Terminating state..."
    
    local namespaces
    namespaces=$(kubectl get namespaces --field-selector=status.phase=Terminating \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    
    if [[ -z "$namespaces" ]]; then
        success "No stuck namespaces found"
        return
    fi

    local count
    count=$(echo "$namespaces" | wc -w)
    log "Found $count namespace(s) stuck in Terminating state"
    warn "This will remove finalizers - ensure no critical resources remain!"

    if $DRY_RUN; then
        warn "[DRY-RUN] Would force-delete namespaces: $namespaces"
        return
    fi

    for ns in $namespaces; do
        log "Processing stuck namespace: $ns"
        
        # First, try to identify blocking resources
        if $VERBOSE; then
            log "Checking for blocking resources in $ns..."
            kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null | \
                xargs -I {} sh -c "kubectl get {} -n $ns 2>/dev/null" | head -20 || true
        fi

        # Remove finalizers from namespace
        kubectl get namespace "$ns" -o json | \
            jq '.spec.finalizers = []' | \
            kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null && \
            success "Removed finalizers from namespace: $ns" || \
            warn "Failed to remove finalizers from: $ns"
    done
}

# Main execution
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            evicted|failed|completed|jobs|stuck-ns|all)
                ACTIONS+=("$1")
                shift
                ;;
            *)
                error "Unknown option: $1"
                usage
                ;;
        esac
    done

    if [[ ${#ACTIONS[@]} -eq 0 ]]; then
        error "No action specified"
        usage
    fi

    check_prereqs

    if $DRY_RUN; then
        warn "Running in DRY-RUN mode - no changes will be made"
    fi

    # Confirmation for non-dry-run
    if ! $DRY_RUN; then
        echo ""
        warn "This will delete resources from your cluster!"
        read -p "Continue? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Aborted"
            exit 0
        fi
    fi

    echo ""

    # Execute requested actions
    for action in "${ACTIONS[@]}"; do
        case $action in
            evicted)
                clean_evicted
                ;;
            failed)
                clean_failed
                ;;
            completed)
                clean_completed
                ;;
            jobs)
                clean_jobs
                ;;
            stuck-ns)
                clean_stuck_namespaces
                ;;
            all)
                clean_evicted
                echo ""
                clean_failed
                echo ""
                clean_completed
                echo ""
                clean_jobs
                echo ""
                clean_stuck_namespaces
                ;;
        esac
        echo ""
    done

    success "Cleanup complete!"
}

main "$@"
